package lingofuse.async;

import lingofuse.DataHandle;
import lingofuse.LfIo;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.lang.foreign.MemorySegment;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Unit tests for the asynchronous subsystem in
 * {@code lingofuse.async}.
 *
 * <p>These tests exercise PURE Java behaviour. They do NOT set up a
 * network and they do NOT call any {@code LF_Async_*} entry point.
 * Instead, they drive the state machine directly by invoking
 * {@link AsyncOp#invokeFromC(MemorySegment, Throwable)} the same way
 * the native upcall stub would. This isolates the subsystem's
 * lifetime management from the network, which is the whole point of
 * having a bridge in the first place.
 *
 * <h2>How to drive the state machine</h2>
 *
 * <p>{@link AsyncOp#invokeFromC(MemorySegment, Throwable)} mirrors
 * the C-side callback contract exactly:
 *
 * <ul>
 *   <li><b>Success</b>: the C side passes a valid, non-NULL
 *       {@code TDataHnd} pointer. The op deserializes it and delivers
 *       the resulting value.</li>
 *   <li><b>Failure</b>: the C side passes
 *       {@link MemorySegment#NULL}. The op skips deserialization and
 *       delivers {@code null} as the value plus a non-null error, or
 *       a {@code null} value plus a non-null error supplied by the
 *       caller.</li>
 * </ul>
 *
 * <p>Therefore a test that wants to verify "the deserializer's output
 * reaches the callback" MUST pass a real DataHandle's raw segment.
 * Passing {@link MemorySegment#NULL} is a legitimate way to simulate
 * a "no result" failure, but it will (correctly) bypass the
 * deserializer.
 *
 * <h2>Cursor position</h2>
 *
 * <p>{@link LfIo#writeJson} / {@link LfIo#writeStringBytes} advance
 * the handle's cursor to the end of the written payload.
 * {@link LfIo#readJson} / {@link LfIo#readStringBytes} read from the
 * current cursor. A test that writes and then reads back through the
 * same handle must therefore reset the cursor to 0 in between,
 * exactly like {@code DataHandleSmokeTest.jsonWireBytesMatchContract}
 * does.
 *
 * <h2>Coverage</h2>
 *
 * <ul>
 *   <li>{@link CallFuture}: the {@code abandoned} flag and its
 *       thread-safe read.</li>
 *   <li>{@link AsyncOp}: the PENDING -&gt; FIRED | ABANDONED |
 *       NOT_QUEUED state machine, including idempotence of every
 *       transition and the "late callback after timeout drops the
 *       result" rule.</li>
 *   <li>{@link AsyncBridge}: registration, release scheduling,
 *       timeout processing, and the diagnostic snapshot.</li>
 *   <li>{@link AsyncSupport}: factory behaviour, including delivery
 *       of results and errors to the caller's callback, and the
 *       {@link AsyncSupport#runAsyncWithFuture} one-stop helper.</li>
 * </ul>
 *
 * <h2>Isolation</h2>
 *
 * <p>{@link AsyncBridge#shutdownInstance()} is called before and after
 * every test method. This guarantees that no op from one test can
 * influence the counters or the queues observed by another.
 *
 * <h2>Timing</h2>
 *
 * <p>The default grace period (60 s) is far too slow for unit tests.
 * Every test that exercises the timeout path assigns a much smaller
 * value to {@link AsyncBridge#graceSeconds} directly on the singleton
 * instance, rather than mutating the global configuration. Waits use
 * generous upper bounds (10x the expected delay) so that a slow CI
 * machine does not produce flaky failures.
 */
@DisplayName("AsyncSupport unit tests")
class AsyncSupportTest {

    // ==================================================================
    // Setup / teardown: isolate the AsyncBridge singleton per test
    // ==================================================================

    @BeforeEach
    void setUp() {
        AsyncBridge.shutdownInstance();
    }

    @AfterEach
    void tearDown() {
        AsyncBridge.shutdownInstance();
    }

    // ==================================================================
    // CallFuture
    // ==================================================================

    @Test
    @DisplayName("a new CallFuture is not abandoned and not done")
    void callFutureInitialState() {
        CallFuture<String> future = new CallFuture<>();
        assertFalse(future.abandoned());
        assertFalse(future.isDone());
    }

    @Test
    @DisplayName("completing a CallFuture with a value makes it done but not abandoned")
    void callFutureCompleteSuccessfully() throws Exception {
        CallFuture<String> future = new CallFuture<>();
        future.complete("hello");

        assertTrue(future.isDone());
        assertFalse(future.abandoned());
        assertEquals("hello", future.get(1, TimeUnit.SECONDS));
    }

    @Test
    @DisplayName("completing a CallFuture exceptionally makes it done but not abandoned")
    void callFutureCompleteExceptionally() {
        CallFuture<String> future = new CallFuture<>();
        future.completeExceptionally(new RuntimeException("boom"));

        assertTrue(future.isDone());
        assertFalse(future.abandoned());
        assertThrows(ExecutionException.class,
                () -> future.get(1, TimeUnit.SECONDS));
    }

    // ==================================================================
    // AsyncOp state machine
    // ==================================================================

    @Test
    @DisplayName("a freshly created op is PENDING")
    void opInitialState() {
        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test", (r, e) -> { }, h -> h);
        assertEquals(AsyncOp.STATE_PENDING, op.state());
    }

    @Test
    @DisplayName("markNotQueued moves the op to NOT_QUEUED")
    void opMarkNotQueued() {
        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test", (r, e) -> { }, h -> h);

        op.markNotQueued();
        assertEquals(AsyncOp.STATE_NOT_QUEUED, op.state());
    }

    @Test
    @DisplayName("markNotQueued is idempotent")
    void opMarkNotQueuedIdempotent() {
        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test", (r, e) -> { }, h -> h);

        op.markNotQueued();
        op.markNotQueued();
        op.markNotQueued();
        assertEquals(AsyncOp.STATE_NOT_QUEUED, op.state());
    }

    @Test
    @DisplayName("invokeFromC with a valid handle delivers the value and moves to FIRED")
    void opInvokeSuccess() {
        StringBuilder received = new StringBuilder();

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test",
                (r, e) -> received.append(e == null ? "ok" : "err"),
                h -> h);

        try (DataHandle dummy = new DataHandle("test-dummy")) {
            op.invokeFromC(dummy.raw(), null);
        }

        assertEquals(AsyncOp.STATE_FIRED, op.state());
        assertEquals("ok", received.toString());
    }

    @Test
    @DisplayName("invokeFromC delivers a non-null error on failure")
    void opInvokeError() {
        Throwable[] captured = new Throwable[1];

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test",
                (r, e) -> captured[0] = e,
                h -> h);

        RuntimeException boom = new RuntimeException("boom");
        op.invokeFromC(MemorySegment.NULL, boom);

        assertEquals(AsyncOp.STATE_FIRED, op.state());
        assertEquals(boom, captured[0]);
    }

    @Test
    @DisplayName("invokeFromC after markNotQueued is a no-op")
    void opInvokeAfterNotQueuedIsNoop() {
        int[] callCount = {0};

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test",
                (r, e) -> callCount[0]++,
                h -> h);

        op.markNotQueued();
        op.invokeFromC(MemorySegment.NULL, null);

        assertEquals(AsyncOp.STATE_NOT_QUEUED, op.state());
        assertEquals(0, callCount[0]);
    }

    @Test
    @DisplayName("invokeFromC twice is idempotent")
    void opInvokeTwiceIdempotent() {
        int[] callCount = {0};

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test",
                (r, e) -> callCount[0]++,
                h -> h);

        op.invokeFromC(MemorySegment.NULL, null);
        op.invokeFromC(MemorySegment.NULL, null);

        assertEquals(AsyncOp.STATE_FIRED, op.state());
        assertEquals(1, callCount[0]);
    }

    @Test
    @DisplayName("invokeFromC delivers the deserialized value to a typed handler")
    void opInvokeTypedSuccess() {
        String[] received = new String[1];

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "test",
                (value, error) -> received[0] = value,
                h -> "typed-value");

        // The deserializer is only invoked when the C side passes a
        // non-NULL Result_. Pass a real (empty) handle to simulate a
        // successful delivery with a payload the deserializer can
        // fabricate from.
        try (DataHandle dummy = new DataHandle("test-dummy")) {
            op.invokeFromC(dummy.raw(), null);
        }

        assertEquals("typed-value", received[0]);
    }

    // ==================================================================
    // Factory: future style
    // ==================================================================

    @Test
    @DisplayName("makeFutureOp returns a live op + future pair")
    void makeFutureOpReturnsPair() {
        AsyncSupport.OpFuturePair<String> pair =
                AsyncSupport.makeFutureOp("test", h -> "x");

        assertNotNull(pair.op());
        assertNotNull(pair.future());
        assertEquals(AsyncOp.STATE_PENDING, pair.op().state());
        assertFalse(pair.future().isDone());
        assertFalse(pair.future().abandoned());
    }

    @Test
    @DisplayName("resolving the future via invokeFromC gives the value")
    void futureResolvesWithValue() throws Exception {
        AsyncSupport.OpFuturePair<String> pair =
                AsyncSupport.makeFutureOp("test", h -> "resolved");

        // Same reasoning as opInvokeTypedSuccess: pass a real handle
        // so that the deserializer is actually invoked.
        try (DataHandle dummy = new DataHandle("test-dummy")) {
            pair.op().invokeFromC(dummy.raw(), null);
        }

        assertEquals("resolved",
                pair.future().get(1, TimeUnit.SECONDS));
        assertEquals(AsyncOp.STATE_FIRED, pair.op().state());
    }

    @Test
    @DisplayName("an error delivered to the future surfaces as ExecutionException")
    void futureResolvesWithError() {
        AsyncSupport.OpFuturePair<String> pair =
                AsyncSupport.makeFutureOp("test", h -> "ignored");

        RuntimeException boom = new RuntimeException("boom");
        pair.op().invokeFromC(MemorySegment.NULL, boom);

        ExecutionException ex = assertThrows(
                ExecutionException.class,
                () -> pair.future().get(1, TimeUnit.SECONDS));
        assertEquals(boom, ex.getCause());
    }

    // ==================================================================
    // runAsyncWithFuture: dispatch failure
    // ==================================================================

    @Test
    @DisplayName("runAsyncWithFuture resolves the future when dispatch fails")
    void runAsyncDispatchFailure() {
        CallFuture<String> future = AsyncSupport.runAsyncWithFuture(
                "test-dispatch-fail",
                stub -> 0,
                h -> "x",
                1000);

        assertTrue(future.isDone(),
                "the future must be resolved immediately on dispatch "
                        + "failure");
        assertThrows(ExecutionException.class,
                () -> future.get(1, TimeUnit.SECONDS));
        assertFalse(future.abandoned());
    }

    @Test
    @DisplayName("runAsyncWithFuture releases the op on dispatch failure")
    void runAsyncDispatchFailureReleasesOp() {
        AsyncSupport.runAsyncWithFuture(
                "test-dispatch-fail-release",
                stub -> 0,
                h -> "x",
                1000);

        int maxIterations = 50;
        for (int i = 0; i < maxIterations; i++) {
            if (AsyncBridge.instance().liveOpCount() == 0) {
                return;
            }
            try {
                Thread.sleep(20);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        assertEquals(0, AsyncBridge.instance().liveOpCount(),
                "the op must have been released");
    }

    @Test
    @DisplayName("runAsyncWithFuture propagates an issueFn exception")
    void runAsyncIssueFnThrows() {
        assertThrows(RuntimeException.class, () ->
                AsyncSupport.runAsyncWithFuture(
                        "test-issue-throws",
                        stub -> { throw new RuntimeException("broke"); },
                        h -> "x",
                        1000));
    }

    // ==================================================================
    // runAsyncWithFuture: timeout
    // ==================================================================

    @Test
    @DisplayName("a positive timeout fires and abandons the future")
    void runAsyncTimeoutFires() {
        AsyncBridge bridge = AsyncBridge.instance();
        bridge.graceSeconds = 0.05;

        CallFuture<String> future = AsyncSupport.runAsyncWithFuture(
                "test-timeout",
                stub -> 1,
                h -> "x",
                50);

        assertThrows(ExecutionException.class,
                () -> future.get(2, TimeUnit.SECONDS));
        assertTrue(future.abandoned());
    }

    @Test
    @DisplayName("a zero timeout leaves the future pending")
    void runAsyncZeroTimeout() {
        CallFuture<String> future = AsyncSupport.runAsyncWithFuture(
                "test-no-timeout",
                stub -> 1,
                h -> "x",
                0);

        assertFalse(future.isDone());
        assertFalse(future.abandoned());
    }

    @Test
    @DisplayName("a late callback after a timeout is silently dropped")
    void runAsyncLateCallbackIsDropped() {
        AsyncBridge bridge = AsyncBridge.instance();
        bridge.graceSeconds = 0.1;

        AsyncSupport.OpFuturePair<String> pair =
                AsyncSupport.makeFutureOp("test-late", h -> "late");

        bridge.scheduleTimeout(pair.op(), 30);

        // Wait for the timeout to fire.
        try {
            pair.future().get(2, TimeUnit.SECONDS);
        } catch (ExecutionException expected) {
            // The future completes exceptionally on timeout.
        } catch (Exception unexpected) {
            throw new AssertionError(
                    "unexpected exception while awaiting timeout",
                    unexpected);
        }
        assertTrue(pair.future().abandoned());

        // Now simulate a late callback with a real handle. It must
        // not change the future's value, and it must not throw.
        try (DataHandle dummy = new DataHandle("test-late-dummy")) {
            assertDoesNotThrow(() ->
                    pair.op().invokeFromC(dummy.raw(), null));
        }

        assertEquals(AsyncOp.STATE_FIRED, pair.op().state());

        // The future still carries the timeout exception.
        ExecutionException ex = assertThrows(
                ExecutionException.class,
                () -> pair.future().get(1, TimeUnit.SECONDS));
        assertTrue(ex.getCause() instanceof
                lingofuse.errors.LingoFuseTimeoutException);
    }

    // ==================================================================
    // AsyncBridge diagnostics
    // ==================================================================

    @Test
    @DisplayName("stats() reports the current op counts")
    void bridgeStats() {
        AsyncBridge bridge = AsyncBridge.instance();

        AsyncSupport.makeFutureOp("test-a", h -> "a");
        AsyncSupport.makeFutureOp("test-b", h -> "b");
        AsyncSupport.makeFutureOp("test-c", h -> "c");

        Map<String, Object> snapshot = bridge.stats();
        assertEquals(3L, snapshot.get("total"));
        assertEquals(3L, snapshot.get("pending"));
        assertEquals(0L, snapshot.get("fired"));
        assertEquals(0L, snapshot.get("abandoned"));
        assertEquals(0L, snapshot.get("not_queued"));
    }

    @Test
    @DisplayName("stats() eventually stops counting a NOT_QUEUED op")
    void bridgeStatsNotQueued() {
        AsyncBridge bridge = AsyncBridge.instance();

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "test-nq", (r, e) -> { }, h -> h);
        op.markNotQueued();

        int maxIterations = 50;
        for (int i = 0; i < maxIterations; i++) {
            if (AsyncBridge.instance().liveOpCount() == 0) {
                break;
            }
            try {
                Thread.sleep(20);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                break;
            }
        }

        assertEquals(0, bridge.liveOpCount());
    }

    @Test
    @DisplayName("shutdownInstance() is idempotent")
    void shutdownInstanceIdempotent() {
        AsyncBridge.instance();
        assertDoesNotThrow(AsyncBridge::shutdownInstance);
        assertDoesNotThrow(AsyncBridge::shutdownInstance);
        assertDoesNotThrow(AsyncBridge::shutdownInstance);
    }

    @Test
    @DisplayName("instance() after shutdownInstance() returns a fresh bridge")
    void freshBridgeAfterShutdown() {
        AsyncBridge first = AsyncBridge.instance();
        AsyncSupport.makeFutureOp("test-fresh", h -> "x");
        assertEquals(1, first.liveOpCount());

        AsyncBridge.shutdownInstance();

        AsyncBridge second = AsyncBridge.instance();
        assertNotNull(second);
        assertEquals(0, second.liveOpCount(),
                "a fresh bridge must start with an empty registry");
    }

    // ==================================================================
    // Typed helpers
    // ==================================================================

    @Test
    @DisplayName("jsonDeserializer reads a JSON payload into the target type")
    void jsonDeserializerRoundTrip() {
        java.util.function.Function<DataHandle, String> deserializer =
                AsyncSupport.jsonDeserializer(String.class);

        try (DataHandle h = new DataHandle("test-json")) {
            LfIo.writeJson(h, "hello");
            // writeJson advances the cursor to the end; reset it so
            // that the reader starts at the beginning.
            h.setPosition(0);
            assertEquals("hello", deserializer.apply(h));
        }
    }

    @Test
    @DisplayName("bytesDeserializer copies the raw payload out")
    void bytesDeserializerRoundTrip() {
        java.util.function.Function<DataHandle, byte[]> deserializer =
                AsyncSupport.bytesDeserializer();

        try (DataHandle h = new DataHandle("test-bytes")) {
            LfIo.writeStringBytes(h, new byte[]{1, 2, 3});
            h.setPosition(0);
            byte[] result = deserializer.apply(h);
            assertEquals(3, result.length);
            assertEquals(1, result[0]);
            assertEquals(2, result[1]);
            assertEquals(3, result[2]);
        }
    }

    @Test
    @DisplayName("stringDeserializer reads a UTF-8 payload")
    void stringDeserializerRoundTrip() {
        java.util.function.Function<DataHandle, String> deserializer =
                AsyncSupport.stringDeserializer();

        try (DataHandle h = new DataHandle("test-string")) {
            LfIo.writeString(h, "hi \u4e16\u754c");
            h.setPosition(0);
            assertEquals("hi \u4e16\u754c", deserializer.apply(h));
        }
    }

    // ==================================================================
    // Handler argument validation
    // ==================================================================

    @Test
    @DisplayName("makeLegacyOp rejects null arguments")
    void makeLegacyOpRejectsNull() {
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.makeLegacyOp(null,
                        (r, e) -> { }, h -> h));
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.makeLegacyOp("a", null, h -> h));
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.makeLegacyOp("a", (r, e) -> { }, null));
    }

    @Test
    @DisplayName("makeTypedLegacyOp rejects null arguments")
    void makeTypedLegacyOpRejectsNull() {
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.makeTypedLegacyOp(null,
                        (v, e) -> { }, h -> "x"));
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.makeTypedLegacyOp("a", null, h -> "x"));
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.makeTypedLegacyOp("a", (v, e) -> { },
                        null));
    }

    @Test
    @DisplayName("runAsyncWithFuture rejects null arguments")
    void runAsyncWithFutureRejectsNull() {
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.runAsyncWithFuture(
                        null, stub -> 1, h -> "x", 100));
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.runAsyncWithFuture(
                        "a", null, h -> "x", 100));
        assertThrows(NullPointerException.class,
                () -> AsyncSupport.runAsyncWithFuture(
                        "a", stub -> 1, null, 100));
    }

    // ==================================================================
    // Typed legacy op: delivery of null value + non-null error
    // ==================================================================

    @Test
    @DisplayName("typed legacy op delivers null value + error on failure")
    void typedLegacyOpErrorPath() {
        Throwable[] captured = new Throwable[1];
        String[] value = { "sentinel" };

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "test",
                (v, e) -> { value[0] = v; captured[0] = e; },
                h -> "irrelevant");

        RuntimeException boom = new RuntimeException("boom");
        op.invokeFromC(MemorySegment.NULL, boom);

        assertNull(value[0]);
        assertEquals(boom, captured[0]);
    }

    // ==================================================================
    // A successful real payload reaches the callback
    // ==================================================================

    @Test
    @DisplayName("a real DataHandle payload is deserialized before delivery")
    void realPayloadReachesTypedCallback() throws Exception {
        java.util.concurrent.CompletableFuture<String> received =
                new java.util.concurrent.CompletableFuture<>();

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "test-real",
                (value, error) -> {
                    if (error != null) {
                        received.completeExceptionally(error);
                    } else {
                        received.complete(value);
                    }
                },
                AsyncSupport.jsonDeserializer(String.class));

        try (DataHandle h = new DataHandle("test-real-result")) {
            LfIo.writeJson(h, "hello from the wire");
            // Reset the cursor so that the deserializer reads from
            // the beginning of the payload.
            h.setPosition(0);
            op.invokeFromC(h.raw(), null);
        }

        assertEquals("hello from the wire",
                received.get(1, TimeUnit.SECONDS));
    }
}