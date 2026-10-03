//
//  DataHandleTests.swift
//  LingoFuseTests
//
//  Step 2A verification: the RAII DataHandle wrapper.
//

import XCTest
import LingoFuse

final class DataHandleTests: XCTestCase {

    // The suite-level load is performed by CAbiTests; by the time any
    // DataHandleTests method runs, LF_LoadLibrary has already been
    // called and the native symbols are resolved. We add a defensive
    // call here so this file can also be run in isolation.
    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // Construction and lifecycle
    // ==================================================================

    func test01_create_auto_recycled_handle() throws {
        let dh = try DataHandle(apiName: "test_auto")
        XCTAssertTrue(dh.isValid)
        XCTAssertTrue(dh.isOwning)
        XCTAssertNotNil(dh.raw)
        dh.dispose()
    }

    func test02_create_permanent_handle() throws {
        let dh = try DataHandle.createPermanent(apiName: "test_perm")
        XCTAssertTrue(dh.isValid)
        XCTAssertTrue(dh.isOwning)
        dh.dispose()
    }

    func test03_dispose_is_idempotent() throws {
        let dh = try DataHandle(apiName: "test_dispose_idem")
        dh.dispose()
        dh.dispose()
        XCTAssertFalse(dh.isValid)
    }

    func test04_use_after_dispose_throws() throws {
        let dh = try DataHandle(apiName: "test_use_after_dispose")
        dh.dispose()
        XCTAssertThrowsError(try dh.writeBytes([1, 2, 3])) { error in
            guard case LingoFuseError.objectDisposed = error else {
                XCTFail("expected objectDisposed, got \(error)")
                return
            }
        }
    }

    func test05_borrowed_handle_dispose_is_noop() throws {
        // Wrap an existing native handle as borrowed. The wrapper must
        // not free the underlying resource on dispose.
        guard let raw = LF_CreateData("test_borrow") else {
            XCTFail("LF_CreateData returned null"); return
        }
        let dh = DataHandle.borrow(raw)
        XCTAssertTrue(dh.isValid)
        XCTAssertFalse(dh.isOwning)

        // dispose() on a borrowed handle is a no-op.
        dh.dispose()
        XCTAssertTrue(dh.isValid,
                      "borrowed handle must remain usable after dispose()")

        // Free the native resource explicitly, since the wrapper will
        // not.
        LF_FreeData(raw)
    }

    // ==================================================================
    // Position and size
    // ==================================================================

    func test10_initial_position_and_size_are_zero() throws {
        let dh = try DataHandle(apiName: "test_init_pos")
        XCTAssertEqual(dh.position, 0)
        XCTAssertEqual(dh.size, 0)
        dh.dispose()
    }

    func test11_set_size_resizes_buffer() throws {
        let dh = try DataHandle(apiName: "test_set_size")
        dh.size = 128
        XCTAssertEqual(dh.size, 128)
        dh.size = 32
        XCTAssertEqual(dh.size, 32)
        dh.dispose()
    }

    func test12_set_position_moves_cursor() throws {
        let dh = try DataHandle(apiName: "test_set_pos")
        dh.position = 0
        XCTAssertEqual(dh.position, 0)
        try dh.writeUInt8(0xAA)
        dh.position = 0
        XCTAssertEqual(dh.position, 0)
        dh.dispose()
    }

    // ==================================================================
    // Byte I/O
    // ==================================================================

    func test20_write_read_bytes_round_trip() throws {
        let dh = try DataHandle(apiName: "test_bytes_rt")
        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        try dh.writeBytes(payload)
        XCTAssertEqual(dh.size, 5)
        dh.position = 0
        let back = try dh.readBytes(5)
        XCTAssertEqual(back, payload)
        dh.dispose()
    }

    func test21_read_bytes_exact_success() throws {
        let dh = try DataHandle(apiName: "test_exact_ok")
        try dh.writeBytes([0x10, 0x20, 0x30, 0x40])
        dh.position = 0
        let back = try dh.readBytesExact(4)
        XCTAssertEqual(back, [0x10, 0x20, 0x30, 0x40])
        dh.dispose()
    }

    func test22_read_bytes_exact_short_throws() throws {
        let dh = try DataHandle(apiName: "test_exact_fail")
        try dh.writeBytes([0x01, 0x02])
        dh.position = 0
        XCTAssertThrowsError(try dh.readBytesExact(4)) { error in
            guard case LingoFuseError.readFailed = error else {
                XCTFail("expected readFailed, got \(error)")
                return
            }
        }
        // The cursor must be restored.
        XCTAssertEqual(dh.position, 0)
        dh.dispose()
    }

