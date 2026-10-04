%% src/lingofuse_json.erl
%%
%% Unified JSON and string I/O for the LingoFuse Erlang binding.
%%
%% This module is the SINGLE place in the Erlang toolchain where
%% Erlang terms are converted to, and from, the bytes carried by a
%% LingoFuse DataHandle. Every service that touches a DataHandle
%% MUST use the helpers defined here instead of calling json:encode
%% / json:decode / lingofuse:write_buffer / lingofuse:read_buffer
%% directly.
%%
%% Wire format
%% -----------
%% A JSON payload on a DataHandle is:
%%
%%     [UTF-8 encoded JSON text][NUL byte]
%%
%% A plain-text payload uses the same framing:
%%
%%     [UTF-8 text][NUL byte]
%%
%% A raw binary payload uses:
%%
%%     [arbitrary bytes][NUL byte]
%%
%% The receiving side is fault-tolerant: if no NUL is found before
%% the end of the buffer, the entire remaining buffer is consumed.
%% This makes the reader tolerant of payloads that arrive from an
%% HTTP bridge or any other producer that does not append a NUL.
%%
%% Cross-language compatibility
%% ----------------------------
%% The framing matches lingofuse_import.pas (Pascal), lf_io.hpp
%% (C++), LfIo.cs (C#), lf-io.js (JavaScript), io.rs (Rust), and
%% lingofuse.lf_io (Python) exactly. For the logical payload
%% {"a":1}, every binding emits the byte sequence
%% 7B 22 61 22 3A 31 7D 00, and every reader follows the same
%% three-case rule.
%%
%% JSON serialization policy
%% -------------------------
%% Every JSON string produced by this module goes through dumps/1,
%% which is the single source of truth for the serialization policy:
%%
%%   - Compact output: no indentation, no trailing newline.
%%   - Non-ASCII characters emitted as literal UTF-8, not as
%%     \\uXXXX escapes.
%%
%% Both properties hold for the OTP built-in json module (OTP 27+)
%% without any post-processing. This module does NOT expose an
%% option to change the policy: doing so would break the
%% byte-for-byte cross-language contract.
%%
%% Requirements
%% ------------
%% OTP 27 or later, for the built-in `json` module. On older OTP
%% releases this module fails to load with a clear error.
%%
%% Threading
%% ---------
%% All helpers are stateless. Concurrent access to the SAME
%% DataHandle must still be serialized by the caller, matching the
%% contract of lingofuse:DataHandle.
%%
%% Dependency direction
%% --------------------
%%     lingofuse (data handle, app handle)
%%         ^
%%     lingofuse_json (this module)
%%         ^
%%     user code, future server / client / bridge modules
%%
%% This module depends only on `lingofuse`. It never calls the NIF
%% module directly.

-module(lingofuse_json).

-on_load(ensure_otp_version/0).

%% Public API
-export([
    dumps/1,
    loads/1,
    write_json/2,
    read_json/1,
    read_json_or_bytes/1,
    cstr/1
]).

%% Error type used by read_json/1.
-export_type([json_read_error/0]).

-type json_read_error() ::
    {invalid_json, binary()}
    | {invalid_utf8, binary()}.

%% =========================================================================
%% OTP version check
%% =========================================================================

%% The module requires the OTP built-in `json` module, introduced in
%% OTP 27. Fail loudly at load time on older releases, rather than
%% with an obscure undef error at first call.
%%
%% `erlang:function_exported/3` cannot be used here: it returns false
%% for any module that has not yet been loaded into the VM, and the
%% `json` module is loaded lazily on first use. `code:ensure_loaded/1`
%% triggers the load and gives a definitive answer.
ensure_otp_version() ->
    case code:ensure_loaded(json) of
        {module, json} ->
            ok;
        {error, _Reason} ->
            error_logger:error_msg(
              "[lingofuse_json] this module requires OTP 27 or later "
              "(the built-in `json` module is not available).~n"),
            erlang:error({lingofuse_json, requires_otp_27_or_later})
    end.

%% =========================================================================
%% Serialization: term -> UTF-8 binary
%% =========================================================================

%% Serialize an Erlang term to a compact UTF-8 JSON binary.
%%
%% The returned binary does NOT include a trailing NUL byte. Callers
%% that want to write it to a DataHandle with the required NUL
%% terminator should use write_json/2 instead.
%%
%% The output is guaranteed to:
%%   - use compact form (no indentation, no trailing newline)
%%   - emit non-ASCII characters as literal UTF-8, never as
%%     \uXXXX escapes
%%
%% Any term that json:encode/1 accepts is accepted here. Notable
%% cases:
%%   - binary()   -> JSON string (must be valid UTF-8)
%%   - list()     -> JSON array
%%   - map()      -> JSON object (keys must be binary / atom)
%%   - integer()  -> JSON number
%%   - float()    -> JSON number
%%   - true / false / null -> JSON literal
%%   - other atoms -> JSON string (their UTF-8 name)
-spec dumps(term()) -> binary().
dumps(Term) ->
    iolist_to_binary(json:encode(Term)).

%% =========================================================================
%% Deserialization: UTF-8 binary -> term
%% =========================================================================

%% Parse a UTF-8 JSON binary into an Erlang term.
%%
%% Strict: any syntax error raises. The exception type is whatever
%% the OTP built-in json module produces; callers that want a
%% uniform error type should use read_json/1 instead, which wraps
%% the failure into {invalid_json, Bin}.
%%
%% Decoded terms follow the OTP json convention:
%%   - JSON string  -> binary() with the literal UTF-8 bytes
%%   - JSON number  -> integer() or float()
%%   - JSON object  -> map() with binary() keys
%%   - JSON array   -> list()
%%   - JSON true    -> true
%%   - JSON false   -> false
%%   - JSON null    -> null
-spec loads(binary()) -> term().
loads(Bin) when is_binary(Bin) ->
    json:decode(Bin).

%% =========================================================================
%% DataHandle I/O: NUL-framed JSON
%% =========================================================================

%% Serialize `Term` and write it to the DataHandle with a trailing NUL.
%%
%% On success returns ok. On a write failure returns {error, Reason};
%% the only failure mode currently produced by lingofuse:write_buffer
%% is a short write, which indicates a corrupt handle or out-of-memory.
-spec write_json(lingofuse:data_handle(), term()) ->
    ok | {error, term()}.
write_json(Hnd, Term) ->
    Payload = dumps(Term),
    Framed = <<Payload/binary, 0>>,
    case lingofuse:write_buffer(Hnd, Framed) of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

%% Read a NUL-framed JSON payload from the DataHandle and return the
%% decoded term.
%%
%% The payload may or may not be NUL-terminated. If a NUL is present,
%% it is treated as the end of the payload; otherwise the entire
%% remaining buffer is consumed.
%%
%% Returns the atom `undefined` when the buffer contains no bytes at
%% all. This matches the historical convention of the toolchain: an
%% empty payload means "no result". Note that a JSON `null` (the
%% four bytes `null`) decodes to the atom `null`, so the two are
%% distinguishable.
%%
%% Raises {invalid_json, Bin} if the bytes are not valid UTF-8 JSON.
-spec read_json(lingofuse:data_handle()) ->
    term() | undefined.
read_json(Hnd) ->
    case read_nul_framed(Hnd) of
        empty ->
            undefined;
        Bin ->
            try loads(Bin) of
                Term -> Term
            catch
                error:_ -> error({invalid_json, Bin})
            end
    end.

%% Read a UTF-8 payload and return either the decoded JSON term or
%% the raw bytes.
%%
%% Semantics:
%%   * Empty payload                -> undefined
%%   * Valid JSON                   -> the decoded Erlang term
%%   * Valid UTF-8 but invalid JSON -> the raw bytes
%%   * Invalid UTF-8                -> the raw bytes
%%
%% This is a deliberately lenient reader for callers that treat a
%% non-JSON response as a payload they should forward or log
%% verbatim, rather than as a protocol error.
-spec read_json_or_bytes(lingofuse:data_handle()) ->
    term() | binary() | undefined.
read_json_or_bytes(Hnd) ->
    case read_nul_framed(Hnd) of
        empty ->
            undefined;
        Bin ->
            try
                loads(Bin)
            catch
                error:_ -> Bin
            end
    end.

%% =========================================================================
%% C ABI string parameter helper
%% =========================================================================

%% Normalize a string-like value into a UTF-8 binary suitable for an
%% LF_* function that expects a `const char*` argument.
%%
%% The NIF layer appends the terminating NUL itself (see get_c_string
%% in c_src/lingofuse_nif.c), so this helper only ensures that the
%% payload is UTF-8 encoded. It does NOT append a NUL.
%%
%% Accepts:
%%   - binary()  -> returned as-is
%%   - list()    -> interpreted as a Unicode charlist, encoded to UTF-8
%%   - atom()    -> atom_to_binary with utf8
%%
%% Any other input raises badarg. The catch-all clause at the end
%% makes the error type uniform: without it, a non-matching argument
%% would raise function_clause instead of badarg.
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

%% =========================================================================
%% Internal helpers
%% =========================================================================

%% Read from the DataHandle until the first NUL (or the end of the
%% buffer). Advance the cursor past the NUL when one is found; when
%% none is found, leave the cursor at the end of the buffer.
%%
%% Returns:
%%   empty  - the cursor was already at or past the end of the buffer
%%   binary - the payload before the NUL (or the whole remaining buffer)
%%
%% The implementation matches the fault-tolerant read behaviour of
%% every other LingoFuse binding: Pascal's LF_ReadString, Python's
%% lf_io.read_string, C++'s io::read_string, C#'s LfIo.ReadString,
%% and JavaScript's lf-io.readString.
read_nul_framed(Hnd) ->
    {ok, Total} = lingofuse:get_size(Hnd),
    {ok, Pos}   = lingofuse:get_pos(Hnd),
    case Pos >= Total of
        true ->
            empty;
        false ->
            Available = Total - Pos,
            {ok, Raw} = lingofuse:read_buffer(Hnd, Available),
            case binary:match(Raw, <<0>>) of
                nomatch ->
                    %% No NUL. The cursor is already at the end of the
                    %% buffer because read_buffer advanced it by the
                    %% full Available count.
                    Raw;
                {NulPos, 1} ->
                    <<Payload:NulPos/binary, _/binary>> = Raw,
                    %% read_buffer advanced the cursor to Total. Rewind
                    %% it to just past the NUL so that a subsequent
                    %% read sees the remaining payload (if any).
                    NewPos = Pos + NulPos + 1,
                    ok = lingofuse:set_pos(Hnd, NewPos),
                    Payload
            end
    end.