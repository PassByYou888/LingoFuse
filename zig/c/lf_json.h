/**
 * @file lf_json.h
 * @brief C ABI wrapper around nlohmann/json, designed for the Zig binding.
 *
 * ============================================================================
 * WHY THIS LIBRARY EXISTS
 * ============================================================================
 *
 * The LingoFuse Zig binding needs a JSON engine that is byte-for-byte
 * compatible with the C++ / C# / Python / Rust / JavaScript bindings. All
 * of them agree on the same wire policy:
 *
 *   - Compact output       : no indentation, no trailing newline.
 *   - Literal UTF-8        : non-ASCII characters are emitted as raw
 *                            UTF-8, never as \uXXXX escapes.
 *   - Control-character    : escaped as \" \\ \n \r \t \b \f, and
 *     escaping               \u00XX for the remaining U+0000..U+001F.
 *   - Numeric formatting   : nlohmann's Grisu2, round-trip safe.
 *
 * Rather than re-implement that policy in Zig, this library exposes the
 * exact same nlohmann/json instance used by the C++ binding through a
 * small, opaque, C ABI. Zig code calls `lf_json_*` functions; the C++
 * compiler does the work.
 *
 * ============================================================================
 * DESIGN
 * ============================================================================
 *
 *   - Opaque handles (`TJsonHnd`, `TJsonWriter`) replace C++ objects.
 *   - All functions are C-ABI: no C++ types cross the boundary.
 *   - No exceptions cross the boundary. A failure is signalled by a
 *     return value (NULL, -1, or 0 depending on the function).
 *   - The library is thread-safe for disjoint handles. A single handle
 *     must not be written from multiple threads concurrently.
 *   - No global state, except a per-process error buffer used by
 *     `lf_json_parse` on failure.
 *
 * ============================================================================
 * TWO ENTRY POINTS
 * ============================================================================
 *
 *   PARSING / QUERYING
 *       `lf_json_parse` -> `TJsonHnd`
 *       Walk the tree with `lf_json_type`, `lf_json_object_*`,
 *       `lf_json_array_*`, `lf_json_get_*`, `lf_json_string_*`.
 *       Serialize back with `lf_json_dump_size` / `lf_json_dump_into`.
 *       Release with `lf_json_free`.
 *
 *   BUILDING / SERIALIZING
 *       Two equivalent approaches:
 *
 *         (a) DOM-builder: `lf_json_new_*` + `lf_json_object_set` /
 *             `lf_json_array_push`, then `lf_json_dump_*`.
 *
 *         (b) Streaming writer: `lf_json_writer_new` + `writer_string`,
 *             `writer_int64`, `writer_raw` (for punctuation), then
 *             `writer_size` / `writer_into`.
 *
 *       The streaming writer is the recommended path for generic
 *       serialization of Zig values, because it avoids building an
 *       intermediate DOM. The DOM builder is useful when a caller needs
 *       to manipulate the tree before serializing.
 *
 * ============================================================================
 * COMPATIBILITY CONTRACT
 * ============================================================================
 *
 * Every value produced by `lf_json_dump_*` or `lf_json_writer_*` is
 * byte-identical to what the C++ binding produces for the same logical
 * payload via:
 *
 *     j.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace)
 *
 * That is the single source of truth for the cross-language wire format.
 */

#ifndef LF_JSON_H_INCLUDED
#define LF_JSON_H_INCLUDED

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Calling convention
 * ============================================================================
 *
 * The library uses the C calling convention (`cdecl`) on all platforms.
 * On Windows x86-64 this is the only convention; on Windows x86-32 it is
 * the default for `extern "C"` declarations. On non-Windows platforms
 * the macro expands to nothing.
 */
#if defined(_WIN32)
#  if defined(__GNUC__) || defined(__clang__)
#    define LF_JSON_CDECL __attribute__((cdecl))
#  else
#    define LF_JSON_CDECL __cdecl
#  endif
#else
#  define LF_JSON_CDECL
#endif

