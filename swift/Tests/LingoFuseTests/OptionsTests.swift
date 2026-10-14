//
//  OptionsTests.swift
//  LingoFuseTests
//
//  Verification of the typed runtime-option API in `Options.swift`
//  and of the string-valued escape hatch `Framework.getOption(_:)`.
//
//  GLOBAL STATE
//  ------------
//  Runtime options are process-global and take effect immediately.
//  Every test in this file that mutates an option restores the
//  original value at the end, so that subsequent tests (including
//  the integration suite, which may run in any order) start from a
//  known state.
//
//  The `password` option is a special case: it has no meaningful
//  getter (the native side returns a fixed mask), so the test
//  restores the well-known development token explicitly after
//  exercising the setter.
//
//  No network session is required. The only LingoFuse entry point
//  these tests touch is `LF_SetOption` / `LF_GetOption` through the
//  Swift wrappers.
//

import XCTest
import LingoFuse

final class OptionsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // Boolean round-trips
    // ==================================================================

    func test01_quiet_roundtrip() {
        let original = Options.getQuiet()
        defer { Options.setQuiet(original) }

        Options.setQuiet(true)
        XCTAssertTrue(Options.getQuiet())

        Options.setQuiet(false)
        XCTAssertFalse(Options.getQuiet())
    }

    func test02_show_thread_id_roundtrip() {
        let original = Options.getShowThreadID()
        defer { Options.setShowThreadID(original) }

        Options.setShowThreadID(false)
        XCTAssertFalse(Options.getShowThreadID())

        Options.setShowThreadID(true)
        XCTAssertTrue(Options.getShowThreadID())
    }

    func test03_console_output_roundtrip() {
        let original = Options.getConsoleOutput()
        defer { Options.setConsoleOutput(original) }

        Options.setConsoleOutput(false)
        XCTAssertFalse(Options.getConsoleOutput())

        Options.setConsoleOutput(true)
        XCTAssertTrue(Options.getConsoleOutput())
    }

    func test04_overlap_connection_roundtrip() {
        let original = Options.getOverlapConnection()
        defer { Options.setOverlapConnection(original) }

        Options.setOverlapConnection(true)
        XCTAssertTrue(Options.getOverlapConnection())

        Options.setOverlapConnection(false)
        XCTAssertFalse(Options.getOverlapConnection())
    }

    func test05_wait_connection_ready_ok_roundtrip() {
        let original = Options.getWaitConnectionReadyOk()
        defer { Options.setWaitConnectionReadyOk(original) }

        Options.setWaitConnectionReadyOk(false)
        XCTAssertFalse(Options.getWaitConnectionReadyOk())

        Options.setWaitConnectionReadyOk(true)
        XCTAssertTrue(Options.getWaitConnectionReadyOk())
    }

    // ==================================================================
    // Numeric round-trips
    // ==================================================================

    func test10_wait_connection_timeout_roundtrip() {
        let original = Options.getWaitConnectionTimeout()
        defer { Options.setWaitConnectionTimeout(original) }

        Options.setWaitConnectionTimeout(12_345)
        XCTAssertEqual(Options.getWaitConnectionTimeout(), 12_345)
    }

    func test11_fixed_sequenced_time_roundtrip() {
        let original = Options.getFixedSequencedTime()
        defer { Options.setFixedSequencedTime(original) }

        Options.setFixedSequencedTime(7_777)
        XCTAssertEqual(Options.getFixedSequencedTime(), 7_777)
    }

    func test12_data_handle_idle_timeout_roundtrip() {
        let original = Options.getDataHandleIdleTimeout()
        defer { Options.setDataHandleIdleTimeout(original) }

        Options.setDataHandleIdleTimeout(60_000)
        XCTAssertEqual(Options.getDataHandleIdleTimeout(), 60_000)
    }

    func test13_data_handle_pool_scan_interval_roundtrip() {
        let original = Options.getDataHandlePoolScanInterval()
        defer { Options.setDataHandlePoolScanInterval(original) }

        Options.setDataHandlePoolScanInterval(1_000)
        XCTAssertEqual(Options.getDataHandlePoolScanInterval(), 1_000)
    }

    func test14_ipc_serv_thread_count_roundtrip() {
        let original = Options.getIPCServThreadCount()
        defer { Options.setIPCServThreadCount(original) }

        Options.setIPCServThreadCount(4)
        XCTAssertEqual(Options.getIPCServThreadCount(), 4)
    }

    func test15_ipc_serv_max_queue_length_roundtrip() {
        let original = Options.getIPCServMaxQueueLength()
        defer { Options.setIPCServMaxQueueLength(original) }

        Options.setIPCServMaxQueueLength(5_000)
        XCTAssertEqual(Options.getIPCServMaxQueueLength(), 5_000)
    }

    func test16_ipc_serv_max_msg_size_roundtrip() {
        let original = Options.getIPCServMaxMsgSize()
        defer { Options.setIPCServMaxMsgSize(original) }

        Options.setIPCServMaxMsgSize(1_048_576)
        XCTAssertEqual(Options.getIPCServMaxMsgSize(), 1_048_576)
    }

    func test17_no_reponse_cmd_null_flush_threshold_roundtrip() {
        let original = Options.getNoReponseCmdNullFlushThreshold()
        defer { Options.setNoReponseCmdNullFlushThreshold(original) }

        Options.setNoReponseCmdNullFlushThreshold(500)
        XCTAssertEqual(Options.getNoReponseCmdNullFlushThreshold(), 500)
    }

    // ==================================================================
    // String round-trips
    // ==================================================================

    func test20_p2p_name_roundtrip() {
        let original = Options.getP2PName()
        defer { Options.setP2PName(original) }

        Options.setP2PName("swift_test_group")
        XCTAssertEqual(Options.getP2PName(), "swift_test_group")
    }

    func test21_p2p_name_empty_roundtrip() {
        let original = Options.getP2PName()
        defer { Options.setP2PName(original) }

        Options.setP2PName("")
        XCTAssertEqual(Options.getP2PName(), "")
    }

    // ==================================================================
    // Write-only options (setter does not crash; getter returns
    // whatever the native layer produces)
    // ==================================================================

    func test30_password_setter_does_not_crash() {
        // The password is a write-only option: its getter returns a
        // fixed mask on the native side. We exercise the setter and
        // then restore the well-known development token so that any
        // subsequent network test can still connect.
        Options.setPassword("swift_test_password")
        _ = Options.getPassword()          // mask, not the real value
        Options.setPassword("DTC40@ZSERVER")
    }

    func test31_debug_setter_does_not_crash() {
        // Debug is write-only; the setter executes a transient C4
        // console debug command. "Instance_Info" is a safe query.
        Options.setDebug("Instance_Info")
        _ = Options.getDebug()
    }

    // ==================================================================
    // Interop with the Framework escape hatch
    // ==================================================================

    func test40_framework_get_option_matches_typed_getter() {
        let original = Options.getQuiet()
        defer { Options.setQuiet(original) }

        Options.setQuiet(true)
        XCTAssertEqual(Framework.getOption("Quiet"), "True")

        Options.setQuiet(false)
        XCTAssertEqual(Framework.getOption("Quiet"), "False")
    }

    func test41_framework_get_option_unknown_returns_empty() {
        XCTAssertEqual(Framework.getOption("__no_such_option__"), "")
    }

    func test42_framework_set_option_is_visible_to_typed_getter() {
        let original = Options.getWaitConnectionReadyOk()
        defer { Options.setWaitConnectionReadyOk(original) }

        Framework.setOption("Wait_Connection_ReadyOk", "False")
        XCTAssertFalse(Options.getWaitConnectionReadyOk())
    }

    // ==================================================================
    // Numeric parsing tolerance (getters ignore trailing garbage
    // and fall back to zero on a malformed value)
    // ==================================================================

    func test50_get_u64_tolerates_trailing_garbage() {
        let original = Options.getWaitConnectionTimeout()
        defer { Options.setWaitConnectionTimeout(original) }

        Framework.setOption("Wait_Connection_Timeout", "5000abc")
        XCTAssertEqual(Options.getWaitConnectionTimeout(), 5000)
    }

    func test51_get_u64_malformed_returns_zero() {
        let original = Options.getWaitConnectionTimeout()
        defer { Options.setWaitConnectionTimeout(original) }

        Framework.setOption("Wait_Connection_Timeout", "not-a-number")
        XCTAssertEqual(Options.getWaitConnectionTimeout(), 0)
    }

    func test52_get_i32_tolerates_trailing_garbage() {
        let original = Options.getIPCServThreadCount()
        defer { Options.setIPCServThreadCount(original) }

        Framework.setOption("IPC_Serv_ThreadCount", "4abc")
        XCTAssertEqual(Options.getIPCServThreadCount(), 4)
    }

    // ==================================================================
    // Boolean strict encoding (getter recognises only "True")
    // ==================================================================

    func test60_get_bool_case_insensitive_true() {
        let original = Options.getQuiet()
        defer { Options.setQuiet(original) }

        Framework.setOption("Quiet", "TRUE")
        XCTAssertTrue(Options.getQuiet())

        Framework.setOption("Quiet", "true")
        XCTAssertTrue(Options.getQuiet())

        Framework.setOption("Quiet", "TrUe")
        XCTAssertTrue(Options.getQuiet())
    }

    func test61_get_bool_rejects_non_true_spellings() {
        let original = Options.getQuiet()
        defer { Options.setQuiet(original) }

        // The C side accepts these as valid booleans for its own
        // parser, but the typed Swift getter follows the C++ binding
        // convention and treats only "True" (case-insensitive) as
        // true. Everything else yields false.
        Framework.setOption("Quiet", "1")
        XCTAssertFalse(Options.getQuiet())

        Framework.setOption("Quiet", "Yes")
        XCTAssertFalse(Options.getQuiet())

        Framework.setOption("Quiet", "on")
        XCTAssertFalse(Options.getQuiet())
    }
}