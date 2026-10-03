package lingofuse;

import lingofuse.errors.LingoFuseObjectDisposedException;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Smoke test for {@link AppHandle}: registration, local execution, and
 * lifecycle.
 *
 * <p>These tests do not require the network. They exercise the
 * application object and its callback bridge through
 * {@code LF_LocalCall} and {@code LF_LocalNotify}, which run entirely
 * inside the current process.
 */
@DisplayName("AppHandle smoke tests")
class AppHandleSmokeTest {

    // ==================================================================
    // Lifecycle
    // ==================================================================

    @Test
    @DisplayName("new AppHandle is valid and carries its name")
    void newAppHandleIsValid() {
        try (AppHandle app = new AppHandle("TestApp", "description")) {
            assertTrue(app.isValid());
            assertEquals("TestApp", app.name());
            assertNotNull(app.raw());
        }
    }

    @Test
    @DisplayName("close() is idempotent and invalidates the handle")
    void closeIsIdempotent() {
        AppHandle app = new AppHandle("TestClose");
        app.close();
        app.close();

        assertFalse(app.isValid());
        assertThrows(LingoFuseObjectDisposedException.class,
                () -> app.registerCall("x", (in, out) -> {}));
        assertThrows(LingoFuseObjectDisposedException.class,
                () -> app.registerNotify("y", in -> {}));
        assertThrows(LingoFuseObjectDisposedException.class,
                () -> app.unregister("x"));
        assertThrows(LingoFuseObjectDisposedException.class, app::bind);
    }

    // ==================================================================
    // Registration
    // ==================================================================

    @Test
    @DisplayName("registerCall accepts and rejects as documented")
    void registerCallContract() {
        try (AppHandle app = new AppHandle("TestRegisterCall")) {
            assertTrue(app.registerCall("add", "add", (in, out) -> {}));
            assertFalse(app.registerCall("add", "add", (in, out) -> {}));
            assertFalse(app.registerCall("ADD", "add", (in, out) -> {}));
        }
    }

    @Test
    @DisplayName("registerNotify accepts and rejects as documented")
    void registerNotifyContract() {
        try (AppHandle app = new AppHandle("TestRegisterNotify")) {
            assertTrue(app.registerNotify("log", "log", in -> {}));
            assertFalse(app.registerNotify("log", "log", in -> {}));
            assertFalse(app.registerNotify("LOG", "log", in -> {}));
        }
    }

    @Test
    @DisplayName("unregister returns true for known API, false otherwise")
    void unregisterContract() {
        try (AppHandle app = new AppHandle("TestUnregister")) {
            app.registerCall("ping", (in, out) -> {});

            assertTrue(app.unregister("ping"));
            assertFalse(app.unregister("ping"));
            assertFalse(app.unregister("never_registered"));
        }
    }

    // ==================================================================
    // Local execution
    // ==================================================================

    @Test
    @DisplayName("local call round-trips an int32 payload")
    void localCallRoundTripsInt32() {
        try (AppHandle app = new AppHandle("TestLocalCall")) {
            app.registerCall("echo_int32", (in, out) ->
                    out.writeInt32(in.readInt32()));

            try (DataHandle request = new DataHandle("echo_int32")) {
                request.writeInt32(12345);

                try (DataHandle response = app.localCall(request)) {
                    assertTrue(response.isValid());
                    assertEquals(4L, response.size());
                    assertEquals(12345, response.readInt32());
                }
            }
        }
    }

    @Test
    @DisplayName("local call of an unregistered API returns an empty handle")
    void localCallUnknownApiReturnsEmpty() {
        try (AppHandle app = new AppHandle("TestUnknownApi")) {
            try (DataHandle request = new DataHandle("no_such_api")) {
                try (DataHandle response = app.localCall(request)) {
                    assertTrue(response.isValid());
                    assertEquals(0L, response.size());
                }
            }
        }
    }

