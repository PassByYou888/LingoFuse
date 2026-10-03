// =============================================================================
//  json_c.zig - Raw C ABI declarations for the lf_json library.
// -----------------------------------------------------------------------------
//  lf_json is a small C ABI wrapper around nlohmann/json, built from
//  `c/lf_json.cpp` and `c/lf_json.h`. It exposes the exact JSON engine
//  that the C++ binding uses, so JSON produced or consumed by this
//  binding is byte-identical to the C++ binding's output.
//
//  This file is PURE DECLARATION. It contains no logic, no state, and
//  no wrappers. `io.zig` will eventually call these functions from its
//  five public JSON entry points.
//
//  Handle semantics
//  ----------------
//  `JsonHnd` and `JsonWriter` are opaque pointers. A handle is either
//  NULL (invalid) or a live pointer. Every function that returns a
//  handle transfers ownership to the caller, who must release it with
//  `lf_json_free` or `lf_json_writer_free`.
//
//  Failure signalling
//  ------------------
//  There are no exceptions across the C ABI. Failures are reported by:
//
//    - NULL return                : handle-producing functions
//    - -1 return                  : size / dump_into / writer_into
//    - 0 return                   : getters and setters
//    - empty string               : lf_json_last_error on success
//
//  See `c/lf_json.h` for the full contract.
// =============================================================================

/// Opaque handle to a parsed or built JSON tree.
pub const JsonHnd = ?*anyopaque;

/// Opaque handle to a streaming writer.
pub const JsonWriter = ?*anyopaque;

// -----------------------------------------------------------------------------
// Type tags. Mirror nlohmann::json::value_t and the LF_JSON_* macros in
// c/lf_json.h. The numeric values are part of the ABI contract.
// -----------------------------------------------------------------------------

pub const TAG_NULL: c_int = 0;
pub const TAG_BOOL: c_int = 1;
pub const TAG_INT: c_int = 2;
pub const TAG_UINT: c_int = 3;
pub const TAG_FLOAT: c_int = 4;
pub const TAG_STRING: c_int = 5;
pub const TAG_ARRAY: c_int = 6;
pub const TAG_OBJECT: c_int = 7;
pub const TAG_BINARY: c_int = 8;
pub const TAG_DISCARDED: c_int = 9;

// -----------------------------------------------------------------------------
// Parsing
// -----------------------------------------------------------------------------

pub extern fn lf_json_parse(text: ?[*]const u8, len: i64) JsonHnd;
pub extern fn lf_json_last_error() ?[*:0]const u8;
pub extern fn lf_json_free(hnd: JsonHnd) void;
pub extern fn lf_json_type(hnd: JsonHnd) c_int;

// -----------------------------------------------------------------------------
// Serialization
// -----------------------------------------------------------------------------

pub extern fn lf_json_dump_size(hnd: JsonHnd) i64;
pub extern fn lf_json_dump_into(
    hnd: JsonHnd,
    buf: ?[*]u8,
    buf_size: i64,
) i64;

// -----------------------------------------------------------------------------
// Value reads
// -----------------------------------------------------------------------------

pub extern fn lf_json_get_bool(hnd: JsonHnd, out: ?*c_int) c_int;
pub extern fn lf_json_get_int64(hnd: JsonHnd, out: ?*i64) c_int;
pub extern fn lf_json_get_uint64(hnd: JsonHnd, out: ?*u64) c_int;
pub extern fn lf_json_get_double(hnd: JsonHnd, out: ?*f64) c_int;

pub extern fn lf_json_string_size(hnd: JsonHnd) i64;
pub extern fn lf_json_string_into(
    hnd: JsonHnd,
    buf: ?[*]u8,
    buf_size: i64,
) i64;

// -----------------------------------------------------------------------------
// Object access
// -----------------------------------------------------------------------------

pub extern fn lf_json_object_size(hnd: JsonHnd) i64;
pub extern fn lf_json_object_key_into(
    hnd: JsonHnd,
    idx: i64,
    buf: ?[*]u8,
    buf_size: i64,
) i64;
pub extern fn lf_json_object_get(
    hnd: JsonHnd,
    key: ?[*]const u8,
    key_len: i64,
) JsonHnd;

// -----------------------------------------------------------------------------
// Array access
// -----------------------------------------------------------------------------

pub extern fn lf_json_array_size(hnd: JsonHnd) i64;
pub extern fn lf_json_array_get(hnd: JsonHnd, idx: i64) JsonHnd;

// -----------------------------------------------------------------------------
// DOM build
// -----------------------------------------------------------------------------

pub extern fn lf_json_new_null() JsonHnd;
pub extern fn lf_json_new_bool(value: c_int) JsonHnd;
pub extern fn lf_json_new_int64(value: i64) JsonHnd;
pub extern fn lf_json_new_uint64(value: u64) JsonHnd;
pub extern fn lf_json_new_double(value: f64) JsonHnd;
pub extern fn lf_json_new_string(s: ?[*]const u8, len: i64) JsonHnd;
pub extern fn lf_json_new_array() JsonHnd;
pub extern fn lf_json_new_object() JsonHnd;

pub extern fn lf_json_object_set(
    parent: JsonHnd,
    key: ?[*]const u8,
    key_len: i64,
    child: JsonHnd,
) c_int;
pub extern fn lf_json_array_push(parent: JsonHnd, child: JsonHnd) c_int;

// -----------------------------------------------------------------------------
// Streaming writer
// -----------------------------------------------------------------------------

pub extern fn lf_json_writer_new() JsonWriter;
pub extern fn lf_json_writer_free(w: JsonWriter) void;

pub extern fn lf_json_writer_raw(
    w: JsonWriter,
    s: ?[*]const u8,
    len: i64,
) void;
pub extern fn lf_json_writer_string(
    w: JsonWriter,
    s: ?[*]const u8,
    len: i64,
) void;
pub extern fn lf_json_writer_int64(w: JsonWriter, v: i64) void;
pub extern fn lf_json_writer_uint64(w: JsonWriter, v: u64) void;
pub extern fn lf_json_writer_double(w: JsonWriter, v: f64) void;
pub extern fn lf_json_writer_bool(w: JsonWriter, v: c_int) void;
pub extern fn lf_json_writer_null(w: JsonWriter) void;

pub extern fn lf_json_writer_size(w: JsonWriter) i64;
pub extern fn lf_json_writer_into(
    w: JsonWriter,
    buf: ?[*]u8,
    buf_size: i64,
) i64;
