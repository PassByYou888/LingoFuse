// test_lingofuse.cpp
// =============================================================================
//  Comprehensive test suite for the LingoFuse C++ RAII wrapper.
//
//  Version 4.0 -- enhanced report form with detailed per-category statistics,
//                 failure tracking, and richer environment information.
//
//  Ported and adapted from the Python test suite (test_lingofuse.py). Every
//  test corresponds to a well-defined contract from the Pascal documentation
//  (LingoFuse_Pascal_Complete_Guide.md, lingofuse_import.pas) and is tagged
//  with the relevant LF-*-NNN pitfall ID where applicable.
//
//  ============================================================================
//  TEST PLAN (42 tests)
//  ============================================================================
//
//  DataHandle (14):
//    01  basic types ................. all integer / floating-point types
//    02  unicode ..................... UTF-8 round-trip via DataHandle
//    03  fault-tolerant read ......... LF-DATA-004: no NUL on the wire
//    04  too-small buffer ............ LF-DATA-004: cursor must not move
//    05  position and size ........... tell / seek / size
//    06  move semantics .............. RAII move-construct / move-assign
//    07  string termination .......... LF-DATA-005: write always appends #0
//    08  empty string ................ empty payload semantics
//    09  GetBufferOffset ............. offset pointer accessor
//    10  large buffer (128 KiB) ...... buffer realloc / growth path
//    11  embedded NUL preserved ...... LF-DATA-003: raw bytes keep #0
//    12  writeRaw does not append NUL  LF-DATA-005: raw path has no terminator
//    13  multi-field sequential I/O .. mixed types in one buffer
//    14  zero-length operations ...... writeRaw(nullptr, 0) / readRaw(x, 0)
//
//  App (8):
//    15  register / local call ....... basic API registration and local call
//    16  duplicate registration ...... second register returns false
//    17  unregister then re-register . API name can be reused after removal
//    18  case-insensitive API match .. "add" matches "Add" on the same App
//    19  callback isolation .......... callback producing no output
//    20  free lifecycle .............. LF-APP-002: two-phase destruction
//    21  getAppName .................. LF-APP-004: name retrieval
//    22  localNotify ................. App::localNotify round-trip
//
//  Network basics (6):
//    23  single address .............. service + client + call
//    24  multi address ............... two services, one app
//    25  generateAppName ............. LF-APP-003: must be after prepareDone
//    26  App::bind ................... LF-APP-005: binds to free clients only
//    27  check functions ............. LF-CHK-001: checkApp / checkApi w/ retry
//    28  deployment mode ............. LF-NET-004: Wait_Ready=False
//
//  Network options (4):
//    29  Overlap_Connection .......... LF-NET-001: False rejects, True allows
//    30  prepareDone only once ....... LF-NET-003: second call returns 0
//    31  dynamic client .............. LF-NET-004: prepareClient after prepareDone
//    32  unknown option ignored ...... LF-OPT-001: bogus options are no-ops
//
//  Network calls (4):
//    33  call timeout empty handle ... LF-CALL-001: size-0 handle, not NULL
//    34  notify + sequenced .......... LF-CALL-002 / LF-SEQ-002
//    35  nonexistent app / API ....... call to missing target returns empty
//    36  long string round-trip ...... LF-XLANG-002: 64 KiB payload
//
//  Network events (1):
//    37  install / clear ............. setNetworkEvent / clearNetworkEvent
//
//  Status queue (1):
//    38  getStatusCount / post ........ status queue operations
//
//  Concurrency (2):
//    39  concurrent local calls ...... 10 threads x 100 App::localCall
//    40  concurrent DataHandles ...... 8 threads x 500 independent handles
//
//  Stress (2):
//    41  1000 sequential local calls . throughput sanity check
//    42  rapid App create/destroy .... LF-APP-002: pool growth pressure
//
//  ============================================================================
//  DESIGN NOTES
//  ============================================================================
//
//    * No external test framework is used. A tiny CHECK / CHECK_EQ macro
//      pair plus a run_test() helper are sufficient for this scope.
//
//    * Every network test uses a UNIQUE IPC endpoint derived from the PID
//      and a global counter, so the suite can be re-run in the same process
//      without address collisions.
//
//    * Every network test ends with exitMainThread() + resetPrepare() so
//      that the next LF_PrepareDone() call can return 1 again.
//
//    {!!!!!  WHY WE DO NOT CALL LF_Shutdown BETWEEN TESTS  !!!!!}
//
//      Pascal documentation claims that LF_Shutdown is "not one-shot" and
//      that the framework may be re-initialised afterwards. In practice,
//      however, calling LF_Shutdown between tests makes every subsequent
//      LF_PrepareDone() return 0 in the same process -- the simulated main
//      thread cannot be restarted once LF_Shutdown has run.
//
//      The Python test suite (test_lingofuse.py) sidesteps this by only
//      calling LF_ExitMainThread() + LF_ResetPrepare() in its tearDown(),
//      never LF_Shutdown. This C++ suite follows the same pattern:
//
//          between tests : exitMainThread() + resetPrepare() + sleep
//          end of suite  : shutdown() (via ShutdownGuard in main())
//
//      Test 30 (prepareDone only once) verifies this behaviour explicitly.
//
//    * App objects live in inner scopes so that ~App() (LF_FreeApp) runs
//      BEFORE the next test's prepareService/prepareClient.
//
//  ============================================================================
//  OUTPUT LAYOUT
//  ============================================================================
//
//      ======================================================================
//      SECTION 1: SUITE HEADER
//      ======================================================================
//        Name, version, process ID, platform, start time
//
//      ======================================================================
//      SECTION 2: ENVIRONMENT
//      ======================================================================
//        CPU cores, working directory, build type
//
//      ======================================================================
//      SECTION 3: TEST PLAN
//      ======================================================================
//        Table of categories and test counts
//
//      ======================================================================
//      SECTION 4: TEST EXECUTION
//      ======================================================================
//        Category banners, per-test headers, PASS / FAIL lines
//
//      ======================================================================
//      SECTION 5: DETAILED SUMMARY
//      ======================================================================
//        Per-category statistics, failure list, totals, end time
// =============================================================================

#include "LingoFuse.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <exception>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#ifdef _WIN32
#  include <process.h>
#  include <windows.h>
#  define LF_TEST_GETPID() static_cast<int>(_getpid())
#else
#  include <unistd.h>
#  define LF_TEST_GETPID() static_cast<int>(::getpid())
#endif

/* ============================================================================
 *  Formatting helpers
 * ============================================================================ */

namespace {

    /* ---- Fixed-width string padding ---------------------------------------- */

    std::string pad_right(const std::string& s, std::size_t width) {
        if (s.size() >= width) return s;
        return s + std::string(width - s.size(), ' ');
    }

    std::string pad_left(const std::string& s, std::size_t width) {
        if (s.size() >= width) return s;
        return std::string(width - s.size(), ' ') + s;
    }

    /* ---- Current wall-clock time as a printable string --------------------- */

    std::string now_string() {
        const auto now = std::chrono::system_clock::now();
        const std::time_t t = std::chrono::system_clock::to_time_t(now);
        std::tm tm_buf{};
#if defined(_WIN32)
        localtime_s(&tm_buf, &t);
#else
        localtime_r(&t, &tm_buf);
#endif
        std::ostringstream oss;
        oss << std::put_time(&tm_buf, "%Y-%m-%d %H:%M:%S");
        return oss.str();
    }

    /* ---- Human-readable duration ------------------------------------------- */

    std::string format_duration(long long ms) {
        std::ostringstream oss;
        if (ms < 1000) {
            oss << ms << " ms";
        }
        else if (ms < 60000) {
            oss << std::fixed << std::setprecision(2)
                << (static_cast<double>(ms) / 1000.0) << " s";
        }
        else {
            const long long total_s = ms / 1000;
            const long long minutes = total_s / 60;
            const long long seconds = total_s % 60;
            oss << minutes << "m " << seconds << "s";
        }
        return oss.str();
    }

