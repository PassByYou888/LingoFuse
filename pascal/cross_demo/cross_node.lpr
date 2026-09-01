program cross_node;

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

procedure do_add_Call(Trigger: Pointer; Input: Pointer; Output: TDataHnd); cdecl;
var
  a, b, c: integer;
begin
  a := LF_ReadInt32(Input);
  b := LF_ReadInt32(Input);
  c := a + b;
  DoStatus('收到计算请求 "a(%d)+b(%d)" = 计算结果 "%d"', [a, b, c]);
  LF_WriteInt32(Output, c);
end;

procedure do_inv_seri_Call(Trigger: Pointer; Input: Pointer; Output: TDataHnd); cdecl;
var
  b: byte;
  w: word;
  c: cardinal;
  u64: uint64;
  s: string;
  f: single;
begin
  b := LF_ReadUInt8(Input);
  w := LF_ReadUInt16(Input);
  c := LF_ReadUInt32(Input);
  u64 := LF_ReadUInt64(Input);
  s := LF_ReadString(Input);
  f := LF_ReadSingle(Input);

  LF_WriteSingle(Output, f);
  LF_WriteString(Output, s);
  LF_WriteUInt64(Output, u64);
  LF_WriteUInt32(Output, c);
  LF_WriteUInt16(Output, w);
  LF_WriteUInt8(Output, b);

  DoStatus('接收数据序 [%d, %d, %d, %d, "%s", %.2f] = 发送数据序 [%.2f, "%s", %d, %d, %d, %d] ',
    [b, w, c, u64, s, f, f, s, u64, c, w, b]);
end;

var
  app: TAppHnd;
begin
  app := LF_CreateAppEx('demo', 'cross app inst');
  LF_RegisterCallEx(app, 'add', 'add(int a, int b)', nil, do_add_Call);
  LF_RegisterCallEx(app, 'inv_seri', 'inv_seri()', nil, do_inv_seri_Call);

  LF_SetOptionEx('Wait_Ready', 'False'); //启动部署模式:计算节点启动没有先后顺序,可以先启动节点,然后再启动服务器
  LF_ResetPrepare();
  LF_PrepareClientEx('ipc:cross', app);
  LF_PrepareDone();
  DoStatus('计算节点启动成功');
  DoStatus('回车键退出.');
  readln();
  DoStatus('清理线程中.');
  LF_FreeApp(app);
  LF_Shutdown();
end.
