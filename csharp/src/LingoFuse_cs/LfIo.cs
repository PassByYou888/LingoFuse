using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LingoFuse;

// ============================================================================
// LfIo — the single entry point for JSON and string I/O on a DataHandle.
// ============================================================================
//
// WHAT THIS FILE DEFINES
// ----------------------
// This file defines the ONE canonical way to move a managed object to
// and from the bytes carried by a LingoFuse DataHandle. Every other
// component — user code, code generators, cross-language peers — must
// go through these functions. There is deliberately no second path.
//
// It is NOT a JSON schema. The JSON grammar is RFC 8259. What this
// file fixes is:
//
//   1. The framing policy  — how a payload is terminated on the wire.
//   2. The serialization policy — how a .NET object becomes JSON text.
//   3. The read tolerance  — how a missing terminator is handled.
//
// WIRE FORMAT
// -----------
// A JSON payload on a DataHandle is:
//
//     [UTF-8 encoded JSON text][0x00]
//
// A plain-text payload uses the same framing:
//
//     [UTF-8 text][0x00]
//
// A raw binary payload is:
//
//     [arbitrary bytes][0x00]
//
// The trailing NUL is what the receiving side uses to find the end of
// the payload. Reading is fault-tolerant: if no NUL is found before
// the end of the buffer, the entire remaining buffer is consumed. This
// is required for interop with producers that do not append a NUL
// (HTTP bridges, browsers, hand-written clients).
//
// SERIALIZATION POLICY
// --------------------
// The JSON serializer is configured with three mandatory properties:
//
//   * Compact output: no indentation, no trailing newline.
//
//   * Literal UTF-8 for non-ASCII characters. "你好" is emitted as
//     the three UTF-8 bytes E4 BD A0 E5 A5 BD, not as the escape
//     sequence \u4f60\u597d. This is what makes the C# producer emit
//     the same bytes as the Pascal, Python and C++ producers.
//
//   * Replace-invalid: a .NET string that contains an unpaired
//     surrogate (which cannot be encoded to UTF-8) is emitted with
//     U+FFFD instead of raising. This mirrors the encoder fallback
//     used by every other binding.
//
// SUPPLEMENTARY PLANE CHARACTERS
// ------------------------------
// System.Text.Json's UnsafeRelaxedJsonEscaping encoder emits BMP
// characters as literal UTF-8, but still emits SUPPLEMENTARY PLANE
// characters (U+10000 and above — for example emoji) as a pair of
// \uXXXX escapes, even when ensure_ascii is effectively disabled.
//
// Every other LingoFuse binding emits these characters as literal
// UTF-8. To match the cross-language contract, Dumps runs a post-
// processing pass that rewrites each surrogate escape pair back into
// the raw .NET char pair (which the subsequent UTF-8 encoding will
// emit as a literal 4-byte sequence).
//
// Only surrogate pairs are unescaped. Control characters, quotes and
// backslashes remain escaped; their escapes are not touched.
//
// DESERIALIZATION POLICY
// ----------------------
// Reading is strict on JSON grammar but lenient on framing: a payload
// that is not valid JSON raises LingoFuseException. Callers that need
// a non-throwing path use TryReadJson.
//
// LAYERING
// --------
// DataHandle is the LOW-LEVEL primitive: raw bytes, atomic types, and
// NUL-framed strings with no serialization policy. LfIo is the
// PROTOCOL layer: it adds the JSON serializer configuration and the
// NUL-framed byte-sequence contract. LfIo is built on top of
// DataHandle and never calls the Native layer directly.
//
// ============================================================================

/// <summary>
/// The single entry point for JSON and string I/O on a LingoFuse
/// data handle.
/// </summary>
public static class LfIo
{
    // ====================================================================
    // Serialization policy (private — the policy is not a public knob)
    // ====================================================================
    //
    // There is deliberately no public accessor for the serializer
    // options. Exposing them would invite callers to build a second
    // serialization path, defeating the purpose of this file. If a
    // caller needs a different shape of JSON, that need belongs to the
    // peer application, not to the transport.
    // ====================================================================

