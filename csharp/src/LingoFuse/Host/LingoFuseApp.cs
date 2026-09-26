using System;
using System.Collections.Generic;

using LingoFuse.Core;
using LingoFuse.Io;
using LingoFuse.Native;

namespace LingoFuse.Host;

// ============================================================================
// LingoFuseApp — high-level application container.
// ============================================================================
//
// Purpose
// -------
// LingoFuseApp layers a JSON-oriented, user-friendly API on top of
// AppHandle. Instead of dealing with DataHandle buffers and NUL framing
// directly, callers register functions that accept and return plain
// objects:
//
//     app.Expose("add", (int a, int b) => a + b);
//     var result = app.LocalCall<int>("add", new object[] { 5, 7 });
//
// The container is responsible for:
//
//   - serialising arguments into a JSON envelope and deserialising the
//     return value out of it;
//   - translating between the JSON view of a payload and the raw
//     DataHandle buffer used on the wire;
//   - wrapping every user handler in the appropriate bridge so that
//     the handler sees managed DataHandle instances instead of raw
//     pointers;
//   - keeping the AppHandle alive and disposing it deterministically.
//
// ----------------------------------------------------------------------------
// TWO PARALLEL REGISTRATION PATHS
// ----------------------------------------------------------------------------
// Two families of Expose overloads are provided. Both are first-class;
// there is no implicit conversion between them.
//
//   JSON path (typed, convenient):
//       Expose<TResult>              zero-argument handler
//       Expose<TArg, TResult>        one-argument handler
//       Expose<T1, T2, TResult>      two-argument handler
//       ExposeNotify<TArg>           typed one-argument notify handler
//
//       The handler receives and returns plain objects. Arguments and
//       return values are serialized through JsonPolicy. This is the
//       natural form for structured RPC and for interop with Python /
//       C++ / Pascal services that speak JSON.
//
//   ABI path (raw, low-level):
//       Expose(apiName, description,
//              Action<DataHandle, DataHandle>)
//       ExposeNotify(apiName, description,
//                    Action<DataHandle>)
//
//       The handler receives borrowed DataHandle instances. No JSON
//       layer is involved. This is the natural form for cross-language
//       binary RPC where every peer reads and writes the same raw byte
//       sequence.
//
// Choose one form per (app, api) and use it consistently across all
// languages; the wire formats are not interchangeable.
//
// ----------------------------------------------------------------------------
// {!!!!!  ABI HANDLERS AND BORROWED HANDLES  !!!!!}
// ----------------------------------------------------------------------------
// In an ABI handler registered through Expose / ExposeNotify, the
// DataHandle instances passed to the handler are BORROWED from the
// native layer:
//
//   - They must NOT be disposed by the handler. DataHandle.Dispose()
//     is a no-op for a borrowed handle, so an accidental call is
//     harmless, but the handler body should treat the handles as
//     read-only in the case of `input`, and write-only in the case of
//     `output`.
//
//   - The handles are valid only for the duration of the handler. Any
//     pointer obtained through GetBufferPointer() is invalidated as
//     soon as the handler returns.
//
//   - Do not capture the handles or their pointers for later use. Copy
//     any data you need into your own buffers.
//
// ----------------------------------------------------------------------------
// JSON ENVELOPE CONVENTION (JSON path only)
// ----------------------------------------------------------------------------
// The typed overloads use a small, language-neutral convention:
//
//   * No argument           -> the payload is the JSON literal `null`.
//   * Single argument       -> the payload is the JSON serialisation
//                              of that argument. A null reference
//                              argument is transmitted as JSON `null`,
//                              and a handler can therefore receive a
//                              null value for a reference type.
//   * Two arguments         -> the payload is a JSON array containing
//                              the serialised arguments in order.
//
// On the return side, the response body is the JSON serialisation of
// the returned value. A null return value produces the JSON literal
// `null`.
//
// Exceptions raised by the user handler are turned into a JSON error
// envelope of the shape { "__error__": "...", "__type__": "..." },
// matching the convention used by the Python binding.
//
// ----------------------------------------------------------------------------
// {!!!!!  LOCALCALL AND UNREGISTERED APIS  !!!!!}
// ----------------------------------------------------------------------------
// C++ and Python return an empty response when a local call targets an
// API that is not registered on the application. Their caller-side
// helpers translate that empty response into a null / None value.
//
// The C# JSON path mirrors this: LocalCall<T> returns default(T) when
// the response handle is empty. Callers that need to distinguish an
// empty response from a legitimate null/default return value should
// use TryLocalCall<T>, which returns a boolean.
//
// The ABI path (LocalCallBinary) exposes the raw response handle. An
// unregistered API produces a size-0 handle; the caller is expected to
// check handle.Size before reading.
//
// ----------------------------------------------------------------------------
// APPLICATION NAME
// ----------------------------------------------------------------------------
// When the name is null or empty, a globally unique name is generated
// via LF_Generate_AppName. That call requires the simulated main thread
// to be running, so an auto-generated name is only safe after
// LF_PrepareDone has returned 1. Passing an explicit name removes that
// constraint.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException              a reference argument is null
//     LingoFuseException                 the underlying AppHandle
//                                        creation or JSON processing
//                                        failed
//     LingoFuseStateException            an auto-generated name was
//                                        requested before the main
//                                        thread was started
//     LingoFuseObjectDisposedException   the container has been disposed
//     LingoFuseRegistrationException     an API could not be registered
//                                        (name already in use)
// ============================================================================

