// =============================================================================
//  CrossNode.cs
// -----------------------------------------------------------------------------
//  Worker node that registers the "add" and "inv_seri" Call APIs.
//
//  It connects to the IPC endpoint "ipc:cross" as a client and exposes
//  the application "demo" to the C4 service mesh. Multiple instances
//  (in different processes) may be launched; the mesh automatically
//  load-balances incoming calls across all live workers.
//
//  Registered APIs:
//
//    add       (int32 a, int32 b)                       -> int32
//        Reads two 32-bit signed integers, returns their sum.
//
//    inv_seri  (uint8, uint16, uint32, uint64,
//               string, float)                          -> same types reversed
//        Reads a fixed sequence of typed values and echoes them back in
//        the reverse order. Used to exercise the binary wire format.
//
//  ---------------------------------------------------------------------------
//  WIRE FORMAT (byte-for-byte identical to C++ / Pascal / Python)
//  ---------------------------------------------------------------------------
//  Both APIs use the raw ABI channel. No JSON is involved at any point.
//
//    add:
//        input  : int32 (little-endian) + int32 (little-endian)
//        output : int32 (little-endian)
//
//    inv_seri:
//        input  : uint8 + uint16 + uint32 + uint64 + string(NUL) + float
//        output : float + string(NUL) + uint64 + uint32 + uint16 + uint8
//
//  All integer types are little-endian. The string is UTF-8, NUL-
//  terminated. This is the exact sequence the C++ / Pascal / Python
//  bindings read and write, so a C# CrossNode is directly interoperable
//  with the C++ CrossCall client and vice versa.
//
//  ---------------------------------------------------------------------------
//  STARTUP ORDER
//  ---------------------------------------------------------------------------
//  Start CrossService first. The node expects the coordinator endpoint
//  to already exist when PrepareClient is called.
//
//  The two APIs MUST be registered before PrepareClient so that the
//  Init_App_Info broadcast carries the complete API list.
//
//  ---------------------------------------------------------------------------
//  CLEANUP
//  ---------------------------------------------------------------------------
//  The finally block performs the LF-CLEAN-001 sequence on every exit
//  path:
//
//      NetworkEvents.Clear -> ExitMainThread -> App.Dispose -> Shutdown
//
//  All operations are idempotent.
// =============================================================================

using System;

using LingoFuse;

namespace LingoFuse.Demo.CrossNode;

internal static class Program
{
    private const string Endpoint = "ipc:cross";
    private const string AppName = "demo";

    private static readonly object LogLock = new();

    private static void Log(string line)
    {
        lock (LogLock) { Console.WriteLine(line); }
    }

    public static int Main()
    {
        Console.WriteLine("=== Cross Node (Worker) ===");

        AppHandle? app = null;
        bool started = false;

        try
        {
            Framework.SetOption("Wait_Connection_ReadyOk", "True");
            Framework.SetOption("Overlap_Connection", "True");
            Framework.SetOption("Wait_Connection_Timeout", "10000");

            Framework.ResetPrepare();

            app = new AppHandle(
                AppName, "C# worker node (ABI wire format)");

            // ---------------------------------------------------------------
            // Register "add": (int32, int32) -> int32
            // ---------------------------------------------------------------
            if (!app.RegisterCall(
                "add",
                "add(int a, int b) -> int",
                (input, output) =>
                {
                    int a = input.ReadInt32();
                    int b = input.ReadInt32();
                    int c = a + b;

                    Log($"[Node] add({a}, {b}) = {c}");

                    output.WriteInt32(c);
                }))
            {
                Console.Error.WriteLine(
                    "[FATAL] Failed to register API 'add'.");
                return 1;
            }

            // ---------------------------------------------------------------
            // Register "inv_seri": (uint8, uint16, uint32, uint64,
            //                       string, float)
            //                      -> reversed sequence
            // ---------------------------------------------------------------
            if (!app.RegisterCall(
                "inv_seri",
                "inv_seri() -> reversed typed sequence",
                (input, output) =>
                {
                    // Read in the C++ order.
                    byte b = input.ReadUInt8();
                    ushort w = input.ReadUInt16();
                    uint c = input.ReadUInt32();
                    ulong u64 = input.ReadUInt64();
                    string s = input.ReadString();
                    float f = input.ReadSingle();

                    Log($"[Node] inv_seri received: " +
                        $"[{b}, {w}, {c}, {u64}, \"{s}\", {f}]");

                    // Reply in reverse order.
                    output.WriteSingle(f);
                    output.WriteString(s);
                    output.WriteUInt64(u64);
                    output.WriteUInt32(c);
                    output.WriteUInt16(w);
                    output.WriteUInt8(b);

                    Log($"[Node] inv_seri replied: " +
                        $"[{f}, \"{s}\", {u64}, {c}, {w}, {b}]");
                }))
            {
                Console.Error.WriteLine(
                    "[FATAL] Failed to register API 'inv_seri'.");
                return 1;
            }

            // ---------------------------------------------------------------
            // Connect the node to the mesh.
            //
            // Registration is complete at this point: the Init_App_Info
            // broadcast will carry both "add" and "inv_seri".
            // ---------------------------------------------------------------
            int clientTag = Framework.PrepareClient(Endpoint, app);
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
                "[Node] Registered APIs 'add' and 'inv_seri' " +
                $"under application '{AppName}'.");
            Console.WriteLine("[Node] Online. Press Enter to exit...");
            Console.ReadLine();

            Console.WriteLine("[Node] Shutting down...");
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
            // LF-CLEAN-001 sequence on every exit path.
            if (started)
            {
                try { NetworkEvents.Clear(); } catch { }
                try { Framework.ExitMainThread(); } catch { }
                try { app?.Dispose(); } catch { }
                try { Framework.Shutdown(); } catch { }
            }
            else
            {
                // Startup failed partway through: release whatever
                // managed resources exist, but do not touch the
                // process-wide framework.
                try { app?.Dispose(); } catch { }
            }
        }

        Console.WriteLine("[Node] Bye.");
        return 0;
    }
}