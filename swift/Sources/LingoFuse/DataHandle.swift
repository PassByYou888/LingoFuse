//
//  DataHandle.swift
//  LingoFuse
//
//  RAII wrapper around a native LingoFuse data handle (TDataHnd).
//
//  RESPONSIBILITY
//  --------------
//  Owns a native data handle and releases it deterministically on
//  `dispose()` or on deinit. Provides byte-level, scalar, and NUL-framed
//  string I/O on top of the underlying buffer.
//
//  This is the LOW-LEVEL primitive layer. JSON serialization and
//  NUL-framed byte sequences are provided by the higher-level `LfIo`
//  type, which is built on top of `DataHandle`.
//
//  TWO KINDS OF HANDLES
//  --------------------
//  The native library provides two flavours of data handle:
//
//    Auto-recycled  (created by `DataHandle(apiName:)`)
//        - Backed by LF_CreateData.
//        - Added to the library's idle pool.
//        - The pool scans every 5 seconds and frees any handle idle
//          (no accessor call) for more than 10 minutes.
//        - `dispose()` only marks the handle as deleted; the actual
//          release happens on the next pool scan (at most 5 seconds
//          later).
//        - Recommended for the vast majority of use cases.
//
//    Permanent      (created by `DataHandle.createPermanent(apiName:)`)
//        - Backed by LF_CreateData_Permanent.
//        - NOT added to the library's idle pool.
//        - The automatic idle-timeout reclaimer will NEVER free it,
//          no matter how long it has been idle.
//        - `dispose()` releases it IMMEDIATELY (synchronously).
//        - Recommended for handles that must survive for the entire
//          process lifetime (cached request templates, long-lived
//          scratch buffers, global registries).
//
//  Both kinds are released by `Framework.shutdown()` when the process
//  terminates, and both kinds must be explicitly disposed to avoid
//  leaks.
//
//  OWNERSHIP
//  ---------
//  A DataHandle is either "owning" or "borrowing":
//
//    Owning    — created by the public initializer or by
//                `createPermanent`. `dispose()` calls LF_FreeData on
//                the native handle.
//    Borrowing — created by `DataHandle.borrow(raw)`. `dispose()` is a
//                no-op; the native layer owns the underlying resource
//                and releases it when the callback returns.
//
//  Borrowing is used for the input/output handles passed into a
//  callback body. Freeing them from Swift would be a double-free.
//
//  BORROWED HANDLE DISPOSE IS A NO-OP
//  ----------------------------------
//  For a borrowed handle, `dispose()` deliberately does NOT change the
//  wrapper state. A callback body that accidentally calls `dispose()` on
//  its input or output handle must not corrupt the wrapper state for the
//  rest of the callback body. The wrapper's `disposed` flag stays false,
//  so `isValid`, `raw`, and all read methods remain usable until the
//  callback returns.
//
//  STRING CONTRACT
//  ---------------
//  LingoFuse frames strings with a single trailing NUL (0x00) byte on
//  the wire. `writeString` always appends the terminator. `readString`
//  is fault-tolerant: it reads until the first NUL, or all remaining
//  bytes if no NUL is present. This matches the behaviour of every
//  other LingoFuse binding and keeps interop with non-Pascal producers
//  (HTTP bridges, browsers) working.
//
//  I/O FAILURE SEMANTICS
//  ---------------------
//  Two symmetric families of read operations are offered so that
//  callers can choose their failure semantics explicitly:
//
//    Partial   `readBytes(_:)`
//              Returns up to n bytes. Never throws for a short read.
//
//    Exact     `readBytesExact(_:)` / `readInt8()` .. `readDouble()`
//              Requires exactly n bytes. Throws `LingoFuseError.readFailed`
//              on a short read.
//
//  The scalar readers are exact by default, because a partially read
//  integer is never useful.
//
//  WRITE FAILURE SEMANTICS
//  -----------------------
//  `writeBytes` requires the native layer to accept every byte. A short
//  write means the handle is corrupt or the process is out of memory;
//  there is no useful recovery path, and silently continuing would
//  produce a truncated payload on the wire. `writeBytes` therefore
//  throws on a short write, symmetrically with `readBytesExact`.
//
//  SWIFT TDataHnd IMPORT NOTE
//  --------------------------
//  The C header declares `typedef void* TDataHnd;` with no nullability
//  annotation. Under `-swift-version 5`, Swift imports pointer-returning
//  functions as implicitly-unwrapped optionals (`TDataHnd!`). A stored
//  property typed as bare `TDataHnd` is nevertheless treated as
//  NON-optional, so `if let`, `guard let`, `= nil`, and `!` are all
//  rejected. This file therefore stores the handle as `TDataHnd?` and
//  unwraps it at every use site.
//