/// <summary>
/// High-level application container that exposes JSON-oriented APIs.
/// </summary>
public sealed class LingoFuseApp : IDisposable
{
    private readonly AppHandle _handle;
    private readonly HashSet<string> _exposedApis =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly object _exposedLock = new();
    private bool _disposed;

    /// <summary>
    /// Creates a new application container.
    /// </summary>
    /// <param name="name">
    /// Application name. When null or empty, a globally unique name is
    /// generated via <c>LF_Generate_AppName</c>. That call requires the
    /// simulated main thread to be running, so it is only safe after
    /// <c>LF_PrepareDone</c> has returned 1.
    /// </param>
    /// <param name="description">Optional description.</param>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when an auto-generated name is requested before the
    /// simulated main thread is running.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the native side fails to allocate the application.
    /// </exception>
    public LingoFuseApp(string? name = null, string description = "")
    {
        string effectiveName = string.IsNullOrEmpty(name)
            ? GenerateAppName()
            : name!;

        _handle = new AppHandle(effectiveName, description);
    }

    /// <summary>The underlying application handle.</summary>
    public AppHandle Handle => _handle;

    /// <summary>Raw native pointer, for callers that need it.</summary>
    public IntPtr Raw => _handle.Raw;

    /// <summary>Application name.</summary>
    public string Name => _handle.Name;

    /// <summary>True while the container is valid and not yet disposed.</summary>
    public bool IsValid => !_disposed && _handle.IsValid;

    // ====================================================================
    // Registration — ABI path
    // ====================================================================
    //
    // These methods pass borrowed DataHandle instances directly to the
    // user handler. No JSON serialization is performed. This is the
    // natural form for cross-language binary RPC.