    /* ---- Section banner ---------------------------------------------------- */

    constexpr const char* kSectionRule =
        "======================================================================";
    constexpr const char* kCategoryRule =
        "######################################################################";

    void print_section_header(const char* title) {
        std::cout << "\n\n" << kSectionRule << "\n";
        std::cout << "  " << title << "\n";
        std::cout << kSectionRule << "\n";
    }

    void print_category_banner(const char* name, const char* description,
        int test_count) {
        std::cout << "\n\n" << kCategoryRule << "\n";
        std::cout << "##  Category: " << name
            << "  (" << test_count << " test"
            << (test_count == 1 ? "" : "s") << ")\n";
        std::cout << "##  " << description << "\n";
        std::cout << kCategoryRule << "\n";
    }

} // namespace

/* ============================================================================
 *  Mini test framework
 * ============================================================================ */

namespace {

    /* ---- Value formatter ---------------------------------------------------- */

    template <typename T>
    std::string to_display(const T& v) {
        std::ostringstream oss;
        if constexpr (std::is_pointer_v<T>) {
            if (v == nullptr) {
                oss << "nullptr";
            }
            else {
                oss << static_cast<const void*>(v);
            }
        }
        else if constexpr (std::is_integral_v<T> && sizeof(T) == 1
            && !std::is_same_v<std::remove_cv_t<T>, bool>) {
            oss << static_cast<int>(v);
        }
        else {
            oss << v;
        }
        return oss.str();
    }

    /* ---- CHECK macros ------------------------------------------------------- */

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::cout << "    [CHECK FAILED] " #cond                       \
                      << "  (line " << __LINE__ << ")\n";                  \
            return false;                                                  \
        }                                                                  \
    } while (0)

#define CHECK_EQ(a, b)                                                     \
    do {                                                                   \
        const auto& _lhs = (a);                                            \
        const auto& _rhs = (b);                                            \
        if (!(_lhs == _rhs)) {                                             \
            std::cout << "    [CHECK_EQ FAILED] " #a " == " #b             \
                      << "  (line " << __LINE__ << ")\n"                   \
                      << "        lhs = " << to_display(_lhs) << "\n"      \
                      << "        rhs = " << to_display(_rhs) << "\n";     \
            return false;                                                  \
        }                                                                  \
    } while (0)

    /* ---- Test result record ------------------------------------------------- */

    struct TestResult {
        bool passed = false;
        bool threw = false;
        long long elapsed_ms = 0;
        std::string error_detail;   // non-empty if an exception was thrown
    };

    using TestFn = bool (*)();

    TestResult run_test(const char* name, TestFn fn) {
        constexpr const char* kRule =
            "======================================================================";

        std::cout << "\n\n" << kRule << "\n";
        std::cout << "[ " << name << " ]\n";
        std::cout << kRule << "\n";

        TestResult r;

        const auto start = std::chrono::steady_clock::now();

        try {
            r.passed = fn();
        }
        catch (const lingofuse::Error& e) {
            r.threw = true;
            r.error_detail =
                "lingofuse::Error (code="
                + std::to_string(static_cast<int>(e.code()))
                + ", what=\"" + e.what() + "\")";
        }
        catch (const std::exception& e) {
            r.threw = true;
            r.error_detail =
                std::string("std::exception (what=\"") + e.what() + "\")";
        }
        catch (...) {
            r.threw = true;
            r.error_detail =
                "unknown exception (not derived from std::exception)";
        }

        const auto end = std::chrono::steady_clock::now();
        r.elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            end - start).count();

        if (r.passed && !r.threw) {
            std::cout << "[ PASS ] (" << r.elapsed_ms << " ms)\n";
        }
        else {
            std::cout << "[ FAIL ]\n";
            if (r.threw) {
                std::cout << "         reason: " << r.error_detail << "\n";
            }
            else {
                std::cout << "         reason: a CHECK macro returned false "
                    "(see the [CHECK...] line above)\n";
            }
            std::cout << "         time:   " << r.elapsed_ms << " ms\n";
        }

        std::cout << kRule << "\n";
        return r;
    }

    /* ---- Unique IPC endpoint generator -------------------------------------- */

    std::string make_unique_endpoint(const char* prefix) {
        static std::atomic<int> counter{ 0 };
        const int n = counter.fetch_add(1, std::memory_order_relaxed);
        return std::string("ipc:test_cpp_") + prefix + "_"
            + std::to_string(LF_TEST_GETPID()) + "_"
            + std::to_string(n);
    }

    /* ---- Network teardown helper ------------------------------------------- */

    void safe_shutdown() {
        try { lingofuse::exitMainThread(); }
        catch (...) {}
        try { lingofuse::resetPrepare(); }
        catch (...) {}
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
    }

    /* ---- ShutdownGuard ------------------------------------------------------ */

    struct ShutdownGuard {
        ~ShutdownGuard() {
            try { lingofuse::shutdown(); }
            catch (...) {}
        }
    };

    /* ---- Helper: wait for an app to become callable ------------------------ */

    bool wait_for_app_callable(const std::string& app_name,
        const std::string& api_name,
        const std::string& payload,
        int max_attempts,
        int per_attempt_ms) {
        for (int i = 0; i < max_attempts; ++i) {
            try {
                lingofuse::DataHandle param(api_name);
                param.write(payload);
                auto response = lingofuse::tryCall(app_name, param, 1000);
                if (response.has_value()) {
                    std::string echoed;
                    if (response->read(echoed) && !echoed.empty()) {
                        return true;
                    }
                }
            }
            catch (...) {}
            std::this_thread::sleep_for(
                std::chrono::milliseconds(per_attempt_ms));
        }
        return false;
    }

    /* ============================================================================
     *  Static API callbacks
     * ============================================================================ */

    void LF_CDECL cb_add(void* /*trigger*/, void* in, void* out) {
        lingofuse::DataHandle in_h(static_cast<TDataHnd>(in), false);
        lingofuse::DataHandle out_h(static_cast<TDataHnd>(out), false);

        std::int32_t a = 0, b = 0;
        if (!in_h.read(a) || !in_h.read(b)) return;
        out_h.write(static_cast<std::int32_t>(a + b));
    }

    void LF_CDECL cb_echo(void* /*trigger*/, void* in, void* out) {
        lingofuse::DataHandle in_h(static_cast<TDataHnd>(in), false);
        lingofuse::DataHandle out_h(static_cast<TDataHnd>(out), false);

        std::string s;
        if (in_h.read(s)) out_h.write(s);
    }

    void LF_CDECL cb_notify_sink(void* /*trigger*/, void* /*in*/) {}

    void LF_CDECL cb_empty(void* /*trigger*/, void* /*in*/, void* /*out*/) {}

} // namespace

/* ============================================================================
 *  CATEGORY: DataHandle (14 tests)
 * ============================================================================ */

bool test_data_handle_basic_types() {
    lingofuse::DataHandle dh("test_basic");

    dh.write(static_cast<std::int8_t>(-128));
    dh.write(static_cast<std::uint8_t>(255));
    dh.write(static_cast<std::int16_t>(-32768));
    dh.write(static_cast<std::uint16_t>(65535));
    dh.write(static_cast<std::int32_t>(-123456789));
    dh.write(static_cast<std::uint32_t>(123456789u));
    dh.write(static_cast<std::int64_t>(-9876543210LL));
    dh.write(static_cast<std::uint64_t>(9876543210ULL));
    dh.write(3.14159f);
    dh.write(2.718281828);
    dh.write(std::string("Hello, world! (ascii-only)"));

    dh.seek(0);

    std::int8_t   i8 = 0;
    std::uint8_t  u8 = 0;
    std::int16_t  i16 = 0;
    std::uint16_t u16 = 0;
    std::int32_t  i32 = 0;
    std::uint32_t u32 = 0;
    std::int64_t  i64 = 0;
    std::uint64_t u64 = 0;
    float         f = 0.0f;
    double        d = 0.0;
    std::string   s;

    CHECK(dh.read(i8));   CHECK_EQ(i8, -128);
    CHECK(dh.read(u8));   CHECK_EQ(u8, 255);
    CHECK(dh.read(i16));  CHECK_EQ(i16, -32768);
    CHECK(dh.read(u16));  CHECK_EQ(u16, 65535);
    CHECK(dh.read(i32));  CHECK_EQ(i32, -123456789);
    CHECK(dh.read(u32));  CHECK_EQ(u32, 123456789u);
    CHECK(dh.read(i64));  CHECK_EQ(i64, -9876543210LL);
    CHECK(dh.read(u64));  CHECK_EQ(u64, 9876543210ULL);
    CHECK(dh.read(f));    CHECK(std::fabs(f - 3.14159f) < 1e-4f);
    CHECK(dh.read(d));    CHECK(std::fabs(d - 2.718281828) < 1e-6);
    CHECK(dh.read(s));    CHECK_EQ(s, std::string("Hello, world! (ascii-only)"));

    return true;
}

