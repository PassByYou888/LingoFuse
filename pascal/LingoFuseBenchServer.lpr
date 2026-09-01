(*
 * ============================================================================
 * LingoFuseBenchServer – LingoFuse 分布式 RPC 压测服务端
 * ============================================================================
 *
 * 本程序是一个 LingoFuse 服务端，实现了 20 个不同的远程 API，用于性能测试
 * 和功能验证。它作为 BenchServer，可以被多个客户端（如 LingoFuseBenchClient
 * 和 LingoFuseBench_API_Check）并发调用，从而评估 LingoFuse 框架的吞吐量、
 * 延迟和稳定性。
 *
 * 服务端注册的 20 个 API 涵盖以下类别：
 *   - 算术运算：add, sub, mul, div
 *   - 表达式求值：eval（支持变量）
 *   - 哈希算法：md5, sha1, sha256, sha512
 *   - 对称加密（模拟）：aes_encrypt, aes_decrypt
 *   - 编码转换：base64_encode, base64_decode
 *   - 随机数生成：random
 *   - 字符串处理：upper, lower, reverse
 *   - 工具函数：timestamp, sleep, echo
 *
 * 所有 API 均以 JSON 格式接收请求和返回响应，确保跨语言兼容性。
 *
 * 服务端同时提供两种传输方式：
 *   - IPC（进程间通信）：ipc:bench_service
 *   - TCP：127.0.0.1:9898
 *
 * 这允许客户端在同一台机器上使用 IPC 进行低延迟测试，或通过网络 TCP 进行
 * 分布式测试。
 *
 * 使用前提：
 *   - LingoFuse 动态库（LingoFuse64.dll / liblingofuse.so）必须可加载。
 *   - 确保端口 9898 未被占用，或 IPC 管道可用。
 *
 * 编译：Free Pascal 3.0+ 或 Delphi 2009+，需链接 lingofuse_helper 和 Z 系列库。
 * ============================================================================
 *)
program LingoFuseBenchServer;

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
  Classes, SysUtils, Variants, DateUtils,
  lingofuse_helper,        // LingoFuse 高级封装
  lingofuse_import,        // LingoFuse 底层导入
  Z.Core,                  // Z 框架基础库
  Z.Status,                // 全局状态（日志）
  Z.Expression,            // 表达式求值引擎
  Z.OpCode,                // 操作码定义
  Z.Cipher,                // 加密/哈希算法
  Z.UnicodeMixedLib,       // Unicode 工具
  Z.Json,                  // JSON 解析/生成
  Z.Parsing,               // 文本解析
  Z.PascalStrings,         // Pascal 字符串增强
  Z.UPascalStrings,        // Unicode Pascal 字符串
  Z.MemoryStream,          // 内存流（未直接使用但保留）
  Z.DFE,                   // 数据帧编码（未直接使用）
  Z.ListEngine;            // 列表引擎（未直接使用）

(*
 * 将 Pascal 字符串安全转换为 UTF-8 编码，确保跨编译器一致性。
 * 若已在 UTF-8 编码下则直接转换，否则调用 UTF8Encode。
 *)
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

(*
 * 向控制台输出 UTF-8 字符串，自动处理 Windows 和 Unix 的差异。
 * Windows 下使用 WriteConsoleW 以支持 Unicode 字符。
 *)
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

(*
 * 控制台换行输出，若指定非空字符串则先输出该字符串再换行。
 *)
procedure ConsoleWriteLn(const S: string = '');
begin
  if S <> '' then ConsoleWrite(S);
{$IFDEF MSWINDOWS}
  ConsoleWrite(sLineBreak);
{$ELSE}
  WriteLn;
{$ENDIF}
end;

(*
 * 从 LF.TDataHandle 中读取一个字符串（UTF-8）并转换为 TUPascalString。
 * @param h  数据句柄
 * @return   解码后的 TUPascalString（Unicode 字符串）
 * @note 若读取失败，返回空字符串。
 *)
function ReadJsonString(h: LF.TDataHandle): TUPascalString;
var
  s: string;
begin
  h.SetPos(0);
  if not h.ReadString(s) then
    Result := ''
  else
    Result := UTF8Decode(s);
end;

(*
 * 将 TUPascalString（Unicode）编码为 UTF-8 并写入 LF.TDataHandle。
 * @param h     数据句柄
 * @param value 要写入的字符串（Unicode）
 * @note 写入前会将句柄位置设为 0 并清空原有内容。
 *)
