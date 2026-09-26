// ============================================================================
// LingoFuseServer — service + client host.
// ============================================================================
//
// Owns a service endpoint, an application container, and an internal
// client. Use it when the process must both expose APIs and call other
// applications.
//
// ----------------------------------------------------------------------------
// ROLE IN THE HOST FAMILY
// ----------------------------------------------------------------------------
//   LingoFuseClient   — consumer only.      No service, no App.
//   LingoFuseServer   — service + client.   Owns a service endpoint
//                                           and an App.
//   LingoFuseNode     — worker.             Owns an App; attaches to
//                                           an existing service.
//
// Use LingoFuseServer when this process is the coordinator for an
// endpoint: it both listens and participates in the mesh. Use
// LingoFuseNode when a coordinator already exists and this process
// only registers APIs on it. Use LingoFuseClient when no API needs to
// be registered.
//
// ----------------------------------------------------------------------------
// TWO PARALLEL CALL PATHS
// ----------------------------------------------------------------------------
//   JSON path (convenience):
//       T Call<T>(targetApp, apiName, payload, timeoutMs?)
//       string CallRaw(targetApp, apiName, payload, timeoutMs)
//       bool TryCall<T>(targetApp, apiName, payload, timeoutMs?, out T?)
//       bool TryCallRaw(targetApp, apiName, payload, timeoutMs, out string?)
//       void Notify(targetApp, apiName, payload)
//       void SequencedNotify(targetApp, apiName, payload)
//
//   ABI path (raw):
//       DataHandle CallBinary(targetApp, request, timeoutMs?)
//       bool TryCallBinary(targetApp, request, timeoutMs?, out response)
//       void NotifyBinary(targetApp, request)
//       void SequencedNotifyBinary(targetApp, request)
//
// For registering the server's OWN APIs:
//
//   JSON:  App.Expose<TResult>(...) / App.Expose<TArg, TResult>(...) /
//          App.Expose<T1, T2, TResult>(...) / App.ExposeNotify<TArg>(...)
//   ABI:   App.Expose(apiName, desc, Action<DataHandle, DataHandle>) /
//          App.ExposeNotify(apiName, desc, Action<DataHandle>)
//
// The Try* variants treat "the peer did not respond" (timeout,
// unreachable target, unregistered API) as an ordinary boolean false
// return, mirroring the C++ / Python tryCall semantics. Argument errors
// and invalid object state still throw.
//
// ----------------------------------------------------------------------------
// LIFECYCLE
// ----------------------------------------------------------------------------
// Start() performs the full preparation sequence in one call:
//     ResetPrepare -> PrepareService -> PrepareClient -> PrepareDone
//
// Stop(fullCleanup: false) stops the network loop but leaves the App
// intact and the framework running. A subsequent Start() on the same
// instance re-prepares the endpoint.
//
// Stop(fullCleanup: true) additionally calls LF_Shutdown, which stops
// the framework process-wide and destroys every native App. The
// instance is invalidated; create a new LingoFuseServer to reinitialise.
//
// Dispose() releases the instance's own resources without calling
// LF_Shutdown. Other hosts in the same process are unaffected.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentException                  a required string argument is
//                                        null or empty
//     ArgumentNullException              a required reference argument
//                                        is null
//     LingoFuseObjectDisposedException   the server has been disposed or
//                                        fully cleaned up
//     LingoFuseStateException            the server is not running, or
//                                        Start() was called twice without
//                                        an intervening Stop()
//     LingoFuseCallException             a throwing remote-call method
//                                        failed
//     LingoFuseException                 JSON serialization or
//                                        deserialization failed on a
//                                        throwing remote-call method
//
// The Try* methods never throw for a failed remote call. They still
// throw for the four argument / state conditions listed above.
// ============================================================================

using System;

using LingoFuse.Core;
using LingoFuse.Diagnostics;
using LingoFuse.Io;
using LingoFuse.Native;

namespace LingoFuse.Host;

/// <summary>
/// High-level server host that manages both the service endpoint and
/// the local application.
/// </summary>
public sealed class LingoFuseServer : IDisposable
{
    private readonly LingoFuseApp _app;
    private readonly string _endpoint;
    private readonly string _publicEndpoint;
    private readonly ulong _defaultTimeoutMs;
    private bool _running;
    private bool _disposed;

