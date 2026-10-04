#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% =============================================================================
%%  cross_service.escript
%% -----------------------------------------------------------------------------
%%  Coordinator process for the IPC endpoint "ipc:cross".
%%
%%  This program:
%%    1. Loads the LingoFuse NIF binding from the local build directory.
%%    2. Creates the IPC service endpoint "ipc:cross".
%%    3. Starts the framework (LF_PrepareDone).
%%    4. Waits for the user to press Enter.
%%    5. Performs a clean shutdown:
%%         LF_ExitMainThread -> LF_Shutdown
%%
%%  It does NOT register any API and does NOT create a client. Its sole
%%  purpose is to act as the discovery/anchor endpoint that worker nodes
%%  and callers connect to.
%%
%%  The endpoint name, the option set, and the shutdown sequence mirror
%%  the C++ / C# / Python / JavaScript Cross demos so that the three
%%  programs can be started in any mix of languages and still interoperate.
%%
%%  Usage (from the project root):
%%      escript cross/cross_service.escript
%%
%%  On Windows, the same command works from PowerShell, provided the
%%  Erlang bin directory is on PATH. Alternatively use the included
%%  helper: cross\run_service.cmd
%% =============================================================================

-mode(compile).

-define(ENDPOINT, <<"ipc:cross">>).

main(_Args) ->
    io:format("=== Cross Service (Coordinator) ===~n"),

    ok = setup_code_path(),
    ok = require_native_library(),

    %% Deployment-friendly options. These match the other language
    %% bindings' Cross demos:
    %%   - Wait_Connection_ReadyOk=False so prepare_done returns as
    %%     soon as the event loop is up (nodes may start out of order);
    %%   - Overlap_Connection=True so multiple clients can attach to
    %%     the same physical address.
    ok = lingofuse:set_option(<<"Wait_Connection_ReadyOk">>, <<"False">>),
    ok = lingofuse:set_option(<<"Overlap_Connection">>,      <<"True">>),
    ok = lingofuse:set_option(<<"Wait_Connection_Timeout">>, <<"10000">>),

    ok = lingofuse:reset_prepare(),

    {ok, ServTag} = lingofuse:prepare_service(?ENDPOINT, ?ENDPOINT),
    io:format("[CrossService] prepare_service ~s tag=~p~n",
              [?ENDPOINT, ServTag]),

    {ok, 1} = lingofuse:prepare_done(),
    io:format("[CrossService] ready on ~s.~n", [?ENDPOINT]),
    io:format("[CrossService] Press Enter to exit.~n"),

    ok = wait_for_enter(),

    io:format("[CrossService] shutting down...~n"),
    _ = lingofuse:exit_main_thread(),
    _ = lingofuse:shutdown(),
    io:format("[CrossService] bye.~n"),
    halt(0).

%% -----------------------------------------------------------------------------
%%  Helpers
%% -----------------------------------------------------------------------------

%% Locate the local lingofuse ebin directory and prepend it to the
%% code path. The script lives at <root>/cross/, so the ebin directory
%% is at <root>/_build/default/lib/lingofuse/ebin.
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
                      "[CrossService] FATAL: cannot find ~s.~n"
                      "[CrossService] Run 'rebar3 compile' in the "
                      "project root first.~n",
                      [EbinDir]),
            halt(1)
    end.

%% Verify that the LingoFuse native library is loaded. If it is not,
%% print a clear diagnostic and exit with status 1.
require_native_library() ->
    case lingofuse:ensure_loaded() of
        ok ->
            io:format("[CrossService] LingoFuse native library loaded.~n"),
            ok;
        {error, lf_not_loaded} ->
            io:format(standard_error,
                      "[CrossService] FATAL: LingoFuse native library "
                      "is not available.~n"
                      "[CrossService] Place LingoFuse64.dll (Windows) "
                      "or liblingofuse.so (Linux) on the loader search "
                      "path and retry.~n", []),
            halt(1)
    end.

%% Block until the user presses Enter. Reads a line from stdin.
%% If stdin is closed (EOF), returns immediately.
wait_for_enter() ->
    case io:get_line("") of
        eof -> ok;
        _   -> ok
    end.