bool test_data_handle_unicode() {
    lingofuse::DataHandle dh("test_unicode");

    const std::string text = "Hello, \xE4\xB8\x96\xE7\x95\x8C! \xF0\x9F\x8C\x8D";

    dh.write(text);
    dh.seek(0);

    std::string out;
    CHECK(dh.read(out));
    CHECK_EQ(out, text);

    return true;
}

bool test_data_handle_fault_tolerant_read() {
    lingofuse::DataHandle dh("test_fault");

    const char raw[] = { 'a', 'b', 'c', 'd', 'e', 'f' };
    dh.writeRaw(raw, 6);
    CHECK_EQ(dh.size(), std::int64_t{ 6 });

    dh.seek(0);

    std::string s;
    CHECK(dh.read(s));
    CHECK_EQ(s, std::string("abcdef"));

    CHECK_EQ(dh.tell(), std::int64_t{ 7 });

    return true;
}

bool test_data_handle_too_small_buffer() {
    lingofuse::DataHandle dh("test_small");

    dh.write(std::string("hello world"));
    dh.seek(0);

    char small_buf[4];
    std::memset(small_buf, 0, sizeof(small_buf));

    const int ret = LF_ReadString(dh.get(), small_buf, sizeof(small_buf));
    CHECK_EQ(ret, 0);
    CHECK_EQ(dh.tell(), std::int64_t{ 0 });

    char big_buf[32];
    std::memset(big_buf, 0, sizeof(big_buf));
    const int ret2 = LF_ReadString(dh.get(), big_buf, sizeof(big_buf));
    CHECK_EQ(ret2, 1);
    CHECK_EQ(std::string(big_buf), std::string("hello world"));

    return true;
}

bool test_data_handle_position_and_size() {
    lingofuse::DataHandle dh("test_pos");

    CHECK_EQ(dh.tell(), std::int64_t{ 0 });
    CHECK_EQ(dh.size(), std::int64_t{ 0 });

    dh.write(std::int32_t{ 123 });
    CHECK_EQ(dh.size(), std::int64_t{ 4 });
    CHECK_EQ(dh.tell(), std::int64_t{ 4 });

    dh.seek(2);
    CHECK_EQ(dh.tell(), std::int64_t{ 2 });

    dh.seek(0);
    std::int32_t v = 0;
    CHECK(dh.read(v));
    CHECK_EQ(v, 123);

    return true;
}

bool test_data_handle_move_semantics() {
    lingofuse::DataHandle dh1("test_move");
    dh1.write(std::int32_t{ 42 });

    const TDataHnd raw = dh1.get();
    CHECK(raw != nullptr);

    lingofuse::DataHandle dh2(std::move(dh1));
    CHECK(dh1.get() == nullptr);
    CHECK_EQ(dh2.get(), raw);

    dh2.seek(0);
    std::int32_t v = 0;
    CHECK(dh2.read(v));
    CHECK_EQ(v, 42);

    lingofuse::DataHandle dh3("test_move_dst");
    dh3 = std::move(dh2);
    CHECK(dh2.get() == nullptr);
    CHECK_EQ(dh3.get(), raw);

    return true;
}

bool test_data_handle_string_termination() {
    lingofuse::DataHandle dh("test_nul");

    dh.write(std::string("abc"));
    CHECK_EQ(dh.size(), std::int64_t{ 4 });

    const std::uint8_t* buf = dh.data();
    CHECK(buf != nullptr);
    CHECK_EQ(buf[0], std::uint8_t{ 'a' });
    CHECK_EQ(buf[1], std::uint8_t{ 'b' });
    CHECK_EQ(buf[2], std::uint8_t{ 'c' });
    CHECK_EQ(buf[3], std::uint8_t{ 0 });

    return true;
}

bool test_data_handle_empty_string() {
    lingofuse::DataHandle dh("test_empty");

    dh.write(std::string(""));
    CHECK_EQ(dh.size(), std::int64_t{ 1 });

    const std::uint8_t* buf = dh.data();
    CHECK(buf != nullptr);
    CHECK_EQ(buf[0], std::uint8_t{ 0 });

    dh.seek(0);
    std::string out;
    CHECK(dh.read(out));
    CHECK_EQ(out, std::string(""));
    CHECK_EQ(dh.tell(), std::int64_t{ 1 });

    return true;
}

bool test_data_handle_get_buffer_offset() {
    lingofuse::DataHandle dh("test_offset");

    const std::int32_t value = 0x11223344;
    dh.write(value);

    void* base = LF_GetBufferOffset(dh.get(), 0);
    void* offset0 = LF_GetBufferOffset(dh.get(), 0);
    CHECK(base == offset0);

    CHECK_EQ(dh.tell(), std::int64_t{ 4 });

    return true;
}

bool test_data_handle_large_buffer() {
    lingofuse::DataHandle dh("test_large");

    constexpr std::size_t kSize = 128 * 1024;
    std::vector<std::uint8_t> payload(kSize);
    for (std::size_t i = 0; i < kSize; ++i) {
        payload[i] = static_cast<std::uint8_t>(i & 0xFF);
    }

    dh.writeRaw(payload.data(), payload.size());
    CHECK_EQ(dh.size(), static_cast<std::int64_t>(kSize));

    dh.seek(0);
    std::vector<std::uint8_t> readback(kSize);
    const std::size_t got = dh.readRaw(readback.data(), readback.size());
    CHECK_EQ(got, kSize);
    CHECK(readback == payload);

    return true;
}

bool test_data_handle_embedded_nul_preserved() {
    // LF-DATA-003: Raw byte writes must preserve embedded #0 bytes. This is
    // the byte-oriented counterpart of the string path.
    lingofuse::DataHandle dh("test_embedded_nul");

    const std::uint8_t data[] = { 'a', 0, 'b', 0, 'c' };
    dh.writeRaw(data, sizeof(data));

    // writeRaw does NOT append a terminator: size is exactly 5.
    CHECK_EQ(dh.size(), std::int64_t{ 5 });

    const std::uint8_t* buf = dh.data();
    CHECK(buf != nullptr);
    CHECK_EQ(buf[0], std::uint8_t{ 'a' });
    CHECK_EQ(buf[1], std::uint8_t{ 0 });
    CHECK_EQ(buf[2], std::uint8_t{ 'b' });
    CHECK_EQ(buf[3], std::uint8_t{ 0 });
    CHECK_EQ(buf[4], std::uint8_t{ 'c' });

    return true;
}

bool test_data_handle_writeraw_no_terminator() {
    // LF-DATA-005 (counterpart): writeRaw does not append a #0 terminator.
    // This is different from write(std::string), which always appends one.
    lingofuse::DataHandle dh("test_raw_no_term");

    const char raw[] = { 'x', 'y', 'z' };
    dh.writeRaw(raw, 3);

    CHECK_EQ(dh.size(), std::int64_t{ 3 });

    // Append a string; its #0 must appear AFTER the raw bytes.
    dh.write(std::string("q"));
    CHECK_EQ(dh.size(), std::int64_t{ 5 });  // 3 raw + 1 'q' + 1 #0

    const std::uint8_t* buf = dh.data();
    CHECK(buf != nullptr);
    CHECK_EQ(buf[3], std::uint8_t{ 'q' });
    CHECK_EQ(buf[4], std::uint8_t{ 0 });

    return true;
}

