// ============================================================================
// File: csharp/src/LingoFuse_cs/P2PUid.cs
// ============================================================================
// P2PUid — 32-byte session UID value type.
// ============================================================================
// A P2PUid is the managed representation of the Pascal-side
// TP2P_UID___ (array[0..31] of Byte), which the framework assigns to
// every client at TunnelLink time and injects into every outbound
// request payload as "side data".
//
// WHY A DEDICATED TYPE
// --------------------
// The UID is a first-class concept in LingoFuse's routing model:
//
//   * It is the primary key for UID addressing (LF_UID_Call,
//     LF_UID_Notify, LF_UID_Sequenced_Notify).
//   * It is the value returned by DataHandle.GetSenderUid() inside a
//     callback, used for authentication, audit logging, and
//     session-scoped routing.
//   * It is a 32-byte binary blob that must round-trip byte-for-byte
//     across IPC/TCP boundaries and across every language binding.
//
// Exposing it as a plain byte[] would be dangerous: arrays are mutable,
// reference-equality semantics are wrong for a value concept, and there
// is no enforcement of the 32-byte invariant. Exposing it as an
// `unsafe fixed byte[32]` would require the consuming project to enable
// AllowUnsafeBlocks, which this binding deliberately avoids.
//
// The solution is a readonly struct backed by four ulong fields:
//
//   * 4 x ulong = 32 bytes, byte-for-byte compatible with the Pascal
//     array (see TUIDNative in NativeTypes.cs).
//   * Blittable: no marshalling stub, no allocation, no unsafe code.
//   * Value semantics: equality is structural, and the struct cannot
//     be mutated after construction.
//   * Zero GC pressure: `default(P2PUid)` is a valid zero-filled UID,
//     and every P2PUid lives on the stack or inline in its container.
//
// BYTE ORDER
// ----------
// The four ulong fields are laid out in LITTLE-ENDIAN order:
//
//   _lo   = bytes  0..7
//   _hi   = bytes  8..15
//   _top  = bytes 16..23
//   _last = bytes 24..31
//
// This matches the Pascal-side `array[0..31] of Byte` layout when
// interpreted as four consecutive 64-bit little-endian words, which is
// how the C ABI passes the aggregate by value on x86-64. On the wire,
// the UID is always transmitted as 32 raw bytes; the byte-for-byte
// mapping between an array and a P2PUid is documented and tested.
//
// STRING FORM
// -----------
// ToHexString() returns 64 lowercase hexadecimal characters, in byte
// order (byte[0] first). TryParse() accepts exactly the same format,
// with either lowercase or uppercase letters. There is no separator,
// no prefix ("0x"), and no grouping; the string is a flat 64-character
// hex encoding of the 32 bytes.
//
// ============================================================================

using System;
using System.Buffers.Binary;
using System.Runtime.InteropServices;

using LingoFuse.Native;

namespace LingoFuse;

