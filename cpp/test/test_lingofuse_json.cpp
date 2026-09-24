// test_lingofuse_json.cpp
// =============================================================================
//  Comprehensive test suite for lf_io.hpp (the unified JSON / string I/O layer).
//
//  Version 1.0
//
//  Coverage:
//    - dumps_json / loads_json        : JSON serialization policy
//    - write_string / read_string     : NUL-framed string round-trip
//    - write_string_bytes / read_*    : raw byte framing (embedded NUL safe)
//    - peek_string_bytes              : non-consuming inspect
//    - read_all_bytes                 : whole-buffer consume
//    - write_json / read_json         : JSON payload with NUL terminator
//    - read_json_or_bytes             : lenient 3-state reader
//    - cstr                           : c_char_p helper
//    - DataHandle integration         : delegation path in LingoFuse.hpp
//    - wire-format invariants         : byte-level compatibility with the
//                                       Pascal / Python producers
//
//  Every test is self-contained: it creates its own DataHandle, exercises
//  the layer, and frees the handle in a scope guard. No network is involved.
//
//  Build requirements (see test/CMakeLists.txt):
//    - links lingofuse_headers and lingofuse_c_wrapper
//    - places the executable next to the DLLs in Binary/
//
//  All comments and status output are in English.
// =============================================================================

#include "LingoFuse.hpp"     // RAII wrapper; pulls in lf_io.hpp via include
#include "lf_io.hpp"         // unified I/O; also usable standalone

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

// ============================================================================
//  Mini test framework (mirrors test_lingofuse.cpp for consistency)
// ============================================================================

namespace {

    constexpr const char* kSectionRule =
        "======================================================================";
    constexpr const char* kCategoryRule =
        "######################################################################";

    void print_section_header(const char* title) {
        std::cout << "\n\n" << kSectionRule << "\n";
        std::cout << "  " << title << "\n";
        std::cout << kSectionRule << "\n";
    }

    void print_category_banner(const char* name,
                               const char* description,
                               int test_count) {
        std::cout << "\n\n" << kCategoryRule << "\n";
        std::cout << "##  Category: " << name
                  << "  (" << test_count << " test"
                  << (test_count == 1 ? "" : "s") << ")\n";
        std::cout << "##  " << description << "\n";
        std::cout << kCategoryRule << "\n";
    }

    struct TestResult {
        bool passed = false;
        bool threw = false;
        long long elapsed_ms = 0;
        std::string error_detail;
    };

    using TestFn = bool (*)();

    TestResult run_test(const char* name, TestFn fn) {
        std::cout << "\n" << kSectionRule << "\n";
        std::cout << "[ " << name << " ]\n";
        std::cout << kSectionRule << "\n";

        TestResult r;
        const auto start = std::chrono::steady_clock::now();

        try {
            r.passed = fn();
        }
        catch (const lingofuse::io::LfIoError& e) {
            r.threw = true;
            r.error_detail = std::string("lingofuse::io::LfIoError: ")
                             + e.what();
        }
        catch (const lingofuse::Error& e) {
            r.threw = true;
            r.error_detail =
                std::string("lingofuse::Error (code=")
                + std::to_string(static_cast<int>(e.code()))
                + "): " + e.what();
        }
        catch (const std::exception& e) {
            r.threw = true;
            r.error_detail = std::string("std::exception: ") + e.what();
        }
        catch (...) {
            r.threw = true;
            r.error_detail = "unknown exception";
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
        std::cout << kSectionRule << "\n";
        return r;
    }

    // ---- CHECK macros -------------------------------------------------------

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
                      << "  (line " << __LINE__ << ")\n";                  \
            return false;                                                  \
        }                                                                  \
    } while (0)

