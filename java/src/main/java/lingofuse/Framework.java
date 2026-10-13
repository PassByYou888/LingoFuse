package lingofuse;

import lingofuse.errors.LingoFuseException;
import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;
import lingofuse.ffi.NativeTypes;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.Objects;
import java.util.function.BiConsumer;

import lingofuse.async.AsyncOp;
import lingofuse.async.AsyncResultHandler;
import lingofuse.async.AsyncSupport;
import lingofuse.async.TypedAsyncResultHandler;

/**
 * Public facade over the process-wide LingoFuse native functions.
 *
 * <p>This class exposes the operations that do not fit the
 * {@link DataHandle} or {@link AppHandle} abstractions:
 *
 * <ul>
 *   <li>Network preparation: {@link #resetPrepare()},
 *       {@link #prepareService(String, String)},
 *       {@link #prepareClient(String, AppHandle)},
 *       {@link #prepareDone()}, {@link #exitMainThread()}.</li>
 *   <li>Remote invocation by App name:
 *       {@link #call(String, DataHandle, long)},
 *       {@link #tryCall(String, DataHandle, long)},
 *       {@link #notify(String, DataHandle)},
 *       {@link #sequencedNotify(String, DataHandle)}.</li>
 *   <li>Remote invocation by UID:
 *       {@link #uidCall(byte[], DataHandle, long)},
 *       {@link #tryUidCall(byte[], DataHandle, long)},
 *       {@link #uidNotify(byte[], DataHandle)},
 *       {@link #uidSequencedNotify(byte[], DataHandle)}.</li>
 *   <li>Remote invocation by P2P name:
 *       {@link #p2pCall(String, DataHandle, long)},
 *       {@link #tryP2pCall(String, DataHandle, long)},
 *       {@link #p2pNotify(String, DataHandle)},
 *       {@link #p2pSequencedNotify(String, DataHandle)}.</li>
 *   <li>Runtime options: {@link #setOption(String, String)},
 *       {@link #getOption(String)}. See {@link Options} for the
 *       typed shortcuts.</li>
 *   <li>Application name generation and query:
 *       {@link #generateAppName()}, {@link #getAppName(AppHandle)}.</li>
 *   <li>Process-wide shutdown: {@link #shutdown()}.</li>
 *   <li>Callback error reporting:
 *       {@link #setCallbackErrorHandler(BiConsumer)}.</li>
 * </ul>
 *
 * <p>The class is a thin facade. It performs no caching, no state
 * management, and no lifecycle coordination. Every method forwards to
 * exactly one native function.
 *
 * <h2>Three addressing modes</h2>
 *
 * <p>Remote invocation comes in three orthogonal flavours, each
 * addressing a different routing key:
 *
 * <ul>
 *   <li><b>App name</b> ({@link #call}, {@link #notify},
 *       {@link #sequencedNotify}) - local-first routing. If the caller
 *       process itself hosts an App with the matching name and API,
 *       the call is serviced locally without touching the network.</li>
 *   <li><b>UID</b> ({@link #uidCall}, {@link #uidNotify},
 *       {@link #uidSequencedNotify}) - local-first routing, matching
 *       App-name routing. Routes to the exact client whose TunnelLink
 *       produced the given 32-byte UID. The UID can address ANY API
 *       registered on the target, without requiring the caller to
 *       know the target App name.</li>
 *   <li><b>P2P name</b> ({@link #p2pCall}, {@link #p2pNotify},
 *       {@link #p2pSequencedNotify}) - NOT local-first. Routes to any
 *       client in a user-defined group. The server-side dispatcher
 *       owns the load-balancing state and picks the actual target.</li>
 * </ul>
 *
 * <h2>UID argument representation</h2>
 *
 * <p>The C ABI declares the UID parameter of every {@code LF_UID_*}
 * function as {@code TP2P_UID___} (a 32-byte array). In cdecl, an
 * array parameter decays to a pointer, so this class accepts the UID
 * as a Java {@code byte[]} of length exactly 32, copies it into a
 * confined Arena on every call, and passes the resulting segment.
 * Length mismatches are rejected with
 * {@link IllegalArgumentException} before any native call is made.
 *
 * <p>Note that this is a DIFFERENT role from the
 * {@code LF_Get_P2P_UID} RETURN value, which is also a pointer but
 * refers to a 32-byte buffer owned by the framework. See
 * {@link DataHandle#getP2pUid()} for the return-role contract.
 *
 * <h2>Callback error reporting</h2>
 *
 * <p>Callback bodies registered through {@link AppHandle} or
 * {@code P2PRegistry} run on native worker threads. An exception
 * escaping such a body would cross into the C stack and could
 * destabilize the process, so every callback is wrapped to swallow
 * exceptions.
 *
 * <p>The wrapper reports every swallowed exception through two
 * channels:
 *
 * <ol>
 *   <li>The handler installed via
 *       {@link #setCallbackErrorHandler(BiConsumer)}, if any. This is
 *       the intended integration point for a real logging pipeline
 *       (SLF4J, Log4j, ...).</li>
 *   <li>{@link System#err}, unconditionally. This gives every
 *       swallowed exception a default visible sink without requiring
 *       the application to install a handler.</li>
 * </ol>
 *
 * <p>The handler is optional. A failure inside the handler itself is
 * swallowed, so a broken logger cannot destabilize the process.
 */
