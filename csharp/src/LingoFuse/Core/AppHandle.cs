using System;
using System.Collections.Generic;
using System.Diagnostics;

using LingoFuse.Native;

namespace LingoFuse.Core;

// ============================================================================
// AppHandle — RAII wrapper around a native TAppHnd.
// ============================================================================
//
// Responsibility
// --------------
// Owns a native application handle and provides a managed API for
// registering Call / Notify endpoints, unregistering them, invoking
// them locally, and binding the application to idle clients.
//
// ----------------------------------------------------------------------------
// CALLBACK MODEL
// ----------------------------------------------------------------------------
// The wrapper presents a user-facing callback signature that receives
// managed DataHandle instances instead of raw IntPtr values:
//
//     Action<DataHandle, DataHandle>   — Call mode (input, output)
//     Action<DataHandle>               — Notify mode (input)
//
// The DataHandle instances passed to a user callback borrow the native
// handle (owned = false). They must NOT be disposed by the callback
// body; the native layer releases them as soon as the callback returns.
//
// ----------------------------------------------------------------------------
// DELEGATE LIFETIME
// ----------------------------------------------------------------------------
// Two levels of keep-alive are required:
//
//   1. The user callback is captured by a bridge closure. As long as
//      the bridge is alive, the user callback cannot be collected.
//
//   2. The bridge itself is stored in this instance's `_registrations`
//      map. As long as the AppHandle is alive (and the API has not been
//      unregistered), the bridge cannot be collected.
//
// When the AppHandle is disposed, or when an API is unregistered, the
// corresponding bridge is released and the user callback becomes
// collectable again.
//
// ----------------------------------------------------------------------------
// SYNCHRONOUS VARIANTS
// ----------------------------------------------------------------------------
// The *Sync variants route the callback through SyncQueue, so the user
// body runs on the main thread. The native worker thread blocks until
// the main thread completes the callback, ensuring the borrowed
// DataHandle instances remain valid for the entire duration of the
// user code. The application must drive SyncQueue.ProcessSyncQueue()
// from its main loop.
//
// ----------------------------------------------------------------------------
// CALLBACK EXCEPTION POLICY
// ----------------------------------------------------------------------------
// User callbacks run on native worker threads. An exception escaping a
// callback would cross into the C stack and could destabilise the
// process. The wrapper therefore catches every exception, logs it via
// System.Diagnostics.Debug.WriteLine, and returns normally. The
// native layer sees a callback that completed without producing output;
// the caller sees an empty response.
//
// This policy is deliberate and matches the reference C core, whose
// Engine.Execute_Call / Execute_Notify also swallow callback failures.
//
// ----------------------------------------------------------------------------
// LIFETIME OF THE UNDERLYING APPLICATION
// ----------------------------------------------------------------------------
// Dispose() calls LF_FreeApp, which is the first stage of a two-stage
// destruction: the native object is detached from all clients and its
// sequenced threads are stopped, but the object itself remains in the
// global pool until LF_Shutdown is called. After Dispose, the handle
// is invalid and must not be reused.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException              a reference argument is null
//     LingoFuseException                 the native layer refused the
//                                        application creation
//     LingoFuseObjectDisposedException   the handle has been disposed
//     LingoFuseRegistrationException     an API could not be registered
//                                        (name already in use)
//
// RegisterCall / RegisterNotify return false when the API name is
// already taken. They do not throw for that specific reason; the
// caller is expected to check the boolean result. The throwing variant
// is only used by LingoFuseApp.Expose, which converts a false return
// into a LingoFuseRegistrationException for a fluent API.
// ============================================================================

/// <summary>
/// RAII wrapper around a native LingoFuse application handle.
/// </summary>
public sealed class AppHandle : IDisposable
{
    private IntPtr _handle;
    private readonly string _name;
    private bool _disposed;

    /// <summary>
    /// Registered bridges indexed by API name. The dictionary is used
    /// both to keep the delegates alive and to support explicit
    /// unregistration. The comparer is case-insensitive to match the
    /// native library's name-matching semantics.
    /// </summary>
    private readonly Dictionary<string, Delegate> _registrations =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Guards mutations of <see cref="_registrations"/>.</summary>
    private readonly object _registrationsLock = new();

    /// <summary>
    /// Creates a new application with the given name and description.
    /// </summary>
    /// <param name="name">
    /// Application name. Must not be null. Should be unique on the mesh;
    /// case-insensitive matching applies at lookup time.
    /// </param>
    /// <param name="description">
    /// Optional human-readable description. A null value is treated as
    /// an empty string.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="name"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the native side fails to allocate the application.
    /// </exception>
    public AppHandle(string name, string description = "")
    {
        ArgumentNullException.ThrowIfNull(name);

        IntPtr namePtr = Utf8Marshal.Alloc(name);
        IntPtr descPtr = Utf8Marshal.Alloc(description ?? string.Empty);
        try
        {
            AppHnd raw = NativeMethods.LF_CreateApp(namePtr, descPtr);
            if (!raw.IsValid)
            {
                throw new LingoFuseException(
                    $"Failed to create application '{name}'.");
            }
            _handle = raw.Handle;
            _name = name;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
            Utf8Marshal.Free(descPtr);
        }
    }

