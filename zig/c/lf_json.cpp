/**
 * @file lf_json.cpp
 * @brief Implementation of the C ABI wrapper around nlohmann/json.
 *
 * See lf_json.h for the API contract.
 *
 * Compilation requirements:
 *   - C++17 or later
 *   - Exceptions enabled (default)
 *   - RTTI is not required
 */

#include "lf_json.h"
#include "json.hpp"

#include <cstring>
#include <iterator>
#include <new>
#include <string>

using nlohmann::json;

// ============================================================================
// Error buffer
// ============================================================================
//
// A single process-wide buffer is enough: parsing failures are reported
// synchronously to the caller, and the buffer is only read until the next
// parse call. It is deliberately a fixed char array rather than a
// std::string, so that it has no dynamic-initialisation or
// thread-local-storage dependency.

namespace {

constexpr std::size_t kErrorBufSize = 1024;
char g_last_error[kErrorBufSize] = {0};

void set_last_error(const char* msg) noexcept {
    if (!msg) {
        g_last_error[0] = '\0';
        return;
    }
    std::size_t i = 0;
    while (i + 1 < kErrorBufSize && msg[i] != '\0') {
        g_last_error[i] = msg[i];
        ++i;
    }
    g_last_error[i] = '\0';
}

void clear_last_error() noexcept {
    g_last_error[0] = '\0';
}

// The canonical serialization policy. This is the single source of truth
// for the wire format used by the whole toolchain.
std::string dump_canonical(const json& j) {
    return j.dump(
        -1,                                      // compact, no indent
        ' ',                                     // indent char (unused)
        false,                                   // ensure_ascii = false
        json::error_handler_t::replace           // invalid UTF-8 -> U+FFFD
    );
}

// A streaming writer. It accumulates bytes in a std::string and tracks
// whether any previous operation failed. Once a writer has failed, every
// subsequent operation becomes a no-op, and `writer_size` returns -1.
struct Writer {
    std::string buf;
    bool failed = false;

    void append(const char* s, std::size_t n) {
        if (failed) return;
        try {
            buf.append(s, n);
        } catch (...) {
            failed = true;
        }
    }

    void append_literal(const char* s) {
        append(s, std::strlen(s));
    }

    void write_string(const char* s, std::int64_t len) {
        if (failed) return;
        if (!s && len != 0) { failed = true; return; }
        if (len < 0) {
            if (!s) { failed = true; return; }
            len = static_cast<std::int64_t>(std::strlen(s));
        }
        try {
            json tmp(std::string(s, static_cast<std::size_t>(len)));
            auto quoted = dump_canonical(tmp);
            buf += quoted;
        } catch (...) {
            failed = true;
        }
    }

    template <class T>
    void write_number(T v) {
        if (failed) return;
        try {
            json tmp(v);
            auto text = dump_canonical(tmp);
            buf += text;
        } catch (...) {
            failed = true;
        }
    }
};

} // namespace

// ============================================================================
// Parsing
// ============================================================================

TJsonHnd LF_JSON_CDECL lf_json_parse(const char* text, std::int64_t len) {
    clear_last_error();

    if (!text && len > 0) {
        set_last_error("lf_json_parse: null text with positive length");
        return nullptr;
    }
    if (len == 0) {
        set_last_error("lf_json_parse: empty input");
        return nullptr;
    }

    try {
        auto* j = new json();
        if (len < 0) {
            // NUL-terminated C string.
            *j = json::parse(text);
        } else {
            *j = json::parse(
                text,
                text + static_cast<std::size_t>(len)
            );
        }
        return static_cast<TJsonHnd>(j);
    } catch (const std::exception& e) {
        set_last_error(e.what());
        return nullptr;
    } catch (...) {
        set_last_error("lf_json_parse: unknown exception");
        return nullptr;
    }
}

const char* LF_JSON_CDECL lf_json_last_error(void) {
    return g_last_error;
}

void LF_JSON_CDECL lf_json_free(TJsonHnd hnd) {
    if (!hnd) return;
    delete static_cast<json*>(hnd);
}

