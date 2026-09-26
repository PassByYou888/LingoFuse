// =============================================================================
//  CrossService.cs
// -----------------------------------------------------------------------------
//  Coordinator process for the IPC endpoint "ipc:cross".
//
//  This program:
//    1. Creates the IPC service endpoint "ipc:cross".
//    2. Starts the framework (LF_PrepareDone).
//    3. Waits for the user to press Enter.
//    4. Performs a clean shutdown (LF_ExitMainThread -> LF_Shutdown).
//
//  It does NOT register any API and does NOT act as a caller. Its sole
//  purpose is to act as the discovery/anchor endpoint that worker nodes
//  and callers connect to.
//
//  ---------------------------------------------------------------------------
//  DIFFERENCE FROM THE C++ COUNTERPART
//  ---------------------------------------------------------------------------
//  The C++ CrossService.cpp uses LibraryLoader + ShutdownGuard + the raw
//  prepareService / prepareDone / exitMainThread sequence. The C# managed
//  binding does not expose a "pure service, no client, no App" mode: the
//  public LingoFuseServer always performs ResetPrepare -> PrepareService
//  -> PrepareClient -> PrepareDone in one call.
//
//  We therefore use LingoFuseServer with a placeholder application name.
//  The placeholder is never called by any peer; it exists only to satisfy
//  the container's constructor contract. The observable behaviour for
//  peers is identical: the "ipc:cross" endpoint is announced on the mesh.
//
//  Note: the coordinator's internal client does not occupy a slot that
//  other processes could use. C4 mesh clients are process-scoped; the
//  Overlap_Connection option only affects multiple clients within the
//  same process.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      LF_ExitMainThread  ->  (App detach)  ->  LF_Shutdown
//
//  LingoFuseServer.Stop(fullCleanup: true) performs all three steps in the
//  required order. The using-statement guarantees it runs on every exit
//  path, including early returns and exceptions.
// =============================================================================

using System;

using LingoFuse;
using LingoFuse.Host;

namespace LingoFuse.Demo.CrossService;

internal static class Program
{
    private const string Endpoint = "ipc:cross";

    /// <summary>
    /// Placeholder application name. The coordinator exposes no API and
    /// is never the target of a call; this name exists only because the
    /// LingoFuseServer container requires one.
    /// </summary>
    private const string CoordinatorAppName = "__cross_coordinator__";

    public static int Main()
    {
        Console.WriteLine("=== Cross Service (Coordinator) ===");

        try
        {
            using var server = new LingoFuseServer(
                appName: CoordinatorAppName,
                endpoint: Endpoint,
                description: "Coordinator endpoint for the C# cross demo");

            server.Start();

            Console.WriteLine(
                $"IPC service '{Endpoint}' is running. " +
                "Press Enter to exit...");
            Console.ReadLine();

            Console.WriteLine("Shutting down...");
            server.Stop(fullCleanup: true);
        }
        catch (LingoFuseException ex)
        {
            Console.Error.WriteLine(
                $"[FATAL] {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(
                $"[FATAL] {ex.GetType().Name}: {ex.Message}");
            return 1;
        }

        Console.WriteLine("Bye.");
        return 0;
    }
}