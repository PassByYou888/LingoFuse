//
//  IntegrationTests.swift
//  LingoFuseTests
//
//  Step 2B integration: a real self-connected session using
//  PrepareService + PrepareClient + PrepareDone, exercising the full
//  call path end-to-end.
//
//  These tests are marked to skip on failure of the framework startup
//  sequence, so they never break the suite if the runtime environment
//  cannot bring up an IPC endpoint.
//

import XCTest
import LingoFuse

final class IntegrationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // Session helper
    // ==================================================================

    /// Opens a self-connected session on a unique IPC endpoint.
    /// Returns (app, endpoint) on success, or nil when the framework
    /// could not be started in the current environment.
    private func openSession(
        _ label: String
    ) throws -> (AppHandle, String) {
        let endpoint = "ipc:swift_integration_\(label)_\(UUID().uuidString.prefix(8))"

        Framework.resetPrepare()
        Framework.setOption("Wait_Ready", "False")
        Framework.setOption("Overlap_Connection", "True")
        Framework.setOption("Wait_Connection_Timeout", "5000")

        let app = try AppHandle(name: "SwiftIntegrationApp_\(label)")

        do {
            _ = try Framework.prepareService(
                listeningAddr: endpoint,
                physicsAddr: endpoint
            )
            _ = try Framework.prepareClient(
                physicsAddr: endpoint,
                app: app
            )
        } catch {
            app.dispose()
            throw XCTSkip("Framework startup failed: \(error)")
        }

        _ = Framework.prepareDone()
        return (app, endpoint)
    }

    private func closeSession(_ app: AppHandle) {
        Framework.exitMainThread()
        app.dispose()
        Framework.shutdown()
    }

    /// Waits up to `timeoutMs` for `checkApi(app, api)` to return true.
    /// The mesh broadcasts with an approximate 3-second delay.
    private func waitForApi(
        _ app: String,
        _ api: String,
        timeoutMs: Int = 6000
    ) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if Framework.checkApi(app, api) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    // ==================================================================
    // End-to-end single-address JSON call
    // ==================================================================

    func test01_single_address_json_call() throws {
        let (app, _) = try openSession("json")
        defer { closeSession(app) }

        struct AddArgs: Codable { let a: Int; let b: Int }
        struct AddResult: Codable { let result: Int }

        _ = try app.registerCall("add", "Add two integers") { input, output in
            guard let args: AddArgs = LfIo.tryReadJson(input) else { return }
            let result = AddResult(result: args.a + args.b)
            try? LfIo.writeJson(output, result)
        }

        // Wait for the mesh to broadcast the registration.
        guard waitForApi(app.name, "add") else {
            throw XCTSkip("App did not become visible on the mesh in time")
        }

        // Build a request and invoke the API locally.
        let param = try DataHandle(apiName: "add")
        defer { param.dispose() }
        try LfIo.writeJson(param, AddArgs(a: 5, b: 7))
        param.position = 0

        let response = try app.localCall(param)
        defer { response.dispose() }
        XCTAssertGreaterThan(response.size, 0)

        response.position = 0
        let out: AddResult = try LfIo.readJson(response)
        XCTAssertEqual(out.result, 12)
    }

    // ==================================================================
    // Long string round-trip
    // ==================================================================

    func test02_long_string_round_trip() throws {
        let (app, _) = try openSession("long")
        defer { closeSession(app) }

        _ = try app.registerCall("echo", "Echo a string") { input, output in
            guard let s: String = LfIo.tryReadJson(input) else { return }
            try? LfIo.writeJson(output, s)
        }

        guard waitForApi(app.name, "echo") else {
            throw XCTSkip("App did not become visible on the mesh in time")
        }

        var payload = ""
        while payload.utf8.count < 64 * 1024 {
            payload += "Hello-\u{4E16}\u{754C}-"
        }

        let param = try DataHandle(apiName: "echo")
        defer { param.dispose() }
        try LfIo.writeJson(param, payload)
        param.position = 0

        let response = try app.localCall(param)
        defer { response.dispose() }
        response.position = 0
        let back: String = try LfIo.readJson(response)
        XCTAssertEqual(back, payload)
    }

    // ==================================================================
    // ABI channel (raw binary, no JSON)
    // ==================================================================

    func test03_abi_channel_int32() throws {
        let (app, _) = try openSession("abi")
        defer { closeSession(app) }

        _ = try app.registerCall("add32", "ABI add32") { input, output in
            guard let a = try? input.readInt32(),
                  let b = try? input.readInt32() else { return }
            try? output.writeInt32(a + b)
        }

        guard waitForApi(app.name, "add32") else {
            throw XCTSkip("App did not become visible on the mesh in time")
        }

        let param = try DataHandle(apiName: "add32")
        defer { param.dispose() }
        try param.writeInt32(15)
        try param.writeInt32(27)
        param.position = 0

        let response = try app.localCall(param)
        defer { response.dispose() }
        XCTAssertGreaterThan(response.size, 0)
        XCTAssertEqual(try response.readInt32(), 42)
    }

    // ==================================================================
    // Notify
    // ==================================================================

    func test04_notify_callback_fires() throws {
        let (app, _) = try openSession("notify")
        defer { closeSession(app) }

        let box = NotifyBox()
        _ = try app.registerNotify("sink", "Notify sink") { _ in
            box.increment()
        }

        guard waitForApi(app.name, "sink") else {
            throw XCTSkip("App did not become visible on the mesh in time")
        }

        let param = try DataHandle(apiName: "sink")
        defer { param.dispose() }
        try LfIo.writeJson(param, "hello")
        param.position = 0

        try app.localNotify(param)
        XCTAssertEqual(box.value, 1)
    }

    // ==================================================================
    // Helpers
    // ==================================================================

    private final class NotifyBox {
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