-module(lingofuse).

-export([ensure_loaded/0]).

-export([
    create_data/1,
    create_data_permanent/1,
    free_data/1,
    write_buffer/2,
    read_buffer/2,
    get_buffer/1,
    get_pos/1,
    set_pos/2,
    get_size/1,
    set_size/2
]).

-export([
    write_int8/2, write_uint8/2,
    write_int16/2, write_uint16/2,
    write_int32/2, write_uint32/2,
    write_int64/2, write_uint64/2,
    write_single/2, write_double/2,
    write_string/2, write_string_bytes/2
]).

-export([
    read_int8/1, read_uint8/1,
    read_int16/1, read_uint16/1,
    read_int32/1, read_uint32/1,
    read_int64/1, read_uint64/1,
    read_single/1, read_double/1,
    read_string/1, read_string_bytes/1
]).

-export([
    create_app/1,
    create_app/2,
    free_app/1,
    generate_app_name/0,
    get_app_name/1,
    bind_app/1
]).

-export([
    register_call/4,
    register_call/5,
    register_call_sync/4,
    register_call_sync/5,
    register_notify/4,
    register_notify/5,
    unregister/2
]).

-export([
    register_p2p_call/3,
    register_p2p_call/4,
    register_p2p_call_sync/3,
    register_p2p_call_sync/4,
    register_p2p_notify/3,
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
    prepare_client/1,
    prepare_client/2,
    prepare_done/0,
    exit_main_thread/0
]).

-export([
    call/2,
    call/3,
    notify/2,
    sequenced_notify/2
]).

-export([
    uid_call/2,
    uid_call/3,
    uid_notify/2,
    uid_sequenced_notify/2
]).

-export([
    p2pname_call/2,
    p2pname_call/3,
    p2pname_notify/2,
    p2pname_sequenced_notify/2
]).

-export([
    async_call/4,
    async_call/5,
    async_call_seq/4,
    async_call_seq/5,
    async_uid_call/4,
    async_uid_call/5,
    async_uid_call_seq/4,
    async_uid_call_seq/5,
    async_p2pname_call/4,
    async_p2pname_call/5,
    async_p2pname_call_seq/4,
    async_p2pname_call_seq/5
]).

-export([
    async_call_raw/3,
    async_call_seq_raw/3,
    async_uid_call_raw/3,
    async_uid_call_seq_raw/3,
    async_p2pname_call_raw/3,
    async_p2pname_call_seq_raw/3
]).

-export([
    set_option/2,
    get_option/1
]).

-export([
    set_opt_password/1, get_opt_password/0,
    set_opt_debug/1, get_opt_debug/0,
    set_opt_quiet/1, get_opt_quiet/0,
    set_opt_show_thread_id/1, get_opt_show_thread_id/0,
    set_opt_console_output/1, get_opt_console_output/0,
    set_opt_overlap_connection/1, get_opt_overlap_connection/0,
    set_opt_wait_connection_ready_ok/1, get_opt_wait_connection_ready_ok/0,
    set_opt_wait_connection_timeout/1, get_opt_wait_connection_timeout/0,
    set_opt_ipc_serv_thread_count/1, get_opt_ipc_serv_thread_count/0,
    set_opt_ipc_serv_max_queue_length/1, get_opt_ipc_serv_max_queue_length/0,
    set_opt_ipc_serv_max_msg_size/1, get_opt_ipc_serv_max_msg_size/0,
    set_opt_fixed_sequenced_time/1, get_opt_fixed_sequenced_time/0,
    set_opt_p2p_name/1, get_opt_p2p_name/0,
    set_opt_data_handle_idle_timeout/1,
    get_opt_data_handle_idle_timeout/0,
    set_opt_data_handle_pool_scan_interval/1,
    get_opt_data_handle_pool_scan_interval/0,
    set_opt_no_reponse_cmd_null_flush_threshold/1,
    get_opt_no_reponse_cmd_null_flush_threshold/0
]).

-export([
    post_status/1,
    get_status/0,
    get_status_count/0
]).

-export([
    check_main_thread/0,
    check_app/1,
    check_api/2,
    check_uid/1,
    check_uid_api/2,
    check_p2pname/1,
    check_p2pname_api/2
]).

-export([
    get_self_uid/0,
    get_self_uid_hex/0
]).

-export([shutdown/0]).

-export([set_network_event/2]).

-type data_handle()  :: reference().
-type app_handle()   :: reference().
-type api_name()     :: binary().
-type app_name()     :: binary().
-type p2p_name()     :: binary().
-type endpoint()     :: binary().
-type uid()          :: <<_:256>>.
-type sync_ref()     :: non_neg_integer().
-type async_ref()    :: non_neg_integer().
-type timeout_ms()   :: non_neg_integer().
-type async_timeout() :: timeout_ms() | infinity.
-type async_result() :: {ok, binary()} | {error, term()}.
-type async_callback() :: fun((async_result()) -> any()).
-type register_options() :: #{with_identity => boolean()}.
-type identity() :: #{uid := uid(), p2p_name := binary()}.
-type abi_io_error() ::
    {error, lf_not_loaded}
    | {error, short_write}
    | {error, truncated}
    | {error, eof}
    | {error, no_nul_terminator}
    | {error, term()}.

-export_type([
    data_handle/0,
    app_handle/0,
    uid/0,
    sync_ref/0,
    async_ref/0,
    async_result/0,
    async_callback/0,
    register_options/0,
    identity/0,
    abi_io_error/0
]).

-define(ASYNC_DEFAULT_TIMEOUT_MS, 30000).
-define(CALL_DEFAULT_TIMEOUT_MS, 5000).

-spec ensure_loaded() -> ok | {error, lf_not_loaded}.
ensure_loaded() ->
    try lingofuse_nif:check_main_thread() of
        _ -> ok
    catch
        error:{not_loaded, _} -> {error, lf_not_loaded};
        error:undef           -> {error, lf_not_loaded}
    end.

-spec create_data(api_name()) -> {ok, data_handle()} | {error, term()}.
create_data(Name) when is_binary(Name) ->
    wrap_handle(lingofuse_nif:create_data(Name));
create_data(_) ->
    error(badarg).

-spec create_data_permanent(api_name()) ->
    {ok, data_handle()} | {error, term()}.
create_data_permanent(Name) when is_binary(Name) ->
    wrap_handle(lingofuse_nif:create_data_permanent(Name));
create_data_permanent(_) ->
    error(badarg).

-spec free_data(data_handle()) -> ok | {error, term()}.
free_data(Hnd) when is_reference(Hnd) ->
    normalize_ok(lingofuse_nif:free_data(Hnd));
free_data(_) ->
    error(badarg).

-spec write_buffer(data_handle(), binary()) ->
    {ok, non_neg_integer()} | {error, term()}.
write_buffer(Hnd, Bin) when is_reference(Hnd), is_binary(Bin) ->
    normalize_ok(lingofuse_nif:write_buffer(Hnd, Bin));
write_buffer(_, _) ->
    error(badarg).

-spec read_buffer(data_handle(), non_neg_integer()) ->
    {ok, binary()} | {error, term()}.
