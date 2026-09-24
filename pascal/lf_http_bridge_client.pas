(*
 * =============================================================================
 * lf_http_bridge_client - Pascal client for the LingoFuse HTTP bridge
 * =============================================================================
 *
 * This unit is a small function library that lets Pascal code reach
 * the outbound POST proxy and the JSON repair service registered by
 * lingofuse/bridge.py. It sends a request through LingoFuse and
 * receives a response.
 *
 * It is a LIBRARY, not a program:
 *
 *   - It does NOT prepare services or clients.
 *   - It does NOT call LF_PrepareDone, LF_ExitMainThread, or LF_Shutdown.
 *   - It does NOT create a LingoFuse App.
 *
 * The caller is responsible for having already established a
 * LingoFuse connection. In a typical deployment the caller is a
 * LingoFuse node that has completed its own LF_PrepareDone and can
 * therefore route LF_Call to the bridge by application name.
 *
 * =============================================================================
 * CONTRACTS WITH bridge.py
 * =============================================================================
 *
 * [1] Outbound POST proxy (default API name __lf_outbound_post__)
 * ---------------------------------------------------------------
 *
 * Request JSON (sent to the bridge's __lf_outbound_post__ API):
 *
 *     {
 *         "url":     "http://example.com/api",
 *         "method":  "POST",
 *         "headers": { "X-Foo": "Bar" },
 *         "body":    { "any": "json" },
 *         "timeout": 25
 *     }
 *
 * Response JSON (returned by the bridge):
 *
 *     {
 *         "status_code": 200,
 *         "headers":     { "content-type": "application/json", ... },
 *         "body":        { ... } | "raw string if not JSON"
 *     }
 *
 * Bridge-level error (returned when the bridge itself refuses the
 * request):
 *
 *     { "error": "description" }
 *
 * These shapes are defined by bridge.py's _parse_outbound_request and
 * _bridge_post_callback. This unit builds and parses them verbatim;
 * no re-interpretation is performed.
 *
 * [2] JSON repair service (default API name __lf_repair_json__)
 * -------------------------------------------------------------
 *
 * Request payload: a UTF-8 encoded JSON text, possibly malformed,
 * possibly with a UTF-8 BOM, possibly with trailing NUL bytes. The
 * Pascal side sends it as a NUL-terminated UTF-8 string via
 * LF_WriteString.
 *
 * Response payload: a UTF-8 encoded, NUL-terminated text. Its content
 * is one of the following:
 *
 *     * The repaired JSON, when the input was malformed but the
 *       bridge's repair engine could recover it.
 *     * The original text, when the input was already valid JSON
 *       (returned byte-for-byte identical).
 *     * The original text, when the input was malformed and could
 *       not be repaired.
 *     * The original raw bytes, when the input could not be decoded
 *       as text by the bridge's encoding fallback chain.
 *
 * The response is a PLAIN STRING, not a JSON envelope. Use
 * LF_ReadString to obtain it (the wrapper LFHttpRepairJson does this
 * for you).
 *
 * No-escape guarantee:
 *   The bridge invokes its repair engine with ensure_ascii=False, so
 *   the returned text NEVER contains a \uXXXX escape for a character
 *   that can be emitted literally in UTF-8. Chinese characters,
 *   emoji, and other non-ASCII content arrive as literal UTF-8
 *   bytes. This matches the toolchain-wide JSON policy defined in
 *   lingofuse.lf_io.dumps_json.
 *
 * Binary safety:
 *   The bridge's repair API is binary-safe. An undecodable payload is
 *   returned unchanged. An unrepairable but decodable payload is also
 *   returned unchanged. Neither case is a transport failure, and
 *   LFHttpRepairJson returns True for both. The caller must inspect
 *   the returned text if it needs to distinguish "already valid"
 *   from "repaired" from "returned unchanged".
 *
 * =============================================================================
 * GLOBAL VARIABLES
 * =============================================================================
 *
 * Five module-level variables control the behavior:
 *
 *   LFBridgeAppName               - LingoFuse App name of the bridge
 *   LFBridgeApiName               - LingoFuse API name of the outbound proxy
 *   LFBridgeRepairApiName         - LingoFuse API name of the repair service
 *   LFBridgeTimeoutMs             - LF_Call timeout for the whole round trip
 *   LFBridgeDefaultHttpTimeoutSec - Default HTTP timeout inside the request
 *
 * The defaults match bridge.py's own defaults. If bridge.py was
 * started with --bridge-app, --bridge-api, or --bridge-repair-api
 * overrides, set the corresponding variable before calling the
 * corresponding function.
 *
 * =============================================================================
 * ENCODING
 * =============================================================================
 *
 * All strings handled by this unit are UTF-8. The Z.Json unit emits
 * UTF-8 bytes, LF_WriteString appends the required NUL terminator,
 * LF_ReadString stops at the NUL and decodes back to a Pascal string.
 * There is no \uXXXX escaping anywhere in the pipeline.
 *
 * =============================================================================
 * THREADING
 * =============================================================================
 *
 * LF_Call is thread-safe. Multiple threads may call LFHttpCall,
 * LFHttpPost, LFHttpPostBody, or LFHttpRepairJson concurrently as
 * long as they do not share the same TZ_JsonObject request body. The
 * unit itself holds no mutable state. The five module-level
 * configuration variables are read-only after the application has
 * finished initializing them; do not modify them from multiple
 * threads at runtime.
 *
 * =============================================================================
 * COMPATIBILITY
 * =============================================================================
 *
 * Free Pascal 3.2.2+ and Delphi 2009+ on Windows, Linux, and macOS.
 * Requires the LingoFuse dynamic library and the Z-framework units
 * (Z.Core, Z.Json, Z.PascalStrings, Z.UPascalStrings).
 *)

unit lf_http_bridge_client;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$CODEPAGE UTF8}
{$endif}
{$R-}
{$H+}

