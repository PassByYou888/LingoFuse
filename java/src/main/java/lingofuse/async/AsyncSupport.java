package lingofuse.async;

import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LfIo;
import lingofuse.errors.LingoFuseException;
import lingofuse.ffi.NativeTypes;

import java.lang.foreign.Arena;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.Objects;
import java.util.function.Function;

/**
 * Factory and utility methods for the asynchronous subsystem.
 *
 * <p>This class is the entry point that {@code Framework} and the
 * {@code Target} hierarchy use to build and issue async operations.
 * It hides all the mechanics of upcall stubs, arenas, and state
 * machines behind a small set of factory methods.
 *
 * <h2>Two families of factories</h2>
 *
 * <ul>
 *   <li><b>Legacy-style</b> ({@link #makeLegacyOp(String,
 *       AsyncResultHandler, Function)}) - the callback receives a
 *       {@link DataHandle} and is responsible for copying data out
 *       before returning.</li>
 *   <li><b>Typed legacy</b> ({@link #makeTypedLegacyOp(String,
 *       TypedAsyncResultHandler, Function)}) - the callback receives
 *       an already-deserialized value; the framework handles the
 *       handle lifetime internally.</li>
 * </ul>
 *
 * <p>The Future-based API is built on top of the same machinery via
 * {@link #runAsyncWithFuture(String, IssueFunction, Function, long)}.
 *
 * <h2>Threading</h2>
 *
 * <p>Every factory method is stateless and thread-safe. The upcall
 * stubs they create share a process-wide {@link Arena#ofShared()}
 * that is never closed: the stubs must remain valid until the JVM
 * exits, because the C library may invoke them at any time (including
 * after the caller thread has moved on).
 *
 * <p>A single op's stub lives until the op is released by
 * {@link AsyncBridge}. After release, the stub is no longer reachable
 * from the op, but the underlying memory remains valid (the arena is
 * still open), so a late C-side invocation of a released stub is a
 * safe no-op.
 *
 * <h2>Upcall stub signature</h2>
 *
 * <p>The native callback prototype is
 * {@code void (*)(void* Data, TDataHnd Result_)}. The Java binding
 * uses a one-element mutable cell to bridge the chicken-and-egg
 * problem between the op and its stub: the op needs the stub, and
 * the stub needs a reference to the op. The cell holds the op after
 * construction; the stub is bound to the cell via
 * {@link MethodHandles#insertArguments}.
 *
 * <p>The C-side {@code Data} argument is always ignored; Java uses
 * the bound cell as the user-data context instead.
 */
public final class AsyncSupport {

    private AsyncSupport() {
        // Utility class; no instances.
    }

    // ------------------------------------------------------------------
    // Static initialization
    // ------------------------------------------------------------------

    private static final Linker LINKER = Linker.nativeLinker();

    /**
     * The arena that owns every upcall stub created by this class.
     * Shared (not confined) because callbacks run on native worker
     * threads. Never closed.
     */
    private static final Arena STUB_ARENA = Arena.ofShared();

    // ------------------------------------------------------------------
    // Factory methods - legacy style
    // ------------------------------------------------------------------

    /**
     * Builds an op for the legacy callback style.
     *
     * <p>The callback receives the raw {@link DataHandle} from the
     * native layer. It is the caller's responsibility to copy data
     * out before the callback returns; see {@link AsyncResultHandler}
     * for the full lifetime contract.
     *
     * @param apiName      the remote API name; used for diagnostics
     * @param handler      the user callback; must not be null
     * @param deserializer the deserializer applied to the result; must
     *                     not be null
     * @return a new op, ready to be passed to one of the
     *         {@code LF_Async_*} entry points via its
     *         {@link AsyncOp#stub() stub}
     */
    public static AsyncOp makeLegacyOp(
            String apiName,
            AsyncResultHandler handler,
            Function<DataHandle, Object> deserializer) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(handler, "handler must not be null");
        Objects.requireNonNull(deserializer, "deserializer must not be null");

        AsyncOp.DeliverFn deliver = (value, error) -> {
            try {
                DataHandle borrowed = (value instanceof DataHandle dh)
                        ? dh
                        : null;
                handler.onResult(borrowed, error);
            } catch (Throwable t) {
                Framework.reportCallbackError(
                        "AsyncResultHandler[" + apiName + "]", t);
            }
        };