import Foundation
import CLingoFuse

public final class DataHandle {

    // ------------------------------------------------------------------
    // Private state
    // ------------------------------------------------------------------

    /// The raw native handle, or nil after an owning handle has been
    /// disposed. Stored as an Optional even though `TDataHnd` itself is
    /// a non-optional pointer type, so that `if let` / `guard let` work.
    private var rawHandle: TDataHnd?

    /// True when `dispose()` should call LF_FreeData.
    private let owned: Bool

    /// True after an owning handle has been disposed.
    private var disposed: Bool = false

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /// Creates a new AUTO-RECYCLED data handle bound to the given API
    /// name. The underlying buffer starts empty.
    ///
    /// The handle is added to the library's idle pool. The pool scans
    /// every 5 seconds and frees any handle idle for more than 10
    /// minutes. Use `DataHandle.createPermanent(apiName:)` when the
    /// handle must survive for the entire process lifetime.
    ///
    /// - Parameter apiName: UTF-8 API name.
    /// - Throws: `.generic` when the native allocator fails.
    public init(apiName: String) throws {
        let raw = LF_CreateData(apiName)
        // `LF_CreateData` is imported as returning `TDataHnd!`. The
        // guard-let unwraps it and rejects a NULL return.
        guard let handle = raw else {
            throw LingoFuseError.generic(
                message: "LF_CreateData returned null for API '\(apiName)'"
            )
        }
        self.rawHandle = handle
        self.owned = true
    }

    /// Creates a new PERMANENT data handle bound to the given API name.
    ///
    /// Difference from the standard initializer:
    ///   - NOT added to the library's idle pool.
    ///   - The automatic idle-timeout reclaimer will NEVER free it.
    ///   - `dispose()` releases it IMMEDIATELY (synchronously).
    ///
    /// [PITFALL - NO-OP WINDOW]
    ///   The underlying LF_FreeData is a no-op while the simulated main
    ///   thread is not active (before `Framework.prepareDone` or after
    ///   `Framework.exitMainThread`). Permanent handles created in that
    ///   window stay allocated until the process terminates or
    ///   `Framework.shutdown` runs.
    ///
    /// [PITFALL - LIFETIME]
    ///   "Permanent" means "not automatically reclaimed", NOT "never
    ///   released". You are fully responsible for calling `dispose()`.
    ///
    /// - Parameter apiName: UTF-8 API name.
    /// - Throws: `.generic` when the native allocator fails.
    public static func createPermanent(apiName: String) throws -> DataHandle {
        let raw = LF_CreateData_Permanent(apiName)
        guard let handle = raw else {
            throw LingoFuseError.generic(
                message: "LF_CreateData_Permanent returned null for API '\(apiName)'"
            )
        }
        return DataHandle(internalHandle: handle, owned: true)
    }

    /// Internal constructor used by `AppHandle` callbacks to wrap a
    /// native handle that the framework already owns.
    ///
    /// - Parameters:
    ///   - raw: The native handle.
    ///   - owned: When true, `dispose()` will call LF_FreeData. When
    ///     false, `dispose()` is a no-op.
    public init(internalHandle raw: TDataHnd, owned: Bool) {
        self.rawHandle = raw
        self.owned = owned
    }

    /// Wraps a native handle that the framework owns. The resulting
    /// object will NOT free the handle on `dispose()`.
    public static func borrow(_ raw: TDataHnd) -> DataHandle {
        return DataHandle(internalHandle: raw, owned: false)
    }

