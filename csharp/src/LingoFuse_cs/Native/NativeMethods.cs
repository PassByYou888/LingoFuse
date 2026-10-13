// ============================================================================
// File: csharp/src/LingoFuse_cs/Native/NativeMethods.cs
// ============================================================================
// NativeMethods — P/Invoke declarations for the LingoFuse C ABI.
// ============================================================================
// This class is the ONLY place in the entire binding where native code
// is invoked. Every managed wrapper in the LingoFuse namespace goes
// through these declarations.
//
// All declarations are grouped and ordered to match the export
// section of Z.LingoFuse_Export.pas. EntryPoint strings are
// case-sensitive and match the Pascal source exactly.
//
// CALLING CONVENTION
// ------------------
// All functions use CallingConvention.Cdecl. The resolver registered
// in the static constructor selects the correct platform library at
// first use:
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
// UID PARAMETERS
// --------------
// The UID is a 32-byte aggregate. It is declared as TUIDNative (a
// blittable struct of four ulongs) and passed BY VALUE, matching the
// Pascal-side array[0..31] of Byte convention on x86-64.
//
// The single exception is LF_Get_P2P_UID, which RETURNS an IntPtr
// pointing to a library-owned 32-byte buffer. The returned pointer is
// valid for approximately 5 seconds; the managed wrapper copies the
// 32 bytes immediately and never exposes the pointer.
//
// ============================================================================

