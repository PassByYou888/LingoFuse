// ============================================================================
// LingoFuseNode — compute worker that exposes its own APIs and can call
// remote APIs.
// ============================================================================
//
// Connects to an existing beacon, exposes its own application, and can
// both receive inbound calls (through the APIs registered on its app)
// and issue outbound calls to other applications in the mesh.
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
// Use LingoFuseNode when a coordinator (started by LingoFuseServer or
// equivalent) already exists and this process only registers APIs on it.
//
// Compared with LingoFuseServer, a node:
//   - does NOT create a service endpoint;
//   - does NOT expose a public address;
//   - only calls LF_ResetPrepare / LF_PrepareClient / LF_PrepareDone
//     when the framework is not yet started in this process.
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
// For registering the node's OWN APIs:
//
//   JSON:  App.Expose<TResult>(...) / App.Expose<TArg, TResult>(...) /
//          App.Expose<T1, T2, TResult>(...) / App.ExposeNotify<TArg>(...)
//   ABI:   App.Expose(apiName, desc, Action<DataHandle, DataHandle>) /
//          App.ExposeNotify(apiName, desc, Action<DataHandle>)
//
// ----------------------------------------------------------------------------
// LIFETIME
// ----------------------------------------------------------------------------
// Two operations are available at the end of a node's life:
//
//   Dispose()      — Detach this node's App from the framework and
//                    release the App handle. The framework itself
//                    stays running so that other hosts in the same
//                    process continue to work.
//
//   FullCleanup()  — Detach this node AND release every native
//                    resource held by the framework process-wide.
//                    Equivalent to Dispose() followed by
//                    LingoFuseFramework.Shutdown().
//
// {!!!!!  CHOOSING BETWEEN Dispose AND FullCleanup  !!!!!}
//
//   If the process hosts only a LingoFuseNode, or if this node is the
//   last remaining host, use FullCleanup() at process exit.
//
//   If the process also hosts a LingoFuseServer, a LingoFuseClient or
//   another LingoFuseNode, use Dispose() so that the other hosts are
//   not torn down underneath them.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentException                  a required string argument is
//                                        null or empty
//     ArgumentNullException              a required reference argument
//                                        is null
//     LingoFuseObjectDisposedException   the node has been disposed
//     LingoFuseStateException            the node is not connected, or
//                                        Connect() was called twice
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
/// Compute worker that exposes its own application and can invoke
/// remote applications in the same mesh.
/// </summary>
public sealed class LingoFuseNode : IDisposable
{
    private readonly LingoFuseApp _app;
    private readonly string _endpoint;
    private readonly ulong _defaultTimeoutMs;
    private bool _connected;
    private bool _disposed;

    /// <summary>
    /// Creates a new node.
    /// </summary>
    /// <param name="appName">
    /// Application name. Must not be null or empty. This name is used
    /// for routing inbound calls and must be unique on the mesh.
    /// </param>
    /// <param name="endpoint">
    /// Beacon endpoint to connect to, for example
    /// <c>ipc:compute_grid</c>. Must not be null or empty.
    /// </param>
    /// <param name="description">
    /// Optional description. A null value is treated as an empty
    /// string.
    /// </param>
    /// <param name="defaultTimeoutMs">
    /// Default timeout applied to outbound calls whose caller does not
    /// specify one.
    /// </param>
    /// <exception cref="ArgumentException">
    /// Thrown when <paramref name="appName"/> or <paramref name="endpoint"/>
    /// is null or empty.
    /// </exception>
    public LingoFuseNode(
        string appName,
        string endpoint,
        string description = "",
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
        _defaultTimeoutMs = defaultTimeoutMs;
    }

    /// <summary>Underlying application container.</summary>
    public LingoFuseApp App => _app;

    /// <summary>Beacon endpoint this node connects to.</summary>
    public string Endpoint => _endpoint;

    /// <summary>
    /// Default timeout, in milliseconds, applied to outbound calls
    /// whose caller does not specify one.
    /// </summary>
    public ulong DefaultTimeoutMs => _defaultTimeoutMs;

    /// <summary>
    /// True while the framework is prepared and the node is registered.
    /// </summary>
    public bool IsConnected => _connected && !_disposed;

    /// <summary>True while the node is not disposed.</summary>
    public bool IsValid => !_disposed;

    // ====================================================================
    // Connection
    // ====================================================================

    /// <summary>
    /// Connects the node to the beacon and registers its application on
    /// the mesh. Safe to call only once per instance.
    /// </summary>
    /// <param name="overlapConnection">
    /// When true, enables the native <c>Overlap_Connection</c> option
    /// so that the same endpoint may be shared with other clients in
    /// the same process. Required when multiple nodes coexist on the
    /// same address.
    /// </param>
    /// <exception cref="LingoFuseObjectDisposedException">
    /// Thrown when the node has been disposed.
    /// </exception>
    /// <exception cref="LingoFuseStateException">
    /// Thrown when the node is already connected, the endpoint is
    /// rejected by the native layer, or the framework fails to start.
    /// </exception>
    public void Connect(bool overlapConnection = false)
    {
        EnsureNotDisposed();
        if (_connected)
        {
            throw new LingoFuseStateException(
                "Node is already connected.");
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
    /// Performs a synchronous Call and returns the raw JSON response.
    /// </summary>
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
    /// payload and the node's default timeout.
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

    /// <summary>Sends a one-way Notify to a remote application.</summary>
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

    /// <summary>Sends a FIFO-ordered Sequenced Notify.</summary>
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
    /// Disconnects this node and releases its application handle. The
    /// framework itself remains running so that any other host in the
    /// same process can continue to operate.
    /// </summary>
    /// <remarks>
    /// Use this method when the process hosts other LingoFuse
    /// instances that must continue to operate after this node is
    /// gone. If this node is the last host, prefer
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
        _app.Dispose();
        _disposed = true;
    }

    /// <summary>
    /// Disconnects this node AND releases the LingoFuse framework
    /// process-wide. Equivalent to <see cref="Dispose"/> followed by
    /// <see cref="LingoFuseFramework.Shutdown"/>.
    /// </summary>
    /// <remarks>
    /// {!!!!!  PROCESS-WIDE EFFECT  !!!!!}
    ///
    /// Calling this method stops the simulated main thread and releases
    /// every native resource held by the framework, including every
    /// App object owned by any LingoFuseServer or LingoFuseClient in
    /// the same process. Use it only when this node is the last
    /// LingoFuse host in the process, or when the process is about to
    /// exit.
    ///
    /// Safe to call multiple times. After the first call, the framework
    /// is fully shut down and this node is disposed.
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
            var appHnd = new AppHnd { Handle = _app.Raw };
            int tag = NativeMethods.LF_PrepareClient(endpointPtr, appHnd);
            if (tag == -1)
            {
                throw new LingoFuseStateException(
                    $"LF_PrepareClient returned -1 for endpoint " +
                    $"'{_endpoint}'. Set overlapConnection: true when " +
                    "sharing the address with another client in the " +
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
            throw new LingoFuseObjectDisposedException(nameof(LingoFuseNode));
        }
    }

    private void EnsureConnected()
    {
        EnsureNotDisposed();
        if (!_connected)
        {
            throw new LingoFuseStateException(
                "Node is not connected. Call Connect() first.");
        }
    }
}