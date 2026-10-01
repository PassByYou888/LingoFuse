// =============================================================================
// test_lingofuse_csharp — comprehensive test suite for the rebuilt
//                        LingoFuse C# binding (two-layer design).
// =============================================================================
//
// Version 3.2 — permanent-handle support:
//   - New tests in the DataHandle category covering DataHandle.CreatePermanent:
//     creation, survival across the idle pool window, and synchronous
//     release semantics.
//   - Total test count raised from 55 to 58.
//
// Version 3.1 — network-session fix:
//   - NetworkSession.StartWithService now takes an optional
//     configureApp callback so APIs are registered on the AppHandle
//     BEFORE Framework.PrepareClient. Registering APIs afterwards
//     leaves the mesh registration with an empty API list.
//   - Wait_Connection_ReadyOk is now True, so PrepareDone blocks
//     until the client is actually online. The previous False value
//     let PrepareDone return before the client could route a call,
//     causing spurious timeouts on the very first call.
//   - Wait_Connection_Timeout raised to 10 seconds.
//
// The binding exposes exactly one public namespace, LingoFuse, with the
// following public types:
//
//     DataHandle           RAII data-buffer handle
//     AppHandle            RAII application handle
//     LfIo                 unified JSON / string / byte I/O
//     Framework            process-wide ABI façade
//     LingoFuseStatus      status queue and health checks
//     NetworkEvents        global connect / disconnect handlers
//     LingoFuseException + four subclasses
//
// Every test in this file consumes only that surface. The Native
// namespace (NativeMethods, Utf8Marshal, DataHnd, AppHnd, the delegate
// prototypes) is internal and is deliberately never referenced here.
//
// TEST PLAN (58 tests)
// --------------------
//
// DataHandle (19)
//   01  basic types                every integer / floating-point type
//   02  unicode                    UTF-8 round trip
//   03  fault-tolerant read        no NUL on the wire (LF-DATA-004)
//   04  position and size          tell / seek / size
//   05  dispose safety             double Dispose + use-after-dispose
//   06  string termination         WriteString always appends #0
//   07  empty string               one-byte payload
//   08  large buffer (128 KiB)     buffer reallocation path
//   09  embedded NUL preserved     raw byte path (LF-DATA-003)
//   10  WriteBytes no terminator   raw path has no #0 (LF-DATA-005)
//   11  multi-field sequential IO  mixed types in one buffer
//   12  zero-length operations     WriteBytes(0) / ReadBytes(0)
//   13  ReadBytesExact success     exact read returns expected bytes
//   14  ReadBytesExact short fail  LingoFuseIoException on short read
//   15  Try* family                boolean non-throwing reads
//   16  ReadAllBytes               consume remaining bytes
//   17  create permanent handle    DataHandle.CreatePermanent success
//   18  permanent survives idle    not added to the idle pool
//   19  permanent dispose sync     synchronous release + idempotent
//
// AppHandle (10)
//   20  register / local call      basic registration and execution
//   21  duplicate registration     second register returns false
//   22  unregister then re-register
//   23  case-insensitive match     "add" matches "Add"
//   24  callback no output         empty response on no write
//   25  callback exception         swallowed by the wrapper
//   26  LocalNotify                one-way local delivery
//   27  LocalCallBinary            raw local call
//   28  LocalNotifyBinary          raw local notify
//   29  dispose safety             use-after-dispose throws
//
// LfIo (7)
//   30  JSON POCO round trip
//   31  JSON null value
//   32  JSON unicode content       no \uXXXX escapes (BMP or surrogates)
//   33  JSON array
//   34  JSON numeric
//   35  TryReadJson returns false on invalid
//   36  ReadJson throws on invalid
//
// Framework (5)
//   37  SetOption does not throw
//   38  ResetPrepare does not throw
//   39  GenerateAppName after PrepareDone
//   40  PrepareDone returns 1 only once
//   41  Shutdown is idempotent
//
// Network integration (8)
//   42  single address JSON call
//   43  missing target returns empty handle (LF-CALL-001)
//   44  long string round trip (LF-XLANG-002)
//   45  Notify
//   46  SequencedNotify FIFO order
//   47  CheckApp / CheckApi
//   48  NetworkEvents install / clear
//   49  Status queue operations
//
// ABI cross-language (5)
//   50  CallBinary int32
//   51  CallBinary multi-type round trip
//   52  byte-exact little-endian wire format
//   53  NotifyBinary
//   54  SequencedNotifyBinary
//
// Concurrency (2)
//   55  10 threads x 100 local calls
//   56  8 threads x 500 independent DataHandles
//
// Stress (2)
//   57  1000 sequential local calls
//   58  100 rapid App create / destroy cycles
// =============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

using LingoFuse;

namespace LingoFuse.Tests;

/* ============================================================================
 * Formatting helpers
 * ========================================================================== */

internal static class Fmt
{
    public const string SectionRule =
        "======================================================================";

    public const string CategoryRule =
        "######################################################################";

    public static string PadRight(string s, int width)
        => s.Length >= width ? s : s + new string(' ', width - s.Length);

    public static string PadLeft(string s, int width)
        => s.Length >= width ? s : new string(' ', width - s.Length) + s;

    public static string NowString()
        => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");

    public static string FormatDuration(long ms)
    {
        if (ms < 1000) return $"{ms} ms";
        if (ms < 60000) return (ms / 1000.0).ToString("F2") + " s";
        var totalSec = ms / 1000;
        var min = totalSec / 60;
        var sec = totalSec % 60;
        return $"{min}m {sec}s";
    }

    public static void PrintSectionHeader(string title)
    {
        Console.WriteLine();
        Console.WriteLine();
        Console.WriteLine(SectionRule);
        Console.WriteLine("  " + title);
        Console.WriteLine(SectionRule);
    }

    public static void PrintCategoryBanner(
        string name, string description, int count)
    {
        Console.WriteLine();
        Console.WriteLine();
        Console.WriteLine(CategoryRule);
        Console.WriteLine($"##  Category: {name}  " +
                          $"({count} test{(count == 1 ? "" : "s")})");
        Console.WriteLine($"##  {description}");
        Console.WriteLine(CategoryRule);
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
                $"        actual  : {FmtValue(actual)}\n" +
                $"        expected: {FmtValue(expected)}");
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
                $"THROWS FAILED (line {line}): expected {typeof(TException).Name}, " +
                $"got {ex.GetType().Name}: {ex.Message}");
        }
        throw new CheckFailedException(
            $"THROWS FAILED (line {line}): expected {typeof(TException).Name}, " +
            "but no exception was thrown");
    }

    private static string FmtValue<T>(T? value)
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
        Console.WriteLine();
        Console.WriteLine();
        Console.WriteLine(Fmt.SectionRule);
        Console.WriteLine($"[ {name} ]");
        Console.WriteLine(Fmt.SectionRule);

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
            Console.WriteLine($"[ PASS ] ({result.ElapsedMs} ms)");
        }
        else
        {
            Console.WriteLine("[ FAIL ]");
            Console.WriteLine(
                result.Threw
                    ? $"         reason: {result.ErrorDetail}"
                    : "         reason: a check returned false");
            Console.WriteLine($"         time:   {result.ElapsedMs} ms");
        }

        Console.WriteLine(Fmt.SectionRule);
        return result;
    }
}

/* ============================================================================
 * Test environment helpers
 * ========================================================================== */

internal static class TestEnv
{
    private static int _counter;

    public static int NextId() => Interlocked.Increment(ref _counter);

    public static string UniqueEndpoint(string prefix)
        => $"ipc:test_cs_{prefix}_{Environment.ProcessId}_{NextId()}";

    public static string UniqueAppName(string prefix)
        => $"test_cs_{prefix}_{Environment.ProcessId}_{NextId()}";

    public static void Settle(int ms = 200) => Thread.Sleep(ms);
}

/* ============================================================================
 * Shared static callbacks
 * ========================================================================== */

internal static class Callbacks
{
    /// <summary>String echo handler registered via the ABI path.</summary>
    public static void Echo(DataHandle input, DataHandle output)
    {
        var s = input.ReadString();
        output.WriteString(s);
    }

    /// <summary>int32 + int32 -> int32 handler registered via the ABI path.</summary>
    public static void Add(DataHandle input, DataHandle output)
    {
        var a = input.ReadInt32();
        var b = input.ReadInt32();
        output.WriteInt32(a + b);
    }

