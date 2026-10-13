// ============================================================================
// File: csharp/src/LingoFuse_cs/Async.cs
// ============================================================================
// Async — callback-style asynchronous invocation facade.
// ============================================================================
// PURPOSE
// -------
// Provides a call-site-inline async API that mirrors the C++ wrapper
// lingofuse::callAsync and the Pascal LF.AsyncCallApp_P. The call and
// its completion handler are a single expression; there is exactly one
// error path (AsyncResult.Ok); the result is read from a borrowed
// handle that is valid only inside the handler body.
//
// This is the sibling of AsyncCallbackBridge (the await-style API
// exposed through Framework.CallAsync). The two are independent:
//
//   Await style   Framework.CallAsync(...) -> Task<DataHandle>
//                 The framework-owned result is COPIED into a fresh
//                 caller-owned DataHandle, and the Task is completed
//                 with that handle. Users interact with the result
//                 after the await returns.
//
//   Callback style   Async.Call(..., r => { ... })
//                 The framework-owned result is exposed as a
//                 BORROWED handle wrapped in AsyncResult. Users read
//                 the result inside the callback body. No Task is
//                 created, no byte-copy is performed, and the
//                 dispatch-failure path completes the callback
//                 synchronously on the caller's thread.
//
// Both styles share the same underlying C ABI, the same ownership
// rules for the framework-owned result, and the same "one error
// path" philosophy.
//
// CONTRACT (identical to C++ and Pascal)
// --------------------------------------
//   * A callback is invoked on a native worker thread. The only
//     exception is the dispatch-failure case, where the callback is
//     invoked synchronously on the caller's thread.
//
//   * The result handle is OWNED BY THE FRAMEWORK. It is released the
//     instant the callback returns. AsyncResult.Handle must not be
//     retained past the callback body, must not be passed to another
//     thread, and must not be passed to LF_FreeData.
//
//   * The callback MUST NOT block, MUST NOT call any blocking
//     LingoFuse function (LF_Call, LF_LocalCall, LF_PrepareDone,
//     LF_Shutdown), and MUST NOT touch UI controls. The same rules
//     that apply to every LingoFuse callback apply here.
//
//   * The callback MUST NOT let an exception escape. The trampoline
//     catches every exception and routes it to
//     Framework.ReportCallbackError.
//
// NO TIMEOUT / NO CANCELLATION
// ----------------------------
// The C ABI's asynchronous family has no timeout parameter and no
// cancellation handle. Async does not fabricate either. A caller that
// needs a hard timeout composes one at a higher layer (for example,
// by also starting a timer and ignoring a late callback).
//
// JSON CONVENIENCE OVERLOADS
// --------------------------
// For each addressing scheme, the DataHandle overload is
// complemented by a convenience overload that takes an API name and a
// POCO. The convenience overload builds the request handle
// internally, serializes the payload with LfIo.WriteJson, dispatches
// the call, and disposes the request handle as soon as the native
// layer has copied the payload (which LF_Async_* does synchronously).
//
// ============================================================================

using System;
using System.Runtime.InteropServices;

using LingoFuse.Native;

namespace LingoFuse;

/// <summary>
/// Callback-style asynchronous invocation.
/// </summary>
/// <remarks>
/// <para>
/// Every method in this class returns <c>void</c>. The completion of
/// the operation is signalled through the
/// <see cref="AsyncResult"/> passed to the user-supplied callback.
/// </para>
/// <para>
/// <b>Callback thread.</b> The callback runs on a native worker
/// thread, except in the dispatch-failure case where it runs
/// synchronously on the caller's thread. Callbacks must be
/// lightweight: no blocking, no UI access, no calls to
/// <c>LF_Call</c> / <c>LF_LocalCall</c> / <c>LF_PrepareDone</c> /
/// <c>LF_Shutdown</c>.
/// </para>
/// <para>
/// <b>Result lifetime.</b> The result handle carried by
/// <see cref="AsyncResult"/> is owned by the framework and released
/// the instant the callback returns. Any data the caller wants to
/// keep must be copied out inside the callback body.
/// </para>
/// </remarks>
public static class Async
{
    // ====================================================================
    // Trampoline and holder
    // ====================================================================

    /// <summary>
    /// The single trampoline used by every asynchronous primitive.
    /// Held in a static readonly field so that the GC cannot collect
    /// the delegate while the framework still holds a function pointer
    /// to it.
    /// </summary>
    private static readonly LfAsyncCallOnResult s_trampoline = OnResult;

