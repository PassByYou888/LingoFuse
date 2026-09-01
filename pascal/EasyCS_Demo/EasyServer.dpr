program EasyServer;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  lingofuse_import,   // 底层 C 绑定
  lingofuse_helper;   // RAII 封装（推荐）

// 加法回调（cdecl，在后台线程执行）

procedure AddCallback(Trigger: Pointer; Input, Output: Pointer); cdecl;
var
  A, B, Sum: Integer;
begin
  if LF_ReadBuffer(TDataHnd(Input), @A, SizeOf(A)) <> SizeOf(A) then
    Exit;
  if LF_ReadBuffer(TDataHnd(Input), @B, SizeOf(B)) <> SizeOf(B) then
    Exit;

  Sum := A + B;
  LF_WriteBuffer(TDataHnd(Output), @Sum, SizeOf(Sum));
end;

var
  App: LF.TAppHandle=nil;

begin
  // 1. 创建应用（RAII，自动释放）
  App := LF.TAppHandle.Create('CalcService', 'Calculator Demo');

  // 2. 注册 API
  if not App.RegisterCall('add', 'a + b', nil, @AddCallback) then
  begin
    Writeln('注册失败');
    LF.Shutdown;
    Halt(1);
  end;

  // 3. 准备网络（IPC 模式）
  LF.ResetPrepare;

  //App 如果为 nil，则充当纯消费者(不对外提供服务)。
  LF.PrepareService('ipc:calc_service', 'ipc:calc_service', App);

  if not LF.PrepareDone then
  begin
    Writeln('网络启动失败');
    LF.Shutdown;
    Halt(1);
  end;

  Writeln('服务已启动，按 Enter 退出...');
  Readln;

  // 4. 清理（RAII 会自动释放 App，但我们手动调用网络停止）
  LF.ExitMainThread;
  LF.Shutdown;
  Freeandnil(App);  // 非必须，但显式释放更清晰
end.
