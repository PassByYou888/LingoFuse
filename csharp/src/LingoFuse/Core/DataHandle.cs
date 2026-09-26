using System;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text;

using LingoFuse.Native;

namespace LingoFuse.Core;

// ============================================================================
// DataHandle — RAII wrapper around a native TDataHnd.
// ============================================================================
//
// Responsibility
// --------------
// Owns a native data handle and releases it deterministically when the
// object is disposed. Provides byte-level, atomic-type, and NUL-framed
// string I/O on top of the underlying buffer.
//
// ----------------------------------------------------------------------------
// LAYERING
// ----------------------------------------------------------------------------
// DataHandle is the LOW-LEVEL primitive layer. It exposes exactly three
// families of operation:
//
//     Raw byte I/O         WriteBytes / ReadBytes / ReadBytesExact
//     Atomic-type I/O      WriteInt8..WriteDouble / ReadInt8..ReadDouble
//     NUL-framed strings   WriteString / ReadString
//
// For higher-level, protocol-aware I/O, use LingoFuse.Io.LfIo:
//
//     WriteStringBytes / ReadStringBytes    raw bytes + NUL framing
//     WriteJson / ReadJson / TryReadJson    JSON + NUL framing
//
// The two layers do not overlap: LfIo is built on top of DataHandle and
// adds only the framing / serialization policy.
//
// ----------------------------------------------------------------------------
// OWNERSHIP
// ----------------------------------------------------------------------------
// A DataHandle is either "owning" or "borrowing":
//
//     Owning    — created by the public constructor. Dispose() calls
//                 LF_FreeData on the native handle.
//     Borrowing — created by FromRaw(handle, owned: false). Dispose()
//                 is a no-op; the native layer owns the underlying
//                 resource and releases it when the callback returns.
//
// Borrowing is used for the input/output handles passed into a callback.
// Freeing them from managed code would be a double-free.
//
// {!!!!!  BORROWED HANDLE DISPOSE IS A NO-OP  !!!!!}
// For a borrowed handle, Dispose() deliberately does NOT change the
// wrapper state. This is a defensive design:
//
//   - A callback body that mistakenly calls Dispose() on its input or
//     output handle must NOT corrupt the wrapper state for the rest of
//     the callback body. The user may still need to read from the
//     input after the accidental Dispose call.
//
//   - The wrapper's _disposed flag stays false, so IsValid, Raw and
//     all read methods remain usable until the callback returns and
//     the native layer releases the underlying resource.
//
// The result: an accidental Dispose inside a callback is harmless.
// Outside a callback, calling Dispose on a borrowed handle is a
// programming error (the handle is not yours to own) but is also
// harmless.
//
// ----------------------------------------------------------------------------
// STRING CONTRACT
// ----------------------------------------------------------------------------
// LingoFuse frames strings with a single trailing NUL (0x00) byte on the
// wire. WriteString always appends the terminator. ReadString is
// fault-tolerant: it reads until the first NUL, or all remaining bytes
// if no NUL is present. This matches the behaviour of the Pascal
// LF_ReadString and the C++ / Python lf_io.read_string helpers, and keeps
// interop with non-Pascal producers (HTTP bridges, browsers) working.
//
// ----------------------------------------------------------------------------
// {!!!!!  CROSS-LANGUAGE UTF-8 POLICY  !!!!!}
// ----------------------------------------------------------------------------
// The four LingoFuse bindings differ in how they handle invalid UTF-8
// byte sequences during a string read:
//
//     C#        replaces each invalid byte with U+FFFD
//     Pascal    replaces each invalid byte with U+FFFD
//     Python    raises UnicodeDecodeError
//     C++       returns the raw bytes unchanged
//
// C# matches Pascal. When interoperating with Python or C++ peers, be
// aware that:
//
//   - A C# sender writing a .NET string never produces invalid UTF-8
//     (the encoder replaces unpaired surrogates with U+FFFD on the way
//     out), so a Python receiver will never see a decode error from a
//     C# peer.
//
//   - A C# receiver of a Python-produced payload that contains invalid
//     UTF-8 will silently see U+FFFD where Python would have thrown.
//     If a C# caller needs to detect invalid UTF-8, it must read the
//     raw bytes via ReadBytesExact / ReadAllBytes and inspect them
//     itself.
//
// This policy is a hard C# design decision, not a bug. It keeps the
// reader binary-safe and matches the Pascal binding.
//
// ----------------------------------------------------------------------------
// I/O FAILURE SEMANTICS
// ----------------------------------------------------------------------------
// Two symmetric families of read/write operations are offered so that
// callers can choose their failure semantics explicitly:
//
//   Partial   ReadBytes(n)
//             Returns up to n bytes, possibly fewer if the buffer ends
//             early. Never throws for a short read. The returned array
//             may be empty.
//
//   Exact     ReadBytesExact(n)  /  ReadInt8() .. ReadDouble()
//             Requires exactly n bytes. Throws LingoFuseIoException if
//             the buffer does not contain enough data.
//
// The atomic-type readers (ReadInt8 .. ReadDouble) are Exact by default,
// because a partially read integer is never useful.
//
// Every Exact reader has a non-throwing Try* counterpart that returns
// false instead of throwing:
//
//     TryReadBytes(n, out byte[]? value)
//     TryReadInt8(out sbyte value)
//     TryReadInt16(out short value)
//     TryReadInt32(out int value)
//     TryReadInt64(out long value)
//     TryReadSingle(out float value)
//     TryReadDouble(out double value)
//     TryReadString(out string? value)
//
// ----------------------------------------------------------------------------
// THREAD SAFETY
// ----------------------------------------------------------------------------
// The native library is thread-safe, but a single data handle cannot be
// written concurrently. Read access is safe while another thread reads.
// Callers that share a handle across threads must serialise writes
// themselves.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException              a reference argument is null
//     ArgumentOutOfRangeException        a numeric argument is negative
//                                        or outside its supported range
//     LingoFuseObjectDisposedException   the handle has been disposed
//     LingoFuseIoException               an exact read or a write failed
//
// The Try* variants never throw for I/O reasons; they may still throw
// ArgumentNullException or LingoFuseObjectDisposedException for caller
// misuse.
// ============================================================================

