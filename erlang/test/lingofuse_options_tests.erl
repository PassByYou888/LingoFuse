%% test/lingofuse_options_tests.erl
%%
%% EUnit test suite for the typed option shortcuts.
%%
%% Scope
%% -----
%% This suite covers the 16 set_opt_* / get_opt_* pairs exposed by
%% lingofuse, plus the generic set_option/2 and get_option/1 that
%% underpin them, plus the special-cased getters for `password' and
%% `debug'.
%%
%% The suite runs entirely in-process. No framework startup is
%% required: the option table is global and is always readable.
%%
%% Restoring the prior value
%% -------------------------
%% Options are process-global and are not persisted across shutdown.
%% Every setter test therefore reads the prior value first, sets the
%% value under test, asserts the round trip, and restores the prior
%% value in an `after' block.
%%
%% Boolean wire form
%% -----------------
%% The C side parses the boolean option value with a strict
%% comparison: only "True", "true", and "TRUE" are recognised as
%% true; everything else is treated as false. The tests therefore
%% exercise exactly those three spellings for true, and the three
%% matching spellings for false, plus a couple of negative controls.
%%
%% The Erlang getter is deliberately MORE tolerant than the setter:
%% it accepts "1", "Yes", "on", etc. as true. That tolerance is
%% irrelevant when the value was written by the C parser, which never
%% produces those forms. It exists so that a hand-crafted option table
%% (for example, a value set from a config file) round-trips
%% correctly.

-module(lingofuse_options_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_TIMEOUT_S, 10).
-define(T(Seconds, Fun), {timeout, Seconds, Fun}).

%% =========================================================================
%% Test descriptors
%% =========================================================================

typed_boolean_options_test_() ->
    [
        {"Quiet round trip",
         ?T(?TEST_TIMEOUT_S, fun t_quiet/0)},
        {"ShowThreadID round trip",
         ?T(?TEST_TIMEOUT_S, fun t_show_thread_id/0)},
        {"ConsoleOutput round trip",
         ?T(?TEST_TIMEOUT_S, fun t_console_output/0)},
        {"Overlap_Connection round trip",
         ?T(?TEST_TIMEOUT_S, fun t_overlap_connection/0)},
        {"Wait_Connection_ReadyOk round trip",
         ?T(?TEST_TIMEOUT_S, fun t_wait_connection_ready_ok/0)}
    ].

typed_integer_options_test_() ->
    [
        {"Wait_Connection_Timeout round trip",
         ?T(?TEST_TIMEOUT_S, fun t_wait_connection_timeout/0)},
        {"IPC_Serv_ThreadCount round trip",
         ?T(?TEST_TIMEOUT_S, fun t_ipc_serv_thread_count/0)},
        {"IPC_Serv_MaxQueueLength round trip",
         ?T(?TEST_TIMEOUT_S, fun t_ipc_serv_max_queue_length/0)},
        {"IPC_Serv_MaxMsgSize round trip",
         ?T(?TEST_TIMEOUT_S, fun t_ipc_serv_max_msg_size/0)},
        {"Fixed_Sequenced_Time round trip",
         ?T(?TEST_TIMEOUT_S, fun t_fixed_sequenced_time/0)},
        {"DataHandle_Idle_Timeout round trip",
         ?T(?TEST_TIMEOUT_S, fun t_data_handle_idle_timeout/0)},
        {"DataHandle_Pool_Scan_Interval round trip",
         ?T(?TEST_TIMEOUT_S, fun t_data_handle_pool_scan_interval/0)},
        {"No_Reponse_Cmd_NULL_Flush_Threshold round trip",
         ?T(?TEST_TIMEOUT_S,
            fun t_no_reponse_cmd_null_flush_threshold/0)}
    ].

typed_string_options_test_() ->
    [
        {"LF_P2P_name round trip",
         ?T(?TEST_TIMEOUT_S, fun t_p2p_name/0)},
        {"password is masked on read",
         ?T(?TEST_TIMEOUT_S, fun t_password_masked/0)},
        {"debug is a write-only placeholder on read",
         ?T(?TEST_TIMEOUT_S, fun t_debug_placeholder/0)}
    ].

generic_options_test_() ->
    [
        {"set_option/get_option round trip on a known key",
         ?T(?TEST_TIMEOUT_S, fun t_generic_round_trip/0)},
        {"get_option on an unknown key returns an empty binary",
         ?T(?TEST_TIMEOUT_S, fun t_generic_unknown/0)},
        {"set_option on an unknown key silently succeeds",
         ?T(?TEST_TIMEOUT_S, fun t_generic_unknown_setter/0)}
    ].

badarg_test_() ->
    [
        {"set_opt_quiet rejects a non-boolean",
         ?T(?TEST_TIMEOUT_S, fun t_badarg_quiet/0)},
        {"set_opt_wait_connection_timeout rejects a negative value",
         ?T(?TEST_TIMEOUT_S, fun t_badarg_timeout/0)},
        {"set_opt_ipc_serv_thread_count rejects a non-integer",
         ?T(?TEST_TIMEOUT_S, fun t_badarg_ipc_thread_count/0)},
        {"set_option rejects a non-binary argument",
         ?T(?TEST_TIMEOUT_S, fun t_badarg_generic/0)}
    ].

boolean_wire_form_test_() ->
    [
        {"canonical true spellings all decode to true",
         ?T(?TEST_TIMEOUT_S, fun t_bool_true_spellings/0)},
        {"canonical false spellings all decode to false",
         ?T(?TEST_TIMEOUT_S, fun t_bool_false_spellings/0)},
        {"an unrecognised value decodes to false",
         ?T(?TEST_TIMEOUT_S, fun t_bool_garbage/0)}
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

safe_bool_getter(Getter) ->
    try Getter() catch _:_ -> false end.

safe_int_getter(Getter) ->
    try Getter() catch _:_ -> 0 end.

safe_bin_getter(Getter) ->
    try Getter() catch _:_ -> <<>> end.

%% =========================================================================
%% Boolean option tests
%% =========================================================================

t_quiet() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(fun lingofuse:get_opt_quiet/0),
            try
                ok = lingofuse:set_opt_quiet(true),
                ?assertEqual(true, lingofuse:get_opt_quiet()),
                ok = lingofuse:set_opt_quiet(false),
                ?assertEqual(false, lingofuse:get_opt_quiet())
            after
                _ = lingofuse:set_opt_quiet(Original)
            end
    end.

t_show_thread_id() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(fun lingofuse:get_opt_show_thread_id/0),
            try
                ok = lingofuse:set_opt_show_thread_id(true),
                ?assertEqual(true, lingofuse:get_opt_show_thread_id()),
                ok = lingofuse:set_opt_show_thread_id(false),
                ?assertEqual(false, lingofuse:get_opt_show_thread_id())
            after
                _ = lingofuse:set_opt_show_thread_id(Original)
            end
    end.

t_console_output() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(fun lingofuse:get_opt_console_output/0),
            try
                ok = lingofuse:set_opt_console_output(true),
                ?assertEqual(true, lingofuse:get_opt_console_output()),
                ok = lingofuse:set_opt_console_output(false),
                ?assertEqual(false, lingofuse:get_opt_console_output())
            after
                _ = lingofuse:set_opt_console_output(Original)
            end
    end.

t_overlap_connection() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(
                         fun lingofuse:get_opt_overlap_connection/0),
            try
                ok = lingofuse:set_opt_overlap_connection(true),
                ?assertEqual(true, lingofuse:get_opt_overlap_connection()),
                ok = lingofuse:set_opt_overlap_connection(false),
                ?assertEqual(false, lingofuse:get_opt_overlap_connection())
            after
                _ = lingofuse:set_opt_overlap_connection(Original)
            end
    end.

t_wait_connection_ready_ok() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(
                         fun lingofuse:get_opt_wait_connection_ready_ok/0),
            try
                ok = lingofuse:set_opt_wait_connection_ready_ok(true),
                ?assertEqual(true,
                             lingofuse:get_opt_wait_connection_ready_ok()),
                ok = lingofuse:set_opt_wait_connection_ready_ok(false),
                ?assertEqual(false,
                             lingofuse:get_opt_wait_connection_ready_ok())
            after
                _ = lingofuse:set_opt_wait_connection_ready_ok(Original)
            end
    end.

%% =========================================================================
%% Integer option tests
%% =========================================================================

t_wait_connection_timeout() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_wait_connection_timeout/0),
            try
                ok = lingofuse:set_opt_wait_connection_timeout(12345),
                ?assertEqual(12345,
                             lingofuse:get_opt_wait_connection_timeout()),
                ok = lingofuse:set_opt_wait_connection_timeout(30000),
                ?assertEqual(30000,
                             lingofuse:get_opt_wait_connection_timeout())
            after
                _ = lingofuse:set_opt_wait_connection_timeout(Original)
            end
    end.

t_ipc_serv_thread_count() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_ipc_serv_thread_count/0),
            try
                ok = lingofuse:set_opt_ipc_serv_thread_count(4),
                ?assertEqual(4, lingofuse:get_opt_ipc_serv_thread_count())
            after
                _ = lingofuse:set_opt_ipc_serv_thread_count(Original)
            end
    end.

t_ipc_serv_max_queue_length() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_ipc_serv_max_queue_length/0),
            try
                ok = lingofuse:set_opt_ipc_serv_max_queue_length(1024),
                ?assertEqual(1024,
                             lingofuse:get_opt_ipc_serv_max_queue_length())
            after
                _ = lingofuse:set_opt_ipc_serv_max_queue_length(Original)
            end
    end.

t_ipc_serv_max_msg_size() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_ipc_serv_max_msg_size/0),
            try
                ok = lingofuse:set_opt_ipc_serv_max_msg_size(1048576),
                ?assertEqual(1048576,
                             lingofuse:get_opt_ipc_serv_max_msg_size())
            after
                _ = lingofuse:set_opt_ipc_serv_max_msg_size(Original)
            end
    end.

t_fixed_sequenced_time() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_fixed_sequenced_time/0),
            try
                ok = lingofuse:set_opt_fixed_sequenced_time(5000),
                ?assertEqual(5000,
                             lingofuse:get_opt_fixed_sequenced_time())
            after
                _ = lingofuse:set_opt_fixed_sequenced_time(Original)
            end
    end.

t_data_handle_idle_timeout() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_data_handle_idle_timeout/0),
            try
                ok = lingofuse:set_opt_data_handle_idle_timeout(600000),
                ?assertEqual(600000,
                             lingofuse:get_opt_data_handle_idle_timeout())
            after
                _ = lingofuse:set_opt_data_handle_idle_timeout(Original)
            end
    end.

t_data_handle_pool_scan_interval() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_data_handle_pool_scan_interval/0),
            try
                ok = lingofuse:set_opt_data_handle_pool_scan_interval(5000),
                ?assertEqual(
                   5000,
                   lingofuse:get_opt_data_handle_pool_scan_interval())
            after
                _ = lingofuse:set_opt_data_handle_pool_scan_interval(Original)
            end
    end.

t_no_reponse_cmd_null_flush_threshold() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_int_getter(
                         fun lingofuse:get_opt_no_reponse_cmd_null_flush_threshold/0),
            try
                ok = lingofuse:set_opt_no_reponse_cmd_null_flush_threshold(5000),
                ?assertEqual(
                   5000,
                   lingofuse:get_opt_no_reponse_cmd_null_flush_threshold())
            after
                _ = lingofuse:set_opt_no_reponse_cmd_null_flush_threshold(
                      Original)
            end
    end.

%% =========================================================================
%% String option tests
%% =========================================================================

t_p2p_name() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bin_getter(fun lingofuse:get_opt_p2p_name/0),
            try
                ok = lingofuse:set_opt_p2p_name(<<"eunit_group">>),
                ?assertEqual(<<"eunit_group">>,
                             lingofuse:get_opt_p2p_name()),
                ok = lingofuse:set_opt_p2p_name(<<>>),
                ?assertEqual(<<>>, lingofuse:get_opt_p2p_name())
            after
                _ = lingofuse:set_opt_p2p_name(Original)
            end
    end.

t_password_masked() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Secret = <<"not-a-real-password-12345">>,
            ok = lingofuse:set_opt_password(Secret),
            Got = lingofuse:get_opt_password(),
            ?assertNotEqual(Secret, Got),
            ?assert(is_binary(Got))
    end.

t_debug_placeholder() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Got = lingofuse:get_opt_debug(),
            ?assert(is_binary(Got))
    end.

%% =========================================================================
%% Generic option tests
%% =========================================================================

t_generic_round_trip() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            OriginalBin = safe_bin_getter(
                            fun() -> lingofuse:get_opt_p2p_name() end),
            try
                ok = lingofuse:set_option(<<"LF_P2P_name">>,
                                          <<"generic_test">>),
                {ok, V} = lingofuse:get_option(<<"LF_P2P_name">>),
                ?assertEqual(<<"generic_test">>, V)
            after
                _ = lingofuse:set_option(<<"LF_P2P_name">>, OriginalBin)
            end
    end.

t_generic_unknown() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            {ok, V} = lingofuse:get_option(<<"This_Key_Does_Not_Exist">>),
            ?assertEqual(<<>>, V)
    end.

t_generic_unknown_setter() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertEqual(
               ok,
               lingofuse:set_option(<<"This_Key_Does_Not_Exist">>,
                                    <<"whatever">>))
    end.

%% =========================================================================
%% Argument validation tests
%% =========================================================================

t_badarg_quiet() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertError(badarg, lingofuse:set_opt_quiet(<<"True">>)),
            ?assertError(badarg, lingofuse:set_opt_quiet(42))
    end.

t_badarg_timeout() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertError(
               badarg,
               lingofuse:set_opt_wait_connection_timeout(-1)),
            ?assertError(
               badarg,
               lingofuse:set_opt_wait_connection_timeout(not_an_integer))
    end.

t_badarg_ipc_thread_count() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertError(
               badarg,
               lingofuse:set_opt_ipc_serv_thread_count(<<"4">>))
    end.

t_badarg_generic() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertError(badarg,
                         lingofuse:set_option(<<"Quiet">>, 42)),
            ?assertError(badarg,
                         lingofuse:set_option(42, <<"True">>))
    end.

%% =========================================================================
%% Boolean wire form tests
%% =========================================================================
%%
%% The C side parses the boolean option value with a strict
%% comparison: only "True", "true", and "TRUE" are recognised as
%% true. Any other value, including "1", "Yes", and "on", is treated
%% as false.
%%
%% The Erlang getter is MORE tolerant than the C setter. It accepts
%% the aliases "1", "Yes", "on" as true. That tolerance is exercised
%% here with a hand-crafted option value, which the tests write
%% directly via set_option/2.

t_bool_true_spellings() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(fun lingofuse:get_opt_quiet/0),
            try
                lists:foreach(
                  fun(Spelling) ->
                      ok = lingofuse:set_option(<<"Quiet">>, Spelling),
                      ?assertEqual(
                         true, lingofuse:get_opt_quiet())
                  end,
                  [<<"True">>, <<"true">>, <<"TRUE">>])
            after
                _ = lingofuse:set_opt_quiet(Original)
            end
    end.

t_bool_false_spellings() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(fun lingofuse:get_opt_quiet/0),
            try
                lists:foreach(
                  fun(Spelling) ->
                      ok = lingofuse:set_option(<<"Quiet">>, Spelling),
                      ?assertEqual(
                         false, lingofuse:get_opt_quiet())
                  end,
                  [<<"False">>, <<"false">>, <<"FALSE">>])
            after
                _ = lingofuse:set_opt_quiet(Original)
            end
    end.

%% A value the C parser cannot recognise as true decodes to false.
t_bool_garbage() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Original = safe_bool_getter(fun lingofuse:get_opt_quiet/0),
            try
                ok = lingofuse:set_option(<<"Quiet">>, <<"maybe">>),
                ?assertEqual(false, lingofuse:get_opt_quiet())
            after
                _ = lingofuse:set_opt_quiet(Original)
            end
    end.