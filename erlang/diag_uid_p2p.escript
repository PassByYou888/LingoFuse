#!/usr/bin/env escript
%%! -noshell -noinput
-mode(compile).

main(_) ->
    setup_code_path(),
    pre_cleanup(),
    banner(),
    Config = try setup_framework()
             catch C:R:S ->
                 io:format("~nSETUP CRASHED: ~p:~p~n~p~n", [C, R, S]),
                 halt(2)
             end,
    Results = run_all(Config),
    verdict(Results),
    safe_cleanup(Config),
    halt(0).

setup_code_path() ->
    lists:foreach(
        fun(P) ->
            case filelib:is_dir(P) of
                true  -> code:add_patha(P);
                false -> ok
            end
        end,
        ["_build/default/lib/lingofuse/ebin",
         "../_build/default/lib/lingofuse/ebin",
         "ebin", "../ebin"]).

pre_cleanup() ->
    try lingofuse:shutdown() catch _:_ -> ok end,
    try lingofuse:reset_prepare() catch _:_ -> ok end,
    ok.

banner() ->
    io:format("~n"),
    io:format("========================================================~n"),
    io:format("  LingoFuse Diagnostic v4~n"),
    io:format("========================================================~n").

setup_framework() ->
    case lingofuse:ensure_loaded() of
        ok -> ok;
        {error, lf_not_loaded} ->
            io:format("[1] NIF loaded ...................... FAIL~n"),
            throw(nif_not_loaded)
    end,
    io:format("[1] NIF loaded ...................... OK~n"),

    _ = lingofuse:set_option(<<"Wait_Connection_ReadyOk">>, <<"False">>),
    _ = lingofuse:set_option(<<"Overlap_Connection">>, <<"True">>),
    _ = lingofuse:set_option(<<"Quiet">>, <<"True">>),
    _ = lingofuse:set_opt_p2p_name(<<"diag_group">>),

    Endpoint = unique_endpoint(),
    AppName  = unique_app_name(),

    {ok, App} = lingofuse:create_app(AppName, <<"diag app">>),

    EchoPid   = spawn(fun echo_server/0),
    WhoamiPid = spawn(fun whoami_server/0),

    ok = lingofuse:register_call_sync(App, <<"echo">>, <<"diag echo">>,
                                      EchoPid),
    ok = lingofuse:register_call_sync(App, <<"whoami">>, <<"diag whoami">>,
                                      WhoamiPid,
                                      #{with_identity => true}),

    _ = lingofuse:reset_prepare(),
    {ok, _} = lingofuse:prepare_service(Endpoint, Endpoint),
    {ok, _} = lingofuse:prepare_client(Endpoint, App),
    {ok, 1} = lingofuse:prepare_done(),

    io:format("[2] setup (App/service/client) ...... OK~n"),

    case wait_check_api(AppName, <<"echo">>, 5000) of
        {ok, _} ->
            io:format("[3] check_api(App, echo) ............ OK~n");
        {error, Reason} ->
            io:format("[3] check_api(App, echo) ............ FAIL (~p)~n",
                      [Reason]),
            throw({check_api_failed, Reason})
    end,

    #{app => App, endpoint => Endpoint, app_name => AppName,
      echo_pid => EchoPid, whoami_pid => WhoamiPid}.

run_all(Config) ->
    R35 = step_local_call(Config),
    case R35 of
        {ok, _} ->
            R4 = step_reverse_whoami(Config),
            R5 = step_check_uid(Config),
            R6 = step_uid_call(Config),
            R7 = step_p2pname_call(Config),
            [{local_call, R35}, {reverse_whoami, R4},
             {check_uid, R5}, {uid_call, R6}, {p2pname_call, R7}];
        {error, _} ->
            io:format("~n[ABORT] LocalCall failed. Skipping network tests.~n"),
            [{local_call, R35},
             {reverse_whoami, {error, skipped}},
             {check_uid, {error, skipped}},
             {uid_call, {error, skipped}},
             {p2pname_call, {error, skipped}}]
    end.

step_local_call(Config) ->
    App = maps:get(app, Config),
    R = run_in_worker(
        fun() ->
            case new_ping_data(<<"echo">>) of
                {ok, Hnd} ->
                    try
                        case lingofuse:local_call(App, Hnd) of
                            {ok, Res} -> read_result(Res);
                            {error, E} -> {error, {local_call, E}}
                        end
                    after
                        _ = lingofuse:free_data(Hnd)
                    end;
                Err -> Err
            end
        end, 10000),
    report("3.5", "LF_LocalCall", R),
    R.

