using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace LingoFuse.Native;

// ============================================================================
// NativeMethods — P/Invoke declarations for the LingoFuse C ABI.
// ============================================================================
//
// This class is the ONLY place in the entire binding where native code
// is invoked. Every managed wrapper in the LingoFuse namespace goes
// through these declarations.
//
// The 37 exports below are declared in the same order as the exports
// section of LingoFuse.lpr. EntryPoint strings are case-sensitive and
// match the Pascal source exactly.
//
// CALLING CONVENTION
// ------------------
// All functions use CallingConvention.Cdecl. The resolver registered in
// the static constructor selects the correct platform library at first
// use:
//
//     Windows 64-bit  ->  LingoFuse64.dll
//     Windows 32-bit  ->  LingoFuse32.dll
//     Linux / BSD     ->  liblingofuse.so
//     macOS           ->  liblingofuse.dylib
//
// The library is loaded lazily by the CLR, on the first call to any
// declaration. There is no separate LF_LoadLibrary step (unlike the
// C wrapper shipped with the Pascal distribution).
//
// STRING PARAMETERS
// -----------------
// String parameters are declared as IntPtr and must be UTF-8,
// NUL-terminated buffers produced by Utf8Marshal.Alloc. String return
// values are also IntPtr and must be copied immediately via
// Utf8Marshal.PtrToString; the native side owns the underlying memory
// and may invalidate it at any time.
//
// ============================================================================

internal static class NativeMethods
{
    /// <summary>
    /// Logical library name used in every DllImport attribute. The
    /// resolver in the static constructor maps it to the actual
    /// platform-specific file name at load time.
    /// </summary>
    internal const string DllName = "LingoFuse";

    // --------------------------------------------------------------------
    // Static constructor — register the platform resolver.
    // --------------------------------------------------------------------

    static NativeMethods()
    {
        NativeLibrary.SetDllImportResolver(
            typeof(NativeMethods).Assembly,
            ResolveLibrary);
    }

