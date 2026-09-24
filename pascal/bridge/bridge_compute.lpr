program bridge_compute;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$CODEPAGE UTF8}
{$APPTYPE CONSOLE}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils,
  Variants,
  Z.Core,
  Z.PascalStrings,
  Z.UPascalStrings,
  Z.UnicodeMixedLib,
  Z.Parsing,
  Z.Expression,
  Z.MemoryStream,
  Z.Status,
  Z.Int128,
  Z.Geometry2D,
  Z.Notify,
  Z.Json,
  lingofuse_helper,
  lingofuse_import;

function ToUTF8(const S: string): utf8string;
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

procedure ConsoleWrite(const S: string);
var
  UTF8Str: utf8string;
  {$IFDEF MSWINDOWS}
  WStr: unicodestring;
  Written: DWORD;
  {$ENDIF}
begin
  if not IsConsole then Exit;
  UTF8Str := ToUTF8(S);
  {$IFDEF MSWINDOWS}
  WStr := UTF8Decode(UTF8Str);
  WriteConsoleW(GetStdHandle(STD_OUTPUT_HANDLE),
    pwidechar(WStr), Length(WStr), Written, nil);
  {$ELSE}
  Write(UTF8Str);
  {$ENDIF}
end;

procedure ConsoleWriteLn(const S: string = '');
begin
  if S <> '' then ConsoleWrite(S);
  {$IFDEF MSWINDOWS}
  ConsoleWrite(sLineBreak);
  {$ELSE}
  WriteLn;
  {$ENDIF}
end;

// --------------------------------------------------------------------
// Expression evaluation callback – receives JSON request, returns JSON response
// --------------------------------------------------------------------
procedure do_exp_Call(Trigger: Pointer; Input: Pointer; Output: TDataHnd); cdecl;
var
  jsonBytes: TBytes;
  jo: TZ_JsonObject;
  argsArr: TZ_JsonArray;
  expr: string;
  tmp: string;
  resObj: TZ_JsonObject;
begin
  // 1. Read UTF-8 string (JSON, null-terminated)
  jsonBytes := LF_ReadStringBytes(Input);

  if Length(jsonBytes) <= 0 then
  begin
    // Return JSON error
    LF_WriteString(Output, '{"code":-1,"error":"Request body is empty"}');
    Exit;
  end;

  // 2. Parse JSON
  jo := nil;
  try
    jo := TZ_JsonObject.Create;
    jo.Parae(jsonBytes);

    // 3. Extract 'args' array
    if not jo.Exists('args') then
    begin
      LF_WriteString(Output, '{"code":-1,"error":"Missing \"args\" field"}');
      Exit;
    end;

    argsArr := jo.A['args'];
    if (argsArr = nil) or (argsArr.Count = 0) then
    begin
      LF_WriteString(Output, '{"code":-1,"error":"\"args\" array is empty"}');
      Exit;
    end;

    // 4. Take first element as expression (string)
    expr := argsArr.S[0];
    if expr = '' then
    begin
      LF_WriteString(Output, '{"code":-1,"error":"Expression is empty"}');
      Exit;
    end;

    // 5. Evaluate expression
    try
      tmp := VarToStr(EvaluateExpressionValue(tsC, expr));
      ConsoleWriteLn(Format('Received compute request "%s" = result "%s"', [expr, tmp]));
      // ---- Return JSON result ----
      resObj := TZ_JsonObject.Create;
      try
        resObj.I['code'] := 0;
        resObj.S['result'] := tmp;
        LF_WriteStringBytes(Output, resObj.ToBytes);
      finally
        resObj.Free;
      end;
    except
      on E: Exception do
      begin
        ConsoleWriteLn(Format('Expression error: %s', [E.Message]));
        LF_WriteString(Output, Format('{"code":-1,"error":"%s"}', [E.Message]));
      end;
    end;

  finally
    jo.Free;
  end;
end;

// --------------------------------------------------------------------
var
  app: TAppHnd;
begin
  ConsoleWriteLn('=== LingoFuse Compute Node (bridge_compute) ===');
  app := LF_CreateAppEx('pas', 'Pascal expression evaluator (JSON input)');

  if LF_RegisterCallEx(app, 'exp', 'exp("expression")', nil, @do_exp_Call) <> 1 then
  begin
    ConsoleWriteLn('Failed to register exp API');
    Halt(1);
  end;

  LF_SetOptionEx('Wait_Ready', 'False');
  LF_ResetPrepare();
  LF_PrepareClientEx('ipc:compute_grid', app);
  if LF_PrepareDone() <> 1 then
  begin
    ConsoleWriteLn('Failed to connect to beacon');
    Halt(1);
  end;

  ConsoleWriteLn('[OK] Compute node connected to beacon, waiting for JSON requests...');
  ConsoleWriteLn('Press Enter to exit...');
  ReadLn;

  LF_FreeApp(app);
  LF_Shutdown();
end.