public final class Framework {

    private Framework() {
        // Utility class; no instances.
    }

    // ==================================================================
    // Callback error reporting
    // ==================================================================

    /**
     * The process-wide callback error handler. Null when no handler
     * has been installed. Volatile so that a handler installed on one
     * thread is visible to callbacks running on another.
     */
    private static volatile BiConsumer<String, Throwable> callbackErrorHandler;

    /**
     * Installs a process-wide callback error handler. Passing null
     * removes the handler.
     *
     * <p>The handler is invoked with two arguments:
     * <ul>
     *   <li>a short identifier for the callback site, for example
     *       {@code "AppHandle.registerCall[add]"};</li>
     *   <li>the exception thrown by the user callback.</li>
     * </ul>
     *
     * <p>The handler runs on the native worker thread that ran the
     * failing callback. It must not block and must not call any
     * blocking LingoFuse function.
     *
     * @param handler the handler, or null to remove the current one
     */
    public static void setCallbackErrorHandler(
            BiConsumer<String, Throwable> handler) {
        callbackErrorHandler = handler;
    }

    /**
     * Internal bridge used by {@link AppHandle} and
     * {@code P2PRegistry} to report a swallowed callback exception.
     *
     * <p>This method is public because it is also called by the
     * asynchronous subsystem in {@code lingofuse.async}, which lives
     * in a different package. It is not intended to be called by
     * application code.
     *
     * @param source a short identifier for the callback site
     * @param t      the exception thrown by the user callback
     */
    public static void reportCallbackError(String source, Throwable t) {
        BiConsumer<String, Throwable> handler = callbackErrorHandler;
        if (handler != null) {
            try {
                handler.accept(source, t);
            } catch (Throwable ignored) {
                // A handler that throws must not be allowed to escape
                // into the native worker thread. Drop the secondary
                // failure.
            }
        }
        // Always write to stderr as well. This gives every swallowed
        // exception a default visible sink.
        try {
            System.err.println(
                    "[LingoFuse] Callback error in " + source + ": " + t);
            t.printStackTrace(System.err);
        } catch (Throwable ignored) {
            // Even stderr may be unavailable in some embeddings.
        }
    }

    // ==================================================================
    // Network preparation
    // ==================================================================

    /**
     * Clears any previously prepared services and clients.
     *
     * <p>Running services and clients are not affected; this only
     * clears the preparation queue.
     */
    public static void resetPrepare() {
        NativeCall.callVoid(NativeMethods.LF_ResetPrepare);
    }

    /**
     * Prepares a C4 service listening on {@code listeningAddr} and
     * advertised as {@code physicsAddr}.
     *
     * <p>If the simulated main thread is already running (after
     * {@link #prepareDone()}), the service is created and started
     * immediately; otherwise it is queued until {@code prepareDone}.
     *
     * @param listeningAddr the local binding address, for example
     *                      {@code "0.0.0.0:9898"} or
     *                      {@code "ipc:my_service"}; must not be null
     * @param physicsAddr   the address advertised to clients; must not
     *                      be null
     * @return an internal tag on success, or -1 for a duplicate or
     *         invalid address
     * @throws NullPointerException if either argument is null
     */
    public static int prepareService(String listeningAddr, String physicsAddr) {
        Objects.requireNonNull(listeningAddr, "listeningAddr must not be null");
        Objects.requireNonNull(physicsAddr, "physicsAddr must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment listenSeg = arena.allocateFrom(listeningAddr);
            MemorySegment physicsSeg = arena.allocateFrom(physicsAddr);
            return NativeCall.callInt(
                    NativeMethods.LF_PrepareService, listenSeg, physicsSeg);
        }
    }

