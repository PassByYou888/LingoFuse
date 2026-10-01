// test_lingofuse_json.cpp
// =============================================================================
//  Comprehensive test suite for lf_io.hpp (the unified JSON / string I/O layer).
//
//  Version 2.0 -- CI mode (--ci) added on top of version 1.0.
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
//  Two operating modes:
//    (1) INTERACTIVE (default) -- human-readable per-test banners
//    (2) CI (--ci)             -- one JSON line per test to stdout,
//                                 plus a final summary line
//
//  All comments and status output are in English.
// =============================================================================

#include "LingoFuse.hpp"
#include "lf_io.hpp"

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
//  CI MODE STATE
// ============================================================================

namespace {

    bool        g_ci_mode = false;
    const char* g_current_cat = "";
    int         g_test_index = 0;
    int         g_test_total = 0;

    std::string json_escape(const std::string& s) {
        std::string out;
        out.reserve(s.size() + 8);
        for (char c : s) {
            switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x",
                        static_cast<unsigned>(c));
                    out += buf;
                }
                else {
                    out += c;
                }
            }
        }
        return out;
    }

} // namespace

// ============================================================================
//  Mini test framework
// ============================================================================

namespace {

    constexpr const char* kSectionRule =
        "======================================================================";
    constexpr const char* kCategoryRule =
        "######################################################################";

    void print_section_header(const char* title) {
        if (g_ci_mode) return;
        std::cout << "\n\n" << kSectionRule << "\n";
        std::cout << "  " << title << "\n";
        std::cout << kSectionRule << "\n";
    }

