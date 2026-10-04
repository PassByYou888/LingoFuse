#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% =============================================================================
%%  cross_call.escript
%% -----------------------------------------------------------------------------
%%  Concurrent client / load tester for the "ipc:cross" endpoint.
%%
%%  Connects as a pure consumer (no application attached) and spawns
%%  ?WORKER_COUNT Erlang processes. Each worker repeatedly invokes one
%%  of two remote APIs on the "demo" application at random:
%%
%%      add       (int32 a, int32 b) -> int32
%%      inv_seri  (uint8, uint16, uint32, uint64, string, float)
%%                                          -> reversed typed sequence
%%
%%  The test runs for ?TEST_SECONDS seconds and then shuts down
%%  cleanly. Multiple instances of this program may be launched
%%  concurrently to drive even higher load against the mesh.
%%
%%  Wire format
%%  -----------
%%  Both APIs use the raw binary ABI channel. Every byte written into
%%  a request DataHandle matches what the C++ CrossCall.cpp client
%%  writes for the same logical call, so the Erlang CrossCall client
%%  can invoke a C++ / Pascal / Python / C# CrossNode server and vice
%%  versa.
%%
%%  Output policy
%%  -------------
%%  Every successful or failed call prints exactly one line. The
%%  aggregate counters in the summary are exact regardless of how
%%  many lines are printed.
%%
%%  Concurrency model
%%  -----------------
%%  Erlang has no shared-memory threads. ?WORKER_COUNT independent
%%  Erlang processes are used instead. Aggregate counters live in a
%%  shared `counters` array (a lock-free atomic structure available
%%  since OTP 21); a shared `atomics` slot is used as the stop flag.
%%  Both are refs that any process can access without copying.
%%
%%  Usage (from the project root)
%%  -----------------------------
%%      escript cross/cross_call.escript
%%
%%  Or on Windows:
%%      cross\run_call.cmd
%% =============================================================================

-mode(compile).

-define(ENDPOINT,        <<"ipc:cross">>).
-define(TARGET_APP,      <<"demo">>).
-define(WORKER_COUNT,    32).
-define(TEST_SECONDS,    10).
-define(CALL_TIMEOUT_MS, 1000).
-define(PAUSE_MS,        1).

%% Counters array indices.
-define(C_TOTAL,      1).
-define(C_ADD,        2).
-define(C_INV_SERI,   3).
-define(C_SUCCESS,    4).
-define(C_FAILED,     5).

main(_Args) ->
    io:format("=== Cross Call (Client) ===~n"),

    ok = setup_code_path(),
    ok = require_native_library(),

    ok = lingofuse:set_option(<<"Wait_Connection_ReadyOk">>, <<"False">>),
    ok = lingofuse:set_option(<<"Overlap_Connection">>,      <<"True">>),
    ok = lingofuse:set_option(<<"Wait_Connection_Timeout">>, <<"10000">>),

    ok = lingofuse:reset_prepare(),
    {ok, CliTag} = lingofuse:prepare_client(?ENDPOINT, undefined),
    io:format("[CrossCall] prepare_client ~s tag=~p~n",
              [?ENDPOINT, CliTag]),

    {ok, 1} = lingofuse:prepare_done(),

    ok = wait_for_app(?TARGET_APP, 10000),
    io:format("[CrossCall] target app ~s is online.~n", [?TARGET_APP]),
    io:format("[CrossCall] starting ~p processes for ~p seconds...~n",
              [?WORKER_COUNT, ?TEST_SECONDS]),
    io:format("~n"),

    %% Shared state.
    Counters = counters:new(5, [write_concurrency]),
    StopFlag = atomics:new(1, [{signed, false}]),
    atomics:put(StopFlag, 1, 0),

    T0 = erlang:monotonic_time(millisecond),

    Workers = [spawn_monitor(fun() -> worker(I, StopFlag, Counters) end)
               || I <- lists:seq(1, ?WORKER_COUNT)],

    timer:sleep(?TEST_SECONDS * 1000),
    atomics:put(StopFlag, 1, 1),

    %% Wait for every worker to exit.
    lists:foreach(
      fun({_Pid, Ref}) ->
          receive
              {'DOWN', Ref, process, _, _} -> ok
          after 5000 ->
              ok
          end
      end, Workers),

    T1 = erlang:monotonic_time(millisecond),
    ElapsedS = (T1 - T0) / 1000.0,

    Total          = counters:get(Counters, ?C_TOTAL),
    AddCalls       = counters:get(Counters, ?C_ADD),
    InvSeriCalls   = counters:get(Counters, ?C_INV_SERI),
    Success        = counters:get(Counters, ?C_SUCCESS),
    Failed         = counters:get(Counters, ?C_FAILED),

    SuccessRate =
        case Total of
            0 -> 0.0;
            _ -> 100.0 * Success / Total
        end,

    Throughput =
        case ElapsedS > 0.0 of
            true  -> Total / ElapsedS;
            false -> 0.0
        end,

    SuccessThroughput =
        case ElapsedS > 0.0 of
            true  -> Success / ElapsedS;
            false -> 0.0
        end,

    io:format("~n"),
    io:format("[CrossCall] Load test summary~n"),
    io:format("         duration          : ~.3f s~n", [ElapsedS]),
    io:format("         total calls       : ~p~n", [Total]),
    io:format("         success           : ~p (~.2f %)~n",
              [Success, SuccessRate]),
    io:format("         failed            : ~p~n", [Failed]),
    io:format("         add calls         : ~p~n", [AddCalls]),
    io:format("         inv_seri calls    : ~p~n", [InvSeriCalls]),
    io:format("         throughput        : ~.2f calls/s~n", [Throughput]),
    io:format("         success throughput: ~.2f calls/s~n",
              [SuccessThroughput]),
    io:format("~n"),
    io:format("[CrossCall] Press Enter to exit.~n"),
    _ = io:get_line(""),

    _ = lingofuse:exit_main_thread(),
    _ = lingofuse:shutdown(),
    io:format("[CrossCall] bye.~n"),
    halt(0).

