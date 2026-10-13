/**
 * @file test_lingofuse_capi.c
 * @brief Small functional test for the C ABI layer (LingoFuse.h / LingoFuse.c).
 *
 * Scope
 * -----
 * This suite is deliberately NARROW and OFFLINE. It exercises only the
 * parts of the C ABI that can be exercised without bringing up a network
 * endpoint:
 *
 *     - library loading and symbol resolution
 *     - data handle creation, destruction, and scalar I/O
 *     - string helpers (NUL-framed and raw byte variants)
 *     - UID helpers (LF_WriteUid / LF_ReadUid) and the 32-byte struct
 *       by-value ABI at the ARGUMENT position
 *     - the LF_Get_P2P_UID RETURN-role pointer type and its documented
 *       zero-fill behaviour for a self-created handle (see the
 *       "SIDE-DATA SEMANTICS" section below)
 *     - the LF_Get_P2P_Name empty-string behaviour for a self-created
 *       handle
 *     - app registration and local (in-process) invocation
 *     - status queue basic callability
 *
 * The full RAII / network test suite lives in test_lingofuse.cpp and
 * test_lingofuse_json.cpp. This file is the C-side complement: it
 * verifies that LingoFuse.h is a clean C header and that LingoFuse.c
 * forwards the ABI correctly.
 *
 * ============================================================================
 * SIDE-DATA SEMANTICS OF LF_Get_P2P_UID / LF_Get_P2P_Name
 * ============================================================================
 * The two identity accessors read the "side data" that the SENDER'S
 * transport layer writes into every request payload before transmission.
 * They are NOT properties of the handle itself:
 *
 *     VALID    -- the `input` argument of a registered Call / Notify
 *                 callback, or the input of a local call.
 *     INVALID  -- an OUTPUT handle, or a caller-created handle.
 *
 * The full end-to-end verification of the sender-side injection path
 * lives in test_lingofuse_uid.c, which brings up a real (local) client
 * and reads the identity from a real callback. This file only checks the
 * ABI-shape consequences that are observable offline:
 *
 *     - The RETURN type of LF_Get_P2P_UID is a pointer. The check is
 *       simple: we can dereference it. If the typedef were still the
 *       by-value struct, `LF_Get_P2P_UID(h)->bytes[0]` would not even
 *       compile.
 *
 *     - For a self-created handle (no "sender"), the library documents
 *       that the function returns a pointer to a zero-filled UID. The
 *       C wrapper forwards this pointer unchanged; it does NOT return
 *       NULL in that case. This is a concrete, offline-verifiable
 *       consequence of the side-data contract.
 *
 *     - For a self-created handle, LF_Get_P2P_Name returns an empty
 *       string, not NULL.
 *
 * Deliberately NOT tested here
 * ----------------------------
 *     - LF_PrepareService / LF_PrepareClient / LF_PrepareDone.
 *       Requires an IPC endpoint and is covered by the C++ suite and
 *       by test_lingofuse_uid.c.
 *
 *     - LF_FreeLibrary followed by LF_LoadLibrary.
 *       Reloading would ZERO every static function pointer, which makes
 *       every subsequent test in this file order-dependent. Left out on
 *       purpose; the C++ suite exercises the loader path from a fresh
 *       process.
 *
 * All output is English.
 */

#if defined(_WIN32) && !defined(_CRT_SECURE_NO_WARNINGS)
#  define _CRT_SECURE_NO_WARNINGS
#endif

#include "LingoFuse.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

 /* ============================================================================
  *  Tiny assertion framework
  * ============================================================================ */

static int g_tests_run = 0;
static int g_tests_passed = 0;
static int g_tests_failed = 0;
static int g_current_ok = 1;

static void section_header(const char* title) {
    printf("\n\n");
    printf("======================================================================\n");
    printf("  %s\n", title);
    printf("======================================================================\n");
}

static void begin_test(const char* name) {
    g_current_ok = 1;
    printf("\n[ %s ]\n", name);
}

