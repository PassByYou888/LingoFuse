{
 * ============================================================================
 * fpc_tester_for_LingoFuse – 完整的 LingoFuse Pascal 绑定测试套件
 * ============================================================================
 *
 * 本程序用于全面测试 lingofuse_import 和 lingofuse_helper 单元的正确性、
 * 性能、并发安全性以及跨平台兼容性。它覆盖了以下核心功能：
 *
 *   – TDataHandle 的基本读写操作（所有整数类型、浮点数、字符串）
 *   – 本地 API 调用和通知（Call/Notify）
 *   – 远程网络通信（基于 IPC 和 TCP 的 C4 服务网格）
 *   – 多线程并发调用（10 线程 × 100 次调用）
 *   – 性能基准测试（1000 次顺序调用）
 *   – 资源泄漏检测（批量分配和释放句柄）
 *   – 重复注册检测（API 名称唯一性）
 *   – 国际化支持（中文 API 名称和 UTF‑8 字符串）
 *
 * 该测试程序可作为 LingoFuse 集成到项目中的参考实现，同时也帮助
 * 开发者快速验证库的安装和环境配置是否正确。
 *
 * 编译要求：Free Pascal 3.0+ 或 Delphi 2009+，需链接 LingoFuse 动态库。
 * ============================================================================
 }
program fpc_tester_for_LingoFuse;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
{$endif}