using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace LingoFuse.Native;

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
    // Data handle operations (12 exports)
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

    /// <summary>
    /// Reads the sender's 32-byte session UID from an INPUT handle.
    /// </summary>
    /// <param name="hnd">
    /// Data handle. Must be the <c>input</c> argument of a Call /
    /// Notify callback. On an output handle or a caller-created handle
    /// the native layer logs a warning and returns a pointer to a
    /// zero-filled UID.
    /// </param>
    /// <returns>
    /// A pointer to a 32-byte UID buffer, OR <see cref="IntPtr.Zero"/>
    /// only if the library itself could not allocate the buffer.
    /// The pointed-to buffer is released by the native layer
    /// approximately 5 seconds after the call.
    ///
    /// <b>Contract:</b>
    /// <list type="bullet">
    ///   <item>Copy the 32 bytes IMMEDIATELY if you want to retain
    ///         them.</item>
    ///   <item>Do NOT free the pointer.</item>
    ///   <item>Do NOT retain the pointer past the ~5-second
    ///         window.</item>
    /// </list>
    ///
    /// The managed wrapper (<c>DataHandle.GetSenderUid</c>) performs
    /// the copy and never exposes the pointer.
    /// </returns>
    /// <remarks>
    /// SIDE-DATA SEMANTICS: this is NOT a property of the handle. It is
    /// the sender's identity, written into the payload header by the
    /// sender's transport layer. It therefore only exists on an INPUT
    /// handle.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Get_P2P_UID", ExactSpelling = true)]
    internal static extern IntPtr LF_Get_P2P_UID(DataHnd hnd);

    /// <summary>
    /// Reads the sender's P2P group name from an INPUT handle.
    /// </summary>
    /// <param name="hnd">
    /// Data handle. Must be the <c>input</c> argument of a Call /
    /// Notify callback. On an output handle or a caller-created handle
    /// the native layer logs a warning and returns an empty string.
    /// </param>
    /// <returns>
    /// A pointer to a UTF-8, NUL-terminated string, or
    /// <see cref="IntPtr.Zero"/> on failure. The pointed-to buffer is
    /// released by the native layer approximately 5 seconds after the
    /// call.
    ///
    /// <b>Contract:</b>
    /// <list type="bullet">
    ///   <item>Copy the string IMMEDIATELY if you want to retain
    ///         it.</item>
    ///   <item>Do NOT free the pointer.</item>
    ///   <item>Do NOT retain the pointer past the ~5-second
    ///         window.</item>
    /// </list>
    ///
    /// The managed wrapper (<c>DataHandle.GetSenderP2PName</c>)
    /// performs the copy and never exposes the pointer.
    /// </returns>
    /// <remarks>
    /// Same SIDE-DATA semantics as <see cref="LF_Get_P2P_UID"/>.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Get_P2P_Name", ExactSpelling = true)]
    internal static extern IntPtr LF_Get_P2P_Name(DataHnd hnd);

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
    // API registration — app-bound (3 exports)
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
    // API registration — process-wide P2P (3 exports)
    // ====================================================================

    /// <summary>
    /// Registers a process-wide Call API on the LF_P2P_APP.
    /// </summary>
    /// <remarks>
    /// APIs registered here are reachable via UID addressing and
    /// P2PName addressing. They are NOT reachable via App-name
    /// addressing, even if the API name happens to match an App name.
    ///
    /// They live on the process-wide LF_P2P_APP and survive until
    /// LF_Shutdown.
    ///
    /// Typical use: globally-discoverable utility APIs (health probes,
    /// capability discovery, identity echo, etc.) that any client in
    /// the mesh can call by UID or by P2PName without knowing the
    /// target's App name.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Register_P2P_Call", ExactSpelling = true)]
    internal static extern int LF_Register_P2P_Call(
        IntPtr methodName,
        IntPtr desc,
        IntPtr trigger,
        LfCallFunc onCall);

    /// <summary>
    /// Registers a process-wide Notify API on the LF_P2P_APP.
    /// </summary>
    /// <remarks>
    /// Same namespace and reachability rules as
    /// <see cref="LF_Register_P2P_Call"/>.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Register_P2P_Notify", ExactSpelling = true)]
    internal static extern int LF_Register_P2P_Notify(
        IntPtr methodName,
        IntPtr desc,
        IntPtr trigger,
        LfNotifyFunc onNotify);

    /// <summary>
    /// Removes a process-wide P2P API by name. Does NOT affect
    /// app-bound APIs of the same name.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Unregister_P2P", ExactSpelling = true)]
    internal static extern int LF_Unregister_P2P(IntPtr methodName);

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
    // Remote invocation — App name addressing (5 exports)
    // ====================================================================

    /// <summary>
    /// Performs a synchronous remote call. On timeout or failure, an
    /// empty handle (size 0) is returned, not a null pointer.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Call", ExactSpelling = true)]
    internal static extern DataHnd LF_Call(IntPtr appName, DataHnd param, ulong timeoutMs);

    /// <summary>
    /// Starts an asynchronous remote call. Returns 1 if the request was
    /// queued, 0 otherwise.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The <paramref name="onResult"/> callback fires later on a worker
    /// thread. If the return value is 0, the callback is NEVER
    /// invoked. The managed bridge detects this synchronous failure
    /// and faults the corresponding Task.
    /// </para>
    /// <para>
    /// The <paramref name="data"/> pointer is forwarded verbatim to
    /// the callback. LingoFuse neither owns nor frees it.
    /// </para>
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Async_Call", ExactSpelling = true)]
    internal static extern int LF_Async_Call(
        IntPtr appName,
        DataHnd param,
        IntPtr data,
        LfAsyncCallOnResult onResult);

    /// <summary>
    /// Starts an asynchronous sequenced remote call (FIFO per
    /// (app, api) pair). Same return-value and callback contract as
    /// <see cref="LF_Async_Call"/>.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Async_Sequenced_Call", ExactSpelling = true)]
    internal static extern int LF_Async_Sequenced_Call(
        IntPtr appName,
        DataHnd param,
        IntPtr data,
        LfAsyncCallOnResult onResult);

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
    // Remote invocation — UID addressing (5 exports)
    // ====================================================================

    /// <summary>
    /// Synchronous remote call addressed by session UID.
    /// Same timeout / failure contract as <see cref="LF_Call"/>.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_UID_Call", ExactSpelling = true)]
    internal static extern DataHnd LF_UID_Call(
        TUIDNative uid,
        DataHnd param,
        ulong timeoutMs);

    /// <summary>
    /// Starts an asynchronous remote call addressed by session UID.
    /// Same return-value and callback contract as
    /// <see cref="LF_Async_Call"/>.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_UID_Async_Call", ExactSpelling = true)]
    internal static extern int LF_UID_Async_Call(
        TUIDNative uid,
        DataHnd param,
        IntPtr data,
        LfAsyncCallOnResult onResult);

    /// <summary>
    /// Starts an asynchronous sequenced remote call addressed by
    /// session UID.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_UID_Async_Sequenced_Call", ExactSpelling = true)]
    internal static extern int LF_UID_Async_Sequenced_Call(
        TUIDNative uid,
        DataHnd param,
        IntPtr data,
        LfAsyncCallOnResult onResult);

    /// <summary>
    /// Sends a one-way notification addressed by session UID.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_UID_Notify", ExactSpelling = true)]
    internal static extern void LF_UID_Notify(TUIDNative uid, DataHnd param);

    /// <summary>
    /// Sends a one-way sequenced notification addressed by session UID.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_UID_Sequenced_Notify", ExactSpelling = true)]
    internal static extern void LF_UID_Sequenced_Notify(TUIDNative uid, DataHnd param);

    // ====================================================================
    // Remote invocation — P2PName addressing (5 exports)
    // ====================================================================

    /// <summary>
    /// Synchronous remote call addressed by P2P group name.
    /// Same timeout / failure contract as <see cref="LF_Call"/>.
    /// </summary>
    /// <remarks>
    /// P2PName routing is NOT local-first: even when the caller process
    /// itself hosts a client in the target group, the call is
    /// forwarded to the server for dispatch.
    /// </remarks>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_P2PNAME_Call", ExactSpelling = true)]
    internal static extern DataHnd LF_P2PNAME_Call(
        IntPtr p2pName,
        DataHnd param,
        ulong timeoutMs);

    /// <summary>
    /// Starts an asynchronous remote call addressed by P2P group name.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_P2PNAME_Async_Call", ExactSpelling = true)]
    internal static extern int LF_P2PNAME_Async_Call(
        IntPtr p2pName,
        DataHnd param,
        IntPtr data,
        LfAsyncCallOnResult onResult);

    /// <summary>
    /// Starts an asynchronous sequenced remote call addressed by P2P
    /// group name.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_P2PNAME_Async_Sequenced_Call", ExactSpelling = true)]
    internal static extern int LF_P2PNAME_Async_Sequenced_Call(
        IntPtr p2pName,
        DataHnd param,
        IntPtr data,
        LfAsyncCallOnResult onResult);

    /// <summary>
    /// Sends a one-way notification addressed by P2P group name.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_P2PNAME_Notify", ExactSpelling = true)]
    internal static extern void LF_P2PNAME_Notify(IntPtr p2pName, DataHnd param);

    /// <summary>
    /// Sends a one-way sequenced notification addressed by P2P group
    /// name.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_P2PNAME_Sequenced_Notify", ExactSpelling = true)]
    internal static extern void LF_P2PNAME_Sequenced_Notify(IntPtr p2pName, DataHnd param);

    // ====================================================================
    // Queries (11 exports)
    // ====================================================================

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

    /// <summary>
    /// Returns 1 if a client with the given UID is currently
    /// registered. Same cache caveat as LF_CheckApp.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Check_UID", ExactSpelling = true)]
    internal static extern int LF_Check_UID(TUIDNative uid);

    /// <summary>
    /// Returns 1 if a client with the given UID exposes the named API.
    /// Same cache caveat as LF_CheckApp.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Check_UID_Api", ExactSpelling = true)]
    internal static extern int LF_Check_UID_Api(TUIDNative uid, IntPtr apiName);

    /// <summary>
    /// Returns 1 if a client with the given P2P group name is
    /// registered. Same cache caveat as LF_CheckApp.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Check_P2PNAME", ExactSpelling = true)]
    internal static extern int LF_Check_P2PNAME(IntPtr p2pName);

    /// <summary>
    /// Returns 1 if a client in the given P2P group exposes the named
    /// API. Same cache caveat as LF_CheckApp.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_Check_P2PNAME_Api", ExactSpelling = true)]
    internal static extern int LF_Check_P2PNAME_Api(IntPtr p2pName, IntPtr apiName);

    // ====================================================================
    // Options (2 exports)
    // ====================================================================

    /// <summary>
    /// Adjusts a global runtime option. Unknown option names are
    /// silently ignored.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_SetOption", ExactSpelling = true)]
    internal static extern void LF_SetOption(IntPtr option, IntPtr value);

    /// <summary>
    /// Reads a global runtime option. The returned pointer targets a
    /// transient buffer released ~5 seconds after the call; copy the
    /// string immediately via Utf8Marshal.PtrToString.
    ///
    /// Unknown option names produce an empty string.
    /// </summary>
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "LF_GetOption", ExactSpelling = true)]
    internal static extern IntPtr LF_GetOption(IntPtr option);

    // ====================================================================
    // Status (3 exports)
    // ====================================================================

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
}