interface

uses
  SysUtils,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.UnicodeMixedLib,
  Z.Json,
  lingofuse_import;

var
  (*
   * LingoFuse App name under which bridge.py registers its outbound
   * POST proxy and its JSON repair service. Default matches
   * bridge.py's --bridge-app default.
   *)
  LFBridgeAppName: string = '__lf_http_bridge__';

  (*
   * LingoFuse API name of the outbound POST proxy. Default matches
   * bridge.py's --bridge-api default.
   *)
  LFBridgeApiName: string = '__lf_outbound_post__';

  (*
   * LingoFuse API name of the JSON repair service. Default matches
   * bridge.py's --bridge-repair-api default.
   *
   * The repair API accepts a UTF-8 JSON text (possibly malformed,
   * possibly with a UTF-8 BOM, possibly with trailing NULs) and
   * returns the repaired text as a plain UTF-8 string. See the unit
   * header for the full contract.
   *)
  LFBridgeRepairApiName: string = '__lf_repair_json__';

  (*
   * Timeout, in milliseconds, for the LF_Call that carries the request
   * to the bridge and carries the response back. This must be larger
   * than the outbound HTTP timeout carried inside the request JSON,
   * otherwise the LF_Call times out before the HTTP request finishes.
   * Default 60000 ms.
   *
   * For the JSON repair API, this is the timeout for the repair
   * computation itself. Repair is a pure in-memory operation on the
   * bridge side, so the default is usually far more than enough.
   *)
  LFBridgeTimeoutMs: UInt64 = 60000;

  (*
   * Default outbound HTTP timeout, in seconds, used when the caller
   * does not supply one. Must be smaller than LFBridgeTimeoutMs / 1000.
   * Default 25 seconds.
   *
   * This variable is used only by the outbound POST proxy. The JSON
   * repair API ignores it.
   *)
  LFBridgeDefaultHttpTimeoutSec: Double = 25.0;

(* ----------------------------------------------------------------------
 * Core function: outbound HTTP POST proxy
 * ---------------------------------------------------------------------- *)

(*
 * Send an HTTP request through the LingoFuse bridge.
 *
 * Parameters:
 *   URL             Target HTTP URL. Required; must not be empty.
 *   Method          HTTP method. Empty string defaults to 'POST'. The
 *                   bridge enforces a whitelist (GET, POST, PUT,
 *                   PATCH, DELETE, HEAD, OPTIONS).
 *   RequestBodyJson Request body as a raw JSON string. Pass '' for no
 *                   body. The string must already be valid JSON; no
 *                   validation is performed here.
 *   TimeoutSeconds  Outbound HTTP timeout in seconds. Pass 0 to use
 *                   LFBridgeDefaultHttpTimeoutSec.
 *   ResponseJson    On success, receives the bridge's full response
 *                   JSON, with the shape:
 *                     {"status_code":..., "headers":{...}, "body":...}
 *                   On failure, receives ''.
 *   ErrorMsg        On failure, receives an English error description.
 *                   On success, receives ''.
 *
 * Returns True on success, False on any failure (including the case
 * where the bridge itself reports an error in the response).
 *
 * The function never raises. All native handles are released before
 * returning, on every path.
 *)
