using System;
using System.Diagnostics;

using LingoFuse.Native;

namespace LingoFuse;

// ============================================================================
// Framework — the direct ABI façade for the LingoFuse native library.
// ============================================================================
//
// This class is the public entry point for every process-wide operation
// that the native library exposes but that does not fit the DataHandle
// or AppHandle abstractions:
//
//   - Network preparation (reset / prepare service / prepare client /
//     prepare done / exit main thread).
//   - Remote invocation (call / try call / notify / sequenced notify).
//   - Runtime options (set option).
//   - Application name generation and query.
//   - Process-wide shutdown.
//
// This file exists because NativeMethods is internal: the public layer
// must present each native export through a managed signature that
// handles UTF-8 marshalling, argument validation, and the ownership
// transfer of any DataHnd returned by the native side.
//
// The class is a thin façade. It performs no caching, no state
// management, and no lifecycle coordination. Every method forwards to
// exactly one native function. Callers who need to know the precise
// native semantics should read the corresponding XML documentation on
// the NativeMethods declaration.
//
// CALLBACK ERROR REPORTING
// ------------------------
// Callback bodies registered through AppHandle and NetworkEvents run on
// native worker threads. An exception escaping such a body would cross
// into the C stack and could destabilise the process, so every callback
// is wrapped to swallow exceptions.
//
// The wrapper reports every swallowed exception through two channels:
//
//   1. CallbackErrorHandler, if the application installed one. This is
//      the intended integration point for a real logging pipeline
//      (Serilog, NLog, Microsoft.Extensions.Logging, ...).
//
//   2. Trace.WriteLine, unconditionally. This is a debugger-visible
//      sink that is active in Release builds, unlike Debug.WriteLine.
//
// The handler is optional. A failure inside the handler itself is
// swallowed, so a broken logger cannot crash the process.
//
// ============================================================================

/// <summary>
/// Public façade over the process-wide LingoFuse native functions.
/// </summary>
public static class Framework
{
    // ====================================================================
    // Callback error reporting
    // ====================================================================

    /// <summary>
    /// Optional handler invoked when a user callback raises an
    /// unhandled exception. The first argument is a short identifier
    /// for the callback site (for example
    /// "AppHandle.RegisterCall[add]" or "NetworkEvents.Connect"); the
    /// second is the exception.
    /// </summary>
    /// <remarks>
    /// Setting this property is optional. When it is null, swallowed
    /// exceptions are still reported through
    /// <see cref="System.Diagnostics.Trace"/>, but no application-level
    /// sink receives them.
    ///
    /// An exception raised by the handler itself is swallowed by the
    /// framework, so a broken logging pipeline cannot destabilise a
    /// native worker thread.
    /// </remarks>
    public static Action<string, Exception>? CallbackErrorHandler { get; set; }

    /// <summary>
    /// Internal bridge used by AppHandle and NetworkEvents to report a
    /// swallowed callback exception.
    /// </summary>
    internal static void ReportCallbackError(string source, Exception ex)
    {
        try
        {
            CallbackErrorHandler?.Invoke(source, ex);
        }
        catch
        {
            // A handler that throws must not be allowed to escape into
            // the native worker thread. Drop the secondary failure.
        }

        // Trace is active in Release builds, unlike Debug. This gives
        // every swallowed exception a default visible sink without
        // requiring the application to install a handler.
        Trace.WriteLine($"[LingoFuse] Callback error in {source}: {ex}");
    }

    // ====================================================================
    // Network preparation
    // ====================================================================

    /// <summary>
    /// Clears any previously prepared services and clients. Running
    /// services and clients are not affected.
    /// </summary>
    public static void ResetPrepare()
        => NativeMethods.LF_ResetPrepare();

    /// <summary>
    /// Prepares a C4 service listening on <paramref name="listeningAddr"/>
    /// and advertised as <paramref name="physicsAddr"/>.
    /// </summary>
    /// <param name="listeningAddr">
    /// Local binding address, for example <c>0.0.0.0:9898</c> or
    /// <c>ipc:my_service</c>. Must not be null.
    /// </param>
    /// <param name="physicsAddr">
    /// Address advertised to clients. Must not be null.
    /// </param>
    /// <returns>
    /// An internal tag on success, or -1 for a duplicate address.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when either argument is null.
    /// </exception>
    public static int PrepareService(string listeningAddr, string physicsAddr)
    {
        ArgumentNullException.ThrowIfNull(listeningAddr);
        ArgumentNullException.ThrowIfNull(physicsAddr);

        IntPtr listenPtr = Utf8Marshal.Alloc(listeningAddr);
        IntPtr physicsPtr = Utf8Marshal.Alloc(physicsAddr);
        try
        {
            return NativeMethods.LF_PrepareService(listenPtr, physicsPtr);
        }
        finally
        {
            Utf8Marshal.Free(listenPtr);
            Utf8Marshal.Free(physicsPtr);
        }
    }

