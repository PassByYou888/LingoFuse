%% test/lingofuse_abi_tests.erl
%%
%% EUnit test suite for the LingoFuse Erlang binding (ABI layer).
%%
%% Run with:
%%     rebar3 eunit
%%
%% The suite exercises the C ABI layer: data handle lifecycle,
%% buffer I/O, position and size, application handle lifecycle, API
%% registration, local execution through the callback bridge, runtime
%% options, and shutdown. It does NOT touch the network; preparation
%% and remote invocation are covered by a separate suite.
%%
%% Native library availability
%% ---------------------------
%% Every test calls ensure_native_or_skip/0 first. When the LingoFuse
%% shared library is not on the search path, the test prints a SKIP
%% message and returns ok. Set the environment variable
%% LINGOFUSE_REQUIRE_NATIVE=1 to turn a missing library into a hard
%% failure; this is intended for CI.

-module(lingofuse_abi_tests).

-include_lib("eunit/include/eunit.hrl").

%% =========================================================================
%% Test descriptors
%% =========================================================================

data_handle_test_() ->
    [
        {"create a data handle",
         fun t_create_data/0},
        {"create a permanent data handle",
         fun t_create_data_permanent/0},
        {"free twice is idempotent",
         fun t_free_twice/0},
        {"free on a non-handle raises badarg",
         fun t_free_badarg/0}
    ].

buffer_io_test_() ->
    [
        {"write and read a small binary",
         fun t_io_roundtrip/0},
        {"write and read an empty binary",
         fun t_io_empty/0},
        {"write and read a 64 KiB random binary",
         fun t_io_large/0},
        {"partial read returns only available bytes",
         fun t_io_partial_read/0},
        {"get_buffer returns an independent snapshot",
         fun t_io_snapshot/0}
    ].

position_size_test_() ->
    [
        {"position starts at zero and advances after write",
         fun t_pos_after_write/0},
        {"set_pos repositions the cursor",
         fun t_pos_set/0},
        {"set_size grows the buffer",
         fun t_pos_grow/0},
        {"negative position raises badarg",
         fun t_pos_badarg/0}
    ].

app_lifecycle_test_() ->
    [
        {"create and free an application",
         fun t_app_create_free/0},
        {"create_app/1 uses an empty description",
         fun t_app_create_default/0},
        {"free twice is idempotent",
         fun t_app_free_twice/0}
    ].

registration_test_() ->
    [
        {"register_call succeeds once",
         fun t_reg_call_once/0},
        {"duplicate register_call is rejected",
         fun t_reg_call_dup/0},
        {"register_notify succeeds once",
         fun t_reg_notify_once/0},
        {"unregister returns true then false",
         fun t_reg_unreg_twice/0},
        {"re-register after unregister succeeds",
         fun t_reg_reregister/0}
    ].

callback_bridge_test_() ->
    [
        {"local_call dispatches to the registered pid",
         fun t_local_call_dispatch/0},
        {"local_notify dispatches to the registered pid",
         fun t_local_notify_dispatch/0},
        {"unregistered local_call returns a size-0 handle",
         fun t_local_call_unregistered/0}
    ].

option_test_() ->
    [
        {"set_option accepts a known key",
         fun t_set_option_known/0},
        {"set_option silently ignores an unknown key",
         fun t_set_option_unknown/0},
        {"set_option with non-binary raises badarg",
         fun t_set_option_badarg/0},
        {"check_main_thread returns a boolean",
         fun t_check_main_thread/0},
        {"check_app on an absent name returns false",
         fun t_check_app_absent/0},
        {"check_api on an absent pair returns false",
         fun t_check_api_absent/0},
        {"post_status and get_status are callable",
         fun t_status_roundtrip/0}
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

unique_app_name(Prefix) ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("TestApp_~s_~p_~p", [Prefix, os:getpid(), N])).

flush_lf_messages() ->
    receive
        {lf_call, _, _}    -> flush_lf_messages();
        {lf_notify, _, _}  -> flush_lf_messages();
        {lf_connect, _}    -> flush_lf_messages();
        {lf_disconnect, _} -> flush_lf_messages()
    after 0 -> ok
    end.

%% =========================================================================
%% Data handle tests
%% =========================================================================

t_create_data() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_create">>),
            ?assert(is_reference(H)),
            ?assertEqual(ok, lingofuse:free_data(H))
    end.

t_create_data_permanent() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data_permanent(<<"t_perm">>),
            ?assert(is_reference(H)),
            ?assertEqual(ok, lingofuse:free_data(H))
    end.

t_free_twice() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_double_free">>),
            ?assertEqual(ok, lingofuse:free_data(H)),
            ?assertEqual(ok, lingofuse:free_data(H))
    end.

t_free_badarg() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertError(badarg, lingofuse:free_data(not_a_handle)),
            ?assertError(badarg, lingofuse:free_data(<<"not a handle">>))
    end.

