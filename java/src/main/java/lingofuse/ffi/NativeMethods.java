package lingofuse.ffi;

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/**
 * FFM downcall handles for the 37 exported functions of the LingoFuse
 * C ABI.
 *
 * <p>This class is the ONLY place in the Java binding where native
 * code is invoked. Every higher-level wrapper ({@code DataHandle},
 * {@code AppHandle}, {@code Framework}, ...) goes through the
 * {@link MethodHandle}s declared here.
 *
 * <p>Every symbol is resolved exactly once, during class
 * initialisation, against the {@link SymbolLookup} returned by
 * {@link LibraryLoader#lookup()}. If any symbol cannot be resolved,
 * class initialisation fails with an {@link UnsatisfiedLinkError}
 * whose message names the missing symbol. This makes a
 * version-mismatch between the Java binding and the native library
 * fail loudly at the first touch of this class, rather than silently
 * producing a null pointer at some later call site.
 *
 * <p>Type mapping (C ABI to Java):
 * <ul>
 *   <li>{@code void*}, {@code TDataHnd}, {@code TAppHnd},
 *       {@code const char*} -&gt; {@link MemorySegment}</li>
 *   <li>{@code int} -&gt; {@code int}</li>
 *   <li>{@code int64_t}, {@code uint64_t} -&gt; {@code long}</li>
 *   <li>{@code void} -&gt; no return value</li>
 * </ul>
 *
 * <p>All handles are represented uniformly as {@link MemorySegment}
 * values. The semantic distinction between a data handle and an
 * application handle is enforced by the RAII layer, not here.
 *
 * <p>Threading: every {@link MethodHandle} returned by
 * {@code Linker.downcallHandle} is thread-safe and may be invoked
 * concurrently from any number of threads. This matches the native
 * library's documented guarantee.
 */
public final class NativeMethods {

    private NativeMethods() {
        // Utility class; no instances.
    }

    // ------------------------------------------------------------------
    // Linker
    // ------------------------------------------------------------------

    /**
     * The platform's native linker. Resolves the C calling convention
     * ({@code cdecl} on every supported 64-bit platform).
     */
    private static final Linker LINKER = Linker.nativeLinker();

    // ------------------------------------------------------------------
    // Symbol resolution helper
    // ------------------------------------------------------------------

    /**
     * Resolves one symbol and creates a downcall handle from it.
     *
     * @param name       the exact symbol name as exported by the library
     * @param descriptor the function's signature
     * @return a callable handle
     * @throws UnsatisfiedLinkError if the symbol is not present
     */
    private static MethodHandle resolve(String name, FunctionDescriptor descriptor) {
        SymbolLookup lookup = LibraryLoader.lookup();
        MemorySegment symbol = lookup.find(name)
                .orElseThrow(() -> new UnsatisfiedLinkError(
                        "LingoFuse symbol not found: " + name
                                + " (library: "
                                + LibraryLoader.selectPlatformFileName()
                                + ")"));
        return LINKER.downcallHandle(symbol, descriptor);
    }

    // ==================================================================
    // Data handle operations (10 exports)
    // ==================================================================

    /**
     * {@code TDataHnd LF_CreateData(const char* method_name);}
     *
     * <p>Creates an AUTO-RECYCLED data handle bound to the given API
     * name. The handle is added to the library's idle pool and will
     * be reclaimed after 10 minutes of idle time (scanned every 5
     * seconds). It must be released with {@link #LF_FreeData}.
     *
     * <p>Argument: UTF-8, NUL-terminated API name.
     * <p>Return: a non-null handle, or a null segment on failure.
     */
    public static final MethodHandle LF_CreateData = resolve(
            "LF_CreateData",
            FunctionDescriptor.of(ADDRESS, ADDRESS));

    /**
     * {@code TDataHnd LF_CreateData_Permanent(const char* method_name);}
     *
     * <p>Creates a PERMANENT data handle bound to the given API name.
     *
     * <p>Difference from {@link #LF_CreateData}: the handle is NOT
     * added to the idle pool, so the automatic reclaimer will never
     * free it. {@link #LF_FreeData} releases it synchronously.
     *
     * <p>Argument: UTF-8, NUL-terminated API name.
     * <p>Return: a non-null handle, or a null segment on failure.
     */
    public static final MethodHandle LF_CreateData_Permanent = resolve(
            "LF_CreateData_Permanent",
            FunctionDescriptor.of(ADDRESS, ADDRESS));

