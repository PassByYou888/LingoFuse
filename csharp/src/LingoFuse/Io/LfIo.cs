using System;

using LingoFuse.Core;

namespace LingoFuse.Io;

// ============================================================================
// LfIo — NUL-framed string and JSON I/O on top of DataHandle.
// ============================================================================
//
// Wire format
// -----------
// A JSON payload on a LingoFuse data handle is:
//
//     [UTF-8 encoded JSON text][0x00]
//
// A plain-text payload uses the same framing:
//
//     [UTF-8 text][0x00]
//
// Reading is fault-tolerant: if no NUL byte is present before the end
// of the buffer, the entire remaining buffer is consumed.
//
// ----------------------------------------------------------------------------
// LAYERING
// ----------------------------------------------------------------------------
// DataHandle is the LOW-LEVEL primitive layer: raw bytes, atomic types,
// and NUL-framed strings with no serialization policy.
//
// LfIo is the PROTOCOL layer: it adds the framing conventions and the
// JSON serialization policy on top of DataHandle.
//
//   Callers that need:
//       raw bytes with no policy         -> DataHandle directly
//       NUL-framed UTF-8 text            -> LfIo.WriteString / ReadString
//       NUL-framed raw bytes             -> LfIo.WriteStringBytes /
//                                           ReadStringBytes
//       JSON with the toolchain policy   -> LfIo.WriteJson / ReadJson
//
// The two layers do not overlap. LfIo never reaches into the native
// layer directly; it always goes through DataHandle.
//
// ----------------------------------------------------------------------------
// JSON POLICY
// ----------------------------------------------------------------------------
// The serialization policy is defined by JsonPolicy and is the single
// source of truth for the whole .NET toolchain:
//
//     - compact output, no indentation;
//     - non-ASCII characters emitted as literal UTF-8, never as \uXXXX
//       escapes, so the output is byte-identical to what the Python,
//       C++ and Pascal producers emit;
//     - invalid UTF-8 in a string value is replaced with U+FFFD, so a
//       broken producer cannot bring the writer down.
//
// The deserialization policy is lenient: a payload that is not JSON
// will be rejected with a LingoFuseException. Callers that need a
// non-throwing path use TryReadJson.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException              a reference argument is null
//     LingoFuseObjectDisposedException   the handle has been disposed
//     LingoFuseException                 JSON serialization or
//                                        deserialization failed
//     LingoFuseIoException               a NUL-framed write failed (a
//                                        short write on the native side)
//
// TryReadJson never throws for I/O or JSON reasons. It may still throw
// ArgumentNullException or LingoFuseObjectDisposedException for caller
// misuse.
// ============================================================================

/// <summary>
/// Unified NUL-framed payload I/O for LingoFuse data handles.
/// </summary>
public static class LfIo
{
    // ====================================================================
    // String I/O — NUL-framed UTF-8
    // ====================================================================

    /// <summary>
    /// Writes <paramref name="value"/> as UTF-8, followed by a NUL byte.
    /// An empty string writes exactly one byte (the NUL).
    /// </summary>
    /// <param name="handle">Target handle. Must not be null.</param>
    /// <param name="value">UTF-8 string. Must not be null.</param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> or <paramref name="value"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public static void WriteString(DataHandle handle, string value)
    {
        ArgumentNullException.ThrowIfNull(handle);
        ArgumentNullException.ThrowIfNull(value);
        handle.WriteString(value);
    }