    /// <summary>
    /// Invoked by the C ABI on a worker thread when an asynchronous
    /// request completes.
    /// </summary>
    /// <param name="data">
    /// The opaque pointer supplied at the call site; a GCHandle whose
    /// target is a <see cref="Holder"/>.
    /// </param>
    /// <param name="result">
    /// A framework-owned data handle. Valid only inside this method;
    /// the framework releases it the instant this method returns.
    /// </param>
    private static void OnResult(IntPtr data, IntPtr result)
    {
        // 1) Recover the holder and release the pin.
        GCHandle pin;
        Holder? holder;
        try
        {
            pin = GCHandle.FromIntPtr(data);
            holder = pin.Target as Holder;
        }
        catch
        {
            // A corrupted or already-freed GCHandle. There is nothing
            // we can do beyond dropping the callback.
            return;
        }

        if (holder is null)
        {
            try { pin.Free(); } catch { /* nothing we can do */ }
            return;
        }

        try { pin.Free(); } catch { /* nothing we can do */ }

        // 2) Build an AsyncResult and hand it to the user callback.
        //
        //    When the framework supplies a non-null result handle, it
        //    is wrapped as a BORROWED DataHandle: Dispose is a no-op,
        //    and the framework releases the underlying buffer when
        //    this method returns. The user callback MUST read whatever
        //    it needs before returning.
        //
        //    When the framework supplies a null handle (a rare "empty
        //    result" path), a fresh, owned, zero-size DataHandle is
        //    installed as a stand-in. It is released by this method's
        //    finally block.
        DataHandle? ownedFallback = null;
        try
        {
            DataHandle borrowed;
            if (result == IntPtr.Zero)
            {
                ownedFallback = new DataHandle("__async_result__");
                borrowed = ownedFallback;
            }
            else
            {
                borrowed = DataHandle.FromRaw(result, owned: false);
            }

            holder.Callback(AsyncResult.FromHandle(borrowed));
        }
        catch (Exception ex)
        {
            // A user callback raised an exception. It must not cross
            // the C stack, so we swallow it and report through the
            // standard callback error channel.
            Framework.ReportCallbackError("Async.OnResult", ex);
        }
        finally
        {
            // Release the owned fallback (if any). For the borrowed
            // path this is a no-op because Dispose on a borrowed
            // DataHandle does nothing.
            ownedFallback?.Dispose();
        }
        // On return, the framework releases the original result handle
        // (if any). Any reference the user callback retained into that
        // buffer is now dangling — same contract as C++ and Pascal.
    }

    /// <summary>
    /// Per-call holder that carries the user callback across the
    /// native boundary. Pinned by a GCHandle whose lifetime is
    /// described in <see cref="OnResult"/>.
    /// </summary>
    private sealed class Holder
    {
        public Action<AsyncResult> Callback = null!;
    }

    // ====================================================================
    // App name addressing — DataHandle form
    // ====================================================================

    /// <summary>
    /// Asynchronously invokes an API on <paramref name="appName"/>.
    /// </summary>
    /// <param name="appName">
    /// Target application name. Must not be null.
    /// </param>
    /// <param name="request">
    /// Request data handle. Must not be null and must not have been
    /// disposed. The native layer copies the payload synchronously
    /// inside the call, so the caller may dispose the handle as soon
    /// as this method returns.
    /// </param>
    /// <param name="onResult">
    /// Completion callback. Must not be null. Runs on a native worker
    /// thread, or synchronously on the caller's thread in the
    /// dispatch-failure case.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    /// <exception cref="ObjectDisposedException">
    /// Thrown when <paramref name="request"/> has already been
    /// disposed.
    /// </exception>
    public static void Call(
        string appName,
        DataHandle request,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onResult);
        EnsureRequestUsable(request);

        var holder = new Holder { Callback = onResult };
        GCHandle pin = GCHandle.Alloc(holder);
        IntPtr dataPtr = GCHandle.ToIntPtr(pin);
        IntPtr namePtr = Utf8Marshal.Alloc(appName);

