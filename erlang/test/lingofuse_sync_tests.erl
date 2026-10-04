%% test/lingofuse_sync_tests.erl
%%
%% EUnit test suite for the sync Call callback bridge.
%%
%% Scope
%% -----
%% This suite verifies:
%%
%%   * register_call_sync/4 + reply/2 round-trip through local_call/2.
%%   * reply/2 correctly rejects an unknown ref.
%%   * A sync callback that never replies causes local_call/2 to
%%     return after the sync timeout, with an empty output handle.
%%   * set_sync_timeout/1 and get_sync_timeout/0.
%%   * Multiple concurrent sync calls each receive their own reply.
%%
%% Pattern
%% -------
%% A sync callback must be handled by a process OTHER than the one
%% that issues the call. If the same process both issues the call
%% and handles the callback, it would deadlock: the caller is
%% blocked inside local_call/2 and cannot receive the callback
%% message.
%%
%% Each test therefore spawns a worker process to perform the call.
%% The test process itself is the callback target: it receives
%% {lf_call, Ref, Api, Payload}, calls reply/2, and then collects the
%% worker's result.
%%
%% This pattern is the canonical way to use the sync bridge. It is
%% documented in src/lingofuse.erl under "Call callback modes".

-module(lingofuse_sync_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_TIMEOUT_S, 30).
-define(T(Seconds, Fun), {timeout, Seconds, Fun}).

