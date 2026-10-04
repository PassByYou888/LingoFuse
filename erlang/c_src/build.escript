#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell -noinput
%%
%% c_src/build.escript
%%
%% Portable build script for the LingoFuse NIF.
%%
%% Compiles the C sources in this directory into a shared library in
%% ../priv/. Runs on Windows, Linux, and macOS without any path
%% hardcoding. Invoked by rebar3 as a pre_hook, and also usable by
%% hand:
%%
%%     escript c_src/build.escript
%%
%% Environment variables
%% ---------------------
%% LINGOFUSE_SKIP_NIF
%%   When set to a non-empty value, the script exits successfully
%%   without compiling anything. Use this in CI jobs that only need
%%   to verify the Erlang side.
%%
%% Compiler detection
%% ------------------
%% The script searches PATH for a C compiler, in this order:
%%
%%     1. gcc     (MinGW-w64 on Windows, native on Linux/macOS/BSD)
%%     2. clang   (LLVM, all platforms)
%%     3. cc      (POSIX generic alias)
%%     4. cl      (MSVC, Windows only, used as a fallback)
%%
%% gcc and clang are preferred because they produce NIFs that load on
%% every OTP build without additional configuration. MSVC is used as
%% a fallback when neither is available, and it produces a DLL with
%% the same runtime behaviour.
%%
%% Detection rules:
%%   - The project root is inferred from the script's own path.
%%   - The erts include directory is obtained from the running VM
%%     (code:root_dir() / erlang:system_info(version)), never from an
%%     environment variable.
%%   - Linker flags are chosen from os:type() and the compiler family:
%%         gcc/clang, {win32, _}      -> -shared
%%         gcc/clang, {unix, darwin}  -> -bundle -undefined dynamic_lookup
%%         gcc/clang, {unix, _}       -> -shared
%%         cl,        {win32, _}      -> /LD /Fe:<target>
%%
%% Exit codes:
%%   0 - success (or skipped)
%%   1 - a required tool or header is missing
%%   2 - the compiler failed

-mode(compile).

-define(SRC_FILES, ["lingofuse_nif.c", "lf_loader.c"]).
-define(LIB_NAME, "lingofuse_nif").

main(_Args) ->
    case skip_requested() of
        true ->
            io:format("[build] LINGOFUSE_SKIP_NIF is set; "
                      "skipping the NIF build.~n"),
            halt(0);
        false ->
            build_nif()
    end.

skip_requested() ->
    case os:getenv("LINGOFUSE_SKIP_NIF") of
        false -> false;
        ""    -> false;
        _     -> true
    end.

%% =========================================================================
%% Top-level build flow
%% =========================================================================

build_nif() ->
    ScriptPath = filename:absname(escript:script_name()),
    CSrcDir    = filename:dirname(ScriptPath),
    RootDir    = filename:dirname(CSrcDir),
    PrivDir    = filename:join(RootDir, "priv"),

    info("project root", RootDir),
    info("c_src dir",    CSrcDir),

    ok = ensure_dir(PrivDir),

    %% --- erts include directory (from the running VM) -------------------
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

    %% --- C compiler ------------------------------------------------------
    {CC, CCName} = find_cc(),
    info("compiler", CC ++ " (" ++ CCName ++ ")"),

    %% --- output library --------------------------------------------------
    Ext    = lib_extension(),
    Target = filename:join(PrivDir, ?LIB_NAME ++ Ext),
    info("output", Target),

    %% --- dispatch on compiler family -------------------------------------
    case is_msvc(CCName) of
        true ->
            build_with_msvc(CC, CSrcDir, ErtsInclude, ErlRoot, ErtsVer,
                            PrivDir, Target);
        false ->
            build_with_gcc(CC, CSrcDir, ErtsInclude, PrivDir, Target)
    end,

    io:format("[build] OK~n"),
    halt(0).

%% =========================================================================
%% GCC / Clang build path
%% =========================================================================

build_with_gcc(CC, CSrcDir, ErtsInclude, PrivDir, Target) ->
    _ = PrivDir,
    Objects = [compile_one_gcc(CC, CSrcDir, ErtsInclude, Src)
               || Src <- ?SRC_FILES],
    link_gcc(CC, Objects, Target),
    [file:delete(filename:join(CSrcDir, O)) || O <- Objects],
    ok.

compile_one_gcc(CC, CSrcDir, ErtsInclude, Src) ->
    Obj     = filename:basename(Src, ".c") ++ ".o",
    SrcPath = filename:join(CSrcDir, Src),
    case filelib:is_file(SrcPath) of
        false ->
            err("source not found: ~s", [SrcPath]),
            halt(1);
        true -> ok
    end,
    Args = ["-O2", "-Wall", "-Wextra", "-std=c11", "-fPIC",
            "-I" ++ ErtsInclude,
            "-c", "-o", Obj, SrcPath],
    run(CC, Args),
    Obj.

link_gcc(CC, Objects, Target) ->
    Args = link_flags_gcc() ++ ["-o", Target | Objects],
    run(CC, Args).

link_flags_gcc() ->
    case os:type() of
        {win32, _}     -> ["-shared"];
        {unix, darwin} -> ["-bundle", "-undefined", "dynamic_lookup"];
        _              -> ["-shared"]
    end.

%% =========================================================================
%% MSVC build path
%% =========================================================================
%%
%% cl.exe performs compilation and linking in a single invocation when
%% the /LD flag is given. The resulting DLL is written to the path
%% specified by /Fe.
%%
%% If the OTP installation provides erts-<ver>/lib/erl_nif.lib, it is
%% appended to the command line so that the erl_nif_* and enif_*
%% symbols are resolved by the linker. On installations that do not
%% ship that import library, the build relies on the BEAM to resolve
%% the symbols at load time, which is the same behaviour as the
%% gcc/clang path.

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

    BaseArgs = ["/nologo", "/O2", "/W3", "/std:c11", "/MD",
                "/LD",
                "/I" ++ ErtsInclude,
                "/Fe" ++ Target],

    Args = case find_erl_nif_lib(ErlRoot, ErtsVer) of
               {ok, LibPath} ->
                   info("import lib", LibPath),
                   BaseArgs ++ SrcPaths ++ [LibPath];
               not_found ->
                   info("import lib", "(not found; relying on runtime resolution)"),
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

%% =========================================================================
%% Compiler detection
%% =========================================================================

find_cc() ->
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

%% =========================================================================
%% Helpers
%% =========================================================================

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
    Port = open_port(
             {spawn_executable, Exe},
             [{args, Args},
              exit_status,
              stderr_to_stdout,
              {line, 4096},
              hide,
              binary]),
    collect(Port).

collect(Port) ->
    receive
        {Port, {data, {eol, Line}}} ->
            io:format("         ~s~n", [Line]),
            collect(Port);
        {Port, {data, {noeol, Line}}} ->
            io:format("         ~s", [Line]),
            collect(Port);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            err("compiler exited with status ~p", [Status]),
            halt(2)
    end.

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