// ============================================================================
// File: csharp/src/LingoFuse_cs/AppHandle.cs
// ============================================================================
// AppHandle — RAII wrapper around a native TAppHnd.
// ============================================================================
// RESPONSIBILITY
// --------------
// Owns a native application handle and provides a managed API for
// registering Call / Notify endpoints, unregistering them, invoking
// them locally, and binding the application to idle clients.
//
// CALLBACK MODEL
// --------------
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
// CALLBACK DISPATCH
// -----------------
// Each registration overload comes in two forms:
//
//   * without a dispatcher  — the handler runs inline on the native
//                             worker thread that triggered the
//                             callback, exactly as before this
//                             abstraction existed;
//
//   * with a dispatcher     — the handler is marshalled to whatever
//                             thread the dispatcher chooses (the
//                             captured UI thread, a dedicated
//                             single-threaded queue, or a
//                             user-supplied scheduling primitive).
//
// The dispatcher contract is synchronous: Dispatch does not return
// until the handler body has completed. This keeps the framework-owned
// input and output handles alive for the entire duration of the
// handler, even when the handler runs on another thread. See
// CallbackDispatcher.cs for the full rationale.
//
// DELEGATE LIFETIME
// -----------------
// Two levels of keep-alive are required:
//
//   1. The user callback is captured by a bridge closure. As long as
//      the bridge is alive, the user callback cannot be collected.
//
//   2. The bridge itself is stored in this instance's _registrations
//      map. As long as the AppHandle is alive (and the API has not
//      been unregistered), the bridge cannot be collected.
//
// When the AppHandle is disposed, or when an API is unregistered, the
// corresponding bridge is released and the user callback becomes
// collectable again.
//
// CALLBACK EXCEPTION POLICY
// -------------------------
// User callbacks run either on native worker threads or on whatever
// thread a dispatcher selects. An exception escaping a callback would
// cross into the C stack and could destabilise the process. The
// wrapper therefore catches every exception and reports it through
// Framework.ReportCallbackError, which forwards to the
// application-installed handler (if any) and to Trace.WriteLine. The
// native layer sees a callback that completed without producing
// output.
//
// This policy matches the reference C core, whose Engine.Execute_Call /
// Execute_Notify also swallow callback failures.
//
// THREAD SAFETY OF REGISTRATION
// -----------------------------
// Every public method that touches the native handle or the
// _registrations dictionary is serialised under _registrationsLock.
// This closes the race between an in-flight Register call and a
// concurrent Dispose: the two cannot interleave in a way that leaves
// LF_RegisterCall operating on an already-freed handle.
//
// LIFETIME OF THE UNDERLYING APPLICATION
// --------------------------------------
// Dispose calls LF_FreeApp, which is the first stage of a two-stage
// destruction: the native object is detached from all clients and its
// sequenced threads are stopped, but the object itself remains in the
// global pool until LF_Shutdown is called. After Dispose, the handle
// is invalid and must not be reused.
//
// ============================================================================

using System;
using System.Collections.Generic;

using LingoFuse.Native;

namespace LingoFuse;

/// <summary>
/// RAII wrapper around a native LingoFuse application handle.
/// </summary>
public sealed class AppHandle : IDisposable
{
    private volatile IntPtr _handle;
    private readonly string _name;
    private bool _disposed;

    /// <summary>
    /// Registered bridges indexed by API name. The dictionary keeps
    /// the bridge delegates alive and supports explicit unregistration.
    /// The comparer is case-insensitive to match the native library's
    /// name-matching semantics.
    ///
    /// All mutations of this dictionary are guarded by
    /// <see cref="_registrationsLock"/>. The same lock also guards
    /// <see cref="_handle"/> and <see cref="_disposed"/> so that a
    /// registration cannot race with a concurrent Dispose.
    /// </summary>
    private readonly Dictionary<string, Delegate> _registrations =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Guards every mutation of the native handle and of the
    /// _registrations dictionary.
    /// </summary>
    private readonly object _registrationsLock = new();

    /// <summary>
    /// Creates a new application with the given name and description.
    /// </summary>
    /// <param name="name">
    /// Application name. Must not be null. Should be unique on the
    /// mesh; case-insensitive matching applies at lookup time.
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
    // API registration — Call mode
    // ====================================================================

