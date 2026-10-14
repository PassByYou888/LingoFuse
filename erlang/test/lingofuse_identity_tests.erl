%% test/lingofuse_identity_tests.erl
%%
%% EUnit test suite for the with_identity registration option.
%%
%% Scope
%% -----
%% The with_identity option controls whether the callback dispatch
%% extracts the sender's side data and appends it to the message.
%%
%%   #{with_identity => false}   (default, or absent)
%%     Call   (async): {lf_call, Api, Payload}
%%     Call   (sync):  {lf_call, Ref, Api, Payload}
%%     Notify:         {lf_notify, Api, Payload}
%%
%%   #{with_identity => true}
%%     Call   (async): {lf_call, Api, Payload, Identity}
%%     Call   (sync):  {lf_call, Ref, Api, Payload, Identity}
%%     Notify:         {lf_notify, Api, Payload, Identity}
%%
%% Identity is a map:
%%
%%     #{uid => <<_:256>>, p2p_name => binary()}
%%
%% The uid is always exactly 32 bytes. The p2p_name is the sender's
%% declared P2P group name; it is the empty binary if the sender did
%% not set one.
%%
%% This suite also verifies that process-wide P2P registration
%% succeeds and that unregistration is idempotent.

-module(lingofuse_identity_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_TIMEOUT_S, 30).
-define(T(Seconds, Fun), {timeout, Seconds, Fun}).

