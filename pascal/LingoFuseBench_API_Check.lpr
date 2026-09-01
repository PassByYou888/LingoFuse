{
 * ============================================================================
 * LingoFuseBench_API_Check – LingoFuse 远端 API 功能验证工具
 * ============================================================================
 *
 * 本程序用于验证 LingoFuse 框架下远端服务（BenchServer）所提供的 20 个 API
 * 的正确性。它充当 RPC 客户端，通过 IPC 连接到 BenchServer，依次调用各个
 * 功能接口并检查返回结果是否符合预期。
 *
 * 测试覆盖的 API 类别：
 *   - 算术运算：add, sub, mul, div
 *   - 表达式求值：eval
 *   - 哈希算法：md5, sha1, sha256, sha512
 *   - 对称加密：aes_encrypt, aes_decrypt
 *   - 编码转换：base64_encode, base64_decode
 *   - 随机数生成：random
 *   - 字符串处理：upper, lower, reverse
 *   - 工具函数：timestamp, sleep, echo
 *
 * 所有 API 均以 JSON 格式传递请求参数和返回结果，确保跨语言兼容性。
 *
 * 使用前提：
 *   - BenchServer 必须已启动并监听指定的 IPC 端点（默认 ipc:bench_service）。
 *   - LingoFuse 动态库（LingoFuse64.dll / liblingofuse.so）必须可被加载。
 *
 * 编译：Free Pascal 3.0+ 或 Delphi 2009+，需链接 lingofuse_helper 和 Z 系列库。
 * ============================================================================
 }
program LingoFuseBench_API_Check;

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
  Classes, SysUtils, DateUtils,
  lingofuse_helper,        // LingoFuse 高级封装
  lingofuse_import,        // LingoFuse 底层导入
  Z.Core,                  // Z 框架基础库（含时间、字符串等）
  Z.Json,                  // JSON 解析和生成
  Z.PascalStrings,         // Pascal 字符串增强
  Z.UPascalStrings,        // Unicode Pascal 字符串
  Z.UnicodeMixedLib;       // 混合 Unicode 工具

{
 * 将 Pascal 字符串安全转换为 UTF-8 编码，确保跨编译器一致性。
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
 * 向控制台输出 UTF-8 字符串，自动处理 Windows 和 Unix 的差异。
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
 * 带颜色标记（通过文字前缀）的输出，用于测试结果的通过/失败。
 * @param IsOK  True 表示测试通过，输出 '[通过]'；否则输出 '[失败]'。
 }
procedure ConsoleWriteLnColor(const S: string; const IsOK: Boolean);
begin
  if IsOK then
    ConsoleWriteLn('[通过] ' + S)
  else
    ConsoleWriteLn('[失败] ' + S);
end;

const
  SERVER_APP = 'BenchServer';          // 远端服务应用名称
  SERVER_ENDPOINT = 'ipc:bench_service'; // 服务端点（IPC 地址）
  TIMEOUT_MS = 5000;                   // 远程调用超时（毫秒）

{
 * 执行远程调用（Call 模式）的通用函数。
 * @param MethodName  远端 API 名称（如 'add'）。
 * @param RequestJSON 请求 JSON 字符串。
 * @param ResponseJSON 返回的响应 JSON 字符串（输出参数）。
 * @param ErrorMsg    如果调用失败，返回错误信息（输出参数）。
 * @return True 表示调用成功且能读取到响应字符串；False 表示失败。
 * @note 该函数内部会创建并释放数据句柄，调用者无需额外管理。
 }
function DoRemoteCall(const MethodName, RequestJSON: string; out ResponseJSON: string; out ErrorMsg: string): Boolean;
var
  HndData, HndRes: LF.TDataHandle;
begin
  Result := False;
  ResponseJSON := '';
  ErrorMsg := '';
  HndData := LF.TDataHandle.Create(MethodName);
  try
    HndData.WriteString(RequestJSON);
    HndRes := LF.CallApp(SERVER_APP, HndData, TIMEOUT_MS);
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

{ ---- 以下是各个 API 的测试过程，每个过程测试一个远端 API ---- }

