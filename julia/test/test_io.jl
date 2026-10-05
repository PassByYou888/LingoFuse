# test_io.jl - Step-3 io.jl acceptance test.
#
# Coverage:
#   - dumps_json policy (compact, literal UTF-8)
#   - loads_json strictness
#   - json_to_dict
#   - write_string! / read_string! round trip
#   - write_string_bytes! / read_string_bytes
#   - Fault-tolerant read (no NUL)
#   - read_all_bytes / peek_string_bytes
#   - write_json! / read_json / try_read_json / read_json_or_bytes
#   - Wire-format invariants (byte-for-byte compatibility)

ENV["LINGOFUSE_TRACE"] = "0"

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "trace.jl"))
include(joinpath(_SRC, "error.jl"))
include(joinpath(_SRC, "loader.jl"))
include(joinpath(_SRC, "abi.jl"))
include(joinpath(_SRC, "shim.jl"))
include(joinpath(_SRC, "callback.jl"))
include(joinpath(_SRC, "data_handle.jl"))
include(joinpath(_SRC, "app.jl"))
include(joinpath(_SRC, "network.jl"))
include(joinpath(_SRC, "io.jl"))

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# ------------------------------------------------------------------ #
# dumps_json / loads_json                                            #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- dumps_json / loads_json ---")

let
    s = dumps_json(Dict("a" => 1, "b" => [2, 3]))
    # Dict iteration order is not stable; check both fragments.
    ck(occursin("\"a\":1", s), "dumps_json emits a compact 'a':1 fragment")
    ck(occursin("\"b\":[2,3]", s), "dumps_json emits a compact 'b':[2,3] fragment")
    ck(!occursin("\n", s), "dumps_json has no newline")
end

let
    # Non-ASCII must appear literally, not as \uXXXX escapes.
    s = dumps_json(Dict("msg" => "你好"))
    ck(occursin("你好", s), "dumps_json emits literal UTF-8 (Chinese)")
    ck(!occursin("\\u", s), "dumps_json has no \\uXXXX escape")
end

let
    s = dumps_json(Dict("emoji" => "🌍"))
    ck(occursin("🌍", s), "dumps_json emits literal UTF-8 (emoji)")
end

let
    v = loads_json("{\"a\": 1, \"b\": [2, 3]}")
    ck(v.a == 1, "loads_json parses a numeric field")
    ck(length(v.b) == 2, "loads_json parses an array field")
end

let
    threw = false
    try
        loads_json("{not json")
    catch
        threw = true
    end
    ck(threw, "loads_json throws on invalid JSON")
end

# ------------------------------------------------------------------ #
# json_to_dict                                                       #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- json_to_dict ---")

let
    v = loads_json("{\"a\": 1, \"b\": [2, 3], \"c\": {\"d\": true}}")
    d = json_to_dict(v)
    ck(d isa Dict, "json_to_dict returns a Dict for an object")
    ck(d["a"] == 1, "json_to_dict preserves scalar values")
    ck(d["b"] isa Vector, "json_to_dict converts arrays to Vector")
    ck(d["b"][1] == 2, "json_to_dict preserves array element values")
    ck(d["c"] isa Dict, "json_to_dict recurses into nested objects")
    ck(d["c"]["d"] === true, "json_to_dict preserves nested boolean")
end

# ------------------------------------------------------------------ #
# String I/O                                                         #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- string I/O ---")

let
    dh = DataHandle("str")
    write_string!(dh, "hello")
    ck(buffer_size(dh) == 6, "write_string! wrote 5 + NUL")
    set_cursor_position!(dh, 0)
    ck(read_string!(dh) == "hello", "read_string! round-trips")
    dispose!(dh)
end

let
    dh = DataHandle("str")
    write_string!(dh, "你好")
    set_cursor_position!(dh, 0)
    s = read_string!(dh)
    ck(s == "你好", "read_string! round-trips non-ASCII text")
    dispose!(dh)
end

let
    dh = DataHandle("str")
    # No NUL: fault-tolerant read must return the whole buffer and
    # advance the cursor to size + 1.
    write_buffer!(dh, UInt8[0x61, 0x62, 0x63])
    set_cursor_position!(dh, 0)
    s = read_string!(dh)
    ck(s == "abc", "read_string! is fault-tolerant when no NUL is present")
    ck(cursor_position(dh) == 4,
       "read_string! advances to size + 1 after a no-NUL read")
    dispose!(dh)
end

# ------------------------------------------------------------------ #
# write_string_bytes! / read_string_bytes                            #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- write_string_bytes! / read_string_bytes ---")

let
    dh = DataHandle("bytes")
    write_string_bytes!(dh, UInt8[0x01, 0x02, 0x03])
    ck(buffer_size(dh) == 4, "write_string_bytes! wrote 3 + NUL")
    set_cursor_position!(dh, 0)
    back = read_string_bytes(dh)
    ck(back == UInt8[0x01, 0x02, 0x03], "read_string_bytes round-trips")
    dispose!(dh)