function LFHttpCall(const URL, Method, RequestBodyJson: string;
                    TimeoutSeconds: Double;
                    out ResponseJson: string;
                    out ErrorMsg: string): Boolean;

(* ----------------------------------------------------------------------
 * Convenience overloads: outbound POST proxy
 * ---------------------------------------------------------------------- *)

(*
 * POST a JSON object body and receive the parsed response.
 *
 * RequestBody  The JSON body to send. May be nil for no body. The
 *              caller retains ownership; this function does not free
 *              it.
 * Response     On success, receives the parsed bridge response. The
 *              caller owns the returned object and must free it.
 *              On failure, Response is nil.
 * ErrorMsg     On failure, receives an English error description.
 *
 * Returns True on success. If the bridge reports a top-level error,
 * returns False and writes the error text to ErrorMsg.
 *
 * The function never raises.
 *)
function LFHttpPost(const URL: string;
                    RequestBody: TZ_JsonObject;
                    out Response: TZ_JsonObject;
                    out ErrorMsg: string): Boolean;

(*
 * POST a raw JSON body and receive only the response's inner "body"
 * field, serialized back to JSON text.
 *
 * This is the highest-level convenience overload. It unwraps the
 * bridge's envelope and hands back just the payload that the remote
 * HTTP server returned. It does NOT surface the HTTP status code or
 * response headers; use LFHttpCall or LFHttpPost when you need those.
 *
 * Returns True on success. ResponseBodyJson is '' when the remote
 * server returned no body. ErrorMsg is '' on success.
 *)
function LFHttpPostBody(const URL, RequestBodyJson: string;
                        out ResponseBodyJson: string;
                        out ErrorMsg: string): Boolean;

(* ----------------------------------------------------------------------
 * Core function: JSON repair service
 * ---------------------------------------------------------------------- *)

(*
 * Repair a malformed JSON string via the bridge's __lf_repair_json__ API.
 *
 * Parameters:
 *   InputJson     The JSON text to repair. May be malformed. May or
 *                 may not be NUL-terminated; this function appends a
 *                 NUL automatically before sending.
 *
 *   RepairedJson  On success, receives the repaired JSON text.
 *
 *                 The following outcomes are all reported as SUCCESS
 *                 (i.e. the function returns True):
 *
 *                   * The input was already valid JSON.
 *                     RepairedJson equals InputJson byte-for-byte.
 *
 *                   * The input was malformed but repairable.
 *                     RepairedJson contains the repaired text. The
 *                     bridge emits one WARNING to its own log.
 *
 *                   * The input was malformed and unrepairable.
 *                     RepairedJson equals InputJson unchanged. The
 *                     bridge emits one ERROR to its own log.
 *
 *                   * The input could not be decoded as text at all
 *                     (i.e. the bridge's encoding fallback chain
 *                     UTF-8 -> GBK -> Latin-1 failed, which is
 *                     unreachable in practice). RepairedJson
 *                     contains the original raw bytes decoded as
 *                     Latin-1.
 *
 *                 On transport-level failure, RepairedJson is ''.
 *
 *   ErrorMsg      On failure, receives an English error description.
 *                 On success, receives ''.
 *
 * Returns True on success, False on any transport-level failure
 * (null handle, LF_Call timeout, empty response, native API error).
 *
 * No-escape guarantee:
 *   The bridge invokes its repair engine with ensure_ascii=False, so
 *   RepairedJson NEVER contains a \uXXXX escape for a character that
 *   can be emitted literally in UTF-8. Chinese characters, emoji,
 *   and other non-ASCII content are returned as literal UTF-8 bytes.
 *
 * Distinguishing "already valid" from "repaired":
 *   This function does NOT compare InputJson to RepairedJson. Both
 *   outcomes are legitimate successes. If the caller needs to know
 *   whether the input was modified, compare the two strings itself.
 *
 * The function never raises. The input and response DataHandle
 * objects are released before returning, on every path.
 *)
function LFHttpRepairJson(const InputJson: string;
                          out RepairedJson: string;
                          out ErrorMsg: string): Boolean;

implementation

(* ----------------------------------------------------------------------
 * Internal helpers
 * ---------------------------------------------------------------------- *)

(*
 * Serialize a TZ_JsonObject to a UTF-8 Pascal string without a NUL
 * terminator. Returns '' for nil input.
 *)
function JsonToText(Obj: TZ_JsonObject): string;
var
  Bytes: TBytes;