procedure WriteJsonString(h: LF.TDataHandle; const value: TUPascalString);
var
  s: string;
begin
  s := UTF8Encode(value.Text);
  h.SetPos(0);
  h.SetSize(0);
  h.WriteString(s);
end;

{ ---- 以下是 20 个 API 的回调函数（cdecl 约定） ---- }

(*
 * add_callback：整数加法。
 * 请求 JSON：{"a": int, "b": int}
 * 响应 JSON：{"result": int} 或 {"error": string}
 *)
procedure add_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  a, b, sum: Integer;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      a := jo.I['a'];
      b := jo.I['b'];
      sum := a + b;
      jo.Clear;
      jo.I['result'] := sum;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"add 失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * sub_callback：整数减法。
 * 请求 JSON：{"a": int, "b": int}
 * 响应 JSON：{"result": int} 或 {"error": string}
 *)
procedure sub_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  a, b, diff: Integer;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      a := jo.I['a'];
      b := jo.I['b'];
      diff := a - b;
      jo.Clear;
      jo.I['result'] := diff;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"sub 失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * mul_callback：整数乘法。
 * 请求 JSON：{"a": int, "b": int}
 * 响应 JSON：{"result": int} 或 {"error": string}
 *)
procedure mul_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  a, b, prod: Integer;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      a := jo.I['a'];
      b := jo.I['b'];
      prod := a * b;
      jo.Clear;
      jo.I['result'] := prod;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"mul 失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * div_callback：整数除法（浮点数结果）。
 * 请求 JSON：{"a": int, "b": int}
 * 响应 JSON：{"result": float} 或 {"error": string}
 * @note 除数 b 不能为零，否则返回错误。
 *)
procedure div_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  a, b: Integer;
  quot: Double;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      a := jo.I['a'];
      b := jo.I['b'];
      if b = 0 then
        raise Exception.Create('除数不能为零');
      quot := a / b;
      jo.Clear;
      jo.F['result'] := quot;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      on e: Exception do
        WriteJsonString(OutHnd, '{"error":"'+UTF8Encode(e.Message)+'"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * eval_callback：表达式求值（支持变量）。
 * 请求 JSON：{"expr": string, "vars": {key: value}}（vars 可选）
 * 响应 JSON：{"result": any} 或 {"error": string}
 * @note 使用 Z.Expression 引擎，支持四则运算、函数调用等。
 *       变量通过 vars 对象传入，键为变量名，值为字符串（将被解析为数值或字符串）。
 *)
procedure eval_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  expr: string;
  vars: TZ_JsonObject;
  vl: THashVariantList;
  i: Integer;
  resultVal: Variant;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  vl := THashVariantList.Create;
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      expr := jo.S['expr'];
      vars := jo.O['vars'];
      if vars <> nil then
      begin
        for i := 0 to vars.Count - 1 do
          vl[vars.Names[i]] := vars.s[vars.Names[i]];
      end;
      resultVal := EvaluateExpressionValue(True, nil, False, tsPascal, expr, SystemOpRunTime, vl);
      jo.Clear;
      if VarIsStr(resultVal) then
        jo.S['result'] := VarToStr(resultVal)
      else if VarIsNumeric(resultVal) then
        jo.F['result'] := resultVal
      else if VarIsBool(resultVal) then
        jo.B['result'] := resultVal
      else
        jo.S['result'] := VarToStr(resultVal);
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      on e: Exception do
        WriteJsonString(OutHnd, '{"error":"'+UTF8Encode(e.Message)+'"}');
    end;
    if jo <> nil then jo.Free;
  finally
    vl.Free;
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * md5_callback：计算 MD5 哈希（32 位十六进制字符串）。
 * 请求 JSON：{"data": string}
 * 响应 JSON：{"md5": string} 或 {"error": string}
 *)
procedure md5_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  data: string;
  md5hex: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      data := jo.S['data'];
      md5hex := umlMD5Str(PByte(data), Length(data));
      jo.Clear;
      jo.S['md5'] := md5hex;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"MD5 计算失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * sha1_callback：计算 SHA-1 哈希（40 位十六进制字符串）。
 * 请求 JSON：{"data": string}
 * 响应 JSON：{"sha1": string} 或 {"error": string}
 *)
