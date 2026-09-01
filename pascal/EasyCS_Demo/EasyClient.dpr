program EasyClient;

{$APPTYPE CONSOLE}

{$R *.res}


uses
  System.SysUtils,
  lingofuse_helper; // RAII 封装（推荐）

var
  Data, Res: LF.TDataHandle;
  Sum: Integer;

begin
  // 1. 连接到服务（纯消费端，不暴露 API）
  LF.ResetPrepare;
  LF.PrepareClient('ipc:calc_service', nil); // App 如果为 nil，则充当纯消费者(不对外提供服务)。

  if not LF.PrepareDone then
    begin
      Writeln('连接失败');
      LF.Shutdown;
      Halt(1);
    end;

  // 2. 构造请求（RAII 自动释放）
  Data := LF.TDataHandle.Create('add');
  Data.WriteInt32(10).WriteInt32(20); // 链式写入

  // 3. 远程调用（超时 3000ms）
  Res := LF.CallApp('CalcService', Data, 3000);
  try
    if Res.GetSize = 0 then
        Writeln('调用超时或失败')
    else if Res.ReadInt32(Sum) then
        Writeln(Format('10 + 20 = %d', [Sum]))
    else
        Writeln('读取结果失败');
  finally
      Res.Free;
  end;
  Writeln('按下回车键退出');
  Readln;

  // 4. 清理
  LF.ExitMainThread;
  LF.Shutdown;

end.
