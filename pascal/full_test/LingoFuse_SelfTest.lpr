(*
 * LingoFuse_SelfTest - comprehensive local API test suite
 *
 * Covers every LF_* function that does not require a live network peer.
 * Includes typed IO, application lifecycle, registration matrix,
 * local execution, options, status, queries, network-event hooks,
 * sync pump, concurrency, and multi-application scenario simulation.
 *
 * Runtime: writes LingoFuse_SelfTest.log in the working directory.
 * Exit code: 0 always (informational).
 *)

program LingoFuse_SelfTest;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$MODESWITCH NestedProcVars}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
{$endif}
{$APPTYPE CONSOLE}

uses
  {$ifdef UNIX}cthreads,{$endif}
  {$ifdef MSWINDOWS}Windows,{$endif}
  Classes, SysUtils, SyncObjs,
  lingofuse_helper, lingofuse_import,
  Z.Core, Z.UnicodeMixedLib, Z.PascalStrings, Z.UPascalStrings;

const
  LOG_FILE = 'LingoFuse_SelfTest.log';

var
  LogFileHandle: TextFile;
  LogOpened: Boolean = False;
  LogLock: TCriticalSection = nil;
  PassCount: Integer = 0;
  FailCount: Integer = 0;
  G_Start_Tick: TTimeTick = 0;

function TickOf: TTimeTick; inline;
begin
  Result := GetTimeTick - G_Start_Tick;
end;

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

procedure CWrite(const S: string);
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

procedure CWriteLn(const S: string = '');
begin
  if S <> '' then CWrite(S);
  {$ifdef MSWINDOWS}
  CWrite(sLineBreak);
  {$else}
  WriteLn;
  {$endif}
end;

procedure LogRaw(const S: string);
begin
  if LogLock <> nil then LogLock.Enter;
  try
    if LogOpened then
    begin
      WriteLn(LogFileHandle, S);
      Flush(LogFileHandle);
    end;
    CWriteLn(S);
  finally
    if LogLock <> nil then LogLock.Leave;
  end;
end;

procedure LogOpen(const FN: string);
begin
  AssignFile(LogFileHandle, FN);
  Rewrite(LogFileHandle);
  LogOpened := True;
end;

procedure LogClose;
begin
  if LogOpened then
  begin
    CloseFile(LogFileHandle);
    LogOpened := False;
  end;
end;

procedure LogSub(const S: string);
begin
  LogRaw('');
  LogRaw('-- ' + S);
end;

procedure LogStep(const S: string);
begin
  LogRaw('');
  LogRaw('============================================================');
  LogRaw('>>> SECTION: ' + S + ' @tick=' + IntToStr(TickOf));
  LogRaw('============================================================');
end;

procedure LogPass(const S: string);
begin
  Inc(PassCount);
  LogRaw('[PASS] ' + S);
end;

procedure LogFail(const S: string);
begin
  Inc(FailCount);
  LogRaw('[FAIL] ' + S);
end;

procedure LogInfo(const S: string);
begin
  LogRaw('[INFO] ' + S);
end;

procedure Check(const Cond: Boolean; const Msg: string); inline;
begin
  if Cond then LogPass(Msg) else LogFail(Msg);
end;

// ---------------------------------------------------------------------------
// cdecl callbacks
// ---------------------------------------------------------------------------