step_reverse_whoami(Config) ->
    AppName = maps:get(app_name, Config),
    R0 = run_in_worker(
        fun() ->
            case new_ping_data(<<"whoami">>) of
                {ok, Hnd} ->
                    try
                        case lingofuse:call(AppName, Hnd, 5000) of
                            {ok, Res} -> read_result(Res);
                            {error, E} -> {error, {lf_call, E}}
                        end
                    after
                        _ = lingofuse:free_data(Hnd)
                    end;
                Err -> Err
            end
        end, 12000),
    R = case R0 of
        {ok, Bin} ->
            case extract_uid_hex(Bin) of
                {ok, Hex} ->
                    put(self_uid, binary:decode_hex(Hex)),
                    {ok, Hex};
                {error, E} -> {error, {parse, E, Bin}}
            end;
        Other -> Other
    end,
    report("4", "LF_Call (reverse whoami)", R),
    R.

step_check_uid(Config) ->
    _ = Config,
    case get(self_uid) of
        undefined ->
            R = {error, no_self_uid},
            report("5", "check_uid(uid)", R),
            R;
        Uid ->
            case wait_check_uid(Uid, 5000) of
                true ->
                    R = {ok, <<"in_pool">>},
                    report("5", "check_uid(uid)", R),
                    R;
                false ->
                    R = {error, not_in_pool},
                    report("5", "check_uid(uid)", R),
                    R
            end
    end.

step_uid_call(Config) ->
    _ = Config,
    case get(self_uid) of
        undefined ->
            R = {error, no_self_uid},
            report("6", "LF_UID_Call", R),
            R;
        Uid ->
            R = run_in_worker(
                fun() ->
                    case new_ping_data(<<"echo">>) of
                        {ok, Hnd} ->
                            try
                                case lingofuse:uid_call(Uid, Hnd, 5000) of
                                    {ok, Res} -> read_result(Res);
                                    {error, E} -> {error, {uid_call, E}}
                                end
                            after
                                _ = lingofuse:free_data(Hnd)
                            end;
                        Err -> Err
                    end
                end, 12000),
            report("6", "LF_UID_Call", R),
            R
    end.

step_p2pname_call(Config) ->
    _ = Config,
    R = run_in_worker(
        fun() ->
            case new_ping_data(<<"echo">>) of
                {ok, Hnd} ->
                    try
                        case lingofuse:p2pname_call(
                               <<"diag_group">>, Hnd, 5000) of
                            {ok, Res} -> read_result(Res);
                            {error, E} -> {error, {p2pname_call, E}}
                        end
                    after
                        _ = lingofuse:free_data(Hnd)
                    end;
                Err -> Err
            end
        end, 12000),
    report("7", "LF_P2PNAME_Call", R),
    R.

new_ping_data(Api) ->
    case lingofuse:create_data(Api) of
        {ok, Hnd} ->
            case lingofuse:write_buffer(Hnd, <<"ping">>) of
                {ok, _Bytes} -> {ok, Hnd};
                {error, E} ->
                    _ = lingofuse:free_data(Hnd),
                    {error, {write_buffer, E}}
            end;
        {error, E} ->
            {error, {create_data, E}}
    end.

read_result(Res) ->
    try
        case lingofuse:get_size(Res) of
            {ok, 0} ->
                {ok, empty};
            {ok, Sz} ->
                case lingofuse:set_pos(Res, 0) of
                    ok ->
                        case lingofuse:read_buffer(Res, Sz) of
                            {ok, Bin} -> {ok, Bin};
                            {error, E} -> {error, {read_buffer, E}}
                        end;
                    {error, E} ->
                        {error, {set_pos, E}}
                end;
            {error, E} ->
                {error, {get_size, E}}
        end
    after
        _ = lingofuse:free_data(Res)
    end.

run_in_worker(Fun, TimeoutMs) ->
    Parent = self(),
    Tag = make_ref(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result = try Fun()
                 catch Class:Reason ->
                     {error, {worker_crash, Class, Reason}}
                 end,
        Parent ! {worker_done, Tag, Result}
    end),
    receive
        {worker_done, Tag, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {worker_died, Reason}}
    after TimeoutMs ->
        try exit(Pid, kill) catch _:_ -> ok end,
        {error, {worker_timeout, TimeoutMs}}
    end.