#define CHECK_THROWS_LFIO(expr)                                            \
    do {                                                                   \
        bool _threw = false;                                               \
        try { (void)(expr); }                                              \
        catch (const lingofuse::io::LfIoError&) { _threw = true; }        \
        catch (...) {}                                                     \
        if (!_threw) {                                                     \
            std::cout << "    [CHECK_THROWS_LFIO FAILED] " #expr           \
                      << " did not throw LfIoError  (line "                \
                      << __LINE__ << ")\n";                                \
            return false;                                                  \
        }                                                                  \
    } while (0)

    // ---- Small RAII helper: a fresh DataHandle bound to a fixed name ------

    class TestHandle {
    public:
        explicit TestHandle(const std::string& api = "lf_io_test")
            : h_(api) {}

        lingofuse::DataHandle& dh() noexcept { return h_; }
        TDataHnd raw() const noexcept { return h_.get(); }

    private:
        lingofuse::DataHandle h_;
    };

    // ---- Byte helpers ------------------------------------------------------

    std::vector<std::uint8_t> to_bytes(std::string_view sv) {
        return std::vector<std::uint8_t>(sv.begin(), sv.end());
    }

    std::string to_string(const std::vector<std::uint8_t>& v) {
        return std::string(
            reinterpret_cast<const char*>(v.data()), v.size());
    }

} // namespace

// ============================================================================
//  CATEGORY: dumps_json / loads_json
// ============================================================================

bool test_dumps_json_compact_no_indent() {
    // Policy: compact output, no newlines, no trailing whitespace.
    const nlohmann::json j = {{"a", 1}, {"b", 2}};
    const std::string s = lingofuse::io::dumps_json(j);

    CHECK(!s.empty());
    CHECK(s.find('\n') == std::string::npos);
    CHECK(s.find(' ') == std::string::npos);
    CHECK_EQ(s.front(), '{');
    CHECK_EQ(s.back(), '}');
    return true;
}

bool test_dumps_json_non_ascii_literal_utf8() {
    // Policy: ensure_ascii = false, so non-ASCII stays literal.
    // The Chinese characters 世界 must appear as raw UTF-8 bytes,
    // NOT as \u4e16\u754c.
    nlohmann::json j;
    j["msg"] = "\xE4\xB8\x96\xE7\x95\x8C";  // UTF-8 for "世界"

    const std::string s = lingofuse::io::dumps_json(j);

    CHECK(s.find("\\u") == std::string::npos);
    CHECK(s.find("\xE4\xB8\x96\xE7\x95\x8C") != std::string::npos);
    return true;
}

bool test_dumps_json_emoji_literal() {
    // 4-byte UTF-8 (U+1F30D, Earth globe) must also be literal.
    nlohmann::json j;
    j["emoji"] = "\xF0\x9F\x8C\x8D";  // 🌍

    const std::string s = lingofuse::io::dumps_json(j);

    CHECK(s.find("\\u") == std::string::npos);
    CHECK(s.find("\xF0\x9F\x8C\x8D") != std::string::npos);
    return true;
}

bool test_dumps_json_nested_structures() {
    nlohmann::json j = {
        {"level1", {
            {"level2", {
                {"list", {1, 2, 3}},
                {"bool", true},
                {"null", nullptr}
            }}
        }}
    };

    const std::string s = lingofuse::io::dumps_json(j);

    // Round-trip and verify structure.
    const auto back = nlohmann::json::parse(s);
    CHECK_EQ(back.at("level1").at("level2").at("list")[0].get<int>(), 1);
    CHECK_EQ(back.at("level1").at("level2").at("list")[2].get<int>(), 3);
    CHECK_EQ(back.at("level1").at("level2").at("bool").get<bool>(), true);
    CHECK(back.at("level1").at("level2").at("null").is_null());
    return true;
}

bool test_loads_json_string_view() {
    const std::string_view text = R"({"x": 42, "y": "hello"})";
    const auto j = lingofuse::io::loads_json(text);

    CHECK_EQ(j.at("x").get<int>(), 42);
    CHECK_EQ(j.at("y").get<std::string>(), std::string("hello"));
    return true;
}

bool test_loads_json_byte_vector_overload() {
    const std::string text = R"([1,2,3])";
    const auto bytes = to_bytes(text);
    const auto j = lingofuse::io::loads_json(bytes);

    CHECK(j.is_array());
    CHECK_EQ(j.size(), std::size_t{ 3 });
    CHECK_EQ(j[0].get<int>(), 1);
    CHECK_EQ(j[2].get<int>(), 3);
    return true;
}

bool test_loads_json_invalid_throws() {
    CHECK_THROWS_LFIO(lingofuse::io::loads_json("{invalid"));
    CHECK_THROWS_LFIO(lingofuse::io::loads_json(""));
    CHECK_THROWS_LFIO(lingofuse::io::loads_json("   "));
    return true;
}