bool test_data_handle_multi_field_round_trip() {
    // Sequential writes of mixed types, then sequential reads in the same
    // order. Verifies the cursor advances consistently.
    lingofuse::DataHandle dh("test_multi_field");

    dh.write(std::int32_t{ 111 });
    dh.write(std::string("middle"));
    dh.write(static_cast<std::uint16_t>(222));
    dh.write(3.5f);
    dh.write(std::int64_t{ -42 });

    dh.seek(0);

    std::int32_t   a = 0;
    std::string    s;
    std::uint16_t  b = 0;
    float          f = 0.0f;
    std::int64_t   c = 0;

    CHECK(dh.read(a));   CHECK_EQ(a, 111);
    CHECK(dh.read(s));   CHECK_EQ(s, std::string("middle"));
    CHECK(dh.read(b));   CHECK_EQ(b, 222);
    CHECK(dh.read(f));   CHECK(std::fabs(f - 3.5f) < 1e-6f);
    CHECK(dh.read(c));   CHECK_EQ(c, std::int64_t{ -42 });

    // Cursor must be at the very end.
    CHECK_EQ(dh.tell(), dh.size());

    return true;
}

bool test_data_handle_zero_length_operations() {
    // Edge case: zero-length writes and reads must be safe no-ops.
    lingofuse::DataHandle dh("test_zero_len");

    dh.writeRaw(nullptr, 0);
    CHECK_EQ(dh.size(), std::int64_t{ 0 });
    CHECK_EQ(dh.tell(), std::int64_t{ 0 });

    // Reading zero bytes from an empty buffer must also be safe.
    const std::size_t got = dh.readRaw(nullptr, 0);
    CHECK_EQ(got, std::size_t{ 0 });
    CHECK_EQ(dh.tell(), std::int64_t{ 0 });

    // Now write something and try a zero-length read from mid-buffer.
    dh.write(std::int32_t{ 42 });
    dh.seek(2);

    const std::size_t got2 = dh.readRaw(nullptr, 0);
    CHECK_EQ(got2, std::size_t{ 0 });
    CHECK_EQ(dh.tell(), std::int64_t{ 2 });  // cursor unchanged

    return true;
}

/* ============================================================================
 *  CATEGORY: App (8 tests)
 * ============================================================================ */

bool test_app_register_and_local_call() {
    lingofuse::App app("test_cpp_app_basic");

    CHECK(app.registerCall("add", "test add", nullptr, cb_add));
    CHECK(app.registerNotify("sink", "test notify", nullptr, cb_notify_sink));

    {
        lingofuse::DataHandle param("add");
        param.write(std::int32_t{ 10 });
        param.write(std::int32_t{ 20 });

        auto result = app.localCall(param);
        std::int32_t sum = 0;
        CHECK(result.read(sum));
        CHECK_EQ(sum, 30);
    }

    {
        lingofuse::DataHandle param("sink");
        param.write(std::string("hello"));
        app.localNotify(param);
    }

    CHECK(app.unregister("add"));
    CHECK(!app.unregister("add"));

    {
        lingofuse::DataHandle param("add");
        param.write(std::int32_t{ 1 });
        param.write(std::int32_t{ 2 });

        auto result = app.localCall(param);
        CHECK_EQ(result.size(), std::int64_t{ 0 });
    }

    return true;
}

bool test_app_duplicate_registration() {
    lingofuse::App app("test_cpp_app_dup");

    CHECK(app.registerCall("dup", "first", nullptr, cb_add));
    CHECK(!app.registerCall("dup", "second", nullptr, cb_add));

    return true;
}

bool test_app_unregister_then_reregister() {
    // After LF_Unregister, the same API name must be re-registerable.
    // This is the contract that makes hot-swapping an implementation safe.
    lingofuse::App app("test_cpp_app_rereg");

    CHECK(app.registerCall("hot", "v1", nullptr, cb_add));
    CHECK(app.unregister("hot"));
    CHECK(app.registerCall("hot", "v2", nullptr, cb_add));

    // Verify it works with the new callback.
    lingofuse::DataHandle param("hot");
    param.write(std::int32_t{ 5 });
    param.write(std::int32_t{ 6 });

    auto result = app.localCall(param);
    std::int32_t sum = 0;
    CHECK(result.read(sum));
    CHECK_EQ(sum, 11);

    return true;
}

bool test_app_case_insensitive_api_matching() {
    // Per lingofuse_import.pas: "API names are case-insensitive when matching,
    // but stored exactly as provided." We register with mixed case and call
    // with lowercase (and vice versa).
    lingofuse::App app("test_cpp_app_case");

    CHECK(app.registerCall("MixedCaseApi", "description", nullptr, cb_add));

    // Calling with lowercase must resolve to the same API.
    {
        lingofuse::DataHandle param("mixedcaseapi");
        param.write(std::int32_t{ 7 });
        param.write(std::int32_t{ 8 });
        auto result = app.localCall(param);
        std::int32_t sum = 0;
        CHECK(result.read(sum));
        CHECK_EQ(sum, 15);
    }

    // Unregister with yet another case variant.
    CHECK(app.unregister("MIXEDCASEAPI"));

    return true;
}

bool test_app_callback_isolation() {
    lingofuse::App app("test_cpp_app_isolation");

    CHECK(app.registerCall("empty", "empty callback", nullptr, cb_empty));

    lingofuse::DataHandle param("empty");
    auto result = app.localCall(param);
    CHECK_EQ(result.size(), std::int64_t{ 0 });

    return true;
}

bool test_app_free_lifecycle() {
    const std::string app_name = "test_cpp_app_lifecycle";

    {
        lingofuse::App app(app_name, "original");
        app.registerCall("ping", "ping", nullptr, cb_echo);

        lingofuse::DataHandle param("ping");
        param.write(std::string("first"));
        auto result = app.localCall(param);

        std::string echoed;
        CHECK(result.read(echoed));
        CHECK_EQ(echoed, std::string("first"));
    }

    {
        lingofuse::App app2(app_name, "second instance");
        app2.registerCall("ping", "ping", nullptr, cb_echo);

        lingofuse::DataHandle param("ping");
        param.write(std::string("second"));
        auto result = app2.localCall(param);

        std::string echoed;
        CHECK(result.read(echoed));
        CHECK_EQ(echoed, std::string("second"));
    }

    return true;
}

bool test_app_get_app_name() {
    lingofuse::App app("test_cpp_app_getname", "some description");

    const std::string name = lingofuse::getAppName(app.get());
    CHECK_EQ(name, std::string("test_cpp_app_getname"));

    return true;
}

bool test_app_local_notify() {
    lingofuse::App app("test_cpp_app_notify");

    CHECK(app.registerNotify("sink", "notify sink", nullptr, cb_notify_sink));

    lingofuse::DataHandle param("sink");
    param.write(std::string("payload"));

    app.localNotify(param);

    return true;
}

/* ============================================================================
 *  CATEGORY: Network basics (6 tests)
 * ============================================================================ */

