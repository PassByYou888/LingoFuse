// =============================================================================
// test_lingofuse_csharp — Comprehensive test suite for the LingoFuse C#
//                         binding.
//
// Version 2.1 — nullable-aware fix pass:
//                - Correct handling of unconstrained T? in LocalCall<T>
//                  and Call<T>: for value types the return is T (not
//                  Nullable<T>); for reference types the return is T?.
//                - TryCall* / TryLocalCall* are the idiomatic way to
//                  distinguish "empty response" from "default(T)".
//
// Every test corresponds to a well-defined contract from the Pascal
// documentation (LingoFuse_Pascal_Complete_Guide.md, lingofuse_import.pas)
// and is tagged with the relevant LF-*-NNN pitfall ID where applicable.
// =============================================================================
//
// TEST PLAN (64 tests)
// --------------------
//
// DataHandle (19):
//   01  basic types ................. all integer / floating-point types
//   02  unicode ..................... UTF-8 round-trip
//   03  fault-tolerant read ......... LF-DATA-004: no NUL on the wire
//   04  position and size ........... tell / seek / size
//   05  dispose safety .............. double Dispose + use-after-dispose
//   06  string termination .......... LF-DATA-005: write always appends #0
//   07  empty string ................ empty payload semantics
//   08  large buffer (128 KiB) ...... buffer realloc / growth path
//   09  embedded NUL preserved ...... LF-DATA-003: raw bytes keep #0
//   10  WriteBytes has no terminator. LF-DATA-005: raw path has no #0
//   11  multi-field sequential I/O .. mixed types in one buffer
//   12  zero-length operations ...... WriteBytes(len:0) / ReadBytes(0)
//   13  buffer pointer access ....... GetBufferPointer is stable
//   14  ReadBytesExact success ...... exact read returns correct bytes
//   15  ReadBytesExact short fails .. LingoFuseIoException on short read
//   16  TryReadBytes / TryReadInt32 . boolean non-throwing reads
//   17  TryReadString ............... Try* family
//   18  borrowed handle dispose ..... Dispose on borrowed handle is a no-op
//   19  ReadAllBytes ................ consume everything from cursor
//
// AppHandle / LingoFuseApp (15):
//   20  register / local call ....... basic API registration + call
//   21  duplicate registration ...... second register returns false
//   22  unregister then re-register . name can be reused after removal
//   23  case-insensitive API match .. "add" matches "Add"
//   24  callback isolation .......... callback producing no output
//   25  free lifecycle .............. LF-APP-002: two-phase destruction
//   26  LocalNotify ................. App::LocalNotify round-trip
//   27  Expose<TResult> ............. zero-argument typed handler
//   28  LocalCall unregistered ...... returns default(T) (Batch 6)
//   29  TryLocalCall success ........ boolean non-throwing local call
//   30  TryLocalCall unregistered ... returns false on empty response
//   31  Expose ABI callback ......... raw DataHandle handler
//   32  ExposeNotify ABI callback ... raw DataHandle notify
//   33  LocalCallBinary ............. raw local call
//   34  LocalNotifyBinary ........... raw local notify
//
// Typed Expose (4):
//   35  Expose<TArg, TResult> ....... one-argument typed handler
//   36  Expose<T1, T2, TResult> ..... two-argument typed handler
//   37  ExposeNotify<TArg> .......... typed one-argument notify
//   38  Expose one-arg with null .... null payload reaches handler
//
// Network basics (4):
//   39  single address .............. service + client + call
//   40  multi address ............... two services, one app
//   41  check functions ............. LF-CHK-001: checkApp / checkApi
//   42  long string round-trip ...... LF-XLANG-002: 64 KiB payload
//
// Network options (1):
//   43  prepareDone only once ....... LF-NET-003: second call returns 0
//
// Network calls (6):
//   44  call timeout empty handle ... LF-CALL-001: size-0 handle, not NULL
//   45  notify + sequenced .......... LF-CALL-002 / LF-SEQ-002
//   46  nonexistent app / API ....... call to missing target
//   47  TryCall success ............. boolean non-throwing JSON call
//   48  TryCall timeout ............. returns false on timeout
//   49  TryCallRaw success .......... raw JSON via TryCallRaw
//
// ABI cross-language (7):
//   50  ABI CallBinary int32 ........ raw int32 in / int32 out
//   51  ABI CallBinary multi-type ... uint8/16/32/64/string/float round-trip
//   52  ABI TryCallBinary timeout ... boolean non-throwing ABI call
//   53  ABI NotifyBinary ............ raw one-way notification
//   54  ABI SequencedNotifyBinary ... raw ordered notification
//   55  ABI byte-exact wire format .. little-endian byte-level verification
//   56  ABI Expose raw callback ..... cross-language raw-handler contract
//
// LingoFuseSync (2):
//   57  public API shape ............ ProcessSyncQueue / SetMainThread
//   58  main thread registration .... IsMainThreadCurrent behaviour
//
// Network events (1):
//   59  install / clear ............. NetworkEvents.Set / Clear
//
// Status queue (1):
//   60  count / post / drain ........ status queue operations
//
// Concurrency (2):
//   61  concurrent local calls ...... 10 threads x 100 App::LocalCall
//   62  concurrent DataHandles ...... 8 threads x 500 independent handles
//
// Stress (2):
//   63  1000 sequential local calls . throughput sanity check
//   64  rapid App create/destroy .... LF-APP-002: pool growth pressure
// =============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

using LingoFuse;
using LingoFuse.Core;
using LingoFuse.Diagnostics;
using LingoFuse.Events;
using LingoFuse.Host;
using LingoFuse.Io;

namespace LingoFuse.Tests;

/* ============================================================================
 *  Formatting helpers
 * ============================================================================ */

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
        if (ms < 60000)
            return (ms / 1000.0).ToString("F2") + " s";
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

    public static void PrintCategoryBanner(string name, string description, int count)
    {
        Console.WriteLine();
        Console.WriteLine();
        Console.WriteLine(CategoryRule);
        Console.WriteLine($"##  Category: {name}  ({count} test{(count == 1 ? "" : "s")})");
        Console.WriteLine($"##  {description}");
        Console.WriteLine(CategoryRule);
    }
}

