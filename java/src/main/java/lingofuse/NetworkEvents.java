package lingofuse;

import lingofuse.ffi.ArenaReaper;
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
 * <p>Wraps {@code LF_Set_Network_Event}. Each install creates its own
 * shared arena; replacing or clearing retires the previous arena
 * through {@link ArenaReaper} so a still-in-flight native callback
 * never sees freed memory.
 */
public final class NetworkEvents {

    private static final long MAX_C_STRING_LENGTH = 1024L * 1024L;

    private static final Linker LINKER = Linker.nativeLinker();

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

    private static final Object LOCK = new Object();

    /*
     * ==================================================================
     * CROSS-LANGUAGE COMPATIBILITY NOTE
     * ------------------------------------------------------------------
     * Each install of a network-event handler creates its own Arena
     * so that a stale trampoline can be retired without touching the
     * currently active one. This is a JAVA-PRIVATE resource strategy.
     *
     * The wire-visible behaviour of LF_Set_Network_Event is
     * unchanged: it still receives two function pointers (or NULL),
     * it still runs the callbacks on native worker threads, and the
     * `addr` argument is still a transient UTF-8, NUL-terminated C
     * string. Other bindings manage their own callbacks however
     * their runtime requires; the wire contract is identical.
     * ==================================================================
     */
    private static MemorySegment connectStub;
    private static MemorySegment disconnectStub;
    private static Arena connectArena;
    private static Arena disconnectArena;

    private static RegisteredCallback connectHolder;
    private static RegisteredCallback disconnectHolder;

    private NetworkEvents() {
    }

    public static void setNetworkEvent(
            Consumer<String> onConnect,
            Consumer<String> onDisconnect) {

        synchronized (LOCK) {
            if (connectArena != null) {
                ArenaReaper.retire(connectArena);
                connectArena = null;
            }
            if (disconnectArena != null) {
                ArenaReaper.retire(disconnectArena);
                disconnectArena = null;
            }

            connectHolder = (onConnect == null)
                    ? null
                    : new RegisteredCallback(
                            "NetworkEvents.connect", onConnect);
            disconnectHolder = (onDisconnect == null)
                    ? null
                    : new RegisteredCallback(
                            "NetworkEvents.disconnect", onDisconnect);

            if (connectHolder != null) {
                connectArena = Arena.ofShared();
                connectStub = buildStub(connectHolder, connectArena);
            } else {
                connectStub = MemorySegment.NULL;
            }

            if (disconnectHolder != null) {
                disconnectArena = Arena.ofShared();
                disconnectStub = buildStub(disconnectHolder, disconnectArena);
            } else {
                disconnectStub = MemorySegment.NULL;
            }

            NativeCall.callVoid(NativeMethods.LF_Set_Network_Event,
                    connectStub, disconnectStub);
        }
    }

    public static void clear() {
        synchronized (LOCK) {
            NativeCall.callVoid(NativeMethods.LF_Set_Network_Event,
                    MemorySegment.NULL, MemorySegment.NULL);

            if (connectArena != null) {
                ArenaReaper.retire(connectArena);
                connectArena = null;
            }
            if (disconnectArena != null) {
                ArenaReaper.retire(disconnectArena);
                disconnectArena = null;
            }

            connectHolder = null;
            disconnectHolder = null;
            connectStub = null;
            disconnectStub = null;
        }
    }

    public static boolean isInstalled() {
        synchronized (LOCK) {
            return connectHolder != null || disconnectHolder != null;
        }
    }

    private static MemorySegment buildStub(
            RegisteredCallback holder, Arena arena) {
        MethodHandle bound = MethodHandles.insertArguments(
                NETWORK_EVENT_BRIDGE, 0, holder);
        return LINKER.upcallStub(
                bound, NativeTypes.LF_NETWORK_EVENT, arena);
    }

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
                        .reinterpret(MAX_C_STRING_LENGTH)
                        .getString(0);
            }
        } catch (Throwable t) {
            Framework.reportCallbackError(
                    holder.source + " (decode failure)", t);
            return;
        }

        try {
            @SuppressWarnings("unchecked")
            Consumer<String> handler = (Consumer<String>) holder.userHandler;
            handler.accept(endpoint);
        } catch (Throwable t) {
            Framework.reportCallbackError(holder.source, t);
        }
    }

    private static final class RegisteredCallback {
        final String source;
        final Object userHandler;

        RegisteredCallback(String source, Object userHandler) {
            this.source = source;
            this.userHandler = userHandler;
        }
    }

    public abstract static class NetworkEventListener {
        public void onConnect(String addr) {
        }

        public void onDisconnect(String addr) {
        }
    }

    public static void setNetworkEventListener(NetworkEventListener listener) {
        if (listener == null) {
            clear();
            return;
        }
        setNetworkEvent(listener::onConnect, listener::onDisconnect);
    }
}