    /**
     * {@code void LF_FreeData(TDataHnd hnd);}
     *
     * <p>Releases a data handle. Passing a null segment is safe and
     * is ignored by the native side.
     *
     * <p>For an auto-recycled handle this only marks the handle as
     * deleted; the actual release happens on the next pool scan (at
     * most 5 seconds later). For a permanent handle the release is
     * synchronous.
     *
     * <p>This call is a NO-OP while the simulated main thread is not
     * active (before {@code LF_PrepareDone} or after
     * {@code LF_ExitMainThread}).
     */
    public static final MethodHandle LF_FreeData = resolve(
            "LF_FreeData",
            FunctionDescriptor.ofVoid(ADDRESS));

    /**
     * {@code void* LF_GetBuffer(TDataHnd hnd);}
     *
     * <p>Returns a pointer to the handle's internal buffer. The
     * pointer is invalidated by any subsequent resize (including
     * implicit growth caused by a write or by a position set past the
     * current size). Do not free the pointer.
     *
     * <p>Return: a raw pointer as a zero-length {@link MemorySegment},
     * or {@link MemorySegment#NULL} if the buffer is empty.
     */
    public static final MethodHandle LF_GetBuffer = resolve(
            "LF_GetBuffer",
            FunctionDescriptor.of(ADDRESS, ADDRESS));

    /**
     * {@code int64_t LF_WriteBuffer(TDataHnd hnd, const void* buff, int64_t size);}
     *
     * <p>Writes {@code size} bytes at the current cursor. The buffer
     * grows as needed; the cursor advances by the number of bytes
     * written.
     *
     * <p>Return: the number of bytes actually written.
     */
    public static final MethodHandle LF_WriteBuffer = resolve(
            "LF_WriteBuffer",
            FunctionDescriptor.of(JAVA_LONG, ADDRESS, ADDRESS, JAVA_LONG));

    /**
     * {@code int64_t LF_ReadBuffer(TDataHnd hnd, void* buff, int64_t size);}
     *
     * <p>Reads up to {@code size} bytes into {@code buff} at the
     * current cursor. The cursor advances by the number of bytes
     * actually read.
     *
     * <p>Return: the number of bytes actually read (may be less than
     * {@code size} at end-of-buffer).
     */
    public static final MethodHandle LF_ReadBuffer = resolve(
            "LF_ReadBuffer",
            FunctionDescriptor.of(JAVA_LONG, ADDRESS, ADDRESS, JAVA_LONG));

    /**
     * {@code int64_t LF_GetPos(TDataHnd hnd);}
     *
     * <p>Returns the current read/write cursor.
     */
    public static final MethodHandle LF_GetPos = resolve(
            "LF_GetPos",
            FunctionDescriptor.of(JAVA_LONG, ADDRESS));

    /**
     * {@code void LF_SetPos(TDataHnd hnd, int64_t pos);}
     *
     * <p>Sets the read/write cursor. A position past the end of the
     * buffer implicitly grows the buffer; the new bytes are
     * uninitialised.
     */
    public static final MethodHandle LF_SetPos = resolve(
            "LF_SetPos",
            FunctionDescriptor.ofVoid(ADDRESS, JAVA_LONG));

    /**
     * {@code int64_t LF_GetSize(TDataHnd hnd);}
     *
     * <p>Returns the total buffer size in bytes.
     */
    public static final MethodHandle LF_GetSize = resolve(
            "LF_GetSize",
            FunctionDescriptor.of(JAVA_LONG, ADDRESS));

    /**
     * {@code void LF_SetSize(TDataHnd hnd, int64_t size);}
     *
     * <p>Resizes the buffer. Newly added bytes are uninitialised.
     */
    public static final MethodHandle LF_SetSize = resolve(
            "LF_SetSize",
            FunctionDescriptor.ofVoid(ADDRESS, JAVA_LONG));

    // ==================================================================
    // Application handle operations (5 exports)
    // ==================================================================

    /**
     * {@code TAppHnd LF_CreateApp(const char* app_name, const char* desc);}
     *
     * <p>Creates a new application with the given name and
     * description. Both arguments must be UTF-8, NUL-terminated. A
     * null {@code desc} is treated as an empty string.
     *
     * <p>Return: a non-null handle, or a null segment on failure.
     */
    public static final MethodHandle LF_CreateApp = resolve(
            "LF_CreateApp",
            FunctionDescriptor.of(ADDRESS, ADDRESS, ADDRESS));