    func test23_try_read_bytes_returns_nil() throws {
        let dh = try DataHandle(apiName: "test_try_read")
        try dh.writeBytes([0x01, 0x02])
        dh.position = 0
        XCTAssertNil(try dh.tryReadBytes(4))
        XCTAssertEqual(dh.position, 0)
        XCTAssertNotNil(try dh.tryReadBytes(2))
        dh.dispose()
    }

    func test24_read_all_bytes() throws {
        let dh = try DataHandle(apiName: "test_read_all")
        try dh.writeBytes([0x01, 0x02, 0x03])
        dh.position = 1
        let rest = try dh.readAllBytes()
        XCTAssertEqual(rest, [0x02, 0x03])
        XCTAssertEqual(dh.position, dh.size)
        dh.dispose()
    }

    // ==================================================================
    // Scalar I/O
    // ==================================================================

    func test30_scalar_round_trip() throws {
        let dh = try DataHandle(apiName: "test_scalar_rt")
        try dh.writeInt8(-128)
        try dh.writeUInt8(255)
        try dh.writeInt16(-32768)
        try dh.writeUInt16(65535)
        try dh.writeInt32(-123456789)
        try dh.writeUInt32(123456789)
        try dh.writeInt64(-9876543210)
        try dh.writeUInt64(9876543210)
        try dh.writeSingle(3.14159)
        try dh.writeDouble(2.718281828)

        dh.position = 0
        XCTAssertEqual(try dh.readInt8(), -128)
        XCTAssertEqual(try dh.readUInt8(), 255)
        XCTAssertEqual(try dh.readInt16(), -32768)
        XCTAssertEqual(try dh.readUInt16(), 65535)
        XCTAssertEqual(try dh.readInt32(), -123456789)
        XCTAssertEqual(try dh.readUInt32(), 123456789)
        XCTAssertEqual(try dh.readInt64(), -9876543210)
        XCTAssertEqual(try dh.readUInt64(), 9876543210)
        XCTAssertEqual(try dh.readSingle(), 3.14159)
        XCTAssertEqual(try dh.readDouble(), 2.718281828)
        dh.dispose()
    }

    func test31_scalar_read_short_throws() throws {
        let dh = try DataHandle(apiName: "test_scalar_short")
        try dh.writeBytes([0x01, 0x02])
        dh.position = 0
        XCTAssertThrowsError(try dh.readInt32()) { error in
            guard case LingoFuseError.readFailed = error else {
                XCTFail("expected readFailed, got \(error)")
                return
            }
        }
        dh.dispose()
    }

    // ==================================================================
    // String I/O
    // ==================================================================

    func test40_write_read_string_ascii() throws {
        let dh = try DataHandle(apiName: "test_string_ascii")
        try dh.writeString("hello world")
        XCTAssertEqual(dh.size, 12, "11 chars + 1 NUL")
        dh.position = 0
        XCTAssertEqual(try dh.readString(), "hello world")
        dh.dispose()
    }

    func test41_write_read_string_utf8() throws {
        let dh = try DataHandle(apiName: "test_string_utf8")
        let original = "Hello, \u{4E16}\u{754C} \u{1F30D}"
        try dh.writeString(original)
        dh.position = 0
        XCTAssertEqual(try dh.readString(), original)
        dh.dispose()
    }

    func test42_write_empty_string_writes_single_nul() throws {
        let dh = try DataHandle(apiName: "test_empty_string")
        try dh.writeString("")
        XCTAssertEqual(dh.size, 1)
        dh.position = 0
        let back = try dh.readBytes(1)
        XCTAssertEqual(back, [0x00])
        dh.dispose()
    }

    func test43_fault_tolerant_read_no_nul() throws {
        let dh = try DataHandle(apiName: "test_fault_read")
        let raw: [UInt8] = Array("no-nul-here".utf8)
        try dh.writeBytes(raw)
        dh.position = 0
        XCTAssertEqual(try dh.readString(), "no-nul-here")
        dh.dispose()
    }

    func test44_try_read_string_returns_nil_when_exhausted() throws {
        let dh = try DataHandle(apiName: "test_try_string")
        XCTAssertNil(try dh.tryReadString())
        try dh.writeString("x")
        dh.position = 0
        XCTAssertEqual(try dh.tryReadString(), "x")
        dh.dispose()
    }
}