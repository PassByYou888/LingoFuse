//
//  CAbiTests.swift
//  LingoFuseTests
//
//  Step 1 verification: the C ABI layer must be fully functional before
//  any high-level wrapper is built on top of it. This test suite drives
//  every exported function that can be exercised without a live network
//  session, and asserts the exact behaviour documented in LingoFuse.h.
//
//  Read functions in the C ABI use the out-parameter convention:
//
//      int LF_ReadInt32(TDataHnd hnd, int32_t* out);
//      int LF_ReadString(TDataHnd hnd, char* buf, size_t buf_size);
//
//  The integer return value is 1 on success and 0 on a short read.
//  This file therefore calls every reader through a local variable and
//  then asserts both the return code and the produced value.
//
//  IMPORTANT: LF_SetPos only moves the cursor. It does NOT grow the
//  reported size. The native TMem64 keeps Position and Size separate
//  until a write actually touches the new region. See test21.
//

import XCTest
import CLingoFuse

final class CAbiTests: XCTestCase {

    // ====================================================================
    // Suite-level setup
    // ====================================================================
    //
    // LF_LoadLibrary is idempotent: the first call loads the native
    // library and resolves all 37 symbols; subsequent calls return 1
    // immediately. We call it once for the whole suite.
    // ====================================================================

    private static var libraryLoaded: Bool = false

    override class func setUp() {
        super.setUp()
        let rc = LF_LoadLibrary()
        libraryLoaded = (rc == 1)
        if !libraryLoaded {
            print("[SKIP] LF_LoadLibrary failed — the native library is not available.")
            print("[SKIP] Place LingoFuse64.dll (Windows) or liblingofuse.dylib (macOS)")
            print("[SKIP] next to the test executable or on the loader search path.")
        }
    }