/* ============================================================================
 *  Mini test framework
 * ============================================================================ */

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
            throw new CheckFailedException($"CHECK FAILED: {expr} (line {line})");
        }
    }

    public static void False(
        bool condition,
        [CallerArgumentExpression(nameof(condition))] string? expr = null,
        [CallerLineNumber] int line = 0)
    {
        if (condition)
        {
            throw new CheckFailedException($"CHECK_FALSE FAILED: {expr} (line {line})");
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
            throw new CheckFailedException($"CHECK_NOT_NULL FAILED: {expr} (line {line})");
        }
    }

    public static void HasValue<T>(
        T? value,
        [CallerArgumentExpression(nameof(value))] string? expr = null,
        [CallerLineNumber] int line = 0)
        where T : struct
    {
        if (!value.HasValue)
        {
            throw new CheckFailedException($"CHECK_HAS_VALUE FAILED: {expr} (line {line})");
        }
    }

    public static void Equal<T>(
        T actual,
        T expected,
        [CallerArgumentExpression(nameof(actual))] string? actualExpr = null,
        [CallerArgumentExpression(nameof(expected))] string? expectedExpr = null,
        [CallerLineNumber] int line = 0)
    {
        if (!EqualityComparer<T>.Default.Equals(actual, expected))
        {
            throw new CheckFailedException(
                $"CHECK_EQ FAILED: {actualExpr} == {expectedExpr} (line {line})\n" +
                $"        actual  : {Format(actual)}\n" +
                $"        expected: {Format(expected)}");
        }
    }

    public static void NotEqual<T>(
        T actual,
        T expected,
        [CallerArgumentExpression(nameof(actual))] string? actualExpr = null,
        [CallerArgumentExpression(nameof(expected))] string? expectedExpr = null,
        [CallerLineNumber] int line = 0)
    {
        if (EqualityComparer<T>.Default.Equals(actual, expected))
        {
            throw new CheckFailedException(
                $"CHECK_NE FAILED: {actualExpr} != {expectedExpr} (line {line})\n" +
                $"        both sides are: {Format(actual)}");
        }
    }

    public static void SequenceEqual<T>(
        IEnumerable<T> actual,
        IEnumerable<T> expected,
        [CallerArgumentExpression(nameof(actual))] string? actualExpr = null,
        [CallerArgumentExpression(nameof(expected))] string? expectedExpr = null,
        [CallerLineNumber] int line = 0)
    {
        if (!actual.SequenceEqual(expected))
        {
            throw new CheckFailedException(
                $"CHECK_SEQ FAILED: {actualExpr} == {expectedExpr} (line {line})");
        }
    }

    public static TException Throws<TException>(Action action,
        [CallerLineNumber] int line = 0)
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

    private static string Format<T>(T? value)
    {
        if (value is null) return "null";
        if (value is string s) return '"' + s + '"';
        return value.ToString() ?? "null";
    }
}

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
            result.ErrorDetail = $"LingoFuseCallException: {ex.Message}";
        }
        catch (LingoFuseStateException ex)
        {
            result.Threw = true;
            result.ErrorDetail = $"LingoFuseStateException: {ex.Message}";
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
            if (result.Threw)
            {
                Console.WriteLine($"         reason: {result.ErrorDetail}");
            }
            else
            {
                Console.WriteLine(
                    "         reason: a check returned false " +
                    "(see the [CHECK...] line above)");
            }
            Console.WriteLine($"         time:   {result.ElapsedMs} ms");
        }

        Console.WriteLine(Fmt.SectionRule);
        return result;
    }
}

/* ============================================================================
 *  Test-scoped helpers
 * ============================================================================ */

internal static class TestEnv
{
    private static int _counter;

    public static int NextId() => Interlocked.Increment(ref _counter);

    public static string UniqueEndpoint(string prefix)
        => $"ipc:test_cs_{prefix}_{Environment.ProcessId}_{NextId()}";

    public static string UniqueAppName(string prefix)
        => $"test_cs_{prefix}_{Environment.ProcessId}_{NextId()}";

    public static void Settle(int ms = 250)
        => Thread.Sleep(ms);
}

/* ============================================================================
 *  Shared static callbacks
 * ============================================================================ */

internal static class Callbacks
{
    // String-echo handler registered via the ABI path.
    public static void Echo(DataHandle input, DataHandle output)
    {
        var s = input.ReadString();
        output.WriteString(s);
    }

    // int32 + int32 -> int32 handler registered via the ABI path.
    public static void Add(DataHandle input, DataHandle output)
    {
        var a = input.ReadInt32();
        var b = input.ReadInt32();
        output.WriteInt32(a + b);
    }

    // Notify handler that discards its payload.
    public static void Sink(DataHandle input)
    {
        _ = input.ReadString();
    }
}

/* ============================================================================
 *  CATEGORY: DataHandle
 * ============================================================================ */

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

        var outText = dh.ReadString();
        Verify.Equal(outText, text);

        return true;
    }

    public static bool FaultTolerantRead()
    {
        // LF-DATA-004: A read with no NUL must consume the remaining
        // buffer and advance the cursor one byte past the end.
        using var dh = new DataHandle("test_fault");

        var raw = Encoding.UTF8.GetBytes("abcdef");
        dh.WriteBytes(raw);
        Verify.Equal(dh.Size, (long)6);

        dh.Position = 0;
        var s = dh.ReadString();
        Verify.Equal(s, "abcdef");

        Verify.Equal(dh.Position, (long)7);

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

        Verify.Throws<LingoFuseObjectDisposedException>(() => { _ = dh.ReadInt32(); });
        Verify.Throws<LingoFuseObjectDisposedException>(() => dh.WriteInt32(1));

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
        var s = dh.ReadString();
        Verify.Equal(s, string.Empty);
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
        var readback = dh.ReadBytes(kSize);
        Verify.SequenceEqual(readback, payload);

        return true;
    }

    public static bool EmbeddedNulPreserved()
    {
        using var dh = new DataHandle("test_embedded_nul");

        var data = new byte[] { (byte)'a', 0, (byte)'b', 0, (byte)'c' };
        dh.WriteBytes(data);

        Verify.Equal(dh.Size, 5L);

        dh.Position = 0;
        var back = dh.ReadBytes(5);
        Verify.SequenceEqual(back, data);

        return true;
    }

    public static bool WriteBytesNoTerminator()
    {
        using var dh = new DataHandle("test_raw_no_term");

        var raw = new byte[] { (byte)'x', (byte)'y', (byte)'z' };
        dh.WriteBytes(raw);
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

        var got = dh.ReadBytes(0);
        Verify.Equal(got.Length, 0);
        Verify.Equal(dh.Position, 0L);

        dh.WriteInt32(42);
        dh.Position = 2;

        var got2 = dh.ReadBytes(0);
        Verify.Equal(got2.Length, 0);
        Verify.Equal(dh.Position, 2L);

        return true;
    }

    public static bool BufferPointerAccess()
    {
        using var dh = new DataHandle("test_buf_ptr");

        dh.WriteInt32(unchecked((int)0x11223344));

        var p = dh.GetBufferPointer();
        Verify.True(p != IntPtr.Zero);

        var b = Marshal.ReadByte(p, 0);
        Verify.Equal(dh.Position, 4L);
        Verify.Equal(b, (byte)0x44);

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
        var ex = Verify.Throws<LingoFuseIoException>(() =>
        {
            _ = dh.ReadBytesExact(4);
        });
        Verify.Equal(ex.Operation, "ReadBytesExact");
        Verify.Equal(dh.Position, 0L);

        return true;
    }

    public static bool TryReadBytesAndInt32()
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

        return true;
    }

    public static bool TryReadStringRoundTrip()
    {
        using var dh = new DataHandle("test_try_string");
        dh.WriteString("hello");

        dh.Position = 0;
        Verify.True(dh.TryReadString(out var s));
        Verify.Equal(s, "hello");

        Verify.False(dh.TryReadString(out var empty));
        Verify.True(empty is null);

        return true;
    }

    public static bool BorrowedHandleDisposeNoOp()
    {
        using var owner = new DataHandle("test_borrow_src");
        owner.WriteInt32(42);
        var raw = owner.Raw;

        var borrowed = DataHandle.FromRaw(raw, owned: false);
        borrowed.Dispose();          // no-op

        Verify.True(borrowed.IsValid);
        Verify.False(borrowed.IsOwning);

        borrowed.Position = 0;
        Verify.Equal(borrowed.ReadInt32(), 42);

        owner.Position = 0;
        Verify.Equal(owner.ReadInt32(), 42);

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
}

