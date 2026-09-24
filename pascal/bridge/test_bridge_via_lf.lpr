(*
 * =============================================================================
 * test_bridge_via_lf - Pascal test driver for the LingoFuse HTTP bridge
 * =============================================================================
 *
 * This program exercises the outbound POST proxy provided by bridge.py,
 * using the lf_http_bridge_client unit. It is the LingoFuse-channel
 * equivalent of web_demo.html, which reaches bridge.py over plain HTTP.
 *
 * Call chain:
 *
 *     Pascal program
 *         -> LF_Call(__lf_http_bridge__ . __lf_outbound_post__)
 *         -> bridge.py outbound handler
 *         -> HTTP POST http://127.0.0.1:8081/pas/exp
 *         -> bridge.py inbound handler
 *         -> LF_Call(pas . exp)
 *         -> bridge_compute (Pascal expression evaluator)
 *         -> response bubbles back up the same chain
 *
 * Prerequisites:
 *
 *   1. bridge_service  running as a beacon on ipc:compute_grid
 *   2. bridge_compute  running and registered as app "pas" api "exp"
 *   3. bridge.py       running with --endpoint ipc:compute_grid
 *
 * The program prepares its own LingoFuse client connection (because the
 * lf_http_bridge_client unit is a library, not a program), runs the
 * built-in test cases, then accepts interactive input from the console.
 *
 * All comments and status output are in English.
 *)

program test_bridge_via_lf;

{$mode delphi}{$H+}
{$CODEPAGE UTF8}
{$APPTYPE CONSOLE}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils,
  Z.Core, Z.Json, Z.PascalStrings, Z.UPascalStrings, Z.UnicodeMixedLib,
  lingofuse_import,
  lf_http_bridge_client;

const
  (*
   * LingoFuse endpoint the test program connects to as a client.
   * Must match the --endpoint of bridge.py and the endpoint used by
   * bridge_compute.
   *)
  LINGOFUSE_ENDPOINT = 'ipc:compute_grid';

  (*
   * The HTTP URL the bridge will POST to. This is bridge.py's own
   * inbound listener, routed to the Pascal evaluator via /pas/exp.
   *)
  BRIDGE_HTTP_URL = 'http://127.0.0.1:8081/pas/exp';

(*
 * The default bridge App name and API name are set by
 * lf_http_bridge_client.pas and match bridge.py's defaults. If the
 * running bridge.py was started with --bridge-app or --bridge-api
 * overrides, adjust LFBridgeAppName / LFBridgeApiName after the
 * `uses` clause of this program, before PrepareLingoFuse runs.
 *)

(* ----------------------------------------------------------------------
 * Console helpers (UTF-8 safe on Windows)
 * ---------------------------------------------------------------------- *)

function ToUtf8(const S: string): UTF8String;
begin
  {$IFDEF FPC}
  if StringCodePage(S) = CP_UTF8 then
    Result := UTF8String(S)
  else
    Result := UTF8Encode(S);
  {$ELSE}
  Result := UTF8Encode(S);
  {$ENDIF}
end;

procedure CW(const S: string);
var
  U: UTF8String;
  {$IFDEF MSWINDOWS}
  W: UnicodeString;
  Written: DWORD;
  {$ENDIF}
begin
  if not IsConsole then Exit;
  U := ToUtf8(S);
  {$IFDEF MSWINDOWS}
  W := UTF8Decode(U);
  WriteConsoleW(GetStdHandle(STD_OUTPUT_HANDLE),
    PWideChar(W), Length(W), Written, nil);
  {$ELSE}
  Write(U);
  {$ENDIF}
end;

procedure CWLn(const S: string = '');
begin
  if S <> '' then CW(S);
  {$IFDEF MSWINDOWS}
  CW(sLineBreak);
  {$ELSE}
  WriteLn;
  {$ENDIF}
end;

(* ----------------------------------------------------------------------
 * LingoFuse connection setup
 *
 * The lf_http_bridge_client unit does not prepare any connection; it
 * assumes the caller already has a working LF session. This function
 * prepares one.
 *
 * Two options are set explicitly:
 *
 *   Wait_Ready          = False
 *       Deployment mode. Do not block on peers that may not be ready.
 *
 *   Overlap_Connection  = True
 *       Allow this test client to coexist with bridge.py and
 *       bridge_compute, which are also connected to the same endpoint.
 * ---------------------------------------------------------------------- *)

function PrepareLingoFuse: Boolean;
begin
  CWLn('Preparing LingoFuse client connection to ' + LINGOFUSE_ENDPOINT + ' ...');

  LF_SetOptionEx('Wait_Ready', 'True');
  LF_SetOptionEx('Overlap_Connection', 'True');

  LF_ResetPrepare;

  if LF_PrepareClientEx(LINGOFUSE_ENDPOINT) = -1 then
  begin
    CWLn('ERROR: LF_PrepareClientEx returned -1 for endpoint ' +
         LINGOFUSE_ENDPOINT);
    CWLn('       The endpoint may be in use, or the address is invalid.');
    Result := False;
    Exit;
  end;

  if LF_PrepareDone <> 1 then
  begin
    CWLn('ERROR: LF_PrepareDone returned non-1.');
    Result := False;
    Exit;
  end;

  CWLn('LingoFuse client ready.');
  Result := True;