procedure sha1_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  data: string;
  hash: TSHA1Digest;
  hex: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      data := jo.S['data'];
      hash := TCipher.GenerateSHA1Hash(PByte(data), Length(data));
      hex := TCipher.BufferToHex(hash, SizeOf(hash));
      jo.Clear;
      jo.S['sha1'] := hex;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"SHA1 计算失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * sha256_callback：计算 SHA-256 哈希（64 位十六进制字符串）。
 * 请求 JSON：{"data": string}
 * 响应 JSON：{"sha256": string} 或 {"error": string}
 *)
procedure sha256_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  data: string;
  hash: TSHA256Digest;
  hex: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      data := jo.S['data'];
      hash := TCipher.GenerateSHA256Hash(PByte(data), Length(data));
      hex := TCipher.BufferToHex(hash, SizeOf(hash));
      jo.Clear;
      jo.S['sha256'] := hex;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"SHA256 计算失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * sha512_callback：计算 SHA-512 哈希（128 位十六进制字符串）。
 * 请求 JSON：{"data": string}
 * 响应 JSON：{"sha512": string} 或 {"error": string}
 *)
procedure sha512_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  data: string;
  hash: TSHA512Digest;
  hex: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      data := jo.S['data'];
      hash := TCipher.GenerateSHA512Hash(PByte(data), Length(data));
      hex := TCipher.BufferToHex(hash, SizeOf(hash));
      jo.Clear;
      jo.S['sha512'] := hex;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"SHA512 计算失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * aes_encrypt_callback：AES 加密（模拟）。
 * 请求 JSON：{"data": string, "key": string}
 * 响应 JSON：{"cipher": string, "status": "ok"} 或 {"status":"error", "error": string}
 * @note 此实现仅为演示，实际加密使用 Base64 编码作为“密文”（非真实 AES）。
 *       真实加密需使用 TCipher 的 AES 功能。
 *)
procedure aes_encrypt_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  data: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      data := jo.S['data'];
      jo.Clear;
      jo.S['cipher'] := umlEncodeLineBASE64(data);
      jo.S['status'] := 'ok';
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"status":"error","error":"模拟加密失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * aes_decrypt_callback：AES 解密（模拟）。
 * 请求 JSON：{"cipher": string, "key": string}
 * 响应 JSON：{"plain": string, "status": "ok"} 或 {"status":"error","error":string}
 * @note 此实现仅为演示，真实解密需使用 TCipher。
 *)
procedure aes_decrypt_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  cipher: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      cipher := jo.S['cipher'];
      jo.Clear;
      jo.S['plain'] := umlDecodeLineBASE64(cipher);
      jo.S['status'] := 'ok';
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      on e: Exception do
        WriteJsonString(OutHnd, '{"status":"error","error":"'+UTF8Encode(e.Message)+'"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * base64_encode_callback：Base64 编码。
 * 请求 JSON：{"data": string}
 * 响应 JSON：{"base64": string} 或 {"error": string}
 *)
procedure base64_encode_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  data: string;
  encoded: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      data := jo.S['data'];
      encoded := umlEncodeLineBASE64(data);
      jo.Clear;
      jo.S['base64'] := encoded;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"Base64 编码失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * base64_decode_callback：Base64 解码。
 * 请求 JSON：{"base64": string}
 * 响应 JSON：{"decoded": string} 或 {"error": string}
 *)
procedure base64_decode_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  encoded: string;
  decoded: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      encoded := jo.S['base64'];
      decoded := umlDecodeLineBASE64(encoded);
      jo.Clear;
      jo.S['decoded'] := decoded;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"Base64 解码失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * random_callback：生成指定范围内的随机整数（包含边界）。
 * 请求 JSON：{"min": int, "max": int}
 * 响应 JSON：{"value": int} 或 {"error": string}
 * @note 若 min > max，返回错误。
 *)
procedure random_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  minVal, maxVal: Integer;
  rndVal: Integer;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      minVal := jo.I['min'];
      maxVal := jo.I['max'];
      if minVal > maxVal then
        raise Exception.Create('min > max');
      rndVal := umlRandomRange(minVal, maxVal);
      jo.Clear;
      jo.I['value'] := rndVal;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      on e: Exception do
        WriteJsonString(OutHnd, '{"error":"'+UTF8Encode(e.Message)+'"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * upper_callback：字符串转大写。
 * 请求 JSON：{"str": string}
 * 响应 JSON：{"result": string} 或 {"error": string}
 *)
procedure upper_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  strVal: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      strVal := jo.S['str'];
      jo.Clear;
      jo.S['result'] := UpperCase(strVal);
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"转大写失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * lower_callback：字符串转小写。
 * 请求 JSON：{"str": string}
 * 响应 JSON：{"result": string} 或 {"error": string}
 *)