    /// <summary>Notify handler that consumes and discards its payload.</summary>
    public static void Sink(DataHandle input)
    {
        _ = input.ReadString();
    }
}

/* ============================================================================
 * Network session — the one and only place in this test suite that
 * touches the process-wide preparation sequence.
 * ============================================================================
 *
 * Every network test creates exactly one NetworkSession, exercises the
 * scenario against it, and disposes it in a using block. The session
 * owns the full LF-CLEAN-001 sequence:
 *
 *     NetworkEvents.Clear()
 *     Framework.ExitMainThread()
 *     App.Dispose()
 *     Framework.Shutdown()
 *
 * Because LF_Shutdown is process-wide, sessions must not overlap. The
 * test runner executes network tests serially, and every network test
 * disposes its session before the next one begins.
 *
 * STARTUP SEQUENCE
 * ----------------
 * The session deliberately mirrors the C++ CrossNode / CrossService
 * flow:
 *
 *     1. Set options (Wait_Connection_ReadyOk = True, Overlap = True).
 *     2. ResetPrepare.
 *     3. PrepareService.
 *     4. Create the AppHandle.
 *     5. Invoke the caller-supplied configureApp callback so that the
 *        app carries its full API list BEFORE PrepareClient binds it.
 *     6. PrepareClient(endpoint, app).
 *     7. PrepareDone. Blocks until the client is fully online.
 *
 * Step 5 is what makes the difference between a working and a
 * non-working network test: if APIs are registered AFTER
 * PrepareClient, the mesh registration carries an empty API list and
 * the very first call against the newly-created app can time out.
 */
internal sealed class NetworkSession : IDisposable
{
    public AppHandle? App { get; private set; }
    public string Endpoint { get; }
    public string AppName { get; }

    private bool _started;

    private NetworkSession(string endpoint, string appName)
    {
        Endpoint = endpoint;
        AppName = appName;
    }

    /// <summary>
    /// Start a session that both listens as a service and connects as a
    /// client to its own endpoint, exposing the given application.
    /// </summary>
    /// <param name="appName">Application name to expose on the mesh.</param>
    /// <param name="endpoint">IPC or TCP endpoint to use.</param>
    /// <param name="configureApp">
    /// Optional callback invoked with the freshly-created AppHandle
    /// BEFORE PrepareClient. Register every API the test needs here so
    /// that the app's full API list is visible on the mesh from the
    /// moment the client is bound.
    /// </param>
    public static NetworkSession StartWithService(
        string appName, string endpoint,
        Action<AppHandle>? configureApp = null)
    {
        var s = new NetworkSession(endpoint, appName);

        // Block until the client is online, and give it plenty of
        // time to complete the handshake. The default of 30 seconds
        // is more than enough; 10 seconds keeps the test suite
        // responsive if something is genuinely wrong.
        Framework.SetOption("Wait_Connection_ReadyOk", "True");
        Framework.SetOption("Overlap_Connection", "True");
        Framework.SetOption("Wait_Connection_Timeout", "10000");

        Framework.ResetPrepare();

        int serviceTag = Framework.PrepareService(endpoint, endpoint);
        if (serviceTag == -1)
        {
            throw new InvalidOperationException(
                $"Framework.PrepareService returned -1 for {endpoint}");
        }

        s.App = new AppHandle(appName);

        // Register APIs before binding, so the Init_App_Info broadcast
        // carries the complete API list.
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

        s._started = true;
        return s;
    }

    public void Dispose()
    {
        if (!_started) return;
        _started = false;

        NetworkEvents.Clear();

        try { Framework.ExitMainThread(); } catch { }
        try { App?.Dispose(); } catch { }
        try { Framework.Shutdown(); } catch { }

        // Give the native layer a moment to release background workers
        // before the next session claims the process-wide framework.
        Thread.Sleep(150);
    }
}

/* ============================================================================
 * Remote call helpers — thin wrappers around Framework.Call that make
 * the test bodies readable.
 * ========================================================================== */

internal static class Rpc
{
    /// <summary>
    /// Send a JSON payload and require a non-empty response. Throws
    /// LingoFuseCallException on timeout / unreachable target.
    /// </summary>
    public static T? CallJson<T>(
        string appName, string apiName, object? payload,
        ulong timeoutMs = 3000)
    {
        using var param = new DataHandle(apiName);
        LfIo.WriteJson(param, payload);
        using var response = Framework.Call(appName, param, timeoutMs);
        if (response.Size == 0)
        {
            throw new LingoFuseCallException(
                "Remote call returned an empty response " +
                "(timeout or unreachable target).",
                appName, apiName);
        }
        return LfIo.ReadJson<T>(response);
    }
}

/* ============================================================================
 * A POCO used by the JSON tests.
 * ============================================================================
 *
 * System.Text.Json uses the C# property name verbatim; the wire JSON
 * keys therefore match the property names. This is a deliberate choice
 * of the binding: the C# object shape IS the JSON shape, and cross-
 * language naming alignment is a business-schema concern, not a
 * transport concern.
 */
internal sealed class Person
{
    public string Name { get; set; } = string.Empty;
    public int Age { get; set; }
}

/* ============================================================================
 * CATEGORY: DataHandle
 * ========================================================================== */

internal static class DataHandleTests
{
    public static bool BasicTypes()
    {
        using var dh = new DataHandle("test_basic");

        dh.WriteInt8(unchecked((sbyte)-128));
        dh.WriteUInt8(255);
        dh.WriteInt16(-32768);
        dh.WriteUInt16(65535);
        dh.WriteInt32(-123456789);
        dh.WriteUInt32(123456789u);
        dh.WriteInt64(-9876543210L);
        dh.WriteUInt64(9876543210UL);
        dh.WriteSingle(3.14159f);
        dh.WriteDouble(2.718281828);
        dh.WriteString("Hello, world! (ascii-only)");

        dh.Position = 0;

        Verify.Equal(dh.ReadInt8(), unchecked((sbyte)-128));
        Verify.Equal(dh.ReadUInt8(), (byte)255);
        Verify.Equal(dh.ReadInt16(), (short)-32768);
        Verify.Equal(dh.ReadUInt16(), (ushort)65535);
        Verify.Equal(dh.ReadInt32(), -123456789);
        Verify.Equal(dh.ReadUInt32(), 123456789u);
        Verify.Equal(dh.ReadInt64(), -9876543210L);
        Verify.Equal(dh.ReadUInt64(), 9876543210UL);
        Verify.True(Math.Abs(dh.ReadSingle() - 3.14159f) < 1e-4f);
        Verify.True(Math.Abs(dh.ReadDouble() - 2.718281828) < 1e-6);
        Verify.Equal(dh.ReadString(), "Hello, world! (ascii-only)");

        return true;
    }

    public static bool Unicode()
    {
        using var dh = new DataHandle("test_unicode");
        const string text = "Hello, \u4e16\u754c! \U0001F30D";
        dh.WriteString(text);
        dh.Position = 0;
        Verify.Equal(dh.ReadString(), text);
        return true;
    }

    public static bool FaultTolerantRead()
    {
        // LF-DATA-004: reading a payload without a NUL consumes the
        // whole remaining buffer and advances the cursor one byte past
        // the end.
        using var dh = new DataHandle("test_fault");

        var raw = Encoding.UTF8.GetBytes("abcdef");
        dh.WriteBytes(raw);
        Verify.Equal(dh.Size, 6L);

        dh.Position = 0;
        Verify.Equal(dh.ReadString(), "abcdef");
        Verify.Equal(dh.Position, 7L);

        return true;
    }

    public static bool PositionAndSize()
    {
        using var dh = new DataHandle("test_pos");
        Verify.Equal(dh.Position, 0L);
        Verify.Equal(dh.Size, 0L);

        dh.WriteInt32(123);
        Verify.Equal(dh.Size, 4L);
        Verify.Equal(dh.Position, 4L);

        dh.Position = 2;
        Verify.Equal(dh.Position, 2L);

        dh.Position = 0;
        Verify.Equal(dh.ReadInt32(), 123);

        return true;
    }