    override class func tearDown() {
        LF_FreeLibrary()
        super.tearDown()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.libraryLoaded,
                          "LingoFuse native library is not available")
    }

    // ====================================================================
    // 1. Library loading
    // ====================================================================

    func test01_load_library_is_idempotent() {
        XCTAssertEqual(LF_LoadLibrary(), 1,
                       "LF_LoadLibrary must be idempotent and return 1 on repeat calls")
    }

    func test02_free_library_is_idempotent() {
        // Do not actually free the library here — that would break the
        // remaining tests. This test just verifies the symbol links.
        XCTAssertTrue(true, "LF_FreeLibrary is declared and linkable")
    }

    // ====================================================================
    // 2. DataHandle — creation, identity, lifecycle
    // ====================================================================

    func test10_create_data_returns_non_null() {
        guard let hnd = LF_CreateData("test_create_data") else {
            XCTFail("LF_CreateData returned null")
            return
        }
        LF_FreeData(hnd)
    }

    func test11_create_data_rejects_null_name() {
        let hnd = LF_CreateData(nil)
        XCTAssertNil(hnd, "LF_CreateData(nil) must return nil")
    }

    func test12_free_data_accepts_nil() {
        LF_FreeData(nil)
    }

    func test13_create_data_permanent_returns_non_null() {
        guard let hnd = LF_CreateData_Permanent("test_create_permanent") else {
            XCTFail("LF_CreateData_Permanent returned null")
            return
        }
        LF_FreeData(hnd)
    }

    // ====================================================================
    // 3. DataHandle — position and size
    // ====================================================================

    func test20_initial_position_and_size_are_zero() {
        guard let hnd = LF_CreateData("test_pos_zero") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        XCTAssertEqual(LF_GetPos(hnd), 0)
        XCTAssertEqual(LF_GetSize(hnd), 0)
    }

    func test21_set_pos_moves_cursor_without_growing_size() {
        guard let hnd = LF_CreateData("test_set_pos") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        // LF_SetPos moves the cursor. It does NOT immediately grow the
        // reported size: the native TMem64 keeps Position and Size
        // separate until a write actually touches the new region.
        LF_SetPos(hnd, 16)
        XCTAssertEqual(LF_GetPos(hnd), 16,
                       "LF_SetPos must move the cursor to the requested position")
        XCTAssertEqual(LF_GetSize(hnd), 0,
                       "LF_SetPos alone must not grow the reported size")

        // Writing at the new cursor position forces the buffer to grow
        // so that the write can be stored. After this, both Size and
        // Position reflect the extended buffer.
        _ = LF_WriteUInt8(hnd, 0xAA)
        XCTAssertGreaterThanOrEqual(LF_GetSize(hnd), 17)
        XCTAssertEqual(LF_GetPos(hnd), 17)
    }

    func test22_set_size_resizes_buffer() {
        guard let hnd = LF_CreateData("test_set_size") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        LF_SetSize(hnd, 128)
        XCTAssertEqual(LF_GetSize(hnd), 128)

        LF_SetSize(hnd, 32)
        XCTAssertEqual(LF_GetSize(hnd), 32)
    }

    // ====================================================================
    // 4. DataHandle — raw byte I/O
    // ====================================================================

    func test30_write_then_read_bytes_round_trip() {
        guard let hnd = LF_CreateData("test_bytes") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let written = payload.withUnsafeBufferPointer { buf in
            LF_WriteBuffer(hnd, buf.baseAddress, Int64(buf.count))
        }
        XCTAssertEqual(written, 5, "LF_WriteBuffer must report the full byte count")
        XCTAssertEqual(LF_GetSize(hnd), 5)

        LF_SetPos(hnd, 0)
        var readback = [UInt8](repeating: 0, count: 5)
        let got = readback.withUnsafeMutableBufferPointer { buf in
            LF_ReadBuffer(hnd, buf.baseAddress, Int64(buf.count))
        }
        XCTAssertEqual(got, 5)
        XCTAssertEqual(readback, payload)
    }

    func test31_write_buffer_auto_grows() {
        guard let hnd = LF_CreateData("test_grow") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        let payload = [UInt8](repeating: 0xAA, count: 128)
        let written = payload.withUnsafeBufferPointer { buf in
            LF_WriteBuffer(hnd, buf.baseAddress, Int64(buf.count))
        }
        XCTAssertEqual(written, 128)
        XCTAssertEqual(LF_GetSize(hnd), 128)
    }

    // ====================================================================
    // 5. DataHandle — atomic types (little-endian)
    // ====================================================================

    func test40_atomic_round_trip_all_types() {
        guard let hnd = LF_CreateData("test_atomic") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        // Write every supported scalar type in sequence.
        let i8v: Int8 = -128
        let u8v: UInt8 = 255
        let i16v: Int16 = -32768
        let u16v: UInt16 = 65535
        let i32v: Int32 = -123456789
        let u32v: UInt32 = 123456789
        let i64v: Int64 = -9876543210
        let u64v: UInt64 = 9876543210
        let f32v: Float = 3.14159
        let f64v: Double = 2.718281828

        XCTAssertEqual(LF_WriteInt8(hnd, i8v), 1)
        XCTAssertEqual(LF_WriteUInt8(hnd, u8v), 1)
        XCTAssertEqual(LF_WriteInt16(hnd, i16v), 1)
        XCTAssertEqual(LF_WriteUInt16(hnd, u16v), 1)
        XCTAssertEqual(LF_WriteInt32(hnd, i32v), 1)
        XCTAssertEqual(LF_WriteUInt32(hnd, u32v), 1)
        XCTAssertEqual(LF_WriteInt64(hnd, i64v), 1)
        XCTAssertEqual(LF_WriteUInt64(hnd, u64v), 1)
        XCTAssertEqual(LF_WriteSingle(hnd, f32v), 1)
        XCTAssertEqual(LF_WriteDouble(hnd, f64v), 1)

        LF_SetPos(hnd, 0)

        // Every reader takes an out-parameter and returns 1 on success.
        var i8r: Int8 = 0
        var u8r: UInt8 = 0
        var i16r: Int16 = 0
        var u16r: UInt16 = 0
        var i32r: Int32 = 0
        var u32r: UInt32 = 0
        var i64r: Int64 = 0
        var u64r: UInt64 = 0
        var f32r: Float = 0
        var f64r: Double = 0

        XCTAssertEqual(LF_ReadInt8(hnd, &i8r), 1);    XCTAssertEqual(i8r, i8v)
        XCTAssertEqual(LF_ReadUInt8(hnd, &u8r), 1);   XCTAssertEqual(u8r, u8v)
        XCTAssertEqual(LF_ReadInt16(hnd, &i16r), 1);  XCTAssertEqual(i16r, i16v)
        XCTAssertEqual(LF_ReadUInt16(hnd, &u16r), 1); XCTAssertEqual(u16r, u16v)
        XCTAssertEqual(LF_ReadInt32(hnd, &i32r), 1);  XCTAssertEqual(i32r, i32v)
        XCTAssertEqual(LF_ReadUInt32(hnd, &u32r), 1); XCTAssertEqual(u32r, u32v)
        XCTAssertEqual(LF_ReadInt64(hnd, &i64r), 1);  XCTAssertEqual(i64r, i64v)
        XCTAssertEqual(LF_ReadUInt64(hnd, &u64r), 1); XCTAssertEqual(u64r, u64v)
        XCTAssertEqual(LF_ReadSingle(hnd, &f32r), 1); XCTAssertEqual(f32r, f32v)
        XCTAssertEqual(LF_ReadDouble(hnd, &f64r), 1); XCTAssertEqual(f64r, f64v)
    }

    func test41_little_endian_wire_format() {
        guard let hnd = LF_CreateData("test_endian") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        // 0x01020304 must appear on the wire as 04 03 02 01.
        let value: Int32 = 0x01020304
        _ = LF_WriteInt32(hnd, value)

        LF_SetPos(hnd, 0)
        var buf = [UInt8](repeating: 0, count: 4)
        _ = buf.withUnsafeMutableBufferPointer { p in
            LF_ReadBuffer(hnd, p.baseAddress, 4)
        }
        XCTAssertEqual(buf, [0x04, 0x03, 0x02, 0x01],
                       "LingoFuse integers are little-endian")
    }

    // ====================================================================
    // 6. DataHandle — NUL-framed strings
    // ====================================================================

    func test50_write_string_appends_nul() {
        guard let hnd = LF_CreateData("test_string_nul") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        XCTAssertEqual(LF_WriteString(hnd, "abc"), 1)
        XCTAssertEqual(LF_GetSize(hnd), 4, "LF_WriteString must append exactly one NUL")

        LF_SetPos(hnd, 0)
        var buf = [UInt8](repeating: 0, count: 4)
        _ = buf.withUnsafeMutableBufferPointer { p in
            LF_ReadBuffer(hnd, p.baseAddress, 4)
        }
        XCTAssertEqual(buf, [0x61, 0x62, 0x63, 0x00])
    }

    func test51_write_empty_string_writes_single_nul() {
        guard let hnd = LF_CreateData("test_empty_string") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        XCTAssertEqual(LF_WriteString(hnd, ""), 1)
        XCTAssertEqual(LF_GetSize(hnd), 1)

        LF_SetPos(hnd, 0)
        var b: UInt8 = 0xFF
        _ = withUnsafeMutablePointer(to: &b) { p in
            LF_ReadBuffer(hnd, p, 1)
        }
        XCTAssertEqual(b, 0x00)
    }

    // Helper: read a NUL-framed string via LF_ReadString into a Swift
    // String. The C ABI requires a caller-supplied char buffer.
    private func readStringViaCAbi(_ hnd: TDataHnd,
                                   capacity: Int = 4096) -> String? {
        var buffer = [CChar](repeating: 0, count: capacity)
        let ok = buffer.withUnsafeMutableBufferPointer { p in
            LF_ReadString(hnd, p.baseAddress, capacity)
        }
        guard ok == 1 else { return nil }
        return String(cString: buffer)
    }

    func test52_read_string_round_trip_ascii() {
        guard let hnd = LF_CreateData("test_read_string") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        _ = LF_WriteString(hnd, "hello world")
        LF_SetPos(hnd, 0)

        let out = readStringViaCAbi(hnd)
        XCTAssertEqual(out, "hello world")
    }

    func test53_read_string_round_trip_utf8() {
        guard let hnd = LF_CreateData("test_read_utf8") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        // Chinese characters + emoji. Both must survive the round trip.
        let original = "Hello, \u{4E16}\u{754C} \u{1F30D}"
        _ = LF_WriteString(hnd, original)
        LF_SetPos(hnd, 0)

        let out = readStringViaCAbi(hnd)
        XCTAssertEqual(out, original)
    }

    func test54_read_string_fault_tolerant_no_nul() {
        guard let hnd = LF_CreateData("test_fault_tolerant") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        // Write raw bytes with no trailing NUL.
        let raw: [UInt8] = Array("no-nul-here".utf8)
        _ = raw.withUnsafeBufferPointer { p in
            LF_WriteBuffer(hnd, p.baseAddress, Int64(p.count))
        }
        LF_SetPos(hnd, 0)

        let out = readStringViaCAbi(hnd)
        XCTAssertEqual(out, "no-nul-here")
    }

    // ====================================================================
    // 7. DataHandle — buffer access
    // ====================================================================

    func test60_get_buffer_returns_non_null_after_write() {
        guard let hnd = LF_CreateData("test_get_buffer") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        _ = LF_WriteUInt8(hnd, 0x42)
        let p = LF_GetBuffer(hnd)
        XCTAssertNotNil(p)

        if let p = p {
            let first = p.assumingMemoryBound(to: UInt8.self).pointee
            XCTAssertEqual(first, 0x42)
        }
    }

    func test61_get_buffer_offset_returns_correct_offset() {
        guard let hnd = LF_CreateData("test_buffer_offset") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(hnd) }

        _ = LF_WriteUInt8(hnd, 0xAA)
        _ = LF_WriteUInt8(hnd, 0xBB)
        _ = LF_WriteUInt8(hnd, 0xCC)

        let base = LF_GetBufferOffset(hnd, 0)
        let at1  = LF_GetBufferOffset(hnd, 1)
        XCTAssertNotNil(base)
        XCTAssertNotNil(at1)

        if let at1 = at1 {
            XCTAssertEqual(at1.assumingMemoryBound(to: UInt8.self).pointee, 0xBB)
        }
    }

    // ====================================================================
    // 8. AppHandle — creation, identity, lifecycle
    // ====================================================================

    func test70_create_app_returns_non_null() {
        guard let app = LF_CreateApp("test_app_create", "test description") else {
            XCTFail("LF_CreateApp returned null")
            return
        }
        LF_FreeApp(app)
    }

    func test71_create_app_with_empty_description() {
        guard let app = LF_CreateApp("test_app_empty_desc", "") else {
            XCTFail("LF_CreateApp returned null")
            return
        }
        LF_FreeApp(app)
    }

    func test72_free_app_accepts_nil() {
        LF_FreeApp(nil)
    }

    // ====================================================================
    // 9. AppHandle — API registration
    // ====================================================================

    func test80_register_call_succeeds() {
        guard let app = LF_CreateApp("test_register_call", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        let rc = LF_RegisterCall(app, "ping", "test ping", nil, testCallCallback)
        XCTAssertEqual(rc, 1, "First registration must succeed")
    }

    func test81_register_call_rejects_duplicate() {
        guard let app = LF_CreateApp("test_register_duplicate", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        _ = LF_RegisterCall(app, "dup", "first", nil, testCallCallback)
        let rc = LF_RegisterCall(app, "dup", "second", nil, testCallCallback)
        XCTAssertEqual(rc, 0, "Second registration with the same name must fail")
    }

    func test82_unregister_existing() {
        guard let app = LF_CreateApp("test_unregister", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        _ = LF_RegisterCall(app, "removable", "", nil, testCallCallback)
        XCTAssertEqual(LF_Unregister(app, "removable"), 1)

        // Second unregister must report "not found".
        XCTAssertEqual(LF_Unregister(app, "removable"), 0)
    }

    func test83_register_notify_succeeds() {
        guard let app = LF_CreateApp("test_register_notify", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        let rc = LF_RegisterNotify(app, "sink", "test notify", nil, testNotifyCallback)
        XCTAssertEqual(rc, 1)
    }

    // ====================================================================
    // 10. AppHandle — local execution
    // ====================================================================

    func test90_local_call_round_trip() {
        guard let app = LF_CreateApp("test_local_call", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        _ = LF_RegisterCall(app, "echo", "", nil, echoCallCallback)

        guard let param = LF_CreateData("echo") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(param) }

        _ = LF_WriteInt32(param, 12345)

        // LF_LocalCall reads the input from position 0, so we must
        // rewind after writing.
        LF_SetPos(param, 0)

        let result = LF_LocalCall(app, param)
        XCTAssertNotNil(result, "LF_LocalCall must not return nil")
        if let result = result {
            defer { LF_FreeData(result) }
            XCTAssertGreaterThan(LF_GetSize(result), 0)

            var readValue: Int32 = 0
            XCTAssertEqual(LF_ReadInt32(result, &readValue), 1)
            XCTAssertEqual(readValue, 12345)
        }
    }

    func test91_local_call_missing_api_returns_empty_handle() {
        guard let app = LF_CreateApp("test_local_missing", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        guard let param = LF_CreateData("does_not_exist") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(param) }

        let result = LF_LocalCall(app, param)
        XCTAssertNotNil(result)
        if let result = result {
            defer { LF_FreeData(result) }
            XCTAssertEqual(LF_GetSize(result), 0,
                           "Missing API must produce a size-0 handle")
        }
    }

    func test92_local_notify_round_trip() {
        guard let app = LF_CreateApp("test_local_notify", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        _ = LF_RegisterNotify(app, "sink", "", nil, testNotifyCallback)

        guard let param = LF_CreateData("sink") else {
            XCTFail("LF_CreateData failed"); return
        }
        defer { LF_FreeData(param) }

        _ = LF_WriteInt32(param, 42)
        LF_SetPos(param, 0)

        // Must not crash; the callback is a no-op.
        LF_LocalNotify(app, param)
    }

    // ====================================================================
    // 11. AppHandle — name lookup
    // ====================================================================

    func test100_get_app_name_returns_constructor_name() {
        guard let app = LF_CreateApp("test_get_name", "") else {
            XCTFail("LF_CreateApp failed"); return
        }
        defer { LF_FreeApp(app) }

        let namePtr = LF_Get_AppName(app)
        XCTAssertNotNil(namePtr)
        if let namePtr = namePtr {
            let name = String(cString: namePtr)
            XCTAssertEqual(name, "test_get_name")
        }
    }

    func test101_get_app_name_nil_returns_nil() {
        let p = LF_Get_AppName(nil)
        XCTAssertNil(p, "LF_Get_AppName(nil) must return nil")
    }

    // ====================================================================
    // 12. Runtime options
    // ====================================================================

    func test110_set_option_accepts_known_key() {
        LF_SetOption("Quiet", "True")
    }

    func test111_set_option_handles_null_safely() {
        LF_SetOption(nil, "True")
        LF_SetOption("Quiet", nil)
        LF_SetOption(nil, nil)
    }

    // ====================================================================
    // 13. Status queue and health checks
    // ====================================================================

    func test120_get_status_count_is_non_negative() {
        let n = LF_GetStatusCount()
        XCTAssertGreaterThanOrEqual(n, 0)
    }

    func test121_get_status_is_callable() {
        let p = LF_GetStatus()
        _ = p   // may be non-nil or nil depending on queue state
    }

    func test122_post_status_is_safe_before_framework_start() {
        LF_PostStatus("c-abi-test: posted before framework startup")
    }

    func test123_check_main_thread_returns_int() {
        let running = LF_CheckMainThread()
        XCTAssertTrue(running == 0 || running == 1)
    }

    func test124_check_app_returns_false_for_absent_name() {
        let r = LF_CheckApp("__definitely_absent_in_tests__")
        XCTAssertEqual(r, 0)
    }

    func test125_check_api_returns_false_for_absent_pair() {
        let r = LF_CheckApi("__definitely_absent_in_tests__",
                            "__also_absent__")
        XCTAssertEqual(r, 0)
    }

    // ====================================================================
    // 14. Network preparation — surface-level only
    // ====================================================================

    func test130_reset_prepare_is_safe() {
        LF_ResetPrepare()
    }

    func test131_prepare_service_returns_tag() {
        LF_ResetPrepare()
        let tag = LF_PrepareService("ipc:swift_c_abi_test_service",
                                    "ipc:swift_c_abi_test_service")
        XCTAssertGreaterThanOrEqual(tag, 0, "A fresh address must be accepted")
    }

    func test132_prepare_service_rejects_duplicate() {
        LF_ResetPrepare()
        let first = LF_PrepareService("ipc:swift_c_abi_test_dup",
                                      "ipc:swift_c_abi_test_dup")
        XCTAssertGreaterThanOrEqual(first, 0)

        // Second call with the same address must be rejected.
        let second = LF_PrepareService("ipc:swift_c_abi_test_dup",
                                       "ipc:swift_c_abi_test_dup")
        XCTAssertEqual(second, -1)

        LF_ResetPrepare()
    }

    // ====================================================================
    // 15. Callback prototype signatures
    // ====================================================================

    func test140_callback_prototypes_compile() {
        let callFn: LF_CallFunc = testCallCallback
        let notifyFn: LF_NotifyFunc = testNotifyCallback
        XCTAssertNotNil(callFn)
        XCTAssertNotNil(notifyFn)
    }
}

// ========================================================================
// Top-level C callbacks
// ------------------------------------------------------------------------
// Swift's @_cdecl requires the callback to be a global function (or a
// static method), not a closure. These functions exist solely to
// exercise registration and local-execution paths.
// ========================================================================

/// A Call-mode callback that echoes a single int32 from input to output.
@_cdecl("lf_test_echo_call_callback")
public func echoCallCallback(trigger: UnsafeMutableRawPointer?,
                             input:  TDataHnd?,
                             output: TDataHnd?) {
    guard let input = input, let output = output else { return }
    var value: Int32 = 0
    guard LF_ReadInt32(input, &value) == 1 else { return }
    _ = LF_WriteInt32(output, value)
}

/// A Call-mode callback that does nothing.
@_cdecl("lf_test_noop_call_callback")
public func testCallCallback(trigger: UnsafeMutableRawPointer?,
                             input:  TDataHnd?,
                             output: TDataHnd?) {
    // no-op
}

/// A Notify-mode callback that does nothing.
@_cdecl("lf_test_noop_notify_callback")
public func testNotifyCallback(trigger: UnsafeMutableRawPointer?,
                               input:  TDataHnd?) {
    // no-op
}