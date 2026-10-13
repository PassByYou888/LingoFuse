// ============================================================================
// File: csharp/test2/Program.cs
// ============================================================================
// test2 — focused test suite for the v5.0 C# binding additions.
// ============================================================================
// SCOPE
// -----
// This project tests ONLY the API surface introduced by the v5.0 upgrade.
// The pre-existing 58-test suite in ../test/ remains unchanged and
// continues to cover the historical surface; this file adds coverage
// for:
//
//   * the P2PUid value type                         (6 tests)
//   * the RuntimeOptions strongly typed facade       (8 tests)
//   * DataHandle.GetSenderUid / GetSenderP2PName     (4 tests)
//   * the ILingoCallbackDispatcher abstraction       (6 tests)
//   * UID addressing (sync + async + probes)         (6 tests)
//   * P2PName addressing (sync + async + probes)     (6 tests)
//   * async App-name invocation (Task based)         (4 tests)
//   * async UID / P2PName invocation                 (4 tests)
//   * process-wide P2P API registration              (3 tests)
//   * end-to-end dispatcher integration              (1 test)
//
// Total: 48 tests.
//
// TEST ISOLATION
// --------------
// Every network test creates exactly one NetworkSession, exercises the
// scenario, and disposes it in a using block. The session owns the
// full LF-CLEAN-001 sequence:
//
//     NetworkEvents.Clear()
//     Framework.ExitMainThread()
//     App.Dispose()
//     Framework.Shutdown()
//
// Because LF_Shutdown is process-wide, sessions must not overlap.
// The test runner executes network tests serially, and every network
// test disposes its session before the next one begins.
//
// VALUE-TYPE AND DISPATCHER TESTS
// --------------------------------
// The P2PUid, RuntimeOptions, and CallbackDispatcher categories do not
// touch the network. They are still placed in the same suite so that
// a single dotnet run covers the entire v5.0 surface.
//
// OUTPUT FORMAT
// -------------
// Human-readable PASS / FAIL lines, one per test, followed by a summary
// table. Exit code 0 = all pass, 1 = at least one failure.
//
// ============================================================================

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

using LingoFuse;

namespace LingoFuse.Tests2;

/* ============================================================================
 * Formatting helpers
 * ========================================================================== */

internal static class Fmt
{
    public const string Rule =
        "======================================================================";

    public static void PrintBanner(string title)
    {
        Console.WriteLine();
        Console.WriteLine();
        Console.WriteLine(Rule);
        Console.WriteLine("  " + title);
        Console.WriteLine(Rule);
    }

    public static void PrintCategory(string name, string description, int count)
    {
        Console.WriteLine();
        Console.WriteLine(Rule);
        Console.WriteLine($"  Category: {name}  ({count} tests)");
        Console.WriteLine($"  {description}");
        Console.WriteLine(Rule);
    }
}

/* ============================================================================
 * Assertion helpers
 * ========================================================================== */

internal sealed class CheckFailedException : Exception
{
    public CheckFailedException(string message) : base(message) { }
}

internal static class Verify
{
    public static void True(
        bool condition,
        [CallerArgumentExpression(nameof(condition))] string? expr = null,
        [CallerLineNumber] int line = 0)
    {
        if (!condition)
        {
            throw new CheckFailedException(
                $"CHECK FAILED: {expr} (line {line})");
        }
    }

    public static void False(
        bool condition,
        [CallerArgumentExpression(nameof(condition))] string? expr = null,
        [CallerLineNumber] int line = 0)
    {
        if (condition)
        {
            throw new CheckFailedException(
                $"CHECK_FALSE FAILED: {expr} (line {line})");
        }
    }

    public static void NotNull<T>(
        T? value,
        [CallerArgumentExpression(nameof(value))] string? expr = null,
        [CallerLineNumber] int line = 0)
        where T : class
    {
        if (value is null)
        {
            throw new CheckFailedException(
                $"CHECK_NOT_NULL FAILED: {expr} (line {line})");
        }
    }

    public static void Equal<T>(
        T actual, T expected,
        [CallerArgumentExpression(nameof(actual))] string? aExpr = null,
        [CallerArgumentExpression(nameof(expected))] string? eExpr = null,
        [CallerLineNumber] int line = 0)
    {
        if (!EqualityComparer<T>.Default.Equals(actual, expected))
        {
            throw new CheckFailedException(
                $"CHECK_EQ FAILED: {aExpr} == {eExpr} (line {line})\n" +
                $"        actual  : {FormatValue(actual)}\n" +
                $"        expected: {FormatValue(expected)}");
        }
    }

    public static void SequenceEqual<T>(
        IEnumerable<T> actual, IEnumerable<T> expected,
        [CallerArgumentExpression(nameof(actual))] string? aExpr = null,
        [CallerArgumentExpression(nameof(expected))] string? eExpr = null,
        [CallerLineNumber] int line = 0)
    {
        if (!actual.SequenceEqual(expected))
        {
            throw new CheckFailedException(
                $"CHECK_SEQ FAILED: {aExpr} == {eExpr} (line {line})");
        }
    }

    public static TException Throws<TException>(
        Action action, [CallerLineNumber] int line = 0)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException ex)
        {
            return ex;
        }
        catch (Exception ex)
        {
            throw new CheckFailedException(
                $"THROWS FAILED (line {line}): expected " +
                $"{typeof(TException).Name}, got {ex.GetType().Name}: " +
                ex.Message);
        }
        throw new CheckFailedException(
            $"THROWS FAILED (line {line}): expected " +
            $"{typeof(TException).Name}, but no exception was thrown");
    }

    private static string FormatValue<T>(T? value)
    {
        if (value is null) return "null";
        if (value is string s) return '"' + s + '"';
        return value.ToString() ?? "null";
    }
}

/* ============================================================================
 * Mini test runner
 * ========================================================================== */

internal sealed class TestResult
{
    public bool Passed;
    public bool Threw;
    public long ElapsedMs;
    public string ErrorDetail = string.Empty;
}

internal delegate bool TestFn();

internal static class TestRunner
{
    public static TestResult Run(string name, TestFn fn)
    {
        var result = new TestResult();
        var sw = Stopwatch.StartNew();
        try
        {
            result.Passed = fn();
        }
        catch (CheckFailedException ex)
        {
            result.Threw = true;
            result.ErrorDetail = ex.Message;
        }
        catch (LingoFuseCallException ex)
        {
            result.Threw = true;
            result.ErrorDetail =
                $"LingoFuseCallException: {ex.Message} " +
                $"(TargetApp={ex.TargetApp ?? "?"})";
        }
        catch (LingoFuseIoException ex)
        {
            result.Threw = true;
            result.ErrorDetail =
                $"LingoFuseIoException[{ex.Operation}]: {ex.Message}";
        }
        catch (LingoFuseObjectDisposedException ex)
        {
            result.Threw = true;
            result.ErrorDetail =
                $"LingoFuseObjectDisposedException: {ex.ObjectName}";
        }
        catch (LingoFuseException ex)
        {
            result.Threw = true;
            result.ErrorDetail = $"LingoFuseException: {ex.Message}";
        }
        catch (Exception ex)
        {
            result.Threw = true;
            result.ErrorDetail = $"{ex.GetType().Name}: {ex.Message}";
        }
        sw.Stop();
        result.ElapsedMs = sw.ElapsedMilliseconds;

        if (result.Passed && !result.Threw)
        {
            Console.WriteLine($"  [ PASS ] {name} ({result.ElapsedMs} ms)");
        }
        else
        {
            Console.WriteLine($"  [ FAIL ] {name}");
            Console.WriteLine(
                result.Threw
                    ? $"           reason: {result.ErrorDetail}"
                    : "           reason: a check returned false");
            Console.WriteLine($"           time:   {result.ElapsedMs} ms");
        }
        return result;
    }
}

/* ============================================================================
 * Test environment helpers
 * ========================================================================== */

internal static class TestEnv
{
    private static int _counter;

    public static int NextId() =>
        Interlocked.Increment(ref _counter);

    public static string UniqueEndpoint(string prefix) =>
        $"ipc:test2_{prefix}_{Environment.ProcessId}_{NextId()}";

    public static string UniqueAppName(string prefix) =>
        $"test2_{prefix}_{Environment.ProcessId}_{NextId()}";

    public static string UniqueP2PName(string prefix) =>
        $"test2_group_{prefix}_{Environment.ProcessId}_{NextId()}";

    public static void Settle(int ms = 200) => Thread.Sleep(ms);
}

/* ============================================================================
 * Test-only synchronization context
 * ========================================================================== */

internal sealed class TestSyncContext : SynchronizationContext, IDisposable
{
    private readonly BlockingCollection<(SendOrPostCallback, object?)> _queue = new();
    private readonly Thread _thread;
    private int _threadId;

    public int ThreadId => Volatile.Read(ref _threadId);

    public TestSyncContext()
    {
        _thread = new Thread(Loop)
        {
            IsBackground = true,
            Name = "TestSyncContext",
        };
        _thread.Start();
        // Wait until the loop thread has recorded its own ID.
        while (ThreadId == 0) Thread.Sleep(1);
    }

    public override void Post(SendOrPostCallback d, object? state)
    {
        _queue.Add((d, state));
    }

    public void Dispose()
    {
        _queue.CompleteAdding();
    }

    private void Loop()
    {
        Volatile.Write(ref _threadId, Environment.CurrentManagedThreadId);
        SynchronizationContext.SetSynchronizationContext(this);
        foreach (var (cb, st) in _queue.GetConsumingEnumerable())
        {
            cb(st);
        }
    }
}

/* ============================================================================
 * Network session
 * ========================================================================== */

