(*
 * =============================================================================
 * LingoFuse_ClientTest - comprehensive client verifier for LingoFuse v5.0
 * =============================================================================
 *
 * Exit paths: normal | console exit|quit|q | Ctrl+C | sentinel
 *             | --auto-exit=SEC | --max-runtime=SEC | connect-fail
 * Exit codes: 0 all pass | 1 some fail | 2 connect failed
 *
 * The test client registers its own app (default name ClientSelf) so that
 * the server can route inbound UID / P2PName addressed calls back to it.
 * The client's own UID and P2PName are discovered via the server's whoami
 * API (see LingoFuse_ServerTest.lpr).
 * =============================================================================
 *)

program LingoFuse_ClientTest;

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
  LF_TEST_EDITION       = '5.0';
  DEFAULT_SERVER_APP    = 'BenchServer';
  DEFAULT_SERVER_ADDR   = '127.0.0.1:9898';
  DEFAULT_SENTINEL      = 'LingoFuse_ClientTest.exit';
  DEFAULT_LOG_FILE      = 'LingoFuse_ClientTest.log';
  DEFAULT_TIMEOUT_MS    = 5000;
  DEFAULT_MAX_RUNTIME   = 300;
  DEFAULT_CLIENT_APP    = 'ClientSelf';
  DEFAULT_CLIENT_P2P    = 'client_test_p2p';
  STATS_INTERVAL_MS     = 5000;
  SENTINEL_POLL_MS      = 500;
  MAIN_LOOP_SLEEP_MS    = 20;
  ASYNC_TIMEOUT_MS      = 8000;
  SEQ_COUNT             = 32;
  CONC_THREADS          = 8;
  CONC_CALLS_PER_THR    = 50;

type
  TClientConfig = record
    ServerApp: string;
    ServerAddr: string;
    ClientApp: string;
    ClientP2PName: string;
    SentinelFile: string;
    LogFile: string;
    TimeoutMs: Integer;
    AutoExitMs: Int64;
    MaxRuntimeMs: Int64;
    Heavy: Boolean;
    SkipConcurrency: Boolean;
    Quiet: Boolean;
    ConsoleOutput: Boolean;
    NoConsoleListener: Boolean;
  end;

var
  G_Config: TClientConfig;
  G_Running: PBoolean = nil;
  G_StartTick: TTimeTick = 0;
  G_StopReason: string = '';
  G_OutputLock: TCriticalSection = nil;
  G_LogFile: TextFile;
  G_LogOpen: Boolean = False;
  G_Pass: Integer = 0;
  G_Fail: Integer = 0;
  G_AsyncLock: TCriticalSection = nil;
  G_AsyncDone: Integer = 0;
  G_AsyncSum: Int64 = 0;
  G_AsyncSeqValue: array[0..255] of Int32;
  G_AsyncSeqNext: Integer = 0;
  G_AsyncSeqOk: Boolean = True;
  G_ConcLock: TCriticalSection = nil;
  G_ConcOK: Integer = 0;
  G_ConcBad: Integer = 0;
  G_ClientApp: LF.TAppHandle = nil;
  G_ClientUID: TP2P_UID___;
  G_ClientUIDValid: Boolean = False;
  G_ClientP2PName: string = '';
  G_ClientP2PValid: Boolean = False;

procedure Async_Add_Cb(Data: Pointer; Result_: TDataHnd___); cdecl; forward;
procedure Async_Seq_Cb(Data: Pointer; Result_: TDataHnd___); cdecl; forward;

// ---------------------------------------------------------------------------

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
  Written := 0;
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
    try CloseFile(G_LogFile); except end;
    G_LogOpen := False;
  end;
end;

procedure EmitLine(const S: string);
begin
  if G_OutputLock <> nil then G_OutputLock.Enter;
  try
    if G_Config.ConsoleOutput and (not G_Config.Quiet) then
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

procedure LogInfo(const S: string);    begin EmitLine('[INFO]  ' + S); end;
procedure LogReady(const S: string);   begin EmitLine('[READY] ' + S); end;
procedure LogFatal(const S: string);   begin EmitLine('[FATAL] ' + S); end;
procedure LogSection(const S: string);
begin
  EmitLine('');
  EmitLine('============================================================');
  EmitLine('>>> ' + S);
  EmitLine('============================================================');
end;

procedure Check(const Cond: Boolean; const Name: string);
begin
  if Cond then
  begin
    Inc(G_Pass);
    EmitLine('[PASS] ' + Name);
  end
  else
  begin
    Inc(G_Fail);
    EmitLine('[FAIL] ' + Name);
  end;
end;

procedure EmitStats;
begin
  EmitLine(Format('[STATS] pass=%d fail=%d uptime_ms=%d',
    [G_Pass, G_Fail, GetTimeTick - G_StartTick]));
end;

procedure SetStopReason(const R: string);
begin
  if G_StopReason = '' then G_StopReason := R;
end;

// ---------------------------------------------------------------------------

function SplitKeyValue(const S: string; out Key, Value: string): Boolean;
var P: Integer;
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
var V: Int64;
begin
  if TryStrToInt64(S, V) and (V >= 0) then
    Result := V * 1000
  else
    Result := DefaultSec * 1000;
end;

function ParseCmdLine: TClientConfig;
var
  I, TempI: Integer;
  A, K, V: string;
begin
  Result.ServerApp := DEFAULT_SERVER_APP;
  Result.ServerAddr := DEFAULT_SERVER_ADDR;
  Result.ClientApp := DEFAULT_CLIENT_APP;
  Result.ClientP2PName := DEFAULT_CLIENT_P2P;
  Result.SentinelFile := DEFAULT_SENTINEL;
  Result.LogFile := DEFAULT_LOG_FILE;
  Result.TimeoutMs := DEFAULT_TIMEOUT_MS;
  Result.AutoExitMs := 0;
  Result.MaxRuntimeMs := Int64(DEFAULT_MAX_RUNTIME) * 1000;
  Result.Heavy := True;
  Result.SkipConcurrency := False;
  Result.Quiet := True;
  Result.ConsoleOutput := True;
  Result.NoConsoleListener := False;

  for I := 1 to ParamCount do
  begin
    A := Trim(ParamStr(I));
    if A = '' then Continue;
    if (A = '--quiet') or (A = '-q') then Result.Quiet := True
    else if A = '--no-console' then Result.ConsoleOutput := False
    else if A = '--no-console-thread' then Result.NoConsoleListener := True
    else if A = '--heavy' then Result.Heavy := True
    else if A = '--no-heavy' then Result.Heavy := False
    else if A = '--skip-concurrency' then Result.SkipConcurrency := True
    else if Copy(A, 1, 2) = '--' then
    begin
      SplitKeyValue(Copy(A, 3, Length(A)), K, V);
      if K = 'server' then Result.ServerApp := V
      else if K = 'addr' then Result.ServerAddr := V
      else if K = 'client-app' then Result.ClientApp := V
      else if K = 'client-p2p' then Result.ClientP2PName := V
      else if K = 'sentinel' then Result.SentinelFile := V
      else if K = 'log' then Result.LogFile := V
      else if K = 'auto-exit' then Result.AutoExitMs := ParseSeconds(V, 0)
      else if K = 'max-runtime' then Result.MaxRuntimeMs := ParseSeconds(V, DEFAULT_MAX_RUNTIME)
      else if K = 'timeout' then
      begin
        TempI := 0;
        if TryStrToInt(V, TempI) and (TempI > 0) then Result.TimeoutMs := TempI;
      end
      else LogInfo('unknown option: ' + A);
    end;
  end;