    /// <summary>
    /// Creates a new server host.
    /// </summary>
    /// <param name="appName">
    /// Application name. Must not be null or empty.
    /// </param>
    /// <param name="endpoint">
    /// Local listening endpoint, for example <c>ipc:calc</c>. Must not
    /// be null or empty.
    /// </param>
    /// <param name="description">
    /// Optional description. A null value is treated as an empty
    /// string.
    /// </param>
    /// <param name="publicEndpoint">
    /// Advertised endpoint. Defaults to <paramref name="endpoint"/>.
    /// </param>
    /// <param name="defaultTimeoutMs">
    /// Default timeout applied to outbound calls whose caller does not
    /// specify one.
    /// </param>
    /// <exception cref="ArgumentException">
    /// Thrown when <paramref name="appName"/> or <paramref name="endpoint"/>
    /// is null or empty.
    /// </exception>
    public LingoFuseServer(
        string appName,
        string endpoint,
        string description = "",
        string? publicEndpoint = null,
        ulong defaultTimeoutMs = 5000)
    {
        if (string.IsNullOrEmpty(appName))
        {
            throw new ArgumentException(
                "Application name must not be empty.", nameof(appName));
        }
        if (string.IsNullOrEmpty(endpoint))
        {
            throw new ArgumentException(
                "Endpoint must not be empty.", nameof(endpoint));
        }

        _app = new LingoFuseApp(appName, description);
        _endpoint = endpoint;
        _publicEndpoint = publicEndpoint ?? endpoint;
        _defaultTimeoutMs = defaultTimeoutMs;
    }

    /// <summary>Underlying application container.</summary>
    public LingoFuseApp App => _app;

    /// <summary>Local listening endpoint.</summary>
    public string Endpoint => _endpoint;

    /// <summary>Advertised endpoint.</summary>
    public string PublicEndpoint => _publicEndpoint;

    /// <summary>
    /// Default timeout, in milliseconds, applied to outbound calls
    /// whose caller does not specify one.
    /// </summary>
    public ulong DefaultTimeoutMs => _defaultTimeoutMs;

    /// <summary>
    /// True while the framework is prepared and the main thread is
    /// active.
    /// </summary>
    public bool IsRunning => _running && !_disposed;

    /// <summary>
    /// True while the server instance is usable: not disposed and not
    /// invalidated by a full cleanup.
    /// </summary>
    public bool IsValid => !_disposed;

    // ====================================================================
    // Lifecycle
    // ====================================================================

    /// <summary>
    /// Performs the full startup sequence. Safe to call multiple times
    /// provided each Start() is paired with a prior Stop(fullCleanup:
    /// false).
    /// </summary>
    /// <param name="overlapConnection">
    /// When true, enables the native <c>Overlap_Connection</c> option
    /// so that multiple clients may share the same endpoint. Required
    /// when the process also acts as a client on the same address.
    /// </param>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed or invalidated by a
    /// previous Stop(fullCleanup: true).
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is already running, the endpoint is
    /// rejected by the native layer, or the framework fails to start.
    /// </exception>
    public void Start(bool overlapConnection = false)
    {
        EnsureNotDisposed();
        if (_running)
        {
            throw new LingoFuseStateException(
                "Server is already running. Call Stop() first.");
        }

        if (overlapConnection)
        {
            LingoFuseRuntime.SetOption("Overlap_Connection", "True");
        }

        NativeMethods.LF_ResetPrepare();

        PrepareService();
        PrepareClient();

        int done = NativeMethods.LF_PrepareDone();
        if (done != 1 && !LingoFuseStatus.CheckMainThread())
        {
            throw new LingoFuseStateException(
                $"LF_PrepareDone returned {done} and the main thread is " +
                "not running.");
        }

        LingoFuseRuntime.MarkStarted();
        _running = true;
    }

    /// <summary>
    /// Stops the network loop.
    /// </summary>
    /// <param name="fullCleanup">
    /// When true, also calls LF_Shutdown to release all native
    /// resources process-wide. After a full cleanup the instance is
    /// invalidated and must not be reused.
    ///
    /// When false (the default), the App handle remains valid and the
    /// framework continues to run; other hosts in the same process are
    /// unaffected, and Start() may be called again on this instance.
    /// </param>
    /// <remarks>
    /// Safe to call multiple times. A call on a server that is not
    /// running is a no-op.
    /// </remarks>
    public void Stop(bool fullCleanup = false)
    {
        if (!_running)
        {
            return;
        }

        NativeMethods.LF_ExitMainThread();
        _running = false;

        if (fullCleanup)
        {
            NativeMethods.LF_Shutdown();
            LingoFuseRuntime.MarkStopped();
            _app.Dispose();
            _disposed = true;
        }
    }

    /// <summary>
    /// Convenience wrapper for <c>Stop(fullCleanup: true)</c>.
    /// </summary>
    /// <remarks>
    /// After a full cleanup the server instance is invalidated; create
    /// a new instance to reinitialise the framework.
    /// </remarks>
    public void FullCleanup() => Stop(fullCleanup: true);

    // ====================================================================
    // Outbound invocation — JSON path (throwing)
    // ====================================================================

