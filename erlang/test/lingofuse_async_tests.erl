%% test/lingofuse_async_tests.erl
%%
%% EUnit test suite for the asynchronous invocation family.
%%
%% Design notes
%% ------------
%% Two patterns are used, chosen to avoid a deadlock that the first
%% version of this suite hit:
%%
%%   Pattern A (async callback, default):
%%     register_call (ASYNC mode) delivers {lf_call, Api, Payload}
%%     and returns immediately. The main test process is therefore
%%     free to receive the async result, and no reply is expected.
%%
%%   Pattern B (sync callback, dedicated server process):
%%     register_call_sync is delivered to a DEDICATED echo server
%%     process, NOT to the main test process. The echo server replies
%%     from its own context, so the main test process is free to
%%     receive the async result. This pattern is used when the test
%%     needs to verify a non-empty payload round trip.
%%
%% Using register_call_sync with the main test process would deadlock:
%% the NIF call blocks the caller, the caller cannot process the
%% {lf_call, Ref, ...} message, and the C-side callback never gets
%% its reply.
%%
%% Timeouts
%% --------
%% Every receive has a bounded timeout. The C-side request is never
%% cancelled by an Erlang-side timeout; a late result is silently
%% discarded.

-module(lingofuse_async_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_TIMEOUT_S, 30).
-define(T(Seconds, Fun), {timeout, Seconds, Fun}).

%% =========================================================================
%% Test descriptors
%% =========================================================================