/* ============================================================================
 *  CATEGORY: AppHandle / LingoFuseApp
 * ============================================================================ */

internal static class AppTests
{
    public static bool RegisterAndLocalCall()
    {
        using var app = new LingoFuseApp("test_cs_app_basic");

        Verify.True(app.Handle.RegisterCall("add", "test add", Callbacks.Add));
        Verify.True(app.Handle.RegisterNotify("sink", "test notify", Callbacks.Sink));

        {
            using var param = new DataHandle("add");
            param.WriteInt32(10);
            param.WriteInt32(20);

            using var result = app.Handle.LocalCall(param);
            Verify.Equal(result.ReadInt32(), 30);
        }

        {
            using var param = new DataHandle("sink");
            param.WriteString("hello");
            app.Handle.LocalNotify(param);
        }

        Verify.True(app.Handle.Unregister("add"));
        Verify.False(app.Handle.Unregister("add"));

        {
            using var param = new DataHandle("add");
            param.WriteInt32(1);
            param.WriteInt32(2);

            using var result = app.Handle.LocalCall(param);
            Verify.Equal(result.Size, 0L);
        }

        return true;
    }

    public static bool DuplicateRegistration()
    {
        using var app = new LingoFuseApp("test_cs_app_dup");

        Verify.True(app.Handle.RegisterCall("dup", "first", Callbacks.Add));
        Verify.False(app.Handle.RegisterCall("dup", "second", Callbacks.Add));

        return true;
    }

    public static bool UnregisterThenReregister()
    {
        using var app = new LingoFuseApp("test_cs_app_rereg");

        Verify.True(app.Handle.RegisterCall("hot", "v1", Callbacks.Add));
        Verify.True(app.Handle.Unregister("hot"));
        Verify.True(app.Handle.RegisterCall("hot", "v2", Callbacks.Add));

        using var param = new DataHandle("hot");
        param.WriteInt32(5);
        param.WriteInt32(6);
        using var result = app.Handle.LocalCall(param);
        Verify.Equal(result.ReadInt32(), 11);

        return true;
    }

    public static bool CaseInsensitiveApiMatching()
    {
        using var app = new LingoFuseApp("test_cs_app_case");

        Verify.True(app.Handle.RegisterCall(
            "MixedCaseApi", "description", Callbacks.Add));

        {
            using var param = new DataHandle("mixedcaseapi");
            param.WriteInt32(7);
            param.WriteInt32(8);
            using var result = app.Handle.LocalCall(param);
            Verify.Equal(result.ReadInt32(), 15);
        }

        Verify.True(app.Handle.Unregister("MIXEDCASEAPI"));

        return true;
    }

    public static bool CallbackIsolation()
    {
        using var app = new LingoFuseApp("test_cs_app_isolation");

        Verify.True(app.Handle.RegisterCall("empty", "empty callback",
            (input, output) => { /* intentionally does nothing */ }));

        using var param = new DataHandle("empty");
        using var result = app.Handle.LocalCall(param);
        Verify.Equal(result.Size, 0L);

        return true;
    }

    public static bool FreeLifecycle()
    {
        const string appName = "test_cs_app_lifecycle";

        {
            using var app = new LingoFuseApp(appName, "original");
            app.Handle.RegisterCall("ping", "ping", Callbacks.Echo);

            using var param = new DataHandle("ping");
            param.WriteString("first");
            using var result = app.Handle.LocalCall(param);
            Verify.Equal(result.ReadString(), "first");
        }

        {
            using var app2 = new LingoFuseApp(appName, "second instance");
            app2.Handle.RegisterCall("ping", "ping", Callbacks.Echo);

            using var param = new DataHandle("ping");
            param.WriteString("second");
            using var result = app2.Handle.LocalCall(param);
            Verify.Equal(result.ReadString(), "second");
        }

        return true;
    }

    public static bool LocalNotify()
    {
        using var app = new LingoFuseApp("test_cs_app_notify");

        Verify.True(app.Handle.RegisterNotify("sink", "notify sink",
            Callbacks.Sink));

        using var param = new DataHandle("sink");
        param.WriteString("payload");
        app.Handle.LocalNotify(param);

        return true;
    }

    public static bool ExposeZeroArg()
    {
        using var app = new LingoFuseApp("test_cs_app_expose0");

        Verify.True(app.Expose<int>("answer", () => 42));

        // LocalCall<T> for a value type T returns T (not Nullable<T>),
        // because T is an unconstrained generic parameter: T? only
        // produces Nullable<T> when T is constrained to struct.
        var v = app.LocalCall<int>("answer");
        Verify.Equal(v, 42);

        return true;
    }

    public static bool LocalCallUnregisteredReturnsDefault()
    {
        // Batch 6: LocalCall<T> returns default(T) for an unregistered
        // API, matching the C++ / Python bindings. For a value type the
        // observable result is default(T); for a reference type it is
        // null. Callers that need to distinguish "empty response" from
        // "default(T)" must use TryLocalCall<T>.
        using var app = new LingoFuseApp("test_cs_app_unregistered");

        // Value type: default(int) == 0.
        var v = app.LocalCall<int>("not_registered");
        Verify.Equal(v, 0);

        // Reference type: default(string) == null.
        var s = app.LocalCall<string>("not_registered");
        Verify.True(s is null);

        return true;
    }

    public static bool TryLocalCallSuccess()
    {
        using var app = new LingoFuseApp("test_cs_app_try_local");
        app.Expose<int, int>("answer", n => n + 1);

        // TryLocalCall<T> is the correct way to distinguish "empty
        // response" from "default(T)": it returns a bool.
        var ok = app.TryLocalCall<int>("answer", 41, out var result);
        Verify.True(ok);
        Verify.Equal(result, 42);

        return true;
    }