end

let
    dh = DataHandle("bytes")
    # Embedded NUL is preserved in the byte count, but read stops
    # at the first NUL.
    write_string_bytes!(dh, UInt8[0x61, 0x00, 0x62])
    set_cursor_position!(dh, 0)
    back = read_string_bytes(dh)
    ck(back == UInt8[0x61], "read_string_bytes stops at the first NUL")
    dispose!(dh)
end

# ------------------------------------------------------------------ #
# read_all_bytes / peek_string_bytes                                 #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- read_all_bytes / peek_string_bytes ---")

let
    dh = DataHandle("all")
    write_string!(dh, "ab")
    write_string!(dh, "cd")
    set_cursor_position!(dh, 0)
    all_bytes = read_all_bytes(dh)
    ck(length(all_bytes) == 6, "read_all_bytes reads the whole buffer")
    ck(all_bytes[3] == 0x00, "read_all_bytes preserves the NUL byte")
    dispose!(dh)
end

let
    dh = DataHandle("peek")
    write_string!(dh, "abcdef")
    set_cursor_position!(dh, 0)
    peeked = peek_string_bytes(dh)
    ck(peeked == Vector{UInt8}(codeunits("abcdef")),
       "peek_string_bytes reads the payload")
    ck(cursor_position(dh) == 0,
       "peek_string_bytes does not advance the cursor")
    # A subsequent read sees the same bytes.
    s = read_string!(dh)
    ck(s == "abcdef", "read_string! after peek returns the same payload")
    dispose!(dh)
end

# ------------------------------------------------------------------ #
# JSON I/O on handles                                                #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- JSON I/O on handles ---")

let
    dh = DataHandle("json")
    n = write_json!(dh, Dict("name" => "张三", "age" => 30))
    ck(n > 0, "write_json! reports bytes written ($n)")

    # Verify literal UTF-8: the bytes on the handle must contain the
    # Chinese characters as real UTF-8, not as \uXXXX escapes.
    set_cursor_position!(dh, 0)
    raw = read_string_bytes(dh)
    text = String(copy(raw))
    ck(occursin("张三", text), "write_json! emits literal UTF-8 on the wire")
    ck(!occursin("\\u", text), "write_json! has no \\uXXXX escape on the wire")

    set_cursor_position!(dh, 0)
    obj = read_json(dh)
    ck(obj.name == "张三", "read_json round-trips a Chinese string")
    ck(obj.age == 30, "read_json round-trips a numeric field")
    dispose!(dh)
end

let
    dh = DataHandle("json")
    set_cursor_position!(dh, 0)
    v = read_json(dh)
    ck(v === nothing, "read_json returns nothing on an empty payload")
    dispose!(dh)
end

let
    dh = DataHandle("json")
    write_string!(dh, "{not json")
    set_cursor_position!(dh, 0)
    threw = false
    try
        read_json(dh)
    catch
        threw = true
    end
    ck(threw, "read_json throws on invalid JSON")
    dispose!(dh)
end

let
    dh = DataHandle("json")
    write_string!(dh, "{not json")
    set_cursor_position!(dh, 0)
    v = try_read_json(dh)
    ck(v === nothing, "try_read_json returns nothing on invalid JSON")
    dispose!(dh)
end

let
    dh = DataHandle("json")
    write_string!(dh, "{not json")
    set_cursor_position!(dh, 0)
    v = read_json_or_bytes(dh)
    ck(v isa Vector{UInt8},
       "read_json_or_bytes returns raw bytes for non-JSON")
    ck(String(copy(v)) == "{not json",
       "read_json_or_bytes preserves the payload")
    dispose!(dh)
end

let
    dh = DataHandle("json")
    write_json!(dh, Dict("a" => 1))
    set_cursor_position!(dh, 0)
    v = read_json_or_bytes(dh)
    ck(v.a == 1,
       "read_json_or_bytes returns a JSON value for a JSON payload")
    dispose!(dh)
end

# ------------------------------------------------------------------ #
# Wire-format invariants                                             #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- wire-format invariants ---")

let
    dh = DataHandle("wire")
    write_json!(dh, Dict("a" => 1))
    set_cursor_position!(dh, 0)
    raw = read_all_bytes(dh)
    # Expected bytes: 7B 22 61 22 3A 31 7D 00
    expected = UInt8[0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D, 0x00]
    ck(raw == expected, "wire format matches Python / C++ byte-for-byte")
    dispose!(dh)
end

# ------------------------------------------------------------------ #
# Summary                                                            #
# ------------------------------------------------------------------ #

println(stderr, "")
println(stderr, "[test] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test] OK")
    exit(0)
else
    println(stderr, "[test] FAILED")
    exit(1)
end