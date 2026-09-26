// ============================================================================
// LingoFuseClient — pure consumer client.
// ============================================================================
//
// Connects to an existing endpoint as a pure consumer. Hosts no service
// and exposes no application. Use it when the process only needs to
// invoke remote APIs.
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
// A host that does not own an App cannot register APIs. Use
// LingoFuseServer or LingoFuseNode when the process must receive calls.
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
// ----------------------------------------------------------------------------
// CONNECTION MODEL
// ----------------------------------------------------------------------------
// The connection is process-global. A client that connects while the
// framework is already running attaches itself to the running framework
// without touching the preparation queue. A client that connects first
// performs the full preparation sequence.
//
// ----------------------------------------------------------------------------
// LIFETIME
// ----------------------------------------------------------------------------
// Two operations are available at the end of a client's life:
//
//   Dispose()      — Detach this client from the framework. The
//                    framework stays running so that other hosts in the
//                    same process continue to work. This is the
//                    correct choice when other hosts will keep using
//                    the framework after the client is gone.
//
//   FullCleanup()  — Detach this client AND release every native
//                    resource held by the framework process-wide. Use
//                    this only when this client is the last host in
//                    the process, or when the process is about to
//                    exit. Equivalent to calling
//                    LingoFuseFramework.Shutdown() after Dispose().
//
// {!!!!!  CHOOSING BETWEEN Dispose AND FullCleanup  !!!!!}
//
//   If the process hosts only a LingoFuseClient, or if this client is
//   the last remaining host, use FullCleanup() at process exit so that
//   the simulated main thread stops and the native library can be
//   unloaded.
//
//   If the process also hosts a LingoFuseServer, LingoFuseNode or
//   another LingoFuseClient, use Dispose() so that the other hosts are
//   not torn down underneath them. Release the framework itself via
//   LingoFuseFramework.Shutdown() (or the server's FullCleanup) once
//   every host is done.
//
// The client does not define a finalizer. Detaching from a finalizer
// thread would race with other hosts; the caller is expected to call
// Dispose or FullCleanup explicitly.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException              a required reference argument
//                                        is null
//     ArgumentException                  a required string argument is
//                                        null or empty
//     LingoFuseObjectDisposedException   the client has been disposed
//     LingoFuseStateException            the client is not connected,
//                                        or Connect() was called twice
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
/// Pure consumer client for the LingoFuse mesh.
/// </summary>
public sealed class LingoFuseClient : IDisposable
{
    private readonly string _endpoint;
    private readonly ulong _defaultTimeoutMs;
    private bool _connected;
    private bool _disposed;

    /// <summary>
    /// Creates a new consumer client.
    /// </summary>
    /// <param name="endpoint">
    /// Endpoint of the beacon / service to connect to. Must not be null
    /// or empty.
    /// </param>
    /// <param name="defaultTimeoutMs">
    /// Default timeout applied to outbound calls whose caller does not
    /// specify one. A value of zero is allowed and means "wait
    /// indefinitely", matching the native layer's semantics.
    /// </param>
    /// <exception cref="ArgumentException">
    /// Thrown when <paramref name="endpoint"/> is null or empty.
    /// </exception>
    public LingoFuseClient(string endpoint, ulong defaultTimeoutMs = 5000)
    {
        if (string.IsNullOrEmpty(endpoint))
        {
            throw new ArgumentException(
                "Endpoint must not be empty.", nameof(endpoint));
        }

        _endpoint = endpoint;
        _defaultTimeoutMs = defaultTimeoutMs;
    }

    /// <summary>The endpoint this client connects to.</summary>
    public string Endpoint => _endpoint;

    /// <summary>
    /// Default timeout, in milliseconds, applied to outbound calls
    /// whose caller does not specify one.
    /// </summary>
    public ulong DefaultTimeoutMs => _defaultTimeoutMs;

    /// <summary>
    /// True while the client is connected and not yet disposed.
    /// </summary>
    public bool IsConnected => _connected && !_disposed;

    /// <summary>True while the client is not disposed.</summary>
    public bool IsValid => !_disposed;

    // ====================================================================
    // Connection
    // ====================================================================