    /// <summary>
    /// Registers a Call (request-response) API whose handler runs
    /// inline on the native worker thread.
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
    /// <remarks>
    /// This overload uses <see cref="CallbackDispatcher.Inline"/>: the
    /// handler runs synchronously on the native worker thread that
    /// triggered the callback. It is the historical behaviour and
    /// remains the correct default for CPU-bound handlers that do not
    /// touch UI or single-threaded state.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or
    /// <paramref name="handler"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterCall(
        string apiName,
        string description,
        Action<DataHandle, DataHandle> handler)
    {
        return RegisterCall(
            apiName, description, handler, CallbackDispatcher.Inline);
    }

    /// <summary>
    /// Registers a Call (request-response) API whose handler runs on
    /// the thread selected by <paramref name="dispatcher"/>.
    /// </summary>
    /// <param name="apiName">
    /// API name. Must not be null.
    /// </param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Receives borrowed DataHandle instances for
    /// input and output. Must not be null.
    /// </param>
    /// <param name="dispatcher">
    /// The dispatcher that decides which thread runs the handler.
    /// Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <remarks>
    /// <para>
    /// The dispatcher contract is synchronous: the native worker
    /// thread that triggered the callback blocks until the handler
    /// body has completed on the dispatcher's chosen thread. This is
    /// what keeps the framework-owned input and output handles alive
    /// for the entire duration of the handler, even when the handler
    /// runs elsewhere.
    /// </para>
    /// <para>
    /// Typical uses:
    /// </para>
    /// <list type="bullet">
    ///   <item><see cref="CallbackDispatcher.MainThread"/> for a
    ///         handler that touches UI controls directly.</item>
    ///   <item><see cref="CallbackDispatcher.CreateSingleThreadedQueue"/>
    ///         for a handler that must serialise access to a
    ///         single-threaded resource.</item>
    ///   <item><see cref="CallbackDispatcher.CreateCustom"/> to plug in
    ///         an application-specific scheduler.</item>
    /// </list>
    /// <para>
    /// See <see cref="CallbackDispatcher"/> for the deadlock caveat
    /// that applies when dispatching to the UI thread while the UI
    /// thread is itself blocked on a synchronous LingoFuse call.
    /// </para>
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterCall(
        string apiName,
        string description,
        Action<DataHandle, DataHandle> handler,
        ILingoCallbackDispatcher dispatcher)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        ArgumentNullException.ThrowIfNull(dispatcher);

        LfCallFunc bridge = (trigger, input, output) =>
        {
            // Wrap the raw pointers in borrowing DataHandle instances
            // before dispatching. Because the dispatcher contract is
            // synchronous, the wrapped handles remain valid for the
            // entire callback lifetime, including the portion that
            // runs on the dispatcher's chosen thread.
            var inHandle = DataHandle.FromRaw(input, owned: false);
            var outHandle = DataHandle.FromRaw(output, owned: false);
            try
            {
                dispatcher.Dispatch(() => handler(inHandle, outHandle));
            }
            catch (Exception ex)
            {
                Framework.ReportCallbackError(
                    $"AppHandle.RegisterCall[{apiName}]", ex);
            }
        };

        lock (_registrationsLock)
        {
            EnsureNotDisposed();
            return RegisterBridgeLocked(apiName, description, bridge);
        }
    }

    // ====================================================================
    // API registration — Notify mode
    // ====================================================================

    /// <summary>
    /// Registers a Notify (one-way) API whose handler runs inline on
    /// the native worker thread.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Receives a borrowed DataHandle for the input
    /// payload. Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <remarks>
    /// This overload uses <see cref="CallbackDispatcher.Inline"/>. It
    /// is the historical behaviour and remains the correct default for
    /// CPU-bound handlers that do not touch UI or single-threaded
    /// state.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or
    /// <paramref name="handler"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterNotify(
        string apiName,
        string description,
        Action<DataHandle> handler)
    {
        return RegisterNotify(
            apiName, description, handler, CallbackDispatcher.Inline);
    }

    /// <summary>
    /// Registers a Notify (one-way) API whose handler runs on the
    /// thread selected by <paramref name="dispatcher"/>.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">
    /// Optional description. Null is treated as an empty string.
    /// </param>
    /// <param name="handler">
    /// The user callback. Receives a borrowed DataHandle for the input
    /// payload. Must not be null.
    /// </param>
    /// <param name="dispatcher">
    /// The dispatcher that decides which thread runs the handler.
    /// Must not be null.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <remarks>
    /// Same synchronous dispatcher contract as
    /// <see cref="RegisterCall(string, string, Action{DataHandle, DataHandle}, ILingoCallbackDispatcher)"/>.
    /// The input handle remains valid for the entire duration of the
    /// handler body.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when any argument is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the handle has been disposed.
    /// </exception>
    public bool RegisterNotify(
        string apiName,
        string description,
        Action<DataHandle> handler,
        ILingoCallbackDispatcher dispatcher)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        ArgumentNullException.ThrowIfNull(dispatcher);

        LfNotifyFunc bridge = (trigger, input) =>
        {
            var inHandle = DataHandle.FromRaw(input, owned: false);
            try
            {
                dispatcher.Dispatch(() => handler(inHandle));
            }
            catch (Exception ex)
            {
                Framework.ReportCallbackError(
                    $"AppHandle.RegisterNotify[{apiName}]", ex);
            }
        };

        lock (_registrationsLock)
        {
            EnsureNotDisposed();
            return RegisterBridgeLocked(apiName, description, bridge);
        }
    }

    // ====================================================================
    // Unregistration
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

        lock (_registrationsLock)
        {
            EnsureNotDisposed();

            IntPtr namePtr = Utf8Marshal.Alloc(apiName);
            try
            {
                int result = NativeMethods.LF_Unregister(
                    CurrentHnd, namePtr);
                if (result == 1)
                {
                    _registrations.Remove(apiName);
                }
                return result == 1;
            }
            finally
            {
                Utf8Marshal.Free(namePtr);
            }
        }
    }

    // ====================================================================
    // Local execution
    // ====================================================================
    //
    // Local call and notify invoke the registered handler synchronously
    // on the CALLING thread, bypassing the native worker pool entirely.
    // No dispatcher is involved: the caller is already in control of
    // its own thread, and the input / output handles are the caller's
    // own DataHandle instances, which the caller manages directly.

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

        lock (_registrationsLock)
        {
            EnsureNotDisposed();

            var inputHnd = new DataHnd { Handle = param.Raw };
            DataHnd result = NativeMethods.LF_LocalCall(
                CurrentHnd, inputHnd);
            if (!result.IsValid)
            {
                throw new LingoFuseCallException(
                    "LF_LocalCall returned a null handle.",
                    targetApp: _name,
                    targetApi: null);
            }
            return DataHandle.FromRaw(result.Handle, owned: true);
        }
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

        lock (_registrationsLock)
        {
            EnsureNotDisposed();

            var inputHnd = new DataHnd { Handle = param.Raw };
            NativeMethods.LF_LocalNotify(CurrentHnd, inputHnd);
        }
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
        lock (_registrationsLock)
        {
            EnsureNotDisposed();
            return NativeMethods.LF_BindApp(CurrentHnd);
        }
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

        lock (_registrationsLock)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;

            // Release the managed bridges first so that no future
            // native invocation can reach user code through this
            // AppHandle.
            _registrations.Clear();

            if (_handle != IntPtr.Zero)
            {
                var hnd = new AppHnd { Handle = _handle };
                NativeMethods.LF_FreeApp(hnd);
                _handle = IntPtr.Zero;
            }
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
    /// <remarks>
    /// The caller MUST hold <see cref="_registrationsLock"/> and MUST
    /// have already called <see cref="EnsureNotDisposed"/>. This
    /// invariant is what prevents a registration from racing with a
    /// concurrent Dispose: the handle cannot be freed while the native
    /// registration call is in flight.
    /// </remarks>
    private bool RegisterBridgeLocked(
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
                // are ever passed in.
                throw new ArgumentException(
                    "Bridge delegate must be LfCallFunc or LfNotifyFunc.",
                    nameof(bridge));
            }

            if (result == 1)
            {
                _registrations[apiName] = bridge;
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