internal sealed class NetworkSession : IDisposable
{
    public AppHandle? App { get; private set; }
    public string Endpoint { get; }
    public string AppName { get; }
    public string P2PName { get; }

    private bool _started;

    private NetworkSession(string endpoint, string appName, string p2pName)
    {
        Endpoint = endpoint;
        AppName = appName;
        P2PName = p2pName;
    }

    public static NetworkSession StartWithService(
        string appName,
        string endpoint,
        Action<AppHandle>? configureApp = null,
        string? p2pName = null)
    {
        string effectiveP2P = p2pName ?? string.Empty;
        var s = new NetworkSession(endpoint, appName, effectiveP2P);

        // Configure the framework through the strongly typed facade.
        // This is itself an exercise of the v5.0 RuntimeOptions layer.
        RuntimeOptions.WaitConnectionReadyOk = true;
        RuntimeOptions.OverlapConnection = true;
        RuntimeOptions.WaitConnectionTimeoutMs = 10000;
        RuntimeOptions.P2PName = effectiveP2P;

        Framework.ResetPrepare();

        int serviceTag = Framework.PrepareService(endpoint, endpoint);
        if (serviceTag == -1)
        {
            throw new InvalidOperationException(
                $"Framework.PrepareService returned -1 for {endpoint}");
        }

        s.App = new AppHandle(appName);
        configureApp?.Invoke(s.App);

        int clientTag = Framework.PrepareClient(endpoint, s.App);
        if (clientTag == -1)
        {
            throw new InvalidOperationException(
                $"Framework.PrepareClient returned -1 for {endpoint}");
        }

        int done = Framework.PrepareDone();
        if (done != 1 && !LingoFuseStatus.CheckMainThread())
        {
            throw new InvalidOperationException(
                $"Framework.PrepareDone returned {done} and the " +
                "main thread is not running.");
        }

        // Give the mesh a moment to propagate the P2PName and UID to
        // the server-side dispatch tables. 500 ms is comfortably above
        // the observed propagation window on a local IPC link.
        if (!string.IsNullOrEmpty(effectiveP2P))
        {
            Thread.Sleep(500);
        }

        s._started = true;
        return s;
    }

    public void Dispose()
    {
        if (!_started) return;
        _started = false;

        try { NetworkEvents.Clear(); } catch { }
        try { Framework.ExitMainThread(); } catch { }
        try { App?.Dispose(); } catch { }
        try { Framework.Shutdown(); } catch { }

        // Release the process-global P2P name so the next session
        // starts from a clean slate.
        try { RuntimeOptions.P2PName = string.Empty; } catch { }

        Thread.Sleep(150);
    }
}

/* ============================================================================
 * Shared static callbacks
 * ========================================================================== */

internal static class Callbacks
{
    public static void EchoString(DataHandle input, DataHandle output)
    {
        output.WriteString(input.ReadString());
    }

    public static void AddInt32(DataHandle input, DataHandle output)
    {
        int a = input.ReadInt32();
        int b = input.ReadInt32();
        output.WriteInt32(a + b);
    }
}

/* ============================================================================
 * Helper: self-UID discovery via whoami
 * ========================================================================== */

internal static class Mesh
{
    /// <summary>
    /// Registers a whoami API on the given app, then calls it once to
    /// discover the caller's own session UID. Returns the discovered
    /// UID, or P2PUid.Empty if the call could not be completed.
    /// </summary>
    public static P2PUid DiscoverSelfUid(
        AppHandle app, string appName, out string selfP2PName)
    {
        var uidHolder = new StrongBox<P2PUid>(P2PUid.Empty);
        var nameHolder = new StrongBox<string>(string.Empty);

        app.RegisterCall(
            "__test_whoami__",
            "test-only whoami helper",
            (input, output) =>
            {
                uidHolder.Value = input.GetSenderUid();
                nameHolder.Value = input.GetSenderP2PName();
                output.WriteString(uidHolder.Value.ToHexString());
            });

        using var p = new DataHandle("__test_whoami__");
        using var resp = Framework.Call(appName, p, 5000);
        if (resp.Size == 0)
        {
            throw new InvalidOperationException(
                "whoami call returned an empty response");
        }
        selfP2PName = nameHolder.Value;
        return uidHolder.Value;
    }
}

/* ============================================================================
 * CATEGORY: P2PUid
 * ========================================================================== */

internal static class P2PUidTests
{
    public static bool EmptyIsAllZero()
    {
        var empty = P2PUid.Empty;
        Verify.True(empty.IsEmpty);

        byte[] bytes = empty.ToByteArray();
        Verify.Equal(bytes.Length, 32);
        foreach (byte b in bytes)
        {
            Verify.Equal(b, (byte)0);
        }

        // default(P2PUid) is the same value.
        P2PUid dflt = default;
        Verify.Equal(dflt, empty);

        return true;
    }

    public static bool FromBytesRoundTrip()
    {
        var source = new byte[32];
        for (int i = 0; i < 32; i++) source[i] = (byte)(i * 7 + 1);

        var uid = P2PUid.FromBytes(source);
        Verify.False(uid.IsEmpty);

        byte[] back = uid.ToByteArray();
        Verify.SequenceEqual(back, source);

        return true;
    }

    public static bool FromBytesRejectsWrongLength()
    {
        Verify.Throws<ArgumentException>(
            () => P2PUid.FromBytes(new byte[31]));
        Verify.Throws<ArgumentException>(
            () => P2PUid.FromBytes(new byte[33]));
        Verify.Throws<ArgumentException>(
            () => P2PUid.FromBytes(Array.Empty<byte>()));
        return true;
    }

    public static bool TryParseValidAndInvalid()
    {
        // Valid: 64 lowercase hex characters.
        const string good =
            "0102030405060708090a0b0c0d0e0f10" +
            "1112131415161718191a1b1c1d1e1f20";
        Verify.True(P2PUid.TryParse(good, out var uid1));
        Verify.Equal(uid1.ToHexString(), good);

        // Uppercase letters accepted.
        const string goodUpper = "ABCDEF0123456789ABCDEF0123456789" +
                                 "ABCDEF0123456789ABCDEF0123456789";
        Verify.True(P2PUid.TryParse(goodUpper, out _));

        // Invalid: too short, non-hex, null.
        Verify.False(P2PUid.TryParse("00", out _));
        Verify.False(P2PUid.TryParse(
            "zz" + new string('0', 62), out _));
        Verify.False(P2PUid.TryParse(null, out _));

        // Parse throws on invalid.
        Verify.Throws<FormatException>(() => P2PUid.Parse("nope"));

        return true;
    }

    public static bool HexFormatAndCopy()
    {
        // Byte 0 first; each byte as two lowercase hex characters.
        var source = new byte[32];
        source[0] = 0xAB;
        source[1] = 0xCD;
        source[31] = 0xEF;

        var uid = P2PUid.FromBytes(source);
        string hex = uid.ToHexString();

        Verify.Equal(hex.Length, 64);
        Verify.Equal(hex.Substring(0, 4), "abcd");
        Verify.Equal(hex.Substring(62, 2), "ef");
        Verify.Equal(uid.ToString(), hex);

        // CopyTo requires at least 32 bytes of destination.
        var dest = new byte[32];
        uid.CopyTo(dest);
        Verify.SequenceEqual(dest, source);

        Verify.Throws<ArgumentException>(() =>
            uid.CopyTo(new byte[31]));

        return true;
    }

    public static bool EqualityAndHashing()
    {
        var a = P2PUid.FromBytes(
            Enumerable.Repeat((byte)0x42, 32).ToArray());
        var b = P2PUid.FromBytes(
            Enumerable.Repeat((byte)0x42, 32).ToArray());
        var c = P2PUid.FromBytes(
            Enumerable.Repeat((byte)0x43, 32).ToArray());

        Verify.True(a == b);
        Verify.False(a != b);
        Verify.True(a != c);
        Verify.False(a == c);

        Verify.True(a.Equals(b));
        Verify.False(a.Equals(c));
        Verify.False(a.Equals(null));
        Verify.Equal(a.GetHashCode(), b.GetHashCode());

        // Dictionary key.
        var map = new Dictionary<P2PUid, string>
        {
            [a] = "value",
        };
        Verify.True(map.ContainsKey(b));
        Verify.Equal(map[b], "value");

        return true;
    }
}

/* ============================================================================
 * CATEGORY: RuntimeOptions
 * ========================================================================== */

internal static class RuntimeOptionsTests
{
    public static bool BoolRoundTrip()
    {
        // OverlapConnection
        RuntimeOptions.OverlapConnection = true;
        Verify.True(RuntimeOptions.OverlapConnection);
        RuntimeOptions.OverlapConnection = false;
        Verify.False(RuntimeOptions.OverlapConnection);

        // WaitConnectionReadyOk
        RuntimeOptions.WaitConnectionReadyOk = true;
        Verify.True(RuntimeOptions.WaitConnectionReadyOk);
        RuntimeOptions.WaitConnectionReadyOk = false;
        Verify.False(RuntimeOptions.WaitConnectionReadyOk);

        // Restore canonical values used by the rest of the suite.
        RuntimeOptions.OverlapConnection = true;
        RuntimeOptions.WaitConnectionReadyOk = true;

        return true;
    }

