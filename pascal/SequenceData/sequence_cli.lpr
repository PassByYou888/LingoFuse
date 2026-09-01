program sequence_cli;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
{$endif}

{$APPTYPE CONSOLE}

{$R-}
{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF MSWINDOWS}
  Windows,
{$ENDIF}
  SysUtils,
  Z.Core,
  Z.PascalStrings,
  Z.UPascalStrings,
  Z.UnicodeMixedLib,
  Z.Parsing,
  Z.Expression,
  Z.MemoryStream,
  Z.Status,
  Z.Int128,
  Z.Geometry2D,
  Z.Notify,
  lingofuse_import; // 直接使用底层绑定，不再使用 helper

const
  Debug_Log = False;
  SEQUENCE_SERVER_APP = 'sequence_test';
  SEQUENCE_TIMEOUT_MS = 5000;

{ -----------------------------------------------------------------------------
  1. 开始一个新会话：调用服务端的 BeginData API
  返回一个会话 ID（服务端对象的指针值）
  使用原生 import 函数，手动管理句柄
  ----------------------------------------------------------------------------- }
function SequenceBegin(var SessionID: UInt64): Boolean;
var
  Param, Res: TDataHnd;
begin
  Result := False;
  SessionID := 0;

  Param := LF_CreateDataEx('BeginData'); // 创建请求句柄
  try
    // 同步调用服务端，超时 5000ms，返回结果句柄
    Res := LF_CallEx(SEQUENCE_SERVER_APP, Param, SEQUENCE_TIMEOUT_MS);
    try
      // 结果至少 8 字节（UInt64）
      if LF_GetSize(Res) >= 8 then
        begin
          LF_SetPos(Res, 0);
          Result := LF_ReadUInt64(Res, SessionID);
        end;
    finally
      LF_FreeData(Res); // 释放结果句柄（即使大小为 0 也必须释放）
    end;
  finally
    LF_FreeData(Param); // 释放请求句柄
  end;
end;

{ -----------------------------------------------------------------------------
  2. 发送一个数据块：使用 Notify（单向通知）
  ----------------------------------------------------------------------------- }
procedure SequenceData(SessionID: UInt64; Index: Int64; const Data: Pointer; Size: Int64);
var
  Param: TDataHnd;
begin
  Param := LF_CreateDataEx('Data');
  try
    LF_WriteUInt64(Param, SessionID);
    LF_WriteInt64(Param, Index);
    LF_WriteBuffer(Param, Data, Size);
    LF_NotifyEx(SEQUENCE_SERVER_APP, Param);
  finally
    LF_FreeData(Param);
  end;
end;

{ -----------------------------------------------------------------------------
  3. 结束会话：发送 EndData 通知
  ----------------------------------------------------------------------------- }
procedure SequenceEnd(SessionID: UInt64; TotalCount: Int64);
var
  Param: TDataHnd;
begin
  Param := LF_CreateDataEx('EndData');
  try
    LF_WriteUInt64(Param, SessionID);
    LF_WriteInt64(Param, TotalCount);
    LF_NotifyEx(SEQUENCE_SERVER_APP, Param);
  finally
    LF_FreeData(Param);
  end;
end;

{ -----------------------------------------------------------------------------
  4. 测试函数：生成 10MB 随机数据，分块发送到服务端
  ----------------------------------------------------------------------------- }
function Test_BigData(simulate_bad: Boolean): Boolean;
var
  m64: TMem64;
  siz: Int64;
  SessionID: UInt64;
  i: Int64;
begin
  Result := False;
  m64 := TMem64.Create;
  m64.Size := 1024 * 1024 * 10; // 10 MB
  MT19937Rand32(MaxInt, m64.Memory, m64.Size div 4);

  if not simulate_bad then
      DoStatus('远程会响应,源数据指纹:%s', [umlMD5ToStr(m64.ToMD5).Text]);

  m64.Position := 0;
  siz := 1536;
  i := 0;
  SessionID := 0;

  try
    if not SequenceBegin(SessionID) then
        Exit;

    while m64.Position + siz < m64.Size do
      begin
        SequenceData(SessionID, i, m64.PosAsPtr, siz);
        if Debug_Log then
            DoStatus('发送的缓冲区索引 %d 指纹: %s', [i, umlMD5ToStr(m64.PosAsPtr, siz).Text]);
        m64.Position := m64.Position + siz;
        Inc(i);
      end;

    siz := m64.Size - m64.Position;
    if siz > 0 then
      begin
        SequenceData(SessionID, i, m64.PosAsPtr, siz);
        if Debug_Log then
            DoStatus('发送的缓冲区索引 %d 指纹: %s', [i, umlMD5ToStr(m64.PosAsPtr, siz).Text]);
        m64.Position := m64.Position + siz;
        Inc(i);
      end;

    if not simulate_bad then
        SequenceEnd(SessionID, i);
  finally
      DisposeObject(m64);
  end;

  if simulate_bad then
      DoStatus('脏数据发送完毕,模拟断线等情况丢失的数据,等待远程自动回收.')
  else
      DoStatus('所有非序列化数据已经发送完毕.');
  Result := True;
end;

{ -----------------------------------------------------------------------------
  5. 键盘监听线程
  ----------------------------------------------------------------------------- }
var
  is_Running: Boolean;

procedure Key_Listen();
var
  s: string;
begin
  DoStatus('input exit do exit.');
  repeat
    readln(s);
    s := umlLowerCase(s).TrimChar(#32#9);
  until s = 'exit';
  is_Running := False;
end;

{ -----------------------------------------------------------------------------
  6. 主程序
  ----------------------------------------------------------------------------- }
var
  tk: TTimeTick;
begin
  is_Running := True;
  try
    // 6.1 连接到服务端（纯消费者）
    LF_PrepareClientEx('ipc:demo', nil);

    if LF_PrepareDone() <> 1 then
        Exit;

    // 6.2 启动键盘监听线程
    TCompute.RunC_NP(Key_Listen, @is_Running, nil);

    // 6.3 主循环
    tk := GetTimeTick();
    while is_Running do
      begin
        Z.Core.Check_Soft_Thread_Synchronize(10);
        if GetTimeTick() - tk > 2000 then
          begin
            if not Test_BigData((TMT19937.Rand32 mod 2) = 0) then
                Exit;
            tk := GetTimeTick();
          end;
      end;

  finally
      LF_Shutdown();
  end;
end.