    /// <summary>
    /// Prepares a C4 client connecting to <paramref name="physicsAddr"/>
    /// and, optionally, exposing <paramref name="app"/> on the mesh.
    /// </summary>
    /// <param name="physicsAddr">
    /// Address of the target service. Must not be null.
    /// </param>
    /// <param name="app">
    /// Application to expose, or null for a pure consumer.
    /// </param>
    /// <returns>
    /// An internal tag on success, or -1 for a duplicate address
    /// (unless <c>Overlap_Connection</c> is enabled via
    /// <see cref="SetOption"/>).
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="physicsAddr"/> is null.
    /// </exception>
    public static int PrepareClient(string physicsAddr, AppHandle? app = null)
    {
        ArgumentNullException.ThrowIfNull(physicsAddr);

        IntPtr addrPtr = Utf8Marshal.Alloc(physicsAddr);
        try
        {
            AppHnd appHnd = app is null
                ? AppHnd.Null
                : new AppHnd { Handle = app.Raw };
            return NativeMethods.LF_PrepareClient(addrPtr, appHnd);
        }
        finally
        {
            Utf8Marshal.Free(addrPtr);
        }
    }

    /// <summary>
    /// Starts the LingoFuse framework with all prepared services and
    /// clients.
    /// </summary>
    /// <returns>
    /// 1 on success. Returns 0 on a second call in the same process
    /// without an intervening <c>LF_Shutdown</c>, which is not a
    /// failure.
    /// </returns>
    public static int PrepareDone()
        => NativeMethods.LF_PrepareDone();

    /// <summary>
    /// Requests the simulated main thread to exit. Does not release all
    /// resources; call <see cref="Shutdown"/> afterwards for a full
    /// cleanup.
    /// </summary>
    /// <remarks>
    /// [PITFALL] <c>LF_ExitMainThread</c> also flushes the data handle
    /// pool, releasing every outstanding handle — including those
    /// created with <see cref="DataHandle.CreatePermanent"/>. Do not
    /// use any data handle after this call has returned.
    /// </remarks>
    public static void ExitMainThread()
        => NativeMethods.LF_ExitMainThread();

    // ====================================================================
    // Runtime options
    // ====================================================================

    /// <summary>
    /// Adjusts a global runtime option. Unknown option names are
    /// silently ignored by the native layer.
    /// </summary>
    /// <param name="option">
    /// Option name, for example <c>Overlap_Connection</c>. Must not be
    /// null.
    /// </param>
    /// <param name="value">
    /// New value, for example <c>True</c>. Must not be null.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when either argument is null.
    /// </exception>
    public static void SetOption(string option, string value)
    {
        ArgumentNullException.ThrowIfNull(option);
        ArgumentNullException.ThrowIfNull(value);

        IntPtr optPtr = Utf8Marshal.Alloc(option);
        IntPtr valPtr = Utf8Marshal.Alloc(value);
        try
        {
            NativeMethods.LF_SetOption(optPtr, valPtr);
        }
        finally
        {
            Utf8Marshal.Free(optPtr);
            Utf8Marshal.Free(valPtr);
        }
    }

    // ====================================================================
    // Application name generation and query
    // ====================================================================

    /// <summary>
    /// Generates a globally unique application name.
    /// </summary>
    /// <remarks>
    /// Must be called after <see cref="PrepareDone"/> returns 1. The
    /// native function returns a pointer that is valid for
    /// approximately 5 seconds; this method copies the string to
    /// managed memory immediately.
    ///
    /// Returns an empty string when the underlying native function
    /// returns a null pointer.
    /// </remarks>
    public static string GenerateAppName()
    {
        IntPtr ptr = NativeMethods.LF_Generate_AppName();
        return Utf8Marshal.PtrToString(ptr);
    }

    /// <summary>
    /// Returns the name of an existing application handle.
    /// </summary>
    /// <remarks>
    /// The native function <c>LF_Get_AppName</c> returns a pointer into
    /// a temporary buffer that is valid for approximately 5 seconds.
    /// This method copies the string to managed memory immediately, so
    /// the returned string is safe to hold indefinitely.
    ///
    /// Returns an empty string when the native function returns a null
    /// pointer (for example, a null handle).
    ///
    /// The managed <see cref="AppHandle.Name"/> property returns the
    /// name that was passed to the constructor. This method, by
    /// contrast, queries the native side and therefore reflects the
    /// authoritative name stored in the C4 mesh registry. The two are
    /// usually identical, but they can differ if the AppHandle was
    /// constructed with a name that the native layer normalised, or
    /// if the caller is inspecting an AppHandle obtained from another
    /// source.
    /// </remarks>
    /// <param name="app">
    /// Application handle. Must not be null.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="app"/> is null.
    /// </exception>
    public static string GetAppName(AppHandle app)
    {
        ArgumentNullException.ThrowIfNull(app);

        var hnd = new AppHnd { Handle = app.Raw };
        IntPtr ptr = NativeMethods.LF_Get_AppName(hnd);
        return Utf8Marshal.PtrToString(ptr);
    }