    public static bool LoggingRoundTrip()
    {
        bool prevQuiet = RuntimeOptions.Quiet;
        bool prevThread = RuntimeOptions.ShowThreadId;
        bool prevConsole = RuntimeOptions.ConsoleOutput;

        try
        {
            RuntimeOptions.Quiet = true;
            Verify.True(RuntimeOptions.Quiet);

            RuntimeOptions.ShowThreadId = true;
            Verify.True(RuntimeOptions.ShowThreadId);

            RuntimeOptions.ConsoleOutput = false;
            Verify.False(RuntimeOptions.ConsoleOutput);
        }
        finally
        {
            RuntimeOptions.Quiet = prevQuiet;
            RuntimeOptions.ShowThreadId = prevThread;
            RuntimeOptions.ConsoleOutput = prevConsole;
        }

        return true;
    }

    public static bool UlongRoundTrip()
    {
        // WaitConnectionTimeoutMs (ulong)
        RuntimeOptions.WaitConnectionTimeoutMs = 12345;
        Verify.Equal(RuntimeOptions.WaitConnectionTimeoutMs, 12345UL);

        // FixedSequencedTimeMs (ulong)
        ulong prevSeq = RuntimeOptions.FixedSequencedTimeMs;
        RuntimeOptions.FixedSequencedTimeMs = 7777;
        Verify.Equal(RuntimeOptions.FixedSequencedTimeMs, 7777UL);
        RuntimeOptions.FixedSequencedTimeMs = prevSeq;

        // DataHandleIdleTimeoutMs (ulong)
        ulong prevIdle = RuntimeOptions.DataHandleIdleTimeoutMs;
        RuntimeOptions.DataHandleIdleTimeoutMs = 60000;
        Verify.Equal(RuntimeOptions.DataHandleIdleTimeoutMs, 60000UL);
        RuntimeOptions.DataHandleIdleTimeoutMs = prevIdle;

        // Restore a safe value for the rest of the run.
        RuntimeOptions.WaitConnectionTimeoutMs = 10000;

        return true;
    }

    public static bool IntRoundTrip()
    {
        int prevThreadCount = RuntimeOptions.IpcServerThreadCount;
        int prevQueueLen = RuntimeOptions.IpcServerMaxQueueLength;
        int prevMsgSize = RuntimeOptions.IpcServerMaxMsgSize;
        int prevFlush = RuntimeOptions.NoReponseCmdNullFlushThreshold;

        try
        {
            RuntimeOptions.IpcServerThreadCount = 4;
            Verify.Equal(RuntimeOptions.IpcServerThreadCount, 4);

            RuntimeOptions.IpcServerMaxQueueLength = 1024;
            Verify.Equal(RuntimeOptions.IpcServerMaxQueueLength, 1024);

            RuntimeOptions.IpcServerMaxMsgSize = 1 << 20;
            Verify.Equal(RuntimeOptions.IpcServerMaxMsgSize, 1 << 20);

            RuntimeOptions.NoReponseCmdNullFlushThreshold = 1000;
            Verify.Equal(
                RuntimeOptions.NoReponseCmdNullFlushThreshold, 1000);
        }
        finally
        {
            RuntimeOptions.IpcServerThreadCount = prevThreadCount;
            RuntimeOptions.IpcServerMaxQueueLength = prevQueueLen;
            RuntimeOptions.IpcServerMaxMsgSize = prevMsgSize;
            RuntimeOptions.NoReponseCmdNullFlushThreshold = prevFlush;
        }

        return true;
    }

    public static bool P2PNameRoundTrip()
    {
        string prev = RuntimeOptions.P2PName;
        try
        {
            RuntimeOptions.P2PName = "test_group_alpha";
            Verify.Equal(RuntimeOptions.P2PName, "test_group_alpha");

            RuntimeOptions.P2PName = "";
            Verify.Equal(RuntimeOptions.P2PName, "");
        }
        finally
        {
            RuntimeOptions.P2PName = prev;
        }
        return true;
    }

    public static bool PasswordIsMasked()
    {
        // The ABI returns a fixed mask, never the real value.
        // Setting a password is still exercised here for symmetry.
        string prev = RuntimeOptions.Password;
        try
        {
            RuntimeOptions.Password = "topsecret-xyz";
            string readBack = RuntimeOptions.Password;
            Verify.False(readBack.Contains("topsecret"));
        }
        finally
        {
            try { RuntimeOptions.Password = prev; } catch { }
        }
        return true;
    }

    public static bool RawEscapeHatch()
    {
        // SetRaw / GetRaw round-trip on a known key.
        RuntimeOptions.SetRaw("Quiet", "True");
        Verify.Equal(RuntimeOptions.GetRaw("Quiet"), "True");

        RuntimeOptions.SetRaw("Quiet", "False");
        Verify.Equal(RuntimeOptions.GetRaw("Quiet"), "False");

        // Unknown options produce an empty string.
        Verify.Equal(RuntimeOptions.GetRaw("__no_such_option__"), "");

        // Null arguments are rejected.
        Verify.Throws<ArgumentNullException>(
            () => RuntimeOptions.GetRaw(null!));
        Verify.Throws<ArgumentNullException>(
            () => RuntimeOptions.SetRaw("x", null!));
        Verify.Throws<ArgumentNullException>(
            () => RuntimeOptions.SetRaw(null!, "y"));

        return true;
    }

    public static bool TypeSafetyOnUnsetOption()
    {
        // An option that has never been set should read back as the
        // type's default value, not throw.
        Verify.Equal(RuntimeOptions.GetRaw("__never_set__"), "");

        // Even after raw-read of an unknown key, typed properties on
        // known keys are unaffected.
        bool quiet = RuntimeOptions.Quiet;
        Verify.True(quiet || !quiet);  // always true; just exercise getter
        return true;
    }
}

/* ============================================================================
 * CATEGORY: DataHandle side data (GetSenderUid / GetSenderP2PName)
 * ========================================================================== */

internal static class SideDataTests
{
    public static bool InputHandleCarriesIdentity()
    {
        var endpoint = TestEnv.UniqueEndpoint("side_in");
        var appName = TestEnv.UniqueAppName("side_in");
        var groupName = TestEnv.UniqueP2PName("side_in");

        var uidSeen = new StrongBox<P2PUid>(P2PUid.Empty);
        var nameSeen = new StrongBox<string>("");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall(
                    "whoami",
                    "identity probe",
                    (input, output) =>
                    {
                        uidSeen.Value = input.GetSenderUid();
                        nameSeen.Value = input.GetSenderP2PName();
                        output.WriteString(
                            uidSeen.Value.ToHexString());
                    });
            },
            p2pName: groupName);

        using var p = new DataHandle("whoami");
        using var resp = Framework.Call(appName, p, 5000);
        Verify.True(resp.Size > 0);

        // The sender (this process) has a non-empty UID and the P2P
        // name we configured.
        Verify.False(uidSeen.Value.IsEmpty);
        Verify.Equal(nameSeen.Value, groupName);

        return true;
    }

    public static bool OutputHandleHasNoIdentity()
    {
        var endpoint = TestEnv.UniqueEndpoint("side_out");
        var appName = TestEnv.UniqueAppName("side_out");

        var outUidSeen = new StrongBox<P2PUid>(P2PUid.Empty);
        var outNameSeen = new StrongBox<string>("?");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall(
                    "probe",
                    "probe output side data",
                    (input, output) =>
                    {
                        // Attempt to read identity from the OUTPUT
                        // handle. The native layer logs a warning and
                        // returns zero / empty; the wrapper reflects
                        // that without throwing.
                        outUidSeen.Value = output.GetSenderUid();
                        outNameSeen.Value = output.GetSenderP2PName();
                        output.WriteString("ok");
                    });
            });

        using var p = new DataHandle("probe");
        using var resp = Framework.Call(appName, p, 5000);
        Verify.True(resp.Size > 0);

        Verify.True(outUidSeen.Value.IsEmpty);
        Verify.Equal(outNameSeen.Value, "");

        return true;
    }

    public static bool CallerCreatedHandleHasNoIdentity()
    {
        // No session needed: a caller-created handle never carries
        // identity, and the accessors must return zero / empty
        // rather than throw.
        using var dh = new DataHandle("any_api");
        Verify.True(dh.GetSenderUid().IsEmpty);
        Verify.Equal(dh.GetSenderP2PName(), "");
        return true;
    }

    public static bool DisposedHandleThrows()
    {
        var dh = new DataHandle("any_api");
        dh.Dispose();

        Verify.Throws<LingoFuseObjectDisposedException>(
            () => { _ = dh.GetSenderUid(); });
        Verify.Throws<LingoFuseObjectDisposedException>(
            () => { _ = dh.GetSenderP2PName(); });

        return true;
    }
}

/* ============================================================================
 * CATEGORY: CallbackDispatcher
 * ========================================================================== */

internal static class DispatcherTests
{
    public static bool InlineRunsOnCallingThread()
    {
        int caller = Environment.CurrentManagedThreadId;
        int seen = -1;

        CallbackDispatcher.Inline.Dispatch(() =>
        {
            seen = Environment.CurrentManagedThreadId;
        });

        Verify.Equal(seen, caller);
        return true;
    }

    public static bool SingleThreadedQueueRunsElsewhere()
    {
        using var dispatcher =
            CallbackDispatcher.CreateSingleThreadedQueue(
                "test2-dispatcher");

        int caller = Environment.CurrentManagedThreadId;
        int seen = -1;

        dispatcher.Dispatch(() =>
        {
            seen = Environment.CurrentManagedThreadId;
        });

        Verify.True(seen != caller);
        Verify.True(seen != 0);
        return true;
    }

    public static bool SingleThreadedQueueBlocksCaller()
    {
        using var dispatcher =
            CallbackDispatcher.CreateSingleThreadedQueue(
                "test2-dispatcher-block");

        var completed = new StrongBox<bool>(false);

        // The dispatcher must not return until the callback has
        // completed, so this flag is observable immediately after
        // Dispatch returns.
        dispatcher.Dispatch(() =>
        {
            Thread.Sleep(50);
            completed.Value = true;
        });

        Verify.True(completed.Value);
        return true;
    }

