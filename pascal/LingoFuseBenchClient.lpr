{
 * ============================================================================
 * LingoFuseBenchClient – LingoFuse 分布式 RPC 压测客户端
 * ============================================================================
 *
 * 本程序是一个多线程、高并发的 RPC 压测工具，用于对 LingoFuse 远端服务
 * （BenchServer）进行压力测试和性能评估。它通过 20 个不同的 API 接口
 * 模拟真实业务负载，统计每个 API 的调用次数、成功率、延迟分布和整体
 * 吞吐量（QPS）。
 *
 * 主要特性：
 *   - 支持可配置的并发线程数和每线程调用次数（默认 50 线程 × 20 次）
 *   - 20 个 API 自动轮询（Round‑Robin），涵盖算术、哈希、加密、编码等
 *   - 细粒度统计：每个 API 独立记录总调用、成功数、平均/最小/最大延迟
 *   - 使用 IPC 通信（默认 ipc:bench_service），也可修改为 TCP
 *   - 内置预热机制，减少冷启动干扰
 *
 * 性能分析提示：程序会输出高延迟的常见原因及优化建议，帮助开发者定位
 * 瓶颈（JSON 序列化、日志输出、sleep 累积等）。
 *
 * 使用前提：
 *   - BenchServer 必须已在同一台机器上运行，并监听 ipc:bench_service
 *   - LingoFuse 动态库（LingoFuse64.dll / liblingofuse.so）必须可加载
 *
 * 编译：Free Pascal 3.0+ 或 Delphi 2009+，需链接 lingofuse_helper 和 Z 库。
 * ============================================================================
 }
program LingoFuseBenchClient;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
{$endif}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,                // Unix 下多线程支持
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,                 // Windows 控制台输出 API
  {$ENDIF}
  Classes, SysUtils, Variants, DateUtils, SyncObjs,
  lingofuse_helper,        // LingoFuse 高级封装
  lingofuse_import,        // LingoFuse 底层导入
  Z.Core,                  // Z 框架基础库
  Z.Status,                // 日志状态（本程序未直接使用，但保留）
  Z.UnicodeMixedLib,       // Unicode 工具
  Z.Json,                  // JSON 解析/生成
  Z.PascalStrings,         // Pascal 字符串增强
  Z.UPascalStrings;        // Unicode 字符串

const
  DEFAULT_THREADS = 50;           // 默认并发线程数
  DEFAULT_CALLS_PER_THREAD = 20;  // 每个线程的调用次数
  TIMEOUT_MS = 10000;             // 远程调用超时（毫秒）
  SERVER_APP = 'BenchServer';     // 远端服务应用名称
  SERVER_ENDPOINT = 'ipc:bench_service'; // IPC 端点地址

type
  { * TAPIStats: 单个 API 的统计信息记录。
    * 用于记录每个 API 的总调用次数、成功次数、累计耗时及极值。
    * }
  TAPIStats = record
    Name: string;          // API 名称（如 'add'）
    TotalCalls: integer;   // 总调用次数
    SuccessCalls: integer; // 成功次数
    TotalTime: int64;      // 所有成功调用的总耗时（微秒）
    MinTime: int64;        // 单次最小耗时（微秒）
    MaxTime: int64;        // 单次最大耗时（微秒）
  end;
  PAPIStats = ^TAPIStats;

var
  Stats: array[0..19] of TAPIStats;   // 20 个 API 的统计数组
  StatsLock: TCriticalSection;        // 保护 Stats 数组的临界区
  Running: boolean;                   // 全局运行标志，控制线程是否继续
  GlobalCallCounter: int64;           // 全局调用计数器（仅用于监控）
  GlobalCallCounterLock: TCriticalSection; // 保护计数器的临界区

{
 * 将 Pascal 字符串转换为 UTF-8 编码，保证跨编译器一致性。
 }
function ToUTF8(const S: string): utf8string;
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
 * 向控制台输出 UTF-8 字符串，自动处理 Windows 和 Unix 的差异。
 }