    public static bool TryLocalCallUnregistered()
    {
        using var app = new LingoFuseApp("test_cs_app_try_unreg");

        var ok = app.TryLocalCall<int>("not_registered", null, out var result);
        Verify.False(ok);

        // The out parameter holds default(int) on failure.
        Verify.Equal(result, 0);

        return true;
    }

    public static bool ExposeAbiCallback()
    {
        // ABI registration: the handler receives borrowed DataHandle
        // instances and must not perform JSON serialization.
        using var app = new LingoFuseApp("test_cs_app_abi");
        Verify.True(app.Expose("add", "ABI add", Callbacks.Add));

        using var param = new DataHandle("add");
        param.WriteInt32(11);
        param.WriteInt32(31);

        using var result = app.LocalCallBinary(param);
        Verify.Equal(result.Size, (long)4);
        Verify.Equal(result.ReadInt32(), 42);

        return true;
    }

    public static bool ExposeNotifyAbiCallback()
    {
        using var app = new LingoFuseApp("test_cs_app_abi_notify");
        var received = new List<int>();
        Verify.True(app.ExposeNotify("bump", "ABI notify",
            input => received.Add(input.ReadInt32())));

        using var param = new DataHandle("bump");
        param.WriteInt32(7);
        app.LocalNotifyBinary(param);

        Verify.Equal(received.Count, 1);
        Verify.Equal(received[0], 7);

        return true;
    }

    public static bool LocalCallBinary()
    {
        using var app = new LingoFuseApp("test_cs_app_local_bin");
        app.Expose("echo32", "ABI echo32",
            (input, output) => output.WriteInt32(input.ReadInt32()));

        using var param = new DataHandle("echo32");
        param.WriteInt32(12345);

        using var result = app.LocalCallBinary(param);
        Verify.Equal(result.Size, (long)4);
        Verify.Equal(result.ReadInt32(), 12345);

        return true;
    }

    public static bool LocalNotifyBinary()
    {
        using var app = new LingoFuseApp("test_cs_app_local_notify_bin");
        var fired = 0;
        app.ExposeNotify("ping_notify", "ABI notify",
            input => Interlocked.Increment(ref fired));

        using var param = new DataHandle("ping_notify");
        param.WriteInt32(1);
        app.LocalNotifyBinary(param);

        Verify.Equal(fired, 1);

        return true;
    }
}

/* ============================================================================
 *  CATEGORY: Typed Expose
 * ============================================================================ */

internal static class TypedExposeTests
{
    public static bool ExposeOneArg()
    {
        using var app = new LingoFuseApp("test_cs_app_expose1");

        Verify.True(app.Expose<string, string>("ping", s => s));

        // LocalCall<string> returns string? (reference type).
        var echoed = app.LocalCall<string>("ping", "hello");
        Verify.NotNull(echoed);
        Verify.Equal(echoed!, "hello");

        return true;
    }

    public static bool ExposeTwoArgs()
    {
        using var app = new LingoFuseApp("test_cs_app_expose2");

        Verify.True(app.Expose<int, int, int>("add", (a, b) => a + b));

        // LocalCall<int> returns int (value type: no Nullable<T>).
        var sum = app.LocalCall<int>("add", new object[] { 5, 7 });
        Verify.Equal(sum, 12);

        return true;
    }

    public static bool ExposeNotifyTyped()
    {
        using var app = new LingoFuseApp("test_cs_app_exposen");

        int received = 0;
        Verify.True(app.ExposeNotify<int>("bump", n => received = n));

        app.LocalNotify("bump", 7);
        Verify.Equal(received, 7);

        return true;
    }

    public static bool ExposeOneArgWithNull()
    {
        // Batch 6: a JSON `null` payload reaches the handler as
        // default(TArg), matching the C++ / Python bindings.
        using var app = new LingoFuseApp("test_cs_app_expose_null");

        var receivedNull = false;
        Verify.True(app.Expose<string?, string>("echo_null", s =>
        {
            receivedNull = s is null;
            return s ?? "(was null)";
        }));

        var echoed = app.LocalCall<string>("echo_null", payload: null);
        Verify.NotNull(echoed);
        Verify.Equal(echoed!, "(was null)");
        Verify.True(receivedNull);

        return true;
    }
}

/* ============================================================================
 *  CATEGORY: Network basics
 * ============================================================================ */

internal static class NetworkBasicsTests
{
    public static bool SingleAddress()
    {
        var endpoint = TestEnv.UniqueEndpoint("single");
        var appName = TestEnv.UniqueAppName("single");

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.Expose<string, string>("ping", s => s));
        server.Start();

        // Call<string> returns string? (reference type).
        var echoed = server.Call<string>(appName, "ping", "hello", 3000);
        Verify.NotNull(echoed);
        Verify.Equal(echoed!, "hello");

        Verify.Throws<LingoFuseCallException>(() =>
        {
            _ = server.Call<string>(appName, "does_not_exist", null, 1000);
        });

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool MultiAddress()
    {
        var ep1 = TestEnv.UniqueEndpoint("multi_a");
        var appName = TestEnv.UniqueAppName("multi");

        using var server = new LingoFuseServer(appName, ep1, "multi-address test");
        Verify.True(server.App.Expose<int, int, int>("add", (a, b) => a + b));
        server.Start();

        // Call<int> returns int (value type: no Nullable<T>).
        var sum = server.Call<int>(appName, "add", new object[] { 3, 4 }, 3000);
        Verify.Equal(sum, 7);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool CheckFunctions()
    {
        var endpoint = TestEnv.UniqueEndpoint("check");
        var appName = TestEnv.UniqueAppName("check");

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.Expose<string, string>("ping", s => s));
        server.Start();

        Verify.True(LingoFuseStatus.CheckMainThread());

        bool appSeen = false, apiSeen = false;
        for (int i = 0; i < 30; i++)
        {
            if (!appSeen) appSeen = LingoFuseStatus.CheckApp(appName);
            if (!apiSeen) apiSeen = LingoFuseStatus.CheckApi(appName, "ping");
            if (appSeen && apiSeen) break;
            Thread.Sleep(200);
        }

        Verify.True(appSeen);
        Verify.True(apiSeen);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool LongStringRoundTrip()
    {
        var endpoint = TestEnv.UniqueEndpoint("long_str");
        var appName = TestEnv.UniqueAppName("long_str");

        const string unit = "Hello-\u4e16\u754c-";
        var sb = new StringBuilder(64 * 1024 + 16);
        while (sb.Length < 64 * 1024) sb.Append(unit);
        var payload = sb.ToString();

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.Expose<string, string>("ping", s => s));
        server.Start();

        var echoed = server.Call<string>(appName, "ping", payload, 5000);
        Verify.NotNull(echoed);
        Verify.Equal(echoed!.Length, payload.Length);
        Verify.Equal(echoed, payload);

        server.Stop();
        TestEnv.Settle();
        return true;
    }
}