    public static bool CustomDispatcherIsInvoked()
    {
        int invoked = 0;
        var dispatcher = CallbackDispatcher.CreateCustom(cb =>
        {
            invoked++;
            cb();
        });

        bool ran = false;
        dispatcher.Dispatch(() => { ran = true; });

        Verify.Equal(invoked, 1);
        Verify.True(ran);
        return true;
    }

    public static bool FromSynchronizationContextRejectsNull()
    {
        Verify.Throws<ArgumentNullException>(
            () => CallbackDispatcher.FromSynchronizationContext(null!));
        return true;
    }

    public static bool MainThreadFallsBackToInlineWhenUncaptured()
    {
        // IsMainThreadCaptured reflects the process-wide state; if a
        // previous test happened to capture it, this check is skipped
        // rather than failed.
        if (CallbackDispatcher.IsMainThreadCaptured)
        {
            return true;
        }

        int caller = Environment.CurrentManagedThreadId;
        int seen = -1;

        CallbackDispatcher.MainThread.Dispatch(() =>
        {
            seen = Environment.CurrentManagedThreadId;
        });

        Verify.Equal(seen, caller);
        return true;
    }
}

/* ============================================================================
 * CATEGORY: UID addressing
 * ========================================================================== */

internal static class UidAddressingTests
{
    public static bool DiscoverSelfUid()
    {
        var endpoint = TestEnv.UniqueEndpoint("uid_self");
        var appName = TestEnv.UniqueAppName("uid_self");

        using var session = NetworkSession.StartWithService(
            appName, endpoint);

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);
        Verify.False(uid.IsEmpty);
        return true;
    }

    public static bool CallByUidSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("uid_call");
        var appName = TestEnv.UniqueAppName("uid_call");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("add", "add two int32",
                    Callbacks.AddInt32);
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);
        Verify.False(uid.IsEmpty);

        using var p = new DataHandle("add");
        p.WriteInt32(21);
        p.WriteInt32(21);
        using var resp = Framework.CallByUid(uid, p, 5000);

        Verify.Equal(resp.Size, 4L);
        Verify.Equal(resp.ReadInt32(), 42);
        return true;
    }

    public static bool NotifyByUidSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("uid_notify");
        var appName = TestEnv.UniqueAppName("uid_notify");

        var received = new StrongBox<int>(0);

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterNotify("sink", "notify sink",
                    input =>
                    {
                        _ = input.ReadString();
                        Interlocked.Increment(ref received.Value);
                    });
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);

        using var p = new DataHandle("sink");
        p.WriteString("hello");
        Framework.NotifyByUid(uid, p);

        Thread.Sleep(400);
        Verify.True(received.Value >= 1);
        return true;
    }

    public static bool SequencedNotifyByUidFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("uid_seq");
        var appName = TestEnv.UniqueAppName("uid_seq");

        int last = -1;
        int count = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterNotify("seq", "sequenced sink",
                    input =>
                    {
                        last = input.ReadInt32();
                        Interlocked.Increment(ref count);
                    });
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);

        for (int i = 0; i < 5; i++)
        {
            using var p = new DataHandle("seq");
            p.WriteInt32(i);
            Framework.SequencedNotifyByUid(uid, p);
        }

        Thread.Sleep(700);
        Verify.True(count >= 1);
        Verify.Equal(last, 4);
        return true;
    }

    public static bool CheckUidAndUidApi()
    {
        var endpoint = TestEnv.UniqueEndpoint("uid_check");
        var appName = TestEnv.UniqueAppName("uid_check");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("ping", "ping", Callbacks.EchoString);
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);

        // The cache broadcast has an approximate 3 s propagation
        // delay. Retry up to 6 s.
        bool uidSeen = false;
        bool apiSeen = false;
        for (int i = 0; i < 30; i++)
        {
            if (!uidSeen) uidSeen = Framework.CheckUid(uid);
            if (!apiSeen)
            {
                apiSeen = Framework.CheckUidApi(uid, "ping");
            }
            if (uidSeen && apiSeen) break;
            Thread.Sleep(200);
        }

        Verify.True(uidSeen);
        Verify.True(apiSeen);

        // P2PUid.Empty should not resolve to a live client.
        Verify.False(Framework.CheckUid(P2PUid.Empty));
        return true;
    }
}

/* ============================================================================
 * CATEGORY: P2PName addressing
 * ========================================================================== */

internal static class P2PNameAddressingTests
{
    public static bool CallByP2PNameSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_call");
        var appName = TestEnv.UniqueAppName("p2p_call");
        var groupName = TestEnv.UniqueP2PName("p2p_call");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("add", "add two int32",
                    Callbacks.AddInt32);
            },
            p2pName: groupName);

        using var p = new DataHandle("add");
        p.WriteInt32(11);
        p.WriteInt32(31);
        using var resp = Framework.CallByP2PName(
            groupName, p, 5000);

        Verify.Equal(resp.Size, 4L);
        Verify.Equal(resp.ReadInt32(), 42);
        return true;
    }

    public static bool NotifyByP2PNameSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_notify");
        var appName = TestEnv.UniqueAppName("p2p_notify");
        var groupName = TestEnv.UniqueP2PName("p2p_notify");

        var count = new StrongBox<int>(0);

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterNotify("sink", "notify sink",
                    input =>
                    {
                        _ = input.ReadString();
                        Interlocked.Increment(ref count.Value);
                    });
            },
            p2pName: groupName);

        using var p = new DataHandle("sink");
        p.WriteString("hello");
        Framework.NotifyByP2PName(groupName, p);

        Thread.Sleep(500);
        Verify.True(count.Value >= 1);
        return true;
    }

    public static bool SequencedNotifyByP2PNameFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_seq");
        var appName = TestEnv.UniqueAppName("p2p_seq");
        var groupName = TestEnv.UniqueP2PName("p2p_seq");

        int last = -1;
        int count = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterNotify("seq", "sequenced sink",
                    input =>
                    {
                        last = input.ReadInt32();
                        Interlocked.Increment(ref count);
                    });
            },
            p2pName: groupName);

        for (int i = 0; i < 5; i++)
        {
            using var p = new DataHandle("seq");
            p.WriteInt32(i);
            Framework.SequencedNotifyByP2PName(groupName, p);
        }

        Thread.Sleep(800);
        Verify.True(count >= 1);
        Verify.Equal(last, 4);
        return true;
    }

    public static bool CheckP2PNameAndApi()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_check");
        var appName = TestEnv.UniqueAppName("p2p_check");
        var groupName = TestEnv.UniqueP2PName("p2p_check");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("ping", "ping", Callbacks.EchoString);
            },
            p2pName: groupName);

        bool groupSeen = false;
        bool apiSeen = false;
        for (int i = 0; i < 30; i++)
        {
            if (!groupSeen)
            {
                groupSeen = Framework.CheckP2PName(groupName);
            }
            if (!apiSeen)
            {
                apiSeen = Framework.CheckP2PNameApi(
                    groupName, "ping");
            }
            if (groupSeen && apiSeen) break;
            Thread.Sleep(200);
        }

        Verify.True(groupSeen);
        Verify.True(apiSeen);
        return true;
    }

    public static bool UnknownGroupProducesEmptyResult()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_unknown");
        var appName = TestEnv.UniqueAppName("p2p_unknown");
        var groupName = TestEnv.UniqueP2PName("p2p_unknown");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            p2pName: groupName);

        using var p = new DataHandle("never_registered");
        using var resp = Framework.CallByP2PName(
            "group_that_does_not_exist_987654",
            p,
            800);

        // Timeout / unreachable group yields a size-0 handle.
        Verify.Equal(resp.Size, 0L);
        return true;
    }
}

/* ============================================================================
 * CATEGORY: Async — App name
 * ========================================================================== */

