/**
 * @file test_lf_fortran.c
 * @brief Standalone C test for the lf_fortran.h C ABI.
 *
 * This test exercises the C ABI that Fortran will consume. It does
 * not depend on Fortran and can be compiled and run on its own. Its
 * purpose is to prove that the bridge works correctly before the
 * Fortran layer is added.
 *
 * ============================================================================
 * COVERED CONTRACTS
 * ============================================================================
 *
 *   Section 1 - Library load / unload
 *   Section 2 - Data handle scalar I/O (all integer / floating types)
 *   Section 3 - String and JSON I/O (UTF-8, NUL framing, empty strings)
 *   Section 4 - UID binary I/O and hex helpers
 *   Section 5 - P2P identity accessors (self-created handle contract)
 *   Section 6 - Local call round-trip and duplicate-registration rejection
 *   Section 7 - App unregister and process-wide P2P registration
 *   Section 8 - App name copy helper with buffer-too-small handling
 *   Section 9 - Options: generic accessors and typed shortcuts
 *   Section 10 - Query functions (offline behaviour)
 *   Section 11 - Async dispatch failure (framework starts, then shuts down)
 *
 * The test is written in portable C11 and uses only the standard
 * library plus the lf_fortran.h interface.
 *
 * All comments and status output are in English.
 */

#include "lf_fortran.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================================
 * Mini test framework
 * ============================================================================ */

static int g_passed = 0;
static int g_failed = 0;

#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "[FAIL] %s:%d: %s\n",                       \
                    __FILE__, __LINE__, #cond);                         \
            ++g_failed;                                                 \
        } else {                                                        \
            ++g_passed;                                                 \
        }                                                               \
    } while (0)

