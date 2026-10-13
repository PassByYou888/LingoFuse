// ============================================================================
// File: csharp/src/LingoFuse_cs/Framework.cs
// ============================================================================
// Framework — the direct ABI facade for the LingoFuse native library.
// ============================================================================
// This class is the public entry point for every process-wide operation
// that the native library exposes but that does not fit the DataHandle
// or AppHandle abstractions:
//
//   - Network preparation (reset / prepare service / prepare client /
//     prepare done / exit main thread).
//   - Remote invocation (call / try call / notify / sequenced notify),
//     across all three addressing schemes (App name / UID / P2PName).
//   - Asynchronous variants of the invocation primitives, exposed as
//     Task<DataHandle> with a synchronous dispatch-failure path.
//   - Process-wide P2P API registration.
//   - Cache-based health probes for every addressing scheme.
//   - Runtime options (raw string interface; see RuntimeOptions for
//     the strongly typed layer).
//   - Application name generation and query.
//   - Process-wide shutdown.
//
// This file exists because NativeMethods is internal: the public layer
// must present each native export through a managed signature that
// handles UTF-8 marshalling, argument validation, and the ownership
// transfer of any DataHnd returned by the native side.
//
// The class is a thin facade. It performs no caching, no state
// management, and no lifecycle coordination beyond the P2P bridge
// registry described below. Every method forwards to exactly one
// native function. Callers who need to know the precise native
// semantics should read the corresponding XML documentation on the
// NativeMethods declaration.
//
// CALLBACK ERROR REPORTING
// ------------------------
// Callback bodies registered through AppHandle, Framework (the P2P
// family), and NetworkEvents run on native worker threads, or on
// whatever thread a dispatcher selects. An exception escaping such a
// body would cross into the C stack and could destabilise the process,
// so every callback is wrapped to swallow exceptions.
//
// The wrapper reports every swallowed exception through two channels:
//
//   1. CallbackErrorHandler, if the application installed one. This is
//      the intended integration point for a real logging pipeline
//      (Serilog, NLog, Microsoft.Extensions.Logging, ...).
//
//   2. Trace.WriteLine, unconditionally. This is a debugger-visible
//      sink that is active in Release builds, unlike Debug.WriteLine.
//
// The handler is optional. A failure inside the handler itself is
// swallowed, so a broken logger cannot crash the process.
//
// P2P REGISTRATION LIFETIME
// -------------------------
// The process-wide P2P registration family has no AppHandle to anchor
// its bridge delegates, so the bridges are held in a private static
// dictionary instead. That dictionary:
//
//   * keeps each registered bridge alive for as long as its API name
//     remains registered;
//   * is released entry-by-entry by UnregisterP2P;
//   * is cleared wholesale by Shutdown, in lockstep with the native
//     LF_Shutdown that destroys the underlying LF_P2P_APP.
//
// Because Shutdown is process-wide, so is the P2P registry. A process
// can only host one P2P API namespace at a time; this matches the
// native library's own contract.
//
// ============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;

using LingoFuse.Native;

namespace LingoFuse;

/// <summary>
/// Public facade over the process-wide LingoFuse native functions.
/// </summary>
public static class Framework
{
    // ====================================================================
    // Callback error reporting
    // ====================================================================

    /// <summary>
    /// Optional handler invoked when a user callback raises an
    /// unhandled exception. The first argument is a short identifier
    /// for the callback site (for example
    /// "AppHandle.RegisterCall[add]" or "Framework.RegisterP2PCall[whoami]");
    /// the second is the exception.
    /// </summary>
    /// <remarks>
    /// Setting this property is optional. When it is null, swallowed
    /// exceptions are still reported through
    /// <see cref="System.Diagnostics.Trace"/>, but no application-level
    /// sink receives them.
    ///
    /// An exception raised by the handler itself is swallowed by the
    /// framework, so a broken logging pipeline cannot destabilise a
    /// native worker thread.
    /// </remarks>
    public static Action<string, Exception>? CallbackErrorHandler { get; set; }

    /// <summary>
    /// Internal bridge used by AppHandle, the P2P registration family,
    /// and NetworkEvents to report a swallowed callback exception.
    /// </summary>
    internal static void ReportCallbackError(string source, Exception ex)
    {
        try
        {
            CallbackErrorHandler?.Invoke(source, ex);
        }
        catch
        {
            // A handler that throws must not be allowed to escape into
            // the native worker thread. Drop the secondary failure.
        }

        // Trace is active in Release builds, unlike Debug. This gives
        // every swallowed exception a default visible sink without
        // requiring the application to install a handler.
        Trace.WriteLine($"[LingoFuse] Callback error in {source}: {ex}");
    }