/* ============================================================================
 * Opaque handle types
 * ============================================================================ */

/** Opaque handle to a nlohmann::json tree node (root of a parsed or built
 *  document). Never dereference. Release with `lf_json_free`. */
typedef void* TJsonHnd;

/** Opaque handle to a streaming writer. Release with `lf_json_writer_free`. */
typedef void* TJsonWriter;

/* ============================================================================
 * JSON type tags
 * ============================================================================
 *
 * Mirrors nlohmann::json::value_t. The numeric values are the ABI contract
 * and must never change.
 */
enum {
    LF_JSON_NULL      = 0,   /**< JSON null.                              */
    LF_JSON_BOOL      = 1,   /**< JSON boolean.                           */
    LF_JSON_INT       = 2,   /**< Signed integer (nlohmann number_integer). */
    LF_JSON_UINT      = 3,   /**< Unsigned integer (number_unsigned).     */
    LF_JSON_FLOAT     = 4,   /**< Floating-point (number_float).          */
    LF_JSON_STRING    = 5,   /**< UTF-8 string.                           */
    LF_JSON_ARRAY     = 6,   /**< Array.                                  */
    LF_JSON_OBJECT    = 7,   /**< Object.                                 */
    LF_JSON_BINARY    = 8,   /**< Binary (not produced by the parser).    */
    LF_JSON_DISCARDED = 9    /**< Discarded (only from lenient parsing).  */
};

/* ============================================================================
 * Parsing
 * ============================================================================ */

/**
 * Parse a UTF-8 JSON document.
 *
 * @param text  Pointer to the JSON text. Must not be NULL when `len > 0`.
 * @param len   Number of bytes. Pass a negative value to treat `text` as
 *              a NUL-terminated C string and compute its length with
 *              `strlen`.
 *
 * @return A new handle owning the parsed tree, or NULL on failure. On
 *         failure, `lf_json_last_error` returns a human-readable
 *         description. The caller owns the handle and must release it
 *         with `lf_json_free`.
 */
TJsonHnd LF_JSON_CDECL lf_json_parse(const char* text, int64_t len);

/**
 * Describe the most recent parse failure.
 *
 * @return A pointer to a process-wide static buffer, valid until the next
 *         call to `lf_json_parse`. The string is NUL-terminated UTF-8.
 *         Returns an empty string if the last parse succeeded.
 */
const char* LF_JSON_CDECL lf_json_last_error(void);

/**
 * Release a handle. NULL is accepted and ignored.
 *
 * After this call, the handle is invalid and must not be used again.
 */
void LF_JSON_CDECL lf_json_free(TJsonHnd hnd);

/**
 * Query the JSON type of a handle.
 *
 * @return One of the `LF_JSON_*` tags, or -1 if the handle is NULL.
 */
int LF_JSON_CDECL lf_json_type(TJsonHnd hnd);

/* ============================================================================
 * Serialization
 * ============================================================================ */

/**
 * Compute the byte length of the canonical serialization of a handle.
 *
 * The output excludes the trailing NUL. The canonical policy is:
 *   - compact (no indentation),
 *   - literal UTF-8 (no \uXXXX for non-ASCII),
 *   - control characters escaped per JSON.
 *
 * @return The number of bytes needed (>= 0), or -1 on failure.
 */
int64_t LF_JSON_CDECL lf_json_dump_size(TJsonHnd hnd);

/**
 * Serialize a handle into a caller-supplied buffer.
 *
 * `buf_size` must be at least `lf_json_dump_size(hnd) + 1` to leave room
 * for the trailing NUL that this function writes.
 *
 * @return The number of bytes written (excluding the NUL), or -1 on
 *         failure. On failure the buffer contents are undefined.
 */