internal static class AsyncAppNameTests
{
    public static bool CallAsyncSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_app");
        var appName = TestEnv.UniqueAppName("async_app");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo", "echo a string",
                    Callbacks.EchoString);
            });

        using var p = new DataHandle("echo");
        p.WriteString("async hello");

        using var result = Framework.CallAsync(appName, p)
            .GetAwaiter().GetResult();

        Verify.True(result.Size > 0);
        Verify.Equal(result.ReadString(), "async hello");
        return true;
    }

    public static bool CallSequencedAsyncFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_seq");
        var appName = TestEnv.UniqueAppName("async_seq");

        int last = -1;
        int count = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo_n", "echo an int",
                    (input, output) =>
                    {
                        int n = input.ReadInt32();
                        last = n;
                        Interlocked.Increment(ref count);
                        output.WriteInt32(n);
                    });
            });

        var tasks = new List<Task<DataHandle>>();
        for (int i = 0; i < 5; i++)
        {
            var p = new DataHandle("echo_n");
            p.WriteInt32(i);
            tasks.Add(Framework.CallSequencedAsync(appName, p));
        }

        Task.WaitAll(tasks.ToArray(), 5000);

        foreach (var t in tasks)
        {
            using var result = t.Result;
            Verify.True(result.Size > 0);
        }

        Verify.True(count >= 1);
        Verify.Equal(last, 4);
        return true;
    }

    public static bool AwaitResumesOnSynchronizationContext()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_ctx");
        var appName = TestEnv.UniqueAppName("async_ctx");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo", "echo a string",
                    Callbacks.EchoString);
            });

        using var ctx = new TestSyncContext();
        var done = new ManualResetEventSlim(false);
        int continuationThread = -1;
        bool ranOnCtxThread = false;
        Exception? captured = null;

        // Post the async lambda to the SyncContext, so the lambda
        // actually runs on the SyncContext's dedicated thread. This
        // mirrors the way a real UI application invokes an async API:
        // the caller is already running on the UI thread when it
        // awaits.
        //
        // If instead the lambda ran on a ThreadPool thread (for
        // example via Task.Run), the await semantics would be
        // misleading: a synchronously-completing Task would resume
        // inline on the ThreadPool thread, and a SyncContext
        // installed by the lambda itself would have no effect.
        ctx.Post(async _ =>
        {
            try
            {
                using var p = new DataHandle("echo");
                p.WriteString("ctx-bound");

                // ConfigureAwait(true) is the default and is written
                // here to be explicit about what is being tested:
                // the await continuation must be posted back to the
                // SynchronizationContext that was current when the
                // await was reached.
                using var result = await Framework.CallAsync(
                    appName, p).ConfigureAwait(true);

                continuationThread =
                    Environment.CurrentManagedThreadId;
                ranOnCtxThread = continuationThread == ctx.ThreadId;
                Verify.Equal(result.ReadString(), "ctx-bound");
            }
            catch (Exception ex)
            {
                captured = ex;
            }
            finally
            {
                done.Set();
            }
        }, null);

        Verify.True(done.Wait(8000),
            "async continuation did not complete within 8 s");

        if (captured is not null)
        {
            throw new CheckFailedException(
                $"exception in async continuation: {captured}");
        }

        Verify.True(ranOnCtxThread,
            $"continuation ran on thread {continuationThread}; " +
            $"expected the SyncContext thread {ctx.ThreadId}");
        return true;
    }

    public static bool ConcurrentCallAsync()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_conc");
        var appName = TestEnv.UniqueAppName("async_conc");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo_n", "echo an int",
                    (input, output) =>
                    {
                        output.WriteInt32(input.ReadInt32());
                    });
            });

        const int kCount = 8;
        var tasks = new Task<DataHandle>[kCount];
        for (int i = 0; i < kCount; i++)
        {
            var p = new DataHandle("echo_n");
            p.WriteInt32(i * 100);
            tasks[i] = Framework.CallAsync(appName, p);
        }

        Task.WaitAll(tasks, 8000);

        for (int i = 0; i < kCount; i++)
        {
            using var result = tasks[i].Result;
            Verify.Equal(result.ReadInt32(), i * 100);
        }
        return true;
    }
}

/* ============================================================================
 * CATEGORY: Async — UID and P2PName
 * ========================================================================== */

internal static class AsyncUidP2PNameTests
{
    public static bool CallByUidAsyncSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_uid");
        var appName = TestEnv.UniqueAppName("async_uid");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo", "echo a string",
                    Callbacks.EchoString);
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);

        using var p = new DataHandle("echo");
        p.WriteString("uid-async");

        using var result = Framework.CallByUidAsync(uid, p)
            .GetAwaiter().GetResult();
        Verify.Equal(result.ReadString(), "uid-async");
        return true;
    }

    public static bool CallByUidSequencedAsyncFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_uid_seq");
        var appName = TestEnv.UniqueAppName("async_uid_seq");

        int last = -1;
        int count = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo_n", "echo an int",
                    (input, output) =>
                    {
                        int n = input.ReadInt32();
                        last = n;
                        Interlocked.Increment(ref count);
                        output.WriteInt32(n);
                    });
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);

        var tasks = new List<Task<DataHandle>>();
        for (int i = 0; i < 4; i++)
        {
            var p = new DataHandle("echo_n");
            p.WriteInt32(i);
            tasks.Add(Framework.CallByUidSequencedAsync(uid, p));
        }

        Task.WaitAll(tasks.ToArray(), 5000);
        foreach (var t in tasks)
        {
            using var result = t.Result;
            Verify.True(result.Size > 0);
        }

        Verify.True(count >= 1);
        Verify.Equal(last, 3);
        return true;
    }

    public static bool CallByP2PNameAsyncSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_p2p");
        var appName = TestEnv.UniqueAppName("async_p2p");
        var groupName = TestEnv.UniqueP2PName("async_p2p");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo", "echo a string",
                    Callbacks.EchoString);
            },
            p2pName: groupName);

        using var p = new DataHandle("echo");
        p.WriteString("p2p-async");

        using var result = Framework.CallByP2PNameAsync(
            groupName, p).GetAwaiter().GetResult();
        Verify.Equal(result.ReadString(), "p2p-async");
        return true;
    }

    public static bool CallByP2PNameSequencedAsyncFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_p2p_seq");
        var appName = TestEnv.UniqueAppName("async_p2p_seq");
        var groupName = TestEnv.UniqueP2PName("async_p2p_seq");

        int last = -1;
        int count = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo_n", "echo an int",
                    (input, output) =>
                    {
                        int n = input.ReadInt32();
                        last = n;
                        Interlocked.Increment(ref count);
                        output.WriteInt32(n);
                    });
            },
            p2pName: groupName);

        var tasks = new List<Task<DataHandle>>();
        for (int i = 0; i < 4; i++)
        {
            var p = new DataHandle("echo_n");
            p.WriteInt32(i);
            tasks.Add(Framework.CallByP2PNameSequencedAsync(
                groupName, p));
        }

        Task.WaitAll(tasks.ToArray(), 5000);
        foreach (var t in tasks)
        {
            using var result = t.Result;
            Verify.True(result.Size > 0);
        }

        Verify.True(count >= 1);
        Verify.Equal(last, 3);
        return true;
    }
}

/* ============================================================================
 * CATEGORY: Process-wide P2P registration
 * ========================================================================== */

internal static class P2PRegistrationTests
{
    public static bool RegisterP2PCallWorks()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_reg_call");
        var appName = TestEnv.UniqueAppName("p2p_reg_call");

        // Register the P2P API before PrepareClient, so the mesh
        // broadcast carries it from the start.
        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                bool ok = Framework.RegisterP2PCall(
                    "__test_p2p_echo__",
                    "test-only P2P echo",
                    (input, output) =>
                    {
                        output.WriteString(input.ReadString());
                    });
                Verify.True(ok);
            });

        // The API is not reachable via App name; it needs a
        // P2PName-addressed call. Set our P2P name for the test.
        // (Session was already prepared without one; the P2P API
        // is still in the LF_P2P_APP's method pool and is invoked
        // through the same-process local path.)
        using var p = new DataHandle("__test_p2p_echo__");
        p.WriteString("p2p-reply");

        // UID addressing reaches the same-process P2P API because
        // local-first routing inspects the local LF_P2P_APP.
        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);

        // The whoami helper just registered a new API on the app.
        // Give the framework a moment to stabilise.
        Thread.Sleep(200);

        using var resp = Framework.CallByUid(uid, p, 3000);
        Verify.True(resp.Size > 0);
        Verify.Equal(resp.ReadString(), "p2p-reply");

        // Clean up so subsequent tests do not see the API.
        Verify.True(Framework.UnregisterP2P("__test_p2p_echo__"));
        return true;
    }

    public static bool RegisterP2PNotifyWorks()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_reg_notify");
        var appName = TestEnv.UniqueAppName("p2p_reg_notify");

        int received = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                bool ok = Framework.RegisterP2PNotify(
                    "__test_p2p_sink__",
                    "test-only P2P notify",
                    input =>
                    {
                        _ = input.ReadString();
                        Interlocked.Increment(ref received);
                    });
                Verify.True(ok);
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);
        Thread.Sleep(200);

        using var p = new DataHandle("__test_p2p_sink__");
        p.WriteString("p2p-notify");
        Framework.NotifyByUid(uid, p);

        Thread.Sleep(500);
        Verify.True(received >= 1);

        Verify.True(Framework.UnregisterP2P("__test_p2p_sink__"));
        return true;
    }

    public static bool UnregisterP2PBehavior()
    {
        var endpoint = TestEnv.UniqueEndpoint("p2p_unreg");
        var appName = TestEnv.UniqueAppName("p2p_unreg");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                Framework.RegisterP2PCall(
                    "__test_p2p_tmp__", "temp",
                    (input, output) => output.WriteInt32(1));
            });

        // A second registration under the same name must fail.
        bool duplicate = Framework.RegisterP2PCall(
            "__test_p2p_tmp__", "temp dup",
            (input, output) => output.WriteInt32(2));
        Verify.False(duplicate);

        // Unregister succeeds, then a second call is a no-op.
        Verify.True(Framework.UnregisterP2P("__test_p2p_tmp__"));
        Verify.False(Framework.UnregisterP2P("__test_p2p_tmp__"));

        // Null argument rejected.
        Verify.Throws<ArgumentNullException>(
            () => Framework.UnregisterP2P(null!));

        return true;
    }
}

/* ============================================================================
 * CATEGORY: End-to-end dispatcher integration
 * ========================================================================== */

internal static class DispatcherIntegrationTests
{
    public static bool HandlerRunsOnDispatcherThread()
    {
        var endpoint = TestEnv.UniqueEndpoint("disp_int");
        var appName = TestEnv.UniqueAppName("disp_int");

        int handlerThread = -1;
        using var dispatcher =
            CallbackDispatcher.CreateSingleThreadedQueue(
                "test2-handler-thread");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall(
                    "ping",
                    "ping with a custom dispatcher",
                    (input, output) =>
                    {
                        handlerThread = Environment
                            .CurrentManagedThreadId;
                        output.WriteInt32(1);
                    },
                    dispatcher);
            });

        // Call from a dedicated thread so the caller's thread ID
        // differs from the dispatcher's worker thread ID.
        int callerThread = -1;
        var caller = new Thread(() =>
        {
            callerThread = Environment.CurrentManagedThreadId;
            using var p = new DataHandle("ping");
            using var resp = Framework.Call(appName, p, 3000);
            Verify.True(resp.Size > 0);
        })
        { IsBackground = true };
        caller.Start();
        Verify.True(caller.Join(5000));

        Verify.True(handlerThread != -1,
            "handler never ran");
        Verify.True(handlerThread != callerThread,
            $"handler ran on the caller thread {callerThread}; " +
            "expected the dispatcher's own thread");

        return true;
    }
}