/// <summary>
/// RAII wrapper around a native LingoFuse data handle.
/// </summary>
/// <remarks>
/// Instances are not thread-safe for concurrent writes. Different
/// instances are fully independent.
/// </remarks>
public sealed class DataHandle : IDisposable
{
    /// <summary>
    /// UTF-8 encoding used for the NUL-framed string contract. No byte
    /// order mark is emitted; invalid byte sequences are replaced with
    /// U+FFFD by the encoder's default fallback, matching the Pascal
    /// binding's behaviour.
    /// </summary>
    private static readonly Encoding Utf8 =
        new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    private IntPtr _handle;
    private readonly bool _owned;
    private bool _disposed;

    // --------------------------------------------------------------------
    // Construction
    // --------------------------------------------------------------------

    /// <summary>
    /// Creates a new data handle bound to the given API name. The
    /// underlying buffer starts empty.
    /// </summary>
    /// <param name="apiName">
    /// UTF-8 API name. Must not be null. An empty string is allowed but
    /// unusual; the native side stores the name as the "MethodName"
    /// component of the wire format.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the native library fails to allocate the handle.
    /// </exception>
    public DataHandle(string apiName)
    {
        ArgumentNullException.ThrowIfNull(apiName);

        IntPtr namePtr = Utf8Marshal.Alloc(apiName);
        try
        {
            DataHnd raw = NativeMethods.LF_CreateData(namePtr);
            if (!raw.IsValid)
            {
                throw new LingoFuseException(
                    $"Failed to create a data handle for API '{apiName}'.");
            }
            _handle = raw.Handle;
            _owned = true;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Wraps an existing raw handle. Intended for internal use when the
    /// native layer already owns the handle (for example, inside a
    /// callback).
    /// </summary>
    /// <param name="raw">Raw pointer to wrap.</param>
    /// <param name="owned">
    /// When <c>true</c>, <see cref="Dispose"/> will call <c>LF_FreeData</c>.
    /// When <c>false</c>, <see cref="Dispose"/> is a no-op and the native
    /// layer retains ownership.
    /// </param>
    public static DataHandle FromRaw(IntPtr raw, bool owned)
    {
        return new DataHandle(raw, owned);
    }

    private DataHandle(IntPtr raw, bool owned)
    {
        _handle = raw;
        _owned = owned;
    }

    // --------------------------------------------------------------------
    // Identity and state
    // --------------------------------------------------------------------

    /// <summary>
    /// Raw native pointer. <see cref="IntPtr.Zero"/> when an owning
    /// handle has been disposed. A borrowed handle keeps its pointer
    /// until the native layer releases it (after the callback returns).
    /// </summary>
    public IntPtr Raw => _handle;

    /// <summary>
    /// True while the handle is valid and usable. A borrowed handle is
    /// always valid until the native layer releases it, even after an
    /// accidental <see cref="Dispose"/> call.
    /// </summary>
    public bool IsValid => !_disposed && _handle != IntPtr.Zero;

    /// <summary>
    /// True when this instance owns the native handle (that is,
    /// <see cref="Dispose"/> will call <c>LF_FreeData</c>).
    /// </summary>
    public bool IsOwning => _owned;

    // --------------------------------------------------------------------
    // Lifetime
    // --------------------------------------------------------------------

    /// <summary>
    /// Releases the native handle when ownership applies.
    /// </summary>
    /// <remarks>
    /// {!!!!!  BORROWED HANDLE SEMANTICS  !!!!!}
    ///
    /// For an OWNING handle:
    ///   - Calls LF_FreeData on the underlying resource.
    ///   - Sets the wrapper's disposed flag; subsequent operations
    ///     throw LingoFuseObjectDisposedException.
    ///   - Idempotent: subsequent Dispose calls are no-ops.
    ///
    /// For a BORROWED handle (owned == false, used inside a callback):
    ///   - This method is a NO-OP. The native layer owns the underlying
    ///     resource and releases it when the callback returns.
    ///   - The wrapper's state is unchanged. IsValid stays true; all
    ///     read methods remain usable until the callback returns.
    ///   - This tolerance protects against an accidental Dispose call
    ///     inside a callback body: the user may still need to read
    ///     from the input after the accidental call.
    /// </remarks>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (!_owned)
        {
            // Borrowed handle: the native layer owns the underlying
            // resource. Dispose() is deliberately a no-op so that an
            // accidental call inside a callback cannot corrupt the
            // wrapper state for the rest of the callback body.
            return;
        }

        _disposed = true;

        if (_handle != IntPtr.Zero)
        {
            var hnd = new DataHnd { Handle = _handle };
            NativeMethods.LF_FreeData(hnd);
        }
        _handle = IntPtr.Zero;
    }

    // --------------------------------------------------------------------
    // Position and size
    // --------------------------------------------------------------------

    /// <summary>
    /// Current read/write cursor position, in bytes.
    /// </summary>
    /// <remarks>
    /// Setting a position past the current size implicitly grows the
    /// buffer. The new bytes are uninitialised.
    /// </remarks>
    /// <exception cref="ArgumentOutOfRangeException">
    /// Thrown when the assigned value is negative.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public long Position
    {
        get
        {
            EnsureNotDisposed();
            return NativeMethods.LF_GetPos(CurrentHnd);
        }
        set
        {
            if (value < 0)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(value), value, "Position must be non-negative.");
            }
            EnsureNotDisposed();
            NativeMethods.LF_SetPos(CurrentHnd, value);
        }
    }

    /// <summary>
    /// Total buffer size, in bytes.
    /// </summary>
    /// <remarks>
    /// Setting a size larger than the current one grows the buffer. The
    /// new bytes are uninitialised. Setting a smaller size shrinks the
    /// buffer and discards the trailing bytes.
    /// </remarks>
    /// <exception cref="ArgumentOutOfRangeException">
    /// Thrown when the assigned value is negative.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public long Size
    {
        get
        {
            EnsureNotDisposed();
            return NativeMethods.LF_GetSize(CurrentHnd);
        }
        set
        {
            if (value < 0)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(value), value, "Size must be non-negative.");
            }
            EnsureNotDisposed();
            NativeMethods.LF_SetSize(CurrentHnd, value);
        }
    }

    /// <summary>
    /// Returns the native pointer to the internal buffer.
    /// </summary>
    /// <remarks>
    /// The pointer is invalidated by any subsequent resize (including
    /// implicit growth caused by a write or by setting
    /// <see cref="Position"/> past the current size). Do not free the
    /// pointer.
    /// </remarks>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public IntPtr GetBufferPointer()
    {
        EnsureNotDisposed();
        return NativeMethods.LF_GetBuffer(CurrentHnd);
    }

    // ====================================================================
    // Byte I/O — partial-read family
    // ====================================================================
    //
    // The partial-read family never throws for a short read. It returns
    // as many bytes as are actually available, which may be fewer than
    // requested, or none at all at end-of-buffer.

    /// <summary>
    /// Appends <paramref name="data"/> at the current cursor. The buffer
    /// grows as needed; the cursor advances by the number of bytes
    /// written.
    /// </summary>
    /// <param name="data">
    /// Bytes to append. Must not be null. An empty array is a no-op.
    /// </param>
    /// <returns>Number of bytes actually written.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="data"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public long WriteBytes(byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        EnsureNotDisposed();

        if (data.Length == 0)
        {
            return 0;
        }
        return NativeMethods.LF_WriteBuffer(CurrentHnd, data, data.Length);
    }

    /// <summary>
    /// Reads up to <paramref name="count"/> bytes into a new array. The
    /// cursor advances by the number of bytes actually read.
    /// </summary>
    /// <param name="count">
    /// Maximum number of bytes to read. Must be non-negative.
    /// </param>
    /// <returns>
    /// The bytes actually read. The array is empty at end-of-buffer and
    /// may be shorter than <paramref name="count"/> when fewer bytes are
    /// available. The result is never null.
    /// </returns>
    /// <exception cref="ArgumentOutOfRangeException">
    /// Thrown when <paramref name="count"/> is negative.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public byte[] ReadBytes(int count)
    {
        if (count < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(count), count, "Count must be non-negative.");
        }
        EnsureNotDisposed();

        if (count == 0)
        {
            return Array.Empty<byte>();
        }

        byte[] buffer = new byte[count];
        long read = NativeMethods.LF_ReadBuffer(CurrentHnd, buffer, count);
        if (read == count)
        {
            return buffer;
        }
        if (read <= 0)
        {
            return Array.Empty<byte>();
        }
        Array.Resize(ref buffer, (int)read);
        return buffer;
    }

    // ====================================================================
    // Byte I/O — exact-read family
    // ====================================================================
    //
    // The exact-read family requires exactly the requested number of
    // bytes. A short read raises LingoFuseIoException, and a Try* variant
    // is provided for callers that prefer a boolean result.

    /// <summary>
    /// Reads exactly <paramref name="count"/> bytes. Throws when the
    /// buffer does not contain enough data. The cursor advances by
    /// exactly <paramref name="count"/> bytes on success and is left
    /// unchanged on failure.
    /// </summary>
    /// <param name="count">Number of bytes to read. Must be non-negative.</param>
    /// <returns>The bytes read. Never null; length equals <paramref name="count"/>.</returns>
    /// <exception cref="ArgumentOutOfRangeException">
    /// Thrown when <paramref name="count"/> is negative.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than <paramref name="count"/> bytes are
    /// available. The exception's <c>Operation</c> property is set to
    /// "ReadBytesExact".
    /// </exception>
    public byte[] ReadBytesExact(int count)
    {
        if (count < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(count), count, "Count must be non-negative.");
        }
        EnsureNotDisposed();

        if (count == 0)
        {
            return Array.Empty<byte>();
        }

        long savedPos = Position;
        byte[] buffer = ReadBytes(count);
        if (buffer.Length != count)
        {
            // Restore the cursor so that a failed exact read does not
            // consume partial data.
            Position = savedPos;

            throw new LingoFuseIoException(
                $"ReadBytesExact requested {count} bytes but only " +
                $"{buffer.Length} were available.",
                operation: "ReadBytesExact");
        }
        return buffer;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadBytesExact(int)"/>.
    /// The cursor advances by <paramref name="count"/> bytes on success
    /// and is left unchanged on failure.
    /// </summary>
    /// <param name="count">Number of bytes to read. Must be non-negative.</param>
    /// <param name="value">
    /// On success, receives the bytes read. On failure, receives null.
    /// </param>
    /// <returns>true on success, false on a short read.</returns>
    /// <exception cref="ArgumentOutOfRangeException">
    /// Thrown when <paramref name="count"/> is negative.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool TryReadBytes(int count, out byte[]? value)
    {
        if (count < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(count), count, "Count must be non-negative.");
        }
        EnsureNotDisposed();

        value = null;
        if (count == 0)
        {
            value = Array.Empty<byte>();
            return true;
        }

        long savedPos = Position;
        byte[] buffer = ReadBytes(count);
        if (buffer.Length != count)
        {
            Position = savedPos;
            return false;
        }
        value = buffer;
        return true;
    }

    /// <summary>
    /// Reads every remaining byte from the current cursor to the end of
    /// the buffer and advances the cursor to the end. Returns an empty
    /// array when the cursor is already at the end.
    /// </summary>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public byte[] ReadAllBytes()
    {
        EnsureNotDisposed();
        long pos = Position;
        long size = Size;
        if (pos >= size)
        {
            return Array.Empty<byte>();
        }
        return ReadBytes((int)(size - pos));
    }

    // ====================================================================
    // Atomic write helpers (little-endian)
    // ====================================================================

    /// <summary>Writes an 8-bit signed integer. The cursor advances by 1 byte.</summary>
    public void WriteInt8(sbyte value) =>
        WriteBytes(unchecked(new[] { (byte)value }));

    /// <summary>Writes an 8-bit unsigned integer. The cursor advances by 1 byte.</summary>
    public void WriteUInt8(byte value) => WriteBytes(new[] { value });

    /// <summary>Writes a 16-bit signed integer. The cursor advances by 2 bytes.</summary>
    public void WriteInt16(short value)
    {
        var bytes = new byte[2];
        BinaryPrimitives.WriteInt16LittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    /// <summary>Writes a 16-bit unsigned integer. The cursor advances by 2 bytes.</summary>
    public void WriteUInt16(ushort value)
    {
        var bytes = new byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    /// <summary>Writes a 32-bit signed integer. The cursor advances by 4 bytes.</summary>
    public void WriteInt32(int value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    /// <summary>Writes a 32-bit unsigned integer. The cursor advances by 4 bytes.</summary>
    public void WriteUInt32(uint value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    /// <summary>Writes a 64-bit signed integer. The cursor advances by 8 bytes.</summary>
    public void WriteInt64(long value)
    {
        var bytes = new byte[8];
        BinaryPrimitives.WriteInt64LittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    /// <summary>Writes a 64-bit unsigned integer. The cursor advances by 8 bytes.</summary>
    public void WriteUInt64(ulong value)
    {
        var bytes = new byte[8];
        BinaryPrimitives.WriteUInt64LittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    /// <summary>Writes a 32-bit single-precision float. The cursor advances by 4 bytes.</summary>
    public void WriteSingle(float value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteSingleLittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    /// <summary>Writes a 64-bit double-precision float. The cursor advances by 8 bytes.</summary>
    public void WriteDouble(double value)
    {
        var bytes = new byte[8];
        BinaryPrimitives.WriteDoubleLittleEndian(bytes, value);
        WriteBytes(bytes);
    }

    // ====================================================================
    // Atomic read helpers (little-endian) — exact semantics
    // ====================================================================
    //
    // Each reader requires exactly its own size in bytes and raises
    // LingoFuseIoException on a short read. A Try* counterpart is
    // provided below for callers that prefer a boolean result.

    /// <summary>
    /// Reads an 8-bit signed integer. Requires 1 byte.
    /// </summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 1 byte is available.
    /// </exception>
    public sbyte ReadInt8()
    {
        byte[] b = ReadBytesExact(1);
        return unchecked((sbyte)b[0]);
    }

    /// <summary>
    /// Reads an 8-bit unsigned integer. Requires 1 byte.
    /// </summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 1 byte is available.
    /// </exception>
    public byte ReadUInt8() => ReadBytesExact(1)[0];

    /// <summary>Reads a 16-bit signed integer. Requires 2 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 2 bytes are available.
    /// </exception>
    public short ReadInt16() =>
        BinaryPrimitives.ReadInt16LittleEndian(ReadBytesExact(2));

    /// <summary>Reads a 16-bit unsigned integer. Requires 2 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 2 bytes are available.
    /// </exception>
    public ushort ReadUInt16() =>
        BinaryPrimitives.ReadUInt16LittleEndian(ReadBytesExact(2));

    /// <summary>Reads a 32-bit signed integer. Requires 4 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 4 bytes are available.
    /// </exception>
    public int ReadInt32() =>
        BinaryPrimitives.ReadInt32LittleEndian(ReadBytesExact(4));

    /// <summary>Reads a 32-bit unsigned integer. Requires 4 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 4 bytes are available.
    /// </exception>
    public uint ReadUInt32() =>
        BinaryPrimitives.ReadUInt32LittleEndian(ReadBytesExact(4));

    /// <summary>Reads a 64-bit signed integer. Requires 8 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 8 bytes are available.
    /// </exception>
    public long ReadInt64() =>
        BinaryPrimitives.ReadInt64LittleEndian(ReadBytesExact(8));

    /// <summary>Reads a 64-bit unsigned integer. Requires 8 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 8 bytes are available.
    /// </exception>
    public ulong ReadUInt64() =>
        BinaryPrimitives.ReadUInt64LittleEndian(ReadBytesExact(8));

    /// <summary>Reads a 32-bit single-precision float. Requires 4 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 4 bytes are available.
    /// </exception>
    public float ReadSingle() =>
        BinaryPrimitives.ReadSingleLittleEndian(ReadBytesExact(4));

    /// <summary>Reads a 64-bit double-precision float. Requires 8 bytes.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 8 bytes are available.
    /// </exception>
    public double ReadDouble() =>
        BinaryPrimitives.ReadDoubleLittleEndian(ReadBytesExact(8));

    // ====================================================================
    // Atomic read helpers — Try* variants
    // ====================================================================
    //
    // Each Try* reader performs the same check as its throwing counterpart
    // but returns false instead of raising LingoFuseIoException. The
    // cursor is left unchanged when the read fails.

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadInt8"/>.
    /// </summary>
    public bool TryReadInt8(out sbyte value)
    {
        if (TryReadBytes(1, out var bytes))
        {
            value = unchecked((sbyte)bytes![0]);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadUInt8"/>.
    /// </summary>
    public bool TryReadUInt8(out byte value)
    {
        if (TryReadBytes(1, out var bytes))
        {
            value = bytes![0];
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadInt16"/>.
    /// </summary>
    public bool TryReadInt16(out short value)
    {
        if (TryReadBytes(2, out var bytes))
        {
            value = BinaryPrimitives.ReadInt16LittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadUInt16"/>.
    /// </summary>
    public bool TryReadUInt16(out ushort value)
    {
        if (TryReadBytes(2, out var bytes))
        {
            value = BinaryPrimitives.ReadUInt16LittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadInt32"/>.
    /// </summary>
    public bool TryReadInt32(out int value)
    {
        if (TryReadBytes(4, out var bytes))
        {
            value = BinaryPrimitives.ReadInt32LittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadUInt32"/>.
    /// </summary>
    public bool TryReadUInt32(out uint value)
    {
        if (TryReadBytes(4, out var bytes))
        {
            value = BinaryPrimitives.ReadUInt32LittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadInt64"/>.
    /// </summary>
    public bool TryReadInt64(out long value)
    {
        if (TryReadBytes(8, out var bytes))
        {
            value = BinaryPrimitives.ReadInt64LittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadUInt64"/>.
    /// </summary>
    public bool TryReadUInt64(out ulong value)
    {
        if (TryReadBytes(8, out var bytes))
        {
            value = BinaryPrimitives.ReadUInt64LittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadSingle"/>.
    /// </summary>
    public bool TryReadSingle(out float value)
    {
        if (TryReadBytes(4, out var bytes))
        {
            value = BinaryPrimitives.ReadSingleLittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadDouble"/>.
    /// </summary>
    public bool TryReadDouble(out double value)
    {
        if (TryReadBytes(8, out var bytes))
        {
            value = BinaryPrimitives.ReadDoubleLittleEndian(bytes);
            return true;
        }
        value = default;
        return false;
    }

    // ====================================================================
    // NUL-framed string I/O
    // ====================================================================

    /// <summary>
    /// Writes <paramref name="value"/> as UTF-8, followed by a single
    /// NUL byte. An empty string writes exactly one byte (the NUL).
    /// </summary>
    /// <param name="value">UTF-8 string. Must not be null.</param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="value"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public void WriteString(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        EnsureNotDisposed();

        byte[] payload = Utf8.GetBytes(value);
        if (payload.Length > 0)
        {
            WriteBytes(payload);
        }
        WriteBytes(new byte[1]);
    }

    /// <summary>
    /// Reads a UTF-8 string from the current cursor, stopping at the
    /// first NUL byte. When no NUL is found before the end of the
    /// buffer, all remaining bytes are consumed and returned. Returns
    /// an empty string when the cursor is already at the end, or when
    /// the first byte is the terminator.
    /// </summary>
    /// <remarks>
    /// Invalid UTF-8 byte sequences are decoded with the encoder's
    /// default fallback (each invalid byte becomes U+FFFD). This
    /// matches the behaviour of the Pascal binding's
    /// <c>TEncoding.utf8.GetString</c> and keeps the reader binary-safe.
    ///
    /// Callers that need to detect invalid UTF-8 must read the raw
    /// bytes via <see cref="ReadBytesExact(int)"/> or
    /// <see cref="ReadAllBytes"/> and inspect them directly.
    /// </remarks>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public string ReadString()
    {
        EnsureNotDisposed();

        IntPtr buffer = GetBufferPointer();
        long start = Position;
        long end = Size;

        if (buffer == IntPtr.Zero || start >= end)
        {
            return string.Empty;
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
        string result = string.Empty;

        if (length > 0)
        {
            byte[] bytes = new byte[length];
            Marshal.Copy(buffer + (int)start, bytes, 0, length);
            result = Utf8.GetString(bytes);
        }

        // Advance past the NUL when found; otherwise to one byte past
        // the end, matching the native fault-tolerant read behaviour.
        Position = scan < end ? scan + 1 : end + 1;
        return result;
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="ReadString"/>. The only
    /// recoverable failure mode is a disposed handle, which still
    /// throws; the method never throws for a malformed UTF-8 payload.
    /// </summary>
    /// <param name="value">
    /// On success, receives the decoded string. On failure, receives null.
    /// </param>
    /// <returns>
    /// true when the read produced a string (possibly empty), false when
    /// the handle was at end-of-buffer and nothing could be read.
    /// </returns>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool TryReadString(out string? value)
    {
        EnsureNotDisposed();

        long start = Position;
        long end = Size;
        if (start >= end)
        {
            value = null;
            return false;
        }

        value = ReadString();
        return true;
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    private DataHnd CurrentHnd => new DataHnd { Handle = _handle };

    private void EnsureNotDisposed()
    {
        if (_disposed || _handle == IntPtr.Zero)
        {
            throw new LingoFuseObjectDisposedException(nameof(DataHandle));
        }
    }
}