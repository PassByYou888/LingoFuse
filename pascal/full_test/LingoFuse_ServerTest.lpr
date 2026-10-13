(*
 * ============================================================================
 * LingoFuse_ServerTest - full-featured LingoFuse RPC server for automated testing
 * ============================================================================
 *
 * Exit paths (any of them triggers a graceful shutdown):
 *   1. Console input: exit | quit | q
 *   2. Ctrl+C / Ctrl+Break (Windows) or SIGINT/SIGTERM (Unix)
 *   3. Command-line --auto-exit=<seconds> elapsed
 *   4. Sentinel file appears (default: LingoFuse_ServerTest.exit)
 *   5. --max-runtime=<seconds> elapsed (default 30 minutes)
 *
 * Automation markers on stdout:
 *   [READY] <advert-addr>     emitted once when the listener is up
 *   [STATS] ...               emitted every 5 seconds
 *   [SHUTDOWN] reason=<x>     emitted before exit
 *
 * Command line:
 *   --app=NAME          default BenchServer
 *   --listen=ADDR       default 0.0.0.0
 *   --advert=ADDR       default 0.0.0.0:9898
 *   --client=ADDR       default 127.0.0.1:9898
 *   --sentinel=PATH     default LingoFuse_ServerTest.exit
 *   --log=PATH          default LingoFuse_ServerTest.log
 *   --auto-exit=SEC     default 0 (disabled)
 *   --max-runtime=SEC   default 1800
 *   --quiet             suppress console output
 *   --no-console        suppress console echo (log file only)
 *   --no-console-thread do not spawn the stdin listener
 *
 * Runtime: writes LingoFuse_ServerTest.log in the working directory.
 * Exit code: 0 on graceful shutdown, 1 on fatal startup error.
 *)

program LingoFuse_ServerTest;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
{$endif}
{$APPTYPE CONSOLE}
{$H+}

uses
  mimalloc4p,
  {$ifdef UNIX}
  cthreads, BaseUnix,
  {$endif}
  {$ifdef MSWINDOWS}
  Windows,
  {$endif}
  Classes, SysUtils, SyncObjs, DateUtils, Variants,
  lingofuse_helper, lingofuse_import,
  Z.Core, Z.Status, Z.UnicodeMixedLib, Z.PascalStrings, Z.UPascalStrings,
  Z.Cipher, Z.Json;

const
  LF_TEST_EDITION      = '4.1';
  DEFAULT_APP_NAME     = 'BenchServer';
  DEFAULT_LISTEN_ADDR  = '0.0.0.0';
  DEFAULT_ADVERT_ADDR  = '0.0.0.0:9898';
  DEFAULT_CLIENT_ADDR  = '127.0.0.1:9898';
  DEFAULT_SENTINEL     = 'LingoFuse_ServerTest.exit';
  DEFAULT_LOG_FILE     = 'LingoFuse_ServerTest.log';
  DEFAULT_MAX_RUNTIME  = 30 * 60;
  STATS_INTERVAL_MS    = 5000;
  SENTINEL_POLL_MS     = 500;
  MAIN_LOOP_SLEEP_MS   = 20;

type
  TServerConfig = record
    AppName: string;
    ListenAddr: string;
    AdvertAddr: string;
    ClientAddr: string;
    SentinelFile: string;
    LogFile: string;
    AutoExitMs: Int64;
    MaxRuntimeMs: Int64;
    Quiet: Boolean;
    ConsoleOutput: Boolean;
    NoConsoleListener: Boolean;
  end;

var
  G_Config: TServerConfig;
  G_Running: PBoolean = nil;
  G_StartTick: TTimeTick = 0;
  G_StopReason: string = '';
  G_TotalCalls: Int64 = 0;
  G_TotalNotifies: Int64 = 0;
  G_TotalErrors: Int64 = 0;
  G_CounterValue: Int64 = 0;
  G_CounterLock: TCriticalSection = nil;
  G_OutputLock: TCriticalSection = nil;
  G_LogFile: TextFile;
  G_LogOpen: Boolean = False;

function ToUTF8(const S: string): UTF8String;
begin
  {$ifdef FPC}
  if StringCodePage(S) = CP_UTF8 then
    Result := UTF8String(S)
  else
    Result := UTF8Encode(S);
  {$else}
  Result := UTF8Encode(S);
  {$endif}