int64_t LF_JSON_CDECL lf_json_dump_into(
    TJsonHnd hnd, char* buf, int64_t buf_size);

/* ============================================================================
 * Value reads
 * ============================================================================
 *
 * Each function returns 1 on success and 0 on failure. Failure means:
 *   - the handle is NULL,
 *   - the output pointer is NULL,
 *   - the node's type is incompatible with the requested conversion, or
 *   - the numeric value is out of the target type's range.
 *
 * No exception is raised across the ABI boundary.
 */

int LF_JSON_CDECL lf_json_get_bool  (TJsonHnd hnd, int*      out);
int LF_JSON_CDECL lf_json_get_int64 (TJsonHnd hnd, int64_t*  out);
int LF_JSON_CDECL lf_json_get_uint64(TJsonHnd hnd, uint64_t* out);
int LF_JSON_CDECL lf_json_get_double(TJsonHnd hnd, double*   out);

/**
 * Byte length of a string node's UTF-8 content.
 *
 * @return The byte count (excluding any NUL), or -1 if the handle is
 *         NULL or the node is not a string.
 */
int64_t LF_JSON_CDECL lf_json_string_size(TJsonHnd hnd);

/**
 * Copy a string node's UTF-8 content into a caller-supplied buffer.
 * No trailing NUL is written.
 *
 * @return The number of bytes written, or -1 on failure (NULL handle,
 *         not a string, or buffer too small).
 */
int64_t LF_JSON_CDECL lf_json_string_into(
    TJsonHnd hnd, char* buf, int64_t buf_size);

/* ============================================================================
 * Object access
 * ============================================================================ */

/**
 * Number of key/value pairs in an object.
 *
 * @return The count, or -1 if the handle is NULL or not an object.
 */
int64_t LF_JSON_CDECL lf_json_object_size(TJsonHnd hnd);

/**
 * Copy the key at position `idx` (0-based, in object iteration order)
 * into `buf`. No trailing NUL is written.
 *
 * Object iteration order is std::map order, i.e. lexicographic by
 * UTF-8 byte sequence, matching the C++ binding exactly.
 *
 * @return The number of bytes written, or -1 on failure.
 */
int64_t LF_JSON_CDECL lf_json_object_key_into(
    TJsonHnd hnd, int64_t idx, char* buf, int64_t buf_size);

/**
 * Look up a child by key. The child is returned as a DEEP COPY in a new
 * handle that the caller owns and must release with `lf_json_free`.
 *
 * @param key      Key bytes; need not be NUL-terminated.
 * @param key_len  Key length in bytes.
 *
 * @return A new handle, or NULL if the handle is not an object, the key
 *         is absent, or allocation failed.
 */
TJsonHnd LF_JSON_CDECL lf_json_object_get(
    TJsonHnd hnd, const char* key, int64_t key_len);

/* ============================================================================
 * Array access
 * ============================================================================ */

/**
 * Number of elements in an array.
 *
 * @return The count, or -1 if the handle is NULL or not an array.
 */
int64_t LF_JSON_CDECL lf_json_array_size(TJsonHnd hnd);

/**
 * Look up a child by index. The child is a DEEP COPY in a new handle
 * that the caller owns and must release with `lf_json_free`.
 *
 * @return A new handle, or NULL on failure (not an array, out of range,
 *         or allocation failure).
 */
TJsonHnd LF_JSON_CDECL lf_json_array_get(TJsonHnd hnd, int64_t idx);

/* ============================================================================
 * Build (DOM)
 * ============================================================================
 *
 * Every `lf_json_new_*` returns a new, caller-owned handle. Every
 * `lf_json_object_set` / `lf_json_array_push` deep-copies the child into
 * the parent; the child handle remains valid and must still be released
 * by the caller.
 *
 * This makes the ownership rule uniform: whoever receives a handle from a
 * `new_*` call owns it and is responsible for calling `lf_json_free`.
 */