identity_test_() ->
    [
        {"app-bound call without identity has 3-tuple message",
         ?T(?TEST_TIMEOUT_S, fun t_call_no_identity/0)},
        {"app-bound call with identity has 4-tuple message with uid map",
         ?T(?TEST_TIMEOUT_S, fun t_call_with_identity/0)},
        {"app-bound notify without identity has 3-tuple message",
         ?T(?TEST_TIMEOUT_S, fun t_notify_no_identity/0)},
        {"app-bound notify with identity has 4-tuple message",
         ?T(?TEST_TIMEOUT_S, fun t_notify_with_identity/0)},
        {"p2p register then unregister is idempotent",
         ?T(?TEST_TIMEOUT_S, fun t_p2p_register_unregister/0)}
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

unique_endpoint(Prefix) ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("ipc:lf_ident_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

unique_app_name(Prefix) ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("IdentTestApp_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

flush_lf_messages() ->
    receive
        {lf_call, _, _, _}      -> flush_lf_messages();
        {lf_call, _, _}         -> flush_lf_messages();
        {lf_notify, _, _}       -> flush_lf_messages();
        {lf_notify, _}          -> flush_lf_messages();
        {lf_p2p_call, _, _}     -> flush_lf_messages();
        {lf_p2p_call, _, _, _}  -> flush_lf_messages();
        {lf_p2p_notify, _, _}   -> flush_lf_messages();
        {lf_p2p_notify, _}      -> flush_lf_messages();
        {lf_async_result, _, _} -> flush_lf_messages();
        {lf_connect, _}         -> flush_lf_messages();
        {lf_disconnect, _}      -> flush_lf_messages()
    after 0 -> ok
    end.

try_silent(Fun) ->
    try Fun() catch _:_ -> ok end.

with_framework(Fun) ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            flush_lf_messages(),
            ok = lingofuse:set_option(<<"Wait_Connection_ReadyOk">>,
                                      <<"False">>),
            ok = lingofuse:set_option(<<"Overlap_Connection">>,
                                      <<"True">>),
            ok = lingofuse:set_option(<<"Quiet">>, <<"True">>),
            Endpoint = unique_endpoint(<<"t">>),
            AppName  = unique_app_name(<<"t">>),
            {ok, A} = lingofuse:create_app(AppName, <<"identity test">>),
            try
                ok = lingofuse:reset_prepare(),
                {ok, _} = lingofuse:prepare_service(Endpoint, Endpoint),
                {ok, _} = lingofuse:prepare_client(Endpoint, A),
                {ok, 1} = lingofuse:prepare_done(),
                true = wait_until(
                         fun() ->
                             case lingofuse:check_app(AppName) of
                                 {ok, true} -> true;
                                 _          -> false
                             end
                         end, 5000),
                Fun(A, AppName)
            after
                try_silent(fun() -> lingofuse:exit_main_thread() end),
                try_silent(fun() -> lingofuse:free_app(A) end),
                try_silent(fun() -> lingofuse:shutdown() end),
                timer:sleep(100),
                flush_lf_messages()
            end,
            ok
    end.

wait_until(Fun, TimeoutMs) ->
    wait_until_loop(Fun, TimeoutMs, 50).

wait_until_loop(Fun, TimeoutMs, _) when TimeoutMs =< 0 ->
    Fun();
wait_until_loop(Fun, TimeoutMs, Interval) ->
    case Fun() of
        true -> true;
        false ->
            timer:sleep(Interval),
            wait_until_loop(Fun, TimeoutMs - Interval, Interval)
    end.

%% =========================================================================
%% Tests
%% =========================================================================

%% The default registration produces the legacy 3-tuple message.
%% The test explicitly checks that no fourth element is appended.
t_call_no_identity() ->
    with_framework(fun(A, AppName) ->
        ok = lingofuse:register_call(A, <<"echo">>, <<"echo">>, self()),

        {ok, Req} = lingofuse:create_data(<<"echo">>),
        ok = lingofuse_json:write_json(Req, #{<<"k">> => 1}),
        _ = lingofuse:call(AppName, Req, 2000),
        ok = lingofuse:free_data(Req),

        receive
            {lf_call, <<"echo">>, Payload} ->
                ?assert(is_binary(Payload)),
                %% The payload round-trips the JSON we wrote.
                ?assertMatch(#{<<"k">> := 1},
                             lingofuse_json:loads(Payload));
            {lf_call, _, _, _} ->
                ?assert(false)  %% 4-tuple means identity was injected
        after 3000 ->
            ?assert(false)
        end
    end).

%% with_identity => true appends a map with uid and p2p_name.
t_call_with_identity() ->
    with_framework(fun(A, AppName) ->
        ok = lingofuse:register_call(
               A, <<"whoami">>, <<"whoami">>, self(),
               #{with_identity => true}),

        {ok, Req} = lingofuse:create_data(<<"whoami">>),
        ok = lingofuse_json:write_json(Req, #{}),
        _ = lingofuse:call(AppName, Req, 2000),
        ok = lingofuse:free_data(Req),

        receive
            {lf_call, <<"whoami">>, _Payload, Identity} ->
                ?assert(is_map(Identity)),
                ?assert(maps:is_key(uid, Identity)),
                ?assert(maps:is_key(p2p_name, Identity)),

                Uid = maps:get(uid, Identity),
                ?assert(is_binary(Uid)),
                ?assertEqual(32, byte_size(Uid)),

                P2PName = maps:get(p2p_name, Identity),
                ?assert(is_binary(P2PName))
        after 3000 ->
            ?assert(false)
        end
    end).

%% Notify without identity keeps the legacy 3-tuple shape.
t_notify_no_identity() ->
    with_framework(fun(A, AppName) ->
        ok = lingofuse:register_notify(A, <<"log">>, <<"log">>, self()),

        {ok, Req} = lingofuse:create_data(<<"log">>),
        ok = lingofuse_json:write_json(Req, <<"hello">>),
        lingofuse:notify(AppName, Req),
        ok = lingofuse:free_data(Req),

        receive
            {lf_notify, <<"log">>, Payload} ->
                ?assert(is_binary(Payload))
        after 3000 ->
            ?assert(false)
        end
    end).

%% Notify with identity appends the identity map.
t_notify_with_identity() ->
    with_framework(fun(A, AppName) ->
        ok = lingofuse:register_notify(
               A, <<"log">>, <<"log">>, self(),
               #{with_identity => true}),

        {ok, Req} = lingofuse:create_data(<<"log">>),
        ok = lingofuse_json:write_json(Req, <<"hello">>),
        lingofuse:notify(AppName, Req),
        ok = lingofuse:free_data(Req),

        receive
            {lf_notify, <<"log">>, _Payload, Identity} ->
                ?assert(is_map(Identity)),
                ?assert(maps:is_key(uid, Identity)),
                ?assertEqual(32, byte_size(maps:get(uid, Identity)))
        after 3000 ->
            ?assert(false)
        end
    end).

%% A process-wide P2P API can be registered and unregistered. The
%% second unregister returns {ok, false}, matching the C ABI.
t_p2p_register_unregister() ->
    with_framework(fun(_A, _AppName) ->
        Api = <<"identity_p2p_test_api">>,
        ok = lingofuse:register_p2p_call(Api, <<"p2p test">>, self()),
        {ok, true}  = lingofuse:unregister_p2p(Api),
        {ok, false} = lingofuse:unregister_p2p(Api)
    end).