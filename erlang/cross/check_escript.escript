#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell -noinput
-mode(compile).

%% =============================================================================
%%  check_escript.escript
%% -----------------------------------------------------------------------------
%%  Syntax-check .escript files without executing them.
%%
%%  Background
%%  ----------
%%  `rebar3 compile` only scans src/ and test/, so the escripts under
%%  cross/ are not touched by any build step. This tool closes that
%%  gap: it strips the escript header, compiles the remaining Erlang
%%  source, and reports every error and warning.
%%
%%  Usage
%%  -----
%%      escript cross/check_escript.escript              # default: cross/*.escript
%%      escript cross/check_escript.escript FILE...      # explicit files
%%
%%  Exit codes
%%  ----------
%%      0 - all files passed
%%      1 - at least one file failed
%%
%%  Windows example
%%  ---------------
%%      cd D:\CoreLibrary\LingoFuse\erlang
%%      escript cross\check_escript.escript
%% =============================================================================

main(Args) ->
    Files = resolve_files(Args),
    case Files of
        [] ->
            io:format(standard_error,
                      "check_escript: no escript files found.~n", []),
            halt(0);
        _ ->
            TmpDir = unique_tmp_dir(),
            ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
            try
                io:format("Checking ~p escript file(s)~n", [length(Files)]),
                Results = [check_one(F, TmpDir) || F <- Files],
                print_summary(Results),
                AllOk = lists:all(
                          fun({_, ok}) -> true; (_) -> false end,
                          Results),
                case AllOk of
                    true  -> halt(0);
                    false -> halt(1)
                end
            after
                cleanup_dir(TmpDir)
            end
    end.

%% -----------------------------------------------------------------------------
%%  File resolution
%% -----------------------------------------------------------------------------

resolve_files([]) ->
    filelib:wildcard("cross/*.escript");
resolve_files(Args) ->
    [F || F <- Args, filelib:is_file(F)].

%% -----------------------------------------------------------------------------
%%  Per-file check
%% -----------------------------------------------------------------------------

%% Returns {File, ok} on success or {File, fail} on failure. The
%% caller treats the result as an opaque tuple; the file name is
%% carried along for the final summary.
check_one(File, TmpDir) ->
    io:format("~n--- ~ts ---~n", [File]),
    case file:read_file(File) of
        {ok, RawBin} ->
            Source  = strip_header(RawBin),
            ModName = derive_module_name(File, Source),
            Source1 = ensure_module_attribute(Source, ModName),
            TmpFile = filename:join(TmpDir,
                                    atom_to_list(ModName) ++ ".erl"),
            ok = file:write_file(TmpFile, Source1),
            Result =
                try
                    run_compile(TmpFile)
                after
                    try file:delete(TmpFile)
                    catch _:_ -> ok
                    end
                end,
            {File, Result};
        {error, Reason} ->
            io:format("  cannot read: ~p~n", [Reason]),
            {File, fail}
    end.

%% -----------------------------------------------------------------------------
%%  Header stripping
%% -----------------------------------------------------------------------------

%% Strip the following lines:
%%   - the shebang line         #!/usr/bin/env escript
%%   - every %%! directive      %%! -noshell -noinput
%%   - the -mode(...). pragma   (escript-only)
strip_header(Bin) ->
    Lines = binary:split(Bin, [<<"\r\n">>, <<"\n">>], [global]),
    Kept  = lists:filter(fun keep_line/1, Lines),
    iolist_to_binary(lists:join(<<"\n">>, Kept)).

keep_line(<<"#!", _/binary>>)  -> false;
keep_line(<<"%%!", _/binary>>) -> false;
keep_line(Line) ->
    Stripped = string:trim(binary_to_list(Line)),
    not lists:prefix("-mode(", Stripped).

%% -----------------------------------------------------------------------------
%%  Module name handling
%% -----------------------------------------------------------------------------

%% Extract an existing -module attribute from the source, if any.
extract_module_name(Source) ->
    case re:run(Source,
                <<"-module\\s*\\(\\s*([a-zA-Z_][a-zA-Z0-9_@]*)\\s*\\)">>,
                [{capture, [1], binary}]) of
        {match, [Name]} -> {ok, binary_to_atom(Name, utf8)};
        nomatch         -> not_found
    end.