    /**
     * {@code void LF_FreeApp(TAppHnd app_hnd);}
     *
     * <p>Performs the first stage of a two-stage destruction: the
     * application is detached from all clients and its sequenced
     * threads are stopped. The underlying object remains alive in the
     * global pool until {@link #LF_Shutdown} is called.
     *
     * <p>After this call, the handle is invalid.
     */
    public static final MethodHandle LF_FreeApp = resolve(
            "LF_FreeApp",
            FunctionDescriptor.ofVoid(ADDRESS));

    /**
     * {@code const char* LF_Generate_AppName(void);}
     *
     * <p>Returns a pointer to a UTF-8, NUL-terminated string. The
     * pointer is valid for approximately 5 seconds; the caller MUST
     * copy the string before then. The higher-level wrapper
     * {@code Framework.generateAppName()} does this automatically.
     *
     * <p>Return: a pointer into a temporary buffer.
     */
    public static final MethodHandle LF_Generate_AppName = resolve(
            "LF_Generate_AppName",
            FunctionDescriptor.of(ADDRESS));

    /**
     * {@code const char* LF_Get_AppName(TAppHnd app_hnd);}
     *
     * <p>Returns a pointer to the application's name. Same 5-second
     * validity rule as {@link #LF_Generate_AppName}.
     */
    public static final MethodHandle LF_Get_AppName = resolve(
            "LF_Get_AppName",
            FunctionDescriptor.of(ADDRESS, ADDRESS));

    /**
     * {@code int LF_BindApp(TAppHnd app_hnd);}
     *
     * <p>Binds the application to all currently unbound clients.
     * Must be called after the simulated main thread is running.
     *
     * <p>Return: the number of clients bound, or 0 if no free client
     * was available or the main thread is not active.
     */
    public static final MethodHandle LF_BindApp = resolve(
            "LF_BindApp",
            FunctionDescriptor.of(JAVA_INT, ADDRESS));

    // ==================================================================
    // API registration (3 exports)
    // ==================================================================

    /**
     * {@code int LF_RegisterCall(TAppHnd app_hnd, const char* method_name,
     *                            const char* desc, void* trigger,
     *                            LF_CallFunc on_call);}
     *
     * <p>Registers a Call-mode (request-response) API.
     *
     * <p>The {@code on_call} argument must be an FFM upcall stub
     * created with {@link NativeTypes#LF_CALL_EVENT}. The trigger
     * pointer is passed through to the callback unchanged and may be
     * {@link MemorySegment#NULL}.
     *
     * <p>Return: 1 on success, 0 if the API name is already taken.
     */
    public static final MethodHandle LF_RegisterCall = resolve(
            "LF_RegisterCall",
            FunctionDescriptor.of(JAVA_INT,
                    ADDRESS,  // TAppHnd
                    ADDRESS,  // const char* method_name
                    ADDRESS,  // const char* desc
                    ADDRESS,  // void* trigger
                    ADDRESS));// LF_CallFunc

    /**
     * {@code int LF_RegisterNotify(TAppHnd app_hnd, const char* method_name,
     *                              const char* desc, void* trigger,
     *                              LF_NotifyFunc on_notify);}
     *
     * <p>Registers a Notify-mode (one-way) API. The {@code on_notify}
     * argument must be an FFM upcall stub created with
     * {@link NativeTypes#LF_NOTIFY_EVENT}.
     *
     * <p>Return: 1 on success, 0 if the API name is already taken.
     */
    public static final MethodHandle LF_RegisterNotify = resolve(
            "LF_RegisterNotify",
            FunctionDescriptor.of(JAVA_INT,
                    ADDRESS,  // TAppHnd
                    ADDRESS,  // const char* method_name
                    ADDRESS,  // const char* desc
                    ADDRESS,  // void* trigger
                    ADDRESS));// LF_NotifyFunc