%% -----------------------------------------------------------------------------
%%  Worker process
%% -----------------------------------------------------------------------------

worker(Index, StopFlag, Counters) ->
    %% Seed the per-process RNG. Each Erlang process has its own
    %% rand state, so no cross-process contention is possible.
    _ = rand:seed(exsss,
                  {erlang:phash2(self()) + Index,
                   erlang:unique_integer([positive]),
                   erlang:system_time(microsecond)}),
    worker_loop(Index, StopFlag, Counters).

worker_loop(Index, StopFlag, Counters) ->
    case atomics:get(StopFlag, 1) of
        1 ->
            ok;
        0 ->
            case rand:uniform(2) of
                1 -> do_add(Index, Counters);
                2 -> do_inv_seri(Index, Counters)
            end,
            case ?PAUSE_MS of
                0 -> ok;
                _ -> timer:sleep(?PAUSE_MS)
            end,
            worker_loop(Index, StopFlag, Counters)
    end.

%% add(int32 a, int32 b) -> int32
%%
%% Prints one line per call so the operator can see the client is
%% actually running. The aggregate counters in the final summary are
%% unaffected by the number of printed lines.
do_add(Index, Counters) ->
    A = rand:uniform(1000),
    B = rand:uniform(1000),
    counters:add(Counters, ?C_TOTAL, 1),
    counters:add(Counters, ?C_ADD, 1),
    try
        {ok, P} = lingofuse:create_data(<<"add">>),
        try
            {ok, 8} = lingofuse:write_buffer(
                        P, <<A:32/little-signed, B:32/little-signed>>),
            case lingofuse:call(?TARGET_APP, P, ?CALL_TIMEOUT_MS) of
                {ok, R} ->
                    try
                        case lingofuse:get_size(R) of
                            {ok, 4} ->
                                {ok, <<Sum:32/little-signed>>} =
                                    lingofuse:read_buffer(R, 4),
                                counters:add(Counters, ?C_SUCCESS, 1),
                                io:format("[CrossCall ~p] "
                                          "add(~p, ~p) = ~p~n",
                                          [Index, A, B, Sum]);
                            _ ->
                                counters:add(Counters, ?C_FAILED, 1),
                                io:format("[CrossCall ~p] "
                                          "add(~p, ~p) failed: "
                                          "empty response~n",
                                          [Index, A, B])
                        end
                    after
                        lingofuse:free_data(R)
                    end;
                {error, CallErr} ->
                    counters:add(Counters, ?C_FAILED, 1),
                    io:format("[CrossCall ~p] add(~p, ~p) failed: ~p~n",
                              [Index, A, B, CallErr])
            end
        after
            lingofuse:free_data(P)
        end
    catch
        Class:CaughtReason ->
            counters:add(Counters, ?C_FAILED, 1),
            io:format("[CrossCall ~p] add(~p, ~p) exception: ~p:~p~n",
                      [Index, A, B, Class, CaughtReason])
    end.

