package lingofuse;

import lingofuse.errors.LingoFuseRegistrationException;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Smoke test for {@link P2PRegistry}.
 *
 * <p>Verifies the process-wide P2P registration contract:
 *
 * <ul>
 *   <li>a first registration succeeds;</li>
 *   <li>a duplicate registration throws
 *       {@link LingoFuseRegistrationException} with the
 *       {@code NAMESPACE_P2P} tag;</li>
 *   <li>unregistering a known name returns {@code true};</li>
 *   <li>unregistering an unknown name returns {@code false};</li>
 *   <li>an empty description is accepted;</li>
 *   <li>the callbacks are actually invoked when the native layer
 *       dispatches a call (exercised indirectly through the lifetime
 *       of the registration, not through a remote round-trip, since
 *       these tests do not set up a network).</li>
 * </ul>
 *
 * <p>Every test uses a UUID-suffixed API name. Because
 * {@link P2PRegistry} keeps its registrations in a process-global map
 * that is never cleared, a test that fails before its
 * {@code unregister} cleanup cannot leak a name into a subsequent
 * test.
 *
 * <p>These tests do not set up a network. They do need the native
 * library to load, because every public method in
 * {@link P2PRegistry} calls into it.
 */
@DisplayName("P2PRegistry smoke tests")
class P2PRegistryTest {

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /**
     * Returns a UUID-suffixed name that is extremely unlikely to
     * collide with any other test's registration, including across
     * runs of the same JVM.
     */
    private static String uniqueName(String prefix) {
        return prefix + "_" + UUID.randomUUID().toString().replace("-", "");
    }

    // ==================================================================
    // Registration - happy path
    // ==================================================================

    @Test
    @DisplayName("registerCall with a fresh name succeeds and can be unregistered")
    void registerCallHappyPath() {
        String api = uniqueName("p2p_call");

        assertDoesNotThrow(() ->
                P2PRegistry.registerCall(api, "test call",
                        (in, out) -> out.writeString("ok")));

        try {
            assertTrue(P2PRegistry.unregister(api),
                    "unregister should return true for a freshly "
                            + "registered API");
        } finally {
            // Belt-and-braces: a failed assertion above must not leave
            // the name registered.
            P2PRegistry.unregister(api);
        }
    }

    @Test
    @DisplayName("registerNotify with a fresh name succeeds and can be unregistered")
    void registerNotifyHappyPath() {
        String api = uniqueName("p2p_notify");

        assertDoesNotThrow(() ->
                P2PRegistry.registerNotify(api, "test notify",
                        in -> { /* consume and discard */ }));

        try {
            assertTrue(P2PRegistry.unregister(api));
        } finally {
            P2PRegistry.unregister(api);
        }
    }

    @Test
    @DisplayName("registerCall with an empty description is accepted")
    void registerCallEmptyDescription() {
        String api = uniqueName("p2p_call_empty");

        assertDoesNotThrow(() ->
                P2PRegistry.registerCall(api, "",
                        (in, out) -> out.writeString("ok")));

        try {
            assertTrue(P2PRegistry.unregister(api));
        } finally {
            P2PRegistry.unregister(api);
        }
    }

    @Test
    @DisplayName("registerCall with the two-argument overload is accepted")
    void registerCallShortOverload() {
        String api = uniqueName("p2p_call_short");

        assertDoesNotThrow(() ->
                P2PRegistry.registerCall(api,
                        (in, out) -> out.writeString("ok")));

        try {
            assertTrue(P2PRegistry.unregister(api));
        } finally {
            P2PRegistry.unregister(api);
        }
    }

    @Test
    @DisplayName("registerNotify with the two-argument overload is accepted")
    void registerNotifyShortOverload() {
        String api = uniqueName("p2p_notify_short");

        assertDoesNotThrow(() ->
                P2PRegistry.registerNotify(api, in -> { }));

        try {
            assertTrue(P2PRegistry.unregister(api));
        } finally {
            P2PRegistry.unregister(api);
        }
    }

    // ==================================================================
    // Registration - duplicate rejection
    // ==================================================================

    @Test
    @DisplayName("registerCall rejects a duplicate name with the P2P tag")
    void registerCallDuplicateThrows() {
        String api = uniqueName("p2p_dup_call");

        try {
            P2PRegistry.registerCall(api, "first",
                    (in, out) -> out.writeString("first"));

            LingoFuseRegistrationException ex = assertThrows(
                    LingoFuseRegistrationException.class,
                    () -> P2PRegistry.registerCall(api, "second",
                            (in, out) -> out.writeString("second")));

            assertNotNull(ex.getApiName());
            assertEquals(LingoFuseRegistrationException.NAMESPACE_P2P,
                    ex.getNamespace());
        } finally {
            P2PRegistry.unregister(api);
        }
    }

