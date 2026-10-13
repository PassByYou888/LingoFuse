package lingofuse.address;

import lingofuse.AppHandle;
import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LfIo;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;
import lingofuse.Options;
import lingofuse.async.AsyncBridge;
import lingofuse.async.CallFuture;
import lingofuse.errors.LingoFuseTimeoutException;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * End-to-end tests for the three addressing targets.
 *
 * <h2>Scope</h2>
 *
 * <p>The {@link AppTarget} surface is exercised end to end across
 * every API style: synchronous, asynchronous callback, and
 * Future-based. This is possible without any external infrastructure
 * because App-name routing is LOCAL-FIRST: a call made in the same
 * process that hosts the matching App is serviced locally.
 *
 * <p>The {@link UIDTarget} and {@link P2PNameTarget} classes are
 * exercised at the structural level only: construction validation,
 * equality, {@code describe()}, and null-argument rejection. Their
 * network paths require a full mesh with a broadcast-discovered UID
 * or P2P group, which is a multi-second setup per test and would make
 * this class flaky without adding meaningful coverage over the App
 * path (all three targets share the same {@link Target} superclass).
 *
 * <h2>Lifecycle</h2>
 *
 * <p>The LingoFuse runtime is a process-global singleton. This class
 * performs a hard cleanup of any state left behind by a previously
 * executed test class, then builds a self-contained mesh in
 * {@link #classSetUp()}: one service, one client, and three APIs
 * ({@code echo}, {@code add}, {@code sink}). Everything is torn down
 * in {@link #classTearDown()}.
 */
@DisplayName("Address target end-to-end tests")
class TargetTest {

    // ------------------------------------------------------------------
    // Fixture
    // ------------------------------------------------------------------

    private static final String APP_NAME = "TargetTestApp";
    private static final String ENDPOINT = "ipc:target_test";

    /** A target whose {@code appName} does not exist anywhere on the mesh. */
    private static final String MISSING_APP = "NoSuchApp_xyz_99999";

    private static AppHandle server;
    private static boolean started;

    @BeforeAll
    static void classSetUp() throws InterruptedException {
        // Hard cleanup of any previous test class's global state.
        NetworkEvents.clear();
        try {
            Framework.exitMainThread();
        } catch (Throwable ignored) {
            // No previous runtime; nothing to clean.
        }
        try {
            Framework.shutdown();
        } catch (Throwable ignored) {
            // No previous runtime; nothing to clean.
        }
        AsyncBridge.shutdownInstance();

        Options.setWaitConnectionReadyOk(true);
        Options.setOverlapConnection(true);
        Options.setWaitConnectionTimeout(10_000L);
        Options.setQuiet(true);

        Framework.resetPrepare();

        server = new AppHandle(APP_NAME, "TargetTest server");
        requireRegistration("echo", server.registerCall(
                "echo", "echo a string",
                (in, out) -> LfIo.writeString(out, LfIo.readString(in))));
        requireRegistration("add", server.registerCall(
                "add", "add two int32s",
                (in, out) -> out.writeInt32(
                        in.readInt32() + in.readInt32())));
        requireRegistration("sink", server.registerNotify(
                "sink", "consume and discard",
                in -> { /* consume */ }));

        int serviceTag = Framework.prepareService(ENDPOINT, ENDPOINT);
        if (serviceTag == -1) {
            throw new IllegalStateException(
                    "prepareService returned -1 for " + ENDPOINT);
        }

        int clientTag = Framework.prepareClient(ENDPOINT, server);
        if (clientTag == -1) {
            throw new IllegalStateException(
                    "prepareClient returned -1 for " + ENDPOINT);
        }

        int done = Framework.prepareDone();
        if (done != 1 && !LingoFuseStatus.checkMainThread()) {
            throw new IllegalStateException(
                    "prepareDone returned " + done
                            + " and the main thread is not running");
        }
        started = true;

        // Wait for the App to become visible on the mesh. The
        // broadcast typically takes a few hundred milliseconds when
        // the peer is local; the 10-second budget is a safety net.
        for (int i = 0; i < 50; i++) {
            if (LingoFuseStatus.checkApi(APP_NAME, "echo")) {
                return;
            }
            Thread.sleep(200);
        }
        // Not fatal; the first test may simply retry internally.
    }

    @AfterAll
    static void classTearDown() {
        AsyncBridge.shutdownInstance();
        NetworkEvents.clear();

        if (started) {
            try {
                Framework.exitMainThread();
            } catch (Throwable ignored) {
                // Best-effort cleanup.
            }
        }
        if (server != null) {
            try {
                server.close();
            } catch (Throwable ignored) {
                // Best-effort cleanup.
            }
        }
        if (started) {
            try {
                Framework.shutdown();
            } catch (Throwable ignored) {
                // Best-effort cleanup.
            }
        }
        server = null;
        started = false;
    }

    private static void requireRegistration(String api, boolean ok) {
        if (!ok) {
            throw new IllegalStateException(
                    "Failed to register API '" + api + "'");
        }
    }

    // ==================================================================
    // Constructor and value semantics
    // ==================================================================

    @Test
    @DisplayName("AppTarget rejects null appName and negative timeout")
    void appTargetConstructorValidation() {
        assertThrows(NullPointerException.class,
                () -> new AppTarget(null));
        assertThrows(IllegalArgumentException.class,
                () -> new AppTarget("A", -1L));
    }

    @Test
    @DisplayName("AppTarget equality and hashCode are based on appName")
    void appTargetEquality() {
        AppTarget a = new AppTarget("MyApp");
        AppTarget b = new AppTarget("MyApp");
        AppTarget c = new AppTarget("Other");

        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
        assertNotEquals(a, c);
        assertNotEquals(a, new P2PNameTarget("MyApp"));
    }

    @Test
    @DisplayName("AppTarget describe() produces a readable label")
    void appTargetDescribe() {
        assertEquals("app(MyApp)", new AppTarget("MyApp").describe());
        assertEquals("AppTarget(MyApp)", new AppTarget("MyApp").toString());
    }

    @Test
    @DisplayName("UIDTarget accepts exactly 32 bytes and rejects other lengths")
    void uidTargetConstructorValidation() {
        assertThrows(NullPointerException.class,
                () -> new UIDTarget(null));
        assertThrows(IllegalArgumentException.class,
                () -> new UIDTarget(new byte[0]));
        assertThrows(IllegalArgumentException.class,
                () -> new UIDTarget(new byte[31]));
        assertThrows(IllegalArgumentException.class,
                () -> new UIDTarget(new byte[33]));
        assertThrows(IllegalArgumentException.class,
                () -> new UIDTarget(new byte[32], -1L));

        // The exact-length case must succeed.
        byte[] uid = new byte[32];
        UIDTarget target = new UIDTarget(uid);
        assertEquals("uid(" + hex(uid) + ")", target.describe());
    }

    @Test
    @DisplayName("UIDTarget makes a defensive copy of the UID")
    void uidTargetDefensiveCopy() {
        byte[] uid = new byte[32];
        uid[0] = 0x7F;

        UIDTarget target = new UIDTarget(uid);

        // Mutating the caller's array must not change the target.
        uid[0] = 0x00;
        byte[] retrieved = target.uidBytes();
        assertEquals(0x7F, retrieved[0]);

        // And mutating the returned array must not change the target.
        retrieved[0] = 0x00;
        assertEquals(0x7F, target.uidBytes()[0]);
    }

    @Test
    @DisplayName("UIDTarget equality is based on the UID bytes")
    void uidTargetEquality() {
        byte[] uid = new byte[32];
        uid[0] = 1;
        UIDTarget a = new UIDTarget(uid);
        UIDTarget b = new UIDTarget(uid);

        byte[] other = new byte[32];
        other[0] = 2;
        UIDTarget c = new UIDTarget(other);

        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
        assertNotEquals(a, c);
    }

    @Test
    @DisplayName("P2PNameTarget rejects null groupName and negative timeout")
    void p2pNameTargetConstructorValidation() {
        assertThrows(NullPointerException.class,
                () -> new P2PNameTarget(null));
        assertThrows(IllegalArgumentException.class,
                () -> new P2PNameTarget("group", -1L));
        assertEquals("p2pname(workers)",
                new P2PNameTarget("workers").describe());
    }

    @Test
    @DisplayName("P2PNameTarget equality is based on groupName")
    void p2pNameTargetEquality() {
        P2PNameTarget a = new P2PNameTarget("g");
        P2PNameTarget b = new P2PNameTarget("g");
        P2PNameTarget c = new P2PNameTarget("h");

        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
        assertNotEquals(a, c);
    }

    // ==================================================================
    // Synchronous API - call / callJson
    // ==================================================================

    @Test
    @DisplayName("call() returns the raw response handle")
    void syncCallReturnsRawHandle() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeString(req, "sync-hello");
            try (DataHandle resp = target.call(req)) {
                assertEquals("sync-hello", LfIo.readString(resp));
            }
        }
    }

    @Test
    @DisplayName("call(param, timeoutMs) honours the timeout parameter")
    void syncCallWithExplicitTimeout() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("add")) {
            req.writeInt32(3);
            req.writeInt32(4);
            try (DataHandle resp = target.call(req, 2_000L)) {
                assertEquals(7, resp.readInt32());
            }
        }
    }

    @Test
    @DisplayName("callJson() returns the deserialized value")
    void syncCallJsonReturnsTypedValue() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "typed-hello");
            String result = target.callJson(req, String.class);
            assertEquals("typed-hello", result);
        }
    }

    @Test
    @DisplayName("callJson() with an explicit timeout works")
    void syncCallJsonWithTimeout() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "typed-with-timeout");
            String result = target.callJson(req, String.class, 2_000L);
            assertEquals("typed-with-timeout", result);
        }
    }

    @Test
    @DisplayName("call() to a missing App throws LingoFuseTimeoutException")
    void syncCallTimeoutThrows() {
        AppTarget target = new AppTarget(MISSING_APP);
        try (DataHandle req = new DataHandle("echo")) {
            assertThrows(LingoFuseTimeoutException.class,
                    () -> target.call(req, 500L));
        }
    }

    @Test
    @DisplayName("call() rejects a null param")
    void syncCallRejectsNullParam() {
        AppTarget target = new AppTarget(APP_NAME);
        assertThrows(NullPointerException.class, () -> target.call(null));
        assertThrows(NullPointerException.class,
                () -> target.call(null, 1_000L));
    }

    @Test
    @DisplayName("callJson() rejects a null type")
    void syncCallJsonRejectsNullType() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "x");
            assertThrows(NullPointerException.class,
                    () -> target.callJson(req, null));
        }
    }

    // ==================================================================
    // Synchronous API - notify / sequencedNotify
    // ==================================================================

    @Test
    @DisplayName("notify() dispatches without throwing")
    void notifyDoesNotThrow() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("sink")) {
            LfIo.writeString(req, "one-way");
            assertDoesNotThrow(() -> target.notify(req));
        }
    }

    @Test
    @DisplayName("sequencedNotify() dispatches without throwing")
    void sequencedNotifyDoesNotThrow() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("sink")) {
            LfIo.writeString(req, "sequenced-one-way");
            assertDoesNotThrow(() -> target.sequencedNotify(req));
        }
    }

    @Test
    @DisplayName("notify() rejects a null param")
    void notifyRejectsNullParam() {
        AppTarget target = new AppTarget(APP_NAME);
        assertThrows(NullPointerException.class, () -> target.notify(null));
    }

    @Test
    @DisplayName("sequencedNotify() rejects a null param")
    void sequencedNotifyRejectsNullParam() {
        AppTarget target = new AppTarget(APP_NAME);
        assertThrows(NullPointerException.class,
                () -> target.sequencedNotify(null));
    }

    // ==================================================================
    // Asynchronous API - callback style (raw handle)
    // ==================================================================

    @Test
    @DisplayName("asyncCall() delivers the raw response to the callback")
    void asyncCallRawCallback() throws InterruptedException {
        AppTarget target = new AppTarget(APP_NAME);

        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> received = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();

        boolean dispatched;
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeString(req, "raw-async-hello");
            dispatched = target.asyncCall(req, (result, error) -> {
                try {
                    if (error != null) {
                        failure.set(error);
                    } else if (result != null) {
                        received.set(LfIo.readString(result));
                    }
                } finally {
                    latch.countDown();
                }
            });
        }

        assertTrue(dispatched, "dispatch should succeed");
        assertTrue(latch.await(5, TimeUnit.SECONDS),
                "callback must fire within 5 seconds");
        if (failure.get() != null) {
            throw new AssertionError(
                    "callback reported an error", failure.get());
        }
        assertEquals("raw-async-hello", received.get());
    }

    @Test
    @DisplayName("asyncCall() returns true on a successful dispatch")
    void asyncCallReturnsTrueOnDispatch() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeString(req, "x");
            boolean ok = target.asyncCall(req, (result, error) -> { });
            assertTrue(ok);
        }
    }

    // ==================================================================
    // Asynchronous API - callback style (typed)
    // ==================================================================

    @Test
    @DisplayName("asyncCallJson() delivers the deserialized value")
    void asyncCallJsonTypedCallback() throws InterruptedException {
        AppTarget target = new AppTarget(APP_NAME);

        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> received = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();

        boolean dispatched;
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "typed-async-hello");
            dispatched = target.asyncCallJson(req, String.class,
                    (value, error) -> {
                        try {
                            if (error != null) {
                                failure.set(error);
                            } else {
                                received.set(value);
                            }
                        } finally {
                            latch.countDown();
                        }
                    });
        }

        assertTrue(dispatched);
        assertTrue(latch.await(5, TimeUnit.SECONDS));
        if (failure.get() != null) {
            throw new AssertionError(
                    "callback reported an error", failure.get());
        }
        assertEquals("typed-async-hello", received.get());
    }

    // ==================================================================
    // Asynchronous API - sequenced variants
    // ==================================================================

    @Test
    @DisplayName("asyncSequencedCall() delivers the raw response")
    void asyncSequencedCallRawCallback() throws InterruptedException {
        AppTarget target = new AppTarget(APP_NAME);

        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> received = new AtomicReference<>();

        boolean dispatched;
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeString(req, "seq-async-hello");
            dispatched = target.asyncSequencedCall(req, (result, error) -> {
                try {
                    if (error == null && result != null) {
                        received.set(LfIo.readString(result));
                    }
                } finally {
                    latch.countDown();
                }
            });
        }

        assertTrue(dispatched);
        assertTrue(latch.await(5, TimeUnit.SECONDS));
        assertEquals("seq-async-hello", received.get());
    }

    @Test
    @DisplayName("asyncSequencedCallJson() delivers the typed value")
    void asyncSequencedCallJsonTypedCallback() throws InterruptedException {
        AppTarget target = new AppTarget(APP_NAME);

        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> received = new AtomicReference<>();

        boolean dispatched;
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "seq-typed-hello");
            dispatched = target.asyncSequencedCallJson(
                    req, String.class, (value, error) -> {
                        try {
                            if (error == null) {
                                received.set(value);
                            }
                        } finally {
                            latch.countDown();
                        }
                    });
        }

        assertTrue(dispatched);
        assertTrue(latch.await(5, TimeUnit.SECONDS));
        assertEquals("seq-typed-hello", received.get());
    }

    // ==================================================================
    // Asynchronous API - Future style
    // ==================================================================

    @Test
    @DisplayName("callFuture() resolves with the typed value")
    void callFutureResolvesWithValue() throws Exception {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "future-hello");
            CallFuture<String> future =
                    target.callFuture(req, String.class, 5_000L);
            assertEquals("future-hello",
                    future.get(5, TimeUnit.SECONDS));
            assertFalse(future.abandoned(),
                    "a successful call must not be abandoned");
        }
    }

    @Test
    @DisplayName("callFuture() with the default timeout overload resolves")
    void callFutureDefaultTimeout() throws Exception {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "future-default");
            CallFuture<String> future = target.callFuture(req, String.class);
            assertEquals("future-default",
                    future.get(5, TimeUnit.SECONDS));
        }
    }

    @Test
    @DisplayName("sequencedCallFuture() resolves with the typed value")
    void sequencedCallFutureResolvesWithValue() throws Exception {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "seq-future-hello");
            CallFuture<String> future =
                    target.sequencedCallFuture(req, String.class, 5_000L);
            assertEquals("seq-future-hello",
                    future.get(5, TimeUnit.SECONDS));
        }
    }

    @Test
    @DisplayName("callFuture() rejects a null type")
    void callFutureRejectsNullType() {
        AppTarget target = new AppTarget(APP_NAME);
        try (DataHandle req = new DataHandle("echo")) {
            LfIo.writeJson(req, "x");
            assertThrows(NullPointerException.class,
                    () -> target.callFuture(req, null));
        }
    }

    // ==================================================================
    // Helper
    // ==================================================================

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0x0F, 16));
            sb.append(Character.forDigit(b & 0x0F, 16));
        }
        return sb.toString();
    }
}