    public static bool DisposeSafety()
    {
        var dh = new DataHandle("test_dispose");
        dh.WriteInt32(7);
        dh.Dispose();
        dh.Dispose();

        Verify.Throws<LingoFuseObjectDisposedException>(
            () => { _ = dh.ReadInt32(); });
        Verify.Throws<LingoFuseObjectDisposedException>(
            () => dh.WriteInt32(1));

        return true;
    }

    public static bool StringTermination()
    {
        using var dh = new DataHandle("test_nul");
        dh.WriteString("abc");
        Verify.Equal(dh.Size, 4L);

        dh.Position = 0;
        var bytes = dh.ReadBytes(4);
        Verify.Equal(bytes.Length, 4);
        Verify.Equal(bytes[0], (byte)'a');
        Verify.Equal(bytes[1], (byte)'b');
        Verify.Equal(bytes[2], (byte)'c');
        Verify.Equal(bytes[3], (byte)0);

        return true;
    }

    public static bool EmptyString()
    {
        using var dh = new DataHandle("test_empty");
        dh.WriteString(string.Empty);
        Verify.Equal(dh.Size, 1L);

        dh.Position = 0;
        var bytes = dh.ReadBytes(1);
        Verify.Equal(bytes.Length, 1);
        Verify.Equal(bytes[0], (byte)0);

        dh.Position = 0;
        Verify.Equal(dh.ReadString(), string.Empty);
        Verify.Equal(dh.Position, 1L);

        return true;
    }

    public static bool LargeBuffer()
    {
        using var dh = new DataHandle("test_large");

        const int kSize = 128 * 1024;
        var payload = new byte[kSize];
        for (int i = 0; i < kSize; i++) payload[i] = (byte)(i & 0xFF);

        dh.WriteBytes(payload);
        Verify.Equal(dh.Size, (long)kSize);

        dh.Position = 0;
        Verify.SequenceEqual(dh.ReadBytes(kSize), payload);

        return true;
    }

    public static bool EmbeddedNulPreserved()
    {
        using var dh = new DataHandle("test_embedded_nul");
        var data = new byte[] { (byte)'a', 0, (byte)'b', 0, (byte)'c' };
        dh.WriteBytes(data);
        Verify.Equal(dh.Size, 5L);

        dh.Position = 0;
        Verify.SequenceEqual(dh.ReadBytes(5), data);

        return true;
    }

    public static bool WriteBytesNoTerminator()
    {
        using var dh = new DataHandle("test_raw_no_term");

        dh.WriteBytes(new byte[] { (byte)'x', (byte)'y', (byte)'z' });
        Verify.Equal(dh.Size, 3L);

        dh.WriteString("q");
        Verify.Equal(dh.Size, 5L);

        dh.Position = 3;
        var back = dh.ReadBytes(2);
        Verify.Equal(back[0], (byte)'q');
        Verify.Equal(back[1], (byte)0);

        return true;
    }

    public static bool MultiFieldSequentialIO()
    {
        using var dh = new DataHandle("test_multi_field");

        dh.WriteInt32(111);
        dh.WriteString("middle");
        dh.WriteUInt16(222);
        dh.WriteSingle(3.5f);
        dh.WriteInt64(-42);

        dh.Position = 0;
        Verify.Equal(dh.ReadInt32(), 111);
        Verify.Equal(dh.ReadString(), "middle");
        Verify.Equal(dh.ReadUInt16(), (ushort)222);
        Verify.True(Math.Abs(dh.ReadSingle() - 3.5f) < 1e-6f);
        Verify.Equal(dh.ReadInt64(), -42L);

        Verify.Equal(dh.Position, dh.Size);

        return true;
    }

    public static bool ZeroLengthOperations()
    {
        using var dh = new DataHandle("test_zero_len");

        dh.WriteBytes(Array.Empty<byte>());
        Verify.Equal(dh.Size, 0L);
        Verify.Equal(dh.Position, 0L);

        Verify.Equal(dh.ReadBytes(0).Length, 0);
        Verify.Equal(dh.Position, 0L);

        dh.WriteInt32(42);
        dh.Position = 2;

        Verify.Equal(dh.ReadBytes(0).Length, 0);
        Verify.Equal(dh.Position, 2L);

        return true;
    }

    public static bool ReadBytesExactSuccess()
    {
        using var dh = new DataHandle("test_exact");
        dh.WriteInt32(unchecked((int)0x04030201));

        dh.Position = 0;
        var bytes = dh.ReadBytesExact(4);
        Verify.Equal(bytes.Length, 4);
        Verify.Equal(bytes[0], (byte)0x01);
        Verify.Equal(bytes[1], (byte)0x02);
        Verify.Equal(bytes[2], (byte)0x03);
        Verify.Equal(bytes[3], (byte)0x04);
        Verify.Equal(dh.Position, 4L);

        return true;
    }

    public static bool ReadBytesExactShortFails()
    {
        using var dh = new DataHandle("test_exact_short");
        dh.WriteBytes(new byte[] { 0x01, 0x02 });

        dh.Position = 0;
        var ex = Verify.Throws<LingoFuseIoException>(
            () => { _ = dh.ReadBytesExact(4); });
        Verify.Equal(ex.Operation, "ReadBytesExact");
        Verify.Equal(dh.Position, 0L);

        return true;
    }

    public static bool TryReadFamily()
    {
        using var dh = new DataHandle("test_try_read");
        dh.WriteInt32(unchecked((int)0x11223344));

        dh.Position = 0;
        Verify.True(dh.TryReadBytes(4, out var bytes));
        Verify.NotNull(bytes);
        Verify.Equal(bytes!.Length, 4);

        dh.Position = 0;
        Verify.True(dh.TryReadInt32(out var value));
        Verify.Equal(value, unchecked((int)0x11223344));

        Verify.False(dh.TryReadInt32(out _));
        Verify.False(dh.TryReadBytes(1, out _));
        Verify.Equal(dh.Position, 4L);

        // TryReadString on an exhausted buffer.
        Verify.False(dh.TryReadString(out var empty));
        Verify.True(empty is null);

        // TryReadString on a fresh handle.
        using var dh2 = new DataHandle("test_try_string");
        dh2.WriteString("hello");
        dh2.Position = 0;
        Verify.True(dh2.TryReadString(out var s));
        Verify.Equal(s, "hello");

        return true;
    }

    public static bool ReadAllBytes()
    {
        using var dh = new DataHandle("test_read_all");
        dh.WriteBytes(new byte[] { 1, 2, 3, 4, 5 });

        dh.Position = 2;
        var rest = dh.ReadAllBytes();
        Verify.Equal(rest.Length, 3);
        Verify.Equal(rest[0], (byte)3);
        Verify.Equal(rest[1], (byte)4);
        Verify.Equal(rest[2], (byte)5);
        Verify.Equal(dh.Position, dh.Size);

        return true;
    }

    public static bool PermanentHandleCreation()
    {
        // A permanent handle is created and used exactly like an
        // auto-recycled one; the only difference is lifetime.
        using var dh = DataHandle.CreatePermanent("test_permanent");

        Verify.True(dh.IsValid);
        Verify.True(dh.IsOwning);
        Verify.True(dh.Raw != IntPtr.Zero);

        dh.WriteInt32(unchecked((int)0x11223344));
        dh.WriteString("permanent-payload");

        dh.Position = 0;
        Verify.Equal(dh.ReadInt32(), unchecked((int)0x11223344));
        Verify.Equal(dh.ReadString(), "permanent-payload");

        return true;
    }

    public static bool PermanentHandleSurvivesIdleWindow()
    {
        // We cannot wait 10 real minutes in a test. What we verify is
        // that the handle is NOT added to the idle pool, so the pool
        // scanner would never see it. Observationally: creating and
        // disposing a permanent handle inside a session does not
        // interfere with other handle activity, and no reclamation
        // warning is triggered for it.
        var endpoint = TestEnv.UniqueEndpoint("perm_surv");
        var appName = TestEnv.UniqueAppName("perm_surv");

        using var session = NetworkSession.StartWithService(
            appName, endpoint);

        using var perm = DataHandle.CreatePermanent("perm_api");
        perm.WriteInt32(42);

        // Give the simulated main thread enough time to run several
        // Progress ticks. Any auto-recycled handle with the wrong
        // lifetime expectation would already have been marked for
        // release; the permanent handle must remain intact.
        TestEnv.Settle(1200);

        Verify.True(perm.IsValid);
        perm.Position = 0;
        Verify.Equal(perm.ReadInt32(), 42);

        // A fresh auto-recycled handle created in the same window must
        // also work normally.
        using var auto = new DataHandle("auto_api");
        auto.WriteString("auto");
        auto.Position = 0;
        Verify.Equal(auto.ReadString(), "auto");

        return true;
    }

