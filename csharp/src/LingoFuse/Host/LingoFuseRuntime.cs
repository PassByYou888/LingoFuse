using System;
using System.Threading;

using LingoFuse.Diagnostics;
using LingoFuse.Native;

namespace LingoFuse.Host;

// ============================================================================
// LingoFuseRuntime — process-wide startup coordination.
// ============================================================================
//
// Why this class exists
// ---------------------
// The native LF_PrepareDone function returns 1 exactly once per "fresh"
// startup of the simulated main thread. A second call, with no
// intervening LF_ExitMainThread, returns 0. Treating that 0 as a failure
// would produce spurious exceptions in any application that hosts more
// than one logical server, client or node in a single process.
//
// This helper centralises the "has the framework already been started"
// question so that LingoFuseServer, LingoFuseClient and LingoFuseNode
// can coordinate without sharing a parent object.
//
// ----------------------------------------------------------------------------
// STARTED VS RUNNING
// ----------------------------------------------------------------------------
// Two distinct conditions matter:
//
//   "Ever started"  — LF_PrepareDone has been called successfully at
//                     least once in this process. Cached in the
//                     _started flag.
//
//   "Currently running" — the native simulated main thread is alive
//                     right now. Reported by
//                     LingoFuseStatus.CheckMainThread().
//
// The public IsStarted property returns "currently running". This is
// the answer that hosts actually care about:
//
//   - After Start(), Stop(fullCleanup: false) the cached flag is still
//     1 but the main thread has exited. IsStarted must return false so
//     that a subsequent host performs a fresh preparation.
//
//   - After Stop(fullCleanup: true), LF_Shutdown has run process-wide.
//     The cached flag is cleared and IsStarted returns false.
//
// The cached flag exists purely to avoid an extra native call in the
// common "never started" case.
//
// ----------------------------------------------------------------------------
// WHY THIS CLASS IS INTERNAL
// ----------------------------------------------------------------------------
// The started/stopped cache is a process-wide invariant that only the
// host classes themselves are entitled to change. Exposing the mutators
// publicly would let an application set the flag out of sync with the
// actual native state, causing every subsequent host to either
// re-prepare the framework (and get 0 from LF_PrepareDone) or skip
// preparation entirely.
//
// The three host classes (LingoFuseServer, LingoFuseClient, LingoFuseNode)
// are the only legitimate callers. The class is therefore internal.
//
// ----------------------------------------------------------------------------
// THREADING
// ----------------------------------------------------------------------------
// The cached flag is accessed through Volatile / Interlocked so that it
// is observed consistently across threads. MarkStarted and MarkStopped
// are idempotent.
//
// SetOption is a thin wrapper around LF_SetOption with managed strings;
// it allocates unmanaged memory per call, copies the UTF-8 bytes, and
// frees the buffers in a finally block. It is safe to call concurrently
// because LF_SetOption itself is thread-safe.
// ============================================================================

/// <summary>
/// Process-wide startup coordination for the LingoFuse framework.
/// </summary>
/// <remarks>
/// This class is an implementation detail of the host layer. It is not
/// part of the public API.
/// </remarks>
internal static class LingoFuseRuntime
{
    /// <summary>
    /// Zero means "never started (or cleanly stopped)". Any non-zero
    /// value means "LF_PrepareDone has been called at least once".
    /// Accessed exclusively through <see cref="Volatile"/> and
    /// <see cref="Interlocked"/> so that the flag is observed
    /// consistently across threads.
    /// </summary>
    private static int _started;

    /// <summary>
    /// True when the framework is currently running: LF_PrepareDone has
    /// been called at least once and the native simulated main thread
    /// is still alive.
    /// </summary>
    /// <remarks>
    /// The cached <c>_started</c> flag short-circuits the check when the
    /// framework has never been started. When the flag is set, the
    /// authoritative answer comes from
    /// <see cref="LingoFuseStatus.CheckMainThread"/>, because a plain
    /// <c>LF_ExitMainThread</c> does not clear the flag (other hosts may
    /// still wish to see "yes, this process has started the framework
    /// before" for diagnostic purposes, but they must not treat it as
    /// "still running").
    /// </remarks>
    public static bool IsStarted
    {
        get
        {
            if (Volatile.Read(ref _started) == 0)
            {
                return false;
            }
            return LingoFuseStatus.CheckMainThread();
        }
    }

    /// <summary>
    /// Atomically records that LF_PrepareDone has succeeded. Idempotent.
    /// </summary>
    /// <remarks>
    /// This method only sets the cached flag; it does not consult the
    /// native state. The flag is used as a fast pre-check by
    /// <see cref="IsStarted"/>.
    /// </remarks>
    public static void MarkStarted()
    {
        Interlocked.Exchange(ref _started, 1);
    }

    /// <summary>
    /// Clears the cached "started" flag. Called after LF_Shutdown,
    /// which resets the process-wide framework state.
    /// </summary>
    /// <remarks>
    /// A plain LF_ExitMainThread does NOT clear the flag: the framework
    /// may be restarted in the same process, and the flag only
    /// represents "has been started at least once". <see cref="IsStarted"/>
    /// resolves the difference by consulting the native main thread
    /// state.
    /// </remarks>
    public static void MarkStopped()
    {
        Volatile.Write(ref _started, 0);
    }

    /// <summary>
    /// Convenience wrapper for LF_SetOption with managed strings.
    /// </summary>
    /// <param name="key">
    /// Option name. Must not be null. An empty string is allowed; the
    /// native layer treats unknown option names as no-ops.
    /// </param>
    /// <param name="value">
    /// Option value. Must not be null. An empty string is allowed and
    /// is passed to the native layer verbatim.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="key"/> or <paramref name="value"/> is
    /// null.
    /// </exception>
    public static void SetOption(string key, string value)
    {
        ArgumentNullException.ThrowIfNull(key);
        ArgumentNullException.ThrowIfNull(value);

        IntPtr keyPtr = Utf8Marshal.Alloc(key);
        IntPtr valPtr = Utf8Marshal.Alloc(value);
        try
        {
            NativeMethods.LF_SetOption(keyPtr, valPtr);
        }
        finally
        {
            Utf8Marshal.Free(keyPtr);
            Utf8Marshal.Free(valPtr);
        }
    }
}