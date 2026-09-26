using System;
using System.Runtime.InteropServices;
using System.Text;

namespace LingoFuse.Native;

// ============================================================================
// Utf8Marshal ¡ª marshalling helpers for UTF-8, NUL-terminated strings.
// ============================================================================
//
// Every string parameter of every LingoFuse export is a
// <c>const char*</c> pointing to UTF-8 bytes terminated by a single
// <c>0x00</c>. This class centralises the conversion so that the wire
// contract lives in exactly one place.
//
// ----------------------------------------------------------------------------
// ENCODING CONTRACT
// ----------------------------------------------------------------------------
// UTF-8 is the ONLY text encoding the LingoFuse mesh accepts or produces.
// This class does not perform any transcoding between UTF-8 and the
// platform default code page. Callers must supply valid UTF-8 strings;
// .NET strings are UTF-16 internally, and the standard
// <see cref="Encoding.UTF8"/> encoder converts them to UTF-8 bytes on
// the way out.
//
// Invalid .NET strings (for example, a string containing an unpaired
// surrogate) are handled by the encoder's default fallback policy, which
// replaces each invalid code unit with U+FFFD. This keeps the writer
// from throwing and matches the behaviour of the Python and C++
// producers when they encounter an invalid input.
//
// ----------------------------------------------------------------------------
// LIFETIME RULES
// ----------------------------------------------------------------------------
//   * Alloc returns unmanaged memory. The caller MUST release it with
//     Free. Failing to do so leaks memory.
//   * PtrToString copies the bytes to managed memory immediately. The
//     caller may free the source pointer (or let the native layer do
//     so) as soon as PtrToString returns.
//   * Free is safe to call with IntPtr.Zero; it is a no-op.
//
// ----------------------------------------------------------------------------
// NUL-TERMINATOR ASSUMPTION
// ----------------------------------------------------------------------------
// PtrToString scans for the NUL terminator byte. The LingoFuse contract
// guarantees that every string parameter and every string returned by
// the library is properly terminated, so the scan always finds a
// terminator before walking off the end. Passing a non-terminated
// pointer is undefined behaviour.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
// This class contains no logic that throws. Alloc(null) returns
// IntPtr.Zero by design (see the method's XML doc), and Free(IntPtr.Zero)
// is a no-op. PtrToString(IntPtr.Zero) returns string.Empty.
// ============================================================================

/// <summary>
/// Marshalling helpers for UTF-8, NUL-terminated strings.
/// </summary>
/// <remarks>
/// This class is an implementation detail of the binding. User code
/// never calls it directly; the managed wrappers in LingoFuse.Core,
/// LingoFuse.Host, LingoFuse.Io and LingoFuse.Events use it on the
/// user's behalf.
/// </remarks>
internal static class Utf8Marshal
{
    /// <summary>
    /// Allocate unmanaged memory holding a NUL-terminated UTF-8 copy of
    /// <paramref name="value"/>.
    /// </summary>
    /// <param name="value">
    /// Managed string. A <c>null</c> argument yields
    /// <see cref="IntPtr.Zero"/>; an empty string yields a one-byte
    /// buffer holding only the terminator.
    /// </param>
    /// <returns>
    /// Pointer to the allocated buffer. The caller must release it with
    /// <see cref="Free"/>.
    /// </returns>
    internal static IntPtr Alloc(string? value)
    {
        if (value is null)
        {
            return IntPtr.Zero;
        }

        byte[] bytes = Encoding.UTF8.GetBytes(value);
        IntPtr ptr = Marshal.AllocHGlobal(bytes.Length + 1);
        if (bytes.Length > 0)
        {
            Marshal.Copy(bytes, 0, ptr, bytes.Length);
        }
        Marshal.WriteByte(ptr, bytes.Length, 0);
        return ptr;
    }

    /// <summary>
    /// Release a pointer previously produced by <see cref="Alloc"/>.
    /// Safe to call with <see cref="IntPtr.Zero"/>; in that case the
    /// call is a no-op.
    /// </summary>
    /// <param name="ptr">
    /// Pointer to release. May be <see cref="IntPtr.Zero"/>.
    /// </param>
    internal static void Free(IntPtr ptr)
    {
        if (ptr != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(ptr);
        }
    }

    /// <summary>
    /// Copy a NUL-terminated UTF-8 string from unmanaged memory into a
    /// managed <see cref="string"/>.
    /// </summary>
    /// <param name="ptr">
    /// Pointer to the first byte. A <see cref="IntPtr.Zero"/> argument
    /// returns <see cref="string.Empty"/>.
    /// </param>
    /// <returns>
    /// The decoded string. The buffer is copied immediately; the caller
    /// is free to discard <paramref name="ptr"/> afterwards.
    /// </returns>
    /// <remarks>
    /// The scan stops at the first NUL byte. The LingoFuse contract
    /// guarantees that every string the library returns is properly
    /// terminated, so this loop always finds a terminator before walking
    /// off the end.
    /// </remarks>
    internal static string PtrToString(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero)
        {
            return string.Empty;
        }

        // Scan for the NUL terminator. The LingoFuse contract guarantees
        // that every string parameter and every string returned by the
        // library is properly terminated, so this loop always finds a
        // terminator before walking off the end.
        int length = 0;
        while (Marshal.ReadByte(ptr, length) != 0)
        {
            length++;
        }

        if (length == 0)
        {
            return string.Empty;
        }

        byte[] bytes = new byte[length];
        Marshal.Copy(ptr, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }
}