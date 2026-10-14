package lingofuse;

import lingofuse.errors.LingoFuseException;
import lingofuse.errors.LingoFuseObjectDisposedException;
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
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.BiConsumer;
import java.util.function.Consumer;
import java.util.function.Function;

/**
 * RAII wrapper around a native LingoFuse application handle
 * ({@code TAppHnd}).
 *
 * <p>Owns a native application handle and provides a managed API for
 * registering Call / Notify endpoints, unregistering them, invoking
 * them locally, and binding the application to idle clients.
 *
 * <h2>Arena strategy</h2>
 *
 * <p>Each successful registration allocates its OWN
 * {@link Arena#ofShared() shared arena} that owns the FFM upcall stub
 * for that one endpoint. This is the same strategy used by
 * {@link P2PRegistry}, and it has three concrete advantages over a
 * single shared arena per AppHandle:
 *
 * <ul>
 *   <li><b>Clean failure path.</b> When the native layer rejects a
 *       registration (a duplicate name, for example), the stub arena
 *       that was allocated for that attempt can be retired
 *       immediately via {@link ArenaReaper#retire(Arena)}. A shared
 *       arena could not do this without closing the whole arena.</li>
 *   <li><b>Clean unregister path.</b> {@link #unregister(String)}
 *       retires only the arena that belonged to the removed endpoint,
 *       leaving every other endpoint's stub untouched.</li>
 *   <li><b>No upfront cost.</b> An AppHandle that never registers any
 *       endpoint never allocates an arena at all.</li>
 * </ul>
 *
 * <p>When the AppHandle is closed, {@link #close()} detaches the
 * application on the native side (via {@code LF_FreeApp}) and then
 * retires every still-live registration arena through
 * {@link ArenaReaper}. The 30-second deferred close implemented by
 * {@code ArenaReaper} guarantees that a callback already in flight on
 * a native worker thread still lands on a valid trampoline.
 *
 * <h2>Release order</h2>
 *
 * <p>{@code LF_FreeApp} is called BEFORE any arena is retired. This
 * is deliberate: {@code LF_FreeApp} is what tells the native library
 * to drop its pointers to the upcall stubs. Retiring an arena before
 * the native side stops referencing the stub inside it would create a
 * window in which the native library holds a dangling function
 * pointer. See {@link #close()} for the exact sequence.
 */
public final class AppHandle implements AutoCloseable {

    private static final Linker LINKER = Linker.nativeLinker();
    private static final MethodHandle CALL_BRIDGE;
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

    private volatile MemorySegment handle;
    private final String name;
    private volatile boolean closed;

    /*
     * ==================================================================
     * CROSS-LANGUAGE COMPATIBILITY NOTE
     * ------------------------------------------------------------------
     * The registration map and each RegisteredCallback's private Arena
     * are JAVA-PRIVATE bookkeeping. They exist because:
     *
     *   - the JVM must hold a strong reference to every lambda that
     *     has been promoted to a native function pointer, otherwise
     *     the GC would free the Java object while the C side still
     *     holds the pointer;
     *   - the FFM upcall stub memory must outlive the native library's
     *     last invocation of that pointer.
     *
     * Neither the map nor any arena participates in any wire protocol.
     * They do NOT change the bytes sent by LF_RegisterCall / LF_Unregister,
     * nor the callback dispatch behaviour of the native library.
     *
     * DO NOT push these structures into the LingoFuse core.
     * ==================================================================
     */
    private final Map<String, RegisteredCallback> registrations =
            new HashMap<>();

    private final Object lock = new Object();

    public AppHandle(String name) {
        this(name, "");
    }

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

    public String name() {
        return name;
    }

    public MemorySegment raw() {
        return handle;
    }

    public boolean isValid() {
        return !closed && !isNull(handle);
    }

