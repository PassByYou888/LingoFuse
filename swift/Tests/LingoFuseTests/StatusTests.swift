//
//  StatusTests.swift
//  LingoFuseTests
//
//  Step 2B verification: status queue and health checks.
//

import XCTest
import LingoFuse

final class StatusTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    func test01_get_status_count_non_negative() {
        let n = Status.getStatusCount()
        XCTAssertGreaterThanOrEqual(n, 0)
    }

    func test02_get_status_returns_string() {
        let s = Status.getStatus()
        _ = s  // empty or a message
    }

    func test03_post_status_is_safe_before_framework_start() {
        Status.postStatus("swift status test message")
    }

    func test04_drain_status_zero_is_noop() {
        let result = Status.drainStatus(maxMessages: 0)
        XCTAssertTrue(result.isEmpty)
    }

    func test05_drain_status_negative_is_noop() {
        let result = Status.drainStatus(maxMessages: -1)
        XCTAssertTrue(result.isEmpty)
    }

    func test06_drain_status_default() {
        let result = Status.drainStatus()
        XCTAssertLessThanOrEqual(result.count, 64)
    }

    func test07_check_main_thread_returns_bool() {
        _ = Status.checkMainThread()
    }

    func test08_check_app_absent_is_false() {
        XCTAssertFalse(Status.checkApp("__absent_status_test__"))
    }

    func test09_check_api_absent_is_false() {
        XCTAssertFalse(Status.checkApi("__absent__", "__also_absent__"))
    }
}