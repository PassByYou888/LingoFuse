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
%%   * Diagnostics: check_main_thread, check_app, check_api.
%%   * Client binding: bind_app.
%%
%% {!!!!!  CALL DISPATCH BEHAVIOUR  !!!!!}
%% In this batch of the binding, a Call callback delivers the
%% {lf_call, Api, Payload} message to the registered Erlang process.
%% The synchronous reply variant (register_call_sync/4 + reply/2)
%% is covered by lingofuse_sync_tests.
%%
%% {!!!!!  WHY Wait_Connection_ReadyOk IS SET TO False  !!!!!}
%% LF_PrepareDone's default behavior blocks for up to
%% max(Wait_Connection_Timeout, 5000) + 1000 = 31000 milliseconds,
%% waiting for every prepared client to become fully ready. That
%% exceeds the EUnit default per-test timeout of 5 seconds, and a
%% timeout here also cancels the remaining tests in the same
%% generator.
%%
%% This suite therefore runs in deployment mode: Wait_Connection_ReadyOk
%% is set to False, LF_PrepareDone returns as soon as the event loop
%% is up, and every test that depends on the App being reachable
%% first waits for check_app/1 to observe it.
%%
%% {!!!!!  LOCAL-FIRST ROUTING  !!!!!}
%% The C4 mesh checks for a local instance of the target App before
%% attempting a network hop. Since this test suite registers and
%% calls the App in the same BEAM process, all "remote" calls in
%% this suite execute on the local mesh loopback.
%%
%% {!!!!!  SKIP BEHAVIOUR  !!!!!}
%% Every test calls ensure_native_or_skip/0 first. When the LingoFuse
%% shared library is not available, the test prints a SKIP message
%% and returns ok. Set LINGOFUSE_REQUIRE_NATIVE=1 to turn a missing
%% library into a hard failure (for CI).
%%
%% Run with:
%%     rebar3 eunit
%% Or, to force a hard failure when the native library is missing:
%%     LINGOFUSE_REQUIRE_NATIVE=1 rebar3 eunit

-module(lingofuse_network_tests).

-include_lib("eunit/include/eunit.hrl").

%% EUnit per-test timeout, in seconds. Chosen to be comfortably
%% larger than the worst-case mesh-ready latency (a few seconds) while
%% remaining small enough that a genuinely deadlocked test does not
%% stall CI forever.
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

%% Build an endpoint name that is unique across processes and
%% across runs within the same process.
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

%% Drain any residual callback message from the mailbox so the next
%% test starts with a clean slate.
flush_lf_messages() ->
    receive
        {lf_call, _, _}    -> flush_lf_messages();
        {lf_notify, _, _}  -> flush_lf_messages();
        {lf_connect, _}    -> flush_lf_messages();
        {lf_disconnect, _} -> flush_lf_messages()
    after 0 -> ok
    end.

%% Register the three test APIs on App A. All callbacks deliver to
%% self(), which is the test process.
register_test_apis(A) ->
    ok = lingofuse:register_call  (A, <<"add">>,    <<"eunit call">>,   self()),
    ok = lingofuse:register_notify(A, <<"log">>,    <<"eunit notify">>, self()),
    ok = lingofuse:register_notify(A, <<"stream">>, <<"eunit stream">>, self()),
    ok.

%% Run Fun() and ignore any exception. Convenience for teardown.
try_silent(Fun) ->
    try Fun() catch _:_ -> ok end.

%% Start a fresh framework session, run Fun(A, Endpoint, AppName),
%% then tear everything down in an `after` block.
%%
%% {!!!!!  DEPLOYMENT MODE  !!!!!}
%% Wait_Connection_ReadyOk is set to False before the framework is
%% started, so LF_PrepareDone returns as soon as the event loop is
%% running instead of blocking for up to 31 seconds waiting for
%% every client to become fully ready. After prepare_done returns,
%% with_framework waits until check_app/1 observes the registered
%% App on the mesh, which absorbs the ~3 second broadcast delay.
with_framework(Fun) ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            flush_lf_messages(),
            %% Deployment mode: do not block LF_PrepareDone.
            ?assertEqual(
               ok,
               lingofuse:set_option(
                 <<"Wait_Connection_ReadyOk">>, <<"False">>)),
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
                %% Wait until the App is visible on the mesh. In
                %% deployment mode prepare_done returns before the
                %% broadcast has necessarily completed.
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
                %% Give the mesh a moment to release sockets and
                %% worker threads before the next test begins.
                timer:sleep(100),
                flush_lf_messages()
            end,
            ok
    end.

%% Poll a predicate up to TimeoutMs, every 50 ms, and return the
%% final result. Used to absorb the ~3 second broadcast delay of the
%% LingoFuse mesh after a fresh registration.
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
%% Framework lifecycle tests
%% =========================================================================

t_prepare_done_first() ->
    with_framework(fun(_A, _E, _N) ->
        %% The helper already asserted prepare_done returned 1.
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
                %% A second prepare_service with the same endpoint
                %% must be rejected with -1. This is documented
                %% behavior of the C4 layer.
                {ok, T2} = lingofuse:prepare_service(Endpoint, Endpoint),
                ?assertEqual(-1, T2)
            after
                try_silent(fun() -> lingofuse:reset_prepare() end),
                try_silent(fun() -> lingofuse:shutdown() end)
            end
    end.

t_reset_prepare_restart() ->
    %% Two consecutive sessions back-to-back. The second
    %% prepare_done must succeed, proving that shutdown + reset
    %% leaves the framework in a restartable state.
    ok = with_framework(fun(_A, _E, _N) -> ok end),
    ok = with_framework(fun(_A, _E, _N) -> ok end),
    ok.

t_exit_main_thread_idempotent() ->
    case ensure_native_or_skip() of
        skip -> ok;
        ok ->
            %% exit_main_thread on a framework that was never started
            %% must not crash, and calling it twice must be safe.
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
                %% Call-mode dispatch in this batch delivers the
                %% message to the registered process. What matters
                %% is that the caller's message reached it.
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
            %% A notify to an absent target is best-effort; it must
            %% not crash and must return ok.
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
        %% The whole point of sequenced notify is FIFO order per
        %% (app, api). If this assertion fails, the sequenced
        %% dispatch path is not preserving order.
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
    %% When the only prepared client already has an App attached,
    %% bind_app has no free client to attach to and must return 0.
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
                %% Prepare a client with no attached app.
                {ok, _} = lingofuse:prepare_client(Endpoint, undefined),
                {ok, 1} = lingofuse:prepare_done(),
                %% Wait for the (still App-less) client to be ready.
                timer:sleep(500),
                %% Now bind the newly created app to the free client.
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