sync_test_() ->
    [
        {"sync callback round-trip via local_call",
         ?T(?TEST_TIMEOUT_S, fun t_sync_local_call_basic/0)},
        {"sync callback with delayed reply",
         ?T(?TEST_TIMEOUT_S, fun t_sync_local_call_delayed/0)},
        {"reply to an unknown ref returns unknown_ref",
         ?T(?TEST_TIMEOUT_S, fun t_reply_unknown_ref/0)},
        {"sync callback that never replies times out",
         ?T(?TEST_TIMEOUT_S, fun t_sync_timeout_empty_output/0)},
        {"set_sync_timeout / get_sync_timeout round-trip",
         ?T(?TEST_TIMEOUT_S, fun t_sync_timeout_roundtrip/0)},
        {"set_sync_timeout rejects a non-positive value",
         ?T(?TEST_TIMEOUT_S, fun t_sync_timeout_badarg/0)},
        {"multiple concurrent sync calls each get their own reply",
         ?T(?TEST_TIMEOUT_S, fun t_multiple_concurrent_sync_calls/0)},
        {"async register_call still delivers without ref",
         ?T(?TEST_TIMEOUT_S, fun t_async_call_unchanged/0)}
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
      io_lib:format("ipc:lf_sync_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

unique_app_name(Prefix) ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("SyncTestApp_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

flush_lf_messages() ->
    receive
        {lf_call, _, _, _} -> flush_lf_messages();
        {lf_call, _, _}    -> flush_lf_messages();
        {lf_notify, _, _}  -> flush_lf_messages();
        {lf_connect, _}    -> flush_lf_messages();
        {lf_disconnect, _} -> flush_lf_messages()
    after 0 -> ok
    end.

try_silent(Fun) ->
    try Fun() catch _:_ -> ok end.

%% Start a fresh framework session in deployment mode and run Fun.
%% Restores the default sync timeout on exit so a test that changes
%% it cannot leak into the next test.
with_framework(Fun) ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            flush_lf_messages(),
            ok = lingofuse:set_option(<<"Wait_Connection_ReadyOk">>,
                                      <<"False">>),
            ok = lingofuse:set_sync_timeout(30000),
            Endpoint = unique_endpoint(<<"t">>),
            AppName  = unique_app_name(<<"t">>),
            {ok, A} = lingofuse:create_app(AppName, <<"sync test">>),
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
                try_silent(fun() -> lingofuse:set_sync_timeout(30000) end),
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

%% Spawn a worker that performs a single local_call and sends the
%% result back to the test process. The test process handles the
%% callback on its own message queue.
spawn_local_call_worker(A, Api, Payload, Parent) ->
    spawn_monitor(fun() ->
        {ok, P} = lingofuse:create_data(Api),
        try
            {ok, _} = lingofuse:write_buffer(P, Payload),
            Result = lingofuse:local_call(A, P),
            Parent ! {worker_result, self(), Result}
        after
            lingofuse:free_data(P)
        end
    end).

%% Wait for one callback message with the given api name, and return
%% the Ref and Payload.
await_callback(ApiName, TimeoutMs) ->
    receive
        {lf_call, Ref, ApiName, Payload} ->
            {Ref, Payload}
    after TimeoutMs ->
        error({timeout_waiting_callback, ApiName})
    end.

%% Wait for the worker to send its result.
await_worker_result(Pid, TimeoutMs) ->
    receive
        {worker_result, Pid, Result} -> Result
    after TimeoutMs ->
        error({timeout_waiting_worker, Pid})
    end.

%% Wait for a monitor DOWN for the given pid and ref, and return the
%% exit reason. A worker that completes normally produces `normal`.
await_down(Ref, Pid, TimeoutMs) ->
    receive
        {'DOWN', Ref, process, Pid, Reason} -> Reason
    after TimeoutMs ->
        error({timeout_waiting_down, Pid})
    end.

%% =========================================================================
%% Tests
%% =========================================================================

t_sync_local_call_basic() ->
    with_framework(fun(A, _AppName) ->
        ok = lingofuse:register_call_sync(A, <<"echo">>, <<"sync echo">>,
                                          self()),
        {Pid, MonRef} = spawn_local_call_worker(
                          A, <<"echo">>, <<"hello">>, self()),
        {Ref, <<"hello">>} = await_callback(<<"echo">>, 3000),
        ok = lingofuse:reply(Ref, <<"world">>),
        {ok, ResultHnd} = await_worker_result(Pid, 3000),
        try
            {ok, 5} = lingofuse:get_size(ResultHnd),
            {ok, <<"world">>} = lingofuse:read_buffer(ResultHnd, 5)
        after
            lingofuse:free_data(ResultHnd)
        end,
        normal = await_down(MonRef, Pid, 1000)
    end).

t_sync_local_call_delayed() ->
    with_framework(fun(A, _AppName) ->
        ok = lingofuse:register_call_sync(A, <<"slow">>, <<"slow sync">>,
                                          self()),
        {Pid, MonRef} = spawn_local_call_worker(
                          A, <<"slow">>, <<"tick">>, self()),
        {Ref, <<"tick">>} = await_callback(<<"slow">>, 3000),
        %% Delay the reply to prove the C callback really blocks
        %% until reply/2 arrives.
        timer:sleep(200),
        ok = lingofuse:reply(Ref, <<"tock">>),
        {ok, ResultHnd} = await_worker_result(Pid, 3000),
        try
            {ok, <<"tock">>} = lingofuse:read_buffer(ResultHnd, 4)
        after
            lingofuse:free_data(ResultHnd)
        end,
        normal = await_down(MonRef, Pid, 1000)
    end).

t_reply_unknown_ref() ->
    with_framework(fun(_A, _AppName) ->
        %% 0 is not a valid ref: the C side starts its counter at 1.
        ?assertEqual({error, unknown_ref},
                     lingofuse:reply(0, <<"payload">>)),
        ?assertEqual({error, unknown_ref},
                     lingofuse:reply(16#DEADBEEF, <<"x">>))
    end).

t_sync_timeout_empty_output() ->
    with_framework(fun(A, _AppName) ->
        %% Set a short timeout so the test does not wait 30 seconds.
        ok = lingofuse:set_sync_timeout(300),
        ok = lingofuse:register_call_sync(A, <<"silent">>, <<"never replies">>,
                                          self()),
        {Pid, MonRef} = spawn_local_call_worker(
                          A, <<"silent">>, <<"in">>, self()),
        {Ref, <<"in">>} = await_callback(<<"silent">>, 3000),
        %% Do NOT reply. The C callback will time out after ~300 ms
        %% and return with an empty output handle.
        {ok, ResultHnd} = await_worker_result(Pid, 3000),
        try
            {ok, 0} = lingofuse:get_size(ResultHnd)
        after
            lingofuse:free_data(ResultHnd)
        end,
        normal = await_down(MonRef, Pid, 1000),
        %% A reply after the timeout must be rejected cleanly.
        ?assertEqual({error, unknown_ref},
                     lingofuse:reply(Ref, <<"late">>))
    end).

t_sync_timeout_roundtrip() ->
    with_framework(fun(_A, _AppName) ->
        ok = lingofuse:set_sync_timeout(1234),
        ?assertEqual({ok, 1234}, lingofuse:get_sync_timeout()),
        ok = lingofuse:set_sync_timeout(5000),
        ?assertEqual({ok, 5000}, lingofuse:get_sync_timeout())
    end).

t_sync_timeout_badarg() ->
    with_framework(fun(_A, _AppName) ->
        ?assertError(badarg, lingofuse:set_sync_timeout(0)),
        ?assertError(badarg, lingofuse:set_sync_timeout(-1)),
        ?assertError(badarg, lingofuse:set_sync_timeout(not_an_int))
    end).

t_multiple_concurrent_sync_calls() ->
    with_framework(fun(A, _AppName) ->
        ok = lingofuse:register_call_sync(A, <<"n">>, <<"n">>, self()),
        Count = 5,
        Workers = [spawn_local_call_worker(
                     A, <<"n">>,
                     integer_to_binary(N), self())
                   || N <- lists:seq(1, Count)],
        %% Collect and reply to every callback.
        lists:foreach(
          fun(_) ->
              {Ref, Payload} = await_callback(<<"n">>, 5000),
              %% Reply echoes the input with a "r:" prefix.
              Reply = <<"r:", Payload/binary>>,
              ok = lingofuse:reply(Ref, Reply)
          end, lists:seq(1, Count)),
        %% Collect every worker's result. `await_down/3` returns the
        %% process exit reason; a worker that completes normally
        %% produces the atom `normal`. The previous revision of this
        %% test compared the reason to `ok`, which never matched and
        %% produced {badmatch, normal}.
        Results = [begin
                       {Pid, MonRef} = W,
                       {ok, Hnd} = await_worker_result(Pid, 5000),
                       normal = await_down(MonRef, Pid, 1000),
                       try
                           {ok, Sz} = lingofuse:get_size(Hnd),
                           {ok, Bin} = lingofuse:read_buffer(Hnd, Sz),
                           Bin
                       after
                           lingofuse:free_data(Hnd)
                       end
                   end || W <- Workers],
        %% Every reply must be observed exactly once, and every
        %% input must have been matched to its own output.
        Sorted = lists:sort(Results),
        Expected = lists:sort(
                     [<<"r:", (integer_to_binary(N))/binary>>
                      || N <- lists:seq(1, Count)]),
        ?assertEqual(Expected, Sorted)
    end).

t_async_call_unchanged() ->
    %% The original register_call/4 (async mode) must still deliver
    %% {lf_call, ApiName, Payload} without a ref, and the C callback
    %% must return without waiting.
    with_framework(fun(A, _AppName) ->
        ok = lingofuse:register_call(A, <<"legacy">>, <<"async">>, self()),
        {Pid, MonRef} = spawn_local_call_worker(
                          A, <<"legacy">>, <<"payload">>, self()),
        receive
            {lf_call, <<"legacy">>, <<"payload">>} -> ok;
            {lf_call, _Ref, _, _} ->
                ?assert(false)
        after 3000 ->
            ?assert(false)
        end,
        {ok, ResultHnd} = await_worker_result(Pid, 3000),
        try
            %% Async mode leaves the output handle empty.
            {ok, 0} = lingofuse:get_size(ResultHnd)
        after
            lingofuse:free_data(ResultHnd)
        end,
        normal = await_down(MonRef, Pid, 1000)
    end).