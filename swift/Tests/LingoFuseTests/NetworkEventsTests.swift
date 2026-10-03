//
//  NetworkEventsTests.swift
//  LingoFuseTests
//
//  Step 2B verification: process-global network event handlers.
//

import XCTest
import LingoFuse

final class NetworkEventsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    override func setUp() {
        super.setUp()
        NetworkEvents.clearNetworkEvent()
    }

    override func tearDown() {
        NetworkEvents.clearNetworkEvent()
        super.tearDown()
    }

    func test01_install_both_handlers() {
        NetworkEvents.setNetworkEvent(
            onConnect: { _ in },
            onDisconnect: { _ in }
        )
        XCTAssertTrue(NetworkEvents.isNetworkEventInstalled)
    }

    func test02_install_connect_only() {
        NetworkEvents.setNetworkEvent(onConnect: { _ in }, onDisconnect: nil)
        XCTAssertTrue(NetworkEvents.isNetworkEventInstalled)
    }

    func test03_install_disconnect_only() {
        NetworkEvents.setNetworkEvent(onConnect: nil, onDisconnect: { _ in })
        XCTAssertTrue(NetworkEvents.isNetworkEventInstalled)
    }

    func test04_clear_removes_handlers() {
        NetworkEvents.setNetworkEvent(
            onConnect: { _ in },
            onDisconnect: { _ in }
        )
        NetworkEvents.clearNetworkEvent()
        XCTAssertFalse(NetworkEvents.isNetworkEventInstalled)
    }

    func test05_clear_is_idempotent() {
        NetworkEvents.clearNetworkEvent()
        NetworkEvents.clearNetworkEvent()
        XCTAssertFalse(NetworkEvents.isNetworkEventInstalled)
    }

    func test06_set_none_none_clears_previous() {
        NetworkEvents.setNetworkEvent(onConnect: { _ in }, onDisconnect: nil)
        XCTAssertTrue(NetworkEvents.isNetworkEventInstalled)

        NetworkEvents.setNetworkEvent(onConnect: nil, onDisconnect: nil)
        XCTAssertFalse(NetworkEvents.isNetworkEventInstalled)
    }

    func test07_replace_handlers() {
        NetworkEvents.setNetworkEvent(onConnect: { _ in }, onDisconnect: nil)
        NetworkEvents.setNetworkEvent(onConnect: { _ in }, onDisconnect: nil)
        XCTAssertTrue(NetworkEvents.isNetworkEventInstalled)
    }
}