        try
        {
            int ret = NativeMethods.LF_Async_Call(
                namePtr,
                new DataHnd { Handle = request.Raw },
                dataPtr,
                s_trampoline);

            if (ret != 1)
            {
                pin.Free();
                onResult(AsyncResult.FromError(
                    "Async.Call: request rejected before dispatch " +
                    $"(target app = \"{appName}\")."));
            }
        }
        catch
        {
            pin.Free();
            throw;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Asynchronously invokes an API with FIFO ordering guaranteed per
    /// (app, api) pair.
    /// </summary>
    /// <remarks>
    /// Same ownership, dispatch-failure, and thread contract as
    /// <see cref="Call"/>.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    /// <exception cref="ObjectDisposedException">
    /// Thrown when <paramref name="request"/> has already been
    /// disposed.
    /// </exception>
    public static void CallSequenced(
        string appName,
        DataHandle request,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onResult);
        EnsureRequestUsable(request);

        var holder = new Holder { Callback = onResult };
        GCHandle pin = GCHandle.Alloc(holder);
        IntPtr dataPtr = GCHandle.ToIntPtr(pin);
        IntPtr namePtr = Utf8Marshal.Alloc(appName);

        try
        {
            int ret = NativeMethods.LF_Async_Sequenced_Call(
                namePtr,
                new DataHnd { Handle = request.Raw },
                dataPtr,
                s_trampoline);

            if (ret != 1)
            {
                pin.Free();
                onResult(AsyncResult.FromError(
                    "Async.CallSequenced: request rejected before " +
                    $"dispatch (target app = \"{appName}\")."));
            }
        }
        catch
        {
            pin.Free();
            throw;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    // ====================================================================
    // App name addressing — JSON convenience form
    // ====================================================================

    /// <summary>
    /// Asynchronously invokes <paramref name="apiName"/> on
    /// <paramref name="appName"/>, serializing
    /// <paramref name="payload"/> as JSON.
    /// </summary>
    /// <typeparam name="T">
    /// Any JSON-serializable payload type. Anonymous types are
    /// supported by System.Text.Json.
    /// </typeparam>
    /// <remarks>
    /// This overload builds the request handle internally, serializes
    /// the payload, dispatches the call, and disposes the request as
    /// soon as the native layer has copied it. No handle is exposed to
    /// the caller.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any reference argument is null.
    /// </exception>
    public static void Call<T>(
        string appName,
        string apiName,
        T payload,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(onResult);

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);
        Call(appName, request, onResult);
    }

    /// <summary>
    /// Sequenced counterpart of
    /// <see cref="Call{T}(string, string, T, Action{AsyncResult})"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any reference argument is null.
    /// </exception>
    public static void CallSequenced<T>(
        string appName,
        string apiName,
        T payload,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(onResult);

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);
        CallSequenced(appName, request, onResult);
    }

    // ====================================================================
    // UID addressing — DataHandle form
    // ====================================================================

    /// <summary>
    /// Asynchronously invokes an API on the client with the given
    /// session UID.
    /// </summary>
    /// <remarks>
    /// UID routing is local-first, matching App-name routing. UIDs are
    /// regenerated on reconnect; a caller that caches a UID across a
    /// link loss must re-probe it.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any reference argument is null.
    /// </exception>
    /// <exception cref="ObjectDisposedException">
    /// Thrown when <paramref name="request"/> has already been
    /// disposed.
    /// </exception>
    public static void CallByUid(
        P2PUid uid,
        DataHandle request,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onResult);
        EnsureRequestUsable(request);

        var holder = new Holder { Callback = onResult };
        GCHandle pin = GCHandle.Alloc(holder);
        IntPtr dataPtr = GCHandle.ToIntPtr(pin);
        TUIDNative nativeUid = uid.ToNative();

