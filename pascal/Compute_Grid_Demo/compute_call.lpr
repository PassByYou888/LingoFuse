program compute_call;

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

function Express(exp_: string): string;
var
  send_, return_: TDataHnd;
begin
  Result := '';
  send_ := LF_CreateDataEx('exp');
  LF_WriteString(send_, exp_);

  return_ := LF_CallEx('pas', send_, 1000);
  if LF_GetSize(return_) > 0 then
    Result := LF_ReadString(return_);

  LF_FreeData(send_);
  LF_FreeData(return_);
end;

var
  app_running: boolean;
procedure Do_Compute_Exp;
const
  op_: array [0..3] of char = ('+', '-', '*', '/');
var
  exp_, return_: string;
  tk: TTimeTick;
begin
  tk := GetTimeTick();
  while app_running and ((GetTimeTick() - tk) < 60 * 1000) do
  begin
    exp_ := PFormat('%d %s %d', [TMT19937.Rand32, op_[TMT19937.RandomRange(0, 3)], TMT19937.Rand32]);
    return_ := Express(exp_);
    if return_ <> '' then
      DoStatus('计算公式 "%s" = 计算结果 %s (等60秒以后会自动退出)', [exp_, return_]);
    TCompute.Sleep(1);
  end;
end;

var
  thread_running: boolean;
begin
  LF_ResetPrepare();
  LF_PrepareClientEx('ipc:compute_grid', nil);
  LF_PrepareDone();
  DoStatus('计算节点启动成功');

  DoStatus('启动仿真计算(大约每秒1000次,可以多开)');
  app_running := True;
  TCompute.RunC_NP(Do_Compute_Exp, @thread_running, nil);

  while thread_running do
    TCompute.Sleep(10);

  DoStatus('清理线程中.');
  LF_ExitMainThread();
  LF_Shutdown();
end.