bool test_loads_json_round_trip_identity() {
    // A value that goes dumps -> loads must be identical to the original.
    const nlohmann::json original = {
        {"name", "LingoFuse"},
        {"version", 3},
        {"features", {"json", "utf-8", "compact"}},
        {"active", true}
    };

    const std::string s = lingofuse::io::dumps_json(original);
    const auto back = lingofuse::io::loads_json(s);

    CHECK(back == original);
    return true;
}

// ============================================================================
//  CATEGORY: write_string / read_string
// ============================================================================

bool test_write_string_appends_nul() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "abc");

    CHECK_EQ(h.dh().size(), std::int64_t{ 4 });

    const std::uint8_t* buf = h.dh().data();
    CHECK(buf != nullptr);
    CHECK_EQ(buf[0], std::uint8_t{ 'a' });
    CHECK_EQ(buf[1], std::uint8_t{ 'b' });
    CHECK_EQ(buf[2], std::uint8_t{ 'c' });
    CHECK_EQ(buf[3], std::uint8_t{ 0 });
    return true;
}

bool test_write_string_empty() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "");

    // Empty string is written as exactly one NUL byte.
    CHECK_EQ(h.dh().size(), std::int64_t{ 1 });
    CHECK_EQ(h.dh().data()[0], std::uint8_t{ 0 });
    return true;
}

bool test_write_string_null_handle_throws() {
    CHECK_THROWS_LFIO(lingofuse::io::write_string(nullptr, "x"));
    return true;
}

bool test_read_string_basic() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "hello");

    h.dh().seek(0);
    const std::string s = lingofuse::io::read_string(h.raw());
    CHECK_EQ(s, std::string("hello"));
    return true;
}

bool test_read_string_fault_tolerant_no_nul() {
    // Simulate a payload from an HTTP bridge: raw bytes, no NUL.
    TestHandle h;
    const char raw[] = { 'j', 's', 'o', 'n' };
    h.dh().writeRaw(raw, 4);

    h.dh().seek(0);
    const std::string s = lingofuse::io::read_string(h.raw());
    CHECK_EQ(s, std::string("json"));

    // Cursor advanced to (size + 1).
    CHECK_EQ(h.dh().tell(), std::int64_t{ 5 });
    return true;
}

bool test_read_string_empty_buffer() {
    TestHandle h;
    const std::string s = lingofuse::io::read_string(h.raw());
    CHECK(s.empty());
    return true;
}

bool test_read_string_utf8_round_trip() {
    const std::string original =
        "Hello, \xE4\xB8\x96\xE7\x95\x8C! \xF0\x9F\x8C\x8D";

    TestHandle h;
    lingofuse::io::write_string(h.raw(), original);

    h.dh().seek(0);
    const std::string back = lingofuse::io::read_string(h.raw());
    CHECK_EQ(back, original);
    return true;
}

// ============================================================================
//  CATEGORY: write_string_bytes / read_string_bytes
// ============================================================================

bool test_write_string_bytes_preserves_embedded_nul() {
    TestHandle h;

    const std::uint8_t data[] = { 'a', 0, 'b', 0, 'c' };
    lingofuse::io::write_string_bytes(h.raw(), data, sizeof(data));

    // 5 payload bytes + 1 terminator = 6.
    CHECK_EQ(h.dh().size(), std::int64_t{ 6 });

    const std::uint8_t* buf = h.dh().data();
    CHECK_EQ(buf[0], std::uint8_t{ 'a' });
    CHECK_EQ(buf[1], std::uint8_t{ 0 });
    CHECK_EQ(buf[2], std::uint8_t{ 'b' });
    CHECK_EQ(buf[5], std::uint8_t{ 0 });  // trailing terminator
    return true;
}

bool test_write_string_bytes_empty() {
    TestHandle h;
    lingofuse::io::write_string_bytes(h.raw(), nullptr, 0);

    // One NUL byte appended even for empty payload.
    CHECK_EQ(h.dh().size(), std::int64_t{ 1 });
    return true;
}

bool test_write_string_bytes_vector_overload() {
    TestHandle h;
    const std::vector<std::uint8_t> v = { 1, 2, 3 };
    lingofuse::io::write_string_bytes(h.raw(), v);

    CHECK_EQ(h.dh().size(), std::int64_t{ 4 });  // 3 payload + 1 NUL
    return true;
}