    void print_category_banner(const char* name,
        const char* description,
        int test_count) {
        if (g_ci_mode) return;
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
        TestResult r;
        const auto start = std::chrono::steady_clock::now();

        if (!g_ci_mode) {
            std::cout << "\n" << kSectionRule << "\n";
            std::cout << "[ " << name << " ]\n";
            std::cout << kSectionRule << "\n";
        }

        try {
            r.passed = fn();
        }
        catch (const lingofuse::io::LfIoError& e) {
            r.threw = true;
            r.error_detail = std::string("LfIoError: ") + e.what();
        }
        catch (const lingofuse::Error& e) {
            r.threw = true;
            r.error_detail = std::string("lingofuse::Error (code=")
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

        if (g_ci_mode) {
            std::ostringstream oss;
            oss << "{\"event\":\"test\""
                << ",\"suite\":\"test_lingofuse_json\""
                << ",\"index\":" << g_test_index
                << ",\"total\":" << g_test_total
                << ",\"category\":\"" << json_escape(g_current_cat) << "\""
                << ",\"name\":\"" << json_escape(name) << "\""
                << ",\"status\":\""
                << ((r.passed && !r.threw) ? "PASS" : "FAIL") << "\""
                << ",\"elapsed_ms\":" << r.elapsed_ms;
            if (!r.passed || r.threw) {
                oss << ",\"error\":\""
                    << json_escape(r.error_detail.empty()
                        ? "CHECK macro returned false"
                        : r.error_detail)
                    << "\"";
            }
            oss << "}";
            std::cout << oss.str() << "\n";
            std::cout.flush();
        }
        else {
            if (r.passed && !r.threw) {
                std::cout << "[ PASS ] (" << r.elapsed_ms << " ms)\n";
            }
            else {
                std::cout << "[ FAIL ]\n";
                if (r.threw) {
                    std::cout << "         reason: " << r.error_detail << "\n";
                }
                else {
                    std::cout << "         reason: a CHECK macro returned false\n";
                }
                std::cout << "         time:   " << r.elapsed_ms << " ms\n";
            }
            std::cout << kSectionRule << "\n";
        }
        return r;
    }

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

    class TestHandle {
    public:
        explicit TestHandle(const std::string& api = "lf_io_test")
            : h_(api) {
        }
        lingofuse::DataHandle& dh() noexcept { return h_; }
        TDataHnd raw() const noexcept { return h_.get(); }
    private:
        lingofuse::DataHandle h_;
    };

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
    const nlohmann::json j = { {"a", 1}, {"b", 2} };
    const std::string s = lingofuse::io::dumps_json(j);
    CHECK(!s.empty());
    CHECK(s.find('\n') == std::string::npos);
    CHECK(s.find(' ') == std::string::npos);
    CHECK_EQ(s.front(), '{');
    CHECK_EQ(s.back(), '}');
    return true;
}

bool test_dumps_json_non_ascii_literal_utf8() {
    nlohmann::json j;
    j["msg"] = "\xE4\xB8\x96\xE7\x95\x8C";
    const std::string s = lingofuse::io::dumps_json(j);
    CHECK(s.find("\\u") == std::string::npos);
    CHECK(s.find("\xE4\xB8\x96\xE7\x95\x8C") != std::string::npos);
    return true;
}

bool test_dumps_json_emoji_literal() {
    nlohmann::json j;
    j["emoji"] = "\xF0\x9F\x8C\x8D";
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
    CHECK_EQ(buf[3], std::uint8_t{ 0 });
    return true;
}

bool test_write_string_empty() {
    TestHandle h;
    lingofuse::io::write_string(h.raw(), "");
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
    TestHandle h;
    const char raw[] = { 'j', 's', 'o', 'n' };
    h.dh().writeRaw(raw, 4);
    h.dh().seek(0);
    const std::string s = lingofuse::io::read_string(h.raw());
    CHECK_EQ(s, std::string("json"));
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
    CHECK_EQ(h.dh().size(), std::int64_t{ 6 });
    const std::uint8_t* buf = h.dh().data();
    CHECK_EQ(buf[0], std::uint8_t{ 'a' });
    CHECK_EQ(buf[1], std::uint8_t{ 0 });
    CHECK_EQ(buf[5], std::uint8_t{ 0 });
    return true;
}

bool test_write_string_bytes_empty() {
    TestHandle h;
    lingofuse::io::write_string_bytes(h.raw(), nullptr, 0);
    CHECK_EQ(h.dh().size(), std::int64_t{ 1 });
    return true;
}

bool test_write_string_bytes_vector_overload() {
    TestHandle h;
    const std::vector<std::uint8_t> v = { 1, 2, 3 };
    lingofuse::io::write_string_bytes(h.raw(), v);
    CHECK_EQ(h.dh().size(), std::int64_t{ 4 });
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
    lingofuse::io::write_string(h.raw(), "ab");
    lingofuse::io::write_string(h.raw(), "cd");
    h.dh().seek(0);
    const auto all = lingofuse::io::read_all_bytes(h.raw());
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
    lingofuse::io::write_json(h.raw(), { {"a", 1} });
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
    const char raw[] = { 'n', 'o', 't', ' ', 'j', 's', 'o', 'n' };
    h.dh().writeRaw(raw, 8);
    h.dh().seek(0);
    CHECK_THROWS_LFIO(lingofuse::io::read_json(h.raw()));
    return true;
}

bool test_read_json_fault_tolerant_no_nul() {
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
    original["msg"] = "\xE4\xB8\x96\xE7\x95\x8C";
    TestHandle h;
    lingofuse::io::write_json(h.raw(), original);
    h.dh().seek(0);
    const auto back = lingofuse::io::read_json(h.raw());
    CHECK_EQ(back.at("msg").get<std::string>(),
        std::string("\xE4\xB8\x96\xE7\x95\x8C"));
    return true;
}

bool test_write_json_rejects_invalid_utf8_safely() {
    const std::string bad = std::string("\xFF");
    nlohmann::json j;
    j["data"] = bad;
    const std::string s = lingofuse::io::dumps_json(j);
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
    lingofuse::io::write_json(h.raw(), { {"a", 1} });
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
    const std::uint8_t bad[] = { 0xFF, 0xFE, 0x00 };
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
//  CATEGORY: DataHandle integration
// ============================================================================

bool test_datahandle_writejson_readjson() {
    lingofuse::DataHandle dh("integ_json");
    const nlohmann::json payload = { {"result", 42}, {"ok", true} };
    dh.writeJson(payload);
    dh.seek(0);
    const auto back = dh.readJson();
    CHECK(back == payload);
    return true;
}

bool test_datahandle_writestring_delegates() {
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
    TestHandle h;
    lingofuse::io::write_json(h.raw(), { {"a", 1} });
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
    TestHandle h;
    const std::string bridge_payload = R"({"b":2})";
    h.dh().writeRaw(bridge_payload.data(), bridge_payload.size());
    h.dh().seek(0);
    const auto j = lingofuse::io::read_json(h.raw());
    CHECK_EQ(j.at("b").get<int>(), 2);
    return true;
}

bool test_wire_write_read_symmetric_on_utf8() {
    const nlohmann::json original = {
        {"cn", "\xE4\xB8\xAD\xE6\x96\x87"},
        {"emoji", "\xF0\x9F\x8E\x89"}
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

    void print_usage(const char* prog) {
        std::cerr
            << "Usage: " << prog << " [options]\n"
            << "  --ci         machine-readable output (JSON Lines); exit 0/1\n"
            << "  -h, --help   show this message\n";
    }

} // namespace

int main(int argc, char* argv[]) {
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--ci") {
            g_ci_mode = true;
        }
        else if (a == "-h" || a == "--help") {
            print_usage(argv[0]);
            return EXIT_SUCCESS;
        }
        else {
            std::cerr << "Unknown argument: " << a << "\n";
            print_usage(argv[0]);
            return 2;
        }
    }

    const auto start_steady = std::chrono::steady_clock::now();

    print_section_header("SECTION 1: SUITE HEADER");
    if (!g_ci_mode) {
        std::cout << "  Suite   : lf_io.hpp JSON / string I/O test suite\n";
        std::cout << "  Version : 2.0 (CI mode)\n";
        std::cout << "  Purpose : covers every public function of the unified\n";
        std::cout << "            payload layer, plus the DataHandle delegation\n";
        std::cout << "            path and the wire-format invariants.\n";
    }

    std::vector<Category> categories = {
        {
            "dumps_json / loads_json",
            "JSON serialization policy and parsing",
            {
                { "dumps_json :: compact, no indent", test_dumps_json_compact_no_indent },
                { "dumps_json :: non-ASCII literal UTF-8 (Chinese)", test_dumps_json_non_ascii_literal_utf8 },
                { "dumps_json :: emoji literal UTF-8 (4-byte)", test_dumps_json_emoji_literal },
                { "dumps_json :: nested structures", test_dumps_json_nested_structures },
                { "loads_json :: string_view overload", test_loads_json_string_view },
                { "loads_json :: byte-vector overload", test_loads_json_byte_vector_overload },
                { "loads_json :: invalid JSON throws LfIoError", test_loads_json_invalid_throws },
                { "loads_json :: round-trip identity", test_loads_json_round_trip_identity },
            }
        },
        {
            "write_string / read_string",
            "NUL-framed string round-trip",
            {
                { "write_string :: appends NUL", test_write_string_appends_nul },
                { "write_string :: empty writes single NUL", test_write_string_empty },
                { "write_string :: null handle throws", test_write_string_null_handle_throws },
                { "read_string :: basic", test_read_string_basic },
                { "read_string :: fault-tolerant, no NUL", test_read_string_fault_tolerant_no_nul },
                { "read_string :: empty buffer", test_read_string_empty_buffer },
                { "read_string :: UTF-8 round-trip", test_read_string_utf8_round_trip },
            }
        },
        {
            "write_string_bytes / read_string_bytes",
            "Raw byte framing; embedded NUL preserved",
            {
                { "write_string_bytes :: embedded NUL preserved", test_write_string_bytes_preserves_embedded_nul },
                { "write_string_bytes :: empty", test_write_string_bytes_empty },
                { "write_string_bytes :: vector overload", test_write_string_bytes_vector_overload },
                { "read_string_bytes :: basic", test_read_string_bytes_basic },
                { "read_string_bytes :: cursor at end", test_read_string_bytes_cursor_at_end },
            }
        },
        {
            "peek_string_bytes",
            "Non-consuming inspect of the current payload",
            {
                { "peek :: does not advance cursor", test_peek_does_not_advance_cursor },
                { "peek :: empty buffer", test_peek_empty_buffer },
                { "peek :: null handle throws", test_peek_null_throws },
            }
        },
        {
            "read_all_bytes",
            "Whole-buffer consume, NUL not special",
            {
                { "read_all :: consumes everything", test_read_all_bytes_consumes_everything },
                { "read_all :: empty buffer", test_read_all_bytes_empty },
            }
        },
        {
            "write_json / read_json",
            "JSON payload with NUL terminator",
            {
                { "write_json :: appends NUL", test_write_json_appends_nul },
                { "write_json / read_json :: round-trip", test_write_json_read_json_round_trip },
                { "read_json :: empty payload -> JSON null", test_read_json_empty_returns_null },
                { "read_json :: invalid JSON throws", test_read_json_invalid_throws },
                { "read_json :: fault-tolerant, no NUL", test_read_json_fault_tolerant_no_nul },
                { "read_json :: non-ASCII round-trip", test_read_json_non_ascii_round_trip },
                { "dumps_json :: invalid UTF-8 safely replaced", test_write_json_rejects_invalid_utf8_safely },
            }
        },
        {
            "read_json_or_bytes",
            "Lenient 3-state variant reader",
            {
                { "json_or_bytes :: empty -> monostate", test_read_json_or_bytes_empty },
                { "json_or_bytes :: valid JSON -> json", test_read_json_or_bytes_valid_json },
                { "json_or_bytes :: non-JSON text -> bytes", test_read_json_or_bytes_non_json_text },
                { "json_or_bytes :: invalid UTF-8 -> bytes", test_read_json_or_bytes_invalid_utf8 },
            }
        },
        {
            "cstr",
            "c_char_p parameter helper",
            {
                { "cstr :: basic", test_cstr_basic },
                { "cstr :: empty", test_cstr_empty },
            }
        },
        {
            "DataHandle integration",
            "Delegation path from LingoFuse.hpp to lf_io.hpp",
            {
                { "DataHandle :: writeJson / readJson", test_datahandle_writejson_readjson },
                { "DataHandle :: write(string) delegates", test_datahandle_writestring_delegates },
                { "DataHandle :: readBytes() delegates", test_datahandle_readbytes_delegates },
                { "DataHandle :: readJson() on empty", test_datahandle_readjson_empty },
            }
        },
        {
            "Wire-format invariants",
            "Byte-level compatibility with Pascal / bridge producers",
            {
                { "wire :: write_json matches Pascal LF_WriteString", test_wire_matches_pascal_write_string },
                { "wire :: reads Pascal-produced NUL-terminated payload", test_wire_reads_pascal_produced_payload },
                { "wire :: reads bridge-produced payload (no NUL)", test_wire_reads_bridge_produced_payload },
                { "wire :: UTF-8 symmetric write/read", test_wire_write_read_symmetric_on_utf8 },
            }
        },
    };

    int total_tests = 0;
    for (const auto& c : categories) {
        total_tests += static_cast<int>(c.tests.size());
    }
    g_test_total = total_tests;

    print_section_header("SECTION 2: TEST PLAN");
    if (!g_ci_mode) {
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
    }

    print_section_header("SECTION 3: TEST EXECUTION");

    std::vector<std::pair<std::string, std::string>> failures;
    int global_index = 0;

    try {
        lingofuse::LibraryLoader loader;

        for (auto& cat : categories) {
            print_category_banner(cat.name, cat.description,
                static_cast<int>(cat.tests.size()));
            g_current_cat = cat.name;

            for (const auto& t : cat.tests) {
                ++global_index;
                g_test_index = global_index;

                if (!g_ci_mode) {
                    std::cout << "\n  Progress: " << global_index
                        << " / " << total_tests << "\n";
                }

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
        if (g_ci_mode) {
            std::cout << "{\"event\":\"fatal\",\"suite\":\"test_lingofuse_json\""
                << ",\"message\":\"" << json_escape(e.what()) << "\"}\n";
        }
        else {
            std::cout << "\n[FATAL] " << e.what() << std::endl;
        }
        return EXIT_FAILURE;
    }
    catch (...) {
        if (g_ci_mode) {
            std::cout << "{\"event\":\"fatal\",\"suite\":\"test_lingofuse_json\""
                << ",\"message\":\"unknown exception\"}\n";
        }
        else {
            std::cout << "\n[FATAL] unknown exception" << std::endl;
        }
        return EXIT_FAILURE;
    }

    // ---- Final summary --------------------------------------------------
    const auto end_steady = std::chrono::steady_clock::now();
    const double elapsed_sec =
        std::chrono::duration<double>(end_steady - start_steady).count();

    int total_passed = 0;
    int total_failed = 0;
    long long total_ms = 0;
    for (const auto& c : categories) {
        total_passed += c.passed;
        total_failed += c.failed;
        total_ms += c.total_ms;
    }

    if (g_ci_mode) {
        std::ostringstream oss;
        oss << "{\"event\":\"summary\""
            << ",\"suite\":\"test_lingofuse_json\""
            << ",\"total\":" << total_tests
            << ",\"passed\":" << total_passed
            << ",\"failed\":" << total_failed
            << ",\"elapsed_sec\":" << std::fixed << std::setprecision(3)
            << elapsed_sec
            << ",\"status\":\"" << (total_failed == 0 ? "PASS" : "FAIL")
            << "\"}";
        std::cout << oss.str() << "\n";
        std::cout.flush();
    }
    else {
        print_section_header("SECTION 4: SUMMARY");

        std::cout << "  " << std::left << std::setw(38) << "Category"
            << std::right << std::setw(7) << "Tests"
            << std::setw(8) << "Passed"
            << std::setw(8) << "Failed"
            << std::setw(12) << "Time"
            << "\n";
        std::cout << "  " << std::string(38 + 7 + 8 + 8 + 12, '-') << "\n";

        for (const auto& c : categories) {
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
    }

    return (total_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}