        try
        {
            int ret = NativeMethods.LF_UID_Async_Call(
                nativeUid,
                new DataHnd { Handle = request.Raw },
                dataPtr,
                s_trampoline);

            if (ret != 1)
            {
                pin.Free();
                onResult(AsyncResult.FromError(
                    "Async.CallByUid: request rejected before dispatch " +
                    $"(target uid = \"{uid.ToHexString()}\")."));
            }
        }
        catch
        {
            pin.Free();
            throw;
        }
    }

    /// <summary>
    /// Sequenced counterpart of <see cref="CallByUid"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any reference argument is null.
    /// </exception>
    /// <exception cref="ObjectDisposedException">
    /// Thrown when <paramref name="request"/> has already been
    /// disposed.
    /// </exception>
    public static void CallByUidSequenced(
        P2PUid uid,
        DataHandle request,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onResult);
        EnsureRequestUsable(request);

        var holder = new Holder { Callback = onResult };
        GCHandle pin = GCHandle.Alloc(holder);
        IntPtr dataPtr = GCHandle.ToIntPtr(pin);
        TUIDNative nativeUid = uid.ToNative();

        try
        {
            int ret = NativeMethods.LF_UID_Async_Sequenced_Call(
                nativeUid,
                new DataHnd { Handle = request.Raw },
                dataPtr,
                s_trampoline);

            if (ret != 1)
            {
                pin.Free();
                onResult(AsyncResult.FromError(
                    "Async.CallByUidSequenced: request rejected before " +
                    $"dispatch (target uid = \"{uid.ToHexString()}\")."));
            }
        }
        catch
        {
            pin.Free();
            throw;
        }
    }

    // ====================================================================
    // UID addressing — JSON convenience form
    // ====================================================================

    /// <summary>
    /// Asynchronously invokes <paramref name="apiName"/> on the client
    /// with the given session UID, serializing
    /// <paramref name="payload"/> as JSON.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or
    /// <paramref name="onResult"/> is null.
    /// </exception>
    public static void CallByUid<T>(
        P2PUid uid,
        string apiName,
        T payload,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(onResult);

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);
        CallByUid(uid, request, onResult);
    }

    // ====================================================================
    // P2PName addressing — DataHandle form
    // ====================================================================

    /// <summary>
    /// Asynchronously invokes an API on a member of the P2P group.
    /// </summary>
    /// <remarks>
    /// P2PName routing is NOT local-first: the call is always
    /// forwarded to the server for dispatch, even when the caller
    /// process itself hosts a member of the target group.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    /// <exception cref="ObjectDisposedException">
    /// Thrown when <paramref name="request"/> has already been
    /// disposed.
    /// </exception>
    public static void CallByP2PName(
        string p2pName,
        DataHandle request,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onResult);
        EnsureRequestUsable(request);

        var holder = new Holder { Callback = onResult };
        GCHandle pin = GCHandle.Alloc(holder);
        IntPtr dataPtr = GCHandle.ToIntPtr(pin);
        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);

        try
        {
            int ret = NativeMethods.LF_P2PNAME_Async_Call(
                namePtr,
                new DataHnd { Handle = request.Raw },
                dataPtr,
                s_trampoline);

            if (ret != 1)
            {
                pin.Free();
                onResult(AsyncResult.FromError(
                    "Async.CallByP2PName: request rejected before " +
                    $"dispatch (target p2p = \"{p2pName}\")."));
            }
        }
        catch
        {
            pin.Free();
            throw;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Sequenced counterpart of <see cref="CallByP2PName"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    /// <exception cref="ObjectDisposedException">
    /// Thrown when <paramref name="request"/> has already been
    /// disposed.
    /// </exception>
    public static void CallByP2PNameSequenced(
        string p2pName,
        DataHandle request,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onResult);
        EnsureRequestUsable(request);

        var holder = new Holder { Callback = onResult };
        GCHandle pin = GCHandle.Alloc(holder);
        IntPtr dataPtr = GCHandle.ToIntPtr(pin);
        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);

        try
        {
            int ret = NativeMethods.LF_P2PNAME_Async_Sequenced_Call(
                namePtr,
                new DataHnd { Handle = request.Raw },
                dataPtr,
                s_trampoline);

            if (ret != 1)
            {
                pin.Free();
                onResult(AsyncResult.FromError(
                    "Async.CallByP2PNameSequenced: request rejected " +
                    $"before dispatch (target p2p = \"{p2pName}\")."));
            }
        }
        catch
        {
            pin.Free();
            throw;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    // ====================================================================
    // P2PName addressing — JSON convenience form
    // ====================================================================

    /// <summary>
    /// Asynchronously invokes <paramref name="apiName"/> on a member
    /// of the P2P group, serializing <paramref name="payload"/> as
    /// JSON.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="p2pName"/>, <paramref name="apiName"/>,
    /// or <paramref name="onResult"/> is null.
    /// </exception>
    public static void CallByP2PName<T>(
        string p2pName,
        string apiName,
        T payload,
        Action<AsyncResult> onResult)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(onResult);

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);
        CallByP2PName(p2pName, request, onResult);
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    private static void EnsureRequestUsable(DataHandle request)
    {
        if (!request.IsValid)
        {
            throw new ObjectDisposedException(
                nameof(request),
                "The request DataHandle has been disposed and cannot be " +
                "used as an asynchronous call parameter.");
        }
    }
}