    /**
     * Executes {@code action} while holding the internal lock and
     * with a guaranteed-valid handle. The action receives the raw
     * native pointer; it must not retain it beyond the call.
     *
     * <p>This is the correct way for {@code Framework} to use an
     * {@code AppHandle} as an argument to a native call: it prevents
     * a concurrent {@link #close()} from freeing the handle while the
     * native call is executing.
     */
    public <T> T withHandle(Function<MemorySegment, T> action) {
        Objects.requireNonNull(action, "action must not be null");
        synchronized (lock) {
            if (closed || isNull(handle)) {
                throw new LingoFuseObjectDisposedException("AppHandle");
            }
            return action.apply(handle);
        }
    }

    public boolean registerCall(
            String apiName,
            BiConsumer<DataHandle, DataHandle> handler) {
        return registerCall(apiName, "", handler);
    }

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

    public boolean registerNotify(
            String apiName,
            Consumer<DataHandle> handler) {
        return registerNotify(apiName, "", handler);
    }

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
     * Removes a previously registered API.
     *
     * <p>Release order:
     * <ol>
     *   <li>{@code LF_Unregister} — the native library drops its
     *       pointer to this endpoint's stub.</li>
     *   <li>{@link ArenaReaper#retire(Arena)} — the arena that owns
     *       the stub is retired with the standard grace period, so
     *       any callback already in flight on a native worker thread
     *       still lands on a valid trampoline.</li>
     * </ol>
     *
     * <p>The native call runs first. Retiring the arena while the
     * native library still holds a pointer to the stub inside it
     * would create a window in which an incoming callback could jump
     * into freed native code.
     *
     * @param apiName the API name
     * @return {@code true} if the API was found and removed
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
                    RegisteredCallback holder =
                            registrations.remove(apiName.toLowerCase());
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

    public DataHandle localCall(DataHandle param) {
        Objects.requireNonNull(param, "param must not be null");

        synchronized (lock) {
            ensureOpen();
            MemorySegment result = param.withHandle(
                    h -> NativeCall.callSeg(
                            NativeMethods.LF_LocalCall, handle, h));
            if (isNull(result)) {
                throw new LingoFuseException(
                        "LF_LocalCall returned a null handle.");
            }
            return DataHandle.fromRaw(result, true);
        }
    }

    public void localNotify(DataHandle param) {
        Objects.requireNonNull(param, "param must not be null");

        synchronized (lock) {
            ensureOpen();
            param.withHandle(h -> {
                NativeCall.callVoid(NativeMethods.LF_LocalNotify, handle, h);
                return null;
            });
        }
    }

    public int bind() {
        synchronized (lock) {
            ensureOpen();
            return NativeCall.callInt(NativeMethods.LF_BindApp, handle);
        }
    }

    /**
     * Performs the first stage of the two-stage native destruction.
     *
     * <p>Release order (see the class header for the rationale):
     * <ol>
     *   <li>{@code LF_FreeApp(handle)} — the native library drops
     *       every pointer to every stub registered through this
     *       handle.</li>
     *   <li>{@link ArenaReaper#retire(Arena)} for each registration
     *       arena — the arenas that own the stubs are retired with
     *       the standard grace period.</li>
     * </ol>
     *
     * <p>The native call MUST run first. Retiring the arenas before
     * {@code LF_FreeApp} would leave the native library holding
     * dangling function pointers for the duration of the
     * {@code LF_FreeApp} call (which detaches clients, stops
     * sequenced threads and removes the update timer); any callback
     * firing in that window would jump to freed memory.
     *
     * <p>Even if {@code LF_FreeApp} raises, every arena is still
     * retired. Without that, FFM would leak native trampoline memory
     * and the JVM might be kept alive by pending callback handles.
     *
     * <p>Safe to call multiple times. After the first call, all
     * methods that require a live handle throw
     * {@link LingoFuseObjectDisposedException}.
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

            // Snapshot the registrations and clear the map up front,
            // so that a re-entrant call from a callback body observes
            // an already-disposed handle.
            List<RegisteredCallback> holders =
                    new ArrayList<>(registrations.values());
            registrations.clear();

            MemorySegment snapshot = handle;
            handle = MemorySegment.NULL;

            // Step 1: detach the application on the native side. After
            // this call returns, the native library no longer holds any
            // pointer to the FFM upcall stubs registered through this
            // handle.
            if (!isNull(snapshot)) {
                try {
                    NativeCall.callVoid(NativeMethods.LF_FreeApp, snapshot);
                } catch (Throwable ignored) {
                    // A throwing native call must not prevent us from
                    // retiring the stub arenas below.
                }
            }

            // Step 2: retire each per-registration arena now that the
            // native library no longer references the stubs.
            for (RegisteredCallback holder : holders) {
                if (holder.arena != null) {
                    ArenaReaper.retire(holder.arena);
                    holder.arena = null;
                }
            }
        }
    }

    private boolean registerCallLocked(
            String apiName,
            String description,
            BiConsumer<DataHandle, DataHandle> handler) {

        RegisteredCallback holder = new RegisteredCallback(apiName, handler);
        Arena arena = Arena.ofShared();
        holder.arena = arena;

        try (Arena temp = Arena.ofConfined()) {
            MemorySegment nameSeg = temp.allocateFrom(apiName);
            MemorySegment descSeg = temp.allocateFrom(description);

            MethodHandle bound = MethodHandles.insertArguments(
                    CALL_BRIDGE, 0, holder);
            MemorySegment stub = LINKER.upcallStub(
                    bound, NativeTypes.LF_CALL_EVENT, arena);
            holder.stub = stub;

            int result;
            try {
                result = NativeCall.callInt(
                        NativeMethods.LF_RegisterCall,
                        handle, nameSeg, descSeg, MemorySegment.NULL, stub);
            } catch (Throwable t) {
                // The native call raised before accepting the stub.
                // Retire this attempt's arena and propagate.
                ArenaReaper.retire(arena);
                holder.arena = null;
                throw t;
            }

            if (result == 1) {
                registrations.put(apiName.toLowerCase(), holder);
                return true;
            }

            // Registration rejected (most likely a duplicate name).
            // Retire this attempt's arena so the stub does not linger
            // until AppHandle.close().
            ArenaReaper.retire(arena);
            holder.arena = null;
            return false;
        }
    }

    private boolean registerNotifyLocked(
            String apiName,
            String description,
            Consumer<DataHandle> handler) {

        RegisteredCallback holder = new RegisteredCallback(apiName, handler);
        Arena arena = Arena.ofShared();
        holder.arena = arena;

        try (Arena temp = Arena.ofConfined()) {
            MemorySegment nameSeg = temp.allocateFrom(apiName);
            MemorySegment descSeg = temp.allocateFrom(description);

            MethodHandle bound = MethodHandles.insertArguments(
                    NOTIFY_BRIDGE, 0, holder);
            MemorySegment stub = LINKER.upcallStub(
                    bound, NativeTypes.LF_NOTIFY_EVENT, arena);
            holder.stub = stub;

            int result;
            try {
                result = NativeCall.callInt(
                        NativeMethods.LF_RegisterNotify,
                        handle, nameSeg, descSeg, MemorySegment.NULL, stub);
            } catch (Throwable t) {
                ArenaReaper.retire(arena);
                holder.arena = null;
                throw t;
            }

            if (result == 1) {
                registrations.put(apiName.toLowerCase(), holder);
                return true;
            }

            ArenaReaper.retire(arena);
            holder.arena = null;
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

    private static final class RegisteredCallback {
        final String apiName;
        final Object userHandler;

        @SuppressWarnings("unused")
        MemorySegment stub;

        /**
         * The shared arena that owns {@link #stub}. Set at
         * registration time and cleared when the arena is retired.
         *
         * <p>Not final because {@link #unregister(String)} and
         * {@link #close()} both clear it after handing the arena to
         * {@link ArenaReaper}.
         */
        Arena arena;

        RegisteredCallback(String apiName, Object userHandler) {
            this.apiName = apiName;
            this.userHandler = userHandler;
        }
    }
}