read_buffer(Hnd, Count)
        when is_reference(Hnd), is_integer(Count), Count >= 0 ->
    normalize_ok(lingofuse_nif:read_buffer(Hnd, Count));
read_buffer(_, _) ->
    error(badarg).

-spec get_buffer(data_handle()) -> {ok, binary()} | {error, term()}.
get_buffer(Hnd) when is_reference(Hnd) ->
    normalize_ok(lingofuse_nif:get_buffer(Hnd));
get_buffer(_) ->
    error(badarg).

-spec get_pos(data_handle()) -> {ok, non_neg_integer()} | {error, term()}.
get_pos(Hnd) when is_reference(Hnd) ->
    normalize_ok(lingofuse_nif:get_pos(Hnd));
get_pos(_) ->
    error(badarg).

-spec set_pos(data_handle(), non_neg_integer()) -> ok | {error, term()}.
set_pos(Hnd, Pos)
        when is_reference(Hnd), is_integer(Pos), Pos >= 0 ->
    normalize_ok(lingofuse_nif:set_pos(Hnd, Pos));
set_pos(_, _) ->
    error(badarg).

-spec get_size(data_handle()) ->
    {ok, non_neg_integer()} | {error, term()}.
get_size(Hnd) when is_reference(Hnd) ->
    normalize_ok(lingofuse_nif:get_size(Hnd));
get_size(_) ->
    error(badarg).

-spec set_size(data_handle(), non_neg_integer()) -> ok | {error, term()}.
set_size(Hnd, Size)
        when is_reference(Hnd), is_integer(Size), Size >= 0 ->
    normalize_ok(lingofuse_nif:set_size(Hnd, Size));
set_size(_, _) ->
    error(badarg).

-spec write_int8(data_handle(), integer()) -> ok | abi_io_error().
write_int8(Hnd, V) when is_reference(Hnd), is_integer(V), V >= -128, V =< 127 ->
    write_fixed(Hnd, <<V:8/little-signed>>);
write_int8(_, _) ->
    error(badarg).

-spec write_uint8(data_handle(), integer()) -> ok | abi_io_error().
write_uint8(Hnd, V) when is_reference(Hnd), is_integer(V), V >= 0, V =< 255 ->
    write_fixed(Hnd, <<V:8/unsigned>>);
write_uint8(_, _) ->
    error(badarg).

-spec write_int16(data_handle(), integer()) -> ok | abi_io_error().
write_int16(Hnd, V) when is_reference(Hnd), is_integer(V),
                         V >= -32768, V =< 32767 ->
    write_fixed(Hnd, <<V:16/little-signed>>);
write_int16(_, _) ->
    error(badarg).

-spec write_uint16(data_handle(), integer()) -> ok | abi_io_error().
write_uint16(Hnd, V) when is_reference(Hnd), is_integer(V),
                          V >= 0, V =< 65535 ->
    write_fixed(Hnd, <<V:16/little-unsigned>>);
write_uint16(_, _) ->
    error(badarg).

-spec write_int32(data_handle(), integer()) -> ok | abi_io_error().
write_int32(Hnd, V) when is_reference(Hnd), is_integer(V),
                         V >= -2147483648, V =< 2147483647 ->
    write_fixed(Hnd, <<V:32/little-signed>>);
write_int32(_, _) ->
    error(badarg).

-spec write_uint32(data_handle(), integer()) -> ok | abi_io_error().
write_uint32(Hnd, V) when is_reference(Hnd), is_integer(V),
                          V >= 0, V =< 4294967295 ->
    write_fixed(Hnd, <<V:32/little-unsigned>>);
write_uint32(_, _) ->
    error(badarg).

-spec write_int64(data_handle(), integer()) -> ok | abi_io_error().
write_int64(Hnd, V) when is_reference(Hnd), is_integer(V),
                         V >= -9223372036854775808,
                         V =< 9223372036854775807 ->
    write_fixed(Hnd, <<V:64/little-signed>>);
write_int64(_, _) ->
    error(badarg).

-spec write_uint64(data_handle(), integer()) -> ok | abi_io_error().
write_uint64(Hnd, V) when is_reference(Hnd), is_integer(V),
                          V >= 0, V =< 18446744073709551615 ->
    write_fixed(Hnd, <<V:64/little-unsigned>>);
write_uint64(_, _) ->
    error(badarg).

-spec write_single(data_handle(), float() | integer()) -> ok | abi_io_error().
write_single(Hnd, V) when is_reference(Hnd), is_number(V) ->
    write_fixed(Hnd, <<(float(V)):32/little-float>>);
write_single(_, _) ->
    error(badarg).

-spec write_double(data_handle(), float() | integer()) -> ok | abi_io_error().
write_double(Hnd, V) when is_reference(Hnd), is_number(V) ->
    write_fixed(Hnd, <<(float(V)):64/little-float>>);
write_double(_, _) ->
    error(badarg).

-spec write_string(data_handle(), binary()) -> ok | abi_io_error().
write_string(Hnd, Bin) when is_reference(Hnd), is_binary(Bin) ->
    write_string_bytes(Hnd, Bin);
write_string(_, _) ->
    error(badarg).

-spec write_string_bytes(data_handle(), binary()) -> ok | abi_io_error().
write_string_bytes(Hnd, Bin) when is_reference(Hnd), is_binary(Bin) ->
    Framed = <<Bin/binary, 0>>,
    case write_buffer(Hnd, Framed) of
        {ok, N} when N =:= byte_size(Framed) -> ok;
        {ok, _}                              -> {error, short_write};
        {error, _} = E                       -> E
    end;
write_string_bytes(_, _) ->
    error(badarg).

-spec read_int8(data_handle()) -> {ok, integer()} | abi_io_error().
read_int8(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 1, fun(<<V:8/little-signed>>) -> {ok, V} end);
read_int8(_) ->
    error(badarg).

-spec read_uint8(data_handle()) -> {ok, integer()} | abi_io_error().
read_uint8(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 1, fun(<<V:8/unsigned>>) -> {ok, V} end);
read_uint8(_) ->
    error(badarg).

-spec read_int16(data_handle()) -> {ok, integer()} | abi_io_error().
read_int16(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 2, fun(<<V:16/little-signed>>) -> {ok, V} end);
read_int16(_) ->
    error(badarg).

-spec read_uint16(data_handle()) -> {ok, integer()} | abi_io_error().
read_uint16(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 2, fun(<<V:16/little-unsigned>>) -> {ok, V} end);
read_uint16(_) ->
    error(badarg).

-spec read_int32(data_handle()) -> {ok, integer()} | abi_io_error().
read_int32(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 4, fun(<<V:32/little-signed>>) -> {ok, V} end);
read_int32(_) ->
    error(badarg).

-spec read_uint32(data_handle()) -> {ok, integer()} | abi_io_error().
read_uint32(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 4, fun(<<V:32/little-unsigned>>) -> {ok, V} end);
read_uint32(_) ->
    error(badarg).

-spec read_int64(data_handle()) -> {ok, integer()} | abi_io_error().
read_int64(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 8, fun(<<V:64/little-signed>>) -> {ok, V} end);
read_int64(_) ->
    error(badarg).

