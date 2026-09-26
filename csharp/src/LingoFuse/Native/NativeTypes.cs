using System;
using System.Runtime.InteropServices;

namespace LingoFuse.Native;

// ============================================================================
// Opaque handle types and callback delegates for the LingoFuse C ABI.
// ============================================================================
//
// This file declares the managed representation of the two opaque handle
// kinds exposed by the native library and the three callback delegate
// prototypes that the C ABI expects.
//
// ----------------------------------------------------------------------------
// HANDLE TYPES
// ----------------------------------------------------------------------------
// Both DataHnd and AppHnd wrap a single IntPtr. The wrapper exists for
// three reasons:
//
//   1. Type safety. DataHnd and AppHnd are distinct types, so the
//      compiler rejects a mix-up at a call site.
//
//   2. Null semantics. Each type exposes a static Null field whose
//      handle is IntPtr.Zero and an IsValid property for readability.
//
//   3. Value semantics. Each type implements IEquatable<T> and
//      overrides GetHashCode, so instances behave correctly in
//      dictionaries, comparisons and pattern matching.
//
// The wrapped pointer must NEVER be dereferenced directly. All access
// goes through the exported functions in NativeMethods or through the
// managed wrappers in LingoFuse.Core.
//
// ----------------------------------------------------------------------------
// CALLBACK DELEGATE TYPES
// ----------------------------------------------------------------------------
// All three delegates are declared with the C calling convention
// (UnmanagedFunctionPointer(CallingConvention.Cdecl)). The managed
// default conventions (fastcall on x64, stdcall on x86) would misalign
// the stack and crash the process.
//
// All three delegates are executed on a native worker thread. Their
// bodies must:
//
//   - never call any blocking LingoFuse function (LF_Call, LF_LocalCall,
//     LF_PrepareDone, LF_Shutdown); this would deadlock;
//   - never touch UI controls without marshalling to the UI thread;
//   - never let an exception escape into the native stack.
//
// The managed wrappers in LingoFuse.Core and LingoFuse.Events enforce
// the last two rules by catching every user exception and logging it
// via Debug.WriteLine.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
// This file contains no executable code that can throw. The only
// exception-relevant behaviour is in the delegate prototypes, which
// never throw on their own; the callee is responsible for its own
// exception isolation.
// ============================================================================

// ============================================================================
// Opaque handle types
// ============================================================================

/// <summary>
/// Opaque handle to a LingoFuse data buffer (TDataHnd).
/// </summary>
/// <remarks>
/// Created by <c>LF_CreateData</c> and released by <c>LF_FreeData</c>.
/// The underlying pointer must never be dereferenced directly; all
/// access must go through the exported functions.
/// </remarks>
[StructLayout(LayoutKind.Sequential)]
public struct DataHnd : IEquatable<DataHnd>
{
    /// <summary>
    /// Raw native pointer. <see cref="IntPtr.Zero"/> means "no handle".
    /// </summary>
    public IntPtr Handle;

    /// <summary>
    /// True when <see cref="Handle"/> is not <see cref="IntPtr.Zero"/>.
    /// </summary>
    public readonly bool IsValid => Handle != IntPtr.Zero;

    /// <summary>
    /// An empty handle (equivalent to a zero pointer). Safe to pass to
    /// <c>LF_FreeData</c>; the native layer ignores it.
    /// </summary>
    public static readonly DataHnd Null = new DataHnd { Handle = IntPtr.Zero };

    /// <summary>
    /// Value equality on the wrapped pointer.
    /// </summary>
    public readonly bool Equals(DataHnd other) =>
        Handle == other.Handle;

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
/// Created by <c>LF_CreateApp</c> and released by <c>LF_FreeApp</c>.
/// <c>LF_FreeApp</c> performs only the first stage of a two-stage
/// destruction: the object remains alive in the global application pool
/// until <c>LF_Shutdown</c> is called.
/// </remarks>
[StructLayout(LayoutKind.Sequential)]
public struct AppHnd : IEquatable<AppHnd>
{
    /// <summary>
    /// Raw native pointer. <see cref="IntPtr.Zero"/> means "no handle".
    /// </summary>
    public IntPtr Handle;

    /// <summary>
    /// True when <see cref="Handle"/> is not <see cref="IntPtr.Zero"/>.
    /// </summary>
    public readonly bool IsValid => Handle != IntPtr.Zero;

    /// <summary>
    /// An empty handle (equivalent to a zero pointer). Safe to pass to
    /// <c>LF_FreeApp</c>; the native layer ignores it. Also the
    /// expected argument for <c>LF_PrepareClient</c> when the client is
    /// a pure consumer that does not expose an application.
    /// </summary>
    public static readonly AppHnd Null = new AppHnd { Handle = IntPtr.Zero };

    /// <summary>
    /// Value equality on the wrapped pointer.
    /// </summary>
    public readonly bool Equals(AppHnd other) =>
        Handle == other.Handle;

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

// ============================================================================
// Callback delegate types
// ============================================================================

/// <summary>
/// Callback prototype for Call-mode (request-response) APIs.
/// </summary>
/// <param name="trigger">
/// User-supplied pointer passed at registration time. The managed
/// wrappers always pass <see cref="IntPtr.Zero"/>.
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
public delegate void LfCallFunc(IntPtr trigger, IntPtr input, IntPtr output);

/// <summary>
/// Callback prototype for Notify-mode (one-way) APIs.
/// </summary>
/// <param name="trigger">
/// User-supplied pointer passed at registration time. The managed
/// wrappers always pass <see cref="IntPtr.Zero"/>.
/// </param>
/// <param name="input">
/// Read-only input data handle. Valid only during the callback
/// invocation; the native layer releases it as soon as the callback
/// returns.
/// </param>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void LfNotifyFunc(IntPtr trigger, IntPtr input);

/// <summary>
/// Callback prototype for network connect / disconnect events.
/// </summary>
/// <param name="addr">
/// UTF-8 encoded endpoint string. The buffer is valid ONLY during the
/// callback invocation; the managed wrapper in LingoFuse.Events copies
/// it immediately, so the user delegate receives a managed string and
/// never sees a dangling pointer.
/// </param>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void LfNetworkEventFunc(IntPtr addr);