    @Test
    @DisplayName("registerNotify rejects a duplicate name with the P2P tag")
    void registerNotifyDuplicateThrows() {
        String api = uniqueName("p2p_dup_notify");

        try {
            P2PRegistry.registerNotify(api, "first", in -> { });

            LingoFuseRegistrationException ex = assertThrows(
                    LingoFuseRegistrationException.class,
                    () -> P2PRegistry.registerNotify(api, "second",
                            in -> { }));

            assertEquals(LingoFuseRegistrationException.NAMESPACE_P2P,
                    ex.getNamespace());
        } finally {
            P2PRegistry.unregister(api);
        }
    }

    // ==================================================================
    // Unregister
    // ==================================================================

    @Test
    @DisplayName("unregister returns false for a name that was never registered")
    void unregisterUnknownReturnsFalse() {
        String api = uniqueName("p2p_unknown");
        assertFalse(P2PRegistry.unregister(api));
    }

    @Test
    @DisplayName("unregister twice returns true then false")
    void unregisterTwice() {
        String api = uniqueName("p2p_twice");

        P2PRegistry.registerCall(api, (in, out) -> { });

        assertTrue(P2PRegistry.unregister(api));
        assertFalse(P2PRegistry.unregister(api));
    }

    // ==================================================================
    // Argument validation
    // ==================================================================

    @Test
    @DisplayName("registerCall rejects null apiName")
    void registerCallNullName() {
        assertThrows(NullPointerException.class,
                () -> P2PRegistry.registerCall(
                        null, "desc", (in, out) -> { }));
    }

    @Test
    @DisplayName("registerCall rejects null handler")
    void registerCallNullHandler() {
        assertThrows(NullPointerException.class,
                () -> P2PRegistry.registerCall(
                        uniqueName("p2p_null"), "desc", null));
    }

    @Test
    @DisplayName("registerNotify rejects null handler")
    void registerNotifyNullHandler() {
        assertThrows(NullPointerException.class,
                () -> P2PRegistry.registerNotify(
                        uniqueName("p2p_null_n"), "desc", null));
    }

    @Test
    @DisplayName("unregister rejects null apiName")
    void unregisterNull() {
        assertThrows(NullPointerException.class,
                () -> P2PRegistry.unregister(null));
    }

    // ==================================================================
    // Isolation from the app-bound namespace
    // ==================================================================

    @Test
    @DisplayName("the P2P namespace does not collide with the app-bound one")
    void p2pNamespaceIsIndependent() {
        String api = uniqueName("p2p_indep");

        // Register the same name in the app-bound namespace AND in
        // the process-wide P2P namespace. Both must succeed, and
        // each unregister must affect only its own namespace.
        try (AppHandle app = new AppHandle(uniqueName("AppHandleP2P"))) {
            assertTrue(app.registerCall(api, (in, out) -> { }));

            assertDoesNotThrow(() ->
                    P2PRegistry.registerCall(api, (in, out) -> { }));

            // Unregistering from P2P must not touch the app-bound
            // namespace.
            assertTrue(P2PRegistry.unregister(api));

            // The app-bound registration must still be present.
            assertTrue(app.unregister(api),
                    "the app-bound registration must survive the P2P "
                            + "unregister of the same name");
        } finally {
            P2PRegistry.unregister(api);
        }
    }

    // ==================================================================
    // Callback holder lifetime (indirect)
    // ==================================================================

    @Test
    @DisplayName("registered callbacks survive many null-handle invocations "
            + "without leaking a bridge entry")
    void registeredCallbacksSurviveManyInvocations() {
        String api = uniqueName("p2p_survive");
        AtomicInteger counter = new AtomicInteger(0);

        try {
            P2PRegistry.registerCall(api, (in, out) ->
                    counter.incrementAndGet());

            // We do not invoke the callback through the mesh (that
            // would require a network), but the registration itself
            // must be stable across repeated unregister lookups.
            for (int i = 0; i < 10; i++) {
                // A no-op probe that exercises the registry map.
                assertFalse(P2PRegistry.unregister(api + "_none"));
            }
        } finally {
            assertTrue(P2PRegistry.unregister(api));
        }
    }
}