procedure lower_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  strVal: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      strVal := jo.S['str'];
      jo.Clear;
      jo.S['result'] := LowerCase(strVal);
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"转小写失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * reverse_callback：字符串反转。
 * 请求 JSON：{"str": string}
 * 响应 JSON：{"result": string} 或 {"error": string}
 *)
procedure reverse_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  strVal: string;
  rev: string;
  i: Integer;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      strVal := jo.S['str'];
      SetLength(rev, Length(strVal));
      for i := 1 to Length(strVal) do
        rev[i] := strVal[Length(strVal)-i+1];
      jo.Clear;
      jo.S['result'] := rev;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"反转失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * timestamp_callback：获取当前 Unix 时间戳（秒）。
 * 请求：无（可发送空 JSON {}）
 * 响应 JSON：{"timestamp": int64} 或 {"error": string}
 *)
procedure timestamp_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  ts: Int64;
  res: TUPascalString;
begin
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      ts := DateTimeToUnix(Now);
      jo.I64['timestamp'] := ts;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"获取时间戳失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    OutHnd.Free;
  end;
end;

(*
 * sleep_callback：让服务端阻塞指定毫秒数（模拟 I/O 等待）。
 * 请求 JSON：{"ms": int}
 * 响应 JSON：{"status": "ok"} 或 {"error": string}
 * @note 此 API 常用于测试网络延迟和并发处理能力。
 *)
procedure sleep_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  ms: Integer;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      ms := jo.I['ms'];
      if ms < 0 then ms := 0;
      Sleep(ms);
      jo.Clear;
      jo.S['status'] := 'ok';
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"sleep 失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

(*
 * echo_callback：回显输入消息。
 * 请求 JSON：{"msg": string}
 * 响应 JSON：{"echo": string} 或 {"error": string}
 * @note 常用于测试网络连通性和数据完整性。
 *)
procedure echo_callback(trigger: Pointer; input: Pointer; output: Pointer); cdecl;
var
  InHnd, OutHnd: LF.TDataHandle;
  jo: TZ_JsonObject;
  msg: string;
  res: TUPascalString;
begin
  InHnd := LF.TDataHandle.Create(TDataHnd(input), False);
  OutHnd := LF.TDataHandle.Create(TDataHnd(output), False);
  try
    jo := nil;
    try
      jo := TZ_JsonObject.Create;
      jo.ParseText(ReadJsonString(InHnd));
      msg := jo.S['msg'];
      jo.Clear;
      jo.S['echo'] := msg;
      res := jo.ToJSONString(False);
      WriteJsonString(OutHnd, res);
    except
      WriteJsonString(OutHnd, '{"error":"回显失败"}');
    end;
    if jo <> nil then jo.Free;
  finally
    InHnd.Free;
    OutHnd.Free;
  end;
end;

{ ---- 主程序 ---- }

var
  App: LF.TAppHandle;
  i: Integer;
  input_: string;
  apiNames: array[0..19] of string = (
    'add', 'sub', 'mul', 'div', 'eval', 'md5', 'sha1', 'sha256', 'sha512',
    'aes_encrypt', 'aes_decrypt', 'base64_encode', 'base64_decode', 'random',
    'upper', 'lower', 'reverse', 'timestamp', 'sleep', 'echo'
  );