TJsonHnd LF_JSON_CDECL lf_json_new_null   (void);
TJsonHnd LF_JSON_CDECL lf_json_new_bool   (int value);
TJsonHnd LF_JSON_CDECL lf_json_new_int64  (int64_t value);
TJsonHnd LF_JSON_CDECL lf_json_new_uint64 (uint64_t value);
TJsonHnd LF_JSON_CDECL lf_json_new_double (double value);
TJsonHnd LF_JSON_CDECL lf_json_new_string (const char* s, int64_t len);
TJsonHnd LF_JSON_CDECL lf_json_new_array  (void);
TJsonHnd LF_JSON_CDECL lf_json_new_object (void);

/**
 * Insert or replace a key/value pair in an object.
 *
 * @return 1 on success, 0 on failure (NULL argument, parent not an
 *         object, or allocation failure).
 */
int LF_JSON_CDECL lf_json_object_set(
    TJsonHnd parent, const char* key, int64_t key_len, TJsonHnd child);

/**
 * Append a value to an array.
 *
 * @return 1 on success, 0 on failure.
 */
int LF_JSON_CDECL lf_json_array_push(TJsonHnd parent, TJsonHnd child);

/* ============================================================================
 * Streaming writer
 * ============================================================================
 *
 * A writer accumulates JSON text in an internal buffer. The caller drives
 * it with a sequence of typed writes. Punctuation (`{`, `}`, `[`, `]`,
 * `:`, `,`) is emitted via `writer_raw`. String values go through
 * `writer_string`, which applies the canonical escaping policy.
 *
 * The writer is the recommended path when a caller is walking a Zig
 * `@typeInfo(T)` tree and wants to emit the wire bytes without building
 * an intermediate DOM.
 *
 * Thread safety: a single writer must not be used from multiple threads.
 * Different writers are independent.
 */

TJsonWriter LF_JSON_CDECL lf_json_writer_new  (void);
void        LF_JSON_CDECL lf_json_writer_free (TJsonWriter w);

/** Emit a raw fragment. The caller guarantees it is valid JSON syntax. */
void LF_JSON_CDECL lf_json_writer_raw(
    TJsonWriter w, const char* s, int64_t len);

/** Emit a string value with quotes and canonical escaping. */
void LF_JSON_CDECL lf_json_writer_string(
    TJsonWriter w, const char* s, int64_t len);

/** Emit an integer value. */
void LF_JSON_CDECL lf_json_writer_int64 (TJsonWriter w, int64_t  v);
void LF_JSON_CDECL lf_json_writer_uint64(TJsonWriter w, uint64_t v);

/**
 * Emit a floating-point value.
 *
 * The formatting is nlohmann's, which is Grisu2-based and round-trip
 * safe. NaN and infinity are emitted as the JSON literal `null`, matching
 * the C++ / C# / JavaScript bindings.
 */
void LF_JSON_CDECL lf_json_writer_double(TJsonWriter w, double v);

/** Emit `true` or `false`. */
void LF_JSON_CDECL lf_json_writer_bool(TJsonWriter w, int v);

/** Emit `null`. */
void LF_JSON_CDECL lf_json_writer_null(TJsonWriter w);

/**
 * Current byte length of the accumulated output.
 *
 * @return The byte count (>= 0), or -1 if the writer is NULL or has
 *         entered an error state (a previous write failed).
 */
int64_t LF_JSON_CDECL lf_json_writer_size(TJsonWriter w);

/**
 * Copy the accumulated output into a caller-supplied buffer. No trailing
 * NUL is written.
 *
 * @return The number of bytes written, or -1 on failure (NULL writer,
 *         buffer too small, or the writer is in an error state).
 */
int64_t LF_JSON_CDECL lf_json_writer_into(
    TJsonWriter w, char* buf, int64_t buf_size);

#ifdef __cplusplus
}
#endif

#endif /* LF_JSON_H_INCLUDED */