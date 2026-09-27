// =============================================================================
//  CrossService.cs
// -----------------------------------------------------------------------------
//  Coordinator process for the IPC endpoint "ipc:cross".
//
//  This program:
//    1. Creates the IPC service endpoint "ipc:cross".
//    2. Starts the framework (Framework.PrepareDone).
//    3. Waits for the user to press Enter.
//    4. Performs a clean shutdown in the LF-CLEAN-001 order:
//           NetworkEvents.Clear -> ExitMainThread -> Shutdown
//
//  It does NOT register any API and does NOT act as a caller. Its sole
//  purpose is to act as the discovery/anchor endpoint that worker nodes
//  and callers connect to.
//
//  ---------------------------------------------------------------------------
//  DIFFERENCE FROM THE C++ COUNTERPART
//  ---------------------------------------------------------------------------
//  The C++ CrossService.cpp uses LibraryLoader + ShutdownGuard + the raw
//  prepareService / prepareDone / exitMainThread sequence.
//
//  The C# two-layer binding exposes those same primitives directly on
//  the Framework facade. This program therefore uses Framework.* only;
//  no AppHandle is created, no API is registered.
//
//  A client is prepared against the local endpoint so that the C4 mesh
//  has at least one physical tunnel to anchor the broadcast loop. The
//  client carries no application.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      NetworkEvents.Clear -> ExitMainThread -> Shutdown
//
//  The finally block guarantees the sequence runs on every exit path,
//  including early returns and exceptions.
// =============================================================================

using System;

using LingoFuse;

namespace LingoFuse.Demo.CrossService;

internal static class Program
{
    private const string Endpoint = "ipc:cross";

    public static int Main()
    {
        Console.WriteLine("=== Cross Service (Coordinator) ===");

        bool started = false;

        try
        {
            // ---------------------------------------------------------------
            // Deployment mode options.
            //
            // Wait_Connection_ReadyOk is True so that PrepareDone blocks
            // until the internal client is actually online. The default
            // of 30 seconds is used, capped here at 10 seconds to keep
            // the demo responsive if something is genuinely wrong.
            // ---------------------------------------------------------------
            Framework.SetOption("Wait_Connection_ReadyOk", "True");
            Framework.SetOption("Overlap_Connection", "True");
            Framework.SetOption("Wait_Connection_Timeout", "10000");

            Framework.ResetPrepare();

            int serviceTag = Framework.PrepareService(Endpoint, Endpoint);
            if (serviceTag == -1)
            {
                Console.Error.WriteLine(
                    $"[FATAL] Framework.PrepareService returned -1 " +
                    $"for {Endpoint}.");
                return 1;
            }

            // Prepare a client with no application. This gives the mesh
            // at least one physical tunnel at the coordinator itself.
            int clientTag = Framework.PrepareClient(Endpoint, null);
            if (clientTag == -1)
            {
                Console.Error.WriteLine(
                    $"[FATAL] Framework.PrepareClient returned -1 " +
                    $"for {Endpoint}.");
                return 1;
            }

            int done = Framework.PrepareDone();
            if (done != 1 && !LingoFuseStatus.CheckMainThread())
            {
                Console.Error.WriteLine(
                    $"[FATAL] Framework.PrepareDone returned {done} and " +
                    "the main thread is not running.");
                return 1;
            }

            started = true;

            Console.WriteLine(
                $"IPC service '{Endpoint}' is running. " +
                "Press Enter to exit...");
            Console.ReadLine();

            Console.WriteLine("Shutting down...");
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
        finally
        {
            // Full shutdown on every exit path. All three operations are
            // idempotent, so calling them here is safe even when the
            // startup sequence failed partway through.
            if (started)
            {
                try { NetworkEvents.Clear(); } catch { }
                try { Framework.ExitMainThread(); } catch { }
                try { Framework.Shutdown(); } catch { }
            }
        }

        Console.WriteLine("Bye.");
        return 0;
    }
}