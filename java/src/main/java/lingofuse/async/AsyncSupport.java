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
 * <p>Every factory creates an independent shared arena that owns the
 * upcall stub for the whole lifetime of the op. The arena is closed
 * by {@link AsyncBridge#releaseOp} (through
 * {@link AsyncOp#releaseResources()}) once the op leaves PENDING.
 */
public final class AsyncSupport {

    private AsyncSupport() {
    }

    private static final Linker LINKER = Linker.nativeLinker();

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

    public static <T> AsyncOp makeTypedLegacyOp(
            String apiName,
            TypedAsyncResultHandler<T> handler,
            Function<DataHandle, T> deserializer) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(handler, "handler must not be null");
        Objects.requireNonNull(deserializer, "deserializer must not be null");

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
            }
        };

        Function<DataHandle, Object> erased = deserializer::apply;
        AsyncOp op = createOp(apiName, erased, deliver, future);
        return new OpFuturePair<>(op, future);
    }

    @FunctionalInterface
    public interface IssueFunction {
        int issue(MemorySegment callbackStub);
    }

    public static <T> CallFuture<T> runAsyncWithFuture(
            String apiName,
            IssueFunction issueFn,
            Function<DataHandle, T> deserializer,
            long timeoutMs) {

        Objects.requireNonNull(apiName, "apiName must not be null");
        Objects.requireNonNull(issueFn, "issueFn must not be null");
        Objects.requireNonNull(deserializer, "deserializer must not be null");

        OpFuturePair<T> pair = makeFutureOp(apiName, deserializer);
        AsyncOp op = pair.op();
        CallFuture<T> future = pair.future();

        int ret;
        try {
            ret = issueFn.issue(op.stub());
        } catch (Throwable t) {
            op.markNotQueued();
            throw t;
        }

        if (ret != 1) {
            op.markNotQueued();
            if (!future.isDone()) {
                future.completeExceptionally(
                        new LingoFuseException(
                                "async request to '" + apiName
                                        + "' was not queued "
                                        + "(dispatch returned " + ret + ")"));
            }
            return future;
        }

        if (timeoutMs > 0) {
            op.ownerBridge().scheduleTimeout(op, timeoutMs);
        }

        return future;
    }

    private static AsyncOp createOp(
            String apiName,
            Function<DataHandle, Object> deserializer,
            AsyncOp.DeliverFn deliver,
            java.util.concurrent.CompletableFuture<?> future) {

        AsyncOp[] cell = new AsyncOp[1];
        /*
         * ==============================================================
         * CROSS-LANGUAGE COMPATIBILITY NOTE
         * --------------------------------------------------------------
         * This arena owns the FFM upcall stub that turns a Java lambda
         * into a C function pointer. It is a JAVA-PRIVATE resource.
         *
         * The lifetime rule this arena obeys is:
         *
         *   - the arena MUST outlive the C library's last possible
         *     invocation of the stub;
         *   - once the op has left PENDING (state FIRED or
         *     NOT_QUEUED), the C library will no longer invoke the
         *     stub, so the arena can be closed safely;
         *   - if the op is ABANDONED (timeout), the C library may
         *     still be about to invoke the stub, so the arena is
         *     intentionally left open until JVM exit.
         *
         * This rule is a Java-side consequence of the FFM API. It
         * does NOT change the LF_Async_Call wire behaviour, the
         * callback threading model, or the ownership rules of the
         * Result_ handle. Other bindings do not have an arena and do
         * not need one.
         *
         * DO NOT migrate this arena into the LingoFuse core library.
         * ==============================================================
         */
        Arena stubArena = Arena.ofShared();

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
            stubArena.close();
            throw new ExceptionInInitializerError(e);
        }

        MemorySegment stub = LINKER.upcallStub(
                bound,
                NativeTypes.LF_ASYNC_CALL_ON_RESULT,
                stubArena);

        AsyncBridge ownerBridge = AsyncBridge.instance();
        AsyncOp op = new AsyncOp(apiName, deserializer, deliver, future,
                stub, stubArena, ownerBridge);
        cell[0] = op;

        ownerBridge.register(op);
        return op;
    }

    static void dispatchViaCell(
            AsyncOp[] cell,
            MemorySegment data,
            MemorySegment result) {
        AsyncOp op = cell[0];
        if (op == null) {
            return;
        }
        op.invokeFromC(result, null);
    }

    public record OpFuturePair<T>(AsyncOp op, CallFuture<T> future) {
    }

    public static <T> Function<DataHandle, T> jsonDeserializer(
            Class<T> type) {
        Objects.requireNonNull(type, "type must not be null");
        return handle -> LfIo.readJson(handle, type);
    }

    public static Function<DataHandle, com.fasterxml.jackson.databind.JsonNode>
            jsonNodeDeserializer() {
        return LfIo::readJson;
    }

    public static Function<DataHandle, String> stringDeserializer() {
        return LfIo::readString;
    }

    public static Function<DataHandle, byte[]> bytesDeserializer() {
        return LfIo::readStringBytes;
    }
}