    // ====================================================================
    // Network preparation
    // ====================================================================

    /// <summary>
    /// Clears any previously prepared services and clients. Running
    /// services and clients are not affected.
    /// </summary>
    public static void ResetPrepare()
        => NativeMethods.LF_ResetPrepare();

    /// <summary>
    /// Prepares a C4 service listening on <paramref name="listeningAddr"/>
    /// and advertised as <paramref name="physicsAddr"/>.
    /// </summary>
    /// <param name="listeningAddr">
    /// Local binding address, for example <c>0.0.0.0:9898</c> or
    /// <c>ipc:my_service</c>. Must not be null.
    /// </param>
    /// <param name="physicsAddr">
    /// Address advertised to clients. Must not be null.
    /// </param>
    /// <returns>
    /// An internal tag on success, or -1 for a duplicate address.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when either argument is null.
    /// </exception>
    public static int PrepareService(string listeningAddr, string physicsAddr)
    {
        ArgumentNullException.ThrowIfNull(listeningAddr);
        ArgumentNullException.ThrowIfNull(physicsAddr);

        IntPtr listenPtr = Utf8Marshal.Alloc(listeningAddr);
        IntPtr physicsPtr = Utf8Marshal.Alloc(physicsAddr);
        try
        {
            return NativeMethods.LF_PrepareService(listenPtr, physicsPtr);
        }
        finally
        {
            Utf8Marshal.Free(listenPtr);
            Utf8Marshal.Free(physicsPtr);
        }
    }

    /// <summary>
    /// Prepares a C4 client connecting to <paramref name="physicsAddr"/>
    /// and, optionally, exposing <paramref name="app"/> on the mesh.
    /// </summary>
    /// <param name="physicsAddr">
    /// Address of the target service. Must not be null.
    /// </param>
    /// <param name="app">
    /// Application to expose, or null for a pure consumer.
    /// </param>
    /// <returns>
    /// An internal tag on success, or -1 for a duplicate address
    /// (unless <c>Overlap_Connection</c> is enabled via
    /// <see cref="RuntimeOptions.OverlapConnection"/>).
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="physicsAddr"/> is null.
    /// </exception>
    public static int PrepareClient(string physicsAddr, AppHandle? app = null)
    {
        ArgumentNullException.ThrowIfNull(physicsAddr);

        IntPtr addrPtr = Utf8Marshal.Alloc(physicsAddr);
        try
        {
            AppHnd appHnd = app is null
                ? AppHnd.Null
                : new AppHnd { Handle = app.Raw };
            return NativeMethods.LF_PrepareClient(addrPtr, appHnd);
        }
        finally
        {
            Utf8Marshal.Free(addrPtr);
        }
    }

    /// <summary>
    /// Starts the LingoFuse framework with all prepared services and
    /// clients.
    /// </summary>
    /// <returns>
    /// 1 on success. Returns 0 on a second call in the same process
    /// without an intervening <c>LF_Shutdown</c>, which is not a
    /// failure.
    /// </returns>
    public static int PrepareDone()
        => NativeMethods.LF_PrepareDone();

    /// <summary>
    /// Requests the simulated main thread to exit. Does not release all
    /// resources; call <see cref="Shutdown"/> afterwards for a full
    /// cleanup.
    /// </summary>
    /// <remarks>
    /// [PITFALL] <c>LF_ExitMainThread</c> also flushes the data handle
    /// pool, releasing every outstanding handle — including those
    /// created with <see cref="DataHandle.CreatePermanent"/>. Do not
    /// use any data handle after this call has returned.
    /// </remarks>
    public static void ExitMainThread()
        => NativeMethods.LF_ExitMainThread();

    // ====================================================================
    // Runtime options
    // ====================================================================

