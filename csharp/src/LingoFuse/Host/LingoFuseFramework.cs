using System;

using LingoFuse.Diagnostics;
using LingoFuse.Events;
using LingoFuse.Native;

namespace LingoFuse.Host;

// ============================================================================
// LingoFuseFramework — process-wide lifecycle control.
// ============================================================================
//
// Why this class exists
// ---------------------
// The LingoFuse C ABI exposes two process-wide lifecycle operations that
// every application must be able to perform explicitly:
//
//     LF_ExitMainThread()  — stop the simulated main thread. The native
//                            library stays loaded and can be re-prepared.
//
//     LF_Shutdown()        — fully release every native resource held by
//                            the process: stop the main thread, stop all
//                            sequenced-notification threads, free every
//                            remaining data handle, destroy every TLF_App
//                            object, and unload the IPC library.
//
// The three host classes (LingoFuseServer, LingoFuseClient, LingoFuseNode)
// expose their own lifecycle APIs (Start/Stop/Dispose/FullCleanup) so that
// an application can manage a single host. But the underlying framework is
// process-wide, so an application that hosts only a pure client or only a
// worker node would otherwise have no way to release the framework before
// exiting.
//
// This class is that missing entry point.
//
// ----------------------------------------------------------------------------
// WHEN TO CALL Shutdown()
// ----------------------------------------------------------------------------
// Before the process exits. If the application never calls it:
//
//   - The simulated main thread keeps running until the OS terminates
//     the process. This is usually harmless for a short-lived tool but
//     leaks resources in a long-running service that periodically
//     reinitialises the framework.
//
//   - The native library is not unloaded. When the C# process is
//     hosting LingoFuse as a plugin (e.g. a DLL loaded by a host
//     application), the host application cannot unload the plugin
//     cleanly.
//
// Calling Shutdown() is idempotent: a second call is a no-op.
//
// ----------------------------------------------------------------------------
// RELATIONSHIP WITH HOST FullCleanup()
// ----------------------------------------------------------------------------
// LingoFuseServer.Stop(fullCleanup: true), LingoFuseClient.FullCleanup()
// and LingoFuseNode.FullCleanup() all delegate to
// LingoFuseFramework.Shutdown(). Use whichever form matches your code
// structure:
//
//   - If your application owns a single LingoFuseServer, prefer
//     server.Stop(fullCleanup: true).
//
//   - If your application owns only a LingoFuseClient or a
//     LingoFuseNode, call its FullCleanup() method.
//
//   - If your application owns multiple hosts, or the host whose
//     lifetime spans the whole application is awkward to name, call
//     LingoFuseFramework.Shutdown() directly at process exit.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
// Every method in this class is best-effort:
//
//   - Any native exception is swallowed so that a shutdown path cannot
//     itself throw. Shutdown code is the last thing a process runs, and
//     a failure there is worse than a silent no-op.
//
//   - Argument validation is not applicable; the class has no public
//     parameters.
// ============================================================================

/// <summary>
/// Process-wide lifecycle control for the LingoFuse framework.
/// </summary>
/// <remarks>
/// Call <see cref="Shutdown"/> before process exit to release every
/// native resource. Safe to call multiple times.
/// </remarks>
public static class LingoFuseFramework
{
    /// <summary>
    /// True when the framework is currently running: LF_PrepareDone has
    /// been called at least once in this process and the native
    /// simulated main thread is still alive.
    /// </summary>
    public static bool IsStarted => LingoFuseRuntime.IsStarted;

    /// <summary>
    /// Fully releases every native resource held by the framework.
    /// </summary>
    /// <remarks>
    /// The shutdown sequence is, in order:
    ///
    ///   1. Clear the process-global network event callbacks.
    ///
    ///   2. Stop the simulated main thread (LF_ExitMainThread).
    ///
    ///   3. Release the framework and unload the IPC library
    ///      (LF_Shutdown).
    ///
    ///   4. Reset the cached "framework started" flag so that a
    ///      subsequent LingoFuseServer.Start / LingoFuseClient.Connect /
    ///      LingoFuseNode.Connect performs a full re-initialisation.
    ///
    /// After this call, the process may start a fresh framework by
    /// creating a new host and calling its Start or Connect method. The
    /// previous host instances are invalid and must not be reused.
    ///
    /// Safe to call multiple times. A call when the framework is not
    /// running is a no-op.
    ///
    /// Never throws. Any failure in the native shutdown path is
    /// swallowed, because shutdown code is the last thing a process
    /// runs and must not itself fail.
    /// </remarks>
    public static void Shutdown()
    {
        // 1. Clear the process-global network event callbacks before
        //    tearing down the framework, so that no user handler can
        //    fire during the shutdown transition.
        try
        {
            NetworkEvents.Clear();
        }
        catch
        {
            // Best-effort: a failure here does not prevent shutdown.
        }

        // 2. Stop the simulated main thread. This is idempotent and
        //    safe even if the thread was never started.
        try
        {
            NativeMethods.LF_ExitMainThread();
        }
        catch
        {
            // Best-effort.
        }

        // 3. Release every native resource held by the framework:
        //    sequenced-notification threads, remaining data handles,
        //    the global application pool, and the IPC library.
        try
        {
            NativeMethods.LF_Shutdown();
        }
        catch
        {
            // Best-effort.
        }

        // 4. Clear the cached flag so that a subsequent host performs
        //    the full preparation sequence.
        LingoFuseRuntime.MarkStopped();
    }

    /// <summary>
    /// Stops the simulated main thread without unloading the native
    /// library.
    /// </summary>
    /// <remarks>
    /// After this call, the framework is no longer running, but the
    /// native library is still loaded. A subsequent host that calls
    /// Start or Connect will re-prepare and re-start the main thread.
    ///
    /// Use this method when the process is going to keep using
    /// LingoFuse after a short pause, or when the application wants to
    /// stop the network loop before performing other cleanup work and
    /// then finish with a call to <see cref="Shutdown"/>.
    ///
    /// Never throws.
    /// </remarks>
    public static void ExitMainThread()
    {
        try
        {
            NativeMethods.LF_ExitMainThread();
        }
        catch
        {
            // Best-effort.
        }
    }

    /// <summary>
    /// Clears any pending preparation commands.
    /// </summary>
    /// <remarks>
    /// This is the equivalent of the native LF_ResetPrepare. It is
    /// normally called automatically by LingoFuseServer.Start and by
    /// LingoFuseClient.Connect / LingoFuseNode.Connect before their
    /// preparation sequence. The method is exposed for callers that
    /// drive the native layer directly, or that need to discard a set
    /// of prepared services and clients before preparing a new set.
    ///
    /// Never throws.
    /// </remarks>
    public static void ResetPrepare()
    {
        try
        {
            NativeMethods.LF_ResetPrepare();
        }
        catch
        {
            // Best-effort.
        }
    }
}