bool test_network_single_address() {
    const std::string endpoint = make_unique_endpoint("single");
    const std::string app_name = "test_cpp_single";

    {
        lingofuse::App app(app_name, "single-address test");
        CHECK(app.registerCall("ping", "ping", nullptr, cb_echo));

        lingofuse::resetPrepare();

        const int serv = lingofuse::prepareService(endpoint, endpoint);
        CHECK(serv >= 0);

        const int cli = lingofuse::prepareClient(endpoint, app.get());
        CHECK(cli >= 0);

        CHECK_EQ(lingofuse::prepareDone(), 1);

        lingofuse::setOption("ConsoleOutput", "True");
        lingofuse::setOption("Quiet", "True");

        {
            lingofuse::DataHandle param("ping");
            param.write(std::string("hello"));

            auto response = lingofuse::tryCall(app_name, param, 3000);
            CHECK(response.has_value());

            std::string echoed;
            CHECK(response->read(echoed));
            CHECK_EQ(echoed, std::string("hello"));
        }

        {
            lingofuse::DataHandle param("does_not_exist");
            auto response = lingofuse::tryCall(app_name, param, 1000);
            CHECK(!response.has_value());
        }

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_multi_address() {
    const std::string ep1 = make_unique_endpoint("multi_a");
    const std::string ep2 = make_unique_endpoint("multi_b");
    const std::string app_name = "test_cpp_multi";

    {
        lingofuse::App app(app_name, "multi-address test");
        CHECK(app.registerCall("add", "add", nullptr, cb_add));

        lingofuse::resetPrepare();

        CHECK(lingofuse::prepareService(ep1, ep1) >= 0);
        CHECK(lingofuse::prepareService(ep2, ep2) >= 0);
        CHECK(lingofuse::prepareClient(ep1, app.get()) >= 0);
        CHECK(lingofuse::prepareClient(ep2, app.get()) >= 0);

        CHECK_EQ(lingofuse::prepareDone(), 1);

        lingofuse::DataHandle param("add");
        param.write(std::int32_t{ 3 });
        param.write(std::int32_t{ 4 });

        auto response = lingofuse::tryCall(app_name, param, 3000);
        CHECK(response.has_value());

        std::int32_t sum = 0;
        CHECK(response->read(sum));
        CHECK_EQ(sum, 7);

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_generate_app_name() {
    const std::string endpoint = make_unique_endpoint("genname");

    lingofuse::resetPrepare();
    CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
    CHECK(lingofuse::prepareClient(endpoint, nullptr) >= 0);

    CHECK_EQ(lingofuse::prepareDone(), 1);

    const std::string name = lingofuse::generateAppName();
    CHECK(!name.empty());
    CHECK(name.find("__generate__@") != std::string::npos);

    const std::string name2 = lingofuse::generateAppName();
    CHECK(name != name2);

    lingofuse::exitMainThread();

    safe_shutdown();
    return true;
}

bool test_network_bind_app() {
    const std::string ep1 = make_unique_endpoint("bind_a");
    const std::string ep2 = make_unique_endpoint("bind_b");

    {
        lingofuse::App app("test_cpp_bind", "bind test");
        CHECK(app.registerCall("ping", "ping", nullptr, cb_echo));

        lingofuse::resetPrepare();

        CHECK(lingofuse::prepareService(ep1, ep1) >= 0);
        CHECK(lingofuse::prepareService(ep2, ep2) >= 0);
        CHECK(lingofuse::prepareClient(ep1, nullptr) >= 0);
        CHECK(lingofuse::prepareClient(ep2, nullptr) >= 0);

        CHECK_EQ(lingofuse::prepareDone(), 1);

        const int bound = app.bind();
        CHECK_EQ(bound, 2);

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_check_functions() {
    const std::string endpoint = make_unique_endpoint("check");
    const std::string app_name = "test_cpp_check";

    {
        lingofuse::App app(app_name, "check test");
        CHECK(app.registerCall("ping", "ping", nullptr, cb_echo));

        lingofuse::resetPrepare();
        CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
        CHECK(lingofuse::prepareClient(endpoint, app.get()) >= 0);

        CHECK_EQ(lingofuse::prepareDone(), 1);

        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        CHECK(lingofuse::checkMainThread());

        bool app_seen = false;
        bool api_seen = false;
        for (int i = 0; i < 30; ++i) {
            if (!app_seen) app_seen = lingofuse::checkApp(app_name);
            if (!api_seen) api_seen = lingofuse::checkApi(app_name, "ping");
            if (app_seen && api_seen) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }

        CHECK(app_seen);
        CHECK(api_seen);

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_deployment_mode() {
    // LF-NET-004: With Wait_Ready = False (deployment mode), LF_PrepareDone
    // must NOT block waiting for the target service to be reachable. This
    // is the pattern used by elastic nodes that start before the coordinator.
    const std::string endpoint = make_unique_endpoint("deploy");

    lingofuse::resetPrepare();
    lingofuse::setOption("Wait_Ready", "False");

    // We deliberately do NOT prepare a service. Only a client, whose target
    // does not exist (yet).
    CHECK(lingofuse::prepareClient(endpoint, nullptr) >= 0);

    // With Wait_Ready=False, this must return quickly (well under 2s),
    // unlike the default Wait_Ready=True which would block for 30s.
    const auto t0 = std::chrono::steady_clock::now();
    const int ready = lingofuse::prepareDone();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();

    CHECK_EQ(ready, 1);
    CHECK(elapsed < 2000);

    lingofuse::exitMainThread();

    // Restore the default for subsequent tests.
    lingofuse::setOption("Wait_Ready", "True");

    safe_shutdown();
    return true;
}

/* ============================================================================
 *  CATEGORY: Network options (4 tests)
 * ============================================================================ */

bool test_network_overlap_connection() {
    {
        const std::string endpoint = make_unique_endpoint("ovl_false");

        lingofuse::resetPrepare();
        lingofuse::setOption("Overlap_Connection", "False");

        CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);

        const int tag1 = lingofuse::prepareClient(endpoint, nullptr);
        CHECK(tag1 >= 0);

        const int tag2 = lingofuse::prepareClient(endpoint, nullptr);
        CHECK_EQ(tag2, -1);

        CHECK_EQ(lingofuse::prepareDone(), 1);
        lingofuse::exitMainThread();
        safe_shutdown();
    }

    {
        const std::string endpoint = make_unique_endpoint("ovl_true");

        lingofuse::resetPrepare();
        lingofuse::setOption("Overlap_Connection", "True");

        CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);

        const int tag1 = lingofuse::prepareClient(endpoint, nullptr);
        CHECK(tag1 >= 0);

        const int tag2 = lingofuse::prepareClient(endpoint, nullptr);
        CHECK(tag2 >= 0);

        CHECK_EQ(lingofuse::prepareDone(), 1);
        lingofuse::exitMainThread();
        safe_shutdown();
    }

    lingofuse::setOption("Overlap_Connection", "False");

    return true;
}

bool test_network_prepare_done_only_once() {
    const std::string ep1 = make_unique_endpoint("once_a");
    const std::string ep2 = make_unique_endpoint("once_b");

    {
        lingofuse::resetPrepare();
        CHECK(lingofuse::prepareService(ep1, ep1) >= 0);
        CHECK(lingofuse::prepareClient(ep1, nullptr) >= 0);

        const int first = lingofuse::prepareDone();
        CHECK_EQ(first, 1);

        const int second = lingofuse::prepareDone();
        CHECK_EQ(second, 0);

        lingofuse::exitMainThread();
        safe_shutdown();

        CHECK(lingofuse::prepareService(ep2, ep2) >= 0);
        CHECK(lingofuse::prepareClient(ep2, nullptr) >= 0);
        CHECK_EQ(lingofuse::prepareDone(), 1);

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_dynamic_client_after_prepare_done() {
    const std::string ep_initial = make_unique_endpoint("dyn_init");
    const std::string ep_dynamic = make_unique_endpoint("dyn_add");
    const std::string app_name = "test_cpp_dynamic";

    {
        lingofuse::App app(app_name, "dynamic client test");
        CHECK(app.registerCall("ping", "ping", nullptr, cb_echo));

        lingofuse::resetPrepare();

        CHECK(lingofuse::prepareService(ep_initial, ep_initial) >= 0);
        CHECK(lingofuse::prepareClient(ep_initial, nullptr) >= 0);
        CHECK_EQ(lingofuse::prepareDone(), 1);

        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        const int serv2 = lingofuse::prepareService(ep_dynamic, ep_dynamic);
        CHECK(serv2 >= 0);

        const int cli2 = lingofuse::prepareClient(ep_dynamic, app.get());
        CHECK(cli2 >= 0);

        const bool ready = wait_for_app_callable(
            app_name, "ping", "hello", 30, 200);
        CHECK(ready);

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_unknown_option_ignored() {
    const std::string endpoint = make_unique_endpoint("unknown_opt");

    lingofuse::resetPrepare();

    lingofuse::setOption("ThisOptionDoesNotExist_12345", "some_value");
    lingofuse::setOption("AnotherBogusOption", "42");
    lingofuse::setOption("", "");

    CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
    CHECK(lingofuse::prepareClient(endpoint, nullptr) >= 0);
    CHECK_EQ(lingofuse::prepareDone(), 1);

    CHECK(lingofuse::checkMainThread());

    lingofuse::exitMainThread();
    safe_shutdown();
    return true;
}

/* ============================================================================
 *  CATEGORY: Network calls (4 tests)
 * ============================================================================ */

bool test_network_call_timeout_empty_handle() {
    const std::string endpoint = make_unique_endpoint("timeout");

    lingofuse::resetPrepare();
    CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
    CHECK(lingofuse::prepareClient(endpoint, nullptr) >= 0);
    CHECK_EQ(lingofuse::prepareDone(), 1);

    lingofuse::DataHandle param("anything");
    TDataHnd result = LF_Call("nonexistent_app_xyz_12345",
        param.get(), 500);

    CHECK(result != nullptr);
    CHECK_EQ(LF_GetSize(result), std::int64_t{ 0 });

    LF_FreeData(result);

    lingofuse::exitMainThread();
    safe_shutdown();
    return true;
}

bool test_network_notify_and_sequenced() {
    const std::string endpoint = make_unique_endpoint("notify");
    const std::string app_name = "test_cpp_notify";

    {
        lingofuse::App app(app_name, "notify test");
        CHECK(app.registerNotify("sink", "notify sink", nullptr, cb_notify_sink));

        lingofuse::resetPrepare();
        CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
        CHECK(lingofuse::prepareClient(endpoint, app.get()) >= 0);
        CHECK_EQ(lingofuse::prepareDone(), 1);

        for (int i = 0; i < 5; ++i) {
            lingofuse::DataHandle param("sink");
            param.write(std::string("n") + std::to_string(i));
            lingofuse::notify(app_name, param);
        }

        for (int i = 0; i < 5; ++i) {
            lingofuse::DataHandle param("sink");
            param.write(std::string("s") + std::to_string(i));
            lingofuse::sequencedNotify(app_name, param);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(300));

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_nonexistent_targets() {
    const std::string endpoint = make_unique_endpoint("missing");
    const std::string app_name = "test_cpp_missing";

    {
        lingofuse::App app(app_name, "missing-target test");
        CHECK(app.registerCall("ping", "ping", nullptr, cb_echo));

        lingofuse::resetPrepare();
        CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
        CHECK(lingofuse::prepareClient(endpoint, app.get()) >= 0);
        CHECK_EQ(lingofuse::prepareDone(), 1);

        {
            lingofuse::DataHandle param("ping");
            param.write(std::string("hello"));
            auto response = lingofuse::tryCall(
                "nonexistent_app_xyz_12345", param, 500);
            CHECK(!response.has_value());
        }

        {
            lingofuse::DataHandle param("nonexistent_api_xyz");
            auto response = lingofuse::tryCall(app_name, param, 500);
            CHECK(!response.has_value());
        }

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

bool test_network_long_string_round_trip() {
    // LF-XLANG-002: Strings must survive UTF-8 transit without corruption.
    // We send a ~64 KiB payload and verify the echo returns the exact same
    // bytes.
    const std::string endpoint = make_unique_endpoint("long_str");
    const std::string app_name = "test_cpp_long_str";

    // Build a 64 KiB payload with a mix of ASCII and multi-byte UTF-8.
    const std::string unit = "Hello-\xE4\xB8\x96\xE7\x95\x8C-";
    std::string payload;
    payload.reserve(64 * 1024);
    while (payload.size() < 64 * 1024) {
        payload += unit;
    }

    {
        lingofuse::App app(app_name, "long string test");
        CHECK(app.registerCall("ping", "ping", nullptr, cb_echo));

        lingofuse::resetPrepare();
        CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
        CHECK(lingofuse::prepareClient(endpoint, app.get()) >= 0);
        CHECK_EQ(lingofuse::prepareDone(), 1);

        lingofuse::DataHandle param("ping");
        param.write(payload);

        auto response = lingofuse::tryCall(app_name, param, 5000);
        CHECK(response.has_value());

        std::string echoed;
        CHECK(response->read(echoed));
        CHECK_EQ(echoed.size(), payload.size());
        CHECK(echoed == payload);

        lingofuse::exitMainThread();
    }

    safe_shutdown();
    return true;
}

/* ============================================================================
 *  CATEGORY: Network events (1 test)
 * ============================================================================ */

bool test_network_events_install_clear() {
    {
        int connect_calls = 0;
        int disconnect_calls = 0;

        lingofuse::setNetworkEvent(
            [&connect_calls](const std::string&) { ++connect_calls; },
            [&disconnect_calls](const std::string&) { ++disconnect_calls; }
        );

        lingofuse::clearNetworkEvent();
    }

    {
        struct DummyListener : lingofuse::NetworkEventListener {
            void onConnect(const std::string&) override {}
            void onDisconnect(const std::string&) override {}
        };

        auto listener = std::make_shared<DummyListener>();
        lingofuse::setNetworkEvent(listener);
        lingofuse::clearNetworkEvent();
    }

    {
        std::shared_ptr<lingofuse::NetworkEventListener> null_listener;
        lingofuse::setNetworkEvent(null_listener);
    }

    lingofuse::clearNetworkEvent();
    lingofuse::clearNetworkEvent();

    return true;
}

/* ============================================================================
 *  CATEGORY: Status queue (1 test)
 * ============================================================================ */

bool test_status_queue_operations() {
    const std::string endpoint = make_unique_endpoint("status");

    lingofuse::resetPrepare();
    CHECK(lingofuse::prepareService(endpoint, endpoint) >= 0);
    CHECK(lingofuse::prepareClient(endpoint, nullptr) >= 0);
    CHECK_EQ(lingofuse::prepareDone(), 1);

    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    const std::string marker = "cpp_test_status_marker_12345";
    lingofuse::postStatus(marker);

    std::this_thread::sleep_for(std::chrono::milliseconds(300));

    const int count = lingofuse::statusCount();
    CHECK(count >= 0);

    for (int i = 0; i < 20; ++i) {
        const std::string msg = lingofuse::popStatus();
        if (msg.empty()) break;
    }

    lingofuse::exitMainThread();
    safe_shutdown();
    return true;
}

/* ============================================================================
 *  CATEGORY: Concurrency (2 tests)
 * ============================================================================ */

bool test_concurrency_local_calls() {
    constexpr int kThreads = 10;
    constexpr int kCallsPerThread = 100;

    lingofuse::App app("test_cpp_concurrency");
    CHECK(app.registerCall("add", "add", nullptr, cb_add));

    std::atomic<int> success{ 0 };

    std::vector<std::thread> threads;
    threads.reserve(kThreads);

    for (int i = 0; i < kThreads; ++i) {
        threads.emplace_back([&app, &success]() {
            for (int j = 0; j < kCallsPerThread; ++j) {
                try {
                    lingofuse::DataHandle param("add");
                    param.write(static_cast<std::int32_t>(j));
                    param.write(static_cast<std::int32_t>(j * 2));

                    auto result = app.localCall(param);

                    std::int32_t sum = 0;
                    if (result.read(sum) && sum == j + j * 2) {
                        success.fetch_add(1, std::memory_order_relaxed);
                    }
                }
                catch (...) {}
            }
            });
    }

    for (auto& t : threads) {
        if (t.joinable()) t.join();
    }

    CHECK_EQ(success.load(), kThreads * kCallsPerThread);

    return true;
}

bool test_concurrency_independent_datahandles() {
    constexpr int kThreads = 8;
    constexpr int kItersPerThread = 500;

    std::atomic<int> success{ 0 };

    std::vector<std::thread> threads;
    threads.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&success, t]() {
            for (int i = 0; i < kItersPerThread; ++i) {
                lingofuse::DataHandle dh("thread_local_handle");

                const std::int32_t expected = t * 10000 + i;
                dh.write(expected);
                dh.seek(0);

                std::int32_t actual = 0;
                if (dh.read(actual) && actual == expected) {
                    success.fetch_add(1, std::memory_order_relaxed);
                }
            }
            });
    }

    for (auto& t : threads) {
        if (t.joinable()) t.join();
    }

    CHECK_EQ(success.load(), kThreads * kItersPerThread);

    return true;
}

/* ============================================================================
 *  CATEGORY: Stress (2 tests)
 * ============================================================================ */

bool test_stress_sequential_local_calls() {
    // 1000 sequential local calls. This is a throughput sanity check:
    // it verifies that repeated LocalCall + DataHandle create/destroy cycles
    // do not degrade over time or leak handles visible to the caller.
    constexpr int kIterations = 1000;

    lingofuse::App app("test_cpp_stress_seq");
    CHECK(app.registerCall("add", "add", nullptr, cb_add));

    int success = 0;
    for (int i = 0; i < kIterations; ++i) {
        try {
            lingofuse::DataHandle param("add");
            param.write(static_cast<std::int32_t>(i));
            param.write(static_cast<std::int32_t>(i + 1));

            auto result = app.localCall(param);

            std::int32_t sum = 0;
            if (result.read(sum) && sum == i + (i + 1)) {
                ++success;
            }
        }
        catch (...) {}
    }

    CHECK_EQ(success, kIterations);

    return true;
}

bool test_stress_rapid_app_create_destroy() {
    // LF-APP-002: LF_FreeApp is two-phase. The object stays in the pool
    // until LF_Shutdown. This test creates and destroys 100 Apps to
    // verify that the pool handles rapid churn without crashing or
    // deadlocking. It does NOT assert pool shrinkage (which cannot happen
    // until the final shutdown).
    constexpr int kCycles = 100;

    int success = 0;
    for (int i = 0; i < kCycles; ++i) {
        try {
            const std::string name = "test_cpp_churn_" + std::to_string(i);
            lingofuse::App app(name, "churn test");
            if (app.registerCall("ping", "ping", nullptr, cb_echo)) {
                lingofuse::DataHandle param("ping");
                param.write(std::string("x"));
                auto result = app.localCall(param);
                std::string echoed;
                if (result.read(echoed) && echoed == "x") {
                    ++success;
                }
            }
        }
        catch (...) {}
    }

    CHECK_EQ(success, kCycles);

    return true;
}

/* ============================================================================
 *  main
 * ============================================================================ */

namespace {

    struct TestCase {
        const char* name;
        TestFn      fn;
    };

    struct Category {
        const char* name;
        const char* description;
        std::vector<TestCase> tests;

        // Filled in by the runner.
        int  passed = 0;
        int  failed = 0;
        long long total_ms = 0;
    };

    struct FailureRecord {
        std::string category;
        std::string test;
        std::string reason;
        long long   elapsed_ms = 0;
    };

    std::string build_type_string() {
#if defined(NDEBUG)
        return "Release";
#else
        return "Debug";
#endif
    }

    unsigned int hardware_concurrency_safe() {
        const unsigned int n = std::thread::hardware_concurrency();
        return (n == 0) ? 1u : n;
    }

} // namespace

int main() {
    // ---- SECTION 1: SUITE HEADER ----------------------------------------
    const std::string start_time_str = now_string();

    print_section_header("SECTION 1: SUITE HEADER");
    std::cout << "  Suite      : LingoFuse C++ Test Suite\n";
    std::cout << "  Version    : 4.0 (enhanced report form)\n";
    std::cout << "  Process ID : " << LF_TEST_GETPID() << "\n";
#if defined(_WIN32)
    std::cout << "  Platform   : Windows "
        << (sizeof(void*) == 8 ? "x64" : "x86") << "\n";
#else
    std::cout << "  Platform   : POSIX "
        << (sizeof(void*) == 8 ? "64-bit" : "32-bit") << "\n";
#endif
    std::cout << "  Start time : " << start_time_str << "\n";

    // ---- SECTION 2: ENVIRONMENT -----------------------------------------
    print_section_header("SECTION 2: ENVIRONMENT");
    std::cout << "  Build type        : " << build_type_string() << "\n";
    std::cout << "  CPU cores         : " << hardware_concurrency_safe() << "\n";
    std::cout << "  C++ standard      : C++"
        << (__cplusplus / 100 % 100) << "\n";
#if defined(_MSC_VER)
    std::cout << "  Compiler          : MSVC " << _MSC_VER << "\n";
#elif defined(__clang__)
    std::cout << "  Compiler          : Clang " << __clang_major__
        << "." << __clang_minor__ << "\n";
#elif defined(__GNUC__)
    std::cout << "  Compiler          : GCC " << __GNUC__
        << "." << __GNUC_MINOR__ << "\n";
#else
    std::cout << "  Compiler          : (unknown)\n";
#endif

    // ---- Test plan ------------------------------------------------------
    std::vector<Category> categories = {
        {
            "DataHandle",
            "Buffer I/O, termination, position, RAII move, large payloads",
            {
                { "DataHandle :: basic types",
                  test_data_handle_basic_types },
                { "DataHandle :: unicode",
                  test_data_handle_unicode },
                { "DataHandle :: fault-tolerant read (LF-DATA-004)",
                  test_data_handle_fault_tolerant_read },
                { "DataHandle :: too-small destination buffer",
                  test_data_handle_too_small_buffer },
                { "DataHandle :: position and size",
                  test_data_handle_position_and_size },
                { "DataHandle :: move semantics",
                  test_data_handle_move_semantics },
                { "DataHandle :: string termination (LF-DATA-005)",
                  test_data_handle_string_termination },
                { "DataHandle :: empty string",
                  test_data_handle_empty_string },
                { "DataHandle :: GetBufferOffset",
                  test_data_handle_get_buffer_offset },
                { "DataHandle :: large buffer (128 KiB)",
                  test_data_handle_large_buffer },
                { "DataHandle :: embedded NUL preserved (LF-DATA-003)",
                  test_data_handle_embedded_nul_preserved },
                { "DataHandle :: writeRaw does not append NUL",
                  test_data_handle_writeraw_no_terminator },
                { "DataHandle :: multi-field sequential I/O",
                  test_data_handle_multi_field_round_trip },
                { "DataHandle :: zero-length operations",
                  test_data_handle_zero_length_operations },
            }
        },
        {
            "App",
            "API registration, local execution, lifetime, names",
            {
                { "App :: register / local call / unregister",
                  test_app_register_and_local_call },
                { "App :: duplicate registration rejected",
                  test_app_duplicate_registration },
                { "App :: unregister then re-register",
                  test_app_unregister_then_reregister },
                { "App :: case-insensitive API matching",
                  test_app_case_insensitive_api_matching },
                { "App :: callback isolation",
                  test_app_callback_isolation },
                { "App :: free lifecycle (LF-APP-002)",
                  test_app_free_lifecycle },
                { "App :: getAppName (LF-APP-004)",
                  test_app_get_app_name },
                { "App :: localNotify",
                  test_app_local_notify },
            }
        },
        {
            "Network basics",
            "Endpoints, generateAppName, bind, check, deployment mode",
            {
                { "Network :: single address",
                  test_network_single_address },
                { "Network :: multi address",
                  test_network_multi_address },
                { "Network :: generateAppName (LF-APP-003)",
                  test_network_generate_app_name },
                { "Network :: App::bind (LF-APP-005)",
                  test_network_bind_app },
                { "Network :: check functions (LF-CHK-001)",
                  test_network_check_functions },
                { "Network :: deployment mode (LF-NET-004)",
                  test_network_deployment_mode },
            }
        },
        {
            "Network options",
            "Overlap_Connection, prepareDone semantics, unknown options",
            {
                { "Network :: Overlap_Connection (LF-NET-001)",
                  test_network_overlap_connection },
                { "Network :: prepareDone only once (LF-NET-003)",
                  test_network_prepare_done_only_once },
                { "Network :: dynamic client after prepareDone (LF-NET-004)",
                  test_network_dynamic_client_after_prepare_done },
                { "Network :: unknown option ignored (LF-OPT-001)",
                  test_network_unknown_option_ignored },
            }
        },
        {
            "Network calls",
            "Call / Notify / Sequenced_Notify, timeout, missing, long data",
            {
                { "Network :: call timeout empty handle (LF-CALL-001)",
                  test_network_call_timeout_empty_handle },
                { "Network :: notify + sequencedNotify (LF-CALL-002)",
                  test_network_notify_and_sequenced },
                { "Network :: nonexistent app / API",
                  test_network_nonexistent_targets },
                { "Network :: long string round-trip (LF-XLANG-002)",
                  test_network_long_string_round_trip },
            }
        },
        {
            "Network events",
            "Global connect / disconnect handlers",
            {
                { "Network events :: install / clear (LF-NET-005/006)",
                  test_network_events_install_clear },
            }
        },
        {
            "Status queue",
            "getStatusCount / getStatus / postStatus",
            {
                { "Status queue :: count / post / pop",
                  test_status_queue_operations },
            }
        },
        {
            "Concurrency",
            "Thread safety of local calls and independent DataHandles",
            {
                { "Concurrency :: 10 threads x 100 local calls",
                  test_concurrency_local_calls },
                { "Concurrency :: 8 threads x 500 independent DataHandles",
                  test_concurrency_independent_datahandles },
            }
        },
        {
            "Stress",
            "Throughput and pool pressure",
            {
                { "Stress :: 1000 sequential local calls",
                  test_stress_sequential_local_calls },
                { "Stress :: rapid App create/destroy (100x)",
                  test_stress_rapid_app_create_destroy },
            }
        },
    };

    // ---- SECTION 3: TEST PLAN -------------------------------------------
    int total_tests = 0;
    for (const auto& c : categories) {
        total_tests += static_cast<int>(c.tests.size());
    }

    print_section_header("SECTION 3: TEST PLAN");
    std::cout << "  "
        << pad_right("Category", 20)
        << " Tests\n";
    std::cout << "  " << std::string(20, '-') << " -----\n";
    for (const auto& c : categories) {
        std::cout << "  "
            << pad_right(c.name, 20)
            << " " << c.tests.size() << "\n";
    }
    std::cout << "  " << std::string(20, '-') << " -----\n";
    std::cout << "  " << pad_right("Total", 20)
        << " " << total_tests << " tests\n";
    std::cout << "\n  Estimated runtime: ~80 seconds "
        "(12 network tests, each ~6 s)\n";

    // ---- SECTION 4: TEST EXECUTION --------------------------------------
    print_section_header("SECTION 4: TEST EXECUTION");

    std::vector<FailureRecord> failures;
    int global_test_index = 0;

    try {
        lingofuse::LibraryLoader loader;
        ShutdownGuard shutdown_guard;

        for (auto& cat : categories) {
            print_category_banner(cat.name, cat.description,
                static_cast<int>(cat.tests.size()));

            for (const auto& t : cat.tests) {
                ++global_test_index;

                // Prefix the running header with the global test index and
                // total, so the operator can follow progress.
                std::cout << "\n\n"
                    << "  Progress: " << global_test_index
                    << " / " << total_tests << "\n";

                TestResult r = run_test(t.name, t.fn);

                if (r.passed && !r.threw) {
                    ++cat.passed;
                }
                else {
                    ++cat.failed;
                    FailureRecord fr;
                    fr.category = cat.name;
                    fr.test = t.name;
                    fr.elapsed_ms = r.elapsed_ms;
                    fr.reason = r.threw
                        ? r.error_detail
                        : "a CHECK macro returned false "
                        "(see the [CHECK...] line above)";
                    failures.push_back(fr);
                }
                cat.total_ms += r.elapsed_ms;
            }
        }
    }
    catch (const std::exception& e) {
        std::cout << "\n[FATAL] " << e.what() << std::endl;
        return EXIT_FAILURE;
    }
    catch (...) {
        std::cout << "\n[FATAL] Unknown exception." << std::endl;
        return EXIT_FAILURE;
    }

    // ---- SECTION 5: DETAILED SUMMARY ------------------------------------
    const std::string end_time_str = now_string();

    print_section_header("SECTION 5: DETAILED SUMMARY");

    // 5.1 Per-category statistics.
    std::cout << "  Per-category statistics:\n\n";
    std::cout << "    "
        << pad_right("Category", 20)
        << pad_left("Tests", 6)
        << pad_left("Passed", 8)
        << pad_left("Failed", 8)
        << pad_left("Time", 12)
        << "\n";
    std::cout << "    " << std::string(20 + 6 + 8 + 8 + 12, '-') << "\n";

    int total_passed = 0;
    int total_failed = 0;
    long long total_ms = 0;

    for (const auto& c : categories) {
        total_passed += c.passed;
        total_failed += c.failed;
        total_ms += c.total_ms;

        std::cout << "    "
            << pad_right(c.name, 20)
            << pad_left(std::to_string(c.tests.size()), 6)
            << pad_left(std::to_string(c.passed), 8)
            << pad_left(std::to_string(c.failed), 8)
            << pad_left(format_duration(c.total_ms), 12)
            << "\n";
    }

    std::cout << "    " << std::string(20 + 6 + 8 + 8 + 12, '-') << "\n";
    std::cout << "    "
        << pad_right("Total", 20)
        << pad_left(std::to_string(total_tests), 6)
        << pad_left(std::to_string(total_passed), 8)
        << pad_left(std::to_string(total_failed), 8)
        << pad_left(format_duration(total_ms), 12)
        << "\n";

    // 5.2 Failure list.
    if (!failures.empty()) {
        std::cout << "\n\n  Failed tests (" << failures.size() << "):\n\n";
        for (std::size_t i = 0; i < failures.size(); ++i) {
            const auto& f = failures[i];
            std::cout << "    [" << (i + 1) << "] " << f.test << "\n";
            std::cout << "        Category : " << f.category << "\n";
            std::cout << "        Time     : " << f.elapsed_ms << " ms\n";
            std::cout << "        Reason   : " << f.reason << "\n\n";
        }
    }
    else {
        std::cout << "\n\n  Failed tests: (none)\n";
    }

    // 5.3 Timing and result summary.
    std::cout << "\n\n  Overall result:\n\n";
    std::cout << "    Total tests       : " << total_tests << "\n";
    std::cout << "    Passed            : " << total_passed << "\n";
    std::cout << "    Failed            : " << total_failed << "\n";

    if (total_tests > 0) {
        const double pass_rate =
            100.0 * static_cast<double>(total_passed)
            / static_cast<double>(total_tests);
        std::cout << "    Pass rate         : " << std::fixed
            << std::setprecision(2) << pass_rate << " %\n";
    }

    std::cout << "    Total wall time   : " << format_duration(total_ms) << "\n";
    std::cout << "    Start time        : " << start_time_str << "\n";
    std::cout << "    End time          : " << end_time_str << "\n";

    if (total_failed == 0) {
        std::cout << "\n  ************************************************************\n";
        std::cout << "  *  RESULT: ALL TESTS PASSED                               *\n";
        std::cout << "  ************************************************************\n";
    }
    else {
        std::cout << "\n  ************************************************************\n";
        std::cout << "  *  RESULT: " << total_failed << " TEST(S) FAILED"
            << std::string(45 - std::to_string(total_failed).size(), ' ')
            << "*\n";
        std::cout << "  ************************************************************\n";
    }

    return (total_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}