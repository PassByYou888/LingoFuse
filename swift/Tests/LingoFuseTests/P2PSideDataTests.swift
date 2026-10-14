//
//  P2PSideDataTests.swift
//  LingoFuseTests
//
//  Verification of the side-data accessors on `DataHandle`
//  (`DataHandle.p2pUid()` and `DataHandle.p2pName()`).
//
//  SIDE-DATA CONTRACT
//  ------------------
//  The two accessors are only meaningful on the INPUT handle of a
//  registered callback. On any OTHER handle, the native layer logs a
//  warning and returns a null UID / empty string. This file pins
//  that contract for every non-input case:
//
//      caller-created auto-recycled handle
//      caller-created permanent handle
//      disposed handle
//      borrowed handle wrapping a caller-created handle
//
//  The positive case (a real sender UID on an INPUT handle) requires
//  a full mesh round-trip and belongs to the integration suite.
//

import XCTest
import LingoFuse

final class P2PSideDataTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // Caller-created auto-recycled handle
    // ==================================================================

    func test01_p2p_uid_on_owning_handle_returns_null() throws {
        let h = try DataHandle(apiName: "swift_side_data_owning")
        defer { h.dispose() }

        let uid = h.p2pUid()
        XCTAssertTrue(uid.isNull, "expected Uid.null, got \(uid)")
    }

    func test02_p2p_name_on_owning_handle_returns_empty() throws {
        let h = try DataHandle(apiName: "swift_side_data_owning_name")
        defer { h.dispose() }

        XCTAssertEqual(h.p2pName(), "")
    }

    // ==================================================================
    // Caller-created permanent handle
    // ==================================================================

    func test10_p2p_uid_on_permanent_handle_returns_null() throws {
        let h = try DataHandle.createPermanent(apiName: "swift_side_perm")
        defer { h.dispose() }

        let uid = h.p2pUid()
        XCTAssertTrue(uid.isNull)
    }

    func test11_p2p_name_on_permanent_handle_returns_empty() throws {
        let h = try DataHandle.createPermanent(apiName: "swift_side_perm_name")
        defer { h.dispose() }

        XCTAssertEqual(h.p2pName(), "")
    }

    // ==================================================================
    // Disposed handle (defensive: never crash, never throw)
    // ==================================================================

    func test20_p2p_uid_on_disposed_handle_returns_null() throws {
        let h = try DataHandle(apiName: "swift_side_disposed")
        h.dispose()

        // `isValid` is false; the accessor returns `.null` without
        // touching the underlying pointer.
        let uid = h.p2pUid()
        XCTAssertTrue(uid.isNull)
    }

    func test21_p2p_name_on_disposed_handle_returns_empty() throws {
        let h = try DataHandle(apiName: "swift_side_disposed_name")
        h.dispose()

        XCTAssertEqual(h.p2pName(), "")
    }

    // ==================================================================
    // Borrowed handle wrapping a caller-created handle
    // ==================================================================
    //
    // This is the closest we can come to "the handle is not really an
    // input handle" without a live mesh. The borrowed wrapper sees the
    // underlying pointer, but the pointer was never the input of a
    // callback, so the side-data fields are absent and the accessors
    // return the null/empty values.

    func test30_p2p_uid_on_borrowed_non_input_handle_returns_null() throws {
        let owning = try DataHandle(apiName: "swift_side_borrow")
        defer { owning.dispose() }

        let borrowed = DataHandle.borrow(owning.raw)
        let uid = borrowed.p2pUid()
        XCTAssertTrue(uid.isNull)

        // The borrowed handle must not have freed the underlying
        // resource: `owning` is still valid.
        XCTAssertTrue(owning.isValid)
    }

    func test31_p2p_name_on_borrowed_non_input_handle_returns_empty() throws {
        let owning = try DataHandle(apiName: "swift_side_borrow_name")
        defer { owning.dispose() }

        let borrowed = DataHandle.borrow(owning.raw)
        XCTAssertEqual(borrowed.p2pName(), "")
        XCTAssertTrue(owning.isValid)
    }

    // ==================================================================
    // Type safety: the returned value is a value, not a pointer
    // ==================================================================

    func test40_p2p_uid_returns_value_type() throws {
        let h = try DataHandle(apiName: "swift_side_value")
        defer { h.dispose() }

        // The returned `Uid` must be safely copyable and retainable
        // past the call. This is a compile-time guarantee, but the
        // assertion exercises it at runtime.
        let a = h.p2pUid()
        let b = a
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.rawBytes, [UInt8](repeating: 0, count: 32))
    }

    func test41_p2p_name_returns_owned_string() throws {
        let h = try DataHandle(apiName: "swift_side_owned")
        defer { h.dispose() }

        let name = h.p2pName()
        // The returned String is a fresh copy; it is safe to hold
        // for as long as needed.
        XCTAssertEqual(name, "")
    }
}