    /// <summary>Application name passed to the constructor.</summary>
    public string Name => _name;

    /// <summary>
    /// Raw native pointer. <see cref="IntPtr.Zero"/> after the handle
    /// has been disposed.
    /// </summary>
    public IntPtr Raw => _handle;

    /// <summary>
    /// True while the handle is valid and not yet disposed.
    /// </summary>
    public bool IsValid => !_disposed && _handle != IntPtr.Zero;

    // ====================================================================
    // API registration — asynchronous (native worker thread)
    // ====================================================================

    /// <summary>
    /// Registers a Call (request-response) API whose handler runs on a
    /// native worker thread.
    /// </summary>
    /// <param name="apiName">
    /// API name. Must not be null. Case-insensitive matching applies at
    /// lookup time.
    /// </param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Receives borrowed DataHandle instances for
    /// input and output. Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or <paramref name="handler"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterCall(
        string apiName,
        string description,
        Action<DataHandle, DataHandle> handler)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        EnsureNotDisposed();

        LfCallFunc bridge = (trigger, input, output) =>
        {
            var inHandle = DataHandle.FromRaw(input, owned: false);
            var outHandle = DataHandle.FromRaw(output, owned: false);
            try
            {
                handler(inHandle, outHandle);
            }
            catch (Exception ex)
            {
                // Do not let a managed exception cross into the native
                // stack. The native layer treats a callback that returns
                // normally as "the handler produced no output"; the
                // caller observes an empty response and can retry.
                Debug.WriteLine(
                    $"[LingoFuse] Call callback for '{apiName}' threw: {ex}");
            }
        };

        return RegisterBridge(apiName, description, bridge);
    }

    /// <summary>
    /// Registers a Call API whose handler runs on the main thread.
    /// The application must drive <c>SyncQueue.ProcessSyncQueue()</c>
    /// from its main loop.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or <paramref name="handler"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterCallSync(
        string apiName,
        string description,
        Action<DataHandle, DataHandle> handler)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        EnsureNotDisposed();

        LfCallFunc userBridge = (trigger, input, output) =>
        {
            var inHandle = DataHandle.FromRaw(input, owned: false);
            var outHandle = DataHandle.FromRaw(output, owned: false);
            handler(inHandle, outHandle);
        };

        LfCallFunc syncBridge = SyncQueue.CreateSyncCallBridge(userBridge);
        return RegisterBridge(apiName, description, syncBridge);
    }

    /// <summary>
    /// Registers a Notify (one-way) API whose handler runs on a native
    /// worker thread.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">Optional description. Null is treated
    /// as an empty string.</param>
    /// <param name="handler">
    /// The user callback. Receives a borrowed DataHandle for the input
    /// payload. Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or <paramref name="handler"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterNotify(
        string apiName,
        string description,
        Action<DataHandle> handler)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        EnsureNotDisposed();

        LfNotifyFunc bridge = (trigger, input) =>
        {
            var inHandle = DataHandle.FromRaw(input, owned: false);
            try
            {
                handler(inHandle);
            }
            catch (Exception ex)
            {
                Debug.WriteLine(
                    $"[LingoFuse] Notify callback for '{apiName}' threw: {ex}");
            }
        };

        return RegisterBridge(apiName, description, bridge);
    }

    /// <summary>
    /// Registers a Notify API whose handler runs on the main thread.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or <paramref name="handler"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterNotifySync(
        string apiName,
        string description,
        Action<DataHandle> handler)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        EnsureNotDisposed();

        LfNotifyFunc userBridge = (trigger, input) =>
        {
            var inHandle = DataHandle.FromRaw(input, owned: false);
            handler(inHandle);
        };

        LfNotifyFunc syncBridge = SyncQueue.CreateSyncNotifyBridge(userBridge);
        return RegisterBridge(apiName, description, syncBridge);
    }

    // ====================================================================
    // API registration — unregister
    // ====================================================================

    /// <summary>
    /// Unregisters a previously registered API. Local effect is
    /// immediate; a network broadcast propagates within a few seconds.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <returns>true if the API was found and removed, false otherwise.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool Unregister(string apiName)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureNotDisposed();

        IntPtr namePtr = Utf8Marshal.Alloc(apiName);
        try
        {
            int result = NativeMethods.LF_Unregister(CurrentHnd, namePtr);
            if (result == 1)
            {
                lock (_registrationsLock)
                {
                    _registrations.Remove(apiName);
                }
            }
            return result == 1;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    // ====================================================================
    // Local execution
    // ====================================================================

    /// <summary>
    /// Invokes a Call API locally within the same process. The input
    /// handle is not consumed by this call.
    /// </summary>
    /// <param name="param">Input data handle. Must not be null.</param>
    /// <returns>
    /// A new DataHandle owning the result. The caller is responsible
    /// for disposing it. When the target API is not registered, the
    /// returned handle has <c>Size == 0</c>.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="param"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the native layer returns a null handle (an
    /// unexpected transport-level failure).
    /// </exception>
    public DataHandle LocalCall(DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(param);
        EnsureNotDisposed();

        var inputHnd = new DataHnd { Handle = param.Raw };
        DataHnd result = NativeMethods.LF_LocalCall(CurrentHnd, inputHnd);
        if (!result.IsValid)
        {
            throw new LingoFuseCallException(
                "LF_LocalCall returned a null handle.",
                targetApp: _name,
                targetApi: null);
        }
        return DataHandle.FromRaw(result.Handle, owned: true);
    }

    /// <summary>
    /// Invokes a Notify API locally within the same process.
    /// </summary>
    /// <param name="param">Input data handle. Must not be null.</param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="param"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public void LocalNotify(DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(param);
        EnsureNotDisposed();

        var inputHnd = new DataHnd { Handle = param.Raw };
        NativeMethods.LF_LocalNotify(CurrentHnd, inputHnd);
    }

    // ====================================================================
    // Client binding
    // ====================================================================

    /// <summary>
    /// Binds the application to all currently unbound clients. Must be
    /// called after the simulated main thread has started (i.e. after
    /// LF_PrepareDone returned 1).
    /// </summary>
    /// <returns>
    /// Number of clients bound. Zero means no free client was available
    /// or the main thread is not active.
    /// </returns>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public int Bind()
    {
        EnsureNotDisposed();
        return NativeMethods.LF_BindApp(CurrentHnd);
    }

    // ====================================================================
    // Lifetime
    // ====================================================================

    /// <summary>
    /// Performs the first stage of the two-stage native destruction.
    /// The application is detached from all clients and its sequenced
    /// threads are stopped. The underlying native object remains in the
    /// global pool until LF_Shutdown is called.
    /// </summary>
    /// <remarks>
    /// Safe to call multiple times. After the first call, all methods
    /// that require a live handle throw
    /// <see cref="LingoFuseObjectDisposedException"/>.
    /// </remarks>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        // Release the managed bridges first so that no future native
        // invocation can reach user code through this AppHandle.
        lock (_registrationsLock)
        {
            _registrations.Clear();
        }

        if (_handle != IntPtr.Zero)
        {
            var hnd = new AppHnd { Handle = _handle };
            NativeMethods.LF_FreeApp(hnd);
            _handle = IntPtr.Zero;
        }
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    private AppHnd CurrentHnd => new AppHnd { Handle = _handle };

    private void EnsureNotDisposed()
    {
        if (_disposed || _handle == IntPtr.Zero)
        {
            throw new LingoFuseObjectDisposedException(nameof(AppHandle));
        }
    }

    /// <summary>
    /// Common registration path shared by the four public register
    /// methods. Stores the bridge in <see cref="_registrations"/> and
    /// calls the appropriate native registration function based on the
    /// runtime type of <paramref name="bridge"/>.
    /// </summary>
    private bool RegisterBridge(
        string apiName,
        string description,
        Delegate bridge)
    {
        IntPtr namePtr = Utf8Marshal.Alloc(apiName);
        IntPtr descPtr = Utf8Marshal.Alloc(description ?? string.Empty);
        try
        {
            int result;
            if (bridge is LfCallFunc callFunc)
            {
                result = NativeMethods.LF_RegisterCall(
                    CurrentHnd, namePtr, descPtr, IntPtr.Zero, callFunc);
            }
            else if (bridge is LfNotifyFunc notifyFunc)
            {
                result = NativeMethods.LF_RegisterNotify(
                    CurrentHnd, namePtr, descPtr, IntPtr.Zero, notifyFunc);
            }
            else
            {
                // Internal invariant: only the two bridge types above
                // are ever passed in. This exception indicates a bug in
                // AppHandle itself, not in user code.
                throw new ArgumentException(
                    "Bridge delegate must be LfCallFunc or LfNotifyFunc.",
                    nameof(bridge));
            }

            if (result == 1)
            {
                lock (_registrationsLock)
                {
                    _registrations[apiName] = bridge;
                }
                return true;
            }
            return false;
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
            Utf8Marshal.Free(descPtr);
        }
    }
}