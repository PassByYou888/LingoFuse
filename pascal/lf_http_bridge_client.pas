(*
 * =============================================================================
 * lf_http_bridge_client - Pascal client for the LingoFuse HTTP Bridge
 * =============================================================================
 *
 * This unit is a small function library that lets Pascal code reach the
 * outbound POST proxy and the JSON repair service registered by the
 * LingoFuse HTTP Bridge (distributed as `bridge.py` or `bridge.exe`).
 *
 * It is a LIBRARY, not a program:
 *
 *   - It does NOT prepare services or clients.
 *   - It does NOT call LF_PrepareDone, LF_ExitMainThread, or LF_Shutdown.
 *   - It does NOT create a LingoFuse App.
 *
 * The caller is responsible for having already established a LingoFuse
 * connection. In a typical deployment the caller is a LingoFuse node
 * that has completed its own LF_PrepareDone and can therefore route
 * LF_Call to the bridge by application name.
 *
 * =============================================================================
 * WHAT THE BRIDGE IS (FOR PASCAL CALLERS)
 * =============================================================================
 *
 * The bridge is a language-neutral POST gateway for LingoFuse. It is a
 * standalone executable (`.py` or `.exe`) that lives somewhere on the
 * mesh. From the Pascal side, it is simply a LingoFuse App with two
 * useful Call APIs. Pascal code never speaks HTTP directly; it uses
 * this unit to ask the bridge to do the HTTP work on its behalf, and
 * to ask the bridge to repair malformed JSON on its behalf.
 *
 * The bridge exposes three directions. Two of them are reachable from
 * this unit:
 *
 *   Direction B (outbound, LingoFuse -> HTTP)
 *   ----------------------------------------------------------------
 *   The bridge registers a Call API, by default named
 *   `__lf_outbound_post__`. A caller sends a JSON request describing
 *   an HTTP request. The bridge performs the HTTP request and returns
 *   the HTTP response as a JSON object. This is how any Pascal service
 *   can perform an HTTP POST, PUT, GET, DELETE, etc., without needing
 *   an HTTP client library.
 *
 *   Direction C (repair, LingoFuse -> LingoFuse)
 *   ----------------------------------------------------------------
 *   The bridge registers a second Call API, by default named
 *   `__lf_repair_json__`. A caller sends a UTF-8 JSON string, possibly
 *   malformed. The bridge runs the toolchain's canonical JSON repair
 *   engine on it and returns the repaired text. This is how any Pascal
 *   service can normalize the malformed JSON that LLMs, template
 *   engines, or hand-written configs frequently produce, without
 *   vendoring a repair library of its own.
 *
 * The third direction (inbound, HTTP -> LingoFuse) is not reachable
 * from this unit. It is used by HTTP clients that want to call into
 * LingoFuse Apps; see the Bridge Knowledge Base, Chapter 3.
 *
 * =============================================================================
 * WHY THE BRIDGE AND THIS UNIT ARE A MATCHED PAIR
 * =============================================================================
 *
 * The bridge and this unit are designed to work together. The following
 * contracts must hold on both sides, or the pair will silently
 * misbehave:
 *
 * [1] The App name must match the bridge's configured App name.
 *     Bridge side: `--bridge-app` or `LINGOFUSE_BRIDGE_APP`
 *                  (default: __lf_http_bridge__)
 *     Client side: LFBridgeAppName (default: __lf_http_bridge__)
 *
 * [2] The outbound API name must match the bridge's configured name.
 *     Bridge side: `--bridge-api` or `LINGOFUSE_BRIDGE_API`
 *                  (default: __lf_outbound_post__)
 *     Client side: LFBridgeApiName (default: __lf_outbound_post__)
 *
 * [3] The repair API name must match the bridge's configured name.
 *     Bridge side: `--bridge-repair-api` or
 *                  `LINGOFUSE_BRIDGE_REPAIR_API`
 *                  (default: __lf_repair_json__)
 *     Client side: LFBridgeRepairApiName (default: __lf_repair_json__)
 *
 * [4] Both sides must agree on UTF-8. The bridge emits literal UTF-8
 *     and never produces \uXXXX escapes for characters that can be
 *     emitted literally. The Pascal side reads and writes UTF-8 via
 *     LF_WriteString / LF_ReadString (see the cross-language notes
 *     in lingofuse_import.pas, section 6, and the LF-XLANG-* entries
 *     of the Pascal Complete Guide).
 *
 * [5] The LF_Call timeout must be larger than the HTTP timeout carried
 *     inside the request JSON. Otherwise the LF_Call times out before
 *     the HTTP request finishes and the caller sees an empty response,
 *     which is indistinguishable from a genuine transport failure.
 *
 * [6] The bridge must not be unreachable at call time. The bridge's
 *     LingoFuse App is registered on the same endpoint the caller is
 *     connected to. If the caller was started with Wait_Ready=False
 *     (deployment mode) it must be prepared for the bridge to be
 *     briefly unavailable right after startup; see the retry pattern
 *     at the bottom of this header.
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
 * These shapes are defined by the bridge's request validator and the
 * outbound POST callback. This unit builds and parses them verbatim;
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
 * THREE WAYS TO USE THIS UNIT
 * =============================================================================
 *
 * (A) Highest level: send a JSON body and unwrap the response body.
 *
 *       var
 *         RespBody, Err: string;
 *       begin
 *         if LFHttpPostBody('https://api.example.com/v1/echo',
 *                           '{"msg":"hello"}',
 *                           RespBody, Err) then
 *           // RespBody contains the remote server's response body,
 *           // re-serialized as JSON text.
 *         else
 *           // Err contains an English error description.
 *       end;
 *
 * (B) Middle level: send a JSON body and receive the full envelope.
 *
 *       var
 *         RespObj: TZ_JsonObject;
 *         Err: string;
 *       begin
 *         if LFHttpPost('https://api.example.com/v1/echo',
 *                       RequestBody,   // TZ_JsonObject, may be nil
 *                       RespObj, Err) then
 *         begin
 *           // RespObj.I['status_code'], RespObj.O['headers'],
 *           // RespObj.O['body'] are all available.
 *           RespObj.Free;
 *         end
 *         else
 *           // Err contains the error text.
 *       end;
 *
 * (C) Lowest level: full control over method, headers, and timeout.
 *
 *       var
 *         RespJson, Err: string;
 *       begin
 *         if LFHttpCall('https://api.example.com/v1/echo',
 *                       'PUT',                        // explicit method
 *                       '{"msg":"hello"}',
 *                       30.0,                         // HTTP timeout
 *                       RespJson, Err) then
 *           // RespJson contains the full bridge response as a JSON
 *           // string; parse it with TZ_JsonObject.ParseText.
 *       end;
 *
 * JSON repair uses a single entry point:
 *
 *       var
 *         Repaired, Err: string;
 *       begin
 *         if LFHttpRepairJson('{''name'': ''Alice'', ''age'': 30,}',
 *                             Repaired, Err) then
 *           // Repaired = '{"name": "Alice", "age": 30}'
 *       end;
 *
 * =============================================================================
 * WHEN TO USE EACH API
 * =============================================================================
 *
 *   Use LFHttpPostBody when:
 *     - You only care about the remote server's response body.
 *     - You do not need the HTTP status code or response headers.
 *     - You want a one-liner that hides the bridge envelope.
 *
 *   Use LFHttpPost when:
 *     - You need the HTTP status code (e.g., to distinguish 200 from
 *       4xx or 5xx).
 *     - You need response headers (e.g., to read a Location header
 *       from a redirect, or a custom header).
 *     - You already have a TZ_JsonObject body and do not want to
 *       serialize it yourself.
 *
 *   Use LFHttpCall when:
 *     - You need a method other than POST (PUT, PATCH, DELETE, GET,
 *       HEAD, OPTIONS).
 *     - You need to control the outbound HTTP timeout.
 *     - You already have the request body as a raw JSON string.
 *
 *   Use LFHttpRepairJson when:
 *     - You have a JSON string that might be malformed and you want the
 *       bridge to repair it.
 *     - You are about to parse JSON produced by an LLM, a template, or
 *       any other source whose output might contain trailing commas,
 *       single quotes, or unbalanced braces.
 *
 * =============================================================================
 * THE PASCAL <-> BRIDGE WIRE PATH, END TO END
 * =============================================================================
 *
 *     Pascal string (UTF-8)
 *         |
 *         v
 *     LF_WriteString(appends NUL)  --> DataHandle buffer
 *         |
 *         v
 *     LF_Call(bridge App, handle)  --> LingoFuse mesh
 *         |
 *         v
 *     bridge App receives LF_Call on its worker thread
 *         |
 *         v
 *     bridge reads bytes up to NUL, decodes UTF-8
 *         |
 *         +-- outbound path:
 *         |     parse request JSON -> perform HTTP request ->
 *         |     build response JSON -> write UTF-8 + NUL
 *         |
 *         +-- repair path:
 *               run canonical repair engine on text ->
 *               write repaired UTF-8 + NUL
 *         |
 *         v
 *     LF_ReadString(stops at NUL)  <-- DataHandle buffer
 *         |
 *         v
 *     Pascal string (UTF-8)
 *
 * No \uXXXX escaping appears anywhere in this path. Non-ASCII
 * characters travel as literal UTF-8 bytes on the wire, and the
 * repair API's output preserves them.
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
 * The defaults match the bridge's own defaults. If the bridge was
 * started with --bridge-app, --bridge-api, or --bridge-repair-api
 * overrides, set the corresponding variable before calling the
 * corresponding function.
 *
 * Example: the bridge was started with
 *     bridge --bridge-app __my_relay__ --bridge-api __post__
 * Then the caller must set, before any call:
 *     LFBridgeAppName := '__my_relay__';
 *     LFBridgeApiName := '__post__';
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
 * The JSON documents exchanged with the bridge are UTF-8 JSON. The
 * canonical serializer in the toolchain uses ensure_ascii=False, and
 * the bridge's normalizer preserves that invariant.
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
 * COMMON PITFALLS
 * =============================================================================
 *
 *   [P1] Forgetting to configure LFBridgeAppName when the bridge was
 *        started with --bridge-app. Symptom: LF_Call returns a
 *        zero-size handle, and the caller sees "empty response".
 *
 *   [P2] Setting LFBridgeTimeoutMs smaller than the HTTP timeout. The
 *        LF_Call times out before the HTTP request completes. Rule of
 *        thumb: LFBridgeTimeoutMs >= (HTTP timeout + 5s) * 1000.
 *
 *   [P3] Treating an empty repair result as a failure. An empty
 *        string is a legitimate repair result when the input was an
 *        empty or whitespace-only payload. LFHttpRepairJson returns
 *        True in that case; check the return value first, then the
 *        string.
 *
 *   [P4] Assuming the repair API always modifies its input. It
 *        returns the input unchanged when the input is already valid
 *        JSON. To find out whether the input was modified, compare
 *        the input string to the output string.
 *
 *   [P5] Assuming the outbound API always returns a JSON body. A
 *        remote server can legitimately respond with a non-JSON body
 *        (an HTML error page, an image, a plain-text message). In
 *        that case the bridge returns the body as a string. Check
 *        the type of Response.O['body'] before assuming it is an
 *        object.
 *
 *   [P6] Parsing the bridge's outbound response as if it were the
 *        remote server's response. The bridge wraps the remote
 *        server's response inside an envelope:
 *            {"status_code":..., "headers":..., "body":...}
 *        The remote server's actual response is inside "body", not
 *        at the top level.
 *
 *   [P7] Sending a request body that is not valid JSON. The bridge
 *        expects the "body" field of the outbound request to be a
 *        JSON value. If you build the request by hand and produce
 *        invalid JSON, the bridge's request parser will reject it.
 *        Use TZ_JsonObject to build request bodies.
 *
 *   [P8] Using the repair API on non-JSON input and expecting it to
 *        fail loudly. The bridge is binary-safe: an unrepairable
 *        payload is returned unchanged with a successful return.
 *        The bridge logs an ERROR on its side, but the Pascal
 *        caller will not see it. If you need to distinguish
 *        "repaired" from "unchanged", compare the strings.
 *
 * =============================================================================
 * RETRY PATTERN (RECOMMENDED FOR PRODUCTION)
 * =============================================================================
 *
 * The bridge's App is registered on the mesh, and the mesh propagates
 * that registration via broadcast. In deployment mode
 * (Wait_Connection_ReadyOk=False) the caller may issue a call before
 * the broadcast reaches it, in which case LF_Call returns a zero-size
 * handle. Wrap any bridge call in a short retry loop:
 *
 *     function WaitForBridge(TimeoutMs: Integer): Boolean;
 *     var
 *       tk: UInt64;
 *     begin
 *       tk := GetTimeTick();
 *       while GetTimeTick() - tk < TimeoutMs do
 *       begin
 *         if LF.CheckApp(LFBridgeAppName) then Exit(True);
 *         TCompute.Sleep(200);
 *       end;
 *       Result := False;
 *     end;
 *
 * The same pattern works for any target App name, not just the
 * bridge. See LF-NET-004 and LF-CHK-001 in the Pascal Complete Guide
 * for the full rationale.
 *
 * =============================================================================
 * COMPATIBILITY
 * =============================================================================
 *
 * Free Pascal 3.2.2+ and Delphi XE 10.4+ on Windows, Linux, and macOS.
 * Requires the LingoFuse dynamic library and the Z-framework units
 * (Z.Core, Z.Json, Z.PascalStrings, Z.UPascalStrings).
 *)

