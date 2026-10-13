package lingofuse;

import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;
import lingofuse.ffi.NativeTypes;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * Status queue and health-check helpers for the LingoFuse runtime.
 *
 * <p>All {@code reinterpret(Long.MAX_VALUE)} occurrences have been
 * replaced by a bounded {@code MAX_C_STRING_LENGTH} to eliminate the
 * out-of-bounds-read hazard when the native side violates its
 * NUL-terminator contract. UID buffers are zeroed before the arena
 * that holds them is closed.
 */
public final class LingoFuseStatus {

    private static final long MAX_C_STRING_LENGTH = 1024L * 1024L;

    private LingoFuseStatus() {
    }

    public static int getStatusCount() {
        return NativeCall.callInt(NativeMethods.LF_GetStatusCount);
    }

    public static String getStatus() {
        MemorySegment ptr = NativeCall.callSeg(NativeMethods.LF_GetStatus);
        if (ptr == null || ptr.address() == 0L) {
            return "";
        }
        return ptr.reinterpret(MAX_C_STRING_LENGTH).getString(0);
    }

    public static List<String> drainStatus(int maxMessages) {
        if (maxMessages < 0) {
            throw new IllegalArgumentException(
                    "maxMessages must be non-negative: " + maxMessages);
        }
        if (maxMessages == 0) {
            return List.of();
        }

        int pending = getStatusCount();
        if (pending <= 0) {
            return List.of();
        }

        int count = Math.min(pending, maxMessages);
        List<String> messages = new ArrayList<>(count);

        for (int i = 0; i < count; i++) {
            String msg = getStatus();
            if (msg.isEmpty()) {
                break;
            }
            messages.add(msg);
        }
        return messages;
    }

    public static List<String> drainStatus() {
        return drainStatus(64);
    }

    public static void postStatus(String message) {
        Objects.requireNonNull(message, "message must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment seg = arena.allocateFrom(message);
            NativeCall.callVoid(NativeMethods.LF_PostStatus, seg);
        }
    }

    public static boolean checkMainThread() {
        return NativeCall.callInt(NativeMethods.LF_CheckMainThread) != 0;
    }

    public static boolean checkApp(String appName) {
        Objects.requireNonNull(appName, "appName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment seg = arena.allocateFrom(appName);
            return NativeCall.callInt(NativeMethods.LF_CheckApp, seg) != 0;
        }
    }

    public static boolean checkApi(String appName, String apiName) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment appSeg = arena.allocateFrom(appName);
            MemorySegment apiSeg = arena.allocateFrom(apiName);
            return NativeCall.callInt(
                    NativeMethods.LF_CheckApi, appSeg, apiSeg) != 0;
        }
    }

    public static boolean checkUid(byte[] uid) {
        checkUidLength(uid, "uid");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            try {
                return NativeCall.callInt(
                        NativeMethods.LF_Check_UID, uidSeg) != 0;
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

    public static boolean checkUidApi(byte[] uid, String apiName) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            try {
                MemorySegment apiSeg = arena.allocateFrom(apiName);
                return NativeCall.callInt(
                        NativeMethods.LF_Check_UID_Api,
                        uidSeg, apiSeg) != 0;
            } finally {
                uidSeg.fill((byte) 0);
            }
        }
    }

    public static boolean checkP2pName(String p2pName) {
        Objects.requireNonNull(p2pName, "p2pName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment seg = arena.allocateFrom(p2pName);
            return NativeCall.callInt(
                    NativeMethods.LF_Check_P2PNAME, seg) != 0;
        }
    }

    public static boolean checkP2pNameApi(String p2pName, String apiName) {
        Objects.requireNonNull(p2pName, "p2pName must not be null");
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(p2pName);
            MemorySegment apiSeg = arena.allocateFrom(apiName);
            return NativeCall.callInt(
                    NativeMethods.LF_Check_P2PNAME_Api,
                    groupSeg, apiSeg) != 0;
        }
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
}