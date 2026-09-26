using System;

using LingoFuse.Native;

namespace LingoFuse.Diagnostics;

// ============================================================================
// LingoFuseStatus — status queue, health checks, and diagnostics.
// ============================================================================
//
// Status queue
// ------------
// The native library maintains a bounded FIFO of log messages, up to
// 1000 entries. Older entries are dropped when the buffer is full.
// Messages are surfaced through GetStatusCount and GetStatus, and can
// be injected by the application through PostStatus.
//
// Main-thread dependency
// ----------------------
// The status queue is processed by the native simulated main thread.
// Before LF_PrepareDone has been called, the queue may be empty or
// contain stale data. Applications should not rely on status messages
// during initialization.
//
// Static buffer hazard
// --------------------
// LF_GetStatus returns a pointer into a process-wide static buffer that
// is overwritten by the next call. This wrapper copies the string to a
// managed instance immediately, so callers never observe a dangling
// pointer.
//
// Health checks
// -------------
// CheckMainThread reports whether the simulated main thread is running.
// CheckApp and CheckApi perform cache-based lookups that are updated by
// network broadcasts with an approximate 3-second delay. They are
// suitable for probing and diagnostics, not for authoritative
// availability decisions. For critical paths, issue the call and handle
// timeouts explicitly.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException   a reference argument is null
//
// This class has no state and no disposal semantics; it is a pure
// façade over the native status functions.
// ============================================================================

/// <summary>
/// Status queue and health-check helpers for the LingoFuse runtime.
/// </summary>
public static class LingoFuseStatus
{
    // ====================================================================
    // Status queue
    // ====================================================================

    /// <summary>
    /// Returns the number of pending log messages in the status queue.
    /// </summary>
    public static int GetStatusCount()
    {
        return NativeMethods.LF_GetStatusCount();
    }

    /// <summary>
    /// Retrieves the next log message from the status queue. Returns an
    /// empty string when the queue is empty.
    /// </summary>
    /// <remarks>
    /// The native function returns a pointer into a static buffer that
    /// the very next call would overwrite. The string is copied to
    /// managed memory before this method returns, so the caller never
    /// observes that hazard.
    /// </remarks>
    public static string GetStatus()
    {
        IntPtr ptr = NativeMethods.LF_GetStatus();
        return Utf8Marshal.PtrToString(ptr);
    }

    /// <summary>
    /// Drains up to <paramref name="maxMessages"/> pending status
    /// messages and returns them in FIFO order. Returns an empty array
    /// when the queue is empty.
    /// </summary>
    /// <param name="maxMessages">
    /// Upper bound on the number of messages to retrieve. Must be
    /// non-negative. A value of zero returns an empty array without
    /// touching the queue.
    /// </param>
    /// <exception cref="ArgumentOutOfRangeException">
    /// Thrown when <paramref name="maxMessages"/> is negative.
    /// </exception>
    public static string[] DrainStatus(int maxMessages = 64)
    {
        if (maxMessages < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxMessages), maxMessages,
                "Maximum number of messages must be non-negative.");
        }
        if (maxMessages == 0)
        {
            return Array.Empty<string>();
        }

        int pending = GetStatusCount();
        if (pending <= 0)
        {
            return Array.Empty<string>();
        }

        int count = Math.Min(pending, maxMessages);
        string[] messages = new string[count];
        int captured = 0;

        for (int i = 0; i < count; i++)
        {
            string msg = GetStatus();
            if (msg.Length == 0)
            {
                break;
            }
            messages[captured++] = msg;
        }

        if (captured == count)
        {
            return messages;
        }

        // Trim the array to the number of messages actually captured.
        var trimmed = new string[captured];
        Array.Copy(messages, trimmed, captured);
        return trimmed;
    }

    /// <summary>
    /// Injects a custom log message into the status queue.
    /// </summary>
    /// <param name="message">
    /// Message to inject. Must not be null. An empty string is allowed;
    /// the native side will queue it as an empty entry.
    /// </param>
    /// <remarks>
    /// Messages posted before the simulated main thread has started may
    /// be discarded by the native side.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="message"/> is null.
    /// </exception>
    public static void PostStatus(string message)
    {
        ArgumentNullException.ThrowIfNull(message);

        IntPtr ptr = Utf8Marshal.Alloc(message);
        try
        {
            NativeMethods.LF_PostStatus(ptr);
        }
        finally
        {
            Utf8Marshal.Free(ptr);
        }
    }

    // ====================================================================
    // Health checks
    // ====================================================================

    /// <summary>
    /// Returns true when the simulated main thread is currently running.
    /// </summary>
    public static bool CheckMainThread()
    {
        return NativeMethods.LF_CheckMainThread() != 0;
    }

    /// <summary>
    /// Probes whether an application with the given name is available.
    /// </summary>
    /// <param name="appName">
    /// Application name. Must not be null. An empty string is allowed;
    /// the native side will report it as unavailable.
    /// </param>
    /// <remarks>
    /// The lookup uses a local cache updated by network broadcasts with
    /// an approximate 3-second delay. False negatives immediately after
    /// registration and false positives shortly after unregistration
    /// are both normal. Do not use this as an authoritative existence
    /// test for critical paths.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> is null.
    /// </exception>
    public static bool CheckApp(string appName)
    {
        ArgumentNullException.ThrowIfNull(appName);

        IntPtr ptr = Utf8Marshal.Alloc(appName);
        try
        {
            return NativeMethods.LF_CheckApp(ptr) != 0;
        }
        finally
        {
            Utf8Marshal.Free(ptr);
        }
    }

    /// <summary>
    /// Probes whether the named API is available for the given
    /// application. Same cache-based caveat as <see cref="CheckApp"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when either argument is null.
    /// </exception>
    public static bool CheckApi(string appName, string apiName)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(apiName);

        IntPtr appPtr = Utf8Marshal.Alloc(appName);
        IntPtr apiPtr = Utf8Marshal.Alloc(apiName);
        try
        {
            return NativeMethods.LF_CheckApi(appPtr, apiPtr) != 0;
        }
        finally
        {
            Utf8Marshal.Free(appPtr);
            Utf8Marshal.Free(apiPtr);
        }
    }
}