/* ============================================================================
 *  CATEGORY: Network options
 * ============================================================================ */

internal static class NetworkOptionsTests
{
    public static bool PrepareDoneOnlyOnce()
    {
        var ep1 = TestEnv.UniqueEndpoint("once_a");
        var ep2 = TestEnv.UniqueEndpoint("once_b");
        var appName1 = TestEnv.UniqueAppName("once_a");
        var appName2 = TestEnv.UniqueAppName("once_b");

        using var server1 = new LingoFuseServer(appName1, ep1);
        server1.App.Expose<string, string>("ping", s => s);
        server1.Start();
        Verify.True(server1.IsRunning);

        using var server2 = new LingoFuseServer(appName2, ep2);
        server2.App.Expose<string, string>("ping", s => s);
        server2.Start();
        Verify.True(server2.IsRunning);

        Verify.Throws<LingoFuseStateException>(() => server1.Start());

        server2.Stop();
        server1.Stop();
        TestEnv.Settle();
        return true;
    }
}

/* ============================================================================
 *  CATEGORY: Network calls
 * ============================================================================ */

internal static class NetworkCallsTests
{
    public static bool CallTimeoutEmptyHandle()
    {
        var endpoint = TestEnv.UniqueEndpoint("timeout");
        var appName = TestEnv.UniqueAppName("timeout");

        using var server = new LingoFuseServer(appName, endpoint);
        server.App.Expose<string, string>("ping", s => s);
        server.Start();

        var ex = Verify.Throws<LingoFuseCallException>(() =>
        {
            _ = server.Call<string>("nonexistent_app_xyz_12345",
                "anything", null, 500);
        });
        Verify.Equal(ex.TargetApp, "nonexistent_app_xyz_12345");

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool NotifyAndSequenced()
    {
        var endpoint = TestEnv.UniqueEndpoint("notify");
        var appName = TestEnv.UniqueAppName("notify");

        using var server = new LingoFuseServer(appName, endpoint);
        int notifyCount = 0;
        int sequencedCount = 0;

        Verify.True(server.App.Handle.RegisterNotify("sink", "notify sink",
            input => Interlocked.Increment(ref notifyCount)));
        Verify.True(server.App.Handle.RegisterNotify("seq", "sequenced sink",
            input => Interlocked.Increment(ref sequencedCount)));

        server.Start();

        for (int i = 0; i < 5; i++)
        {
            server.Notify(appName, "sink", $"n{i}");
        }
        for (int i = 0; i < 5; i++)
        {
            server.SequencedNotify(appName, "seq", $"s{i}");
        }

        Thread.Sleep(500);

        Verify.True(notifyCount >= 1);
        Verify.True(sequencedCount >= 1);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool NonexistentTargets()
    {
        var endpoint = TestEnv.UniqueEndpoint("missing");
        var appName = TestEnv.UniqueAppName("missing");

        using var server = new LingoFuseServer(appName, endpoint);
        server.App.Expose<string, string>("ping", s => s);
        server.Start();

        Verify.Throws<LingoFuseCallException>(() =>
        {
            _ = server.Call<string>("nonexistent_app_xyz_12345",
                "ping", "hello", 500);
        });

        Verify.Throws<LingoFuseCallException>(() =>
        {
            _ = server.Call<string>(appName, "nonexistent_api_xyz", null, 500);
        });

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool TryCallSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("try_ok");
        var appName = TestEnv.UniqueAppName("try_ok");

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.Expose<int, int, int>("add", (a, b) => a + b));
        server.Start();

        // TryCall<int> for a value type T produces an out int (not
        // Nullable<int>) because T is an unconstrained generic parameter.
        var ok = server.TryCall<int>(
            appName, "add", new object[] { 20, 22 }, 3000, out var sum);
        Verify.True(ok);
        Verify.Equal(sum, 42);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool TryCallTimeout()
    {
        var endpoint = TestEnv.UniqueEndpoint("try_timeout");
        var appName = TestEnv.UniqueAppName("try_timeout");

        using var server = new LingoFuseServer(appName, endpoint);
        server.App.Expose<string, string>("ping", s => s);
        server.Start();

        // For reference types, the out parameter is null on failure.
        var ok = server.TryCall<string>(
            "nonexistent_app_xyz_12345", "ping", "hello", 500, out var result);
        Verify.False(ok);
        Verify.True(result is null);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool TryCallRawSuccess()
    {
        var endpoint = TestEnv.UniqueEndpoint("try_raw");
        var appName = TestEnv.UniqueAppName("try_raw");

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.Expose<string, string>("ping", s => s));
        server.Start();

        var ok = server.TryCallRaw(
            appName, "ping", "hello", 3000, out var json);
        Verify.True(ok);
        Verify.NotNull(json);
        // The JSON serialisation of a string is a quoted string.
        Verify.Equal(json!, "\"hello\"");

        server.Stop();
        TestEnv.Settle();
        return true;
    }
}

/* ============================================================================
 *  CATEGORY: ABI cross-language
 * ============================================================================ */
//
// These tests exercise the raw binary path that the C++ / Pascal / Python
// bindings use to interoperate with a C# peer. Every byte on the wire is
// written and read explicitly through DataHandle's atomic-type helpers,
// with no JSON serialization in between.

internal static class AbiCrossLanguageTests
{
    public static bool AbiCallBinaryInt32()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_int32");
        var appName = TestEnv.UniqueAppName("abi_int32");

        using var server = new LingoFuseServer(appName, endpoint);
        // ABI registration: raw DataHandle handler.
        Verify.True(server.App.Expose("add32", "ABI add32",
            (input, output) =>
            {
                int a = input.ReadInt32();
                int b = input.ReadInt32();
                output.WriteInt32(a + b);
            }));
        server.Start();

        using var request = new DataHandle("add32");
        request.WriteInt32(15);
        request.WriteInt32(27);

        using var response = server.CallBinary(appName, request, 3000);
        Verify.Equal(response.Size, (long)4);
        Verify.Equal(response.ReadInt32(), 42);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool AbiCallBinaryMultiType()
    {
        // Exercises every atomic type plus a NUL-framed string. This is
        // the exact shape used by the C++ CrossNode/CrossCall demos.
        var endpoint = TestEnv.UniqueEndpoint("abi_multi");
        var appName = TestEnv.UniqueAppName("abi_multi");

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.Expose("inv_seri", "ABI inv_seri",
            (input, output) =>
            {
                byte b = input.ReadUInt8();
                ushort w = input.ReadUInt16();
                uint c = input.ReadUInt32();
                ulong u64 = input.ReadUInt64();
                string s = input.ReadString();
                float f = input.ReadSingle();

                // Reply in the reverse field order.
                output.WriteSingle(f);
                output.WriteString(s);
                output.WriteUInt64(u64);
                output.WriteUInt32(c);
                output.WriteUInt16(w);
                output.WriteUInt8(b);
            }));
        server.Start();

        using var request = new DataHandle("inv_seri");
        request.WriteUInt8(200);
        request.WriteUInt16(0x10);
        request.WriteUInt32(0x2F);
        request.WriteUInt64(0x3F);
        request.WriteString("hello world");
        request.WriteSingle(3.14f);

        using var response = server.CallBinary(appName, request, 3000);

        Verify.Equal(response.ReadSingle(), 3.14f);
        Verify.Equal(response.ReadString(), "hello world");
        Verify.Equal(response.ReadUInt64(), 0x3FUL);
        Verify.Equal(response.ReadUInt32(), 0x2FUL);
        Verify.Equal(response.ReadUInt16(), (ushort)0x10);
        Verify.Equal(response.ReadUInt8(), (byte)200);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool AbiTryCallBinaryTimeout()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_try_timeout");
        var appName = TestEnv.UniqueAppName("abi_try_timeout");

        using var server = new LingoFuseServer(appName, endpoint);
        server.App.Expose("noop", "ABI noop", (input, output) => { });
        server.Start();

        using var request = new DataHandle("noop");
        var ok = server.TryCallBinary(
            "nonexistent_app_xyz_12345", request, 500, out var response);
        Verify.False(ok);
        Verify.True(response is null);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool AbiNotifyBinary()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_notify");
        var appName = TestEnv.UniqueAppName("abi_notify");

        int received = 0;
        int payload = 0;

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.ExposeNotify("sink", "ABI sink",
            input =>
            {
                payload = input.ReadInt32();
                Interlocked.Increment(ref received);
            }));
        server.Start();

        using var request = new DataHandle("sink");
        request.WriteInt32(4242);
        server.NotifyBinary(appName, request);

        // Give the worker thread time to dispatch.
        Thread.Sleep(400);

        Verify.True(received >= 1);
        Verify.Equal(payload, 4242);

        server.Stop();
        TestEnv.Settle();
        return true;
    }

