package lingofuse;

import lingofuse.errors.LingoFuseException;
import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.util.Objects;
import java.util.function.BiConsumer;

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
 *   <li>Remote invocation: {@link #call(String, DataHandle, long)},
 *       {@link #tryCall(String, DataHandle, long)},
 *       {@link #notify(String, DataHandle)},
 *       {@link #sequencedNotify(String, DataHandle)}.</li>
 *   <li>Runtime options: {@link #setOption(String, String)}.</li>
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
 * <h2>Callback error reporting</h2>
 *
 * <p>Callback bodies registered through {@link AppHandle} run on
 * native worker threads. An exception escaping such a body would
 * cross into the C stack and could destabilize the process, so every
 * callback is wrapped to swallow exceptions.
 *
 * <p>The wrapper reports every swallowed exception through two
 * channels:
 *
 * <ol>
 *   <li>The handler installed via {@link #setCallbackErrorHandler(BiConsumer)},
 *       if any. This is the intended integration point for a real
 *       logging pipeline (SLF4J, Log4j, ...).</li>
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
     * Internal bridge used by {@link AppHandle} to report a swallowed
     * callback exception.
     *
     * <p>This method is package-private: it is an implementation
     * detail of the binding, not part of the public surface.
     *
     * @param source a short identifier for the callback site
     * @param t      the exception thrown by the user callback
     */
    static void reportCallbackError(String source, Throwable t) {
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
     * {@link #setOption(String, String)}.
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
     * {@code "Fixed_Sequenced_Time"}. See the LingoFuse documentation
     * for the full list.
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
    // Remote invocation
    // ==================================================================

    /**
     * Performs a synchronous remote call and returns the response.
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
     * <p>Ownership: when this method returns a non-null handle, the
     * caller is responsible for closing it. When this method returns
     * null, the underlying empty handle has already been closed by
     * this method; the caller must not free anything.
     *
     * @param appName   the target application name; must not be null
     * @param param     the request data handle; must not be null
     * @param timeoutMs the timeout in milliseconds
     * @return a new {@link DataHandle} when the response is non-empty,
     *         or {@code null} on timeout or unreachable target
     * @throws NullPointerException if {@code appName} or {@code param}
     *                              is null
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
     * Sends a one-way notification.
     *
     * <p>Delivery order is not guaranteed; use
     * {@link #sequencedNotify(String, DataHandle)} when FIFO ordering
     * per {@code (app, api)} pair is required.
     *
     * @param appName the target application name; must not be null
     * @param param   the payload; must not be null
     * @throws NullPointerException if either argument is null
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
     * <p>The underlying implementation uses a dedicated thread per
     * pair. If the thread is idle for more than 5 minutes, it
     * terminates; the next notification recreates it.
     *
     * @param appName the target application name; must not be null
     * @param param   the payload; must not be null
     * @throws NullPointerException if either argument is null
     */
    public static void sequencedNotify(String appName, DataHandle param) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            NativeCall.callVoid(
                    NativeMethods.LF_Sequenced_Notify, nameSeg, param.raw());
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
}