    /**
     * Prepares a C4 client connecting to {@code physicsAddr}.
     *
     * <p>Pass {@code null} for a pure consumer that does not expose
     * any application.
     *
     * @param physicsAddr the address of the target service; must not
     *                    be null
     * @param app         the application to expose, or null
     * @return an internal tag on success, or -1 for a duplicate
     *         address (unless {@code Overlap_Connection} is enabled
     *         via {@link #setOption(String, String)})
     * @throws NullPointerException if {@code physicsAddr} is null
     */
    public static int prepareClient(String physicsAddr, AppHandle app) {
        Objects.requireNonNull(physicsAddr, "physicsAddr must not be null");

        MemorySegment appSeg = (app == null)
                ? MemorySegment.NULL
                : app.raw();

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment addrSeg = arena.allocateFrom(physicsAddr);
            return NativeCall.callInt(
                    NativeMethods.LF_PrepareClient, addrSeg, appSeg);
        }
    }

    /**
     * Starts the LingoFuse framework with all prepared services and
     * clients.
     *
     * <p>Returns 1 only once per process. A second call without an
     * intervening {@link #shutdown()} returns 0; this is NOT a
     * failure. If a restart is required, call {@link #shutdown()}
     * first, then {@link #resetPrepare()}, then this method again.
     *
     * <p>By default ({@code Wait_Connection_ReadyOk=True}), this
     * method blocks until every prepared client is online, or until
     * the configured timeout ({@code Wait_Connection_Timeout},
     * default 30 s) expires. Both options can be changed via
     * {@link #setOption(String, String)} or the typed shortcuts in
     * {@link Options}.
     *
     * @return 1 on success, 0 otherwise
     */
    public static int prepareDone() {
        return NativeCall.callInt(NativeMethods.LF_PrepareDone);
    }

    /**
     * Requests the simulated main thread to exit.
     *
     * <p>Stops the network event loop but does not release all
     * resources; call {@link #shutdown()} for a full cleanup.
     *
     * <p>This call also flushes the data handle pool, releasing every
     * outstanding handle, including permanent ones. Do not use any
     * data handle after this call has returned.
     */
    public static void exitMainThread() {
        NativeCall.callVoid(NativeMethods.LF_ExitMainThread);
    }

    // ==================================================================
    // Runtime options
    // ==================================================================

    /**
     * Adjusts a global runtime option.
     *
     * <p>Unknown option names are silently ignored by the native
     * layer. Changes are not persisted across {@link #shutdown()}.
     *
     * <p>Common option keys include {@code "Overlap_Connection"},
     * {@code "Wait_Connection_ReadyOk"},
     * {@code "Wait_Connection_Timeout"}, {@code "Quiet"},
     * {@code "ConsoleOutput"}, {@code "ShowThreadID"},
     * {@code "Fixed_Sequenced_Time"}. See {@link Options} for the
     * typed shortcuts that hard-code every canonical key.
     *
     * @param option the option name; must not be null
     * @param value  the option value; must not be null
     * @throws NullPointerException if either argument is null
     */
    public static void setOption(String option, String value) {
        Objects.requireNonNull(option, "option must not be null");
        Objects.requireNonNull(value, "value must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment optSeg = arena.allocateFrom(option);
            MemorySegment valSeg = arena.allocateFrom(value);
            NativeCall.callVoid(NativeMethods.LF_SetOption, optSeg, valSeg);
        }
    }

    /**
     * Reads the current value of a runtime option.
     *
     * <p>Returns an empty string for unknown option names, matching
     * the underlying library's behaviour.
     *
     * <p>The underlying {@code LF_GetOption} returns a pointer to a
     * transient buffer that is released approximately 5 seconds after
     * the call. This method copies the string to managed memory
     * immediately, so the returned {@link String} is safe to retain
     * indefinitely.
     *
     * @param option the option name; must not be null
     * @return the option value, or an empty string when unset or
     *         unknown
     * @throws NullPointerException if {@code option} is null
     */
    public static String getOption(String option) {
        Objects.requireNonNull(option, "option must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment optSeg = arena.allocateFrom(option);
            MemorySegment ptr = NativeCall.callSeg(
                    NativeMethods.LF_GetOption, optSeg);
            if (isNull(ptr)) {
                return "";
            }
            return ptr.reinterpret(Long.MAX_VALUE).getString(0);
        }
    }

    // ==================================================================
    // Application name generation and query
    // ==================================================================

    /**
     * Generates a globally unique application name.
     *
     * <p>Must be called after {@link #prepareDone()} returns 1.
     * Before that, the tunnel information is not available and the
     * name may not be unique.
     *
     * <p>The native function returns a pointer that is valid for
     * approximately 5 seconds; this method copies the string to
     * managed memory immediately, so the returned {@link String} is
     * safe to hold indefinitely.
     *
     * @return the generated name, or an empty string if the native
     *         function returned null
     */
    public static String generateAppName() {
        MemorySegment ptr = NativeCall.callSeg(
                NativeMethods.LF_Generate_AppName);
        if (isNull(ptr)) {
            return "";
        }
        return ptr.reinterpret(Long.MAX_VALUE).getString(0);
    }

    /**
     * Returns the name of an existing application handle.
     *
     * <p>Same 5-second validity rule as
     * {@link #generateAppName()}; this method copies the string
     * immediately.
     *
     * <p>The managed {@link AppHandle#name()} accessor returns the
     * name that was passed to the constructor. This method, by
     * contrast, queries the native side and therefore reflects the
     * authoritative name stored in the C4 mesh registry. The two are
     * usually identical, but they can differ if the AppHandle was
     * constructed with a name that the native layer normalised.
     *
     * @param app the application handle; must not be null and must
     *            not be closed
     * @return the application name, or an empty string if the native
     *         function returned null
     * @throws NullPointerException if {@code app} is null
     */
    public static String getAppName(AppHandle app) {
        Objects.requireNonNull(app, "app must not be null");

        MemorySegment ptr = NativeCall.callSeg(
                NativeMethods.LF_Get_AppName, app.raw());
        if (isNull(ptr)) {
            return "";
        }
        return ptr.reinterpret(Long.MAX_VALUE).getString(0);
    }

    // ==================================================================
    // Remote invocation by App name
    // ==================================================================

    /**
     * Performs a synchronous remote call addressed by App name.
     *
     * <p>On timeout or unreachable target, the native side returns an
     * EMPTY handle (size 0), not a null pointer. The returned handle
     * is still valid: {@code response.isValid() == true},
     * {@code response.size() == 0}.
     *
     * <p>This call blocks the calling thread until the response
     * arrives or the timeout expires. Do not call it from inside a
     * LingoFuse callback; it will deadlock.
     *
     * @param appName   the target application name; must not be null
     * @param param     the request data handle; must not be null
     * @param timeoutMs the timeout in milliseconds; 0 means "wait
     *                  indefinitely"
     * @return a new {@link DataHandle} owning the response. The
     *         caller must close it.
     * @throws NullPointerException if {@code appName} or {@code param}
     *                              is null
     * @throws LingoFuseException   if the native layer returns a null
     *                              handle (an unexpected transport
     *                              failure)
     */
    public static DataHandle call(
            String appName, DataHandle param, long timeoutMs) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_Call,
                    nameSeg,
                    param.raw(),
                    timeoutMs);

            if (isNull(raw)) {
                throw new LingoFuseException(
                        "LF_Call returned a null handle for app '"
                                + appName + "'.");
            }
            return DataHandle.fromRaw(raw, true);
        }
    }

    /**
     * Performs a synchronous remote call and returns the response only
     * when the native layer produced a non-empty payload.
     *
     * <p>Returns {@code null} on timeout or unreachable target,
     * instead of a size-0 {@link DataHandle}. Callers that need to
     * distinguish "timeout" from "empty response" must use
     * {@link #call(String, DataHandle, long)} and inspect
     * {@code size()} themselves.
     *
     * @param appName   the target application name; must not be null
     * @param param     the request data handle; must not be null
     * @param timeoutMs the timeout in milliseconds
     * @return a new {@link DataHandle} when the response is non-empty,
     *         or {@code null} on timeout or unreachable target
     */
    public static DataHandle tryCall(
            String appName, DataHandle param, long timeoutMs) {
        DataHandle response = call(appName, param, timeoutMs);
        if (response.size() == 0) {
            response.close();
            return null;
        }
        return response;
    }

    /**
     * Sends a one-way notification addressed by App name.
     *
     * <p>Delivery order is not guaranteed; use
     * {@link #sequencedNotify(String, DataHandle)} when FIFO ordering
     * per {@code (app, api)} pair is required.
     *
     * @param appName the target application name; must not be null
     * @param param   the payload; must not be null
     */
    public static void notify(String appName, DataHandle param) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            NativeCall.callVoid(
                    NativeMethods.LF_Notify, nameSeg, param.raw());
        }
    }

    /**
     * Sends a one-way notification with FIFO ordering guaranteed for
     * the same {@code (app, api)} pair.
     *
     * @param appName the target application name; must not be null
     * @param param   the payload; must not be null
     */
    public static void sequencedNotify(String appName, DataHandle param) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            NativeCall.callVoid(
                    NativeMethods.LF_Sequenced_Notify,
                    nameSeg,
                    param.raw());
        }
    }

    // ==================================================================
    // Remote invocation by UID
    // ==================================================================
    //
    // The UID parameter is a 32-byte value. On every call this class
    // copies the Java byte[] into a confined Arena and passes the
    // resulting segment. In cdecl, an array parameter decays to a
    // pointer, so the FFM representation is a single ADDRESS. The
    // length is validated before any native call is made.
    //
    // This is a DIFFERENT role from the LF_Get_P2P_UID RETURN value,
    // which is also a pointer but refers to a 32-byte buffer owned by
    // the framework. See DataHandle.getP2pUid() for that contract.

    /**
     * Performs a synchronous remote call addressed by UID.
     *
     * <p>Routing is LOCAL-FIRST, matching App-name routing. The UID
     * can address ANY API registered on the target, without requiring
     * the caller to know the target App name.
     *
     * <p>Same return-handle contract as
     * {@link #call(String, DataHandle, long)}: an empty handle
     * (size 0) signals a timeout or unreachable target.
     *
     * @param uid       the 32-byte UID; must not be null and must be
     *                  exactly 32 bytes long
     * @param param     the request data handle; must not be null
     * @param timeoutMs the timeout in milliseconds
     * @return a new {@link DataHandle} owning the response
     * @throws NullPointerException     if any argument is null
     * @throws IllegalArgumentException if {@code uid.length != 32}
     * @throws LingoFuseException       if the native layer returns a
     *                                  null handle
     */
    public static DataHandle uidCall(
            byte[] uid, DataHandle param, long timeoutMs) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_UID_Call,
                    uidSeg,
                    param.raw(),
                    timeoutMs);

            if (isNull(raw)) {
                throw new LingoFuseException(
                        "LF_UID_Call returned a null handle for uid="
                                + hex(uid) + ".");
            }
            return DataHandle.fromRaw(raw, true);
        }
    }

    /**
     * UID variant of {@link #tryCall(String, DataHandle, long)}.
     *
     * @param uid       the 32-byte UID
     * @param param     the request data handle
     * @param timeoutMs the timeout in milliseconds
     * @return a new {@link DataHandle} when the response is non-empty,
     *         or {@code null} on timeout or unreachable target
     */
    public static DataHandle tryUidCall(
            byte[] uid, DataHandle param, long timeoutMs) {
        DataHandle response = uidCall(uid, param, timeoutMs);
        if (response.size() == 0) {
            response.close();
            return null;
        }
        return response;
    }

    /**
     * Sends a one-way notification addressed by UID.
     *
     * @param uid   the 32-byte UID
     * @param param the payload
     */
    public static void uidNotify(byte[] uid, DataHandle param) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            NativeCall.callVoid(
                    NativeMethods.LF_UID_Notify, uidSeg, param.raw());
        }
    }

    /**
     * Sends a one-way notification addressed by UID, with FIFO
     * ordering guaranteed for the same {@code (uid, api)} pair.
     *
     * @param uid   the 32-byte UID
     * @param param the payload
     */
    public static void uidSequencedNotify(byte[] uid, DataHandle param) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            NativeCall.callVoid(
                    NativeMethods.LF_UID_Sequenced_Notify,
                    uidSeg,
                    param.raw());
        }
    }

    // ==================================================================
    // Remote invocation by P2P name
    // ==================================================================
    //
    // P2PName addressing routes to any client in a user-defined group.
    // Unlike App-name and UID routing, it is NOT local-first: even
    // when the caller process itself hosts a client in the target
    // group, the call is forwarded to the server for dispatch. This
    // preserves the server-side load-balancing state.

    /**
     * Performs a synchronous remote call addressed by P2P group name.
     *
     * <p>Same return-handle contract as
     * {@link #call(String, DataHandle, long)}: an empty handle
     * (size 0) signals a timeout or unreachable target.
     *
     * @param group     the P2P group name; must not be null
     * @param param     the request data handle; must not be null
     * @param timeoutMs the timeout in milliseconds
     * @return a new {@link DataHandle} owning the response
     * @throws NullPointerException if any argument is null
     * @throws LingoFuseException   if the native layer returns a null
     *                              handle
     */
    public static DataHandle p2pCall(
            String group, DataHandle param, long timeoutMs) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_P2PNAME_Call,
                    groupSeg,
                    param.raw(),
                    timeoutMs);

            if (isNull(raw)) {
                throw new LingoFuseException(
                        "LF_P2PNAME_Call returned a null handle for group='"
                                + group + "'.");
            }
            return DataHandle.fromRaw(raw, true);
        }
    }

    /**
     * P2PName variant of {@link #tryCall(String, DataHandle, long)}.
     *
     * @param group     the P2P group name
     * @param param     the request data handle
     * @param timeoutMs the timeout in milliseconds
     * @return a new {@link DataHandle} when the response is non-empty,
     *         or {@code null} on timeout or unreachable target
     */
    public static DataHandle tryP2pCall(
            String group, DataHandle param, long timeoutMs) {
        DataHandle response = p2pCall(group, param, timeoutMs);
        if (response.size() == 0) {
            response.close();
            return null;
        }
        return response;
    }

    /**
     * Sends a one-way notification addressed by P2P group name.
     *
     * @param group the P2P group name
     * @param param the payload
     */
    public static void p2pNotify(String group, DataHandle param) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            NativeCall.callVoid(
                    NativeMethods.LF_P2PNAME_Notify,
                    groupSeg,
                    param.raw());
        }
    }

    /**
     * Sends a one-way notification addressed by P2P group name, with
     * FIFO ordering guaranteed for the same {@code (group, api)} pair.
     *
     * @param group the P2P group name
     * @param param the payload
     */
    public static void p2pSequencedNotify(String group, DataHandle param) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            NativeCall.callVoid(
                    NativeMethods.LF_P2PNAME_Sequenced_Notify,
                    groupSeg,
                    param.raw());
        }
    }

    // ==================================================================
    // Asynchronous invocation
    // ==================================================================
    //
    // These methods expose the C ABI's asynchronous call family to
    // Java callers in a form that lets them write the business logic
    // directly inside a lambda:
    //
    //     Framework.asyncCallJson("MyApp", req, Person.class,
    //         (person, error) -> {
    //             if (error != null) {
    //                 log.warn("failed", error);
    //                 return;
    //             }
    //             System.out.println(person.name);
    //         });
    //
    // The three addressing modes (App name, UID, P2P name) each
    // provide two call shapes (call / sequencedCall) and two result
    // styles (raw handle / typed JSON):
    //
    //     asyncCall            - raw handle, unordered
    //     asyncCallJson        - typed, unordered
    //     asyncSequencedCall   - raw handle, FIFO per (target, api)
    //     asyncSequencedCallJson - typed, FIFO per (target, api)
    //
    // All twelve methods return true when the C library accepted the
    // request for dispatch, false when it did not. On false, the
    // callback will never fire and no op is leaked.
    //
    // For a cleaner, more composable API, prefer the Target class:
    //
    //     new AppTarget("MyApp").asyncCallJson(req, Person.class,
    //         (person, error) -> { ... });
    //
    // The Target API shares the same underlying async machinery, so
    // the two can be freely mixed.

    // ------------------------------------------------------------------
    // App name
    // ------------------------------------------------------------------

    /**
     * Sends a non-blocking request addressed by App name, with a
     * raw-handle callback.
     *
     * @param appName the target application name; must not be null
     * @param param   the request handle; must not be null
     * @param handler the user callback; must not be null
     * @return true if the request was queued successfully
     * @throws NullPointerException if any argument is null
     */
    public static boolean asyncCall(
            String appName, DataHandle param, AsyncResultHandler handler) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncCall[" + appName + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_Async_Call,
                    nameSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking request addressed by App name, with a
     * typed callback. The framework deserializes the result before
     * invoking the handler.
     *
     * @param appName the target application name; must not be null
     * @param param   the request handle; must not be null
     * @param type    the target type; must not be null
     * @param handler the user callback; must not be null
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public static <T> boolean asyncCallJson(
            String appName, DataHandle param, Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncCallJson[" + appName + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_Async_Call,
                    nameSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking sequenced request addressed by App name,
     * with a raw-handle callback. FIFO ordering is guaranteed per
     * {@code (app, api)} pair.
     *
     * @param appName the target application name
     * @param param   the request handle
     * @param handler the user callback
     * @return true if the request was queued successfully
     */
    public static boolean asyncSequencedCall(
            String appName, DataHandle param, AsyncResultHandler handler) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncSequencedCall[" + appName + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_Async_Sequenced_Call,
                    nameSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking sequenced request addressed by App name,
     * with a typed callback.
     *
     * @param appName the target application name
     * @param param   the request handle
     * @param type    the target type
     * @param handler the user callback
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public static <T> boolean asyncSequencedCallJson(
            String appName, DataHandle param, Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncSequencedCallJson[" + appName + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_Async_Sequenced_Call,
                    nameSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    // ------------------------------------------------------------------
    // UID
    // ------------------------------------------------------------------

    /**
     * Sends a non-blocking request addressed by UID, with a raw-handle
     * callback.
     *
     * @param uid     the 32-byte UID; must not be null and must be
     *                exactly 32 bytes long
     * @param param   the request handle
     * @param handler the user callback
     * @return true if the request was queued successfully
     */
    public static boolean asyncUidCall(
            byte[] uid, DataHandle param, AsyncResultHandler handler) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncUidCall[" + hex(uid) + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_UID_Async_Call,
                    uidSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking request addressed by UID, with a typed
     * callback.
     *
     * @param uid     the 32-byte UID
     * @param param   the request handle
     * @param type    the target type
     * @param handler the user callback
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public static <T> boolean asyncUidCallJson(
            byte[] uid, DataHandle param, Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncUidCallJson[" + hex(uid) + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_UID_Async_Call,
                    uidSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking sequenced request addressed by UID, with a
     * raw-handle callback.
     *
     * @param uid     the 32-byte UID
     * @param param   the request handle
     * @param handler the user callback
     * @return true if the request was queued successfully
     */
    public static boolean asyncUidSequencedCall(
            byte[] uid, DataHandle param, AsyncResultHandler handler) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncUidSequencedCall[" + hex(uid) + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_UID_Async_Sequenced_Call,
                    uidSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking sequenced request addressed by UID, with a
     * typed callback.
     *
     * @param uid     the 32-byte UID
     * @param param   the request handle
     * @param type    the target type
     * @param handler the user callback
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public static <T> boolean asyncUidSequencedCallJson(
            byte[] uid, DataHandle param, Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncUidSequencedCallJson[" + hex(uid) + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_UID_Async_Sequenced_Call,
                    uidSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    // ------------------------------------------------------------------
    // P2P name
    // ------------------------------------------------------------------

    /**
     * Sends a non-blocking request addressed by P2P group name, with a
     * raw-handle callback.
     *
     * @param group   the P2P group name; must not be null
     * @param param   the request handle
     * @param handler the user callback
     * @return true if the request was queued successfully
     */
    public static boolean asyncP2pCall(
            String group, DataHandle param, AsyncResultHandler handler) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncP2pCall[" + group + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_P2PNAME_Async_Call,
                    groupSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking request addressed by P2P group name, with a
     * typed callback.
     *
     * @param group   the P2P group name
     * @param param   the request handle
     * @param type    the target type
     * @param handler the user callback
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public static <T> boolean asyncP2pCallJson(
            String group, DataHandle param, Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncP2pCallJson[" + group + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_P2PNAME_Async_Call,
                    groupSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking sequenced request addressed by P2P group
     * name, with a raw-handle callback.
     *
     * @param group   the P2P group name
     * @param param   the request handle
     * @param handler the user callback
     * @return true if the request was queued successfully
     */
    public static boolean asyncP2pSequencedCall(
            String group, DataHandle param, AsyncResultHandler handler) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncP2pSequencedCall[" + group + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_P2PNAME_Async_Sequenced_Call,
                    groupSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    /**
     * Sends a non-blocking sequenced request addressed by P2P group
     * name, with a typed callback.
     *
     * @param group   the P2P group name
     * @param param   the request handle
     * @param type    the target type
     * @param handler the user callback
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public static <T> boolean asyncP2pSequencedCallJson(
            String group, DataHandle param, Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncP2pSequencedCallJson[" + group + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            int ret = NativeCall.callInt(
                    NativeMethods.LF_P2PNAME_Async_Sequenced_Call,
                    groupSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }
    
    // ==================================================================
    // Shutdown
    // ==================================================================

    /**
     * Gracefully terminates the framework, releasing all resources.
     *
     * <p>Safe to call multiple times. After this call, the library
     * may be re-initialised by calling {@link #resetPrepare()},
     * {@link #prepareService(String, String)},
     * {@link #prepareClient(String, AppHandle)}, and
     * {@link #prepareDone()} again.
     *
     * <p>Every {@link AppHandle} still alive in the process becomes
     * invalid after this call. The {@code AppHandle} wrappers do not
     * detect this automatically; callers must ensure that no
     * {@code AppHandle} is used after {@code shutdown()} has returned.
     *
     * <p>All runtime options are reset to their built-in defaults
     * (see the "not persisted across shutdown" note in
     * {@link Options}).
     */
    public static void shutdown() {
        NativeCall.callVoid(NativeMethods.LF_Shutdown);
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    private static boolean isNull(MemorySegment seg) {
        return seg == null || seg.address() == 0L;
    }

    /**
     * Validates that a UID argument has exactly the expected length.
     *
     * @param uid     the UID argument
     * @param argName the parameter name to use in the error message
     * @throws NullPointerException     if {@code uid} is null
     * @throws IllegalArgumentException if {@code uid.length} does not
     *                                  match {@link NativeTypes#UID_BYTES}
     */
    private static void checkUidLength(byte[] uid, String argName) {
        Objects.requireNonNull(uid, argName + " must not be null");
        if (uid.length != NativeTypes.UID_BYTES) {
            throw new IllegalArgumentException(
                    argName + " must be exactly " + NativeTypes.UID_BYTES
                            + " bytes, got " + uid.length);
        }
    }

    /**
     * Allocates a 32-byte segment in the given arena and copies the
     * UID into it.
     *
     * <p>The caller is responsible for ensuring that the arena
     * outlives the native call that receives the segment. This class
     * always uses a confined arena scoped to the enclosing method.
     *
     * @param arena the arena to allocate from
     * @param uid   the 32-byte UID; must have been validated already
     * @return a segment that holds the 32 UID bytes
     */
    private static MemorySegment allocateUid(Arena arena, byte[] uid) {
        MemorySegment seg = arena.allocate(NativeTypes.UID_BYTES);
        MemorySegment.copy(uid, 0, seg, ValueLayout.JAVA_BYTE, 0,
                (int) NativeTypes.UID_BYTES);
        return seg;
    }

    /**
     * Returns a lowercase hexadecimal representation of the given
     * bytes. Used for diagnostic messages only.
     *
     * @param bytes the bytes to format; null yields an empty string
     * @return the hex string
     */
    private static String hex(byte[] bytes) {
        if (bytes == null || bytes.length == 0) {
            return "";
        }
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0x0F, 16));
            sb.append(Character.forDigit(b & 0x0F, 16));
        }
        return sb.toString();
    }
}