    /// <summary>
    /// Registers a Call API whose handler receives the input as a
    /// DataHandle and is expected to write the output into another
    /// DataHandle. No JSON serialization is performed.
    /// </summary>
    /// <param name="apiName">API name. Must not be null.</param>
    /// <param name="description">Optional description.</param>
    /// <param name="handler">
    /// The user callback. Receives borrowed DataHandle instances.
    /// Must not be null.
    ///
    /// {!!!!!  BORROWED HANDLE CONTRACT  !!!!!}
    /// The `input` and `output` handles passed to the handler are
    /// borrowed from the native layer:
    ///
    ///   - Do NOT capture them beyond the handler's return; the native
    ///     layer releases them immediately afterwards.
    ///   - Do NOT capture pointers returned by GetBufferPointer(); they
    ///     become invalid the moment the handler returns.
    ///   - Dispose() is a no-op on a borrowed handle, so an accidental
    ///     call is harmless, but it should not be relied upon.
    /// </param>
    /// <param name="synchronous">
    /// When true, the handler runs on the main thread. The application
    /// must drive <c>LingoFuseSync.ProcessSyncQueue()</c> from its main
    /// loop. When false (the default), the handler runs on a native
    /// worker thread.
    /// </param>
    /// <returns>true on success, false if the API name is already taken.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or <paramref name="handler"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the container has been disposed.
    /// </exception>
    public bool Expose(
        string apiName,
        string description,
        Action<DataHandle, DataHandle> handler,
        bool synchronous = false)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        EnsureNotDisposed();

        bool ok = synchronous
            ? _handle.RegisterCallSync(apiName, description, handler)
            : _handle.RegisterCall(apiName, description, handler);