end;

procedure CW(const S: string);
var
  U: UTF8String;
  {$ifdef MSWINDOWS}
  W: UnicodeString;
  Written: DWORD;
  {$endif}
begin
  if not IsConsole then Exit;
  U := ToUTF8(S);
  {$ifdef MSWINDOWS}
  W := UTF8Decode(U);
  WriteConsoleW(GetStdHandle(STD_OUTPUT_HANDLE),
    PWideChar(W), Length(W), Written, nil);
  {$else}
  Write(U);
  {$endif}
end;

procedure CWLn(const S: string = '');
begin
  if S <> '' then CW(S);
  {$ifdef MSWINDOWS}
  CW(sLineBreak);
  {$else}
  WriteLn;
  {$endif}
end;

procedure OpenLog(const FN: string);
begin
  try
    AssignFile(G_LogFile, FN);
    Rewrite(G_LogFile);
    G_LogOpen := True;
  except
    G_LogOpen := False;
  end;
end;

procedure CloseLog;
begin
  if G_LogOpen then
  begin
    try
      CloseFile(G_LogFile);
    except
    end;
    G_LogOpen := False;
  end;
end;

procedure EmitLine(const S: string);
begin
  if G_OutputLock <> nil then G_OutputLock.Enter;
  try
    if G_Config.ConsoleOutput then
      CWLn(S);
    if G_LogOpen then
    begin
      try
        WriteLn(G_LogFile, S);
        Flush(G_LogFile);
      except
      end;
    end;
  finally
    if G_OutputLock <> nil then G_OutputLock.Leave;
  end;
end;

procedure LogInfo(const S: string);  begin EmitLine('[INFO]  ' + S); end;
procedure LogReady(const S: string); begin EmitLine('[READY] ' + S); end;
procedure LogFatal(const S: string); begin EmitLine('[FATAL] ' + S); end;
procedure LogStats;
var
  Elapsed: Int64;
begin
  Elapsed := GetTimeTick - G_StartTick;
  EmitLine(Format('[STATS] uptime_ms=%d calls=%d notifies=%d errors=%d counter=%d',
    [Elapsed, G_TotalCalls, G_TotalNotifies, G_TotalErrors, G_CounterValue]));
end;

procedure SetStopReason(const R: string);
begin
  if G_StopReason = '' then G_StopReason := R;
end;

procedure IncCall;     begin AtomInc(G_TotalCalls);    end;
procedure IncNotify;   begin AtomInc(G_TotalNotifies); end;
procedure IncErr;      begin AtomInc(G_TotalErrors);   end;

function SplitKeyValue(const S: string; out Key, Value: string): Boolean;
var
  P: Integer;
begin
  P := Pos('=', S);
  if P > 0 then
  begin
    Key := LowerCase(Copy(S, 1, P - 1));
    Value := Copy(S, P + 1, Length(S));
    Result := True;
  end
  else
  begin
    Key := LowerCase(S);
    Value := '';
    Result := False;
  end;
end;

function ParseSeconds(const S: string; DefaultSec: Int64): Int64;
var
  V: Int64;
begin
  if TryStrToInt64(S, V) and (V >= 0) then
    Result := V * 1000
  else
    Result := DefaultSec * 1000;
end;

function ParseCmdLine: TServerConfig;
var
  I: Integer;
  A, K, V: string;
begin
  Result.AppName := DEFAULT_APP_NAME;
  Result.ListenAddr := DEFAULT_LISTEN_ADDR;
  Result.AdvertAddr := DEFAULT_ADVERT_ADDR;
  Result.ClientAddr := DEFAULT_CLIENT_ADDR;
  Result.SentinelFile := DEFAULT_SENTINEL;
  Result.LogFile := DEFAULT_LOG_FILE;
  Result.AutoExitMs := 0;
  Result.MaxRuntimeMs := Int64(DEFAULT_MAX_RUNTIME) * 1000;
  Result.Quiet := True;
  Result.ConsoleOutput := True;
  Result.NoConsoleListener := False;

  for I := 1 to ParamCount do
  begin
    A := Trim(ParamStr(I));
    if A = '' then Continue;

    if (A = '--quiet') or (A = '-q') then
      Result.Quiet := True
    else if A = '--no-console' then
      Result.ConsoleOutput := False
    else if A = '--no-console-thread' then
      Result.NoConsoleListener := True
    else if Copy(A, 1, 2) = '--' then
    begin
      SplitKeyValue(Copy(A, 3, Length(A)), K, V);
      if K = 'app' then Result.AppName := V
      else if K = 'listen' then Result.ListenAddr := V
      else if K = 'advert' then Result.AdvertAddr := V
      else if K = 'client' then Result.ClientAddr := V
      else if K = 'sentinel' then Result.SentinelFile := V
      else if K = 'log' then Result.LogFile := V
      else if K = 'auto-exit' then Result.AutoExitMs := ParseSeconds(V, 0)
      else if K = 'max-runtime' then Result.MaxRuntimeMs := ParseSeconds(V, DEFAULT_MAX_RUNTIME)
      else LogInfo('unknown command-line option: ' + A);
    end
    else
      LogInfo('ignored argument: ' + A);
  end;