(*
 * 测试 add API：两数相加。
 * 发送 {"a":10,"b":20}，期望返回 {"result":30}。
 *)
procedure TestAdd;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b, sum: Integer;
begin
  a := 10; b := 20;
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  ConsoleWriteLn(Format('[add] 请求: %s', [Req]));
  if DoRemoteCall('add', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[add] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('add 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
      begin
        sum := jo.I['result'];
        if sum = a + b then
          ConsoleWriteLnColor(Format('add(%d,%d)=%d 正确', [a, b, sum]), True)
        else
          ConsoleWriteLnColor(Format('add(%d,%d) 结果 %d 期望 %d', [a, b, sum, a+b]), False);
      end
      else
        ConsoleWriteLnColor('add 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('add 调用失败: ' + Err, False);
end;

(*
 * 测试 sub API：两数相减。
 * 发送 {"a":50,"b":30}，期望返回 {"result":20}。
 *)
procedure TestSub;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b, diff: Integer;
begin
  a := 50; b := 30;
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  ConsoleWriteLn(Format('[sub] 请求: %s', [Req]));
  if DoRemoteCall('sub', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[sub] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('sub 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
      begin
        diff := jo.I['result'];
        if diff = a - b then
          ConsoleWriteLnColor(Format('sub(%d,%d)=%d 正确', [a, b, diff]), True)
        else
          ConsoleWriteLnColor(Format('sub(%d,%d) 结果 %d 期望 %d', [a, b, diff, a-b]), False);
      end
      else
        ConsoleWriteLnColor('sub 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('sub 调用失败: ' + Err, False);
end;

(*
 * 测试 mul API：两数相乘。
 * 发送 {"a":6,"b":7}，期望返回 {"result":42}。
 *)
procedure TestMul;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b, prod: Integer;
begin
  a := 6; b := 7;
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  ConsoleWriteLn(Format('[mul] 请求: %s', [Req]));
  if DoRemoteCall('mul', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[mul] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('mul 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
      begin
        prod := jo.I['result'];
        if prod = a * b then
          ConsoleWriteLnColor(Format('mul(%d,%d)=%d 正确', [a, b, prod]), True)
        else
          ConsoleWriteLnColor(Format('mul(%d,%d) 结果 %d 期望 %d', [a, b, prod, a*b]), False);
      end
      else
        ConsoleWriteLnColor('mul 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('mul 调用失败: ' + Err, False);
end;

(*
 * 测试 div API：两数相除（浮点数结果）。
 * 发送 {"a":10,"b":3}，期望返回接近 3.3333 的结果。
 *)
procedure TestDiv;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  a, b: Integer;
  quot: Double;
begin
  a := 10; b := 3;
  Req := Format('{"a":%d,"b":%d}', [a, b]);
  ConsoleWriteLn(Format('[div] 请求: %s', [Req]));
  if DoRemoteCall('div', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[div] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('div 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
      begin
        quot := jo.F['result'];
        if Abs(quot - (a / b)) < 0.0001 then
          ConsoleWriteLnColor(Format('div(%d,%d)=%f 正确', [a, b, quot]), True)
        else
          ConsoleWriteLnColor(Format('div(%d,%d) 结果 %f 期望 %f', [a, b, quot, a/b]), False);
      end
      else
        ConsoleWriteLnColor('div 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('div 调用失败: ' + Err, False);
end;

(*
 * 测试 eval API：表达式求值。
 * 发送 {"expr":"1+2*3"}，期望返回 {"result":"7"}（或数字形式）。
 *)
procedure TestEval;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
begin
  Req := '{"expr":"1+2*3"}';
  ConsoleWriteLn(Format('[eval] 请求: %s', [Req]));
  if DoRemoteCall('eval', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[eval] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('eval 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
        ConsoleWriteLnColor(Format('eval(1+2*3)=%s', [jo.S['result']]), True)
      else
        ConsoleWriteLnColor('eval 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('eval 调用失败: ' + Err, False);
end;

(*
 * 测试 md5 API：计算 MD5 哈希。
 * 发送 {"data":"hello"}，期望返回 32 位十六进制字符串。
 *)
procedure TestMD5;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  data, md5: string;
begin
  data := 'hello';
  Req := Format('{"data":"%s"}', [data]);
  ConsoleWriteLn(Format('[md5] 请求: %s', [Req]));
  if DoRemoteCall('md5', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[md5] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('md5 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('md5') then
      begin
        md5 := jo.S['md5'];
        if Length(md5) = 32 then
          ConsoleWriteLnColor(Format('md5("hello")=%s 长度正确', [md5]), True)
        else
          ConsoleWriteLnColor(Format('md5("hello") 长度 %d 期望 32', [Length(md5)]), False);
      end
      else
        ConsoleWriteLnColor('md5 响应缺少 md5 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('md5 调用失败: ' + Err, False);
end;

(*
 * 测试 sha1 API：计算 SHA-1 哈希。
 * 发送 {"data":"hello"}，期望返回 40 位十六进制字符串。
 *)
procedure TestSHA1;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  data, sha1: string;
begin
  data := 'hello';
  Req := Format('{"data":"%s"}', [data]);
  ConsoleWriteLn(Format('[sha1] 请求: %s', [Req]));
  if DoRemoteCall('sha1', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[sha1] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('sha1 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('sha1') then
      begin
        sha1 := jo.S['sha1'];
        if Length(sha1) = 40 then
          ConsoleWriteLnColor(Format('sha1("hello")=%s 长度正确', [sha1]), True)
        else
          ConsoleWriteLnColor(Format('sha1("hello") 长度 %d 期望 40', [Length(sha1)]), False);
      end
      else
        ConsoleWriteLnColor('sha1 响应缺少 sha1 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('sha1 调用失败: ' + Err, False);
end;

(*
 * 测试 sha256 API：计算 SHA-256 哈希。
 * 发送 {"data":"hello"}，期望返回 64 位十六进制字符串。
 *)
procedure TestSHA256;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  data, sha256: string;
begin
  data := 'hello';
  Req := Format('{"data":"%s"}', [data]);
  ConsoleWriteLn(Format('[sha256] 请求: %s', [Req]));
  if DoRemoteCall('sha256', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[sha256] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('sha256 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('sha256') then
      begin
        sha256 := jo.S['sha256'];
        if Length(sha256) = 64 then
          ConsoleWriteLnColor(Format('sha256("hello")=%s 长度正确', [sha256]), True)
        else
          ConsoleWriteLnColor(Format('sha256("hello") 长度 %d 期望 64', [Length(sha256)]), False);
      end
      else
        ConsoleWriteLnColor('sha256 响应缺少 sha256 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('sha256 调用失败: ' + Err, False);
end;

(*
 * 测试 sha512 API：计算 SHA-512 哈希。
 * 发送 {"data":"hello"}，期望返回 128 位十六进制字符串。
 *)
procedure TestSHA512;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  data, sha512: string;
begin
  data := 'hello';
  Req := Format('{"data":"%s"}', [data]);
  ConsoleWriteLn(Format('[sha512] 请求: %s', [Req]));
  if DoRemoteCall('sha512', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[sha512] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('sha512 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('sha512') then
      begin
        sha512 := jo.S['sha512'];
        if Length(sha512) = 128 then
          ConsoleWriteLnColor(Format('sha512("hello")=%s 长度正确', [sha512]), True)
        else
          ConsoleWriteLnColor(Format('sha512("hello") 长度 %d 期望 128', [Length(sha512)]), False);
      end
      else
        ConsoleWriteLnColor('sha512 响应缺少 sha512 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('sha512 调用失败: ' + Err, False);
end;

(*
 * 测试 aes_encrypt API：AES 加密（模拟）。
 * 发送 {"data":"secret","key":"password"}，期望返回 base64 编码的密文。
 *)
procedure TestAESEncrypt;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  data, key, cipher: string;
begin
  data := 'secret';
  key := 'password';
  Req := Format('{"data":"%s","key":"%s"}', [data, key]);
  ConsoleWriteLn(Format('[aes_encrypt] 请求: %s', [Req]));
  if DoRemoteCall('aes_encrypt', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[aes_encrypt] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('aes_encrypt 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('cipher') then
      begin
        cipher := jo.S['cipher'];
        if Length(cipher) > 0 then
          ConsoleWriteLnColor(Format('aes_encrypt 成功，密文长度 %d', [Length(cipher)]), True)
        else
          ConsoleWriteLnColor('aes_encrypt 返回空密文', False);
      end
      else
        ConsoleWriteLnColor('aes_encrypt 响应缺少 cipher 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('aes_encrypt 调用失败: ' + Err, False);
end;

(*
 * 测试 aes_decrypt API：AES 解密。
 * 发送 {"cipher":"aGVsbG8=","key":"password"}，期望返回明文 "hello"。
 *)
procedure TestAESDecrypt;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  cipher, key, plain: string;
begin
  cipher := 'aGVsbG8=';
  key := 'password';
  Req := Format('{"cipher":"%s","key":"%s"}', [cipher, key]);
  ConsoleWriteLn(Format('[aes_decrypt] 请求: %s', [Req]));
  if DoRemoteCall('aes_decrypt', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[aes_decrypt] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('aes_decrypt 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('plain') then
      begin
        plain := jo.S['plain'];
        ConsoleWriteLnColor(Format('aes_decrypt 成功，明文: %s', [plain]), True);
      end
      else
        ConsoleWriteLnColor('aes_decrypt 响应缺少 plain 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('aes_decrypt 调用失败: ' + Err, False);
end;

(*
 * 测试 base64_encode API：Base64 编码。
 * 发送 {"data":"hello"}，期望返回 {"base64":"aGVsbG8="}。
 *)
procedure TestBase64Encode;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  data, encoded: string;
begin
  data := 'hello';
  Req := Format('{"data":"%s"}', [data]);
  ConsoleWriteLn(Format('[base64_encode] 请求: %s', [Req]));
  if DoRemoteCall('base64_encode', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[base64_encode] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('base64_encode 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('base64') then
      begin
        encoded := jo.S['base64'];
        if Length(encoded) > 0 then
          ConsoleWriteLnColor(Format('base64_encode("hello")=%s', [encoded]), True)
        else
          ConsoleWriteLnColor('base64_encode 返回空字符串', False);
      end
      else
        ConsoleWriteLnColor('base64_encode 响应缺少 base64 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('base64_encode 调用失败: ' + Err, False);
end;

(*
 * 测试 base64_decode API：Base64 解码。
 * 发送 {"base64":"aGVsbG8="}，期望返回 {"decoded":"hello"}。
 *)
procedure TestBase64Decode;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  encoded, decoded: string;
begin
  encoded := 'aGVsbG8=';
  Req := Format('{"base64":"%s"}', [encoded]);
  ConsoleWriteLn(Format('[base64_decode] 请求: %s', [Req]));
  if DoRemoteCall('base64_decode', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[base64_decode] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('base64_decode 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('decoded') then
      begin
        decoded := jo.S['decoded'];
        if decoded = 'hello' then
          ConsoleWriteLnColor(Format('base64_decode("aGVsbG8=")="%s" 正确', [decoded]), True)
        else
          ConsoleWriteLnColor(Format('base64_decode 结果 "%s" 期望 "hello"', [decoded]), False);
      end
      else
        ConsoleWriteLnColor('base64_decode 响应缺少 decoded 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('base64_decode 调用失败: ' + Err, False);
end;

(*
 * 测试 random API：生成指定范围内的随机整数。
 * 发送 {"min":1,"max":100}，期望返回 1~100 之间的整数。
 *)
procedure TestRandom;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  minVal, maxVal, value: Integer;
begin
  minVal := 1; maxVal := 100;
  Req := Format('{"min":%d,"max":%d}', [minVal, maxVal]);
  ConsoleWriteLn(Format('[random] 请求: %s', [Req]));
  if DoRemoteCall('random', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[random] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('random 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('value') then
      begin
        value := jo.I['value'];
        if (value >= minVal) and (value <= maxVal) then
          ConsoleWriteLnColor(Format('random(%d,%d)=%d 在区间内', [minVal, maxVal, value]), True)
        else
          ConsoleWriteLnColor(Format('random(%d,%d)=%d 超出区间', [minVal, maxVal, value]), False);
      end
      else
        ConsoleWriteLnColor('random 响应缺少 value 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('random 调用失败: ' + Err, False);
end;

(*
 * 测试 upper API：字符串转大写。
 * 发送 {"str":"hello"}，期望返回 {"result":"HELLO"}。
 *)
procedure TestUpper;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  str, result: string;
begin
  str := 'hello';
  Req := Format('{"str":"%s"}', [str]);
  ConsoleWriteLn(Format('[upper] 请求: %s', [Req]));
  if DoRemoteCall('upper', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[upper] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('upper 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
      begin
        result := jo.S['result'];
        if result = 'HELLO' then
          ConsoleWriteLnColor(Format('upper("hello")="%s" 正确', [result]), True)
        else
          ConsoleWriteLnColor(Format('upper("hello")="%s" 期望 "HELLO"', [result]), False);
      end
      else
        ConsoleWriteLnColor('upper 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('upper 调用失败: ' + Err, False);
end;

(*
 * 测试 lower API：字符串转小写。
 * 发送 {"str":"HELLO"}，期望返回 {"result":"hello"}。
 *)
procedure TestLower;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  str, result: string;
begin
  str := 'HELLO';
  Req := Format('{"str":"%s"}', [str]);
  ConsoleWriteLn(Format('[lower] 请求: %s', [Req]));
  if DoRemoteCall('lower', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[lower] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('lower 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
      begin
        result := jo.S['result'];
        if result = 'hello' then
          ConsoleWriteLnColor(Format('lower("HELLO")="%s" 正确', [result]), True)
        else
          ConsoleWriteLnColor(Format('lower("HELLO")="%s" 期望 "hello"', [result]), False);
      end
      else
        ConsoleWriteLnColor('lower 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('lower 调用失败: ' + Err, False);
end;

(*
 * 测试 reverse API：字符串反转。
 * 发送 {"str":"hello"}，期望返回 {"result":"olleh"}。
 *)
procedure TestReverse;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  str, result: string;
begin
  str := 'hello';
  Req := Format('{"str":"%s"}', [str]);
  ConsoleWriteLn(Format('[reverse] 请求: %s', [Req]));
  if DoRemoteCall('reverse', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[reverse] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('reverse 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('result') then
      begin
        result := jo.S['result'];
        if result = 'olleh' then
          ConsoleWriteLnColor(Format('reverse("hello")="%s" 正确', [result]), True)
        else
          ConsoleWriteLnColor(Format('reverse("hello")="%s" 期望 "olleh"', [result]), False);
      end
      else
        ConsoleWriteLnColor('reverse 响应缺少 result 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('reverse 调用失败: ' + Err, False);
end;

(*
 * 测试 timestamp API：获取当前时间戳（毫秒或秒）。
 * 发送空对象 {}，期望返回 {"timestamp": 数字}。
 *)
procedure TestTimestamp;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  ts: Int64;
begin
  Req := '{}';
  ConsoleWriteLn('[timestamp] 请求: {}');
  if DoRemoteCall('timestamp', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[timestamp] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('timestamp 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('timestamp') then
      begin
        ts := jo.I64['timestamp'];
        ConsoleWriteLnColor(Format('timestamp 成功，值: %d', [ts]), True);
      end
      else
        ConsoleWriteLnColor('timestamp 响应缺少 timestamp 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('timestamp 调用失败: ' + Err, False);
end;

(*
 * 测试 sleep API：让服务端休眠指定毫秒数。
 * 发送 {"ms":100}，期望返回 {"status":"ok"}。
 *)
procedure TestSleep;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  ms: Integer;
begin
  ms := 100;
  Req := Format('{"ms":%d}', [ms]);
  ConsoleWriteLn(Format('[sleep] 请求: %s', [Req]));
  if DoRemoteCall('sleep', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[sleep] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('sleep 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('status') then
        ConsoleWriteLnColor(Format('sleep(%d) 返回 status="%s"', [ms, jo.S['status']]), True)
      else
        ConsoleWriteLnColor('sleep 响应缺少 status 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('sleep 调用失败: ' + Err, False);
end;

(*
 * 测试 echo API：消息回显。
 * 发送 {"msg":"Hello, LingoFuse!"}，期望返回 {"echo":"Hello, LingoFuse!"}。
 *)
procedure TestEcho;
var
  Req, Resp, Err: string;
  jo: TZ_JsonObject;
  msg, result: string;
begin
  msg := 'Hello, LingoFuse!';
  Req := Format('{"msg":"%s"}', [msg]);
  ConsoleWriteLn(Format('[echo] 请求: %s', [Req]));
  if DoRemoteCall('echo', Req, Resp, Err) then
  begin
    ConsoleWriteLn(Format('[echo] 响应: %s', [Resp]));
    jo := TZ_JsonObject.Create;
    try
      jo.ParseText(Resp);
      if jo.Exists('error') then
        ConsoleWriteLnColor('echo 返回错误: ' + jo.S['error'], False)
      else if jo.Exists('echo') then
      begin
        result := jo.S['echo'];
        if result = msg then
          ConsoleWriteLnColor(Format('echo 正确返回 "%s"', [result]), True)
        else
          ConsoleWriteLnColor(Format('echo 返回 "%s" 期望 "%s"', [result, msg]), False);
      end
      else
        ConsoleWriteLnColor('echo 响应缺少 echo 字段', False);
    finally
      jo.Free;
    end;
  end
  else
    ConsoleWriteLnColor('echo 调用失败: ' + Err, False);
end;

{ ---- 主程序 ---- }

var
  input_: string;
begin
  ConsoleWriteLn('╔══════════════════════════════════════════════════════════════╗');
  ConsoleWriteLn('║       LingoFuse 单 API 功能验证工具 (API Check)  v2.0        ║');
  ConsoleWriteLn('║       顺序测试 BenchServer 的 20 个 API                      ║');
  ConsoleWriteLn('╚══════════════════════════════════════════════════════════════╝');
  ConsoleWriteLn('');
  ConsoleWriteLn(Format('目标服务: %s @ %s', [SERVER_APP, SERVER_ENDPOINT]));
  ConsoleWriteLn('');

  // 重置之前的准备状态，准备连接服务器
  LF.ResetPrepare;
  LF.PrepareClient(SERVER_ENDPOINT, nil);  // 作为纯客户端，不暴露应用

  if not LF.PrepareDone then
  begin
    ConsoleWriteLn('连接服务器失败，请确保 BenchServer 已启动');
    LF.Shutdown;
    Halt(1);
  end;

  ConsoleWriteLn('已连接到 ' + SERVER_ENDPOINT);
  ConsoleWriteLn('');
  ConsoleWriteLn('开始测试...');
  ConsoleWriteLn('');

  // 依次执行所有测试过程，每个测试后输出空行分隔
  TestAdd;      ConsoleWriteLn('');
  TestSub;      ConsoleWriteLn('');
  TestMul;      ConsoleWriteLn('');
  TestDiv;      ConsoleWriteLn('');
  TestEval;     ConsoleWriteLn('');
  TestMD5;      ConsoleWriteLn('');
  TestSHA1;     ConsoleWriteLn('');
  TestSHA256;   ConsoleWriteLn('');
  TestSHA512;   ConsoleWriteLn('');
  TestAESEncrypt; ConsoleWriteLn('');
  TestAESDecrypt; ConsoleWriteLn('');
  TestBase64Encode; ConsoleWriteLn('');
  TestBase64Decode; ConsoleWriteLn('');
  TestRandom;   ConsoleWriteLn('');
  TestUpper;    ConsoleWriteLn('');
  TestLower;    ConsoleWriteLn('');
  TestReverse;  ConsoleWriteLn('');
  TestTimestamp; ConsoleWriteLn('');
  TestSleep;    ConsoleWriteLn('');
  TestEcho;     ConsoleWriteLn('');

  ConsoleWriteLn('所有测试完成！输入 exit 退出...');
  repeat
    ReadLn(input_);
  until umlTrimSpace(input_).Same('exit');

  // 优雅退出网络线程并关闭库
  LF.ExitMainThread;
  LF.Shutdown;
end.
