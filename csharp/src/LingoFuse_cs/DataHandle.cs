using System;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text;

using LingoFuse.Native;

namespace LingoFuse;

// ============================================================================
// DataHandle — RAII wrapper around a native TDataHnd.
// ============================================================================
//
// RESPONSIBILITY
// --------------
// Owns a native data handle and releases it deterministically on
// Dispose. Provides byte-level, atomic-type, and NUL-framed string I/O
// on top of the underlying buffer.
//
// This is the LOW-LEVEL primitive layer. JSON serialization and
// NUL-framed byte sequences are provided by the higher-level LfIo
// class, which is built on top of DataHandle.
//
// TWO KINDS OF HANDLES
// --------------------
// The native library provides two flavours of data handle:
//
//   Auto-recycled  (created by the public constructor)
//       - Backed by LF_CreateData.
//       - Added to the library's idle pool.
//       - The pool scans every 5 seconds and frees any handle idle
//         (no accessor call) for more than 10 minutes.
//       - LF_FreeData only marks the handle as deleted; the actual
//         release happens on the next pool scan (at most 5 seconds
//         later).
//       - Recommended for the vast majority of use cases.
//
//   Permanent      (created by the CreatePermanent factory)
//       - Backed by LF_CreateData_Permanent.
//       - NOT added to the library's idle pool.
//       - The automatic idle-timeout reclaimer will NEVER free it,
//         no matter how long it has been idle.
//       - LF_FreeData releases it IMMEDIATELY (synchronously).
//       - Recommended for handles that must survive for the entire
//         process lifetime (cached request templates, long-lived
//         scratch buffers, global registries, etc.).
//
//   Both kinds are released by Framework.Shutdown when the process
//   terminates, and both kinds must be explicitly disposed to avoid
//   leaks.
//
// OWNERSHIP
// ---------
// A DataHandle is either "owning" or "borrowing":
//
//   Owning    — created by the public constructor or by
//               CreatePermanent. Dispose calls LF_FreeData on the
//               native handle.
//   Borrowing — created by FromRaw(raw, owned: false). Dispose is a
//               no-op; the native layer owns the underlying resource
//               and releases it when the callback returns.
//
// Borrowing is used for the input/output handles passed into a
// callback. Freeing them from managed code would be a double-free.
//
// BORROWED HANDLE DISPOSE IS A NO-OP
// ----------------------------------
// For a borrowed handle, Dispose deliberately does NOT change the
// wrapper state. A callback body that accidentally calls Dispose on
// its input or output handle must not corrupt the wrapper state for
// the rest of the callback body. The wrapper's _disposed flag stays
// false, so IsValid, Raw, and all read methods remain usable until
// the callback returns.
//
// STRING CONTRACT
// ---------------
// LingoFuse frames strings with a single trailing NUL (0x00) byte on
// the wire. WriteString always appends the terminator. ReadString is
// fault-tolerant: it reads until the first NUL, or all remaining bytes
// if no NUL is present. This matches the behaviour of every other
// LingoFuse binding and keeps interop with non-Pascal producers
// (HTTP bridges, browsers) working.
//
// Invalid UTF-8 byte sequences encountered during a read are decoded
// with the encoder's default fallback: each invalid byte becomes
// U+FFFD. This keeps the reader binary-safe. Callers that need to
// detect invalid UTF-8 must read the raw bytes via ReadBytesExact /
// ReadAllBytes and inspect them directly.
//
// I/O FAILURE SEMANTICS
// ---------------------
// Two symmetric families of read operations are offered so that
// callers can choose their failure semantics explicitly:
//
//   Partial   ReadBytes(n)
//             Returns up to n bytes. Never throws for a short read.
//
//   Exact     ReadBytesExact(n)  /  ReadInt8() .. ReadDouble()
//             Requires exactly n bytes. Throws LingoFuseIoException
//             on a short read.
//
// The atomic-type readers are Exact by default, because a partially
// read integer is never useful. Each Exact reader has a Try*
// counterpart that returns false instead of throwing.
//
// WRITE FAILURE SEMANTICS
// -----------------------
// WriteBytes requires the native layer to accept every byte. A short
// write means the handle is corrupt or the process is out of memory;
// there is no useful recovery path, and silently continuing would
// produce a truncated payload on the wire. WriteBytes therefore
// throws LingoFuseIoException on a short write, symmetrically with
// ReadBytesExact.
//
// THREAD SAFETY
// -------------
// The native library is thread-safe, but a single data handle cannot
// be written concurrently. Read access is safe while another thread
// reads. Callers that share a handle across threads must serialise
// writes themselves.
//
// The _handle field is declared volatile so that a Dispose on one
// thread is observed by an EnsureNotDisposed on another thread without
// requiring an external lock. This is sufficient for the "do not use
// after dispose" contract; it does not make concurrent writes safe.
//
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
    /// U+FFFD by the encoder's default fallback.
    /// </summary>
    private static readonly Encoding Utf8 =
        new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    /// <summary>
    /// The trailing NUL byte written by WriteString and by LfIo's
    /// byte-oriented writers. Held as a static field to avoid a heap
    /// allocation per empty-string write.
    /// </summary>
    private static readonly byte[] NullByte = new byte[1];

    /// <summary>
    /// The native handle. Declared volatile so that a Dispose on one
    /// thread becomes visible to a concurrent EnsureNotDisposed on
    /// another thread without an external lock.
    /// </summary>
    private volatile IntPtr _handle;

    /// <summary>
    /// True when Dispose will call LF_FreeData. A borrowed handle has
    /// this set to false and Dispose is a no-op.
    /// </summary>
    private readonly bool _owned;

    /// <summary>
    /// True after an owning handle has been disposed. Not volatile:
    /// the disposed flag is only ever transitioned from false to true
    /// under the protective visibility of the volatile _handle read,
    /// which is always checked first by EnsureNotDisposed.
    /// </summary>
    private bool _disposed;

    // --------------------------------------------------------------------
    // Construction
    // --------------------------------------------------------------------

    /// <summary>
    /// Creates a new AUTO-RECYCLED data handle bound to the given API
    /// name. The underlying buffer starts empty.
    /// </summary>
    /// <param name="apiName">
    /// UTF-8 API name. Must not be null. An empty string is allowed but
    /// unusual; the native side stores the name as the "MethodName"
    /// component of the wire format.
    /// </param>
    /// <remarks>
    /// The handle is added to the library's idle pool. The pool scans
    /// every 5 seconds and frees any handle that has been idle for
    /// more than 10 minutes. Any accessor call (Position, Size,
    /// GetBufferPointer, ReadBytes, WriteBytes, ReadString,
    /// WriteString, ...) refreshes the idle timestamp.
    ///
    /// Use <see cref="CreatePermanent"/> when the handle must survive
    /// for the entire process lifetime.
    /// </remarks>
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
    /// Creates a new PERMANENT data handle bound to the given API name.
    /// The underlying buffer starts empty.
    /// </summary>
    /// <param name="apiName">
    /// UTF-8 API name. Must not be null.
    /// </param>
    /// <remarks>
    /// Difference from <see cref="DataHandle(string)"/>:
    /// <list type="bullet">
    ///   <item>NOT added to the library's idle pool.</item>
    ///   <item>The automatic idle-timeout reclaimer will NEVER free it,
    ///         no matter how long it has been idle.</item>
    ///   <item><see cref="Dispose"/> releases it IMMEDIATELY
    ///         (synchronously), rather than marking it for a later pool
    ///         scan.</item>
    /// </list>
    ///
    /// When to use:
    /// <list type="bullet">
    ///   <item>Handles that must survive for the entire lifetime of the
    ///         process, or for an unbounded period (cached request
    ///         templates, long-lived scratch buffers, global registries,
    ///         etc.).</item>
    /// </list>
    ///
    /// When NOT to use:
    /// <list type="bullet">
    ///   <item>Short-lived or one-shot handles. Use the regular
    ///         constructor for those, so the pool can reclaim any handle
    ///         you forget to dispose.</item>
    /// </list>
    ///
    /// [PITFALL - NO-OP WINDOW]
    ///   The underlying LF_FreeData is a no-op while the simulated main
    ///   thread is not active (before Framework.PrepareDone or after
    ///   Framework.ExitMainThread). Permanent handles created in that
    ///   window stay allocated until the process terminates, or until
    ///   Framework.Shutdown runs.
    ///
    /// [PITFALL - LIFETIME]
    ///   "Permanent" means "not automatically reclaimed", NOT "never
    ///   released". You are fully responsible for disposing it. Losing
    ///   the reference leaks the handle for the lifetime of the
    ///   process.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the native library fails to allocate the handle.
    /// </exception>
    public static DataHandle CreatePermanent(string apiName)
    {
        ArgumentNullException.ThrowIfNull(apiName);

        IntPtr namePtr = Utf8Marshal.Alloc(apiName);
        try
        {
            DataHnd raw = NativeMethods.LF_CreateData_Permanent(namePtr);
            if (!raw.IsValid)
            {
                throw new LingoFuseException(
                    $"Failed to create a permanent data handle for API " +
                    $"'{apiName}'.");
            }
            return new DataHandle(raw.Handle, owned: true);
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
    /// When <c>true</c>, <see cref="Dispose"/> will call LF_FreeData.
    /// When <c>false</c>, <see cref="Dispose"/> is a no-op and the
    /// native layer retains ownership.
    /// </param>
    public static DataHandle FromRaw(IntPtr raw, bool owned)
        => new DataHandle(raw, owned);

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
    /// <see cref="Dispose"/> will call LF_FreeData).
    /// </summary>
    public bool IsOwning => _owned;

    // --------------------------------------------------------------------
    // Lifetime
    // --------------------------------------------------------------------

    /// <summary>
    /// Releases the native handle when ownership applies.
    /// </summary>
    /// <remarks>
    /// For an OWNING AUTO-RECYCLED handle (created by the public
    /// constructor): calls LF_FreeData, which only marks the handle as
    /// deleted. The actual release happens on the next idle-pool scan
    /// (at most 5 seconds later). The wrapper's state transitions to
    /// disposed and subsequent operations throw
    /// <see cref="LingoFuseObjectDisposedException"/>. Idempotent.
    ///
    /// For an OWNING PERMANENT handle (created by
    /// <see cref="CreatePermanent"/>): calls LF_FreeData, which
    /// releases the handle IMMEDIATELY (synchronously). The wrapper's
    /// state transitions to disposed, and subsequent operations throw
    /// <see cref="LingoFuseObjectDisposedException"/>. Idempotent.
    ///
    /// For a BORROWED handle: this method is a NO-OP. The native layer
    /// owns the underlying resource and releases it when the callback
    /// returns. The wrapper's state is unchanged so that a callback
    /// body that accidentally calls Dispose can still read from the
    /// input handle for the rest of its execution.
    /// </remarks>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (!_owned)
        {
            // Borrowed handle: the native layer owns the resource.
            // Dispose is deliberately a no-op.
            return;
        }

        _disposed = true;

        // Snapshot the handle into a local, then clear the field.
        // Publishing IntPtr.Zero through the volatile field makes the
        // disposal visible to a concurrent EnsureNotDisposed on
        // another thread.
        IntPtr handle = _handle;
        _handle = IntPtr.Zero;

        if (handle != IntPtr.Zero)
        {
            var hnd = new DataHnd { Handle = handle };
            NativeMethods.LF_FreeData(hnd);
        }
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
    /// Setting a size larger than the current one grows the buffer; the
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

    /// <summary>
    /// Appends <paramref name="data"/> at the current cursor. The
    /// buffer grows as needed; the cursor advances by the number of
    /// bytes written.
    /// </summary>
    /// <param name="data">
    /// Bytes to append. Must not be null. An empty array is a no-op.
    /// </param>
    /// <returns>
    /// Number of bytes actually written (equal to <c>data.Length</c>).
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="data"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when the native layer writes fewer bytes than requested.
    /// A short write means the handle is corrupt or the process is out
    /// of memory; there is no useful recovery path, and silently
    /// continuing would produce a truncated payload on the wire.
    /// </exception>
    public long WriteBytes(byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        EnsureNotDisposed();

        if (data.Length == 0)
        {
            return 0;
        }

        long written = NativeMethods.LF_WriteBuffer(
            CurrentHnd, data, data.Length);
        if (written != data.Length)
        {
            throw new LingoFuseIoException(
                $"WriteBytes requested {data.Length} bytes but only " +
                $"{written} were written.",
                operation: "WriteBytes");
        }
        return written;
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

    /// <summary>
    /// Reads exactly <paramref name="count"/> bytes. Throws on a short
    /// read. The cursor advances by exactly <paramref name="count"/>
    /// bytes on success and is left unchanged on failure.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">
    /// Thrown when <paramref name="count"/> is negative.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than <paramref name="count"/> bytes are
    /// available.
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
    /// the buffer and advances the cursor to the end.
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

    /// <summary>Reads an 8-bit signed integer. Requires 1 byte.</summary>
    /// <exception cref="LingoFuseIoException">
    /// Thrown when fewer than 1 byte is available.
    /// </exception>
    public sbyte ReadInt8()
    {
        byte[] b = ReadBytesExact(1);
        return unchecked((sbyte)b[0]);
    }

    /// <summary>Reads an 8-bit unsigned integer. Requires 1 byte.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadInt8"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadUInt8"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadInt16"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadUInt16"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadInt32"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadUInt32"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadInt64"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadUInt64"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadSingle"/>.</summary>
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

    /// <summary>Non-throwing counterpart of <see cref="ReadDouble"/>.</summary>
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
    /// <exception cref="LingoFuseIoException">
    /// Thrown when the native layer writes fewer bytes than requested.
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
        WriteBytes(NullByte);
    }

    /// <summary>
    /// Reads a UTF-8 string from the current cursor, stopping at the
    /// first NUL byte. When no NUL is found before the end of the
    /// buffer, all remaining bytes are consumed and returned.
    /// </summary>
    /// <remarks>
    /// Invalid UTF-8 byte sequences are decoded with the encoder's
    /// default fallback (each invalid byte becomes U+FFFD). Callers
    /// that need to detect invalid UTF-8 must read the raw bytes via
    /// <see cref="ReadBytesExact(int)"/> or
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
    /// recoverable failure mode is an exhausted buffer; a disposed
    /// handle still throws.
    /// </summary>
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
        // The volatile read of _handle makes a concurrent Dispose
        // visible to this thread. The _disposed flag is checked after
        // the handle so that a borrowed-handle instance, whose
        // _disposed is never set, is not falsely reported as disposed.
        if (_handle == IntPtr.Zero || _disposed)
        {
            throw new LingoFuseObjectDisposedException(nameof(DataHandle));
        }
    }
}