    /// <summary>
    /// Adjusts a global runtime option. Unknown option names are
    /// silently ignored by the native layer.
    /// </summary>
    /// <param name="option">
    /// Option name, for example <c>Overlap_Connection</c>. Must not be
    /// null.
    /// </param>
    /// <param name="value">
    /// New value, for example <c>True</c>. Must not be null.
    /// </param>
    /// <remarks>
    /// For every option the native layer recognises, a strongly typed
    /// property exists on <see cref="RuntimeOptions"/>. Prefer those
    /// properties in new code: they enforce the canonical option name
    /// and value format at compile time. This method remains available
    /// for forward compatibility with options introduced after this
    /// binding was compiled.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when either argument is null.
    /// </exception>
    public static void SetOption(string option, string value)
    {
        ArgumentNullException.ThrowIfNull(option);
        ArgumentNullException.ThrowIfNull(value);

        IntPtr optPtr = Utf8Marshal.Alloc(option);
        IntPtr valPtr = Utf8Marshal.Alloc(value);
        try
        {
            NativeMethods.LF_SetOption(optPtr, valPtr);
        }
        finally
        {
            Utf8Marshal.Free(optPtr);
            Utf8Marshal.Free(valPtr);
        }
    }

    // ====================================================================
    // Application name generation and query
    // ====================================================================

    /// <summary>
    /// Generates a globally unique application name.
    /// </summary>
    /// <remarks>
    /// Must be called after <see cref="PrepareDone"/> returns 1. The
    /// native function returns a pointer that is valid for
    /// approximately 5 seconds; this method copies the string to
    /// managed memory immediately.
    ///
    /// Returns an empty string when the underlying native function
    /// returns a null pointer.
    /// </remarks>
    public static string GenerateAppName()
    {
        IntPtr ptr = NativeMethods.LF_Generate_AppName();
        return Utf8Marshal.PtrToString(ptr);
    }

    /// <summary>
    /// Returns the name of an existing application handle.
    /// </summary>
    /// <remarks>
    /// The native function <c>LF_Get_AppName</c> returns a pointer into
    /// a temporary buffer that is valid for approximately 5 seconds.
    /// This method copies the string to managed memory immediately, so
    /// the returned string is safe to hold indefinitely.
    ///
    /// Returns an empty string when the native function returns a null
    /// pointer (for example, a null handle).
    ///
    /// The managed <see cref="AppHandle.Name"/> property returns the
    /// name that was passed to the constructor. This method, by
    /// contrast, queries the native side and therefore reflects the
    /// authoritative name stored in the C4 mesh registry. The two are
    /// usually identical, but they can differ if the AppHandle was
    /// constructed with a name that the native layer normalised, or
    /// if the caller is inspecting an AppHandle obtained from another
    /// source.
    /// </remarks>
    /// <param name="app">
    /// Application handle. Must not be null.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="app"/> is null.
    /// </exception>
    public static string GetAppName(AppHandle app)
    {
        ArgumentNullException.ThrowIfNull(app);

        var hnd = new AppHnd { Handle = app.Raw };
        IntPtr ptr = NativeMethods.LF_Get_AppName(hnd);
        return Utf8Marshal.PtrToString(ptr);
    }

    // ====================================================================
    // Remote invocation — App name addressing (synchronous)
    // ====================================================================

