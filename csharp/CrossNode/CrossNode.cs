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
//  The wire format matches the C++ CrossNode.cpp exactly:
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
//  to already exist when Connect() is called.
//
//  ---------------------------------------------------------------------------
//  CLEANUP
//  ---------------------------------------------------------------------------
//  The node's Dispose() only detaches the App from the framework; it
//  does NOT stop the simulated main thread or unload the native
//  library. To perform a full process-wide shutdown
//  (LF_ExitMainThread -> LF_Shutdown), Main() calls node.FullCleanup()
//  in a finally block, so the framework is released on every exit
//  path, including early returns and exceptions.
//
//  Output interleaving:
//      Callbacks are invoked on the library's background worker threads.
//      All callback output is routed through Log() / LogError(), which
//      format the whole line and emit it under a process-wide lock. This
//      keeps each line intact; the order between lines is still arbitrary.
// =============================================================================

using System;

using LingoFuse;
using LingoFuse.Core;
using LingoFuse.Host;

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

        LingoFuseNode? node = null;

        try
        {
            node = new LingoFuseNode(
                appName: AppName,
                endpoint: Endpoint,
                description: "C# worker node (ABI wire format)");

            // ------------------------------------------------------------------
            // Register "add": (int32, int32) -> int32
            //
            // The ABI overload accepts a raw DataHandle handler. The handler
            // reads two int32 values from the input and writes one int32 to
            // the output. No JSON serialization is performed.
            // ------------------------------------------------------------------
            if (!node.App.Expose(
                "add",
                "add(int a, int b) -> int",
                (DataHandle input, DataHandle output) =>
                {
                    int a = input.ReadInt32();
                    int b = input.ReadInt32();
                    int c = a + b;

                    Log($"[Node] add({a}, {b}) = {c}");

                    output.WriteInt32(c);
                }))
            {
                Console.Error.WriteLine("[FATAL] Failed to register API 'add'.");
                return 1;
            }

            // ------------------------------------------------------------------
            // Register "inv_seri": (uint8, uint16, uint32, uint64,
            //                       string, float)
            //                      -> reversed sequence
            //
            // The reply is emitted in the reverse field order, using the
            // exact same scalar types. The string is written with a NUL
            // terminator via WriteString.
            // ------------------------------------------------------------------
            if (!node.App.Expose(
                "inv_seri",
                "inv_seri() -> reversed typed sequence",
                (DataHandle input, DataHandle output) =>
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

            Console.WriteLine(
                "[Node] Registered APIs 'add' and 'inv_seri' " +
                $"under application '{AppName}'.");

            // ------------------------------------------------------------------
            // Connect the node to the mesh.
            //
            // overlapConnection: true allows the same process to host more
            // than one client on the same endpoint, and matches the C++
            // demo's tolerance for repeated runs inside the same process.
            // ------------------------------------------------------------------
            node.Connect(overlapConnection: true);

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
            // FullCleanup performs the LF-CLEAN-001 sequence in the
            // required order:
            //
            //     LF_ExitMainThread  ->  (App detach)  ->  LF_Shutdown
            //
            // Dispose() alone would only detach the App; it would leave
            // the simulated main thread running and the native library
            // loaded. Since this demo owns the only LingoFuseNode in
            // the process, FullCleanup is the correct exit path.
            //
            // FullCleanup is idempotent; calling it on a disposed node
            // is a no-op.
            node?.FullCleanup();
        }

        Console.WriteLine("[Node] Bye.");
        return 0;
    }
}