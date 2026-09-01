program cross_call;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
{$endif}

{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils, Variants, Z.Core, // Z 框架核心（线程池、原子操作、时间等）
  Z.PascalStrings, Z.UPascalStrings, Z.UnicodeMixedLib, Z.Parsing, Z.Expression, Z.MemoryStream, // TMem64 内存流
  Z.Status, Z.Int128, Z.Geometry2D, Z.Notify, lingofuse_helper, // RAII 封装
  lingofuse_import; // C 绑定

function add__(a, b: integer): integer;
var
  send_, return_: TDataHnd;
begin
  Result := 0;
  send_ := LF_CreateDataEx('add');
  LF_WriteInt32(send_, a);
  LF_WriteInt32(send_, b);

  return_ := LF_CallEx('demo', send_, 1000);
  if LF_GetSize(return_) > 0 then
    Result := LF_ReadInt32(return_);

  LF_FreeData(send_);
  LF_FreeData(return_);
end;

function inv_seri_: string;
var
  b: byte;
  w: word;
  c: cardinal;
  u64: uint64;
  s: string;
  f: single;
  send_, return_: TDataHnd;
begin
  b := 200;
  w := $10;
  c := $2F;
  u64 := $3F;
  s := 'hello world';
  f := 3.14;

  send_ := LF_CreateDataEx('inv_seri');

  LF_WriteUInt8(send_, b);
  LF_WriteUInt16(send_, w);
  LF_WriteUInt32(send_, c);
  LF_WriteUInt64(send_, u64);
  LF_WriteString(send_, s);
  LF_WriteSingle(send_, f);

  return_ := LF_CallEx('demo', send_, 1000);
  if LF_GetSize(return_) > 0 then
  begin
    f := LF_ReadSingle(return_);
    s := LF_ReadString(return_);
    u64 := LF_ReadUInt64(return_);
    c := LF_ReadUInt32(return_);
    w := LF_ReadUInt16(return_);
    b := LF_ReadUInt8(return_);
    Result := PFormat('接收数据序 [%d, %d, %d, %d, "%s", %.2f] = 发送数据序 [%.2f, "%s", %d, %d, %d, %d] ', [b, w, c, u64, s, f, f, s, u64, c, w, b]);
  end
  else
    Result := '计算超时';

  LF_FreeData(send_);
  LF_FreeData(return_);
end;

var
  app_running: boolean;
procedure Do_Compute;
var
  a, b, c: integer;
  tk: TTimeTick;
begin
  tk := GetTimeTick();
  while app_running and ((GetTimeTick() - tk) < 10 * 1000) do
  begin
    if TMT19937.Rand32 mod 2 = 0 then
    begin
      a := TMT19937.RandomRange(1, $FFFFFFF);
      b := TMT19937.RandomRange(1, $FFFFFFF);
      c := add__(a, b);
      if c <> 0 then
        DoStatus('计算 "a(%d)+b(%d)" = 计算结果 %d (%.2f秒以后退出)', [a, b, c, ((10 * 1000) - (GetTimeTick() - tk)) * 0.001]);
    end
    else
    begin
      DoStatus(inv_seri_() + PFormat('(%.2f秒退出)', [((10 * 1000) - (GetTimeTick() - tk)) * 0.001]));
    end;
  end;
end;

var
  thread_running: boolean;
begin
  LF_ResetPrepare();
  LF_PrepareClientEx('ipc:cross', nil);
  LF_PrepareDone();
  DoStatus('计算节点启动成功');

  DoStatus('启动仿真计算(可以多开)');
  app_running := True;
  TCompute.RunC_NP(Do_Compute, @thread_running, nil);

  while thread_running do
    TCompute.Sleep(100);

  DoStatus('清理线程中.');
  LF_ExitMainThread();
  LF_Shutdown();
end.