begin
  if Obj = nil then Exit('');
  Bytes := Obj.ToBytes;
  if Length(Bytes) = 0 then Exit('');
  Result := TEncoding.UTF8.GetString(Bytes);
end;

(*
 * Build the request JSON sent to the bridge. Fields are emitted in a
 * stable order for easier debugging. The "headers" and "body" fields
 * are omitted when empty, because bridge.py treats their absence the
 * same as an empty object.
 *)
function BuildRequestJson(const URL, Method, BodyJson: string;
                          TimeoutSeconds: Double): string;
begin
  Result := '{"url":"' + URL + '"';
  Result := Result + ',"method":"' + Method + '"';
  if BodyJson <> '' then
    Result := Result + ',"body":' + BodyJson;
  Result := Result + ',"timeout":' + IntToStr(Round(TimeoutSeconds));
  Result := Result + '}';
end;

(* ----------------------------------------------------------------------
 * LFHttpCall
 * ---------------------------------------------------------------------- *)

function LFHttpCall(const URL, Method, RequestBodyJson: string;
                    TimeoutSeconds: Double;
                    out ResponseJson: string;
                    out ErrorMsg: string): Boolean;
var
  EffectiveMethod: string;
  EffectiveTimeout: Double;
  RequestJson: string;
  ReqHandle, ResHandle: TDataHnd___;
begin
  ResponseJson := '';
  ErrorMsg := '';

  (* ---- Argument validation ---- *)
  if URL = '' then
  begin
    ErrorMsg := 'URL is empty';
    Exit(False);
  end;

  if Method = '' then
    EffectiveMethod := 'POST'
  else
    EffectiveMethod := Method;

  if TimeoutSeconds <= 0 then
    EffectiveTimeout := LFBridgeDefaultHttpTimeoutSec
  else
    EffectiveTimeout := TimeoutSeconds;

  (* ---- Build the request JSON ---- *)
  RequestJson := BuildRequestJson(URL, EffectiveMethod,
                                  RequestBodyJson, EffectiveTimeout);

  (* ---- Create the input DataHandle ---- *)
  ReqHandle := LF_CreateDataEx(LFBridgeApiName);
  if ReqHandle = nil then
  begin
    ErrorMsg := 'LF_CreateDataEx failed';
    Exit(False);
  end;

  (* ---- Send the LF_Call and release the input handle ---- *)
  try
    if not LF_WriteString(ReqHandle, RequestJson) then
    begin
      ErrorMsg := 'LF_WriteString failed';
      Exit(False);
    end;

    ResHandle := LF_CallEx(LFBridgeAppName, ReqHandle, LFBridgeTimeoutMs);
  finally
    LF_FreeData(ReqHandle);
  end;

  (* ---- Validate the response handle ---- *)
  if ResHandle = nil then
  begin
    ErrorMsg := 'LF_Call returned a null handle';
    Exit(False);
  end;

  (* ---- Read the response and release the response handle ---- *)
  try
    if LF_GetSize(ResHandle) = 0 then
    begin
      ErrorMsg := 'Bridge returned an empty response (timeout?)';
      Exit(False);
    end;
    ResponseJson := LF_ReadString(ResHandle);
  finally
    LF_FreeData(ResHandle);
  end;

  if ResponseJson = '' then
  begin
    ErrorMsg := 'Bridge returned an empty string';
    Exit(False);
  end;

  Result := True;
end;

(* ----------------------------------------------------------------------
 * LFHttpPost
 * ---------------------------------------------------------------------- *)

function LFHttpPost(const URL: string;
                    RequestBody: TZ_JsonObject;
                    out Response: TZ_JsonObject;
                    out ErrorMsg: string): Boolean;
var
  BodyJson, ResponseJson: string;
begin
  Response := nil;
  ErrorMsg := '';

  if RequestBody <> nil then
    BodyJson := JsonToText(RequestBody)
  else
    BodyJson := '';

  if not LFHttpCall(URL, 'POST', BodyJson, 0, ResponseJson, ErrorMsg) then
    Exit(False);

  (* ---- Parse the response envelope ---- *)
  Response := TZ_JsonObject.Create;
  try
    if not Response.ParseText(ResponseJson) then
    begin
      ErrorMsg := 'Failed to parse bridge response JSON';
      FreeAndNil(Response);
      Exit(False);
    end;
  except
    ErrorMsg := 'Exception while parsing bridge response JSON';
    FreeAndNil(Response);
    Exit(False);
  end;

  (* ---- Promote a bridge-level error to a False return ---- *)
  if Response.Exists('error') then
  begin
    ErrorMsg := Response.S['error'];
    FreeAndNil(Response);
    Exit(False);
  end;

  Result := True;
