#ifndef LINGOFUSE_IO_HPP_INCLUDED
#define LINGOFUSE_IO_HPP_INCLUDED

/**
 * @file lf_io.hpp
 * @brief Unified JSON and string I/O for LingoFuse data handles (C++17).
 *
 * This header is the C++ counterpart of the Python module
 * `lingofuse.lf_io`. It is the SINGLE place in the C++ toolchain where
 * C++ objects are converted to, and from, the bytes carried by a
 * LingoFuse data handle (TDataHnd). Every service that touches a
 * TDataHnd should use the helpers defined here instead of calling
 * LF_WriteBuffer / LF_ReadBuffer / nlohmann::json::dump /
 * nlohmann::json::parse directly.
 *
 * ============================================================================
 * DEPENDENCY DIRECTION
 * ============================================================================
 *
 *     LingoFuse.h     (C ABI declarations + C helper functions)
 *         ^
 *     lf_io.hpp       (this file - header-only, based on raw TDataHnd)
 *         ^
 *     LingoFuse.hpp   (C++17 RAII wrappers: DataHandle / App /
 *                      LibraryLoader / NetworkEventListener)
 *
 * lf_io.hpp intentionally depends only on LingoFuse.h, NOT on
 * LingoFuse.hpp. This keeps it usable from contexts where the RAII
 * wrapper is not available, for example inside a plain C++ callback
 * that receives a raw TDataHnd from the framework.
 *
 * ============================================================================
 * WIRE FORMAT
 * ============================================================================
 *
 * A JSON payload on a data handle is:
 *
 *     [UTF-8 encoded JSON text][NUL byte]
 *
 * A plain-text payload uses the same framing:
 *
 *     [UTF-8 text][NUL byte]
 *
 * A raw binary payload uses:
 *
 *     [arbitrary bytes]          (no NUL, no framing)
 *
 * The receiving side (read_json / read_string / read_string_bytes) is
 * fault-tolerant: if no NUL is found before the end of the buffer, the
 * entire remaining buffer is consumed. This makes the reader tolerant
 * of payloads that arrive from an HTTP bridge or any other producer
 * that does not append a NUL.
 *
 * ============================================================================
 * COMPATIBILITY WITH THE PASCAL AND PYTHON SIDES
 * ============================================================================
 *
 * The framing matches lingofuse_import.pas and lingofuse.lf_io exactly:
 *
 *     Pascal LF_WriteString('{"a":1}')
 *         -> bytes  7B 22 61 22 3A 31 7D 00
 *
 *     Python lf_io.write_json(hnd, {"a": 1})
 *         -> bytes  7B 22 61 22 3A 31 7D 00
 *
 *     C++ io::write_json(hnd, {{"a", 1}})
 *         -> bytes  7B 22 61 22 3A 31 7D 00
 *
 * All three producers emit the same byte sequence for the same logical
 * payload, and all three readers follow the same three-case rule:
 *
 *     Case 1 - a NUL is found:
 *         Return the bytes before it, advance the cursor past the NUL.
 *
 *     Case 2 - no NUL is found:
 *         Return the entire remaining buffer, advance the cursor to
 *         (buffer size + 1). The underlying library implicitly grows
 *         the buffer by one byte to accommodate the new position. This
 *         matches Pascal's LF_SetPos(Hnd, e + 1) with e == size.
 *
 *     Case 3 - the cursor is at or past the end:
 *         Return an empty result, cursor unchanged.
 *
 * ============================================================================
 * JSON SERIALIZATION POLICY
 * ============================================================================
 *
 * Every JSON string produced by this toolchain goes through dumps_json().
 * That function is the single source of truth for the serialization
 * policy. Its three properties are:
 *
 *     - Compact output, no indentation, no trailing newline.
 *     - ensure_ascii = false, so non-ASCII characters are emitted as
 *       literal UTF-8, not as \\uXXXX escapes.
 *     - error_handler_t::replace, so invalid UTF-8 bytes in
 *       std::string values are replaced with U+FFFD instead of
 *       aborting the serialization.
 *
 * This matches the Python policy:
 *
 *     json.dumps(obj, ensure_ascii=False, default=str)
 *
 * Difference from the Python policy that is inherent to C++:
 *
 *     `default=str` in Python silently coerces unknown types to their
 *     string representation. In C++ there is no runtime "unknown
 *     type"; the caller must either supply a json-convertible value
 *     or provide an ADL `to_json` overload. The static type system
 *     handles the equivalent of Python's `default=str` at compile
 *     time.
 *
 * ============================================================================
 * THREAD SAFETY
 * ============================================================================
 *
 * Every helper is stateless. Concurrent access to the SAME TDataHnd
 * must still be serialized by the caller, matching the contract
 * documented in LingoFuse.h.
 *
 * ============================================================================
 * ERROR HANDLING
 * ============================================================================
 *
 * All failures throw `lingofuse::io::LfIoError`, which derives from
 * std::runtime_error. There is no silent failure path. Every helper
 * therefore documents which error conditions can be raised.
 *
 * ============================================================================
 * NAMESPACE AND NAMING
 * ============================================================================
 *
 * All public symbols live in `lingofuse::io`. Internal helpers live in
 * `lingofuse::io::detail` and are not part of the public API.
 *
 * The function names intentionally mirror the Python module
 * `lingofuse.lf_io`:
 *
 *     dumps_json          <->  lf_io.dumps_json
 *     loads_json          <->  (no Python equivalent; Python uses
 *                               json.loads directly)
 *     write_string        <->  lf_io.write_string
 *     write_string_bytes  <->  lf_io.write_string_bytes
 *     read_string         <->  lf_io.read_string
 *     read_string_bytes   <->  lf_io.read_string_bytes
 *     peek_string_bytes   <->  lf_io.peek_string_bytes
 *     read_all_bytes      <->  lf_io.read_all_bytes
 *     write_json          <->  lf_io.write_json
 *     read_json           <->  lf_io.read_json
 *     read_json_or_bytes  <->  lf_io.read_json_or_bytes
 *     cstr                <->  lf_io.cstr
 *
 * ============================================================================
 * USAGE EXAMPLE
 * ============================================================================
 *
 * @code
 * #include "lf_io.hpp"
 * #include <iostream>
 *
 * static void LF_CDECL add_cb(void*, void* in, void* out) {
 *     using namespace lingofuse::io;
 *     auto req = read_json(static_cast<TDataHnd>(in));
 *     const int a = req.at("a").get<int>();
 *     const int b = req.at("b").get<int>();
 *     write_json(static_cast<TDataHnd>(out), {{"result", a + b}});
 * }
 * @endcode
 */