-spec read_uint64(data_handle()) -> {ok, integer()} | abi_io_error().
read_uint64(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 8, fun(<<V:64/little-unsigned>>) -> {ok, V} end);
read_uint64(_) ->
    error(badarg).

-spec read_single(data_handle()) -> {ok, float()} | abi_io_error().
read_single(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 4, fun(<<V:32/little-float>>) -> {ok, V} end);
read_single(_) ->
    error(badarg).

-spec read_double(data_handle()) -> {ok, float()} | abi_io_error().
read_double(Hnd) when is_reference(Hnd) ->
    read_fixed(Hnd, 8, fun(<<V:64/little-float>>) -> {ok, V} end);
read_double(_) ->
    error(badarg).

-spec read_string(data_handle()) -> {ok, binary()} | abi_io_error().
read_string(Hnd) when is_reference(Hnd) ->
    read_string_bytes(Hnd);
read_string(_) ->
    error(badarg).

-spec read_string_bytes(data_handle()) -> {ok, binary()} | abi_io_error().
read_string_bytes(Hnd) when is_reference(Hnd) ->
    case get_pos(Hnd) of
        {ok, Pos} ->
            case get_size(Hnd) of
                {ok, Size} when Size > Pos ->
                    Len = Size - Pos,
                    case read_buffer(Hnd, Len) of
                        {ok, Bin} ->
                            case binary:match(Bin, <<0>>) of
                                {NulPos, 1} ->
                                    <<Str:NulPos/binary, _/binary>> = Bin,
                                    ok = set_pos(Hnd, Pos + NulPos + 1),
                                    {ok, Str};
                                nomatch ->
                                    ok = set_pos(Hnd, Size),
                                    {ok, Bin}
                            end;
                        {error, _} = E ->
                            E
                    end;
                {ok, _} ->
                    {error, eof};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;
read_string_bytes(_) ->
    error(badarg).

-spec create_app(app_name()) -> {ok, app_handle()} | {error, term()}.
create_app(Name) ->
    create_app(Name, <<>>).

-spec create_app(app_name(), binary()) -> {ok, app_handle()} | {error, term()}.
create_app(Name, Desc) when is_binary(Name), is_binary(Desc) ->
    wrap_handle(lingofuse_nif:create_app(Name, Desc));
create_app(_, _) ->
    error(badarg).

-spec free_app(app_handle()) -> ok | {error, term()}.
free_app(Hnd) when is_reference(Hnd) ->
    normalize_ok(lingofuse_nif:free_app(Hnd));
free_app(_) ->
    error(badarg).

-spec generate_app_name() -> {ok, binary()} | {error, term()}.
generate_app_name() ->
    normalize_ok(lingofuse_nif:generate_app_name()).

-spec get_app_name(app_handle()) -> {ok, binary()} | {error, term()}.
get_app_name(Hnd) when is_reference(Hnd) ->
    normalize_ok(lingofuse_nif:get_app_name(Hnd));
get_app_name(_) ->
    error(badarg).

-spec bind_app(app_handle()) -> {ok, non_neg_integer()} | {error, term()}.
bind_app(Hnd) when is_reference(Hnd) ->
    normalize_ok(lingofuse_nif:bind_app(Hnd));
bind_app(_) ->
    error(badarg).

-spec register_call(app_handle(), api_name(), binary(), pid()) ->
    ok | {error, term()}.