procedure ConsoleWrite(const S: string);
var
  UTF8Str: utf8string;
  {$IFDEF MSWINDOWS}
  WStr: unicodestring;
  Written: DWORD;
  {$ENDIF}
begin
  if not IsConsole then Exit;
  UTF8Str := ToUTF8(S);
  {$IFDEF MSWINDOWS}
  WStr := UTF8Decode(UTF8Str);
  WriteConsoleW(GetStdHandle(STD_OUTPUT_HANDLE),
    pwidechar(WStr), Length(WStr), Written, nil);
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
 * 执行远程调用（Call 模式）的通用函数。
 * @param AppName      目标应用名称（通常为 SERVER_APP）
 * @param MethodName   API 名称（如 'add'）
 * @param RequestJSON  请求 JSON 字符串
 * @param ResponseJSON 返回的响应 JSON 字符串（输出参数）
 * @param ErrorMsg     错误信息（输出参数）
 * @return True 表示调用成功且能读取到响应字符串；False 表示失败。
 * @note 该函数内部创建并释放数据句柄，调用者无需额外管理。
 *       超时由 TIMEOUT_MS 常量控制。
 }
function DoRemoteCall(const AppName, MethodName, RequestJSON: string; out ResponseJSON: string; out ErrorMsg: string): boolean;
var
  HndData, HndRes: LF.TDataHandle;
begin
  Result := False;
  ResponseJSON := '';
  ErrorMsg := '';
  HndData := LF.TDataHandle.Create(MethodName);
  try
    HndData.WriteString(RequestJSON);
    HndRes := LF.CallApp(AppName, HndData, TIMEOUT_MS);
    try
      if HndRes = nil then
      begin
        ErrorMsg := 'CallApp 返回 nil';
        Exit;
      end;
      HndRes.SetPos(0);
      if not HndRes.ReadString(ResponseJSON) then
      begin
        ErrorMsg := '读取响应字符串失败';
        Exit;
      end;
      Result := True;
    finally
      HndRes.Free;
    end;
  finally
    HndData.Free;
  end;
end;

{ ---- 以下是 20 个 API 的包装函数，每个函数执行一次远程调用并返回结果 ---- }

{
 * 调用 add API：两数相加（随机参数），返回计算结果。
 * @param outVal 返回计算结果（整数）
 * @return True 表示调用成功且结果有效
 }
