// ============================================================================
// File: csharp/src/LingoFuse_cs/Native/NativeTypes.cs
// ============================================================================
// NativeTypes — opaque handles, the blittable UID struct, and callback
// prototypes for the C ABI.
// ============================================================================
// This file declares the managed representation of:
//
//   - the two opaque handle kinds exposed by the native library;
//   - the 32-byte UID struct (blittable, ABI-compatible with Pascal
//     TP2P_UID___ = array[0..31] of Byte);
//   - the four callback delegate prototypes the C ABI expects.
//
// All types are declared internal. User code never sees them:
// DataHandle / AppHandle wrap the raw pointer, P2PUid wraps the 32-byte
// UID, and callbacks are registered through the managed signatures on
// AppHandle / Framework / NetworkEvents. Exposing these types publicly
// would invite user code to hand-roll P/Invoke calls, which is exactly
// what the layer-0 boundary exists to prevent.
//
// HANDLE TYPES
// ------------
// Both DataHnd and AppHnd wrap a single IntPtr. The wrapper exists for
// type safety and null semantics. The wrapped pointer must NEVER be
// dereferenced directly; all access goes through the exported functions
// in NativeMethods.
//
// UID TYPE — TUIDNative
// ---------------------
// The Pascal-side type TP2P_UID___ is array[0..31] of Byte. The C ABI
// declares it as a 32-byte aggregate that is passed BY VALUE for
// argument positions (LF_UID_Call, LF_Check_UID, LF_WriteUid,
// LF_ReadUid) and BY POINTER for the single return position
// (LF_Get_P2P_UID returns a pointer).
//
// TUIDNative is the managed representation of the ARGUMENT-role UID.
// It is deliberately a 32-byte blittable struct expressed as four
// ulong fields:
//
//   * 4 x ulong = 32 bytes, matching the Pascal array byte-for-byte.
//   * Blittable: no marshalling stub is generated, no copy is made,
//     and the struct is passed on the stack exactly as the C ABI
//     expects for a >16-byte aggregate on x86-64.
//   * No `unsafe` / `fixed` keyword is required, so the binding can
//     remain under AllowUnsafeBlocks = false.
//
// The public P2PUid type (in P2PUid.cs) is a higher-level wrapper
// around TUIDNative with value semantics, hex formatting, and equality.
//
// CALLBACK TYPES
// --------------
// All four delegates are declared with CallingConvention.Cdecl. The
// managed default conventions (fastcall on x64, stdcall on x86) would
// misalign the stack on Windows and crash the process.
//
// All four delegates execute on a native worker thread. Their bodies
// must never call any blocking LingoFuse function (LF_Call,
// LF_LocalCall, LF_PrepareDone, LF_Shutdown); doing so deadlocks.
//
// ============================================================================

using System;
using System.Runtime.InteropServices;

namespace LingoFuse.Native;

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
/// ARGUMENT-role 32-byte UID, ABI-compatible with the Pascal-side
/// <c>array[0..31] of Byte</c>.
/// </summary>
/// <remarks>
/// <para>
/// This is the LOW-LEVEL representation used internally by
/// <see cref="NativeMethods"/>. User code never sees it; the public
/// surface uses <c>P2PUid</c>, which wraps and reinterprets the same
/// 32 bytes with value semantics, equality, and hex formatting.
/// </para>
/// <para>
/// <b>Role distinction:</b> TUIDNative is the ARGUMENT-role
/// representation. The single RETURN-role position
/// (<c>LF_Get_P2P_UID</c>) is expressed as an <c>IntPtr</c> pointing
/// to a library-owned 32-byte buffer. Do NOT conflate the two.
/// </para>
/// <para>
/// <b>Layout:</b> four ulong fields = 32 bytes, with default packing.
/// On x86-64 System V AMD64 and Microsoft x64, a >16-byte aggregate is
/// passed on the stack; the same applies to the Pascal side. The two
/// are byte-compatible.
/// </para>
/// </remarks>
[StructLayout(LayoutKind.Sequential)]
internal struct TUIDNative
{
    /// <summary>Bytes 0..7, little-endian.</summary>
    public ulong Lo;

    /// <summary>Bytes 8..15, little-endian.</summary>
    public ulong Hi;

    /// <summary>Bytes 16..23, little-endian.</summary>
    public ulong Top;

    /// <summary>Bytes 24..31, little-endian.</summary>
    public ulong Last;

    /// <summary>A zero-filled UID.</summary>
    public static readonly TUIDNative Empty = default;

    /// <summary>
    /// True when all 32 bytes are zero.
    /// </summary>
    public readonly bool IsEmpty =>
        Lo == 0UL && Hi == 0UL && Top == 0UL && Last == 0UL;
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

/// <summary>
/// Callback prototype for asynchronous remote-call completion.
/// </summary>
/// <param name="data">
/// Opaque pointer the caller supplied at the call site. LingoFuse
/// neither owns nor frees it. The managed bridge uses this to route
/// the completion back to the originating Task.
/// </param>
/// <param name="result">
/// A data handle OWNED BY THE FRAMEWORK. It is released IMMEDIATELY
/// after this callback returns. The managed bridge MUST copy whatever
/// it needs out of the handle inside the callback body, MUST NOT call
/// LF_FreeData on it, and MUST NOT retain the raw pointer past the
/// callback body.
/// </param>
/// <remarks>
/// <para>
/// This delegate is invoked by the C ABI for every completion of
/// <c>LF_Async_Call</c>, <c>LF_Async_Sequenced_Call</c>, and the UID /
/// P2PName variants.
/// </para>
/// <para>
/// <b>Dispatch failure:</b> if the C ABI call returns 0 (request was
/// rejected before being queued), the framework NEVER invokes this
/// callback. The managed bridge is responsible for detecting that
/// synchronous return value and completing the Task with an error.
/// </para>
/// </remarks>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void LfAsyncCallOnResult(IntPtr data, IntPtr result);