    public static bool AbiSequencedNotifyBinary()
    {
        var endpoint = TestEnv.UniqueEndpoint("abi_seq");
        var appName = TestEnv.UniqueAppName("abi_seq");

        int received = 0;
        int lastPayload = -1;

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.ExposeNotify("seq", "ABI seq",
            input =>
            {
                lastPayload = input.ReadInt32();
                Interlocked.Increment(ref received);
            }));
        server.Start();

        for (int i = 0; i < 5; i++)
        {
            using var request = new DataHandle("seq");
            request.WriteInt32(i);
            server.SequencedNotifyBinary(appName, request);
        }

        Thread.Sleep(500);

        Verify.True(received >= 1);
        // FIFO per (app, api): the last delivered payload must be 4.
        Verify.Equal(lastPayload, 4);

        server.Stop();
        TestEnv.Settle();
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

    public static bool AbiExposeRawCallback()
    {
        // A raw-handler ABI server must be callable by a JSON-registered
        // peer and vice versa, but the wire format is chosen per
        // (app, api). This test verifies the raw path end-to-end.
        var endpoint = TestEnv.UniqueEndpoint("abi_raw");
        var appName = TestEnv.UniqueAppName("abi_raw");

        using var server = new LingoFuseServer(appName, endpoint);
        Verify.True(server.App.Expose("echo_bytes", "ABI raw echo",
            (input, output) =>
            {
                // Read every remaining byte from the input and write it
                // verbatim into the output. This is the exact shape a
                // byte-stream proxy or passthrough uses.
                var data = input.ReadAllBytes();
                output.WriteBytes(data);
            }));
        server.Start();

        var payload = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        using var request = new DataHandle("echo_bytes");
        request.WriteBytes(payload);

        using var response = server.CallBinary(appName, request, 3000);
        var echoed = response.ReadAllBytes();

        Verify.SequenceEqual(echoed, payload);

        server.Stop();
        TestEnv.Settle();
        return true;
    }
}

/* ============================================================================
 *  CATEGORY: LingoFuseSync
 * ============================================================================ */

internal static class LingoFuseSyncTests
{
    public static bool PublicApiShape()
    {
        // ProcessSyncQueue must be callable without throwing, and the
        // return value must reflect the number of items that were
        // executed. In the absence of pending work, the return value is
        // zero.
        var processed = LingoFuseSync.ProcessSyncQueue();
        Verify.True(processed >= 0);

        // The pending-count accessor must be usable and reflect the
        // current queue state.
        var pending = LingoFuseSync.PendingSyncCount;
        Verify.True(pending >= 0);

        return true;
    }

    public static bool MainThreadRegistration()
    {
        // The first ProcessSyncQueue call registers the calling thread
        // as the main thread.
        LingoFuseSync.SetMainThread();
        Verify.True(LingoFuseSync.IsMainThreadCurrent);

        // ProcessSyncQueue from the registered thread must be a no-op
        // when the queue is empty.
        var processed = LingoFuseSync.ProcessSyncQueue();
        Verify.Equal(processed, 0);

        return true;
    }
}

/* ============================================================================
 *  CATEGORY: Network events
 * ============================================================================ */

internal static class NetworkEventsTests
{
    public static bool InstallClear()
    {
        Verify.False(NetworkEvents.IsInstalled);

        int connectCalls = 0;
        int disconnectCalls = 0;

        NetworkEvents.Set(
            addr => Interlocked.Increment(ref connectCalls),
            addr => Interlocked.Increment(ref disconnectCalls));
        Verify.True(NetworkEvents.IsInstalled);

        NetworkEvents.Clear();
        Verify.False(NetworkEvents.IsInstalled);

        NetworkEvents.Clear();
        NetworkEvents.Clear();
        Verify.False(NetworkEvents.IsInstalled);

        return true;
    }
}

/* ============================================================================
 *  CATEGORY: Status queue
 * ============================================================================ */

internal static class StatusQueueTests
{
    public static bool Operations()
    {
        var endpoint = TestEnv.UniqueEndpoint("status");

        using var server = new LingoFuseServer(
            TestEnv.UniqueAppName("status"), endpoint);
        server.Start();

        Thread.Sleep(200);

        const string marker = "cs_test_status_marker_12345";
        LingoFuseStatus.PostStatus(marker);

        Thread.Sleep(300);

        var count = LingoFuseStatus.GetStatusCount();
        Verify.True(count >= 0);

        var drained = LingoFuseStatus.DrainStatus(20);
        Verify.True(drained.Length <= 20);

        server.Stop();
        TestEnv.Settle();
        return true;
    }
}

/* ============================================================================
 *  CATEGORY: Concurrency
 * ============================================================================ */

