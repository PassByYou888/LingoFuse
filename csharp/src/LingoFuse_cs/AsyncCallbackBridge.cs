// ============================================================================
// File: csharp/src/LingoFuse_cs/Native/AsyncCallbackBridge.cs
// ============================================================================
// AsyncCallbackBridge — internal bridge from the C ABI's asynchronous
// completion callback to a managed Task<DataHandle>.
// ============================================================================
// THE C ABI'S ASYNC MODEL
// -----------------------
// The C ABI exposes six asynchronous call primitives:
//
//     LF_Async_Call                     LF_Async_Sequenced_Call
//     LF_UID_Async_Call                 LF_UID_Async_Sequenced_Call
//     LF_P2PNAME_Async_Call             LF_P2PNAME_Async_Sequenced_Call
//
// Each takes four arguments:
//
//     (target, param, void* data, LfAsyncCallOnResult onResult)
//
// and returns an int that is 1 when the request was queued and 0 when
// it was rejected before dispatch. When the return value is 1, the
// framework will later invoke onResult on one of its worker threads,
// passing back the same `data` pointer plus a `result` handle. When
// the return value is 0, the framework will NEVER invoke onResult.
//
// Two properties of the callback make a direct C# wrapper awkward:
//
//   1. The `result` handle is OWNED BY THE FRAMEWORK. It is released
//      the instant the callback returns. Any attempt to read from it
//      after the callback's last statement is use-after-free; calling
//      LF_FreeData on it is double-free.
//
//   2. The callback runs on a native worker thread.
//
// THE BRIDGE
// ----------
// This class wraps every asynchronous primitive in a Task<DataHandle>
// that:
//
//   * copies the entire result payload out of the framework-owned
//     handle INSIDE the callback body, into a fresh handle that the
//     caller owns,
//
//   * completes on the calling thread if the C ABI rejected the
//     request (return value 0), preserving the synchronous error path
//     without requiring the caller to inspect a return code,
//
//   * honors the caller's SynchronizationContext on the await
//     continuation automatically, via C#'s native await machinery,
//
//   * never exposes the framework-owned handle or its raw pointer to
//     user code.
//
// AWAIT CONTINUATION — WHY NO RunContinuationsAsynchronously
// ----------------------------------------------------------
// The TaskCompletionSource is deliberately created WITHOUT
// TaskCreationOptions.RunContinuationsAsynchronously. That choice is
// what makes the following two idioms work as every C# developer
// expects:
//
//   * In a UI application (WPF / WinForms / MAUI / Avalonia), an
//     `await Framework.CallAsync(...)` on the UI thread resumes on
//     the UI thread. The developer can touch UI controls directly
//     after the await without an extra Dispatcher.Invoke.
//
//   * In a console / background service without a captured
//     SynchronizationContext, the continuation runs inline on the
//     native worker thread that completed the Task. The developer
//     can force the opposite behavior with ConfigureAwait(false) if
//     they know they will not need the UI thread.
//
// This matches the behavior of every Task-returning API in the BCL
// (HttpClient.GetAsync, Stream.ReadAsync, DbCommand.ExecuteReaderAsync,
// ...), none of which set RunContinuationsAsynchronously.
//
// THE TRADE-OFF
// -------------
// Without RunContinuationsAsynchronously, a continuation that blocks
// will block the thread that completed the Task — in our case, a
// native worker thread. This is the standard .NET trade-off and is
// governed by the ecosystem-wide rule that continuations must return
// promptly. A blocking continuation is a developer error regardless
// of which async API is being used; it is not something the bridge
// can protect against without also breaking await semantics for
// every correctly-written caller.
//
// Developers who want to guarantee that no continuation ever runs on
// a native worker thread can wrap the call:
//
//     var result = await Framework
//         .CallAsync("App", param)
//         .ConfigureAwait(false);
//
// which is exactly the same escape hatch the BCL offers.
//
// HOLDER LIFETIME
// ---------------
// A single GCHandle pins an internal AsyncOp object for the duration
// of one C ABI call. Ownership of that GCHandle transfers as follows:
//
//   * allocated in the calling method, before LF_Async_* is invoked;
//
//   * on return value 1: the callback owns the handle and releases
//     it in the trampoline, after copying the payload but before
//     completing the Task;
//
//   * on return value 0: the calling method still owns the handle
//     and releases it after completing the Task with an error.
//
// These two paths are mutually exclusive by the C ABI's own contract,
// so the handle is released exactly once in every execution.
//
// DISPATCH FAILURE SEMANTICS
// --------------------------
// When the C ABI returns 0, the Task completes in the Faulted state
// with a LingoFuseCallException. The caller's code path is therefore
// uniform: `await` always succeeds with a valid DataHandle or throws.
// There is no separate return code to check, and no way for a caller
// to accidentally observe a Task that never completes because the
// dispatch silently failed.
//
// NO TIMEOUT / NO CANCELLATION
// ----------------------------
// The C ABI's async family has neither a timeout parameter nor a
// cancellation handle. This bridge does not invent one, because a
// fabricated timeout would either abandon the holder (leak) or
// require a cooperative cancellation protocol that the C ABI does not
// support. Callers that need a hard timeout compose one at a higher
// layer:
//
//     var completed = await Task.WhenAny(
//         Framework.CallAsync("App", param),
//         Task.Delay(TimeSpan.FromSeconds(5)));
//
// If the delay wins, the underlying holder remains allocated until
// the framework eventually delivers the callback. This is the same
// contract the C++ binding offers, and it is documented there as a
// theoretical rather than a practical concern.
//
// ============================================================================

