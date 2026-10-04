#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% =============================================================================
%%  cross_node.escript
%% -----------------------------------------------------------------------------
%%  Worker node that registers the "add" and "inv_seri" Call APIs.
%%
%%  It connects to the IPC endpoint "ipc:cross" as a client and exposes
%%  the application "demo" to the C4 service mesh. Multiple instances
%%  (in different processes) may be launched; the mesh automatically
%%  load-balances incoming calls across all live workers.
%%
%%  Registered APIs
%%  ---------------
%%  Both APIs use the raw binary ABI channel. No JSON is involved at
%%  any point, so a C++ / C# / Python / JavaScript CrossCall client
%%  sees exactly the same bytes it would see from a CrossNode written
%%  in any other language.
%%
%%      add      : (int32 a, int32 b) -> int32
%%                  both integers are little-endian
%%
%%      inv_seri : (uint8, uint16, uint32, uint64, string(NUL), float)
%%              -> (float, string(NUL), uint64, uint32, uint16, uint8)
%%                  all integers little-endian
%%                  the string is UTF-8, NUL-terminated
%%
%%  Callback mode
%%  -------------
%%  register_call_sync/4 is used so that the caller receives a proper
%%  synchronous reply. Each {lf_call, Ref, Api, Payload} message is
%%  handled by the callback loop, which calls lingofuse:reply/2 with
%%  the response payload.
%%
%%  Cleanup order (matching LF-CLEAN-001)
%%  -------------------------------------
%%      LF_ExitMainThread -> LF_FreeApp -> LF_Shutdown
%%
%%  Usage (from the project root)
%%  -----------------------------
%%      escript cross/cross_node.escript
%%
%%  Or on Windows:
%%      cross\run_node.cmd
%% =============================================================================

-mode(compile).

-define(ENDPOINT, <<"ipc:cross">>).
-define(APP_NAME, <<"demo">>).

main(_Args) ->
    io:format("=== Cross Node (Worker) ===~n"),

    ok = setup_code_path(),
    ok = require_native_library(),

    {ok, App} = lingofuse:create_app(
                  ?APP_NAME, <<"Erlang worker node (raw ABI wire format)">>),

    ok = lingofuse:register_call_sync(
           App, <<"add">>,
           <<"add(int a, int b) -> int">>,
           self()),
    ok = lingofuse:register_call_sync(
           App, <<"inv_seri">>,
           <<"inv_seri() -> reversed typed sequence">>,
           self()),

    ok = lingofuse:set_option(<<"Wait_Connection_ReadyOk">>, <<"False">>),
    ok = lingofuse:set_option(<<"Overlap_Connection">>,      <<"True">>),
    ok = lingofuse:set_option(<<"Wait_Connection_Timeout">>, <<"10000">>),

    ok = lingofuse:reset_prepare(),
    {ok, CliTag} = lingofuse:prepare_client(?ENDPOINT, App),
    io:format("[CrossNode] prepare_client ~s tag=~p~n",
              [?ENDPOINT, CliTag]),

    {ok, 1} = lingofuse:prepare_done(),
    io:format("[CrossNode] registered 'add' and 'inv_seri' under ~s.~n",
              [?APP_NAME]),
    io:format("[CrossNode] Press Enter to exit.~n"),

    %% Spawn a background process that watches stdin. When the user
    %% presses Enter, it sends `stop` to the callback loop.
    _ = spawn_enter_watcher(self()),

    ok = loop(),

    io:format("[CrossNode] shutting down...~n"),
    _ = lingofuse:exit_main_thread(),
    _ = lingofuse:free_app(App),
    _ = lingofuse:shutdown(),
    io:format("[CrossNode] bye.~n"),
    halt(0).

%% -----------------------------------------------------------------------------
%%  Callback loop
%% -----------------------------------------------------------------------------

loop() ->
    receive
        {lf_call, Ref, <<"add">>, Payload} ->
            Reply = handle_add(Payload),
            _ = lingofuse:reply(Ref, Reply),
            loop();
        {lf_call, Ref, <<"inv_seri">>, Payload} ->
            Reply = handle_inv_seri(Payload),
            _ = lingofuse:reply(Ref, Reply),
            loop();
        {lf_call, Ref, OtherApi, _} ->
            io:format(standard_error,
                      "[CrossNode] unexpected api ~p ref=~p; replying empty~n",
                      [OtherApi, Ref]),
            _ = lingofuse:reply(Ref, <<>>),
            loop();
        stop ->
            ok
    end.

%% add(int32 a, int32 b) -> int32
handle_add(Payload) ->
    try
        <<A:32/little-signed, B:32/little-signed>> = Payload,
        Sum = A + B,
        io:format("[CrossNode] add(~p, ~p) = ~p~n", [A, B, Sum]),
        <<Sum:32/little-signed>>
    catch
        error:Reason ->
            io:format(standard_error,
                      "[CrossNode] add handler failed: ~p~n", [Reason]),
            <<>>
    end.

%% inv_seri() -> reversed typed sequence
handle_inv_seri(Payload) ->
    try
        <<B:8,
          W:16/little-unsigned,
          C:32/little-unsigned,
          U64:64/little-unsigned,
          Rest/binary>> = Payload,
        {S, <<F:32/little-float>>} = read_nul_string(Rest),

        io:format("[CrossNode] inv_seri received: "
                  "[~p, ~p, ~p, ~p, ~p, ~p]~n",
                  [B, W, C, U64, S, F]),

        %% Reply in reverse field order.
        Resp = <<F:32/little-float,
                 S/binary, 0,
                 U64:64/little-unsigned,
                 C:32/little-unsigned,
                 W:16/little-unsigned,
                 B:8>>,

        io:format("[CrossNode] inv_seri replied:  "
                  "[~p, ~p, ~p, ~p, ~p, ~p]~n",
                  [F, S, U64, C, W, B]),

        Resp
    catch
        error:Reason ->
            io:format(standard_error,
                      "[CrossNode] inv_seri handler failed: ~p~n",
                      [Reason]),
            <<>>
    end.

%% Read a NUL-terminated byte sequence from Bin and return
%% {PayloadBytes, RestOfBin}.
read_nul_string(Bin) ->
    case binary:match(Bin, <<0>>) of
        {Pos, 1} ->
            <<Str:Pos/binary, 0, Rest/binary>> = Bin,
            {Str, Rest};
        nomatch ->
            error({missing_nul_terminator, Bin})
    end.

%% -----------------------------------------------------------------------------
%%  Helpers
%% -----------------------------------------------------------------------------

%% Watch stdin for a single Enter keypress, then send `stop` to the
%% given pid. Runs in a separate process so that the main loop can
%% keep receiving {lf_call, ...} messages while this process blocks
%% on io:get_line/1.
spawn_enter_watcher(Parent) ->
    spawn(fun() ->
        _ = io:get_line(""),
        Parent ! stop
    end),
    ok.

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
                      "[CrossNode] FATAL: cannot find ~s.~n"
                      "[CrossNode] Run 'rebar3 compile' in the "
                      "project root first.~n",
                      [EbinDir]),
            halt(1)
    end.

require_native_library() ->
    case lingofuse:ensure_loaded() of
        ok ->
            io:format("[CrossNode] LingoFuse native library loaded.~n"),
            ok;
        {error, lf_not_loaded} ->
            io:format(standard_error,
                      "[CrossNode] FATAL: LingoFuse native library "
                      "is not available.~n"
                      "[CrossNode] Place LingoFuse64.dll (Windows) "
                      "or liblingofuse.so (Linux) on the loader search "
                      "path and retry.~n", []),
            halt(1)
    end.