    private static readonly JsonSerializerOptions Options = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        return new JsonSerializerOptions
        {
            WriteIndented = false,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            PropertyNameCaseInsensitive = false,
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
            NumberHandling = JsonNumberHandling.Strict,
        };
    }

    // --------------------------------------------------------------------
    // Private JSON helpers
    // --------------------------------------------------------------------

    /// <summary>
    /// Serialize <paramref name="value"/> to compact UTF-8 JSON text
    /// using the policy defined by <see cref="Options"/>, then rewrite
    /// any supplementary-plane surrogate escape pairs back into raw
    /// characters. A null value produces the four-byte JSON literal
    /// <c>null</c>.
    /// </summary>
    private static string Dumps(object? value)
    {
        try
        {
            string json = JsonSerializer.Serialize(value, Options);
            return UnescapeSurrogatePairs(json);
        }
        catch (Exception ex) when (ex is not LingoFuseException)
        {
            string typeName = value?.GetType().FullName ?? "null";
            throw new LingoFuseException(
                $"JSON serialization failed for type '{typeName}'.", ex);
        }
    }

    /// <summary>
    /// Rewrite every pair of surrogate escapes (<c>\uD8xx\uDCxx</c>)
    /// back into the corresponding raw .NET <see cref="char"/> pair.
    /// </summary>
    /// <remarks>
    /// This is the fix-up that makes C# JSON output byte-for-byte
    /// compatible with the Pascal, Python and C++ bindings for
    /// supplementary-plane characters (for example emoji). Those
    /// bindings emit the character as a literal 4-byte UTF-8
    /// sequence; System.Text.Json emits the same character as two
    /// \uXXXX escapes even with the relaxed encoder.
    ///
    /// Only surrogate pairs are processed. A lone \uXXXX escape that
    /// is not part of a surrogate pair (a control character, or a
    /// character that a future encoder build might escape) is left
    /// untouched, so no semantic change can occur.
    /// </remarks>
    private static string UnescapeSurrogatePairs(string s)
    {
        // Fast path: no escapes at all.
        if (s.IndexOf("\\u", StringComparison.Ordinal) < 0)
        {
            return s;
        }

        var sb = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            if (i + 12 <= s.Length
                && s[i] == '\\' && s[i + 1] == 'u'
                && s[i + 6] == '\\' && s[i + 7] == 'u'
                && IsHex(s[i + 2]) && IsHex(s[i + 3])
                && IsHex(s[i + 4]) && IsHex(s[i + 5])
                && IsHex(s[i + 8]) && IsHex(s[i + 9])
                && IsHex(s[i + 10]) && IsHex(s[i + 11]))
            {
                int high = Convert.ToInt32(
                    s.Substring(i + 2, 4), 16);
                int low = Convert.ToInt32(
                    s.Substring(i + 8, 4), 16);

                if (high >= 0xD800 && high <= 0xDBFF
                    && low >= 0xDC00 && low <= 0xDFFF)
                {
                    // A valid UTF-16 surrogate pair. Append both
                    // chars; the subsequent UTF-8 encoding will
                    // emit the literal 4-byte sequence.
                    sb.Append((char)high);
                    sb.Append((char)low);
                    i += 11; // +1 from the loop header = 12 total
                    continue;
                }
            }

            sb.Append(s[i]);
        }
        return sb.ToString();
    }

    private static bool IsHex(char c)
    {
        return (c >= '0' && c <= '9')
            || (c >= 'a' && c <= 'f')
            || (c >= 'A' && c <= 'F');
    }

    /// <summary>
    /// Deserialize a UTF-8 JSON string into an instance of
    /// <typeparamref name="T"/>.
    /// </summary>
    private static T Loads<T>(string json)
    {
        try
        {
            T? result = JsonSerializer.Deserialize<T>(json, Options);
            if (result is null && default(T) is not null)
            {
                throw new LingoFuseException(
                    $"JSON payload deserialized to null but " +
                    $"T={typeof(T).FullName} is non-nullable.");
            }
            return result!;
        }
        catch (JsonException ex)
        {
            throw new LingoFuseException(
                $"Invalid JSON payload: {ex.Message}", ex);
        }
        catch (NotSupportedException ex)
        {
            // T is not supported by System.Text.Json (for example an
            // interface without a converter, or a type with no
            // parameterless constructor reachable through reflection).
            // This is a caller contract violation, not a transport
            // failure, but it must still surface as a LingoFuse
            // exception so the caller has a single catch type.
            throw new LingoFuseException(
                $"JSON deserialization is not supported for type " +
                $"'{typeof(T).FullName}': {ex.Message}", ex);
        }
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="Loads{T}"/>.
    /// </summary>
    private static bool TryLoads<T>(string? json, out T? value)
    {
        value = default;
        if (string.IsNullOrEmpty(json))
        {
            return false;
        }

        try
        {
            value = JsonSerializer.Deserialize<T>(json, Options);
            return true;
        }
        catch (JsonException)
        {
            // Malformed JSON, type mismatch, or a missing required
            // member. The Try family promises a boolean result.
            return false;
        }
        catch (NotSupportedException)
        {
            // T is not supported by System.Text.Json. Also a boolean
            // result, not an exception, on the Try path.
            return false;
        }
    }

    // ====================================================================
    // String I/O — NUL-framed UTF-8
    // ====================================================================

    /// <summary>
    /// Writes <paramref name="value"/> as UTF-8, followed by a NUL
    /// byte. An empty string writes exactly one byte (the NUL).
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
    /// <exception cref="LingoFuseIoException">
    /// Thrown when the native layer writes fewer bytes than requested.
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
    /// bytes when no terminator is present). The cursor is advanced
    /// past the NUL, or one byte past the end of the buffer when no
    /// NUL was found, matching the native fault-tolerant read
    /// behaviour.
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
            byte b = Marshal.ReadByte(buffer, (int)scan);
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
            Marshal.Copy(buffer + (int)start, result, 0, length);
        }

        // Advance past the NUL when found; otherwise to one byte past
        // the end, matching the native fault-tolerant read behaviour.
        handle.Position = scan < end ? scan + 1 : end + 1;
        return result;
    }

    /// <summary>
    /// Reads every remaining byte from the current cursor to the end of
    /// the buffer, without NUL handling. The cursor advances to the end.
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
    /// Serializes <paramref name="value"/> using the policy defined by
    /// this file and writes it with the standard NUL terminator.
    /// </summary>
    /// <param name="handle">Target handle. Must not be null.</param>
    /// <param name="value">
    /// Any JSON-serializable value, or <c>null</c>. A null value is
    /// written as the JSON literal <c>null</c>.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the value cannot be serialized to JSON.
    /// </exception>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when the native layer writes fewer bytes than requested.
    /// </exception>
    public static void WriteJson(DataHandle handle, object? value)
    {
        ArgumentNullException.ThrowIfNull(handle);
        string text = Dumps(value);
        handle.WriteString(text);
    }

    /// <summary>
    /// Reads a NUL-framed JSON payload and deserializes it into
    /// <typeparamref name="T"/>.
    /// </summary>
    /// <param name="handle">Source handle. Must not be null.</param>
    /// <returns>The deserialized value.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handle"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the payload is not valid JSON or cannot be
    /// materialized as <typeparamref name="T"/>.
    /// </exception>
    public static T ReadJson<T>(DataHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);
        string text = handle.ReadString();
        return Loads<T>(text);
    }

    /// <summary>
    /// Attempts to read and deserialize a NUL-framed JSON payload
    /// without throwing on malformed input. The cursor is advanced
    /// regardless of whether the payload parses successfully.
    /// </summary>
    /// <param name="handle">Source handle. Must not be null.</param>
    /// <param name="value">
    /// On success, receives the deserialized value. On failure,
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
        return TryLoads(text, out value);
    }
}