static void end_test(void) {
    ++g_tests_run;
    if (g_current_ok) {
        ++g_tests_passed;
        printf("[ PASS ]\n");
    }
    else {
        ++g_tests_failed;
        printf("[ FAIL ]\n");
    }
}

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            printf("    [CHECK FAILED] %s  (line %d)\n", #cond, __LINE__); \
            g_current_ok = 0;                                              \
        }                                                                  \
    } while (0)

#define CHECK_EQ(actual, expected)                                         \
    do {                                                                   \
        long long _a = (long long)(actual);                                \
        long long _e = (long long)(expected);                              \
        if (_a != _e) {                                                    \
            printf("    [CHECK_EQ FAILED] %s == %s  (line %d)\n",          \
                   #actual, #expected, __LINE__);                          \
            printf("        actual   = %lld\n", _a);                       \
            printf("        expected = %lld\n", _e);                       \
            g_current_ok = 0;                                              \
        }                                                                  \
    } while (0)

/* ============================================================================
 *  Test callbacks
 * ============================================================================ */

static void LF_CDECL cb_add(void* trigger, void* input, void* output) {
    int32_t a = 0;
    int32_t b = 0;
    (void)trigger;
    if (!LF_ReadInt32((TDataHnd)input, &a)) return;
    if (!LF_ReadInt32((TDataHnd)input, &b)) return;
    LF_WriteInt32((TDataHnd)output, a + b);
}

static void LF_CDECL cb_sink(void* trigger, void* input) {
    (void)trigger;
    (void)input;
    /* Intentionally empty. Only used to prove Notify registration works. */
}

/* ============================================================================
 *  UID helper (used to build deterministic test values)
 * ============================================================================ */

static TP2P_UID make_uid(uint8_t seed) {
    TP2P_UID u;
    int i;
    for (i = 0; i < 32; ++i) {
        u.bytes[i] = (uint8_t)(seed + (uint8_t)i);
    }
    return u;
}

static int uid_is_all_zero(const TP2P_UID* u) {
    int i;
    for (i = 0; i < 32; ++i) {
        if (u->bytes[i] != 0) return 0;
    }
    return 1;
}

/* ============================================================================
 *  Section 1: Library loading and symbol resolution
 * ============================================================================ */

static void test_loader_first_load(void) {
    begin_test("Loader :: LF_LoadLibrary returns 1");
    CHECK_EQ(LF_LoadLibrary(), 1);
    end_test();
}

static void test_loader_second_load_is_idempotent(void) {
    begin_test("Loader :: second LF_LoadLibrary is a no-op returning 1");
    CHECK_EQ(LF_LoadLibrary(), 1);
    CHECK_EQ(LF_LoadLibrary(), 1);
    end_test();
}

/* ============================================================================
 *  Section 2: Data handle creation, destruction, scalar I/O
 * ============================================================================ */

static void test_handle_create_free(void) {
    TDataHnd h;
    begin_test("Handle :: create / free an auto-recycled handle");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);
    CHECK_EQ(LF_GetSize(h), 0);
    CHECK_EQ(LF_GetPos(h), 0);
    LF_FreeData(h);
    end_test();
}

static void test_handle_create_permanent(void) {
    TDataHnd h;
    begin_test("Handle :: create / free a permanent handle");
    h = LF_CreateData_Permanent("test_api");
    CHECK(h != NULL);
    CHECK_EQ(LF_GetSize(h), 0);
    LF_FreeData(h);
    end_test();
}

static void test_handle_free_null_is_safe(void) {
    begin_test("Handle :: LF_FreeData(NULL) is safe");
    LF_FreeData(NULL);   /* must not crash */
    end_test();
}

static void test_handle_create_null_name_returns_null(void) {
    begin_test("Handle :: LF_CreateData(NULL) returns NULL");
    /* The C wrapper prints a diagnostic to stderr, then returns NULL.
       That diagnostic is expected output, not a test failure. */
    CHECK(LF_CreateData(NULL) == NULL);
    end_test();
}