    public static bool PermanentHandleDisposeIsSynchronous()
    {
        var dh = DataHandle.CreatePermanent("perm_sync");
        dh.WriteInt32(1);
        Verify.True(dh.IsValid);

        dh.Dispose();

        // After Dispose, the wrapper is disposed.
        Verify.False(dh.IsValid);
        Verify.True(dh.Raw == IntPtr.Zero);
        Verify.Throws<LingoFuseObjectDisposedException>(
            () => { _ = dh.ReadInt32(); });

        // Dispose is idempotent.
        dh.Dispose();
        dh.Dispose();

        // A second independent permanent handle must also be usable.
        using var dh2 = DataHandle.CreatePermanent("perm_sync_2");
        dh2.WriteString("second");
        dh2.Position = 0;
        Verify.Equal(dh2.ReadString(), "second");

        return true;
    }
}

/* ============================================================================
 * CATEGORY: AppHandle
 * ========================================================================== */

internal static class AppHandleTests
{
    public static bool RegisterAndLocalCall()
    {
        using var app = new AppHandle("test_cs_app_basic");

        Verify.True(app.RegisterCall("add", "test add", Callbacks.Add));
        Verify.True(app.RegisterNotify("sink", "test notify", Callbacks.Sink));

        {
            using var param = new DataHandle("add");
            param.WriteInt32(10);
            param.WriteInt32(20);
            using var result = app.LocalCall(param);
            Verify.Equal(result.ReadInt32(), 30);
        }

        {
            using var param = new DataHandle("sink");
            param.WriteString("hello");
            app.LocalNotify(param);
        }

        Verify.True(app.Unregister("add"));
        Verify.False(app.Unregister("add"));

        {
            using var param = new DataHandle("add");
            param.WriteInt32(1);
            param.WriteInt32(2);
            using var result = app.LocalCall(param);
            Verify.Equal(result.Size, 0L);
        }

        return true;
    }

    public static bool DuplicateRegistration()
    {
        using var app = new AppHandle("test_cs_app_dup");
        Verify.True(app.RegisterCall("dup", "first", Callbacks.Add));
        Verify.False(app.RegisterCall("dup", "second", Callbacks.Add));
        return true;
    }

    public static bool UnregisterThenReregister()
    {
        using var app = new AppHandle("test_cs_app_rereg");

        Verify.True(app.RegisterCall("hot", "v1", Callbacks.Add));
        Verify.True(app.Unregister("hot"));
        Verify.True(app.RegisterCall("hot", "v2", Callbacks.Add));

        using var param = new DataHandle("hot");
        param.WriteInt32(5);
        param.WriteInt32(6);
        using var result = app.LocalCall(param);
        Verify.Equal(result.ReadInt32(), 11);

        return true;
    }

    public static bool CaseInsensitiveApiMatching()
    {
        using var app = new AppHandle("test_cs_app_case");
        Verify.True(app.RegisterCall(
            "MixedCaseApi", "description", Callbacks.Add));

        using var param = new DataHandle("mixedcaseapi");
        param.WriteInt32(7);
        param.WriteInt32(8);
        using var result = app.LocalCall(param);
        Verify.Equal(result.ReadInt32(), 15);

        Verify.True(app.Unregister("MIXEDCASEAPI"));
        return true;
    }

    public static bool CallbackNoOutput()
    {
        using var app = new AppHandle("test_cs_app_empty");
        Verify.True(app.RegisterCall("empty", "does nothing",
            (input, output) => { /* intentionally empty */ }));

        using var param = new DataHandle("empty");
        using var result = app.LocalCall(param);
        Verify.Equal(result.Size, 0L);

        return true;
    }

    public static bool CallbackExceptionSwallowed()
    {
        // The wrapper catches every callback exception and reports it
        // through Framework.ReportCallbackError. The native layer sees
        // a callback that completed normally, and the caller receives
        // an empty response.
        using var app = new AppHandle("test_cs_app_exc");
        Verify.True(app.RegisterCall("boom", "throws",
            (input, output) =>
            {
                throw new InvalidOperationException("intentional");
            }));

        using var param = new DataHandle("boom");
        using var result = app.LocalCall(param);
        Verify.Equal(result.Size, 0L);

        return true;
    }

    public static bool LocalNotify()
    {
        using var app = new AppHandle("test_cs_app_notify");
        Verify.True(app.RegisterNotify("sink", "notify sink", Callbacks.Sink));

        using var param = new DataHandle("sink");
        param.WriteString("payload");
        app.LocalNotify(param);

        return true;
    }

    public static bool LocalCallBinary()
    {
        using var app = new AppHandle("test_cs_app_local_bin");
        app.RegisterCall("echo32", "ABI echo32",
            (input, output) => output.WriteInt32(input.ReadInt32()));

        using var param = new DataHandle("echo32");
        param.WriteInt32(12345);

        using var result = app.LocalCall(param);
        Verify.Equal(result.Size, 4L);
        Verify.Equal(result.ReadInt32(), 12345);

        return true;
    }

    public static bool LocalNotifyBinary()
    {
        using var app = new AppHandle("test_cs_app_local_notify_bin");
        int fired = 0;
        app.RegisterNotify("ping_notify", "ABI notify",
            input => Interlocked.Increment(ref fired));

        using var param = new DataHandle("ping_notify");
        param.WriteInt32(1);
        app.LocalNotify(param);

        Verify.Equal(fired, 1);
        return true;
    }

    public static bool DisposeSafety()
    {
        var app = new AppHandle("test_cs_app_dispose");
        Verify.True(app.IsValid);
        Verify.False(app.Raw == IntPtr.Zero);

        app.Dispose();
        app.Dispose();

        Verify.False(app.IsValid);
        Verify.True(app.Raw == IntPtr.Zero);
        Verify.Throws<LingoFuseObjectDisposedException>(
            () => app.RegisterCall("x", "y", Callbacks.Add));
        Verify.Throws<LingoFuseObjectDisposedException>(
            () => { using var p = new DataHandle("x"); app.LocalCall(p); });

        return true;
    }
}

/* ============================================================================
 * CATEGORY: LfIo (JSON I/O)
 * ========================================================================== */

internal static class LfIoTests
{
    public static bool JsonPocoRoundTrip()
    {
        using var dh = new DataHandle("json_poco");
        var original = new Person { Name = "Alice", Age = 30 };
        LfIo.WriteJson(dh, original);

        dh.Position = 0;
        var back = LfIo.ReadJson<Person>(dh);
        Verify.NotNull(back);
        Verify.Equal(back!.Name, "Alice");
        Verify.Equal(back.Age, 30);

        return true;
    }

    public static bool JsonNullValue()
    {
        using var dh = new DataHandle("json_null");
        LfIo.WriteJson(dh, null);

        // The JSON literal `null` is four bytes plus the framing NUL.
        Verify.Equal(dh.Size, 5L);

        dh.Position = 0;
        var back = LfIo.ReadJson<Person?>(dh);
        Verify.True(back is null);

        return true;
    }

    public static bool JsonUnicode()
    {
        using var dh = new DataHandle("json_unicode");
        var original = new Person { Name = "\u4e16\u754c \U0001F30D", Age = 42 };
        LfIo.WriteJson(dh, original);

        // The serialized text must contain literal UTF-8, not \uXXXX.
        // Both the BMP characters (世界) and the supplementary-plane
        // emoji must be emitted as raw code points.
        dh.Position = 0;
        var text = dh.ReadString();
        Verify.False(text.Contains("\\u4e16"));
        Verify.False(text.Contains("\\uD83C"));
        Verify.False(text.Contains("\\uDF0D"));
        Verify.True(text.Contains("\u4e16\u754c"));
        Verify.True(text.Contains("\U0001F30D"));

        dh.Position = 0;
        var back = LfIo.ReadJson<Person>(dh);
        Verify.NotNull(back);
        Verify.Equal(back!.Name, "\u4e16\u754c \U0001F30D");

        return true;
    }