procedure Cb_Add(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
    LF_WriteInt32(Output, A + B);
end;

procedure Cb_Sub(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
    LF_WriteInt32(Output, A - B);
end;

procedure Cb_Mul(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
    LF_WriteInt32(Output, A * B);
end;

procedure Cb_Div(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var A, B: Int32;
begin
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) and (B <> 0) then
    LF_WriteDouble(Output, A / B);
end;

procedure Cb_FullEcho(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var
  V8: Int8; V16: Int16; V32: Int32; V64: Int64;
  U8: UInt8; U16: UInt16; U32: UInt32; U64: UInt64;
  Sgl: Single; Dbl: Double; S: string; B: TBytes;
begin
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
end;

procedure Cb_StrUpper(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  LF_SetPos(Input, 0);
  if LF_ReadString(Input, S) then
    LF_WriteString(Output, UpperCase(S));
end;

procedure Cb_StrLower(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S: string;
begin
  LF_SetPos(Input, 0);
  if LF_ReadString(Input, S) then
    LF_WriteString(Output, LowerCase(S));
end;

procedure Cb_StrReverse(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S, R: string; I: Integer;
begin
  LF_SetPos(Input, 0);
  if LF_ReadString(Input, S) then
  begin
    SetLength(R, Length(S));
    for I := 1 to Length(S) do
      R[I] := S[Length(S) - I + 1];
    LF_WriteString(Output, R);
  end;
end;

procedure Cb_Base64Enc(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S, E: string;
begin
  LF_SetPos(Input, 0);
  if LF_ReadString(Input, S) then
  begin
    E := umlEncodeLineBASE64(TPascalString(S)).Text;
    LF_WriteString(Output, E);
  end;
end;

procedure Cb_Base64Dec(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var S, D: string;
begin
  LF_SetPos(Input, 0);
  if LF_ReadString(Input, S) then
  begin
    D := umlDecodeLineBASE64(TPascalString(S)).Text;
    LF_WriteString(Output, D);
  end;
end;

procedure Cb_Log(Trigger: Pointer; Input: TDataHnd___); cdecl;
var S: string;
begin
  LF_SetPos(Input, 0);
  if LF_ReadString(Input, S) then
    LogInfo('    [SRV-LOG] ' + S);
end;

procedure Cb_BigPayload(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var B: TBytes;
begin
  LF_SetPos(Input, 0);
  B := LF_ReadStringBytes(Input);
  LF_WriteStringBytes(Output, B);
end;

procedure Cb_Counter(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
var
  Ctr: PInteger absolute Trigger;
  Delta: Int32;
begin
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, Delta) then
  begin
    Inc(Ctr^, Delta);
    LF_WriteInt32(Output, Ctr^);
  end;
end;

// ---------------------------------------------------------------------------
// M-style callback host
// ---------------------------------------------------------------------------

type
  TM_Handler = class
  public
    CallCount: Integer;
    NotifyCount: Integer;
    LastValue: Int32;
    procedure DoAdd(Input, Output: TDataHnd___);
    procedure DoNotify(Input: TDataHnd___);
  end;

procedure TM_Handler.DoAdd(Input, Output: TDataHnd___);
var A, B: Int32;
begin
  LF_SetPos(Input, 0);
  if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
  begin
    LastValue := A + B;
    LF_WriteInt32(Output, LastValue);
    Inc(CallCount);
  end;
end;

procedure TM_Handler.DoNotify(Input: TDataHnd___);
var S: string;
begin
  LF_SetPos(Input, 0);
  LF_ReadString(Input, S);
  Inc(NotifyCount);
end;

// ---------------------------------------------------------------------------
// Section: DataHandle basic
// ---------------------------------------------------------------------------

procedure T_DataHandle_Create;
var H: LF.TDataHandle;
begin
  LogSub('DataHandle.Create / Create_Permanent / Free');

  H := LF.TDataHandle.Create('api1');
  Check(H <> nil, 'TDataHandle.Create');
  Check(H.Handle <> nil, 'Handle non-nil');
  H.Free;

  H := LF.TDataHandle.Create_Permanent('api2');
  Check(H <> nil, 'TDataHandle.Create_Permanent');
  H.Free;

  LF_FreeData(nil);
  LogPass('LF_FreeData(nil) is safe');

  H := LF.TDataHandle.Create(TDataHnd___(nil), False);
  Check(H.Handle = nil, 'Create(nil) safe');
  H.Free;

  H := LF.TDataHandle.Create('non-own');
  Check(H.Handle <> nil, 'non-own Create keeps handle');
  H.Free;
end;

procedure T_DataHandle_TypedIO;
var
  H: LF.TDataHandle;
  V8: Int8; V16: Int16; V32: Int32; V64: Int64;
  U8: UInt8; U16: UInt16; U32: UInt32; U64: UInt64;
  Sgl: Single; Dbl: Double; Str: string;
begin
  LogSub('DataHandle typed IO roundtrip');

  H := LF.TDataHandle.Create('typed');
  H.WriteInt8(-100);
  H.WriteInt16(-30000);
  H.WriteInt32(-2000000000);
  H.WriteInt64(Int64(-8000000000000000000));
  H.WriteUInt8(200);
  H.WriteUInt16(60000);
  H.WriteUInt32(4000000000);
  H.WriteUInt64(UInt64(18000000000000000000));
  H.WriteSingle(1.5);
  H.WriteDouble(2.5);
  H.WriteString('xyz');

  H.SetPos(0);
  Check(H.ReadInt8(V8) and (V8 = -100), 'ReadInt8');
  Check(H.ReadInt16(V16) and (V16 = -30000), 'ReadInt16');
  Check(H.ReadInt32(V32) and (V32 = -2000000000), 'ReadInt32');
  Check(H.ReadInt64(V64) and (V64 = Int64(-8000000000000000000)), 'ReadInt64');
  Check(H.ReadUInt8(U8) and (U8 = 200), 'ReadUInt8');
  Check(H.ReadUInt16(U16) and (U16 = 60000), 'ReadUInt16');
  Check(H.ReadUInt32(U32) and (U32 = 4000000000), 'ReadUInt32');
  Check(H.ReadUInt64(U64) and (U64 = UInt64(18000000000000000000)), 'ReadUInt64');
  Check(H.ReadSingle(Sgl) and (Abs(Sgl - 1.5) < 1e-5), 'ReadSingle');
  Check(H.ReadDouble(Dbl) and (Abs(Dbl - 2.5) < 1e-9), 'ReadDouble');
  Check(H.ReadString(Str) and (Str = 'xyz'), 'ReadString');

  H.SetPos(0);
  Check(H.ReadInt8 = -100, 'ReadInt8 no-out');
  Check(H.ReadInt16 = -30000, 'ReadInt16 no-out');
  Check(H.ReadInt32 = -2000000000, 'ReadInt32 no-out');
  Check(H.ReadInt64 = Int64(-8000000000000000000), 'ReadInt64 no-out');
  Check(H.ReadUInt8 = 200, 'ReadUInt8 no-out');
  Check(H.ReadUInt16 = 60000, 'ReadUInt16 no-out');
  Check(H.ReadUInt32 = 4000000000, 'ReadUInt32 no-out');
  Check(H.ReadUInt64 = UInt64(18000000000000000000), 'ReadUInt64 no-out');
  Check(Abs(H.ReadSingle - 1.5) < 1e-5, 'ReadSingle no-out');
  Check(Abs(H.ReadDouble - 2.5) < 1e-9, 'ReadDouble no-out');
  Check(H.ReadString = 'xyz', 'ReadString no-out');

  H.Free;
end;

procedure T_DataHandle_Extreme;
var H: LF.TDataHandle;
begin
  LogSub('DataHandle extreme values');

  H := LF.TDataHandle.Create('extreme');
  H.WriteInt8(-128); H.WriteInt8(127);
  H.WriteUInt8(0); H.WriteUInt8(255);
  H.WriteInt16(-32768); H.WriteInt16(32767);
  H.WriteUInt16(0); H.WriteUInt16(65535);
  H.WriteInt32(Low(Int32)); H.WriteInt32(High(Int32));
  H.WriteUInt32(0); H.WriteUInt32(High(UInt32));
  H.WriteInt64(Int64(-9223372036854775807));
  H.WriteInt64(Int64(9223372036854775807));
  H.WriteUInt64(0); H.WriteUInt64(High(UInt64));
  H.WriteSingle(0.0); H.WriteSingle(1.0e30);
  H.WriteDouble(0.0); H.WriteDouble(1.0e300);

  H.SetPos(0);
  Check(H.ReadInt8 = -128, 'Int8 min');
  Check(H.ReadInt8 = 127, 'Int8 max');
  Check(H.ReadUInt8 = 0, 'UInt8 min');
  Check(H.ReadUInt8 = 255, 'UInt8 max');
  Check(H.ReadInt16 = -32768, 'Int16 min');
  Check(H.ReadInt16 = 32767, 'Int16 max');
  Check(H.ReadUInt16 = 0, 'UInt16 min');
  Check(H.ReadUInt16 = 65535, 'UInt16 max');
  Check(H.ReadInt32 = Low(Int32), 'Int32 min');
  Check(H.ReadInt32 = High(Int32), 'Int32 max');
  Check(H.ReadUInt32 = 0, 'UInt32 min');
  Check(H.ReadUInt32 = High(UInt32), 'UInt32 max');
  Check(H.ReadInt64 = Int64(-9223372036854775807), 'Int64 min');
  Check(H.ReadInt64 = Int64(9223372036854775807), 'Int64 max');
  Check(H.ReadUInt64 = 0, 'UInt64 min');
  Check(H.ReadUInt64 = High(UInt64), 'UInt64 max');
  Check(H.ReadSingle = 0.0, 'Single zero');
  Check(Abs(H.ReadSingle - 1.0e30) / 1.0e30 < 1e-5, 'Single large');
  Check(H.ReadDouble = 0.0, 'Double zero');
  Check(H.ReadDouble = 1.0e300, 'Double large');

  H.Free;
end;

procedure T_DataHandle_Empty;
var H: LF.TDataHandle; S: string; B: TBytes;
begin
  LogSub('DataHandle empty string / bytes');

  H := LF.TDataHandle.Create('empty');

  H.SetSize(0);
  H.WriteString('');
  H.SetPos(0);
  Check(H.ReadString(S) and (S = ''), 'empty string roundtrip');

  H.SetSize(0);
  SetLength(B, 0);
  H.WriteStringBytes(B);
  H.SetPos(0);
  Check(H.ReadStringBytes(B) and (Length(B) = 0), 'empty bytes roundtrip');

  H.SetSize(0);
  Check(H.ReadString = '', 'ReadString on empty returns empty');
  Check(Length(H.ReadStringBytes) = 0, 'ReadStringBytes on empty returns empty');

  H.Free;
end;

procedure T_DataHandle_LargeString;
const N = 1 * 1024 * 1024;
var H: LF.TDataHandle; InS, OutS: string; I: Integer;
begin
  LogSub('DataHandle 1MB string roundtrip');

  SetLength(InS, N);
  for I := 1 to N do
    InS[I] := Char(Ord('A') + (I mod 26));

  H := LF.TDataHandle.Create('big');
  H.WriteString(InS);
  H.SetPos(0);
  Check(H.ReadString(OutS) and (Length(OutS) = N) and (OutS = InS),
    '1MB string roundtrip');
  H.Free;
end;

procedure T_DataHandle_BufferSize;
var
  H: LF.TDataHandle;
  Buf: array[0..255] of Byte;
  I: Integer;
  P: Pointer;
  Sz: Int64;
begin
  LogSub('DataHandle buffer/offset/size');

  H := LF.TDataHandle.Create('buf');
  for I := 0 to 255 do Buf[I] := Byte(I);
  H.WriteBuffer(Buf, SizeOf(Buf));

  H.SetPos(0);
  Check(H.GetBuffer <> nil, 'GetBuffer non-nil');
  P := H.GetBufferOffset(0);
  Check(P <> nil, 'GetBufferOffset(0)');
  P := H.GetBufferOffset(128);
  Check(P <> nil, 'GetBufferOffset(128)');

  Sz := H.GetSize;
  Check(Sz = 256, 'GetSize = 256');

  H.SetSize(128);
  Check(H.GetSize = 128, 'SetSize(128)');
  H.SetSize(512);
  Check(H.GetSize = 512, 'SetSize(512) growth');
  H.SetSize(0);
  Check(H.GetSize = 0, 'SetSize(0)');

  H.Free;
end;

procedure T_DataHandle_Pos;
var H: LF.TDataHandle;
begin
  LogSub('DataHandle position');

  H := LF.TDataHandle.Create('pos');
  H.WriteInt32(1); H.WriteInt32(2); H.WriteInt32(3);

  H.SetPos(0);
  Check(H.GetPos = 0, 'SetPos(0)');
  H.SetPos(4);
  Check(H.GetPos = 4, 'SetPos(4)');
  H.SetPos(12);
  Check(H.GetPos = 12, 'SetPos(12)');
  H.SetPos(1000000);
  Check(H.GetPos = 1000000, 'SetPos(beyond)');
  H.Free;
end;

procedure T_DataHandle_Partial_Zero;
var
  H: LF.TDataHandle;
  Buf: array[0..127] of Byte;
  N: Int64;
  B: Byte;
begin
  LogSub('DataHandle partial read / zero-length write');

  H := LF.TDataHandle.Create('pz');
  H.SetSize(0);
  H.WriteUInt8(1); H.WriteUInt8(2); H.WriteUInt8(3);
  H.SetPos(0);
  N := H.ReadBuffer(Buf, 128);
  Check(N = 3, 'partial read returns 3');

  H.SetSize(0);
  B := 42;
  N := H.WriteBuffer(B, 0);
  Check(N = 0, 'zero-length write returns 0');
  Check(H.GetSize = 0, 'size stays 0');

  H.Free;
end;

procedure T_DataHandle_P2P;
var
  H: LF.TDataHandle;
  UID: TP2P_UID___;
  N: string;
  AllZero: Boolean;
  I: Integer;
begin
  LogSub('DataHandle Get_P2P_UID / Get_P2P_Name');

  H := LF.TDataHandle.Create('p2p');
  UID := H.Get_P2P_UID^;
  AllZero := True;
  for I := 0 to High(UID) do
    if UID[I] <> 0 then begin AllZero := False; Break; end;
  Check(AllZero, 'Get_P2P_UID all-zero for fresh handle');

  N := H.Get_P2P_Name;
  Check(N = '', 'Get_P2P_Name empty for fresh handle');

  UID := LF_Get_P2P_UID(H.Handle)^;
  Check(UID[0] = 0, 'LF_Get_P2P_UID direct');
  Check(LF_Get_P2P_NameEx(H.Handle) = '', 'LF_Get_P2P_NameEx direct');

  H.Free;
end;

procedure T_DataHandle_StringBytes;
var
  H: LF.TDataHandle;
  InB, OutB: TBytes;
  I: Integer;
  Ok: Boolean;
begin
  LogSub('DataHandle StringBytes roundtrip (non-ASCII)');

  SetLength(InB, 512);
  for I := 0 to 511 do
    InB[I] := Byte((I mod 255) + 1);

  H := LF.TDataHandle.Create('sb');
  H.WriteStringBytes(InB);
  H.SetPos(0);
  Ok := H.ReadStringBytes(OutB) and (Length(OutB) = 512);
  if Ok then
    for I := 0 to 511 do
      if OutB[I] <> InB[I] then
      begin
        Ok := False;
        Break;
      end;
  Check(Ok, '512-byte StringBytes roundtrip');
  H.Free;
end;

procedure T_DataHandle_RawWrappers;
var
  Hnd: TDataHnd___;
  V: Int32;
  Buf: array[0..7] of Byte;
  N: Int64;
begin
  LogSub('Direct raw LF_* wrappers on data handle');

  Hnd := LF_CreateDataEx('raw');
  Check(Hnd <> nil, 'LF_CreateDataEx');
  Check(LF_WriteInt32(Hnd, 12345), 'LF_WriteInt32');
  Check(LF_GetPos(Hnd) = 4, 'LF_GetPos after write = 4');
  Check(LF_GetSize(Hnd) = 4, 'LF_GetSize after write = 4');
  LF_SetPos(Hnd, 0);
  Check(LF_ReadInt32(Hnd, V) and (V = 12345), 'LF_ReadInt32');
  LF_SetPos(Hnd, 0);
  N := LF_ReadBuffer(Hnd, @Buf[0], SizeOf(Buf));
  Check(N = 4, 'partial read returns 4');

  LF_FreeData(Hnd);
  LogPass('LF_FreeData');

  Hnd := LF_CreateDataEx('raw2');
  LF_SetSize(Hnd, 100);
  Check(LF_GetSize(Hnd) = 100, 'LF_SetSize');
  LF_FreeData(Hnd);

  Hnd := LF_CreateDataEx('raw3');
  LF_WriteString(Hnd, 'hello');
  LF_SetPos(Hnd, 0);
  Check(LF_ReadString(Hnd) = 'hello', 'LF_WriteString / LF_ReadString');
  LF_FreeData(Hnd);
end;

// ---------------------------------------------------------------------------
// Section: AppHandle
// ---------------------------------------------------------------------------

procedure T_App_Handle;
var A: LF.TAppHandle; N: string;
begin
  LogSub('AppHandle create/free/name');

  A := LF.TAppHandle.Create('AppX', 'desc');
  Check(A <> nil, 'Create named app');
  Check(A.Name = 'AppX', 'Name property');

  N := LF.Get_AppName(A);
  Check(N = 'AppX', 'LF_Get_AppName');

  A.Free;

  A := LF.TAppHandle.Create('', 'empty');
  Check(A <> nil, 'Create empty-name app');
  A.Free;

  N := LF.Generate_AppName;
  Check(N <> '', 'LF_Generate_AppName non-empty');

  A := LF.TAppHandle.Create('AppY', 'y');
  Check(A.Handle <> nil, 'Direct handle non-nil');
  A.Free;
end;

procedure T_App_Multiple;
var
  A, B, C: LF.TAppHandle;
  Req, Res: LF.TDataHandle;
begin
  LogSub('AppHandle multiple coexisting');

  A := LF.TAppHandle.Create('Multi_A', '');
  B := LF.TAppHandle.Create('Multi_B', '');
  C := LF.TAppHandle.Create('Multi_C', '');
  try
    Check(A.RegisterCall('add', 'add', nil, @Cb_Add), 'A register');
    Check(B.RegisterCall('add', 'add', nil, @Cb_Add), 'B register');
    Check(C.RegisterCall('add', 'add', nil, @Cb_Add), 'C register');

    Req := LF.TDataHandle.Create('add');
    try
      Req.WriteInt32(1); Req.WriteInt32(2);
      Res := B.LocalCall(Req);
      try Check(Res.ReadInt32 = 3, 'B adds 1+2=3'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('add');
    try
      Req.WriteInt32(10); Req.WriteInt32(20);
      Res := C.LocalCall(Req);
      try Check(Res.ReadInt32 = 30, 'C adds 10+20=30'); finally Res.Free; end;
    finally Req.Free; end;
  finally
    A.Free; B.Free; C.Free;
  end;
end;

procedure T_Bind_No_Net;
var A: LF.TAppHandle; R: Integer;
begin
  LogSub('LF_BindApp without network');
  A := LF.TAppHandle.Create('BindApp', '');
  try
    R := LF.BindApp(A);
    Check(R = 0, 'BindApp returns 0 without network');
  finally A.Free; end;
end;

procedure T_App_UTF8;
var A: LF.TAppHandle; N: string;
begin
  LogSub('AppHandle UTF-8 name');
  A := LF.TAppHandle.Create('中文App', '测试描述');
  try
    Check(A.Handle <> nil, 'UTF-8 app handle');
    N := A.Name;
    Check(N = '中文App', 'UTF-8 app name preserved');
  finally A.Free; end;
end;

// ---------------------------------------------------------------------------
// Section: Registration
// ---------------------------------------------------------------------------

procedure T_Reg_Call_Cdecl;
var A: LF.TAppHandle; Req, Res: LF.TDataHandle;
begin
  LogSub('RegisterCall cdecl');
  A := LF.TAppHandle.Create('RegC', '');
  try
    Check(A.RegisterCall('add', 'add', nil, @Cb_Add), 'register');
    Req := LF.TDataHandle.Create('add');
    try
      Req.WriteInt32(5); Req.WriteInt32(7);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 12, 'call 5+7=12'); finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_Reg_Call_M;
var A: LF.TAppHandle; M: TM_Handler; Req, Res: LF.TDataHandle;
begin
  LogSub('RegisterCall_M / RegisterSyncCall_M');
  M := TM_Handler.Create;
  A := LF.TAppHandle.Create('RegM', '');
  try
    Check(A.RegisterCall('add', 'add', M.DoAdd), 'RegisterCall_M');
    Req := LF.TDataHandle.Create('add');
    try
      Req.WriteInt32(3); Req.WriteInt32(9);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 12, 'M call 3+9=12'); finally Res.Free; end;
    finally Req.Free; end;
    Check(M.CallCount = 1, 'M handler invoked once');
    A.Unregister('add');

    Check(A.RegisterCallSync('add2', 'add2', M.DoAdd), 'RegisterSyncCall_M');
    Req := LF.TDataHandle.Create('add2');
    try
      Req.WriteInt32(4); Req.WriteInt32(8);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 12, 'Sync M call 4+8=12'); finally Res.Free; end;
    finally Req.Free; end;
  finally
    A.Free;
    M.Free;
  end;
end;

procedure T_Reg_Call_P;
var
  A: LF.TAppHandle; Req, Res: LF.TDataHandle;
  procedure OnP(Input, Output: TDataHnd___);
  var X, Y: Int32;
  begin
    LF_SetPos(Input, 0);
    LF_ReadInt32(Input, X);
    LF_ReadInt32(Input, Y);
    LF_WriteInt32(Output, X + Y);
  end;
begin
  LogSub('RegisterCall_P / RegisterSyncCall_P');
  A := LF.TAppHandle.Create('RegP', '');
  try
    Check(A.RegisterCall_P('add', 'add', OnP), 'RegisterCall_P');
    Req := LF.TDataHandle.Create('add');
    try
      Req.WriteInt32(4); Req.WriteInt32(6);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 10, 'P call 4+6=10'); finally Res.Free; end;
    finally Req.Free; end;
    A.Unregister('add');

    Check(A.RegisterCallSync_P('add2', 'add2', OnP), 'RegisterSyncCall_P');
    Req := LF.TDataHandle.Create('add2');
    try
      Req.WriteInt32(7); Req.WriteInt32(8);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 15, 'Sync P call 7+8=15'); finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_Reg_Notify_Cdecl;
var A: LF.TAppHandle; Req: LF.TDataHandle;
begin
  LogSub('RegisterNotify cdecl');
  A := LF.TAppHandle.Create('RegN', '');
  try
    Check(A.RegisterNotify('log', 'log', nil, @Cb_Log), 'register');
    Req := LF.TDataHandle.Create('log');
    try
      Req.WriteString('hello-notify');
      A.LocalNotify(Req);
      LogPass('LocalNotify dispatched');
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_Reg_Notify_M;
var A: LF.TAppHandle; M: TM_Handler; Req: LF.TDataHandle;
begin
  LogSub('RegisterNotify_M / RegisterSyncNotify_M');
  M := TM_Handler.Create;
  A := LF.TAppHandle.Create('RegNM', '');
  try
    Check(A.RegisterNotify('log', 'log', M.DoNotify), 'RegisterNotify_M');
    Req := LF.TDataHandle.Create('log');
    try
      Req.WriteString('x');
      A.LocalNotify(Req);
      Check(M.NotifyCount = 1, 'Notify handler invoked');
    finally Req.Free; end;
    A.Unregister('log');

    Check(A.RegisterNotifySync('log2', 'log2', M.DoNotify), 'RegisterSyncNotify_M');
    Req := LF.TDataHandle.Create('log2');
    try
      Req.WriteString('y');
      A.LocalNotify(Req);
      Check(M.NotifyCount = 2, 'Sync Notify invoked');
    finally Req.Free; end;
  finally
    A.Free;
    M.Free;
  end;
end;

procedure T_Reg_Notify_P;
var
  A: LF.TAppHandle; Counter: Integer; Req: LF.TDataHandle;
  procedure OnP(Input: TDataHnd___);
  begin
    Inc(Counter);
  end;
begin
  LogSub('RegisterNotify_P / RegisterSyncNotify_P');
  Counter := 0;
  A := LF.TAppHandle.Create('RegNP', '');
  try
    Check(A.RegisterNotify_P('log', 'log', OnP), 'RegisterNotify_P');
    Req := LF.TDataHandle.Create('log');
    try
      Req.WriteString('x');
      A.LocalNotify(Req);
      Check(Counter = 1, 'P Notify invoked');
    finally Req.Free; end;
    A.Unregister('log');

    Check(A.RegisterNotifySync_P('log2', 'log2', OnP), 'RegisterSyncNotify_P');
    Req := LF.TDataHandle.Create('log2');
    try
      Req.WriteString('z');
      A.LocalNotify(Req);
      Check(Counter = 2, 'Sync P Notify invoked');
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_Reg_Duplicate_Unregister;
var A: LF.TAppHandle;
begin
  LogSub('Register duplicate / unregister / re-register');

  A := LF.TAppHandle.Create('RegD', '');
  try
    Check(A.RegisterCall('x', 'x', nil, @Cb_Add), 'first register');
    Check(not A.RegisterCall('x', 'x', nil, @Cb_Add), 'duplicate rejected');
    Check(A.Unregister('x'), 'unregister');
    Check(not A.Unregister('x'), 'unregister missing returns false');
    Check(A.RegisterCall('x', 'x', nil, @Cb_Add), 're-register after unregister');
    A.Unregister('x');
  finally A.Free; end;
end;

procedure T_Reg_UTF8;
var A: LF.TAppHandle; Req, Res: LF.TDataHandle;
begin
  LogSub('Register with UTF-8 names');

  A := LF.TAppHandle.Create('中文App2', '测试');
  try
    Check(A.RegisterCall('加法', '两数相加', nil, @Cb_Add), 'UTF-8 register call');
    Check(A.RegisterNotify('通知', '通知', nil, @Cb_Log), 'UTF-8 register notify');

    Req := LF.TDataHandle.Create('加法');
    try
      Req.WriteInt32(9); Req.WriteInt32(11);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 20, 'UTF-8 call 9+11=20'); finally Res.Free; end;
    finally Req.Free; end;

    Check(A.Unregister('加法'), 'UTF-8 unregister');
  finally A.Free; end;
end;

procedure T_P2P_Register_All;
var
  M: TM_Handler;
  procedure P2P_P(Input, Output: TDataHnd___);
  var X, Y: Int32;
  begin
    LF_SetPos(Input, 0);
    LF_ReadInt32(Input, X);
    LF_ReadInt32(Input, Y);
    LF_WriteInt32(Output, X + Y);
  end;
  procedure P2P_NP(Input: TDataHnd___);
  begin
  end;
begin
  LogSub('Process-wide P2P registration matrix');

  M := TM_Handler.Create;
  try
    Check(LF_Register_P2P_CallEx('p2p_c1', '', nil, @Cb_Add) = 1, 'P2P_CallEx');
    Check(LF_Unregister_P2PEx('p2p_c1') = 1, 'Unregister_P2PEx p2p_c1');

    Check(LF_Register_P2P_NotifyEx('p2p_n1', '', nil, @Cb_Log) = 1, 'P2P_NotifyEx');
    Check(LF_Unregister_P2PEx('p2p_n1') = 1, 'Unregister_P2PEx p2p_n1');

    Check(LF_Register_P2P_Call_M('p2p_c2', '', M.DoAdd) = 1, 'P2P_Call_M');
    Check(LF_Unregister_P2PEx('p2p_c2') = 1, 'unreg p2p_c2');

    Check(LF_Register_P2P_SyncCall_M('p2p_c3', '', M.DoAdd) = 1, 'P2P_SyncCall_M');
    Check(LF_Unregister_P2PEx('p2p_c3') = 1, 'unreg p2p_c3');

    Check(LF_Register_P2P_Notify_M('p2p_n2', '', M.DoNotify) = 1, 'P2P_Notify_M');
    Check(LF_Unregister_P2PEx('p2p_n2') = 1, 'unreg p2p_n2');

    Check(LF_Register_P2P_SyncNotify_M('p2p_n3', '', M.DoNotify) = 1, 'P2P_SyncNotify_M');
    Check(LF_Unregister_P2PEx('p2p_n3') = 1, 'unreg p2p_n3');

    Check(LF_Register_P2P_Call_P('p2p_c4', '', P2P_P) = 1, 'P2P_Call_P');
    Check(LF_Unregister_P2PEx('p2p_c4') = 1, 'unreg p2p_c4');

    Check(LF_Register_P2P_SyncCall_P('p2p_c5', '', P2P_P) = 1, 'P2P_SyncCall_P');
    Check(LF_Unregister_P2PEx('p2p_c5') = 1, 'unreg p2p_c5');

    Check(LF_Register_P2P_Notify_P('p2p_n4', '', P2P_NP) = 1, 'P2P_Notify_P');
    Check(LF_Unregister_P2PEx('p2p_n4') = 1, 'unreg p2p_n4');

    Check(LF_Register_P2P_SyncNotify_P('p2p_n5', '', P2P_NP) = 1, 'P2P_SyncNotify_P');
    Check(LF_Unregister_P2PEx('p2p_n5') = 1, 'unreg p2p_n5');

    Check(LF_Register_P2P_CallEx('p2p_dup', '', nil, @Cb_Add) = 1, 'p2p_dup first');
    Check(LF_Register_P2P_CallEx('p2p_dup', '', nil, @Cb_Add) = 0, 'p2p_dup duplicate rejected');
    Check(LF_Unregister_P2PEx('p2p_dup') = 1, 'p2p_dup unreg');
    Check(LF_Unregister_P2PEx('p2p_dup') = 0, 'p2p_dup unreg missing');
  finally M.Free; end;
end;

// ---------------------------------------------------------------------------
// Section: Local execution
// ---------------------------------------------------------------------------

procedure T_LocalCall_Unregistered;
var A: LF.TAppHandle; Req, Res: LF.TDataHandle;
begin
  LogSub('LocalCall to unregistered API');
  A := LF.TAppHandle.Create('UnregApp', '');
  try
    Req := LF.TDataHandle.Create('nonexistent');
    try
      Res := A.LocalCall(Req);
      try Check(Res.GetSize = 0, 'unregistered returns empty result'); finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_LocalCall_Full_IO;
var
  A: LF.TAppHandle;
  Req, Res: LF.TDataHandle;
  InB, OutB: TBytes;
  S: string;
  I: Integer;
  Ok: Boolean;
begin
  LogSub('LocalCall full-IO roundtrip');
  A := LF.TAppHandle.Create('FullIOApp', '');
  try
    Check(A.RegisterCall('fullio', 'echo all', nil, @Cb_FullEcho), 'register');

    SetLength(InB, 64);
    for I := 0 to 63 do
      InB[I] := Byte(I + 1);

    Req := LF.TDataHandle.Create('fullio');
    try
      Req.WriteInt8(-1);
      Req.WriteInt16(-1000);
      Req.WriteInt32(-100000);
      Req.WriteInt64(Int64(-10000000000));
      Req.WriteUInt8(200);
      Req.WriteUInt16(60000);
      Req.WriteUInt32(4000000000);
      Req.WriteUInt64(UInt64(17000000000000000000));
      Req.WriteSingle(3.25);
      Req.WriteDouble(6.5);
      Req.WriteString('full-io');
      Req.WriteStringBytes(InB);

      Res := A.LocalCall(Req);
      try
        Res.SetPos(0);
        Check(Res.ReadInt8 = -1, 'full io int8');
        Check(Res.ReadInt16 = -1000, 'full io int16');
        Check(Res.ReadInt32 = -100000, 'full io int32');
        Check(Res.ReadInt64 = Int64(-10000000000), 'full io int64');
        Check(Res.ReadUInt8 = 200, 'full io uint8');
        Check(Res.ReadUInt16 = 60000, 'full io uint16');
        Check(Res.ReadUInt32 = 4000000000, 'full io uint32');
        Check(Res.ReadUInt64 = UInt64(17000000000000000000), 'full io uint64');
        Check(Abs(Res.ReadSingle - 3.25) < 1e-5, 'full io single');
        Check(Abs(Res.ReadDouble - 6.5) < 1e-9, 'full io double');
        Res.ReadString(S);
        Check(S = 'full-io', 'full io string');
        SetLength(OutB, 0);
        Res.ReadStringBytes(OutB);
        Ok := Length(OutB) = 64;
        if Ok then
          for I := 0 to 63 do
            if OutB[I] <> InB[I] then
            begin
              Ok := False;
              Break;
            end;
        Check(Ok, 'full io bytes content');
      finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_LocalCall_Large_Payload;
const N = 4 * 1024 * 1024;
var
  A: LF.TAppHandle; Req, Res: LF.TDataHandle;
  InB, OutB: TBytes; I: Integer; Ok: Boolean;
begin
  LogSub('LocalCall 4MB payload');

  A := LF.TAppHandle.Create('BigIOApp', '');
  try
    Check(A.RegisterCall('bigio', 'big echo', nil, @Cb_BigPayload), 'register');

    SetLength(InB, N);
    for I := 0 to N - 1 do
      InB[I] := Byte((I mod 255) + 1);

    Req := LF.TDataHandle.Create('bigio');
    try
      Req.WriteStringBytes(InB);
      Res := A.LocalCall(Req);
      try
        SetLength(OutB, 0);
        Res.SetPos(0);
        Res.ReadStringBytes(OutB);
        Check(Length(OutB) = N, '4MB length matches');
        Ok := Length(OutB) = N;
        if Ok then
          for I := 0 to N - 1 do
            if OutB[I] <> InB[I] then
            begin
              Ok := False;
              Break;
            end;
        Check(Ok, '4MB content matches');
      finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_LocalCall_Repeated;
const N = 1000;
var
  A: LF.TAppHandle; Req, Res: LF.TDataHandle;
  I: Integer; AllOk: Boolean;
begin
  LogSub('LocalCall 1000 sequential');

  A := LF.TAppHandle.Create('RepApp', '');
  try
    A.RegisterCall('add', 'add', nil, @Cb_Add);
    AllOk := True;
    for I := 1 to N do
    begin
      Req := LF.TDataHandle.Create('add');
      try
        Req.WriteInt32(I); Req.WriteInt32(I * 2);
        Res := A.LocalCall(Req);
        try
          if Res.ReadInt32 <> I * 3 then
          begin
            AllOk := False;
            Break;
          end;
        finally Res.Free; end;
      finally Req.Free; end;
    end;
    Check(AllOk, Format('1000 sequential calls, last result correct', []));
  finally A.Free; end;
end;

// ---------------------------------------------------------------------------
// Section: Options
// ---------------------------------------------------------------------------

procedure T_Options_All;
var V: string;
begin
  LogSub('Options: full set/get matrix');

  LF_SetOptionEx('LF_P2P_name', 'x1');
  Check(LF_GetOptionEx('LF_P2P_name') = 'x1', 'SetOptionEx/GetOptionEx');

  LF.Set_Opt_P2P_Name('SelfTestP2P');
  Check(LF.Get_Opt_P2P_Name = 'SelfTestP2P', 'Set/Get P2P_Name');

  LF.Set_Opt_Password('passw0rd');
  Check(LF.Get_Opt_Password = '********', 'Password masked');

  LF.Set_Opt_Quiet(True);  Check(LF.Get_Opt_Quiet, 'Quiet True');
  LF.Set_Opt_Quiet(False); Check(not LF.Get_Opt_Quiet, 'Quiet False');
  LF.Set_Opt_Quiet(True);

  LF.Set_Opt_Overlap_Connection(True);
  Check(LF.Get_Opt_Overlap_Connection, 'Overlap True');
  LF.Set_Opt_Overlap_Connection(False);
  Check(not LF.Get_Opt_Overlap_Connection, 'Overlap False');
  LF.Set_Opt_Overlap_Connection(True);

  LF.Set_Opt_Wait_Connection_ReadyOk(True);
  Check(LF.Get_Opt_Wait_Connection_ReadyOk, 'WaitReadyOk True');
  LF.Set_Opt_Wait_Connection_ReadyOk(False);
  Check(not LF.Get_Opt_Wait_Connection_ReadyOk, 'WaitReadyOk False');
  LF.Set_Opt_Wait_Connection_ReadyOk(True);

  LF.Set_Opt_Wait_Connection_Timeout(20000);
  Check(LF.Get_Opt_Wait_Connection_Timeout = 20000, 'WaitTimeout 20000');

  LF.Set_Opt_ShowThreadID(False);
  Check(not LF.Get_Opt_ShowThreadID, 'ShowThreadID False');
  LF.Set_Opt_ShowThreadID(True);
  Check(LF.Get_Opt_ShowThreadID, 'ShowThreadID True');
  LF.Set_Opt_ShowThreadID(False);

  LF.Set_Opt_ConsoleOutput(True);
  Check(LF.Get_Opt_ConsoleOutput, 'ConsoleOutput True');
  LF.Set_Opt_ConsoleOutput(False);
  Check(not LF.Get_Opt_ConsoleOutput, 'ConsoleOutput False');
  LF.Set_Opt_ConsoleOutput(True);

  LF.Set_Opt_IPC_Serv_ThreadCount(4);
  Check(LF.Get_Opt_IPC_Serv_ThreadCount = 4, 'IPC thread count');

  LF.Set_Opt_IPC_Serv_MaxQueueLength(512);
  Check(LF.Get_Opt_IPC_Serv_MaxQueueLength = 512, 'IPC max queue');

  LF.Set_Opt_IPC_Serv_MaxMsgSize(2 * 1024 * 1024);
  Check(LF.Get_Opt_IPC_Serv_MaxMsgSize = 2 * 1024 * 1024, 'IPC max msg');

  LF.Set_Opt_Fixed_Sequenced_Time(25000);
  Check(LF.Get_Opt_Fixed_Sequenced_Time = 25000, 'Fixed_Sequenced_Time');

  LF.Set_Opt_DataHandle_Idle_Timeout(600000);
  Check(LF.Get_Opt_DataHandle_Idle_Timeout = 600000, 'DataHandle_Idle_Timeout');

  LF.Set_Opt_DataHandle_Pool_Scan_Interval(5000);
  Check(LF.Get_Opt_DataHandle_Pool_Scan_Interval = 5000, 'DataHandle_Scan');

  LF.Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(1000);
  Check(LF.Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold = 1000, 'NoReponse threshold');

  LF.Set_Opt_Debug('');
  V := LF.Get_Opt_Debug;
  Check(V <> '', 'Debug get returns non-empty');

  LF_SetOptionEx('__not_exist_option__', 'x');
  LogPass('unknown option set is safe');
  Check(LF_GetOptionEx('__not_exist_option__') = '', 'unknown option get is empty');
end;

// ---------------------------------------------------------------------------
// Section: Status
// ---------------------------------------------------------------------------

procedure T_Status_All;
var N, N2: Integer; S: string;
begin
  LogSub('Status: Post / Get / GetStatusCount');

  while LF.Get_Status_Num > 0 do LF.GetStatus;
  N := LF.Get_Status_Num;
  Check(N = 0, 'queue drained');

  LF.PostStatus('status one');
  LF.PostStatus('status two');
  LF_PostStatusEx('status three');

  N := LF.Get_Status_Num;
  Check(N >= 2, 'at least 2 statuses queued');

  S := LF.GetStatus;
  Check(S <> '', 'GetStatus returns non-empty');
  N2 := LF.Get_Status_Num;
  Check(N2 = N - 1, 'GetStatus consumed one entry');

  while LF.Get_Status_Num > 0 do LF.GetStatus;
  Check(LF.GetStatus = '', 'empty queue returns empty');
end;

procedure T_Status_Overflow;
const N = 1500;
var I: Integer;
begin
  LogSub('Status queue overflow (cap = 1000)');

  while LF.Get_Status_Num > 0 do LF.GetStatus;
  for I := 1 to N do
    LF.PostStatus('msg-' + IntToStr(I));

  I := LF.Get_Status_Num;
  Check(I <= 1100, Format('queue bounded (count=%d)', [I]));
  while LF.Get_Status_Num > 0 do LF.GetStatus;
  LogPass('queue drained after overflow');
end;

// ---------------------------------------------------------------------------
// Section: Queries
// ---------------------------------------------------------------------------

procedure T_Check_All;
var UID: TP2P_UID___;
begin
  LogSub('CheckMainThread / CheckApp / CheckApi / CheckUID / CheckP2PName');

  LogInfo('CheckMainThread = ' + BoolToStr(LF.CheckMainThread, True));

  Check(not LF.CheckApp('NoSuchApp_XYZ'), 'CheckApp missing = false');
  Check(not LF.CheckApi('NoSuchApp', 'noApi'), 'CheckApi missing = false');

  FillChar(UID, SizeOf(UID), 0);
  Check(not LF.CheckUID(UID), 'CheckUID all-zero = false');
  Check(not LF.CheckUIDApi(UID, 'noApi'), 'CheckUIDApi missing = false');
  Check(not LF.CheckP2PName('NoP2P'), 'CheckP2PName missing = false');
  Check(not LF.CheckP2PNameApi('NoP2P', 'noApi'), 'CheckP2PNameApi missing');
end;

procedure T_Check_All_Raw;
var UID: TP2P_UID___;
begin
  LogSub('Raw LF___ query wrappers');

  LogInfo('LF_CheckMainThread = ' + IntToStr(LF___.LF_CheckMainThread));
  LogInfo('LF_CheckMainThreadEx = ' + BoolToStr(LF___.LF_CheckMainThreadEx, True));

  Check(LF___.LF_CheckAppEx('NoSuchApp_XYZ') = False, 'LF_CheckAppEx missing');
  Check(LF___.LF_CheckApiEx('NoSuchApp', 'noApi') = False, 'LF_CheckApiEx missing');

  FillChar(UID, SizeOf(UID), 0);
  Check(LF___.LF_Check_UID(UID) = 0, 'LF_Check_UID all-zero');
  Check(LF___.LF_Check_UIDEx(UID) = False, 'LF_Check_UIDEx all-zero');
  Check(LF___.LF_Check_UID_Api(UID, 'noApi') = 0, 'LF_Check_UID_Api missing');
  Check(LF___.LF_Check_UID_ApiEx(UID, 'noApi') = False, 'LF_Check_UID_ApiEx missing');

  Check(LF___.LF_Check_P2PNAME('NoP2P') = 0, 'LF_Check_P2PNAME missing');
  Check(LF___.LF_Check_P2PNAMEEx('NoP2P') = False, 'LF_Check_P2PNAMEEx missing');
  Check(LF___.LF_Check_P2PNAME_Api('NoP2P', 'noApi') = 0, 'LF_Check_P2PNAME_Api');
  Check(LF___.LF_Check_P2PNAME_ApiEx('NoP2P', 'noApi') = False, 'LF_Check_P2PNAME_ApiEx');
end;

// ---------------------------------------------------------------------------
// Section: Network events / sync / reset
// ---------------------------------------------------------------------------

procedure NetEv(const addr: pansichar); cdecl;
begin
end;

procedure T_Network_Event;
begin
  LogSub('Set_Network_Event');

  LF.Set_Network_Event(@NetEv, @NetEv);
  LogPass('Set both handlers');

  LF.Set_Network_Event(nil, nil);
  LogPass('Clear both handlers');
end;

procedure T_Reset_Prepare;
begin
  LogSub('ResetPrepare idempotent');
  LF_ResetPrepare;
  LogPass('LF_ResetPrepare first call');
  LF_ResetPrepare;
  LogPass('LF_ResetPrepare second call');
end;

procedure T_Sync;
var N: Integer;
begin
  LogSub('LF_Sync callable');
  N := LF.Sync;
  LogInfo(Format('LF_Sync returned %d', [N]));
  LogPass('LF_Sync callable');
end;

// ---------------------------------------------------------------------------
// Section: Concurrency
// ---------------------------------------------------------------------------

var
  CL: TCriticalSection;
  CS_OK: Integer;
  CS_Total: Integer;

type
  TLocalCallThread = class(TThread)
  private
    FApp: LF.TAppHandle;
  protected
    procedure Execute; override;
  public
    constructor Create(A: LF.TAppHandle);
  end;

constructor TLocalCallThread.Create(A: LF.TAppHandle);
begin
  inherited Create(True);
  FApp := A;
end;

procedure TLocalCallThread.Execute;
var
  I: Integer;
  Req, Res: LF.TDataHandle;
begin
  for I := 1 to 100 do
  begin
    Req := LF.TDataHandle.Create('add');
    Req.WriteInt32(I); Req.WriteInt32(I * 2);
    Res := FApp.LocalCall(Req);
    try
      if Res.ReadInt32 = I * 3 then
      begin
        CL.Enter;
        try Inc(CS_OK); finally CL.Leave; end;
      end;
    finally
      Res.Free;
      Req.Free;
    end;
    CL.Enter;
    try Inc(CS_Total); finally CL.Leave; end;
  end;
end;

procedure T_Concurrency_LocalCall;
const N = 12;
var
  A: LF.TAppHandle;
  Threads: array[0..N-1] of TLocalCallThread;
  I: Integer;
begin
  LogSub(Format('Concurrency LocalCall: %d threads x 100 calls', [N]));

  CL := TCriticalSection.Create;
  CS_OK := 0;
  CS_Total := 0;
  try
    A := LF.TAppHandle.Create('CC_App', '');
    try
      A.RegisterCall('add', 'add', nil, @Cb_Add);
      for I := 0 to N - 1 do Threads[I] := TLocalCallThread.Create(A);
      for I := 0 to N - 1 do Threads[I].Start;
      for I := 0 to N - 1 do begin Threads[I].WaitFor; Threads[I].Free; end;

      LogInfo(Format('Total=%d OK=%d', [CS_Total, CS_OK]));
      Check(CS_Total = N * 100, 'all local calls completed');
      Check(CS_OK = CS_Total, 'all local calls succeeded');
    finally A.Free; end;
  finally CL.Free; end;
end;

var
  HL: TCriticalSection;
  H_OK: Integer;

type
  THandleThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure THandleThread.Execute;
var
  I: Integer;
  H: LF.TDataHandle;
begin
  for I := 1 to 500 do
  begin
    H := LF.TDataHandle.Create('h');
    try
      H.WriteInt32(I);
      H.SetPos(0);
      if H.GetSize = 4 then
      begin
        HL.Enter;
        try Inc(H_OK); finally HL.Leave; end;
      end;
    finally H.Free; end;
  end;
end;

procedure T_Concurrency_Handle;
const N = 8; const M = 500;
var
  Threads: array[0..N-1] of THandleThread;
  I: Integer;
begin
  LogSub(Format('Concurrency Handle: %d threads x %d alloc/free', [N, M]));

  HL := TCriticalSection.Create;
  H_OK := 0;
  try
    for I := 0 to N - 1 do Threads[I] := THandleThread.Create(True);
    for I := 0 to N - 1 do Threads[I].Start;
    for I := 0 to N - 1 do begin Threads[I].WaitFor; Threads[I].Free; end;
    Check(H_OK = N * M, Format('all %d handle ops OK', [N * M]));
  finally HL.Free; end;
end;

// ---------------------------------------------------------------------------
// Section: Scenario simulation
// ---------------------------------------------------------------------------

procedure T_Scenario_Calculator;
var
  A: LF.TAppHandle; Req, Res: LF.TDataHandle;
begin
  LogSub('Scenario: Calculator (add/sub/mul/div)');

  A := LF.TAppHandle.Create('Calc', 'calculator service');
  try
    A.RegisterCall('add', 'a+b', nil, @Cb_Add);
    A.RegisterCall('sub', 'a-b', nil, @Cb_Sub);
    A.RegisterCall('mul', 'a*b', nil, @Cb_Mul);
    A.RegisterCall('div', 'a/b', nil, @Cb_Div);

    Req := LF.TDataHandle.Create('add');
    try
      Req.WriteInt32(100); Req.WriteInt32(23);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 123, 'calc add 100+23'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('sub');
    try
      Req.WriteInt32(100); Req.WriteInt32(23);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 77, 'calc sub 100-23'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('mul');
    try
      Req.WriteInt32(12); Req.WriteInt32(12);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 144, 'calc mul 12*12'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('div');
    try
      Req.WriteInt32(10); Req.WriteInt32(4);
      Res := A.LocalCall(Req);
      try Check(Abs(Res.ReadDouble - 2.5) < 1e-9, 'calc div 10/4'); finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_Scenario_String;
var
  A: LF.TAppHandle; Req, Res: LF.TDataHandle;
begin
  LogSub('Scenario: String processing');

  A := LF.TAppHandle.Create('StrProc', 'string processing service');
  try
    A.RegisterCall('upper', 'uppercase', nil, @Cb_StrUpper);
    A.RegisterCall('lower', 'lowercase', nil, @Cb_StrLower);
    A.RegisterCall('reverse', 'reverse string', nil, @Cb_StrReverse);

    Req := LF.TDataHandle.Create('upper');
    try
      Req.WriteString('hello world');
      Res := A.LocalCall(Req);
      try Check(Res.ReadString = 'HELLO WORLD', 'upper'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('lower');
    try
      Req.WriteString('HELLO WORLD');
      Res := A.LocalCall(Req);
      try Check(Res.ReadString = 'hello world', 'lower'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('reverse');
    try
      Req.WriteString('abcdef');
      Res := A.LocalCall(Req);
      try Check(Res.ReadString = 'fedcba', 'reverse'); finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_Scenario_Encoder;
var
  A: LF.TAppHandle; Req, Res: LF.TDataHandle; Encoded: string;
begin
  LogSub('Scenario: Base64 encoding');

  A := LF.TAppHandle.Create('B64', 'base64 service');
  try
    A.RegisterCall('enc', 'base64 encode', nil, @Cb_Base64Enc);
    A.RegisterCall('dec', 'base64 decode', nil, @Cb_Base64Dec);

    Req := LF.TDataHandle.Create('enc');
    try
      Req.WriteString('hello');
      Res := A.LocalCall(Req);
      try
        Encoded := Res.ReadString;
        Check(Encoded = 'aGVsbG8=', 'base64 enc');
      finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('dec');
    try
      Req.WriteString(Encoded);
      Res := A.LocalCall(Req);
      try Check(Res.ReadString = 'hello', 'base64 dec'); finally Res.Free; end;
    finally Req.Free; end;
  finally A.Free; end;
end;

procedure T_Scenario_StatefulCounter;
var
  A: LF.TAppHandle;
  Ctr: Integer;
  Req, Res: LF.TDataHandle;
begin
  LogSub('Scenario: Stateful counter');

  Ctr := 0;
  A := LF.TAppHandle.Create('Counter', 'counter service');
  try
    A.RegisterCall('inc', 'increment', @Ctr, @Cb_Counter);

    Req := LF.TDataHandle.Create('inc');
    try
      Req.WriteInt32(5);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 5, 'counter 0+5=5'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('inc');
    try
      Req.WriteInt32(3);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 8, 'counter 5+3=8'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('inc');
    try
      Req.WriteInt32(-2);
      Res := A.LocalCall(Req);
      try Check(Res.ReadInt32 = 6, 'counter 8-2=6'); finally Res.Free; end;
    finally Req.Free; end;

    Check(Ctr = 6, 'counter final = 6');
  finally A.Free; end;
end;

procedure T_Scenario_MultiApp;
var
  A1, A2, A3: LF.TAppHandle;
  Req, Res: LF.TDataHandle;
begin
  LogSub('Scenario: Multi-app routing');

  A1 := LF.TAppHandle.Create('AppOne', 'one');
  A2 := LF.TAppHandle.Create('AppTwo', 'two');
  A3 := LF.TAppHandle.Create('AppThree', 'three');
  try
    A1.RegisterCall('op', 'op', nil, @Cb_Add);
    A2.RegisterCall('op', 'op', nil, @Cb_Sub);
    A3.RegisterCall('op', 'op', nil, @Cb_Mul);

    Req := LF.TDataHandle.Create('op');
    try
      Req.WriteInt32(10); Req.WriteInt32(3);
      Res := A1.LocalCall(Req);
      try Check(Res.ReadInt32 = 13, 'A1 add'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('op');
    try
      Req.WriteInt32(10); Req.WriteInt32(3);
      Res := A2.LocalCall(Req);
      try Check(Res.ReadInt32 = 7, 'A2 sub'); finally Res.Free; end;
    finally Req.Free; end;

    Req := LF.TDataHandle.Create('op');
    try
      Req.WriteInt32(10); Req.WriteInt32(3);
      Res := A3.LocalCall(Req);
      try Check(Res.ReadInt32 = 30, 'A3 mul'); finally Res.Free; end;
    finally Req.Free; end;
  finally
    A1.Free; A2.Free; A3.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Section: Memory pressure
// ---------------------------------------------------------------------------

procedure T_Memory_Pressure;
const N = 5000;
var
  Arr: array of LF.TDataHandle;
  I: Integer;
begin
  LogSub(Format('Memory pressure: %d handles alive', [N]));

  SetLength(Arr, N);
  for I := 0 to N - 1 do
  begin
    Arr[I] := LF.TDataHandle.Create('p' + IntToStr(I));
    Arr[I].WriteInt32(I);
  end;
  LogPass(Format('%d handles created', [N]));

  for I := 0 to N - 1 do
  begin
    Arr[I].SetPos(0);
    if Arr[I].ReadInt32 <> I then
    begin
      LogFail('handle content mismatch');
      Break;
    end;
  end;
  LogPass('all handle contents verified');

  for I := 0 to N - 1 do
    Arr[I].Free;
  LogPass('all handles freed');
end;

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

var
  T0: TDateTime;

procedure RunSection(const Name: string; Proc: TProcedure);
var
  E: Double;
  P0, F0: Integer;
begin
  T0 := Now;
  P0 := PassCount;
  F0 := FailCount;
  try
    Proc;
  except
    on Ex: Exception do
    begin
      LogFail('EXCEPTION in ' + Name + ': ' + Ex.ClassName + ': ' + Ex.Message);
    end;
  end;
  E := (Now - T0) * 86400.0;
  LogInfo(Format('  [%s] %.3fs, +%d pass / +%d fail',
    [Name, E, PassCount - P0, FailCount - F0]));
end;

begin
  G_Start_Tick := GetTimeTick;
  LogLock := TCriticalSection.Create;
  LogOpen(LOG_FILE);
  try
    LogRaw('============================================================');
    LogRaw('LingoFuse_SelfTest');
    LogRaw('Start: ' + DateTimeToStr(Now));
    LogRaw('============================================================');
    LogRaw('');

    LF.Sync;

    RunSection('DataHandle.Create',        @T_DataHandle_Create);
    RunSection('DataHandle.TypedIO',       @T_DataHandle_TypedIO);
    RunSection('DataHandle.Extreme',       @T_DataHandle_Extreme);
    RunSection('DataHandle.Empty',         @T_DataHandle_Empty);
    RunSection('DataHandle.LargeString',   @T_DataHandle_LargeString);
    RunSection('DataHandle.BufferSize',    @T_DataHandle_BufferSize);
    RunSection('DataHandle.Pos',           @T_DataHandle_Pos);
    RunSection('DataHandle.Partial/Zero',  @T_DataHandle_Partial_Zero);
    RunSection('DataHandle.P2P',           @T_DataHandle_P2P);
    RunSection('DataHandle.StringBytes',   @T_DataHandle_StringBytes);
    RunSection('DataHandle.RawWrappers',   @T_DataHandle_RawWrappers);

    RunSection('App.Handle',               @T_App_Handle);
    RunSection('App.Multiple',             @T_App_Multiple);
    RunSection('App.BindNoNet',            @T_Bind_No_Net);
    RunSection('App.UTF8',                 @T_App_UTF8);

    RunSection('Reg.CallCdecl',            @T_Reg_Call_Cdecl);
    RunSection('Reg.CallM',                @T_Reg_Call_M);
    RunSection('Reg.CallP',                @T_Reg_Call_P);
    RunSection('Reg.NotifyCdecl',          @T_Reg_Notify_Cdecl);
    RunSection('Reg.NotifyM',              @T_Reg_Notify_M);
    RunSection('Reg.NotifyP',              @T_Reg_Notify_P);
    RunSection('Reg.DupUnreg',             @T_Reg_Duplicate_Unregister);
    RunSection('Reg.UTF8',                 @T_Reg_UTF8);
    RunSection('P2P.RegisterAll',          @T_P2P_Register_All);

    RunSection('LocalCall.Unregistered',   @T_LocalCall_Unregistered);
    RunSection('LocalCall.FullIO',         @T_LocalCall_Full_IO);
    RunSection('LocalCall.LargePayload',   @T_LocalCall_Large_Payload);
    RunSection('LocalCall.Repeated',       @T_LocalCall_Repeated);

    RunSection('Options.All',              @T_Options_All);
    RunSection('Status.All',               @T_Status_All);
    RunSection('Status.Overflow',          @T_Status_Overflow);

    RunSection('Check.All',                @T_Check_All);
    RunSection('Check.All.Raw',            @T_Check_All_Raw);
    RunSection('Network.Event',            @T_Network_Event);
    RunSection('Reset.Prepare',            @T_Reset_Prepare);
    RunSection('Sync',                     @T_Sync);

    RunSection('Concurrency.LocalCall',    @T_Concurrency_LocalCall);
    RunSection('Concurrency.Handle',       @T_Concurrency_Handle);

    RunSection('Scenario.Calculator',      @T_Scenario_Calculator);
    RunSection('Scenario.String',          @T_Scenario_String);
    RunSection('Scenario.Encoder',         @T_Scenario_Encoder);
    RunSection('Scenario.StatefulCounter', @T_Scenario_StatefulCounter);
    RunSection('Scenario.MultiApp',        @T_Scenario_MultiApp);

    RunSection('Memory.Pressure',          @T_Memory_Pressure);

    LogRaw('');
    LogRaw('============================================================');
    LogRaw('  FINAL SUMMARY');
    LogRaw('============================================================');
    LogRaw(Format('  Passed : %d', [PassCount]));
    LogRaw(Format('  Failed : %d', [FailCount]));
    LogRaw(Format('  Total  : %d', [PassCount + FailCount]));
    LogRaw(Format('  Elapsed: %d ms', [TickOf]));
    LogRaw('============================================================');

    try LF_Shutdown; except end;
  finally
    LogClose;
    if LogLock <> nil then LogLock.Free;
  end;
end.