        return createOp(apiName, deserializer, deliver, null);
    }

    /**
     * Builds an op for the typed legacy callback style.
     *
     * <p>The framework deserializes the result before invoking the
     * handler, so the handler never sees a {@link DataHandle}.
     *
     * @param apiName      the remote API name
     * @param handler      the user callback; must not be null
     * @param deserializer the deserializer; must not be null
     * @param <T>          the deserialized value type
     * @return a new op
     */
    public static <T> AsyncOp makeTypedLegacyOp(
            String apiName,
            TypedAsyncResultHandler<T> handler,
            Function<DataHandle, T> deserializer) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(handler, "handler must not be null");
        Objects.requireNonNull(deserializer, "deserializer must not be null");

        // Wrap the typed deserializer so that the op's internal
        // Function<DataHandle, Object> contract is satisfied while
        // the outer value is still a T.
        Function<DataHandle, Object> erased = deserializer::apply;

        AsyncOp.DeliverFn deliver = (value, error) -> {
            @SuppressWarnings("unchecked")
            T typed = (T) value;
            try {
                handler.onResult(typed, error);
            } catch (Throwable t) {
                Framework.reportCallbackError(
                        "TypedAsyncResultHandler[" + apiName + "]", t);
            }
        };

        return createOp(apiName, erased, deliver, null);
    }

    // ------------------------------------------------------------------
    // Factory methods - future style
    // ------------------------------------------------------------------

    /**
     * Builds an op + {@link CallFuture} pair.
     *
     * <p>No timeout is armed here; call
     * {@link AsyncBridge#scheduleTimeout(AsyncOp, long)} after
     * successful dispatch, or use
     * {@link #runAsyncWithFuture(String, IssueFunction, Function, long)},
     * which does it automatically.
     *
     * @param apiName      the remote API name
     * @param deserializer the deserializer; must not be null
     * @param <T>          the deserialized value type
     * @return a pair of {@code (op, future)}
     */
    public static <T> OpFuturePair<T> makeFutureOp(
            String apiName,
            Function<DataHandle, T> deserializer) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(deserializer, "deserializer must not be null");

        CallFuture<T> future = new CallFuture<>();

        AsyncOp.DeliverFn deliver = (value, error) -> {
            if (future.isDone()) {
                return;
            }
            try {
                if (error != null) {
                    future.completeExceptionally(error);
                } else {
                    @SuppressWarnings("unchecked")
                    T typed = (T) value;
                    future.complete(typed);
                }
            } catch (Throwable ignored) {
                // Race with another completion path; the other party
                // wins.
            }
        };

        Function<DataHandle, Object> erased = deserializer::apply;
        AsyncOp op = createOp(apiName, erased, deliver, future);
        return new OpFuturePair<>(op, future);
    }

    // ------------------------------------------------------------------
    // One-stop helper
    // ------------------------------------------------------------------

    /**
     * Functional interface for issuing an async request.
     *
     * <p>The implementation receives the upcall stub that should be
     * passed to one of the {@code LF_Async_*} functions, and returns
     * 1 on successful dispatch, 0 on failure.
     */
    @FunctionalInterface
    public interface IssueFunction {
        int issue(MemorySegment callbackStub);
    }

    /**
     * One-stop helper: build op + future, issue the C request, arm
     * the timeout on success, and return the future.
     *
     * @param apiName      the remote API name; used for diagnostics
     * @param issueFn      the dispatch function; must not be null
     * @param deserializer the deserializer; must not be null
     * @param timeoutMs    the Python-side timeout in milliseconds;
     *                     values {@code <= 0} disable the timeout
     * @param <T>          the deserialized value type
     * @return the Future that will resolve with the result
     */
    public static <T> CallFuture<T> runAsyncWithFuture(
            String apiName,
            IssueFunction issueFn,
            Function<DataHandle, T> deserializer,
            long timeoutMs) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(issueFn, "issueFn must not be null");
        Objects.requireNonNull(deserializer,
                "deserializer must not be null");

        OpFuturePair<T> pair = makeFutureOp(apiName, deserializer);
        AsyncOp op = pair.op();
        CallFuture<T> future = pair.future();

        int ret;
        try {
            ret = issueFn.issue(op.stub());
        } catch (Throwable t) {
            // The C request was not issued. Release the op and
            // propagate the original exception.
            op.markNotQueued();
            throw t;
        }

        if (ret != 1) {
            // Dispatch failed; the callback will never fire.
            op.markNotQueued();
            if (!future.isDone()) {
                future.completeExceptionally(
                        new LingoFuseException(
                                "async request to '" + apiName
                                        + "' was not queued "
                                        + "(dispatch returned "
                                        + ret + ")"));
            }
            return future;
        }

        if (timeoutMs > 0) {
            AsyncBridge.instance().scheduleTimeout(op, timeoutMs);
        }

        return future;
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    private static AsyncOp createOp(
            String apiName,
            Function<DataHandle, Object> deserializer,
            AsyncOp.DeliverFn deliver,
            java.util.concurrent.CompletableFuture<?> future) {

        // The stub must be created before the op (the stub carries
        // the op reference as its bound first argument), but the
        // op's constructor requires the stub. We bridge the cycle
        // with a one-element mutable cell.
        AsyncOp[] cell = new AsyncOp[1];

        MethodHandle bound;
        try {
            MethodHandle cellBridge = MethodHandles.lookup().findStatic(
                    AsyncSupport.class,
                    "dispatchViaCell",
                    MethodType.methodType(
                            void.class,
                            AsyncOp[].class,
                            MemorySegment.class,
                            MemorySegment.class));
            bound = MethodHandles.insertArguments(
                    cellBridge, 0, (Object) cell);
        } catch (NoSuchMethodException | IllegalAccessException e) {
            throw new ExceptionInInitializerError(e);
        }

        MemorySegment stub = LINKER.upcallStub(
                bound,
                NativeTypes.LF_ASYNC_CALL_ON_RESULT,
                STUB_ARENA);

        AsyncOp op = new AsyncOp(apiName, deserializer, deliver, future, stub);
        cell[0] = op;

        AsyncBridge.instance().register(op);
        return op;
    }

    /**
     * Static bridge method invoked by the upcall stub. Delegates to
     * the op stored in the given cell.
     *
     * <p>Package-private visibility is not sufficient here because
     * the method is looked up by name via
     * {@link MethodHandles.Lookup#findStatic}, which requires the
     * method to be accessible from {@code AsyncSupport} itself.
     *
     * @param cell   the one-element cell holding the op
     * @param data   the C-side user_data argument (ignored)
     * @param result the raw result handle
     */
    static void dispatchViaCell(
            AsyncOp[] cell,
            MemorySegment data,
            MemorySegment result) {
        AsyncOp op = cell[0];
        if (op == null) {
            // Defensive: the stub was created but the op was never
            // assigned to the cell. Should not happen.
            return;
        }
        op.invokeFromC(result, null);
    }

    // ------------------------------------------------------------------
    // Pair holder
    // ------------------------------------------------------------------

    /**
     * A pair of {@link AsyncOp} and its associated {@link CallFuture}.
     *
     * @param op     the op
     * @param future the future
     * @param <T>    the deserialized value type
     */
    public record OpFuturePair<T>(AsyncOp op, CallFuture<T> future) {
    }

    // ------------------------------------------------------------------
    // Typed helpers for LfIo-based deserialization
    // ------------------------------------------------------------------

    /**
     * Returns a deserializer that reads a UTF-8 JSON payload into the
     * given type via {@link LfIo#readJson(DataHandle, Class)}.
     *
     * @param type the target type; must not be null
     * @param <T>  the target type parameter
     * @return a deserializer suitable for the factory methods above
     */
    public static <T> Function<DataHandle, T> jsonDeserializer(
            Class<T> type) {
        Objects.requireNonNull(type, "type must not be null");
        return handle -> LfIo.readJson(handle, type);
    }

    /**
     * Returns a deserializer that reads a UTF-8 JSON payload into a
     * Jackson {@code JsonNode}.
     *
     * @return a deserializer suitable for the factory methods above
     */
    public static Function<DataHandle, com.fasterxml.jackson.databind.JsonNode>
            jsonNodeDeserializer() {
        return LfIo::readJson;
    }

    /**
     * Returns a deserializer that reads a UTF-8 string payload.
     *
     * @return a deserializer suitable for the factory methods above
     */
    public static Function<DataHandle, String> stringDeserializer() {
        return LfIo::readString;
    }

    /**
     * Returns a deserializer that copies the raw bytes out of the
     * handle. The returned array is a fresh Java object, fully
     * detached from the native buffer.
     *
     * @return a deserializer suitable for the factory methods above
     */
    public static Function<DataHandle, byte[]> bytesDeserializer() {
        return LfIo::readStringBytes;
    }
}