/**
 * @file LingoFuse.h
 * @brief C explicit-linking wrapper for the LingoFuse dynamic library.
 *
 * This header declares the complete C ABI of the LingoFuse distributed RPC
 * framework. It mirrors the Pascal import unit `lingofuse_import.pas` and
 * the export table defined in `LingoFuse.lpr`.
 *
 * ============================================================================
 * EXPORTED FUNCTIONS (36 total, defined in LingoFuse.lpr)
 * ============================================================================
 *
 *   Data handles (9):
 *       LF_CreateData, LF_FreeData, LF_GetBuffer,
 *       LF_WriteBuffer, LF_ReadBuffer,
 *       LF_GetPos, LF_SetPos, LF_GetSize, LF_SetSize
 *
 *   Application handles (5):
 *       LF_CreateApp, LF_FreeApp,
 *       LF_Generate_AppName, LF_Get_AppName, LF_BindApp
 *
 *   API registration (3):
 *       LF_RegisterCall, LF_RegisterNotify, LF_Unregister
 *
 *   Local execution (2):
 *       LF_LocalCall, LF_LocalNotify
 *
 *   Network preparation (5):
 *       LF_PrepareService, LF_PrepareClient,
 *       LF_ResetPrepare, LF_PrepareDone, LF_ExitMainThread
 *
 *   Remote invocation (3):
 *       LF_Call, LF_Notify, LF_Sequenced_Notify
 *
 *   Options and diagnostics (7):
 *       LF_SetOption,
 *       LF_GetStatusCount, LF_GetStatus, LF_PostStatus,
 *       LF_CheckMainThread, LF_CheckApp, LF_CheckApi
 *
 *   Shutdown (1):
 *       LF_Shutdown
 *
 *   Network events (1):
 *       LF_Set_Network_Event
 *
 * ============================================================================
 * HELPER FUNCTIONS (implemented by this C wrapper, NOT exported from the DLL)
 * ============================================================================
 * The helpers below are declared at the bottom of this file. They mirror the
 * Pascal helper functions in `lingofuse_import.pas` and are implemented on
 * top of the exported primitives (LF_WriteBuffer / LF_ReadBuffer / etc.).
 *
 * All integer helpers use little-endian byte order, matching the wire format.
 *
 * ============================================================================
 * STRING ENCODING - UTF-8 IS MANDATORY
 * ============================================================================
 * All string parameters (API names, descriptions, network addresses, etc.)
 * MUST be encoded in UTF-8 and MUST be null-terminated (i.e., end with a
 * byte of value 0).
 *
 * The library internally decodes UTF-8 input into Unicode and encodes
 * outgoing strings back to UTF-8. This is platform-independent and works
 * identically on Windows, Linux, macOS, and BSD.
 *
 * Do NOT use the system ANSI codepage (e.g., CP_ACP on Windows). All
 * strings are explicitly marshaled as UTF-8.
 *
 * ============================================================================
 * STRING MECHANISM - THE #0 NULL TERMINATOR CONTRACT
 * ============================================================================
 * LingoFuse uses C-style null-terminated strings on the wire. The rules are:
 *
 *   1. Every string written by LF_WriteString / LF_WriteStringBytes is
 *      followed by exactly ONE byte of value 0 (#0).
 *
 *   2. When reading, LF_ReadString / LF_ReadStringBytes scan forward until
 *      the first #0. This is the "null-terminated" mode.
 *
 *   3. FAULT-TOLERANT MODE (critical for cross-language interop):
 *      If no #0 is found before the end of the buffer, the reader returns
 *      ALL remaining bytes and advances the cursor to (buffer size + 1),
 *      i.e. ONE BYTE PAST the end of the buffer. This is the exact
 *      behaviour of Pascal's LF_ReadString in `lingofuse_import.pas`
 *      (LF_SetPos(Hnd, e + 1) with e == size), and the underlying library
 *      implicitly grows the buffer by one byte to accommodate the position.
 *
 *      This case is REQUIRED for interoperability with HTTP bridges
 *      (e.g., bridge.py) and any non-Pascal client that forwards raw JSON
 *      without appending a #0.
 *
 *      Do NOT assume "read returns 0" means "no #0 found". In this library,
 *      both "found #0" and "read to end" return success. A failure return
 *      means either the buffer is exhausted before any data, or the caller-
 *      supplied destination buffer is too small.
 *
 *   4. UTF-8 validation: This C wrapper does NOT validate UTF-8. The bytes
 *      copied into the caller's buffer are raw. If strict UTF-8 validation
 *      is required, the caller must perform it after reading.
 *
 * ============================================================================
 * THREAD SAFETY
 * ============================================================================
 * All exported functions are fully thread-safe and may be called concurrently
 * from any thread without external synchronization.
 *
 * However, for a given data handle (TDataHnd), write operations
 * (LF_WriteBuffer, LF_SetPos, LF_SetSize) must be serialised across threads
 * because they mutate the internal buffer state. Read-only operations
 * (LF_GetBuffer, LF_GetPos, LF_GetSize) are safe even while another thread
 * is writing, provided the handle is not being freed.
 *
 * Different TDataHnd instances are independent and may be used concurrently
 * without any restrictions.
 *
 * ============================================================================
 * CALLBACK EXECUTION CONTEXT (CRITICAL)
 * ============================================================================
 * All registered callbacks (LF_CallFunc, LF_NotifyFunc, LF_NetworkEventFunc)
 * are executed in background worker threads from the library's internal
 * thread pool. This means:
 *
 *   - DO NOT perform long-blocking operations inside a callback.
 *   - DO NOT call LF_Call() or LF_Notify() from within a callback; this
 *     may cause a deadlock because the callback thread may hold internal
 *     locks. If you need to make a remote call, offload the request to a
 *     separate worker thread and return quickly.
 *   - DO NOT access UI components or thread-local storage without proper
 *     synchronization (e.g., a message queue).
 *
 * The library guarantees callbacks are thread-safe and reentrant, but it is
 * the caller's responsibility to synchronize any shared data accessed from
 * callbacks.
 *
 * ============================================================================
 * DATA HANDLE LIFETIME
 * ============================================================================
 * Every TDataHnd created with LF_CreateData() MUST be freed with
 * LF_FreeData() when no longer needed. The library has an automatic
 * idle-timeout reclaimer (5 minutes) on the simulated main thread, but it is
 * not immediate; relying on it can leak resources under heavy load.
 *
 * LF_Call() ALWAYS returns a valid TDataHnd (never a NULL pointer). If the
 * call times out or fails, the handle size will be 0. You must still free it
 * with LF_FreeData().
 *
 * ============================================================================
 * LIBRARY LOADING
 * ============================================================================
 * On Windows, use `LF_LoadLibrary()` to explicitly load `LingoFuse64.dll`
 * (or `LingoFuse32.dll`). On Linux/macOS the loader resolves
 * `liblingofuse.so` / `liblingofuse.dylib`.
 *
 * The loader first tries the executable's own directory, then falls back to
 * the system search path. Call `LF_FreeLibrary()` when done.
 *
 * Note: The loader functions (LF_LoadLibrary / LF_FreeLibrary) are provided
 * by the C wrapper itself; they are NOT exported from the dynamic library.
 *
 * ============================================================================
 * USAGE EXAMPLE
 * ============================================================================
 * @code
 * #include "LingoFuse.h"
 * #include <stdio.h>
 *
 * static void LF_CDECL AddCallback(void* trigger, void* input, void* output) {
 *     int a = 0, b = 0, sum = 0;
 *     LF_ReadInt32((TDataHnd)input, &a);
 *     LF_ReadInt32((TDataHnd)input, &b);
 *     sum = a + b;
 *     LF_WriteInt32((TDataHnd)output, sum);
 * }
 *
 * int main(void) {
 *     if (!LF_LoadLibrary()) return 1;
 *
 *     TAppHnd app = LF_CreateApp("Calculator", "Simple calculator");
 *     LF_RegisterCall(app, "add", "Add two integers", NULL, AddCallback);
 *
 *     LF_ResetPrepare();
 *     LF_PrepareService("0.0.0.0", "127.0.0.1:9898");
 *     LF_PrepareClient("127.0.0.1:9898", app);
 *     if (LF_PrepareDone() != 1) { LF_FreeLibrary(); return 1; }
 *
 *     TDataHnd data = LF_CreateData("add");
 *     LF_WriteInt32(data, 5);
 *     LF_WriteInt32(data, 7);
 *     TDataHnd result = LF_Call("Calculator", data, 5000);
 *     int sum = 0;
 *     if (result && LF_GetSize(result) >= 4) LF_ReadInt32(result, &sum);
 *     printf("5 + 7 = %d\n", sum);
 *
 *     LF_FreeData(data);
 *     LF_FreeData(result);
 *     LF_FreeApp(app);
 *     LF_Shutdown();
 *     LF_FreeLibrary();
 *     return 0;
 * }
 * @endcode
 */

