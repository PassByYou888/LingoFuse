program bridge_service;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
{$endif}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils,
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

begin
  ConsoleWriteLn('=== LingoFuse Beacon (bridge_service) ===');
  LF_ResetPrepare();
  if LF_PrepareService('ipc:compute_grid', 'ipc:compute_grid') = -1 then
  begin
    ConsoleWriteLn('Beacon startup failed, endpoint may be occupied');
    LF_Shutdown();
    Halt(1);
  end;
  if LF_PrepareDone() <> 1 then
  begin
    ConsoleWriteLn('Beacon startup failed');
    LF_Shutdown();
    Halt(1);
  end;
  ConsoleWriteLn('[OK] Beacon started on endpoint: ipc:compute_grid');
  ConsoleWriteLn('Press Enter to exit...');
  ReadLn;
  LF_ExitMainThread();
  LF_Shutdown();
end.