bool test_read_string_bytes_basic() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "hello");

    h.dh().seek(0);
    const auto bytes = lingofuse::io::read_string_bytes(h.raw());
    CHECK_EQ(bytes.size(), std::size_t{ 5 });
    CHECK_EQ(to_string(bytes), std::string("hello"));
    return true;
}

bool test_read_string_bytes_cursor_at_end() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "x");

    // Cursor is already past the payload; nothing to read.
    h.dh().seek(h.dh().size());
    const auto bytes = lingofuse::io::read_string_bytes(h.raw());
    CHECK(bytes.empty());
    return true;
}

// ============================================================================
//  CATEGORY: peek_string_bytes
// ============================================================================

bool test_peek_does_not_advance_cursor() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "abcdef");
    h.dh().seek(0);

    const auto peeked = lingofuse::io::peek_string_bytes(h.raw());
    CHECK_EQ(to_string(peeked), std::string("abcdef"));
    CHECK_EQ(h.dh().tell(), std::int64_t{ 0 });

    // A subsequent read must return the same bytes.
    const auto read = lingofuse::io::read_string(h.raw());
    CHECK_EQ(read, std::string("abcdef"));
    return true;
}

bool test_peek_empty_buffer() {
    TestHandle h;
    const auto peeked = lingofuse::io::peek_string_bytes(h.raw());
    CHECK(peeked.empty());
    CHECK_EQ(h.dh().tell(), std::int64_t{ 0 });
    return true;
}

bool test_peek_null_throws() {
    CHECK_THROWS_LFIO(lingofuse::io::peek_string_bytes(nullptr));
    return true;
}

// ============================================================================
//  CATEGORY: read_all_bytes
// ============================================================================

bool test_read_all_bytes_consumes_everything() {
    TestHandle h;

    // Two string writes; read_all_bytes must return both payloads and their
    // embedded NULs as raw bytes.
    lingofuse::io::write_string(h.raw(), "ab");
    lingofuse::io::write_string(h.raw(), "cd");
    h.dh().seek(0);

    const auto all = lingofuse::io::read_all_bytes(h.raw());
    // Expected: 'a' 'b' 0 'c' 'd' 0 -> 6 bytes.
    CHECK_EQ(all.size(), std::size_t{ 6 });
    CHECK_EQ(all[2], std::uint8_t{ 0 });
    CHECK_EQ(all[5], std::uint8_t{ 0 });
    CHECK_EQ(h.dh().tell(), h.dh().size());
    return true;
}

bool test_read_all_bytes_empty() {
    TestHandle h;
    const auto all = lingofuse::io::read_all_bytes(h.raw());
    CHECK(all.empty());
    return true;
}

// ============================================================================
//  CATEGORY: write_json / read_json
// ============================================================================

bool test_write_json_appends_nul() {
    TestHandle h;
    lingofuse::io::write_json(h.raw(), {{"a", 1}});

    // Serialized payload is `{"a":1}` = 7 bytes, plus the NUL.
    CHECK_EQ(h.dh().size(), std::int64_t{ 8 });
    CHECK_EQ(h.dh().data()[7], std::uint8_t{ 0 });
    return true;
}

bool test_write_json_read_json_round_trip() {
    const nlohmann::json original = {
        {"name", "LingoFuse"},
        {"nums", {1, 2, 3}},
        {"nested", {{"k", "v"}}}
    };

    TestHandle h;
    lingofuse::io::write_json(h.raw(), original);
    h.dh().seek(0);

    const auto back = lingofuse::io::read_json(h.raw());
    CHECK(back == original);
    return true;
}

bool test_read_json_empty_returns_null() {
    TestHandle h;
    const auto j = lingofuse::io::read_json(h.raw());
    CHECK(j.is_null());
    return true;
}

bool test_read_json_invalid_throws() {
    TestHandle h;
    // Raw text that is not valid JSON.
    const char raw[] = { 'n', 'o', 't', ' ', 'j', 's', 'o', 'n' };
    h.dh().writeRaw(raw, 8);
    h.dh().seek(0);

    CHECK_THROWS_LFIO(lingofuse::io::read_json(h.raw()));
    return true;
}

bool test_read_json_fault_tolerant_no_nul() {
    // Payload without a NUL terminator (bridge.py style).
    TestHandle h;
    const std::string text = R"({"k":"v"})";
    h.dh().writeRaw(text.data(), text.size());
    h.dh().seek(0);

    const auto j = lingofuse::io::read_json(h.raw());
    CHECK_EQ(j.at("k").get<std::string>(), std::string("v"));
    return true;
}

