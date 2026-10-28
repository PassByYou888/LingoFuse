#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell -noinput
-mode(compile).

-include_lib("kernel/include/file.hrl").

-define(SRC_FILES, ["lingofuse_nif.c", "lf_loader.c"]).
-define(LIB_NAME, "lingofuse_nif").

main(_Args) ->
    case skip_requested() of
        true ->
            io:format("[build] LINGOFUSE_SKIP_NIF is truthy; "
                      "skipping the NIF build.~n"),
            halt(0);
        false ->
            build_nif()
    end.

skip_requested() ->
    case os:getenv("LINGOFUSE_SKIP_NIF") of
        false -> false;
        ""    -> false;
        Val   ->
            case string:lowercase(string:trim(Val)) of
                "0"     -> false;
                "false" -> false;
                "no"    -> false;
                "off"   -> false;
                _       -> true
            end
    end.

build_nif() ->
    ScriptPath = filename:absname(escript:script_name()),
    CSrcDir    = filename:dirname(ScriptPath),
    RootDir    = filename:dirname(CSrcDir),
    PrivDir    = filename:join(RootDir, "priv"),

    info("project root", RootDir),
    info("c_src dir",    CSrcDir),

    ok = ensure_dir(PrivDir),

    ErlRoot     = code:root_dir(),
    ErtsVer     = erlang:system_info(version),
    ErtsInclude = filename:join([ErlRoot, "erts-" ++ ErtsVer, "include"]),
    info("erl root",     ErlRoot),
    info("erts include", ErtsInclude),

    HeaderCheck = filename:join(ErtsInclude, "erl_nif.h"),
    case filelib:is_file(HeaderCheck) of
        false ->
            err("erl_nif.h not found at ~s", [HeaderCheck]),
            halt(1);
        true -> ok
    end,

    {CC, CCName} = find_cc(),
    info("compiler", CC ++ " (" ++ CCName ++ ")"),

    Ext    = lib_extension(),
    Target = filename:join(PrivDir, ?LIB_NAME ++ Ext),
    info("output", Target),

    case is_msvc(CCName) of
        true ->
            build_with_msvc(CC, CSrcDir, ErtsInclude, ErlRoot, ErtsVer,
                            PrivDir, Target);
        false ->
            build_with_gcc(CC, CSrcDir, ErtsInclude, PrivDir, Target)
    end,

    case filelib:file_size(Target) of
        0 ->
            err("post-build check: ~s is 0 bytes", [Target]),
            halt(3);
        _ -> ok
    end,

    copy_to_build_dir(RootDir, Target),

    case filelib:file_size(Target) of
        0 ->
            err("post-copy check: ~s is 0 bytes (copy truncated it)",
                [Target]),
            halt(4);
        _ -> ok
    end,

    io:format("[build] OK~n"),
    halt(0).

copy_to_build_dir(RootDir, Target) ->
    BaseName = filename:basename(Target),
    Candidates = [
        filename:join([RootDir, "_build", "default", "lib",
                       "lingofuse", "priv", BaseName]),
        filename:join([RootDir, "_build", "test", "lib",
                       "lingofuse", "priv", BaseName])
    ],
    lists:foreach(fun(Dest) -> maybe_copy(Target, Dest) end, Candidates).

maybe_copy(Target, Dest) ->
    case filelib:is_dir(filename:dirname(Dest)) of
        false ->
            info("skip (no dir)", filename:dirname(Dest));
        true ->
            case same_stat(Target, Dest) of
                true ->
                    info("skip (same file)", Dest);
                false ->
                    case file:copy(Target, Dest) of
                        {ok, _} ->
                            info("copied to", Dest);
                        {error, R} ->
                            io:format(standard_error,
                                      "[build] WARN: cannot copy to ~s: ~p~n",
                                      [Dest, R])
                    end
            end
    end.

same_stat(P1, P2) ->
    case {file:read_file_info(P1), file:read_file_info(P2)} of
        {{ok, I1}, {ok, I2}} ->
            I1#file_info.size =:= I2#file_info.size andalso
            I1#file_info.mtime =:= I2#file_info.mtime;
        _ -> false
    end.

build_with_gcc(CC, CSrcDir, ErtsInclude, PrivDir, Target) ->
    _ = PrivDir,
    RootDir = filename:dirname(CSrcDir),
    Objs = [compile_one_gcc(CC, RootDir, CSrcDir, ErtsInclude, Src)
            || Src <- ?SRC_FILES],

    io:format("~n[build] object file sizes:~n"),
    lists:foreach(fun report_size/1, Objs),

    link_gcc(CC, Objs, Target),

    io:format("~n[build] output file size:~n"),
    report_size(Target),

    case filelib:file_size(Target) of
        0 ->
            err("gcc produced a 0-byte DLL: ~s", [Target]),
            err("object files are: ~p", [Objs]),
            halt(2);
        _ -> ok
    end,
    ok.

report_size(Path) ->
    case filelib:is_file(Path) of
        false ->
            io:format("         ~-60s MISSING~n", [Path]);
        true ->
            case filelib:file_size(Path) of
                0 -> io:format("         ~-60s 0 bytes (EMPTY!)~n", [Path]);
                N -> io:format("         ~-60s ~p bytes~n", [Path, N])
            end
    end.