    // ====================================================================
    // Remote invocation
    // ====================================================================

    /// <summary>
    /// Performs a synchronous remote call and returns the response.
    /// </summary>
    /// <param name="appName">
    /// Target application name. Must not be null.
    /// </param>
    /// <param name="param">
    /// Request data handle. Must not be null.
    /// </param>
    /// <param name="timeoutMs">
    /// Timeout in milliseconds. Zero means "wait indefinitely".
    /// Defaults to 5000 ms.
    /// </param>
    /// <returns>
    /// A new DataHandle owning the response. On timeout or failure, the
    /// native side returns an empty handle (Size == 0). The result is
    /// never null; the caller must dispose it.
    ///
    /// Callers who need to distinguish "timeout / unreachable target"
    /// from "empty response" should inspect <c>Size</c> directly, or
    /// use <see cref="TryCall"/> for a null-on-failure contract.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static DataHandle Call(
        string appName,
        DataHandle param,
        ulong timeoutMs = 5000)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr appPtr = Utf8Marshal.Alloc(appName);
        try
        {
            DataHnd result = NativeMethods.LF_Call(
                appPtr,
                new DataHnd { Handle = param.Raw },
                timeoutMs);
            return DataHandle.FromRaw(result.Handle, owned: true);
        }
        finally
        {
            Utf8Marshal.Free(appPtr);
        }
    }

    /// <summary>
    /// Performs a synchronous remote call and returns the response only
    /// when the native layer produced a non-empty payload.
    /// </summary>
    /// <remarks>
    /// This is the C# equivalent of the C++ <c>tryCall</c> helper. It
    /// returns <c>null</c> on timeout or unreachable target, instead
    /// of a size-0 <see cref="DataHandle"/>. Callers who need to
    /// distinguish "timeout" from "empty response" must use
    /// <see cref="Call"/> and inspect <c>Size</c> themselves.
    ///
    /// Ownership: when the method returns a non-null handle, the
    /// caller is responsible for disposing it. When the method returns
    /// null, the underlying empty handle has already been disposed by
    /// this method; the caller must not free anything.
    ///
    /// The idiom:
    /// <code>
    /// using var response = Framework.TryCall("App", param, 3000);
    /// if (response is null) { /* timeout or unreachable */ }
    /// else { /* response.Size > 0 */ }
    /// </code>
    /// </remarks>
    /// <param name="appName">
    /// Target application name. Must not be null.
    /// </param>
    /// <param name="param">
    /// Request data handle. Must not be null.
    /// </param>
    /// <param name="timeoutMs">
    /// Timeout in milliseconds. Zero means "wait indefinitely".
    /// Defaults to 5000 ms.
    /// </param>
    /// <returns>
    /// A new DataHandle when the response is non-empty; <c>null</c>
    /// when the native layer returned an empty (size-0) handle, which
    /// indicates a timeout or an unreachable target.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static DataHandle? TryCall(
        string appName,
        DataHandle param,
        ulong timeoutMs = 5000)
    {
        var response = Call(appName, param, timeoutMs);
        if (response.Size == 0)
        {
            response.Dispose();
            return null;
        }
        return response;
    }

    /// <summary>
    /// Sends a one-way Notify. Delivery order is not guaranteed; use
    /// <see cref="SequencedNotify"/> when FIFO ordering is required.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static void Notify(string appName, DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr appPtr = Utf8Marshal.Alloc(appName);
        try
        {
            NativeMethods.LF_Notify(appPtr, new DataHnd { Handle = param.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appPtr);
        }
    }

    /// <summary>
    /// Sends a one-way notification with FIFO ordering guaranteed for
    /// the same (application, API) pair.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="appName"/> or <paramref name="param"/>
    /// is null.
    /// </exception>
    public static void SequencedNotify(string appName, DataHandle param)
    {
        ArgumentNullException.ThrowIfNull(appName);
        ArgumentNullException.ThrowIfNull(param);

        IntPtr appPtr = Utf8Marshal.Alloc(appName);
        try
        {
            NativeMethods.LF_Sequenced_Notify(
                appPtr,
                new DataHnd { Handle = param.Raw });
        }
        finally
        {
            Utf8Marshal.Free(appPtr);
        }
    }

    // ====================================================================
    // Shutdown
    // ====================================================================

    /// <summary>
    /// Gracefully terminates the framework, releasing all resources.
    /// Safe to call multiple times.
    /// </summary>
    /// <remarks>
    /// Every AppHandle still alive in the process becomes invalid after
    /// this call. The AppHandle wrappers do not detect this
    /// automatically; callers must ensure that no AppHandle is used
    /// after <see cref="Shutdown"/> has returned.
    ///
    /// The native side also clears both network event callbacks during
    /// teardown. The managed delegate references held by
    /// <see cref="NetworkEvents"/> are NOT released automatically; call
    /// <see cref="NetworkEvents.Clear"/> explicitly before shutdown if
    /// you want to release them.
    /// </remarks>
    public static void Shutdown()
        => NativeMethods.LF_Shutdown();
}