bool test_read_json_non_ascii_round_trip() {
    nlohmann::json original;
    original["msg"] = "\xE4\xB8\x96\xE7\x95\x8C";  // "世界"

    TestHandle h;
    lingofuse::io::write_json(h.raw(), original);
    h.dh().seek(0);

    const auto back = lingofuse::io::read_json(h.raw());
    CHECK_EQ(back.at("msg").get<std::string>(),
             std::string("\xE4\xB8\x96\xE7\x95\x8C"));
    return true;
}

bool test_write_json_rejects_invalid_utf8_safely() {
    // A std::string containing an invalid UTF-8 byte (0xFF).
    // The policy is error_handler_t::replace, so this must NOT throw;
    // the offending byte is replaced with U+FFFD in the output.
    const std::string bad = std::string("\xFF");
    nlohmann::json j;
    j["data"] = bad;

    const std::string s = lingofuse::io::dumps_json(j);

    // Output must be valid UTF-8 (no raw 0xFF byte survives).
    CHECK(s.find('\xFF') == std::string::npos);
    return true;
}

// ============================================================================
//  CATEGORY: read_json_or_bytes (3-state variant)
// ============================================================================

bool test_read_json_or_bytes_empty() {
    TestHandle h;
    const auto v = lingofuse::io::read_json_or_bytes(h.raw());
    CHECK(std::holds_alternative<std::monostate>(v));
    return true;
}

bool test_read_json_or_bytes_valid_json() {
    TestHandle h;
    lingofuse::io::write_json(h.raw(), {{"a", 1}});
    h.dh().seek(0);

    const auto v = lingofuse::io::read_json_or_bytes(h.raw());
    CHECK(std::holds_alternative<nlohmann::json>(v));

    const auto& j = std::get<nlohmann::json>(v);
    CHECK_EQ(j.at("a").get<int>(), 1);
    return true;
}

bool test_read_json_or_bytes_non_json_text() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "plain text, not json");
    h.dh().seek(0);

    const auto v = lingofuse::io::read_json_or_bytes(h.raw());
    CHECK(std::holds_alternative<std::vector<std::uint8_t>>(v));

    const auto& bytes = std::get<std::vector<std::uint8_t>>(v);
    CHECK_EQ(to_string(bytes), std::string("plain text, not json"));
    return true;
}

bool test_read_json_or_bytes_invalid_utf8() {
    TestHandle h;
    // Raw bytes that are neither valid UTF-8 nor JSON.
    const std::uint8_t bad[] = { 0xFF, 0xFE, 0x00 };
    // Note: write_string_bytes appends a NUL, so the payload is
    // 0xFF 0xFE 0x00 0x00. read_until_nul stops at the first NUL byte
    // inside the payload, i.e. the 3-byte 0xFF 0xFE 0x00 prefix...
    // Actually the first NUL is at index 2, so we get 0xFF 0xFE.
    lingofuse::io::write_string_bytes(h.raw(), bad, sizeof(bad));
    h.dh().seek(0);

    const auto v = lingofuse::io::read_json_or_bytes(h.raw());
    CHECK(std::holds_alternative<std::vector<std::uint8_t>>(v));
    return true;
}

// ============================================================================
//  CATEGORY: cstr
// ============================================================================

bool test_cstr_basic() {
    const std::string s = lingofuse::io::cstr("hello");
    CHECK_EQ(s, std::string("hello"));
    // c_str() must be NUL-terminated.
    CHECK_EQ(s.c_str()[5], '\0');
    return true;
}

bool test_cstr_empty() {
    const std::string s = lingofuse::io::cstr("");
    CHECK(s.empty());
    CHECK_EQ(s.c_str()[0], '\0');
    return true;
}

// ============================================================================
//  CATEGORY: DataHandle integration (LingoFuse.hpp delegation path)
// ============================================================================

bool test_datahandle_writejson_readjson() {
    lingofuse::DataHandle dh("integ_json");

    const nlohmann::json payload = {{"result", 42}, {"ok", true}};
    dh.writeJson(payload);
    dh.seek(0);

    const auto back = dh.readJson();
    CHECK(back == payload);
    return true;
}

