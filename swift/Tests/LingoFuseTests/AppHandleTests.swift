//
//  AppHandleTests.swift
//  LingoFuseTests
//
//  Step 2B verification: the RAII AppHandle wrapper.
//

import XCTest
import LingoFuse

final class AppHandleTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // Construction and lifecycle
    // ==================================================================

    func test01_create_handle() throws {
        let app = try AppHandle(name: "test_ah_create", description: "test")
        XCTAssertTrue(app.isValid)
        XCTAssertEqual(app.name, "test_ah_create")
        app.dispose()
    }

    func test02_dispose_is_idempotent() throws {
        let app = try AppHandle(name: "test_ah_dispose")
        app.dispose()
        app.dispose()
        XCTAssertFalse(app.isValid)
    }

    func test03_use_after_dispose_throws() throws {
        let app = try AppHandle(name: "test_ah_use_after")
        app.dispose()
        XCTAssertThrowsError(try app.registerCall("x") { _, _ in }) { error in
            guard case LingoFuseError.objectDisposed = error else {
                XCTFail("expected objectDisposed, got \(error)")
                return
            }
        }
    }

    // ==================================================================
    // API registration
    // ==================================================================

    func test10_register_call_succeeds() throws {
        let app = try AppHandle(name: "test_ah_reg_call")
        defer { app.dispose() }

        let rc = try app.registerCall("ping", "test ping") { _, _ in }
        XCTAssertTrue(rc)
    }

    func test11_register_call_rejects_duplicate() throws {
        let app = try AppHandle(name: "test_ah_reg_dup")
        defer { app.dispose() }

        _ = try app.registerCall("dup", "") { _, _ in }
        let rc = try app.registerCall("dup", "") { _, _ in }
        XCTAssertFalse(rc)
    }

    func test12_unregister_existing() throws {
        let app = try AppHandle(name: "test_ah_unreg")
        defer { app.dispose() }

        _ = try app.registerCall("removable", "") { _, _ in }
        XCTAssertTrue(try app.unregister("removable"))
        XCTAssertFalse(try app.unregister("removable"))
    }

    func test13_register_notify_succeeds() throws {
        let app = try AppHandle(name: "test_ah_reg_notify")
        defer { app.dispose() }

        let rc = try app.registerNotify("sink", "") { _ in }
        XCTAssertTrue(rc)
    }

    // ==================================================================
    // Local execution
    // ==================================================================

    func test20_local_call_round_trip() throws {
        let app = try AppHandle(name: "test_ah_local_call")
        defer { app.dispose() }

        _ = try app.registerCall("echo", "") { input, output in
            // Read one Int32 from the input and write it back.
            if let v = try? input.readInt32() {
                try? output.writeInt32(v)
            }
        }

        let param = try DataHandle(apiName: "echo")
        defer { param.dispose() }
        try param.writeInt32(12345)
        param.position = 0

        let result = try app.localCall(param)
        defer { result.dispose() }

        XCTAssertGreaterThan(result.size, 0)
        XCTAssertEqual(try result.readInt32(), 12345)
    }

    func test21_local_call_missing_api_returns_empty_handle() throws {
        let app = try AppHandle(name: "test_ah_local_missing")
        defer { app.dispose() }

        let param = try DataHandle(apiName: "does_not_exist")
        defer { param.dispose() }

        let result = try app.localCall(param)
        defer { result.dispose() }
        XCTAssertEqual(result.size, 0)
    }

    func test22_local_notify_round_trip() throws {
        let app = try AppHandle(name: "test_ah_local_notify")
        defer { app.dispose() }

        var fired = false
        _ = try app.registerNotify("sink", "") { _ in
            fired = true
        }

        let param = try DataHandle(apiName: "sink")
        defer { param.dispose() }
        try param.writeInt32(42)
        param.position = 0

        try app.localNotify(param)
        XCTAssertTrue(fired, "notify callback must fire")
    }

    // ==================================================================
    // Callback context lifecycle
    // ==================================================================

    func test30_callback_fires_after_register() throws {
        let app = try AppHandle(name: "test_ah_cb_fire")
        defer { app.dispose() }

        let counter = Counter()
        _ = try app.registerCall("count", "") { _, _ in
            counter.increment()
        }

        let param = try DataHandle(apiName: "count")
        defer { param.dispose() }
        _ = try app.localCall(param)

        XCTAssertEqual(counter.value, 1)
    }

    func test31_callback_after_unregister_stops_firing() throws {
        let app = try AppHandle(name: "test_ah_cb_unreg")
        defer { app.dispose() }

        let counter = Counter()
        _ = try app.registerCall("count", "") { _, _ in
            counter.increment()
        }

        let param = try DataHandle(apiName: "count")
        defer { param.dispose() }
        _ = try app.localCall(param)
        XCTAssertEqual(counter.value, 1)

        _ = try app.unregister("count")

        // Calling a removed API produces an empty handle; no callback.
        let result = try app.localCall(param)
        defer { result.dispose() }
        XCTAssertEqual(counter.value, 1, "callback must not fire after unregister")
    }

    // ==================================================================
    // Counter helper
    // ==================================================================

    private final class Counter {
        private let lock = NSLock()
        private var _value = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        func increment() {
            lock.lock()
            _value += 1
            lock.unlock()
        }
    }
}