using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace LingoFuse.Native;

/// <summary>
/// Bridges the C ABI's asynchronous completion callback into a
/// managed <see cref="Task{TResult}"/> of <see cref="DataHandle"/>.
/// </summary>
/// <remarks>
/// This type is an implementation detail of the binding. User code
/// interacts with the asynchronous primitives exclusively through
/// <see cref="Framework.CallAsync"/> and its siblings.
/// </remarks>
internal static class AsyncCallbackBridge
{
    // --------------------------------------------------------------------
    // Constants and static state
    // --------------------------------------------------------------------

    /// <summary>
    /// The API name attached to the fresh handle that carries a
    /// copied async result. It is reserved for internal use and is not
    /// a routable API name; the handle exists only as a byte buffer.
    /// </summary>
    private const string AsyncResultApiName = "__async_result__";

    /// <summary>
    /// Maximum number of bytes copied per LF_ReadBuffer call when
    /// materializing an async result. 1 MiB is large enough to move
    /// typical payloads in one pass and small enough to avoid
    /// oversized pinned arrays in the managed side.
    /// </summary>
    private const int CopyChunkSize = 1 << 20;

    /// <summary>
    /// The single trampoline used by every asynchronous primitive.
    /// One function pointer constant keeps the C ABI-facing surface
    /// trivially small and makes it obvious that every entry point
    /// shares the same lifetime rules.
    /// </summary>
    private static readonly LfAsyncCallOnResult s_trampoline = OnResult;

    // ====================================================================
    // Public entry points
    // ====================================================================
    //
    // These are the six async primitives, matching the C ABI 1:1.
    // Each returns a Task that either succeeds with a caller-owned
    // DataHandle or fails with a LingoFuseCallException.