end;

{$ifdef MSWINDOWS}
function WindowsCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  if (dwCtrlType = CTRL_C_EVENT) or
     (dwCtrlType = CTRL_BREAK_EVENT) or
     (dwCtrlType = CTRL_CLOSE_EVENT) then
  begin
    SetStopReason('ctrl-c');
    if G_Running <> nil then G_Running^ := False;
    Result := TRUE;
  end
  else
    Result := FALSE;
end;
{$endif}

{$ifdef UNIX}
procedure UnixSignalHandler(sig: LongInt); cdecl;
begin
  SetStopReason('signal');
  if G_Running <> nil then G_Running^ := False;
end;
{$endif}

procedure InstallSignalHandlers;
begin
  {$ifdef MSWINDOWS}
  SetConsoleCtrlHandler(@WindowsCtrlHandler, TRUE);
  {$endif}
  {$ifdef UNIX}
  fpSignal(SIGINT, @UnixSignalHandler);
  fpSignal(SIGTERM, @UnixSignalHandler);
  {$endif}
end;

type
  TConsoleListener = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TConsoleListener.Execute;
var
  S: string;
begin
  try
    while (G_Running <> nil) and G_Running^ and (not Terminated) do
    begin
      try
        if EOF(Input) then Break;
        ReadLn(S);
      except
        Break;
      end;
      S := LowerCase(Trim(S));
      if (S = 'exit') or (S = 'quit') or (S = 'q') then
      begin
        SetStopReason('console-exit');
        if G_Running <> nil then G_Running^ := False;
        Break;
      end
      else if S = 'stats' then
        LogStats
      else if S = 'help' then
        EmitLine('[INFO]  commands: exit | quit | q | stats | help');
    end;
  except
  end;
end;

// ---------------------------------------------------------------------------
// Arithmetic callbacks
// ---------------------------------------------------------------------------

