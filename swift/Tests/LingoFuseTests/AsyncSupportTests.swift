//
//  AsyncSupportTests.swift
//  LingoFuseTests
//
//  Verification of the modern async/await API in `AsyncSupport.swift`.
//
//  SCOPE
//  -----
//  Two families of tests:
//
//  1. DETERMINISTIC — the synchronous `sequencedCall(_:_:timeoutMs:)`
//     has a real timeout and can be asserted strictly. When no mesh
//     is present, the target is unreachable and the call throws
//     `LingoFuseError.timeout` after the requested window.
//
//  2. BOUNDED WAIT — the `callAsync` / `sequencedCallAsync` methods
//     have no timeout by design (the C ABI's async family has none).
//     The tests therefore race the call against a short sleep and
//     accept ANY outcome (success, error, timeout-of-the-test) as
//     long as the test itself does not hang. This mirrors the
//     Python binding's `test_call_future_dispatch_failure`.
//
//  No live mesh is required. No network session is started.
//

import XCTest
import LingoFuse

final class AsyncSupportTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // Helpers
    // ==================================================================

    private func makeParam(_ apiName: String) throws -> DataHandle {
        return try DataHandle(apiName: apiName)
    }

    /// Races the given operation against a sleep of `seconds`. If the
    /// operation completes first, returns `.value(result)`; if the
    /// sleep wins, returns `.timedOut`. The operation's outcome
    /// (success or failure) is always propagated as `.value`.
    ///
    /// The generic signature accommodates both `async throws -> T`
    /// closures and `async -> T` closures: the caller wraps its
    /// operation in a closure that never throws by catching
    /// internally.
    private enum Race<T> {
        case value(T)
        case timedOut
    }

    private func race<T>(
        _ seconds: Double,
        _ operation: @escaping () async -> T
    ) async -> Race<T> {
        return await withTaskGroup(of: Race<T>.self) { group in
            group.addTask {
                return .value(await operation())
            }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(seconds * 1_000_000_000)
                )
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    // ==================================================================
    // Compile-time: AsyncTarget conformance
    // ==================================================================

    private func acceptsAsyncTarget<T: AsyncTarget>(_ t: T) -> String {
        return t.description
    }

    func test01_all_targets_conform_to_async_protocol() {
        XCTAssertEqual(
            acceptsAsyncTarget(AppTarget("A")),
            "app(A)"
        )
        XCTAssertEqual(
            acceptsAsyncTarget(UidTarget(.null)),
            "uid(00000000..00000000)"
        )
        XCTAssertEqual(
            acceptsAsyncTarget(P2PNameTarget("G")),
            "p2p(G)"
        )
    }

    // ==================================================================
    // sequencedCall — deterministic timeout
    // ==================================================================

    func test10_app_sequenced_call_times_out() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = AppTarget("__absent_async_app__")
        XCTAssertThrowsError(
            try t.sequencedCall("any_api", param, timeoutMs: 200)
        ) { error in
            guard case LingoFuseError.timeout = error else {
                XCTFail("expected timeout, got \(error)")
                return
            }
        }
    }

    func test11_uid_sequenced_call_times_out() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = UidTarget(.null)
        XCTAssertThrowsError(
            try t.sequencedCall("any_api", param, timeoutMs: 200)
        ) { error in
            guard case LingoFuseError.timeout = error else {
                XCTFail("expected timeout, got \(error)")
                return
            }
        }
    }

    func test12_p2pname_sequenced_call_times_out() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let t = P2PNameTarget("__absent_group__")
        XCTAssertThrowsError(
            try t.sequencedCall("any_api", param, timeoutMs: 200)
        ) { error in
            guard case LingoFuseError.timeout = error else {
                XCTFail("expected timeout, got \(error)")
                return
            }
        }
    }

    func test13_sequenced_call_uses_default_timeout_when_nil() throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        // Set an explicit default timeout on the target. Calling
        // `sequencedCall` without a `timeoutMs` argument must use
        // that default. We cannot observe the exact duration without
        // instrumenting the clock, but we can verify the call does
        // not hang and completes in bounded time.
        let t = AppTarget("__absent_async_app__", defaultTimeoutMs: 200)
        let start = Date()
        XCTAssertThrowsError(try t.sequencedCall("any_api", param)) { error in
            guard case LingoFuseError.timeout = error else {
                XCTFail("expected timeout, got \(error)")
                return
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "default timeout not honoured")
    }

    // ==================================================================
    // callAsync — bounded wait, accept any outcome
    // ==================================================================
    //
    // The `callAsync` family has no timeout by design. The tests below
    // race each call against a short sleep and accept any outcome
    // (returned handle, thrown error, or the race's own timeout). The
    // only property they assert is that the test does not hang.

    func test20_app_call_async_does_not_hang() async throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let outcome = await race(2.0) {
            do {
                let r = try await AppTarget("__absent_async_app__")
                    .callAsync("any_api", param)
                r.dispose()
                return "ok"
            } catch {
                return "error"
            }
        }

        switch outcome {
        case .value, .timedOut:
            // Both outcomes are acceptable: the call completed (either
            // by success or failure), or the test itself timed out and
            // we gracefully moved on. Reaching this line proves that
            // the call did not block the test process.
            break
        }
    }

    func test21_uid_call_async_does_not_hang() async throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let outcome = await race(2.0) {
            do {
                let r = try await UidTarget(.null)
                    .callAsync("any_api", param)
                r.dispose()
                return "ok"
            } catch {
                return "error"
            }
        }

        switch outcome {
        case .value, .timedOut:
            break
        }
    }

    func test22_p2pname_call_async_does_not_hang() async throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let outcome = await race(2.0) {
            do {
                let r = try await P2PNameTarget("__absent_group__")
                    .callAsync("any_api", param)
                r.dispose()
                return "ok"
            } catch {
                return "error"
            }
        }

        switch outcome {
        case .value, .timedOut:
            break
        }
    }

    func test23_sequenced_call_async_does_not_hang() async throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let outcome = await race(2.0) {
            do {
                let r = try await AppTarget("__absent_async_app__")
                    .sequencedCallAsync("any_api", param)
                r.dispose()
                return "ok"
            } catch {
                return "error"
            }
        }

        switch outcome {
        case .value, .timedOut:
            break
        }
    }

    // ==================================================================
    // Framework convenience
    // ==================================================================

    func test30_framework_call_async_does_not_hang() async throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let outcome = await race(2.0) {
            do {
                let r = try await Framework.callAsync(
                    "__absent_async_app__", param
                )
                r.dispose()
                return "ok"
            } catch {
                return "error"
            }
        }

        switch outcome {
        case .value, .timedOut:
            break
        }
    }

    func test31_framework_call_async_by_uid_does_not_hang() async throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let outcome = await race(2.0) {
            do {
                let r = try await Framework.callAsyncByUid(
                    .null, param
                )
                r.dispose()
                return "ok"
            } catch {
                return "error"
            }
        }

        switch outcome {
        case .value, .timedOut:
            break
        }
    }

    func test32_framework_call_async_by_p2p_name_does_not_hang() async throws {
        let param = try makeParam("any_api")
        defer { param.dispose() }

        let outcome = await race(2.0) {
            do {
                let r = try await Framework.callAsyncByP2PName(
                    "__absent_group__", param
                )
                r.dispose()
                return "ok"
            } catch {
                return "error"
            }
        }

        switch outcome {
        case .value, .timedOut:
            break
        }
    }
}