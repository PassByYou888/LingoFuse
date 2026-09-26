// =============================================================================
//  CrossCall.cs
// -----------------------------------------------------------------------------
//  Concurrent client / load tester for the "ipc:cross" endpoint.
//
//  It connects as a pure consumer (no application attached) and spawns
//  several worker threads. Each thread repeatedly invokes one of two remote
//  APIs on the "demo" application at random:
//
//      add       (int32 a, int32 b)                       -> int32
//      inv_seri  (uint8, uint16, uint32, uint64,
//                 string, float)                          -> reversed types
//
//  The test runs for a fixed duration and then shuts down cleanly. Multiple
//  instances of this program may be launched concurrently to drive even
//  higher load against the mesh.
//
//  ---------------------------------------------------------------------------
//  WIRE FORMAT (byte-for-byte identical to C++ / Pascal / Python)
//  ---------------------------------------------------------------------------
//  Both APIs use the raw ABI channel. No JSON is involved at any point.
//  Every byte written into a request DataHandle matches what the C++
//  CrossCall.cpp produces for the same logical call, so a C# CrossCall
//  client can invoke a C++ / Pascal / Python CrossNode server and vice
//  versa.
//
//  Log sampling:
//      With WorkerThreads = 32 and PauseMs = 1, the process issues many
//      thousands of calls per second. Printing every call would make the
//      log I/O itself the bottleneck. Each worker therefore only logs one
//      out of every LogEveryNthCall iterations; the aggregate counters
//      remain exact.
//
//  ---------------------------------------------------------------------------
//  CLEANUP
//  ---------------------------------------------------------------------------
//  The client's Dispose() only detaches the client from the framework;
//  it does NOT stop the simulated main thread or unload the native
//  library. To perform a full process-wide shutdown
//  (LF_ExitMainThread -> LF_Shutdown), Main() calls client.FullCleanup()
//  in a finally block, so the framework is released on every exit
//  path, including early returns and exceptions.
//
//  FullCleanup is idempotent; calling it on a disposed client is a
//  no-op.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

using LingoFuse;
using LingoFuse.Core;
using LingoFuse.Host;

namespace LingoFuse.Demo.CrossCall;

internal static class Program
{
    // ------------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------------

    private const string TargetApp = "demo";
    private const string Endpoint = "ipc:cross";

    private const int WorkerThreads = 32;
    private const int TestSeconds = 10;
    private const int CallTimeoutMs = 1000;
    private const int PauseMs = 1;
    private const long LogEveryNthCall = 5000;

    private const int NumberMin = 1;
    private const int NumberMax = 1000;

    // ------------------------------------------------------------------------
    // Thread-safe line output
    // ------------------------------------------------------------------------

    private static readonly object LogLock = new();

    private static void Log(string line)
    {
        lock (LogLock) { Console.WriteLine(line); }
    }

    // ------------------------------------------------------------------------
    // Aggregate statistics
    // ------------------------------------------------------------------------

    private sealed class Stats
    {
        public long TotalCalls;
        public long SuccessCalls;
        public long FailedCalls;
        public long AddCalls;
        public long InvSeriCalls;
    }

    // ------------------------------------------------------------------------
    // main
    // ------------------------------------------------------------------------

    public static int Main()
    {
        Console.WriteLine("=== Cross Call (Client) ===");

        LingoFuseClient? client = null;

        try
        {
            client = new LingoFuseClient(Endpoint, CallTimeoutMs);
            client.Connect(overlapConnection: true);

            Console.WriteLine(
                $"[Call] Connected to {Endpoint}. " +
                $"Starting {TestSeconds}-second load test with " +
                $"{WorkerThreads} threads...");

            var stats = new Stats();
            var stop = new ManualResetEventSlim(false);
            var threads = new List<Thread>(WorkerThreads);

            var sw = Stopwatch.StartNew();

            for (int i = 0; i < WorkerThreads; i++)
            {
                int index = i;
                var t = new Thread(() => WorkerBody(index, stop, stats, client))
                {
                    IsBackground = true,
                    Name = $"cross-call-{index}",
                };
                threads.Add(t);
                t.Start();
            }

            Thread.Sleep(TimeSpan.FromSeconds(TestSeconds));
            stop.Set();

            foreach (var t in threads) t.Join();
            sw.Stop();

            double elapsedS = sw.Elapsed.TotalSeconds;

            long total, success, failed, addCalls, invSeriCalls;
            lock (stats)
            {
                total = stats.TotalCalls;
                success = stats.SuccessCalls;
                failed = stats.FailedCalls;
                addCalls = stats.AddCalls;
                invSeriCalls = stats.InvSeriCalls;
            }

            double successRate = total > 0
                ? 100.0 * success / total
                : 0.0;
            double throughput = elapsedS > 0
                ? total / elapsedS
                : 0.0;
            double successThroughput = elapsedS > 0
                ? success / elapsedS
                : 0.0;

            Console.WriteLine();
            Console.WriteLine("[Call] Load test summary");
            Console.WriteLine($"         duration          : {elapsedS:F3} s");
            Console.WriteLine($"         total calls       : {total}");
            Console.WriteLine(
                $"         success           : {success} ({successRate:F2} %)");
            Console.WriteLine($"         failed            : {failed}");
            Console.WriteLine($"         add calls         : {addCalls}");
            Console.WriteLine($"         inv_seri calls    : {invSeriCalls}");
            Console.WriteLine(
                $"         throughput        : {throughput:F2} calls/s");
            Console.WriteLine(
                $"         success throughput: {successThroughput:F2} calls/s");

            Console.WriteLine("[Call] Press Enter to exit...");
            Console.ReadLine();
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
            //     LF_ExitMainThread  ->  (client detach)  ->  LF_Shutdown
            //
            // Dispose() alone would only detach the client; it would
            // leave the simulated main thread running and the native
            // library loaded. Since this demo owns the only
            // LingoFuseClient in the process, FullCleanup is the
            // correct exit path.
            //
            // FullCleanup is idempotent; calling it on a disposed
            // client is a no-op.
            client?.FullCleanup();
        }

        Console.WriteLine("[Call] Bye.");
        return 0;
    }