register_call(App, Name, Desc, Pid) ->
    register_call(App, Name, Desc, Pid, #{}).

-spec register_call(app_handle(), api_name(), binary(), pid(),
                    register_options() | undefined) ->
    ok | {error, term()}.
register_call(App, Name, Desc, Pid, Options)
        when is_reference(App), is_binary(Name), is_binary(Desc),
             is_pid(Pid), is_map(Options) ->
    normalize_ok(
      lingofuse_nif:register_call(App, Name, Desc, Pid, Options));
register_call(App, Name, Desc, Pid, undefined)
        when is_reference(App), is_binary(Name), is_binary(Desc),
             is_pid(Pid) ->
    normalize_ok(
      lingofuse_nif:register_call(App, Name, Desc, Pid, #{}));
register_call(_, _, _, _, _) ->
    error(badarg).

-spec register_call_sync(app_handle(), api_name(), binary(), pid()) ->
    ok | {error, term()}.
register_call_sync(App, Name, Desc, Pid) ->
    register_call_sync(App, Name, Desc, Pid, #{}).

-spec register_call_sync(app_handle(), api_name(), binary(), pid(),
                         register_options() | undefined) ->
    ok | {error, term()}.
register_call_sync(App, Name, Desc, Pid, Options)
        when is_reference(App), is_binary(Name), is_binary(Desc),
             is_pid(Pid), is_map(Options) ->
    normalize_ok(
      lingofuse_nif:register_call_sync(App, Name, Desc, Pid, Options));
register_call_sync(App, Name, Desc, Pid, undefined)
        when is_reference(App), is_binary(Name), is_binary(Desc),
             is_pid(Pid) ->
    normalize_ok(
      lingofuse_nif:register_call_sync(App, Name, Desc, Pid, #{}));
register_call_sync(_, _, _, _, _) ->
    error(badarg).

-spec register_notify(app_handle(), api_name(), binary(), pid()) ->
    ok | {error, term()}.
register_notify(App, Name, Desc, Pid) ->
    register_notify(App, Name, Desc, Pid, #{}).

-spec register_notify(app_handle(), api_name(), binary(), pid(),
                      register_options() | undefined) ->
    ok | {error, term()}.
register_notify(App, Name, Desc, Pid, Options)
        when is_reference(App), is_binary(Name), is_binary(Desc),
             is_pid(Pid), is_map(Options) ->
    normalize_ok(
      lingofuse_nif:register_notify(App, Name, Desc, Pid, Options));
register_notify(App, Name, Desc, Pid, undefined)
        when is_reference(App), is_binary(Name), is_binary(Desc),
             is_pid(Pid) ->
    normalize_ok(
      lingofuse_nif:register_notify(App, Name, Desc, Pid, #{}));
register_notify(_, _, _, _, _) ->
    error(badarg).

-spec unregister(app_handle(), api_name()) ->
    {ok, boolean()} | {error, term()}.
unregister(App, Name) when is_reference(App), is_binary(Name) ->
    case lingofuse_nif:unregister(App, Name) of
        true            -> {ok, true};
        false           -> {ok, false};
        {error, Reason} -> {error, Reason}
    end;
unregister(_, _) ->
    error(badarg).

-spec register_p2p_call(api_name(), binary(), pid()) ->
    ok | {error, term()}.
register_p2p_call(Name, Desc, Pid) ->
    register_p2p_call(Name, Desc, Pid, #{}).

-spec register_p2p_call(api_name(), binary(), pid(),
                        register_options() | undefined) ->
    ok | {error, term()}.
register_p2p_call(Name, Desc, Pid, Options)
        when is_binary(Name), is_binary(Desc),
             is_pid(Pid), is_map(Options) ->
    normalize_ok(
      lingofuse_nif:register_p2p_call(Name, Desc, Pid, Options));
register_p2p_call(Name, Desc, Pid, undefined)
        when is_binary(Name), is_binary(Desc), is_pid(Pid) ->
    normalize_ok(
      lingofuse_nif:register_p2p_call(Name, Desc, Pid, #{}));
register_p2p_call(_, _, _, _) ->
    error(badarg).

-spec register_p2p_call_sync(api_name(), binary(), pid()) ->
    ok | {error, term()}.
register_p2p_call_sync(Name, Desc, Pid) ->
    register_p2p_call_sync(Name, Desc, Pid, #{}).

-spec register_p2p_call_sync(api_name(), binary(), pid(),
                             register_options() | undefined) ->
    ok | {error, term()}.
register_p2p_call_sync(Name, Desc, Pid, Options)
        when is_binary(Name), is_binary(Desc),
             is_pid(Pid), is_map(Options) ->
    normalize_ok(
      lingofuse_nif:register_p2p_call_sync(Name, Desc, Pid, Options));
register_p2p_call_sync(Name, Desc, Pid, undefined)
        when is_binary(Name), is_binary(Desc), is_pid(Pid) ->
    normalize_ok(
      lingofuse_nif:register_p2p_call_sync(Name, Desc, Pid, #{}));
register_p2p_call_sync(_, _, _, _) ->
    error(badarg).

-spec register_p2p_notify(api_name(), binary(), pid()) ->
    ok | {error, term()}.
register_p2p_notify(Name, Desc, Pid) ->
    register_p2p_notify(Name, Desc, Pid, #{}).

-spec register_p2p_notify(api_name(), binary(), pid(),
                          register_options() | undefined) ->
    ok | {error, term()}.
register_p2p_notify(Name, Desc, Pid, Options)
        when is_binary(Name), is_binary(Desc),
             is_pid(Pid), is_map(Options) ->
    normalize_ok(
      lingofuse_nif:register_p2p_notify(Name, Desc, Pid, Options));
register_p2p_notify(Name, Desc, Pid, undefined)
        when is_binary(Name), is_binary(Desc), is_pid(Pid) ->
    normalize_ok(
      lingofuse_nif:register_p2p_notify(Name, Desc, Pid, #{}));
register_p2p_notify(_, _, _, _) ->
    error(badarg).

-spec unregister_p2p(api_name()) -> {ok, boolean()} | {error, term()}.
unregister_p2p(Name) when is_binary(Name) ->
    case lingofuse_nif:unregister_p2p(Name) of
        true            -> {ok, true};
        false           -> {ok, false};
        {error, Reason} -> {error, Reason}
    end;
unregister_p2p(_) ->
    error(badarg).

-spec reply(sync_ref(), binary()) -> ok | {error, term()}.
reply(Ref, ResultBin)
        when is_integer(Ref), Ref >= 0, is_binary(ResultBin) ->
    normalize_ok(lingofuse_nif:reply(Ref, ResultBin));
reply(_, _) ->
    error(badarg).

-spec set_sync_timeout(pos_integer()) -> ok | {error, term()}.
set_sync_timeout(Ms) when is_integer(Ms), Ms > 0 ->
    normalize_ok(lingofuse_nif:set_sync_timeout(Ms));
set_sync_timeout(_) ->
    error(badarg).

-spec get_sync_timeout() -> {ok, pos_integer()} | {error, term()}.
get_sync_timeout() ->
    normalize_ok(lingofuse_nif:get_sync_timeout()).

-spec local_call(app_handle(), data_handle()) ->
    {ok, data_handle()} | {error, term()}.
local_call(App, Param) when is_reference(App), is_reference(Param) ->
    wrap_handle(lingofuse_nif:local_call(App, Param));
local_call(_, _) ->
    error(badarg).

-spec local_notify(app_handle(), data_handle()) -> ok | {error, term()}.
local_notify(App, Param) when is_reference(App), is_reference(Param) ->
    normalize_ok(lingofuse_nif:local_notify(App, Param));
local_notify(_, _) ->
    error(badarg).

-spec reset_prepare() -> ok | {error, term()}.
reset_prepare() ->
    normalize_ok(lingofuse_nif:reset_prepare()).

-spec prepare_service(endpoint(), endpoint()) ->
    {ok, integer()} | {error, term()}.
prepare_service(Listen, Physics)
        when is_binary(Listen), is_binary(Physics) ->
    normalize_ok(lingofuse_nif:prepare_service(Listen, Physics));
prepare_service(_, _) ->
    error(badarg).

-spec prepare_client(endpoint()) -> {ok, integer()} | {error, term()}.
prepare_client(Addr) ->
    prepare_client(Addr, undefined).

-spec prepare_client(endpoint(), app_handle() | undefined) ->
    {ok, integer()} | {error, term()}.
prepare_client(Addr, App)
        when is_binary(Addr), is_reference(App) ->
    normalize_ok(lingofuse_nif:prepare_client(Addr, App));
prepare_client(Addr, undefined) when is_binary(Addr) ->
    normalize_ok(lingofuse_nif:prepare_client(Addr, undefined));
prepare_client(_, _) ->
    error(badarg).

-spec prepare_done() -> {ok, integer()} | {error, term()}.
prepare_done() ->
    normalize_ok(lingofuse_nif:prepare_done()).

-spec exit_main_thread() -> ok | {error, term()}.
exit_main_thread() ->
    normalize_ok(lingofuse_nif:exit_main_thread()).

-spec call(app_name(), data_handle()) ->
    {ok, data_handle()} | {error, term()}.
call(App, Param) ->
    call(App, Param, ?CALL_DEFAULT_TIMEOUT_MS).

-spec call(app_name(), data_handle(), timeout_ms()) ->
    {ok, data_handle()} | {error, term()}.
call(App, Param, Timeout)
        when is_binary(App), is_reference(Param),
             is_integer(Timeout), Timeout >= 0 ->
    wrap_handle(lingofuse_nif:call(App, Param, Timeout));
call(_, _, _) ->
    error(badarg).

-spec notify(app_name(), data_handle()) -> ok | {error, term()}.
notify(App, Param) when is_binary(App), is_reference(Param) ->
    normalize_ok(lingofuse_nif:notify(App, Param));
notify(_, _) ->
    error(badarg).

-spec sequenced_notify(app_name(), data_handle()) ->
    ok | {error, term()}.
sequenced_notify(App, Param) when is_binary(App), is_reference(Param) ->
    normalize_ok(lingofuse_nif:sequenced_notify(App, Param));
sequenced_notify(_, _) ->
    error(badarg).

-spec uid_call(uid(), data_handle()) ->
    {ok, data_handle()} | {error, term()}.
uid_call(Uid, Param) ->
    uid_call(Uid, Param, ?CALL_DEFAULT_TIMEOUT_MS).

-spec uid_call(uid(), data_handle(), timeout_ms()) ->
    {ok, data_handle()} | {error, term()}.
uid_call(Uid, Param, Timeout)
        when is_binary(Uid), is_reference(Param),
             is_integer(Timeout), Timeout >= 0 ->
    wrap_handle(lingofuse_nif:uid_call(Uid, Param, Timeout));
uid_call(_, _, _) ->
    error(badarg).

-spec uid_notify(uid(), data_handle()) -> ok | {error, term()}.
uid_notify(Uid, Param) when is_binary(Uid), is_reference(Param) ->
    normalize_ok(lingofuse_nif:uid_notify(Uid, Param));
uid_notify(_, _) ->
    error(badarg).

-spec uid_sequenced_notify(uid(), data_handle()) ->
    ok | {error, term()}.
uid_sequenced_notify(Uid, Param)
        when is_binary(Uid), is_reference(Param) ->
    normalize_ok(lingofuse_nif:uid_sequenced_notify(Uid, Param));
uid_sequenced_notify(_, _) ->
    error(badarg).

-spec p2pname_call(p2p_name(), data_handle()) ->
    {ok, data_handle()} | {error, term()}.
p2pname_call(Name, Param) ->
    p2pname_call(Name, Param, ?CALL_DEFAULT_TIMEOUT_MS).

-spec p2pname_call(p2p_name(), data_handle(), timeout_ms()) ->
    {ok, data_handle()} | {error, term()}.
p2pname_call(Name, Param, Timeout)
        when is_binary(Name), is_reference(Param),
             is_integer(Timeout), Timeout >= 0 ->
    wrap_handle(lingofuse_nif:p2pname_call(Name, Param, Timeout));
p2pname_call(_, _, _) ->
    error(badarg).

-spec p2pname_notify(p2p_name(), data_handle()) -> ok | {error, term()}.
p2pname_notify(Name, Param) when is_binary(Name), is_reference(Param) ->
    normalize_ok(lingofuse_nif:p2pname_notify(Name, Param));
p2pname_notify(_, _) ->
    error(badarg).

-spec p2pname_sequenced_notify(p2p_name(), data_handle()) ->
    ok | {error, term()}.
p2pname_sequenced_notify(Name, Param)
        when is_binary(Name), is_reference(Param) ->
    normalize_ok(lingofuse_nif:p2pname_sequenced_notify(Name, Param));
p2pname_sequenced_notify(_, _) ->
    error(badarg).

-spec async_call(app_name(), api_name(), term(), async_callback()) -> ok.
async_call(Target, Api, Payload, Fun) ->
    async_call(Target, Api, Payload, Fun, ?ASYNC_DEFAULT_TIMEOUT_MS).

-spec async_call(app_name(), api_name(), term(), async_callback(),
                 async_timeout()) -> ok.
async_call(Target, Api, Payload, Fun, Timeout)
        when is_binary(Target), is_binary(Api), is_function(Fun, 1) ->
    _ = spawn(fun() ->
        run_async_worker(
          fun(Pid) ->
              case as_data_handle(Api, Payload) of
                  {ok, Hnd} ->
                      R = lingofuse_nif:async_call(Target, Hnd, Pid),
                      {R, Hnd};
                  {error, E} ->
                      {{error, E}, undefined}
              end
          end,
          Fun,
          Timeout)
    end),
    ok;
async_call(_, _, _, _, _) ->
    error(badarg).

-spec async_call_seq(app_name(), api_name(), term(), async_callback()) -> ok.
async_call_seq(Target, Api, Payload, Fun) ->
    async_call_seq(Target, Api, Payload, Fun, ?ASYNC_DEFAULT_TIMEOUT_MS).

-spec async_call_seq(app_name(), api_name(), term(), async_callback(),
                     async_timeout()) -> ok.
async_call_seq(Target, Api, Payload, Fun, Timeout)
        when is_binary(Target), is_binary(Api), is_function(Fun, 1) ->
    _ = spawn(fun() ->
        run_async_worker(
          fun(Pid) ->
              case as_data_handle(Api, Payload) of
                  {ok, Hnd} ->
                      R = lingofuse_nif:async_sequenced_call(Target, Hnd, Pid),
                      {R, Hnd};
                  {error, E} ->
                      {{error, E}, undefined}
              end
          end,
          Fun,
          Timeout)
    end),
    ok;
async_call_seq(_, _, _, _, _) ->
    error(badarg).

-spec async_uid_call(uid(), api_name(), term(), async_callback()) -> ok.
async_uid_call(Uid, Api, Payload, Fun) ->
    async_uid_call(Uid, Api, Payload, Fun, ?ASYNC_DEFAULT_TIMEOUT_MS).

-spec async_uid_call(uid(), api_name(), term(), async_callback(),
                     async_timeout()) -> ok.
async_uid_call(Uid, Api, Payload, Fun, Timeout)
        when is_binary(Uid), is_binary(Api), is_function(Fun, 1) ->
    _ = spawn(fun() ->
        run_async_worker(
          fun(Pid) ->
              case as_data_handle(Api, Payload) of
                  {ok, Hnd} ->
                      R = lingofuse_nif:uid_async_call(Uid, Hnd, Pid),
                      {R, Hnd};
                  {error, E} ->
                      {{error, E}, undefined}
              end
          end,
          Fun,
          Timeout)
    end),
    ok;
async_uid_call(_, _, _, _, _) ->
    error(badarg).

-spec async_uid_call_seq(uid(), api_name(), term(), async_callback()) -> ok.
async_uid_call_seq(Uid, Api, Payload, Fun) ->
    async_uid_call_seq(Uid, Api, Payload, Fun, ?ASYNC_DEFAULT_TIMEOUT_MS).

-spec async_uid_call_seq(uid(), api_name(), term(), async_callback(),
                         async_timeout()) -> ok.
async_uid_call_seq(Uid, Api, Payload, Fun, Timeout)
        when is_binary(Uid), is_binary(Api), is_function(Fun, 1) ->
    _ = spawn(fun() ->
        run_async_worker(
          fun(Pid) ->
              case as_data_handle(Api, Payload) of
                  {ok, Hnd} ->
                      R = lingofuse_nif:uid_async_sequenced_call(Uid, Hnd, Pid),
                      {R, Hnd};
                  {error, E} ->
                      {{error, E}, undefined}
              end
          end,
          Fun,
          Timeout)
    end),
    ok;
async_uid_call_seq(_, _, _, _, _) ->
    error(badarg).

-spec async_p2pname_call(p2p_name(), api_name(), term(),
                         async_callback()) -> ok.
async_p2pname_call(Name, Api, Payload, Fun) ->
    async_p2pname_call(Name, Api, Payload, Fun,
                       ?ASYNC_DEFAULT_TIMEOUT_MS).

-spec async_p2pname_call(p2p_name(), api_name(), term(),
                         async_callback(), async_timeout()) -> ok.
async_p2pname_call(Name, Api, Payload, Fun, Timeout)
        when is_binary(Name), is_binary(Api), is_function(Fun, 1) ->
    _ = spawn(fun() ->
        run_async_worker(
          fun(Pid) ->
              case as_data_handle(Api, Payload) of
                  {ok, Hnd} ->
                      R = lingofuse_nif:p2pname_async_call(Name, Hnd, Pid),
                      {R, Hnd};
                  {error, E} ->
                      {{error, E}, undefined}
              end
          end,
          Fun,
          Timeout)
    end),
    ok;
async_p2pname_call(_, _, _, _, _) ->
    error(badarg).

-spec async_p2pname_call_seq(p2p_name(), api_name(), term(),
                             async_callback()) -> ok.
async_p2pname_call_seq(Name, Api, Payload, Fun) ->
    async_p2pname_call_seq(Name, Api, Payload, Fun,
                           ?ASYNC_DEFAULT_TIMEOUT_MS).

-spec async_p2pname_call_seq(p2p_name(), api_name(), term(),
                             async_callback(), async_timeout()) -> ok.
async_p2pname_call_seq(Name, Api, Payload, Fun, Timeout)
        when is_binary(Name), is_binary(Api), is_function(Fun, 1) ->
    _ = spawn(fun() ->
        run_async_worker(
          fun(Pid) ->
              case as_data_handle(Api, Payload) of
                  {ok, Hnd} ->
                      R = lingofuse_nif:p2pname_async_sequenced_call(
                            Name, Hnd, Pid),
                      {R, Hnd};
                  {error, E} ->
                      {{error, E}, undefined}
              end
          end,
          Fun,
          Timeout)
    end),
    ok;
async_p2pname_call_seq(_, _, _, _, _) ->
    error(badarg).

-spec async_call_raw(app_name(), data_handle(), pid()) ->
    {ok, async_ref()} | {error, term()}.
async_call_raw(Target, Param, ReplyPid)
        when is_binary(Target), is_reference(Param), is_pid(ReplyPid) ->
    normalize_async_ref(
      lingofuse_nif:async_call(Target, Param, ReplyPid));
async_call_raw(_, _, _) ->
    error(badarg).

-spec async_call_seq_raw(app_name(), data_handle(), pid()) ->
    {ok, async_ref()} | {error, term()}.
async_call_seq_raw(Target, Param, ReplyPid)
        when is_binary(Target), is_reference(Param), is_pid(ReplyPid) ->
    normalize_async_ref(
      lingofuse_nif:async_sequenced_call(Target, Param, ReplyPid));
async_call_seq_raw(_, _, _) ->
    error(badarg).

-spec async_uid_call_raw(uid(), data_handle(), pid()) ->
    {ok, async_ref()} | {error, term()}.
async_uid_call_raw(Uid, Param, ReplyPid)
        when is_binary(Uid), is_reference(Param), is_pid(ReplyPid) ->
    normalize_async_ref(
      lingofuse_nif:uid_async_call(Uid, Param, ReplyPid));
async_uid_call_raw(_, _, _) ->
    error(badarg).

-spec async_uid_call_seq_raw(uid(), data_handle(), pid()) ->
    {ok, async_ref()} | {error, term()}.
async_uid_call_seq_raw(Uid, Param, ReplyPid)
        when is_binary(Uid), is_reference(Param), is_pid(ReplyPid) ->
    normalize_async_ref(
      lingofuse_nif:uid_async_sequenced_call(Uid, Param, ReplyPid));
async_uid_call_seq_raw(_, _, _) ->
    error(badarg).

-spec async_p2pname_call_raw(p2p_name(), data_handle(), pid()) ->
    {ok, async_ref()} | {error, term()}.
async_p2pname_call_raw(Name, Param, ReplyPid)
        when is_binary(Name), is_reference(Param), is_pid(ReplyPid) ->
    normalize_async_ref(
      lingofuse_nif:p2pname_async_call(Name, Param, ReplyPid));
async_p2pname_call_raw(_, _, _) ->
    error(badarg).

-spec async_p2pname_call_seq_raw(p2p_name(), data_handle(), pid()) ->
    {ok, async_ref()} | {error, term()}.
async_p2pname_call_seq_raw(Name, Param, ReplyPid)
        when is_binary(Name), is_reference(Param), is_pid(ReplyPid) ->
    normalize_async_ref(
      lingofuse_nif:p2pname_async_sequenced_call(Name, Param, ReplyPid));
async_p2pname_call_seq_raw(_, _, _) ->
    error(badarg).

-spec set_option(binary(), binary()) -> ok | {error, term()}.
set_option(Opt, Val) when is_binary(Opt), is_binary(Val) ->
    normalize_ok(lingofuse_nif:set_option(Opt, Val));
set_option(_, _) ->
    error(badarg).

-spec get_option(binary()) -> {ok, binary()} | {error, term()}.
get_option(Opt) when is_binary(Opt) ->
    normalize_ok(lingofuse_nif:get_option(Opt));
get_option(_) ->
    error(badarg).

-spec set_opt_password(binary() | string()) -> ok.
set_opt_password(V) when is_binary(V) ->
    set_option(<<"password">>, V);
set_opt_password(V) when is_list(V) ->
    set_option(<<"password">>, unicode:characters_to_binary(V));
set_opt_password(_) ->
    error(badarg).

-spec get_opt_password() -> binary().
get_opt_password() ->
    raw_get_option(<<"password">>).

-spec set_opt_debug(binary() | string()) -> ok.
set_opt_debug(V) when is_binary(V) ->
    set_option(<<"debug">>, V);
set_opt_debug(V) when is_list(V) ->
    set_option(<<"debug">>, unicode:characters_to_binary(V));
set_opt_debug(_) ->
    error(badarg).

-spec get_opt_debug() -> binary().
get_opt_debug() ->
    raw_get_option(<<"debug">>).

-spec set_opt_quiet(boolean()) -> ok.
set_opt_quiet(true)  -> set_option(<<"Quiet">>, <<"True">>);
set_opt_quiet(false) -> set_option(<<"Quiet">>, <<"False">>);
set_opt_quiet(_)     -> error(badarg).

-spec get_opt_quiet() -> boolean().
get_opt_quiet() ->
    raw_get_bool(<<"Quiet">>).

-spec set_opt_show_thread_id(boolean()) -> ok.
set_opt_show_thread_id(true)  ->
    set_option(<<"ShowThreadID">>, <<"True">>);
set_opt_show_thread_id(false) ->
    set_option(<<"ShowThreadID">>, <<"False">>);
set_opt_show_thread_id(_) ->
    error(badarg).

-spec get_opt_show_thread_id() -> boolean().
get_opt_show_thread_id() ->
    raw_get_bool(<<"ShowThreadID">>).

-spec set_opt_console_output(boolean()) -> ok.
set_opt_console_output(true)  ->
    set_option(<<"ConsoleOutput">>, <<"True">>);
set_opt_console_output(false) ->
    set_option(<<"ConsoleOutput">>, <<"False">>);
set_opt_console_output(_) ->
    error(badarg).

-spec get_opt_console_output() -> boolean().
get_opt_console_output() ->
    raw_get_bool(<<"ConsoleOutput">>).

-spec set_opt_overlap_connection(boolean()) -> ok.
set_opt_overlap_connection(true)  ->
    set_option(<<"Overlap_Connection">>, <<"True">>);
set_opt_overlap_connection(false) ->
    set_option(<<"Overlap_Connection">>, <<"False">>);
set_opt_overlap_connection(_) ->
    error(badarg).

-spec get_opt_overlap_connection() -> boolean().
get_opt_overlap_connection() ->
    raw_get_bool(<<"Overlap_Connection">>).

-spec set_opt_wait_connection_ready_ok(boolean()) -> ok.
set_opt_wait_connection_ready_ok(true)  ->
    set_option(<<"Wait_Connection_ReadyOk">>, <<"True">>);
set_opt_wait_connection_ready_ok(false) ->
    set_option(<<"Wait_Connection_ReadyOk">>, <<"False">>);
set_opt_wait_connection_ready_ok(_) ->
    error(badarg).

-spec get_opt_wait_connection_ready_ok() -> boolean().
get_opt_wait_connection_ready_ok() ->
    raw_get_bool(<<"Wait_Connection_ReadyOk">>).

-spec set_opt_wait_connection_timeout(non_neg_integer()) -> ok.
set_opt_wait_connection_timeout(V) when is_integer(V), V >= 0 ->
    set_option(<<"Wait_Connection_Timeout">>, integer_to_binary(V));
set_opt_wait_connection_timeout(_) ->
    error(badarg).

-spec get_opt_wait_connection_timeout() -> non_neg_integer().
get_opt_wait_connection_timeout() ->
    raw_get_u64(<<"Wait_Connection_Timeout">>).

-spec set_opt_ipc_serv_thread_count(integer()) -> ok.
set_opt_ipc_serv_thread_count(V) when is_integer(V) ->
    set_option(<<"IPC_Serv_ThreadCount">>, integer_to_binary(V));
set_opt_ipc_serv_thread_count(_) ->
    error(badarg).

-spec get_opt_ipc_serv_thread_count() -> integer().
get_opt_ipc_serv_thread_count() ->
    raw_get_int(<<"IPC_Serv_ThreadCount">>).

-spec set_opt_ipc_serv_max_queue_length(integer()) -> ok.
set_opt_ipc_serv_max_queue_length(V) when is_integer(V) ->
    set_option(<<"IPC_Serv_MaxQueueLength">>, integer_to_binary(V));
set_opt_ipc_serv_max_queue_length(_) ->
    error(badarg).

-spec get_opt_ipc_serv_max_queue_length() -> integer().
get_opt_ipc_serv_max_queue_length() ->
    raw_get_int(<<"IPC_Serv_MaxQueueLength">>).

-spec set_opt_ipc_serv_max_msg_size(integer()) -> ok.
set_opt_ipc_serv_max_msg_size(V) when is_integer(V) ->
    set_option(<<"IPC_Serv_MaxMsgSize">>, integer_to_binary(V));
set_opt_ipc_serv_max_msg_size(_) ->
    error(badarg).

-spec get_opt_ipc_serv_max_msg_size() -> integer().
get_opt_ipc_serv_max_msg_size() ->
    raw_get_int(<<"IPC_Serv_MaxMsgSize">>).

-spec set_opt_fixed_sequenced_time(non_neg_integer()) -> ok.
set_opt_fixed_sequenced_time(V) when is_integer(V), V >= 0 ->
    set_option(<<"Fixed_Sequenced_Time">>, integer_to_binary(V));
set_opt_fixed_sequenced_time(_) ->
    error(badarg).

-spec get_opt_fixed_sequenced_time() -> non_neg_integer().
get_opt_fixed_sequenced_time() ->
    raw_get_u64(<<"Fixed_Sequenced_Time">>).

-spec set_opt_p2p_name(binary() | string()) -> ok.
set_opt_p2p_name(V) when is_binary(V) ->
    set_option(<<"LF_P2P_name">>, V);
set_opt_p2p_name(V) when is_list(V) ->
    set_option(<<"LF_P2P_name">>, unicode:characters_to_binary(V));
set_opt_p2p_name(_) ->
    error(badarg).

-spec get_opt_p2p_name() -> binary().
get_opt_p2p_name() ->
    raw_get_option(<<"LF_P2P_name">>).

-spec set_opt_data_handle_idle_timeout(non_neg_integer()) -> ok.
set_opt_data_handle_idle_timeout(V) when is_integer(V), V >= 0 ->
    set_option(<<"DataHandle_Idle_Timeout">>, integer_to_binary(V));
set_opt_data_handle_idle_timeout(_) ->
    error(badarg).

-spec get_opt_data_handle_idle_timeout() -> non_neg_integer().
get_opt_data_handle_idle_timeout() ->
    raw_get_u64(<<"DataHandle_Idle_Timeout">>).

-spec set_opt_data_handle_pool_scan_interval(non_neg_integer()) -> ok.
set_opt_data_handle_pool_scan_interval(V)
        when is_integer(V), V >= 0 ->
    set_option(<<"DataHandle_Pool_Scan_Interval">>,
               integer_to_binary(V));
set_opt_data_handle_pool_scan_interval(_) ->
    error(badarg).

-spec get_opt_data_handle_pool_scan_interval() -> non_neg_integer().
get_opt_data_handle_pool_scan_interval() ->
    raw_get_u64(<<"DataHandle_Pool_Scan_Interval">>).

-spec set_opt_no_reponse_cmd_null_flush_threshold(integer()) -> ok.
set_opt_no_reponse_cmd_null_flush_threshold(V)
        when is_integer(V) ->
    set_option(<<"No_Reponse_Cmd_NULL_Flush_Threshold">>,
               integer_to_binary(V));
set_opt_no_reponse_cmd_null_flush_threshold(_) ->
    error(badarg).

-spec get_opt_no_reponse_cmd_null_flush_threshold() -> integer().
get_opt_no_reponse_cmd_null_flush_threshold() ->
    raw_get_int(<<"No_Reponse_Cmd_NULL_Flush_Threshold">>).

-spec post_status(binary()) -> ok | {error, term()}.
post_status(Status) when is_binary(Status) ->
    normalize_ok(lingofuse_nif:post_status(Status));
post_status(_) ->
    error(badarg).

-spec get_status() -> {ok, binary()} | {error, term()}.
get_status() ->
    normalize_ok(lingofuse_nif:get_status()).

-spec get_status_count() -> {ok, integer()} | {error, term()}.
get_status_count() ->
    normalize_ok(lingofuse_nif:get_status_count()).

-spec check_main_thread() -> {ok, boolean()} | {error, term()}.
check_main_thread() ->
    normalize_ok(lingofuse_nif:check_main_thread()).

-spec check_app(app_name()) -> {ok, boolean()} | {error, term()}.
check_app(App) when is_binary(App) ->
    normalize_ok(lingofuse_nif:check_app(App));
check_app(_) ->
    error(badarg).

-spec check_api(app_name(), api_name()) -> {ok, boolean()} | {error, term()}.
check_api(App, Api) when is_binary(App), is_binary(Api) ->
    normalize_ok(lingofuse_nif:check_api(App, Api));
check_api(_, _) ->
    error(badarg).

-spec check_uid(uid()) -> {ok, boolean()} | {error, term()}.
check_uid(Uid) when is_binary(Uid) ->
    normalize_ok(lingofuse_nif:check_uid(Uid));
check_uid(_) ->
    error(badarg).

-spec check_uid_api(uid(), api_name()) ->
    {ok, boolean()} | {error, term()}.
check_uid_api(Uid, Api) when is_binary(Uid), is_binary(Api) ->
    normalize_ok(lingofuse_nif:check_uid_api(Uid, Api));
check_uid_api(_, _) ->
    error(badarg).

-spec check_p2pname(p2p_name()) -> {ok, boolean()} | {error, term()}.
check_p2pname(Name) when is_binary(Name) ->
    normalize_ok(lingofuse_nif:check_p2pname(Name));
check_p2pname(_) ->
    error(badarg).

-spec check_p2pname_api(p2p_name(), api_name()) ->
    {ok, boolean()} | {error, term()}.
check_p2pname_api(Name, Api) when is_binary(Name), is_binary(Api) ->
    normalize_ok(lingofuse_nif:check_p2pname_api(Name, Api));
check_p2pname_api(_, _) ->
    error(badarg).

-spec get_self_uid() ->
    {ok, uid()} | {error, no_client | not_supported | lf_not_loaded | term()}.
get_self_uid() ->
    try lingofuse_nif:get_self_uid() of
        Bin when is_binary(Bin), byte_size(Bin) =:= 32 ->
            case is_all_zero(Bin) of
                true  -> {error, no_client};
                false -> {ok, Bin}
            end;
        {error, _} = Err ->
            Err;
        Other ->
            {error, {unexpected_return, Other}}
    catch
        error:{not_loaded, _} -> {error, lf_not_loaded};
        error:undef           -> {error, lf_not_loaded}
    end.

-spec get_self_uid_hex() ->
    {ok, binary()} | {error, no_client | not_supported | lf_not_loaded | term()}.
get_self_uid_hex() ->
    case get_self_uid() of
        {ok, Bin}      -> {ok, binary:encode_hex(Bin)};
        {error, _} = E -> E
    end.

-spec shutdown() -> ok | {error, term()}.
shutdown() ->
    normalize_ok(lingofuse_nif:shutdown()).

-spec set_network_event(pid() | undefined, pid() | undefined) ->
    ok | {error, term()}.
set_network_event(Connect, Disconnect)
        when is_pid(Connect), is_pid(Disconnect) ->
    normalize_ok(
      lingofuse_nif:set_network_event(Connect, Disconnect));
set_network_event(Connect, undefined) when is_pid(Connect) ->
    normalize_ok(
      lingofuse_nif:set_network_event(Connect, undefined));
set_network_event(undefined, Disconnect) when is_pid(Disconnect) ->
    normalize_ok(
      lingofuse_nif:set_network_event(undefined, Disconnect));
set_network_event(undefined, undefined) ->
    normalize_ok(
      lingofuse_nif:set_network_event(undefined, undefined));
set_network_event(_, _) ->
    error(badarg).

write_fixed(Hnd, Bin) ->
    Expected = byte_size(Bin),
    case write_buffer(Hnd, Bin) of
        {ok, N} when N =:= Expected -> ok;
        {ok, _}                     -> {error, short_write};
        {error, _} = E              -> E
    end.

read_fixed(Hnd, Count, Decoder) ->
    case read_buffer(Hnd, Count) of
        {ok, Bin} when byte_size(Bin) =:= Count ->
            Decoder(Bin);
        {ok, _} ->
            {error, truncated};
        {error, _} = E ->
            E
    end.

wrap_handle(Value) ->
    try
        case Value of
            {error, _} = Err               -> Err;
            Term when is_reference(Term)   -> {ok, Term};
            Term                           -> {ok, Term}
        end
    catch
        error:{not_loaded, _} -> {error, lf_not_loaded}
    end.

normalize_ok(Value) ->
    try
        case Value of
            ok             -> ok;
            {error, _} = E -> E;
            Term           -> {ok, Term}
        end
    catch
        error:{not_loaded, _} -> {error, lf_not_loaded}
    end.

normalize_async_ref(Value) ->
    try
        case Value of
            {error, _} = E                    -> E;
            Ref when is_integer(Ref), Ref > 0 -> {ok, Ref};
            Other -> {error, {unexpected_return, Other}}
        end
    catch
        error:{not_loaded, _} -> {error, lf_not_loaded}
    end.

raw_get_option(Name) ->
    case lingofuse_nif:get_option(Name) of
        Bin when is_binary(Bin) -> Bin;
        {error, _}              -> <<>>;
        _                       -> <<>>
    end.

raw_get_bool(Name) ->
    case raw_get_option(Name) of
        <<"True">>  -> true;
        <<"true">>  -> true;
        <<"TRUE">>  -> true;
        <<"1">>     -> true;
        <<"Yes">>   -> true;
        <<"yes">>   -> true;
        <<"On">>    -> true;
        <<"on">>    -> true;
        _           -> false
    end.

raw_get_u64(Name) ->
    raw_get_integer(Name, 0).

raw_get_int(Name) ->
    raw_get_integer(Name, 0).

raw_get_integer(Name, Default) ->
    Bin = raw_get_option(Name),
    try
        binary_to_integer(Bin)
    catch
        _:_ -> Default
    end.

as_data_handle(Api, Payload) ->
    case create_data(Api) of
        {ok, Hnd} ->
            case lingofuse_json:write_json(Hnd, Payload) of
                ok ->
                    {ok, Hnd};
                {error, Reason} ->
                    _ = free_data(Hnd),
                    {error, {payload_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {handle_failed, Reason}}
    end.

run_async_worker(Issue, Fun, Timeout) ->
    {NifResult, Hnd} =
        try Issue(self())
        catch
            C:R ->
                {{error, {C, R}}, undefined}
        end,
    try
        dispatch_async_result(NifResult, Fun, Timeout)
    after
        case Hnd of
            undefined -> ok;
            _         -> _ = free_data(Hnd)
        end
    end.

dispatch_async_result(Ref, Fun, Timeout) when is_integer(Ref), Ref > 0 ->
    receive
        {lf_async_result, Ref, Result} ->
            safe_call(Fun, Result);
        {lf_async_result, _Other, _} ->
            safe_call(Fun, {error, ref_mismatch})
    after timeout_to_ms(Timeout) ->
        safe_call(Fun, {error, timeout})
    end;
dispatch_async_result({error, Reason}, Fun, _Timeout) ->
    safe_call(Fun, {error, Reason});
dispatch_async_result(Other, Fun, _Timeout) ->
    safe_call(Fun, {error, {unexpected_return, Other}}).

safe_call(Fun, Result) ->
    try Fun(Result) catch _:_ -> ok end.

timeout_to_ms(infinity) -> infinity;
timeout_to_ms(N) when is_integer(N), N >= 0 -> N;
timeout_to_ms(_) -> ?ASYNC_DEFAULT_TIMEOUT_MS.

is_all_zero(Bin) when is_binary(Bin) ->
    is_all_zero_loop(Bin, 0).

is_all_zero_loop(Bin, Pos) when Pos >= byte_size(Bin) ->
    true;
is_all_zero_loop(Bin, Pos) ->
    case binary:at(Bin, Pos) of
        0 -> is_all_zero_loop(Bin, Pos + 1);
        _ -> false
    end.