end;

(* ----------------------------------------------------------------------
 * LFHttpPostBody
 * ---------------------------------------------------------------------- *)

function LFHttpPostBody(const URL, RequestBodyJson: string;
                        out ResponseBodyJson: string;
                        out ErrorMsg: string): Boolean;
var
  Response: TZ_JsonObject;
  Inner: TZ_JsonObject;
begin
  ResponseBodyJson := '';
  ErrorMsg := '';

  if not LFHttpPost(URL, nil, Response, ErrorMsg) then
    Exit(False);

  try
    (*
     * The bridge's response has the shape:
     *     {"status_code":..., "headers":{...}, "body":...}
     * We unwrap "body" and serialize it back to text. A missing or
     * null body yields ''.
     *)
    Inner := Response.O['body'];
    if Inner <> nil then
      ResponseBodyJson := JsonToText(Inner);
    Result := True;
  finally
    Response.Free;
  end;
end;

(* ----------------------------------------------------------------------
 * LFHttpRepairJson
 * ---------------------------------------------------------------------- *)

function LFHttpRepairJson(const InputJson: string;
                          out RepairedJson: string;
                          out ErrorMsg: string): Boolean;
var
  ReqHandle, ResHandle: TDataHnd___;
begin
  RepairedJson := '';
  ErrorMsg := '';

  (* ------------------------------------------------------------------
   * Step 1: create the input DataHandle.
   *
   * The repair API does not require a non-empty input. An empty input
   * is a legitimate (if degenerate) request: the bridge will process
   * it and return an empty NUL-terminated payload.
   * ------------------------------------------------------------------ *)
  ReqHandle := LF_CreateDataEx(LFBridgeRepairApiName);
  if ReqHandle = nil then
  begin
    ErrorMsg := 'LF_CreateDataEx failed';
    Exit(False);
  end;

  (* ------------------------------------------------------------------
   * Step 2: write the input and issue the LF_Call.
   *
   * LF_WriteString appends the NUL terminator that the LingoFuse wire
   * protocol requires, so the bridge's read_string_bytes() sees a
   * well-framed payload. The input string is UTF-8, exactly as the
   * repair API expects.
   *
   * The input handle is released in the finally block, on every path.
   * ------------------------------------------------------------------ *)
  try
    if not LF_WriteString(ReqHandle, InputJson) then
    begin
      ErrorMsg := 'LF_WriteString failed';
      Exit(False);
    end;

    ResHandle := LF_CallEx(LFBridgeAppName, ReqHandle, LFBridgeTimeoutMs);
  finally
    LF_FreeData(ReqHandle);
  end;

  (* ------------------------------------------------------------------
   * Step 3: validate the response handle.
   * ------------------------------------------------------------------ *)
  if ResHandle = nil then
  begin
    ErrorMsg := 'LF_Call returned a null handle';
    Exit(False);
  end;

  (* ------------------------------------------------------------------
   * Step 4: read the repaired text and release the response handle.
   *
   * LF_ReadString stops at the first NUL and returns the bytes before
   * it. A completely empty payload (size = 0) means the bridge did
   * not write anything at all, which indicates a transport-level
   * failure (for example a timeout). An empty NUL-terminated payload
   * (size >= 1) is a legitimate "repaired to empty" result and is
   * treated as success.
   *
   * The response handle is released in the finally block, on every
   * path.
   * ------------------------------------------------------------------ *)
  try
    if LF_GetSize(ResHandle) = 0 then
    begin
      ErrorMsg := 'Bridge returned an empty response (timeout?)';
      Exit(False);
    end;
    RepairedJson := LF_ReadString(ResHandle);
  finally
    LF_FreeData(ResHandle);
  end;

  (*
   * NOTE on the absent "empty RepairedJson" check:
   *
   * Unlike LFHttpCall, this function does NOT treat an empty result
   * as a failure. The bridge's repair API legitimately returns an
   * empty string when the input was an empty or whitespace-only
   * payload, or when the repair engine reduced a payload to nothing.
   * Treating that outcome as a transport failure would be incorrect.
   *
   * If the caller needs to distinguish "empty result" from
   * "transport failure", it should check the return value AND the
   * RepairedJson string, in that order:
   *
   *     if not LFHttpRepairJson(input, repaired, err) then
   *       // transport-level failure
   *     else if repaired = '' then
   *       // legitimate empty result
   *     else
   *       // non-empty repaired text
   *)

  Result := True;
end;

end.