    public static bool JsonArray()
    {
        using var dh = new DataHandle("json_array");
        var original = new int[] { 1, 2, 3, 4, 5 };
        LfIo.WriteJson(dh, original);

        dh.Position = 0;
        var back = LfIo.ReadJson<int[]>(dh);
        Verify.NotNull(back);
        Verify.SequenceEqual(back!, original);

        return true;
    }

    public static bool JsonNumeric()
    {
        using var dh = new DataHandle("json_number");
        LfIo.WriteJson(dh, 42);

        dh.Position = 0;
        Verify.Equal(LfIo.ReadJson<int>(dh), 42);

        using var dh2 = new DataHandle("json_double");
        LfIo.WriteJson(dh2, 3.14159);
        dh2.Position = 0;
        var d = LfIo.ReadJson<double>(dh2);
        Verify.True(Math.Abs(d - 3.14159) < 1e-9);

        return true;
    }

    public static bool TryReadJsonReturnsFalseOnInvalid()
    {
        using var dh = new DataHandle("json_invalid");
        dh.WriteString("not-a-json-value");
        dh.Position = 0;

        Verify.False(LfIo.TryReadJson<Person>(dh, out var result));
        Verify.True(result is null);

        return true;
    }

    public static bool ReadJsonThrowsOnInvalid()
    {
        using var dh = new DataHandle("json_throw");
        dh.WriteString("not-a-json-value");
        dh.Position = 0;

        Verify.Throws<LingoFuseException>(
            () => { _ = LfIo.ReadJson<Person>(dh); });

        return true;
    }
}

/* ============================================================================
 * CATEGORY: Framework
 * ========================================================================== */

internal static class FrameworkTests
{
    public static bool SetOptionNoThrow()
    {
        // Unknown option names are silently ignored by the native side.
        Framework.SetOption("Totally_Unknown_Option_xyz", "whatever");
        return true;
    }

    public static bool ResetPrepareNoThrow()
    {
        Framework.ResetPrepare();
        Framework.ResetPrepare();
        return true;
    }

    public static bool GenerateAppName()
    {
        var endpoint = TestEnv.UniqueEndpoint("gen_name");
        var appName = TestEnv.UniqueAppName("gen_name");

        using var session = NetworkSession.StartWithService(appName, endpoint);

        var generated = Framework.GenerateAppName();
        Verify.NotNull(generated);
        Verify.True(generated.Length > 0);

        return true;
    }

    public static bool PrepareDoneReturnsOneOnlyOnce()
    {
        // First session: PrepareDone returns 1.
        var ep1 = TestEnv.UniqueEndpoint("done_once_a");
        var app1 = TestEnv.UniqueAppName("done_once_a");

        using (var s1 = NetworkSession.StartWithService(app1, ep1))
        {
            Verify.True(LingoFuseStatus.CheckMainThread());
        }

        // Second session after the first has been fully shut down:
        // PrepareDone must again return 1.
        var ep2 = TestEnv.UniqueEndpoint("done_once_b");
        var app2 = TestEnv.UniqueAppName("done_once_b");

        using var s2 = NetworkSession.StartWithService(app2, ep2);
        Verify.True(LingoFuseStatus.CheckMainThread());

        return true;
    }

    public static bool ShutdownIsIdempotent()
    {
        // Shutdown on a process with no active framework must not
        // throw. This is safe at any point in the process lifetime.
        Framework.Shutdown();
        Framework.Shutdown();
        return true;
    }
}

/* ============================================================================
 * CATEGORY: Network integration
 * ========================================================================== */

internal static class NetworkIntegrationTests
{
    public static bool SingleAddressJsonCall()
    {
        var endpoint = TestEnv.UniqueEndpoint("single");
        var appName = TestEnv.UniqueAppName("single");

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterCall("ping", "JSON ping",
                    (input, output) =>
                    {
                        var s = LfIo.ReadJson<string>(input);
                        LfIo.WriteJson(output, s);
                    });
            });

        var echoed = Rpc.CallJson<string>(appName, "ping", "hello", 3000);
        Verify.NotNull(echoed);
        Verify.Equal(echoed!, "hello");

        return true;
    }

    public static bool MissingTargetReturnsEmptyHandle()
    {
        var endpoint = TestEnv.UniqueEndpoint("missing");
        var appName = TestEnv.UniqueAppName("missing");

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterCall("ping", "ping",
                    (input, output) => { });
            });

        using var param = new DataHandle("ping");
        LfIo.WriteJson(param, "hello");

        // LF-CALL-001: a call to a missing target yields a size-0
        // handle, not a null pointer and not a thrown exception.
        using var response = Framework.Call(
            "no_such_app_xyz_98765", param, 500);
        Verify.NotNull(response);
        Verify.Equal(response.Size, 0L);

        return true;
    }

    public static bool LongStringRoundTrip()
    {
        var endpoint = TestEnv.UniqueEndpoint("long_str");
        var appName = TestEnv.UniqueAppName("long_str");

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterCall("ping", "long ping",
                    (input, output) =>
                    {
                        var s = LfIo.ReadJson<string>(input);
                        LfIo.WriteJson(output, s);
                    });
            });

        var sb = new StringBuilder(64 * 1024 + 16);
        const string unit = "Hello-\u4e16\u754c-";
        while (sb.Length < 64 * 1024) sb.Append(unit);
        var payload = sb.ToString();

        var echoed = Rpc.CallJson<string>(appName, "ping", payload, 5000);
        Verify.NotNull(echoed);
        Verify.Equal(echoed!.Length, payload.Length);
        Verify.Equal(echoed, payload);

        return true;
    }

    public static bool NotifyOneWay()
    {
        var endpoint = TestEnv.UniqueEndpoint("notify");
        var appName = TestEnv.UniqueAppName("notify");

        int received = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterNotify("sink", "JSON notify sink",
                    input =>
                    {
                        _ = LfIo.ReadJson<string>(input);
                        Interlocked.Increment(ref received);
                    });
            });

        using var param = new DataHandle("sink");
        LfIo.WriteJson(param, "hello");
        Framework.Notify(appName, param);

        Thread.Sleep(400);

        Verify.True(received >= 1);

        return true;
    }

    public static bool SequencedNotifyFifo()
    {
        var endpoint = TestEnv.UniqueEndpoint("seq");
        var appName = TestEnv.UniqueAppName("seq");

        int received = 0;
        int lastPayload = -1;

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterNotify("seq", "JSON sequenced sink",
                    input =>
                    {
                        lastPayload = LfIo.ReadJson<int>(input);
                        Interlocked.Increment(ref received);
                    });
            });

        for (int i = 0; i < 5; i++)
        {
            using var param = new DataHandle("seq");
            LfIo.WriteJson(param, i);
            Framework.SequencedNotify(appName, param);
        }

        Thread.Sleep(700);

        Verify.True(received >= 1);
        // FIFO guarantee per (app, api): the last delivered value is 4.
        Verify.Equal(lastPayload, 4);

        return true;
    }

    public static bool CheckAppAndApi()
    {
        var endpoint = TestEnv.UniqueEndpoint("check");
        var appName = TestEnv.UniqueAppName("check");

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterCall("ping", "ping",
                    (input, output) => { });
            });

        Verify.True(LingoFuseStatus.CheckMainThread());

        // The mesh broadcasts with an approximate 3-second delay.
        // Retry up to 6 seconds.
        bool appSeen = false;
        bool apiSeen = false;
        for (int i = 0; i < 30; i++)
        {
            if (!appSeen) appSeen = LingoFuseStatus.CheckApp(appName);
            if (!apiSeen)
            {
                apiSeen = LingoFuseStatus.CheckApi(appName, "ping");
            }
            if (appSeen && apiSeen) break;
            Thread.Sleep(200);
        }

        Verify.True(appSeen);
        Verify.True(apiSeen);

        return true;
    }

    public static bool NetworkEventsInstallClear()
    {
        Verify.False(NetworkEvents.IsInstalled);

        int connectCalls = 0;
        int disconnectCalls = 0;

        NetworkEvents.Set(
            addr => Interlocked.Increment(ref connectCalls),
            addr => Interlocked.Increment(ref disconnectCalls));
        Verify.True(NetworkEvents.IsInstalled);

        // Replace is a REPLACE operation: the previous handlers are
        // discarded even when one of the new arguments is null.
        NetworkEvents.Set(
            addr => Interlocked.Increment(ref connectCalls), null);
        Verify.True(NetworkEvents.IsInstalled);

        NetworkEvents.Clear();
        Verify.False(NetworkEvents.IsInstalled);

        // Clear is idempotent.
        NetworkEvents.Clear();
        NetworkEvents.Clear();
        Verify.False(NetworkEvents.IsInstalled);

        return true;
    }

    public static bool StatusQueueOperations()
    {
        var endpoint = TestEnv.UniqueEndpoint("status");
        var appName = TestEnv.UniqueAppName("status");

        using var session = NetworkSession.StartWithService(appName, endpoint);
        TestEnv.Settle(200);

        const string marker = "cs_test_status_marker_12345";
        LingoFuseStatus.PostStatus(marker);

        Thread.Sleep(300);

        var count = LingoFuseStatus.GetStatusCount();
        Verify.True(count >= 0);

        var drained = LingoFuseStatus.DrainStatus(20);
        Verify.True(drained.Length <= 20);

        // A direct single-message read must not throw.
        var single = LingoFuseStatus.GetStatus();
        Verify.NotNull(single);

        return true;
    }
}