%% =========================================================================
%% Buffer I/O tests
%% =========================================================================

t_io_roundtrip() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_io_rt">>),
            try
                Payload = <<"hello, world">>,
                {ok, N} = lingofuse:write_buffer(H, Payload),
                ?assertEqual(byte_size(Payload), N),
                {ok, S} = lingofuse:get_size(H),
                ?assertEqual(byte_size(Payload), S),
                ok = lingofuse:set_pos(H, 0),
                {ok, Got} = lingofuse:read_buffer(H, N),
                ?assertEqual(Payload, Got)
            after
                lingofuse:free_data(H)
            end
    end.

t_io_empty() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_io_empty">>),
            try
                {ok, 0} = lingofuse:write_buffer(H, <<>>),
                {ok, 0} = lingofuse:get_size(H),
                ok = lingofuse:set_pos(H, 0),
                {ok, <<>>} = lingofuse:read_buffer(H, 0)
            after
                lingofuse:free_data(H)
            end
    end.

t_io_large() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_io_large">>),
            try
                Size = 64 * 1024,
                Payload = crypto:strong_rand_bytes(Size),
                {ok, Size} = lingofuse:write_buffer(H, Payload),
                ok = lingofuse:set_pos(H, 0),
                {ok, Got} = lingofuse:read_buffer(H, Size),
                ?assertEqual(Payload, Got)
            after
                lingofuse:free_data(H)
            end
    end.

t_io_partial_read() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_io_partial">>),
            try
                {ok, 4} = lingofuse:write_buffer(H, <<"abcd">>),
                ok = lingofuse:set_pos(H, 0),
                {ok, Got} = lingofuse:read_buffer(H, 16),
                ?assertEqual(<<"abcd">>, Got)
            after
                lingofuse:free_data(H)
            end
    end.

t_io_snapshot() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_io_snap">>),
            try
                {ok, 3} = lingofuse:write_buffer(H, <<"xyz">>),
                {ok, Snap1} = lingofuse:get_buffer(H),
                ?assertEqual(<<"xyz">>, Snap1),
                {ok, 3} = lingofuse:write_buffer(H, <<"ABC">>),
                {ok, Snap2} = lingofuse:get_buffer(H),
                ?assertEqual(<<"xyz">>, Snap1),
                ?assertEqual(<<"xyzABC">>, Snap2)
            after
                lingofuse:free_data(H)
            end
    end.

%% =========================================================================
%% Position and size tests
%% =========================================================================

t_pos_after_write() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_pos_write">>),
            try
                {ok, 0} = lingofuse:get_pos(H),
                {ok, 5} = lingofuse:write_buffer(H, <<"12345">>),
                {ok, 5} = lingofuse:get_pos(H)
            after
                lingofuse:free_data(H)
            end
    end.

t_pos_set() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_pos_set">>),
            try
                {ok, 5} = lingofuse:write_buffer(H, <<"12345">>),
                ok = lingofuse:set_pos(H, 2),
                {ok, 2} = lingofuse:get_pos(H),
                {ok, <<"345">>} = lingofuse:read_buffer(H, 3)
            after
                lingofuse:free_data(H)
            end
    end.

t_pos_grow() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_pos_grow">>),
            try
                {ok, 3} = lingofuse:write_buffer(H, <<"abc">>),
                ok = lingofuse:set_size(H, 10),
                {ok, 10} = lingofuse:get_size(H)
            after
                lingofuse:free_data(H)
            end
    end.

t_pos_badarg() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, H} = lingofuse:create_data(<<"t_pos_bad">>),
            try
                ?assertError(badarg, lingofuse:set_pos(H, -1)),
                ?assertError(badarg, lingofuse:set_size(H, -1))
            after
                lingofuse:free_data(H)
            end
    end.

%% =========================================================================
%% Application lifecycle tests
%% =========================================================================

t_app_create_free() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(
                        unique_app_name(<<"cf">>),
                        <<"test application">>),
            ?assert(is_reference(A)),
            ?assertEqual(ok, lingofuse:free_app(A))
    end.

t_app_create_default() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"def">>)),
            ?assert(is_reference(A)),
            ?assertEqual(ok, lingofuse:free_app(A))
    end.

t_app_free_twice() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"df">>)),
            ?assertEqual(ok, lingofuse:free_app(A)),
            ?assertEqual(ok, lingofuse:free_app(A))
    end.

%% =========================================================================
%% Registration tests
%% =========================================================================

t_reg_call_once() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"rc">>)),
            try
                ?assertEqual(
                   ok,
                   lingofuse:register_call(
                     A, <<"my_api">>, <<"desc">>, self()))
            after
                lingofuse:free_app(A)
            end
    end.

t_reg_call_dup() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"rd">>)),
            try
                ok = lingofuse:register_call(
                       A, <<"dup">>, <<"first">>, self()),
                ?assertEqual(
                   {error, registration_failed},
                   lingofuse:register_call(
                     A, <<"dup">>, <<"second">>, self()))
            after
                lingofuse:free_app(A)
            end
    end.