int LF_JSON_CDECL lf_json_type(TJsonHnd hnd) {
    if (!hnd) return -1;
    auto* j = static_cast<json*>(hnd);
    switch (j->type()) {
        case json::value_t::null:            return LF_JSON_NULL;
        case json::value_t::boolean:         return LF_JSON_BOOL;
        case json::value_t::number_integer:  return LF_JSON_INT;
        case json::value_t::number_unsigned: return LF_JSON_UINT;
        case json::value_t::number_float:    return LF_JSON_FLOAT;
        case json::value_t::string:          return LF_JSON_STRING;
        case json::value_t::array:           return LF_JSON_ARRAY;
        case json::value_t::object:          return LF_JSON_OBJECT;
        case json::value_t::binary:          return LF_JSON_BINARY;
        case json::value_t::discarded:       return LF_JSON_DISCARDED;
    }
    return -1;
}

// ============================================================================
// Serialization
// ============================================================================

std::int64_t LF_JSON_CDECL lf_json_dump_size(TJsonHnd hnd) {
    if (!hnd) return -1;
    auto* j = static_cast<json*>(hnd);
    try {
        auto s = dump_canonical(*j);
        return static_cast<std::int64_t>(s.size());
    } catch (...) {
        return -1;
    }
}

std::int64_t LF_JSON_CDECL lf_json_dump_into(
    TJsonHnd hnd, char* buf, std::int64_t buf_size) {
    if (!hnd || !buf || buf_size <= 0) return -1;
    auto* j = static_cast<json*>(hnd);
    try {
        auto s = dump_canonical(*j);
        const std::int64_t n = static_cast<std::int64_t>(s.size());
        if (n + 1 > buf_size) return -1;
        if (n > 0) {
            std::memcpy(buf, s.data(), static_cast<std::size_t>(n));
        }
        buf[n] = '\0';
        return n;
    } catch (...) {
        return -1;
    }
}

// ============================================================================
// Value reads
// ============================================================================

int LF_JSON_CDECL lf_json_get_bool(TJsonHnd hnd, int* out) {
    if (!hnd || !out) return 0;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_boolean()) return 0;
    *out = j->get<bool>() ? 1 : 0;
    return 1;
}

int LF_JSON_CDECL lf_json_get_int64(TJsonHnd hnd, std::int64_t* out) {
    if (!hnd || !out) return 0;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_number_integer()) return 0;
    try {
        *out = j->get<std::int64_t>();
        return 1;
    } catch (...) {
        return 0;
    }
}

int LF_JSON_CDECL lf_json_get_uint64(TJsonHnd hnd, std::uint64_t* out) {
    if (!hnd || !out) return 0;
    auto* j = static_cast<json*>(hnd);

    // Unsigned node: direct read.
    if (j->is_number_unsigned()) {
        *out = j->get<std::uint64_t>();
        return 1;
    }

    // Signed node: read as int64 first, then reject negatives
    // explicitly. nlohmann's `get<std::uint64_t>()` on a signed node
    // does NOT range-check; it would silently wrap -1 to UINT64_MAX.
    if (j->is_number_integer()) {
        try {
            const std::int64_t v = j->get<std::int64_t>();
            if (v < 0) return 0;
            *out = static_cast<std::uint64_t>(v);
            return 1;
        } catch (...) {
            return 0;
        }
    }

    return 0;
}

int LF_JSON_CDECL lf_json_get_double(TJsonHnd hnd, double* out) {
    if (!hnd || !out) return 0;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_number()) return 0;
    try {
        *out = j->get<double>();
        return 1;
    } catch (...) {
        return 0;
    }
}

std::int64_t LF_JSON_CDECL lf_json_string_size(TJsonHnd hnd) {
    if (!hnd) return -1;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_string()) return -1;
    return static_cast<std::int64_t>(
        j->get_ref<const std::string&>().size()
    );
}

