//
//  UidTests.swift
//  LingoFuseTests
//
//  Verification of the `Uid` value type.
//
//  These tests are PURE VALUE SEMANTICS: they do not require a live
//  network session and do not create any native handle. The only
//  LingoFuse entry point they touch is `LF_LoadLibrary()` (from the
//  suite-level setUp) so that the module is initialised identically
//  to the rest of the test suite.
//

import XCTest
import LingoFuse

final class UidTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // The null constant
    // ==================================================================

    func test01_null_is_all_zero() {
        XCTAssertTrue(Uid.null.isNull)
        XCTAssertEqual(Uid.null.rawBytes, [UInt8](repeating: 0, count: 32))
        XCTAssertEqual(Uid.null.toHex(), String(repeating: "0", count: 64))
    }

    // ==================================================================
    // Construction from bytes
    // ==================================================================

    func test02_init_bytes_exact_32_succeeds() throws {
        let bytes = [UInt8](0..<32)
        let uid = try Uid(bytes: bytes)
        XCTAssertEqual(uid.rawBytes, bytes)
        XCTAssertFalse(uid.isNull)
    }

    func test03_init_bytes_short_throws() {
        XCTAssertThrowsError(try Uid(bytes: [UInt8](0..<31))) { error in
            guard case LingoFuseError.invalidArgument = error else {
                XCTFail("expected invalidArgument, got \(error)")
                return
            }
        }
    }

    func test04_init_bytes_long_throws() {
        XCTAssertThrowsError(try Uid(bytes: [UInt8](0..<33)))
    }

    // ==================================================================
    // Construction from hex
    // ==================================================================

    func test05_init_hex_roundtrip_lowercase() throws {
        let hex = "0123456789abcdef0123456789abcdef"
                + "0123456789abcdef0123456789abcdef"
        let uid = try Uid(hex: hex)
        XCTAssertEqual(uid.toHex(), hex)
    }

    func test06_init_hex_roundtrip_uppercase() throws {
        let hex = "0123456789ABCDEF0123456789ABCDEF"
                + "0123456789ABCDEF0123456789ABCDEF"
        let uid = try Uid(hex: hex)
        // toHex() always emits lowercase.
        XCTAssertEqual(uid.toHex(), hex.lowercased())
    }

    func test07_init_hex_accepts_0x_prefix() throws {
        let body = "0123456789abcdef0123456789abcdef"
                 + "0123456789abcdef0123456789abcdef"
        let withPrefix = "0x" + body
        let uid = try Uid(hex: withPrefix)
        XCTAssertEqual(uid.toHex(), body)
    }

    func test08_init_hex_accepts_0X_prefix() throws {
        let body = "0123456789abcdef0123456789abcdef"
                 + "0123456789abcdef0123456789abcdef"
        let withPrefix = "0X" + body
        let uid = try Uid(hex: withPrefix)
        XCTAssertEqual(uid.toHex(), body)
    }

    func test09_init_hex_wrong_length_throws() {
        XCTAssertThrowsError(try Uid(hex: ""))
        XCTAssertThrowsError(try Uid(hex: "abc"))
        XCTAssertThrowsError(try Uid(hex: String(repeating: "a", count: 63)))
        XCTAssertThrowsError(try Uid(hex: String(repeating: "a", count: 65)))
    }

    func test10_init_hex_non_hex_chars_throws() {
        let bad = String(repeating: "z", count: 64)
        XCTAssertThrowsError(try Uid(hex: bad))
    }

    // ==================================================================
    // Value semantics
    // ==================================================================

    func test11_equality_and_hash() throws {
        let a = try Uid(bytes: [UInt8](repeating: 1, count: 32))
        let b = try Uid(bytes: [UInt8](repeating: 1, count: 32))
        let c = try Uid(bytes: [UInt8](repeating: 2, count: 32))

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)

        var set = Set<Uid>()
        set.insert(a)
        XCTAssertTrue(set.contains(b))
        XCTAssertFalse(set.contains(c))
    }

    func test12_copy_preserves_value() throws {
        let a = try Uid(bytes: [UInt8](repeating: 7, count: 32))
        let b = a          // value semantics: `a` still usable
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.rawBytes, b.rawBytes)
    }

    // ==================================================================
    // Formatting
    // ==================================================================

    func test13_description_is_64_char_lowercase_hex() throws {
        let uid = try Uid(bytes: [UInt8](repeating: 0xFF, count: 32))
        XCTAssertEqual(uid.description, String(repeating: "f", count: 64))
    }

    func test14_debug_description_short_form() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0]  = 0x01; bytes[1]  = 0x23
        bytes[2]  = 0x45; bytes[3]  = 0x67
        bytes[28] = 0x89; bytes[29] = 0xAB
        bytes[30] = 0xCD; bytes[31] = 0xEF
        let uid = try Uid(bytes: bytes)
        XCTAssertEqual(uid.debugDescription, "Uid(01234567..89abcdef)")
    }

    func test15_debug_description_null() {
        XCTAssertEqual(Uid.null.debugDescription, "Uid(NULL)")
    }

    // ==================================================================
    // isNull
    // ==================================================================

    func test16_is_null_false_for_non_zero() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[15] = 1
        let uid = try Uid(bytes: bytes)
        XCTAssertFalse(uid.isNull)
    }

    // ==================================================================
    // byteCount / hexLength constants
    // ==================================================================

    func test17_byte_count_and_hex_length() {
        XCTAssertEqual(Uid.byteCount, 32)
        XCTAssertEqual(Uid.hexLength, 64)
    }
}