    /// <summary>
    /// Performs a synchronous remote call and returns the response.
    /// </summary>
    /// <param name="appName">
    /// Target application name. Must not be null.
    /// </param>
    /// <param name="param">
    /// Request data handle. Must not be null.
    /// </param>
    /// <param name="timeoutMs">
    /// Timeout in milliseconds. Zero means "wait indefinitely".
    /// Defaults to 5000 ms.
    /// </param>
    /// <returns>
    /// A new DataHandle owning the response. On timeout or failure, the
    /// native side returns an empty handle (Size == 0). The result is
    /// never null; the caller must dispose it.
    ///
    /// Callers who need to distinguish "timeout / unreachable target"
    /// from "empty response" should inspect <c>Size</c> directly, or
    /// use <see cref="TryCall"/> for a null-on-failure contract.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static DataHandle Call(
        string appName,
        DataHandle param,
        ulong timeoutMs = 5000)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr appPtr = Utf8Marshal.Alloc(appName);
        try
        {
            DataHnd result = NativeMethods.LF_Call(
                appPtr,
                new DataHnd { Handle = param.Raw },
                timeoutMs);
            return DataHandle.FromRaw(result.Handle, owned: true);
        }
        finally
        {
            Utf8Marshal.Free(appPtr);
        }
    }

    /// <summary>
    /// Performs a synchronous remote call and returns the response only
    /// when the native layer produced a non-empty payload.
    /// </summary>
    /// <remarks>
    /// This is the C# equivalent of the C++ <c>tryCall</c> helper. It
    /// returns <c>null</c> on timeout or unreachable target, instead
    /// of a size-0 <see cref="DataHandle"/>. Callers who need to
    /// distinguish "timeout" from "empty response" must use
    /// <see cref="Call"/> and inspect <c>Size</c> themselves.
    ///
    /// Ownership: when the method returns a non-null handle, the
    /// caller is responsible for disposing it. When the method returns
    /// null, the underlying empty handle has already been disposed by
    /// this method; the caller must not free anything.
    ///
    /// The idiom:
    /// <code>
    /// using var response = Framework.TryCall("App", param, 3000);
    /// if (response is null) { /* timeout or unreachable */ }
    /// else { /* response.Size > 0 */ }
    /// </code>
    /// </remarks>
    /// <param name="appName">
    /// Target application name. Must not be null.
    /// </param>
    /// <param name="param">
    /// Request data handle. Must not be null.
    /// </param>
    /// <param name="timeoutMs">
    /// Timeout in milliseconds. Zero means "wait indefinitely".
    /// Defaults to 5000 ms.
    /// </param>
    /// <returns>
    /// A new DataHandle when the response is non-empty; <c>null</c>
    /// when the native layer returned an empty (size-0) handle, which
    /// indicates a timeout or an unreachable target.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static DataHandle? TryCall(
        string appName,
        DataHandle param,
        ulong timeoutMs = 5000)
    {
        var response = Call(appName, param, timeoutMs);
        if (response.Size == 0)
        {
            response.Dispose();
            return null;
        }
        return response;
    }

    /// <summary>
    /// Sends a one-way Notify. Delivery order is not guaranteed; use
    /// <see cref="SequencedNotify"/> when FIFO ordering is required.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static void Notify(string appName, DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr appPtr = Utf8Marshal.Alloc(appName);
        try
        {
            NativeMethods.LF_Notify(appPtr, new DataHnd { Handle = param.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appPtr);
        }
    }

    /// <summary>
    /// Sends a one-way notification with FIFO ordering guaranteed for
    /// the same (application, API) pair.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static void SequencedNotify(string appName, DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr appPtr = Utf8Marshal.Alloc(appName);
        try
        {
            NativeMethods.LF_Sequenced_Notify(
                appPtr,
                new DataHnd { Handle = param.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appPtr);
        }
    }

    // ====================================================================
    // Remote invocation — App name addressing (asynchronous)
    // ====================================================================

    /// <summary>
    /// Starts an asynchronous remote call addressed by App name.
    /// </summary>
    /// <param name="appName">
    /// Target application name. Must not be null.
    /// </param>
    /// <param name="param">
    /// Request data handle. Must not be null and must not have been
    /// disposed. The native layer copies the payload synchronously
    /// inside the call, so the caller may dispose the handle as soon
    /// as this method returns.
    /// </param>
    /// <returns>
    /// A <see cref="Task{TResult}"/> that completes with a fresh,
    /// caller-owned <see cref="DataHandle"/> when the remote side
    /// responds, or faults with a
    /// <see cref="LingoFuseCallException"/> when the request could not
    /// be dispatched.
    /// </returns>
    /// <remarks>
    /// <para>
    /// <b>Await semantics.</b> The await continuation is posted back
    /// to the caller's SynchronizationContext by the normal C# await
    /// machinery. A UI thread that awaits this Task automatically
    /// resumes on the UI thread; no dispatcher needs to be involved.
    /// </para>
    /// <para>
    /// <b>Dispatch failure.</b> When the native layer rejects the
    /// request before dispatching it, the returned Task faults
    /// immediately with a <see cref="LingoFuseCallException"/>. There
    /// is no separate return code to inspect.
    /// </para>
    /// <para>
    /// <b>No timeout, no cancellation.</b> The C ABI family has
    /// neither a timeout parameter nor a cancellation handle. To
    /// impose a hard timeout, compose one at the call site:
    /// <code>
    /// var result = await Task.WhenAny(
    ///     Framework.CallAsync("App", param),
    ///     Task.Delay(TimeSpan.FromSeconds(5)));
    /// </code>
    /// If the delay wins, the underlying operation remains pending
    /// until the framework eventually delivers its callback. The
    /// holder is released at that point.
    /// </para>
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    /// <exception cref="ObjectDisposedException">
    /// Thrown when <paramref name="param"/> has already been disposed.
    /// </exception>
    public static Task<DataHandle> CallAsync(
        string appName,
        DataHandle param)
        => AsyncCallbackBridge.CallAsync(appName, param);

    /// <summary>
    /// Starts an asynchronous sequenced remote call addressed by App
    /// name, with FIFO ordering per (app, api) pair.
    /// </summary>
    /// <remarks>
    /// Same ownership, dispatch-failure, and timeout contract as
    /// <see cref="CallAsync"/>.
    /// </remarks>
    public static Task<DataHandle> CallSequencedAsync(
        string appName,
        DataHandle param)
        => AsyncCallbackBridge.CallSequencedAsync(appName, param);

    // ====================================================================
    // Remote invocation — UID addressing
    // ====================================================================

    /// <summary>
    /// Performs a synchronous remote call addressed by session UID.
    /// </summary>
    /// <param name="uid">
    /// The target's session UID. A <see cref="P2PUid.Empty"/> value is
    /// routed to no one and produces a size-0 result.
    /// </param>
    /// <param name="param">Request data handle. Must not be null.</param>
    /// <param name="timeoutMs">
    /// Timeout in milliseconds. Zero means "wait indefinitely".
    /// Defaults to 5000 ms.
    /// </param>
    /// <returns>
    /// A new DataHandle owning the response. Same timeout / failure
    /// contract as <see cref="Call"/>.
    /// </returns>
    /// <remarks>
    /// UID addressing routes to the exact client whose TunnelLink
    /// produced the given UID. A UID can address ANY API registered
    /// on the target — whether app-bound (<see cref="AppHandle.RegisterCall"/>)
    /// or process-wide (<see cref="RegisterP2PCall"/>) — without
    /// requiring the caller to know the target App name.
    ///
    /// UID routing is LOCAL-FIRST, matching App-name routing.
    ///
    /// The UID is regenerated on every reconnect. A caller that caches
    /// a UID MUST re-probe it after a link loss.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="param"/> is null.
    /// </exception>
    public static DataHandle CallByUid(
        P2PUid uid,
        DataHandle param,
        ulong timeoutMs = 5000)
    {
        ArgumentNullException.ThrowIfNull(param);

        DataHnd result = NativeMethods.LF_UID_Call(
            uid.ToNative(),
            new DataHnd { Handle = param.Raw },
            timeoutMs);
        return DataHandle.FromRaw(result.Handle, owned: true);
    }

    /// <summary>
    /// Sends a one-way notification addressed by session UID.
    /// </summary>
    /// <remarks>
    /// Same routing and lifetime rules as <see cref="CallByUid"/>.
    /// </remarks>
    public static void NotifyByUid(P2PUid uid, DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(param);

        NativeMethods.LF_UID_Notify(
            uid.ToNative(),
            new DataHnd { Handle = param.Raw });
    }

    /// <summary>
    /// Sends a one-way sequenced notification addressed by session UID.
    /// </summary>
    /// <remarks>
    /// Same routing and lifetime rules as <see cref="CallByUid"/>.
    /// FIFO ordering is guaranteed per (uid, api) pair.
    /// </remarks>
    public static void SequencedNotifyByUid(P2PUid uid, DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(param);

        NativeMethods.LF_UID_Sequenced_Notify(
            uid.ToNative(),
            new DataHnd { Handle = param.Raw });
    }

    /// <summary>
    /// Starts an asynchronous remote call addressed by session UID.
    /// </summary>
    /// <remarks>
    /// Same await, dispatch-failure, and timeout contract as
    /// <see cref="CallAsync"/>.
    /// </remarks>
    public static Task<DataHandle> CallByUidAsync(
        P2PUid uid,
        DataHandle param)
        => AsyncCallbackBridge.CallByUidAsync(uid, param);

    /// <summary>
    /// Starts an asynchronous sequenced remote call addressed by
    /// session UID.
    /// </summary>
    /// <remarks>
    /// Same contract as <see cref="CallByUidAsync"/>, with FIFO
    /// ordering per (uid, api) pair.
    /// </remarks>
    public static Task<DataHandle> CallByUidSequencedAsync(
        P2PUid uid,
        DataHandle param)
        => AsyncCallbackBridge.CallByUidSequencedAsync(uid, param);

    // ====================================================================
    // Remote invocation — P2PName addressing
    // ====================================================================

    /// <summary>
    /// Performs a synchronous remote call addressed by P2P group name.
    /// </summary>
    /// <param name="p2pName">
    /// Target P2P group name. Must not be null. An empty string routes
    /// to no group and produces a size-0 result.
    /// </param>
    /// <param name="param">Request data handle. Must not be null.</param>
    /// <param name="timeoutMs">
    /// Timeout in milliseconds. Zero means "wait indefinitely".
    /// Defaults to 5000 ms.
    /// </param>
    /// <returns>
    /// A new DataHandle owning the response. Same timeout / failure
    /// contract as <see cref="Call"/>.
    /// </returns>
    /// <remarks>
    /// P2PName routing is NOT local-first. Even when the caller
    /// process itself hosts a client in the target group, the call is
    /// forwarded to the server for dispatch. The server-side
    /// dispatcher picks a target using one of two strategies:
    ///
    ///   - Load balancing (Cycle_Anchor): the target with the smallest
    ///     anchor value is chosen, and its anchor is then advanced.
    ///
    ///   - Sticky affinity (FixedSequenced, governed by
    ///     <see cref="RuntimeOptions.FixedSequencedTimeMs"/>).
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="p2pName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static DataHandle CallByP2PName(
        string p2pName,
        DataHandle param,
        ulong timeoutMs = 5000)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);
        try
        {
            DataHnd result = NativeMethods.LF_P2PNAME_Call(
                namePtr,
                new DataHnd { Handle = param.Raw },
                timeoutMs);
            return DataHandle.FromRaw(result.Handle, owned: true);
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Sends a one-way notification addressed by P2P group name.
    /// </summary>
    /// <remarks>
    /// Same routing rules as <see cref="CallByP2PName"/>. Delivery
    /// order is not guaranteed.
    /// </remarks>
    public static void NotifyByP2PName(string p2pName, DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);
        try
        {
            NativeMethods.LF_P2PNAME_Notify(
                namePtr,
                new DataHnd { Handle = param.Raw });
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Sends a one-way sequenced notification addressed by P2P group
    /// name.
    /// </summary>
    /// <remarks>
    /// Same routing rules as <see cref="CallByP2PName"/>. FIFO
    /// ordering is guaranteed per (p2p, api) pair.
    /// </remarks>
    public static void SequencedNotifyByP2PName(
        string p2pName,
        DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);
        try
        {
            NativeMethods.LF_P2PNAME_Sequenced_Notify(
                namePtr,
                new DataHnd { Handle = param.Raw });
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Starts an asynchronous remote call addressed by P2P group name.
    /// </summary>
    /// <remarks>
    /// Same await, dispatch-failure, and timeout contract as
    /// <see cref="CallAsync"/>.
    /// </remarks>
    public static Task<DataHandle> CallByP2PNameAsync(
        string p2pName,
        DataHandle param)
        => AsyncCallbackBridge.CallByP2PNameAsync(p2pName, param);

    /// <summary>
    /// Starts an asynchronous sequenced remote call addressed by
    /// P2P group name.
    /// </summary>
    /// <remarks>
    /// Same contract as <see cref="CallByP2PNameAsync"/>, with FIFO
    /// ordering per (p2p, api) pair.
    /// </remarks>
    public static Task<DataHandle> CallByP2PNameSequencedAsync(
        string p2pName,
        DataHandle param)
        => AsyncCallbackBridge.CallByP2PNameSequencedAsync(p2pName, param);

    // ====================================================================
    // Process-wide P2P API registration
    // ====================================================================
    //
    // P2P APIs live on the process-wide LF_P2P_APP. They are reachable
    // via UID and P2PName addressing ONLY; they are NOT reachable via
    // App-name addressing, even if the API name happens to match an
    // App name.
    //
    // Typical use: globally-discoverable utility APIs (health probes,
    // capability discovery, identity echo, etc.) that any client in
    // the mesh can call by UID or by P2PName without knowing the
    // target's App name.
    //
    // Bridge lifetime is managed by the private static dictionary
    // below. See the file header for the full rationale.

    /// <summary>
    /// Registered P2P bridges indexed by API name. Keeps the delegate
    /// alive for as long as its API name is registered. Guarded by
    /// <see cref="_p2pLock"/>.
    /// </summary>
    private static readonly Dictionary<string, Delegate> _p2pRegistrations =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Guards every mutation of <see cref="_p2pRegistrations"/>.
    /// </summary>
    private static readonly object _p2pLock = new();

    /// <summary>
    /// Registers a process-wide Call API whose handler runs inline on
    /// the native worker thread.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Receives borrowed DataHandle instances for
    /// input and output. Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <remarks>
    /// This overload uses <see cref="CallbackDispatcher.Inline"/>.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or
    /// <paramref name="handler"/> is null.
    /// </exception>
    public static bool RegisterP2PCall(
        string apiName,
        string description,
        Action<DataHandle, DataHandle> handler)
    {
        return RegisterP2PCall(
            apiName, description, handler, CallbackDispatcher.Inline);
    }

    /// <summary>
    /// Registers a process-wide Call API whose handler runs on the
    /// thread selected by <paramref name="dispatcher"/>.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Must not be null.
    /// </param>
    /// <param name="dispatcher">
    /// The dispatcher that decides which thread runs the handler.
    /// Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    public static bool RegisterP2PCall(
        string apiName,
        string description,
        Action<DataHandle, DataHandle> handler,
        ILingoCallbackDispatcher dispatcher)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        ArgumentNullException.ThrowIfNull(dispatcher);

        LfCallFunc bridge = (trigger, input, output) =>
        {
            var inHandle = DataHandle.FromRaw(input, owned: false);
            var outHandle = DataHandle.FromRaw(output, owned: false);
            try
            {
                dispatcher.Dispatch(() => handler(inHandle, outHandle));
            }
            catch (Exception ex)
            {
                ReportCallbackError(
                    $"Framework.RegisterP2PCall[{apiName}]", ex);
            }
        };

        lock (_p2pLock)
        {
            IntPtr namePtr = Utf8Marshal.Alloc(apiName);
            IntPtr descPtr = Utf8Marshal.Alloc(description ?? string.Empty);
            try
            {
                int result = NativeMethods.LF_Register_P2P_Call(
                    namePtr, descPtr, IntPtr.Zero, bridge);

                if (result == 1)
                {
                    _p2pRegistrations[apiName] = bridge;
                    return true;
                }
                return false;
            }
            finally
            {
                Utf8Marshal.Free(namePtr);
                Utf8Marshal.Free(descPtr);
            }
        }
    }

    /// <summary>
    /// Registers a process-wide Notify API whose handler runs inline
    /// on the native worker thread.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Receives a borrowed DataHandle for the input
    /// payload. Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <remarks>
    /// This overload uses <see cref="CallbackDispatcher.Inline"/>.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or
    /// <paramref name="handler"/> is null.
    /// </exception>
    public static bool RegisterP2PNotify(
        string apiName,
        string description,
        Action<DataHandle> handler)
    {
        return RegisterP2PNotify(
            apiName, description, handler, CallbackDispatcher.Inline);
    }

    /// <summary>
    /// Registers a process-wide Notify API whose handler runs on the
    /// thread selected by <paramref name="dispatcher"/>.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Must not be null.
    /// </param>
    /// <param name="dispatcher">
    /// The dispatcher that decides which thread runs the handler.
    /// Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    public static bool RegisterP2PNotify(
        string apiName,
        string description,
        Action<DataHandle> handler,
        ILingoCallbackDispatcher dispatcher)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        ArgumentNullException.ThrowIfNull(dispatcher);

        LfNotifyFunc bridge = (trigger, input) =>
        {
            var inHandle = DataHandle.FromRaw(input, owned: false);
            try
            {
                dispatcher.Dispatch(() => handler(inHandle));
            }
            catch (Exception ex)
            {
                ReportCallbackError(
                    $"Framework.RegisterP2PNotify[{apiName}]", ex);
            }
        };

        lock (_p2pLock)
        {
            IntPtr namePtr = Utf8Marshal.Alloc(apiName);
            IntPtr descPtr = Utf8Marshal.Alloc(description ?? string.Empty);
            try
            {
                int result = NativeMethods.LF_Register_P2P_Notify(
                    namePtr, descPtr, IntPtr.Zero, bridge);

                if (result == 1)
                {
                    _p2pRegistrations[apiName] = bridge;
                    return true;
                }
                return false;
            }
            finally
            {
                Utf8Marshal.Free(namePtr);
                Utf8Marshal.Free(descPtr);
            }
        }
    }

    /// <summary>
    /// Removes a process-wide P2P API by name. Does NOT affect
    /// app-bound APIs of the same name.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <returns>true if the API was found and removed, false otherwise.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    public static bool UnregisterP2P(string apiName)
    {
        ArgumentNullException.ThrowIfNull(apiName);

        lock (_p2pLock)
        {
            IntPtr namePtr = Utf8Marshal.Alloc(apiName);
            try
            {
                int result = NativeMethods.LF_Unregister_P2P(namePtr);
                if (result == 1)
                {
                    _p2pRegistrations.Remove(apiName);
                }
                return result == 1;
            }
            finally
            {
                Utf8Marshal.Free(namePtr);
            }
        }
    }

    // ====================================================================
    // Health probes — UID and P2PName
    // ====================================================================
    //
    // Every probe consults a LOCALLY CACHED view of the mesh, updated
    // by periodic broadcasts with a typical propagation delay of about
    // 3 seconds. A probe can return false negatives shortly after a
    // registration and false positives shortly after an
    // unregistration. Use them as probing tools, not as authoritative
    // existence tests. For critical decisions, call the target API
    // directly and handle timeouts gracefully.

    /// <summary>
    /// Probes whether a client with the given UID is currently
    /// registered.
    /// </summary>
    /// <remarks>
    /// Same cache caveat as
    /// <see cref="LingoFuseStatus.CheckApp"/>.
    /// </remarks>
    public static bool CheckUid(P2PUid uid)
        => NativeMethods.LF_Check_UID(uid.ToNative()) != 0;

    /// <summary>
    /// Probes whether a client with the given UID exposes the named
    /// API.
    /// </summary>
    /// <param name="uid">Target UID.</param>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    /// <remarks>
    /// Same cache caveat as
    /// <see cref="LingoFuseStatus.CheckApp"/>.
    /// </remarks>
    public static bool CheckUidApi(P2PUid uid, string apiName)
    {
        ArgumentNullException.ThrowIfNull(apiName);

        IntPtr apiPtr = Utf8Marshal.Alloc(apiName);
        try
        {
            return NativeMethods.LF_Check_UID_Api(
                uid.ToNative(), apiPtr) != 0;
        }
        finally
        {
            Utf8Marshal.Free(apiPtr);
        }
    }

    /// <summary>
    /// Probes whether a client with the given P2P group name is
    /// registered.
    /// </summary>
    /// <param name="p2pName">P2P group name. Must not be null.</param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="p2pName"/> is null.
    /// </exception>
    /// <remarks>
    /// Same cache caveat as
    /// <see cref="LingoFuseStatus.CheckApp"/>.
    /// </remarks>
    public static bool CheckP2PName(string p2pName)
    {
        ArgumentNullException.ThrowIfNull(p2pName);

        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);
        try
        {
            return NativeMethods.LF_Check_P2PNAME(namePtr) != 0;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Probes whether a client in the given P2P group exposes the
    /// named API.
    /// </summary>
    /// <param name="p2pName">P2P group name. Must not be null.</param>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when either argument is null.
    /// </exception>
    /// <remarks>
    /// Same cache caveat as
    /// <see cref="LingoFuseStatus.CheckApp"/>.
    /// </remarks>
    public static bool CheckP2PNameApi(string p2pName, string apiName)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(apiName);

        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);
        IntPtr apiPtr = Utf8Marshal.Alloc(apiName);
        try
        {
            return NativeMethods.LF_Check_P2PNAME_Api(
                namePtr, apiPtr) != 0;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
            Utf8Marshal.Free(apiPtr);
        }
    }

    // ====================================================================
    // Shutdown
    // ====================================================================

    /// <summary>
    /// Gracefully terminates the framework, releasing all resources.
    /// Safe to call multiple times.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Every AppHandle still alive in the process becomes invalid after
    /// this call. The AppHandle wrappers do not detect this
    /// automatically; callers must ensure that no AppHandle is used
    /// after <see cref="Shutdown"/> has returned.
    /// </para>
    /// <para>
    /// The native side also clears both network event callbacks and
    /// destroys the LF_P2P_APP (and therefore every API registered
    /// through <see cref="RegisterP2PCall"/> /
    /// <see cref="RegisterP2PNotify"/>) during teardown. The managed
    /// delegate references held by <see cref="NetworkEvents"/> and by
    /// the P2P registry are released here as well, so a subsequent
    /// re-initialisation starts from a clean slate.
    /// </para>
    /// <para>
    /// Call <see cref="NetworkEvents.Clear"/> explicitly before
    /// <c>Shutdown</c> if you want to release the network event
    /// delegates deterministically, rather than at shutdown time.
    /// </para>
    /// </remarks>
    public static void Shutdown()
    {
        // Release the managed P2P bridges before the native teardown.
        // The order matters: if a callback is somehow still in flight,
        // the bridge's try/catch will observe the failure and route it
        // through ReportCallbackError. Clearing the dictionary first
        // also guarantees that a re-initialisation does not inherit
        // stale delegate references.
        lock (_p2pLock)
        {
            _p2pRegistrations.Clear();
        }

        NativeMethods.LF_Shutdown();
    }
}