/// <summary>
/// A 32-byte LingoFuse session UID.
/// </summary>
/// <remarks>
/// <para>
/// Immutable value type. Two P2PUid values are equal if and only if
/// all 32 bytes are equal. <see cref="Empty"/> is the all-zero UID,
/// which is the framework's sentinel for "no UID" and is what
/// <c>DataHandle.GetSenderUid()</c> returns when the identity is not
/// available (for example, on an output handle or a caller-created
/// handle).
/// </para>
/// <para>
/// <b>Lifetime:</b> a UID is assigned to a client at TunnelLink time
/// and is REGENERATED on every reconnect. Do not cache a UID across a
/// link loss and expect it to remain valid; re-probe it after
/// reconnection (see the "whoami" pattern in the Pascal guide).
/// </para>
/// </remarks>
[StructLayout(LayoutKind.Sequential)]
public readonly struct P2PUid : IEquatable<P2PUid>
{
    // --------------------------------------------------------------------
    // Storage
    // --------------------------------------------------------------------
    //
    // Four ulong fields laid out in little-endian byte order:
    //
    //     _lo   covers bytes  0..7
    //     _hi   covers bytes  8..15
    //     _top  covers bytes 16..23
    //     _last covers bytes 24..31
    //
    // 4 x 8 = 32 bytes, matching the Pascal array[0..31] of Byte
    // byte-for-byte, and matching the C ABI's by-value aggregate
    // convention for >16-byte structs on x86-64.
    // --------------------------------------------------------------------

    private readonly ulong _lo;
    private readonly ulong _hi;
    private readonly ulong _top;
    private readonly ulong _last;

    /// <summary>
    /// The all-zero UID.
    /// </summary>
    /// <remarks>
    /// This is the framework's sentinel for "no UID". It is returned
    /// by <c>DataHandle.GetSenderUid()</c> when the underlying native
    /// call could not populate the identity.
    /// </remarks>
    public static readonly P2PUid Empty = default;

    /// <summary>
    /// Constructs a UID from four little-endian 64-bit words.
    /// </summary>
    /// <remarks>
    /// This constructor is private. Use <see cref="FromBytes"/> or
    /// <see cref="TryParse"/> to obtain a P2PUid from external data.
    /// </remarks>
    private P2PUid(ulong lo, ulong hi, ulong top, ulong last)
    {
        _lo = lo;
        _hi = hi;
        _top = top;
        _last = last;
    }

    // --------------------------------------------------------------------
    // Construction
    // --------------------------------------------------------------------

    /// <summary>
    /// Creates a UID from exactly 32 bytes.
    /// </summary>
    /// <param name="bytes">
    /// A span of exactly 32 bytes. The byte at index 0 is the first
    /// byte of the UID; the byte at index 31 is the last.
    /// </param>
    /// <exception cref="ArgumentException">
    /// Thrown when <paramref name="bytes"/> does not have a length of
    /// exactly 32.
    /// </exception>
    public static P2PUid FromBytes(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != 32)
        {
            throw new ArgumentException(
                $"A P2PUid is exactly 32 bytes; got {bytes.Length}.",
                nameof(bytes));
        }

        return new P2PUid(
            BinaryPrimitives.ReadUInt64LittleEndian(bytes.Slice(0, 8)),
            BinaryPrimitives.ReadUInt64LittleEndian(bytes.Slice(8, 8)),
            BinaryPrimitives.ReadUInt64LittleEndian(bytes.Slice(16, 8)),
            BinaryPrimitives.ReadUInt64LittleEndian(bytes.Slice(24, 8)));
    }

    /// <summary>
    /// Parses a 64-character hexadecimal string into a UID.
    /// </summary>
    /// <param name="hex">
    /// A 64-character hex string. Letters may be lowercase or uppercase.
    /// No separators, no prefix.
    /// </param>
    /// <param name="uid">
    /// On success, receives the parsed UID. On failure, receives
    /// <see cref="Empty"/>.
    /// </param>
    /// <returns>
    /// <c>true</c> if <paramref name="hex"/> is a valid 64-character
    /// hex string; <c>false</c> otherwise.
    /// </returns>
    public static bool TryParse(string? hex, out P2PUid uid)
    {
        uid = Empty;

        if (hex is null || hex.Length != 64)
        {
            return false;
        }

        // Parse directly into the four ulong fields. This avoids an
        // intermediate 32-byte array and a second pass, and keeps the
        // byte-order handling in exactly one place.
        Span<byte> bytes = stackalloc byte[32];
        for (int i = 0; i < 32; i++)
        {
            int hi = HexValue(hex[i * 2]);
            int lo = HexValue(hex[i * 2 + 1]);
            if (hi < 0 || lo < 0)
            {
                return false;
            }
            bytes[i] = (byte)((hi << 4) | lo);
        }

        uid = FromBytes(bytes);
        return true;
    }

    /// <summary>
    /// Parses a 64-character hexadecimal string into a UID, throwing on
    /// failure.
    /// </summary>
    /// <exception cref="FormatException">
    /// Thrown when <paramref name="hex"/> is not a valid 64-character
    /// hex string.
    /// </exception>
    public static P2PUid Parse(string hex)
    {
        if (!TryParse(hex, out var uid))
        {
            throw new FormatException(
                "Expected 64 hexadecimal characters (0-9, a-f, A-F).");
        }
        return uid;
    }

    // --------------------------------------------------------------------
    // Conversion
    // --------------------------------------------------------------------

    /// <summary>
    /// True when all 32 bytes are zero.
    /// </summary>
    public bool IsEmpty =>
        _lo == 0UL && _hi == 0UL && _top == 0UL && _last == 0UL;

    /// <summary>
    /// Returns the UID as a freshly allocated 32-byte array.
    /// </summary>
    /// <remarks>
    /// The returned array is independent of this value and may be
    /// mutated freely by the caller. Byte[0] is the first byte of the
    /// UID.
    /// </remarks>
    public byte[] ToByteArray()
    {
        var bytes = new byte[32];
        CopyTo(bytes);
        return bytes;
    }

    /// <summary>
    /// Copies the 32 bytes of this UID into <paramref name="destination"/>.
    /// </summary>
    /// <param name="destination">
    /// A span of at least 32 bytes. The first 32 bytes are overwritten.
    /// </param>
    /// <exception cref="ArgumentException">
    /// Thrown when <paramref name="destination"/> is shorter than 32.
    /// </exception>
    public void CopyTo(Span<byte> destination)
    {
        if (destination.Length < 32)
        {
            throw new ArgumentException(
                $"A P2PUid requires 32 bytes of destination space; " +
                $"got {destination.Length}.",
                nameof(destination));
        }

        BinaryPrimitives.WriteUInt64LittleEndian(destination.Slice(0, 8), _lo);
        BinaryPrimitives.WriteUInt64LittleEndian(destination.Slice(8, 8), _hi);
        BinaryPrimitives.WriteUInt64LittleEndian(destination.Slice(16, 8), _top);
        BinaryPrimitives.WriteUInt64LittleEndian(destination.Slice(24, 8), _last);
    }

    /// <summary>
    /// Returns 64 lowercase hexadecimal characters (byte[0] first).
    /// </summary>
    public string ToHexString()
    {
        // Stack-allocated character buffer avoids a heap allocation for
        // the intermediate char[]. StringBuilder would also work, but
        // this is the common case and is worth the extra two lines.
        Span<char> chars = stackalloc char[64];
        WriteHex(_lo, chars.Slice(0, 16));
        WriteHex(_hi, chars.Slice(16, 16));
        WriteHex(_top, chars.Slice(32, 16));
        WriteHex(_last, chars.Slice(48, 16));
        return new string(chars);
    }

    /// <inheritdoc/>
    public override string ToString() => ToHexString();

    // --------------------------------------------------------------------
    // Internal bridge to the native representation
    // --------------------------------------------------------------------

    /// <summary>
    /// Converts this UID into the native representation used by the
    /// P/Invoke layer. Internal to the assembly.
    /// </summary>
    internal TUIDNative ToNative() => new TUIDNative
    {
        Lo = _lo,
        Hi = _hi,
        Top = _top,
        Last = _last,
    };

    /// <summary>
    /// Converts a native UID into the public value type. Internal to
    /// the assembly.
    /// </summary>
    internal static P2PUid FromNative(TUIDNative native) =>
        new P2PUid(native.Lo, native.Hi, native.Top, native.Last);

    // --------------------------------------------------------------------
    // Equality
    // --------------------------------------------------------------------

    /// <inheritdoc/>
    public bool Equals(P2PUid other) =>
        _lo == other._lo
        && _hi == other._hi
        && _top == other._top
        && _last == other._last;

    /// <inheritdoc/>
    public override bool Equals(object? obj) =>
        obj is P2PUid other && Equals(other);

    /// <inheritdoc/>
    public override int GetHashCode() =>
        HashCode.Combine(_lo, _hi, _top, _last);

    /// <summary>Structural equality operator.</summary>
    public static bool operator ==(P2PUid left, P2PUid right) =>
        left.Equals(right);

    /// <summary>Structural inequality operator.</summary>
    public static bool operator !=(P2PUid left, P2PUid right) =>
        !left.Equals(right);

    // --------------------------------------------------------------------
    // Private helpers
    // --------------------------------------------------------------------

    /// <summary>
    /// Writes <paramref name="value"/> as 16 lowercase hex characters,
    /// with the LOW-order nibble of the byte stream last (i.e. byte 0
    /// of the byte stream is the first two characters of the output).
    /// </summary>
    /// <remarks>
    /// The ulong is stored little-endian relative to the 32-byte UID,
    /// so the byte at output position 0 corresponds to bits 0..7 of
    /// the ulong. The loop below writes the nibbles in that order.
    /// </remarks>
    private static void WriteHex(ulong value, Span<char> dest)
    {
        // dest.Length is always 16 at every call site.
        for (int i = 0; i < 8; i++)
        {
            byte b = (byte)(value >> (i * 8));
            dest[i * 2] = HexDigitsLower[(b >> 4) & 0x0F];
            dest[i * 2 + 1] = HexDigitsLower[b & 0x0F];
        }
    }

    private static int HexValue(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };

    private static readonly char[] HexDigitsLower =
        { '0', '1', '2', '3', '4', '5', '6', '7',
          '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
}