end;

// ---------------------------------------------------------------------------

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
  else Result := FALSE;
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
var S: string;
begin
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
    else if S = 'stats' then EmitStats
    else if S = 'help' then EmitLine('[INFO]  commands: exit | quit | q | stats | help');
  end;
end;

// ---------------------------------------------------------------------------
// Client-side callbacks registered under G_Config.ClientApp
// ---------------------------------------------------------------------------

procedure Cb_Self_Echo(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  S := '';
  LF_SetPos(Input, 0);
  if LF_ReadString(Input, S) then
    LF_WriteString(Output, S);
end;

procedure Cb_Self_Add(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  A := 0; B := 0;
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
    LF_WriteInt32(Output, A + B);
end;

procedure Cb_Self_SeqNoop(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var N: Int32;
begin
  N := 0;
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, N) then
    LF_WriteInt32(Output, N);
end;

procedure Cb_Self_Log(Trigger: Pointer; Input: TDataHnd___); cdecl;
var S: string;
begin
  S := '';
  LF_SetPos(Input, 0);
  LF_ReadString(Input, S);
end;

// ---------------------------------------------------------------------------
// Baseline app-name probes
// ---------------------------------------------------------------------------

var
  SERVER_APP: string = DEFAULT_SERVER_APP;

function NewReq(const Api: string): LF.TDataHandle;
begin
  Result := LF.TDataHandle.Create(Api);
end;

function Probe_II(const Api: string; A, B: Int32; out R: Int32): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteInt32(A); Req.WriteInt32(B);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 4) then Exit;
      Res.SetPos(0);
      R := Res.ReadInt32;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_II_D(const Api: string; A, B: Int32; out R: Double): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteInt32(A); Req.WriteInt32(B);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 8) then Exit;
      Res.SetPos(0);
      R := Res.ReadDouble;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_I(const Api: string; A: Int32; out R: Int32): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteInt32(A);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 4) then Exit;
      Res.SetPos(0);
      R := Res.ReadInt32;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_S2I(const Api: string; const S: string; out R: Int32): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteString(S);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 4) then Exit;
      Res.SetPos(0);
      R := Res.ReadInt32;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_D(const Api: string; D: Double; out R: Double): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteDouble(D);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 8) then Exit;
      Res.SetPos(0);
      R := Res.ReadDouble;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_S(const Api: string; const S: string; out R: string): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := '';
  Req := NewReq(Api);
  try
    Req.WriteString(S);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 1) then Exit;
      Res.SetPos(0);
      R := Res.ReadString;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_SS(const Api: string; const S1, S2: string; out R: string): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := '';
  Req := NewReq(Api);
  try
    Req.WriteString(S1); Req.WriteString(S2);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 1) then Exit;
      Res.SetPos(0);
      R := Res.ReadString;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_I2S(const Api: string; A: Int32; out R: string): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := '';
  Req := NewReq(Api);
  try
    Req.WriteInt32(A);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 1) then Exit;
      Res.SetPos(0);
      R := Res.ReadString;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_B2S(const Api: string; const B: TBytes; out R: string): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := '';
  Req := NewReq(Api);
  try
    Req.WriteStringBytes(B);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 1) then Exit;
      Res.SetPos(0);
      R := Res.ReadString;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_B2B(const Api: string; const B: TBytes; out R: TBytes): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  SetLength(R, 0);
  Req := NewReq(Api);
  try
    Req.WriteStringBytes(B);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 1) then Exit;
      Res.SetPos(0);
      R := Res.ReadStringBytes;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_B2I(const Api: string; const B: TBytes; out R: Int32): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteStringBytes(B);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 4) then Exit;
      Res.SetPos(0);
      R := Res.ReadInt32;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_B2U32(const Api: string; const B: TBytes; out R: UInt32): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteStringBytes(B);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 4) then Exit;
      Res.SetPos(0);
      R := Res.ReadUInt32;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_I2B(const Api: string; N: Int32; out R: TBytes): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  SetLength(R, 0);
  Req := NewReq(Api);
  try
    Req.WriteInt32(N);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 1) then Exit;
      Res.SetPos(0);
      R := Res.ReadStringBytes;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_I64_NoArg(const Api: string; out R: Int64): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 8) then Exit;
      Res.SetPos(0);
      R := Res.ReadInt64;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Probe_I64_Arg(const Api: string; A: Int64; out R: Int64): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := 0;
  Req := NewReq(Api);
  try
    Req.WriteInt64(A);
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if (Res = nil) or (Res.GetSize < 8) then Exit;
      Res.SetPos(0);
      R := Res.ReadInt64;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Notify_Empty(const Api: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq(Api);
  try
    LF.NotifyApp(SERVER_APP, Req);
    Result := True;
  finally Req.Free; end;
end;

function Notify_Str(const Api: string; const S: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq(Api);
  try
    Req.WriteString(S);
    LF.NotifyApp(SERVER_APP, Req);
    Result := True;
  finally Req.Free; end;
end;

function Notify_I(const Api: string; A: Int32): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq(Api);
  try
    Req.WriteInt32(A);
    LF.NotifyApp(SERVER_APP, Req);
    Result := True;
  finally Req.Free; end;
end;

function Notify_SSS(const Api: string; const S1, S2, S3: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq(Api);
  try
    Req.WriteString(S1); Req.WriteString(S2); Req.WriteString(S3);
    LF.NotifyApp(SERVER_APP, Req);
    Result := True;
  finally Req.Free; end;
end;

// ---------------------------------------------------------------------------
// Identity discovery and probes for UID / P2PName addressed invocation.
//
// whoami returns 32 raw UID bytes followed by a null-terminated UTF-8
// P2PName string. Both values refer to this very client, because the
// framework injects the caller identity on every outbound request.
// ---------------------------------------------------------------------------

function Probe_WhoAmI(out UID: TP2P_UID___; out P2PName: string): Boolean;
var
  Req, Res: LF.TDataHandle;
begin
  Result := False;
  FillChar(UID, SizeOf(UID), 0);
  P2PName := '';
  Req := NewReq('whoami');
  try
    Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
    try
      if Res = nil then Exit;
      if Res.GetSize < SizeOf(UID) + 1 then Exit;
      Res.SetPos(0);
      Res.ReadBuffer(UID, SizeOf(UID));
      P2PName := Res.ReadString;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Is_Null_UID_Local(const UID: TP2P_UID___): Boolean;
var I: Integer;
begin
  for I := 0 to High(UID) do
    if UID[I] <> 0 then Exit(False);
  Result := True;
end;

function Probe_UID_Echo(const UID: TP2P_UID___; const S: string; out R: string): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := '';
  Req := NewReq('echo');
  try
    Req.WriteString(S);
    Res := LF.CallUID(UID, Req, G_Config.TimeoutMs);
    try
      if Res = nil then Exit;
      if Res.GetSize < 1 then Exit;
      Res.SetPos(0);
      R := Res.ReadString;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Dispatch_UID_Async_Echo(const UID: TP2P_UID___; const S: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('echo');
  try
    Req.WriteString(S);
    Result := LF.AsyncCallUID(UID, Req, nil, @Async_Add_Cb) = 1;
  finally Req.Free; end;
end;

function Dispatch_UID_AsyncSeq(const UID: TP2P_UID___; I: Int32): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('seq_noop');
  try
    Req.WriteInt32(I * 7);
    Result := LF.AsyncSequencedCallUID(UID, Req, nil, @Async_Seq_Cb) = 1;
  finally Req.Free; end;
end;

function Dispatch_UID_Notify(const UID: TP2P_UID___; const S: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('log');
  try
    Req.WriteString(S);
    LF.NotifyUID(UID, Req);
    Result := True;
  finally Req.Free; end;
end;

function Dispatch_UID_SeqNotify(const UID: TP2P_UID___; const S: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('log');
  try
    Req.WriteString(S);
    LF.SequencedNotifyUID(UID, Req);
    Result := True;
  finally Req.Free; end;
end;

function Probe_P2P_Echo(const P2PName, S: string; out R: string): Boolean;
var Req, Res: LF.TDataHandle;
begin
  Result := False;
  R := '';
  Req := NewReq('echo');
  try
    Req.WriteString(S);
    Res := LF.CallP2PName(P2PName, Req, G_Config.TimeoutMs);
    try
      if Res = nil then Exit;
      if Res.GetSize < 1 then Exit;
      Res.SetPos(0);
      R := Res.ReadString;
      Result := True;
    finally Res.Free; end;
  finally Req.Free; end;
end;

function Dispatch_P2P_Async_Echo(const P2PName, S: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('echo');
  try
    Req.WriteString(S);
    Result := LF.AsyncCallP2PName(P2PName, Req, nil, @Async_Add_Cb) = 1;
  finally Req.Free; end;
end;

function Dispatch_P2P_AsyncSeq(const P2PName: string; I: Int32): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('seq_noop');
  try
    Req.WriteInt32(I * 7);
    Result := LF.AsyncSequencedCallP2PName(P2PName, Req, nil, @Async_Seq_Cb) = 1;
  finally Req.Free; end;
end;

function Dispatch_P2P_Notify(const P2PName, S: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('log');
  try
    Req.WriteString(S);
    LF.NotifyP2PName(P2PName, Req);
    Result := True;
  finally Req.Free; end;
end;

function Dispatch_P2P_SeqNotify(const P2PName, S: string): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('log');
  try
    Req.WriteString(S);
    LF.SequencedNotifyP2PName(P2PName, Req);
    Result := True;
  finally Req.Free; end;
end;

// ---------------------------------------------------------------------------
// Baseline test sections
// ---------------------------------------------------------------------------

procedure Test_Arithmetic;
var V: Int32; D: Double;
begin
  LogSection('Section: Arithmetic APIs');

  Check(Probe_II('add', 7, 35, V) and (V = 42), 'add(7,35)=42');
  Check(Probe_II('add', -100, 100, V) and (V = 0), 'add(-100,100)=0');
  Check(Probe_II('add', 0, 0, V) and (V = 0), 'add(0,0)=0');

  Check(Probe_II('sub', 100, 23, V) and (V = 77), 'sub(100,23)=77');
  Check(Probe_II('sub', 0, 100, V) and (V = -100), 'sub(0,100)=-100');

  Check(Probe_II('mul', 12, 12, V) and (V = 144), 'mul(12,12)=144');
  Check(Probe_II('mul', -6, 7, V) and (V = -42), 'mul(-6,7)=-42');

  Check(Probe_II_D('div', 10, 4, D) and (Abs(D - 2.5) < 1e-9), 'div(10,4)=2.5');
  Check(Probe_II_D('div', 1, 3, D) and (Abs(D - 0.333333) < 0.001), 'div(1,3)~0.333');

  Check(Probe_II('mod_', 17, 5, V) and (V = 2), 'mod_(17,5)=2');
  Check(Probe_II('mod_', 10, 10, V) and (V = 0), 'mod_(10,10)=0');

  Check(Probe_I('neg', 42, V) and (V = -42), 'neg(42)=-42');
  Check(Probe_I('neg', -42, V) and (V = 42), 'neg(-42)=42');
  Check(Probe_I('inc', 99, V) and (V = 100), 'inc(99)=100');
  Check(Probe_I('inc', -1, V) and (V = 0), 'inc(-1)=0');

  Check(Probe_D('sqrt', 144, D) and (Abs(D - 12) < 1e-9), 'sqrt(144)=12');
  Check(Probe_D('sqrt', 2, D) and (Abs(D - 1.41421356) < 1e-6), 'sqrt(2)~1.414');
end;

procedure Test_String;
var R: string; V: Int32;
begin
  LogSection('Section: String APIs');

  Check(Probe_S('upper', 'hello world', R) and (R = 'HELLO WORLD'), 'upper');
  Check(Probe_S('lower', 'HELLO WORLD', R) and (R = 'hello world'), 'lower');
  Check(Probe_S('reverse', 'abcdef', R) and (R = 'fedcba'), 'reverse');
  Check(Probe_S('reverse', '', R) and (R = ''), 'reverse empty');
  Check(Probe_S('trim', '   hi   ', R) and (R = 'hi'), 'trim');
  Check(Probe_S('trim', #9'x'#9, R) and (R = 'x'), 'trim tabs');

  Check(Probe_S2I('len', 'hello', V) and (V = 5), 'len(hello)=5');
  Check(Probe_S2I('len', '', V) and (V = 0), 'len("")=0');

  Check(Probe_SS('concat', 'abc', 'def', R) and (R = 'abcdef'), 'concat');
  Check(Probe_SS('concat', '', 'xyz', R) and (R = 'xyz'), 'concat empty left');

  Check(Probe_S('upper', '中文abc', R) and (Pos('ABC', R) > 0), 'upper UTF-8');
end;

procedure Test_Encoding;
var
  R: string;
  B, Back: TBytes;
  I: Integer;
  Ok: Boolean;
begin
  LogSection('Section: Encoding APIs');

  Check(Probe_B2S('b64_enc', TEncoding.UTF8.GetBytes('hello'), R)
    and (R = 'aGVsbG8='), 'b64_enc("hello")');

  B := TEncoding.UTF8.GetBytes('aGVsbG8=');
  Check(Probe_B2B('b64_dec', B, Back)
    and (TEncoding.UTF8.GetString(Back) = 'hello'), 'b64_dec("aGVsbG8=")');

  B := TEncoding.ASCII.GetBytes('hello');
  Check(Probe_B2S('hex_enc', B, R) and SameText(R, '68656C6C6F'), 'hex_enc(hello)');

  B := TEncoding.ASCII.GetBytes('68656C6C6F');
  Check(Probe_B2B('hex_dec', B, Back)
    and (TEncoding.ASCII.GetString(Back) = 'hello'), 'hex_dec(68656C6C6F)');

  Check(Probe_S('url_enc', 'a b&c', R) and (Pos('%', R) > 0), 'url_enc');
  Check(Probe_S('url_dec', 'a%20b%26c', R) and (R = 'a b&c'), 'url_dec');

  SetLength(B, 64);
  for I := 0 to 63 do B[I] := Byte((I mod 255) + 1);
  Ok := Probe_B2S('hex_enc', B, R) and (Length(R) = 128);
  if Ok then
  begin
    B := TEncoding.ASCII.GetBytes(R);
    Ok := Probe_B2B('hex_dec', B, Back) and (Length(Back) = 64);
    if Ok then
      for I := 0 to 63 do
        if Back[I] <> Byte((I mod 255) + 1) then
        begin
          Ok := False;
          Break;
        end;
  end;
  Check(Ok, 'hex roundtrip 64 bytes');
end;

procedure Test_Hash;
var
  R: string;
  B: TBytes;
  V32: Int32;
  VU32: UInt32;
begin
  LogSection('Section: Hash APIs');

  B := TEncoding.ASCII.GetBytes('hello');
  Check(Probe_B2S('md5', B, R) and (Length(R) = 32)
    and SameText(R, '5D41402ABC4B2A76B9719D911017C592'), 'md5("hello")');

  Check(Probe_B2S('sha1', B, R) and (Length(R) = 40)
    and SameText(R, 'AAF4C61DDCC5E8A2DABEDE0F3B482CD9AEA9434D'), 'sha1("hello")');

  Check(Probe_B2S('sha256', B, R) and (Length(R) = 64), 'sha256 len');
  Check(Probe_B2S('sha512', B, R) and (Length(R) = 128), 'sha512 len');

  B := TEncoding.ASCII.GetBytes('123456789');
  Check(Probe_B2U32('crc32', B, VU32) and (VU32 = $CBF43926),
    'crc32("123456789")=0xCBF43926');

  Check(Probe_B2I('crc16', B, V32) and (V32 > 0), 'crc16 returns non-zero');
end;

procedure Test_Random;
var
  V: Int32;
  B: TBytes;
  I: Integer;
  Ok: Boolean;
begin
  LogSection('Section: Random APIs');

  Ok := True;
  for I := 1 to 32 do
    if not Probe_II('rand', I * 10, I * 10 + 100, V) then
    begin
      Ok := False;
      Break;
    end;
  Check(Ok, 'rand 32 samples callable');

  if Probe_II('rand', 1, 100, V) then
    Check((V >= 1) and (V <= 100),
      Format('rand(1,100) in range (got %d)', [V]))
  else
    Check(False, 'rand(1,100)');

  SetLength(B, 0);
  if Probe_I2B('rand_bytes', 32, B) then
    Check((Length(B) > 0) and (Length(B) <= 32),
      Format('rand_bytes(32) bytes returned (%d, max 32)', [Length(B)]))
  else
    Check(False, 'rand_bytes(32)');

  SetLength(B, 0);
  if Probe_I2B('rand_bytes', 1024, B) then
    Check((Length(B) > 0) and (Length(B) <= 1024),
      Format('rand_bytes(1024) bytes returned (%d, max 1024)', [Length(B)]))
  else
    Check(False, 'rand_bytes(1024)');
end;

procedure Test_Time;
var T, U: Int64; R: string;
begin
  LogSection('Section: Time APIs');

  Check(Probe_I64_NoArg('ts', T) and (T > 1600000000) and (T < 2000000000), 'ts sane');
  Check(Probe_I64_NoArg('uptime', U) and (U >= 0), 'uptime non-negative');

  Check(Probe_I2S('sleep', 50, R) and (R = 'ok'), 'sleep(50)');

  if Probe_I64_NoArg('ts', T) then
    if Probe_I64_NoArg('ts', U) then
      Check(U >= T, 'ts monotonic');
end;

procedure Test_BigPayload;
const N = 1024 * 1024;
var
  InB, OutB: TBytes;
  I: Integer;
  Ok: Boolean;
  R: string;
begin
  LogSection('Section: Large payload');

  if not G_Config.Heavy then
  begin
    LogInfo('  skipped (--no-heavy)');
    Exit;
  end;

  SetLength(InB, N);
  for I := 0 to N - 1 do
    InB[I] := Byte((I mod 255) + 1);

  SetLength(OutB, 0);
  if Probe_B2B('big_echo', InB, OutB) then
  begin
    Ok := Length(OutB) = N;
    if Ok then
      for I := 0 to N - 1 do
        if OutB[I] <> InB[I] then
        begin
          Ok := False;
          Break;
        end;
    Check(Ok, Format('big_echo 1MB roundtrip (%d bytes)', [N]));
  end
  else
    Check(False, 'big_echo 1MB');

  R := '';
  if Probe_B2S('big_hash', InB, R) then
    Check(Length(R) = 32, 'big_hash md5 length');
end;

procedure Test_Info;
var
  R: string;
  JO: TZ_JsonObject;
  AppName: string;
  Ok: Boolean;
begin
  LogSection('Section: Info / Stats');

  R := '';
  if Probe_I2S('info', 0, R) then
  begin
    JO := TZ_JsonObject.Create;
    try
      Ok := JO.ParseText(R);
      if Ok then
      begin
        AppName := JO.S['app'];
        Check(AppName <> '', 'info.app non-empty');
        Check(JO.S['edition'] <> '', 'info.edition non-empty');
      end
      else
        Check(False, 'info JSON parse');
    finally JO.Free; end;
  end
  else
    Check(False, 'info callable');

  R := '';
  if Probe_I2S('stats', 0, R) then
  begin
    JO := TZ_JsonObject.Create;
    try
      Ok := JO.ParseText(R);
      if Ok then
      begin
        Check(JO.Exists('uptime_ms'), 'stats.uptime_ms present');
        Check(JO.Exists('total_calls'), 'stats.total_calls present');
      end
      else
        Check(False, 'stats JSON parse');
    finally JO.Free; end;
  end
  else
    Check(False, 'stats callable');
end;

procedure Test_Counter;
var V0, V1, V2, V: Int64;
begin
  LogSection('Section: Stateful counter');

  Probe_I64_Arg('counter_reset', 0, V0);
  Check(V0 = 0, 'counter_reset returns 0');

  Probe_I64_Arg('counter_inc', 10, V1);
  Check(V1 = 10, 'counter_inc(10)=10');

  Probe_I64_Arg('counter_inc', 5, V2);
  Check(V2 = 15, 'counter_inc(5)=15');

  Probe_I64_Arg('counter_inc', -3, V2);
  Check(V2 = 12, 'counter_inc(-3)=12');

  if Probe_I64_NoArg('counter_get', V) then
    Check(V = 12, Format('counter_get=%d', [V]));
end;

procedure Test_Sequence;
var
  I: Integer;
  Ok: Boolean;
  V: Int32;
begin
  LogSection('Section: Sequenced noop');

  Ok := True;
  for I := 1 to 20 do
  begin
    if not Probe_I('seq_noop', I * 7, V) or (V <> I * 7) then
    begin
      Ok := False;
      Break;
    end;
  end;
  Check(Ok, 'seq_noop 20 sequential');
end;

// ---------------------------------------------------------------------------
// Async helpers
// ---------------------------------------------------------------------------

procedure Async_Add_Cb(Data: Pointer; Result_: TDataHnd___); cdecl;
var V: Int32;
begin
  if G_AsyncLock = nil then Exit;
  G_AsyncLock.Enter;
  try
    if Result_ <> nil then
    begin
      LF_SetPos(Result_, 0);
      if LF_ReadInt32(Result_, V) then
      begin
        Inc(G_AsyncDone);
        Inc(G_AsyncSum, V);
      end;
    end;
  finally G_AsyncLock.Leave; end;
end;

procedure Async_Seq_Cb(Data: Pointer; Result_: TDataHnd___); cdecl;
var V: Int32;
begin
  if G_AsyncLock = nil then Exit;
  G_AsyncLock.Enter;
  try
    if Result_ <> nil then
    begin
      LF_SetPos(Result_, 0);
      if LF_ReadInt32(Result_, V) then
      begin
        if G_AsyncSeqNext <= High(G_AsyncSeqValue) then
        begin
          G_AsyncSeqValue[G_AsyncSeqNext] := V;
          Inc(G_AsyncSeqNext);
          if V <> G_AsyncSeqNext * 7 then
            G_AsyncSeqOk := False;
        end;
        Inc(G_AsyncDone);
      end;
    end;
  finally G_AsyncLock.Leave; end;
end;

function WaitAsync(Count, TimeoutMs: Integer): Boolean;
var T0: TTimeTick;
begin
  T0 := GetTimeTick;
  while GetTimeTick - T0 < Cardinal(TimeoutMs) do
  begin
    Z.Core.Check_Soft_Thread_Synchronize(10);
    try LF.Sync; except end;
    G_AsyncLock.Enter;
    try
      if G_AsyncDone >= Count then Exit(True);
    finally G_AsyncLock.Leave; end;
    Sleep(5);
  end;
  Result := False;
end;

procedure AsyncReset;
begin
  G_AsyncLock.Enter;
  try
    G_AsyncDone := 0;
    G_AsyncSum := 0;
    G_AsyncSeqNext := 0;
    G_AsyncSeqOk := True;
  finally G_AsyncLock.Leave; end;
end;

function DispatchAsyncAdd(A, B: Int32): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('add');
  try
    Req.WriteInt32(A); Req.WriteInt32(B);
    Result := LF.AsyncCallApp(SERVER_APP, Req, nil, @Async_Add_Cb) = 1;
  finally Req.Free; end;
end;

function DispatchAsyncSeq(I: Int32): Boolean;
var Req: LF.TDataHandle;
begin
  Result := False;
  Req := NewReq('seq_noop');
  try
    Req.WriteInt32(I * 7);
    Result := LF.AsyncSequencedCallApp(SERVER_APP, Req, nil, @Async_Seq_Cb) = 1;
  finally Req.Free; end;
end;

procedure Test_Async_Single;
begin
  LogSection('Section: Async call - single');

  AsyncReset;
  Check(DispatchAsyncAdd(10, 20), 'dispatch async add(10,20)');

  if WaitAsync(1, ASYNC_TIMEOUT_MS) then
  begin
    G_AsyncLock.Enter;
    try
      Check(G_AsyncSum = 30, Format('async callback sum=%d', [G_AsyncSum]));
    finally G_AsyncLock.Leave; end;
  end
  else
    Check(False, 'async add timeout');
end;

procedure Test_Async_Batch10;
const N = 10;
var I: Integer; Ok: Boolean;
begin
  LogSection('Section: Async call - 10 concurrent dispatches');

  AsyncReset;
  Ok := True;
  for I := 1 to N do
    if not DispatchAsyncAdd(I, I * 2) then Ok := False;
  Check(Ok, Format('%d async dispatched', [N]));

  if WaitAsync(N, ASYNC_TIMEOUT_MS) then
  begin
    G_AsyncLock.Enter;
    try
      Check(G_AsyncSum = (N * (N + 1) div 2) * 3,
        Format('async batch sum=%d expected=%d',
          [G_AsyncSum, (N * (N + 1) div 2) * 3]));
    finally G_AsyncLock.Leave; end;
  end
  else
  begin
    G_AsyncLock.Enter;
    try
      Check(False, Format('async batch timeout, only %d/%d completed',
        [G_AsyncDone, N]));
    finally G_AsyncLock.Leave; end;
  end;
end;

procedure Test_Async_Sequenced;
var I: Integer; Ok: Boolean;
begin
  LogSection('Section: Async sequenced call - FIFO');

  AsyncReset;
  Ok := True;
  for I := 1 to SEQ_COUNT do
    if not DispatchAsyncSeq(I) then Ok := False;
  Check(Ok, Format('%d sequenced dispatched', [SEQ_COUNT]));

  if WaitAsync(SEQ_COUNT, ASYNC_TIMEOUT_MS) then
  begin
    G_AsyncLock.Enter;
    try
      Check(G_AsyncSeqOk, Format('sequenced FIFO order verified (%d items)',
        [G_AsyncSeqNext]));
    finally G_AsyncLock.Leave; end;
  end
  else
  begin
    G_AsyncLock.Enter;
    try
      Check(False, Format('sequenced timeout, only %d/%d completed',
        [G_AsyncDone, SEQ_COUNT]));
    finally G_AsyncLock.Leave; end;
  end;
end;

procedure Test_Notify;
begin
  LogSection('Section: Notify APIs');

  Check(Notify_Str('log', 'clienttest-notify-1'), 'log(string) dispatched');
  Check(Notify_I('log_int', 12345), 'log_int(12345) dispatched');
  Check(Notify_SSS('log_multi', 'alpha', 'beta', 'gamma'), 'log_multi dispatched');
  Check(Notify_Empty('log_noop'), 'log_noop dispatched');

  Sleep(500);
  Z.Core.Check_Soft_Thread_Synchronize(10);

  Check(Notify_Str('log', 'clienttest-notify-2'), 'log(string) second dispatch');
  Sleep(200);
end;

// ---------------------------------------------------------------------------
// Identity discovery and UID / P2PName addressed invocation
// ---------------------------------------------------------------------------

procedure Test_Identity_Discovery;
var
  UID: TP2P_UID___;
  P2P: string;
  Ok: Boolean;
begin
  LogSection('Section: Identity discovery (whoami)');

  FillChar(UID, SizeOf(UID), 0);
  P2P := '';

  Ok := Probe_WhoAmI(UID, P2P);
  Check(Ok, 'whoami callable');
  if not Ok then Exit;

  G_ClientUID := UID;
  G_ClientP2PName := P2P;
  G_ClientUIDValid := not Is_Null_UID_Local(UID);
  G_ClientP2PValid := P2P <> '';

  Check(G_ClientUIDValid, 'UID is non-zero');
  Check(G_ClientP2PValid, Format('P2PName="%s"', [P2P]));
  Check(P2P = G_Config.ClientP2PName,
    Format('P2PName matches configured value "%s"', [G_Config.ClientP2PName]));

  LogInfo(Format('  UID       = %s', [TCipher.BufferToHex(UID[0], SizeOf(UID)).Text]));
  LogInfo(Format('  P2PName   = %s', [P2P]));
end;

procedure Test_UID_Call;
var R: string;
begin
  LogSection('Section: UID addressed Call');

  if not G_ClientUIDValid then
  begin
    Check(False, 'UID not discovered, skipping UID_Call');
    Exit;
  end;

  Check(Probe_UID_Echo(G_ClientUID, 'uid-call-1', R) and (R = 'uid-call-1'),
    'UID_Call echo("uid-call-1")');

  Check(Probe_UID_Echo(G_ClientUID, 'uid-call-2', R) and (R = 'uid-call-2'),
    'UID_Call echo("uid-call-2")');

  Check(Probe_UID_Echo(G_ClientUID, '', R) and (R = ''),
    'UID_Call echo("")');
end;

procedure Test_UID_Async_Call;
var Ok: Boolean;
begin
  LogSection('Section: UID addressed Async Call');

  if not G_ClientUIDValid then
  begin
    Check(False, 'UID not discovered, skipping UID_Async_Call');
    Exit;
  end;

  AsyncReset;
  Ok := Dispatch_UID_Async_Echo(G_ClientUID, 'uid-async-1');
  Check(Ok, 'UID_Async_Call dispatched');

  if WaitAsync(1, ASYNC_TIMEOUT_MS) then
    Check(True, 'UID_Async_Call callback invoked')
  else
    Check(False, 'UID_Async_Call timeout');
end;

procedure Test_UID_Async_Sequenced_Call;
var I: Integer; Ok: Boolean;
begin
  LogSection('Section: UID addressed Async Sequenced Call');

  if not G_ClientUIDValid then
  begin
    Check(False, 'UID not discovered, skipping UID_Async_Sequenced_Call');
    Exit;
  end;

  AsyncReset;
  Ok := True;
  for I := 1 to SEQ_COUNT do
    if not Dispatch_UID_AsyncSeq(G_ClientUID, I) then Ok := False;
  Check(Ok, Format('%d UID-sequenced dispatched', [SEQ_COUNT]));

  if WaitAsync(SEQ_COUNT, ASYNC_TIMEOUT_MS) then
  begin
    G_AsyncLock.Enter;
    try
      Check(G_AsyncSeqOk,
        Format('UID-sequenced FIFO order verified (%d items)', [G_AsyncSeqNext]));
    finally G_AsyncLock.Leave; end;
  end
  else
  begin
    G_AsyncLock.Enter;
    try
      Check(False, Format('UID-sequenced timeout, only %d/%d completed',
        [G_AsyncDone, SEQ_COUNT]));
    finally G_AsyncLock.Leave; end;
  end;
end;

procedure Test_UID_Notify;
begin
  LogSection('Section: UID addressed Notify');

  if not G_ClientUIDValid then
  begin
    Check(False, 'UID not discovered, skipping UID_Notify');
    Exit;
  end;

  Check(Dispatch_UID_Notify(G_ClientUID, 'uid-notify-1'),
    'UID_Notify dispatched (single)');

  Sleep(200);
  Z.Core.Check_Soft_Thread_Synchronize(10);

  Check(Dispatch_UID_Notify(G_ClientUID, 'uid-notify-2'),
    'UID_Notify dispatched (second)');

  Sleep(200);
end;

procedure Test_UID_Sequenced_Notify;
begin
  LogSection('Section: UID addressed Sequenced Notify');

  if not G_ClientUIDValid then
  begin
    Check(False, 'UID not discovered, skipping UID_Sequenced_Notify');
    Exit;
  end;

  Check(Dispatch_UID_SeqNotify(G_ClientUID, 'uid-seq-notify-1'),
    'UID_Sequenced_Notify dispatched (1)');
  Check(Dispatch_UID_SeqNotify(G_ClientUID, 'uid-seq-notify-2'),
    'UID_Sequenced_Notify dispatched (2)');
  Check(Dispatch_UID_SeqNotify(G_ClientUID, 'uid-seq-notify-3'),
    'UID_Sequenced_Notify dispatched (3)');

  Sleep(300);
  Z.Core.Check_Soft_Thread_Synchronize(10);
end;

procedure Test_P2PName_Call;
var R: string;
begin
  LogSection('Section: P2PName addressed Call');

  if not G_ClientP2PValid then
  begin
    Check(False, 'P2PName not discovered, skipping P2PNAME_Call');
    Exit;
  end;

  Check(Probe_P2P_Echo(G_ClientP2PName, 'p2p-call-1', R) and (R = 'p2p-call-1'),
    'P2PNAME_Call echo("p2p-call-1")');

  Check(Probe_P2P_Echo(G_ClientP2PName, 'p2p-call-2', R) and (R = 'p2p-call-2'),
    'P2PNAME_Call echo("p2p-call-2")');

  Check(Probe_P2P_Echo(G_ClientP2PName, '', R) and (R = ''),
    'P2PNAME_Call echo("")');
end;

procedure Test_P2PName_Async_Call;
var Ok: Boolean;
begin
  LogSection('Section: P2PName addressed Async Call');

  if not G_ClientP2PValid then
  begin
    Check(False, 'P2PName not discovered, skipping P2PNAME_Async_Call');
    Exit;
  end;

  AsyncReset;
  Ok := Dispatch_P2P_Async_Echo(G_ClientP2PName, 'p2p-async-1');
  Check(Ok, 'P2PNAME_Async_Call dispatched');

  if WaitAsync(1, ASYNC_TIMEOUT_MS) then
    Check(True, 'P2PNAME_Async_Call callback invoked')
  else
    Check(False, 'P2PNAME_Async_Call timeout');
end;

procedure Test_P2PName_Async_Sequenced_Call;
var I: Integer; Ok: Boolean;
begin
  LogSection('Section: P2PName addressed Async Sequenced Call');

  if not G_ClientP2PValid then
  begin
    Check(False, 'P2PName not discovered, skipping P2PNAME_Async_Sequenced_Call');
    Exit;
  end;

  AsyncReset;
  Ok := True;
  for I := 1 to SEQ_COUNT do
    if not Dispatch_P2P_AsyncSeq(G_ClientP2PName, I) then Ok := False;
  Check(Ok, Format('%d P2PName-sequenced dispatched', [SEQ_COUNT]));

  if WaitAsync(SEQ_COUNT, ASYNC_TIMEOUT_MS) then
  begin
    G_AsyncLock.Enter;
    try
      Check(G_AsyncSeqOk,
        Format('P2PName-sequenced FIFO order verified (%d items)', [G_AsyncSeqNext]));
    finally G_AsyncLock.Leave; end;
  end
  else
  begin
    G_AsyncLock.Enter;
    try
      Check(False, Format('P2PName-sequenced timeout, only %d/%d completed',
        [G_AsyncDone, SEQ_COUNT]));
    finally G_AsyncLock.Leave; end;
  end;
end;

procedure Test_P2PName_Notify;
begin
  LogSection('Section: P2PName addressed Notify');

  if not G_ClientP2PValid then
  begin
    Check(False, 'P2PName not discovered, skipping P2PNAME_Notify');
    Exit;
  end;

  Check(Dispatch_P2P_Notify(G_ClientP2PName, 'p2p-notify-1'),
    'P2PNAME_Notify dispatched (single)');

  Sleep(200);
  Z.Core.Check_Soft_Thread_Synchronize(10);

  Check(Dispatch_P2P_Notify(G_ClientP2PName, 'p2p-notify-2'),
    'P2PNAME_Notify dispatched (second)');

  Sleep(200);
end;

procedure Test_P2PName_Sequenced_Notify;
begin
  LogSection('Section: P2PName addressed Sequenced Notify');

  if not G_ClientP2PValid then
  begin
    Check(False, 'P2PName not discovered, skipping P2PNAME_Sequenced_Notify');
    Exit;
  end;

  Check(Dispatch_P2P_SeqNotify(G_ClientP2PName, 'p2p-seq-notify-1'),
    'P2PNAME_Sequenced_Notify dispatched (1)');
  Check(Dispatch_P2P_SeqNotify(G_ClientP2PName, 'p2p-seq-notify-2'),
    'P2PNAME_Sequenced_Notify dispatched (2)');
  Check(Dispatch_P2P_SeqNotify(G_ClientP2PName, 'p2p-seq-notify-3'),
    'P2PNAME_Sequenced_Notify dispatched (3)');

  Sleep(300);
  Z.Core.Check_Soft_Thread_Synchronize(10);
end;

procedure Test_Check_Identity;
var
  ZeroUID: TP2P_UID___;
begin
  LogSection('Section: Check_UID / Check_P2PName with real values');

  FillChar(ZeroUID, SizeOf(ZeroUID), 0);

  if G_ClientUIDValid then
  begin
    Check(LF.CheckUID(G_ClientUID),
      'CheckUID on discovered UID = true');
    Check(LF.CheckUIDApi(G_ClientUID, 'echo'),
      'CheckUIDApi(discovered, "echo") = true');
    Check(not LF.CheckUIDApi(G_ClientUID, '__no_such_api__'),
      'CheckUIDApi(discovered, missing) = false');
  end
  else
  begin
    Check(False, 'UID was not discovered, cannot run CheckUID tests');
  end;

  Check(not LF.CheckUID(ZeroUID), 'CheckUID on all-zero UID = false');

  if G_ClientP2PValid then
  begin
    Check(LF.CheckP2PName(G_ClientP2PName),
      Format('CheckP2PName("%s") = true', [G_ClientP2PName]));
    Check(LF.CheckP2PNameApi(G_ClientP2PName, 'echo'),
      'CheckP2PNameApi(discovered, "echo") = true');
    Check(not LF.CheckP2PNameApi(G_ClientP2PName, '__no_such_api__'),
      'CheckP2PNameApi(discovered, missing) = false');
  end
  else
  begin
    Check(False, 'P2PName was not discovered, cannot run CheckP2PName tests');
  end;

  Check(not LF.CheckP2PName('__no_such_p2p__'),
    'CheckP2PName(missing) = false');
end;

// ---------------------------------------------------------------------------
// Concurrency
// ---------------------------------------------------------------------------

type
  TConcThread = class(TThread)
  private
    FTid: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ATid: Integer);
  end;

constructor TConcThread.Create(ATid: Integer);
begin
  inherited Create(True);
  FTid := ATid;
end;

procedure TConcThread.Execute;
var
  I: Integer;
  Req, Res: LF.TDataHandle;
  A, B, V: Int32;
begin
  for I := 1 to CONC_CALLS_PER_THR do
  begin
    A := FTid * 1000 + I;
    B := I * 3;
    Req := NewReq('add');
    try
      Req.WriteInt32(A); Req.WriteInt32(B);
      Res := LF.CallApp(SERVER_APP, Req, G_Config.TimeoutMs);
      if Res <> nil then
      begin
        try
          if Res.GetSize >= 4 then
          begin
            Res.SetPos(0);
            V := Res.ReadInt32;
            if V = A + B then
            begin
              G_ConcLock.Enter;
              try Inc(G_ConcOK); finally G_ConcLock.Leave; end;
            end
            else
            begin
              G_ConcLock.Enter;
              try Inc(G_ConcBad); finally G_ConcLock.Leave; end;
            end;
          end
          else
          begin
            G_ConcLock.Enter;
            try Inc(G_ConcBad); finally G_ConcLock.Leave; end;
          end;
        finally Res.Free; end;
      end
      else
      begin
        G_ConcLock.Enter;
        try Inc(G_ConcBad); finally G_ConcLock.Leave; end;
      end;
    finally Req.Free; end;
  end;
end;

procedure Test_Concurrency;
var
  Threads: array[0..CONC_THREADS - 1] of TConcThread;
  I: Integer;
begin
  LogSection(Format('Section: Concurrency - %d threads x %d calls',
    [CONC_THREADS, CONC_CALLS_PER_THR]));

  if G_Config.SkipConcurrency then
  begin
    LogInfo('  skipped (--skip-concurrency)');
    Exit;
  end;

  G_ConcLock := TCriticalSection.Create;
  G_ConcOK := 0;
  G_ConcBad := 0;
  try
    for I := 0 to CONC_THREADS - 1 do
      Threads[I] := TConcThread.Create(I);
    for I := 0 to CONC_THREADS - 1 do
      Threads[I].Start;
    for I := 0 to CONC_THREADS - 1 do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;

    Check(G_ConcOK = CONC_THREADS * CONC_CALLS_PER_THR,
      Format('concurrent OK=%d bad=%d of %d',
        [G_ConcOK, G_ConcBad, CONC_THREADS * CONC_CALLS_PER_THR]));
  finally
    G_ConcLock.Free;
    G_ConcLock := nil;
  end;
end;

// ---------------------------------------------------------------------------

procedure Test_ErrorPaths;
var
  Req, Res: LF.TDataHandle;
  Ok: Boolean;
begin
  LogSection('Section: Error paths');

  Req := NewReq('__no_such_api__');
  try
    Res := LF.CallApp(SERVER_APP, Req, 1500);
    try
      Ok := (Res = nil) or (Res.GetSize = 0);
      Check(Ok, 'unknown API returns empty');
    finally Res.Free; end;
  finally Req.Free; end;

  Req := NewReq('div');
  try
    Req.WriteInt32(1); Req.WriteInt32(0);
    Res := LF.CallApp(SERVER_APP, Req, 1500);
    try
      Ok := (Res = nil) or (Res.GetSize = 0);
      Check(Ok, 'div by zero returns empty');
    finally Res.Free; end;
  finally Req.Free; end;

  Check(LF.CheckApp('__no_such_app__') = False, 'CheckApp unknown = false');
  Check(LF.CheckApi(SERVER_APP, '__no_such_api__') = False,
    'CheckApi unknown = false');
  Check(LF.CheckApp(SERVER_APP) = True, 'CheckApp known = true');
  Check(LF.CheckApi(SERVER_APP, 'add') = True, 'CheckApi known add = true');
  Check(LF.CheckApi(SERVER_APP, 'md5') = True, 'CheckApi known md5 = true');
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

var
  ConsoleThread: TConsoleListener;
  LastStats, LastSentinel: TTimeTick;
  NowTick: TTimeTick;
  Rc: Integer;

begin
  New(G_Running);
  G_Running^ := True;
  G_StartTick := GetTimeTick;
  G_OutputLock := TCriticalSection.Create;
  G_AsyncLock := TCriticalSection.Create;
  try
    G_Config := ParseCmdLine;
    SERVER_APP := G_Config.ServerApp;
    OpenLog(G_Config.LogFile);

    EmitLine('============================================================');
    EmitLine('LingoFuse_ClientTest v' + LF_TEST_EDITION);
    EmitLine('Start: ' + DateTimeToStr(Now));
    EmitLine('============================================================');
    LogInfo('server       = ' + G_Config.ServerApp + ' @ ' + G_Config.ServerAddr);
    LogInfo('client app   = ' + G_Config.ClientApp);
    LogInfo('client p2p   = ' + G_Config.ClientP2PName);
    LogInfo('timeout      = ' + IntToStr(G_Config.TimeoutMs) + ' ms');
    if G_Config.Heavy then LogInfo('heavy        = on') else LogInfo('heavy        = off');
    if G_Config.SkipConcurrency then LogInfo('concurrency  = off');

    if FileExists(G_Config.SentinelFile) then
    begin
      try DeleteFile(G_Config.SentinelFile); except end;
    end;

    InstallSignalHandlers;

    LF.Set_Opt_Quiet(G_Config.Quiet);
    LF.Set_Opt_ConsoleOutput(G_Config.ConsoleOutput);
    LF.Set_Opt_Wait_Connection_Timeout(15000);
    LF.Set_Opt_Wait_Connection_ReadyOk(True);
    LF.Set_Opt_Overlap_Connection(True);
    LF.Set_Opt_P2P_Name(G_Config.ClientP2PName);

    LF.Sync;

    G_ClientApp := LF.TAppHandle.Create(G_Config.ClientApp, 'LingoFuse client self-test app');
    G_ClientApp.RegisterCall('echo', 'echo back string', nil, @Cb_Self_Echo);
    G_ClientApp.RegisterCall('add', 'int32+int32 -> int32', nil, @Cb_Self_Add);
    G_ClientApp.RegisterCall('seq_noop', 'int32 -> int32', nil, @Cb_Self_SeqNoop);
    G_ClientApp.RegisterNotify('log', 'log string', nil, @Cb_Self_Log);

    LF_ResetPrepare;
    Rc := LF_PrepareClientEx(G_Config.ServerAddr, G_ClientApp.Handle);
    if Rc = -1 then
    begin
      LogFatal('PrepareClient returned -1');
      SetStopReason('connect-failed');
      Rc := -1;
    end
    else if LF_PrepareDone <> 1 then
    begin
      LogFatal('PrepareDone failed');
      SetStopReason('connect-timeout');
      Rc := -1;
    end
    else
      Rc := 0;

    if Rc = 0 then
    begin
      LogReady(G_Config.ServerAddr);

      if not G_Config.NoConsoleListener then
      begin
        ConsoleThread := TConsoleListener.Create(True);
        ConsoleThread.FreeOnTerminate := True;
        ConsoleThread.Start;
      end;

      Sleep(500);
      Z.Core.Check_Soft_Thread_Synchronize(10);
      try LF.Sync; except end;

      LastStats := GetTimeTick;
      LastSentinel := GetTimeTick;

      try
        Test_Arithmetic;
        Test_String;
        Test_Encoding;
        Test_Hash;
        Test_Random;
        Test_Time;
        Test_BigPayload;
        Test_Info;
        Test_Counter;
        Test_Sequence;
        Test_Identity_Discovery;
        Test_UID_Call;
        Test_UID_Async_Call;
        Test_UID_Async_Sequenced_Call;
        Test_UID_Notify;
        Test_UID_Sequenced_Notify;
        Test_P2PName_Call;
        Test_P2PName_Async_Call;
        Test_P2PName_Async_Sequenced_Call;
        Test_P2PName_Notify;
        Test_P2PName_Sequenced_Notify;
        Test_Check_Identity;
        Test_Async_Single;
        Test_Async_Batch10;
        Test_Async_Sequenced;
        Test_Notify;
        Test_Concurrency;
        Test_ErrorPaths;
      except
        on Ex: Exception do
        begin
          LogFatal('unexpected exception during tests: ' + Ex.ClassName + ': ' + Ex.Message);
          Inc(G_Fail);
        end;
      end;

      while G_Running^ do
      begin
        Z.Core.Check_Soft_Thread_Synchronize(10);
        try LF.Sync; except end;
        NowTick := GetTimeTick;

        if (NowTick - LastStats) >= STATS_INTERVAL_MS then
        begin
          EmitStats;
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

        if not G_Running^ then Break;
        if (G_Pass + G_Fail) > 0 then Break;

        Sleep(MAIN_LOOP_SLEEP_MS);
      end;
    end;

    EmitLine('');
    EmitLine('============================================================');
    EmitLine('  TEST SUMMARY');
    EmitLine('============================================================');
    EmitLine(Format('[SUMMARY] pass=%d fail=%d total=%d uptime_ms=%d',
      [G_Pass, G_Fail, G_Pass + G_Fail, GetTimeTick - G_StartTick]));

    if G_StopReason = '' then SetStopReason('normal');
    EmitLine(Format('[SHUTDOWN] reason=%s', [G_StopReason]));

    try LF_ExitMainThread; except end;

    if G_ClientApp <> nil then
    begin
      try G_ClientApp.Free; except end;
      G_ClientApp := nil;
    end;

    try LF_Shutdown; except end;
    try
      if FileExists(G_Config.SentinelFile) then
        DeleteFile(G_Config.SentinelFile);
    except
    end;

    if Rc <> 0 then
      ExitCode := 2
    else if G_Fail > 0 then
      ExitCode := 1
    else
      ExitCode := 0;
  finally
    CloseLog;
    if G_AsyncLock <> nil then G_AsyncLock.Free;
    if G_Running <> nil then
    begin
      Dispose(G_Running);
      G_Running := nil;
    end;
    if G_OutputLock <> nil then G_OutputLock.Free;
  end;
end.