    // ------------------------------------------------------------------------
    // Worker thread body
    // ------------------------------------------------------------------------

    private static void WorkerBody(
        int index,
        ManualResetEventSlim stop,
        Stats stats,
        LingoFuseClient client)
    {
        var rng = new Random(unchecked(
            Environment.TickCount * 397 + index));

        long iter = 0;
        while (!stop.IsSet)
        {
            iter++;
            bool doLog = (iter % LogEveryNthCall == 0);

            if (rng.Next(2) == 0)
            {
                // ---- add ----
                int a = rng.Next(NumberMin, NumberMax + 1);
                int b = rng.Next(NumberMin, NumberMax + 1);

                bool ok = RemoteAdd(client, a, b, out int sum);

                lock (stats)
                {
                    stats.TotalCalls++;
                    stats.AddCalls++;
                    if (ok) stats.SuccessCalls++;
                    else stats.FailedCalls++;
                }

                if (doLog)
                {
                    if (ok)
                    {
                        Log($"[Call {index}] add({a}, {b}) = {sum}");
                    }
                    else
                    {
                        Log($"[Call {index}] add({a}, {b}) timed out or failed.");
                    }
                }
            }
            else
            {
                // ---- inv_seri ----
                bool ok = RemoteInvSeri(client, out string? replyText);

                lock (stats)
                {
                    stats.TotalCalls++;
                    stats.InvSeriCalls++;
                    if (ok) stats.SuccessCalls++;
                    else stats.FailedCalls++;
                }

                if (doLog)
                {
                    if (ok && replyText is not null)
                    {
                        Log($"[Call {index}] {replyText}");
                    }
                    else
                    {
                        Log($"[Call {index}] inv_seri timed out or failed.");
                    }
                }
            }

            if (PauseMs > 0)
            {
                Thread.Sleep(PauseMs);
            }
        }
    }

    // ------------------------------------------------------------------------
    // Remote call wrappers — raw ABI
    // ------------------------------------------------------------------------

    /// <summary>
    /// Invoke the remote "add" API via the ABI channel.
    /// </summary>
    /// <remarks>
    /// The request is two little-endian int32 values; the reply is one
    /// little-endian int32. This is the exact byte sequence the C++
    /// CrossCall.cpp client writes and reads.
    /// </remarks>
    /// <returns>
    /// true on success; the sum is returned in <paramref name="sum"/>.
    /// false on timeout, unreachable target, or an empty reply.
    /// </returns>
    private static bool RemoteAdd(
        LingoFuseClient client, int a, int b, out int sum)
    {
        sum = 0;
        try
        {
            using var param = new DataHandle("add");
            param.WriteInt32(a);
            param.WriteInt32(b);

            if (!client.TryCallBinary(
                    TargetApp, param, (ulong)CallTimeoutMs, out var response))
            {
                return false;
            }

            using (response)
            {
                if (response is null || response.Size < 4)
                {
                    return false;
                }
                sum = response.ReadInt32();
                return true;
            }
        }
        catch (LingoFuseCallException)
        {
            return false;
        }
        catch (LingoFuseException)
        {
            return false;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Invoke the remote "inv_seri" API via the ABI channel.
    /// </summary>
    /// <remarks>
    /// The request is the exact byte sequence
    /// (uint8, uint16, uint32, uint64, string(NUL), float)
    /// that the C++ CrossCall.cpp client writes. The reply is the same
    /// sequence in reverse field order.
    /// </remarks>
    /// <returns>
    /// true on success; a human-readable description of the reply is
    /// returned in <paramref name="replyText"/>.
    /// </returns>
    private static bool RemoteInvSeri(
        LingoFuseClient client, out string? replyText)
    {
        replyText = null;
        try
        {
            // Same constants as the C++ counterpart.
            const byte b = 200;
            const ushort w = 0x10;
            const uint c = 0x2F;
            const ulong u64 = 0x3F;
            const string s = "hello world";
            const float f = 3.14f;

            using var param = new DataHandle("inv_seri");
            param.WriteUInt8(b);
            param.WriteUInt16(w);
            param.WriteUInt32(c);
            param.WriteUInt64(u64);
            param.WriteString(s);
            param.WriteSingle(f);

            if (!client.TryCallBinary(
                    TargetApp, param, (ulong)CallTimeoutMs, out var response))
            {
                return false;
            }

            using (response)
            {
                if (response is null)
                {
                    return false;
                }

                // Read the reply fields in the reverse order the node
                // wrote them.
                float rf = response.ReadSingle();
                string rs = response.ReadString();
                ulong ru64 = response.ReadUInt64();
                uint rc = response.ReadUInt32();
                ushort rw = response.ReadUInt16();
                byte rb = response.ReadUInt8();

                replyText =
                    $"reply: [{rb}, {rw}, {rc}, {ru64}, \"{rs}\", {rf}]" +
                    $"  original: [{b}, {w}, {c}, {u64}, \"{s}\", {f}]";
                return true;
            }
        }
        catch (LingoFuseCallException)
        {
            return false;
        }
        catch (LingoFuseException)
        {
            return false;
        }
        catch (Exception)
        {
            return false;
        }
    }
}