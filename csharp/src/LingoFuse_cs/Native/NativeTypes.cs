using System;
using System.Runtime.InteropServices;

namespace LingoFuse.Native;

// ============================================================================
// NativeTypes — opaque handles and callback prototypes for the C ABI.
// ============================================================================
//
// This file declares the managed representation of:
//
//   - the two opaque handle kinds exposed by the native library;
//   - the three callback delegate prototypes the C ABI expects.
//
// All five types are declared internal. User code never sees them:
// DataHandle and AppHandle wrap the raw pointer, and the callbacks are
// registered through the managed signatures on AppHandle and
// NetworkEvents. Exposing these types publicly would invite user code
// to hand-roll P/Invoke calls, which is exactly what the layer-1
// boundary exists to prevent.
//
// HANDLE TYPES
// ------------
// Both DataHnd and AppHnd wrap a single IntPtr. The wrapper exists for
// type safety and null semantics. The wrapped pointer must NEVER be
// dereferenced directly; all access goes through the exported functions
// in NativeMethods.
//
// CALLBACK TYPES
// --------------
// All three delegates are declared with CallingConvention.Cdecl. The
// managed default conventions (fastcall on x64, stdcall on x86) would
// misalign the stack on Windows and crash the process.
//
// All three delegates execute on a native worker thread. Their bodies
// must never call any blocking LingoFuse function (LF_Call,
// LF_LocalCall, LF_PrepareDone, LF_Shutdown); doing so deadlocks.
//
// ============================================================================

/// <summary>
/// Opaque handle to a LingoFuse data buffer (TDataHnd).
/// </summary>
/// <remarks>
/// Created by LF_CreateData / LF_CreateData_Permanent and released by
/// LF_FreeData. The wrapped pointer must never be dereferenced
/// directly.
/// </remarks>
[StructLayout(LayoutKind.Sequential)]
internal struct DataHnd : IEquatable<DataHnd>
{
    /// <summary>
    /// Raw pointer. <see cref="IntPtr.Zero"/> means "no handle".
    /// </summary>
    public IntPtr Handle;

    /// <summary>
    /// True when the wrapped pointer is not <see cref="IntPtr.Zero"/>.
    /// </summary>
    public readonly bool IsValid => Handle != IntPtr.Zero;

    /// <summary>
    /// An empty handle. Safe to pass to LF_FreeData; the native layer
    /// ignores it.
    /// </summary>
    public static readonly DataHnd Null = new DataHnd { Handle = IntPtr.Zero };

    /// <inheritdoc/>
    public readonly bool Equals(DataHnd other) => Handle == other.Handle;

    /// <inheritdoc/>
    public readonly override bool Equals(object? obj) =>
        obj is DataHnd other && Equals(other);

    /// <inheritdoc/>
    public readonly override int GetHashCode() => Handle.GetHashCode();

    /// <summary>Equality operator.</summary>
    public static bool operator ==(DataHnd left, DataHnd right) =>
        left.Equals(right);

    /// <summary>Inequality operator.</summary>
    public static bool operator !=(DataHnd left, DataHnd right) =>
        !left.Equals(right);
}

/// <summary>
/// Opaque handle to a LingoFuse application (TAppHnd).
/// </summary>
/// <remarks>
/// Created by LF_CreateApp and released by LF_FreeApp. LF_FreeApp
/// performs only the first stage of a two-stage destruction: the
/// underlying object remains alive in the global pool until
/// LF_Shutdown is called.
/// </remarks>
[StructLayout(LayoutKind.Sequential)]
internal struct AppHnd : IEquatable<AppHnd>
{
    /// <summary>
    /// Raw pointer. <see cref="IntPtr.Zero"/> means "no handle".
    /// </summary>
    public IntPtr Handle;

    /// <summary>
    /// True when the wrapped pointer is not <see cref="IntPtr.Zero"/>.
    /// </summary>
    public readonly bool IsValid => Handle != IntPtr.Zero;

    /// <summary>
    /// An empty handle. Safe to pass to LF_FreeApp. Also the expected
    /// argument for LF_PrepareClient when the client is a pure consumer
    /// that does not expose an application.
    /// </summary>
    public static readonly AppHnd Null = new AppHnd { Handle = IntPtr.Zero };

    /// <inheritdoc/>
    public readonly bool Equals(AppHnd other) => Handle == other.Handle;

    /// <inheritdoc/>
    public readonly override bool Equals(object? obj) =>
        obj is AppHnd other && Equals(other);

    /// <inheritdoc/>
    public readonly override int GetHashCode() => Handle.GetHashCode();

    /// <summary>Equality operator.</summary>
    public static bool operator ==(AppHnd left, AppHnd right) =>
        left.Equals(right);

    /// <summary>Inequality operator.</summary>
    public static bool operator !=(AppHnd left, AppHnd right) =>
        !left.Equals(right);
}

/// <summary>
/// Callback prototype for Call-mode (request-response) APIs.
/// </summary>
/// <param name="trigger">
/// User-supplied pointer passed at registration time.
/// </param>
/// <param name="input">
/// Read-only input data handle. Valid only during the callback
/// invocation; the native layer releases it as soon as the callback
/// returns.
/// </param>
/// <param name="output">
/// Writable output data handle. Valid only during the callback
/// invocation; the native layer releases it as soon as the callback
/// returns.
/// </param>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void LfCallFunc(IntPtr trigger, IntPtr input, IntPtr output);

/// <summary>
/// Callback prototype for Notify-mode (one-way) APIs.
/// </summary>
/// <param name="trigger">
/// User-supplied pointer passed at registration time.
/// </param>
/// <param name="input">
/// Read-only input data handle. Valid only during the callback
/// invocation; the native layer releases it as soon as the callback
/// returns.
/// </param>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void LfNotifyFunc(IntPtr trigger, IntPtr input);

/// <summary>
/// Callback prototype for network connect / disconnect events.
/// </summary>
/// <param name="addr">
/// UTF-8 encoded endpoint string. The buffer is valid ONLY during the
/// callback invocation. The wrapper in LingoFuse.NetworkEvents copies
/// it to managed memory immediately.
/// </param>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void LfNetworkEventFunc(IntPtr addr);