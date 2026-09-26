using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;

using LingoFuse.Native;

namespace LingoFuse.Core;

// ============================================================================
// SyncQueue — main-thread marshalling for callbacks (internal).
// ============================================================================
//
// Why this class exists
// ---------------------
// The C ABI exposes only asynchronous callback registration. Every
// callback runs on a native worker thread and receives short-lived
// input/output handles that the native side releases as soon as the
// callback returns.
//
// Some use cases — notably UI updates — require the callback body to
// run on the application's main thread. This class provides that by:
//
//   1. Wrapping the user delegate in a bridge delegate whose body
//      enqueues the real work and then BLOCKS until the main thread
//      has finished executing it.
//
//   2. Exposing ProcessSyncQueue(), which the main thread must call
//      periodically (via a timer, an idle handler, or a message loop)
//      to drain the queue.
//
// ----------------------------------------------------------------------------
// WHY THE BRIDGE MUST BLOCK
// ----------------------------------------------------------------------------
// If the bridge returned immediately after enqueuing, the native side
// would release the input/output handles while the main thread is
// still waiting to run the user callback. When the user callback
// finally runs, it would dereference freed memory and crash with an
// access violation.
//
// Blocking the bridge thread until the main thread completes the
// callback guarantees the handles stay valid for the entire duration
// of the user code. This mirrors the semantics of the Pascal binding's
// TSoft_Synchronize_Tool.
//
// ----------------------------------------------------------------------------
// INLINE EXECUTION ON THE MAIN THREAD
// ----------------------------------------------------------------------------
// If the bridge is somehow invoked on the main thread itself (possible
// when the callback originates from a synchronous native path), the
// user delegate is executed inline instead of being enqueued. This
// avoids a self-deadlock that would otherwise occur when the bridge
// waited on a queue that only the current thread could drain.
//
// ----------------------------------------------------------------------------
// WHY THIS CLASS IS INTERNAL
// ----------------------------------------------------------------------------
// SyncQueue is an implementation detail. User code must go through the
// public façade in LingoFuseSync, which exposes only the three
// operations that the queue contract requires
// (ProcessSyncQueue / SetMainThread / IsMainThreadCurrent).
//
// The AppHandle RegisterCallSync / RegisterNotifySync methods reference
// this class internally; user code never does.
//
// ----------------------------------------------------------------------------
// MAIN THREAD REGISTRATION
// ----------------------------------------------------------------------------
// The main thread ID is captured automatically on the first call to
// ProcessSyncQueue. If the very first call may come from a non-UI
// thread, the application should call LingoFuseSync.SetMainThread
// explicitly during startup, before any synchronous callback can be
// delivered.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException   the bridge factory receives a null
//                             user callback
//
// The class has no disposal semantics and no other failure modes. Any
// exception raised by a user callback is caught inside the bridge and
// logged via Debug.WriteLine; it never escapes to the native stack.
// ============================================================================

/// <summary>
/// Process-wide queue that marshals callback invocations to the main
/// thread.
/// </summary>
/// <remarks>
/// This class is an implementation detail. User code must call
/// <see cref="LingoFuseSync"/> instead of touching this class directly.
/// </remarks>
internal static class SyncQueue
{
    /// <summary>Pending work items waiting for the main thread.</summary>
    private static readonly ConcurrentQueue<Action> Queue = new();

    /// <summary>
    /// Managed thread ID of the main thread. Zero means "not yet set".
    /// The value is populated automatically on the first call to
    /// <see cref="ProcessSyncQueue"/> or explicitly via
    /// <see cref="SetMainThread"/>.
    /// </summary>
    private static int _mainThreadId;

    /// <summary>
    /// Cumulative count of work items executed since process start.
    /// Provided for diagnostics only.
    /// </summary>
    private static long _totalProcessed;

    /// <summary>
    /// Explicitly designates the current thread as the main thread.
    /// Call this once during application startup, before any synchronous
    /// callback can be delivered, if the first call to
    /// <see cref="ProcessSyncQueue"/> may come from a non-UI thread.
    /// </summary>
    public static void SetMainThread()
    {
        Interlocked.Exchange(
            ref _mainThreadId,
            Environment.CurrentManagedThreadId);
    }

    /// <summary>
    /// True when the calling thread is the registered main thread.
    /// </summary>
    public static bool IsMainThreadCurrent
    {
        get
        {
            int id = Volatile.Read(ref _mainThreadId);
            return id != 0
                && Environment.CurrentManagedThreadId == id;
        }
    }

