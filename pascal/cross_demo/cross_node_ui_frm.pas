unit cross_node_ui_frm;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$CODEPAGE UTF8}
{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  lingofuse_helper, lingofuse_import;

type
  Tcross_node_ui_form = class(TForm)
    info_Label: TLabel;
    Memo: TMemo;
    sysTimer: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure sysTimerTimer(Sender: TObject);
  private
  public
    procedure do_add_Call(Input: TDataHnd; Output: TDataHnd);
    procedure do_inv_seri_Call(Input: TDataHnd; Output: TDataHnd);
  end;

  TBoot_Th = class(TThread)
  public
    procedure Execute; override;
  end;

var
  cross_node_ui_form: Tcross_node_ui_form;
implementation
{$R *.lfm}
procedure TBoot_Th.Execute;
var
  app: TAppHnd;
begin
  FreeOnTerminate := True;
  LF.ResetPrepare;
  app := LF___.LF_CreateAppEx('demo', 'cross app inst');
  LF___.LF_RegisterSyncCall_M(app, 'add', 'add(int a, int b)', cross_node_ui_form.do_add_Call);
  LF___.LF_RegisterSyncCall_M(app, 'inv_seri', 'inv_seri()', cross_node_ui_form.do_inv_seri_Call);
  LF___.LF_SetOptionEx('Wait_Ready', 'False');
  LF___.LF_ResetPrepare();
  LF___.LF_PrepareClientEx('ipc:cross', app);
  LF___.LF_PrepareDone();
end;
procedure Tcross_node_ui_form.do_add_Call(Input: TDataHnd; Output: TDataHnd);
var
  a, b, c: integer;
begin
  a := LF___.LF_ReadInt32(Input);
  b := LF___.LF_ReadInt32(Input);
  c := a + b;
  LF_PostStatusEx(Format('收到计算请求 "a(%d)+b(%d)" = 计算结果 "%d"', [a, b, c]));
  LF___.LF_WriteInt32(Output, c);
end;
procedure Tcross_node_ui_form.do_inv_seri_Call(Input: TDataHnd; Output: TDataHnd);
var
  b: byte;
  w: word;
  c: cardinal;
  u64: uint64;
  s: string;
  f: single;
begin
  b := LF___.LF_ReadUInt8(Input);
  w := LF___.LF_ReadUInt16(Input);
  c := LF___.LF_ReadUInt32(Input);
  u64 := LF___.LF_ReadUInt64(Input);
  s := LF___.LF_ReadString(Input);
  f := LF___.LF_ReadSingle(Input);
  LF___.LF_WriteSingle(Output, f);
  LF___.LF_WriteString(Output, s);
  LF___.LF_WriteUInt64(Output, u64);
  LF___.LF_WriteUInt32(Output, c);
  LF___.LF_WriteUInt16(Output, w);
  LF___.LF_WriteUInt8(Output, b);
  LF_PostStatusEx(Format('接收数据序 [%d, %d, %d, %d, "%s", %.2f] = 发送数据序 [%.2f, "%s", %d, %d, %d, %d] ',
    [b, w, c, u64, s, f, f, s, u64, c, w, b]));
end;

procedure Tcross_node_ui_form.sysTimerTimer(Sender: TObject);
begin
  LF.Sync;
  while LF_GetStatusCount() > 0 do
    Memo.Lines.Add(LF_GetStatusEx());
end;
procedure Tcross_node_ui_form.FormCreate(Sender: TObject);
begin
  TBoot_Th.Create(False);
end;
procedure Tcross_node_ui_form.FormDestroy(Sender: TObject);
begin
  LF___.LF_Shutdown;
end;
end.

