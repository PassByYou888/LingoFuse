package lingofuse;

import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;
import lingofuse.ffi.NativeTypes;

import java.lang.foreign.Arena;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.function.Consumer;

/**
 * Process-global connect / disconnect event handlers.
 *
 * <p>This class wraps {@code LF_Set_Network_Event}, which installs a
 * pair of process-wide callbacks that fire when a LingoFuse client
 * becomes online or goes offline.
 *
 * <h2>Semantics</h2>
 *
 * <ul>
 *   <li><b>Connect</b> fires the FIRST time a client receives a
 *       service API-info broadcast. It is NOT the TCP handshake; it
 *       is the earliest point at which remote calls can be routed.
 *       Fires once per connection lifecycle, and again after an
 *       auto-reconnect.</li>
 *   <li><b>Disconnect</b> fires once per physical link loss. An
 *       automatic reconnect does NOT emit a Disconnect for the
 *       reconnect attempt itself; it emits a new Connect once the
 *       client is back online.</li>
 * </ul>
 *
 * <h2>Threading contract</h2>
 *
 * <p>Callbacks run on a background worker thread owned by the native
 * library. They must never block, never touch UI, and never call a
 * blocking LingoFuse function. The wrapper catches every exception
 * raised by a user handler and reports it through
 * {@link Framework#reportCallbackError(String, Throwable)}.
 *
 * <h2>Global scope</h2>
 *
 * <p>{@code LF_Set_Network_Event} is a process-global slot. There is
 * no per-client registration API. Installing new handlers replaces
 * the previous ones entirely; passing {@code null} for a handler
 * disables that event.
 *
 * <h2>Delegate lifetime</h2>
 *
 * <p>Upcall stubs are owned by a private {@link Arena#ofShared()}
 * instance that lives for the entire JVM lifetime. The arena is
 * released when the JVM exits.
 */
public final class NetworkEvents {

    // ------------------------------------------------------------------
    // Static initialization
    // ------------------------------------------------------------------

    private static final Linker LINKER = Linker.nativeLinker();

    /**
     * The arena that owns every upcall stub created by this class.
     * Shared (not confined) because callbacks run on native worker
     * threads. Never closed; released on JVM exit.
     */
    private static final Arena CALLBACK_ARENA = Arena.ofShared();

    /**
     * The static bridge method that each network event upcall stub
     * invokes. Signature:
     * {@code (RegisteredCallback, MemorySegment) -> void}.
     *
     * <p>Referenced only through
     * {@link MethodHandles.Lookup#findStatic} at class initialisation
     * time.
     */
    private static final MethodHandle NETWORK_EVENT_BRIDGE;

