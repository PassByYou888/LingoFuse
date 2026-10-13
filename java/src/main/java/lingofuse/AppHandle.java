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
import java.util.HashMap;
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
 * <p>The callback arena is retired through {@link ArenaReaper} on
 * {@link #close()}, so a callback that is still running on a native
 * worker thread is never left pointing at freed native code.
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

    private final Arena callbackArena = Arena.ofShared();

    /*
     * ==================================================================
     * CROSS-LANGUAGE COMPATIBILITY NOTE
     * ------------------------------------------------------------------
     * The registration map and the callbackArena are JAVA-PRIVATE
     * bookkeeping. They exist because:
     *
     *   - the JVM must hold a strong reference to every lambda that
     *     has been promoted to a native function pointer, otherwise
     *     the GC would free the Java object while the C side still
     *     holds the pointer;
     *   - the FFM upcall stub memory must outlive the native library's
     *     last invocation of that pointer.
     *
     * Neither the map nor the arena participates in any wire protocol.
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

    public void localNotify(DataHandle param) {
        Objects.requireNonNull(param, "param must not be null");

        synchronized (lock) {
            ensureOpen();
            NativeCall.callVoid(
                    NativeMethods.LF_LocalNotify, handle, param.raw());
        }
    }

    public int bind() {
        synchronized (lock) {
            ensureOpen();
            return NativeCall.callInt(NativeMethods.LF_BindApp, handle);
        }
    }

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
                    // Defer arena close: in-flight callbacks may still
                    // be running on native worker threads.
                    ArenaReaper.retire(callbackArena);
                }
            } else {
                ArenaReaper.retire(callbackArena);
            }
        }
    }

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
                    handle, nameSeg, descSeg, MemorySegment.NULL, stub);

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
                    handle, nameSeg, descSeg, MemorySegment.NULL, stub);

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

        RegisteredCallback(String apiName, Object userHandler) {
            this.apiName = apiName;
            this.userHandler = userHandler;
        }
    }
}