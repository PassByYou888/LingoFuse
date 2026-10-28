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