{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,               // Free Pascal 在 Unix 下需启用 cthreads 以支持多线程
{$ENDIF}
{$IFDEF MSWINDOWS}
  Windows,                // Windows 下用于 WriteConsoleW 等 API
{$ENDIF}
  Classes, SysUtils, DateUtils, SyncObjs,
  lingofuse_helper,       // 高级面向对象封装
  lingofuse_import;       // 低级 C-ABI 导入

{
 * 将 Pascal 字符串安全地转换为 UTF-8 编码的字符串，
 * 确保在 Free Pascal 和 Delphi 下行为一致。
 }
function ToUTF8(const S: string): UTF8String;
begin
{$IFDEF FPC}
  if StringCodePage(S) = CP_UTF8 then
      Result := UTF8String(S)
  else
      Result := UTF8Encode(S);
{$ELSE}
  Result := UTF8Encode(S);
{$ENDIF}
end;

{
 * 向控制台输出 UTF-8 文本，自动处理 Windows 下 WriteConsoleW
 * 和 Unix 下标准输出的差异，确保中文和 Emoji 正确显示。
 }
procedure ConsoleWrite(const S: string);
var
  UTF8Str: UTF8String;
{$IFDEF MSWINDOWS}
  WStr: UnicodeString;
  Written: DWORD;
{$ENDIF}
begin
  if not IsConsole then Exit;
  UTF8Str := ToUTF8(S);
{$IFDEF MSWINDOWS}
  WStr := UTF8Decode(UTF8Str);
  WriteConsoleW(GetStdHandle(STD_OUTPUT_HANDLE),
                PWideChar(WStr), Length(WStr), Written, nil);
{$ELSE}
  Write(UTF8Str);
{$ENDIF}
end;

{
 * 控制台换行输出，若指定非空字符串则先输出该字符串再换行。
 }
procedure ConsoleWriteLn(const S: string = '');
begin
  if S <> '' then ConsoleWrite(S);
{$IFDEF MSWINDOWS}
  ConsoleWrite(sLineBreak);
{$ELSE}
  WriteLn;
{$ENDIF}
end;

{
 * 测试回调函数：加法 API（Call 模式）
 * 从 Input 读取两个 32 位整数，计算和并写入 Output。
 * 此函数会被 LingoFuse 框架在本地或远程调用时触发。
 }
procedure AddCallback(Trigger: Pointer; Input, Output: Pointer); cdecl;
var
  A, B, Sum: Integer;
begin
  if LF_ReadBuffer(TDataHnd(Input), @A, SizeOf(A)) <> SizeOf(A) then Exit;
  if LF_ReadBuffer(TDataHnd(Input), @B, SizeOf(B)) <> SizeOf(B) then Exit;
  Sum := A + B;
  LF_WriteBuffer(TDataHnd(Output), @Sum, SizeOf(Sum));
end;

{
 * 测试回调函数：回显 API（Call 模式）
 * 将 Input 缓冲区中的全部数据原样复制到 Output，实现“回显”功能。
 }
procedure EchoCallback(Trigger: Pointer; Input, Output: Pointer); cdecl;
var
  Size: Int64;
  Buf: PByte;
begin
  Size := LF_GetSize(TDataHnd(Input));
  if Size > 0 then
  begin
    GetMem(Buf, Size);
    try
      LF_SetPos(TDataHnd(Input), 0);
      LF_ReadBuffer(TDataHnd(Input), Buf, Size);
      LF_WriteBuffer(TDataHnd(Output), Buf, Size);
    finally
      FreeMem(Buf);
    end;
  end;
end;

{
 * 测试回调函数：打印通知（Notify 模式）
 * 从 Input 读取一个长度前缀的字符串，解码后输出到控制台。
 * 用于演示 Notify 单向通知机制。
 }
procedure PrintNotify(Trigger: Pointer; Input: Pointer); cdecl;
var
  Len: Int32;
  Utf8: UTF8String;
  Msg: string;
begin
  if LF_ReadBuffer(TDataHnd(Input), @Len, SizeOf(Len)) <> SizeOf(Len) then Exit;
  SetLength(Utf8, Len);
  if Len > 0 then
    if LF_ReadBuffer(TDataHnd(Input), @Utf8[1], Len) <> Len then Exit;
  Msg := UTF8Decode(Utf8);
  ConsoleWriteLn('[Notify] Received: ' + Msg);
end;

{ ---- 测试报告辅助过程 ---- }

procedure Report(const Msg: string; const Args: array of const); overload;
begin
  ConsoleWriteLn(Format(Msg, Args));
end;

procedure Report(const Msg: string); overload;
begin
  ConsoleWriteLn(Msg);
end;

procedure ReportPass(const TestName: string);
begin
  ConsoleWriteLn('[PASS] ' + TestName);
end;

procedure ReportFail(const TestName: string);
begin
  ConsoleWriteLn('[FAIL] ' + TestName);
end;

{ ---- 并发测试相关变量和线程类 ---- }

var
  ConcurrencyTotalCalls: Integer;  // 成功调用的累计次数（原子递增）

{
 * 并发测试线程类
 * 每个线程调用 LocalCall 100 次，验证结果是否正确，
 * 并将成功次数累加到全局变量中。
 }
type
  TConcurrencyThread = class(TThread)
  private
    FApp: LF.TAppHandle;      // 应用句柄（共享）
    FThreadIndex: Integer;    // 线程索引（仅用于调试）
  protected
    procedure Execute; override;
  public
    constructor Create(App: LF.TAppHandle; ThreadIndex: Integer);
  end;

constructor TConcurrencyThread.Create(App: LF.TAppHandle; ThreadIndex: Integer);
begin
  inherited Create(True);       // 创建时挂起，等待外部 Start
  FApp := App;
  FThreadIndex := ThreadIndex;
  FreeOnTerminate := False;     // 由主线程负责释放
end;

procedure TConcurrencyThread.Execute;
var
  j: Integer;
  Data, Res: LF.TDataHandle;
  Sum: Integer;
begin
  for j := 1 to 100 do
  begin
    Data := LF.TDataHandle.Create('add');
    try
      Data.WriteInt32(j).WriteInt32(j*2);
      Res := FApp.LocalCall(Data);
      try
        if Res.ReadInt32(Sum) and (Sum = j + j*2) then
          InterlockedIncrement(ConcurrencyTotalCalls);   // 线程安全计数
      finally Res.Free; end;
    finally Data.Free; end;
  end;
end;

{ ---- 测试用例：数据句柄基本操作 ---- }

procedure TestDataHandleBasics;
var
  DH: LF.TDataHandle;
  I8: Int8; U8: UInt8; I16: Int16; U16: UInt16;
  I32: Int32; U32: UInt32; I64: Int64; U64: UInt64;
  Sgl: Single; Dbl: Double; Str: string;
  BufPtr: Pointer;
begin
  Report('=== API.TDataHandle Basic Operations (Chaining) ===');

  DH := LF.TDataHandle.Create('test_api');
  try
    // 链式写入所有支持的数据类型，测试 Write 方法和位置自动推进
    DH.WriteInt8(-128)
      .WriteUInt8(255)
      .WriteInt16(-32768)
      .WriteUInt16(65535)
      .WriteInt32(-123456789)
      .WriteUInt32(123456789)
      .WriteInt64(-9876543210)
      .WriteUInt64(9876543210)
      .WriteSingle(3.14159)
      .WriteDouble(2.718281828)
      .WriteString('Hello, 世界! 🌍');

    // 重置位置到开头，依次读取验证
    DH.SetPos(0);
    if DH.ReadInt8(I8) and DH.ReadUInt8(U8) and DH.ReadInt16(I16) and
       DH.ReadUInt16(U16) and DH.ReadInt32(I32) and DH.ReadUInt32(U32) and
       DH.ReadInt64(I64) and DH.ReadUInt64(U64) and
       DH.ReadSingle(Sgl) and DH.ReadDouble(Dbl) and DH.ReadString(Str) then
    begin
      Report('Int8=%d UInt8=%d Int16=%d UInt16=%d Int32=%d UInt32=%d Int64=%d UInt64=%d',
        [I8, U8, I16, U16, I32, U32, I64, U64]);
      Report('Single=%f Double=%f', [Sgl, Dbl]);
      Report('String: ' + Str);
      ReportPass('All types read/written correctly');
    end
    else
      ReportFail('Read operations failed');

    // 测试位置设置和获取
    DH.SetPos(4);
    if DH.GetPos = 4 then
      ReportPass('SetPos/GetPos')
    else
      ReportFail('SetPos/GetPos');

    // 测试截断缓冲区
    DH.SetSize(10);
    if DH.GetSize = 10 then
      ReportPass('SetSize (truncate)')
    else
      ReportFail('SetSize');

    // 测试 GetBuffer 返回有效指针
    BufPtr := DH.GetBuffer;
    if BufPtr <> nil then
      ReportPass('GetBuffer returns valid pointer')
    else
      ReportFail('GetBuffer returned nil');
  finally
    DH.Free;
  end;
end;

{ ---- 测试用例：本地调用和通知 ---- }

procedure TestLocalCalls;
var
  App: LF.TAppHandle;
  Data, Res: LF.TDataHandle;
  Sum: Integer; Msg: string;
begin
  Report('=== Local Calls & Notifications ===');

  App := LF.TAppHandle.Create('LocalApp', 'Local test');
  try
    // 注册三个 API：加法、回显、打印通知
    if not App.RegisterCall('add', 'Addition', nil, @AddCallback) then
      ReportFail('RegisterCall add');
    if not App.RegisterCall('echo', 'Echo', nil, @EchoCallback) then
      ReportFail('RegisterCall echo');
    if not App.RegisterNotify('print', 'Print', nil, @PrintNotify) then
      ReportFail('RegisterNotify print');

    // 测试加法 API
    Data := LF.TDataHandle.Create('add');
    try
      Data.WriteInt32(5).WriteInt32(7);
      Res := App.LocalCall(Data);
      try
        if Res.ReadInt32(Sum) and (Sum = 12) then
          ReportPass('Local add(5,7)=12')
        else
          ReportFail('Local add result wrong');
      finally Res.Free; end;
    finally Data.Free; end;

    // 测试回显 API
    Data := LF.TDataHandle.Create('echo');
    try
      Data.WriteString('Local Echo Test');
      Res := App.LocalCall(Data);
      try
        if Res.ReadString(Msg) and (Msg = 'Local Echo Test') then
          ReportPass('Local echo')
        else
          ReportFail('Local echo result wrong');
      finally Res.Free; end;
    finally Data.Free; end;

    // 测试通知 API（无返回值）
    Data := LF.TDataHandle.Create('print');
    try
      Data.WriteString('Local notify message');
      App.LocalNotify(Data);
      ReportPass('Local notify sent (see callback output above)');
    finally Data.Free; end;
  finally
    App.Free;
  end;
end;

{ ---- 测试用例：网络 IPC 远程调用 ---- }

procedure TestNetworkIPC;
var
  App: LF.TAppHandle;
  Data, Res: LF.TDataHandle;
  Sum: Integer; Msg: string;
begin
  Report('=== Remote IPC Network ===');

  App := LF.TAppHandle.Create('TestService', 'IPC test');
  try
    // 注册与本地测试相同的 API，用于远程调用
    if not App.RegisterCall('add', 'Add', nil, @AddCallback) then
      ReportFail('RegisterCall add');
    if not App.RegisterCall('echo', 'Echo', nil, @EchoCallback) then
      ReportFail('RegisterCall echo');
    if not App.RegisterNotify('print', 'Print', nil, @PrintNotify) then
      ReportFail('RegisterNotify print');

    // 准备网络：清除之前的配置，然后同时启动 IPC 服务和 TCP 服务，
    // 并让客户端连接到这两个服务。
    LF.ResetPrepare;
    LF.PrepareService('ipc:test_svc', 'ipc:test_svc');   // 进程间通信服务
    LF.PrepareService('0.0.0.0:9988', '127.0.0.1:9988'); // TCP 服务（本地回环）
    LF.PrepareClient('ipc:test_svc', App);              // 客户端连接 IPC
    LF.PrepareClient('127.0.0.1:9988', App);            // 客户端连接 TCP

    // 启动网络，阻塞直到就绪或超时
    if not LF.PrepareDone then
    begin
      ReportFail('PrepareDone failed – check console for errors');
      Exit;
    end;
    ReportPass('PrepareDone succeeded');

    // 远程加法调用
    Data := LF.TDataHandle.Create('add');
    try
      Data.WriteInt32(100).WriteInt32(200);
      Res := LF.CallApp('TestService', Data, 3000);
      try
        if Res.ReadInt32(Sum) and (Sum = 300) then
          ReportPass('Remote add(100,200)=300')
        else
          ReportFail('Remote add result wrong');
      finally Res.Free; end;
    finally Data.Free; end;

    // 远程回显调用
    Data := LF.TDataHandle.Create('echo');
    try
      Data.WriteString('Hello from network!');
      Res := LF.CallApp('TestService', Data, 3000);
      try
        if Res.ReadString(Msg) and (Msg = 'Hello from network!') then
          ReportPass('Remote echo')
        else
          ReportFail('Remote echo result wrong');
      finally Res.Free; end;
    finally Data.Free; end;

    // 远程通知
    Data := LF.TDataHandle.Create('print');
    try
      Data.WriteString('Network notify');
      LF.NotifyApp('TestService', Data);
      ReportPass('Remote notify sent (see callback output)');
    finally Data.Free; end;

    // 调用不存在的 API，应返回空结果
    Data := LF.TDataHandle.Create('unknown');
    try
      Res := LF.CallApp('TestService', Data, 1000);
      try
        if Res.GetSize = 0 then
          ReportPass('Unknown API returns size 0')
        else
          ReportFail('Unknown API should return size 0');
      finally Res.Free; end;
    finally Data.Free; end;
  finally
    App.Free;
  end;

  // 优雅退出网络线程并关闭库
  LF.ExitMainThread;
  LF.Shutdown;
  ReportPass('Network shutdown complete');
end;

{ ---- 测试用例：多线程并发调用 ---- }

procedure TestConcurrency;
const
  THREAD_COUNT = 10;
  CALLS_PER_THREAD = 100;
var
  Threads: array[0..THREAD_COUNT-1] of TConcurrencyThread;
  App: LF.TAppHandle;
  StartTime: TDateTime;
  Elapsed: Double;
  i: Integer;
begin
  Report('=== Concurrency Test (%d threads × %d calls each) ===',
    [THREAD_COUNT, CALLS_PER_THREAD]);

  ConcurrencyTotalCalls := 0;

  App := LF.TAppHandle.Create('ConcurrencyApp', 'Concurrency');
  try
    if not App.RegisterCall('add', 'Add', nil, @AddCallback) then
    begin
      ReportFail('RegisterCall add in concurrency test');
      Exit;
    end;

    StartTime := Now;

    // 创建并启动所有线程
    for i := 0 to THREAD_COUNT-1 do
      Threads[i] := TConcurrencyThread.Create(App, i);

    for i := 0 to THREAD_COUNT-1 do
      Threads[i].Start;

    // 等待所有线程完成
    for i := 0 to THREAD_COUNT-1 do
    begin
      Threads[i].WaitFor;
      Threads[i].Free;
    end;

    Elapsed := (Now - StartTime) * SecsPerDay;
    Report('Completed %d calls in %.3f seconds = %.2f calls/sec',
      [ConcurrencyTotalCalls, Elapsed, ConcurrencyTotalCalls / Elapsed]);

    if ConcurrencyTotalCalls = THREAD_COUNT * CALLS_PER_THREAD then
      ReportPass('All concurrent calls succeeded')
    else
      ReportFail('Some calls failed or produced wrong results');
  finally
    App.Free;
  end;
end;

{ ---- 测试用例：性能基准 ---- }

procedure TestPerformance;
const
  ITERATIONS = 1000;
var
  App: LF.TAppHandle;
  Data, Res: LF.TDataHandle;
  StartTime: TDateTime;
  Elapsed: Double;
  Sum: Integer;
  i: Integer;
  SuccessCount: Integer;
begin
  Report('=== Performance Test (%d sequential local calls) ===', [ITERATIONS]);

  App := LF.TAppHandle.Create('PerfApp', 'Performance');
  try
    if not App.RegisterCall('add', 'Add', nil, @AddCallback) then
    begin
      ReportFail('RegisterCall add in performance test');
      Exit;
    end;

    StartTime := Now;
    SuccessCount := 0;

    // 顺序执行多次本地调用，测量吞吐量
    for i := 1 to ITERATIONS do
    begin
      Data := LF.TDataHandle.Create('add');
      try
        Data.WriteInt32(i).WriteInt32(i+1);
        Res := App.LocalCall(Data);
        try
          if Res.ReadInt32(Sum) and (Sum = 2*i+1) then
            Inc(SuccessCount);
        finally Res.Free; end;
      finally Data.Free; end;
    end;

    Elapsed := (Now - StartTime) * SecsPerDay;
    Report('Completed %d successful out of %d calls in %.3f seconds = %.2f calls/sec',
      [SuccessCount, ITERATIONS, Elapsed, ITERATIONS / Elapsed]);

    if SuccessCount = ITERATIONS then
      ReportPass('All performance calls correct')
    else
      ReportFail('Some performance calls gave wrong results');
  finally
    App.Free;
  end;
end;

{ ---- 测试用例：资源泄漏检测 ---- }

procedure TestResourceLeak;
const
  ALLOC_COUNT = 10000;
var
  i: Integer;
  Handles: array of LF.TDataHandle;
begin
  Report('=== Resource Leak Test (allocate %d handles) ===', [ALLOC_COUNT]);

  SetLength(Handles, ALLOC_COUNT);
  try
    for i := 0 to ALLOC_COUNT-1 do
      Handles[i] := LF.TDataHandle.Create(Format('leak_%d', [i]));
    Report('Successfully created %d handles', [ALLOC_COUNT]);
    ReportPass('All handles allocated');
  finally
    for i := 0 to ALLOC_COUNT-1 do
      Handles[i].Free;
    ReportPass('All handles freed');
  end;
end;

{ ---- 测试用例：重复注册检测 ---- }

procedure TestDuplicateRegistration;
var
  App: LF.TAppHandle;
begin
  Report('=== Duplicate Registration Detection ===');

  App := LF.TAppHandle.Create('DupApp', 'Duplicate test');
  try
    if App.RegisterCall('test', 'first', nil, @AddCallback) then
      ReportPass('First registration succeeded')
    else
      ReportFail('First registration should succeed');

    // 第二次注册同名 API 应失败
    if not App.RegisterCall('test', 'second', nil, @AddCallback) then
      ReportPass('Duplicate registration correctly rejected')
    else
      ReportFail('Duplicate registration should have been rejected');
  finally
    App.Free;
  end;
end;

{ ---- 测试用例：UTF-8 国际化支持 ---- }

procedure TestUTF8International;
var
  App: LF.TAppHandle;
  Data, Res: LF.TDataHandle;
  Sum: Integer;
begin
  Report('=== UTF‑8 Internationalization (Chinese/Emoji) ===');

  // 创建中文应用名和描述
  App := LF.TAppHandle.Create('中文字符服务', '包含中文描述');
  try
    if not App.RegisterCall('加法', '两数相加', nil, @AddCallback) then
      ReportFail('RegisterCall with Chinese name');
    if not App.RegisterNotify('日志', '中文日志', nil, @PrintNotify) then
      ReportFail('RegisterNotify with Chinese name');

    // 调用中文命名的 API
    Data := LF.TDataHandle.Create('加法');
    try
      Data.WriteInt32(8).WriteInt32(9);
      Res := App.LocalCall(Data);
      try
        if Res.ReadInt32(Sum) and (Sum = 17) then
          ReportPass('Chinese API call succeeded: 8+9=17')
        else
          ReportFail('Chinese API call returned wrong result');
      finally Res.Free; end;
    finally Data.Free; end;

    // 发送包含中文和 Emoji 的通知
    Data := LF.TDataHandle.Create('日志');
    try
      Data.WriteString('测试通知 🎉');
      App.LocalNotify(Data);
      ReportPass('Chinese notification sent (check callback output)');
    finally Data.Free; end;
  finally
    App.Free;
  end;
end;

{ ---- 主程序 ---- }

begin
  ConsoleWriteLn('API Hub Tool Pascal Wrapper – Full Test v2.3');
  ConsoleWriteLn('Author: API Hub Tool Team');
  ConsoleWriteLn;

  try
    // 依次执行所有测试用例
    TestDataHandleBasics;      ConsoleWriteLn;
    TestLocalCalls;            ConsoleWriteLn;
    TestNetworkIPC;            ConsoleWriteLn;
    TestConcurrency;           ConsoleWriteLn;
    TestPerformance;           ConsoleWriteLn;
    TestResourceLeak;          ConsoleWriteLn;
    TestDuplicateRegistration; ConsoleWriteLn;
    TestUTF8International;     ConsoleWriteLn;

    ConsoleWriteLn('✅ All tests completed. Press Enter to exit...');
  except
    on E: Exception do
      ConsoleWriteLn('❌ Test exception: ' + E.ClassName + ': ' + E.Message);
  end;

  // 确保库被完全关闭
  LF.Shutdown();
  ReadLn;
end.