static void test_handle_scalar_io(void) {
    TDataHnd h;
    int32_t  i32_out = 0;
    int64_t  i64_out = 0;
    double   d_out = 0.0;
    uint16_t u16_out = 0;

    begin_test("Handle :: scalar write / read round-trip");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    CHECK_EQ(LF_WriteInt32(h, -123456789), 1);
    CHECK_EQ(LF_WriteUInt16(h, 65535), 1);
    CHECK_EQ(LF_WriteInt64(h, (int64_t)-9876543210LL), 1);
    CHECK_EQ(LF_WriteDouble(h, 3.141592653589793), 1);

    CHECK_EQ(LF_GetSize(h), 4 + 2 + 8 + 8);
    CHECK_EQ(LF_GetPos(h), 4 + 2 + 8 + 8);

    LF_SetPos(h, 0);
    CHECK_EQ(LF_GetPos(h), 0);

    CHECK_EQ(LF_ReadInt32(h, &i32_out), 1);
    CHECK_EQ(i32_out, -123456789);

    CHECK_EQ(LF_ReadUInt16(h, &u16_out), 1);
    CHECK_EQ(u16_out, 65535);

    CHECK_EQ(LF_ReadInt64(h, &i64_out), 1);
    CHECK_EQ(i64_out, -9876543210LL);

    CHECK_EQ(LF_ReadDouble(h, &d_out), 1);
    /* Doubles round-trip bit-exactly on the same platform */
    CHECK(d_out == 3.141592653589793);

    CHECK_EQ(LF_GetPos(h), LF_GetSize(h));
    LF_FreeData(h);
    end_test();
}

static void test_handle_set_size(void) {
    TDataHnd h;
    begin_test("Handle :: LF_SetSize resizes the buffer");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);
    CHECK_EQ(LF_GetSize(h), 0);
    LF_SetSize(h, 128);
    CHECK_EQ(LF_GetSize(h), 128);
    LF_FreeData(h);
    end_test();
}

static void test_handle_get_buffer_offset(void) {
    TDataHnd h;
    void* base;
    void* offset;
    begin_test("Handle :: LF_GetBufferOffset returns base + offset");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);
    LF_WriteInt32(h, 42);
    base = LF_GetBufferOffset(h, 0);
    offset = LF_GetBufferOffset(h, 2);
    CHECK(base != NULL);
    CHECK(offset != NULL);
    CHECK((char*)offset == (char*)base + 2);
    LF_FreeData(h);
    end_test();
}

/* ============================================================================
 *  Section 3: String helpers
 * ============================================================================ */

static void test_string_round_trip(void) {
    TDataHnd h;
    char buf[64];
    begin_test("String :: LF_WriteString / LF_ReadString round-trip");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    CHECK_EQ(LF_WriteString(h, "hello"), 1);
    /* "hello" is 5 bytes + 1 NUL = 6 */
    CHECK_EQ(LF_GetSize(h), 6);

    LF_SetPos(h, 0);
    memset(buf, 0, sizeof(buf));
    CHECK_EQ(LF_ReadString(h, buf, sizeof(buf)), 1);
    CHECK(strcmp(buf, "hello") == 0);
    /* Cursor must be past the NUL */
    CHECK_EQ(LF_GetPos(h), 6);

    LF_FreeData(h);
    end_test();
}

static void test_string_empty(void) {
    TDataHnd h;
    char buf[8];
    begin_test("String :: empty string writes exactly one NUL");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    CHECK_EQ(LF_WriteString(h, ""), 1);
    CHECK_EQ(LF_GetSize(h), 1);

    LF_SetPos(h, 0);
    memset(buf, 0xFF, sizeof(buf));
    CHECK_EQ(LF_ReadString(h, buf, sizeof(buf)), 1);
    CHECK(strcmp(buf, "") == 0);
    CHECK_EQ(LF_GetPos(h), 1);

    LF_FreeData(h);
    end_test();
}

static void test_string_utf8_multibyte(void) {
    /* 4-byte emoji, encoded as an explicit byte sequence to avoid
       any dependence on the source file's encoding. */
    static const char utf8_globe[] = {
        (char)0xF0, (char)0x9F, (char)0x8C, (char)0x8D, '\0'
    };
    TDataHnd h;
    char buf[16];
    begin_test("String :: UTF-8 multibyte round-trip");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    CHECK_EQ(LF_WriteString(h, utf8_globe), 1);
    CHECK_EQ(LF_GetSize(h), 5);   /* 4 UTF-8 bytes + NUL */

    LF_SetPos(h, 0);
    memset(buf, 0, sizeof(buf));
    CHECK_EQ(LF_ReadString(h, buf, sizeof(buf)), 1);
    CHECK(memcmp(buf, utf8_globe, 5) == 0);

    LF_FreeData(h);
    end_test();
}

