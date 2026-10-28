-module(lingofuse_nif).

-on_load(init/0).

-export([
    create_data/1,
    create_data_permanent/1,
    free_data/1,
    get_buffer/1,
    write_buffer/2,
    read_buffer/2,
    get_pos/1,
    set_pos/2,
    get_size/1,
    set_size/2
]).

-export([
    create_app/2,
    free_app/1,
    generate_app_name/0,
    get_app_name/1,
    bind_app/1
]).

-export([
    register_call/5,
    register_call_sync/5,
    register_notify/5,
    unregister/2
]).

-export([
    register_p2p_call/4,
    register_p2p_call_sync/4,
    register_p2p_notify/4,
    unregister_p2p/1
]).

-export([
    reply/2,
    set_sync_timeout/1,
    get_sync_timeout/0
]).

-export([
    local_call/2,
    local_notify/2
]).

-export([
    reset_prepare/0,
    prepare_service/2,
    prepare_client/2,
    prepare_done/0,
    exit_main_thread/0
]).

-export([
    call/3,
    notify/2,
    sequenced_notify/2
]).

-export([
    uid_call/3,
    uid_notify/2,
    uid_sequenced_notify/2
]).

-export([
    p2pname_call/3,
    p2pname_notify/2,
    p2pname_sequenced_notify/2
]).

-export([
    async_call/3,
    async_sequenced_call/3,
    uid_async_call/3,
    uid_async_sequenced_call/3,
    p2pname_async_call/3,
    p2pname_async_sequenced_call/3
]).

-export([
    set_option/2,
    get_option/1,
    get_status_count/0,
    get_status/0,
    post_status/1,
    check_main_thread/0,
    check_app/1,
    check_api/2
]).

-export([
    check_uid/1,
    check_uid_api/2,
    check_p2pname/1,
    check_p2pname_api/2
]).

-export([shutdown/0]).

-export([set_network_event/2]).

-export([get_self_uid/0]).

create_data(_Name)              -> erlang:nif_error({not_loaded, ?MODULE}).
create_data_permanent(_Name)    -> erlang:nif_error({not_loaded, ?MODULE}).
free_data(_Hnd)                 -> erlang:nif_error({not_loaded, ?MODULE}).
get_buffer(_Hnd)                -> erlang:nif_error({not_loaded, ?MODULE}).
write_buffer(_Hnd, _Bin)        -> erlang:nif_error({not_loaded, ?MODULE}).
read_buffer(_Hnd, _Count)       -> erlang:nif_error({not_loaded, ?MODULE}).
get_pos(_Hnd)                   -> erlang:nif_error({not_loaded, ?MODULE}).
set_pos(_Hnd, _Pos)             -> erlang:nif_error({not_loaded, ?MODULE}).
get_size(_Hnd)                  -> erlang:nif_error({not_loaded, ?MODULE}).
set_size(_Hnd, _Size)           -> erlang:nif_error({not_loaded, ?MODULE}).

create_app(_Name, _Desc)        -> erlang:nif_error({not_loaded, ?MODULE}).
free_app(_Hnd)                  -> erlang:nif_error({not_loaded, ?MODULE}).
generate_app_name()             -> erlang:nif_error({not_loaded, ?MODULE}).
get_app_name(_Hnd)              -> erlang:nif_error({not_loaded, ?MODULE}).
bind_app(_Hnd)                  -> erlang:nif_error({not_loaded, ?MODULE}).

register_call(_App, _Name, _Desc, _Pid, _Opts)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
register_call_sync(_App, _Name, _Desc, _Pid, _Opts)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
register_notify(_App, _Name, _Desc, _Pid, _Opts)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
unregister(_App, _Name)         -> erlang:nif_error({not_loaded, ?MODULE}).

register_p2p_call(_Name, _Desc, _Pid, _Opts)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
register_p2p_call_sync(_Name, _Desc, _Pid, _Opts)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
register_p2p_notify(_Name, _Desc, _Pid, _Opts)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
unregister_p2p(_Name)           -> erlang:nif_error({not_loaded, ?MODULE}).

reply(_Ref, _ResultBin)         -> erlang:nif_error({not_loaded, ?MODULE}).
set_sync_timeout(_Ms)           -> erlang:nif_error({not_loaded, ?MODULE}).
get_sync_timeout()              -> erlang:nif_error({not_loaded, ?MODULE}).

local_call(_App, _Param)        -> erlang:nif_error({not_loaded, ?MODULE}).
local_notify(_App, _Param)      -> erlang:nif_error({not_loaded, ?MODULE}).