    /// <summary>
    /// Maps the logical library name to the correct platform file.
    /// Returns <see cref="IntPtr.Zero"/> for unrelated libraries so that
    /// other DllImport declarations in the same assembly continue to
    /// resolve through the default mechanism.
    /// </summary>
    private static IntPtr ResolveLibrary(
        string libraryName,
        Assembly assembly,
        DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, DllName, StringComparison.Ordinal))
        {
            return IntPtr.Zero;
        }

        string platformName = SelectPlatformFileName();
        return NativeLibrary.Load(platformName, assembly, searchPath);
    }

    /// <summary>
    /// Returns the platform-specific library file name.
    /// </summary>
    private static string SelectPlatformFileName()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return IntPtr.Size == 8 ? "LingoFuse64.dll" : "LingoFuse32.dll";
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return "liblingofuse.dylib";
        }
        // Linux, BSD, and any other ELF-based system.
        return "liblingofuse.so";
    }

    // ====================================================================
    // Data handle operations (10 exports)
    // ====================================================================

    /// <summary>
    /// Creates a new AUTO-RECYCLED data handle bound to the given API
    /// name. The underlying buffer starts empty.
    /// </summary>
    /// <param name="methodName">UTF-8, NUL-terminated API name.</param>
    /// <remarks>
    /// The handle is added to the library's idle pool. The pool scans
    /// every 5 seconds and frees any handle that has been idle (no
    /// accessor call) for more than 10 minutes. Any accessor call
    /// refreshes the idle timestamp.
    ///
    /// The handle must be released with LF_FreeData. LF_FreeData on an
    /// auto-recycled handle only marks it as deleted; the actual
    /// release happens on the next pool scan (at most 5 seconds later).
    ///
    /// Use LF_CreateData_Permanent when the handle must survive for the
    /// entire process lifetime.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_CreateData", ExactSpelling = true)]
    internal static extern DataHnd LF_CreateData(IntPtr methodName);

    /// <summary>
    /// Creates a new PERMANENT data handle bound to the given API name.
    /// The underlying buffer starts empty.
    /// </summary>
    /// <param name="methodName">UTF-8, NUL-terminated API name.</param>
    /// <remarks>
    /// Difference from LF_CreateData:
    /// <list type="bullet">
    ///   <item>The handle is NOT added to the library's idle pool.</item>
    ///   <item>The automatic idle-timeout reclaimer will NEVER free it,
    ///         no matter how long it has been idle.</item>
    ///   <item>LF_FreeData releases it IMMEDIATELY (synchronously),
    ///         rather than merely marking it for a later pool
    ///         scan.</item>
    /// </list>
    ///
    /// Use this for handles that must survive for the entire lifetime
    /// of the process (cached request templates, long-lived scratch
    /// buffers, global registries, etc.). Do NOT use it for short-lived
    /// handles; the pool safety net is lost.
    ///
    /// [PITFALL - NO-OP WINDOW]
    ///   LF_FreeData is a no-op while the simulated main thread is not
    ///   active (before LF_PrepareDone or after LF_ExitMainThread).
    ///   Permanent handles created in that window stay allocated until
    ///   the process terminates. LF_Shutdown also releases any
    ///   permanent handle that is still alive.
    ///
    /// [PITFALL - LIFETIME]
    ///   "Permanent" means "not automatically reclaimed", NOT "never
    ///   released". You are fully responsible for calling LF_FreeData.
    ///   Losing the pointer leaks the handle for the lifetime of the
    ///   process.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_CreateData_Permanent", ExactSpelling = true)]
    internal static extern DataHnd LF_CreateData_Permanent(IntPtr methodName);

    /// <summary>
    /// Releases a data handle. Passing a null handle is safe and
    /// ignored.
    /// </summary>
    /// <remarks>
    /// For an auto-recycled handle (created by LF_CreateData) this call
    /// only marks the handle as deleted; the actual release happens on
    /// the next pool scan (at most 5 seconds later). For a permanent
    /// handle (created by LF_CreateData_Permanent) the release happens
    /// synchronously.
    ///
    /// [PITFALL] This call is a NO-OP while the simulated main thread
    /// is not active (before LF_PrepareDone or after
    /// LF_ExitMainThread). Permanent handles created in that window
    /// stay allocated until the process terminates or LF_Shutdown runs.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_FreeData", ExactSpelling = true)]
    internal static extern void LF_FreeData(DataHnd hnd);

    /// <summary>
    /// Returns a pointer to the handle's internal buffer. The pointer is
    /// invalidated by any subsequent resize; do not free it.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_GetBuffer", ExactSpelling = true)]
    internal static extern IntPtr LF_GetBuffer(DataHnd hnd);

    /// <summary>
    /// Writes <paramref name="size"/> bytes at the current cursor. The
    /// buffer grows as needed and the cursor advances. Returns the
    /// number of bytes actually written.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_WriteBuffer", ExactSpelling = true)]
    internal static extern long LF_WriteBuffer(DataHnd hnd, byte[] buff, long size);

    /// <summary>
    /// Reads up to <paramref name="size"/> bytes into
    /// <paramref name="buff"/>. The cursor advances by the number of
    /// bytes actually read.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_ReadBuffer", ExactSpelling = true)]
    internal static extern long LF_ReadBuffer(DataHnd hnd, byte[] buff, long size);

    /// <summary>Returns the current read/write cursor.</summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_GetPos", ExactSpelling = true)]
    internal static extern long LF_GetPos(DataHnd hnd);

    /// <summary>
    /// Sets the read/write cursor. A position past the end of the buffer
    /// implicitly grows the buffer; the new bytes are uninitialized.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_SetPos", ExactSpelling = true)]
    internal static extern void LF_SetPos(DataHnd hnd, long pos);

    /// <summary>Returns the total buffer size in bytes.</summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_GetSize", ExactSpelling = true)]
    internal static extern long LF_GetSize(DataHnd hnd);

    /// <summary>
    /// Resizes the buffer. Newly added bytes are uninitialized.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_SetSize", ExactSpelling = true)]
    internal static extern void LF_SetSize(DataHnd hnd, long size);

    // ====================================================================
    // Application handle operations (5 exports)
    // ====================================================================

    /// <summary>
    /// Creates a new application with the given name and description.
    /// The handle must be released with LF_FreeApp.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_CreateApp", ExactSpelling = true)]
    internal static extern AppHnd LF_CreateApp(IntPtr appName, IntPtr desc);

    /// <summary>
    /// Detaches the application from all clients and stops its sequenced
    /// notification threads. The underlying object remains alive in the
    /// global pool until LF_Shutdown is called. The handle is invalid
    /// afterwards.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_FreeApp", ExactSpelling = true)]
    internal static extern void LF_FreeApp(AppHnd appHnd);

    /// <summary>
    /// Generates a globally unique application name built from active C4
    /// tunnels, process name, and a timestamp.
    /// </summary>
    /// <remarks>
    /// Must be called after LF_PrepareDone returns 1. The returned
    /// pointer is valid for approximately 5 seconds; copy the string
    /// immediately via Utf8Marshal.PtrToString.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Generate_AppName", ExactSpelling = true)]
    internal static extern IntPtr LF_Generate_AppName();

    /// <summary>
    /// Returns the name of the given application handle.
    /// </summary>
    /// <remarks>
    /// Same 5-second validity rule as LF_Generate_AppName. The
    /// returned pointer targets a temporary buffer; copy the string
    /// immediately via Utf8Marshal.PtrToString.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Get_AppName", ExactSpelling = true)]
    internal static extern IntPtr LF_Get_AppName(AppHnd appHnd);

    /// <summary>
    /// Binds the application to all currently unbound clients. Returns
    /// the number of clients bound. Zero means no free client or the
    /// simulated main thread is not active.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_BindApp", ExactSpelling = true)]
    internal static extern int LF_BindApp(AppHnd appHnd);

    // ====================================================================
    // API registration (3 exports)
    // ====================================================================

    /// <summary>
    /// Registers a Call (request-response) API. Returns 1 on success,
    /// 0 if the API name is already taken.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_RegisterCall", ExactSpelling = true)]
    internal static extern int LF_RegisterCall(
        AppHnd appHnd,
        IntPtr methodName,
        IntPtr desc,
        IntPtr trigger,
        LfCallFunc onCall);

    /// <summary>
    /// Registers a Notify (one-way) API. Returns 1 on success, 0 if the
    /// API name is already taken.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_RegisterNotify", ExactSpelling = true)]
    internal static extern int LF_RegisterNotify(
        AppHnd appHnd,
        IntPtr methodName,
        IntPtr desc,
        IntPtr trigger,
        LfNotifyFunc onNotify);

    /// <summary>
    /// Removes a previously registered API. Returns 1 if the API was
    /// found and removed, 0 otherwise.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Unregister", ExactSpelling = true)]
    internal static extern int LF_Unregister(AppHnd appHnd, IntPtr methodName);

    // ====================================================================
    // Local execution (2 exports)
    // ====================================================================

    /// <summary>
    /// Executes a Call API locally within the same process, bypassing
    /// the network. Returns a new result handle that the caller must
    /// free.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_LocalCall", ExactSpelling = true)]
    internal static extern DataHnd LF_LocalCall(AppHnd appHnd, DataHnd param);

    /// <summary>
    /// Executes a Notify API locally within the same process.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_LocalNotify", ExactSpelling = true)]
    internal static extern void LF_LocalNotify(AppHnd appHnd, DataHnd param);

    // ====================================================================
    // Network preparation (5 exports)
    // ====================================================================

    /// <summary>
    /// Clears any previously prepared services and clients. Running
    /// services and clients are not affected.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_ResetPrepare", ExactSpelling = true)]
    internal static extern void LF_ResetPrepare();

    /// <summary>
    /// Prepares a C4 service. Returns an internal tag, or -1 for a
    /// duplicate address.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_PrepareService", ExactSpelling = true)]
    internal static extern int LF_PrepareService(IntPtr listeningAddr, IntPtr physicsAddr);

    /// <summary>
    /// Prepares a C4 client. Returns an internal tag, or -1 for a
    /// duplicate address (unless Overlap_Connection is enabled).
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_PrepareClient", ExactSpelling = true)]
    internal static extern int LF_PrepareClient(IntPtr physicsAddr, AppHnd appHnd);

    /// <summary>
    /// Starts the LingoFuse framework with all prepared services and
    /// clients. Returns 1 on success. Returns 0 on the second call in
    /// the same process (which is not a failure).
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_PrepareDone", ExactSpelling = true)]
    internal static extern int LF_PrepareDone();

    /// <summary>
    /// Requests the simulated main thread to exit. Does not release all
    /// resources; call LF_Shutdown afterwards.
    /// </summary>
    /// <remarks>
    /// [PITFALL] LF_ExitMainThread also flushes the data handle pool,
    /// releasing every outstanding handle — including those created
    /// with LF_CreateData_Permanent. Do not use any data handle after
    /// this call.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_ExitMainThread", ExactSpelling = true)]
    internal static extern void LF_ExitMainThread();

    // ====================================================================
    // Remote invocation (3 exports)
    // ====================================================================

    /// <summary>
    /// Performs a synchronous remote call. On timeout or failure, an
    /// empty handle (size 0) is returned, not a null pointer.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Call", ExactSpelling = true)]
    internal static extern DataHnd LF_Call(IntPtr appName, DataHnd param, ulong timeoutMs);

    /// <summary>
    /// Sends a one-way notification. Delivery order is not guaranteed.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Notify", ExactSpelling = true)]
    internal static extern void LF_Notify(IntPtr appName, DataHnd param);

    /// <summary>
    /// Sends a one-way notification with FIFO ordering guaranteed for
    /// the same (application, API) pair.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Sequenced_Notify", ExactSpelling = true)]
    internal static extern void LF_Sequenced_Notify(IntPtr appName, DataHnd param);

    // ====================================================================
    // Options and diagnostics (7 exports)
    // ====================================================================

    /// <summary>
    /// Adjusts a global runtime option. Unknown option names are
    /// silently ignored.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_SetOption", ExactSpelling = true)]
    internal static extern void LF_SetOption(IntPtr option, IntPtr value);

    /// <summary>
    /// Returns the number of pending log messages (max 1000).
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_GetStatusCount", ExactSpelling = true)]
    internal static extern int LF_GetStatusCount();

    /// <summary>
    /// Returns the next log message. The returned pointer targets a
    /// static buffer that is invalidated by the next call; copy the
    /// string immediately.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_GetStatus", ExactSpelling = true)]
    internal static extern IntPtr LF_GetStatus();

    /// <summary>
    /// Injects a custom log message into the status queue.
    /// </summary>
    /// <remarks>
    /// The message is queued even when the simulated main thread is not
    /// running. The queue is bounded at 1000 entries; older entries are
    /// dropped when the buffer is full.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_PostStatus", ExactSpelling = true)]
    internal static extern void LF_PostStatus(IntPtr status);

    /// <summary>
    /// Returns 1 if the simulated main thread is running.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_CheckMainThread", ExactSpelling = true)]
    internal static extern int LF_CheckMainThread();

    /// <summary>
    /// Returns 1 if an application with the given name is available.
    /// The lookup uses a local cache with an approximate 3-second
    /// broadcast delay.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_CheckApp", ExactSpelling = true)]
    internal static extern int LF_CheckApp(IntPtr appName);

    /// <summary>
    /// Returns 1 if the named API is available for the given
    /// application. Same cache caveat as LF_CheckApp.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_CheckApi", ExactSpelling = true)]
    internal static extern int LF_CheckApi(IntPtr appName, IntPtr apiName);

    // ====================================================================
    // Shutdown (1 export)
    // ====================================================================

    /// <summary>
    /// Gracefully terminates the framework, releasing all resources.
    /// Safe to call multiple times.
    /// </summary>
    /// <remarks>
    /// The native side also clears both network event callbacks during
    /// teardown. The managed delegate references held by
    /// LingoFuse.NetworkEvents are NOT released automatically; call
    /// NetworkEvents.Clear explicitly before shutdown if you want to
    /// release them.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Shutdown", ExactSpelling = true)]
    internal static extern void LF_Shutdown();

    // ====================================================================
    // Network events (1 export)
    // ====================================================================

    /// <summary>
    /// Installs or clears the process-global network connect and
    /// disconnect callbacks. Pass <c>null</c> for either parameter to
    /// disable that event.
    /// </summary>
    /// <remarks>
    /// Callbacks run on background worker threads and receive a UTF-8
    /// endpoint string that is valid only during the callback
    /// invocation.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Set_Network_Event", ExactSpelling = true)]
    internal static extern void LF_Set_Network_Event(
        LfNetworkEventFunc? onConnect,
        LfNetworkEventFunc? onDisconnect);
}