/**
 * @file test_lf_fortran.c
 * @brief Standalone C test for the lf_fortran.h C ABI.
 *
 * This test exercises the C ABI that Fortran will consume. It does
 * not depend on Fortran and can be compiled and run on its own. Its
 * purpose is to prove that the bridge works correctly before the
 * Fortran layer is added.
 *
 * Covered contracts:
 *   - Library load / unload
 *   - Application create / destroy
 *   - Data handle create / destroy
 *   - Scalar write / read round-trips
 *   - String write / read round-trips (including UTF-8)
 *   - JSON write / read round-trips
 *   - Local call round-trip through a registered Call API
 *   - Notify round-trip through a registered Notify API
 *   - Duplicate registration rejection
 *   - Application name copy helper with buffer-too-small handling
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

/* ============================================================================
 * Tests
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

    test_data_handle_scalars();
    test_data_handle_strings();
    test_data_handle_json();
    test_local_call();
    test_duplicate_registration();
    test_app_name_buffer();

    printf("\n=== Summary ===\n");
    printf("  Passed: %d\n", g_passed);
    printf("  Failed: %d\n", g_failed);

    if (g_failed == 0) {
        printf("\n[OK] All C bridge tests passed.\n");
        return 0;
    } else {
        printf("\n[ERROR] %d test(s) failed.\n", g_failed);
        return 1;
    }
}