static void test_string_null_is_error(void) {
    TDataHnd h;
    begin_test("String :: LF_WriteString(NULL) returns 0 and writes nothing");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);
    CHECK_EQ(LF_WriteString(h, NULL), 0);
    CHECK_EQ(LF_GetSize(h), 0);
    LF_FreeData(h);
    end_test();
}

static void test_string_fault_tolerant_no_nul(void) {
    /* When no NUL is present, LF_ReadString must consume the entire
       remaining buffer and move the cursor to (size + 1). */
    static const char raw[] = { 'a', 'b', 'c', 'd' };
    TDataHnd h;
    char buf[16];
    begin_test("String :: fault-tolerant read when no NUL is present");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    CHECK_EQ(LF_WriteBuffer(h, raw, 4), 4);
    CHECK_EQ(LF_GetSize(h), 4);

    LF_SetPos(h, 0);
    memset(buf, 0, sizeof(buf));
    CHECK_EQ(LF_ReadString(h, buf, sizeof(buf)), 1);
    CHECK(strcmp(buf, "abcd") == 0);
    /* Cursor advanced one past the end of the buffer */
    CHECK_EQ(LF_GetPos(h), 5);

    LF_FreeData(h);
    end_test();
}

static void test_string_too_small_buffer(void) {
    TDataHnd h;
    char small[4];
    char big[32];
    begin_test("String :: too-small destination is rejected without moving cursor");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    CHECK_EQ(LF_WriteString(h, "hello world"), 1);
    LF_SetPos(h, 0);

    memset(small, 0, sizeof(small));
    /* 11 bytes + NUL = 12 > 4, so must return 0 and not move the cursor. */
    CHECK_EQ(LF_ReadString(h, small, sizeof(small)), 0);
    CHECK_EQ(LF_GetPos(h), 0);

    memset(big, 0, sizeof(big));
    CHECK_EQ(LF_ReadString(h, big, sizeof(big)), 1);
    CHECK(strcmp(big, "hello world") == 0);

    LF_FreeData(h);
    end_test();
}

static void test_string_cursor_at_end(void) {
    TDataHnd h;
    char buf[8];
    begin_test("String :: read at end of buffer returns 0");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    /* Empty buffer: cursor is at position 0 == size, so read fails. */
    CHECK_EQ(LF_ReadString(h, buf, sizeof(buf)), 0);

    LF_FreeData(h);
    end_test();
}

static void test_string_bytes_round_trip(void) {
    /* LF_WriteStringBytes / LF_ReadStringBytes: raw byte sequences,
       embedded NUL bytes are preserved by the writer. The reader stops
       at the first NUL, matching the Pascal and Python behaviour. */
    static const uint8_t payload[] = { 'a', 0, 'b', 0, 'c' };
    TDataHnd h;
    uint8_t buf[16];
    begin_test("StringBytes :: raw byte round-trip with embedded NUL");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    CHECK_EQ(LF_WriteStringBytes(h, payload, 5), 1);
    CHECK_EQ(LF_GetSize(h), 6);   /* 5 payload bytes + 1 terminator */

    LF_SetPos(h, 0);
    memset(buf, 0xFF, sizeof(buf));
    /* The reader stops at the first NUL, so only "a" is returned. */
    CHECK_EQ(LF_ReadStringBytes(h, buf, sizeof(buf)), 1);
    CHECK_EQ(buf[0], (uint8_t)'a');
    /* Cursor is one past the first NUL */
    CHECK_EQ(LF_GetPos(h), 2);

    LF_FreeData(h);
    end_test();
}