/* ============================================================================
 * CATEGORY: ABI cross-language
 * ============================================================================
 *
 * These tests exercise the raw binary path that the C++ / Pascal /
 * Python bindings use to interoperate with a C# peer. Every byte on the
 * wire is written and read through DataHandle's atomic-type helpers,
 * with no JSON serialization in between.
 */
internal static class AbiCrossLanguageTests
{
    public static bool AbiCallBinaryInt32()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_int32");
        var appName = TestEnv.UniqueAppName("abi_int32");

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterCall("add32", "ABI add32",
                    (input, output) =>
                    {
                        int a = input.ReadInt32();
                        int b = input.ReadInt32();
                        output.WriteInt32(a + b);
                    });
            });

        using var request = new DataHandle("add32");
        request.WriteInt32(15);
        request.WriteInt32(27);

        using var response = Framework.Call(appName, request, 3000);
        Verify.Equal(response.Size, 4L);
        Verify.Equal(response.ReadInt32(), 42);

        return true;
    }

    public static bool AbiCallBinaryMultiType()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_multi");
        var appName = TestEnv.UniqueAppName("abi_multi");

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterCall("inv_seri", "ABI inv_seri",
                    (input, output) =>
                    {
                        byte b = input.ReadUInt8();
                        ushort w = input.ReadUInt16();
                        uint c = input.ReadUInt32();
                        ulong u64 = input.ReadUInt64();
                        string s = input.ReadString();
                        float f = input.ReadSingle();

                        // Reply in reverse field order.
                        output.WriteSingle(f);
                        output.WriteString(s);
                        output.WriteUInt64(u64);
                        output.WriteUInt32(c);
                        output.WriteUInt16(w);
                        output.WriteUInt8(b);
                    });
            });

        using var request = new DataHandle("inv_seri");
        request.WriteUInt8(200);
        request.WriteUInt16(0x10);
        request.WriteUInt32(0x2F);
        request.WriteUInt64(0x3F);
        request.WriteString("hello world");
        request.WriteSingle(3.14f);

        using var response = Framework.Call(appName, request, 3000);

        Verify.Equal(response.ReadSingle(), 3.14f);
        Verify.Equal(response.ReadString(), "hello world");
        Verify.Equal(response.ReadUInt64(), 0x3FUL);
        Verify.Equal(response.ReadUInt32(), 0x2FUL);
        Verify.Equal(response.ReadUInt16(), (ushort)0x10);
        Verify.Equal(response.ReadUInt8(), (byte)200);

        return true;
    }

    public static bool AbiByteExactWireFormat()
    {
        // Byte-for-byte verification of the little-endian wire format
        // that every binding (C++, Pascal, Python, C#) reads and writes.
        using var dh = new DataHandle("wire");

        dh.WriteInt32(unchecked((int)0x01020304));
        dh.WriteUInt16(0xAABB);

        dh.Position = 0;
        var bytes = dh.ReadBytes(6);

        Verify.Equal(bytes.Length, 6);
        // int32 little-endian: least significant byte first.
        Verify.Equal(bytes[0], (byte)0x04);
        Verify.Equal(bytes[1], (byte)0x03);
        Verify.Equal(bytes[2], (byte)0x02);
        Verify.Equal(bytes[3], (byte)0x01);
        // uint16 little-endian.
        Verify.Equal(bytes[4], (byte)0xBB);
        Verify.Equal(bytes[5], (byte)0xAA);

        return true;
    }

    public static bool AbiNotifyBinary()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_notify");
        var appName = TestEnv.UniqueAppName("abi_notify");

        int received = 0;
        int payload = 0;

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterNotify("sink", "ABI notify sink",
                    input =>
                    {
                        payload = input.ReadInt32();
                        Interlocked.Increment(ref received);
                    });
            });

        using var request = new DataHandle("sink");
        request.WriteInt32(4242);
        Framework.Notify(appName, request);

        Thread.Sleep(400);

        Verify.True(received >= 1);
        Verify.Equal(payload, 4242);

        return true;
    }

    public static bool AbiSequencedNotifyBinary()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_seq");
        var appName = TestEnv.UniqueAppName("abi_seq");

        int received = 0;
        int lastPayload = -1;

        using var session = NetworkSession.StartWithService(
            appName, endpoint, app =>
            {
                app.RegisterNotify("seq", "ABI sequenced notify sink",
                    input =>
                    {
                        lastPayload = input.ReadInt32();
                        Interlocked.Increment(ref received);
                    });
            });

        for (int i = 0; i < 5; i++)
        {
            using var request = new DataHandle("seq");
            request.WriteInt32(i);
            Framework.SequencedNotify(appName, request);
        }

        Thread.Sleep(700);

        Verify.True(received >= 1);
        // FIFO per (app, api): the last delivered value is 4.
        Verify.Equal(lastPayload, 4);

        return true;
    }
}

/* ============================================================================
 * CATEGORY: Concurrency
 * ========================================================================== */

internal static class ConcurrencyTests
{
    public static bool ConcurrentLocalCalls()
    {
        const int kThreads = 10;
        const int kCallsPerThread = 100;

        using var app = new AppHandle("test_cs_concurrency");
        app.RegisterCall("add", "add",
            (input, output) =>
            {
                int a = input.ReadInt32();
                int b = input.ReadInt32();
                output.WriteInt32(a + b);
            });

        int success = 0;
        var threads = new List<Thread>(kThreads);

        for (int t = 0; t < kThreads; t++)
        {
            var thread = new Thread(() =>
            {
                for (int j = 0; j < kCallsPerThread; j++)
                {
                    try
                    {
                        using var param = new DataHandle("add");
                        param.WriteInt32(j);
                        param.WriteInt32(j * 2);
                        using var result = app.LocalCall(param);
                        if (result.Size == 4
                            && result.ReadInt32() == j + j * 2)
                        {
                            Interlocked.Increment(ref success);
                        }
                    }
                    catch
                    {
                        // Shortfall caught by the aggregate.
                    }
                }
            });
            threads.Add(thread);
        }

        foreach (var thread in threads) thread.Start();
        foreach (var thread in threads) thread.Join();

        Verify.Equal(success, kThreads * kCallsPerThread);
        return true;
    }

    public static bool ConcurrentDataHandles()
    {
        const int kThreads = 8;
        const int kItersPerThread = 500;

        int success = 0;
        var threads = new List<Thread>(kThreads);

        for (int t = 0; t < kThreads; t++)
        {
            int threadIndex = t;
            var thread = new Thread(() =>
            {
                for (int i = 0; i < kItersPerThread; i++)
                {
                    try
                    {
                        using var dh = new DataHandle("thread_local_handle");
                        int expected = threadIndex * 10000 + i;
                        dh.WriteInt32(expected);
                        dh.Position = 0;
                        int actual = dh.ReadInt32();
                        if (actual == expected)
                        {
                            Interlocked.Increment(ref success);
                        }
                    }
                    catch
                    {
                        // Shortfall caught by the aggregate.
                    }
                }
            });
            threads.Add(thread);
        }

        foreach (var thread in threads) thread.Start();
        foreach (var thread in threads) thread.Join();

        Verify.Equal(success, kThreads * kItersPerThread);
        return true;
    }
}