    /// <summary>
    /// App-name addressing, asynchronous, unordered.
    /// </summary>
    public static Task<DataHandle> CallAsync(
        string appName,
        DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);
        return IssueAppName(appName, param, sequenced: false);
    }

    /// <summary>
    /// App-name addressing, asynchronous, FIFO per (app, api).
    /// </summary>
    public static Task<DataHandle> CallSequencedAsync(
        string appName,
        DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);
        return IssueAppName(appName, param, sequenced: true);
    }

    /// <summary>
    /// UID addressing, asynchronous, unordered.
    /// </summary>
    public static Task<DataHandle> CallByUidAsync(
        P2PUid uid,
        DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(param);
        return IssueUid(uid, param, sequenced: false);
    }

    /// <summary>
    /// UID addressing, asynchronous, FIFO per (uid, api).
    /// </summary>
    public static Task<DataHandle> CallByUidSequencedAsync(
        P2PUid uid,
        DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(param);
        return IssueUid(uid, param, sequenced: true);
    }

    /// <summary>
    /// P2PName addressing, asynchronous, unordered.
    /// </summary>
    public static Task<DataHandle> CallByP2PNameAsync(
        string p2pName,
        DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(param);
        return IssueP2PName(p2pName, param, sequenced: false);
    }

    /// <summary>
    /// P2PName addressing, asynchronous, FIFO per (p2p, api).
    /// </summary>
    public static Task<DataHandle> CallByP2PNameSequencedAsync(
        string p2pName,
        DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(p2pName);
        ArgumentNullException.ThrowIfNull(param);
        return IssueP2PName(p2pName, param, sequenced: true);
    }

    // ====================================================================
    // Shared submission core
    // ====================================================================

    private static Task<DataHandle> IssueAppName(
        string appName,
        DataHandle param,
        bool sequenced)
    {
        EnsureParamValid(param);

        var op = new AsyncOp();
        GCHandle holder = GCHandle.Alloc(op);
        IntPtr dataPtr = GCHandle.ToIntPtr(holder);
        IntPtr namePtr = Utf8Marshal.Alloc(appName);
        var hnd = new DataHnd { Handle = param.Raw };

        try
        {
            int ret = sequenced
                ? NativeMethods.LF_Async_Sequenced_Call(
                    namePtr, hnd, dataPtr, s_trampoline)
                : NativeMethods.LF_Async_Call(
                    namePtr, hnd, dataPtr, s_trampoline);

            if (ret != 1)
            {
                holder.Free();
                op.Tcs.TrySetException(BuildDispatchFailure(
                    $"LF_Async_Call rejected request before dispatch " +
                    $"(target app = \"{appName}\")."));
            }
        }
        catch
        {
            holder.Free();
            throw;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }

        return op.Tcs.Task;
    }

    private static Task<DataHandle> IssueUid(
        P2PUid uid,
        DataHandle param,
        bool sequenced)
    {
        EnsureParamValid(param);

        var op = new AsyncOp();
        GCHandle holder = GCHandle.Alloc(op);
        IntPtr dataPtr = GCHandle.ToIntPtr(holder);
        TUIDNative nativeUid = uid.ToNative();
        var hnd = new DataHnd { Handle = param.Raw };

        try
        {
            int ret = sequenced
                ? NativeMethods.LF_UID_Async_Sequenced_Call(
                    nativeUid, hnd, dataPtr, s_trampoline)
                : NativeMethods.LF_UID_Async_Call(
                    nativeUid, hnd, dataPtr, s_trampoline);

            if (ret != 1)
            {
                holder.Free();
                op.Tcs.TrySetException(BuildDispatchFailure(
                    $"LF_UID_Async_Call rejected request before " +
                    $"dispatch (target uid = \"{uid.ToHexString()}\")."));
            }
        }
        catch
        {
            holder.Free();
            throw;
        }

        return op.Tcs.Task;
    }

    private static Task<DataHandle> IssueP2PName(
        string p2pName,
        DataHandle param,
        bool sequenced)
    {
        EnsureParamValid(param);

        var op = new AsyncOp();
        GCHandle holder = GCHandle.Alloc(op);
        IntPtr dataPtr = GCHandle.ToIntPtr(holder);
        IntPtr namePtr = Utf8Marshal.Alloc(p2pName);
        var hnd = new DataHnd { Handle = param.Raw };

        try
        {
            int ret = sequenced
                ? NativeMethods.LF_P2PNAME_Async_Sequenced_Call(
                    namePtr, hnd, dataPtr, s_trampoline)
                : NativeMethods.LF_P2PNAME_Async_Call(
                    namePtr, hnd, dataPtr, s_trampoline);

            if (ret != 1)
            {
                holder.Free();
                op.Tcs.TrySetException(BuildDispatchFailure(
                    $"LF_P2PNAME_Async_Call rejected request before " +
                    $"dispatch (target p2p = \"{p2pName}\")."));
            }
        }
        catch
        {
            holder.Free();
            throw;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }

        return op.Tcs.Task;
    }

    // ====================================================================
    // Trampoline
    // ====================================================================

    /// <summary>
    /// Static callback invoked by the C ABI on a worker thread when an
    /// async request completes.
    /// </summary>
    private static void OnResult(IntPtr data, IntPtr result)
    {
        GCHandle holder;
        AsyncOp? op;
        try
        {
            holder = GCHandle.FromIntPtr(data);
            op = holder.Target as AsyncOp;
        }
        catch
        {
            return;
        }

        if (op is null)
        {
            try { holder.Free(); } catch { /* nothing we can do */ }
            return;
        }

        // Release the pinned reference before doing any real work.
        try { holder.Free(); } catch { /* nothing we can do */ }

        // Copy the framework-owned payload into a caller-owned handle
        // and complete the Task.
        //
        // The materialization MUST complete before TrySetResult is
        // called: the framework-owned handle becomes invalid the
        // instant this trampoline returns, and TrySetResult may run
        // a user continuation inline on this worker thread.
        try
        {
            DataHandle owned = MaterializeResult(result);
            op.Tcs.TrySetResult(owned);
        }
        catch (Exception ex)
        {
            op.Tcs.TrySetException(ex);
        }
    }

    // ====================================================================
    // Result materialization
    // ====================================================================

    /// <summary>
    /// Copies the entire payload of a framework-owned result handle
    /// into a fresh, caller-owned handle.
    /// </summary>
    private static DataHandle MaterializeResult(IntPtr borrowed)
    {
        if (borrowed == IntPtr.Zero)
        {
            return new DataHandle(AsyncResultApiName);
        }

        // Wrap the framework-owned handle in a BORROWING DataHandle.
        // Its Dispose is a no-op, so we cannot accidentally release
        // the framework's buffer.
        var src = DataHandle.FromRaw(borrowed, owned: false);

        long size = src.Size;
        var owned = new DataHandle(AsyncResultApiName);

        if (size <= 0)
        {
            return owned;
        }

        src.Position = 0;

        long remaining = size;
        while (remaining > 0)
        {
            int want = (int)Math.Min(CopyChunkSize, remaining);
            byte[] chunk = src.ReadBytes(want);
            if (chunk.Length == 0)
            {
                // Unexpected short read. Expose the partial result.
                // This branch is unreachable in practice but keeps
                // the loop bounded under any pathological buffer
                // state.
                break;
            }

            owned.WriteBytes(chunk);
            remaining -= chunk.Length;
        }

        // Rewind so that the caller can read the payload straight
        // away, matching the behaviour of the synchronous path.
        owned.Position = 0;

        return owned;
    }

    // ====================================================================
    // Helpers
    // ====================================================================

    private static void EnsureParamValid(DataHandle param)
    {
        if (!param.IsValid)
        {
            throw new ObjectDisposedException(
                nameof(param),
                "The request DataHandle has been disposed and cannot " +
                "be used as an asynchronous call parameter.");
        }
    }

    private static LingoFuseCallException BuildDispatchFailure(
        string message)
    {
        return new LingoFuseCallException(
            message,
            targetApp: null,
            targetApi: null);
    }

    // ====================================================================
    // Holder
    // ====================================================================

    /// <summary>
    /// The per-operation holder that carries the TaskCompletionSource
    /// across the C ABI boundary.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A single instance is allocated per async call. It is pinned by
    /// a GCHandle whose lifetime is described in the file header.
    /// </para>
    /// <para>
    /// <b>No RunContinuationsAsynchronously.</b> The
    /// TaskCompletionSource is constructed with default options on
    /// purpose, so that the standard C# await semantics apply:
    /// continuations are posted back to the awaiting thread's
    /// SynchronizationContext when one exists (UI scenarios), and run
    /// inline on the completing thread when it does not (console /
    /// background-service scenarios). See the file-level
    /// documentation for the full rationale.
    /// </para>
    /// <para>
    /// Because of that choice, the caller of TrySetResult may run a
    /// user continuation synchronously. This trampoline therefore
    /// finishes all work on the framework-owned handle BEFORE calling
    /// TrySetResult.
    /// </para>
    /// </remarks>
    private sealed class AsyncOp
    {
        public readonly TaskCompletionSource<DataHandle> Tcs = new();
    }
}