#include "LingoFuse.h"   // TDataHnd, LF_GetBuffer, LF_ReadBuffer, ...
#include "json.hpp"      // nlohmann::json

#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace lingofuse {
    namespace io {

        // ============================================================================
        // Constants
        // ============================================================================

        /// The NUL byte used as the string terminator on the wire.
        inline constexpr std::uint8_t NUL_BYTE = 0x00;

        /// The only text encoding used on the wire. Matches Pascal's UTF-8
        /// convention and the Python lf_io module.
        inline constexpr const char* ENCODING = "utf-8";

        // ============================================================================
        // Error type
        // ============================================================================

        /**
         * @brief Exception thrown by all helpers in this header on failure.
         *
         * Derives from std::runtime_error, so a plain
         * `catch (const std::exception&)` still works. Use this type to
         * distinguish I/O failures raised by the unified payload layer from
         * other exceptions in the surrounding code.
         */
        class LfIoError : public std::runtime_error {
        public:
            explicit LfIoError(const std::string& what)
                : std::runtime_error(what) {}
        };

        // ============================================================================
        // JSON serialization policy
        // ============================================================================

        /**
         * @brief Serialize a JSON value to a compact UTF-8 string.
         *
         * Policy (single source of truth for the whole C++ toolchain):
         *
         *   - Compact output: no indentation, no trailing newline.
         *   - ensure_ascii = false: non-ASCII characters are emitted as
         *     literal UTF-8, not as \\uXXXX escapes. This makes the output
         *     byte-identical to what the Python lf_io.dumps_json() produces
         *     for the same value.
         *   - error_handler_t::replace: invalid UTF-8 sequences in std::string
         *     values are replaced with U+FFFD instead of causing an exception.
         *
         * The returned string does NOT include a trailing NUL byte. Callers
         * that want to write it to a data handle with the required NUL
         * terminator should use write_json() or write_string() instead.
         *
         * @param obj The JSON value to serialize.
         * @return The compact UTF-8 JSON text.
         */
        inline std::string dumps_json(const nlohmann::json& obj) {
            return obj.dump(
                -1,                                     // compact, no indent
                ' ',                                    // indent char (unused)
                false,                                  // ensure_ascii = false
                nlohmann::json::error_handler_t::replace
            );
        }

        /**
         * @brief Parse a UTF-8 JSON string into a JSON value.
         *
         * Mirrors the strict behaviour of Python's json.loads: any syntax
         * error or invalid UTF-8 sequence raises LfIoError. Leading and
         * trailing whitespace is ignored. A UTF-8 BOM is NOT skipped; strip
         * it yourself if you need to accept BOM-prefixed input.
         *
         * @param text A UTF-8 JSON document.
         * @return The parsed JSON value.
         * @throws LfIoError if the text is not valid JSON.
         */
        inline nlohmann::json loads_json(std::string_view text) {
            try {
                return nlohmann::json::parse(text.begin(), text.end());
            }
            catch (const nlohmann::json::parse_error& e) {
                throw LfIoError(
                    std::string("lf_io::loads_json: invalid JSON: ") + e.what()
                );
            }
        }

        /**
         * @brief Parse a UTF-8 JSON byte sequence into a JSON value.
         *
         * Convenience overload for callers that already hold the raw bytes
         * (for example, the result of read_string_bytes()).
         *
         * @param bytes A UTF-8 JSON document.
         * @return The parsed JSON value.
         * @throws LfIoError if the bytes are not valid JSON.
         */
        inline nlohmann::json loads_json(const std::vector<std::uint8_t>& bytes) {
            return loads_json(std::string_view(
                reinterpret_cast<const char*>(bytes.data()),
                bytes.size()
            ));
        }

        // ============================================================================
        // Internal helpers
        // ============================================================================
        //
        // These functions are the ONLY places in the C++ toolchain that touch
        // LF_WriteBuffer / LF_ReadBuffer / LF_GetBuffer / LF_GetPos /
        // LF_GetSize / LF_SetPos for payload I/O. Everything else goes through
        // the public API below.
        //
        // Do not call anything in this namespace from outside this header.

        namespace detail {

            /// Append raw bytes to a handle at the current position.
            /// Raises LfIoError on a short write.
            inline void write_bytes(TDataHnd hnd, const void* data, std::size_t len) {
                if (len == 0) {
                    return;
                }
                if (hnd == nullptr) {
                    throw LfIoError("lf_io::detail::write_bytes: null handle");
                }
                if (data == nullptr) {
                    throw LfIoError(
                        "lf_io::detail::write_bytes: null data with len > 0"
                    );
                }

                const auto written = LF_WriteBuffer(
                    hnd, data, static_cast<std::int64_t>(len)
                );
                if (written != static_cast<std::int64_t>(len)) {
                    throw LfIoError(
                        "lf_io::detail::write_bytes: short write ("
                        + std::to_string(written) + " of "
                        + std::to_string(len) + " bytes)"
                    );
                }
            }

            /// Read bytes from the current position up to the first NUL (or the
            /// end of the buffer), and advance the position past the NUL (or to
            /// size + 1 when no NUL was found).
            ///
            /// This is the exact behaviour of Pascal's LF_ReadString and the
            /// Python lf_io._read_until_nul helper.
            inline std::vector<std::uint8_t> read_until_nul(TDataHnd hnd) {
                if (hnd == nullptr) {
                    throw LfIoError("lf_io::detail::read_until_nul: null handle");
                }

                const auto start = LF_GetPos(hnd);
                const auto total = LF_GetSize(hnd);
                if (start < 0 || start >= total) {
                    // Cursor at or past the end of the buffer: nothing to read.
                    return {};
                }

                const auto* base = static_cast<const std::uint8_t*>(
                    LF_GetBuffer(hnd)
                    );
                if (base == nullptr) {
                    return {};
                }

                std::int64_t end = start;
                while (end < total && base[end] != NUL_BYTE) {
                    ++end;
                }

                const auto len = static_cast<std::size_t>(end - start);

                std::vector<std::uint8_t> result;
                if (len > 0) {
                    result.assign(base + start, base + end);
                }

                // Advance the cursor:
                //   - When a NUL was found (end < total), skip past it: end + 1.
                //   - When no NUL was found (end == total), move to total + 1.
                //     The underlying library implicitly grows the buffer by one
                //     byte to accommodate the new position. This matches
                //     Pascal's LF_SetPos(Hnd, e + 1) with e == size.
                LF_SetPos(hnd, end + 1);

                return result;
            }

            /// Read all remaining bytes from the handle, without NUL handling.
            /// The cursor is advanced to the end of the buffer.
            inline std::vector<std::uint8_t> read_all(TDataHnd hnd) {
                if (hnd == nullptr) {
                    throw LfIoError("lf_io::detail::read_all: null handle");
                }

                const auto start = LF_GetPos(hnd);
                const auto total = LF_GetSize(hnd);
                if (start < 0 || start >= total) {
                    return {};
                }

                const auto len = total - start;
                std::vector<std::uint8_t> result(static_cast<std::size_t>(len));

                const auto got = LF_ReadBuffer(hnd, result.data(), len);
                if (got != len) {
                    throw LfIoError(
                        "lf_io::detail::read_all: short read ("
                        + std::to_string(got) + " of "
                        + std::to_string(len) + " bytes)"
                    );
                }

                return result;
            }

        } // namespace detail

        // ============================================================================
        // String I/O
        // ============================================================================

        /**
         * @brief Write `value` as UTF-8 bytes, followed by a NUL terminator.
         *
         * An empty string is written as a single NUL byte, matching Pascal's
         * LF_WriteString('').
         *
         * @param hnd   Target data handle.
         * @param value UTF-8 text. May be empty.
         * @throws LfIoError if the handle is null or a write fails.
         */
        inline void write_string(TDataHnd hnd, std::string_view value) {
            if (hnd == nullptr) {
                throw LfIoError("lf_io::write_string: null handle");
            }

            if (!value.empty()) {
                detail::write_bytes(hnd, value.data(), value.size());
            }

            const char nul = 0;
            detail::write_bytes(hnd, &nul, 1);
        }

        /**
         * @brief Write raw UTF-8 bytes followed by a NUL terminator.
         *
         * The bytes are NOT validated as UTF-8. Use this only when the bytes
         * are known to be UTF-8 (for example, the output of dumps_json()).
         *
         * @param hnd  Target data handle.
         * @param data Source bytes. May be null only when `len` is 0.
         * @param len  Number of bytes to write (not counting the appended NUL).
         * @throws LfIoError if the handle is null or a write fails.
         */
        inline void write_string_bytes(
            TDataHnd hnd,
            const void* data,
            std::size_t len
        ) {
            if (hnd == nullptr) {
                throw LfIoError("lf_io::write_string_bytes: null handle");
            }

            if (len > 0) {
                detail::write_bytes(hnd, data, len);
            }

            const char nul = 0;
            detail::write_bytes(hnd, &nul, 1);
        }

        /**
         * @brief Convenience overload for std::vector<std::uint8_t>.
         *
         * @param hnd  Target data handle.
         * @param data Source bytes.
         * @throws LfIoError if the handle is null or a write fails.
         */
        inline void write_string_bytes(
            TDataHnd hnd,
            const std::vector<std::uint8_t>& data
        ) {
            write_string_bytes(hnd, data.data(), data.size());
        }

        /**
         * @brief Read a UTF-8 string from the handle, stopping at the first NUL.
         *
         * If no NUL is present, the entire remaining buffer is consumed.
         * Returns an empty string when the cursor is at or past the end of
         * the buffer, or when the first byte is a NUL.
         *
         * The bytes are returned as a std::string with no UTF-8 validation
         * performed. Callers that need to reject invalid UTF-8 should use
         * read_string_bytes() and decode explicitly.
         *
         * @param hnd Source data handle.
         * @return The decoded string (possibly empty).
         * @throws LfIoError if the handle is null.
         */
        inline std::string read_string(TDataHnd hnd) {
            const auto bytes = detail::read_until_nul(hnd);
            if (bytes.empty()) {
                return {};
            }
            return std::string(
                reinterpret_cast<const char*>(bytes.data()),
                bytes.size()
            );
        }

        /**
         * @brief Read raw bytes from the handle, stopping at the first NUL.
         *
         * Unlike read_all_bytes(), which consumes the entire remaining buffer,
         * this stops at the NUL that write_string / write_json append. The
         * bytes are returned undecoded, so the caller can inspect or forward
         * them without a UTF-8 round-trip.
         *
         * This is the accessor to use inside a bridge or proxy that forwards
         * a payload unchanged to a downstream consumer.
         *
         * @param hnd Source data handle.
         * @return The bytes before the NUL (possibly empty).
         * @throws LfIoError if the handle is null.
         */
        inline std::vector<std::uint8_t> read_string_bytes(TDataHnd hnd) {
            return detail::read_until_nul(hnd);
        }

        /**
         * @brief Read raw bytes up to the first NUL WITHOUT advancing the cursor.
         *
         * Provided for diagnostic and logging code that needs to inspect the
         * current payload without consuming it. The cursor is restored to its
         * original value before returning, so a subsequent read_string /
         * read_json sees the same bytes.
         *
         * @param hnd Source data handle.
         * @return The bytes before the NUL (possibly empty).
         * @throws LfIoError if the handle is null.
         */
        inline std::vector<std::uint8_t> peek_string_bytes(TDataHnd hnd) {
            if (hnd == nullptr) {
                throw LfIoError("lf_io::peek_string_bytes: null handle");
            }

            const auto saved = LF_GetPos(hnd);
            try {
                auto result = detail::read_until_nul(hnd);
                LF_SetPos(hnd, saved);
                return result;
            }
            catch (...) {
                // Restore the cursor even when the read failed, so that a
                // subsequent operation sees the original state.
                LF_SetPos(hnd, saved);
                throw;
            }
        }

        /**
         * @brief Read all remaining bytes from the handle, without NUL handling.
         *
         * The cursor is advanced to the end of the buffer. Use this for raw
         * binary payloads; use read_string_bytes() for NUL-terminated text
         * or JSON payloads.
         *
         * @param hnd Source data handle.
         * @return The remaining bytes (possibly empty).
         * @throws LfIoError if the handle is null or a read fails.
         */
        inline std::vector<std::uint8_t> read_all_bytes(TDataHnd hnd) {
            return detail::read_all(hnd);
        }

        // ============================================================================
        // JSON I/O
        // ============================================================================

        /**
         * @brief Serialize `obj` as UTF-8 JSON and write it with a NUL terminator.
         *
         * The serialization goes through dumps_json(), so ensure_ascii = false
         * and the error_handler_t::replace policy are guaranteed. The output
         * never contains a \\uXXXX escape for non-ASCII text, and a trailing
         * NUL byte is always appended.
         *
         * @param hnd Target data handle.
         * @param obj The JSON value to write.
         * @throws LfIoError if the handle is null or a write fails.
         */
        inline void write_json(TDataHnd hnd, const nlohmann::json& obj) {
            const std::string text = dumps_json(obj);
            write_string(hnd, text);
        }

        /**
         * @brief Read a UTF-8 JSON payload from the handle and return it.
         *
         * The payload may or may not be NUL-terminated. If a NUL is present,
         * it is treated as the end of the payload; otherwise the entire
         * remaining buffer is consumed.
         *
         * Returns a null JSON value (a default-constructed nlohmann::json)
         * when the buffer contains no bytes at all. This matches the
         * historical convention of the toolchain: an empty payload means
         * "no result". Note that a JSON `null` (the four bytes `null`) also
         * decodes to a null json value; callers that need to distinguish the
         * two must inspect the raw buffer themselves via read_string_bytes().
         *
         * @param hnd Source data handle.
         * @return The parsed JSON value, or a null json value for an empty
         *         payload.
         * @throws LfIoError if the handle is null or the bytes are not valid
         *         JSON.
         */
        inline nlohmann::json read_json(TDataHnd hnd) {
            const auto bytes = detail::read_until_nul(hnd);
            if (bytes.empty()) {
                return nlohmann::json();  // JSON null
            }
            return loads_json(bytes);
        }

        /**
         * @brief Result of a lenient JSON-or-bytes read.
         *
         * A std::variant with three states:
         *
         *   - std::monostate          the handle was empty (no bytes at all)
         *   - nlohmann::json          the payload was valid JSON
         *   - std::vector<uint8_t>    the payload was not JSON; raw bytes
         */
        using JsonOrBytes = std::variant<
            std::monostate,
            nlohmann::json,
            std::vector<std::uint8_t>
        >;

        /**
         * @brief Read a UTF-8 payload and return either the JSON value or the
         *        raw bytes.
         *
         * Semantics:
         *
         *   - Empty payload                -> std::monostate
         *   - Valid JSON                   -> nlohmann::json
         *   - Valid UTF-8 but invalid JSON -> std::vector<std::uint8_t> (raw)
         *   - Invalid UTF-8                -> std::vector<std::uint8_t> (raw)
         *
         * This is a deliberately lenient reader for callers that historically
         * treated a non-JSON response as a payload they should forward or log
         * verbatim, rather than as a protocol error. The canonical example is
         * an MCP bridge: a backend API may return plain text or binary, and
         * the bridge must not reject it merely because it is not JSON.
         *
         * Callers that want strict behaviour (reject anything that is not
         * valid JSON) must use read_json() instead.
         *
         * The handle cursor is advanced past the payload exactly as in
         * read_string_bytes().
         *
         * @param hnd Source data handle.
         * @return A variant holding one of the three states described above.
         * @throws LfIoError if the handle is null.
         */
        inline JsonOrBytes read_json_or_bytes(TDataHnd hnd) {
            const auto bytes = detail::read_until_nul(hnd);
            if (bytes.empty()) {
                return std::monostate{};
            }
            try {
                return loads_json(bytes);
            }
            catch (const LfIoError&) {
                return bytes;
            }
        }

        // ============================================================================
        // C-ABI string parameters
        // ============================================================================

        /**
         * @brief Return a NUL-terminated UTF-8 std::string for an LF_* c_char_p
         *        parameter.
         *
         * Every LF_* string parameter (app name, API name, endpoint, option
         * name, option value) SHOULD be passed through this helper so that
         * the wire contract is explicit at the call site:
         *
         *     LF_PrepareClient(lingofuse::io::cstr(endpoint).c_str(), app);
         *
         * The returned std::string guarantees a trailing NUL byte via its
         * c_str() method, matching the C ABI's expectation. The helper itself
         * does NOT append an extra NUL - std::string already terminates its
         * internal buffer.
         *
         * Note: this helper is primarily for symmetry with the Python lf_io
         * module and for callers that pass std::string_view. For a plain
         * std::string argument, `arg.c_str()` is already sufficient.
         *
         * @param value The text to pass to an LF_* function.
         * @return A std::string whose c_str() is NUL-terminated.
         */
        inline std::string cstr(std::string_view value) {
            return std::string(value);
        }

    } // namespace io
} // namespace lingofuse

#endif // LINGOFUSE_IO_HPP_INCLUDED