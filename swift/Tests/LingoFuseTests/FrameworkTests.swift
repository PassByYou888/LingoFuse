//
//  FrameworkTests.swift
//  LingoFuseTests
//
//  Step 2B verification: the process-wide Framework facade.
//
//  SECTIONS
//  --------
//  Tests 01-53 : original surface (options, health checks, network
//                preparation, shutdown, generateAppName, and the
//                App-name-addressed invocation family).
//  Tests 60-69 : v1.1 additions (Framework.getOption, and the
//                UID- / P2PName-addressed invocation family).
//

import XCTest
import LingoFuse

final class FrameworkTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // Options
    // ==================================================================

    func test01_set_option_accepts_known_key() {
        // Must not throw or crash.
        Framework.setOption("Quiet", "True")
        Framework.setOption("Quiet", "False")
    }

    func test02_reset_prepare_is_safe() {
        Framework.resetPrepare()
        Framework.resetPrepare()
    }

    // ==================================================================
    // Health checks
    // ==================================================================

    func test10_check_main_thread_returns_bool() {
        // Before prepareDone the main thread is not running. Must not
        // crash and must return a Bool.
        _ = Framework.checkMainThread()
    }

    func test11_check_app_absent_is_false() {
        XCTAssertFalse(Framework.checkApp("__definitely_absent__"))
    }

    func test12_check_api_absent_is_false() {
        XCTAssertFalse(Framework.checkApi("__absent__", "__also_absent__"))
    }

    // ==================================================================
    // Network preparation (surface)
    // ==================================================================

    func test20_prepare_service_returns_tag() throws {
        Framework.resetPrepare()
        let tag = try Framework.prepareService(
            listeningAddr: "ipc:swift_framework_test_svc",
            physicsAddr: "ipc:swift_framework_test_svc"
        )
        XCTAssertGreaterThanOrEqual(tag, 0)
        Framework.resetPrepare()
    }

    func test21_prepare_service_rejects_duplicate() throws {
        Framework.resetPrepare()
        _ = try Framework.prepareService(
            listeningAddr: "ipc:swift_framework_dup",
            physicsAddr: "ipc:swift_framework_dup"
        )
        XCTAssertThrowsError(try Framework.prepareService(
            listeningAddr: "ipc:swift_framework_dup",
            physicsAddr: "ipc:swift_framework_dup"
        ))
        Framework.resetPrepare()
    }

    func test22_prepare_client_returns_tag() throws {
        Framework.resetPrepare()
        let tag = try Framework.prepareClient(
            physicsAddr: "ipc:swift_framework_test_cli"
        )
        XCTAssertGreaterThanOrEqual(tag, 0)
        Framework.resetPrepare()
    }

    // ==================================================================
    // Shutdown
    // ==================================================================

    func test30_shutdown_is_idempotent() {
        // Shutdown on a fresh process must not throw or crash.
        Framework.shutdown()
        Framework.shutdown()
    }

    // ==================================================================
    // generateAppName
    // ==================================================================

    func test40_generate_app_name_returns_empty_before_prepare_done() {
        // The native contract: the returned pointer is valid for ~5
        // seconds; this wrapper copies it immediately. Before
        // prepareDone the name lacks tunnel info but the call must not
        // crash.
        let name = Framework.generateAppName()
        _ = name  // may be empty
    }

    // ==================================================================
    // Remote invocation surface (no live session)
    // ==================================================================

    func test50_call_to_absent_target_returns_empty_handle() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        let result = try Framework.call(
            "__absent_app_for_call_test__",
            param,
            timeoutMs: 200
        )
        defer { result.dispose() }
        // The native layer documents that LF_Call never returns nil;
        // on timeout it returns a size-0 handle.
        XCTAssertEqual(result.size, 0)
    }

    func test51_try_call_to_absent_target_returns_nil() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        let result = try Framework.tryCall(
            "__absent_app_for_try_call_test__",
            param,
            timeoutMs: 200
        )
        XCTAssertNil(result)
    }

    func test52_notify_does_not_throw() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }
        // Best-effort: must not crash even with an absent target.
        Framework.notify("__absent_app_for_notify_test__", param)
    }

    func test53_sequenced_notify_does_not_throw() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }
        Framework.sequencedNotify("__absent_app_for_seq_notify_test__", param)
    }

    // ==================================================================
    // 60+ v1.1 additions
    // ------------------------------------------------------------------
    // String-valued option reader and the UID- / P2PName-addressed
    // invocation family. All tests are non-network: they exercise the
    // C wrapper's null-guard and the deterministic C-level fallback
    // (size-0 handle for the sync Call, nil for tryCall).
    // ==================================================================

    // ---- Framework.getOption ----

    func test60_get_option_roundtrip_against_typed_api() {
        let original = Options.getQuiet()
        defer { Options.setQuiet(original) }

        Options.setQuiet(true)
        XCTAssertEqual(Framework.getOption("Quiet"), "True")

        Options.setQuiet(false)
        XCTAssertEqual(Framework.getOption("Quiet"), "False")
    }

    func test61_get_option_unknown_returns_empty() {
        XCTAssertEqual(Framework.getOption("__no_such_option__"), "")
    }

    func test62_get_option_is_case_insensitive() {
        let original = Options.getQuiet()
        defer { Options.setQuiet(original) }

        Options.setQuiet(true)
        // The native side matches option names case-insensitively.
        XCTAssertEqual(Framework.getOption("quiet"), "True")
        XCTAssertEqual(Framework.getOption("QUIET"), "True")
    }

    // ---- UID addressing ----

    func test63_call_by_uid_to_null_uid_returns_empty_handle() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        let result = try Framework.callByUid(
            .null,
            param,
            timeoutMs: 200
        )
        defer { result.dispose() }
        XCTAssertEqual(result.size, 0)
    }

    func test64_try_call_by_uid_to_null_uid_returns_nil() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        let result = try Framework.tryCallByUid(
            .null,
            param,
            timeoutMs: 200
        )
        XCTAssertNil(result)
    }

    func test65_notify_by_uid_does_not_throw() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        Framework.notifyByUid(.null, param)
    }

    func test66_sequenced_notify_by_uid_does_not_throw() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        Framework.sequencedNotifyByUid(.null, param)
    }

    // ---- P2PName addressing ----

    func test67_call_by_p2p_name_to_absent_group_returns_empty_handle() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        let result = try Framework.callByP2PName(
            "__absent_group__",
            param,
            timeoutMs: 200
        )
        defer { result.dispose() }
        XCTAssertEqual(result.size, 0)
    }

    func test68_try_call_by_p2p_name_to_absent_group_returns_nil() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        let result = try Framework.tryCallByP2PName(
            "__absent_group__",
            param,
            timeoutMs: 200
        )
        XCTAssertNil(result)
    }

    func test69_notify_and_sequenced_notify_by_p2p_name_do_not_throw() throws {
        let param = try DataHandle(apiName: "any_api")
        defer { param.dispose() }

        Framework.notifyByP2PName("__absent_group__", param)
        Framework.sequencedNotifyByP2PName("__absent_group__", param)
    }
}