%% Derive a module name. Escripts usually have no -module, so one
%% is synthesized from the file name.
derive_module_name(File, Source) ->
    case extract_module_name(Source) of
        {ok, Name} ->
            Name;
        not_found ->
            Base    = filename:basename(File, ".escript"),
            Cleaned = re:replace(Base, "[^a-zA-Z0-9_]",
                                 "_", [global, {return, list}]),
            NameStr = case Cleaned of
                [C | _] when C >= $a, C =< $z -> Cleaned;
                [C | _] when C >= $A, C =< $Z -> Cleaned;
                _ -> "escript_" ++ Cleaned
            end,
            list_to_atom(NameStr)
    end.

%% Insert a -module attribute when the source does not already
%% declare one.
ensure_module_attribute(Source, ModName) ->
    case extract_module_name(Source) of
        {ok, _} ->
            Source;
        not_found ->
            ModLine = iolist_to_binary(
                        io_lib:format("-module(~p).~n", [ModName])),
            <<ModLine/binary, Source/binary>>
    end.

%% -----------------------------------------------------------------------------
%%  Compilation and reporting
%% -----------------------------------------------------------------------------

%% The temporary module is compiled with `export_all` so that the
%% `unused_function` warning is not emitted for every top-level
%% function in the escript. The escript runtime effectively exports
%% them all; we simply mirror that behaviour here.
run_compile(TmpFile) ->
    Opts = [
        return_errors,
        return_warnings,
        binary,
        export_all,
        nowarn_export_all,
        nowarn_shadow_vars
    ],
    case compile:file(TmpFile, Opts) of
        {ok, _Mod, _Bin} ->
            io:format("  OK (no warnings)~n"),
            ok;
        {ok, _Mod, _Bin, []} ->
            io:format("  OK (no warnings)~n"),
            ok;
        {ok, _Mod, _Bin, Warnings} ->
            io:format("  OK, ~p warning(s):~n", [length(Warnings)]),
            print_messages(Warnings),
            ok;
        {error, Errors, Warnings} ->
            io:format("  FAIL: ~p error(s), ~p warning(s)~n",
                      [length(Errors), length(Warnings)]),
            io:format("  Errors:~n"),
            print_messages(Errors),
            case Warnings of
                [] -> ok;
                _ ->
                    io:format("  Warnings:~n"),
                    print_messages(Warnings)
            end,
            fail;
        error ->
            io:format("  FAIL: compilation failed~n"),
            fail
    end.

print_messages(Messages) ->
    lists:foreach(
      fun(Msg) ->
          io:format("    ~ts~n", [format_message(Msg)])
      end, Messages).

format_message({File, [{Line, Mod, Desc}]}) ->
    io_lib:format("~ts:~p: ~ts: ~ts",
                  [File, Line, Mod, Mod:format_error(Desc)]);
format_message({Line, Mod, Desc}) when is_integer(Line) ->
    io_lib:format("line ~p: ~ts: ~ts",
                  [Line, Mod, Mod:format_error(Desc)]);
format_message(Other) ->
    io_lib:format("~p", [Other]).

%% -----------------------------------------------------------------------------
%%  Summary
%% -----------------------------------------------------------------------------

print_summary(Results) ->
    io:format("~n=== Summary ===~n"),
    lists:foreach(
      fun({File, ok})   -> io:format("  OK   ~ts~n", [File]);
         ({File, fail}) -> io:format("  FAIL ~ts~n", [File])
      end, Results),
    OkCount   = length([1 || {_, ok}   <- Results]),
    FailCount = length([1 || {_, fail} <- Results]),
    io:format("  passed: ~p   failed: ~p~n", [OkCount, FailCount]).

%% -----------------------------------------------------------------------------
%%  Temporary directory
%% -----------------------------------------------------------------------------

unique_tmp_dir() ->
    Unique = integer_to_list(erlang:unique_integer([positive])),
    filename:join(base_tmp_dir(), "check_escript_" ++ Unique).

base_tmp_dir() ->
    case os:getenv("TMPDIR") of
        false ->
            case os:getenv("TEMP") of
                false ->
                    case os:getenv("TMP") of
                        false -> "/tmp";
                        D     -> D
                    end;
                D -> D
            end;
        D -> D
    end.

cleanup_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(
              fun(E) ->
                  try file:delete(filename:join(Dir, E))
                  catch _:_ -> ok
                  end
              end,
              Entries),
            try file:del_dir(Dir)
            catch _:_ -> ok
            end,
            ok;
        {error, _} ->
            ok
    end.