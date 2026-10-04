%% src/lingofuse_app.erl
%%
%% OTP application callback module for the LingoFuse binding.
%%
%% Responsibilities:
%%   * On start, verify that the NIF is loaded. Failure here is a
%%     hard error: the application cannot serve any request without
%%     the native library.
%%   * On stop, do nothing beyond the supervisor's own shutdown. The
%%     native library is not unloaded from BEAM at application stop;
%%     see the note in c_src/lf_loader.c for the rationale.
%%
%% The application does not spawn worker processes. All NIF calls are
%% synchronous and stateless. The empty supervisor exists only so
%% that the OTP application has a proper structure for release
%% management and for future extension.

-module(lingofuse_app).

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case lingofuse:ensure_loaded() of
        ok ->
            io:put_chars("[lingofuse] application starting\n"),
            lingofuse_sup:start_link();
        {error, lf_not_loaded} ->
            io:put_chars(standard_error,
                         "[lingofuse] application cannot start: "
                         "the NIF library is not loaded. "
                         "Place the LingoFuse shared library on the "
                         "search path and reinstall the binding.\n"),
            {error, {lingofuse, nif_not_loaded}}
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    io:put_chars("[lingofuse] application stopped\n"),
    ok.