std::int64_t LF_JSON_CDECL lf_json_string_into(
    TJsonHnd hnd, char* buf, std::int64_t buf_size) {
    if (!hnd || !buf || buf_size < 0) return -1;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_string()) return -1;
    const auto& s = j->get_ref<const std::string&>();
    const std::int64_t n = static_cast<std::int64_t>(s.size());
    if (n > buf_size) return -1;
    if (n > 0) {
        std::memcpy(buf, s.data(), static_cast<std::size_t>(n));
    }
    return n;
}

// ============================================================================
// Object access
// ============================================================================

std::int64_t LF_JSON_CDECL lf_json_object_size(TJsonHnd hnd) {
    if (!hnd) return -1;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_object()) return -1;
    return static_cast<std::int64_t>(j->size());
}

std::int64_t LF_JSON_CDECL lf_json_object_key_into(
    TJsonHnd hnd, std::int64_t idx, char* buf, std::int64_t buf_size) {
    if (!hnd || !buf || buf_size < 0 || idx < 0) return -1;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_object()) return -1;
    if (idx >= static_cast<std::int64_t>(j->size())) return -1;

    auto it = j->begin();
    std::advance(it, static_cast<std::ptrdiff_t>(idx));
    const auto& key = it.key();
    const std::int64_t n = static_cast<std::int64_t>(key.size());
    if (n > buf_size) return -1;
    if (n > 0) {
        std::memcpy(buf, key.data(), static_cast<std::size_t>(n));
    }
    return n;
}

TJsonHnd LF_JSON_CDECL lf_json_object_get(
    TJsonHnd hnd, const char* key, std::int64_t key_len) {
    if (!hnd || !key || key_len < 0) return nullptr;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_object()) return nullptr;

    auto it = j->find(std::string(key, static_cast<std::size_t>(key_len)));
    if (it == j->end()) return nullptr;

    try {
        auto* result = new json(*it);
        return static_cast<TJsonHnd>(result);
    } catch (...) {
        return nullptr;
    }
}

// ============================================================================
// Array access
// ============================================================================

std::int64_t LF_JSON_CDECL lf_json_array_size(TJsonHnd hnd) {
    if (!hnd) return -1;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_array()) return -1;
    return static_cast<std::int64_t>(j->size());
}

TJsonHnd LF_JSON_CDECL lf_json_array_get(TJsonHnd hnd, std::int64_t idx) {
    if (!hnd || idx < 0) return nullptr;
    auto* j = static_cast<json*>(hnd);
    if (!j->is_array()) return nullptr;
    if (idx >= static_cast<std::int64_t>(j->size())) return nullptr;

    try {
        auto* result = new json((*j)[static_cast<std::size_t>(idx)]);
        return static_cast<TJsonHnd>(result);
    } catch (...) {
        return nullptr;
    }
}

// ============================================================================
// Build (DOM)
// ============================================================================

TJsonHnd LF_JSON_CDECL lf_json_new_null(void) {
    try { return static_cast<TJsonHnd>(new json(nullptr)); }
    catch (...) { return nullptr; }
}

TJsonHnd LF_JSON_CDECL lf_json_new_bool(int value) {
    try { return static_cast<TJsonHnd>(new json(value != 0)); }
    catch (...) { return nullptr; }
}

TJsonHnd LF_JSON_CDECL lf_json_new_int64(std::int64_t value) {
    try { return static_cast<TJsonHnd>(new json(value)); }
    catch (...) { return nullptr; }
}

TJsonHnd LF_JSON_CDECL lf_json_new_uint64(std::uint64_t value) {
    try { return static_cast<TJsonHnd>(new json(value)); }
    catch (...) { return nullptr; }
}

TJsonHnd LF_JSON_CDECL lf_json_new_double(double value) {
    try { return static_cast<TJsonHnd>(new json(value)); }
    catch (...) { return nullptr; }
}

TJsonHnd LF_JSON_CDECL lf_json_new_string(const char* s, std::int64_t len) {
    if (!s && len != 0) return nullptr;
    if (len < 0) {
        if (!s) return nullptr;
        len = static_cast<std::int64_t>(std::strlen(s));
    }
    try {
        return static_cast<TJsonHnd>(
            new json(std::string(s, static_cast<std::size_t>(len)))
        );
    } catch (...) {
        return nullptr;
    }
}

