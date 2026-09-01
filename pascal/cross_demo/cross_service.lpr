program cross_service;

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
  SysUtils, Z.Core, // Z 框架核心（线程池、原子操作、时间等）
  Z.PascalStrings, Z.UPascalStrings, Z.UnicodeMixedLib, Z.Parsing, Z.Expression, Z.MemoryStream, // TMem64 内存流
  Z.Status, Z.Int128, Z.Geometry2D, Z.Notify, lingofuse_helper, // RAII 封装
  lingofuse_import; // C 绑定

begin
  LF_ResetPrepare();
  LF_PrepareServiceEx('ipc:cross', 'ipc:cross');
  if LF_PrepareDone() <> 1 then
  begin
    DoStatus('计算服务启动失败');
    LF_Shutdown();
    DoStatus('3秒后退出');
    TCompute.Sleep(3000);
    exit;
  end;
  DoStatus('计算服务启动成功');
  DoStatus('回车键退出.');
  readln();
  DoStatus('清理线程中.');
  LF_Shutdown();
end.