bool test_datahandle_writestring_delegates() {
    // DataHandle::write(std::string) must use lf_io's NUL framing.
    lingofuse::DataHandle dh("integ_str");
    dh.write(std::string("abc"));

    CHECK_EQ(dh.size(), std::int64_t{ 4 });
    CHECK_EQ(dh.data()[3], std::uint8_t{ 0 });
    return true;
}

bool test_datahandle_readbytes_delegates() {
    lingofuse::DataHandle dh("integ_bytes");
    dh.write(std::string("hello"));
    dh.seek(0);

    const auto bytes = dh.readBytes();
    CHECK_EQ(bytes.size(), std::size_t{ 5 });
    CHECK_EQ(to_string(bytes), std::string("hello"));
    return true;
}

bool test_datahandle_readjson_empty() {
    lingofuse::DataHandle dh("integ_empty");
    const auto j = dh.readJson();
    CHECK(j.is_null());
    return true;
}

// ============================================================================
//  CATEGORY: wire-format invariants
// ============================================================================

bool test_wire_matches_pascal_write_string() {
    // Pascal LF_WriteString('{"a":1}') produces:
    //   7B 22 61 22 3A 31 7D 00
    // write_json({{"a",1}}) must produce the identical byte sequence.
    TestHandle h;
    lingofuse::io::write_json(h.raw(), {{"a", 1}});

    const std::uint8_t expected[] = {
        0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D, 0x00
    };
    CHECK_EQ(h.dh().size(), std::int64_t{ 8 });
    for (int i = 0; i < 8; ++i) {
        CHECK_EQ(h.dh().data()[i], expected[i]);
    }
    return true;
}

bool test_wire_reads_pascal_produced_payload() {
    // Simulate a Pascal-written payload: NUL-terminated UTF-8 JSON.
    TestHandle h;
    const std::string pascal_payload = R"({"a":1})";
    h.dh().writeRaw(pascal_payload.data(), pascal_payload.size());
    const char nul = 0;
    h.dh().writeRaw(&nul, 1);

    h.dh().seek(0);
    const auto j = lingofuse::io::read_json(h.raw());
    CHECK_EQ(j.at("a").get<int>(), 1);
    return true;
}

bool test_wire_reads_bridge_produced_payload() {
    // Simulate a bridge.py-written payload: raw JSON without a NUL.
    TestHandle h;
    const std::string bridge_payload = R"({"b":2})";
    h.dh().writeRaw(bridge_payload.data(), bridge_payload.size());

    h.dh().seek(0);
    const auto j = lingofuse::io::read_json(h.raw());
    CHECK_EQ(j.at("b").get<int>(), 2);
    return true;
}

bool test_wire_write_read_symmetric_on_utf8() {
    // Non-ASCII payload must survive a full write/read cycle byte-for-byte.
    const nlohmann::json original = {
        {"cn", "\xE4\xB8\xAD\xE6\x96\x87"},       // 中文
        {"emoji", "\xF0\x9F\x8E\x89"}             // 🎉
    };

    TestHandle h;
    lingofuse::io::write_json(h.raw(), original);
    h.dh().seek(0);
    const auto back = lingofuse::io::read_json(h.raw());

    CHECK(back == original);
    return true;
}

// ============================================================================
//  main
// ============================================================================

namespace {

    struct TestCase {
        const char* name;
        TestFn      fn;
    };

    struct Category {
        const char* name;
        const char* description;
        std::vector<TestCase> tests;

        int       passed = 0;
        int       failed = 0;
        long long total_ms = 0;
    };

} // namespace