function CallAdd(out outVal: integer): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b: integer;
begin
  Result := False;
  a := Random(100);
  b := Random(100);
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  if DoRemoteCall(SERVER_APP, 'add', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.I['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 sub API：两数相减，返回差值。
 }
function CallSub(out outVal: integer): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b: integer;
begin
  Result := False;
  a := Random(100);
  b := Random(100);
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  if DoRemoteCall(SERVER_APP, 'sub', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.I['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 mul API：两数相乘，返回乘积。
 }
function CallMul(out outVal: integer): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b: integer;
begin
  Result := False;
  a := Random(100);
  b := Random(100);
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  if DoRemoteCall(SERVER_APP, 'mul', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.I['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 div API：两数相除（浮点数结果），返回商。
 * @param outVal 返回浮点数结果
 }
function CallDiv(out outVal: double): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b: integer;
begin
  Result := False;
  a := Random(100) + 1;  // 避免除零
  b := Random(10) + 1;
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  if DoRemoteCall(SERVER_APP, 'div', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.F['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 eval API：表达式求值，返回结果字符串。
 }
function CallEval(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
begin
  Result := False;
  Req := '{"expr":"' + IntToStr(Random(100)) + '+' + IntToStr(Random(100)) + '*2"}';
  if DoRemoteCall(SERVER_APP, 'eval', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.S['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 md5 API：计算字符串的 MD5 哈希，返回 32 位十六进制字符串。
 }
function CallMD5(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  Data: string;
begin
  Result := False;
  Data := 'test_' + IntToStr(Random(9999));
  Req := Format('{"data":"%s"}', [Data]);
  if DoRemoteCall(SERVER_APP, 'md5', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('md5') then
      begin
        outVal := jo.S['md5'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 sha1 API：计算 SHA-1 哈希，返回 40 位十六进制字符串。
 }
function CallSHA1(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  Data: string;
begin
  Result := False;
  Data := 'test_' + IntToStr(Random(9999));
  Req := Format('{"data":"%s"}', [Data]);
  if DoRemoteCall(SERVER_APP, 'sha1', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('sha1') then
      begin
        outVal := jo.S['sha1'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 sha256 API：计算 SHA-256 哈希，返回 64 位十六进制字符串。
 }
function CallSHA256(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  Data: string;
begin
  Result := False;
  Data := 'test_' + IntToStr(Random(9999));
  Req := Format('{"data":"%s"}', [Data]);
  if DoRemoteCall(SERVER_APP, 'sha256', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('sha256') then
      begin
        outVal := jo.S['sha256'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 sha512 API：计算 SHA-512 哈希，返回 128 位十六进制字符串。
 }
function CallSHA512(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  Data: string;
begin
  Result := False;
  Data := 'test_' + IntToStr(Random(9999));
  Req := Format('{"data":"%s"}', [Data]);
  if DoRemoteCall(SERVER_APP, 'sha512', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('sha512') then
      begin
        outVal := jo.S['sha512'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 aes_encrypt API：AES 加密，返回 base64 编码的密文。
 }
function CallAESEncrypt(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  Data, key: string;
begin
  Result := False;
  Data := 'secret_' + IntToStr(Random(999));
  key := 'key_' + IntToStr(Random(999));
  Req := Format('{"data":"%s","key":"%s"}', [Data, key]);
  if DoRemoteCall(SERVER_APP, 'aes_encrypt', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('cipher') then
      begin
        outVal := jo.S['cipher'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 aes_decrypt API：AES 解密，返回明文。
 * 注意：密文和密钥为固定测试值，仅用于功能验证。
 }
function CallAESDecrypt(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  cipher, key: string;
begin
  Result := False;
  cipher := 'c2VjcmV0Xyc=';  // 固定测试密文
  key := 'key_123';
  Req := Format('{"cipher":"%s","key":"%s"}', [cipher, key]);
  if DoRemoteCall(SERVER_APP, 'aes_decrypt', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('plain') then
      begin
        outVal := jo.S['plain'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 base64_encode API：Base64 编码，返回编码后的字符串。
 }
function CallBase64Encode(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  Data: string;
begin
  Result := False;
  Data := 'data_' + IntToStr(Random(999));
  Req := Format('{"data":"%s"}', [Data]);
  if DoRemoteCall(SERVER_APP, 'base64_encode', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('base64') then
      begin
        outVal := jo.S['base64'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 base64_decode API：Base64 解码，返回解码后的字符串。
 * 使用固定编码值 'aGVsbG8=' 测试。
 }
function CallBase64Decode(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  encoded: string;
begin
  Result := False;
  encoded := 'aGVsbG8=';
  Req := Format('{"base64":"%s"}', [encoded]);
  if DoRemoteCall(SERVER_APP, 'base64_decode', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('decoded') then
      begin
        outVal := jo.S['decoded'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 random API：生成指定范围内的随机整数，返回该整数。
 }
function CallRandom(out outVal: integer): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  minVal, maxVal: integer;
begin
  Result := False;
  minVal := 1;
  maxVal := 1000;
  Req := Format('{"min":%d,"max":%d}', [minVal, maxVal]);
  if DoRemoteCall(SERVER_APP, 'random', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('value') then
      begin
        outVal := jo.I['value'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 upper API：字符串转大写，返回转换后的字符串。
 }
function CallUpper(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  str: string;
begin
  Result := False;
  str := 'hello_' + IntToStr(Random(999));
  Req := Format('{"str":"%s"}', [str]);
  if DoRemoteCall(SERVER_APP, 'upper', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.S['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 lower API：字符串转小写，返回转换后的字符串。
 }
function CallLower(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  str: string;
begin
  Result := False;
  str := 'HELLO_' + IntToStr(Random(999));
  Req := Format('{"str":"%s"}', [str]);
  if DoRemoteCall(SERVER_APP, 'lower', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.S['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 reverse API：字符串反转，返回反转后的字符串。
 }
function CallReverse(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  str: string;
begin
  Result := False;
  str := 'reverse_' + IntToStr(Random(999));
  Req := Format('{"str":"%s"}', [str]);
  if DoRemoteCall(SERVER_APP, 'reverse', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('result') then
      begin
        outVal := jo.S['result'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 timestamp API：获取当前时间戳（毫秒级），返回 int64。
 }
function CallTimestamp(out outVal: int64): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
begin
  Result := False;
  Req := '{}';
  if DoRemoteCall(SERVER_APP, 'timestamp', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('timestamp') then
      begin
        outVal := jo.I64['timestamp'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 sleep API：让服务端休眠指定毫秒数，返回状态字符串。
 * 休眠时间随机 1-10ms。
 }
function CallSleep(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  ms: integer;
begin
  Result := False;
  ms := Random(10) + 1;
  Req := Format('{"ms":%d}', [ms]);
  if DoRemoteCall(SERVER_APP, 'sleep', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('status') then
      begin
        outVal := jo.S['status'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

{
 * 调用 echo API：消息回显，返回原消息。
 }
function CallEcho(out outVal: string): boolean;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  msg: string;
begin
  Result := False;
  msg := 'echo_' + IntToStr(Random(999));
  Req := Format('{"msg":"%s"}', [msg]);
  if DoRemoteCall(SERVER_APP, 'echo', Req, Resp, Err) then
  begin
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('echo') then
      begin
        outVal := jo.S['echo'];
        Result := True;
      end;
    finally
      jo.Free;
    end;
  end;
end;

type
  { * TWorkerThread: 工作线程，负责执行一定数量的远程调用。
    * 每个线程在循环中随机选择 20 个 API 之一进行调用，并更新全局统计。
    * }
  TWorkerThread = class(TThread)
  private
    FThreadIndex: integer;      // 线程索引（仅用于调试）
    FCallsPerThread: integer;   // 该线程应执行的调用次数
    FCompletedCalls: integer;   // 已完成调用计数（实际调用次数）
  public
    constructor Create(ThreadIndex, CallsPerThread: integer);
    procedure Execute; override;
  end;

constructor TWorkerThread.Create(ThreadIndex, CallsPerThread: integer);
begin
  inherited Create(False);      // 创建即启动
  FThreadIndex := ThreadIndex;
  FCallsPerThread := CallsPerThread;
  FCompletedCalls := 0;
  FreeOnTerminate := False;     // 由主线程负责释放
end;

procedure TWorkerThread.Execute;
var
  I, idx: integer;
  StartTime, EndTime: int64;
  Elapsed: int64;
  Success: boolean;
  tmpInt: integer;
  tmpFloat: double;
  tmpStr: string;
  tmpInt64: int64;
begin
  for I := 1 to FCallsPerThread do
  begin
    if not Running then Break;   // 检查全局停止标志

    // 轮询选择 API（顺序循环）
    idx := (I - 1) mod 20;

    // 记录开始时间（微秒，GetTickCount64 返回毫秒，乘以 1000 转为微秒）
    StartTime := GetTickCount64 * 1000;
    Success := False;

    // 根据 idx 调用对应的 API
    case idx of
      0: Success := CallAdd(tmpInt);
      1: Success := CallSub(tmpInt);
      2: Success := CallMul(tmpInt);
      3: Success := CallDiv(tmpFloat);
      4: Success := CallEval(tmpStr);
      5: Success := CallMD5(tmpStr);
      6: Success := CallSHA1(tmpStr);
      7: Success := CallSHA256(tmpStr);
      8: Success := CallSHA512(tmpStr);
      9: Success := CallAESEncrypt(tmpStr);
      10: Success := CallAESDecrypt(tmpStr);
      11: Success := CallBase64Encode(tmpStr);
      12: Success := CallBase64Decode(tmpStr);
      13: Success := CallRandom(tmpInt);
      14: Success := CallUpper(tmpStr);
      15: Success := CallLower(tmpStr);
      16: Success := CallReverse(tmpStr);
      17: Success := CallTimestamp(tmpInt64);
      18: Success := CallSleep(tmpStr);
      19: Success := CallEcho(tmpStr);
    end;

    EndTime := GetTickCount64 * 1000;
    Elapsed := EndTime - StartTime;  // 微秒

    // 更新对应 API 的统计（临界区保护）
    StatsLock.Enter;
    try
      with Stats[idx] do
      begin
        Inc(TotalCalls);
        if Success then
        begin
          Inc(SuccessCalls);
          TotalTime := TotalTime + Elapsed;
          if (MinTime = 0) or (Elapsed < MinTime) then MinTime := Elapsed;
          if Elapsed > MaxTime then MaxTime := Elapsed;
        end;
      end;
    finally
      StatsLock.Leave;
    end;

    // 更新全局调用计数器（用于显示进度，非关键）
    GlobalCallCounterLock.Enter;
    try
      Inc(GlobalCallCounter);
    finally
      GlobalCallCounterLock.Leave;
    end;

    Inc(FCompletedCalls);

    // 每 10 次调用让出 CPU，避免饥饿
    if I mod 10 = 0 then Sleep(0);
  end;
end;

{ ---- 主程序 ---- }

var
  I: integer;
  ThreadCount, CallsPerThread: integer;
  Threads: array of TWorkerThread;
  StartTime, EndTime: TDateTime;
  TotalCalls, TotalSuccess: integer;
  TotalElapsed: int64;
  QPS: double;
  input_: string;
  apiNames: array[0..19] of string = ('add', 'sub', 'mul', 'div', 'eval', 'md5', 'sha1', 'sha256', 'sha512', 'aes_encrypt', 'aes_decrypt', 'base64_encode', 'base64_decode', 'random', 'upper', 'lower', 'reverse', 'timestamp', 'sleep', 'echo');

begin
  Randomize;

  ConsoleWriteLn('╔══════════════════════════════════════════════════════════════╗');
  ConsoleWriteLn('║       LingoFuse 压测客户端 (Benchmark Client)  v2.0          ║');
  ConsoleWriteLn('║       对 BenchServer 进行 20 API 并发压测                    ║');
  ConsoleWriteLn('╚══════════════════════════════════════════════════════════════╝');
  ConsoleWriteLn('');

  ThreadCount := DEFAULT_THREADS;
  CallsPerThread := DEFAULT_CALLS_PER_THREAD;

  ConsoleWriteLn('压测配置:');
  ConsoleWriteLn('   目标服务  : ' + SERVER_APP + ' @ ' + SERVER_ENDPOINT);
  ConsoleWriteLn('   并发线程数: ' + IntToStr(ThreadCount));
  ConsoleWriteLn('   每线程调用: ' + IntToStr(CallsPerThread));
  ConsoleWriteLn('   总调用次数: ' + IntToStr(ThreadCount * CallsPerThread));
  ConsoleWriteLn('');

  // 输出性能分析建议（帮助开发者理解延迟来源）
  ConsoleWriteLn('高延迟原因分析 (仅供参考):');
  ConsoleWriteLn('   1. 服务端 JSON 序列化/反序列化 (TZ_JsonObject)');
  ConsoleWriteLn('   2. 服务端控制台日志输出 (ConsoleWriteLn)');
  ConsoleWriteLn('   3. sleep API 的累积阻塞 (1-10ms/次)');
  ConsoleWriteLn('   4. C4 线程池调度和上下文切换开销');
  ConsoleWriteLn('   5. API.TDataHandle 多次底层读写操作');
  ConsoleWriteLn('');
  ConsoleWriteLn('优化建议:');
  ConsoleWriteLn('   - 生产环境关闭服务端 ConsoleWriteLn');
  ConsoleWriteLn('   - 使用二进制协议替代 JSON 序列化');
  ConsoleWriteLn('   - 增加 C4 线程池大小');
  ConsoleWriteLn('   - 使用更轻量的序列化方式 (如 MessagePack)');
  ConsoleWriteLn('');

  // 初始化统计数据和锁
  StatsLock := TCriticalSection.Create;
  GlobalCallCounterLock := TCriticalSection.Create;

  for I := 0 to 19 do
  begin
    Stats[I].Name := apiNames[I];
    Stats[I].TotalCalls := 0;
    Stats[I].SuccessCalls := 0;
    Stats[I].TotalTime := 0;
    Stats[I].MinTime := 0;
    Stats[I].MaxTime := 0;
  end;

  // 连接服务器
  LF.ResetPrepare;
  LF.PrepareClient(SERVER_ENDPOINT, nil);  // 不暴露应用，只作为客户端

  if not LF.PrepareDone then
  begin
    ConsoleWriteLn('连接服务器失败，请确保 BenchServer 已启动');
    LF.Shutdown;
    Halt(1);
  end;

  ConsoleWriteLn('已连接到 ' + SERVER_ENDPOINT);
  ConsoleWriteLn('');

  // 预热：执行几次简单调用，减少冷启动误差
  ConsoleWriteLn('预热中...');
  CallAdd(I);
  CallSub(I);
  CallMul(I);

  ConsoleWriteLn('开始压测...');
  ConsoleWriteLn('');

  Running := True;
  GlobalCallCounter := 0;
  StartTime := Now;

  // 创建并启动所有工作线程
  SetLength(Threads, ThreadCount);
  for I := 0 to ThreadCount - 1 do
    Threads[I] := TWorkerThread.Create(I, CallsPerThread);

  // 等待所有线程完成
  for I := 0 to ThreadCount - 1 do
  begin
    Threads[I].WaitFor;
    Threads[I].Free;
  end;

  EndTime := Now;
  Running := False;

  // 汇总统计
  TotalCalls := 0;
  TotalSuccess := 0;
  TotalElapsed := 0;
  for I := 0 to 19 do
  begin
    TotalCalls := TotalCalls + Stats[I].TotalCalls;
    TotalSuccess := TotalSuccess + Stats[I].SuccessCalls;
    TotalElapsed := TotalElapsed + Stats[I].TotalTime;
  end;

  // 计算 QPS（每秒查询数），注意 TotalElapsed 为微秒
  if TotalElapsed > 0 then
    QPS := TotalSuccess / (TotalElapsed / 1000000)
  else
    QPS := 0;

  ConsoleWriteLn('');
  ConsoleWriteLn('压测结果汇总');
  ConsoleWriteLn('  总调用数    : ' + IntToStr(TotalCalls));
  ConsoleWriteLn('  成功数      : ' + IntToStr(TotalSuccess));
  ConsoleWriteLn('  失败数      : ' + IntToStr(TotalCalls - TotalSuccess));
  ConsoleWriteLn('  成功率      : ' + Format('%.2f%%', [(TotalSuccess / TotalCalls) * 100]));
  ConsoleWriteLn('  总耗时      : ' + Format('%.2f 秒', [(EndTime - StartTime) * SecsPerDay]));
  ConsoleWriteLn('  吞吐量 (QPS): ' + Format('%.2f', [QPS]));
  ConsoleWriteLn('');

  // 输出每个 API 的详细统计（表格形式）
  ConsoleWriteLn('各 API 详细统计:');
  ConsoleWriteLn('  API 名称           调用数   成功数  平均(μs)  最小(μs)  最大(μs)');
  ConsoleWriteLn('  --------------------------------------------------------------');
  for I := 0 to 19 do
  begin
    with Stats[I] do
    begin
      if SuccessCalls > 0 then
        ConsoleWriteLn(Format('  %-18s %8d %8d %10d %10d %10d', [Name, TotalCalls, SuccessCalls, TotalTime div SuccessCalls, MinTime, MaxTime]))
      else
        ConsoleWriteLn(Format('  %-18s %8d %8d %10s %10s %10s', [Name, TotalCalls, SuccessCalls, 'N/A', 'N/A', 'N/A']));
    end;
  end;

  ConsoleWriteLn('');
  ConsoleWriteLn('正在清理...');

  // 优雅退出
  LF.ExitMainThread;
  LF.Shutdown;

  StatsLock.Free;
  GlobalCallCounterLock.Free;

  ConsoleWriteLn('压测完成！');
end.
