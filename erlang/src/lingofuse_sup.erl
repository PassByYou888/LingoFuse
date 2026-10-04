%% src/lingofuse_sup.erl
%%
%% Top-level supervisor for the LingoFuse Erlang binding.
%%
%% The supervisor has no children. It exists to give the OTP
%% application a valid supervisor tree, which simplifies release
%% management and makes it trivial to add supervised processes in a
%% future version (for example, a request-reply registry for the
%% synchronous Call protocol).
%%
%% Strategy: one_for_one with a small restart intensity. With no
%% children, the intensity values are effectively inert; they are
%% declared here as a matter of convention.

-module(lingofuse_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Flags = #{
        strategy  => one_for_one,
        intensity => 1,
        period    => 5
    },
    {ok, {Flags, []}}.