/* ============================================================================
 *  Section 4: UID helpers, struct-by-value ABI, and side-data accessors
 * ============================================================================
 *
 * This section has TWO distinct parts:
 *
 *   Part A -- ARGUMENT-role ABI (LF_WriteUid / LF_ReadUid).
 *
 *     `TP2P_UID` is passed and received by value (a 32-byte struct).
 *     `sizeof(TP2P_UID) == 32` and the fixed-length round-trip has no
 *     terminator. This is the argument-role representation.
 *
 *   Part B -- RETURN-role ABI (LF_Get_P2P_UID).
 *
 *     The function returns a POINTER to a 32-byte UID, not the value.
 *     The type is `const TP2P_UID*`. Two offline-observable facts are
 *     checked here:
 *
 *       1. The return type is a pointer (the code dereferences it; if
 *          the typedef were still the by-value struct, this would not
 *          compile).
 *
 *       2. For a self-created handle (i.e. no "sender"), the library
 *          returns a pointer to a ZERO-FILLED UID, NOT NULL. This is
 *          the documented side-data contract for non-input handles.
 *
 *     The full sender-injection path (which requires a real client and
 *     a real callback) is exercised by test_lingofuse_uid.c.
 *
 *   Part C -- LF_Get_P2P_Name for a self-created handle.
 *
 *     Same side-data rule as above: empty string, NOT NULL.
 */

 /* ---- Part A: ARGUMENT-role UID helpers ---------------------------------- */

static void test_uid_struct_size_is_32(void) {
    begin_test("UID :: sizeof(TP2P_UID) == 32 (ARGUMENT role)");
    CHECK_EQ((int)sizeof(TP2P_UID), 32);
    end_test();
}

static void test_uid_write_read_round_trip(void) {
    TP2P_UID in_uid;
    TP2P_UID out_uid;
    TDataHnd h;

    begin_test("UID :: LF_WriteUid / LF_ReadUid round-trip (ARGUMENT role)");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    in_uid = make_uid(0x10);
    CHECK_EQ(LF_WriteUid(h, in_uid), 1);
    /* A 32-byte UID write must produce exactly 32 bytes, no terminator. */
    CHECK_EQ(LF_GetSize(h), 32);

    LF_SetPos(h, 0);
    memset(&out_uid, 0, sizeof(out_uid));
    CHECK_EQ(LF_ReadUid(h, &out_uid), 1);
    CHECK(memcmp(in_uid.bytes, out_uid.bytes, 32) == 0);
    CHECK_EQ(LF_GetPos(h), 32);

    LF_FreeData(h);
    end_test();
}

static void test_uid_sequential_writes(void) {
    /* Two UIDs written back-to-back must read back in the same order. */
    TP2P_UID u1;
    TP2P_UID u2;
    TP2P_UID r1;
    TP2P_UID r2;
    TDataHnd h;

    begin_test("UID :: two sequential UIDs read back in order (ARGUMENT role)");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    u1 = make_uid(0x00);
    u2 = make_uid(0x80);

    CHECK_EQ(LF_WriteUid(h, u1), 1);
    CHECK_EQ(LF_WriteUid(h, u2), 1);
    CHECK_EQ(LF_GetSize(h), 64);

    LF_SetPos(h, 0);
    memset(&r1, 0, sizeof(r1));
    memset(&r2, 0, sizeof(r2));
    CHECK_EQ(LF_ReadUid(h, &r1), 1);
    CHECK_EQ(LF_ReadUid(h, &r2), 1);

    CHECK(memcmp(u1.bytes, r1.bytes, 32) == 0);
    CHECK(memcmp(u2.bytes, r2.bytes, 32) == 0);

    LF_FreeData(h);
    end_test();
}

static void test_uid_read_null_out(void) {
    TDataHnd h;
    begin_test("UID :: LF_ReadUid(NULL out) returns 0 (ARGUMENT role)");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);
    {
        TP2P_UID u = make_uid(0x00);
        CHECK_EQ(LF_WriteUid(h, u), 1);
    }
    LF_SetPos(h, 0);
    CHECK_EQ(LF_ReadUid(h, NULL), 0);
    LF_FreeData(h);
    end_test();
}