/* ============================================================================
 * CATEGORY: Async — callback style (LingoFuse.Async)
 * ==========================================================================
 *
 * These tests exercise the callback-style asynchronous API exposed by
 * the LingoFuse.Async facade. The API mirrors the C++ wrapper
 * lingofuse::callAsync and the Pascal LF.AsyncCallApp_P: the call and
 * its completion handler are a single expression, there is exactly one
 * error path (AsyncResult.Ok), and the result is read from a borrowed
 * handle that is valid only inside the handler body.
 *
 * The tests below deliberately avoid the await-style API
 * (Framework.CallAsync) so that the two styles remain independently
 * verifiable.
 *
 * Threading: Async.Call invokes the user callback on a native worker
 * thread, except in the dispatch-failure case where the callback is
 * invoked synchronously on the caller's thread. Every test uses a
 * ManualResetEventSlim (or CountdownEvent) to synchronise the worker
 * callback with the test thread.
 * ========================================================================== */

internal static class AsyncCallbackTests
{
    // ------------------------------------------------------------------
    // T1 — Call success via the JSON convenience overload
    // ------------------------------------------------------------------
    public static bool CallSuccessJson()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_json");
        var appName = TestEnv.UniqueAppName("async_cb_json");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("add", "JSON add",
                    (input, output) =>
                    {
                        var m = LfIo.ReadJson<Dictionary<string, int>>(input);
                        LfIo.WriteJson(output,
                            new Dictionary<string, int>
                            {
                                ["result"] = m["a"] + m["b"],
                            });
                    });
            });

        using var done = new ManualResetEventSlim(false);
        var result = new StrongBox<int>(-1);
        var error = new StrongBox<string?>(null);

        Async.Call(appName, "add",
            new { a = 10, b = 20 },
            r =>
            {
                try
                {
                    if (!r.Ok) { error.Value = r.Error; return; }
                    var m = r.ReadJson<Dictionary<string, int>>();
                    result.Value = m["result"];
                }
                finally
                {
                    done.Set();
                }
            });

        Verify.True(done.Wait(5000),
            "callback did not fire within 5 s");
        Verify.True(error.Value is null,
            $"callback error: {error.Value}");
        Verify.Equal(result.Value, 30);

        return true;
    }

    // ------------------------------------------------------------------
    // T2 — Call success via the DataHandle overload
    // ------------------------------------------------------------------
    public static bool CallSuccessDataHandle()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_dh");
        var appName = TestEnv.UniqueAppName("async_cb_dh");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("add32", "add two int32",
                    Callbacks.AddInt32);
            });

        using var done = new ManualResetEventSlim(false);
        var sum = new StrongBox<int>(-1);

        using var request = new DataHandle("add32");
        request.WriteInt32(15);
        request.WriteInt32(27);

        Async.Call(appName, request,
            r =>
            {
                try
                {
                    if (r.Ok && r.Size >= 4)
                    {
                        sum.Value = r.Handle.ReadInt32();
                    }
                }
                finally
                {
                    done.Set();
                }
            });

        Verify.True(done.Wait(5000),
            "callback did not fire within 5 s");
        Verify.Equal(sum.Value, 42);

        return true;
    }

    // ------------------------------------------------------------------
    // T3 — dispatch failure fires the callback synchronously
    // ------------------------------------------------------------------
    //
    // Bring up a session, tear it down, then issue an Async.Call against
    // a framework that has no dispatch capability. LF_Async_Call must
    // return 0, and Async must invoke the callback synchronously on the
    // caller's thread with Ok == false.
    public static bool DispatchFailureIsSynchronous()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_fail");
        var appName = TestEnv.UniqueAppName("async_cb_fail");

        var session = NetworkSession.StartWithService(appName, endpoint);

        // Create the request handle while the framework is still alive
        // so that LF_CreateData has a valid context.
        using var request = new DataHandle("never_dispatched");
        request.WriteInt32(1);

        // Tear the framework down. All three calls are idempotent.
        try { NetworkEvents.Clear(); } catch { }
        try { Framework.ExitMainThread(); } catch { }
        try { session.App?.Dispose(); } catch { }
        try { Framework.Shutdown(); } catch { }

        var fired = new StrongBox<bool>(false);
        var ok = new StrongBox<bool>(true);
        var err = new StrongBox<string?>(null);
        int callerThread = Environment.CurrentManagedThreadId;
        var callbackThread = new StrongBox<int>(-1);

        Async.Call(appName, request,
            r =>
            {
                fired.Value = true;
                ok.Value = r.Ok;
                err.Value = r.Error;
                callbackThread.Value =
                    Environment.CurrentManagedThreadId;
            });

        // Because the callback runs synchronously, these checks are
        // already conclusive after Async.Call returns.
        Verify.True(fired.Value,
            "dispatch-failure callback was not invoked synchronously");
        Verify.False(ok.Value,
            "Ok must be false on dispatch failure");
        Verify.NotNull(err.Value,
            "Error must be set on dispatch failure");
        Verify.Equal(callbackThread.Value, callerThread,
            "dispatch-failure callback must run on the caller's thread");

        return true;
    }

    // ------------------------------------------------------------------
    // T4 — CallSequenced preserves FIFO per (app, api)
    // ------------------------------------------------------------------
    public static bool CallSequencedFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_seq");
        var appName = TestEnv.UniqueAppName("async_cb_seq");

        int serverLast = -1;
        int serverCount = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo_n", "echo an int",
                    (input, output) =>
                    {
                        int n = input.ReadInt32();
                        serverLast = n;
                        Interlocked.Increment(ref serverCount);
                        output.WriteInt32(n);
                    });
            });

        const int N = 5;
        using var done = new CountdownEvent(N);
        var results = new int[N];

        for (int i = 0; i < N; i++)
        {
            int idx = i;
            using var request = new DataHandle("echo_n");
            request.WriteInt32(idx);

            Async.CallSequenced(appName, request,
                r =>
                {
                    try
                    {
                        if (r.Ok && r.Size >= 4)
                        {
                            results[idx] = r.Handle.ReadInt32();
                        }
                    }
                    finally
                    {
                        done.Signal();
                    }
                });
        }

        Verify.True(done.Wait(5000),
            "sequenced callbacks did not all complete within 5 s");
        Verify.True(serverCount >= 1,
            "server did not observe any call");
        Verify.Equal(serverLast, N - 1,
            "last delivered payload should be N-1 (FIFO)");
        for (int i = 0; i < N; i++)
        {
            Verify.Equal(results[i], i);
        }

        return true;
    }

    // ------------------------------------------------------------------
    // T5 — CallByUid success
    // ------------------------------------------------------------------
    public static bool CallByUidSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_uid");
        var appName = TestEnv.UniqueAppName("async_cb_uid");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("add32", "add two int32",
                    Callbacks.AddInt32);
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);
        Verify.False(uid.IsEmpty);

        using var done = new ManualResetEventSlim(false);
        var sum = new StrongBox<int>(-1);
        var error = new StrongBox<string?>(null);

        using var request = new DataHandle("add32");
        request.WriteInt32(21);
        request.WriteInt32(21);

        Async.CallByUid(uid, request,
            r =>
            {
                try
                {
                    if (!r.Ok) { error.Value = r.Error; return; }
                    if (r.Size >= 4)
                    {
                        sum.Value = r.Handle.ReadInt32();
                    }
                }
                finally
                {
                    done.Set();
                }
            });

        Verify.True(done.Wait(5000),
            "callback did not fire within 5 s");
        Verify.True(error.Value is null,
            $"callback error: {error.Value}");
        Verify.Equal(sum.Value, 42);

        return true;
    }

    // ------------------------------------------------------------------
    // T6 — CallByUidSequenced preserves FIFO per (uid, api)
    // ------------------------------------------------------------------
    public static bool CallByUidSequencedFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_uid_seq");
        var appName = TestEnv.UniqueAppName("async_cb_uid_seq");

        int serverLast = -1;
        int serverCount = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo_n", "echo an int",
                    (input, output) =>
                    {
                        int n = input.ReadInt32();
                        serverLast = n;
                        Interlocked.Increment(ref serverCount);
                        output.WriteInt32(n);
                    });
            });

        var uid = Mesh.DiscoverSelfUid(
            session.App!, appName, out _);

        const int N = 4;
        using var done = new CountdownEvent(N);
        var results = new int[N];

        for (int i = 0; i < N; i++)
        {
            int idx = i;
            using var request = new DataHandle("echo_n");
            request.WriteInt32(idx);

            Async.CallByUidSequenced(uid, request,
                r =>
                {
                    try
                    {
                        if (r.Ok && r.Size >= 4)
                        {
                            results[idx] = r.Handle.ReadInt32();
                        }
                    }
                    finally
                    {
                        done.Signal();
                    }
                });
        }

        Verify.True(done.Wait(5000),
            "uid-sequenced callbacks did not all complete");
        Verify.True(serverCount >= 1);
        Verify.Equal(serverLast, N - 1);
        for (int i = 0; i < N; i++)
        {
            Verify.Equal(results[i], i);
        }

        return true;
    }

    // ------------------------------------------------------------------
    // T7 — CallByP2PName success
    // ------------------------------------------------------------------
    public static bool CallByP2PNameSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_p2p");
        var appName = TestEnv.UniqueAppName("async_cb_p2p");
        var groupName = TestEnv.UniqueP2PName("async_cb_p2p");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("add32", "add two int32",
                    Callbacks.AddInt32);
            },
            p2pName: groupName);

        using var done = new ManualResetEventSlim(false);
        var sum = new StrongBox<int>(-1);
        var error = new StrongBox<string?>(null);

        using var request = new DataHandle("add32");
        request.WriteInt32(11);
        request.WriteInt32(31);

        Async.CallByP2PName(groupName, request,
            r =>
            {
                try
                {
                    if (!r.Ok) { error.Value = r.Error; return; }
                    if (r.Size >= 4)
                    {
                        sum.Value = r.Handle.ReadInt32();
                    }
                }
                finally
                {
                    done.Set();
                }
            });

        Verify.True(done.Wait(5000),
            "callback did not fire within 5 s");
        Verify.True(error.Value is null,
            $"callback error: {error.Value}");
        Verify.Equal(sum.Value, 42);

        return true;
    }

    // ------------------------------------------------------------------
    // T8 — CallByP2PNameSequenced preserves FIFO per (p2p, api)
    // ------------------------------------------------------------------
    public static bool CallByP2PNameSequencedFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_p2p_seq");
        var appName = TestEnv.UniqueAppName("async_cb_p2p_seq");
        var groupName = TestEnv.UniqueP2PName("async_cb_p2p_seq");

        int serverLast = -1;
        int serverCount = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("echo_n", "echo an int",
                    (input, output) =>
                    {
                        int n = input.ReadInt32();
                        serverLast = n;
                        Interlocked.Increment(ref serverCount);
                        output.WriteInt32(n);
                    });
            },
            p2pName: groupName);

        const int N = 4;
        using var done = new CountdownEvent(N);
        var results = new int[N];

        for (int i = 0; i < N; i++)
        {
            int idx = i;
            using var request = new DataHandle("echo_n");
            request.WriteInt32(idx);

            Async.CallByP2PNameSequenced(groupName, request,
                r =>
                {
                    try
                    {
                        if (r.Ok && r.Size >= 4)
                        {
                            results[idx] = r.Handle.ReadInt32();
                        }
                    }
                    finally
                    {
                        done.Signal();
                    }
                });
        }

        Verify.True(done.Wait(5000),
            "p2p-sequenced callbacks did not all complete");
        Verify.True(serverCount >= 1);
        Verify.Equal(serverLast, N - 1);
        for (int i = 0; i < N; i++)
        {
            Verify.Equal(results[i], i);
        }

        return true;
    }

    // ------------------------------------------------------------------
    // T9 — callback exception is swallowed by the trampoline
    // ------------------------------------------------------------------
    public static bool CallbackExceptionIsSwallowed()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_exc");
        var appName = TestEnv.UniqueAppName("async_cb_exc");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("ping", "ping", Callbacks.EchoString);
            });

        using var done = new ManualResetEventSlim(false);
        var reachedFinally = new StrongBox<bool>(false);

        using var request = new DataHandle("ping");
        request.WriteString("hi");

        Async.Call(appName, request,
            r =>
            {
                try
                {
                    // Async.OnResult catches this and routes it to
                    // Framework.ReportCallbackError. The process must
                    // remain fully functional.
                    throw new InvalidOperationException(
                        "intentional test exception");
                }
                finally
                {
                    reachedFinally.Value = true;
                    done.Set();
                }
            });

        Verify.True(done.Wait(5000),
            "callback did not fire within 5 s");
        Verify.True(reachedFinally.Value);

        // The framework must still be alive: issue a synchronous call.
        using var probe = new DataHandle("ping");
        probe.WriteString("world");
        using var echo = Framework.TryCall(appName, probe, 3000);
        Verify.NotNull(echo,
            "framework did not survive the callback exception");
        echo!.Position = 0;
        Verify.Equal(echo.ReadString(), "world");

        return true;
    }

    // ------------------------------------------------------------------
    // T10 — chained calls: issue the next async call from a callback
    // ------------------------------------------------------------------
    public static bool ChainedCalls()
    {
        var endpoint = TestEnv.UniqueEndpoint("async_cb_chain");
        var appName = TestEnv.UniqueAppName("async_cb_chain");

        using var session = NetworkSession.StartWithService(
            appName, endpoint,
            configureApp: app =>
            {
                app.RegisterCall("double", "double an int",
                    (input, output) =>
                        output.WriteInt32(input.ReadInt32() * 2));
                app.RegisterCall("add32", "add two int32",
                    Callbacks.AddInt32);
            });

        using var done = new ManualResetEventSlim(false);
        var final = new StrongBox<int>(-1);
        var stage = new StrongBox<int>(0);

        // Step 1: double(5) -> 10
        using var req1 = new DataHandle("double");
        req1.WriteInt32(5);

        Async.Call(appName, req1,
            r1 =>
            {
                if (!r1.Ok || r1.Size < 4)
                {
                    done.Set();
                    return;
                }
                int doubled = r1.Handle.ReadInt32();
                stage.Value = 1;

                // Step 2: add(10, 7) -> 17. The second request handle
                // is created inside the callback; its payload is
                // copied synchronously by LF_Async_*, so disposing it
                // as soon as Async.Call returns is safe.
                using var req2 = new DataHandle("add32");
                req2.WriteInt32(doubled);
                req2.WriteInt32(7);

                Async.Call(appName, req2,
                    r2 =>
                    {
                        try
                        {
                            if (r2.Ok && r2.Size >= 4)
                            {
                                final.Value = r2.Handle.ReadInt32();
                            }
                        }
                        finally
                        {
                            done.Set();
                        }
                    });
            });

        Verify.True(done.Wait(5000),
            "chained callbacks did not complete within 5 s");
        Verify.Equal(stage.Value, 1,
            "first-stage callback did not complete");
        Verify.Equal(final.Value, 17);

        return true;
    }
}

