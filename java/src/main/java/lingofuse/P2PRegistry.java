package lingofuse;

import lingofuse.errors.LingoFuseRegistrationException;
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
 * <p>APIs registered here live on the process-wide
 * {@code LF_P2P_APP} and are reachable via UID addressing or P2PName
 * addressing from any client in the mesh, without requiring the
 * caller to know the target App name. They are NOT reachable via
 * App-name addressing, even if the registered API name happens to
 * match an App name.
 *
 * <h2>Relation to AppHandle</h2>
 *
 * <p>{@link AppHandle#registerCall} / {@link AppHandle#registerNotify}
 * register into the APP-BOUND namespace, which is owned by the
 * handle's {@code TLF_App}. That namespace dies with the App (which
 * is detached by {@code LF_FreeApp} and destroyed by
 * {@code LF_Shutdown}).
 *
 * <p>This class registers into the PROCESS-WIDE P2P namespace, which
 * is owned by the process itself and survives until the process
 * exits. The two namespaces are orthogonal: a name registered in one
 * does NOT collide with the same name in the other.
 *
 * <h2>Typical use</h2>
 *
 * <p>Register a small set of globally-discoverable utility APIs
 * (health probes, capability discovery, identity echo) that any
 * client in the mesh can call by group name or by UID. For example:
 *
 * <pre>{@code
 * P2PRegistry.registerCall("whoami", "Echo the caller's identity",
 *     (in, out) -> {
 *         byte[] uid = in.getP2pUid();
 *         String name = in.getP2pName();
 *         LfIo.writeJson(out, Map.of(
 *             "uid_hex", toHex(uid),
 *             "p2p_name", name));
 *     });
 * }</pre>
 *
 * <h2>Callback lifetime</h2>
 *
 * <p>The native library holds a raw function pointer to each
 * installed callback. To turn a Java lambda into such a pointer, this
 * class uses
 * {@link Linker#upcallStub(MethodHandle, java.lang.foreign.FunctionDescriptor, Arena)}.
 * All stubs share a single process-wide {@link Arena#ofShared()},
 * which is never closed: the stubs must remain valid until the JVM
 * exits, because a remote caller may invoke the API at any time.
 *
 * <p>Each stub is bound to a {@link RegisteredCallback} holder, which
 * in turn holds a strong reference to the user-supplied lambda. The
 * holder is stored in the module-level {@link #REGISTRATIONS} map,
 * which is never cleared. This chain of references keeps the lambda
 * alive for as long as the JVM may receive a call, matching the
 * contract of the Python binding's {@code _p2p_callbacks} list.
 *
 * <p>The {@link #unregister(String)} method removes the name from the
 * native registry but deliberately does NOT release the holder, the
 * stub, or the lambda. The native library does not provide a way to
 * release a callback object, and keeping the reference is harmless (a
 * few dozen bytes per registration) while removing it would risk a
 * use-after-free if the library still holds the pointer.
 *
 * <h2>Callback exception policy</h2>
 *
 * <p>User callbacks run on native worker threads. An exception
 * escaping a callback would cross into the C stack and could
 * destabilize the process. The wrapper therefore catches every
 * exception and reports it through
 * {@link Framework#reportCallbackError(String, Throwable)}. The
 * native layer sees a callback that completed without producing
 * output.
 *
 * <h2>Threading</h2>
 *
 * <p>Registration, unregistration, and callback invocation are all
 * safe to run concurrently. The static initialization of the bridge
 * method handles and of the registration map is performed once, under
 * the class initializer's implicit lock. Every public method takes
 * the module-level {@link #LOCK} before mutating shared state.
 *
 * <h2>Pre- and post-startup registration</h2>
 *
 * <p>Registration may be performed at any point in the process
 * lifetime, both before and after {@link Framework#prepareDone()}.
 * The native library does not require the main thread to be running
 * in order to accept a P2P registration.
 */
public final class P2PRegistry {

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
     * The static bridge method that each P2P Call upcall stub
     * invokes. Signature:
     * {@code (RegisteredCallback, MemorySegment, MemorySegment, MemorySegment) -> void}.
     */
    private static final MethodHandle CALL_BRIDGE;

    /**
     * The static bridge method that each P2P Notify upcall stub
     * invokes. Signature:
     * {@code (RegisteredCallback, MemorySegment, MemorySegment) -> void}.
     */
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

    // ------------------------------------------------------------------
    // Module-level state
    // ------------------------------------------------------------------

    /**
     * Guards every mutation of {@link #REGISTRATIONS}.
     */
    private static final Object LOCK = new Object();

    /**
     * Registered callbacks, indexed by lower-cased API name. Holds the
     * {@link RegisteredCallback} holders, which keep the user-supplied
     * lambdas alive for the process lifetime.
     *
     * <p>This map is never cleared. See the class Javadoc for the full
     * rationale.
     */
    private static final Map<String, RegisteredCallback> REGISTRATIONS =
            new HashMap<>();

    private P2PRegistry() {
        // Utility class; no instances.
    }

    // ==================================================================
    // Public API
    // ==================================================================

    /**
     * Registers a process-wide P2P Call API.
     *
     * <p>The API becomes reachable via UID addressing or P2PName
     * addressing from any client in the mesh, without requiring the
     * caller to know the target App name. It is NOT reachable via
     * App-name addressing.
     *
     * @param apiName     the API name; must not be null
     * @param description an optional description; null is treated as
     *                    an empty string
     * @param handler     the user callback; must not be null. It runs
     *                    on a native worker thread. It MUST NOT block,
     *                    and MUST NOT call any blocking LingoFuse
     *                    function. Any exception it throws is caught
     *                    and reported; it never escapes into the C
     *                    stack.
     * @throws NullPointerException         if {@code apiName} or
     *                                      {@code handler} is null
     * @throws LingoFuseRegistrationException
     *                                      if the name is already
     *                                      taken in the process-wide
     *                                      P2P namespace, or the
     *                                      native layer rejects the
     *                                      registration for any other
     *                                      reason
     */
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

            try (Arena temp = Arena.ofConfined()) {
                MemorySegment nameSeg = temp.allocateFrom(apiName);
                MemorySegment descSeg = temp.allocateFrom(desc);

                MethodHandle bound = MethodHandles.insertArguments(
                        CALL_BRIDGE, 0, holder);
                MemorySegment stub = LINKER.upcallStub(
                        bound, NativeTypes.LF_CALL_EVENT, CALLBACK_ARENA);
                holder.stub = stub;

                int result = NativeCall.callInt(
                        NativeMethods.LF_Register_P2P_Call,
                        nameSeg,
                        descSeg,
                        MemorySegment.NULL,
                        stub);

                if (result == 1) {
                    REGISTRATIONS.put(apiName.toLowerCase(), holder);
                    return;
                }

                throw new LingoFuseRegistrationException(
                        "Failed to register P2P Call API '" + apiName
                                + "' (name may already be taken in the "
                                + "process-wide P2P namespace).",
                        apiName,
                        LingoFuseRegistrationException.NAMESPACE_P2P);
            }
        }
    }

    /**
     * Registers a process-wide P2P Call API with an empty
     * description.
     *
     * <p>Convenience overload of
     * {@link #registerCall(String, String, BiConsumer)}.
     *
     * @param apiName the API name; must not be null
     * @param handler the user callback; must not be null
     */
    public static void registerCall(
            String apiName,
            BiConsumer<DataHandle, DataHandle> handler) {
        registerCall(apiName, "", handler);
    }

    /**
     * Registers a process-wide P2P Notify API.
     *
     * <p>Same namespace and lifetime rules as
     * {@link #registerCall(String, String, BiConsumer)}; the
     * difference is that a Notify API has no output handle.
     *
     * @param apiName     the API name; must not be null
     * @param description an optional description; null is treated as
     *                    an empty string
     * @param handler     the user callback; must not be null. It runs
     *                    on a native worker thread. It MUST NOT block,
     *                    and MUST NOT call any blocking LingoFuse
     *                    function. Any exception it throws is caught
     *                    and reported; it never escapes into the C
     *                    stack.
     * @throws NullPointerException         if {@code apiName} or
     *                                      {@code handler} is null
     * @throws LingoFuseRegistrationException
     *                                      if the name is already
     *                                      taken in the process-wide
     *                                      P2P namespace
     */
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

            try (Arena temp = Arena.ofConfined()) {
                MemorySegment nameSeg = temp.allocateFrom(apiName);
                MemorySegment descSeg = temp.allocateFrom(desc);

                MethodHandle bound = MethodHandles.insertArguments(
                        NOTIFY_BRIDGE, 0, holder);
                MemorySegment stub = LINKER.upcallStub(
                        bound, NativeTypes.LF_NOTIFY_EVENT, CALLBACK_ARENA);
                holder.stub = stub;

                int result = NativeCall.callInt(
                        NativeMethods.LF_Register_P2P_Notify,
                        nameSeg,
                        descSeg,
                        MemorySegment.NULL,
                        stub);

                if (result == 1) {
                    REGISTRATIONS.put(apiName.toLowerCase(), holder);
                    return;
                }

                throw new LingoFuseRegistrationException(
                        "Failed to register P2P Notify API '" + apiName
                                + "' (name may already be taken in the "
                                + "process-wide P2P namespace).",
                        apiName,
                        LingoFuseRegistrationException.NAMESPACE_P2P);
            }
        }
    }

    /**
     * Registers a process-wide P2P Notify API with an empty
     * description.
     *
     * <p>Convenience overload of
     * {@link #registerNotify(String, String, Consumer)}.
     *
     * @param apiName the API name; must not be null
     * @param handler the user callback; must not be null
     */
    public static void registerNotify(
            String apiName,
            Consumer<DataHandle> handler) {
        registerNotify(apiName, "", handler);
    }

    /**
     * Removes a previously registered process-wide P2P API.
     *
     * <p>The removal is immediate locally. Remote peers may still see
     * the API for up to about 3 seconds until the network broadcast
     * propagates.
     *
     * <p>This method removes the name from the native registry, but it
     * deliberately does NOT release the {@link RegisteredCallback}
     * holder, the upcall stub, or the user lambda. See the class
     * Javadoc for the full rationale.
     *
     * @param apiName the API name; must not be null
     * @return true if the API was found and removed
     * @throws NullPointerException if {@code apiName} is null
     */
    public static boolean unregister(String apiName) {
        Objects.requireNonNull(apiName, "apiName must not be null");

        synchronized (LOCK) {
            try (Arena temp = Arena.ofConfined()) {
                MemorySegment nameSeg = temp.allocateFrom(apiName);
                int result = NativeCall.callInt(
                        NativeMethods.LF_Unregister_P2P, nameSeg);

                if (result == 1) {
                    REGISTRATIONS.remove(apiName.toLowerCase());
                    return true;
                }
                return false;
            }
        }
    }

    // ==================================================================
    // Callback bridge methods
    // ==================================================================
    //
    // These methods are referenced only through
    // MethodHandles.Lookup.findStatic at class initialisation time.
    // The @SuppressWarnings("unused") annotation is required because a
    // static analysis tool cannot see the reflective use.

    /**
     * Static bridge method for P2P Call-mode callbacks.
     *
     * @param holder  the per-registration holder, bound at stub
     *                creation
     * @param trigger the user trigger pointer (unused by this binding)
     * @param input   the borrowed input handle
     * @param output  the borrowed output handle
     */
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

    /**
     * Static bridge method for P2P Notify-mode callbacks.
     *
     * @param holder  the per-registration holder, bound at stub
     *                creation
     * @param trigger the user trigger pointer (unused by this binding)
     * @param input   the borrowed input handle
     */
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

    // ==================================================================
    // Internal holder
    // ==================================================================

    /**
     * Per-registration holder. Keeps the user-supplied lambda, the API
     * name, and the upcall stub alive for the process lifetime.
     */
    private static final class RegisteredCallback {

        final String apiName;
        final Object userHandler;

        /**
         * The upcall stub returned by {@code Linker.upcallStub}. Stored
         * for diagnostic purposes and to make the ownership chain
         * explicit; the actual lifetime is managed by
         * {@link #CALLBACK_ARENA}, so this field is never read
         * directly.
         */
        @SuppressWarnings("unused")
        MemorySegment stub;

        RegisteredCallback(String apiName, Object userHandler) {
            this.apiName = apiName;
            this.userHandler = userHandler;
        }
    }
}