static void test_uid_read_insufficient_bytes(void) {
    TP2P_UID out;
    TDataHnd h;
    begin_test("UID :: LF_ReadUid with < 32 bytes available returns 0 (ARGUMENT role)");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);
    {
        uint8_t partial[16];
        memset(partial, 0xAA, sizeof(partial));
        CHECK_EQ(LF_WriteBuffer(h, partial, 16), 16);
    }
    LF_SetPos(h, 0);
    memset(&out, 0, sizeof(out));
    CHECK_EQ(LF_ReadUid(h, &out), 0);
    LF_FreeData(h);
    end_test();
}

/* ---- Part B: RETURN-role UID accessor ----------------------------------- */

static void test_uid_get_p2p_uid_returns_pointer_type(void) {
    /*
     * The only "type check" that is possible at compile time: the
     * return value must be dereferenceable as a `TP2P_UID`. If the
     * typedef in LingoFuse.h were still the by-value struct, then
     * `LF_Get_P2P_UID(h)->bytes[0]` would not compile.
     *
     * This test therefore does NOT assert a specific value: it only
     * proves that the C compiler accepted the pointer form. Any
     * subsequent assertion about the contents is done in the
     * dedicated side-data test below.
     */
    TDataHnd h;
    const TP2P_UID* uid_ptr;

    begin_test("UID :: LF_Get_P2P_UID return type is a pointer (RETURN role)");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    uid_ptr = LF_Get_P2P_UID(h);

    /*
     * For a self-created handle, the library documents that it
     * returns a pointer to a zero-filled UID (the DLL emits a warning
     * on the C side). It does NOT return NULL in this case.
     *
     * A NULL here would be a load-order failure, which is not the
     * situation under test (Section 1 already loaded the library).
     */
    CHECK(uid_ptr != NULL);

    /*
     * Dereference to prove the pointer type compiles and to observe
     * the documented zero-fill value. Reading the field through the
     * pointer is exactly what a real caller would do.
     */
    if (uid_ptr != NULL) {
        CHECK(uid_ptr->bytes[0] == 0);
        CHECK(uid_is_all_zero(uid_ptr));
    }

    LF_FreeData(h);
    end_test();
}

static void test_uid_get_p2p_uid_zero_for_self_created_handle(void) {
    /*
     * Concrete side-data consequence, verified offline:
     *
     *   A handle the caller created itself has no "sender", so there
     *   is no FromUID side data to report. The library returns a
     *   pointer to a zero-filled UID.
     *
     * This is not a defect. It is the documented, expected behaviour
     * for this handle class and it is what a real caller will observe
     * if it (incorrectly) calls LF_Get_P2P_UID outside a callback.
     */
    TDataHnd h;
    const TP2P_UID* uid_ptr;

    begin_test("UID :: LF_Get_P2P_UID returns zero-filled UID for self-created handle");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    /* Write some payload, to prove that the zero-fill is independent
       of the handle's own contents. */
    CHECK_EQ(LF_WriteString(h, "some payload"), 1);
    LF_SetPos(h, 0);

    uid_ptr = LF_Get_P2P_UID(h);
    CHECK(uid_ptr != NULL);
    if (uid_ptr != NULL) {
        CHECK(uid_is_all_zero(uid_ptr));
    }

    LF_FreeData(h);
    end_test();
}

/* ---- Part C: RETURN-role P2P name accessor ------------------------------ */

static void test_uid_get_p2p_name_empty_for_self_created_handle(void) {
    /*
     * Same side-data rule as LF_Get_P2P_UID: a self-created handle has
     * no "sender", so the sender's P2P name is not available and the
     * library returns an EMPTY string, NOT NULL.
     */
    TDataHnd h;
    const char* name;

    begin_test("UID :: LF_Get_P2P_Name returns empty string for self-created handle");
    h = LF_CreateData("test_api");
    CHECK(h != NULL);

    name = LF_Get_P2P_Name(h);
    CHECK(name != NULL);
    if (name != NULL) {
        CHECK_EQ((int)strlen(name), 0);
        CHECK_EQ(name[0], '\0');
    }

    LF_FreeData(h);
    end_test();
}

/* ============================================================================
 *  Section 5: App registration and local invocation
 * ============================================================================ */

static void test_app_create_free(void) {
    TAppHnd app;
    begin_test("App :: LF_CreateApp / LF_FreeApp");
    app = LF_CreateApp("test_capi_app", "C API test application");
    CHECK(app != NULL);
    LF_FreeApp(app);
    end_test();
}