    /// <summary>Number of work items currently waiting to run.</summary>
    public static int PendingCount => Queue.Count;

    /// <summary>Cumulative number of work items executed.</summary>
    public static long TotalProcessed =>
        Interlocked.Read(ref _totalProcessed);

    /// <summary>
    /// Drains every pending work item, executing each in the order it
    /// was enqueued. This method must be called from the main thread.
    /// </summary>
    /// <returns>
    /// The number of work items executed during this call. A return
    /// value of zero means the queue was already empty.
    /// </returns>
    public static int ProcessSyncQueue()
    {
        // Auto-register the caller as the main thread on first use.
        if (Volatile.Read(ref _mainThreadId) == 0)
        {
            Interlocked.CompareExchange(
                ref _mainThreadId,
                Environment.CurrentManagedThreadId,
                0);
        }

        int processed = 0;
        while (Queue.TryDequeue(out Action? action))
        {
            try
            {
                action();
                processed++;
            }
            catch (Exception ex)
            {
                // The action body already isolates user exceptions;
                // this guard catches failures in the plumbing itself
                // (for example, an error raised while setting the
                // completion event).
                Debug.WriteLine(
                    "[LingoFuse] SyncQueue.ProcessSyncQueue: action " +
                    "failed: " + ex);
            }
        }

        if (processed > 0)
        {
            Interlocked.Add(ref _totalProcessed, processed);
        }
        return processed;
    }

    // ====================================================================
    // Bridge factories
    // ====================================================================

    /// <summary>
    /// Wraps a user-supplied Call delegate so that it executes on the
    /// main thread while the native worker thread blocks until the
    /// user code has completed.
    /// </summary>
    /// <param name="userCallback">
    /// The delegate to marshal. Must not be null.
    /// </param>
    /// <returns>
    /// A new bridge delegate suitable for passing to
    /// <c>LF_RegisterCall</c>.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="userCallback"/> is null.
    /// </exception>
    public static LfCallFunc CreateSyncCallBridge(LfCallFunc userCallback)
    {
        ArgumentNullException.ThrowIfNull(userCallback);

        return (trigger, input, output) =>
        {
            if (IsMainThreadCurrent)
            {
                InvokeSafely(
                    () => userCallback(trigger, input, output),
                    "Call (inline)");
                return;
            }

            using var completion = new ManualResetEventSlim(
                initialState: false);

            Queue.Enqueue(() =>
            {
                try
                {
                    InvokeSafely(
                        () => userCallback(trigger, input, output),
                        "Call (marshalled)");
                }
                finally
                {
                    // Release the native worker thread regardless of
                    // whether the user callback succeeded or failed.
                    completion.Set();
                }
            });

            // Block until the main thread has finished the callback.
            // This is what keeps the input/output handles valid for
            // the whole duration of the user code.
            completion.Wait();
        };
    }

    /// <summary>
    /// Wraps a user-supplied Notify delegate using the same semantics
    /// as <see cref="CreateSyncCallBridge"/>.
    /// </summary>
    /// <param name="userCallback">
    /// The delegate to marshal. Must not be null.
    /// </param>
    /// <returns>
    /// A new bridge delegate suitable for passing to
    /// <c>LF_RegisterNotify</c>.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="userCallback"/> is null.
    /// </exception>
    public static LfNotifyFunc CreateSyncNotifyBridge(LfNotifyFunc userCallback)
    {
        ArgumentNullException.ThrowIfNull(userCallback);

        return (trigger, input) =>
        {
            if (IsMainThreadCurrent)
            {
                InvokeSafely(
                    () => userCallback(trigger, input),
                    "Notify (inline)");
                return;
            }

            using var completion = new ManualResetEventSlim(
                initialState: false);

            Queue.Enqueue(() =>
            {
                try
                {
                    InvokeSafely(
                        () => userCallback(trigger, input),
                        "Notify (marshalled)");
                }
                finally
                {
                    completion.Set();
                }
            });

            completion.Wait();
        };
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    /// <summary>
    /// Executes <paramref name="body"/>, catching every exception so
    /// that no managed error can escape into the native stack.
    /// </summary>
    private static void InvokeSafely(Action body, string label)
    {
        try
        {
            body();
        }
        catch (Exception ex)
        {
            // Log via the debugger so that developers see the failure
            // during debugging, but never let it propagate.
            Debug.WriteLine(
                $"[LingoFuse] SyncQueue {label} callback threw: {ex}");
        }
    }
}