unit lf_http_bridge_client;

{$DEFINE FPC_DELPHI_MODE}
{$I ..\..\Z.Define.inc}

interface

uses
  SysUtils,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.UnicodeMixedLib,
  Z.Json,
  lingofuse_import;

var
  (*
   * LingoFuse App name under which the bridge registers its outbound
   * POST proxy and its JSON repair service.
   *
   * Default matches the bridge's --bridge-app default.
   *
   * If the bridge was started with --bridge-app <name> or with the
   * environment variable LINGOFUSE_BRIDGE_APP=<name>, set this
   * variable to the same value BEFORE calling any function in this
   * unit. The functions themselves do not modify it.
   *)
  LFBridgeAppName: string = '__lf_http_bridge__';

  (*
   * LingoFuse API name of the outbound POST proxy.
   *
   * Default matches the bridge's --bridge-api default.
   *
   * If the bridge was started with --bridge-api <name> or with the
   * environment variable LINGOFUSE_BRIDGE_API=<name>, set this
   * variable to the same value BEFORE calling LFHttpCall, LFHttpPost,
   * or LFHttpPostBody.
   *)
  LFBridgeApiName: string = '__lf_outbound_post__';

  (*
   * LingoFuse API name of the JSON repair service.
   *
   * Default matches the bridge's --bridge-repair-api default.
   *
   * The repair API accepts a UTF-8 JSON text (possibly malformed,
   * possibly with a UTF-8 BOM, possibly with trailing NULs) and
   * returns the repaired text as a plain UTF-8 string. See the unit
   * header for the full contract.
   *)
  LFBridgeRepairApiName: string = '__lf_repair_json__';

  (*
   * Timeout, in milliseconds, for the LF_Call that carries the request
   * to the bridge and carries the response back. Default 60000 ms.
   *
   * This must be larger than the outbound HTTP timeout carried inside
   * the request JSON, otherwise the LF_Call times out before the HTTP
   * request finishes. As a rule of thumb, keep at least 5 seconds of
   * headroom between the HTTP timeout and the LF_Call timeout:
   *
   *     LFBridgeTimeoutMs >= (HTTP timeout in seconds + 5) * 1000
   *
   * For the JSON repair API, this is the timeout for the repair
   * computation itself. Repair is a pure in-memory operation on the
   * bridge side, so the default is usually far more than enough.
   *)
  LFBridgeTimeoutMs: UInt64 = 60000;

  (*
   * Default outbound HTTP timeout, in seconds, used when the caller
   * does not supply one. Default 25 seconds.
   *
   * Used only by the outbound POST proxy. The JSON repair API ignores
   * this variable.
   *
   * Must be smaller than LFBridgeTimeoutMs / 1000 by a comfortable
   * margin; see the note on LFBridgeTimeoutMs above.
   *)
  LFBridgeDefaultHttpTimeoutSec: Double = 25.0;

