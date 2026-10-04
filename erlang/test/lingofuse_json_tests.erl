%% test/lingofuse_json_tests.erl
%%
%% EUnit test suite for the unified JSON module.
%%
%% Scope
%% -----
%% This suite verifies:
%%   - the JSON serialization policy (compact, UTF-8 literal, no
%%     \uXXXX escapes);
%%   - the deserialization policy (strict on grammar, tolerant on
%%     framing);
%%   - the NUL framing on the wire;
%%   - the three-case read behaviour (NUL found / no NUL / empty);
%%   - the byte-for-byte compatibility of the emitted payload with
%%     the documented reference sequence.
%%
%% The suite does NOT touch the network. It only requires the NIF
%% and the native library to be available for the DataHandle-based
%% tests; the pure function tests (dumps / loads) do not need them.

-module(lingofuse_json_tests).

-include_lib("eunit/include/eunit.hrl").

%% =========================================================================
%% Test descriptors
%% =========================================================================

dumps_test_() ->
    [
        {"compact output has no indentation",
         fun t_dumps_compact/0},
        {"non-ASCII characters stay literal (CJK)",
         fun t_dumps_cjk/0},
        {"non-ASCII characters stay literal (emoji)",
         fun t_dumps_emoji/0},
        {"numbers and booleans round-trip",
         fun t_dumps_scalars/0},
        {"nested objects and arrays",
         fun t_dumps_nested/0}
    ].

loads_test_() ->
    [
        {"valid JSON decodes to a map",
         fun t_loads_object/0},
        {"valid JSON array decodes to a list",
         fun t_loads_array/0},
        {"null decodes to the atom null",
         fun t_loads_null/0},
        {"true / false decode to booleans",
         fun t_loads_booleans/0},
        {"invalid JSON raises",
         fun t_loads_invalid/0}
    ].

wire_format_test_() ->
    [
        {"dumps/1 produces the reference byte sequence",
         fun t_wire_reference/0},
        {"write_json appends exactly one NUL",
         fun t_wire_nul/0},
        {"CJK payload matches the reference bytes",
         fun t_wire_cjk/0}
    ].

handle_io_test_() ->
    [
        {"write_json / read_json round-trip a small object",
         fun t_handle_roundtrip/0},
        {"write_json / read_json round-trip Unicode content",
         fun t_handle_roundtrip_unicode/0},
        {"read_json on an empty handle returns undefined",
         fun t_handle_empty/0},
        {"read_json on garbage raises {invalid_json, _}",
         fun t_handle_invalid/0},
        {"read_json stops at the first NUL, leaving the rest",
         fun t_handle_two_payloads/0},
        {"read_json tolerates a payload without a NUL",
         fun t_handle_no_nul/0},
        {"read_json_or_bytes returns bytes on garbage",
         fun t_handle_lenient/0},
        {"read_json_or_bytes returns the term on valid JSON",
         fun t_handle_lenient_valid/0},
        {"read_json_or_bytes returns undefined on empty",
         fun t_handle_lenient_empty/0}
    ].

cstr_test_() ->
    [
        {"cstr accepts a binary unchanged",
         fun t_cstr_binary/0},
        {"cstr encodes a charlist to UTF-8",
         fun t_cstr_charlist/0},
        {"cstr encodes an atom to UTF-8",
         fun t_cstr_atom/0},
        {"cstr rejects other types with badarg",
         fun t_cstr_badarg/0}
    ].

%% =========================================================================
%% Helpers
%% =========================================================================

ensure_native_or_skip() ->
    case lingofuse:ensure_loaded() of
        ok -> ok;
        {error, lf_not_loaded} ->
            case os:getenv("LINGOFUSE_REQUIRE_NATIVE") of
                false -> skip_message();
                ""    -> skip_message();
                _     -> error(native_library_unavailable)
            end
    end.

skip_message() ->
    io:format(standard_error,
              "  [SKIP] LingoFuse native library not available "
              "(set LINGOFUSE_REQUIRE_NATIVE=1 to fail)~n", []),
    skip.

%% Build a data handle, run the fun, and always free the handle.
with_handle(ApiName, Fun) ->
    {ok, H} = lingofuse:create_data(ApiName),
    try
        Fun(H)
    after
        lingofuse:free_data(H)
    end.