#define CHECK_EQ_INT(a, b)                                              \
    do {                                                                \
        const long long _a = (long long)(a);                            \
        const long long _b = (long long)(b);                            \
        if (_a != _b) {                                                 \
            fprintf(stderr,                                             \
                    "[FAIL] %s:%d: %s == %s (got %lld, expected %lld)\n", \
                    __FILE__, __LINE__, #a, #b, _a, _b);                \
            ++g_failed;                                                 \
        } else {                                                        \
            ++g_passed;                                                 \
        }                                                               \
    } while (0)

#define CHECK_STREQ(a, b)                                               \
    do {                                                                \
        const char* _a = (a);                                           \
        const char* _b = (b);                                           \
        if (!_a || !_b || strcmp(_a, _b) != 0) {                        \
            fprintf(stderr,                                             \
                    "[FAIL] %s:%d: %s == %s (got \"%s\", expected \"%s\")\n", \
                    __FILE__, __LINE__, #a, #b,                         \
                    _a ? _a : "(null)", _b ? _b : "(null)");            \
            ++g_failed;                                                 \
        } else {                                                        \
            ++g_passed;                                                 \
        }                                                               \
    } while (0)

#define CHECK_MEMEQ(a, b, n)                                            \
    do {                                                                \
        if (memcmp((a), (b), (n)) != 0) {                               \
            fprintf(stderr, "[FAIL] %s:%d: memcmp(%s, %s, %d) != 0\n",  \
                    __FILE__, __LINE__, #a, #b, (int)(n));              \
            ++g_failed;                                                 \
        } else {                                                        \
            ++g_passed;                                                 \
        }                                                               \
    } while (0)

#define TEST_SECTION(name)                                              \
    printf("\n=== %s ===\n", (name))

/* ============================================================================
 * Test callbacks
 *
 * These are plain C functions with the exact signatures declared in
 * lf_fortran.h. The Fortran test will declare equivalent `bind(C)`
 * procedures.
 * ============================================================================ */

/* add(int32 a, int32 b) -> int32 */
static void add_callback(void* input, void* output) {
    int32_t a = 0, b = 0, sum = 0;
    if (lf_data_read_int32(input, &a) != 1) return;
    if (lf_data_read_int32(input, &b) != 1) return;
    sum = a + b;
    lf_data_write_int32(output, sum);
}

/* log(string) -> (void); records the last payload for inspection. */
static char g_last_notify[512] = { 0 };

static void log_callback(void* input) {
    char buf[512];
    int64_t n = lf_data_read_string(input, buf, (int64_t)sizeof(buf));
    if (n < 0) return;
    buf[n] = '\0';

    /* Bounded copy that never triggers -Wstringop-truncation. */
    size_t copy_len = strlen(buf);
    if (copy_len >= sizeof(g_last_notify)) {
        copy_len = sizeof(g_last_notify) - 1;
    }
    memcpy(g_last_notify, buf, copy_len);
    g_last_notify[copy_len] = '\0';
}

/* Async callback state. Used by the dispatch-failure test. */
static int   g_async_cb_count = 0;
static void* g_async_cb_last_result = (void*)1;

static void async_test_callback(void* user_data, void* result_handle) {
    (void)user_data;
    ++g_async_cb_count;
    g_async_cb_last_result = result_handle;
}

/* ============================================================================
 * Section 1: Data handle scalar I/O
 * ============================================================================ */

static void test_data_handle_scalars(void) {
    TEST_SECTION("DataHandle scalar round-trip");

    LfDataHandle h = lf_data_create("scalar_test");
    CHECK(h != NULL);

    CHECK_EQ_INT(lf_data_write_int8(h, -128), 1);
    CHECK_EQ_INT(lf_data_write_int16(h, -32768), 1);
    CHECK_EQ_INT(lf_data_write_int32(h, -123456789), 1);
    CHECK_EQ_INT(lf_data_write_int64(h, -9876543210LL), 1);

    CHECK_EQ_INT(lf_data_write_uint8(h, 255), 1);
    CHECK_EQ_INT(lf_data_write_uint16(h, 65535), 1);
    CHECK_EQ_INT(lf_data_write_uint32(h, 0xDEADBEEFu), 1);
    CHECK_EQ_INT(lf_data_write_uint64(h, 0x123456789ABCDEF0ULL), 1);

    CHECK_EQ_INT(lf_data_write_float32(h, 3.14f), 1);
    CHECK_EQ_INT(lf_data_write_float64(h, 2.718281828), 1);

    lf_data_set_position(h, 0);

    int8_t   i8  = 0;
    int16_t  i16 = 0;
    int32_t  i32 = 0;
    int64_t  i64 = 0;
    uint8_t  u8  = 0;
    uint16_t u16 = 0;
    uint32_t u32 = 0;
    uint64_t u64 = 0;
    float    f32 = 0.0f;
    double   f64 = 0.0;

    CHECK_EQ_INT(lf_data_read_int8(h, &i8), 1);    CHECK_EQ_INT(i8, -128);
    CHECK_EQ_INT(lf_data_read_int16(h, &i16), 1);  CHECK_EQ_INT(i16, -32768);
    CHECK_EQ_INT(lf_data_read_int32(h, &i32), 1);  CHECK_EQ_INT(i32, -123456789);
    CHECK_EQ_INT(lf_data_read_int64(h, &i64), 1);  CHECK_EQ_INT(i64, -9876543210LL);
    CHECK_EQ_INT(lf_data_read_uint8(h, &u8), 1);   CHECK_EQ_INT(u8, 255);
    CHECK_EQ_INT(lf_data_read_uint16(h, &u16), 1); CHECK_EQ_INT(u16, 65535);
    CHECK_EQ_INT(lf_data_read_uint32(h, &u32), 1); CHECK_EQ_INT(u32, 0xDEADBEEFu);
    CHECK_EQ_INT(lf_data_read_uint64(h, &u64), 1); CHECK_EQ_INT(u64, 0x123456789ABCDEF0ULL);
    CHECK_EQ_INT(lf_data_read_float32(h, &f32), 1);
    CHECK_EQ_INT(lf_data_read_float64(h, &f64), 1);

    lf_data_destroy(h);
}

/* ============================================================================
 * Section 2: Data handle strings
 * ============================================================================ */

static void test_data_handle_strings(void) {
    TEST_SECTION("DataHandle string round-trip");

    LfDataHandle h = lf_data_create("string_test");
    CHECK(h != NULL);

    const char* text = "Hello, \xE4\xB8\x96\xE7\x95\x8C! \xF0\x9F\x8C\x8D";
    CHECK_EQ_INT(lf_data_write_string(h, text), 1);
    CHECK_EQ_INT(lf_data_get_size(h),
                 (int64_t)(strlen(text) + 1));

    lf_data_set_position(h, 0);

    char buf[256] = { 0 };
    int64_t n = lf_data_read_string(h, buf, (int64_t)sizeof(buf));
    CHECK_EQ_INT(n, (int64_t)strlen(text));
    CHECK_STREQ(buf, text);

    lf_data_destroy(h);
}

/* ============================================================================
 * Section 3: Data handle JSON
 * ============================================================================ */

static void test_data_handle_json(void) {
    TEST_SECTION("DataHandle JSON round-trip");

    LfDataHandle h = lf_data_create("json_test");
    CHECK(h != NULL);

    const char* json = "{\"a\":1,\"b\":\"\xE4\xB8\xAD\xE6\x96\x87\"}";
    CHECK_EQ_INT(lf_data_write_json(h, json), 1);

    lf_data_set_position(h, 0);

    char buf[256] = { 0 };
    int64_t n = lf_data_read_json(h, buf, (int64_t)sizeof(buf));
    CHECK_EQ_INT(n, (int64_t)strlen(json));
    CHECK_STREQ(buf, json);

    lf_data_destroy(h);
}

/* ============================================================================
 * Section 4: UID binary I/O
 * ============================================================================ */

static void test_data_handle_uid_io(void) {
    TEST_SECTION("DataHandle UID binary I/O");

    LfDataHandle h = lf_data_create("uid_test");
    CHECK(h != NULL);

    int8_t uid1[32];
    int8_t uid2[32];
    int8_t r1[32];
    int8_t r2[32];

    /* Deterministic byte patterns. */
    for (int i = 0; i < 32; ++i) {
        uid1[i] = (int8_t)(i + 0x10);
        uid2[i] = (int8_t)(0xFF - i);
    }

    /* ---- Two sequential writes ---- */
    CHECK_EQ_INT(lf_data_write_uid(h, uid1), 1);
    CHECK_EQ_INT(lf_data_write_uid(h, uid2), 1);
    CHECK_EQ_INT(lf_data_get_size(h), 64);
    CHECK_EQ_INT(lf_data_get_position(h), 64);

    /* ---- Read back in order ---- */
    lf_data_set_position(h, 0);
    memset(r1, 0, sizeof(r1));
    memset(r2, 0, sizeof(r2));
    CHECK_EQ_INT(lf_data_read_uid(h, r1), 1);
    CHECK_EQ_INT(lf_data_read_uid(h, r2), 1);

    CHECK_MEMEQ(uid1, r1, 32);
    CHECK_MEMEQ(uid2, r2, 32);
    CHECK_EQ_INT(lf_data_get_position(h), 64);

    /* ---- Insufficient bytes remaining ---- */
    lf_data_set_position(h, 48);   /* only 16 bytes left */
    int8_t r3[32];
    memset(r3, 0xAA, sizeof(r3));
    CHECK_EQ_INT(lf_data_read_uid(h, r3), 0);
    /* Output must be untouched on failure. */
    for (int i = 0; i < 32; ++i) {
        CHECK_EQ_INT(r3[i], (int8_t)0xAA);
    }

    /* ---- NULL argument rejection ---- */
    CHECK_EQ_INT(lf_data_write_uid(h, NULL), 0);
    CHECK_EQ_INT(lf_data_read_uid(h, NULL), 0);
    CHECK_EQ_INT(lf_data_write_uid(NULL, uid1), 0);
    CHECK_EQ_INT(lf_data_read_uid(NULL, r1), 0);

    lf_data_destroy(h);
}

/* ============================================================================
 * Section 4b: UID <-> hex helpers
 * ============================================================================ */

static void test_uid_hex_helpers(void) {
    TEST_SECTION("UID <-> hex helpers");

    int8_t uid[32];
    char   hex[65];
    char   upper[65];
    int8_t back[32];

    /* Deterministic bytes spanning the full 0x00..0xFF range. */
    for (int i = 0; i < 32; ++i) {
        uid[i] = (int8_t)(i * 7 + 0x10);
    }

    /* ---- UID -> hex ---- */
    CHECK_EQ_INT(lf_uid_to_hex(uid, hex), 1);
    CHECK_EQ_INT((int)strlen(hex), 64);
    /* Spot checks on the lowercase hex output. */
    CHECK(hex[0] == '1');   /* first byte = 0x10 -> '1','0' */
    CHECK(hex[1] == '0');

    /* ---- hex -> UID (lowercase) ---- */
    memset(back, 0, sizeof(back));
    CHECK_EQ_INT(lf_uid_from_hex(hex, back), 1);
    CHECK_MEMEQ(uid, back, 32);

    /* ---- hex -> UID (uppercase accepted) ---- */
    for (int i = 0; i < 64; ++i) {
        upper[i] = (hex[i] >= 'a' && hex[i] <= 'f')
                       ? (char)(hex[i] - 'a' + 'A')
                       : hex[i];
    }
    upper[64] = '\0';
    memset(back, 0, sizeof(back));
    CHECK_EQ_INT(lf_uid_from_hex(upper, back), 1);
    CHECK_MEMEQ(uid, back, 32);

    /* ---- Invalid hex is rejected and output is unchanged ---- */
    int8_t sentinel[32];
    memset(sentinel, 0xAA, sizeof(sentinel));
    const char* bad = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
                      "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
    CHECK_EQ_INT(lf_uid_from_hex(bad, sentinel), 0);
    for (int i = 0; i < 32; ++i) {
        CHECK_EQ_INT(sentinel[i], (int8_t)0xAA);
    }

    /* ---- NULL argument rejection ---- */
    CHECK_EQ_INT(lf_uid_to_hex(NULL, hex), 0);
    CHECK_EQ_INT(lf_uid_to_hex(uid, NULL), 0);
    CHECK_EQ_INT(lf_uid_from_hex(NULL, back), 0);
    CHECK_EQ_INT(lf_uid_from_hex(hex, NULL), 0);
}

/* ============================================================================
 * Section 5: P2P identity accessors (self-created handle)
 * ============================================================================
 *
 * A self-created handle has no "sender", so the framework's side-data
 * fields are empty. The library returns a zero-filled UID and an empty
 * P2P name. Our bridge faithfully forwards those values.
 *
 * The full sender-injection path (client + callback) is exercised by
 * the Fortran-side test in test_lf_fortran_f.f90 and by the
 * cross-language demo.
 */

static void test_p2p_identity_accessors(void) {
    TEST_SECTION("P2P identity accessors (self-created handle)");

    LfDataHandle h = lf_data_create("p2p_identity_test");
    CHECK(h != NULL);

    /* Write some payload to prove the zero-fill is independent of the
       handle's own contents. */
    CHECK_EQ_INT(lf_data_write_string(h, "some payload"), 1);

    /* ---- UID accessor: returns success, fills 32 zero bytes ---- */
    int8_t uid[32];
    memset(uid, 0xAA, sizeof(uid));
    CHECK_EQ_INT(lf_data_get_p2p_uid(h, uid), 1);
    for (int i = 0; i < 32; ++i) {
        CHECK_EQ_INT(uid[i], 0);
    }

    /* ---- Name accessor: returns 0 (successfully copied an empty
       string) and writes a NUL into the first byte. ---- */
    char name[128];
    memset(name, 0xAA, sizeof(name));
    int64_t rc = lf_data_get_p2p_name(h, name, (int64_t)sizeof(name));
    CHECK_EQ_INT(rc, 0);
    CHECK_EQ_INT((int)name[0], 0);

    /* ---- NULL handle is rejected ---- */
    CHECK_EQ_INT(lf_data_get_p2p_uid(NULL, uid), 0);
    CHECK_EQ_INT(lf_data_get_p2p_name(NULL, name, (int64_t)sizeof(name)), -1);

    /* ---- NULL / invalid buffers are rejected ---- */
    CHECK_EQ_INT(lf_data_get_p2p_uid(h, NULL), 0);
    CHECK_EQ_INT(lf_data_get_p2p_name(h, NULL, 128), -1);
    CHECK_EQ_INT(lf_data_get_p2p_name(h, name, 0), -1);

    lf_data_destroy(h);
}

/* ============================================================================
 * Section 6: Local call and duplicate registration
 * ============================================================================ */

static void test_local_call(void) {
    TEST_SECTION("Local call round-trip");

    LfAppHandle app = lf_app_create("TestCApp", "C bridge test");
    CHECK(app != NULL);

    CHECK_EQ_INT(
        lf_app_register_call(app, "add", "add two ints", &add_callback), 1);
    CHECK_EQ_INT(
        lf_app_register_notify(app, "log", "log a message", &log_callback), 1);

    /* ----- Call: add(5, 7) -> 12 ----- */
    {
        LfDataHandle req = lf_data_create("add");
        CHECK(req != NULL);
        CHECK_EQ_INT(lf_data_write_int32(req, 5), 1);
        CHECK_EQ_INT(lf_data_write_int32(req, 7), 1);

        LfDataHandle resp = lf_local_call(app, req);
        CHECK(resp != NULL);
        CHECK_EQ_INT(lf_data_get_size(resp), 4);

        int32_t sum = 0;
        CHECK_EQ_INT(lf_data_read_int32(resp, &sum), 1);
        CHECK_EQ_INT(sum, 12);

        lf_data_destroy(resp);
        lf_data_destroy(req);
    }

    /* ----- Notify: log("hello") ----- */
    {
        LfDataHandle req = lf_data_create("log");
        CHECK(req != NULL);
        CHECK_EQ_INT(lf_data_write_string(req, "hello"), 1);

        /* The public API routes through the mesh, so this call is
           asynchronous. We only verify that the call itself does not
           crash. Delivery is not asserted here. */
        lf_notify("TestCApp", req);

        lf_data_destroy(req);
    }

    lf_app_destroy(app);
}

static void test_duplicate_registration(void) {
    TEST_SECTION("Duplicate registration rejection");

    LfAppHandle app = lf_app_create("TestCAppDup", "dup test");
    CHECK(app != NULL);

    CHECK_EQ_INT(
        lf_app_register_call(app, "dup", "first", &add_callback), 1);
    CHECK_EQ_INT(
        lf_app_register_call(app, "dup", "second", &add_callback), 0);

    lf_app_destroy(app);
}

/* ============================================================================
 * Section 7: App unregister and process-wide P2P registration
 * ============================================================================ */

static void test_app_unregister(void) {
    TEST_SECTION("App unregister");

    LfAppHandle app = lf_app_create("TestCAppUnreg", "unreg test");
    CHECK(app != NULL);

    CHECK_EQ_INT(
        lf_app_register_call(app, "temp", "temp api", &add_callback), 1);

    /* First unregister succeeds. */
    CHECK_EQ_INT(lf_app_unregister(app, "temp"), 1);

    /* Second unregister fails (the API is already gone). */
    CHECK_EQ_INT(lf_app_unregister(app, "temp"), 0);

    /* Re-register after unregister is allowed. */
    CHECK_EQ_INT(
        lf_app_register_call(app, "temp", "temp api", &add_callback), 1);

    /* Clean up. */
    lf_app_unregister(app, "temp");
    lf_app_destroy(app);
}

static void test_p2p_registration(void) {
    TEST_SECTION("Process-wide P2P registration");

    /* Register a P2P Call and Notify API. */
    CHECK_EQ_INT(
        lf_register_p2p_call("test_p2p_ping", "test ping", &add_callback), 1);
    CHECK_EQ_INT(
        lf_register_p2p_notify("test_p2p_log", "test log", &log_callback), 1);

    /* Duplicate registration must be rejected. */
    CHECK_EQ_INT(
        lf_register_p2p_call("test_p2p_ping", "dup", &add_callback), 0);

    /* Unregister the Call API. */
    CHECK_EQ_INT(lf_unregister_p2p("test_p2p_ping"), 1);

    /* Second unregister of the same name fails. */
    CHECK_EQ_INT(lf_unregister_p2p("test_p2p_ping"), 0);

    /* Unregister the Notify API. */
    CHECK_EQ_INT(lf_unregister_p2p("test_p2p_log"), 1);

    /* NULL argument rejection. */
    CHECK_EQ_INT(lf_register_p2p_call(NULL, "desc", &add_callback), 0);
    CHECK_EQ_INT(lf_register_p2p_call("api", "desc", NULL), 0);
    CHECK_EQ_INT(lf_register_p2p_notify(NULL, "desc", &log_callback), 0);
    CHECK_EQ_INT(lf_register_p2p_notify("api", "desc", NULL), 0);
    CHECK_EQ_INT(lf_unregister_p2p(NULL), 0);
}

/* ============================================================================
 * Section 8: App name copy helper
 * ============================================================================ */

static void test_app_name_buffer(void) {
    TEST_SECTION("App name copy helper");

    LfAppHandle app = lf_app_create("TestCAppName", "name test");
    CHECK(app != NULL);

    char buf[128] = { 0 };
    int64_t n = lf_get_app_name(app, buf, (int64_t)sizeof(buf));
    CHECK_EQ_INT(n, (int64_t)strlen("TestCAppName"));
    CHECK_STREQ(buf, "TestCAppName");

    /* Buffer too small: must fail with -2 and leave the buffer alone. */
    char small[4] = { 'X', 'X', 'X', '\0' };
    int64_t n2 = lf_get_app_name(app, small, (int64_t)sizeof(small));
    CHECK_EQ_INT(n2, -2);

    lf_app_destroy(app);
}

/* ============================================================================
 * Section 9: Options
 * ============================================================================ */

static void test_options_generic(void) {
    TEST_SECTION("Options - generic accessors");

    /* ---- Known string option: set and get ---- */
    lf_set_option("LF_P2P_name", "test_group_xyz");
    {
        char buf[128] = { 0 };
        int64_t n = lf_get_option("LF_P2P_name", buf, (int64_t)sizeof(buf));
        CHECK_EQ_INT(n, (int64_t)strlen("test_group_xyz"));
        CHECK_STREQ(buf, "test_group_xyz");
    }

    /* Restore the empty default. */
    lf_set_option("LF_P2P_name", "");

    /* ---- Unknown option: set is silently ignored, get returns "" ---- */
    lf_set_option("__not_a_real_option__", "ignored");
    {
        char buf[128];
        memset(buf, 0xAA, sizeof(buf));
        int64_t n = lf_get_option("__not_a_real_option__", buf,
                                   (int64_t)sizeof(buf));
        CHECK_EQ_INT(n, 0);
        CHECK_EQ_INT((int)buf[0], 0);
    }

    /* ---- Buffer too small ---- */
    lf_set_option("LF_P2P_name", "abcdefghij");
    {
        char small[4];
        int64_t n = lf_get_option("LF_P2P_name", small,
                                   (int64_t)sizeof(small));
        CHECK_EQ_INT(n, -2);
    }
    lf_set_option("LF_P2P_name", "");

    /* ---- NULL rejection ---- */
    lf_set_option(NULL, "x");
    lf_set_option("x", NULL);
    {
        char buf[16];
        CHECK_EQ_INT(lf_get_option(NULL, buf, (int64_t)sizeof(buf)), -1);
        CHECK_EQ_INT(lf_get_option("Quiet", NULL, 16), -1);
        CHECK_EQ_INT(lf_get_option("Quiet", buf, 0), -1);
    }
}

static void test_options_typed(void) {
    TEST_SECTION("Options - typed shortcuts");

    /* ---- Authentication ---- */
    lf_set_opt_password("hunter2");
    {
        /* The library never exposes the real value; it always returns
           the mask "********". */
        const char* mask = lf_get_opt_password();
        CHECK(mask != NULL);
        CHECK_STREQ(mask, "********");
    }

    /* ---- Logging and diagnostics ---- */
    lf_set_opt_debug("");
    {
        const char* placeholder = lf_get_opt_debug();
        CHECK(placeholder != NULL);
        /* The library returns a fixed non-empty placeholder for this
           write-only option. */
        CHECK(strlen(placeholder) > 0);
    }

    lf_set_opt_quiet(1);
    CHECK_EQ_INT(lf_get_opt_quiet(), 1);
    lf_set_opt_quiet(0);
    CHECK_EQ_INT(lf_get_opt_quiet(), 0);

    lf_set_opt_show_thread_id(0);
    CHECK_EQ_INT(lf_get_opt_show_thread_id(), 0);
    lf_set_opt_show_thread_id(1);
    CHECK_EQ_INT(lf_get_opt_show_thread_id(), 1);
    lf_set_opt_show_thread_id(0);   /* restore default */

    lf_set_opt_console_output(1);
    CHECK_EQ_INT(lf_get_opt_console_output(), 1);
    lf_set_opt_console_output(0);
    CHECK_EQ_INT(lf_get_opt_console_output(), 0);
    lf_set_opt_console_output(1);   /* restore default */

    /* ---- Connection readiness ---- */
    lf_set_opt_overlap_connection(1);
    CHECK_EQ_INT(lf_get_opt_overlap_connection(), 1);
    lf_set_opt_overlap_connection(0);
    CHECK_EQ_INT(lf_get_opt_overlap_connection(), 0);

    lf_set_opt_wait_ready_ok(0);
    CHECK_EQ_INT(lf_get_opt_wait_ready_ok(), 0);
    lf_set_opt_wait_ready_ok(1);
    CHECK_EQ_INT(lf_get_opt_wait_ready_ok(), 1);

    lf_set_opt_wait_timeout(12345);
    CHECK_EQ_INT(lf_get_opt_wait_timeout(), 12345);
    lf_set_opt_wait_timeout(30000);   /* restore default */

    /* ---- IPC ---- */
    lf_set_opt_ipc_thread_count(4);
    CHECK_EQ_INT(lf_get_opt_ipc_thread_count(), 4);

    lf_set_opt_ipc_max_queue(512);
    CHECK_EQ_INT(lf_get_opt_ipc_max_queue(), 512);

    lf_set_opt_ipc_max_msg_size(2 * 1024 * 1024);
    CHECK_EQ_INT(lf_get_opt_ipc_max_msg_size(), 2 * 1024 * 1024);

    /* ---- Sequenced notifications ---- */
    lf_set_opt_fixed_sequenced_time(25000);
    CHECK_EQ_INT(lf_get_opt_fixed_sequenced_time(), 25000);
    lf_set_opt_fixed_sequenced_time(20000);   /* restore default */

    /* ---- P2P group name ---- */
    lf_set_opt_p2p_name("typed_opt_group");
    {
        char buf[128];
        int64_t n = lf_get_opt_p2p_name(buf, (int64_t)sizeof(buf));
        CHECK_EQ_INT(n, (int64_t)strlen("typed_opt_group"));
        CHECK_STREQ(buf, "typed_opt_group");
    }
    lf_set_opt_p2p_name("");

    /* ---- Data handle pool ---- */
    lf_set_opt_data_idle_timeout(600000);
    CHECK_EQ_INT(lf_get_opt_data_idle_timeout(), 600000);

    lf_set_opt_data_scan_interval(5000);
    CHECK_EQ_INT(lf_get_opt_data_scan_interval(), 5000);

    /* ---- Command flushing ---- */
    lf_set_opt_null_flush_threshold(1000);
    CHECK_EQ_INT(lf_get_opt_null_flush_threshold(), 1000);
    lf_set_opt_null_flush_threshold(5000);   /* restore default */
}

/* ============================================================================
 * Section 10: Query functions (offline)
 * ============================================================================
 *
 * Before the framework is started, every query must return 0 (false).
 * This is the "no mesh" baseline that any real application will
 * observe during its first milliseconds of execution.
 */

static void test_query_functions_offline(void) {
    TEST_SECTION("Query functions (offline)");

    /* Main thread is not running until lf_prepare_done succeeds. */
    CHECK_EQ_INT(lf_check_main_thread(), 0);

    /* Unknown targets must return 0. */
    CHECK_EQ_INT(lf_check_app("__no_such_app_xyz__"), 0);
    CHECK_EQ_INT(lf_check_api("__no_such_app_xyz__", "__no_such_api__"), 0);

    /* All-zero UID cannot match any session. */
    int8_t zero_uid[32];
    memset(zero_uid, 0, sizeof(zero_uid));
    CHECK_EQ_INT(lf_check_uid(zero_uid), 0);
    CHECK_EQ_INT(lf_check_uid_api(zero_uid, "__no_such_api__"), 0);

    /* Unknown group names must return 0. */
    CHECK_EQ_INT(lf_check_p2pname("__no_such_group_xyz__"), 0);
    CHECK_EQ_INT(lf_check_p2pname_api("__no_such_group_xyz__",
                                       "__no_such_api__"), 0);

    /* NULL argument rejection. */
    CHECK_EQ_INT(lf_check_uid(NULL), 0);
    CHECK_EQ_INT(lf_check_uid_api(NULL, "api"), 0);
    CHECK_EQ_INT(lf_check_uid_api(zero_uid, NULL), 0);
    CHECK_EQ_INT(lf_check_p2pname(NULL), 0);
    CHECK_EQ_INT(lf_check_p2pname_api(NULL, "api"), 0);
    CHECK_EQ_INT(lf_check_p2pname_api("group", NULL), 0);
}

/* ============================================================================
 * Section 11: Async dispatch failure
 * ============================================================================
 *
 * This is the LAST test in the suite because it starts the framework
 * and then tears it down.
 *
 * The test prepares a minimal framework with NO client and NO service.
 * In that state, LF_Async_Call cannot find any connection and returns
 * 0, which is the dispatch-failure path that the bridge is designed to
 * route through the callback.
 *
 * The bridge must therefore invoke the user callback SYNCHRONOUSLY, on
 * the caller's thread, with a NULL result handle.
 */

static void test_async_dispatch_failure(void) {
    TEST_SECTION("Async dispatch failure path");

    /* Restore options that could affect prepareDone's behaviour. */
    lf_set_opt_wait_ready_ok(1);
    lf_set_opt_wait_timeout(15000);
    lf_set_opt_overlap_connection(1);

    /* Prepare a minimal framework with no client and no service. */
    lf_reset_prepare();
    int rc = lf_prepare_done();
    CHECK_EQ_INT(rc, 1);

    /* Reset the callback tracking. */
    g_async_cb_count = 0;
    g_async_cb_last_result = (void*)0xDEADBEEF;

    /* Issue an async call to a non-existent app. With no client,
       LF_Async_Call returns 0, and the bridge must therefore invoke
       our callback synchronously with a NULL result. */
    LfDataHandle req = lf_data_create("anything");
    CHECK(req != NULL);
    lf_data_write_int32(req, 0);

    int dispatched = lf_async_call("__no_such_app_xyz__",
                                   req,
                                   &async_test_callback,
                                   NULL);

    /* The dispatch must have failed. */
    CHECK_EQ_INT(dispatched, 0);

    /* The callback must have run exactly once. */
    CHECK_EQ_INT(g_async_cb_count, 1);

    /* The result handle must be NULL on the failure path. */
    CHECK(g_async_cb_last_result == NULL);

    lf_data_destroy(req);

    /* Cleanup. The order matches Pascal's LF-CLEAN-001 contract. */
    lf_exit_main_thread();
    lf_shutdown();
}

/* ============================================================================
 * main
 * ============================================================================ */

int main(void) {
    printf("=== LingoFuse C bridge test suite ===\n");
    printf("Built with: __STDC_VERSION__ = %ld\n", (long)__STDC_VERSION__);

    /* Explicit load: fail fast if the runtime library is missing.
       (The bridge would also lazy-load on the first API call, but
       calling it here produces a clearer message at a known point.) */
    if (lf_load_library() != 1) {
        fprintf(stderr,
                "[FATAL] lf_load_library failed.\n"
                "        Place LingoFuse64.dll (or the platform "
                "equivalent)\n"
                "        next to this executable, or on the system "
                "loader path.\n");
        return 2;
    }
    printf("[OK] LingoFuse runtime loaded.\n");

    /* ---- Section 1: Data handle scalar I/O ---- */
    test_data_handle_scalars();

    /* ---- Section 2: Strings ---- */
    test_data_handle_strings();

    /* ---- Section 3: JSON ---- */
    test_data_handle_json();

    /* ---- Section 4: UID binary I/O and hex helpers ---- */
    test_data_handle_uid_io();
    test_uid_hex_helpers();

    /* ---- Section 5: P2P identity accessors ---- */
    test_p2p_identity_accessors();

    /* ---- Section 6: Local call and duplicate registration ---- */
    test_local_call();
    test_duplicate_registration();

    /* ---- Section 7: App unregister and P2P registration ---- */
    test_app_unregister();
    test_p2p_registration();

    /* ---- Section 8: App name buffer ---- */
    test_app_name_buffer();

    /* ---- Section 9: Options ---- */
    test_options_generic();
    test_options_typed();

    /* ---- Section 10: Query functions (offline) ---- */
    test_query_functions_offline();

    /* ---- Section 11: Async dispatch failure (LAST: starts framework) ---- */
    test_async_dispatch_failure();

    /* ---- Final summary ---- */
    printf("\n\n");
    printf("======================================================================\n");
    printf("  Summary\n");
    printf("======================================================================\n");
    printf("  Tests run    : %d\n", g_passed + g_failed);
    printf("  Tests passed : %d\n", g_passed);
    printf("  Tests failed : %d\n", g_failed);
    if (g_failed == 0) {
        printf("\n  RESULT: ALL TESTS PASSED\n");
    } else {
        printf("\n  RESULT: %d TEST(S) FAILED\n", g_failed);
    }
    printf("======================================================================\n");

    /* The library is intentionally NOT unloaded here. LF_FreeLibrary
       would ZERO every static function pointer, and a follow-on test
       run in the same process would then need to call LF_LoadLibrary
       again. For a single-shot test program the operating system
       reclaims everything at process exit. */

    return (g_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}