t_reg_notify_once() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"rn">>)),
            try
                ?assertEqual(
                   ok,
                   lingofuse:register_notify(
                     A, <<"events">>, <<"desc">>, self()))
            after
                lingofuse:free_app(A)
            end
    end.

t_reg_unreg_twice() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"ru">>)),
            try
                ok = lingofuse:register_call(
                       A, <<"gone">>, <<"desc">>, self()),
                ?assertEqual({ok, true},
                             lingofuse:unregister(A, <<"gone">>)),
                ?assertEqual({ok, false},
                             lingofuse:unregister(A, <<"gone">>))
            after
                lingofuse:free_app(A)
            end
    end.

t_reg_reregister() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"rr">>)),
            try
                ok = lingofuse:register_call(
                       A, <<"hot">>, <<"v1">>, self()),
                {ok, true} = lingofuse:unregister(A, <<"hot">>),
                ?assertEqual(
                   ok,
                   lingofuse:register_call(
                     A, <<"hot">>, <<"v2">>, self()))
            after
                lingofuse:free_app(A)
            end
    end.

%% =========================================================================
%% Callback bridge tests
%% =========================================================================

t_local_call_dispatch() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            flush_lf_messages(),
            {ok, A} = lingofuse:create_app(unique_app_name(<<"lc">>)),
            try
                ok = lingofuse:register_call(
                       A, <<"ping">>, <<"desc">>, self()),
                {ok, P} = lingofuse:create_data(<<"ping">>),
                try
                    {ok, _} = lingofuse:write_buffer(P, <<"hello">>),
                    {ok, _R} = lingofuse:local_call(A, P),
                    receive
                        {lf_call, Api, Payload} ->
                            ?assertEqual(<<"ping">>, Api),
                            ?assertEqual(<<"hello">>, Payload)
                    after 2000 ->
                        ?assert(false)
                    end
                after
                    lingofuse:free_data(P)
                end
            after
                lingofuse:free_app(A)
            end
    end.

t_local_notify_dispatch() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            flush_lf_messages(),
            {ok, A} = lingofuse:create_app(unique_app_name(<<"ln">>)),
            try
                ok = lingofuse:register_notify(
                       A, <<"log">>, <<"desc">>, self()),
                {ok, P} = lingofuse:create_data(<<"log">>),
                try
                    {ok, _} = lingofuse:write_buffer(P, <<"event">>),
                    ok = lingofuse:local_notify(A, P),
                    receive
                        {lf_notify, Api, Payload} ->
                            ?assertEqual(<<"log">>, Api),
                            ?assertEqual(<<"event">>, Payload)
                    after 2000 ->
                        ?assert(false)
                    end
                after
                    lingofuse:free_data(P)
                end
            after
                lingofuse:free_app(A)
            end
    end.

t_local_call_unregistered() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, A} = lingofuse:create_app(unique_app_name(<<"lu">>)),
            {ok, P} = lingofuse:create_data(<<"not_registered">>),
            try
                {ok, _} = lingofuse:write_buffer(P, <<"data">>),
                {ok, R} = lingofuse:local_call(A, P),
                try
                    {ok, Size} = lingofuse:get_size(R),
                    ?assertEqual(0, Size)
                after
                    lingofuse:free_data(R)
                end
            after
                lingofuse:free_data(P),
                lingofuse:free_app(A)
            end
    end.

%% =========================================================================
%% Option and diagnostic tests
%% =========================================================================

t_set_option_known() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertEqual(ok, lingofuse:set_option(<<"Quiet">>, <<"True">>)),
            ?assertEqual(ok,
                         lingofuse:set_option(
                           <<"Overlap_Connection">>, <<"True">>))
    end.

t_set_option_unknown() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertEqual(ok,
                         lingofuse:set_option(
                           <<"This_Key_Does_Not_Exist">>, <<"whatever">>))
    end.

t_set_option_badarg() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertError(badarg, lingofuse:set_option(<<"key">>, 42)),
            ?assertError(badarg, lingofuse:set_option(42, <<"value">>))
    end.

t_check_main_thread() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, V} = lingofuse:check_main_thread(),
            ?assert(is_boolean(V))
    end.

t_check_app_absent() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, V} = lingofuse:check_app(<<"__definitely_absent__">>),
            ?assertEqual(false, V)
    end.

t_check_api_absent() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, V} = lingofuse:check_api(
                        <<"__absent__">>, <<"__absent__">>),
            ?assertEqual(false, V)
    end.

t_status_roundtrip() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertEqual(ok,
                         lingofuse:post_status(
                           <<"eunit status marker">>)),
            {ok, N} = lingofuse:get_status_count(),
            ?assert(is_integer(N)),
            {ok, S} = lingofuse:get_status(),
            ?assert(is_binary(S))
    end.