%% =========================================================================
%% dumps/1 tests
%% =========================================================================

t_dumps_compact() ->
    Bin = lingofuse_json:dumps(#{<<"a">> => 1, <<"b">> => 2}),
    %% A map in Erlang does not preserve key order, but the output
    %% must be compact. Assert no whitespace and no newline.
    ?assertEqual(nomatch, binary:match(Bin, <<" ">>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"\n">>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"\t">>)).

t_dumps_cjk() ->
    Bin = lingofuse_json:dumps(#{<<"name">> => <<"张三"/utf8>>}),
    %% The literal UTF-8 bytes must appear; no \uXXXX escape.
    ?assertNotEqual(nomatch, binary:match(Bin, <<"张三"/utf8>>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"\\u">>)).

t_dumps_emoji() ->
    Bin = lingofuse_json:dumps(#{<<"emoji">> => <<"🌍"/utf8>>}),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"🌍"/utf8>>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"\\u">>)).

t_dumps_scalars() ->
    ?assertEqual(<<"42">>,    lingofuse_json:dumps(42)),
    ?assertEqual(<<"-7">>,    lingofuse_json:dumps(-7)),
    ?assertEqual(<<"3.5">>,   lingofuse_json:dumps(3.5)),
    ?assertEqual(<<"true">>,  lingofuse_json:dumps(true)),
    ?assertEqual(<<"false">>, lingofuse_json:dumps(false)),
    ?assertEqual(<<"null">>,  lingofuse_json:dumps(null)).

t_dumps_nested() ->
    Term = #{<<"a">> => [#{<<"b">> => 1}, #{<<"b">> => 2}]},
    Bin = lingofuse_json:dumps(Term),
    Back = lingofuse_json:loads(Bin),
    ?assertEqual(Term, Back).

%% =========================================================================
%% loads/1 tests
%% =========================================================================

t_loads_object() ->
    ?assertEqual(#{<<"a">> => 1},
                 lingofuse_json:loads(<<"{\"a\":1}">>)).

t_loads_array() ->
    ?assertEqual([1, 2, 3],
                 lingofuse_json:loads(<<"[1,2,3]">>)).

t_loads_null() ->
    ?assertEqual(null, lingofuse_json:loads(<<"null">>)).

t_loads_booleans() ->
    ?assertEqual(true,  lingofuse_json:loads(<<"true">>)),
    ?assertEqual(false, lingofuse_json:loads(<<"false">>)).

t_loads_invalid() ->
    ?assertError(_, lingofuse_json:loads(<<"not json">>)).

%% =========================================================================
%% Wire format tests
%% =========================================================================

t_wire_reference() ->
    %% The reference byte sequence for {"a":1} in every LingoFuse
    %% binding: 7B 22 61 22 3A 31 7D
    Bin = lingofuse_json:dumps(#{<<"a">> => 1}),
    ?assertEqual(<<16#7B, 16#22, 16#61, 16#22, 16#3A, 16#31, 16#7D>>,
                 Bin).

t_wire_nul() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_nul">>, fun(H) ->
                ok = lingofuse_json:write_json(H, #{<<"a">> => 1}),
                {ok, Total} = lingofuse:get_size(H),
                %% {"a":1} is 7 bytes, plus one NUL = 8.
                ?assertEqual(8, Total),
                %% The last byte must be NUL.
                ok = lingofuse:set_pos(H, Total - 1),
                {ok, <<0>>} = lingofuse:read_buffer(H, 1)
            end)
    end.

t_wire_cjk() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_cjk">>, fun(H) ->
                Payload = #{<<"name">> => <<"张三"/utf8>>},
                ok = lingofuse_json:write_json(H, Payload),
                %% Read the raw bytes and confirm the literal UTF-8
                %% sequence E5 BC A0 E4 B8 89 is present.
                ok = lingofuse:set_pos(H, 0),
                {ok, Size} = lingofuse:get_size(H),
                {ok, Raw} = lingofuse:read_buffer(H, Size),
                Expected = <<"张三"/utf8>>,
                ?assertNotEqual(nomatch, binary:match(Raw, Expected)),
                ?assertEqual(nomatch, binary:match(Raw, <<"\\u">>))
            end)
    end.

%% =========================================================================
%% DataHandle I/O tests
%% =========================================================================

t_handle_roundtrip() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_rt">>, fun(H) ->
                Term = #{<<"a">> => 1, <<"b">> => <<"hello">>},
                ok = lingofuse_json:write_json(H, Term),
                ok = lingofuse:set_pos(H, 0),
                Got = lingofuse_json:read_json(H),
                ?assertEqual(Term, Got)
            end)
    end.

t_handle_roundtrip_unicode() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_rt_unicode">>, fun(H) ->
                Term = #{<<"name">>  => <<"张三"/utf8>>,
                         <<"emoji">> => <<"🌍"/utf8>>,
                         <<"age">>   => 30},
                ok = lingofuse_json:write_json(H, Term),
                ok = lingofuse:set_pos(H, 0),
                Got = lingofuse_json:read_json(H),
                ?assertEqual(Term, Got)
            end)
    end.