    /// <summary>
    /// Performs a synchronous Call to a remote application and
    /// deserialises the response as <typeparamref name="T"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the call fails.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the response payload cannot be deserialised.
    /// </exception>
    public T? Call<T>(
        string targetApp,
        string apiName,
        object? payload = null,
        ulong? timeoutMs = null)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);

        string json = CallRaw(
            targetApp, apiName, payload, timeoutMs ?? _defaultTimeoutMs);
        return JsonPolicy.Loads<T>(json);
    }

    /// <summary>
    /// Performs a synchronous Call and returns the raw JSON response.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the call fails.
    /// </exception>
    public string CallRaw(
        string targetApp,
        string apiName,
        object? payload,
        ulong timeoutMs)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureRunning();

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);

        IntPtr appNamePtr = Utf8Marshal.Alloc(targetApp);
        try
        {
            DataHnd resultRaw = NativeMethods.LF_Call(
                appNamePtr,
                new DataHnd { Handle = request.Raw },
                timeoutMs);

            if (!resultRaw.IsValid)
            {
                throw new LingoFuseCallException(
                    "LF_Call returned a null handle.",
                    targetApp, apiName);
            }

            using var response = DataHandle.FromRaw(resultRaw.Handle, owned: true);
            if (response.Size == 0)
            {
                throw new LingoFuseCallException(
                    "LF_Call timed out or the target application is " +
                    "unreachable.",
                    targetApp, apiName);
            }

            return LfIo.ReadString(response);
        }
        finally
        {
            Utf8Marshal.Free(appNamePtr);
        }
    }

    // ====================================================================
    // Outbound invocation — JSON path (non-throwing)
    // ====================================================================

    /// <summary>
    /// Non-throwing variant of <see cref="Call{T}"/>. Returns true when
    /// the call succeeded AND the response deserialised as
    /// <typeparamref name="T"/>; false on timeout, unreachable target,
    /// empty reply, or JSON deserialisation failure.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    public bool TryCall<T>(
        string targetApp,
        string apiName,
        object? payload,
        ulong? timeoutMs,
        out T? result)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);

        result = default;

        if (!TryCallRaw(
                targetApp,
                apiName,
                payload,
                timeoutMs ?? _defaultTimeoutMs,
                out string? json))
        {
            return false;
        }

        return JsonPolicy.TryLoads(json!, out result);
    }

    /// <summary>
    /// Convenience overload of <see cref="TryCall{T}"/> with a null
    /// payload and the server's default timeout.
    /// </summary>
    public bool TryCall<T>(
        string targetApp,
        string apiName,
        out T? result)
        => TryCall(targetApp, apiName, payload: null, timeoutMs: null, out result);

    /// <summary>
    /// Non-throwing variant of <see cref="CallRaw"/>. Returns true when
    /// the call produced a non-empty response; false on timeout,
    /// unreachable target, or an explicit empty reply.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    public bool TryCallRaw(
        string targetApp,
        string apiName,
        object? payload,
        ulong timeoutMs,
        out string? result)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);

        result = null;
        EnsureRunning();

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);

        IntPtr appNamePtr = Utf8Marshal.Alloc(targetApp);
        try
        {
            DataHnd resultRaw = NativeMethods.LF_Call(
                appNamePtr,
                new DataHnd { Handle = request.Raw },
                timeoutMs);

            if (!resultRaw.IsValid)
            {
                return false;
            }

            using var response = DataHandle.FromRaw(resultRaw.Handle, owned: true);
            if (response.Size == 0)
            {
                return false;
            }

            result = LfIo.ReadString(response);
            return true;
        }
        finally
        {
            Utf8Marshal.Free(appNamePtr);
        }
    }

    // ====================================================================
    // Outbound invocation — Notify
    // ====================================================================

    /// <summary>Sends a one-way Notify to a remote application.</summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    public void Notify(
        string targetApp,
        string apiName,
        object? payload = null)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureRunning();

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);

        IntPtr appNamePtr = Utf8Marshal.Alloc(targetApp);
        try
        {
            NativeMethods.LF_Notify(
                appNamePtr,
                new DataHnd { Handle = request.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appNamePtr);
        }
    }

    /// <summary>Sends a FIFO-ordered Sequenced Notify.</summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    public void SequencedNotify(
        string targetApp,
        string apiName,
        object? payload = null)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureRunning();

        using var request = new DataHandle(apiName);
        LfIo.WriteJson(request, payload);

        IntPtr appNamePtr = Utf8Marshal.Alloc(targetApp);
        try
        {
            NativeMethods.LF_Sequenced_Notify(
                appNamePtr,
                new DataHnd { Handle = request.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appNamePtr);
        }
    }

    // ====================================================================
    // Outbound invocation — ABI path
    // ====================================================================

    /// <summary>
    /// Performs a synchronous ABI-level Call. No JSON serialization is
    /// involved at any point.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="request"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the call fails.
    /// </exception>
    public DataHandle CallBinary(
        string targetApp,
        DataHandle request,
        ulong? timeoutMs = null)
    {
        if (!TryCallBinary(targetApp, request, timeoutMs, out var response))
        {
            throw new LingoFuseCallException(
                "LF_Call returned an empty or null response " +
                "(timeout, unreachable target, or explicit empty reply).",
                targetApp,
                targetApi: null);
        }
        return response!;
    }

    /// <summary>
    /// Non-throwing variant of <see cref="CallBinary"/>. Returns true
    /// when the remote call produced a non-empty response handle;
    /// false on timeout, unreachable target, or an empty reply.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="request"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    public bool TryCallBinary(
        string targetApp,
        DataHandle request,
        ulong? timeoutMs,
        out DataHandle? response)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(request);

        response = null;
        EnsureRunning();

        IntPtr appNamePtr = Utf8Marshal.Alloc(targetApp);
        try
        {
            DataHnd resultRaw = NativeMethods.LF_Call(
                appNamePtr,
                new DataHnd { Handle = request.Raw },
                timeoutMs ?? _defaultTimeoutMs);

            if (!resultRaw.IsValid)
            {
                return false;
            }

            var handle = DataHandle.FromRaw(resultRaw.Handle, owned: true);
            if (handle.Size == 0)
            {
                handle.Dispose();
                return false;
            }

            response = handle;
            return true;
        }
        finally
        {
            Utf8Marshal.Free(appNamePtr);
        }
    }

    /// <summary>
    /// Sends a one-way ABI-level notification. No JSON serialization is
    /// performed.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="request"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    public void NotifyBinary(string targetApp, DataHandle request)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(request);
        EnsureRunning();

        IntPtr appNamePtr = Utf8Marshal.Alloc(targetApp);
        try
        {
            NativeMethods.LF_Notify(
                appNamePtr,
                new DataHnd { Handle = request.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appNamePtr);
        }
    }

    /// <summary>
    /// Sends a FIFO-ordered ABI-level notification. No JSON
    /// serialization is performed.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="request"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the server has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the server is not running.
    /// </exception>
    public void SequencedNotifyBinary(string targetApp, DataHandle request)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(request);
        EnsureRunning();

        IntPtr appNamePtr = Utf8Marshal.Alloc(targetApp);
        try
        {
            NativeMethods.LF_Sequenced_Notify(
                appNamePtr,
                new DataHnd { Handle = request.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appNamePtr);
        }
    }

    // ====================================================================
    // Lifetime
    // ====================================================================

    /// <summary>
    /// Releases the instance's own resources without calling
    /// LF_Shutdown. Other hosts in the same process are unaffected.
    /// </summary>
    /// <remarks>
    /// Safe to call multiple times. If the server is running, this
    /// stops the network loop first. To fully unload the native
    /// library, call <see cref="Stop"/> with <c>fullCleanup: true</c>
    /// or <see cref="FullCleanup"/> before disposing.
    /// </remarks>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (_running)
        {
            NativeMethods.LF_ExitMainThread();
            _running = false;
        }

        _app.Dispose();
        _disposed = true;
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    private void PrepareService()
    {
        IntPtr listenPtr = Utf8Marshal.Alloc(_endpoint);
        IntPtr physicsPtr = Utf8Marshal.Alloc(_publicEndpoint);
        try
        {
            int tag = NativeMethods.LF_PrepareService(listenPtr, physicsPtr);
            if (tag == -1)
            {
                throw new LingoFuseStateException(
                    $"LF_PrepareService returned -1 for endpoint " +
                    $"'{_endpoint}'.");
            }
        }
        finally
        {
            Utf8Marshal.Free(listenPtr);
            Utf8Marshal.Free(physicsPtr);
        }
    }

    private void PrepareClient()
    {
        IntPtr endpointPtr = Utf8Marshal.Alloc(_endpoint);
        try
        {
            var appHnd = new AppHnd { Handle = _app.Raw };
            int tag = NativeMethods.LF_PrepareClient(endpointPtr, appHnd);
            if (tag == -1)
            {
                throw new LingoFuseStateException(
                    $"LF_PrepareClient returned -1 for endpoint " +
                    $"'{_endpoint}'. Set overlapConnection: true when " +
                    "sharing the address.");
            }
        }
        finally
        {
            Utf8Marshal.Free(endpointPtr);
        }
    }

    private void EnsureNotDisposed()
    {
        if (_disposed)
        {
            throw new LingoFuseObjectDisposedException(nameof(LingoFuseServer));
        }
    }

    private void EnsureRunning()
    {
        EnsureNotDisposed();
        if (!_running)
        {
            throw new LingoFuseStateException(
                "Server is not running. Call Start() first.");
        }
    }
}