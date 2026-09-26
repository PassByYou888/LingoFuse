using System;

namespace LingoFuse.Core;

// ============================================================================
// LingoFuseSync — public API for main-thread callback marshalling.
// ============================================================================
//
// Why this class exists
// ---------------------
// The AppHandle exposes synchronous callback registration through
// RegisterCallSync / RegisterNotifySync. Those callbacks do NOT run on
// the native worker thread directly: they are queued, and the
// application's main thread must drain the queue periodically.
//
// The underlying queue implementation (SyncQueue) is internal because it
// is an implementation detail. This class is the public façade that
// user code is expected to call. It exposes exactly the three operations
// that the queue contract requires:
//
//     ProcessSyncQueue()   drain pending callbacks on the main thread
//     SetMainThread()      explicitly designate the main thread
//     IsMainThreadCurrent  report whether the caller is the main thread
//
// ----------------------------------------------------------------------------
// WHEN TO USE THIS CLASS
// ----------------------------------------------------------------------------
// Any application that registers a *Sync callback on an AppHandle (or
// through LingoFuseApp.Expose(..., synchronous: true)) MUST drive
// ProcessSyncQueue from its main loop.
//
// Typical patterns:
//
//   Windows Forms / WPF:
//       System.Windows.Forms.Application.Idle += (_, __) => LingoFuseSync.ProcessSyncQueue();
//       // or a timer, or an override of OnIdle.
//
//   Console / service:
//       // A dedicated main loop that also handles other work.
//       while (running)
//       {
//           LingoFuseSync.ProcessSyncQueue();
//           Thread.Sleep(10);
//       }
//
//   ASP.NET Core:
//       // A hosted service that runs on the main request pipeline thread,
//       // or a dedicated background thread registered as the main thread
//       // via SetMainThread().
//
// If ProcessSyncQueue is never called:
//   - the queued callbacks never execute;
//   - the native worker threads that dispatched them block forever
//     inside completion.Wait();
//   - the framework eventually stalls.
//
// ----------------------------------------------------------------------------
// MAIN THREAD REGISTRATION
// ----------------------------------------------------------------------------
// The first call to ProcessSyncQueue automatically registers the calling
// thread as the main thread. If the very first ProcessSyncQueue call may
// come from a non-UI thread (for example, a background dispatcher that
// runs before the UI loop starts), call SetMainThread() explicitly
// during application startup, before any sync callback can be delivered.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
// All methods in this class are non-throwing. An exception raised by a
// user callback is caught by the SyncQueue bridge and logged via
// Debug.WriteLine; it never reaches this API.
// ============================================================================

/// <summary>
/// Public façade for the main-thread callback marshalling queue.
/// </summary>
/// <remarks>
/// Applications that register synchronous callbacks must call
/// <see cref="ProcessSyncQueue"/> periodically from their main loop.
/// </remarks>
public static class LingoFuseSync
{
    /// <summary>
    /// Explicitly designates the calling thread as the main thread.
    /// </summary>
    /// <remarks>
    /// Call this once during application startup, before any synchronous
    /// callback can be delivered, if the first call to
    /// <see cref="ProcessSyncQueue"/> may come from a non-UI thread.
    ///
    /// If <see cref="ProcessSyncQueue"/> is called first, the calling
    /// thread is registered as the main thread automatically.
    /// </remarks>
    public static void SetMainThread() => SyncQueue.SetMainThread();

    /// <summary>
    /// True when the calling thread is the registered main thread.
    /// </summary>
    public static bool IsMainThreadCurrent => SyncQueue.IsMainThreadCurrent;

    /// <summary>
    /// Number of work items currently waiting to be drained.
    /// </summary>
    /// <remarks>
    /// Useful for diagnostics: a persistently non-zero value means the
    /// main loop is not calling <see cref="ProcessSyncQueue"/> often
    /// enough.
    /// </remarks>
    public static int PendingSyncCount => SyncQueue.PendingCount;

    /// <summary>
    /// Cumulative number of work items executed since process start.
    /// Provided for diagnostics only.
    /// </summary>
    public static long TotalSyncProcessed => SyncQueue.TotalProcessed;

    /// <summary>
    /// Drains every pending work item, executing each on the calling
    /// thread in the order it was enqueued.
    /// </summary>
    /// <returns>
    /// The number of work items executed during this call. Zero means the
    /// queue was already empty.
    /// </returns>
    /// <remarks>
    /// This method must be called from the registered main thread. The
    /// first call registers the calling thread as the main thread if no
    /// thread has been registered yet.
    ///
    /// The method is safe to call from a timer, an idle handler, a message
    /// loop, or any other periodic main-thread execution point. It is
    /// non-blocking when the queue is empty, and executes each pending
    /// item synchronously when the queue is non-empty.
    /// </remarks>
    public static int ProcessSyncQueue() => SyncQueue.ProcessSyncQueue();
}