        if (ok)
        {
            lock (_exposedLock)
            {
                _exposedApis.Add(apiName);
            }
        }
        return ok;
    }

    /// <summary>
    /// Registers a Notify API whose handler receives the input as a
    /// DataHandle. No JSON serialization is performed.
    /// </summary>
    /// <remarks>
    /// See <see cref="Expose"/> for the borrowed-handle contract that
    /// applies to the `input` handle passed to the handler.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> or <paramref name="handler"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the container has been disposed.
    /// </exception>
    public bool ExposeNotify(
        string apiName,
        string description,
        Action<DataHandle> handler,
        bool synchronous = false)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        ArgumentNullException.ThrowIfNull(handler);
        EnsureNotDisposed();

        bool ok = synchronous
            ? _handle.RegisterNotifySync(apiName, description, handler)
            : _handle.RegisterNotify(apiName, description, handler);

        if (ok)
        {
            lock (_exposedLock)
            {
                _exposedApis.Add(apiName);
            }
        }
        return ok;
    }

    // ====================================================================
    // Registration — JSON path (typed)
    // ====================================================================

    /// <summary>
    /// Registers a Call API whose handler accepts zero arguments. The
    /// handler's return value is serialized to JSON and written to the
    /// response handle.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handler"/> is null.
    /// </exception>
    public bool Expose<TResult>(
        string apiName,
        Func<TResult> handler,
        string description = "",
        bool synchronous = false)
    {
        ArgumentNullException.ThrowIfNull(handler);

        return Expose(apiName, description, (input, output) =>
        {
            try
            {
                TResult result = handler();
                LfIo.WriteJson(output, result);
            }
            catch (Exception ex)
            {
                WriteErrorEnvelope(output, ex);
            }
        }, synchronous);
    }

    /// <summary>
    /// Registers a Call API whose handler accepts one argument. The
    /// argument is deserialized from the request payload; the return
    /// value is serialized to JSON.
    /// </summary>
    /// <remarks>
    /// The payload may take one of the following shapes:
    ///   - a JSON value, which is deserialized directly into TArg;
    ///   - a one-element JSON array, whose single element is deserialized
    ///     into TArg;
    ///   - the JSON literal null, in which case the handler receives
    ///     default(TArg). This makes it possible to transmit a null
    ///     reference argument from a JSON peer, matching the behaviour
    ///     of the Python / C++ / Pascal bindings.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handler"/> is null.
    /// </exception>
    public bool Expose<TArg, TResult>(
        string apiName,
        Func<TArg, TResult> handler,
        string description = "",
        bool synchronous = false)
    {
        ArgumentNullException.ThrowIfNull(handler);

        return Expose(apiName, description, (input, output) =>
        {
            try
            {
                TArg arg = ReadSingleArgument<TArg>(input);
                TResult result = handler(arg);
                LfIo.WriteJson(output, result);
            }
            catch (Exception ex)
            {
                WriteErrorEnvelope(output, ex);
            }
        }, synchronous);
    }

    /// <summary>
    /// Registers a Call API whose handler accepts two arguments. The
    /// payload must be a JSON array with exactly two elements.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handler"/> is null.
    /// </exception>
    public bool Expose<T1, T2, TResult>(
        string apiName,
        Func<T1, T2, TResult> handler,
        string description = "",
        bool synchronous = false)
    {
        ArgumentNullException.ThrowIfNull(handler);

        return Expose(apiName, description, (input, output) =>
        {
            try
            {
                (T1 first, T2 second) = ReadTwoArguments<T1, T2>(input);
                TResult result = handler(first, second);
                LfIo.WriteJson(output, result);
            }
            catch (Exception ex)
            {
                WriteErrorEnvelope(output, ex);
            }
        }, synchronous);
    }

    /// <summary>
    /// Registers a Notify API whose handler accepts one argument.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="handler"/> is null.
    /// </exception>
    public bool ExposeNotify<TArg>(
        string apiName,
        Action<TArg> handler,
        string description = "",
        bool synchronous = false)
    {
        ArgumentNullException.ThrowIfNull(handler);

        return ExposeNotify(apiName, description, input =>
        {
            TArg arg = ReadSingleArgument<TArg>(input);
            handler(arg);
        }, synchronous);
    }

    // ====================================================================
    // Unregister
    // ====================================================================

    /// <summary>
    /// Removes a previously registered API.
    /// </summary>
    /// <returns>true if the API was found and removed, false otherwise.</returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    public bool Unregister(string apiName)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureNotDisposed();

        bool ok = _handle.Unregister(apiName);
        if (ok)
        {
            lock (_exposedLock)
            {
                _exposedApis.Remove(apiName);
            }
        }
        return ok;
    }

    /// <summary>Snapshot of the API names currently registered.</summary>
    public IReadOnlyCollection<string> ExposedApis
    {
        get
        {
            lock (_exposedLock)
            {
                return new List<string>(_exposedApis);
            }
        }
    }

    // ====================================================================
    // Local execution — JSON path
    // ====================================================================

    /// <summary>
    /// Invokes a Call API locally within the same process. The payload
    /// is serialized through JsonPolicy; the response is deserialized
    /// back.
    /// </summary>
    /// <param name="apiName">The target API name. Must not be null.</param>
    /// <param name="payload">
    /// Argument to the API. Pass <c>null</c> for a no-argument API.
    /// Pass a bare value for a single-argument API. Pass an
    /// <c>object[]</c> for a two-or-more-argument API.
    /// </param>
    /// <returns>
    /// The response body, deserialised as <typeparamref name="T"/>.
    /// Returns <c>default(T)</c> when the API is not registered on this
    /// application (matching the behaviour of the Python and C++
    /// bindings), or when the response payload is the JSON literal
    /// <c>null</c>.
    /// </returns>
    /// <remarks>
    /// Callers that need to distinguish an empty response (unregistered
    /// API) from a legitimate null/default return value should use
    /// <see cref="TryLocalCall{T}"/>, which returns a boolean.
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the container has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the native layer returns a null handle.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the response payload is not valid JSON for
    /// <typeparamref name="T"/>.
    /// </exception>
    public T? LocalCall<T>(string apiName, object? payload = null)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureNotDisposed();

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);

        using DataHandle response = _handle.LocalCall(request);

        // An unregistered API returns a size-0 handle. This mirrors the
        // behaviour of the C++ and Python bindings, whose callers see a
        // null / None value in this case. Return default(T) rather than
        // throwing, so that the C# API stays symmetric with the rest of
        // the LingoFuse family.
        if (response.Size == 0)
        {
            return default;
        }

        return LfIo.ReadJson<T>(response);
    }

    /// <summary>
    /// Non-throwing counterpart of <see cref="LocalCall{T}"/>. Returns
    /// true when the response handle was non-empty, false when the API
    /// was not registered (size-0 response).
    /// </summary>
    /// <param name="apiName">The target API name. Must not be null.</param>
    /// <param name="payload">
    /// Argument to the API. Same shape as <see cref="LocalCall{T}"/>.
    /// </param>
    /// <param name="result">
    /// On success, receives the deserialised response. On failure (empty
    /// response), receives <c>default</c>.
    /// </param>
    /// <returns>
    /// true when the API produced a non-empty response; false when the
    /// API was not registered.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the container has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the native layer returns a null handle.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the response payload is not valid JSON for
    /// <typeparamref name="T"/>.
    /// </exception>
    public bool TryLocalCall<T>(
        string apiName,
        object? payload,
        out T? result)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureNotDisposed();

        result = default;

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);

        using DataHandle response = _handle.LocalCall(request);
        if (response.Size == 0)
        {
            return false;
        }

        result = LfIo.ReadJson<T>(response);
        return true;
    }

    /// <summary>
    /// Convenience overload of <see cref="TryLocalCall{T}"/> with a
    /// default null payload.
    /// </summary>
    public bool TryLocalCall<T>(string apiName, out T? result)
        => TryLocalCall(apiName, payload: null, out result);

    /// <summary>
    /// Invokes a Notify API locally within the same process. The
    /// payload is serialized through JsonPolicy.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="apiName"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the container has been disposed.
    /// </exception>
    public void LocalNotify(string apiName, object? payload = null)
    {
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureNotDisposed();

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);
        _handle.LocalNotify(request);
    }

    // ====================================================================
    // Local execution — ABI path
    // ====================================================================

    /// <summary>
    /// Invokes a Call API locally within the same process, using a
    /// caller-supplied request handle. No JSON serialization is
    /// performed. The caller retains ownership of <paramref name="request"/>.
    /// </summary>
    /// <param name="request">
    /// Request data handle. Must not be null.
    /// </param>
    /// <returns>
    /// A new response handle owned by the caller. The caller must
    /// dispose it. When the target API is not registered, the returned
    /// handle has <c>Size == 0</c>; the caller is expected to check
    /// <c>Size</c> before reading.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="request"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the container has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the native layer returns a null handle.
    /// </exception>
    public DataHandle LocalCallBinary(DataHandle request)
    {
        ArgumentNullException.ThrowIfNull(request);
        EnsureNotDisposed();
        return _handle.LocalCall(request);
    }

    /// <summary>
    /// Invokes a Notify API locally within the same process, using a
    /// caller-supplied request handle. No JSON serialization is
    /// performed.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="request"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the container has been disposed.
    /// </exception>
    public void LocalNotifyBinary(DataHandle request)
    {
        ArgumentNullException.ThrowIfNull(request);
        EnsureNotDisposed();
        _handle.LocalNotify(request);
    }

    // ====================================================================
    // Client binding
    // ====================================================================

    /// <summary>
    /// Binds this application to all currently unbound clients. Must be
    /// called after the simulated main thread has started.
    /// </summary>
    /// <returns>
    /// Number of clients bound. Zero means no free client was available
    /// or the main thread is not active.
    /// </returns>
    public int Bind()
    {
        EnsureNotDisposed();
        return _handle.Bind();
    }

    // ====================================================================
    // Lifetime
    // ====================================================================

    /// <summary>
    /// Releases the underlying application handle. The native object
    /// itself remains in the global pool until <c>LF_Shutdown</c> is
    /// called.
    /// </summary>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        lock (_exposedLock)
        {
            _exposedApis.Clear();
        }
        _handle.Dispose();
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    private void EnsureNotDisposed()
    {
        if (_disposed)
        {
            throw new LingoFuseObjectDisposedException(nameof(LingoFuseApp));
        }
    }

    private static string GenerateAppName()
    {
        IntPtr ptr = NativeMethods.LF_Generate_AppName();
        string name = Utf8Marshal.PtrToString(ptr);
        if (name.Length == 0)
        {
            throw new LingoFuseStateException(
                "Failed to generate an application name. " +
                "LF_Generate_AppName must be called after LF_PrepareDone returns 1.");
        }
        return name;
    }

    /// <summary>
    /// Reads the request body and returns the single argument it
    /// carries.
    /// </summary>
    /// <remarks>
    /// Accepted shapes:
    ///   - a bare JSON value  ->  deserialised directly into T;
    ///   - a one-element JSON array  ->  its single element is
    ///     deserialised into T;
    ///   - the JSON literal null  ->  default(T), which allows a
    ///     reference-typed argument to be null across the wire.
    ///
    /// An empty payload (not "null", but truly zero bytes) is rejected
    /// as a caller error, matching the behaviour of the Python and C++
    /// bindings, which require a payload.
    /// </remarks>
    private static T ReadSingleArgument<T>(DataHandle input)
    {
        string json = LfIo.ReadString(input);
        if (string.IsNullOrEmpty(json))
        {
            throw new LingoFuseException(
                "Expected a JSON argument but the input payload was empty.");
        }

        // Case 1: a bare JSON value. This includes the JSON literal
        // `null`, which deserialises to default(T) for reference types
        // and to null for Nullable<T>; the deserialiser will reject
        // `null` for a non-nullable value type, and we fall through to
        // the array branch below.
        if (JsonPolicy.TryLoads(json, out T? direct))
        {
            return direct!;
        }

        // Case 2: a one-element JSON array whose single element is the
        // argument.
        T[]? unwrapped = null;
        if (JsonPolicy.TryLoads(json, out unwrapped)
            && unwrapped is { Length: 1 })
        {
            return unwrapped[0];
        }

        throw new LingoFuseException(
            $"Failed to interpret the input payload as a single argument " +
            $"of type {typeof(T).FullName}.");
    }

    /// <summary>
    /// Reads a two-argument request. The payload must be a JSON array
    /// with exactly two elements.
    /// </summary>
    private static (T1, T2) ReadTwoArguments<T1, T2>(DataHandle input)
    {
        string json = LfIo.ReadString(input);
        if (string.IsNullOrEmpty(json))
        {
            throw new LingoFuseException(
                "Expected a JSON array argument but the input payload was empty.");
        }

        if (!JsonPolicy.TryLoads(json, out object?[]? asObjects)
            || asObjects is not { Length: 2 })
        {
            throw new LingoFuseException(
                $"Failed to interpret the input payload as a two-element " +
                $"array of types ({typeof(T1).FullName}, {typeof(T2).FullName}).");
        }

        T1 first = ConvertElement<T1>(asObjects[0]);
        T2 second = ConvertElement<T2>(asObjects[1]);
        return (first, second);
    }

    /// <summary>
    /// Converts a single JSON-decoded element into the requested type.
    /// A null element produces default(T) for reference types and
    /// Nullable&lt;T&gt;, and is rejected for non-nullable value types.
    /// </summary>
    private static T ConvertElement<T>(object? element)
    {
        if (element is null)
        {
            // Reference types and Nullable<T> accept null.
            if (!typeof(T).IsValueType
                || Nullable.GetUnderlyingType(typeof(T)) is not null)
            {
                return default!;
            }

            throw new LingoFuseException(
                $"Null element cannot be converted to {typeof(T).FullName}.");
        }
        if (element is T typed)
        {
            return typed;
        }

        string text = JsonPolicy.Dumps(element);
        return JsonPolicy.Loads<T>(text);
    }

    /// <summary>
    /// Writes a JSON error envelope to the response handle. The shape
    /// matches the convention used by the Python binding:
    /// <c>{ "__error__": "...", "__type__": "..." }</c>.
    /// </summary>
    private static void WriteErrorEnvelope(DataHandle output, Exception ex)
    {
        var envelope = new Dictionary<string, string>
        {
            ["__error__"] = ex.Message,
            ["__type__"] = ex.GetType().FullName ?? ex.GetType().Name,
        };
        try
        {
            LfIo.WriteJson(output, envelope);
        }
        catch
        {
            // The output handle may already be in an inconsistent
            // state; there is nothing more we can do here. The native
            // caller will observe an empty response.
        }
    }
}