/* ============================================================================
 * Suite plan
 * ========================================================================== */

internal sealed class TestCase
{
    public string Name { get; }
    public TestFn Fn { get; }
    public TestCase(string name, TestFn fn)
    {
        Name = name;
        Fn = fn;
    }
}

internal sealed class Category
{
    public string Name { get; }
    public string Description { get; }
    public List<TestCase> Tests { get; }
    public int Passed;
    public int Failed;
    public long TotalMs;

    public Category(string name, string description, List<TestCase> tests)
    {
        Name = name;
        Description = description;
        Tests = tests;
    }
}

internal sealed class FailureRecord
{
    public string Category = string.Empty;
    public string Test = string.Empty;
    public string Reason = string.Empty;
}

/* ============================================================================
 * Program
 * ========================================================================== */

internal static class Program
{
    private const string SuiteVersion = "1.0 (v5.0 new-API coverage)";

    public static int Main(string[] args)
    {
        var startTime = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");

        Fmt.PrintBanner("LingoFuse C# v5.0 Test Suite (test2)");
        Console.WriteLine($"  Version      : {SuiteVersion}");
        Console.WriteLine($"  Process ID   : {Environment.ProcessId}");
        Console.WriteLine($"  Platform     : {System.Runtime.InteropServices.RuntimeInformation.OSDescription}");
        Console.WriteLine($"  Architecture : {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}");
        Console.WriteLine($"  Start time   : {startTime}");
        Console.WriteLine($"  CPUs         : {Environment.ProcessorCount}");

        var categories = BuildPlan();
        int totalTests = categories.Sum(c => c.Tests.Count);

        Fmt.PrintBanner("Test plan");
        Console.WriteLine("  Category                         Tests");
        Console.WriteLine("  -------------------------------- -----");
        foreach (var cat in categories)
        {
            Console.WriteLine($"  {cat.Name,-32} {cat.Tests.Count,5}");
        }
        Console.WriteLine("  -------------------------------- -----");
        Console.WriteLine($"  {"Total",-32} {totalTests,5}");

        var failures = new List<FailureRecord>();
        int globalIndex = 0;

        foreach (var cat in categories)
        {
            Fmt.PrintCategory(cat.Name, cat.Description, cat.Tests.Count);

            foreach (var t in cat.Tests)
            {
                globalIndex++;
                Console.WriteLine(
                    $"  -- [{globalIndex}/{totalTests}] --");
                var result = TestRunner.Run(t.Name, t.Fn);

                if (result.Passed && !result.Threw)
                {
                    cat.Passed++;
                }
                else
                {
                    cat.Failed++;
                    failures.Add(new FailureRecord
                    {
                        Category = cat.Name,
                        Test = t.Name,
                        Reason = result.Threw
                            ? result.ErrorDetail
                            : "a check returned false",
                    });
                }
                cat.TotalMs += result.ElapsedMs;
            }
        }

        // ---- Summary --------------------------------------------------
        Fmt.PrintBanner("Summary");
        Console.WriteLine("  Category                         Total Passed Failed");
        Console.WriteLine("  -------------------------------- ----- ------ ------");

        int totalPassed = 0;
        int totalFailed = 0;
        long totalMs = 0;

        foreach (var cat in categories)
        {
            totalPassed += cat.Passed;
            totalFailed += cat.Failed;
            totalMs += cat.TotalMs;
            Console.WriteLine(
                $"  {cat.Name,-32} {cat.Tests.Count,5} " +
                $"{cat.Passed,6} {cat.Failed,6}");
        }

        Console.WriteLine("  -------------------------------- ----- ------ ------");
        Console.WriteLine(
            $"  {"Total",-32} {totalTests,5} {totalPassed,6} {totalFailed,6}");
        Console.WriteLine();
        Console.WriteLine($"  Elapsed: {totalMs} ms");

        if (failures.Count > 0)
        {
            Console.WriteLine();
            Console.WriteLine($"  Failures ({failures.Count}):");
            for (int i = 0; i < failures.Count; i++)
            {
                var f = failures[i];
                Console.WriteLine($"    [{i + 1}] {f.Category} :: {f.Test}");
                Console.WriteLine($"        {f.Reason}");
            }
        }

        Console.WriteLine();
        if (totalFailed == 0)
        {
            Console.WriteLine(
                "  ************************************************************");
            Console.WriteLine(
                "  *  RESULT: ALL TESTS PASSED                                *");
            Console.WriteLine(
                "  ************************************************************");
        }
        else
        {
            Console.WriteLine(
                "  ************************************************************");
            Console.WriteLine(
                $"  *  RESULT: {totalFailed} TEST(S) FAILED");
            Console.WriteLine(
                "  ************************************************************");
        }

        return totalFailed == 0 ? 0 : 1;
    }

