package lingofuse;

import lingofuse.errors.LingoFuseException;
import lingofuse.errors.LingoFuseObjectDisposedException;
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
 * RAII wrapper around a native LingoFuse application handle
 * ({@code TAppHnd}).
 *
 * <p>Owns a native application handle and provides a managed API for
 * registering Call / Notify endpoints, unregistering them, invoking
 * them locally, and binding the application to idle clients.
 *
 * <h2>Callback model</h2>
 *
 * <p>The wrapper presents a user-facing callback signature that
 * receives managed {@link DataHandle} instances instead of raw
 * pointers:
 *
 * <ul>
 *   <li>Call mode:
 *       {@code BiConsumer<DataHandle, DataHandle>} - (input, output)</li>
 *   <li>Notify mode:
 *       {@code Consumer<DataHandle>} - (input)</li>
 * </ul>
 *
 * <p>The {@code DataHandle} instances passed to a user callback are
 * BORROWED ({@code owned = false}). They must NOT be closed by the
 * callback body; the native layer releases them as soon as the
 * callback returns.
 *
 * <h2>Callback lifetime</h2>
 *
 * <p>The native library stores raw function pointers. To turn a Java
 * lambda into such a pointer, this class uses
 * {@link Linker#upcallStub(MethodHandle, java.lang.foreign.FunctionDescriptor, Arena)}.
 * The resulting stub is a {@link MemorySegment} whose lifetime is
 * bound to the {@link #callbackArena}, which lives as long as the
 * {@code AppHandle}. A stub is only released when the {@code AppHandle}
 * is closed.
 *
 * <p>Each stub is bound to a {@link RegisteredCallback} holder, which
 * in turn holds a strong reference to the user-supplied lambda. This
 * chain of references keeps the lambda alive for as long as the
 * native library may invoke it. Without this, the JVM garbage
 * collector could reclaim the lambda while the native side still held
 * its function pointer, causing a crash on the next invocation.
 *
 * <h2>Callback exception policy</h2>
 *
 * <p>User callbacks run on native worker threads. An exception
 * escaping a callback would cross into the C stack and could
 * destabilize the process. The wrapper therefore catches every
 * exception and reports it through {@link Framework#reportCallbackError(String, Throwable)}.
 * The native layer sees a callback that completed without producing
 * output.
 *
 * <h2>Thread safety</h2>
 *
 * <p>Every public method that touches the native handle or the
 * {@code registrations} map is serialized under {@code lock}. This
 * closes the race between an in-flight {@code register*} call and a
 * concurrent {@link #close()}: the two cannot interleave in a way
 * that leaves {@code LF_RegisterCall} operating on an already-freed
 * handle.
 */
public final class AppHandle implements AutoCloseable {

    // ------------------------------------------------------------------
    // Static initialization: pre-resolve the upcall bridge method handles
    // ------------------------------------------------------------------

    private static final Linker LINKER = Linker.nativeLinker();

    /**
     * The static bridge method that each Call upcall stub invokes.
     * Signature: {@code (RegisteredCallback, MemorySegment, MemorySegment, MemorySegment) -> void}.
     *
     * <p>Referenced only through {@link MethodHandles.Lookup#findStatic}
     * at class initialisation time. A static analysis tool cannot see
     * this indirect use, which is why the bridge methods carry an
     * {@code @SuppressWarnings("unused")} annotation.
     */
    private static final MethodHandle CALL_BRIDGE;

    /**
     * The static bridge method that each Notify upcall stub invokes.
     * Signature: {@code (RegisteredCallback, MemorySegment, MemorySegment) -> void}.
     *
     * <p>Referenced only through {@link MethodHandles.Lookup#findStatic}.
     */
    private static final MethodHandle NOTIFY_BRIDGE;

    static {
        try {
            MethodHandles.Lookup lookup = MethodHandles.lookup();
            CALL_BRIDGE = lookup.findStatic(
                    AppHandle.class,
                    "dispatchCall",
                    MethodType.methodType(
                            void.class,
                            RegisteredCallback.class,
                            MemorySegment.class,
                            MemorySegment.class,
                            MemorySegment.class));
            NOTIFY_BRIDGE = lookup.findStatic(
                    AppHandle.class,
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
    // Instance state
    // ------------------------------------------------------------------

    private volatile MemorySegment handle;
    private final String name;
    private volatile boolean closed;

    /**
     * Arena that owns every upcall stub created by this instance.
     *
     * <p>{@link Arena#ofShared()} is used rather than
     * {@code Arena.ofConfined()} because callbacks may be invoked from
     * any native worker thread.
     */
    private final Arena callbackArena = Arena.ofShared();

    /**
     * Registered callbacks, indexed by API name with case-insensitive
     * lookup. The map holds the {@link RegisteredCallback} holders,
     * which keep the user-supplied lambdas alive for as long as the
     * registration is active.
     */
    private final Map<String, RegisteredCallback> registrations =
            new HashMap<>();

    /**
     * Guards every mutation of the native handle and of the
     * {@code registrations} map.
     */
    private final Object lock = new Object();

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /**
     * Creates a new application with the given name and an empty
     * description.
     *
     * @param name the application name; must not be null
     * @throws NullPointerException if {@code name} is null
     * @throws LingoFuseException   if the native side fails to allocate
     */
    public AppHandle(String name) {
        this(name, "");
    }

    /**
     * Creates a new application with the given name and description.
     *
     * @param name        the application name; must not be null
     * @param description a human-readable description; null is treated
     *                    as an empty string
     * @throws NullPointerException if {@code name} is null
     * @throws LingoFuseException   if the native side fails to allocate
     */
    public AppHandle(String name, String description) {
        Objects.requireNonNull(name, "name must not be null");
        String desc = (description == null) ? "" : description;

        try (Arena temp = Arena.ofConfined()) {
            MemorySegment nameSeg = temp.allocateFrom(name);
            MemorySegment descSeg = temp.allocateFrom(desc);

            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_CreateApp, nameSeg, descSeg);
            if (isNull(raw)) {
                throw new LingoFuseException(
                        "Failed to create application '" + name + "'");
            }
            this.handle = raw;
            this.name = name;
        }
    }

    // ------------------------------------------------------------------
    // Identity and state
    // ------------------------------------------------------------------

    /**
     * Returns the application name passed to the constructor.
     *
     * @return the application name
     */
    public String name() {
        return name;
    }

    /**
     * Returns the raw native pointer. Returns
     * {@link MemorySegment#NULL} after {@link #close()}.
     *
     * @return the raw handle
     */
    public MemorySegment raw() {
        return handle;
    }

    /**
     * Returns whether the handle is valid and not yet closed.
     *
     * @return true while the handle is usable
     */
    public boolean isValid() {
        return !closed && !isNull(handle);
    }

    // ==================================================================
    // API registration
    // ==================================================================

    /**
     * Registers a Call API with the default empty description.
     *
     * @param apiName the API name; must not be null
     * @param handler the user callback; must not be null
     * @return true on success, false if the API name is already taken
     */
    public boolean registerCall(
            String apiName,
            BiConsumer<DataHandle, DataHandle> handler) {
        return registerCall(apiName, "", handler);
    }

    /**
     * Registers a Call API whose handler runs on a native worker
     * thread.
     *
     * @param apiName     the API name; must not be null
     * @param description an optional description
     * @param handler     the user callback; must not be null
     * @return true on success, false if the API name is already taken
     */
    public boolean registerCall(
            String apiName,
            String description,
            BiConsumer<DataHandle, DataHandle> handler) {
        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(handler, "handler must not be null");
        String desc = (description == null) ? "" : description;

        synchronized (lock) {
            ensureOpen();
            return registerCallLocked(apiName, desc, handler);
        }
    }

    /**
     * Registers a Notify API with the default empty description.
     *
     * @param apiName the API name; must not be null
     * @param handler the user callback; must not be null
     * @return true on success, false if the API name is already taken
     */
    public boolean registerNotify(
            String apiName,
            Consumer<DataHandle> handler) {
        return registerNotify(apiName, "", handler);
    }

    /**
     * Registers a Notify API whose handler runs on a native worker
     * thread.
     *
     * @param apiName     the API name; must not be null
     * @param description an optional description
     * @param handler     the user callback; must not be null
     * @return true on success, false if the API name is already taken
     */
    public boolean registerNotify(
            String apiName,
            String description,
            Consumer<DataHandle> handler) {
        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(handler, "handler must not be null");
        String desc = (description == null) ? "" : description;

        synchronized (lock) {
            ensureOpen();
            return registerNotifyLocked(apiName, desc, handler);
        }
    }

    /**
     * Unregisters a previously registered API.
     *
     * @param apiName the API name; must not be null
     * @return true if the API was found and removed
     */
    public boolean unregister(String apiName) {
        Objects.requireNonNull(apiName, "apiName must not be null");

        synchronized (lock) {
            ensureOpen();

            try (Arena temp = Arena.ofConfined()) {
                MemorySegment nameSeg = temp.allocateFrom(apiName);
                int result = NativeCall.callInt(
                        NativeMethods.LF_Unregister, handle, nameSeg);

                if (result == 1) {
                    registrations.remove(apiName.toLowerCase());
                    return true;
                }
                return false;
            }
        }
    }

    // ==================================================================
    // Local execution
    // ==================================================================

    /**
     * Invokes a Call API locally within the same process.
     *
     * <p>The input handle is not consumed by this call.
     *
     * @param param the input data handle; must not be null
     * @return a new {@link DataHandle} owning the result
     */
    public DataHandle localCall(DataHandle param) {
        Objects.requireNonNull(param, "param must not be null");

        synchronized (lock) {
            ensureOpen();

            MemorySegment result = NativeCall.callSeg(
                    NativeMethods.LF_LocalCall, handle, param.raw());
            if (isNull(result)) {
                throw new LingoFuseException(
                        "LF_LocalCall returned a null handle.");
            }
            return DataHandle.fromRaw(result, true);
        }
    }

    /**
     * Invokes a Notify API locally within the same process.
     *
     * @param param the input data handle; must not be null
     */
    public void localNotify(DataHandle param) {
        Objects.requireNonNull(param, "param must not be null");

        synchronized (lock) {
            ensureOpen();
            NativeCall.callVoid(
                    NativeMethods.LF_LocalNotify, handle, param.raw());
        }
    }

    // ==================================================================
    // Client binding
    // ==================================================================

    /**
     * Binds the application to all currently unbound clients.
     *
     * @return the number of clients bound
     */
    public int bind() {
        synchronized (lock) {
            ensureOpen();
            return NativeCall.callInt(NativeMethods.LF_BindApp, handle);
        }
    }

    // ==================================================================
    // Lifetime
    // ==================================================================

    /**
     * Performs the first stage of the two-stage native destruction.
     * Safe to call multiple times.
     */
    @Override
    public void close() {
        if (closed) {
            return;
        }
        synchronized (lock) {
            if (closed) {
                return;
            }
            closed = true;

            registrations.clear();

            MemorySegment snapshot = handle;
            handle = MemorySegment.NULL;

            if (!isNull(snapshot)) {
                try {
                    NativeCall.callVoid(NativeMethods.LF_FreeApp, snapshot);
                } finally {
                    callbackArena.close();
                }
            } else {
                callbackArena.close();
            }
        }
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    private boolean registerCallLocked(
            String apiName,
            String description,
            BiConsumer<DataHandle, DataHandle> handler) {

        RegisteredCallback holder = new RegisteredCallback(apiName, handler);

        try (Arena temp = Arena.ofConfined()) {
            MemorySegment nameSeg = temp.allocateFrom(apiName);
            MemorySegment descSeg = temp.allocateFrom(description);

            MethodHandle bound = MethodHandles.insertArguments(
                    CALL_BRIDGE, 0, holder);
            MemorySegment stub = LINKER.upcallStub(
                    bound, NativeTypes.LF_CALL_EVENT, callbackArena);
            holder.stub = stub;

            int result = NativeCall.callInt(
                    NativeMethods.LF_RegisterCall,
                    handle,
                    nameSeg,
                    descSeg,
                    MemorySegment.NULL,
                    stub);

            if (result == 1) {
                registrations.put(apiName.toLowerCase(), holder);
                return true;
            }
            return false;
        }
    }

    private boolean registerNotifyLocked(
            String apiName,
            String description,
            Consumer<DataHandle> handler) {

        RegisteredCallback holder = new RegisteredCallback(apiName, handler);

        try (Arena temp = Arena.ofConfined()) {
            MemorySegment nameSeg = temp.allocateFrom(apiName);
            MemorySegment descSeg = temp.allocateFrom(description);

            MethodHandle bound = MethodHandles.insertArguments(
                    NOTIFY_BRIDGE, 0, holder);
            MemorySegment stub = LINKER.upcallStub(
                    bound, NativeTypes.LF_NOTIFY_EVENT, callbackArena);
            holder.stub = stub;

            int result = NativeCall.callInt(
                    NativeMethods.LF_RegisterNotify,
                    handle,
                    nameSeg,
                    descSeg,
                    MemorySegment.NULL,
                    stub);

            if (result == 1) {
                registrations.put(apiName.toLowerCase(), holder);
                return true;
            }
            return false;
        }
    }

    private void ensureOpen() {
        if (closed || isNull(handle)) {
            throw new LingoFuseObjectDisposedException("AppHandle");
        }
    }

    private static boolean isNull(MemorySegment seg) {
        return seg == null || seg.address() == 0L;
    }

    // ==================================================================
    // Callback bridge methods
    // ==================================================================
    //
    // These methods are referenced only through
    // MethodHandles.Lookup.findStatic at class initialisation time.
    // The @SuppressWarnings("unused") annotation is required because
    // a static analysis tool cannot see the reflective use.

    /**
     * Static bridge method for Call-mode callbacks.
     *
     * @param holder the per-registration holder, bound at stub creation
     * @param trigger the user trigger pointer (unused by this binding)
     * @param input the borrowed input handle
     * @param output the borrowed output handle
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
                    "AppHandle.registerCall[" + holder.apiName + "]", t);
        }
    }

    /**
     * Static bridge method for Notify-mode callbacks.
     *
     * @param holder the per-registration holder, bound at stub creation
     * @param trigger the user trigger pointer (unused by this binding)
     * @param input the borrowed input handle
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
                    "AppHandle.registerNotify[" + holder.apiName + "]", t);
        }
    }

    // ==================================================================
    // Internal holder
    // ==================================================================

    /**
     * Per-registration holder. Keeps the user-supplied lambda, the
     * API name, and the upcall stub alive for as long as the
     * registration is active.
     */
    private static final class RegisteredCallback {

        final String apiName;
        final Object userHandler;

        /**
         * The upcall stub returned by {@code Linker.upcallStub}. Stored
         * for diagnostic purposes and to make the ownership chain
         * explicit; the actual lifetime is managed by the enclosing
         * {@code callbackArena}, so this field is never read directly.
         */
        @SuppressWarnings("unused")
        MemorySegment stub;

        RegisteredCallback(String apiName, Object userHandler) {
            this.apiName = apiName;
            this.userHandler = userHandler;
        }
    }
}