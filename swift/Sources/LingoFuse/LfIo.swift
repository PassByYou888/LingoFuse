//
//  LfIo.swift
//  LingoFuse
//
//  Unified JSON, string, and byte I/O for LingoFuse data handles.
//
//  This module is the Swift counterpart of `lf_io.hpp` (C++), `LfIo.cs`
//  (C#), `lf-io.js` (JavaScript), and `io.rs` (Rust). It is the SINGLE
//  sanctioned path for moving structured data to and from a
//  `DataHandle`.
//
//  WIRE FORMAT
//  -----------
//  A JSON payload on a data handle is:
//
//      [UTF-8 encoded JSON text][NUL byte]
//
//  A plain-text payload uses the same framing. A raw binary payload is:
//
//      [arbitrary bytes][NUL byte]
//
//  Reading is fault-tolerant: if no NUL is found before the end of the
//  buffer, the entire remaining buffer is consumed. This makes the
//  reader tolerant of payloads that arrive from an HTTP bridge or any
//  other producer that does not append a NUL.
//
//  CROSS-LANGUAGE COMPATIBILITY
//  ----------------------------
//  The framing matches lingofuse_import.pas, lingofuse.lf_io,
//  lf_io.hpp, LfIo.cs, lf-io.js, and io.rs exactly. For the logical
//  payload {"a":1}, every binding emits the byte sequence
//  7B 22 61 22 3A 31 7D 00, and every reader follows the same
//  three-case rule.
//
//  JSON SERIALIZATION POLICY
//  -------------------------
//  Every JSON string produced by this module goes through `encodeJson`.
//  The policy is:
//
//    - Compact output: no indentation, no trailing newline.
//    - Non-ASCII characters emitted as literal UTF-8, not as \\uXXXX
//      escapes. This is Foundation's default behaviour for JSONEncoder,
//      and it matches the Python (ensure_ascii=False), C++
//      (error_handler_t::replace), and C# (UnsafeRelaxedJsonEscaping)
//      producers.
//    - Forward slashes are NOT escaped. Without
//      `.withoutEscapingSlashes`, Foundation would emit `\/` for a
//      literal `/`; every other binding emits `/` verbatim.
//
//  This module deliberately does not offer pretty-printing:
//  indentation would break the byte-for-byte cross-language contract.
//

import Foundation

public enum LfIo {

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// The NUL byte used as the string terminator on the wire.
    public static let nulByte: UInt8 = 0x00

    // ------------------------------------------------------------------
    // JSON <-> Swift value
    // ------------------------------------------------------------------

    /// Encodes a `Codable` value to compact UTF-8 JSON text.
    ///
    /// The returned string does NOT include a trailing NUL byte.
    /// Callers that write it to a data handle should use
    /// `LfIo.writeJson(_:_:)` or `DataHandle.writeString(_:)`.
    public static func encodeJson<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw LingoFuseError.writeFailed(
                operation: "LfIo.encodeJson",
                expected: 0,
                actual: 0
            )
        }
    }

    /// Decodes a UTF-8 JSON string into a `Decodable` value.
    ///
    /// Strict: any syntax error or type mismatch throws
    /// `LingoFuseError.readFailed`.
    public static func decodeJson<T: Decodable>(_ text: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw LingoFuseError.readFailed(
                operation: "LfIo.decodeJson",
                expected: 1,
                actual: 0
            )
        }
    }

    // ------------------------------------------------------------------
    // String I/O (NUL-framed UTF-8)
    // ------------------------------------------------------------------

    /// Writes a string as UTF-8 bytes, followed by a single NUL byte.
    public static func writeString(_ handle: DataHandle, _ value: String) throws {
        try handle.writeString(value)
    }

    /// Reads a UTF-8 string from the handle, stopping at the first NUL.
    public static func readString(_ handle: DataHandle) throws -> String {
        return try handle.readString()
    }

    // ------------------------------------------------------------------
    // Byte-oriented I/O (NUL-framed raw bytes)
    // ------------------------------------------------------------------

    /// Writes raw bytes followed by a single NUL byte.
    ///
    /// The bytes are written verbatim; embedded NUL bytes are preserved
    /// in the buffer. Note that the read side stops at the first NUL, so
    /// an embedded NUL acts as a terminator on read. This asymmetry is
    /// intentional and matches every other LingoFuse binding.
    public static func writeStringBytes(_ handle: DataHandle, _ data: [UInt8]) throws {
        try handle.writeBytes(data)
        let nul: UInt8 = 0
        try handle.writeBytes([nul])
    }

    /// Reads raw bytes from the handle, stopping at the first NUL.
    ///
    /// Unlike `readAllBytes`, which consumes the entire remaining
    /// buffer, this stops at the NUL that `writeString` / `writeJson`
    /// append.
    public static func readStringBytes(_ handle: DataHandle) throws -> [UInt8] {
        let start = handle.position
        let total = handle.size
        if start >= total { return [] }
        let raw = try handle.readBytes(Int(total - start))
        if raw.isEmpty { return [] }

        if let nulIndex = raw.firstIndex(of: 0) {
            handle.position = start + Int64(nulIndex) + 1
            return Array(raw.prefix(nulIndex))
        } else {
            handle.position = start + Int64(raw.count) + 1
            return raw
        }
    }

    /// Reads every remaining byte from the current cursor to the end of
    /// the buffer, without NUL handling.
    public static func readAllBytes(_ handle: DataHandle) throws -> [UInt8] {
        return try handle.readAllBytes()
    }

    // ------------------------------------------------------------------
    // JSON I/O (NUL-framed JSON)
    // ------------------------------------------------------------------

    /// Serializes `value` as UTF-8 JSON and writes it with the standard
    /// NUL terminator.
    public static func writeJson<T: Encodable>(_ handle: DataHandle, _ value: T) throws {
        let text = try encodeJson(value)
        try handle.writeString(text)
    }

    /// Reads a UTF-8 JSON payload from the handle and deserializes it.
    public static func readJson<T: Decodable>(_ handle: DataHandle) throws -> T {
        let text = try handle.readString()
        if text.isEmpty {
            throw LingoFuseError.readFailed(
                operation: "LfIo.readJson",
                expected: 1,
                actual: 0
            )
        }
        return try decodeJson(text)
    }

    /// Non-throwing counterpart of `readJson`. The cursor is advanced
    /// regardless of whether the payload parses successfully.
    public static func tryReadJson<T: Decodable>(_ handle: DataHandle) -> T? {
        do {
            return try readJson(handle)
        } catch {
            return nil
        }
    }
}