%% inv_seri() -> reversed typed sequence
do_inv_seri(Index, Counters) ->
    B   = 200,
    W   = 16#10,
    C   = 16#2F,
    U64 = 16#3F,
    S   = <<"hello world">>,
    F   = 3.14,
    counters:add(Counters, ?C_TOTAL, 1),
    counters:add(Counters, ?C_INV_SERI, 1),
    try
        {ok, P} = lingofuse:create_data(<<"inv_seri">>),
        try
            Req = <<B:8,
                    W:16/little-unsigned,
                    C:32/little-unsigned,
                    U64:64/little-unsigned,
                    S/binary, 0,
                    F:32/little-float>>,
            {ok, _} = lingofuse:write_buffer(P, Req),
            case lingofuse:call(?TARGET_APP, P, ?CALL_TIMEOUT_MS) of
                {ok, R} ->
                    try
                        case lingofuse:get_size(R) of
                            {ok, Sz} when Sz > 0 ->
                                {ok, Bin} = lingofuse:read_buffer(R, Sz),
                                case parse_inv_seri_response(Bin) of
                                    {ok, Parsed} ->
                                        counters:add(Counters,
                                                     ?C_SUCCESS, 1),
                                        io:format(
                                          "[CrossCall ~p] "
                                          "inv_seri reply: ~p~n",
                                          [Index, Parsed]);
                                    error ->
                                        counters:add(Counters,
                                                     ?C_FAILED, 1),
                                        io:format(
                                          "[CrossCall ~p] "
                                          "inv_seri parse error: ~p~n",
                                          [Index, Bin])
                                end;
                            _ ->
                                counters:add(Counters, ?C_FAILED, 1),
                                io:format(
                                  "[CrossCall ~p] inv_seri failed: "
                                  "empty response~n",
                                  [Index])
                        end
                    after
                        lingofuse:free_data(R)
                    end;
                {error, CallErr} ->
                    counters:add(Counters, ?C_FAILED, 1),
                    io:format("[CrossCall ~p] inv_seri failed: ~p~n",
                              [Index, CallErr])
            end
        after
            lingofuse:free_data(P)
        end
    catch
        Class:CaughtReason ->
            counters:add(Counters, ?C_FAILED, 1),
            io:format("[CrossCall ~p] inv_seri exception: ~p:~p~n",
                      [Index, Class, CaughtReason])
    end.

%% Parse the inv_seri response: float, string(NUL), uint64, uint32,
%% uint16, uint8 -- in that order.
parse_inv_seri_response(Bin) ->
    try
        <<F:32/little-float, Rest/binary>> = Bin,
        {S, <<U64:64/little-unsigned,
              C:32/little-unsigned,
              W:16/little-unsigned,
              B:8>>} = read_nul_string(Rest),
        {ok, [F, S, U64, C, W, B]}
    catch
        _:_ -> error
    end.

read_nul_string(Bin) ->
    case binary:match(Bin, <<0>>) of
        {Pos, 1} ->
            <<Str:Pos/binary, 0, Rest/binary>> = Bin,
            {Str, Rest};
        nomatch ->
            error(missing_nul_terminator)
    end.

%% -----------------------------------------------------------------------------
%%  Helpers
%% -----------------------------------------------------------------------------

wait_for_app(_Name, 0) ->
    io:put_chars(standard_error,
                 "[CrossCall] FATAL: target app did not appear in time.\n"
                 "[CrossCall] Is cross_node (or any 'demo' worker) running?\n"),
    halt(1);
wait_for_app(Name, Remaining) ->
    case lingofuse:check_app(Name) of
        {ok, true} -> ok;
        _ ->
            timer:sleep(100),
            wait_for_app(Name, Remaining - 100)
    end.

setup_code_path() ->
    ScriptPath = filename:absname(escript:script_name()),
    CrossDir   = filename:dirname(ScriptPath),
    RootDir    = filename:dirname(CrossDir),
    EbinDir    = filename:join([RootDir, "_build", "default",
                                "lib", "lingofuse", "ebin"]),
    case filelib:is_dir(EbinDir) of
        true ->
            code:add_patha(EbinDir),
            ok;
        false ->
            io:format(standard_error,
                      "[CrossCall] FATAL: cannot find ~s.~n"
                      "[CrossCall] Run 'rebar3 compile' in the "
                      "project root first.~n",
                      [EbinDir]),
            halt(1)
    end.

require_native_library() ->
    case lingofuse:ensure_loaded() of
        ok ->
            io:format("[CrossCall] LingoFuse native library loaded.~n"),
            ok;
        {error, lf_not_loaded} ->
            io:put_chars(standard_error,
                         "[CrossCall] FATAL: LingoFuse native library "
                         "is not available.\n"),
            halt(1)
    end.