    /// <summary>
    /// Reads a UTF-8 string from the current cursor, stopping at the
    /// first NUL byte. When no NUL is present, all remaining bytes are
    /// consumed and returned.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public static string ReadString(DataHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);
        return handle.ReadString();
    }

    // ====================================================================
    // Byte-oriented I/O — NUL-framed raw bytes
    // ====================================================================

    /// <summary>
    /// Writes raw bytes followed by a NUL terminator. The bytes are
    /// written verbatim; embedded NUL bytes are preserved.
    /// </summary>
    /// <param name="handle">Target handle. Must not be null.</param>
    /// <param name="data">
    /// Source bytes. Must not be null. An empty array writes exactly
    /// one byte (the NUL).
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> or <paramref name="data"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public static void WriteStringBytes(DataHandle handle, byte[] data)
    {
        ArgumentNullException.ThrowIfNull(handle);
        ArgumentNullException.ThrowIfNull(data);

        if (data.Length > 0)
        {
            handle.WriteBytes(data);
        }
        handle.WriteBytes(new byte[1]);
    }

    /// <summary>
    /// Reads the bytes before the next NUL terminator (or all remaining
    /// bytes when no terminator is present). The cursor is advanced past
    /// the NUL, or one byte past the end of the buffer when no NUL was
    /// found, matching the native fault-tolerant read behaviour.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public static byte[] ReadStringBytes(DataHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);

        IntPtr buffer = handle.GetBufferPointer();
        long start = handle.Position;
        long end = handle.Size;

        if (buffer == IntPtr.Zero || start >= end)
        {
            return Array.Empty<byte>();
        }

        long scan = start;
        while (scan < end)
        {
            byte b = System.Runtime.InteropServices.Marshal.ReadByte(
                buffer, (int)scan);
            if (b == 0)
            {
                break;
            }
            scan++;
        }

        int length = (int)(scan - start);
        byte[] result = Array.Empty<byte>();

        if (length > 0)
        {
            result = new byte[length];
            System.Runtime.InteropServices.Marshal.Copy(
                buffer + (int)start, result, 0, length);
        }

        // Advance past the NUL when found; otherwise to one byte past
        // the end, matching the native fault-tolerant read behaviour.
        handle.Position = scan < end ? scan + 1 : end + 1;
        return result;
    }

    /// <summary>
    /// Reads every remaining byte from the current cursor to the end of
    /// the buffer, without NUL handling.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public static byte[] ReadAllBytes(DataHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);
        return handle.ReadAllBytes();
    }

    // ====================================================================
    // JSON I/O
    // ====================================================================

    /// <summary>
    /// Serialises <paramref name="value"/> using <see cref="JsonPolicy"/>
    /// and writes it with the standard NUL terminator.
    /// </summary>
    /// <param name="handle">Target handle. Must not be null.</param>
    /// <param name="value">
    /// Any JSON-serialisable value, or <c>null</c>. A null value is
    /// written as the JSON literal <c>null</c>.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the value cannot be serialised to JSON.
    /// </exception>
    public static void WriteJson(DataHandle handle, object? value)
    {
        ArgumentNullException.ThrowIfNull(handle);
        string text = JsonPolicy.Dumps(value);
        handle.WriteString(text);
    }

    /// <summary>
    /// Reads a NUL-framed JSON payload and deserialises it into
    /// <typeparamref name="T"/>.
    /// </summary>
    /// <param name="handle">Source handle. Must not be null.</param>
    /// <returns>The deserialised value.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the payload is not valid JSON or cannot be
    /// materialised as <typeparamref name="T"/>.
    /// </exception>
    public static T ReadJson<T>(DataHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);
        string text = handle.ReadString();
        return JsonPolicy.Loads<T>(text);
    }

    /// <summary>
    /// Attempts to read and deserialise a NUL-framed JSON payload
    /// without throwing on malformed input. The cursor is advanced
    /// regardless of whether the payload parses successfully.
    /// </summary>
    /// <param name="handle">Source handle. Must not be null.</param>
    /// <param name="value">
    /// On success, receives the deserialised value. On failure,
    /// receives <c>default</c>.
    /// </param>
    /// <returns>true on success, false when the payload is not valid JSON.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public static bool TryReadJson<T>(DataHandle handle, out T? value)
    {
        ArgumentNullException.ThrowIfNull(handle);
        string text = handle.ReadString();
        return JsonPolicy.TryLoads(text, out value);
    }
}