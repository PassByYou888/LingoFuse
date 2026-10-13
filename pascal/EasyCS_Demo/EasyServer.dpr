program EasyServer;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  lingofuse_import,   // 底层 C 绑定（TDataHnd___ / TLF_Call_P 等）
  lingofuse_helper;   // RAII 封装（LF.TAppHandle）

var
  App: LF.TAppHandle;

begin
  // ── 1. 创建应用（RAII，函数结尾由 App.Free 释放）────────────────
  App := LF.TAppHandle.Create('CalcService', 'Calculator Demo');

  // ── 2. 用匿名函数注册 Call 回调 ─────────────────────────────────
  //
  //   TLF_Call_P = reference to procedure(Input, Output: TDataHnd___);
  //
  //   匿名函数直接长在注册点上，注册动作和回调逻辑是一条线；
  //   回调体运行在 LingoFuse 的 TCompute 工作线程（非主线程），
  //   禁止调 LF_Call / LF_Notify / LF_Shutdown，禁止直接操作 UI。
  //
  //   注意：回调内不要 Free Input / Output —— 框架管理。
  //         必须把 Output 写完再返回（回调返回后 Output 失效）。
  //
  if not App.RegisterCall_P('add', 'a + b',
       // ↓↓↓ 标准 Delphi 匿名函数，内联在参数位上 ↓↓↓
       procedure(Input, Output: TDataHnd___)
       var
         A, B, Sum: Integer;
       begin
         // ── 本段代码运行在 TCompute 工作线程 ──

         // 按客户端写入顺序读入参
         LF_SetPos(Input, 0);
         if LF_ReadInt32(Input, A) and LF_ReadInt32(Input, B) then
         begin
           Sum := A + B;
           Writeln(Format('[服务端回调] %d + %d = %d', [A, B, Sum]));

           // 写回结果（同步把 Output 写完，返回即失效）
           LF_WriteInt32(Output, Sum);
         end;
       end
       // ↑↑↑ 匿名函数结束 ↑↑↑
     ) then
  begin
    Writeln('注册 add API 失败');
    App.Free;
    LF.Shutdown;
    Halt(1);
  end;

  // ── 3. 准备网络（IPC 模式：服务端 + 客户端一体）─────────────────
  //
  //   PrepareService(..., App) 这个重载内部会自动再 PrepareClient，
  //   把本进程既作为服务监听 ipc:calc_service，又作为客户端连上去，
  //   所以 EasyClient 只是"纯消费端"，本进程才是真正的 API 提供者。
  //
  LF.ResetPrepare;
  LF.PrepareService('ipc:calc_service', 'ipc:calc_service', App);

  if not LF.PrepareDone then
  begin
    Writeln('网络启动失败');
    App.Free;
    LF.Shutdown;
    Halt(1);
  end;

  Writeln('服务已启动，监听 ipc:calc_service');
  Writeln('等待 EasyClient 连接...');
  Writeln('按下回车键退出...');
  Readln;

  // ── 4. 清理（顺序固定：ExitMainThread → Shutdown → FreeApp）────
  LF.ExitMainThread;
  LF.Shutdown;
  App.Free;
end.