    deinit {
        dispose()
    }

    // ------------------------------------------------------------------
    // Identity and state
    // ------------------------------------------------------------------

    /// The raw native pointer.
    ///
    /// The caller must not free the returned pointer; ownership remains
    /// with the wrapper. Calling this on a disposed handle is a
    /// programming error and traps.
    public var raw: TDataHnd {
        return currentRaw("raw")
    }

    /// True while the handle is valid and usable.
    public var isValid: Bool {
        return !disposed && rawHandle != nil
    }

    /// True when `dispose()` will call LF_FreeData.
    public var isOwning: Bool {
        return owned
    }

    // ------------------------------------------------------------------
    // Lifetime
    // ------------------------------------------------------------------

    /// Releases the native handle when ownership applies. Idempotent.
    ///
    /// For an owning auto-recycled handle this only marks the handle as
    /// deleted; the actual release happens on the next pool scan. For
    /// an owning permanent handle the release is synchronous.
    ///
    /// For a borrowed handle this method is a no-op.
    public func dispose() {
        if disposed { return }
        if !owned { return }   // borrowed handles: no-op
        disposed = true
        if let handle = rawHandle {
            LF_FreeData(handle)
        }
        rawHandle = nil
    }

    // ------------------------------------------------------------------
    // Position and size
    // ------------------------------------------------------------------

    /// The current read/write cursor position, in bytes.
    public var position: Int64 {
        get {
            let hnd = currentRaw("position")
            return LF_GetPos(hnd)
        }
        set {
            let hnd = currentRaw("position")
            LF_SetPos(hnd, newValue)
        }
    }

    /// The total buffer size, in bytes.
    public var size: Int64 {
        get {
            let hnd = currentRaw("size")
            return LF_GetSize(hnd)
        }
        set {
            let hnd = currentRaw("size")
            LF_SetSize(hnd, newValue)
        }
    }

    /// Returns the native pointer to the internal buffer.
    ///
    /// The pointer is invalidated by any subsequent resize. Do not free
    /// the pointer.
    public func getBufferPointer() -> UnsafeMutableRawPointer? {
        let hnd = currentRaw("getBufferPointer")
        return LF_GetBuffer(hnd)
    }

    // ------------------------------------------------------------------
    // Byte I/O — partial-read family
    // ------------------------------------------------------------------

    /// Appends the given bytes at the current cursor. The buffer grows
    /// as needed; the cursor advances by the number of bytes written.
    ///
    /// An empty array is a no-op.
    public func writeBytes(_ data: [UInt8]) throws {
        if data.isEmpty { return }
        let hnd = try requireRaw("writeBytes")
        let written = data.withUnsafeBufferPointer { buffer -> Int64 in
            return LF_WriteBuffer(hnd, buffer.baseAddress, Int64(data.count))
        }
        if written != Int64(data.count) {
            throw LingoFuseError.writeFailed(
                operation: "writeBytes",
                expected: data.count,
                actual: written
            )
        }
    }

    /// Reads up to `count` bytes. The cursor advances by the number of
    /// bytes actually read. Never throws for a short read.
    public func readBytes(_ count: Int) throws -> [UInt8] {
        if count < 0 {
            throw LingoFuseError.invalidArgument(
                operation: "readBytes",
                detail: "count must be non-negative"
            )
        }
        if count == 0 { return [] }
        let hnd = try requireRaw("readBytes")
        var buffer = [UInt8](repeating: 0, count: count)
        let got = buffer.withUnsafeMutableBufferPointer { p -> Int64 in
            return LF_ReadBuffer(hnd, p.baseAddress, Int64(count))
        }
        if got <= 0 { return [] }
        if got == Int64(count) { return buffer }
        return Array(buffer.prefix(Int(got)))
    }

    // ------------------------------------------------------------------
    // Byte I/O — exact-read family
    // ------------------------------------------------------------------

