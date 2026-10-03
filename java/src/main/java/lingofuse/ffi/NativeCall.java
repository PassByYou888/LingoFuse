package lingofuse.ffi;

import lingofuse.errors.LingoFuseException;

import java.lang.foreign.MemorySegment;
import java.lang.invoke.MethodHandle;

/**
 * Invocation helpers for FFM {@link MethodHandle}s.
 *
 * <p>{@link MethodHandle#invokeExact} requires argument and return
 * types to match the descriptor exactly at every call site, which is
 * fragile in normal application code. This class uses
 * {@link MethodHandle#invokeWithArguments(Object...)} instead, which
 * performs the correct type adaptation automatically.
 *
 * <p>{@code invokeWithArguments} throws {@link Throwable}. The native
 * functions declared in {@link NativeMethods} never throw, so this
 * class only wraps {@code Throwable} into a {@link LingoFuseException}
 * to keep the calling code free of try/catch noise.
 */
public final class NativeCall {

    private NativeCall() {
        // Utility class; no instances.
    }

    /**
     * Invokes a downcall handle whose descriptor returns a pointer
     * ({@code ADDRESS}).
     *
     * @param handle the method handle to invoke
     * @param args   the arguments
     * @return the returned {@link MemorySegment}
     */
    public static MemorySegment callSeg(MethodHandle handle, Object... args) {
        try {
            return (MemorySegment) handle.invokeWithArguments(args);
        } catch (Throwable t) {
            throw new LingoFuseException("Native call failed: " + t.getMessage(), t);
        }
    }

    /**
     * Invokes a downcall handle whose descriptor returns a
     * {@code int64_t} or {@code uint64_t}.
     *
     * @param handle the method handle to invoke
     * @param args   the arguments
     * @return the returned {@code long}
     */
    public static long callLong(MethodHandle handle, Object... args) {
        try {
            return (Long) handle.invokeWithArguments(args);
        } catch (Throwable t) {
            throw new LingoFuseException("Native call failed: " + t.getMessage(), t);
        }
    }

    /**
     * Invokes a downcall handle whose descriptor returns a C
     * {@code int}.
     *
     * @param handle the method handle to invoke
     * @param args   the arguments
     * @return the returned {@code int}
     */
    public static int callInt(MethodHandle handle, Object... args) {
        try {
            return (Integer) handle.invokeWithArguments(args);
        } catch (Throwable t) {
            throw new LingoFuseException("Native call failed: " + t.getMessage(), t);
        }
    }

    /**
     * Invokes a downcall handle whose descriptor returns {@code void}.
     *
     * @param handle the method handle to invoke
     * @param args   the arguments
     */
    public static void callVoid(MethodHandle handle, Object... args) {
        try {
            handle.invokeWithArguments(args);
        } catch (Throwable t) {
            throw new LingoFuseException("Native call failed: " + t.getMessage(), t);
        }
    }
}