end;

procedure ShutdownLingoFuse;
begin
  CWLn('');
  CWLn('Shutting down LingoFuse ...');
  try
    LF_ExitMainThread;
  except
  end;
  try
    LF_Shutdown;
  except
  end;
  CWLn('LingoFuse shut down.');
end;

(* ----------------------------------------------------------------------
 * Single test execution
 *
 * Sends one expression through the bridge and prints the result.
 *
 * The request body sent to the HTTP target is:
 *     {"args": ["<expr>"]}
 *
 * The response envelope from the bridge is:
 *     {"status_code":..., "headers":{...}, "body":{...}}
 *
 * The inner body from the Pascal evaluator is:
 *     {"code":0, "result":"..."}   on success
 *     {"code":-1, "error":"..."}   on failure
 * ---------------------------------------------------------------------- *)

procedure RunOneTest(const Expr: string);
var
  RequestBody: TZ_JsonObject;
  Response:    TZ_JsonObject;
  Inner:       TZ_JsonObject;
  ErrorMsg:    string;
  Code:        Integer;
  StatusCode:  Integer;
  ResultText:  string;
begin
  CWLn('');
  CWLn('--- Test: ' + Expr + ' ---');

  (* ---- Build the HTTP request body: {"args": ["<expr>"]} ---- *)
  RequestBody := TZ_JsonObject.Create;
  try
    RequestBody.A['args'].Add(Expr);

    (* ---- Send through the bridge via LF ---- *)
    if not LFHttpPost(BRIDGE_HTTP_URL, RequestBody, Response, ErrorMsg) then
    begin
      CWLn('FAILED: ' + ErrorMsg);
      Exit;
    end;
  finally
    RequestBody.Free;
  end;

  (* ---- Inspect the bridge response envelope ---- *)
  try
    StatusCode := Response.I['status_code'];
    if StatusCode <> 200 then
      CWLn('Note: HTTP status code = ' + IntToStr(StatusCode));

    Inner := Response.O['body'];
    if Inner = nil then
    begin
      CWLn('FAILED: response body is missing or null');
      Exit;
    end;

    (* ---- Inspect the inner body from the Pascal evaluator ---- *)
    Code := Inner.I['code'];

    case Code of
      0:
        begin
          ResultText := Inner.S['result'];
          CWLn('OK: result = ' + ResultText);
        end;
      -1:
        begin
          CWLn('FAILED (code=-1): ' + Inner.S['error']);
        end;
      -2:
        begin
          CWLn('FAILED (code=-2): request shape error - ' + Inner.S['error']);
        end;
      -3:
        begin
          CWLn('FAILED (code=-3): API not available - ' + Inner.S['error']);
        end;
    else
      CWLn('UNEXPECTED: code=' + IntToStr(Code));
    end;
  finally
    Response.Free;
  end;
end;

(* ----------------------------------------------------------------------
 * Main program
 * ---------------------------------------------------------------------- *)

var
  TestCases: array[0..6] of string;
  i:         Integer;
  Line:      string;
begin
  CWLn('==============================================');
  CWLn('  LingoFuse Bridge Client Test (via LF_Call)');
  CWLn('  Equivalent to web_demo.html, but through LF');
  CWLn('==============================================');
  CWLn('');
  CWLn('HTTP target URL : ' + BRIDGE_HTTP_URL);
  CWLn('LF endpoint     : ' + LINGOFUSE_ENDPOINT);
  CWLn('Bridge App name : ' + LFBridgeAppName);
  CWLn('Bridge API name : ' + LFBridgeApiName);
  CWLn('LF timeout      : ' + IntToStr(LFBridgeTimeoutMs) + ' ms');
  CWLn('HTTP timeout    : ' +
       FloatToStr(LFBridgeDefaultHttpTimeoutSec) + ' s');
  CWLn('');

  if not PrepareLingoFuse then
  begin
    CWLn('Startup failed. Exiting.');
    Halt(1);
  end;

  try
    (* ---- Built-in test cases (mirrors web_demo.html examples) ---- *)
    TestCases[0] := '1+2*3';
    TestCases[1] := '(10+20)/2';
    TestCases[2] := '2^8';
    TestCases[3] := 'sin(3.14/2)';
    TestCases[4] := 'sqrt(144)';
    TestCases[5] := '5!';
    TestCases[6] := '1/0';

    CWLn('');
    CWLn('Running built-in test cases ...');
    for i := Low(TestCases) to High(TestCases) do
      RunOneTest(TestCases[i]);

    (* ---- Interactive mode ---- *)
    CWLn('');
    CWLn('Enter an expression to test, or press Enter on an empty line to quit.');

    while True do
    begin
      CW('> ');
      ReadLn(Line);
      Line := Trim(Line);
      if Line = '' then Break;
      RunOneTest(Line);
    end;

  finally
    ShutdownLingoFuse;
  end;

  CWLn('');
  CWLn('Bye.');
end.
