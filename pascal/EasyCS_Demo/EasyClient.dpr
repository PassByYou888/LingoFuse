program EasyClient;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  lingofuse_import,   // TDataHnd___ / TLF_Async_Call_P
  lingofuse_helper;   // LF.TDataHandle / LF.AsyncCallApp_P

var
  Data:      LF.TDataHandle;
  Done:      Boolean;
  Lock:      TCriticalSection;
  ResultSum: Integer;
  Tick:      Cardinal;

begin
  Lock := TCriticalSection.Create;
  try
    Done      := False;
    ResultSum := 0;

    // ── 1. 连接（App=nil 表示纯消费端，不对外暴露 API）──────────────
    LF.ResetPrepare;
    LF.PrepareClient('ipc:calc_service', nil);
    if not LF.PrepareDone then
    begin
      Writeln('连接失败');
      LF.Shutdown;
      Halt(1);
    end;
    Writeln('[主线程] 已连接到 ipc:calc_service');

    // ── 2. 构造请求（RAII，函数结尾统一释放）────────────────────────
    Data := LF.TDataHandle.Create('add');
    Data.WriteInt32(10).WriteInt32(20);

    // ── 3. 一气呵成：直接把匿名函数写在调用点上 ─────────────────────
    //
    //   TLF_Async_Call_P = reference to procedure(Result_: TDataHnd___);
    //
    //   AsyncCallApp_P 立即返回，真正的回调在网络往返完成后由
    //   TCompute 工作线程执行；匿名函数用闭包捕获 Done / Lock /
    //   ResultSum，从调用点到结果落地是一条完整的代码线。
    //
    Writeln('[主线程] 发起异步调用 ...');

    if LF.AsyncCallApp_P('CalcService', Data,
         // ↓↓↓ 标准 Delphi 匿名函数，内联在参数位上 ↓↓↓
         procedure(Result_: TDataHnd___)
         var
           Sum: Integer;
         begin
           // ── 本段代码运行在 TCompute 工作线程（非主线程）──

           // Result_ 由框架拥有，回调返回瞬间被释放；
           // 必须在这里把数据读走，绝不能把 Result_ 保存出去。
           if (Result_ = nil) or (LF_GetSize(Result_) < SizeOf(Integer)) then
           begin
             Lock.Enter;
             try
               Done := True;
               Writeln('[异步回调] 调用超时或数据无效');
             finally
               Lock.Leave;
             end;
             Exit;
           end;

           LF_SetPos(Result_, 0);
           LF_ReadInt32(Result_, Sum);   // 数据拷贝到本地变量

           Lock.Enter;
           try
             ResultSum := Sum;
             Done      := True;
             Writeln(Format('[异步回调] 10 + 20 = %d', [ResultSum]));
           finally
             Lock.Leave;
           end;

           // ❌ LF_FreeData(Result_)      —— double-free
           // ❌ 把 Result_ 存到全局变量    —— use-after-free
           // ❌ 在回调里直接操作 UI        —— 跨线程
         end
         // ↑↑↑ 匿名函数结束 ↑↑↑
       ) <> 1 then
    begin
      Writeln('[主线程] 异步派发失败');
      Data.Free;
      LF.ExitMainThread;
      LF.Shutdown;
      Halt(1);
    end;

    // ── 4. 主线程等待异步回调落地 ─────────────────────────────────
    //    模拟主线程在 LF_PrepareDone 时已启动，网络进度自动推进；
    //    主线程只需轮询完成标志，顺便 LF.Sync 排空同步队列。
    Tick := TThread.GetTickCount;
    while (not Done) and (TThread.GetTickCount - Tick < 5000) do
    begin
      LF.Sync;
      Sleep(10);
    end;

    if not Done then
      Writeln('[主线程] 等待异步回调超时')
    else
      Writeln(Format('[主线程] 确认结果: 10 + 20 = %d', [ResultSum]));

    // ── 5. 释放调用者拥有的请求句柄（Result_ 是框架的，不动）─────────
    Data.Free;

    Writeln('按下回车键退出');
    Readln;

    // ── 6. 清理（顺序固定）─────────────────────────────────────────
    LF.ExitMainThread;
    LF.Shutdown;
  finally
    Lock.Free;
  end;
end.