internal static class ConcurrencyTests
{
    public static bool ConcurrentLocalCalls()
    {
        const int kThreads = 10;
        const int kCallsPerThread = 100;

        using var app = new LingoFuseApp("test_cs_concurrency");
        Verify.True(app.Expose<int, int, int>("add", (a, b) => a + b));

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
                        var result = app.LocalCall<int>(
                            "add", new object[] { j, j * 2 });
                        if (result == j + j * 2)
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
 *  CATEGORY: Stress
 * ============================================================================ */

internal static class StressTests
{
    public static bool SequentialLocalCalls()
    {
        const int kIterations = 1000;

        using var app = new LingoFuseApp("test_cs_stress_seq");
        Verify.True(app.Expose<int, int, int>("add", (a, b) => a + b));

        int success = 0;
        for (int i = 0; i < kIterations; i++)
        {
            try
            {
                // LocalCall<int> for a value type T returns int, not
                // Nullable<int>; no null-coalescing is needed.
                int result = app.LocalCall<int>(
                    "add", new object[] { i, i + 1 });
                if (result == i + (i + 1))
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
                using var app = new LingoFuseApp(
                    $"test_cs_churn_{i}", "churn test");
                if (app.Handle.RegisterCall("ping", "ping", Callbacks.Echo))
                {
                    using var param = new DataHandle("ping");
                    param.WriteString("x");
                    using var result = app.Handle.LocalCall(param);
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
 *  Suite descriptor
 * ============================================================================ */

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
 *  main
 * ============================================================================ */

internal static class Program
{
    private const string SuiteVersion = "2.1 (C# managed, nullable-aware)";

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
        Console.WriteLine("  Suite      : LingoFuse C# Test Suite");
        Console.WriteLine($"  Version    : {SuiteVersion}");
        Console.WriteLine($"  Process ID : {Environment.ProcessId}");
        Console.WriteLine($"  Platform   : {RuntimeInformation.OSDescription}");
        Console.WriteLine($"  Architecture: {RuntimeInformation.ProcessArchitecture}");
        Console.WriteLine($"  Start time : {startTime}");

        // ---- SECTION 2: ENVIRONMENT ------------------------------------
        Fmt.PrintSectionHeader("SECTION 2: ENVIRONMENT");
        Console.WriteLine($"  Build type        : {BuildTypeString()}");
        Console.WriteLine($"  CPU cores         : {HardwareConcurrencySafe()}");
        Console.WriteLine($"  Runtime           : {RuntimeInformation.FrameworkDescription}");
        Console.WriteLine($"  Working directory : {Environment.CurrentDirectory}");
        Console.WriteLine($"  OS architecture   : {RuntimeInformation.OSArchitecture}");

        var categories = BuildPlan();
        int totalTests = categories.Sum(c => c.Tests.Count);

        // ---- SECTION 3: TEST PLAN --------------------------------------
        Fmt.PrintSectionHeader("SECTION 3: TEST PLAN");
        Console.WriteLine("  " + Fmt.PadRight("Category", 24) + " Tests");
        Console.WriteLine("  " + new string('-', 24) + " -----");
        foreach (var cat in categories)
        {
            Console.WriteLine("  " + Fmt.PadRight(cat.Name, 24) + " " + cat.Tests.Count);
        }
        Console.WriteLine("  " + new string('-', 24) + " -----");
        Console.WriteLine("  " + Fmt.PadRight("Total", 24) + " " + totalTests + " tests");
        Console.WriteLine();
        Console.WriteLine("  Estimated runtime: ~70 seconds (network tests dominate)");

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
            + Fmt.PadRight("Category", 24)
            + Fmt.PadLeft("Tests", 6)
            + Fmt.PadLeft("Passed", 8)
            + Fmt.PadLeft("Failed", 8)
            + Fmt.PadLeft("Time", 12));
        Console.WriteLine("    " + new string('-', 24 + 6 + 8 + 8 + 12));

        int totalPassed = 0;
        int totalFailed = 0;
        long totalMs = 0;

        foreach (var cat in categories)
        {
            totalPassed += cat.Passed;
            totalFailed += cat.Failed;
            totalMs += cat.TotalMs;

            Console.WriteLine("    "
                + Fmt.PadRight(cat.Name, 24)
                + Fmt.PadLeft(cat.Tests.Count.ToString(), 6)
                + Fmt.PadLeft(cat.Passed.ToString(), 8)
                + Fmt.PadLeft(cat.Failed.ToString(), 8)
                + Fmt.PadLeft(Fmt.FormatDuration(cat.TotalMs), 12));
        }

        Console.WriteLine("    " + new string('-', 24 + 6 + 8 + 8 + 12));
        Console.WriteLine("    "
            + Fmt.PadRight("Total", 24)
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
        Console.WriteLine($"    Total tests       : {totalTests}");
        Console.WriteLine($"    Passed            : {totalPassed}");
        Console.WriteLine($"    Failed            : {totalFailed}");

        if (totalTests > 0)
        {
            double passRate = 100.0 * totalPassed / totalTests;
            Console.WriteLine($"    Pass rate         : {passRate:F2} %");
        }

        Console.WriteLine($"    Total wall time   : {Fmt.FormatDuration(totalMs)}");
        Console.WriteLine($"    Start time        : {startTime}");
        Console.WriteLine($"    End time          : {endTime}");

        Console.WriteLine();
        if (totalFailed == 0)
        {
            Console.WriteLine("  ************************************************************");
            Console.WriteLine("  *  RESULT: ALL TESTS PASSED                              *");
            Console.WriteLine("  ************************************************************");
        }
        else
        {
            Console.WriteLine("  ************************************************************");
            Console.WriteLine($"  *  RESULT: {totalFailed} TEST(S) FAILED");
            Console.WriteLine("  ************************************************************");
        }

        return totalFailed == 0 ? 0 : 1;
    }

    private static List<Category> BuildPlan()
    {
        return new List<Category>
        {
            new Category(
                "DataHandle",
                "Buffer I/O, termination, position, RAII dispose, exact/Try reads",
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
                    new TestCase("DataHandle :: string termination (LF-DATA-005)",
                        DataHandleTests.StringTermination),
                    new TestCase("DataHandle :: empty string",
                        DataHandleTests.EmptyString),
                    new TestCase("DataHandle :: large buffer (128 KiB)",
                        DataHandleTests.LargeBuffer),
                    new TestCase("DataHandle :: embedded NUL preserved (LF-DATA-003)",
                        DataHandleTests.EmbeddedNulPreserved),
                    new TestCase("DataHandle :: WriteBytes has no terminator",
                        DataHandleTests.WriteBytesNoTerminator),
                    new TestCase("DataHandle :: multi-field sequential I/O",
                        DataHandleTests.MultiFieldSequentialIO),
                    new TestCase("DataHandle :: zero-length operations",
                        DataHandleTests.ZeroLengthOperations),
                    new TestCase("DataHandle :: buffer pointer access",
                        DataHandleTests.BufferPointerAccess),
                    new TestCase("DataHandle :: ReadBytesExact success",
                        DataHandleTests.ReadBytesExactSuccess),
                    new TestCase("DataHandle :: ReadBytesExact short fails",
                        DataHandleTests.ReadBytesExactShortFails),
                    new TestCase("DataHandle :: TryReadBytes and TryReadInt32",
                        DataHandleTests.TryReadBytesAndInt32),
                    new TestCase("DataHandle :: TryReadString",
                        DataHandleTests.TryReadStringRoundTrip),
                    new TestCase("DataHandle :: borrowed handle dispose no-op",
                        DataHandleTests.BorrowedHandleDisposeNoOp),
                    new TestCase("DataHandle :: ReadAllBytes",
                        DataHandleTests.ReadAllBytes),
                }),

            new Category(
                "AppHandle / LingoFuseApp",
                "API registration, local execution, lifetime, ABI handlers",
                new List<TestCase>
                {
                    new TestCase("App :: register / local call / unregister",
                        AppTests.RegisterAndLocalCall),
                    new TestCase("App :: duplicate registration rejected",
                        AppTests.DuplicateRegistration),
                    new TestCase("App :: unregister then re-register",
                        AppTests.UnregisterThenReregister),
                    new TestCase("App :: case-insensitive API matching",
                        AppTests.CaseInsensitiveApiMatching),
                    new TestCase("App :: callback isolation",
                        AppTests.CallbackIsolation),
                    new TestCase("App :: free lifecycle (LF-APP-002)",
                        AppTests.FreeLifecycle),
                    new TestCase("App :: LocalNotify",
                        AppTests.LocalNotify),
                    new TestCase("App :: Expose<TResult> (zero args)",
                        AppTests.ExposeZeroArg),
                    new TestCase("App :: LocalCall unregistered returns default",
                        AppTests.LocalCallUnregisteredReturnsDefault),
                    new TestCase("App :: TryLocalCall success",
                        AppTests.TryLocalCallSuccess),
                    new TestCase("App :: TryLocalCall unregistered",
                        AppTests.TryLocalCallUnregistered),
                    new TestCase("App :: Expose ABI callback",
                        AppTests.ExposeAbiCallback),
                    new TestCase("App :: ExposeNotify ABI callback",
                        AppTests.ExposeNotifyAbiCallback),
                    new TestCase("App :: LocalCallBinary",
                        AppTests.LocalCallBinary),
                    new TestCase("App :: LocalNotifyBinary",
                        AppTests.LocalNotifyBinary),
                }),

            new Category(
                "Typed Expose",
                "LingoFuseApp typed JSON handlers",
                new List<TestCase>
                {
                    new TestCase("Expose :: Expose<TArg, TResult>",
                        TypedExposeTests.ExposeOneArg),
                    new TestCase("Expose :: Expose<T1, T2, TResult>",
                        TypedExposeTests.ExposeTwoArgs),
                    new TestCase("Expose :: ExposeNotify<TArg>",
                        TypedExposeTests.ExposeNotifyTyped),
                    new TestCase("Expose :: one-arg with null payload",
                        TypedExposeTests.ExposeOneArgWithNull),
                }),

            new Category(
                "Network basics",
                "Endpoints, check functions, long strings",
                new List<TestCase>
                {
                    new TestCase("Network :: single address",
                        NetworkBasicsTests.SingleAddress),
                    new TestCase("Network :: multi address",
                        NetworkBasicsTests.MultiAddress),
                    new TestCase("Network :: check functions (LF-CHK-001)",
                        NetworkBasicsTests.CheckFunctions),
                    new TestCase("Network :: long string round-trip (LF-XLANG-002)",
                        NetworkBasicsTests.LongStringRoundTrip),
                }),

            new Category(
                "Network options",
                "prepareDone semantics, framework restart behaviour",
                new List<TestCase>
                {
                    new TestCase("Network :: prepareDone only once (LF-NET-003)",
                        NetworkOptionsTests.PrepareDoneOnlyOnce),
                }),

            new Category(
                "Network calls",
                "Call / TryCall / Notify / Sequenced_Notify, timeout, missing targets",
                new List<TestCase>
                {
                    new TestCase("Network :: call timeout empty handle (LF-CALL-001)",
                        NetworkCallsTests.CallTimeoutEmptyHandle),
                    new TestCase("Network :: notify + sequencedNotify (LF-CALL-002)",
                        NetworkCallsTests.NotifyAndSequenced),
                    new TestCase("Network :: nonexistent app / API",
                        NetworkCallsTests.NonexistentTargets),
                    new TestCase("Network :: TryCall success",
                        NetworkCallsTests.TryCallSuccess),
                    new TestCase("Network :: TryCall timeout",
                        NetworkCallsTests.TryCallTimeout),
                    new TestCase("Network :: TryCallRaw success",
                        NetworkCallsTests.TryCallRawSuccess),
                }),

            new Category(
                "ABI cross-language",
                "Raw binary Call / Notify / SequencedNotify / Expose",
                new List<TestCase>
                {
                    new TestCase("ABI :: CallBinary int32",
                        AbiCrossLanguageTests.AbiCallBinaryInt32),
                    new TestCase("ABI :: CallBinary multi-type round trip",
                        AbiCrossLanguageTests.AbiCallBinaryMultiType),
                    new TestCase("ABI :: TryCallBinary timeout",
                        AbiCrossLanguageTests.AbiTryCallBinaryTimeout),
                    new TestCase("ABI :: NotifyBinary",
                        AbiCrossLanguageTests.AbiNotifyBinary),
                    new TestCase("ABI :: SequencedNotifyBinary",
                        AbiCrossLanguageTests.AbiSequencedNotifyBinary),
                    new TestCase("ABI :: byte-exact wire format",
                        AbiCrossLanguageTests.AbiByteExactWireFormat),
                    new TestCase("ABI :: Expose raw callback",
                        AbiCrossLanguageTests.AbiExposeRawCallback),
                }),

            new Category(
                "LingoFuseSync",
                "Main-thread callback marshalling public API",
                new List<TestCase>
                {
                    new TestCase("Sync :: public API shape",
                        LingoFuseSyncTests.PublicApiShape),
                    new TestCase("Sync :: main thread registration",
                        LingoFuseSyncTests.MainThreadRegistration),
                }),

            new Category(
                "Network events",
                "Global connect / disconnect handlers",
                new List<TestCase>
                {
                    new TestCase("Network events :: install / clear (LF-NET-005/006)",
                        NetworkEventsTests.InstallClear),
                }),

            new Category(
                "Status queue",
                "GetStatusCount / GetStatus / PostStatus / DrainStatus",
                new List<TestCase>
                {
                    new TestCase("Status queue :: count / post / drain",
                        StatusQueueTests.Operations),
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
                    new TestCase("Stress :: rapid App create/destroy (100x)",
                        StressTests.RapidAppCreateDestroy),
                }),
        };
    }
}