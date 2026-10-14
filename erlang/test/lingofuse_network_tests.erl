%% test/lingofuse_network_tests.erl
%%
%% EUnit test suite for the LingoFuse Erlang binding: network layer.
%%
%% Scope
%% -----
%% This suite exercises the C ABI functions that participate in the
%% LingoFuse C4 service mesh:
%%
%%   * Framework lifecycle: reset_prepare, prepare_service,
%%     prepare_client, prepare_done, exit_main_thread, shutdown.
%%   * Call-mode dispatch through the single-process mesh loopback.
%%   * Notify-mode dispatch (one-way).
%%   * Sequenced notify dispatch, including FIFO order verification.
%%   * UID addressing: probe the caller's UID via whoami, then call
%%     it back with uid_call / uid_notify.
%%   * P2PName addressing: set this process's group name, wait for
%%     the mesh broadcast, then call the group back with
%%     p2pname_call / p2pname_notify.
%%   * Process-wide P2P registration: register_p2p_call[_sync] /
%%     register_p2p_notify / unregister_p2p.
%%   * Diagnostics: check_main_thread, check_app, check_api,
%%     check_uid, check_uid_api, check_p2pname, check_p2pname_api.
%%   * Client binding: bind_app.
%%
%% The notify forwarder
%% --------------------
%% EUnit's {setup, Setup, Cleanup, Instantiator} group runs Setup in
%% its own process and spawns each test in a fresh process. A notify
%% callback registered with the Setup process's pid would therefore
%% deliver its messages to a process that never reads them.
%%
%% The suite solves this by spawning a small forwarder process during
%% setup. The `log' notify API is registered with the forwarder, and
%% each notify test uses a Ref-tagged handshake to tell the forwarder
%% where to route the next message. Because the handshake is
%% synchronous, the test knows the forwarder has switched targets
%% before it issues the notify.
%%
%% UID wire format
%% ---------------
%% The 32-byte UID is NOT valid UTF-8 in general, so it cannot be
%% placed directly into a JSON value. The whoami handler therefore
%% encodes it as a 64-character lowercase hex string, and the caller
%% decodes it back with binary:decode_hex/1.
%%
%% Reply tolerance
%% ---------------
%% A sync callback can receive its reply after the C side has already
%% timed out or the PendingSync has already been reclaimed. In that
%% case reply/2 returns {error, unknown_ref}, which is a legal
%% outcome. The test_server therefore does NOT treat the return value
%% of reply/2 as a fatal error; it ignores whatever reply/2 returns.
%%
%% Why Wait_Connection_ReadyOk is set to False
%% -------------------------------------------
%% LF_PrepareDone's default behavior blocks for up to
%% max(Wait_Connection_Timeout, 5000) + 1000 = 31000 milliseconds,
%% waiting for every prepared client to become fully ready. Every
%% group therefore runs in deployment mode: Wait_Connection_ReadyOk
%% is set to False, LF_PrepareDone returns as soon as the event loop
%% is up, and every test that depends on an App being reachable
%% first waits for check_app to observe it.
%%
%% Local-first routing
%% -------------------
%% The C4 mesh checks for a local instance of the target App before
%% attempting a network hop. Since this suite registers and calls the
%% App in the same BEAM process, all "remote" calls in this suite
%% execute on the local mesh loopback.

-module(lingofuse_network_tests).

-include_lib("eunit/include/eunit.hrl").

%% EUnit per-test timeout, in seconds.
-define(TEST_TIMEOUT_S, 30).

%% Convenience macro that wraps a Fun in an EUnit timeout tuple.
-define(T(Seconds, Fun), {timeout, Seconds, Fun}).

%% =========================================================================
%% Test descriptors
%% =========================================================================

framework_lifecycle_test_() ->
    [
        {"prepare_done returns 1 on the first call",
         ?T(?TEST_TIMEOUT_S, fun t_prepare_done_first/0)},
        {"check_main_thread reports the framework is up",
         ?T(?TEST_TIMEOUT_S, fun t_main_thread_active/0)},
        {"prepare_service returns a non-negative tag",
         ?T(?TEST_TIMEOUT_S, fun t_prepare_service_tag/0)},
        {"prepare_client returns a non-negative tag",
         ?T(?TEST_TIMEOUT_S, fun t_prepare_client_tag/0)},
        {"duplicate prepare_service on the same endpoint is rejected",
         ?T(?TEST_TIMEOUT_S, fun t_prepare_service_dup/0)},
        {"reset_prepare then restart succeeds",
         ?T(?TEST_TIMEOUT_S, fun t_reset_prepare_restart/0)},
        {"exit_main_thread is idempotent",
         ?T(?TEST_TIMEOUT_S, fun t_exit_main_thread_idempotent/0)},
        {"shutdown is idempotent",
         ?T(?TEST_TIMEOUT_S, fun t_shutdown_idempotent/0)}
    ].

local_dispatch_test_() ->
    [
        {"local_call dispatches {lf_call, Api, Payload}",
         ?T(?TEST_TIMEOUT_S, fun t_local_call_dispatch/0)},
        {"local_call on a missing API returns a size-0 handle",
         ?T(?TEST_TIMEOUT_S, fun t_local_call_missing/0)},
        {"local_notify dispatches {lf_notify, Api, Payload}",
         ?T(?TEST_TIMEOUT_S, fun t_local_notify_dispatch/0)},
        {"local_call rejects bad arguments",
         ?T(?TEST_TIMEOUT_S, fun t_local_call_badarg/0)}
    ].

remote_dispatch_test_() ->
    [
        {"call to a local app dispatches the {lf_call, ...} message",
         ?T(?TEST_TIMEOUT_S, fun t_call_loopback/0)},
        {"call to an unknown app returns an empty handle or error",
         ?T(?TEST_TIMEOUT_S, fun t_call_unknown/0)},
        {"notify to a local app dispatches the {lf_notify, ...} message",
         ?T(?TEST_TIMEOUT_S, fun t_notify_loopback/0)},
        {"notify to an unknown app returns ok",
         ?T(?TEST_TIMEOUT_S, fun t_notify_unknown/0)},
        {"sequenced_notify dispatches the {lf_notify, ...} message",
         ?T(?TEST_TIMEOUT_S, fun t_sequenced_notify_dispatch/0)},
        {"sequenced_notify preserves FIFO order",
         ?T(?TEST_TIMEOUT_S, fun t_sequenced_notify_fifo/0)}
    ].

diagnostics_test_() ->
    [
        {"check_app becomes true for a registered app",
         ?T(?TEST_TIMEOUT_S, fun t_check_app/0)},
        {"check_app returns false for an absent app",
         ?T(?TEST_TIMEOUT_S, fun t_check_app_absent/0)},
        {"check_api becomes true for a registered api",
         ?T(?TEST_TIMEOUT_S, fun t_check_api/0)},
        {"check_api returns false for an absent api",
         ?T(?TEST_TIMEOUT_S, fun t_check_api_absent/0)},
        {"get_status_count returns a non-negative integer",
         ?T(?TEST_TIMEOUT_S, fun t_get_status_count/0)},
        {"set_option is accepted during network activity",
         ?T(?TEST_TIMEOUT_S, fun t_set_option_during_network/0)}
    ].

bind_test_() ->
    [
        {"bind_app returns 0 when no free client exists",
         ?T(?TEST_TIMEOUT_S, fun t_bind_app_no_free_client/0)},
        {"bind_app attaches an app to a prepared nil client",
         ?T(?TEST_TIMEOUT_S, fun t_bind_app_success/0)}
    ].

uid_addressing_test_() ->
    {setup,
     fun setup_uid_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) ->
         [
             {"whoami returns the caller's 32-byte UID and P2P name",
              ?T(?TEST_TIMEOUT_S, fun() -> t_whoami_shape(Ctx) end)},
             {"uid_call round trips to a known UID",
              ?T(?TEST_TIMEOUT_S, fun() -> t_uid_call(Ctx) end)},
             {"uid_notify reaches the target without a reply",
              ?T(?TEST_TIMEOUT_S, fun() -> t_uid_notify(Ctx) end)},
             {"check_uid and check_uid_api agree for a live UID",
              ?T(?TEST_TIMEOUT_S, fun() -> t_check_uid(Ctx) end)}
         ]
     end}.

p2pname_addressing_test_() ->
    {setup,
     fun setup_p2pname_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) ->
         [
             {"p2pname_call round trips to the group",
              ?T(?TEST_TIMEOUT_S, fun() -> t_p2pname_call(Ctx) end)},
             {"p2pname_notify reaches the group without a reply",
              ?T(?TEST_TIMEOUT_S, fun() -> t_p2pname_notify(Ctx) end)},
             {"check_p2pname and check_p2pname_api agree",
              ?T(?TEST_TIMEOUT_S, fun() -> t_check_p2pname(Ctx) end)}
         ]
     end}.

p2p_registration_test_() ->
    {setup,
     fun setup_p2pname_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) ->
         [
             {"register_p2p_call then unregister_p2p is idempotent",
              ?T(?TEST_TIMEOUT_S,
                 fun() -> t_p2p_register_call(Ctx) end)},
             {"register_p2p_notify then unregister_p2p is idempotent",
              ?T(?TEST_TIMEOUT_S,
                 fun() -> t_p2p_register_notify(Ctx) end)},
             {"register_p2p_call_sync then unregister_p2p is idempotent",
              ?T(?TEST_TIMEOUT_S,
                 fun() -> t_p2p_register_call_sync(Ctx) end)}
         ]
     end}.

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
      io_lib:format("ipc:lf_net_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

unique_app_name(Prefix) ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("NetTestApp_~s_~s_~p",
                    [Prefix, os:getpid(), N])).

unique_p2p_name() ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("eunit_p2p_~s_~p", [os:getpid(), N])).

flush_lf_messages() ->
    receive
        {lf_call, _, _, _}      -> flush_lf_messages();
        {lf_call, _, _}         -> flush_lf_messages();
        {lf_notify, _, _}       -> flush_lf_messages();
        {lf_notify, _}          -> flush_lf_messages();
        {lf_p2p_call, _, _}     -> flush_lf_messages();
        {lf_p2p_call, _, _, _}  -> flush_lf_messages();
        {lf_p2p_notify, _, _}   -> flush_lf_messages();
        {lf_p2p_notify, _}      -> flush_lf_messages();
        {lf_async_result, _, _} -> flush_lf_messages();
        {lf_connect, _}         -> flush_lf_messages();
        {lf_disconnect, _}      -> flush_lf_messages()
    after 0 -> ok
    end.

try_silent(Fun) ->
    try Fun() catch _:_ -> ok end.

register_test_apis(A) ->
    ok = lingofuse:register_call  (A, <<"add">>,    <<"eunit call">>,   self()),
    ok = lingofuse:register_notify(A, <<"log">>,    <<"eunit notify">>, self()),
    ok = lingofuse:register_notify(A, <<"stream">>, <<"eunit stream">>, self()),
    ok.

with_framework(Fun) ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            flush_lf_messages(),
            ?assertEqual(
               ok,
               lingofuse:set_option(
                 <<"Wait_Connection_ReadyOk">>, <<"False">>)),
            ?assertEqual(
               ok,
               lingofuse:set_option(
                 <<"Overlap_Connection">>, <<"True">>)),
            ?assertEqual(
               ok,
               lingofuse:set_option(<<"Quiet">>, <<"True">>)),
            Endpoint = unique_endpoint(<<"t">>),
            AppName  = unique_app_name(<<"t">>),
            {ok, A} = lingofuse:create_app(AppName, <<"network test">>),
            try
                ok = register_test_apis(A),
                ok = lingofuse:reset_prepare(),
                {ok, ServTag} = lingofuse:prepare_service(Endpoint, Endpoint),
                ?assert(ServTag >= 0),
                {ok, CliTag} = lingofuse:prepare_client(Endpoint, A),
                ?assert(CliTag >= 0),
                {ok, 1} = lingofuse:prepare_done(),
                true = wait_until(
                         fun() ->
                             case lingofuse:check_app(AppName) of
                                 {ok, true} -> true;
                                 _          -> false
                             end
                         end, 5000),
                Fun(A, Endpoint, AppName)
            after
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

wait_until_loop(Fun, TimeoutMs, _Interval) when TimeoutMs =< 0 ->
    Fun();
wait_until_loop(Fun, TimeoutMs, Interval) ->
    case Fun() of
        true -> true;
        false ->
            timer:sleep(Interval),
            wait_until_loop(Fun, TimeoutMs - Interval, Interval)
    end.

%% =========================================================================
%% Notify forwarder
%% =========================================================================
%%
%% A tiny relay process that the notify tests can point at themselves
%% for the duration of one test. The forwarder starts with no target
%% and drops every notify it receives until a target is set.
%%
%% The handshake is Ref-tagged so that a test can be certain the
%% forwarder has switched targets before it issues the notify.

notify_forwarder() ->
    notify_forwarder_loop(undefined).

notify_forwarder_loop(Current) ->
    receive
        {set_listener, From, Ref} ->
            From ! {listener_set, Ref},
            notify_forwarder_loop(From);
        {lf_notify, _, _} = Msg ->
            case Current of
                undefined -> ok;
                Pid when is_pid(Pid) -> Pid ! Msg
            end,
            notify_forwarder_loop(Current);
        {lf_p2p_notify, _, _} = Msg ->
            case Current of
                undefined -> ok;
                Pid when is_pid(Pid) -> Pid ! Msg
            end,
            notify_forwarder_loop(Current);
        _Other ->
            notify_forwarder_loop(Current)
    end.

%% Point the forwarder at the calling process, and wait for the
%% handshake to complete.
set_forwarder_target(ForwarderPid) ->
    Ref = make_ref(),
    ForwarderPid ! {set_listener, self(), Ref},
    receive
        {listener_set, Ref} -> ok
    after 1000 ->
        error({forwarder_handshake_timeout, ForwarderPid})
    end.

%% =========================================================================
%% Sync test server used by the UID and P2PName groups
%% =========================================================================

test_server() ->
    receive
        {lf_call, Ref, <<"echo">>, Payload} ->
            _ = lingofuse:reply(Ref, Payload),
            test_server();
        {lf_call, Ref, <<"whoami">>, _, Identity} ->
            UID  = maps:get(uid, Identity),
            Name = maps:get(p2p_name, Identity),
            Reply = lingofuse_json:dumps(#{
                <<"uid_hex">>  => binary:encode_hex(UID),
                <<"p2p_name">> => Name
            }),
            _ = lingofuse:reply(Ref, Reply),
            test_server();
        {lf_call, Ref, <<"ping">>, _Payload} ->
            Reply = lingofuse_json:dumps(<<"pong">>),
            _ = lingofuse:reply(Ref, Reply),
            test_server();
        _Other ->
            test_server()
    end.

%% =========================================================================
%% Framework setup / cleanup shared by the UID and P2PName groups
%% =========================================================================

setup_uid_framework() ->
    common_framework_setup(<<"uid">>, undefined).

setup_p2pname_framework() ->
    Group = unique_p2p_name(),
    common_framework_setup(<<"p2p">>, Group).

common_framework_setup(Tag, P2PNameOpt) ->
    case ensure_native_or_skip() of
        skip -> skip;
        ok ->
            flush_lf_messages(),

            ok = lingofuse:set_option(<<"Wait_Connection_ReadyOk">>,
                                      <<"False">>),
            ok = lingofuse:set_option(<<"Overlap_Connection">>,
                                      <<"True">>),
            ok = lingofuse:set_option(<<"Quiet">>, <<"True">>),

            case P2PNameOpt of
                undefined -> ok;
                Group     -> ok = lingofuse:set_opt_p2p_name(Group)
            end,

            Endpoint = unique_endpoint(Tag),
            AppName  = unique_app_name(Tag),
            {ok, A}  = lingofuse:create_app(AppName, <<"net group test">>),

            Server    = spawn(fun test_server/0),
            Forwarder = spawn(fun notify_forwarder/0),

            ok = lingofuse:register_call_sync(
                   A, <<"echo">>,   <<"echo">>,   Server),
            ok = lingofuse:register_call_sync(
                   A, <<"whoami">>, <<"whoami">>, Server,
                   #{with_identity => true}),
            ok = lingofuse:register_call_sync(
                   A, <<"ping">>,   <<"ping">>,   Server),

            %% The notify API is registered with the forwarder, not
            %% with the setup process, so that each test can take
            %% ownership of the delivery stream for its own duration.
            ok = lingofuse:register_notify(
                   A, <<"log">>, <<"eunit log">>, Forwarder),

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

            UID = probe_uid(AppName),

            case P2PNameOpt of
                undefined -> ok;
                _         -> timer:sleep(3500)
            end,

            #{app       => A,
              app_name  => AppName,
              server    => Server,
              forwarder => Forwarder,
              uid       => UID,
              group     => P2PNameOpt}
    end.

cleanup_framework(skip) -> ok;
cleanup_framework(Ctx) when is_map(Ctx) ->
    Server    = maps:get(server, Ctx, undefined),
    Forwarder = maps:get(forwarder, Ctx, undefined),
    App       = maps:get(app, Ctx, undefined),
    case Server of
        Pid when is_pid(Pid) -> try_silent(fun() -> exit(Pid, kill) end);
        _                    -> ok
    end,
    case Forwarder of
        Pid2 when is_pid(Pid2) -> try_silent(fun() -> exit(Pid2, kill) end);
        _                      -> ok
    end,
    try_silent(fun() -> lingofuse:exit_main_thread() end),
    case App of
        A when is_reference(A) -> try_silent(fun() -> lingofuse:free_app(A) end);
        _                      -> ok
    end,
    try_silent(fun() -> lingofuse:shutdown() end),
    timer:sleep(100),
    flush_lf_messages(),
    ok;
cleanup_framework(_) -> ok.

probe_uid(AppName) ->
    {ok, Req} = lingofuse:create_data(<<"whoami">>),
    try
        ok = lingofuse_json:write_json(Req, #{}),
        {ok, Res} = lingofuse:call(AppName, Req, 5000),
        try
            ok = lingofuse:set_pos(Res, 0),
            Reply = lingofuse_json:read_json(Res),
            ?assert(is_map(Reply)),
            UIDHex = maps:get(<<"uid_hex">>, Reply),
            ?assert(is_binary(UIDHex)),
            ?assertEqual(64, byte_size(UIDHex)),
            UID = binary:decode_hex(UIDHex),
            ?assertEqual(32, byte_size(UID)),
            UID
        after
            lingofuse:free_data(Res)
        end
    after
        lingofuse:free_data(Req)
    end.

%% =========================================================================
%% Framework lifecycle tests
%% =========================================================================

t_prepare_done_first() ->
    with_framework(fun(_A, _E, _N) ->
        ?assertEqual({ok, true}, lingofuse:check_main_thread())
    end).

t_main_thread_active() ->
    with_framework(fun(_A, _E, _N) ->
        ?assertEqual({ok, true}, lingofuse:check_main_thread())
    end).

t_prepare_service_tag() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Endpoint = unique_endpoint(<<"svc">>),
            try
                ok = lingofuse:reset_prepare(),
                {ok, Tag} = lingofuse:prepare_service(Endpoint, Endpoint),
                ?assert(Tag >= 0)
            after
                try_silent(fun() -> lingofuse:reset_prepare() end),
                try_silent(fun() -> lingofuse:shutdown() end)
            end
    end.

t_prepare_client_tag() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Endpoint = unique_endpoint(<<"cli">>),
            try
                ok = lingofuse:reset_prepare(),
                {ok, Tag} = lingofuse:prepare_client(Endpoint, undefined),
                ?assert(Tag >= 0)
            after
                try_silent(fun() -> lingofuse:reset_prepare() end),
                try_silent(fun() -> lingofuse:shutdown() end)
            end
    end.

t_prepare_service_dup() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            Endpoint = unique_endpoint(<<"dup">>),
            try
                ok = lingofuse:reset_prepare(),
                {ok, T1} = lingofuse:prepare_service(Endpoint, Endpoint),
                ?assert(T1 >= 0),
                {ok, T2} = lingofuse:prepare_service(Endpoint, Endpoint),
                ?assertEqual(-1, T2)
            after
                try_silent(fun() -> lingofuse:reset_prepare() end),
                try_silent(fun() -> lingofuse:shutdown() end)
            end
    end.

t_reset_prepare_restart() ->
    ok = with_framework(fun(_A, _E, _N) -> ok end),
    ok = with_framework(fun(_A, _E, _N) -> ok end),
    ok.

t_exit_main_thread_idempotent() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertEqual(ok, lingofuse:exit_main_thread()),
            ?assertEqual(ok, lingofuse:exit_main_thread())
    end.

t_shutdown_idempotent() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertEqual(ok, lingofuse:shutdown()),
            ?assertEqual(ok, lingofuse:shutdown())
    end.

%% =========================================================================
%% Local dispatch tests
%% =========================================================================

t_local_call_dispatch() ->
    with_framework(fun(A, _E, _N) ->
        flush_lf_messages(),
        {ok, P} = lingofuse:create_data(<<"add">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"hello">>),
            {ok, _R} = lingofuse:local_call(A, P),
            receive
                {lf_call, Api, Payload} ->
                    ?assertEqual(<<"add">>, Api),
                    ?assertEqual(<<"hello">>, Payload)
            after 2000 ->
                ?assert(false)
            end
        after
            lingofuse:free_data(P)
        end
    end).

t_local_call_missing() ->
    with_framework(fun(A, _E, _N) ->
        {ok, P} = lingofuse:create_data(<<"__missing__">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"x">>),
            {ok, R} = lingofuse:local_call(A, P),
            try
                {ok, Size} = lingofuse:get_size(R),
                ?assertEqual(0, Size)
            after
                lingofuse:free_data(R)
            end
        after
            lingofuse:free_data(P)
        end
    end).

t_local_notify_dispatch() ->
    with_framework(fun(A, _E, _N) ->
        flush_lf_messages(),
        {ok, P} = lingofuse:create_data(<<"log">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"event">>),
            ok = lingofuse:local_notify(A, P),
            receive
                {lf_notify, Api, Payload} ->
                    ?assertEqual(<<"log">>, Api),
                    ?assertEqual(<<"event">>, Payload)
            after 2000 ->
                ?assert(false)
            end
        after
            lingofuse:free_data(P)
        end
    end).

t_local_call_badarg() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            ?assertError(badarg,
                         lingofuse:local_call(not_an_app, not_a_data))
    end.

%% =========================================================================
%% Remote dispatch tests (single-process loopback)
%% =========================================================================

t_call_loopback() ->
    with_framework(fun(_A, _E, AppName) ->
        flush_lf_messages(),
        {ok, P} = lingofuse:create_data(<<"add">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"payload">>),
            {ok, R} = lingofuse:call(AppName, P, 3000),
            try
                receive
                    {lf_call, Api, Payload} ->
                        ?assertEqual(<<"add">>, Api),
                        ?assertEqual(<<"payload">>, Payload)
                after 3000 ->
                    ?assert(false)
                end
            after
                lingofuse:free_data(R)
            end
        after
            lingofuse:free_data(P)
        end
    end).

t_call_unknown() ->
    with_framework(fun(_A, _E, _N) ->
        {ok, P} = lingofuse:create_data(<<"any">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"x">>),
            Result = lingofuse:call(<<"__definitely_absent__">>, P, 500),
            case Result of
                {ok, R} ->
                    {ok, Size} = lingofuse:get_size(R),
                    ?assertEqual(0, Size),
                    lingofuse:free_data(R);
                {error, Reason} ->
                    ?assert(is_atom(Reason))
            end
        after
            lingofuse:free_data(P)
        end
    end).

t_notify_loopback() ->
    with_framework(fun(_A, _E, AppName) ->
        flush_lf_messages(),
        {ok, P} = lingofuse:create_data(<<"log">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"notify-payload">>),
            ok = lingofuse:notify(AppName, P),
            receive
                {lf_notify, Api, Payload} ->
                    ?assertEqual(<<"log">>, Api),
                    ?assertEqual(<<"notify-payload">>, Payload)
            after 3000 ->
                ?assert(false)
            end
        after
            lingofuse:free_data(P)
        end
    end).

t_notify_unknown() ->
    with_framework(fun(_A, _E, _N) ->
        {ok, P} = lingofuse:create_data(<<"log">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"x">>),
            ?assertEqual(ok,
                         lingofuse:notify(<<"__absent__">>, P))
        after
            lingofuse:free_data(P)
        end
    end).

t_sequenced_notify_dispatch() ->
    with_framework(fun(_A, _E, AppName) ->
        flush_lf_messages(),
        {ok, P} = lingofuse:create_data(<<"stream">>),
        try
            {ok, _} = lingofuse:write_buffer(P, <<"seq-payload">>),
            ok = lingofuse:sequenced_notify(AppName, P),
            receive
                {lf_notify, Api, Payload} ->
                    ?assertEqual(<<"stream">>, Api),
                    ?assertEqual(<<"seq-payload">>, Payload)
            after 3000 ->
                ?assert(false)
            end
        after
            lingofuse:free_data(P)
        end
    end).

t_sequenced_notify_fifo() ->
    with_framework(fun(_A, _E, AppName) ->
        flush_lf_messages(),
        Payloads = [integer_to_binary(N) || N <- lists:seq(1, 8)],
        lists:foreach(
          fun(Payload) ->
              {ok, P} = lingofuse:create_data(<<"stream">>),
              try
                  {ok, _} = lingofuse:write_buffer(P, Payload),
                  ok = lingofuse:sequenced_notify(AppName, P)
              after
                  lingofuse:free_data(P)
              end
          end, Payloads),
        Received = [receive
                        {lf_notify, <<"stream">>, B} -> B
                    after 5000 ->
                        ?assert(false)
                    end || _ <- Payloads],
        ?assertEqual(Payloads, Received)
    end).

%% =========================================================================
%% Diagnostics tests
%% =========================================================================

t_check_app() ->
    with_framework(fun(_A, _E, AppName) ->
        Result = wait_until(
                   fun() ->
                       case lingofuse:check_app(AppName) of
                           {ok, true} -> true;
                           _ -> false
                       end
                   end, 3000),
        ?assert(Result)
    end).

t_check_app_absent() ->
    with_framework(fun(_A, _E, _N) ->
        {ok, Result} = lingofuse:check_app(<<"__definitely_absent__">>),
        ?assertEqual(false, Result)
    end).

t_check_api() ->
    with_framework(fun(_A, _E, AppName) ->
        Result = wait_until(
                   fun() ->
                       case lingofuse:check_api(AppName, <<"add">>) of
                           {ok, true} -> true;
                           _ -> false
                       end
                   end, 3000),
        ?assert(Result)
    end).

t_check_api_absent() ->
    with_framework(fun(_A, _E, AppName) ->
        {ok, Result} = lingofuse:check_api(AppName, <<"__missing_api__">>),
        ?assertEqual(false, Result)
    end).

t_get_status_count() ->
    with_framework(fun(_A, _E, _N) ->
        {ok, N} = lingofuse:get_status_count(),
        ?assert(is_integer(N)),
        ?assert(N >= 0)
    end).

t_set_option_during_network() ->
    with_framework(fun(_A, _E, _N) ->
        ?assertEqual(ok, lingofuse:set_option(<<"Quiet">>, <<"True">>)),
        ?assertEqual(ok, lingofuse:set_option(<<"Quiet">>, <<"False">>))
    end).

%% =========================================================================
%% Client binding tests
%% =========================================================================

t_bind_app_no_free_client() ->
    with_framework(fun(A, _E, _N) ->
        {ok, N} = lingofuse:bind_app(A),
        ?assertEqual(0, N)
    end).

t_bind_app_success() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            flush_lf_messages(),
            ?assertEqual(
               ok,
               lingofuse:set_option(
                 <<"Wait_Connection_ReadyOk">>, <<"False">>)),
            Endpoint = unique_endpoint(<<"bind">>),
            AppName  = unique_app_name(<<"bind">>),
            {ok, A} = lingofuse:create_app(AppName, <<"bind test">>),
            ok = lingofuse:register_call(A, <<"ping">>, <<"d">>, self()),
            try
                ok = lingofuse:reset_prepare(),
                {ok, _} = lingofuse:prepare_service(Endpoint, Endpoint),
                {ok, _} = lingofuse:prepare_client(Endpoint, undefined),
                {ok, 1} = lingofuse:prepare_done(),
                timer:sleep(500),
                {ok, Bound} = lingofuse:bind_app(A),
                ?assertEqual(1, Bound)
            after
                try_silent(fun() -> lingofuse:exit_main_thread() end),
                try_silent(fun() -> lingofuse:free_app(A) end),
                try_silent(fun() -> lingofuse:shutdown() end),
                timer:sleep(100),
                flush_lf_messages()
            end,
            ok
    end.

%% =========================================================================
%% UID addressing group tests
%% =========================================================================

t_whoami_shape(Ctx) ->
    AppName = maps:get(app_name, Ctx),
    {ok, Req} = lingofuse:create_data(<<"whoami">>),
    try
        ok = lingofuse_json:write_json(Req, #{}),
        {ok, Res} = lingofuse:call(AppName, Req, 5000),
        try
            ok = lingofuse:set_pos(Res, 0),
            Reply = lingofuse_json:read_json(Res),
            ?assert(is_map(Reply)),

            UIDHex = maps:get(<<"uid_hex">>, Reply),
            ?assert(is_binary(UIDHex)),
            ?assertEqual(64, byte_size(UIDHex)),

            UID = binary:decode_hex(UIDHex),
            ?assertEqual(32, byte_size(UID)),

            ?assert(maps:is_key(<<"p2p_name">>, Reply))
        after
            lingofuse:free_data(Res)
        end
    after
        lingofuse:free_data(Req)
    end.

t_uid_call(Ctx) ->
    UID = maps:get(uid, Ctx),
    {ok, Req} = lingofuse:create_data(<<"ping">>),
    try
        ok = lingofuse_json:write_json(Req, #{}),
        {ok, Res} = lingofuse:uid_call(UID, Req, 5000),
        try
            ok = lingofuse:set_pos(Res, 0),
            Reply = lingofuse_json:read_json(Res),
            ?assertEqual(<<"pong">>, Reply)
        after
            lingofuse:free_data(Res)
        end
    after
        lingofuse:free_data(Req)
    end.

%% uid_notify sends a one-way notification by UID. The `log' Notify
%% API is registered with the forwarder; the test points the forwarder
%% at itself before issuing the notify.
t_uid_notify(Ctx) ->
    UID       = maps:get(uid, Ctx),
    Forwarder = maps:get(forwarder, Ctx),
    flush_lf_messages(),
    ok = set_forwarder_target(Forwarder),
    {ok, Req} = lingofuse:create_data(<<"log">>),
    try
        ok = lingofuse_json:write_json(
               Req, #{<<"event">> => <<"uid_notify">>}),
        ?assertEqual(ok, lingofuse:uid_notify(UID, Req)),
        receive
            {lf_notify, <<"log">>, _Payload} -> ok
        after 3000 ->
            ?assert(false)
        end
    after
        lingofuse:free_data(Req)
    end.

t_check_uid(Ctx) ->
    UID = maps:get(uid, Ctx),
    Result1 = wait_until(
                fun() ->
                    case lingofuse:check_uid(UID) of
                        {ok, true} -> true;
                        _          -> false
                    end
                end, 5000),
    ?assert(Result1),
    Result2 = wait_until(
                fun() ->
                    case lingofuse:check_uid_api(UID, <<"ping">>) of
                        {ok, true} -> true;
                        _          -> false
                    end
                end, 5000),
    ?assert(Result2).

%% =========================================================================
%% P2PName addressing group tests
%% =========================================================================

t_p2pname_call(Ctx) ->
    Group = maps:get(group, Ctx),
    {ok, Req} = lingofuse:create_data(<<"ping">>),
    try
        ok = lingofuse_json:write_json(Req, #{}),
        {ok, Res} = lingofuse:p2pname_call(Group, Req, 5000),
        try
            ok = lingofuse:set_pos(Res, 0),
            Reply = lingofuse_json:read_json(Res),
            ?assertEqual(<<"pong">>, Reply)
        after
            lingofuse:free_data(Res)
        end
    after
        lingofuse:free_data(Req)
    end.

t_p2pname_notify(Ctx) ->
    Group     = maps:get(group, Ctx),
    Forwarder = maps:get(forwarder, Ctx),
    flush_lf_messages(),
    ok = set_forwarder_target(Forwarder),
    {ok, Req} = lingofuse:create_data(<<"log">>),
    try
        ok = lingofuse_json:write_json(
               Req, #{<<"event">> => <<"p2pname_notify">>}),
        ?assertEqual(ok, lingofuse:p2pname_notify(Group, Req)),
        receive
            {lf_notify, <<"log">>, _Payload} -> ok
        after 3000 ->
            ?assert(false)
        end
    after
        lingofuse:free_data(Req)
    end.

t_check_p2pname(Ctx) ->
    Group = maps:get(group, Ctx),
    Result1 = wait_until(
                fun() ->
                    case lingofuse:check_p2pname(Group) of
                        {ok, true} -> true;
                        _          -> false
                    end
                end, 5000),
    ?assert(Result1),
    Result2 = wait_until(
                fun() ->
                    case lingofuse:check_p2pname_api(Group, <<"ping">>) of
                        {ok, true} -> true;
                        _          -> false
                    end
                end, 5000),
    ?assert(Result2).

%% =========================================================================
%% Process-wide P2P registration group tests
%% =========================================================================

t_p2p_register_call(Ctx) ->
    _ = Ctx,
    Api = <<"eunit_p2p_call_api">>,
    ok = lingofuse:register_p2p_call(Api, <<"eunit p2p call">>, self()),
    ?assertEqual({ok, true},  lingofuse:unregister_p2p(Api)),
    ?assertEqual({ok, false}, lingofuse:unregister_p2p(Api)).

t_p2p_register_notify(Ctx) ->
    _ = Ctx,
    Api = <<"eunit_p2p_notify_api">>,
    ok = lingofuse:register_p2p_notify(Api, <<"eunit p2p notify">>, self()),
    ?assertEqual({ok, true},  lingofuse:unregister_p2p(Api)),
    ?assertEqual({ok, false}, lingofuse:unregister_p2p(Api)).

t_p2p_register_call_sync(Ctx) ->
    _ = Ctx,
    Api = <<"eunit_p2p_call_sync_api">>,
    ok = lingofuse:register_p2p_call_sync(Api, <<"eunit p2p call sync">>,
                                          self()),
    ?assertEqual({ok, true},  lingofuse:unregister_p2p(Api)),
    ?assertEqual({ok, false}, lingofuse:unregister_p2p(Api)).