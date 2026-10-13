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
 * <p>Change log for the current revision:
 * <ul>
 *   <li>{@code reportCallbackError} writes to stderr only when
 *       {@code setCallbackErrorStderrFallback(true)} is in effect.
 *       The default is true; applications that install a
 *       {@code callbackErrorHandler} can disable the stderr sink by
 *       calling {@code setCallbackErrorStderrFallback(false)}.</li>
 *   <li>UID arguments are zeroed before the arena that holds them is
 *       closed, so a freed native buffer never retains the UID
 *       octets.</li>
 *   <li>{@code prepareClient} routes the {@code AppHandle} argument
 *       through {@link AppHandle#withHandle}, which closes the race
 *       between a concurrent {@code AppHandle.close()} and the native
 *       call.</li>
 *   <li>All {@code reinterpret(Long.MAX_VALUE)} occurrences have been
 *       replaced by a bounded {@code MAX_C_STRING_LENGTH}.</li>
 * </ul>
 */
public final class Framework {

    private Framework() {
    }

    // ==================================================================
    // Callback error reporting
    // ==================================================================

    /*
     * ==================================================================
     * CROSS-LANGUAGE COMPATIBILITY NOTE
     * ------------------------------------------------------------------
     * MAX_C_STRING_LENGTH is a JAVA-PRIVATE safety bound applied when
     * reading a NUL-terminated C string returned by the native
     * library. The value (1 MiB) is chosen to be:
     *
     *   - far larger than any legitimate return value from the
     *     LingoFuse ABI (APP names, API names, option values, P2P
     *     names are all short strings);
     *   - small enough that a runaway read cannot exhaust the JVM
     *     heap or scan into unmapped memory.
     *
     * The bound is used ONLY by the Java-side reader. It does NOT
     * truncate the underlying wire payload: if a C-side producer ever
     * sent a string longer than 1 MiB, the wire would still carry the
     * full bytes, and any OTHER language binding that does not apply
     * this bound would read the full string.
     *
     * In practice the LingoFuse ABI guarantees NUL termination for
     * every string returned through these functions, so the bound is
     * defensive only.
     * ==================================================================
     */
    private static final long MAX_C_STRING_LENGTH = 1024L * 1024L;

    private static volatile BiConsumer<String, Throwable> callbackErrorHandler;
    private static volatile boolean stderrFallbackEnabled = true;

    public static void setCallbackErrorHandler(
            BiConsumer<String, Throwable> handler) {
        callbackErrorHandler = handler;
    }

    /**
     *
     * <p>This switch is a JAVA-PRIVATE logging policy. It does NOT
     * affect the LingoFuse callback contract, does NOT change the
     * threading model of any callback, and does NOT change what the
     * native library does with a swallowed exception. Disabling the
     * stderr sink simply means the Java wrapper does not call
     * {@code System.err.println} and {@code Throwable.printStackTrace}.
     * The native library's own behaviour is unchanged.
     * Enables or disables the default stderr sink for swallowed
     * callback exceptions. The sink is enabled by default; disable it
     * when a custom error handler is installed and stderr duplication
     * is undesirable.
     */
    public static void setCallbackErrorStderrFallback(boolean enabled) {
        stderrFallbackEnabled = enabled;
    }

    public static void reportCallbackError(String source, Throwable t) {
        BiConsumer<String, Throwable> handler = callbackErrorHandler;
        if (handler != null) {
            try {
                handler.accept(source, t);
            } catch (Throwable ignored) {
            }
        }
        if (stderrFallbackEnabled) {
            try {
                System.err.println(
                        "[LingoFuse] Callback error in " + source + ": " + t);
                t.printStackTrace(System.err);
            } catch (Throwable ignored) {
            }
        }
    }

    // ==================================================================
    // Network preparation
    // ==================================================================

    public static void resetPrepare() {
        NativeCall.callVoid(NativeMethods.LF_ResetPrepare);
    }

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

    public static int prepareClient(String physicsAddr, AppHandle app) {
        Objects.requireNonNull(physicsAddr, "physicsAddr must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment addrSeg = arena.allocateFrom(physicsAddr);
            if (app == null) {
                return NativeCall.callInt(
                        NativeMethods.LF_PrepareClient,
                        addrSeg, MemorySegment.NULL);
            }
            return app.withHandle(h -> NativeCall.callInt(
                    NativeMethods.LF_PrepareClient, addrSeg, h));
        }
    }

    public static int prepareDone() {
        return NativeCall.callInt(NativeMethods.LF_PrepareDone);
    }

    public static void exitMainThread() {
        NativeCall.callVoid(NativeMethods.LF_ExitMainThread);
    }

    // ==================================================================
    // Runtime options
    // ==================================================================

    public static void setOption(String option, String value) {
        Objects.requireNonNull(option, "option must not be null");
        Objects.requireNonNull(value, "value must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment optSeg = arena.allocateFrom(option);
            MemorySegment valSeg = arena.allocateFrom(value);
            NativeCall.callVoid(NativeMethods.LF_SetOption, optSeg, valSeg);
        }
    }

    public static String getOption(String option) {
        Objects.requireNonNull(option, "option must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment optSeg = arena.allocateFrom(option);
            MemorySegment ptr = NativeCall.callSeg(
                    NativeMethods.LF_GetOption, optSeg);
            if (isNull(ptr)) {
                return "";
            }
            return ptr.reinterpret(MAX_C_STRING_LENGTH).getString(0);
        }
    }

    // ==================================================================
    // Application name generation and query
    // ==================================================================

    public static String generateAppName() {
        MemorySegment ptr = NativeCall.callSeg(
                NativeMethods.LF_Generate_AppName);
        if (isNull(ptr)) {
            return "";
        }
        return ptr.reinterpret(MAX_C_STRING_LENGTH).getString(0);
    }

    public static String getAppName(AppHandle app) {
        Objects.requireNonNull(app, "app must not be null");

        return app.withHandle(h -> {
            MemorySegment ptr = NativeCall.callSeg(
                    NativeMethods.LF_Get_AppName, h);
            if (isNull(ptr)) {
                return "";
            }
            return ptr.reinterpret(MAX_C_STRING_LENGTH).getString(0);
        });
    }

    // ==================================================================
    // Remote invocation by App name
    // ==================================================================

    public static DataHandle call(
            String appName, DataHandle param, long timeoutMs) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_Call,
                    nameSeg, param.raw(), timeoutMs);
            if (isNull(raw)) {
                throw new LingoFuseException(
                        "LF_Call returned a null handle for app '"
                                + appName + "'.");
            }
            return DataHandle.fromRaw(raw, true);
        }
    }

    public static DataHandle tryCall(
            String appName, DataHandle param, long timeoutMs) {
        DataHandle response = call(appName, param, timeoutMs);
        if (response.size() == 0) {
            response.close();
            return null;
        }
        return response;
    }

    public static void notify(String appName, DataHandle param) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            NativeCall.callVoid(
                    NativeMethods.LF_Notify, nameSeg, param.raw());
        }
    }

    public static void sequencedNotify(String appName, DataHandle param) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSeg = arena.allocateFrom(appName);
            NativeCall.callVoid(
                    NativeMethods.LF_Sequenced_Notify,
                    nameSeg, param.raw());
        }
    }

    // ==================================================================
    // Remote invocation by UID
    // ==================================================================

    public static DataHandle uidCall(
            byte[] uid, DataHandle param, long timeoutMs) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            try {
                MemorySegment raw = NativeCall.callSeg(
                        NativeMethods.LF_UID_Call,
                        uidSeg, param.raw(), timeoutMs);
                if (isNull(raw)) {
                    throw new LingoFuseException(
                            "LF_UID_Call returned a null handle for uid="
                                    + hex(uid) + ".");
                }
                return DataHandle.fromRaw(raw, true);
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

    public static DataHandle tryUidCall(
            byte[] uid, DataHandle param, long timeoutMs) {
        DataHandle response = uidCall(uid, param, timeoutMs);
        if (response.size() == 0) {
            response.close();
            return null;
        }
        return response;
    }

    public static void uidNotify(byte[] uid, DataHandle param) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            try {
                NativeCall.callVoid(
                        NativeMethods.LF_UID_Notify, uidSeg, param.raw());
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

    public static void uidSequencedNotify(byte[] uid, DataHandle param) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            try {
                NativeCall.callVoid(
                        NativeMethods.LF_UID_Sequenced_Notify,
                        uidSeg, param.raw());
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

    // ==================================================================
    // Remote invocation by P2P name
    // ==================================================================

    public static DataHandle p2pCall(
            String group, DataHandle param, long timeoutMs) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_P2PNAME_Call,
                    groupSeg, param.raw(), timeoutMs);
            if (isNull(raw)) {
                throw new LingoFuseException(
                        "LF_P2PNAME_Call returned a null handle for group='"
                                + group + "'.");
            }
            return DataHandle.fromRaw(raw, true);
        }
    }

    public static DataHandle tryP2pCall(
            String group, DataHandle param, long timeoutMs) {
        DataHandle response = p2pCall(group, param, timeoutMs);
        if (response.size() == 0) {
            response.close();
            return null;
        }
        return response;
    }

    public static void p2pNotify(String group, DataHandle param) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            NativeCall.callVoid(
                    NativeMethods.LF_P2PNAME_Notify,
                    groupSeg, param.raw());
        }
    }

    public static void p2pSequencedNotify(String group, DataHandle param) {
        Objects.requireNonNull(group, "group must not be null");
        Objects.requireNonNull(param, "param must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(group);
            NativeCall.callVoid(
                    NativeMethods.LF_P2PNAME_Sequenced_Notify,
                    groupSeg, param.raw());
        }
    }

    // ==================================================================
    // Asynchronous invocation - App name
    // ==================================================================

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
                    nameSeg, param.raw(), MemorySegment.NULL, op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

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
                    nameSeg, param.raw(), MemorySegment.NULL, op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

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
                    nameSeg, param.raw(), MemorySegment.NULL, op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

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
                    nameSeg, param.raw(), MemorySegment.NULL, op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

    // ==================================================================
    // Asynchronous invocation - UID
    // ==================================================================

    public static boolean asyncUidCall(
            byte[] uid, DataHandle param, AsyncResultHandler handler) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncUidCall[" + hex(uid) + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            try {
                int ret = NativeCall.callInt(
                        NativeMethods.LF_UID_Async_Call,
                        uidSeg, param.raw(), MemorySegment.NULL, op.stub());
                if (ret != 1) {
                    op.markNotQueued();
                    return false;
                }
                return true;
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

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
            try {
                int ret = NativeCall.callInt(
                        NativeMethods.LF_UID_Async_Call,
                        uidSeg, param.raw(), MemorySegment.NULL, op.stub());
                if (ret != 1) {
                    op.markNotQueued();
                    return false;
                }
                return true;
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

    public static boolean asyncUidSequencedCall(
            byte[] uid, DataHandle param, AsyncResultHandler handler) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncUidSequencedCall[" + hex(uid) + "]", handler, h -> h);

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            try {
                int ret = NativeCall.callInt(
                        NativeMethods.LF_UID_Async_Sequenced_Call,
                        uidSeg, param.raw(), MemorySegment.NULL, op.stub());
                if (ret != 1) {
                    op.markNotQueued();
                    return false;
                }
                return true;
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

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
            try {
                int ret = NativeCall.callInt(
                        NativeMethods.LF_UID_Async_Sequenced_Call,
                        uidSeg, param.raw(), MemorySegment.NULL, op.stub());
                if (ret != 1) {
                    op.markNotQueued();
                    return false;
                }
                return true;
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

    // ==================================================================
    // Asynchronous invocation - P2P name
    // ==================================================================

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
                    groupSeg, param.raw(), MemorySegment.NULL, op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

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
                    groupSeg, param.raw(), MemorySegment.NULL, op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

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
                    groupSeg, param.raw(), MemorySegment.NULL, op.stub());
            if (ret != 1) {
                op.markNotQueued();
                return false;
            }
            return true;
        }
    }

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
                    groupSeg, param.raw(), MemorySegment.NULL, op.stub());
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

    public static void shutdown() {
        NativeCall.callVoid(NativeMethods.LF_Shutdown);
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    private static boolean isNull(MemorySegment seg) {
        return seg == null || seg.address() == 0L;
    }

    private static void checkUidLength(byte[] uid, String argName) {
        Objects.requireNonNull(uid, argName + " must not be null");
        if (uid.length != NativeTypes.UID_BYTES) {
            throw new IllegalArgumentException(
                    argName + " must be exactly " + NativeTypes.UID_BYTES
                            + " bytes, got " + uid.length);
        }
    }

    private static MemorySegment allocateUid(Arena arena, byte[] uid) {
        MemorySegment seg = arena.allocate(NativeTypes.UID_BYTES);
        MemorySegment.copy(uid, 0, seg, ValueLayout.JAVA_BYTE, 0,
                (int) NativeTypes.UID_BYTES);
        return seg;
    }

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