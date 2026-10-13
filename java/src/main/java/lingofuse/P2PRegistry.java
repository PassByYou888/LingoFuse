package lingofuse;

import lingofuse.errors.LingoFuseRegistrationException;
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
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

/**
 * Process-wide P2P API registration.
 *
 * <p>APIs registered here live on the process-wide {@code LF_P2P_APP}
 * and are reachable via UID or P2PName addressing, but NOT via
 * App-name addressing. The namespace is orthogonal to the app-bound
 * one.
 *
 * <p>Each registration owns an independent shared arena. On
 * {@link #unregister(String)} the arena is retired through
 * {@link ArenaReaper}, so the native side never observes a dangling
 * stub.
 */
public final class P2PRegistry {

    private static final Linker LINKER = Linker.nativeLinker();
    private static final MethodHandle CALL_BRIDGE;
    private static final MethodHandle NOTIFY_BRIDGE;

    static {
        try {
            MethodHandles.Lookup lookup = MethodHandles.lookup();
            CALL_BRIDGE = lookup.findStatic(
                    P2PRegistry.class,
                    "dispatchCall",
                    MethodType.methodType(
                            void.class,
                            RegisteredCallback.class,
                            MemorySegment.class,
                            MemorySegment.class,
                            MemorySegment.class));
            NOTIFY_BRIDGE = lookup.findStatic(
                    P2PRegistry.class,
                    "dispatchNotify",
                    MethodType.methodType(
                            void.class,
                            RegisteredCallback.class,
                            MemorySegment.class,
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
     * REGISTRATIONS and each holder's private Arena are JAVA-PRIVATE
     * bookkeeping for upcall stubs. They do NOT participate in any
     * wire protocol, and the P2P namespace visible on the wire is
     * entirely owned by the LingoFuse core.
     *
     * The "who owns the lambda" and "who owns the trampoline memory"
     * questions are answered entirely on the Java side, exactly the
     * same way as in the Python binding's `_p2p_callbacks` list and
     * the C# binding's equivalent registry.
     *
     * DO NOT expose these structures to other bindings or migrate
     * them into the native library.
     * ==================================================================
     */
    private static final Map<String, RegisteredCallback> REGISTRATIONS =
            new HashMap<>();

    private P2PRegistry() {
    }

    public static void registerCall(
            String apiName,
            String description,
            BiConsumer<DataHandle, DataHandle> handler) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(handler, "handler must not be null");
        String desc = (description == null) ? "" : description;

        synchronized (LOCK) {
            RegisteredCallback holder =
                    new RegisteredCallback(apiName, handler);
            Arena arena = Arena.ofShared();
            holder.arena = arena;

            try (Arena temp = Arena.ofConfined()) {
                MemorySegment nameSeg = temp.allocateFrom(apiName);
                MemorySegment descSeg = temp.allocateFrom(desc);

                MethodHandle bound = MethodHandles.insertArguments(
                        CALL_BRIDGE, 0, holder);
                MemorySegment stub = LINKER.upcallStub(
                        bound, NativeTypes.LF_CALL_EVENT, arena);
                holder.stub = stub;

                int result = NativeCall.callInt(
                        NativeMethods.LF_Register_P2P_Call,
                        nameSeg, descSeg, MemorySegment.NULL, stub);

                if (result == 1) {
                    REGISTRATIONS.put(apiName.toLowerCase(), holder);
                    return;
                }

                ArenaReaper.retire(arena);
                throw new LingoFuseRegistrationException(
                        "Failed to register P2P Call API '" + apiName
                                + "' (name may already be taken in the "
                                + "process-wide P2P namespace).",
                        apiName,
                        LingoFuseRegistrationException.NAMESPACE_P2P);
            }
        }
    }

    public static void registerCall(
            String apiName,
            BiConsumer<DataHandle, DataHandle> handler) {
        registerCall(apiName, "", handler);
    }

    public static void registerNotify(
            String apiName,
            String description,
            Consumer<DataHandle> handler) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(handler, "handler must not be null");
        String desc = (description == null) ? "" : description;

        synchronized (LOCK) {
            RegisteredCallback holder =
                    new RegisteredCallback(apiName, handler);
            Arena arena = Arena.ofShared();
            holder.arena = arena;

            try (Arena temp = Arena.ofConfined()) {
                MemorySegment nameSeg = temp.allocateFrom(apiName);
                MemorySegment descSeg = temp.allocateFrom(desc);

                MethodHandle bound = MethodHandles.insertArguments(
                        NOTIFY_BRIDGE, 0, holder);
                MemorySegment stub = LINKER.upcallStub(
                        bound, NativeTypes.LF_NOTIFY_EVENT, arena);
                holder.stub = stub;

                int result = NativeCall.callInt(
                        NativeMethods.LF_Register_P2P_Notify,
                        nameSeg, descSeg, MemorySegment.NULL, stub);

                if (result == 1) {
                    REGISTRATIONS.put(apiName.toLowerCase(), holder);
                    return;
                }

                ArenaReaper.retire(arena);
                throw new LingoFuseRegistrationException(
                        "Failed to register P2P Notify API '" + apiName
                                + "' (name may already be taken in the "
                                + "process-wide P2P namespace).",
                        apiName,
                        LingoFuseRegistrationException.NAMESPACE_P2P);
            }
        }
    }

    public static void registerNotify(
            String apiName,
            Consumer<DataHandle> handler) {
        registerNotify(apiName, "", handler);
    }

    public static boolean unregister(String apiName) {
        Objects.requireNonNull(apiName, "apiName must not be null");

        synchronized (LOCK) {
            try (Arena temp = Arena.ofConfined()) {
                MemorySegment nameSeg = temp.allocateFrom(apiName);
                int result = NativeCall.callInt(
                        NativeMethods.LF_Unregister_P2P, nameSeg);

                if (result == 1) {
                    RegisteredCallback holder =
                            REGISTRATIONS.remove(apiName.toLowerCase());
                    if (holder != null && holder.arena != null) {
                        ArenaReaper.retire(holder.arena);
                        holder.arena = null;
                    }
                    return true;
                }
                return false;
            }
        }
    }

    @SuppressWarnings("unused")
    private static void dispatchCall(
            RegisteredCallback holder,
            MemorySegment trigger,
            MemorySegment input,
            MemorySegment output) {
        try {
            @SuppressWarnings("unchecked")
            BiConsumer<DataHandle, DataHandle> handler =
                    (BiConsumer<DataHandle, DataHandle>) holder.userHandler;
            DataHandle inputHandle = DataHandle.fromRaw(input, false);
            DataHandle outputHandle = DataHandle.fromRaw(output, false);
            handler.accept(inputHandle, outputHandle);
        } catch (Throwable t) {
            Framework.reportCallbackError(
                    "P2PRegistry.registerCall[" + holder.apiName + "]", t);
        }
    }

    @SuppressWarnings("unused")
    private static void dispatchNotify(
            RegisteredCallback holder,
            MemorySegment trigger,
            MemorySegment input) {
        try {
            @SuppressWarnings("unchecked")
            Consumer<DataHandle> handler =
                    (Consumer<DataHandle>) holder.userHandler;
            DataHandle inputHandle = DataHandle.fromRaw(input, false);
            handler.accept(inputHandle);
        } catch (Throwable t) {
            Framework.reportCallbackError(
                    "P2PRegistry.registerNotify[" + holder.apiName + "]", t);
        }
    }

    private static final class RegisteredCallback {
        final String apiName;
        final Object userHandler;

        @SuppressWarnings("unused")
        MemorySegment stub;

        Arena arena;

        RegisteredCallback(String apiName, Object userHandler) {
            this.apiName = apiName;
            this.userHandler = userHandler;
        }
    }
}