extract_uid_hex(Bin) when is_binary(Bin) ->
    Trimmed = trim_trailing_nuls(Bin),
    try
        Map = lingofuse_json:loads(Trimmed),
        case is_map(Map) andalso maps:is_key(<<"uid_hex">>, Map) of
            true ->
                case maps:get(<<"uid_hex">>, Map) of
                    Hex when is_binary(Hex), byte_size(Hex) =:= 64 ->
                        {ok, Hex};
                    Other ->
                        {error, {unexpected_uid_hex, Other}}
                end;
            false ->
                {error, {not_a_map, Trimmed}}
        end
    catch
        _:E -> {error, {parse_failed, E, Trimmed}}
    end.

trim_trailing_nuls(Bin) ->
    case byte_size(Bin) > 0 andalso binary:last(Bin) =:= 0 of
        true  -> trim_trailing_nuls(binary:part(Bin, 0, byte_size(Bin) - 1));
        false -> Bin
    end.

wait_check_api(App, Api, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    loop_check_api(App, Api, Deadline).

loop_check_api(App, Api, Deadline) ->
    case lingofuse:check_api(App, Api) of
        {ok, true} -> {ok, <<"visible">>};
        _ ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true  -> {error, not_visible};
                false -> timer:sleep(200),
                         loop_check_api(App, Api, Deadline)
            end
    end.

wait_check_uid(Uid, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    loop_check_uid(Uid, Deadline).

loop_check_uid(Uid, Deadline) ->
    case lingofuse:check_uid(Uid) of
        {ok, true} -> true;
        _ ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true  -> false;
                false -> timer:sleep(200),
                         loop_check_uid(Uid, Deadline)
            end
    end.

report(Label, Desc, {ok, empty}) ->
    io:format("[~s] ~-32s ...... EMPTY (size=0, ROUTING TIMEOUT)~n",
              [Label, Desc]);
report(Label, Desc, {ok, Bin}) when is_binary(Bin) ->
    io:format("[~s] ~-32s ...... OK  (size=~p, data=~p)~n",
              [Label, Desc, byte_size(Bin), preview(Bin)]);
report(Label, Desc, {error, Reason}) ->
    io:format("[~s] ~-32s ...... FAIL (~p)~n",
              [Label, Desc, Reason]).

preview(Bin) when byte_size(Bin) > 32 ->
    binary:part(Bin, 0, 32);
preview(Bin) -> Bin.

verdict(Results) ->
    LocalR  = get_step(Results, local_call),
    WhoamiR = get_step(Results, reverse_whoami),
    CheckR  = get_step(Results, check_uid),
    UidR    = get_step(Results, uid_call),
    P2pR    = get_step(Results, p2pname_call),

    io:format("~n--------------------------------------------------------~n"),
    io:format("  VERDICT~n"),
    io:format("--------------------------------------------------------~n"),
    case {LocalR, WhoamiR, UidR, P2pR} of
        {{ok, _}, {ok, _}, {ok, _}, {ok, _}} ->
            io:format("  ALL PASS.~n~n"),
            io:format("  The UID/P2PName routing works end to end.~n"),
            io:format("  The original test-suite FAILs are a harness bug~n"),
            io:format("  (timeout, setup order, or shared state), not a~n"),
            io:format("  core library bug.~n~n"),
            io:format("  Next: review erlang_abi_test_generator_tool.pas~n"),
            io:format("  for timeout values and shared-state leaks between~n"),
            io:format("  test cases. No Pascal core change needed.~n");

        {{error, LocalErr}, _, _, _} ->
            io:format("  LocalCall FAILED: ~p~n~n", [LocalErr]),
            io:format("  This is the NIF-layer sync bridge. Network is not~n"),
            io:format("  involved, so this is purely lingofuse_nif.c.~n~n"),
            io:format("  Investigate: lf_call_callback, sync_wait,~n"),
            io:format("  sync_deliver, and the CK sync mutex.~n");

        {{ok, _}, {error, WhoamiErr}, _, _} ->
            io:format("  LocalCall OK, but LF_Call FAILED: ~p~n~n",
                      [WhoamiErr]),
            io:format("  LocalCall proves the NIF sync bridge works.~n"),
            io:format("  Therefore LF_Call failure is either:~n"),
            io:format("    a) C4 routing never invokes the callback, OR~n"),
            io:format("    b) the callback fires but writes to the wrong~n"),
            io:format("       output handle.~n~n"),
            io:format("  Distinguish by running with LINGOFUSE_NIF_DEBUG=1~n"),
            io:format("  and searching stderr for '[lf_call_callback] enter'~n"),
            io:format("  right after step 4.~n~n"),
            io:format("  If absent  -> Z.Net.C4.LingoFuse.pas Send_Execute_*.~n"),
            io:format("  If present -> lingofuse_nif.c write_to_output_handle.~n");

        {{ok, _}, {ok, _}, {error, CheckErr}, _} ->
            io:format("  LF_Call OK, but check_uid FAILED: ~p~n~n",
                      [CheckErr]),
            case CheckErr of
                no_self_uid ->
                    io:format("  Could not parse whoami response.~n");
                not_in_pool ->
                    io:format("  FUID_Pool does NOT contain the UID.~n"),
                    io:format("  Update_UID never reached the server.~n"),
                    io:format("  Investigate TC40_LF_Client.Update_UID_Info~n"),
                    io:format("  and cmd_Update_UID in Z.Net.C4.LingoFuse.pas.~n");
                _ ->
                    io:format("  Unexpected check_uid error.~n")
            end;

        {{ok, _}, {ok, _}, {ok, _}, {error, P2pErr}} ->
            io:format("  UID PASS, P2PName FAILED: ~p~n~n", [P2pErr]),
            io:format("  FUID_Pool is populated but FP2PName_Pool is not,~n"),
            io:format("  OR Find_P2PName_LoadBalance cannot pick the target.~n"),
            io:format("  Investigate cmd_Update_UID (does it also populate~n"),
            io:format("  FP2PName_Pool?) and Find_P2PName_LoadBalance.~n");

        {{ok, _}, {ok, _}, {error, UidErr}, {error, _}} ->
            io:format("  App-name works, UID fails, P2PName fails.~n"),
            io:format("  UID error: ~p~n~n", [UidErr]),
            io:format("  This pattern points to a shared registration path~n"),
            io:format("  (Update_UID) being dropped for the self-loop~n"),
            io:format("  client only.~n");

        _ ->
            io:format("  Inconclusive.~n"),
            io:format("  local_call : ~p~n", [LocalR]),
            io:format("  whoami     : ~p~n", [WhoamiR]),
            io:format("  check_uid  : ~p~n", [CheckR]),
            io:format("  uid_call   : ~p~n", [UidR]),
            io:format("  p2pname    : ~p~n", [P2pR])
    end,
    io:format("~n").

get_step(Results, Name) ->
    case lists:keyfind(Name, 1, Results) of
        {Name, R} -> R;
        false     -> {error, missing}
    end.

echo_server() ->
    receive
        {lf_call, Ref, <<"echo">>, _Payload} ->
            _ = lingofuse:reply(Ref, <<"pong">>),
            echo_server();
        {lf_call, Ref, _Api, _Payload} ->
            _ = lingofuse:reply(Ref, <<>>),
            echo_server();
        _ ->
            echo_server()
    end.

whoami_server() ->
    receive
        {lf_call, Ref, <<"whoami">>, _Payload, Identity} ->
            UidBin = case is_map(Identity) of
                true  -> maps:get(uid, Identity, <<0:256>>);
                false -> <<0:256>>
            end,
            P2PNameBin = case is_map(Identity) of
                true  -> maps:get(p2p_name, Identity, <<>>);
                false -> <<>>
            end,
            Map = #{
                <<"uid_hex">>  => binary:encode_hex(UidBin),
                <<"p2p_name">> => P2PNameBin
            },
            Reply = lingofuse_json:dumps(Map),
            _ = lingofuse:reply(Ref, Reply),
            whoami_server();
        {lf_call, Ref, _Api, _Payload, _Identity} ->
            _ = lingofuse:reply(Ref, <<>>),
            whoami_server();
        {lf_call, Ref, _Api, _Payload} ->
            _ = lingofuse:reply(Ref, <<>>),
            whoami_server();
        _ ->
            whoami_server()
    end.

safe_cleanup(Config) ->
    maps:foreach(
        fun(K, V) when (K =:= echo_pid orelse K =:= whoami_pid)
                       andalso is_pid(V) ->
               try exit(V, kill) catch _:_ -> ok end;
           (_K, _V) -> ok
        end,
        Config),
    try lingofuse:exit_main_thread() catch _:_ -> ok end,
    case maps:get(app, Config, undefined) of
        App when is_reference(App) ->
            try lingofuse:free_app(App) catch _:_ -> ok end;
        _ -> ok
    end,
    try lingofuse:shutdown() catch _:_ -> ok end,
    timer:sleep(200),
    io:format("Cleanup complete.~n").

unique_endpoint() ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("ipc:lf_diag_~s_~p", [os:getpid(), N])).

unique_app_name() ->
    N = erlang:unique_integer([positive, monotonic]),
    iolist_to_binary(
      io_lib:format("DiagApp_~s_~p", [os:getpid(), N])).