    /// Reads exactly `count` bytes. The cursor advances by exactly
    /// `count` bytes on success and is left unchanged on failure.
    public func readBytesExact(_ count: Int) throws -> [UInt8] {
        if count < 0 {
            throw LingoFuseError.invalidArgument(
                operation: "readBytesExact",
                detail: "count must be non-negative"
            )
        }
        if count == 0 { return [] }
        let saved = self.position
        let buf = try readBytes(count)
        if buf.count != count {
            self.position = saved
            throw LingoFuseError.readFailed(
                operation: "readBytesExact",
                expected: count,
                actual: buf.count
            )
        }
        return buf
    }

    /// Non-throwing counterpart of `readBytesExact`. Returns nil on a
    /// short read; the cursor is restored in that case.
    public func tryReadBytes(_ count: Int) throws -> [UInt8]? {
        if count < 0 {
            throw LingoFuseError.invalidArgument(
                operation: "tryReadBytes",
                detail: "count must be non-negative"
            )
        }
        if count == 0 { return [] }
        let saved = self.position
        let buf = try readBytes(count)
        if buf.count != count {
            self.position = saved
            return nil
        }
        return buf
    }

    /// Reads every remaining byte from the current cursor to the end of
    /// the buffer and advances the cursor to the end.
    public func readAllBytes() throws -> [UInt8] {
        let pos = self.position
        let total = self.size
        if pos >= total { return [] }
        return try readBytes(Int(total - pos))
    }

    // ------------------------------------------------------------------
    // Scalar I/O (little-endian)
    // ------------------------------------------------------------------

    public func writeInt8(_ v: Int8) throws {
        let hnd = try requireRaw("writeInt8")
        guard LF_WriteInt8(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeInt8 failed")
        }
    }

    public func writeUInt8(_ v: UInt8) throws {
        let hnd = try requireRaw("writeUInt8")
        guard LF_WriteUInt8(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeUInt8 failed")
        }
    }

    public func writeInt16(_ v: Int16) throws {
        let hnd = try requireRaw("writeInt16")
        guard LF_WriteInt16(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeInt16 failed")
        }
    }

    public func writeUInt16(_ v: UInt16) throws {
        let hnd = try requireRaw("writeUInt16")
        guard LF_WriteUInt16(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeUInt16 failed")
        }
    }

    public func writeInt32(_ v: Int32) throws {
        let hnd = try requireRaw("writeInt32")
        guard LF_WriteInt32(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeInt32 failed")
        }
    }

    public func writeUInt32(_ v: UInt32) throws {
        let hnd = try requireRaw("writeUInt32")
        guard LF_WriteUInt32(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeUInt32 failed")
        }
    }

    public func writeInt64(_ v: Int64) throws {
        let hnd = try requireRaw("writeInt64")
        guard LF_WriteInt64(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeInt64 failed")
        }
    }

    public func writeUInt64(_ v: UInt64) throws {
        let hnd = try requireRaw("writeUInt64")
        guard LF_WriteUInt64(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeUInt64 failed")
        }
    }

    public func writeSingle(_ v: Float) throws {
        let hnd = try requireRaw("writeSingle")
        guard LF_WriteSingle(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeSingle failed")
        }
    }

    public func writeDouble(_ v: Double) throws {
        let hnd = try requireRaw("writeDouble")
        guard LF_WriteDouble(hnd, v) == 1 else {
            throw LingoFuseError.generic(message: "writeDouble failed")
        }
    }

    public func readInt8() throws -> Int8 {
        let hnd = try requireRaw("readInt8")
        var v: Int8 = 0
        guard LF_ReadInt8(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readInt8", expected: 1, actual: 0)
        }
        return v
    }

    public func readUInt8() throws -> UInt8 {
        let hnd = try requireRaw("readUInt8")
        var v: UInt8 = 0
        guard LF_ReadUInt8(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readUInt8", expected: 1, actual: 0)
        }
        return v
    }

    public func readInt16() throws -> Int16 {
        let hnd = try requireRaw("readInt16")
        var v: Int16 = 0
        guard LF_ReadInt16(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readInt16", expected: 2, actual: 0)
        }
        return v
    }

    public func readUInt16() throws -> UInt16 {
        let hnd = try requireRaw("readUInt16")
        var v: UInt16 = 0
        guard LF_ReadUInt16(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readUInt16", expected: 2, actual: 0)
        }
        return v
    }

