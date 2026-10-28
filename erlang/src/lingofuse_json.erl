-module(lingofuse_json).

-on_load(ensure_otp_version/0).

-export([
    dumps/1,
    loads/1,
    write_json/2,
    read_json/1,
    read_json_or_bytes/1,
    cstr/1
]).

-export_type([json_read_error/0]).

-type json_read_error() ::
    {invalid_json, binary()}
    | {invalid_utf8, binary()}.

ensure_otp_version() ->
    case code:ensure_loaded(json) of
        {module, json} ->
            ok;
        {error, _Reason} ->
            logger:error(
              "[lingofuse_json] this module requires OTP 27 or later "
              "(the built-in `json` module is not available).", []),
            erlang:error({lingofuse_json, requires_otp_27_or_later})
    end.

-spec dumps(term()) -> binary().
dumps(Term) ->
    iolist_to_binary(json:encode(Term)).

-spec loads(binary()) -> term().
loads(Bin) when is_binary(Bin) ->
    json:decode(strip_trailing_nul(Bin)).

strip_trailing_nul(<<>>) ->
    <<>>;
strip_trailing_nul(Bin) ->
    case binary:last(Bin) of
        0 -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.

-spec write_json(lingofuse:data_handle(), term()) ->
    ok | {error, term()}.
write_json(Hnd, Term) ->
    Payload = dumps(Term),
    case lingofuse:write_string_bytes(Hnd, Payload) of
        ok             -> ok;
        {error, _} = E -> E
    end.

-spec read_json(lingofuse:data_handle()) -> term() | undefined.
read_json(Hnd) ->
    case read_nul_framed(Hnd) of
        {ok, Bin} ->
            try loads(Bin) of
                Term -> Term
            catch
                error:_ -> error({invalid_json, Bin})
            end;
        {error, eof} ->
            undefined;
        {error, Reason} ->
            erlang:error({lf_io_error, Reason})
    end.

-spec read_json_or_bytes(lingofuse:data_handle()) ->
    term() | binary() | undefined.
read_json_or_bytes(Hnd) ->
    case read_nul_framed(Hnd) of
        {ok, Bin} ->
            try
                loads(Bin)
            catch
                error:_ -> Bin
            end;
        {error, eof} ->
            undefined;
        {error, Reason} ->
            erlang:error({lf_io_error, Reason})
    end.

-spec cstr(binary() | string() | atom()) -> binary().
cstr(Bin) when is_binary(Bin) ->
    Bin;
cstr(Str) when is_list(Str) ->
    case unicode:characters_to_binary(Str, unicode, utf8) of
        Bin when is_binary(Bin) -> Bin;
        {error, _, _} -> error(badarg);
        {incomplete, _, _} -> error(badarg)
    end;
cstr(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
cstr(_) ->
    error(badarg).

read_nul_framed(Hnd) ->
    lingofuse:read_string_bytes(Hnd).