procedure Cb_Add(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
      LF_WriteInt32(Output, A + B)
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Sub(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
      LF_WriteInt32(Output, A - B)
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Mul(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
      LF_WriteInt32(Output, A * B)
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Div(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) and (B <> 0) then
      LF_WriteDouble(Output, A / B)
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Mod(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) and (B <> 0) then
      LF_WriteInt32(Output, A mod B)
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Neg(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, A) then
      LF_WriteInt32(Output, -A)
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Inc(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, A) then
      LF_WriteInt32(Output, A + 1)
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Sqrt(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var X: Double;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadDouble(Input, X) and (X >= 0) then
      LF_WriteDouble(Output, Sqrt(X))
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_FullEcho(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var
  V8: Int8; V16: Int16; V32: Int32; V64: Int64;
  U8: UInt8; U16: UInt16; U32: UInt32; U64: UInt64;
  Sgl: Single; Dbl: Double; S: string; B: TBytes;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    LF_ReadInt8(Input, V8);
    LF_ReadInt16(Input, V16);
    LF_ReadInt32(Input, V32);
    LF_ReadInt64(Input, V64);
    LF_ReadUInt8(Input, U8);
    LF_ReadUInt16(Input, U16);
    LF_ReadUInt32(Input, U32);
    LF_ReadUInt64(Input, U64);
    LF_ReadSingle(Input, Sgl);
    LF_ReadDouble(Input, Dbl);
    LF_ReadString(Input, S);
    B := LF_ReadStringBytes(Input);

    LF_WriteInt8(Output, V8);
    LF_WriteInt16(Output, V16);
    LF_WriteInt32(Output, V32);
    LF_WriteInt64(Output, V64);
    LF_WriteUInt8(Output, U8);
    LF_WriteUInt16(Output, U16);
    LF_WriteUInt32(Output, U32);
    LF_WriteUInt64(Output, U64);
    LF_WriteSingle(Output, Sgl);
    LF_WriteDouble(Output, Dbl);
    LF_WriteString(Output, S);
    LF_WriteStringBytes(Output, B);
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// String callbacks
// ---------------------------------------------------------------------------

procedure Cb_Upper(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
      LF_WriteString(Output, UpperCase(S))
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Lower(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
      LF_WriteString(Output, LowerCase(S))
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Reverse(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S, R: string; I: Integer;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
    begin
      SetLength(R, Length(S));
      for I := 1 to Length(S) do
        R[I] := S[Length(S) - I + 1];
      LF_WriteString(Output, R);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Trim(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
      LF_WriteString(Output, Trim(S))
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Len(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
      LF_WriteInt32(Output, Length(S))
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_Concat(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: string;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, A) and LF_ReadString(Input, B) then
      LF_WriteString(Output, A + B)
    else
      IncErr;
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Encoding callbacks
// ---------------------------------------------------------------------------

procedure Cb_B64Enc(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes; E: TPascalString;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      E := umlEncodeLineBASE64(TPascalString(B))
    else
      E := '';
    LF_WriteString(Output, E);
  except
    IncErr;
  end;
end;

procedure Cb_B64Dec(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string; D: TPascalString; B: TBytes;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
    begin
      D := umlDecodeLineBASE64(TPascalString(S));
      SetLength(B, D.Len);
      if D.Len > 0 then
        Move(D.buff[0], B[0], D.Len);
      LF_WriteStringBytes(Output, B);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_HexEnc(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes; H: TCipherString;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      H := TCipher.BufferToHex(B[0], Length(B))
    else
      H := '';
    LF_WriteString(Output, H);
  except
    IncErr;
  end;
end;

procedure Cb_HexDec(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string; B: TBytes;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
    begin
      SetLength(B, Length(S) div 2);
      if Length(B) > 0 then
        TCipher.HexToBuffer(S, B[0], Length(B));
      LF_WriteStringBytes(Output, B);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_UrlEnc(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
      LF_WriteString(Output, umlURLEncode(TPascalString(S)))
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_UrlDec(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
      LF_WriteString(Output, umlURLDecode(TPascalString(S), False))
    else
      IncErr;
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Hash callbacks
// ---------------------------------------------------------------------------

procedure Cb_Md5(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      LF_WriteString(Output, umlMD5Str(@B[0], Length(B)))
    else
      LF_WriteString(Output, umlMD5Str(nil, 0));
  except
    IncErr;
  end;
end;

procedure Cb_Sha1(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes; H: TSHA1Digest;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      H := TCipher.GenerateSHA1Hash(@B[0], Length(B))
    else
      H := TCipher.GenerateSHA1Hash(nil, 0);
    LF_WriteString(Output, TCipher.BufferToHex(H, SizeOf(H)));
  except
    IncErr;
  end;
end;

procedure Cb_Sha256(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes; H: TSHA256Digest;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      H := TCipher.GenerateSHA256Hash(@B[0], Length(B))
    else
      H := TCipher.GenerateSHA256Hash(nil, 0);
    LF_WriteString(Output, TCipher.BufferToHex(H, SizeOf(H)));
  except
    IncErr;
  end;
end;

procedure Cb_Sha512(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes; H: TSHA512Digest;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      H := TCipher.GenerateSHA512Hash(@B[0], Length(B))
    else
      H := TCipher.GenerateSHA512Hash(nil, 0);
    LF_WriteString(Output, TCipher.BufferToHex(H, SizeOf(H)));
  except
    IncErr;
  end;
end;

procedure Cb_CRC16(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes; W: Word;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      W := umlCRC16(@B[0], Length(B))
    else
      W := 0;
    LF_WriteInt32(Output, W);
  except
    IncErr;
  end;
end;

procedure Cb_CRC32(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes; D: Cardinal;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      D := umlCRC32(@B[0], Length(B))
    else
      D := 0;
    LF_WriteUInt32(Output, D);
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Random callbacks
// ---------------------------------------------------------------------------

procedure Cb_Random(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var Lo, Hi, V: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, Lo) and LF_ReadInt32(Input, Hi) then
    begin
      if Lo > Hi then
      begin
        V := Lo;
        Lo := Hi;
        Hi := V;
      end;
      V := umlRandomRange(Lo, Hi);
      LF_WriteInt32(Output, V);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_RandomBytes(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var N: Int32; B: TBytes; I: Integer;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, N) then
    begin
      if N < 0 then N := 0;
      if N > 1024 * 1024 then N := 1024 * 1024;
      SetLength(B, N);
      for I := 0 to N - 1 do
        B[I] := Byte(umlRandomRange(0, 255));
      LF_WriteStringBytes(Output, B);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Time callbacks
// ---------------------------------------------------------------------------

procedure Cb_Timestamp(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var T: Int64;
begin
  IncCall;
  try
    T := DateTimeToUnix(Now);
    LF_WriteInt64(Output, T);
  except
    IncErr;
  end;
end;

procedure Cb_Uptime(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var T: Int64;
begin
  IncCall;
  try
    T := GetTimeTick - G_StartTick;
    LF_WriteInt64(Output, T);
  except
    IncErr;
  end;
end;

procedure Cb_Sleep(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var MS: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, MS) then
    begin
      if MS < 0 then MS := 0;
      if MS > 30000 then MS := 30000;
      Sleep(MS);
      LF_WriteString(Output, 'ok');
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Big payload callbacks
// ---------------------------------------------------------------------------

procedure Cb_BigEcho(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    LF_WriteStringBytes(Output, B);
  except
    IncErr;
  end;
end;

procedure Cb_BigHash(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes;
begin
  IncCall;
  try
    B := LF_ReadStringBytes(Input);
    if Length(B) > 0 then
      LF_WriteString(Output, umlMD5Str(@B[0], Length(B)))
    else
      LF_WriteString(Output, umlMD5Str(nil, 0));
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Info / Stats callbacks
// ---------------------------------------------------------------------------

procedure Cb_Info(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var
  JO: TZ_JsonObject;
  S: string;
begin
  IncCall;
  try
    JO := TZ_JsonObject.Create;
    try
      JO.S['app'] := G_Config.AppName;
      JO.S['listen'] := G_Config.ListenAddr;
      JO.S['advert'] := G_Config.AdvertAddr;
      JO.S['edition'] := LF_TEST_EDITION;
      JO.I64['uptime_ms'] := GetTimeTick - G_StartTick;
      S := JO.ToJSONString(False);
    finally
      JO.Free;
    end;
    LF_WriteString(Output, S);
  except
    IncErr;
  end;
end;

procedure Cb_Stats(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var
  JO: TZ_JsonObject;
  S: string;
begin
  IncCall;
  try
    JO := TZ_JsonObject.Create;
    try
      JO.I64['uptime_ms'] := GetTimeTick - G_StartTick;
      JO.I64['total_calls'] := G_TotalCalls;
      JO.I64['total_notifies'] := G_TotalNotifies;
      JO.I64['total_errors'] := G_TotalErrors;
      JO.I64['counter'] := G_CounterValue;
      S := JO.ToJSONString(False);
    finally
      JO.Free;
    end;
    LF_WriteString(Output, S);
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Identity callbacks
//
//* Cb_WhoAmI returns the caller's P2P UID (32 raw bytes) followed by the
//* caller's P2PName as a null-terminated UTF-8 string. Both values are
//* injected automatically by the framework on every inbound request.
//* ---------------------------------------------------------------------------

procedure Cb_WhoAmI(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var
  UID: TP2P_UID___;
  P2P: pansichar;
  P2PStr: string;
begin
  IncCall;
  try
    UID := LF_Get_P2P_UID(Input)^;
    P2P := LF_Get_P2P_Name(Input);
    if P2P = nil then
      P2PStr := ''
    else
      P2PStr := string(UTF8Decode(P2P));

    LF_WriteBuffer(Output, @UID[0], SizeOf(UID));
    LF_WriteString(Output, P2PStr);
  except
    IncErr;
  end;
end;

procedure Cb_P2PName_Echo(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var
  P2P: pansichar;
  P2PStr: string;
begin
  IncCall;
  try
    P2P := LF_Get_P2P_Name(Input);
    if P2P = nil then
      P2PStr := ''
    else
      P2PStr := string(UTF8Decode(P2P));
    LF_WriteString(Output, P2PStr);
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Counter callbacks
// ---------------------------------------------------------------------------

procedure Cb_CounterReset(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
begin
  IncCall;
  try
    G_CounterLock.Enter;
    try
      G_CounterValue := 0;
    finally
      G_CounterLock.Leave;
    end;
    LF_WriteInt64(Output, 0);
  except
    IncErr;
  end;
end;

procedure Cb_CounterInc(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var D: Int64;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt64(Input, D) then
    begin
      G_CounterLock.Enter;
      try
        Inc(G_CounterValue, D);
        D := G_CounterValue;
      finally
        G_CounterLock.Leave;
      end;
      LF_WriteInt64(Output, D);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_CounterGet(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var V: Int64;
begin
  IncCall;
  try
    G_CounterLock.Enter;
    try
      V := G_CounterValue;
    finally
      G_CounterLock.Leave;
    end;
    LF_WriteInt64(Output, V);
  except
    IncErr;
  end;
end;

procedure Cb_SeqNoop(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var N: Int32;
begin
  IncCall;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, N) then
      LF_WriteInt32(Output, N)
    else
      IncErr;
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Notify callbacks
// ---------------------------------------------------------------------------

procedure Cb_Log(Trigger: Pointer; Input: TDataHnd___); cdecl;
var S: string;
begin
  IncNotify;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
    begin
      if not G_Config.Quiet then
        EmitLine('[NOTIFY] ' + S);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_LogInt(Trigger: Pointer; Input: TDataHnd___); cdecl;
var N: Int32;
begin
  IncNotify;
  try
    LF_SetPos(Input, 0);
    if LF_ReadInt32(Input, N) then
    begin
      if not G_Config.Quiet then
        EmitLine(Format('[NOTIFY] int=%d', [N]));
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_LogMulti(Trigger: Pointer; Input: TDataHnd___); cdecl;
var A, B, C: string;
begin
  IncNotify;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, A) and LF_ReadString(Input, B) and LF_ReadString(Input, C) then
    begin
      if not G_Config.Quiet then
        EmitLine(Format('[NOTIFY] %s | %s | %s', [A, B, C]));
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

procedure Cb_LogNoop(Trigger: Pointer; Input: TDataHnd___); cdecl;
begin
  IncNotify;
end;

// ---------------------------------------------------------------------------
// P2P process-wide registration callbacks
// ---------------------------------------------------------------------------

procedure Cb_P2P_Ping(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
begin
  IncCall;
  try
    LF_WriteString(Output, 'pong');
  except
    IncErr;
  end;
end;

procedure Cb_P2P_Log(Trigger: Pointer; Input: TDataHnd___); cdecl;
var S: string;
begin
  IncNotify;
  try
    LF_SetPos(Input, 0);
    if LF_ReadString(Input, S) then
    begin
      if not G_Config.Quiet then
        EmitLine('[P2P-NOTIFY] ' + S);
    end
    else
      IncErr;
  except
    IncErr;
  end;
end;

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

procedure RegisterAllAPIs(App: LF.TAppHandle);
begin
  App.RegisterCall('add', 'int32+int32 -> int32', nil, @Cb_Add);
  App.RegisterCall('sub', 'int32-int32 -> int32', nil, @Cb_Sub);
  App.RegisterCall('mul', 'int32*int32 -> int32', nil, @Cb_Mul);
  App.RegisterCall('div', 'int32/int32 -> double', nil, @Cb_Div);
  App.RegisterCall('mod_', 'int32 mod int32 -> int32', nil, @Cb_Mod);
  App.RegisterCall('neg', 'int32 -> int32', nil, @Cb_Neg);
  App.RegisterCall('inc', 'int32 -> int32', nil, @Cb_Inc);
  App.RegisterCall('sqrt', 'double -> double', nil, @Cb_Sqrt);
  App.RegisterCall('full_echo', 'full typed echo', nil, @Cb_FullEcho);

  App.RegisterCall('upper', 'string -> string', nil, @Cb_Upper);
  App.RegisterCall('lower', 'string -> string', nil, @Cb_Lower);
  App.RegisterCall('reverse', 'string -> string', nil, @Cb_Reverse);
  App.RegisterCall('trim', 'string -> string', nil, @Cb_Trim);
  App.RegisterCall('len', 'string -> int32', nil, @Cb_Len);
  App.RegisterCall('concat', 'string+string -> string', nil, @Cb_Concat);

  App.RegisterCall('b64_enc', 'bytes -> base64 string', nil, @Cb_B64Enc);
  App.RegisterCall('b64_dec', 'base64 string -> bytes', nil, @Cb_B64Dec);
  App.RegisterCall('hex_enc', 'bytes -> hex string', nil, @Cb_HexEnc);
  App.RegisterCall('hex_dec', 'hex string -> bytes', nil, @Cb_HexDec);
  App.RegisterCall('url_enc', 'string -> urlencoded', nil, @Cb_UrlEnc);
  App.RegisterCall('url_dec', 'urlencoded -> string', nil, @Cb_UrlDec);

  App.RegisterCall('md5', 'bytes -> md5 hex', nil, @Cb_Md5);
  App.RegisterCall('sha1', 'bytes -> sha1 hex', nil, @Cb_Sha1);
  App.RegisterCall('sha256', 'bytes -> sha256 hex', nil, @Cb_Sha256);
  App.RegisterCall('sha512', 'bytes -> sha512 hex', nil, @Cb_Sha512);
  App.RegisterCall('crc16', 'bytes -> int32', nil, @Cb_CRC16);
  App.RegisterCall('crc32', 'bytes -> uint32', nil, @Cb_CRC32);

  App.RegisterCall('rand', 'int32,int32 -> int32', nil, @Cb_Random);
  App.RegisterCall('rand_bytes', 'int32 -> bytes', nil, @Cb_RandomBytes);

  App.RegisterCall('ts', '-> int64 unix sec', nil, @Cb_Timestamp);
  App.RegisterCall('uptime', '-> int64 ms', nil, @Cb_Uptime);
  App.RegisterCall('sleep', 'int32 ms -> "ok"', nil, @Cb_Sleep);

  App.RegisterCall('big_echo', 'bytes -> bytes', nil, @Cb_BigEcho);
  App.RegisterCall('big_hash', 'bytes -> md5 hex', nil, @Cb_BigHash);

  App.RegisterCall('info', '-> json', nil, @Cb_Info);
  App.RegisterCall('stats', '-> json', nil, @Cb_Stats);

  App.RegisterCall('whoami', 'return caller UID (32 bytes) + P2PName', nil, @Cb_WhoAmI);
  App.RegisterCall('p2pname_echo', 'return caller P2PName only', nil, @Cb_P2PName_Echo);

  App.RegisterCall('counter_reset', '-> 0', nil, @Cb_CounterReset);
  App.RegisterCall('counter_inc', 'int64 -> int64', nil, @Cb_CounterInc);
  App.RegisterCall('counter_get', '-> int64', nil, @Cb_CounterGet);

  App.RegisterCall('seq_noop', 'int32 -> int32', nil, @Cb_SeqNoop);

  App.RegisterNotify('log', 'string', nil, @Cb_Log);
  App.RegisterNotify('log_int', 'int32', nil, @Cb_LogInt);
  App.RegisterNotify('log_multi', 'string,string,string', nil, @Cb_LogMulti);
  App.RegisterNotify('log_noop', '', nil, @Cb_LogNoop);

  LF_Register_P2P_CallEx('p2p_ping', 'P2P ping', nil, @Cb_P2P_Ping);
  LF_Register_P2P_NotifyEx('p2p_log', 'P2P log', nil, @Cb_P2P_Log);
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

var
  App: LF.TAppHandle;
  ConsoleThread: TConsoleListener;
  LastStats, LastSentinel: TTimeTick;
  NowTick: TTimeTick;
  Rc: Integer;

begin
  New(G_Running);
  G_Running^ := True;
  G_StartTick := GetTimeTick;
  G_OutputLock := TCriticalSection.Create;
  G_CounterLock := TCriticalSection.Create;
  App := nil;

  try
    G_Config := ParseCmdLine;
    OpenLog(G_Config.LogFile);

    EmitLine('============================================================');
    EmitLine('LingoFuse_ServerTest v' + LF_TEST_EDITION);
    EmitLine('Start: ' + DateTimeToStr(Now));
    EmitLine('============================================================');
    LogInfo('app=' + G_Config.AppName);
    LogInfo('listen=' + G_Config.ListenAddr);
    LogInfo('advert=' + G_Config.AdvertAddr);
    LogInfo('client=' + G_Config.ClientAddr);
    LogInfo('sentinel=' + G_Config.SentinelFile);
    if G_Config.AutoExitMs > 0 then
      LogInfo(Format('auto-exit=%d ms', [G_Config.AutoExitMs]));
    LogInfo(Format('max-runtime=%d ms', [G_Config.MaxRuntimeMs]));

    if FileExists(G_Config.SentinelFile) then
    begin
      try
        DeleteFile(G_Config.SentinelFile);
      except
      end;
    end;

    InstallSignalHandlers;

    LF.Set_Opt_Quiet(G_Config.Quiet);
    LF.Set_Opt_ConsoleOutput(G_Config.ConsoleOutput);
    LF.Set_Opt_Wait_Connection_Timeout(15000);
    LF.Set_Opt_Wait_Connection_ReadyOk(True);
    LF.Set_Opt_Overlap_Connection(True);

    App := LF.TAppHandle.Create(G_Config.AppName, 'LingoFuse_ServerTest');
    RegisterAllAPIs(App);

    LF_ResetPrepare;
    Rc := LF_PrepareServiceEx(G_Config.ListenAddr, G_Config.AdvertAddr);
    if Rc = -1 then
    begin
      LogFatal('PrepareService failed (endpoint may be occupied)');
      SetStopReason('service-failed');
    end
    else
    begin
      LF.PrepareClient(G_Config.ClientAddr, App);

      if LF_PrepareDone <> 1 then
      begin
        LogFatal('PrepareDone failed');
        SetStopReason('init-failed');
      end
      else
      begin
        LogReady(G_Config.AdvertAddr);

        if not G_Config.NoConsoleListener then
        begin
          ConsoleThread := TConsoleListener.Create(True);
          ConsoleThread.FreeOnTerminate := True;
          ConsoleThread.Start;
        end;

        LastStats := GetTimeTick;
        LastSentinel := GetTimeTick;

        while G_Running^ do
        begin
          Z.Core.Check_Soft_Thread_Synchronize(10);
          try LF.Sync; except end;

          NowTick := GetTimeTick;

          if (not G_Config.Quiet) and ((NowTick - LastStats) >= STATS_INTERVAL_MS) then
          begin
            LogStats;
            LastStats := NowTick;
          end;

          if (NowTick - LastSentinel) >= SENTINEL_POLL_MS then
          begin
            if FileExists(G_Config.SentinelFile) then
            begin
              SetStopReason('sentinel');
              G_Running^ := False;
            end;
            LastSentinel := NowTick;
          end;

          if (G_Config.AutoExitMs > 0) and
             (Int64(NowTick - G_StartTick) >= G_Config.AutoExitMs) then
          begin
            SetStopReason('auto-exit');
            G_Running^ := False;
          end;

          if (G_Config.MaxRuntimeMs > 0) and
             (Int64(NowTick - G_StartTick) >= G_Config.MaxRuntimeMs) then
          begin
            SetStopReason('max-runtime');
            G_Running^ := False;
          end;

          Sleep(MAIN_LOOP_SLEEP_MS);
        end;
      end;
    end;

    if G_StopReason = '' then
      SetStopReason('normal');
    EmitLine(Format('[SHUTDOWN] reason=%s uptime_ms=%d calls=%d notifies=%d errors=%d',
      [G_StopReason, GetTimeTick - G_StartTick,
       G_TotalCalls, G_TotalNotifies, G_TotalErrors]));

    try
      LF_ExitMainThread;
    except
    end;

    if App <> nil then
    begin
      try
        App.Free;
      except
      end;
      App := nil;
    end;

    try
      LF_Shutdown;
    except
    end;

    try
      if FileExists(G_Config.SentinelFile) then
        DeleteFile(G_Config.SentinelFile);
    except
    end;
  finally
    CloseLog;
    if G_Running <> nil then
    begin
      Dispose(G_Running);
      G_Running := nil;
    end;
    if G_OutputLock <> nil then
    begin
      G_OutputLock.Free;
      G_OutputLock := nil;
    end;
    if G_CounterLock <> nil then
    begin
      G_CounterLock.Free;
      G_CounterLock := nil;
    end;
  end;
end.
