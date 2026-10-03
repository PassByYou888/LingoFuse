//
//  LfIoTests.swift
//  LingoFuseTests
//
//  Step 2A verification: the unified JSON / string / byte I/O layer.
//

import XCTest
import LingoFuse

final class LfIoTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        _ = LF_LoadLibrary()
    }

    // ==================================================================
    // JSON string helpers (no handle required)
    // ==================================================================

    struct Point: Codable, Equatable {
        let x: Int
        let y: Int
    }

    struct Person: Codable, Equatable {
        let name: String
        let age: Int
    }

    func test01_encode_compact_no_whitespace() throws {
        let p = Point(x: 1, y: 2)
        let text = try LfIo.encodeJson(p)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("  "))
        XCTAssertTrue(text.hasPrefix("{"))
        XCTAssertTrue(text.hasSuffix("}"))
    }

    func test02_encode_non_ascii_literal() throws {
        let original = Person(name: "\u{4E16}\u{754C}", age: 30)
        let text = try LfIo.encodeJson(original)
        XCTAssertFalse(text.contains("\\u"))
        XCTAssertTrue(text.contains("\u{4E16}\u{754C}"))
    }

    func test03_encode_emoji_literal() throws {
        let original = Person(name: "\u{1F30D}", age: 1)
        let text = try LfIo.encodeJson(original)
        XCTAssertFalse(text.contains("\\u"))
        XCTAssertTrue(text.contains("\u{1F30D}"))
    }

    func test04_encode_does_not_escape_forward_slash() throws {
        let original = Person(name: "a/b/c", age: 0)
        let text = try LfIo.encodeJson(original)
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertTrue(text.contains("a/b/c"))
    }

    func test05_decode_valid_json() throws {
        let text = #"{"x":10,"y":20}"#
        let p: Point = try LfIo.decodeJson(text)
        XCTAssertEqual(p.x, 10)
        XCTAssertEqual(p.y, 20)
    }

    func test06_decode_invalid_throws() {
        let text = "{not json"
        XCTAssertThrowsError(try LfIo.decodeJson(text) as Point)
    }

    func test07_decode_type_mismatch_throws() {
        let text = #"{"x":"a","y":"b"}"#
        XCTAssertThrowsError(try LfIo.decodeJson(text) as Point)
    }

    // ==================================================================
    // JSON I/O on a handle
    // ==================================================================

    func test10_write_json_appends_nul() throws {
        let dh = try DataHandle(apiName: "json_write")
        try LfIo.writeJson(dh, Point(x: 1, y: 2))
        // Last byte must be the NUL terminator.
        let size = dh.size
        XCTAssertGreaterThan(size, 0)
        dh.position = size - 1
        let last = try dh.readBytes(1)
        XCTAssertEqual(last, [0x00])
        dh.dispose()
    }

    func test11_json_round_trip() throws {
        let dh = try DataHandle(apiName: "json_rt")
        let original = Point(x: 42, y: 84)
        try LfIo.writeJson(dh, original)
        dh.position = 0
        let back: Point = try LfIo.readJson(dh)
        XCTAssertEqual(back, original)
        dh.dispose()
    }

    func test12_json_unicode_round_trip() throws {
        let dh = try DataHandle(apiName: "json_unicode")
        let original = Person(name: "\u{4E16}\u{754C} \u{1F30D}", age: 42)
        try LfIo.writeJson(dh, original)

        // Verify the wire bytes contain literal UTF-8 and no \uXXXX.
        dh.position = 0
        let raw = try LfIo.readStringBytes(dh)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("\\u"))
        XCTAssertTrue(text.contains("\u{4E16}\u{754C}"))
        XCTAssertTrue(text.contains("\u{1F30D}"))

        dh.position = 0
        let back: Person = try LfIo.readJson(dh)
        XCTAssertEqual(back, original)
        dh.dispose()
    }

    func test13_read_json_empty_throws() throws {
        let dh = try DataHandle(apiName: "json_empty")
        try dh.writeString("")
        dh.position = 0
        XCTAssertThrowsError(try LfIo.readJson(dh) as Point)
        dh.dispose()
    }

    func test14_try_read_json_returns_nil_on_invalid() throws {
        let dh = try DataHandle(apiName: "json_try_invalid")
        try dh.writeString("not-json")
        dh.position = 0
        let result: Point? = LfIo.tryReadJson(dh)
        XCTAssertNil(result)
        dh.dispose()
    }

    func test15_try_read_json_returns_nil_on_empty() throws {
        let dh = try DataHandle(apiName: "json_try_empty")
        try dh.writeString("")
        dh.position = 0
        let result: Point? = LfIo.tryReadJson(dh)
        XCTAssertNil(result)
        dh.dispose()
    }

    // ==================================================================
    // Byte-oriented I/O
    // ==================================================================

    func test20_write_string_bytes_appends_nul() throws {
        let dh = try DataHandle(apiName: "bytes_write")
        try LfIo.writeStringBytes(dh, [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(dh.size, 4)
        dh.dispose()
    }

    func test21_read_string_bytes_stops_at_nul() throws {
        let dh = try DataHandle(apiName: "bytes_read")
        try LfIo.writeStringBytes(dh, [0x01, 0x02, 0x03])
        dh.position = 0
        let back = try LfIo.readStringBytes(dh)
        XCTAssertEqual(back, [0x01, 0x02, 0x03])
        dh.dispose()
    }

    func test22_read_all_bytes_ignores_nul() throws {
        let dh = try DataHandle(apiName: "bytes_all")
        try dh.writeBytes([0x01, 0x00, 0x02, 0x00, 0x03])
        dh.position = 0
        let all = try LfIo.readAllBytes(dh)
        XCTAssertEqual(all, [0x01, 0x00, 0x02, 0x00, 0x03])
        dh.dispose()
    }

    // ==================================================================
    // Wire-format invariants (byte-for-byte cross-language contract)
    // ==================================================================

    func test30_wire_format_matches_pascal() throws {
        // {"a":1} must produce the exact byte sequence used by every
        // other LingoFuse binding.
        struct Msg: Codable {
            let a: Int
        }
        let dh = try DataHandle(apiName: "wire_check")
        try LfIo.writeJson(dh, Msg(a: 1))
        dh.position = 0
        let bytes = try LfIo.readStringBytes(dh)
        XCTAssertEqual(bytes, [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D])
        dh.dispose()
    }

    func test31_wire_utf8_bytes_match_pascal() throws {
        // {"msg":"世界"} — verify the CJK bytes are emitted verbatim.
        struct Msg: Codable {
            let msg: String
        }
        let dh = try DataHandle(apiName: "wire_utf8")
        try LfIo.writeJson(dh, Msg(msg: "\u{4E16}\u{754C}"))
        dh.position = 0
        let bytes = try LfIo.readStringBytes(dh)

        // Expected UTF-8: {"msg":"E4 B8 96 E7 95 8C"}
        let expected: [UInt8] = [
            0x7B, 0x22, 0x6D, 0x73, 0x67, 0x22, 0x3A, 0x22,
            0xE4, 0xB8, 0x96, 0xE7, 0x95, 0x8C,
            0x22, 0x7D,
        ]
        XCTAssertEqual(bytes, expected)
        dh.dispose()
    }
}