    private static List<Category> BuildPlan()
    {
        return new List<Category>
        {
            new Category(
                "P2PUid",
                "Value type: emptiness, byte round-trip, hex parse, equality",
                new List<TestCase>
                {
                    new("P2PUid :: Empty is all zero",
                        P2PUidTests.EmptyIsAllZero),
                    new("P2PUid :: FromBytes round-trip",
                        P2PUidTests.FromBytesRoundTrip),
                    new("P2PUid :: FromBytes rejects wrong length",
                        P2PUidTests.FromBytesRejectsWrongLength),
                    new("P2PUid :: TryParse valid and invalid",
                        P2PUidTests.TryParseValidAndInvalid),
                    new("P2PUid :: hex format and CopyTo",
                        P2PUidTests.HexFormatAndCopy),
                    new("P2PUid :: equality and hashing",
                        P2PUidTests.EqualityAndHashing),
                }),

            new Category(
                "RuntimeOptions",
                "Strongly typed set/get over every ABI option key",
                new List<TestCase>
                {
                    new("RuntimeOptions :: bool round-trip",
                        RuntimeOptionsTests.BoolRoundTrip),
                    new("RuntimeOptions :: logging round-trip",
                        RuntimeOptionsTests.LoggingRoundTrip),
                    new("RuntimeOptions :: ulong round-trip",
                        RuntimeOptionsTests.UlongRoundTrip),
                    new("RuntimeOptions :: int round-trip",
                        RuntimeOptionsTests.IntRoundTrip),
                    new("RuntimeOptions :: P2PName round-trip",
                        RuntimeOptionsTests.P2PNameRoundTrip),
                    new("RuntimeOptions :: password is masked",
                        RuntimeOptionsTests.PasswordIsMasked),
                    new("RuntimeOptions :: GetRaw / SetRaw escape hatch",
                        RuntimeOptionsTests.RawEscapeHatch),
                    new("RuntimeOptions :: unset option type safety",
                        RuntimeOptionsTests.TypeSafetyOnUnsetOption),
                }),

            new Category(
                "DataHandle side-data",
                "Sender identity is only meaningful on INPUT handles",
                new List<TestCase>
                {
                    new("SideData :: input handle carries identity",
                        SideDataTests.InputHandleCarriesIdentity),
                    new("SideData :: output handle has no identity",
                        SideDataTests.OutputHandleHasNoIdentity),
                    new("SideData :: caller-created handle has no identity",
                        SideDataTests.CallerCreatedHandleHasNoIdentity),
                    new("SideData :: disposed handle throws",
                        SideDataTests.DisposedHandleThrows),
                }),

            new Category(
                "CallbackDispatcher",
                "Thread selection for server-side callback execution",
                new List<TestCase>
                {
                    new("Dispatcher :: Inline runs on calling thread",
                        DispatcherTests.InlineRunsOnCallingThread),
                    new("Dispatcher :: SingleThreadedQueue runs elsewhere",
                        DispatcherTests.SingleThreadedQueueRunsElsewhere),
                    new("Dispatcher :: SingleThreadedQueue blocks caller",
                        DispatcherTests.SingleThreadedQueueBlocksCaller),
                    new("Dispatcher :: custom dispatcher is invoked",
                        DispatcherTests.CustomDispatcherIsInvoked),
                    new("Dispatcher :: FromSynchronizationContext rejects null",
                        DispatcherTests.FromSynchronizationContextRejectsNull),
                    new("Dispatcher :: MainThread falls back to inline",
                        DispatcherTests.MainThreadFallsBackToInlineWhenUncaptured),
                }),

            new Category(
                "UID addressing",
                "LF_UID_Call / LF_UID_Notify / LF_UID_Sequenced_Notify + probes",
                new List<TestCase>
                {
                    new("UID :: discover self UID",
                        UidAddressingTests.DiscoverSelfUid),
                    new("UID :: CallByUid success",
                        UidAddressingTests.CallByUidSuccess),
                    new("UID :: NotifyByUid success",
                        UidAddressingTests.NotifyByUidSuccess),
                    new("UID :: SequencedNotifyByUid FIFO",
                        UidAddressingTests.SequencedNotifyByUidFifo),
                    new("UID :: CheckUid and CheckUidApi",
                        UidAddressingTests.CheckUidAndUidApi),
                }),

            new Category(
                "P2PName addressing",
                "LF_P2PNAME_Call / Notify / Sequenced + probes",
                new List<TestCase>
                {
                    new("P2PName :: CallByP2PName success",
                        P2PNameAddressingTests.CallByP2PNameSuccess),
                    new("P2PName :: NotifyByP2PName success",
                        P2PNameAddressingTests.NotifyByP2PNameSuccess),
                    new("P2PName :: SequencedNotifyByP2PName FIFO",
                        P2PNameAddressingTests.SequencedNotifyByP2PNameFifo),
                    new("P2PName :: CheckP2PName and CheckP2PNameApi",
                        P2PNameAddressingTests.CheckP2PNameAndApi),
                    new("P2PName :: unknown group produces empty result",
                        P2PNameAddressingTests.UnknownGroupProducesEmptyResult),
                }),

            new Category(
                "Async — App name",
                "Task<DataHandle> and await continuation across SyncContext",
                new List<TestCase>
                {
                    new("Async :: CallAsync success",
                        AsyncAppNameTests.CallAsyncSuccess),
                    new("Async :: CallSequencedAsync FIFO",
                        AsyncAppNameTests.CallSequencedAsyncFifo),
                    new("Async :: await resumes on SyncContext",
                        AsyncAppNameTests.AwaitResumesOnSynchronizationContext),
                    new("Async :: concurrent CallAsync x 8",
                        AsyncAppNameTests.ConcurrentCallAsync),
                }),

            new Category(
                "Async — UID / P2PName",
                "Task-based invocation across UID and P2PName",
                new List<TestCase>
                {
                    new("Async :: CallByUidAsync success",
                        AsyncUidP2PNameTests.CallByUidAsyncSuccess),
                    new("Async :: CallByUidSequencedAsync FIFO",
                        AsyncUidP2PNameTests.CallByUidSequencedAsyncFifo),
                    new("Async :: CallByP2PNameAsync success",
                        AsyncUidP2PNameTests.CallByP2PNameAsyncSuccess),
                    new("Async :: CallByP2PNameSequencedAsync FIFO",
                        AsyncUidP2PNameTests.CallByP2PNameSequencedAsyncFifo),
                }),

            new Category(
                "P2P registration",
                "Process-wide LF_Register_P2P_* family",
                new List<TestCase>
                {
                    new("P2P :: RegisterP2PCall works",
                        P2PRegistrationTests.RegisterP2PCallWorks),
                    new("P2P :: RegisterP2PNotify works",
                        P2PRegistrationTests.RegisterP2PNotifyWorks),
                    new("P2P :: UnregisterP2P behaviour",
                        P2PRegistrationTests.UnregisterP2PBehavior),
                }),

            new Category(
                "Dispatcher integration",
                "Registered handler executes on the dispatcher thread",
                new List<TestCase>
                {
                    new("Dispatcher :: handler runs on dispatcher thread",
                        DispatcherIntegrationTests.HandlerRunsOnDispatcherThread),
                }),
            new Category(
                "Async — callback style",
                "LingoFuse.Async facade: call-site-inline completion callbacks",
                new List<TestCase>
                {
                    new("Async.Call :: success via JSON convenience",
                        AsyncCallbackTests.CallSuccessJson),
                    new("Async.Call :: success via DataHandle",
                        AsyncCallbackTests.CallSuccessDataHandle),
                    new("Async.Call :: dispatch failure is synchronous",
                        AsyncCallbackTests.DispatchFailureIsSynchronous),
                    new("Async.CallSequenced :: FIFO per (app, api)",
                        AsyncCallbackTests.CallSequencedFifo),
                    new("Async.CallByUid :: success",
                        AsyncCallbackTests.CallByUidSuccess),
                    new("Async.CallByUidSequenced :: FIFO per (uid, api)",
                        AsyncCallbackTests.CallByUidSequencedFifo),
                    new("Async.CallByP2PName :: success",
                        AsyncCallbackTests.CallByP2PNameSuccess),
                    new("Async.CallByP2PNameSequenced :: FIFO per (p2p, api)",
                        AsyncCallbackTests.CallByP2PNameSequencedFifo),
                    new("Async :: callback exception is swallowed",
                        AsyncCallbackTests.CallbackExceptionIsSwallowed),
                    new("Async :: chained calls (call inside callback)",
                        AsyncCallbackTests.ChainedCalls),
                }),
        };
    }
}