#ifndef LINGOFUSE_H_INCLUDED
#define LINGOFUSE_H_INCLUDED

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

    /* ----------------------------------------------------------------------------
     * Calling convention
     * ----------------------------------------------------------------------------
     * The library uses the C calling convention (cdecl) on all platforms.
     *
     *   - MSVC / clang-cl: __cdecl
     *   - MinGW / Cygwin GCC: __cdecl (GCC's Windows target supports it)
     *   - GCC / Clang on non-Windows platforms: the default calling convention,
     *     so the macro expands to nothing.
     * ------------------------------------------------------------------------- */
#if defined(_WIN32)
#  if defined(__GNUC__) || defined(__clang__)
#    define LF_CDECL __attribute__((cdecl))
#  else
#    define LF_CDECL __cdecl
#  endif
#else
#  define LF_CDECL
#endif

     /* ----------------------------------------------------------------------------
      * Opaque handle types
      * ------------------------------------------------------------------------- */
    typedef void* TDataHnd;   /**< Data handle (binary buffer with an API name). */
    typedef void* TAppHnd;    /**< Application handle (groups a set of APIs).    */

    /* ----------------------------------------------------------------------------
     * Callback types (all cdecl, all executed on background worker threads)
     * ------------------------------------------------------------------------- */
     /**
      * @brief Prototype for a Call-mode (request-response) callback.
      *
      * @param trigger  User-supplied pointer passed at registration time.
      * @param input    Read-only data handle containing the request payload.
      * @param output   Writable data handle to be filled with the response.
      */
    typedef void (LF_CDECL* LF_CallFunc)(void* trigger, void* input, void* output);

    /**
     * @brief Prototype for a Notify-mode (one-way) callback.
     *
     * @param trigger  User-supplied pointer passed at registration time.
     * @param input    Read-only data handle containing the notification payload.
     */
    typedef void (LF_CDECL* LF_NotifyFunc)(void* trigger, void* input);

    /**
     * @brief Prototype for a network connect/disconnect callback.
     *
     * @param addr  UTF-8 endpoint string. Valid ONLY during the callback
     *              invocation; copy the string if you need to retain it.
     *
     * IMPORTANT: Runs on a background worker thread. Do NOT touch UI directly.
     */
    typedef void (LF_CDECL* LF_NetworkEventFunc)(const char* addr);

    /* ============================================================================
     * Library loader API (implemented by this C wrapper, not exported from DLL)
     * ============================================================================ */

     /**
      * @brief Loads the LingoFuse dynamic library and resolves all exported symbols.
      *
      * Resolution order:
      *   1. The directory containing the current executable.
      *   2. The system search path.
      *
      * @return 1 on success, 0 on failure.
      * @note Must be called before any other LF_* function.
      */
    int  LF_LoadLibrary(void);

    /**
     * @brief Unloads the dynamic library and clears all cached function pointers.
     *
     * Safe to call multiple times.
     */
    void LF_FreeLibrary(void);

    /* ============================================================================
     * DATA HANDLE - creation, destruction, raw buffer access
     * ============================================================================ */

     /**
      * @brief Creates a new data handle bound to the given API name.
      *
      * The initial payload is empty. The handle must be freed with LF_FreeData().
      *
      * @param method_name  UTF-8, null-terminated API name.
      * @return A new TDataHnd (never NULL on success).
      */
    TDataHnd LF_CreateData(const char* method_name);

    /**
     * @brief Destroys a data handle and releases its memory.
     *
     * @param hnd  Handle to free. NULL is accepted and ignored.
     */
    void LF_FreeData(TDataHnd hnd);

    /**
     * @brief Returns a pointer to the internal buffer.
     *
     * The pointer is valid until the handle is freed or resized. Do NOT free it.
     *
     * @param hnd  Data handle.
     * @return Pointer to internal memory, or NULL if the handle is empty.
     */
    void* LF_GetBuffer(TDataHnd hnd);

    /**
     * @brief Writes @p size bytes at the current position; advances the position.
     *
     * @param hnd   Data handle.
     * @param buff  Source buffer.
     * @param size  Number of bytes to write.
     * @return Number of bytes actually written (normally equals @p size).
     */
    int64_t LF_WriteBuffer(TDataHnd hnd, const void* buff, int64_t size);

    /**
     * @brief Reads up to @p size bytes from the current position into @p buff.
     *
     * @param hnd   Data handle.
     * @param buff  Destination buffer.
     * @param size  Maximum number of bytes to read.
     * @return Number of bytes actually read.
     */
    int64_t LF_ReadBuffer(TDataHnd hnd, void* buff, int64_t size);

    /**
     * @brief Returns the current read/write position.
     */
    int64_t LF_GetPos(TDataHnd hnd);

    /**
     * @brief Sets the current read/write position.
     *
     * If @p pos exceeds the current size, the buffer is implicitly expanded.
     */
    void LF_SetPos(TDataHnd hnd, int64_t pos);

    /**
     * @brief Returns the total buffer size in bytes.
     */
    int64_t LF_GetSize(TDataHnd hnd);

    /**
     * @brief Adjusts the buffer size. Newly added space is uninitialized.
     */
    void LF_SetSize(TDataHnd hnd, int64_t size);

    /* ============================================================================
     * APPLICATION HANDLE - creation, name generation, client binding
     * ============================================================================ */

     /**
      * @brief Creates a new application with the given name and description.
      *
      * @param app_name  UTF-8, null-terminated application name (unique on the
      *                  wire; matching is case-insensitive).
      * @param desc      UTF-8, null-terminated description. A NULL value is
      *                  treated as an empty string by this wrapper.
      * @return A new TAppHnd (never NULL on success).
      */
    TAppHnd LF_CreateApp(const char* app_name, const char* desc);

    /**
     * @brief Detaches the application from all clients and stops its sequenced
     *        notification threads.
     *
     * The underlying application object is NOT destroyed immediately; it remains
     * in the global pool until LF_Shutdown() is called. After LF_FreeApp() the
     * handle must be considered invalid.
     *
     * @param app_hnd  Application handle.
     */
    void LF_FreeApp(TAppHnd app_hnd);

    /**
     * @brief Generates a globally unique application name.
     *
     * The name is built from active C4 tunnel addresses, process name (with PID),
     * and a high-resolution timestamp.
     *
     * IMPORTANT (Pascal LF-APP-003):
     *   Must be called AFTER LF_PrepareDone() has returned 1. Otherwise the
     *   generated name lacks the tunnel information and may not be unique.
     *
     * IMPORTANT (Pascal LF-APP-004):
     *   The returned pointer is valid for ONLY 5 SECONDS. The library frees the
     *   underlying memory after that time. Copy the string immediately
     *   (e.g., via strdup, or a stack/heap buffer) before the pointer becomes
     *   invalid.
     *
     * @return Pointer to a null-terminated UTF-8 string (do not free).
     *         Returns an empty string "" on failure.
     */
    const char* LF_Generate_AppName(void);

    /**
     * @brief Retrieves the application name associated with the given handle.
     *
     * Same 5-second validity rule as LF_Generate_AppName (Pascal LF-APP-004).
     * Copy the string immediately.
     *
     * @param app_hnd  Application handle.
     * @return Pointer to a null-terminated UTF-8 string (do not free).
     *         Returns an empty string "" on failure.
     */
    const char* LF_Get_AppName(TAppHnd app_hnd);

    /**
     * @brief Binds the application to all currently unbound LingoFuse clients.
     *
     * Must be called AFTER LF_PrepareDone() has returned 1 and while the
     * simulated main thread is active. A client is eligible for binding only if
     * it has no app attached yet (Cli.app == NULL). Each client can host at
     * most one application.
     *
     * @param app_hnd  Application handle.
     * @return Number of clients successfully bound. 0 means either the main
     *         thread is not active or all clients are already occupied.
     */
    int LF_BindApp(TAppHnd app_hnd);

    /* ============================================================================
     * API REGISTRATION - Call (request-response) / Notify (one-way) / Unregister
     * ============================================================================ */

     /**
      * @brief Registers a Call API (request-response).
      *
      * @param app_hnd      Application handle.
      * @param method_name  UTF-8, null-terminated API name (case-insensitive).
      * @param desc         UTF-8, null-terminated description. A NULL value is
      *                     treated as an empty string by this wrapper.
      * @param trigger      User-supplied pointer passed back to the callback.
      * @param on_call      Callback function (must use LF_CDECL).
      * @return 1 on success, 0 on failure (e.g., duplicate API name).
      */
    int LF_RegisterCall(TAppHnd app_hnd,
        const char* method_name,
        const char* desc,
        void* trigger,
        LF_CallFunc on_call);

    /**
     * @brief Registers a Notify API (one-way).
     *
     * @param app_hnd      Application handle.
     * @param method_name  UTF-8, null-terminated API name (case-insensitive).
     * @param desc         UTF-8, null-terminated description. A NULL value is
     *                     treated as an empty string by this wrapper.
     * @param trigger      User-supplied pointer passed back to the callback.
     * @param on_notify    Callback function (must use LF_CDECL).
     * @return 1 on success, 0 on failure (e.g., duplicate API name).
     */
    int LF_RegisterNotify(TAppHnd app_hnd,
        const char* method_name,
        const char* desc,
        void* trigger,
        LF_NotifyFunc on_notify);

    /**
     * @brief Unregisters a previously registered API by name.
     *
     * The removal takes effect locally immediately. A network broadcast is
     * triggered; remote peers will stop seeing the API within approximately
     * 3 seconds (Pascal LF-CHK-001).
     *
     * @return 1 if the API was found and removed, 0 otherwise.
     */
    int LF_Unregister(TAppHnd app_hnd, const char* method_name);

    /* ============================================================================
     * LOCAL EXECUTION - bypass the network and invoke the callback directly
     * ============================================================================ */

     /**
      * @brief Executes a Call API locally within the same process.
      *
      * @param app_hnd  Application handle.
      * @param param    Input data handle (not freed by this function).
      * @return A new result data handle (must be freed by the caller).
      *         Never NULL on success; if the underlying call fails, an empty
      *         handle (size 0) is returned.
      */
    TDataHnd LF_LocalCall(TAppHnd app_hnd, TDataHnd param);

    /**
     * @brief Executes a Notify API locally within the same process.
     *
     * @param app_hnd  Application handle.
     * @param param    Input data handle (not freed by this function).
     */
    void LF_LocalNotify(TAppHnd app_hnd, TDataHnd param);

    /* ============================================================================
     * NETWORK PREPARATION - service/client setup and shutdown of the event loop
     * ============================================================================ */

     /**
      * @brief Clears any previously prepared services and clients.
      *
      * Call this before preparing a new set to avoid conflicts. Does not affect
      * already running services/clients; it only clears the preparation queue.
      */
    void LF_ResetPrepare(void);

    /**
     * @brief Prepares a C4 service listening on @p listening_addr and advertised
     *        as @p physics_addr.
     *
     * If the simulated main thread is already running (after LF_PrepareDone),
     * the service is created and started immediately; otherwise it is queued.
     *
     * @return A tag ID, or -1 if the address is a duplicate/invalid.
     */
    int LF_PrepareService(const char* listening_addr, const char* physics_addr);

    /**
     * @brief Prepares a client connecting to @p physics_addr and optionally
     *        attaching @p app_hnd.
     *
     * IMPORTANT (Pascal LF-NET-001):
     *   The same physical address can be used for only ONE client. A second
     *   call with the same address returns -1 and logs a "repeat connection"
     *   error, UNLESS the `Overlap_Connection` option is set to True via
     *   LF_SetOption() BEFORE the call.
     *
     *   Setting `Overlap_Connection=True` allows multiple independent client
     *   tunnels to the same address, each attached to a different app.
     *
     * @return A tag ID, or -1 if the address is a duplicate.
     */
    int LF_PrepareClient(const char* physics_addr, TAppHnd app_hnd);

    /**
     * @brief Starts the LingoFuse framework with all prepared services and clients.
     *
     * Blocks until the framework is initialised (or until the configured timeout
     * expires, depending on `Wait_Connection_ReadyOk`).
     *
     * IMPORTANT (Pascal LF-NET-003):
     *   LF_PrepareDone() returns 1 ONLY ONCE per process (without an intervening
     *   LF_Shutdown()). A second call returns 0, even though the framework is
     *   already running. Do not interpret 0 on the second call as a failure.
     *   If you must re-initialise, call LF_Shutdown() first.
     *
     * @return 1 on success, 0 on failure or repeated call.
     */
    int LF_PrepareDone(void);

    /**
     * @brief Signals the simulated main thread to exit gracefully.
     *
     * The framework stops processing network events but does not free all
     * resources. Call LF_Shutdown() for a full cleanup.
     */
    void LF_ExitMainThread(void);

    /* ============================================================================
     * REMOTE INVOCATION - Call, Notify, Sequenced_Notify
     * ============================================================================ */

     /**
      * @brief Calls a remote API and waits for a response.
      *
      * On timeout or failure, an EMPTY data handle (size 0) is returned, NOT a
      * NULL pointer. Always check LF_GetSize(result) > 0 to detect failures.
      *
      * @param app_name    Target application name (UTF-8).
      * @param param       Input data handle (not freed by this function).
      * @param timeout_ms  Timeout in milliseconds. 0 means infinite wait.
      * @return A new result data handle (must be freed by the caller).
      */
    TDataHnd LF_Call(const char* app_name, TDataHnd param, uint64_t timeout_ms);

    /**
     * @brief Sends a one-way notification to a remote application.
     *
     * Order of delivery is NOT guaranteed. Use LF_Sequenced_Notify() if
     * FIFO ordering per (app, api) pair is required.
     *
     * @param app_name  Target application name (UTF-8).
     * @param param     Input data handle (not freed by this function).
     */
    void LF_Notify(const char* app_name, TDataHnd param);

    /**
     * @brief Sends a one-way notification with FIFO ordering guarantee for the
     *        same (app, api) pair.
     *
     * The notification is queued in a dedicated thread per (app, api), so
     * delivery order is preserved. Large payloads are streamed efficiently.
     * Returns immediately after queueing.
     *
     * @param app_name  Target application name (UTF-8).
     * @param param     Input data handle (not freed by this function).
     */
    void LF_Sequenced_Notify(const char* app_name, TDataHnd param);

    /* ============================================================================
     * OPTIONS - runtime configuration (see lingofuse_import.pas for full list)
     * ============================================================================ */

     /**
      * @brief Adjusts a global runtime option.
      *
      * Supported option keys (case-insensitive, aliases accepted):
      *
      *   "password" / "passwd"
      *       C4 P2PVM authentication token (string).
      *   "Quiet"
      *       Enable/disable quiet mode (boolean).
      *   "ShowThreadID" / "ShowThread" / "Show_Thread"
      *       Show thread IDs in log output (boolean).
      *   "ConsoleOutput" / "Console_Output"
      *       Enable/disable console logging (boolean).
      *   "Overlap_Connection" / "Overlap_Client" / "OverlapConnection" /
      *   "OverlapClient" / "OverlapConnect"
      *       Allow multiple client tunnels to the same address (boolean).
      *   "Wait_Connection_ReadyOk" / "Wait_API_Prepare_Done" / "WaitConnect" /
      *   "Wait_Ready" / "WaitReady"
      *       Block until all prepared clients are ready (boolean).
      *   "Wait_Connection_Timeout" / "Wait_TimeOut" / "API_Prepare_Done_TimeOut"
      *       Timeout for the above wait (integer, milliseconds).
      *   "IPC_Serv_ThreadCount" / "IPC_ThreadCount" / "IPC_Server_ThreadCount"
      *       Number of IPC server threads (integer).
      *   "IPC_Serv_MaxQueueLength" / "IPC_MaxQueueLength"
      *       Maximum IPC message queue length (integer).
      *   "IPC_Serv_MaxMsgSize" / "IPC_MaxMsgSize"
      *       Maximum size of a single IPC message in bytes (integer).
      *   "Fixed_Sequenced_Time" / "Fixed_Sequenced_Life"
      *       Idle timeout for sequenced notification fallback (integer, ms).
      *
      * Unknown options are silently ignored. Changes are not persisted across
      * restarts.
      *
      * @param option  UTF-8, null-terminated option name.
      * @param value   UTF-8, null-terminated value.
      */
    void LF_SetOption(const char* option, const char* value);

    /* ============================================================================
     * STATUS AND DIAGNOSTICS
     * ============================================================================ */

     /**
      * @brief Returns the number of pending log messages in the status queue.
      *
      * The queue holds up to 1000 messages; older messages are discarded when
      * the limit is reached.
      *
      * IMPORTANT (Pascal LF-OPT-001 / LF-OPT-002):
      *   This function relies on the simulated main thread to process the queue.
      *   If the main thread is not running (i.e., before LF_PrepareDone), the
      *   queue may be empty or stale. Use it only after the framework is fully
      *   initialised.
      */
    int LF_GetStatusCount(void);

    /**
     * @brief Retrieves the next log message from the status queue (FIFO).
     *
     * Returns a pointer to an internal static buffer (UTF-8, null-terminated).
     * The pointer is valid only until the next call to this function; copy the
     * string immediately if you need to retain it.
     *
     * IMPORTANT: Same main-thread dependency as LF_GetStatusCount.
     *
     * @return Pointer to the message, or an empty string "" if the queue is
     *         empty. Do NOT free the returned pointer.
     */
    const char* LF_GetStatus(void);

    /**
     * @brief Injects a custom log message into the status queue.
     *
     * IMPORTANT: Same main-thread dependency as LF_GetStatusCount. Messages
     * posted before LF_PrepareDone may be discarded.
     *
     * @param status  UTF-8, null-terminated message string.
     */
    void LF_PostStatus(const char* status);

    /**
     * @brief Checks whether the simulated main thread is currently active.
     *
     * @return 1 if running, 0 if stopped or not yet started.
     */
    int LF_CheckMainThread(void);

    /**
     * @brief Checks whether an application with the given name is available.
     *
     * IMPORTANT (Pascal LF-CHK-001):
     *   The lookup is based on a local cache updated via network broadcasts
     *   with a typical propagation delay of about 3 seconds. This function can
     *   return:
     *     - false negatives immediately after an app is registered
     *     - false positives shortly after an app is unregistered
     *   It is a probing tool, not an authoritative existence test. For critical
     *   decisions, call the target API directly and handle timeouts gracefully.
     *
     * @param app_name  UTF-8, null-terminated application name.
     * @return 1 if at least one instance exists, 0 otherwise.
     */
    int LF_CheckApp(const char* app_name);

    /**
     * @brief Checks whether a specific API is available on the network for the
     *        given application.
     *
     * Searches both local and remote instances. Same cache-delay caveat as
     * LF_CheckApp.
     *
     * @param app_name  UTF-8, null-terminated application name.
     * @param api_name  UTF-8, null-terminated API name.
     * @return 1 if the API is available on at least one instance, 0 otherwise.
     */
    int LF_CheckApi(const char* app_name, const char* api_name);

    /* ============================================================================
     * SHUTDOWN
     * ============================================================================ */

     /**
      * @brief Gracefully terminates the entire LingoFuse framework.
      *
      * Steps performed (matching Pascal LF_Shutdown):
      *   1. Clears network event callbacks.
      *   2. Stops all sequenced notification threads.
      *   3. Frees all remaining data handles.
      *   4. Exits the simulated main thread.
      *   5. Clears the global application pool (destroying all TLF_App objects).
      *   6. Unloads the IPC library.
      *
      * After LF_Shutdown(), the library is fully reset and may be re-initialised
      * by calling the preparation functions again. Safe to call multiple times.
      *
      * Cleanup order (Pascal LF-CLEAN-001):
      *   LF_ExitMainThread -> LF_FreeApp(app) -> LF_Shutdown
      * Calling LF_Shutdown alone also performs steps 1, 3, and 5 above, so an
      * explicit LF_FreeApp is not strictly required before shutdown.
      */
    void LF_Shutdown(void);

    /* ============================================================================
     * NETWORK EVENTS - process-global connect/disconnect notifications
     * ============================================================================ */

     /**
      * @brief Installs or clears the global network event handlers.
      *
      * Both handlers are process-global; there is no per-client registration.
      *
      * "Connect" semantics (Pascal LF-NET-005):
      *   Fires the FIRST time a client receives a service API-info broadcast.
      *   This is NOT the TCP handshake; it is the earliest point at which the
      *   client can actually route remote calls. Gated by the internal
      *   FService_Info_Is_Onlne False -> True transition. Fires at most once
      *   per connection lifecycle (but again after an auto-reconnect).
      *
      * "Disconnect" semantics:
      *   Fires once per physical link loss. Automatic reconnects do NOT emit a
      *   Disconnect for the reconnect attempt itself.
      *
      * Threading contract (CRITICAL):
      *   - Callbacks run on a BACKGROUND WORKER THREAD, not on the calling
      *     thread and not on the simulated main thread.
      *   - The @c addr argument is valid ONLY during the callback invocation
      *     (the library frees it immediately after the callback returns).
      *     Copy the string inside the callback if you need to retain it
      *     (Pascal LF-NET-006).
      *   - Never call blocking LingoFuse functions inside these callbacks
      *     (LF_Call, LF_LocalCall, LF_PrepareDone, LF_Shutdown). It will deadlock.
      *   - In managed languages (C# / Java / Python ctypes), keep a strong
      *     reference to the delegate/callback object for as long as it is
      *     installed, otherwise the GC may collect it and cause a crash.
      *
      * Passing NULL for either argument disables that particular event.
      *
      * LF_Shutdown() automatically clears both handlers before teardown.
      *
      * @param on_connect     Callback invoked when a client becomes online.
      * @param on_disconnect  Callback invoked when a client goes offline.
      */
    void LF_Set_Network_Event(LF_NetworkEventFunc on_connect,
        LF_NetworkEventFunc on_disconnect);

    /* ============================================================================
     * HELPER FUNCTIONS - implemented by this C wrapper, NOT exported from the DLL
     * ----------------------------------------------------------------------------
     * These mirror the Pascal helper functions in `lingofuse_import.pas` and
     * rely on LF_WriteBuffer / LF_ReadBuffer / LF_GetBuffer / LF_SetPos.
     * All helpers use little-endian byte order, matching the library's wire format.
     * ============================================================================ */

     /* ----------------------------------------------------------------------------
      * Buffer offset accessor
      * ------------------------------------------------------------------------- */

      /**
       * @brief Returns a pointer to the buffer at the given byte offset.
       *
       * Mirrors Pascal's LF_GetBufferOffset. Use this to read a region of the
       * internal buffer without a copy. The pointer is valid as long as the
       * handle is not resized or freed.
       *
       * @param hnd     Data handle.
       * @param offset  Byte offset from the start of the buffer (can be 0).
       * @return Pointer to (buffer + offset), or NULL if the buffer is NULL.
       */
    void* LF_GetBufferOffset(TDataHnd hnd, int64_t offset);

    /* ----------------------------------------------------------------------------
     * Atomic write helpers (return 1 on success, 0 on failure)
     * ------------------------------------------------------------------------- */

    int LF_WriteInt8(TDataHnd hnd, int8_t   value);
    int LF_WriteUInt8(TDataHnd hnd, uint8_t  value);
    int LF_WriteInt16(TDataHnd hnd, int16_t  value);
    int LF_WriteUInt16(TDataHnd hnd, uint16_t value);
    int LF_WriteInt32(TDataHnd hnd, int32_t  value);
    int LF_WriteUInt32(TDataHnd hnd, uint32_t value);
    int LF_WriteInt64(TDataHnd hnd, int64_t  value);
    int LF_WriteUInt64(TDataHnd hnd, uint64_t value);
    int LF_WriteSingle(TDataHnd hnd, float    value);
    int LF_WriteDouble(TDataHnd hnd, double   value);

    /**
     * @brief Writes a UTF-8 string followed by a null terminator (#0).
     *
     * Empty strings ("") write exactly one byte: #0.
     *
     * A NULL @p value is treated as a failure and returns 0 immediately; no
     * bytes are written and the cursor is not advanced.
     *
     * @param hnd    Data handle.
     * @param value  Null-terminated UTF-8 string (may be empty, must not be NULL).
     * @return 1 if the full string plus the null was written, 0 otherwise.
     */
    int LF_WriteString(TDataHnd hnd, const char* value);

    /**
     * @brief Writes a raw byte sequence followed by a null terminator (#0).
     *
     * This is the byte-oriented counterpart of LF_WriteString. Unlike
     * LF_WriteString, it does NOT stop at embedded #0 bytes; it writes exactly
     * @p length bytes and appends one additional #0 byte.
     *
     * Mirrors Pascal's LF_WriteStringBytes.
     *
     * @param hnd     Data handle.
     * @param data    Source byte buffer (may be NULL only if @p length is 0).
     * @param length  Number of bytes to write (not including the appended #0).
     * @return 1 on success, 0 on failure.
     */
    int LF_WriteStringBytes(TDataHnd hnd, const void* data, int64_t length);

    /* ----------------------------------------------------------------------------
     * Atomic read helpers (return 1 on success, 0 on failure)
     * ------------------------------------------------------------------------- */

    int LF_ReadInt8(TDataHnd hnd, int8_t* out);
    int LF_ReadUInt8(TDataHnd hnd, uint8_t* out);
    int LF_ReadInt16(TDataHnd hnd, int16_t* out);
    int LF_ReadUInt16(TDataHnd hnd, uint16_t* out);
    int LF_ReadInt32(TDataHnd hnd, int32_t* out);
    int LF_ReadUInt32(TDataHnd hnd, uint32_t* out);
    int LF_ReadInt64(TDataHnd hnd, int64_t* out);
    int LF_ReadUInt64(TDataHnd hnd, uint64_t* out);
    int LF_ReadSingle(TDataHnd hnd, float* out);
    int LF_ReadDouble(TDataHnd hnd, double* out);

    /**
     * @brief Reads a null-terminated UTF-8 string from the current position.
     *
     * Behavior (matching Pascal's fault-tolerant LF_ReadString in
     * `lingofuse_import.pas`):
     *
     *   Case 1 - A #0 is found within the buffer:
     *       The bytes up to (but not including) the #0 are copied into @p buf,
     *       and the cursor is advanced to just past the #0.
     *
     *   Case 2 - No #0 is found before the end of the buffer (fault-tolerant):
     *       The remaining bytes up to the end of the buffer are copied, and the
     *       cursor is advanced to (buffer size + 1) ¡ª i.e. ONE BYTE PAST the
     *       end of the buffer. This matches Pascal's LF_SetPos(Hnd, e + 1)
     *       with e == size: the underlying library implicitly grows the buffer
     *       by one byte to accommodate the new position.
     *
     *       This case is COMMON when receiving data from an HTTP bridge or a
     *       non-Pascal client that does not append a #0 terminator. The cursor
     *       semantics are identical to the C# / Python / Pascal wrappers.
     *
     *   Case 3 - No data available (cursor is at or past the end of the buffer):
     *       Returns 0 and sets @p buf to an empty string. The cursor is left
     *       unchanged.
     *
     *   Case 4 - @p buf is too small to hold the whole string:
     *       Returns 0 and does NOT advance the cursor (caller can retry with a
     *       larger buffer).
     *
     * On success, @p buf is always null-terminated.
     *
     * This C wrapper does NOT validate UTF-8; the copied bytes are raw.
     *
     * @param hnd       Data handle.
     * @param buf       Output buffer (must be at least 1 byte).
     * @param buf_size  Size of @p buf in bytes.
     * @return 1 on success (either Case 1 or Case 2 above), 0 on failure.
     */
    int LF_ReadString(TDataHnd hnd, char* buf, size_t buf_size);

    /**
     * @brief Reads a byte sequence that is either terminated by a #0 or ends at
     *        the end of the buffer.
     *
     * This is the byte-oriented counterpart of LF_ReadString. It mirrors
     * Pascal's LF_ReadStringBytes:
     *
     *   Case 1 - A #0 is found:
     *       Copies the bytes up to (but not including) the #0, advances the
     *       cursor past the #0. Returns the number of bytes copied.
     *
     *   Case 2 - No #0 found before the end of the buffer:
     *       Copies all remaining bytes, advances the cursor to
     *       (buffer size + 1) ¡ª i.e. ONE BYTE PAST the end of the buffer.
     *       This matches Pascal's LF_SetPos(Hnd, e + 1) with e == size; the
     *       underlying library implicitly grows the buffer by one byte.
     *       Returns the number of bytes copied.
     *
     *   Case 3 - No data available (cursor is at or past the end of the buffer):
     *       Returns -1. The cursor is left unchanged.
     *
     *   Case 4 - @p buf_size is too small:
     *       Returns -1 and does NOT advance the cursor.
     *
     * Note: an empty string (just a #0 byte) is a valid input and yields 0
     * bytes copied with a successful return value of 0.
     *
     * @param hnd       Data handle.
     * @param buf       Destination buffer (may be NULL if @p buf_size is 0).
     * @param buf_size  Size of @p buf in bytes.
     * @return Number of bytes copied (>= 0) on success, -1 on failure.
     */
    int64_t LF_ReadStringBytes(TDataHnd hnd, void* buf, int64_t buf_size);

#ifdef __cplusplus
}
#endif

#endif /* LINGOFUSE_H_INCLUDED */