compile_one_gcc(CC, RootDir, CSrcDir, ErtsInclude, Src) ->
    ObjName = filename:basename(Src, ".c") ++ ".o",
    Obj     = filename:join(RootDir, ObjName),
    SrcPath = filename:join(CSrcDir, Src),
    case filelib:is_file(SrcPath) of
        false ->
            err("source not found: ~s", [SrcPath]),
            halt(1);
        true -> ok
    end,
    BaseArgs = ["-O2", "-Wall", "-Wextra", "-std=c11",
                "-I", ErtsInclude,
                "-c", "-o", Obj, SrcPath],
    Args = case os:type() of
               {win32, _} -> BaseArgs;
               _          -> ["-fPIC" | BaseArgs]
           end,
    run(CC, Args),
    case filelib:file_size(Obj) of
        0 ->
            err("gcc produced a 0-byte object: ~s", [Obj]),
            halt(2);
        _ -> ok
    end,
    Obj.

link_gcc(CC, Objs, Target) ->
    _ = file:delete(Target),
    Args = link_flags_gcc() ++ ["-o", Target | Objs],
    run(CC, Args).

link_flags_gcc() ->
    case os:type() of
        {win32, _}     -> ["-shared"];
        {unix, darwin} -> ["-bundle", "-undefined", "dynamic_lookup"];
        _              -> ["-shared"]
    end.

build_with_msvc(CC, CSrcDir, ErtsInclude, ErlRoot, ErtsVer,
                PrivDir, Target) ->
    _ = PrivDir,
    SrcPaths = [filename:join(CSrcDir, S) || S <- ?SRC_FILES],
    [case filelib:is_file(P) of
         false ->
             err("source not found: ~s", [P]),
             halt(1);
         true -> ok
     end || P <- SrcPaths],

    _ = file:delete(Target),

    BaseArgs = ["/nologo", "/O2", "/W3", "/std:c11", "/MD",
                "/LD",
                "/I" ++ ErtsInclude,
                "/Fe" ++ Target],

    Args = case find_erl_nif_lib(ErlRoot, ErtsVer) of
               {ok, LibPath} ->
                   info("import lib", LibPath),
                   BaseArgs ++ SrcPaths ++ [LibPath];
               not_found ->
                   info("import lib",
                        "(not found; relying on runtime resolution)"),
                   BaseArgs ++ SrcPaths
           end,

    run(CC, Args).

find_erl_nif_lib(ErlRoot, ErtsVer) ->
    Candidates = [
        filename:join([ErlRoot, "erts-" ++ ErtsVer, "lib", "erl_nif.lib"]),
        filename:join([ErlRoot, "erts-" ++ ErtsVer, "lib", "erl_nif.lib",
                       "Release", "erl_nif.lib"]),
        filename:join([ErlRoot, "lib", "erl_nif.lib"])
    ],
    find_first_existing(Candidates).

find_first_existing([]) -> not_found;
find_first_existing([P | Rest]) ->
    case filelib:is_file(P) of
        true  -> {ok, P};
        false -> find_first_existing(Rest)
    end.

find_cc() ->
    case os:getenv("LINGOFUSE_CC") of
        false -> find_cc_auto();
        ""    -> find_cc_auto();
        Requested ->
            case os:find_executable(Requested) of
                false ->
                    err("LINGOFUSE_CC=~s not found on PATH",
                        [Requested]),
                    halt(1);
                AbsPath ->
                    info("LINGOFUSE_CC", Requested),
                    {ok, {AbsPath, filename:basename(Requested)}}
            end
    end.

find_cc_auto() ->
    Primary = ["gcc", "clang", "cc"],
    case try_cc_list(Primary) of
        {ok, Result} -> Result;
        not_found ->
            case os:type() of
                {win32, _} ->
                    case try_cc_list(["cl"]) of
                        {ok, R} -> R;
                        not_found -> halt_no_cc()
                    end;
                _ ->
                    halt_no_cc()
            end
    end.

try_cc_list([]) -> not_found;
try_cc_list([Name | Rest]) ->
    case os:find_executable(Name) of
        false   -> try_cc_list(Rest);
        AbsPath -> {ok, {AbsPath, Name}}
    end.

halt_no_cc() ->
    err("no C compiler found on PATH. Install one of: "
        "gcc, clang, cc (POSIX), or cl (MSVC on Windows).", []),
    halt(1).

is_msvc(Name) ->
    L = string:lowercase(Name),
    L =:= "cl" orelse lists:suffix("cl.exe", L).

ensure_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true -> ok;
        false ->
            case file:make_dir(Dir) of
                ok               -> ok;
                {error, eexist}  -> ok;
                {error, Reason}  ->
                    err("cannot create ~s: ~p", [Dir, Reason]),
                    halt(1)
            end
    end.

lib_extension() ->
    case os:type() of
        {win32, _}     -> ".dll";
        {unix, darwin} -> ".so";
        _              -> ".so"
    end.

run(Exe, Args) ->
    display_command(Exe, Args),
    Q = fun(S) ->
        case lists:any(fun(C) -> C =:= $\s orelse C =:= $" end, S) of
            true  -> [$", S, $"];
            false -> S
        end
    end,
    Cmd = Q(Exe) ++ " " ++ lists:join(" ", [Q(A) || A <- Args]) ++ " 2>&1",
    Output = os:cmd(Cmd),
    case Output of
        "" -> ok;
        _  -> io:format("         ~s", [Output])
    end,
    ok.

display_command(Exe, Args) ->
    Quoted = [quote(A) || A <- Args],
    io:format("[build] ~s ~s~n",
              [filename:basename(Exe), lists:join(" ", Quoted)]).

quote(S) ->
    case lists:any(fun(C) -> C =:= $\s end, S) of
        true  -> [$", S, $"];
        false -> S
    end.

info(Label, Value) ->
    io:format("[build] ~-13s : ~s~n", [Label, Value]).

err(Fmt, Args) ->
    io:format(standard_error, "[build] FATAL: " ++ Fmt ++ "~n", Args).