TJsonHnd LF_JSON_CDECL lf_json_new_array(void) {
    try { return static_cast<TJsonHnd>(new json(json::array())); }
    catch (...) { return nullptr; }
}

TJsonHnd LF_JSON_CDECL lf_json_new_object(void) {
    try { return static_cast<TJsonHnd>(new json(json::object())); }
    catch (...) { return nullptr; }
}

int LF_JSON_CDECL lf_json_object_set(
    TJsonHnd parent, const char* key, std::int64_t key_len, TJsonHnd child) {
    if (!parent || !key || key_len < 0 || !child) return 0;
    auto* p = static_cast<json*>(parent);
    auto* c = static_cast<json*>(child);
    if (!p->is_object()) return 0;
    try {
        (*p)[std::string(key, static_cast<std::size_t>(key_len))] = *c;
        return 1;
    } catch (...) {
        return 0;
    }
}

int LF_JSON_CDECL lf_json_array_push(TJsonHnd parent, TJsonHnd child) {
    if (!parent || !child) return 0;
    auto* p = static_cast<json*>(parent);
    auto* c = static_cast<json*>(child);
    if (!p->is_array()) return 0;
    try {
        p->push_back(*c);
        return 1;
    } catch (...) {
        return 0;
    }
}

// ============================================================================
// Streaming writer
// ============================================================================

TJsonWriter LF_JSON_CDECL lf_json_writer_new(void) {
    try { return static_cast<TJsonWriter>(new Writer()); }
    catch (...) { return nullptr; }
}

void LF_JSON_CDECL lf_json_writer_free(TJsonWriter w) {
    if (!w) return;
    delete static_cast<Writer*>(w);
}

void LF_JSON_CDECL lf_json_writer_raw(
    TJsonWriter w, const char* s, std::int64_t len) {
    if (!w) return;
    auto* wr = static_cast<Writer*>(w);
    if (!s || len < 0) { wr->failed = true; return; }
    wr->append(s, static_cast<std::size_t>(len));
}

void LF_JSON_CDECL lf_json_writer_string(
    TJsonWriter w, const char* s, std::int64_t len) {
    if (!w) return;
    static_cast<Writer*>(w)->write_string(s, len);
}

void LF_JSON_CDECL lf_json_writer_int64(TJsonWriter w, std::int64_t v) {
    if (!w) return;
    static_cast<Writer*>(w)->write_number(v);
}

void LF_JSON_CDECL lf_json_writer_uint64(TJsonWriter w, std::uint64_t v) {
    if (!w) return;
    static_cast<Writer*>(w)->write_number(v);
}

void LF_JSON_CDECL lf_json_writer_double(TJsonWriter w, double v) {
    if (!w) return;
    static_cast<Writer*>(w)->write_number(v);
}

void LF_JSON_CDECL lf_json_writer_bool(TJsonWriter w, int v) {
    if (!w) return;
    auto* wr = static_cast<Writer*>(w);
    if (v) {
        wr->append_literal("true");
    } else {
        wr->append_literal("false");
    }
}

void LF_JSON_CDECL lf_json_writer_null(TJsonWriter w) {
    if (!w) return;
    static_cast<Writer*>(w)->append_literal("null");
}

std::int64_t LF_JSON_CDECL lf_json_writer_size(TJsonWriter w) {
    if (!w) return -1;
    auto* wr = static_cast<Writer*>(w);
    if (wr->failed) return -1;
    return static_cast<std::int64_t>(wr->buf.size());
}

std::int64_t LF_JSON_CDECL lf_json_writer_into(
    TJsonWriter w, char* buf, std::int64_t buf_size) {
    if (!w || !buf || buf_size < 0) return -1;
    auto* wr = static_cast<Writer*>(w);
    if (wr->failed) return -1;
    const std::int64_t n = static_cast<std::int64_t>(wr->buf.size());
    if (n > buf_size) return -1;
    if (n > 0) {
        std::memcpy(buf, wr->buf.data(), static_cast<std::size_t>(n));
    }
    return n;
}