    @Test
    @DisplayName("local notify invokes the registered handler")
    void localNotifyInvokesHandler() {
        AtomicInteger counter = new AtomicInteger(0);

        try (AppHandle app = new AppHandle("TestLocalNotify")) {
            app.registerNotify("ping", in -> counter.incrementAndGet());

            try (DataHandle request = new DataHandle("ping")) {
                request.writeString("hello");
                app.localNotify(request);
            }
        }
        assertEquals(1, counter.get());
    }

    // ==================================================================
    // Callback exception isolation
    // ==================================================================

    @Test
    @DisplayName("callback exception does not crash the process")
    void callbackExceptionIsIsolated() {
        try (AppHandle app = new AppHandle("TestExceptionIsolation")) {
            app.registerCall("boom", (in, out) -> {
                throw new RuntimeException("intentional");
            });

            try (DataHandle request = new DataHandle("boom")) {
                // The call must complete; the exception is swallowed
                // and reported, but does not propagate to the caller.
                try (DataHandle response = app.localCall(request)) {
                    assertNotNull(response);
                    assertEquals(0L, response.size());
                }
            }
        }
    }

    @Test
    @DisplayName("callback that closes a borrowed handle is harmless")
    void borrowedHandleCloseIsNoop() {
        // The borrowed input/output handles returned to a callback
        // have owned=false, so close() is a no-op. The callback body
        // remains usable after an accidental close().
        try (AppHandle app = new AppHandle("TestBorrowedClose")) {
            app.registerCall("accidental_close", (in, out) -> {
                // Accidentally close both handles.
                in.close();
                out.close();
                // Both handles must still be usable.
                assertTrue(in.isValid());
                assertTrue(out.isValid());
                out.writeInt32(in.readInt32() + 1);
            });

            try (DataHandle request = new DataHandle("accidental_close")) {
                request.writeInt32(41);
                try (DataHandle response = app.localCall(request)) {
                    assertEquals(42, response.readInt32());
                }
            }
        }
    }

    // ==================================================================
    // Argument validation
    // ==================================================================

    @Test
    @DisplayName("null arguments raise NullPointerException")
    void nullArgumentsRaiseNpe() {
        assertThrows(NullPointerException.class,
                () -> new AppHandle(null));
        assertThrows(NullPointerException.class,
                () -> new AppHandle(null, "desc"));

        try (AppHandle app = new AppHandle("TestNpe")) {
            assertThrows(NullPointerException.class,
                    () -> app.registerCall(null, (in, out) -> {}));
            assertThrows(NullPointerException.class,
                    () -> app.registerCall("x", (java.util.function.BiConsumer<
                            DataHandle, DataHandle>) null));
            assertThrows(NullPointerException.class,
                    () -> app.registerNotify(null, in -> {}));
            assertThrows(NullPointerException.class,
                    () -> app.registerNotify("x",
                            (java.util.function.Consumer<DataHandle>) null));
            assertThrows(NullPointerException.class,
                    () -> app.unregister(null));
            assertThrows(NullPointerException.class, () -> app.localCall(null));
            assertThrows(NullPointerException.class, () -> app.localNotify(null));
        }
    }

    @Test
    @DisplayName("null description is treated as empty")
    void nullDescriptionIsEmpty() {
        try (AppHandle app = new AppHandle("TestNullDesc", null)) {
            assertTrue(app.isValid());
            assertTrue(app.registerCall("ping", null, (in, out) -> {}));
        }
    }

    // ==================================================================
    // Callback lifetime
    // ==================================================================

    @Test
    @DisplayName("registered handlers keep working across many calls")
    void handlersSurviveManyCalls() {
        AtomicInteger counter = new AtomicInteger(0);

        try (AppHandle app = new AppHandle("TestManyCalls")) {
            app.registerCall("count", (in, out) ->
                    out.writeInt32(counter.incrementAndGet()));

            for (int i = 1; i <= 100; i++) {
                try (DataHandle request = new DataHandle("count");
                     DataHandle response = app.localCall(request)) {
                    assertEquals(i, response.readInt32());
                }
            }
        }
        assertEquals(100, counter.get());
    }
}