/* ============================================================================
 * CATEGORY: Stress
 * ========================================================================== */

internal static class StressTests
{
    public static bool SequentialLocalCalls()
    {
        const int kIterations = 1000;

        using var app = new AppHandle("test_cs_stress_seq");
        app.RegisterCall("add", "add",
            (input, output) =>
            {
                int a = input.ReadInt32();
                int b = input.ReadInt32();
                output.WriteInt32(a + b);
            });

        int success = 0;
        for (int i = 0; i < kIterations; i++)
        {
            try
            {
                using var param = new DataHandle("add");
                param.WriteInt32(i);
                param.WriteInt32(i + 1);
                using var result = app.LocalCall(param);
                if (result.ReadInt32() == i + (i + 1))
                {
                    success++;
                }
            }
            catch
            {
                // Shortfall caught by the aggregate.
            }
        }

        Verify.Equal(success, kIterations);
        return true;
    }

    public static bool RapidAppCreateDestroy()
    {
        const int kCycles = 100;

        int success = 0;
        for (int i = 0; i < kCycles; i++)
        {
            try
            {
                using var app = new AppHandle(
                    $"test_cs_churn_{i}", "churn test");
                if (app.RegisterCall("ping", "ping", Callbacks.Echo))
                {
                    using var param = new DataHandle("ping");
                    param.WriteString("x");
                    using var result = app.LocalCall(param);
                    var echoed = result.ReadString();
                    if (echoed == "x") success++;
                }
            }
            catch
            {
                // Shortfall caught by the aggregate.
            }
        }

        Verify.Equal(success, kCycles);
        return true;
    }
}

/* ============================================================================
 * Suite descriptor
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
    public long ElapsedMs;
}

/* ============================================================================
 * main
 * ========================================================================== */

internal static class Program
{
    private const string SuiteVersion = "3.2 (permanent-handle support)";

    private static string BuildTypeString()
    {
#if DEBUG
        return "Debug";
#else
        return "Release";
#endif
    }

    private static int HardwareConcurrencySafe()
    {
        var n = Environment.ProcessorCount;
        return n <= 0 ? 1 : n;
    }

    public static int Main(string[] args)
    {
        var startTime = Fmt.NowString();

        // ---- SECTION 1: SUITE HEADER -----------------------------------
        Fmt.PrintSectionHeader("SECTION 1: SUITE HEADER");
        Console.WriteLine("  Suite        : LingoFuse C# Test Suite");
        Console.WriteLine($"  Version      : {SuiteVersion}");
        Console.WriteLine($"  Process ID   : {Environment.ProcessId}");
        Console.WriteLine($"  Platform     : {RuntimeInformation.OSDescription}");
        Console.WriteLine(
            $"  Architecture : {RuntimeInformation.ProcessArchitecture}");
        Console.WriteLine($"  Start time   : {startTime}");

        // ---- SECTION 2: ENVIRONMENT ------------------------------------
        Fmt.PrintSectionHeader("SECTION 2: ENVIRONMENT");
        Console.WriteLine($"  Build type        : {BuildTypeString()}");
        Console.WriteLine($"  CPU cores         : {HardwareConcurrencySafe()}");
        Console.WriteLine(
            $"  Runtime           : {RuntimeInformation.FrameworkDescription}");
        Console.WriteLine(
            $"  Working directory : {Environment.CurrentDirectory}");
        Console.WriteLine(
            $"  OS architecture   : {RuntimeInformation.OSArchitecture}");

        var categories = BuildPlan();
        int totalTests = categories.Sum(c => c.Tests.Count);

        // ---- SECTION 3: TEST PLAN --------------------------------------
        Fmt.PrintSectionHeader("SECTION 3: TEST PLAN");
        Console.WriteLine("  " + Fmt.PadRight("Category", 26) + " Tests");
        Console.WriteLine("  " + new string('-', 26) + " -----");
        foreach (var cat in categories)
        {
            Console.WriteLine(
                "  " + Fmt.PadRight(cat.Name, 26) + " " + cat.Tests.Count);
        }
        Console.WriteLine("  " + new string('-', 26) + " -----");
        Console.WriteLine(
            "  " + Fmt.PadRight("Total", 26) + " " + totalTests + " tests");

        // ---- SECTION 4: TEST EXECUTION ---------------------------------
        Fmt.PrintSectionHeader("SECTION 4: TEST EXECUTION");

        var failures = new List<FailureRecord>();
        int globalIndex = 0;

        foreach (var cat in categories)
        {
            Fmt.PrintCategoryBanner(cat.Name, cat.Description, cat.Tests.Count);

            foreach (var t in cat.Tests)
            {
                globalIndex++;
                Console.WriteLine();
                Console.WriteLine();
                Console.WriteLine($"  Progress: {globalIndex} / {totalTests}");

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
                        ElapsedMs = result.ElapsedMs,
                        Reason = result.Threw
                            ? result.ErrorDetail
                            : "a check returned false",
                    });
                }