async_test_() ->
    [
        {"async_call basic roundtrip (async callback)",
         ?T(?TEST_TIMEOUT_S, fun t_async_call_basic/0)},
        {"async_call with sync echo server (payload round trip)",
         ?T(?TEST_TIMEOUT_S, fun t_async_call_with_sync_echo/0)},
        {"async_call_seq roundtrip",
         ?T(?TEST_TIMEOUT_S, fun t_async_call_seq/0)},
        {"async_call_raw with sync echo server",
         ?T(?TEST_TIMEOUT_S, fun t_async_call_raw/0)},
        {"async_call concurrent workers (async callback)",
         ?T(?TEST_TIMEOUT_S, fun t_async_call_concurrent/0)}
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
      io_lib:format("ipc:lf_async_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

unique_app_name(Prefix) ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("AsyncTestApp_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

%% Drain every message that a previous test might have left behind.
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
        {lf_disconnect, _}      -> flush_lf_messages();
        {async_done, _, _}      -> flush_lf_messages();
        {async_done, _}         -> flush_lf_messages()
    after 0 -> ok
    end.

try_silent(Fun) ->
    try Fun() catch _:_ -> ok end.

%% Bring up a fresh framework session in deployment mode, run
%% Fun(A, AppName), then tear everything down in an `after' block.
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
            {ok, A} = lingofuse:create_app(AppName, <<"async test">>),
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

%% A dedicated echo server process. It handles the sync callback from
%% its own context so that the main test process is free to receive
%% the async result. The reply payload is a fixed binary chosen by the
%% test; the value is passed via the server's init argument.
echo_server(ReplyPayload) ->
    receive
        {lf_call, Ref, <<"echo">>, _Payload} ->
            ok = lingofuse:reply(Ref, ReplyPayload),
            echo_server(ReplyPayload);
        _Other ->
            echo_server(ReplyPayload)
    end.

%% =========================================================================
%% Tests
%% =========================================================================

%% Pattern A: async callback. No reply is expected from the callback,
%% so the async result is an empty payload.
t_async_call_basic() ->
    with_framework(fun(A, AppName) ->
        Parent = self(),
        ok = lingofuse:register_call(A, <<"echo">>, <<"echo">>, self()),
        ok = lingofuse:async_call(
               AppName, <<"echo">>, #{<<"k">> => <<"v">>},
               fun(Result) -> Parent ! {async_done, Result} end),

        %% Async callback notification.
        receive
            {lf_call, <<"echo">>, _Payload} -> ok
        after 3000 ->
            ?assert(false)
        end,

        %% Async result notification. The callback did not write to
        %% the output handle, so the payload is empty.
        receive
            {async_done, Result} ->
                ?assertEqual({ok, <<>>}, Result)
        after 3000 ->
            ?assert(false)
        end
    end).

%% Pattern B: sync callback served by a dedicated process. This lets
%% us verify a non-empty payload round trip without deadlocking.
t_async_call_with_sync_echo() ->
    with_framework(fun(A, AppName) ->
        Parent = self(),
        EchoPid = spawn_link(fun() -> echo_server(<<"echo-reply">>) end),
        ok = lingofuse:register_call_sync(A, <<"echo">>, <<"echo">>, EchoPid),

        ok = lingofuse:async_call(
               AppName, <<"echo">>, #{<<"hello">> => true},
               fun(Result) -> Parent ! {async_done, Result} end),

        receive
            {async_done, Result} ->
                ?assertEqual({ok, <<"echo-reply">>}, Result)
        after 5000 ->
            ?assert(false)
        end
    end).

%% async_call_seq uses LF_Async_Sequenced_Call. Same shape as the
%% basic form when there is a single outstanding request.
t_async_call_seq() ->
    with_framework(fun(A, AppName) ->
        Parent = self(),
        ok = lingofuse:register_call(A, <<"echo">>, <<"echo">>, self()),
        ok = lingofuse:async_call_seq(
               AppName, <<"echo">>, #{<<"k">> => 1},
               fun(Result) -> Parent ! {async_done, Result} end),

        receive
            {lf_call, <<"echo">>, _} -> ok
        after 3000 -> ?assert(false)
        end,

        receive
            {async_done, Result} ->
                ?assertEqual({ok, <<>>}, Result)
        after 3000 -> ?assert(false)
        end
    end).

%% Pattern B for the raw form: the caller provides the reply pid and
%% receives {lf_async_result, Ref, Result} directly.
t_async_call_raw() ->
    with_framework(fun(A, AppName) ->
        Parent = self(),
        EchoPid = spawn_link(fun() -> echo_server(<<"raw-reply">>) end),
        ok = lingofuse:register_call_sync(A, <<"echo">>, <<"echo">>, EchoPid),

        {ok, Req} = lingofuse:create_data(<<"echo">>),
        ok = lingofuse_json:write_json(Req, #{<<"raw">> => true}),

        {ok, Ref} = lingofuse:async_call_raw(AppName, Req, Parent),

        %% Do NOT free Req until the async result arrives. The C side
        %% may still hold an internal reference to it while the async
        %% worker is in flight.
        receive
            {lf_async_result, Ref, Result} ->
                ?assertEqual({ok, <<"raw-reply">>}, Result)
        after 5000 ->
            ?assert(false)
        end,

        ok = lingofuse:free_data(Req)
    end).

%% Pattern A with five concurrent workers. Every async result must
%% arrive independently.
t_async_call_concurrent() ->
    with_framework(fun(A, AppName) ->
        Parent = self(),
        ok = lingofuse:register_call(A, <<"echo">>, <<"echo">>, self()),

        N = 5,
        [ok = lingofuse:async_call(
                AppName, <<"echo">>, #{<<"i">> => I},
                fun(Result) -> Parent ! {async_done, I, Result} end)
         || I <- lists:seq(1, N)],

        %% N async callback notifications.
        Calls = [receive
                     {lf_call, <<"echo">>, _} -> ok
                 after 5000 -> ?assert(false)
                 end || _ <- lists:seq(1, N)],
        ?assertEqual(N, length(Calls)),

        %% N async result notifications.
        Results = [receive
                       {async_done, I, R} -> {I, R}
                   after 5000 -> ?assert(false)
                   end || _ <- lists:seq(1, N)],
        ?assertEqual(N, length(Results)),
        [?assertEqual({ok, <<>>}, R) || {_, R} <- Results]
    end).