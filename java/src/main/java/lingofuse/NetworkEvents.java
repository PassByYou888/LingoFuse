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
 *
 * <h2>Install / replace order</h2>
 *
 * <p>Installing or replacing the handlers is a three-phase operation:
 *
 * <ol>
 *   <li><b>Construct</b> — allocate the new trampolines in their own
 *       shared arenas. Module state is NOT touched yet.</li>
 *   <li><b>Install</b> — call {@code LF_Set_Network_Event} with the
 *       new pointers. Only after this call returns does the native
 *       library stop referencing the old pointers.</li>
 *   <li><b>Publish</b> — update the module-level state to reference
 *       the new trampolines, and retire the old arenas through
 *       {@link ArenaReaper}.</li>
 * </ol>
 *
 * <p>If the install step throws, the operation is aborted by
 * retiring the newly-created arenas (which the native library has
 * never seen) and leaving the module state unchanged. The previous
 * handlers remain installed and remain valid.
 *
 * <p>Reversing the order (retiring old arenas before the native
 * swap) would leave the native library holding a pointer to a
 * retiring trampoline for the duration of the swap window. Any
 * connect/disconnect event arriving in that window would jump into
 * freed native code.
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
     *
     * Module state kept here:
     *
     *   connectArena / disconnectArena   — the arenas that own the
     *                                      currently installed
     *                                      trampolines. Retired when
     *                                      replaced or cleared.
     *
     *   connectHolder / disconnectHolder — the trampoline holders
     *                                      (source label + user
     *                                      callback). Referenced by
     *                                      isInstalled() and, through
     *                                      the closure built in
     *                                      buildStub, by the stub
     *                                      itself.
     *
     * The raw MemorySegment of the installed stub is NOT stored:
     * every setNetworkEvent / clear call constructs the pointer it
     * needs as a local. Storing it would add mutable state with no
     * reader.
     */
    private static Arena connectArena;
    private static Arena disconnectArena;

    private static RegisteredCallback connectHolder;
    private static RegisteredCallback disconnectHolder;

    private NetworkEvents() {
    }

    /**
     * Installs or replaces the process-global network event handlers.
     *
     * <p>Passing {@code null} for either handler disables that event.
     * This is a REPLACE operation, not a patch: calling it a second
     * time discards any previously installed handlers, even those
     * whose corresponding argument is null in the new call.
     *
     * <p>See the class header for the three-phase install order and
     * for the failure-handling contract.
     *
     * @param onConnect    handler invoked when a client becomes
     *                     online; may be null
     * @param onDisconnect handler invoked when a client goes offline;
     *                     may be null
     */
    public static void setNetworkEvent(
            Consumer<String> onConnect,
            Consumer<String> onDisconnect) {

        synchronized (LOCK) {
            // Snapshot the currently installed state. These must
            // remain live and installed until the native install call
            // below succeeds.
            Arena oldConnectArena = connectArena;
            Arena oldDisconnectArena = disconnectArena;

            // -----------------------------------------------------------------
            // Phase 1: construct. Module state is not modified yet.
            // -----------------------------------------------------------------
            RegisteredCallback newConnectHolder = (onConnect == null)
                    ? null
                    : new RegisteredCallback(
                            "NetworkEvents.connect", onConnect);
            RegisteredCallback newDisconnectHolder = (onDisconnect == null)
                    ? null
                    : new RegisteredCallback(
                            "NetworkEvents.disconnect", onDisconnect);

            Arena newConnectArena = null;
            Arena newDisconnectArena = null;
            MemorySegment newConnectStub = MemorySegment.NULL;
            MemorySegment newDisconnectStub = MemorySegment.NULL;

            try {
                if (newConnectHolder != null) {
                    newConnectArena = Arena.ofShared();
                    newConnectStub = buildStub(
                            newConnectHolder, newConnectArena);
                }
                if (newDisconnectHolder != null) {
                    newDisconnectArena = Arena.ofShared();
                    newDisconnectStub = buildStub(
                            newDisconnectHolder, newDisconnectArena);
                }
            } catch (Throwable t) {
                // Construction failed before the native library was
                // touched. Retire whichever half we managed to build
                // and rethrow. Module state is unchanged.
                if (newConnectArena != null) {
                    ArenaReaper.retire(newConnectArena);
                }
                if (newDisconnectArena != null) {
                    ArenaReaper.retire(newDisconnectArena);
                }
                throw t;
            }

            // -----------------------------------------------------------------
            // Phase 2: install on the native side. If this throws, the
            // old handlers are still installed and still valid; the
            // newly-built arenas are retired and module state is
            // unchanged.
            // -----------------------------------------------------------------
            try {
                NativeCall.callVoid(NativeMethods.LF_Set_Network_Event,
                        newConnectStub, newDisconnectStub);
            } catch (Throwable t) {
                if (newConnectArena != null) {
                    ArenaReaper.retire(newConnectArena);
                }
                if (newDisconnectArena != null) {
                    ArenaReaper.retire(newDisconnectArena);
                }
                throw t;
            }

            // -----------------------------------------------------------------
            // Phase 3: publish. The native library has accepted the
            // new pointers; from this point forward, the old arenas
            // are no longer referenced by the native side and can be
            // retired.
            // -----------------------------------------------------------------
            connectHolder = newConnectHolder;
            disconnectHolder = newDisconnectHolder;
            connectArena = newConnectArena;
            disconnectArena = newDisconnectArena;

            if (oldConnectArena != null) {
                ArenaReaper.retire(oldConnectArena);
            }
            if (oldDisconnectArena != null) {
                ArenaReaper.retire(oldDisconnectArena);
            }
        }
    }

    /**
     * Removes both handlers. Safe to call multiple times.
     *
     * <p>Install order is the same as {@link #setNetworkEvent}: the
     * native slot is cleared first, then the arenas that owned the
     * previous trampolines are retired.
     */
    public static void clear() {
        synchronized (LOCK) {
            // Phase 1: nothing to construct.
            //
            // Phase 2: install NULLs on the native side. If this
            // throws, leave the module state untouched.
            try {
                NativeCall.callVoid(NativeMethods.LF_Set_Network_Event,
                        MemorySegment.NULL, MemorySegment.NULL);
            } catch (Throwable t) {
                throw t;
            }

            // Phase 3: publish and retire.
            Arena oldConnectArena = connectArena;
            Arena oldDisconnectArena = disconnectArena;

            connectHolder = null;
            disconnectHolder = null;
            connectArena = null;
            disconnectArena = null;

            if (oldConnectArena != null) {
                ArenaReaper.retire(oldConnectArena);
            }
            if (oldDisconnectArena != null) {
                ArenaReaper.retire(oldDisconnectArena);
            }
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