    /**
     * {@code int LF_Unregister(TAppHnd app_hnd, const char* method_name);}
     *
     * <p>Removes a previously registered API. Local effect is
     * immediate; a network broadcast propagates within a few seconds.
     *
     * <p>Return: 1 if the API was found and removed, 0 otherwise.
     */
    public static final MethodHandle LF_Unregister = resolve(
            "LF_Unregister",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));

    // ==================================================================
    // Local execution (2 exports)
    // ==================================================================

    /**
     * {@code TDataHnd LF_LocalCall(TAppHnd app_hnd, TDataHnd param);}
     *
     * <p>Executes a Call API within the same process, bypassing the
     * network. The input handle is NOT consumed by this call; the
     * caller retains ownership.
     *
     * <p>Return: a new handle owning the result. The caller must
     * release it with {@link #LF_FreeData}. When the target API is
     * not registered, the returned handle has size 0.
     */
    public static final MethodHandle LF_LocalCall = resolve(
            "LF_LocalCall",
            FunctionDescriptor.of(ADDRESS, ADDRESS, ADDRESS));

    /**
     * {@code void LF_LocalNotify(TAppHnd app_hnd, TDataHnd param);}
     *
     * <p>Executes a Notify API within the same process. The input
     * handle is NOT consumed by this call.
     */
    public static final MethodHandle LF_LocalNotify = resolve(
            "LF_LocalNotify",
            FunctionDescriptor.ofVoid(ADDRESS, ADDRESS));

    // ==================================================================
    // Network preparation (5 exports)
    // ==================================================================

    /**
     * {@code void LF_ResetPrepare(void);}
     *
     * <p>Clears any previously prepared services and clients. Running
     * services and clients are not affected.
     */
    public static final MethodHandle LF_ResetPrepare = resolve(
            "LF_ResetPrepare",
            FunctionDescriptor.ofVoid());

    /**
     * {@code int LF_PrepareService(const char* listening_addr,
     *                              const char* physics_addr);}
     *
     * <p>Prepares a C4 service listening on {@code listening_addr}
     * and advertised as {@code physics_addr}. Both arguments must be
     * UTF-8, NUL-terminated.
     *
     * <p>Return: an internal tag on success, or -1 for a duplicate
     * address.
     */
    public static final MethodHandle LF_PrepareService = resolve(
            "LF_PrepareService",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));

    /**
     * {@code int LF_PrepareClient(const char* physics_addr, TAppHnd app_hnd);}
     *
     * <p>Prepares a C4 client connecting to {@code physics_addr} and
     * optionally attaching {@code app_hnd}. Pass
     * {@link MemorySegment#NULL} for a pure consumer.
     *
     * <p>Return: an internal tag on success, or -1 for a duplicate
     * address (unless {@code Overlap_Connection} is enabled).
     */
    public static final MethodHandle LF_PrepareClient = resolve(
            "LF_PrepareClient",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));

    /**
     * {@code int LF_PrepareDone(void);}
     *
     * <p>Starts the LingoFuse framework with all prepared services
     * and clients.
     *
     * <p>Return: 1 on success. Returns 0 on a second call in the same
     * process without an intervening {@link #LF_Shutdown}, which is
     * NOT a failure.
     */
    public static final MethodHandle LF_PrepareDone = resolve(
            "LF_PrepareDone",
            FunctionDescriptor.of(JAVA_INT));

    /**
     * {@code void LF_ExitMainThread(void);}
     *
     * <p>Requests the simulated main thread to exit. Does not release
     * all resources; call {@link #LF_Shutdown} for a full cleanup.
     *
     * <p>This call also flushes the data handle pool, releasing every
     * outstanding handle (including permanent ones). Do not use any
     * data handle after this call has returned.
     */
    public static final MethodHandle LF_ExitMainThread = resolve(
            "LF_ExitMainThread",
            FunctionDescriptor.ofVoid());

    // ==================================================================
    // Remote invocation (3 exports)
    // ==================================================================

    /**
     * {@code TDataHnd LF_Call(const char* app_name, TDataHnd param,
     *                          uint64_t timeout_ms);}
     *
     * <p>Performs a synchronous remote call.
     *
     * <p>On timeout or failure, an EMPTY handle (size 0) is returned,
     * not a null pointer. Always check {@code LF_GetSize(result) > 0}
     * to detect failures.
     *
     * <p>The input handle is NOT consumed by this call. The returned
     * handle is NEW and must be released by the caller.
     */
    public static final MethodHandle LF_Call = resolve(
            "LF_Call",
            FunctionDescriptor.of(ADDRESS, ADDRESS, ADDRESS, JAVA_LONG));

    /**
     * {@code void LF_Notify(const char* app_name, TDataHnd param);}
     *
     * <p>Sends a one-way notification. Delivery order is NOT
     * guaranteed; use {@link #LF_Sequenced_Notify} when FIFO ordering
     * is required.
     */
    public static final MethodHandle LF_Notify = resolve(
            "LF_Notify",
            FunctionDescriptor.ofVoid(ADDRESS, ADDRESS));

    /**
     * {@code void LF_Sequenced_Notify(const char* app_name, TDataHnd param);}
     *
     * <p>Sends a one-way notification with FIFO ordering guaranteed
     * for the same {@code (app, api)} pair.
     */
    public static final MethodHandle LF_Sequenced_Notify = resolve(
            "LF_Sequenced_Notify",
            FunctionDescriptor.ofVoid(ADDRESS, ADDRESS));

    // ==================================================================
    // Options and diagnostics (7 exports)
    // ==================================================================

    /**
     * {@code void LF_SetOption(const char* option, const char* value);}
     *
     * <p>Adjusts a global runtime option. Unknown option names are
     * silently ignored by the native side.
     */
    public static final MethodHandle LF_SetOption = resolve(
            "LF_SetOption",
            FunctionDescriptor.ofVoid(ADDRESS, ADDRESS));

    /**
     * {@code int LF_GetStatusCount(void);}
     *
     * <p>Returns the number of pending log messages in the status
     * queue. The queue holds up to 1000 messages.
     */
    public static final MethodHandle LF_GetStatusCount = resolve(
            "LF_GetStatusCount",
            FunctionDescriptor.of(JAVA_INT));

    /**
     * {@code const char* LF_GetStatus(void);}
     *
     * <p>Returns a pointer to the next log message in a static buffer
     * that the next call will overwrite. Copy the string immediately
     * via {@code MemorySegment.getString(0)}.
     */
    public static final MethodHandle LF_GetStatus = resolve(
            "LF_GetStatus",
            FunctionDescriptor.of(ADDRESS));

    /**
     * {@code void LF_PostStatus(const char* status);}
     *
     * <p>Injects a custom log message into the status queue.
     */
    public static final MethodHandle LF_PostStatus = resolve(
            "LF_PostStatus",
            FunctionDescriptor.ofVoid(ADDRESS));

    /**
     * {@code int LF_CheckMainThread(void);}
     *
     * <p>Returns 1 if the simulated main thread is currently running.
     */
    public static final MethodHandle LF_CheckMainThread = resolve(
            "LF_CheckMainThread",
            FunctionDescriptor.of(JAVA_INT));

    /**
     * {@code int LF_CheckApp(const char* app_name);}
     *
     * <p>Returns 1 if an application with the given name is
     * available. The lookup uses a local cache updated by network
     * broadcasts with an approximate 3-second delay.
     */
    public static final MethodHandle LF_CheckApp = resolve(
            "LF_CheckApp",
            FunctionDescriptor.of(JAVA_INT, ADDRESS));

    /**
     * {@code int LF_CheckApi(const char* app_name, const char* api_name);}
     *
     * <p>Returns 1 if the named API is available for the given
     * application. Same cache caveat as {@link #LF_CheckApp}.
     */
    public static final MethodHandle LF_CheckApi = resolve(
            "LF_CheckApi",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));

    // ==================================================================
    // Shutdown (1 export)
    // ==================================================================

    /**
     * {@code void LF_Shutdown(void);}
     *
     * <p>Gracefully terminates the framework, releasing all
     * resources. Clears network event callbacks, stops sequenced
     * threads, frees all remaining data handles (including permanent
     * ones), exits the main thread, clears the global app pool, and
     * unloads the IPC library.
     *
     * <p>Safe to call multiple times. After this call, the library
     * may be re-initialised by calling {@link #LF_ResetPrepare} /
     * {@link #LF_PrepareService} / {@link #LF_PrepareClient} /
     * {@link #LF_PrepareDone} again.
     */
    public static final MethodHandle LF_Shutdown = resolve(
            "LF_Shutdown",
            FunctionDescriptor.ofVoid());

    // ==================================================================
    // Network events (1 export)
    // ==================================================================

    /**
     * {@code void LF_Set_Network_Event(LF_NetworkEventFunc on_connect,
     *                                   LF_NetworkEventFunc on_disconnect);}
     *
     * <p>Installs or clears the process-global network event handlers.
     * Both arguments must be FFM upcall stubs created with
     * {@link NativeTypes#LF_NETWORK_EVENT}, or
     * {@link MemorySegment#NULL} to disable the corresponding event.
     *
     * <p>The callbacks run on a background worker thread; the
     * {@code addr} string is freed by the library as soon as the
     * callback returns.
     */
    public static final MethodHandle LF_Set_Network_Event = resolve(
            "LF_Set_Network_Event",
            FunctionDescriptor.ofVoid(ADDRESS, ADDRESS));
}