    /// <summary>
    /// Prepares the framework if necessary and connects to the endpoint.
    /// Safe to call only once per instance.
    /// </summary>
    /// <param name="overlapConnection">
    /// When true, enables the native <c>Overlap_Connection</c> option
    /// so that the same endpoint may be reused by another client in
    /// the same process. Required when multiple clients coexist on the
    /// same address.
    /// </param>
    /// <remarks>
    /// When the framework is already running in this process (started
    /// by a server or another host), the client attaches to it without
    /// touching the preparation queue. Otherwise, the client performs
    /// the full preparation sequence.
    /// </remarks>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the client has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the client is already connected, the endpoint is
    /// rejected by the native layer, or the framework fails to start.
    /// </exception>
    public void Connect(bool overlapConnection = false)
    {
        EnsureNotDisposed();
        if (_connected)
        {
            throw new LingoFuseStateException(
                "Client is already connected.");
        }

        if (overlapConnection)
        {
            LingoFuseRuntime.SetOption("Overlap_Connection", "True");
        }

        if (LingoFuseRuntime.IsStarted)
        {
            RegisterClient();
        }
        else
        {
            NativeMethods.LF_ResetPrepare();
            RegisterClient();

            int done = NativeMethods.LF_PrepareDone();
            if (done != 1 && !LingoFuseStatus.CheckMainThread())
            {
                throw new LingoFuseStateException(
                    $"LF_PrepareDone returned {done} and the main thread " +
                    "is not running.");
            }

            LingoFuseRuntime.MarkStarted();
        }

        _connected = true;
    }

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
    /// Thrown when the client has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the client is not connected.
    /// </exception>
    /// <exception cref="LingoFuseCallException">
    /// Thrown when the call times out, the target is unreachable, or
    /// the remote handler returned no payload.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the response payload cannot be deserialised as
    /// <typeparamref name="T"/>.
    /// </exception>
    public T Call<T>(
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
    /// Performs a synchronous Call and returns the raw JSON response
    /// as a string.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
    /// </exception>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the client has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the client is not connected.
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
        EnsureConnected();

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
    /// Non-throwing variant of <see cref="Call{T}"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="targetApp"/> or <paramref name="apiName"/>
    /// is null.
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
    /// payload and the client's default timeout.
    /// </summary>
    public bool TryCall<T>(
        string targetApp,
        string apiName,
        out T? result)
        => TryCall(targetApp, apiName, payload: null, timeoutMs: null, out result);

    /// <summary>
    /// Non-throwing variant of <see cref="CallRaw"/>.
    /// </summary>
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
        EnsureConnected();

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

    /// <summary>
    /// Sends a one-way Notify to a remote application. Delivery order
    /// is not guaranteed; use <see cref="SequencedNotify"/> when FIFO
    /// ordering is required.
    /// </summary>
    public void Notify(
        string targetApp,
        string apiName,
        object? payload = null)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureConnected();

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

    /// <summary>
    /// Sends a FIFO-ordered Sequenced Notify.
    /// </summary>
    public void SequencedNotify(
        string targetApp,
        string apiName,
        object? payload = null)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(apiName);
        EnsureConnected();

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
    /// Performs a synchronous ABI-level Call.
    /// </summary>
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
    /// Non-throwing variant of <see cref="CallBinary"/>.
    /// </summary>
    public bool TryCallBinary(
        string targetApp,
        DataHandle request,
        ulong? timeoutMs,
        out DataHandle? response)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(request);

        response = null;
        EnsureConnected();

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
    /// Sends a one-way ABI-level notification.
    /// </summary>
    public void NotifyBinary(string targetApp, DataHandle request)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(request);
        EnsureConnected();

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
    /// Sends a FIFO-ordered ABI-level notification.
    /// </summary>
    public void SequencedNotifyBinary(string targetApp, DataHandle request)
    {
        ArgumentNullException.ThrowIfNull(targetApp);
        ArgumentNullException.ThrowIfNull(request);
        EnsureConnected();

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
    /// Disconnects this client from the framework. Other hosts in the
    /// same process are unaffected; the framework stays running.
    /// </summary>
    /// <remarks>
    /// Use this method when the process hosts other LingoFuse
    /// instances that must continue to operate after this client is
    /// gone. If this client is the last host, prefer
    /// <see cref="FullCleanup"/> so that the native framework is
    /// released.
    ///
    /// Safe to call multiple times. After the first call, all methods
    /// that require a live connection throw
    /// <see cref="LingoFuseObjectDisposedException"/>.
    /// </remarks>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _connected = false;
        _disposed = true;
    }

    /// <summary>
    /// Disconnects this client AND releases the LingoFuse framework
    /// process-wide. Equivalent to <see cref="Dispose"/> followed by
    /// <see cref="LingoFuseFramework.Shutdown"/>.
    /// </summary>
    /// <remarks>
    /// {!!!!!  PROCESS-WIDE EFFECT  !!!!!}
    ///
    /// Calling this method stops the simulated main thread and releases
    /// every native resource held by the framework, including every
    /// App object owned by any LingoFuseServer or LingoFuseNode in the
    /// same process. Use it only when this client is the last LingoFuse
    /// host in the process, or when the process is about to exit.
    ///
    /// Safe to call multiple times. After the first call, the framework
    /// is fully shut down and this client is disposed.
    /// </remarks>
    public void FullCleanup()
    {
        Dispose();
        LingoFuseFramework.Shutdown();
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    private void RegisterClient()
    {
        IntPtr endpointPtr = Utf8Marshal.Alloc(_endpoint);
        try
        {
            int tag = NativeMethods.LF_PrepareClient(
                endpointPtr, AppHnd.Null);
            if (tag == -1)
            {
                throw new LingoFuseStateException(
                    $"LF_PrepareClient returned -1 for endpoint " +
                    $"'{_endpoint}'. Use Connect(overlapConnection: true) " +
                    "when sharing the address with another client in the " +
                    "same process.");
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
            throw new LingoFuseObjectDisposedException(nameof(LingoFuseClient));
        }
    }

    private void EnsureConnected()
    {
        EnsureNotDisposed();
        if (!_connected)
        {
            throw new LingoFuseStateException(
                "Client is not connected. Call Connect() first.");
        }
    }
}