    public func readInt32() throws -> Int32 {
        let hnd = try requireRaw("readInt32")
        var v: Int32 = 0
        guard LF_ReadInt32(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readInt32", expected: 4, actual: 0)
        }
        return v
    }

    public func readUInt32() throws -> UInt32 {
        let hnd = try requireRaw("readUInt32")
        var v: UInt32 = 0
        guard LF_ReadUInt32(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readUInt32", expected: 4, actual: 0)
        }
        return v
    }

    public func readInt64() throws -> Int64 {
        let hnd = try requireRaw("readInt64")
        var v: Int64 = 0
        guard LF_ReadInt64(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readInt64", expected: 8, actual: 0)
        }
        return v
    }

    public func readUInt64() throws -> UInt64 {
        let hnd = try requireRaw("readUInt64")
        var v: UInt64 = 0
        guard LF_ReadUInt64(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readUInt64", expected: 8, actual: 0)
        }
        return v
    }

    public func readSingle() throws -> Float {
        let hnd = try requireRaw("readSingle")
        var v: Float = 0
        guard LF_ReadSingle(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readSingle", expected: 4, actual: 0)
        }
        return v
    }

    public func readDouble() throws -> Double {
        let hnd = try requireRaw("readDouble")
        var v: Double = 0
        guard LF_ReadDouble(hnd, &v) == 1 else {
            throw LingoFuseError.readFailed(operation: "readDouble", expected: 8, actual: 0)
        }
        return v
    }

    // ------------------------------------------------------------------
    // NUL-framed string I/O
    // ------------------------------------------------------------------

    /// Writes a string as UTF-8, followed by a single NUL byte. An empty
    /// string writes exactly one byte (the NUL).
    public func writeString(_ value: String) throws {
        let hnd = try requireRaw("writeString")
        guard LF_WriteString(hnd, value) == 1 else {
            throw LingoFuseError.generic(
                message: "writeString failed for '\(value)'"
            )
        }
    }

    /// Reads a UTF-8 string from the current cursor, stopping at the
    /// first NUL byte. When no NUL is found before the end of the
    /// buffer, all remaining bytes are consumed and returned.
    ///
    /// Invalid UTF-8 byte sequences are decoded with replacement
    /// characters (U+FFFD). Callers that need to detect invalid UTF-8
    /// must read the raw bytes and inspect them directly.
    public func readString() throws -> String {
        let hnd = try requireRaw("readString")

        // The C ABI requires a caller-supplied buffer. Grow it on
        // failure: LF_ReadString leaves the cursor unchanged when the
        // destination is too small, so a retry is safe.
        var capacity = 256
        while capacity <= 1_000_000_000 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let ok = buffer.withUnsafeMutableBufferPointer { p -> Int32 in
                return LF_ReadString(hnd, p.baseAddress, capacity)
            }
            if ok == 1 {
                return String(cString: buffer)
            }
            // Distinguish "nothing to read" from "buffer too small".
            let pos = LF_GetPos(hnd)
            let sz = LF_GetSize(hnd)
            if pos >= sz {
                return ""
            }
            capacity *= 4
        }
        throw LingoFuseError.readFailed(
            operation: "readString",
            expected: capacity,
            actual: 0
        )
    }

    /// Non-throwing counterpart of `readString`. Returns nil only when
    /// the cursor is at or past the end of the buffer.
    public func tryReadString() throws -> String? {
        if self.position >= self.size {
            return nil
        }
        return try readString()
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// Non-throwing accessor used by computed properties that cannot
    /// throw. Traps on a disposed handle; callers must check
    /// `isValid` first.
    private func currentRaw(_ operation: String) -> TDataHnd {
        precondition(
            !disposed && rawHandle != nil,
            "\(operation): DataHandle has been disposed"
        )
        return rawHandle!
    }

    private func requireRaw(_ operation: String) throws -> TDataHnd {
        if disposed {
            throw LingoFuseError.objectDisposed(objectName: "DataHandle")
        }
        guard let handle = rawHandle else {
            throw LingoFuseError.nullHandle(operation: operation)
        }
        return handle
    }
}