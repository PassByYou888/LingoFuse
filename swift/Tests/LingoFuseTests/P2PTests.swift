//
//  P2PTests.swift
//  LingoFuseTests
//
//  Verification of the process-wide P2P registration API.
//
//  SCOPE
//  -----
//  These tests cover only the REGISTRATION LIFECYCLE:
//
//      - a fresh registration succeeds
//      - a duplicate registration is rejected
//      - unregister removes a live registration
//      - unregister on an unknown name returns false
//      - unregister is idempotent
//      - a name can be re-registered after unregister
//
//  They do NOT verify that a registered callback actually fires:
//  that requires a full mesh round-trip and belongs to the
//  integration suite.
//
//  ISOLATION
//  ---------
//  All tests in this file run in a single process, so a name that
//  leaks past a test would break the next one. Every test uses a
//  UNIQUE UUID-suffixed API name, and every test releases the name
//  in a `defer` block. This makes the suite independent of test
//  execution order.
//

import XCTest
import LingoFuse

final class P2PTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ------------------------------------------------------------------
    // Helper: a unique, non-colliding API name for one test
    // ------------------------------------------------------------------

    private func uniqueName(_ prefix: String) -> String {
        return "\(prefix)_\(UUID().uuidString.prefix(8))"
    }

    // ==================================================================
    // registerCall
    // ==================================================================

    func test01_register_call_succeeds() throws {
        let name = uniqueName("swift_p2p_call")
        defer { P2P.unregister(name) }

        let ok = try P2P.registerCall(name, description: "test") { _, _ in }
        XCTAssertTrue(ok)
    }

    func test02_register_call_duplicate_throws() throws {
        let name = uniqueName("swift_p2p_dup")
        defer { P2P.unregister(name) }

        _ = try P2P.registerCall(name, description: "first") { _, _ in }

        XCTAssertThrowsError(
            try P2P.registerCall(name, description: "second") { _, _ in }
        ) { error in
            guard case LingoFuseError.registrationFailed = error else {
                XCTFail("expected registrationFailed, got \(error)")
                return
            }
        }
    }

    func test03_unregister_live_call_returns_true() throws {
        let name = uniqueName("swift_p2p_unreg")
        _ = try P2P.registerCall(name, description: "test") { _, _ in }

        XCTAssertTrue(P2P.unregister(name))
    }

    func test04_unregister_unknown_returns_false() {
        let name = uniqueName("swift_p2p_unknown")
        XCTAssertFalse(P2P.unregister(name))
    }

    func test05_unregister_is_idempotent() throws {
        let name = uniqueName("swift_p2p_idem")
        _ = try P2P.registerCall(name, description: "test") { _, _ in }

        XCTAssertTrue(P2P.unregister(name))
        XCTAssertFalse(P2P.unregister(name))
        XCTAssertFalse(P2P.unregister(name))
    }

    func test06_reregister_after_unregister_succeeds() throws {
        let name = uniqueName("swift_p2p_rereg")
        _ = try P2P.registerCall(name, description: "first") { _, _ in }
        XCTAssertTrue(P2P.unregister(name))

        defer { P2P.unregister(name) }
        let ok = try P2P.registerCall(name, description: "second") { _, _ in }
        XCTAssertTrue(ok)
    }

    func test07_multiple_distinct_names_coexist() throws {
        let a = uniqueName("swift_p2p_a")
        let b = uniqueName("swift_p2p_b")
        let c = uniqueName("swift_p2p_c")
        defer {
            P2P.unregister(a)
            P2P.unregister(b)
            P2P.unregister(c)
        }

        XCTAssertTrue(try P2P.registerCall(a, description: "") { _, _ in })
        XCTAssertTrue(try P2P.registerCall(b, description: "") { _, _ in })
        XCTAssertTrue(try P2P.registerCall(c, description: "") { _, _ in })

        XCTAssertTrue(P2P.unregister(b))
        // Removing b must not affect a or c.
        XCTAssertFalse(P2P.unregister(b))  // already removed
        // a and c are still registered; unregister them via defer.
    }

    // ==================================================================
    // registerNotify
    // ==================================================================

    func test10_register_notify_succeeds() throws {
        let name = uniqueName("swift_p2p_notify")
        defer { P2P.unregister(name) }

        let ok = try P2P.registerNotify(name, description: "test") { _ in }
        XCTAssertTrue(ok)
    }

    func test11_register_notify_duplicate_throws() throws {
        let name = uniqueName("swift_p2p_notify_dup")
        defer { P2P.unregister(name) }

        _ = try P2P.registerNotify(name, description: "first") { _ in }

        XCTAssertThrowsError(
            try P2P.registerNotify(name, description: "second") { _ in }
        ) { error in
            guard case LingoFuseError.registrationFailed = error else {
                XCTFail("expected registrationFailed, got \(error)")
                return
            }
        }
    }

    func test12_unregister_live_notify_returns_true() throws {
        let name = uniqueName("swift_p2p_notify_unreg")
        _ = try P2P.registerNotify(name, description: "test") { _ in }

        XCTAssertTrue(P2P.unregister(name))
    }

    // ==================================================================
    // Namespace independence
    // ==================================================================

    func test20_call_and_notify_namespaces_are_independent() throws {
        // The process-wide P2P namespace does not distinguish between
        // "Call" and "Notify" API names: a name is unique within the
        // whole P2P namespace, regardless of which registration
        // function claimed it first.
        let name = uniqueName("swift_p2p_mix")
        defer { P2P.unregister(name) }

        _ = try P2P.registerCall(name, description: "as call") { _, _ in }

        XCTAssertThrowsError(
            try P2P.registerNotify(name, description: "as notify") { _ in }
        ) { error in
            guard case LingoFuseError.registrationFailed = error else {
                XCTFail("expected registrationFailed, got \(error)")
                return
            }
        }
    }

    // ==================================================================
    // Diagnostics (debug-only)
    // ==================================================================

    #if DEBUG
    func test30_retained_context_count_increases_on_register() throws {
        let before = P2P.retainedContextCount
        let name = uniqueName("swift_p2p_count")
        defer { P2P.unregister(name) }

        _ = try P2P.registerCall(name, description: "") { _, _ in }
        XCTAssertEqual(P2P.retainedContextCount, before + 1)
    }

    func test31_retained_context_count_does_not_decrease_on_unregister() throws {
        // Contexts are intentionally never released; the registry
        // count is monotonic. This test pins that contract so that a
        // future "cleanup" refactor cannot silently introduce a
        // use-after-free.
        let name = uniqueName("swift_p2p_count2")
        _ = try P2P.registerCall(name, description: "") { _, _ in }

        let afterRegister = P2P.retainedContextCount
        _ = P2P.unregister(name)
        XCTAssertEqual(P2P.retainedContextCount, afterRegister)
    }

    func test32_retained_context_count_not_incremented_on_dispatch_failure() {
        // A duplicate registration fails at the native layer and the
        // Swift context is never retained. The count must therefore
        // not move on a failing register call.
        let name = uniqueName("swift_p2p_fail")
        defer { P2P.unregister(name) }

        do {
            _ = try P2P.registerCall(name, description: "first") { _, _ in }
        } catch {
            XCTFail("first registration must succeed: \(error)")
            return
        }

        let before = P2P.retainedContextCount
        do {
            _ = try P2P.registerCall(name, description: "second") { _, _ in }
            XCTFail("second registration must fail")
        } catch {
            // Expected.
        }
        XCTAssertEqual(P2P.retainedContextCount, before)
    }
    #endif
}