static void test_app_create_null_name(void) {
    begin_test("App :: LF_CreateApp(NULL) returns NULL");
    CHECK(LF_CreateApp(NULL, "desc") == NULL);
    end_test();
}

static void test_app_local_call(void) {
    TAppHnd app;
    TDataHnd param;
    TDataHnd result;
    int32_t  sum = 0;

    begin_test("App :: register Call + LF_LocalCall round-trip");
    app = LF_CreateApp("test_capi_localcall", "local call test");
    CHECK(app != NULL);

    CHECK_EQ(LF_RegisterCall(app, "add", "add two int32", NULL, cb_add), 1);

    param = LF_CreateData("add");
    CHECK(param != NULL);
    CHECK_EQ(LF_WriteInt32(param, 10), 1);
    CHECK_EQ(LF_WriteInt32(param, 32), 1);
    LF_SetPos(param, 0);

    result = LF_LocalCall(app, param);
    CHECK(result != NULL);
    CHECK_EQ(LF_GetSize(result), 4);
    CHECK_EQ(LF_ReadInt32(result, &sum), 1);
    CHECK_EQ(sum, 42);

    LF_FreeData(param);
    LF_FreeData(result);
    LF_FreeApp(app);
    end_test();
}

static void test_app_local_call_unregistered_api(void) {
    TAppHnd app;
    TDataHnd param;
    TDataHnd result;

    begin_test("App :: LF_LocalCall on unregistered API returns size-0 handle");
    app = LF_CreateApp("test_capi_missing", "missing API test");
    CHECK(app != NULL);

    param = LF_CreateData("no_such_api");
    CHECK(param != NULL);
    LF_WriteInt32(param, 1);
    LF_SetPos(param, 0);

    result = LF_LocalCall(app, param);
    /* The underlying library returns a valid handle with size 0; the
       library prints a diagnostic to the status queue. */
    CHECK(result != NULL);
    CHECK_EQ(LF_GetSize(result), 0);

    LF_FreeData(param);
    LF_FreeData(result);
    LF_FreeApp(app);
    end_test();
}

static void test_app_local_notify(void) {
    TAppHnd app;
    TDataHnd param;

    begin_test("App :: register Notify + LF_LocalNotify");
    app = LF_CreateApp("test_capi_notify", "notify test");
    CHECK(app != NULL);

    CHECK_EQ(LF_RegisterNotify(app, "sink", "notify sink", NULL, cb_sink), 1);

    param = LF_CreateData("sink");
    CHECK(param != NULL);
    LF_WriteString(param, "payload");
    LF_SetPos(param, 0);

    /* Must not crash. Notify is fire-and-forget. */
    LF_LocalNotify(app, param);

    LF_FreeData(param);
    LF_FreeApp(app);
    end_test();
}

static void test_app_duplicate_registration(void) {
    TAppHnd app;
    begin_test("App :: duplicate API registration returns 0");
    app = LF_CreateApp("test_capi_dup", "duplicate test");
    CHECK(app != NULL);

    CHECK_EQ(LF_RegisterCall(app, "same", "first", NULL, cb_add), 1);
    CHECK_EQ(LF_RegisterCall(app, "same", "second", NULL, cb_add), 0);

    LF_FreeApp(app);
    end_test();
}

static void test_app_unregister(void) {
    TAppHnd app;
    begin_test("App :: LF_Unregister removes the API");
    app = LF_CreateApp("test_capi_unreg", "unregister test");
    CHECK(app != NULL);

    CHECK_EQ(LF_RegisterCall(app, "temp", "temp", NULL, cb_add), 1);
    CHECK_EQ(LF_Unregister(app, "temp"), 1);
    /* Second unregister must fail. */
    CHECK_EQ(LF_Unregister(app, "temp"), 0);

    LF_FreeApp(app);
    end_test();
}

static void test_app_get_name(void) {
    TAppHnd app;
    const char* name;
    begin_test("App :: LF_Get_AppName returns the registered name");
    app = LF_CreateApp("test_capi_getname", "getname test");
    CHECK(app != NULL);

    name = LF_Get_AppName(app);
    CHECK(name != NULL);
    CHECK(strcmp(name, "test_capi_getname") == 0);

    LF_FreeApp(app);
    end_test();
}