    static {
        try {
            NETWORK_EVENT_BRIDGE = MethodHandles.lookup().findStatic(
                    NetworkEvents.class,
                    "dispatchNetworkEvent",
                    MethodType.methodType(
                            void.class,
                            RegisteredCallback.class,
                            MemorySegment.class));
        } catch (NoSuchMethodException | IllegalAccessException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    // ------------------------------------------------------------------
    // Module-level state
    // ------------------------------------------------------------------

    private static final Object LOCK = new Object();

    private static MemorySegment connectStub;
    private static MemorySegment disconnectStub;

    private static RegisteredCallback connectHolder;
    private static RegisteredCallback disconnectHolder;

    private NetworkEvents() {
        // Utility class; no instances.
    }

    // ==================================================================
    // Public API
    // ==================================================================

    /**
     * Installs the process-global connect and disconnect handlers.
     *
     * <p>Passing {@code null} for either argument disables that event.
     * This is a REPLACE operation, not a patch.
     *
     * @param onConnect    handler for online events; may be null
     * @param onDisconnect handler for offline events; may be null
     */
    public static void setNetworkEvent(
            Consumer<String> onConnect,
            Consumer<String> onDisconnect) {

        synchronized (LOCK) {
            connectHolder = (onConnect == null)
                    ? null
                    : new RegisteredCallback("NetworkEvents.connect", onConnect);
            disconnectHolder = (onDisconnect == null)
                    ? null
                    : new RegisteredCallback("NetworkEvents.disconnect",
                            onDisconnect);

            connectStub = (connectHolder == null)
                    ? MemorySegment.NULL
                    : buildStub(connectHolder);
            disconnectStub = (disconnectHolder == null)
                    ? MemorySegment.NULL
                    : buildStub(disconnectHolder);

            NativeCall.callVoid(
                    NativeMethods.LF_Set_Network_Event,
                    connectStub,
                    disconnectStub);
        }
    }

    /**
     * Removes both handlers. Safe to call multiple times.
     */
    public static void clear() {
        synchronized (LOCK) {
            NativeCall.callVoid(
                    NativeMethods.LF_Set_Network_Event,
                    MemorySegment.NULL,
                    MemorySegment.NULL);

            connectHolder = null;
            disconnectHolder = null;
            connectStub = null;
            disconnectStub = null;
        }
    }

    /**
     * Returns whether at least one handler is currently installed.
     *
     * @return true when either handler is installed
     */
    public static boolean isInstalled() {
        synchronized (LOCK) {
            return connectHolder != null || disconnectHolder != null;
        }
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    private static MemorySegment buildStub(RegisteredCallback holder) {
        MethodHandle bound = MethodHandles.insertArguments(
                NETWORK_EVENT_BRIDGE, 0, holder);
        return LINKER.upcallStub(
                bound, NativeTypes.LF_NETWORK_EVENT, CALLBACK_ARENA);
    }

    /**
     * Static bridge method for network event callbacks.
     *
     * <p>Referenced only through
     * {@link MethodHandles.Lookup#findStatic} at class initialisation
     * time.
     *
     * @param holder the per-registration holder
     * @param addrSegment the UTF-8, NUL-terminated endpoint string
     */
    @SuppressWarnings("unused")
    private static void dispatchNetworkEvent(
            RegisteredCallback holder,
            MemorySegment addrSegment) {

        String endpoint;
        try {
            if (addrSegment == null || addrSegment.address() == 0L) {
                endpoint = "";
            } else {
                endpoint = addrSegment
                        .reinterpret(Long.MAX_VALUE)
                        .getString(0);
            }
        } catch (Throwable t) {
            Framework.reportCallbackError(
                    holder.source + " (decode failure)", t);
            return;
        }

        try {
            @SuppressWarnings("unchecked")
            Consumer<String> handler =
                    (Consumer<String>) holder.userHandler;
            handler.accept(endpoint);
        } catch (Throwable t) {
            Framework.reportCallbackError(holder.source, t);
        }
    }

    // ==================================================================
    // Internal holder
    // ==================================================================

    /**
     * Per-registration holder. Keeps the user-supplied lambda and a
     * diagnostic source label alive for as long as the registration
     * is active.
     */
    private static final class RegisteredCallback {
        final String source;
        final Object userHandler;

        RegisteredCallback(String source, Object userHandler) {
            this.source = source;
            this.userHandler = userHandler;
        }
    }

    // ==================================================================
    // Object-oriented listener (optional convenience)
    // ==================================================================

    /**
     * Base class for object-oriented network event listeners.
     *
     * <p>Subclass and override {@link #onConnect(String)} /
     * {@link #onDisconnect(String)} as needed. Both methods run on a
     * native worker thread.
     */
    public abstract static class NetworkEventListener {

        /**
         * Called when a client becomes online. Default does nothing.
         *
         * @param addr the endpoint string
         */
        public void onConnect(String addr) {
        }

        /**
         * Called when a client goes offline. Default does nothing.
         *
         * @param addr the endpoint string
         */
        public void onDisconnect(String addr) {
        }
    }

    /**
     * Installs a {@link NetworkEventListener}.
     *
     * @param listener the listener, or null to uninstall
     */
    public static void setNetworkEventListener(NetworkEventListener listener) {
        if (listener == null) {
            clear();
            return;
        }
        setNetworkEvent(listener::onConnect, listener::onDisconnect);
    }
}