reset_prepare()                 -> erlang:nif_error({not_loaded, ?MODULE}).
prepare_service(_L, _P)         -> erlang:nif_error({not_loaded, ?MODULE}).
prepare_client(_Addr, _App)     -> erlang:nif_error({not_loaded, ?MODULE}).
prepare_done()                  -> erlang:nif_error({not_loaded, ?MODULE}).
exit_main_thread()              -> erlang:nif_error({not_loaded, ?MODULE}).

call(_App, _Param, _Timeout)    -> erlang:nif_error({not_loaded, ?MODULE}).
notify(_App, _Param)            -> erlang:nif_error({not_loaded, ?MODULE}).
sequenced_notify(_App, _Param)  -> erlang:nif_error({not_loaded, ?MODULE}).

uid_call(_Uid, _Param, _Timeout)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
uid_notify(_Uid, _Param)        -> erlang:nif_error({not_loaded, ?MODULE}).
uid_sequenced_notify(_Uid, _Param)
                                -> erlang:nif_error({not_loaded, ?MODULE}).

p2pname_call(_Name, _Param, _Timeout)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
p2pname_notify(_Name, _Param)   -> erlang:nif_error({not_loaded, ?MODULE}).
p2pname_sequenced_notify(_Name, _Param)
                                -> erlang:nif_error({not_loaded, ?MODULE}).

async_call(_App, _Param, _ReplyPid)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
async_sequenced_call(_App, _Param, _ReplyPid)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
uid_async_call(_Uid, _Param, _ReplyPid)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
uid_async_sequenced_call(_Uid, _Param, _ReplyPid)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
p2pname_async_call(_Name, _Param, _ReplyPid)
                                -> erlang:nif_error({not_loaded, ?MODULE}).
p2pname_async_sequenced_call(_Name, _Param, _ReplyPid)
                                -> erlang:nif_error({not_loaded, ?MODULE}).

set_option(_Opt, _Val)          -> erlang:nif_error({not_loaded, ?MODULE}).
get_option(_Opt)                -> erlang:nif_error({not_loaded, ?MODULE}).
get_status_count()              -> erlang:nif_error({not_loaded, ?MODULE}).
get_status()                    -> erlang:nif_error({not_loaded, ?MODULE}).
post_status(_Status)            -> erlang:nif_error({not_loaded, ?MODULE}).
check_main_thread()             -> erlang:nif_error({not_loaded, ?MODULE}).
check_app(_App)                 -> erlang:nif_error({not_loaded, ?MODULE}).
check_api(_App, _Api)           -> erlang:nif_error({not_loaded, ?MODULE}).

check_uid(_Uid)                 -> erlang:nif_error({not_loaded, ?MODULE}).
check_uid_api(_Uid, _Api)       -> erlang:nif_error({not_loaded, ?MODULE}).
check_p2pname(_Name)            -> erlang:nif_error({not_loaded, ?MODULE}).
check_p2pname_api(_Name, _Api)  -> erlang:nif_error({not_loaded, ?MODULE}).

shutdown()                      -> erlang:nif_error({not_loaded, ?MODULE}).

set_network_event(_C, _D)       -> erlang:nif_error({not_loaded, ?MODULE}).

get_self_uid()                  -> erlang:nif_error({not_loaded, ?MODULE}).

init() ->
    case find_priv_dir() of
        {ok, PrivDir} ->
            NifPath = filename:join(PrivDir, "lingofuse_nif"),
            do_load(NifPath);
        {error, Reason} ->
            io:format(standard_error,
                      "[lingofuse_nif] cannot locate priv dir: ~p~n",
                      [Reason]),
            ok
    end.

do_load(NifPath) ->
    try erlang:load_nif(NifPath, 0) of
        ok ->
            io:format(standard_error,
                      "[lingofuse_nif] NIF loaded from ~s~n", [NifPath]),
            ok;
        {error, {reload, _}} ->
            ok;
        {error, Reason} ->
            io:format(standard_error,
                      "[lingofuse_nif] NIF load failed (~s): ~p~n",
                      [NifPath, Reason]),
            ok
    catch
        Class:Reason2 ->
            io:format(standard_error,
                      "[lingofuse_nif] NIF load raised (~s): ~p:~p~n",
                      [NifPath, Class, Reason2]),
            ok
    end.

find_priv_dir() ->
    case code:priv_dir(lingofuse) of
        {error, _} ->
            case code:which(?MODULE) of
                Path when is_list(Path) ->
                    {ok, filename:join(filename:dirname(Path), "../priv")};
                _ ->
                    {error, priv_dir_not_found}
            end;
        Dir when is_list(Dir) ->
            {ok, Dir}
    end.