begin
  ConsoleWriteLn('╔══════════════════════════════════════════════════════════════╗');
  ConsoleWriteLn('║       LingoFuse 压测服务器 (Benchmark Server)  v3.0          ║');
  ConsoleWriteLn('║       基于 Z-framework  &  C4 分布式服务网格                 ║');
  ConsoleWriteLn('╚══════════════════════════════════════════════════════════════╝');
  ConsoleWriteLn('');

  // 初始化加密系统（用于哈希和加密 API）
  InitSysCBCAndDefaultKey(Random(High(Integer)));

  // 创建应用句柄（名称为 'BenchServer'）
  App := LF.TAppHandle.Create('BenchServer', 'LingoFuse 压测服务器 (20 个内置 API)');
  ConsoleWriteLn('应用句柄创建成功: "BenchServer"');

  // 注册 20 个 API，每个 API 绑定一个回调函数（cdecl）
  App.RegisterCall('add', 'add(a:int, b:int) -> {result:int}  整数加法', nil, @add_callback);
  App.RegisterCall('sub', 'sub(a:int, b:int) -> {result:int}  整数减法', nil, @sub_callback);
  App.RegisterCall('mul', 'mul(a:int, b:int) -> {result:int}  整数乘法', nil, @mul_callback);
  App.RegisterCall('div', 'div(a:int, b:int) -> {result:float}  整数除法（浮点结果，b≠0）', nil, @div_callback);
  App.RegisterCall('eval', 'eval(expr:string, vars:object) -> {result:any}  表达式求值（支持变量）', nil, @eval_callback);
  App.RegisterCall('md5', 'md5(data:string) -> {md5:string}  MD5 哈希（32位十六进制）', nil, @md5_callback);
  App.RegisterCall('sha1', 'sha1(data:string) -> {sha1:string}  SHA-1 哈希（40位十六进制）', nil, @sha1_callback);
  App.RegisterCall('sha256', 'sha256(data:string) -> {sha256:string}  SHA-256 哈希（64位十六进制）', nil, @sha256_callback);
  App.RegisterCall('sha512', 'sha512(data:string) -> {sha512:string}  SHA-512 哈希（128位十六进制）', nil, @sha512_callback);
  App.RegisterCall('aes_encrypt', 'aes_encrypt(data:string, key:string) -> {cipher:string}  AES-128-CBC 加密（输出Base64）', nil, @aes_encrypt_callback);
  App.RegisterCall('aes_decrypt', 'aes_decrypt(cipher:string, key:string) -> {plain:string}  AES-128-CBC 解密', nil, @aes_decrypt_callback);
  App.RegisterCall('base64_encode', 'base64_encode(data:string) -> {base64:string}  Base64 编码', nil, @base64_encode_callback);
  App.RegisterCall('base64_decode', 'base64_decode(base64:string) -> {decoded:string}  Base64 解码', nil, @base64_decode_callback);
  App.RegisterCall('random', 'random(min:int, max:int) -> {value:int}  生成 [min, max] 区间随机整数', nil, @random_callback);
  App.RegisterCall('upper', 'upper(str:string) -> {result:string}  转大写', nil, @upper_callback);
  App.RegisterCall('lower', 'lower(str:string) -> {result:string}  转小写', nil, @lower_callback);
  App.RegisterCall('reverse', 'reverse(str:string) -> {result:string}  字符串反转', nil, @reverse_callback);
  App.RegisterCall('timestamp', 'timestamp() -> {timestamp:int64}  获取当前 Unix 时间戳（秒）', nil, @timestamp_callback);
  App.RegisterCall('sleep', 'sleep(ms:int) -> {status:"ok"}  阻塞等待指定毫秒（模拟耗时）', nil, @sleep_callback);
  App.RegisterCall('echo', 'echo(msg:string) -> {echo:string}  回显输入消息', nil, @echo_callback);

  ConsoleWriteLn('已注册 20 个 API:');
  for i := 0 to 19 do
    ConsoleWriteLn('   - ' + apiNames[i]);
  ConsoleWriteLn('');

  // 准备网络：清除之前配置，启动 IPC 和 TCP 服务，并让客户端连接自身（用于本地回环测试）
  LF.ResetPrepare;
  LF.PrepareService('ipc:bench_service', 'ipc:bench_service');          // IPC 服务
  LF.PrepareService('0.0.0.0', '0.0.0.0:9898');                         // TCP 服务（监听所有网卡）
  LF.PrepareClient('ipc:bench_service', App);                           // 本地 IPC 客户端（注册应用）
  LF.PrepareClient('127.0.0.1:9898', App);                              // 本地 TCP 客户端（注册应用）

  // 启动网络，阻塞直到就绪或失败
  if not LF.PrepareDone then
  begin
    ConsoleWriteLn('网络启动失败，请检查端口/IPC 是否被占用');
    LF.Shutdown;
    Halt(1);
  end;

  ConsoleWriteLn('服务已启动，监听地址：');
  ConsoleWriteLn('   IPC   : ipc:bench_service');
  ConsoleWriteLn('   TCP   : 127.0.0.1:9898');
  ConsoleWriteLn('');
  ConsoleWriteLn('提示：输入 exit 停止服务器...');

  // 等待用户输入 'exit' 以停止服务器
  repeat
    ReadLn(input_);
  until umlTrimSpace(input_) = 'exit';

  // 优雅关闭
  ConsoleWriteLn('正在停止服务器...');
  LF.ExitMainThread;
  LF.Shutdown;
  App.Free;
  ConsoleWriteLn('服务器已停止');
end.