/* ============================================================================
 *  Section 6: Status queue (basic, no main thread required)
 * ============================================================================ */

static void test_status_count_callable(void) {
    begin_test("Status :: LF_GetStatusCount is callable before PrepareDone");
    /* Before LF_PrepareDone the queue may be empty; the point of the test
       is that the call does not crash and returns a non-negative value. */
    CHECK(LF_GetStatusCount() >= 0);
    end_test();
}

/* ============================================================================
 *  main
 * ============================================================================ */

int main(void) {
    printf("======================================================================\n");
    printf("  LingoFuse C ABI Test Suite\n");
    printf("======================================================================\n");
    printf("  Purpose : exercise the pure C ABI (LingoFuse.h / LingoFuse.c)\n");
    printf("  Scope   : offline -- no network endpoint is required\n");
    printf("\n");
    printf("  This suite covers the two UID roles separately:\n");
    printf("    - ARGUMENT role (LF_WriteUid / LF_ReadUid): struct by value\n");
    printf("    - RETURN   role (LF_Get_P2P_UID): pointer, side-data semantics\n");
    printf("\n");
    printf("  The full sender-injection path (client + callback) is covered\n");
    printf("  by test_lingofuse_uid.c, which brings up a real local mesh.\n");

    /* Load the library once. Every subsequent test assumes it is loaded. */
    section_header("Section 1: Library loading");
    test_loader_first_load();
    test_loader_second_load_is_idempotent();

    section_header("Section 2: Data handle");
    test_handle_create_free();
    test_handle_create_permanent();
    test_handle_free_null_is_safe();
    test_handle_create_null_name_returns_null();
    test_handle_scalar_io();
    test_handle_set_size();
    test_handle_get_buffer_offset();

    section_header("Section 3: String helpers");
    test_string_round_trip();
    test_string_empty();
    test_string_utf8_multibyte();
    test_string_null_is_error();
    test_string_fault_tolerant_no_nul();
    test_string_too_small_buffer();
    test_string_cursor_at_end();
    test_string_bytes_round_trip();

    section_header("Section 4: UID helpers and side-data accessor ABI");
    printf("  Part A -- ARGUMENT role (struct by value)\n");
    test_uid_struct_size_is_32();
    test_uid_write_read_round_trip();
    test_uid_sequential_writes();
    test_uid_read_null_out();
    test_uid_read_insufficient_bytes();
    printf("\n  Part B -- RETURN role (pointer) and side-data zero-fill\n");
    test_uid_get_p2p_uid_returns_pointer_type();
    test_uid_get_p2p_uid_zero_for_self_created_handle();
    printf("\n  Part C -- RETURN-role P2P name for self-created handle\n");
    test_uid_get_p2p_name_empty_for_self_created_handle();

    section_header("Section 5: App and local invocation");
    test_app_create_free();
    test_app_create_null_name();
    test_app_local_call();
    test_app_local_call_unregistered_api();
    test_app_local_notify();
    test_app_duplicate_registration();
    test_app_unregister();
    test_app_get_name();

    section_header("Section 6: Status queue");
    test_status_count_callable();

    /* ---- Final summary ------------------------------------------------ */
    printf("\n\n");
    printf("======================================================================\n");
    printf("  Summary\n");
    printf("======================================================================\n");
    printf("  Tests run    : %d\n", g_tests_run);
    printf("  Tests passed : %d\n", g_tests_passed);
    printf("  Tests failed : %d\n", g_tests_failed);
    if (g_tests_failed == 0) {
        printf("\n  RESULT: ALL TESTS PASSED\n");
    }
    else {
        printf("\n  RESULT: %d TEST(S) FAILED\n", g_tests_failed);
    }
    printf("======================================================================\n");

    /* The library is intentionally NOT unloaded here. LF_FreeLibrary would
       ZERO every static function pointer, and a follow-on test run in the
       same process would then need to call LF_LoadLibrary again. For a
       single-shot test program the operating system reclaims everything
       at process exit. */

    return (g_tests_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}