t_handle_empty() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_empty">>, fun(H) ->
                ?assertEqual(undefined, lingofuse_json:read_json(H))
            end)
    end.

t_handle_invalid() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_invalid">>, fun(H) ->
                %% Write raw bytes that are not JSON and terminate
                %% with a NUL so the reader sees them as one payload.
                {ok, _} = lingofuse:write_buffer(H, <<"not json", 0>>),
                ok = lingofuse:set_pos(H, 0),
                ?assertError({invalid_json, _},
                             lingofuse_json:read_json(H))
            end)
    end.

t_handle_two_payloads() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_two">>, fun(H) ->
                %% Write two NUL-framed payloads back to back.
                ok = lingofuse_json:write_json(H, #{<<"n">> => 1}),
                ok = lingofuse_json:write_json(H, #{<<"n">> => 2}),
                ok = lingofuse:set_pos(H, 0),
                ?assertEqual(#{<<"n">> => 1}, lingofuse_json:read_json(H)),
                ?assertEqual(#{<<"n">> => 2}, lingofuse_json:read_json(H)),
                ?assertEqual(undefined, lingofuse_json:read_json(H))
            end)
    end.

t_handle_no_nul() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_nonul">>, fun(H) ->
                %% Raw JSON, no NUL terminator.
                {ok, _} = lingofuse:write_buffer(H, <<"{\"a\":1}">>),
                ok = lingofuse:set_pos(H, 0),
                ?assertEqual(#{<<"a">> => 1},
                             lingofuse_json:read_json(H))
            end)
    end.

t_handle_lenient() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_lenient">>, fun(H) ->
                {ok, _} = lingofuse:write_buffer(H, <<"raw bytes", 0>>),
                ok = lingofuse:set_pos(H, 0),
                Got = lingofuse_json:read_json_or_bytes(H),
                ?assertEqual(<<"raw bytes">>, Got)
            end)
    end.

t_handle_lenient_valid() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_lenient_ok">>, fun(H) ->
                ok = lingofuse_json:write_json(H, #{<<"ok">> => true}),
                ok = lingofuse:set_pos(H, 0),
                Got = lingofuse_json:read_json_or_bytes(H),
                ?assertEqual(#{<<"ok">> => true}, Got)
            end)
    end.

t_handle_lenient_empty() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            with_handle(<<"json_lenient_empty">>, fun(H) ->
                ?assertEqual(undefined,
                             lingofuse_json:read_json_or_bytes(H))
            end)
    end.

%% =========================================================================
%% cstr/1 tests
%% =========================================================================

t_cstr_binary() ->
    ?assertEqual(<<"hello">>, lingofuse_json:cstr(<<"hello">>)),
    ?assertEqual(<<"张三"/utf8>>,
                 lingofuse_json:cstr(<<"张三"/utf8>>)).

t_cstr_charlist() ->
    ?assertEqual(<<"hello">>, lingofuse_json:cstr("hello")),
    ?assertEqual(<<"张三"/utf8>>, lingofuse_json:cstr("张三")).

t_cstr_atom() ->
    ?assertEqual(<<"hello">>, lingofuse_json:cstr(hello)),
    ?assertEqual(<<"Quiet">>, lingofuse_json:cstr('Quiet')).

t_cstr_badarg() ->
    ?assertError(badarg, lingofuse_json:cstr(42)),
    ?assertError(badarg, lingofuse_json:cstr({a, b})).