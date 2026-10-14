//
//  TargetTests.swift
//  LingoFuseTests
//
//  Verification of the addressing abstraction (`Target.swift`).
//
//  SCOPE
//  -----
//  These tests cover the SYNCHRONOUS surface shared by the three
//  concrete target types:
//
//      - construction and `description`
//      - `call` / `tryCall` against an absent target
//      - `notify` / `sequencedNotify` do not throw
//      - `defaultTimeoutMs` handling
//
//  No live mesh is required: when the target cannot be reached, the
//  C ABI returns a size-0 handle (never nil), and `tryCall` converts
//  that into `nil`. The same behaviour is already exercised by
//  `FrameworkTests.test50` / `test51`.
//
//  The async surface (`callAsync` / `sequencedCallAsync`) lives in
//  `AsyncSupportTests.swift`.
//

import XCTest
import LingoFuse

final class TargetTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ------------------------------------------------------------------
    // Helper: build an empty payload for the given API name
    // ------------------------------------------------------------------

    private func makeParam(_ apiName: String) throws -> DataHandle {
        return try DataHandle(apiName: apiName)
    }

    // ==================================================================
    // Construction and description
    // ==================================================================

    func test01_app_target_description() {
        let t = AppTarget("Calculator")
        XCTAssertEqual(t.appName, "Calculator")
        XCTAssertEqual(t.description, "app(Calculator)")
    }

    func test02_uid_target_description() throws {
        let bytes = [UInt8](repeating: 0, count: 32)
        var b = bytes
        b[0]  = 0x01; b[1]  = 0x23; b[2]  = 0x45; b[3]  = 0x67
        b[28] = 0x89; b[29] = 0xAB; b[30] = 0xCD; b[31] = 0xEF
        let uid = try Uid(bytes: b)
        let t = UidTarget(uid)
        XCTAssertEqual(t.description, "uid(01234567..89abcdef)")
    }

    func test03_uid_target_null_description() {
        let t = UidTarget(.null)
        XCTAssertEqual(t.description, "uid(00000000..00000000)")
    }

    func test04_p2pname_target_description() {
        let t = P2PNameTarget("worker_group")
        XCTAssertEqual(t.groupName, "worker_group")
        XCTAssertEqual(t.description, "p2p(worker_group)")
    }

    // ==================================================================
    // Default timeout
    // ==================================================================

    func test10_default_timeout_is_5000() {
        XCTAssertEqual(AppTarget("X").defaultTimeoutMs, 5000)
        XCTAssertEqual(UidTarget(.null).defaultTimeoutMs, 5000)
        XCTAssertEqual(P2PNameTarget("X").defaultTimeoutMs, 5000)
    }

    func test11_custom_default_timeout() {
        XCTAssertEqual(AppTarget("X", defaultTimeoutMs: 1234).defaultTimeoutMs, 1234)
        XCTAssertEqual(UidTarget(.null, defaultTimeoutMs: 1234).defaultTimeoutMs, 1234)
        XCTAssertEqual(P2PNameTarget("X", defaultTimeoutMs: 1234).defaultTimeoutMs, 1234)
    }

    // ==================================================================
    // Call against an absent target
    // ==================================================================
    //
    // In all three cases, the target does not exist on any mesh. The
    // C ABI returns a size-0 handle (never nil) after the timeout
    // expires. Tests use a short timeout (200 ms) to keep the suite
    // fast.

    func test20_app_call_to_absent_returns_empty_handle() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = AppTarget("__absent_target_app__")
        let response = try t.call("any_api", param, timeoutMs: 200)
        defer { response.dispose() }
        XCTAssertEqual(response.size, 0)
    }

    func test21_app_try_call_to_absent_returns_nil() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = AppTarget("__absent_target_app__")
        let response = try t.tryCall("any_api", param, timeoutMs: 200)
        XCTAssertNil(response)
    }

    func test22_uid_call_to_null_uid_returns_empty_handle() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = UidTarget(.null)
        let response = try t.call("any_api", param, timeoutMs: 200)
        defer { response.dispose() }
        XCTAssertEqual(response.size, 0)
    }

    func test23_uid_try_call_to_null_uid_returns_nil() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = UidTarget(.null)
        XCTAssertNil(try t.tryCall("any_api", param, timeoutMs: 200))
    }

    func test24_p2pname_call_to_absent_group_returns_empty_handle() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = P2PNameTarget("__absent_group__")
        let response = try t.call("any_api", param, timeoutMs: 200)
        defer { response.dispose() }
        XCTAssertEqual(response.size, 0)
    }

    func test25_p2pname_try_call_to_absent_group_returns_nil() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = P2PNameTarget("__absent_group__")
        XCTAssertNil(try t.tryCall("any_api", param, timeoutMs: 200))
    }

    // ==================================================================
    // Notify: must not throw even when the target is absent
    // ==================================================================

    func test30_app_notify_does_not_throw() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        AppTarget("__absent_app__").notify("any_api", param)
    }

    func test31_app_sequenced_notify_does_not_throw() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        AppTarget("__absent_app__").sequencedNotify("any_api", param)
    }

    func test32_uid_notify_does_not_throw() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        UidTarget(.null).notify("any_api", param)
    }

    func test33_uid_sequenced_notify_does_not_throw() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        UidTarget(.null).sequencedNotify("any_api", param)
    }

    func test34_p2pname_notify_does_not_throw() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        P2PNameTarget("__absent_group__").notify("any_api", param)
    }

    func test35_p2pname_sequenced_notify_does_not_throw() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        P2PNameTarget("__absent_group__").sequencedNotify("any_api", param)
    }

    // ==================================================================
    // Value semantics of the concrete targets
    // ==================================================================

    func test40_app_target_value_equality() {
        XCTAssertEqual(AppTarget("X"), AppTarget("X"))
        XCTAssertNotEqual(AppTarget("X"), AppTarget("Y"))
    }

    func test41_uid_target_value_equality() throws {
        let a = try Uid(bytes: [UInt8](repeating: 1, count: 32))
        let b = try Uid(bytes: [UInt8](repeating: 1, count: 32))
        let c = try Uid(bytes: [UInt8](repeating: 2, count: 32))

        XCTAssertEqual(UidTarget(a), UidTarget(b))
        XCTAssertNotEqual(UidTarget(a), UidTarget(c))
    }

    func test42_p2pname_target_value_equality() {
        XCTAssertEqual(P2PNameTarget("G"), P2PNameTarget("G"))
        XCTAssertNotEqual(P2PNameTarget("G"), P2PNameTarget("H"))
    }

    // ==================================================================
    // Protocol conformance
    // ==================================================================
    //
    // Compile-time: every concrete target must conform to `Target`.
    // The test body only needs to call a generic function that
    // requires the protocol.

    private func acceptsAnyTarget<T: Target>(_ t: T) -> String {
        return t.description
    }

    func test50_all_targets_conform_to_protocol() {
        XCTAssertEqual(acceptsAnyTarget(AppTarget("A")), "app(A)")
        XCTAssertEqual(acceptsAnyTarget(UidTarget(.null)), "uid(00000000..00000000)")
        XCTAssertEqual(acceptsAnyTarget(P2PNameTarget("G")), "p2p(G)")
    }
}