int main() {
    print_section_header("SECTION 1: SUITE HEADER");
    std::cout << "  Suite   : lf_io.hpp JSON / string I/O test suite\n";
    std::cout << "  Version : 1.0\n";
    std::cout << "  Purpose : covers every public function of the unified\n";
    std::cout << "            payload layer, plus the DataHandle delegation\n";
    std::cout << "            path and the wire-format invariants.\n";

    std::vector<Category> categories = {
        {
            "dumps_json / loads_json",
            "JSON serialization policy and parsing",
            {
                { "dumps_json :: compact, no indent",
                  test_dumps_json_compact_no_indent },
                { "dumps_json :: non-ASCII literal UTF-8 (Chinese)",
                  test_dumps_json_non_ascii_literal_utf8 },
                { "dumps_json :: emoji literal UTF-8 (4-byte)",
                  test_dumps_json_emoji_literal },
                { "dumps_json :: nested structures",
                  test_dumps_json_nested_structures },
                { "loads_json :: string_view overload",
                  test_loads_json_string_view },
                { "loads_json :: byte-vector overload",
                  test_loads_json_byte_vector_overload },
                { "loads_json :: invalid JSON throws LfIoError",
                  test_loads_json_invalid_throws },
                { "loads_json :: round-trip identity",
                  test_loads_json_round_trip_identity },
            }
        },
        {
            "write_string / read_string",
            "NUL-framed string round-trip",
            {
                { "write_string :: appends NUL",
                  test_write_string_appends_nul },
                { "write_string :: empty writes single NUL",
                  test_write_string_empty },
                { "write_string :: null handle throws",
                  test_write_string_null_handle_throws },
                { "read_string :: basic",
                  test_read_string_basic },
                { "read_string :: fault-tolerant, no NUL",
                  test_read_string_fault_tolerant_no_nul },
                { "read_string :: empty buffer",
                  test_read_string_empty_buffer },
                { "read_string :: UTF-8 round-trip",
                  test_read_string_utf8_round_trip },
            }
        },
        {
            "write_string_bytes / read_string_bytes",
            "Raw byte framing; embedded NUL preserved",
            {
                { "write_string_bytes :: embedded NUL preserved",
                  test_write_string_bytes_preserves_embedded_nul },
                { "write_string_bytes :: empty",
                  test_write_string_bytes_empty },
                { "write_string_bytes :: vector overload",
                  test_write_string_bytes_vector_overload },
                { "read_string_bytes :: basic",
                  test_read_string_bytes_basic },
                { "read_string_bytes :: cursor at end",
                  test_read_string_bytes_cursor_at_end },
            }
        },
        {
            "peek_string_bytes",
            "Non-consuming inspect of the current payload",
            {
                { "peek :: does not advance cursor",
                  test_peek_does_not_advance_cursor },
                { "peek :: empty buffer",
                  test_peek_empty_buffer },
                { "peek :: null handle throws",
                  test_peek_null_throws },
            }
        },
        {
            "read_all_bytes",
            "Whole-buffer consume, NUL not special",
            {
                { "read_all :: consumes everything",
                  test_read_all_bytes_consumes_everything },
                { "read_all :: empty buffer",
                  test_read_all_bytes_empty },
            }
        },
        {
            "write_json / read_json",
            "JSON payload with NUL terminator",
            {
                { "write_json :: appends NUL",
                  test_write_json_appends_nul },
                { "write_json / read_json :: round-trip",
                  test_write_json_read_json_round_trip },
                { "read_json :: empty payload -> JSON null",
                  test_read_json_empty_returns_null },
                { "read_json :: invalid JSON throws",
                  test_read_json_invalid_throws },
                { "read_json :: fault-tolerant, no NUL",
                  test_read_json_fault_tolerant_no_nul },
                { "read_json :: non-ASCII round-trip",
                  test_read_json_non_ascii_round_trip },
                { "dumps_json :: invalid UTF-8 safely replaced",
                  test_write_json_rejects_invalid_utf8_safely },
            }
        },
        {
            "read_json_or_bytes",
            "Lenient 3-state variant reader",
            {
                { "json_or_bytes :: empty -> monostate",
                  test_read_json_or_bytes_empty },
                { "json_or_bytes :: valid JSON -> json",
                  test_read_json_or_bytes_valid_json },
                { "json_or_bytes :: non-JSON text -> bytes",
                  test_read_json_or_bytes_non_json_text },
                { "json_or_bytes :: invalid UTF-8 -> bytes",
                  test_read_json_or_bytes_invalid_utf8 },
            }
        },
        {
            "cstr",
            "c_char_p parameter helper",
            {
                { "cstr :: basic",
                  test_cstr_basic },
                { "cstr :: empty",
                  test_cstr_empty },
            }
        },
        {
            "DataHandle integration",
            "Delegation path from LingoFuse.hpp to lf_io.hpp",
            {
                { "DataHandle :: writeJson / readJson",
                  test_datahandle_writejson_readjson },
                { "DataHandle :: write(string) delegates",
                  test_datahandle_writestring_delegates },
                { "DataHandle :: readBytes() delegates",
                  test_datahandle_readbytes_delegates },
                { "DataHandle :: readJson() on empty",
                  test_datahandle_readjson_empty },
            }
        },
        {
            "Wire-format invariants",
            "Byte-level compatibility with Pascal / bridge producers",
            {
                { "wire :: write_json matches Pascal LF_WriteString",
                  test_wire_matches_pascal_write_string },
                { "wire :: reads Pascal-produced NUL-terminated payload",
                  test_wire_reads_pascal_produced_payload },
                { "wire :: reads bridge-produced payload (no NUL)",
                  test_wire_reads_bridge_produced_payload },
                { "wire :: UTF-8 symmetric write/read",
                  test_wire_write_read_symmetric_on_utf8 },
            }
        },
    };

    int total_tests = 0;
    for (const auto& c : categories) {
        total_tests += static_cast<int>(c.tests.size());
    }

    print_section_header("SECTION 2: TEST PLAN");
    std::cout << "  " << std::left << std::setw(38) << "Category"
              << " Tests\n";
    std::cout << "  " << std::string(38, '-') << " -----\n";
    for (const auto& c : categories) {
        std::cout << "  " << std::left << std::setw(38) << c.name
                  << " " << c.tests.size() << "\n";
    }
    std::cout << "  " << std::string(38, '-') << " -----\n";
    std::cout << "  " << std::left << std::setw(38) << "Total"
              << " " << total_tests << " tests\n";

    print_section_header("SECTION 3: TEST EXECUTION");

    std::vector<std::pair<std::string, std::string>> failures;
    int global_index = 0;

    try {
        // Load the dynamic library. lf_io only needs LF_LoadLibrary to have
        // succeeded; no network preparation is required for these tests.
        lingofuse::LibraryLoader loader;

        for (auto& cat : categories) {
            print_category_banner(cat.name, cat.description,
                                  static_cast<int>(cat.tests.size()));
            for (const auto& t : cat.tests) {
                ++global_index;
                std::cout << "\n  Progress: " << global_index
                          << " / " << total_tests << "\n";

                TestResult r = run_test(t.name, t.fn);
                if (r.passed && !r.threw) {
                    ++cat.passed;
                }
                else {
                    ++cat.failed;
                    failures.emplace_back(
                        cat.name,
                        std::string(t.name) + " -- "
                        + (r.threw ? r.error_detail : "CHECK failed"));
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
        std::cout << "\n[FATAL] unknown exception" << std::endl;
        return EXIT_FAILURE;
    }

    print_section_header("SECTION 4: SUMMARY");

    int total_passed = 0;
    int total_failed = 0;
    long long total_ms = 0;

    std::cout << "  " << std::left << std::setw(38) << "Category"
              << std::right << std::setw(7) << "Tests"
              << std::setw(8) << "Passed"
              << std::setw(8) << "Failed"
              << std::setw(12) << "Time"
              << "\n";
    std::cout << "  " << std::string(38 + 7 + 8 + 8 + 12, '-') << "\n";

    for (const auto& c : categories) {
        total_passed += c.passed;
        total_failed += c.failed;
        total_ms += c.total_ms;
        std::cout << "  " << std::left << std::setw(38) << c.name
                  << std::right << std::setw(7) << c.tests.size()
                  << std::setw(8) << c.passed
                  << std::setw(8) << c.failed
                  << std::setw(12) << (std::to_string(c.total_ms) + " ms")
                  << "\n";
    }

    std::cout << "  " << std::string(38 + 7 + 8 + 8 + 12, '-') << "\n";
    std::cout << "  " << std::left << std::setw(38) << "Total"
              << std::right << std::setw(7) << total_tests
              << std::setw(8) << total_passed
              << std::setw(8) << total_failed
              << std::setw(12) << (std::to_string(total_ms) + " ms")
              << "\n";

    if (!failures.empty()) {
        std::cout << "\n  Failed tests (" << failures.size() << "):\n\n";
        for (const auto& [cat, detail] : failures) {
            std::cout << "    [" << cat << "] " << detail << "\n";
        }
    }
    else {
        std::cout << "\n  Failed tests: (none)\n";
    }

    if (total_failed == 0) {
        std::cout << "\n  ************************************************************\n";
        std::cout << "  *  RESULT: ALL TESTS PASSED                               *\n";
        std::cout << "  ************************************************************\n";
    }
    else {
        std::cout << "\n  ************************************************************\n";
        std::cout << "  *  RESULT: " << total_failed << " TEST(S) FAILED\n";
        std::cout << "  ************************************************************\n";
    }

    return (total_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}