(* ----------------------------------------------------------------------
 * Core function: outbound HTTP POST proxy
 * ---------------------------------------------------------------------- *)

(*
 * Send an HTTP request through the LingoFuse bridge.
 *
 * Parameters:
 *   URL             Target HTTP URL. Required; must not be empty. The
 *                   scheme must be http or https; the bridge does not
 *                   restrict the scheme, but the underlying HTTP
 *                   client library does.
 *
 *   Method          HTTP method. Empty string defaults to 'POST'. The
 *                   bridge enforces a whitelist: GET, POST, PUT,
 *                   PATCH, DELETE, HEAD, OPTIONS. Passing a method
 *                   outside the whitelist produces a bridge-level
 *                   error (see below).
 *
 *   RequestBodyJson Request body as a raw JSON string. Pass '' for no
 *                   body. The string must already be valid JSON; no
 *                   validation is performed here. If you are not
 *                   certain the string is valid JSON, either build it
 *                   with TZ_JsonObject, or pass it through
 *                   LFHttpRepairJson first.
 *
 *   TimeoutSeconds  Outbound HTTP timeout in seconds. Pass 0 to use
 *                   LFBridgeDefaultHttpTimeoutSec.
 *
 *   ResponseJson    On success, receives the bridge's full response
 *                   JSON, with the shape:
 *                     {"status_code":..., "headers":{...}, "body":...}
 *                   On failure, receives ''.
 *
 *                   NOTE: the bridge's response is a bridge envelope.
 *                   The remote server's actual response body is inside
 *                   the "body" field. Do not parse ResponseJson as if
 *                   it were the remote server's response.
 *
 *   ErrorMsg        On failure, receives an English error description.
 *                   On success, receives ''.
 *
 * Returns True on success, False on any failure. On a False return,
 * ErrorMsg describes the failure in English. The failure may originate
 * on the Pascal side (empty URL, DataHandle creation failure, LF_Call
 * timeout) or on the bridge side (unreachable target, HTTP error,
 * method not allowed). On a bridge-side failure, ErrorMsg contains the
 * bridge's error text verbatim.
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
 * POST a JSON object body and receive the parsed bridge response.
 *
 * This is the middle-level entry point. It always uses POST and always
 * uses LFBridgeDefaultHttpTimeoutSec for the outbound HTTP timeout. Use
 * LFHttpCall when you need a different method or an explicit timeout.
 *
 * Parameters:
 *   URL          Target HTTP URL. Required.
 *
 *   RequestBody  The JSON body to send. May be nil for no body. The
 *                caller retains ownership; this function does not free
 *                it.
 *
 *   Response     On success, receives the parsed bridge response. The
 *                caller owns the returned object and must free it.
 *                On failure, Response is nil.
 *
 *                The returned object has the bridge envelope shape:
 *                    Response.I['status_code']
 *                    Response.O['headers']
 *                    Response.O['body']
 *
 *   ErrorMsg     On failure, receives an English error description.
 *                On success, receives ''.
 *
 * Returns True on success. If the bridge reports a top-level error in
 * the response body (a JSON object with an "error" field instead of a
 * "status_code" field), returns False and writes the error text to
 * ErrorMsg.
 *
 * The function never raises. On a False return, Response is nil.
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
 * If you need the HTTP status code (for example, to distinguish a
 * successful 200 from a failing 500), do not use this function. Use
 * LFHttpPost instead and inspect Response.I['status_code'].
 *
 * Parameters:
 *   URL             Target HTTP URL. Required.
 *
 *   RequestBodyJson Request body as a raw JSON string. Pass '' for
 *                   no body. The string must already be valid JSON.
 *
 *   ResponseBodyJson
 *                   On success, receives the remote server's response
 *                   body, re-serialized as JSON text. Empty string
 *                   when the remote server returned no body.
 *
 *   ErrorMsg        On failure, receives an English error description.
 *                   On success, receives ''.
 *
 * Returns True on success, False on any failure.
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
 * The bridge's repair engine applies the toolchain's canonical JSON
 * repair policy: it validates the input against strict JSON, attempts
 * a conservative repair if strict parsing fails, re-validates its own
 * output, and returns either the repaired text or the original text
 * unchanged.
 *
 * Typical inputs that benefit from this API:
 *   - LLM-generated JSON with trailing commas, single quotes, or
 *     unbalanced braces.
 *   - Config files edited by hand and saved with a UTF-8 BOM.
 *   - Payloads that arrived with a stray trailing NUL.
 *   - Payloads produced by a non-UTF-8 producer and mis-tagged.
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
 *                   * The input was empty or whitespace-only, and the
 *                     repair engine reduced it to an empty string.
 *                     RepairedJson is ''.
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
 *   Example:
 *
 *       if not LFHttpRepairJson(input, repaired, err) then
 *         // transport failure
 *       else if input = repaired then
 *         // input was already valid, or unrepairable
 *       else
 *         // input was repaired
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
 *
 * The Z.Json unit produces UTF-8 bytes via ToBytes; those bytes are
 * decoded here into a Pascal string. The subsequent LF_WriteString
 * call re-encodes the string to UTF-8 and appends a NUL terminator,
 * which is the exact framing the bridge expects.
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
 * Build the request JSON sent to the bridge's outbound proxy.
 *
 * Fields are emitted in a stable order for easier debugging. The
 * "headers" and "body" fields are omitted when empty, because the
 * bridge treats their absence the same as an empty object or an
 * absent body.
 *
 * The output is a JSON object that matches the bridge's request
 * contract verbatim (see the unit header). No escaping is applied to
 * the body: the caller is responsible for passing a valid JSON
 * fragment in BodyJson.
 *
 * SECURITY NOTE:
 *   This function does not validate URL, Method, or BodyJson. Passing
 *   a URL containing an unescaped double quote would produce invalid
 *   JSON. In practice, URL and Method strings never contain quotes,
 *   and BodyJson is produced by TZ_JsonObject.
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

  (* ---- Send the LF_Call and release the input handle ----
   *
   * LF_WriteString appends the NUL terminator that the LingoFuse
   * wire protocol requires, so the bridge's read_string_bytes() sees
   * a well-framed payload. The input handle is released in the
   * finally block, on every path. *)
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

  (* ---- Validate the response handle ----
   *
   * A nil handle means the LF_Call could not be delivered at all.
   * A non-nil handle with size 0 means the call timed out or the
   * bridge returned nothing. Both are transport-level failures. *)
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

  (* ---- Promote a bridge-level error to a False return ----
   *
   * The bridge returns {"error": "..."} when it refuses a request
   * before reaching the target HTTP server: missing url, method not
   * in the whitelist, malformed headers, or an internal failure.
   * Those are failures from the caller's perspective, so we surface
   * them as a False return with the bridge's error text. *)
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

  (*
   * Delegate to LFHttpPost. The raw body string is parsed here into a
   * TZ_JsonObject so that LFHttpPost can accept it. If the caller
   * passed an empty body string, we pass nil to indicate "no body".
   *
   * If the body string is not valid JSON, LFHttpPost will build a
   * request whose "body" field is malformed; the bridge will reject
   * it with a bridge-level error, which LFHttpPost surfaces as a
   * False return with the error text in ErrorMsg.
   *)
  if RequestBodyJson = '' then
  begin
    if not LFHttpPost(URL, nil, Response, ErrorMsg) then
      Exit(False);
  end
  else
  begin
    Inner := TZ_JsonObject.Create;
    try
      if not Inner.ParseText(RequestBodyJson) then
      begin
        ErrorMsg := 'RequestBodyJson is not valid JSON';
        Exit(False);
      end;
      if not LFHttpPost(URL, Inner, Response, ErrorMsg) then
        Exit(False);
    finally
      Inner.Free;
    end;
  end;

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