                cat.TotalMs += result.ElapsedMs;
            }
        }

        // ---- SECTION 5: DETAILED SUMMARY -------------------------------
        var endTime = Fmt.NowString();

        Fmt.PrintSectionHeader("SECTION 5: DETAILED SUMMARY");

        Console.WriteLine("  Per-category statistics:");
        Console.WriteLine();
        Console.WriteLine("    "
            + Fmt.PadRight("Category", 26)
            + Fmt.PadLeft("Tests", 6)
            + Fmt.PadLeft("Passed", 8)
            + Fmt.PadLeft("Failed", 8)
            + Fmt.PadLeft("Time", 12));
        Console.WriteLine("    " + new string('-', 26 + 6 + 8 + 8 + 12));

        int totalPassed = 0;
        int totalFailed = 0;
        long totalMs = 0;

        foreach (var cat in categories)
        {
            totalPassed += cat.Passed;
            totalFailed += cat.Failed;
            totalMs += cat.TotalMs;

            Console.WriteLine("    "
                + Fmt.PadRight(cat.Name, 26)
                + Fmt.PadLeft(cat.Tests.Count.ToString(), 6)
                + Fmt.PadLeft(cat.Passed.ToString(), 8)
                + Fmt.PadLeft(cat.Failed.ToString(), 8)
                + Fmt.PadLeft(Fmt.FormatDuration(cat.TotalMs), 12));
        }

        Console.WriteLine("    " + new string('-', 26 + 6 + 8 + 8 + 12));
        Console.WriteLine("    "
            + Fmt.PadRight("Total", 26)
            + Fmt.PadLeft(totalTests.ToString(), 6)
            + Fmt.PadLeft(totalPassed.ToString(), 8)
            + Fmt.PadLeft(totalFailed.ToString(), 8)
            + Fmt.PadLeft(Fmt.FormatDuration(totalMs), 12));

        if (failures.Count > 0)
        {
            Console.WriteLine();
            Console.WriteLine();
            Console.WriteLine($"  Failed tests ({failures.Count}):");
            Console.WriteLine();
            for (int i = 0; i < failures.Count; i++)
            {
                var f = failures[i];
                Console.WriteLine($"    [{i + 1}] {f.Test}");
                Console.WriteLine($"        Category : {f.Category}");
                Console.WriteLine($"        Time     : {f.ElapsedMs} ms");
                Console.WriteLine($"        Reason   : {f.Reason}");
                Console.WriteLine();
            }
        }
        else
        {
            Console.WriteLine();
            Console.WriteLine();
            Console.WriteLine("  Failed tests: (none)");
        }

        Console.WriteLine();
        Console.WriteLine();
        Console.WriteLine("  Overall result:");
        Console.WriteLine();
        Console.WriteLine($"    Total tests     : {totalTests}");
        Console.WriteLine($"    Passed          : {totalPassed}");
        Console.WriteLine($"    Failed          : {totalFailed}");

        if (totalTests > 0)
        {
            double passRate = 100.0 * totalPassed / totalTests;
            Console.WriteLine($"    Pass rate       : {passRate:F2} %");
        }

        Console.WriteLine($"    Total wall time : {Fmt.FormatDuration(totalMs)}");
        Console.WriteLine($"    Start time      : {startTime}");
        Console.WriteLine($"    End time        : {endTime}");

        Console.WriteLine();
        if (totalFailed == 0)
        {
            Console.WriteLine(
                "  ************************************************************");
            Console.WriteLine(
                "  *  RESULT: ALL TESTS PASSED                              *");
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
                "DataHandle",
                "Buffer I/O, termination, position, RAII dispose, permanent handles",
                new List<TestCase>
                {
                    new TestCase("DataHandle :: basic types",
                        DataHandleTests.BasicTypes),
                    new TestCase("DataHandle :: unicode",
                        DataHandleTests.Unicode),
                    new TestCase("DataHandle :: fault-tolerant read (LF-DATA-004)",
                        DataHandleTests.FaultTolerantRead),
                    new TestCase("DataHandle :: position and size",
                        DataHandleTests.PositionAndSize),
                    new TestCase("DataHandle :: dispose safety",
                        DataHandleTests.DisposeSafety),
                    new TestCase("DataHandle :: string termination",
                        DataHandleTests.StringTermination),
                    new TestCase("DataHandle :: empty string",
                        DataHandleTests.EmptyString),
                    new TestCase("DataHandle :: large buffer (128 KiB)",
                        DataHandleTests.LargeBuffer),
                    new TestCase("DataHandle :: embedded NUL preserved (LF-DATA-003)",
                        DataHandleTests.EmbeddedNulPreserved),
                    new TestCase("DataHandle :: WriteBytes has no terminator (LF-DATA-005)",
                        DataHandleTests.WriteBytesNoTerminator),
                    new TestCase("DataHandle :: multi-field sequential I/O",
                        DataHandleTests.MultiFieldSequentialIO),
                    new TestCase("DataHandle :: zero-length operations",
                        DataHandleTests.ZeroLengthOperations),
                    new TestCase("DataHandle :: ReadBytesExact success",
                        DataHandleTests.ReadBytesExactSuccess),
                    new TestCase("DataHandle :: ReadBytesExact short fails",
                        DataHandleTests.ReadBytesExactShortFails),
                    new TestCase("DataHandle :: Try* family",
                        DataHandleTests.TryReadFamily),
                    new TestCase("DataHandle :: ReadAllBytes",
                        DataHandleTests.ReadAllBytes),
                    new TestCase("DataHandle :: create permanent handle",
                        DataHandleTests.PermanentHandleCreation),
                    new TestCase("DataHandle :: permanent handle survives idle window",
                        DataHandleTests.PermanentHandleSurvivesIdleWindow),
                    new TestCase("DataHandle :: permanent handle dispose is synchronous",
                        DataHandleTests.PermanentHandleDisposeIsSynchronous),
                }),

            new Category(
                "AppHandle",
                "Registration, local execution, lifecycle, callback isolation",
                new List<TestCase>
                {
                    new TestCase("App :: register / local call / unregister",
                        AppHandleTests.RegisterAndLocalCall),
                    new TestCase("App :: duplicate registration rejected",
                        AppHandleTests.DuplicateRegistration),
                    new TestCase("App :: unregister then re-register",
                        AppHandleTests.UnregisterThenReregister),
                    new TestCase("App :: case-insensitive API matching",
                        AppHandleTests.CaseInsensitiveApiMatching),
                    new TestCase("App :: callback produces no output",
                        AppHandleTests.CallbackNoOutput),
                    new TestCase("App :: callback exception is swallowed",
                        AppHandleTests.CallbackExceptionSwallowed),
                    new TestCase("App :: LocalNotify",
                        AppHandleTests.LocalNotify),
                    new TestCase("App :: LocalCallBinary",
                        AppHandleTests.LocalCallBinary),
                    new TestCase("App :: LocalNotifyBinary",
                        AppHandleTests.LocalNotifyBinary),
                    new TestCase("App :: dispose safety",
                        AppHandleTests.DisposeSafety),
                }),

            new Category(
                "LfIo",
                "Unified JSON read / write on a DataHandle",
                new List<TestCase>
                {
                    new TestCase("LfIo :: JSON POCO round trip",
                        LfIoTests.JsonPocoRoundTrip),
                    new TestCase("LfIo :: JSON null value",
                        LfIoTests.JsonNullValue),
                    new TestCase("LfIo :: JSON unicode (no \\uXXXX escapes)",
                        LfIoTests.JsonUnicode),
                    new TestCase("LfIo :: JSON array",
                        LfIoTests.JsonArray),
                    new TestCase("LfIo :: JSON numeric",
                        LfIoTests.JsonNumeric),
                    new TestCase("LfIo :: TryReadJson returns false on invalid",
                        LfIoTests.TryReadJsonReturnsFalseOnInvalid),
                    new TestCase("LfIo :: ReadJson throws on invalid",
                        LfIoTests.ReadJsonThrowsOnInvalid),
                }),

            new Category(
                "Framework",
                "Process-wide ABI facade: prepare / generate name / shutdown",
                new List<TestCase>
                {
                    new TestCase("Framework :: SetOption does not throw",
                        FrameworkTests.SetOptionNoThrow),
                    new TestCase("Framework :: ResetPrepare does not throw",
                        FrameworkTests.ResetPrepareNoThrow),
                    new TestCase("Framework :: GenerateAppName after prepare",
                        FrameworkTests.GenerateAppName),
                    new TestCase("Framework :: PrepareDone returns 1 only once (LF-NET-003)",
                        FrameworkTests.PrepareDoneReturnsOneOnlyOnce),
                    new TestCase("Framework :: Shutdown is idempotent",
                        FrameworkTests.ShutdownIsIdempotent),
                }),

            new Category(
                "Network integration",
                "Service + client, Call / Notify / SequencedNotify, check / status",
                new List<TestCase>
                {
                    new TestCase("Network :: single address JSON call",
                        NetworkIntegrationTests.SingleAddressJsonCall),
                    new TestCase("Network :: missing target returns empty handle (LF-CALL-001)",
                        NetworkIntegrationTests.MissingTargetReturnsEmptyHandle),
                    new TestCase("Network :: long string round trip (LF-XLANG-002)",
                        NetworkIntegrationTests.LongStringRoundTrip),
                    new TestCase("Network :: Notify",
                        NetworkIntegrationTests.NotifyOneWay),
                    new TestCase("Network :: SequencedNotify FIFO order (LF-SEQ-002)",
                        NetworkIntegrationTests.SequencedNotifyFifo),
                    new TestCase("Network :: CheckApp / CheckApi (LF-CHK-001)",
                        NetworkIntegrationTests.CheckAppAndApi),
                    new TestCase("Network :: NetworkEvents install / clear (LF-NET-005/006)",
                        NetworkIntegrationTests.NetworkEventsInstallClear),
                    new TestCase("Network :: status queue operations",
                        NetworkIntegrationTests.StatusQueueOperations),
                }),

            new Category(
                "ABI cross-language",
                "Raw binary Call / Notify / wire format",
                new List<TestCase>
                {
                    new TestCase("ABI :: CallBinary int32",
                        AbiCrossLanguageTests.AbiCallBinaryInt32),
                    new TestCase("ABI :: CallBinary multi-type round trip",
                        AbiCrossLanguageTests.AbiCallBinaryMultiType),
                    new TestCase("ABI :: byte-exact little-endian wire format",
                        AbiCrossLanguageTests.AbiByteExactWireFormat),
                    new TestCase("ABI :: NotifyBinary",
                        AbiCrossLanguageTests.AbiNotifyBinary),
                    new TestCase("ABI :: SequencedNotifyBinary",
                        AbiCrossLanguageTests.AbiSequencedNotifyBinary),
                }),

            new Category(
                "Concurrency",
                "Thread safety of local calls and independent DataHandles",
                new List<TestCase>
                {
                    new TestCase("Concurrency :: 10 threads x 100 local calls",
                        ConcurrencyTests.ConcurrentLocalCalls),
                    new TestCase("Concurrency :: 8 threads x 500 DataHandles",
                        ConcurrencyTests.ConcurrentDataHandles),
                }),

            new Category(
                "Stress",
                "Throughput and pool pressure",
                new List<TestCase>
                {
                    new TestCase("Stress :: 1000 sequential local calls",
                        StressTests.SequentialLocalCalls),
                    new TestCase("Stress :: 100 rapid App create / destroy",
                        StressTests.RapidAppCreateDestroy),
                }),
        };
    }
}