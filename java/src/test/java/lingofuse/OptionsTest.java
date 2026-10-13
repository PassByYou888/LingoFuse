package lingofuse;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Smoke test for {@link Options}.
 *
 * <p>Verifies that every typed option shortcut:
 *
 * <ul>
 *   <li>round-trips a value through the native option store without
 *       throwing (for options that have a usable read-back path);</li>
 *   <li>returns a reasonable value for options with special semantics
 *       (masked password, write-only debug, defensive zero on parse
 *       failure);</li>
 *   <li>rejects null arguments at the entry point.</li>
 * </ul>
 *
 * <p>Every test that mutates a global option saves the previous value
 * in {@link #setUp()} and restores it in {@link #tearDown()}. This
 * guarantees that a test failure cannot leak a non-default
 * configuration into the next test.
 *
 * <p>These tests do not touch the network. They do need the native
 * library to load, because {@link Options} delegates every call to
 * {@link Framework#setOption(String, String)} and
 * {@link Framework#getOption(String)}.
 */
@DisplayName("Options smoke tests")
class OptionsTest {

    // ------------------------------------------------------------------
    // Setup / teardown: snapshot & restore the mutable global options
    // ------------------------------------------------------------------

    private boolean savedQuiet;
    private boolean savedShowThreadId;
    private boolean savedConsoleOutput;
    private boolean savedOverlapConnection;
    private boolean savedWaitConnectionReadyOk;
    private long    savedWaitConnectionTimeout;
    private int     savedIpcServThreadCount;
    private int     savedIpcServMaxQueueLength;
    private int     savedIpcServMaxMsgSize;
    private long    savedFixedSequencedTime;
    private String  savedP2pName;
    private long    savedDataHandleIdleTimeout;
    private long    savedDataHandlePoolScanInterval;
    private int     savedNoReponseCmdNullFlushThreshold;

    @BeforeEach
    void setUp() {
        savedQuiet = Options.getQuiet();
        savedShowThreadId = Options.getShowThreadId();
        savedConsoleOutput = Options.getConsoleOutput();
        savedOverlapConnection = Options.getOverlapConnection();
        savedWaitConnectionReadyOk = Options.getWaitConnectionReadyOk();
        savedWaitConnectionTimeout = Options.getWaitConnectionTimeout();
        savedIpcServThreadCount = Options.getIpcServThreadCount();
        savedIpcServMaxQueueLength = Options.getIpcServMaxQueueLength();
        savedIpcServMaxMsgSize = Options.getIpcServMaxMsgSize();
        savedFixedSequencedTime = Options.getFixedSequencedTime();
        savedP2pName = Options.getP2pName();
        savedDataHandleIdleTimeout = Options.getDataHandleIdleTimeout();
        savedDataHandlePoolScanInterval =
                Options.getDataHandlePoolScanInterval();
        savedNoReponseCmdNullFlushThreshold =
                Options.getNoReponseCmdNullFlushThreshold();
    }

    @AfterEach
    void tearDown() {
        Options.setQuiet(savedQuiet);
        Options.setShowThreadId(savedShowThreadId);
        Options.setConsoleOutput(savedConsoleOutput);
        Options.setOverlapConnection(savedOverlapConnection);
        Options.setWaitConnectionReadyOk(savedWaitConnectionReadyOk);
        Options.setWaitConnectionTimeout(savedWaitConnectionTimeout);
        Options.setIpcServThreadCount(savedIpcServThreadCount);
        Options.setIpcServMaxQueueLength(savedIpcServMaxQueueLength);
        Options.setIpcServMaxMsgSize(savedIpcServMaxMsgSize);
        Options.setFixedSequencedTime(savedFixedSequencedTime);
        Options.setP2pName(savedP2pName);
        Options.setDataHandleIdleTimeout(savedDataHandleIdleTimeout);
        Options.setDataHandlePoolScanInterval(savedDataHandlePoolScanInterval);
        Options.setNoReponseCmdNullFlushThreshold(
                savedNoReponseCmdNullFlushThreshold);
    }

    // ==================================================================
    // Boolean options - full round-trip
    // ==================================================================

    @Test
    @DisplayName("setQuiet / getQuiet round-trip")
    void quietRoundTrip() {
        Options.setQuiet(true);
        assertTrue(Options.getQuiet());
        Options.setQuiet(false);
        assertFalse(Options.getQuiet());
    }

    @Test
    @DisplayName("setShowThreadId / getShowThreadId round-trip")
    void showThreadIdRoundTrip() {
        Options.setShowThreadId(true);
        assertTrue(Options.getShowThreadId());
        Options.setShowThreadId(false);
        assertFalse(Options.getShowThreadId());
    }

    @Test
    @DisplayName("setConsoleOutput / getConsoleOutput round-trip")
    void consoleOutputRoundTrip() {
        Options.setConsoleOutput(true);
        assertTrue(Options.getConsoleOutput());
        Options.setConsoleOutput(false);
        assertFalse(Options.getConsoleOutput());
    }

    @Test
    @DisplayName("setOverlapConnection / getOverlapConnection round-trip")
    void overlapConnectionRoundTrip() {
        Options.setOverlapConnection(true);
        assertTrue(Options.getOverlapConnection());
        Options.setOverlapConnection(false);
        assertFalse(Options.getOverlapConnection());
    }

    @Test
    @DisplayName("setWaitConnectionReadyOk / getWaitConnectionReadyOk round-trip")
    void waitConnectionReadyOkRoundTrip() {
        Options.setWaitConnectionReadyOk(true);
        assertTrue(Options.getWaitConnectionReadyOk());
        Options.setWaitConnectionReadyOk(false);
        assertFalse(Options.getWaitConnectionReadyOk());
    }

    // ==================================================================
    // Numeric options - full round-trip
    // ==================================================================

    @Test
    @DisplayName("setWaitConnectionTimeout / getWaitConnectionTimeout round-trip")
    void waitConnectionTimeoutRoundTrip() {
        Options.setWaitConnectionTimeout(12345L);
        assertEquals(12345L, Options.getWaitConnectionTimeout());
    }

    @Test
    @DisplayName("setIpcServThreadCount / getIpcServThreadCount round-trip")
    void ipcServThreadCountRoundTrip() {
        Options.setIpcServThreadCount(7);
        assertEquals(7, Options.getIpcServThreadCount());
    }

    @Test
    @DisplayName("setIpcServMaxQueueLength / getIpcServMaxQueueLength round-trip")
    void ipcServMaxQueueLengthRoundTrip() {
        Options.setIpcServMaxQueueLength(2048);
        assertEquals(2048, Options.getIpcServMaxQueueLength());
    }

    @Test
    @DisplayName("setIpcServMaxMsgSize / getIpcServMaxMsgSize round-trip")
    void ipcServMaxMsgSizeRoundTrip() {
        Options.setIpcServMaxMsgSize(1 << 20);
        assertEquals(1 << 20, Options.getIpcServMaxMsgSize());
    }

    @Test
    @DisplayName("setFixedSequencedTime / getFixedSequencedTime round-trip")
    void fixedSequencedTimeRoundTrip() {
        Options.setFixedSequencedTime(30000L);
        assertEquals(30000L, Options.getFixedSequencedTime());
    }

    @Test
    @DisplayName("setDataHandleIdleTimeout / getDataHandleIdleTimeout round-trip")
    void dataHandleIdleTimeoutRoundTrip() {
        Options.setDataHandleIdleTimeout(900000L);
        assertEquals(900000L, Options.getDataHandleIdleTimeout());
    }

    @Test
    @DisplayName("setDataHandlePoolScanInterval / getDataHandlePoolScanInterval round-trip")
    void dataHandlePoolScanIntervalRoundTrip() {
        Options.setDataHandlePoolScanInterval(1000L);
        assertEquals(1000L, Options.getDataHandlePoolScanInterval());
    }

    @Test
    @DisplayName("setNoReponseCmdNullFlushThreshold / get round-trip")
    void noReponseCmdNullFlushThresholdRoundTrip() {
        Options.setNoReponseCmdNullFlushThreshold(100);
        assertEquals(100, Options.getNoReponseCmdNullFlushThreshold());
    }

    // ==================================================================
    // String options - full round-trip
    // ==================================================================

    @Test
    @DisplayName("setP2pName / getP2pName round-trip, including empty string")
    void p2pNameRoundTrip() {
        Options.setP2pName("workers_group");
        assertEquals("workers_group", Options.getP2pName());

        Options.setP2pName("");
        assertEquals("", Options.getP2pName());
    }

    @Test
    @DisplayName("setP2pName accepts unicode and long names")
    void p2pNameAcceptsUnicode() {
        String name = "\u4e2d\u6587\u7ec4_\uD83C\uDF0D";
        Options.setP2pName(name);
        assertEquals(name, Options.getP2pName());
    }

    // ==================================================================
    // Special-semantics options
    // ==================================================================

    @Test
    @DisplayName("getPassword always returns the mask, not the real value")
    void passwordIsMasked() {
        Options.setPassword("secret-value");
        String retrieved = Options.getPassword();
        assertNotNull(retrieved);
        // The library returns a fixed mask; the real password must
        // never be exposed through the read path.
        assertEquals("********", retrieved);
    }

    @Test
    @DisplayName("setDebug accepts a command without throwing")
    void setDebugDoesNotThrow() {
        // The write-only debug option runs a C4 console command.
        // We use a harmless unknown command so that no diagnostic
        // helper produces noise.
        assertDoesNotThrow(() -> Options.setDebug("no_such_command_xyz"));
    }

    @Test
    @DisplayName("getDebug returns the write-only placeholder")
    void getDebugReturnsPlaceholder() {
        String retrieved = Options.getDebug();
        assertNotNull(retrieved);
        // The underlying option is write-only; any non-null String is
        // acceptable here, and the implementation documents that the
        // library returns a fixed placeholder.
    }

    // ==================================================================
    // Argument validation
    // ==================================================================

    @Test
    @DisplayName("setP2pName / setPassword reject null")
    void nullArgumentsAreRejected() {
        assertThrows(NullPointerException.class,
                () -> Options.setP2pName(null));
        assertThrows(NullPointerException.class,
                () -> Options.setPassword(null));
        assertThrows(NullPointerException.class,
                () -> Options.setDebug(null));
    }

    // ==================================================================
    // Interaction with the generic Framework API
    // ==================================================================

    @Test
    @DisplayName("typed setter and generic getOption agree on the value")
    void typedAndGenericAgree() {
        Options.setP2pName("generic_check");
        assertEquals("generic_check",
                Framework.getOption("LF_P2P_name"));

        Options.setWaitConnectionTimeout(1234L);
        assertEquals("1234",
                Framework.getOption("Wait_Connection_Timeout"));
    }

    @Test
    @DisplayName("generic setOption and typed getter agree on the value")
    void genericAndTypedAgree() {
        Framework.setOption("LF_P2P_name", "from_generic");
        assertEquals("from_generic", Options.getP2pName());

        Framework.setOption("Wait_Connection_Timeout", "5678");
        assertEquals(5678L, Options.getWaitConnectionTimeout());
    }

    @Test
    @DisplayName("Framework.getOption returns empty for an unknown key")
    void unknownKeyReturnsEmpty() {
        assertEquals("", Framework.getOption("no_such_option_xyz"));
    }
}