program sequence_serv;

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
  cthreads, // Free Pascal 下多线程支持
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils, Z.Core, // Z 框架核心（线程池、原子操作、时间等）
  Z.PascalStrings, Z.UPascalStrings, Z.UnicodeMixedLib, Z.Parsing, Z.Expression, Z.MemoryStream, Z.Status, Z.Int128, Z.Geometry2D, Z.Notify, lingofuse_import; 

const
  Debug_Log = False; // 是否打印调试日志

  { -----------------------------------------------------------------------------
    数据类型定义
    ----------------------------------------------------------------------------- }

  // 单个数据块记录：包含索引和内存块
type
  TSequ_Data = record
    index: int64; // 数据块序列号（客户端发送时指定）
    Mem: TMem64; // 实际数据内容
  end;

  // 一个会话（Session）的数据池，用于收集属于同一个会话的所有数据块
  // 继承自 TBigList，用于存储 TSequ_Data 并按索引排序
type
  TSequPool = class(TBigList<TSequ_Data>)
  private
    FMax_recv_Num: uint64; // 期望接收的总块数（由 EndData 设置）
    FLast_Update: TTimeTick; // 最后一次收到 Data 或 EndData 的时间（毫秒）
    FU64_Inst: uint64;
  public
    constructor Create;
    destructor Destroy; override;
    procedure DoFree(var Data: TSequ_Data); override;
    function DoSortSequ(var L, R: TSequ_Data): integer;
    procedure Sequence_End; // 处理完整序列（后台线程执行）
  end;

  // 安全指针映射表：将 UInt64（客户端传递的指针值）映射到 TSequPool 对象
  // 用于防止客户端伪造指针导致的野指针访问
type
  TSequPool_Safe_Pointer = class(TBig_Hash_Pair_Pool<uint64, TSequPool>)
  end;

var
  Safe_Pointer: TSequPool_Safe_Pointer; // 全局安全指针池

  { -----------------------------------------------------------------------------
    TSequPool 实现
    ----------------------------------------------------------------------------- }

constructor TSequPool.Create;
begin
  inherited Create;
  FMax_recv_Num := 0;
  FLast_Update := GetTimeTick(); // 初始时间戳
  FU64_Inst := 0;
end;

destructor TSequPool.Destroy;
begin
  inherited Destroy;
end;

// 当从列表中移除数据时，释放 TMem64 对象
procedure TSequPool.DoFree(var Data: TSequ_Data);
begin
  DisposeObjectAndNil(Data.Mem);
  inherited;
end;

// 排序比较函数：按索引升序
function TSequPool.DoSortSequ(var L, R: TSequ_Data): integer;
begin
  Result := CompareInteger(L.index, R.index);
end;

// 【核心处理】当 EndData 触发后，此方法在后台线程执行
// 它等待所有数据块到达，排序，然后计算最终 MD5
procedure TSequPool.Sequence_End;
var
  all_done: boolean;
  m5tool: TMD5_Tool;
  tk: TTimeTick;
begin
  // 1. 忙等待直到接收到的块数达到预期总数
  FLast_Update := GetTimeTick();
  repeat
    Lock;
    all_done := num >= FMax_recv_Num; // num 来自 TBigList.Count
    UnLock;
    if not all_done then
      TCompute.Sleep(10); // 不占满 CPU
  until (all_done) or (GetTimeTick() - tk > 2000);

  if not all_done then
  begin
    DoStatus('出现了丢数据的情况');
  end;

  Safe_Pointer.Lock;
  Safe_Pointer.Delete(FU64_Inst); // 从安全池中移除该键，之后不再接受此会话的新数据
  Safe_Pointer.UnLock;

  // 2. 对数据块按索引排序（确保顺序正确）
  Sort_M(DoSortSequ);

  // 3. 将所有数据块依次拼接到 MD5 计算器中，得到最终指纹
  m5tool := TMD5_Tool.Create;
  if num > 0 then
    with repeat_ do
      repeat
        if Debug_Log then
          DoStatus('处理序列 %d', [queue^.Data.index]);
        m5tool.Update(queue^.Data.Mem.Memory, queue^.Data.Mem.Size);
      until not Next;

  DoStatus('最终数据指纹 %s', [umlMD5ToStr(m5tool.FinalizeMD5).Text]);

  // 4. 延迟 5 秒后释放当前池对象，给客户端留出缓冲时间
  DelayFreeObj(5.0, Self);
end;

{ -----------------------------------------------------------------------------
  野指针回收机制
  ----------------------------------------------------------------------------- }

// 定时检查：如果某个会话超过 5 秒未收到任何数据，则判定为“事故”并回收资源
procedure Fixed_Lose_SequPool;
var
  removed_num: nativeint;
begin
  Safe_Pointer.Lock;
  try
    if Safe_Pointer.num > 0 then
    begin
      removed_num := 0;
      with Safe_Pointer.repeat_ do
        repeat
          // 如果最后更新时间距今超过 5 秒，则认为会话已中断
          if GetTimeTick() - queue^.Data.Data.Second.FLast_Update > 5000 then
          begin
            DoStatus('由于长时间未操作,系统判定事故,并且回收数据');
            DisposeObjectAndNil(queue^.Data.Data.Second); // 销毁 TSequPool 对象
            Safe_Pointer.Push_To_Recycle_Pool2(queue); // 从哈希表中移除
            Inc(removed_num);
          end;
        until not Next;

      if removed_num > 0 then
        Safe_Pointer.Free_Recycle_Pool; // 真正释放回收的节点
    end;
  finally
    Safe_Pointer.UnLock;
  end;
end;

{ -----------------------------------------------------------------------------
  回调函数（cdecl，运行在 C4 线程池中）
  注意：回调中禁止调用 API_Call 或 API_Notify，否则可能死锁。
  ----------------------------------------------------------------------------- }

// 1. BeginData：客户端请求开始一个新会话，返回一个会话 ID（即新 TSequPool 对象的指针）
procedure BeginData_Notify(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
var
  p: Pointer;
  u64: uint64;
begin
  p := Pointer(TSequPool.Create); // 创建新的会话池
  u64 := uint64(p); // 将指针值作为会话 ID
  Safe_Pointer.Lock;
  Safe_Pointer.Add(u64, TSequPool(p), False); // 存入安全指针池，键为指针值
  Safe_Pointer.UnLock;
  LF_WriteUInt64(Output, u64); // 返回 ID 给客户端
end;

// 2. Data：接收一个数据块（包含会话 ID、索引、数据）
procedure Data_Notify(Trigger: Pointer; Input: TDataHnd); cdecl;
var
  u64: uint64;
  p: Pointer;
  dataQueue: TSequPool;
begin
  // 安全检查：数据长度至少 16 字节（ID + 索引）
  if LF_GetSize(Input) < 16 then
    Exit;
  LF_SetPos(Input, 0);
  LF_ReadUInt64(Input, u64);
  if u64 = 0 then
    Exit;
  p := Pointer(u64);

  Safe_Pointer.Lock;
  try
    // 【野指针防护】检查该 ID 是否存在于安全池中，防止客户端伪造地址
    if not Safe_Pointer.Exists_Key(u64) then
    begin
      DoStatus('Data_Notify 野指针.');
      Exit;
    end;
  finally
    Safe_Pointer.UnLock;
  end;

  dataQueue := p;
  dataQueue.Lock;
  try
    dataQueue.FLast_Update := GetTimeTick(); // 更新活跃时间
    // 在池中新增一条记录
    with dataQueue.Add_Null^ do
    begin
      Data.index := LF_ReadInt64(Input); // 读取索引
      Data.Mem := TMem64.Create;
      // 从偏移 16 处开始读取数据（前 16 字节是 ID + 索引）
      Data.Mem.WritePtr(LF_GetBufferOffset(Input, 16), LF_GetSize(Input) - 16);
      if Debug_Log then
        DoStatus('接收到的缓冲区索引 %d 指纹: %s', [Data.index, umlMD5ToStr(Data.Mem.ToMD5).Text]);
    end;
  finally
    dataQueue.UnLock;
  end;
end;

// 3. EndData：结束会话，指定总块数，触发后台处理
procedure EndData_Notify(Trigger: Pointer; Input: TDataHnd); cdecl;
var
  u64: uint64;
  p: Pointer;
  dataQueue: TSequPool;
begin
  if LF_GetSize(Input) < 16 then
    Exit;
  LF_SetPos(Input, 0);
  LF_ReadUInt64(Input, u64);
  if u64 = 0 then
    Exit;
  p := Pointer(u64);
  Safe_Pointer.Lock;
  try
    // 再次检查指针有效性
    if not Safe_Pointer.Exists_Key(u64) then
    begin
      DoStatus('EndData_Notify 野指针.');
      Exit;
    end;

    dataQueue := p;
    dataQueue.FLast_Update := GetTimeTick(); // 更新活跃时间
    // 读取总块数
    LF_ReadUInt64(Input, dataQueue.FMax_recv_Num);
    dataQueue.FU64_Inst := u64;
    if dataQueue.FMax_recv_Num = 0 then
      Exit;
  finally
    Safe_Pointer.UnLock;
  end;
  // 【关键】在后台线程中处理排序和 MD5 计算，避免阻塞回调线程
  TCompute.RunM_NP(dataQueue.Sequence_End);
end;

{ -----------------------------------------------------------------------------
  主程序
  ----------------------------------------------------------------------------- }

var
  is_Running: boolean;

procedure Key_Listen();
var
  s: string;
begin
  DoStatus('input exit do exit.');
  repeat
    readln(s);
    s := umlLowerCase(s).TrimChar(#32#9);
  until s = 'exit';
end;

var
  app: TAppHnd;
  tk: TTimeTick;

begin
  // 初始化安全指针池（哈希表大小 255，空值默认 nil）
  Safe_Pointer := TSequPool_Safe_Pointer.Create($FF, nil);

  // 创建app
  app := LF_CreateAppEx('sequence_test', '序列算法');

  // 注册三个 API
  LF_RegisterCallEx(app, 'BeginData', '序列数据', nil, BeginData_Notify);
  LF_RegisterNotifyEx(app, 'Data', '序列数据', nil, Data_Notify);
  LF_RegisterNotifyEx(app, 'EndData', '序列完结', nil, EndData_Notify);

  // 准备网络：使用 IPC 通道（同机通信）
  LF_PrepareServiceEx('ipc:demo', 'ipc:demo');
  LF_PrepareClientEx('ipc:demo', app);

  if LF_PrepareDone() <> 1 then
    Exit;

  // 启动键盘监听线程（便于手动退出）
  TCompute.RunC_NP(Key_Listen, @is_Running, nil);

  // 主循环：每 1 秒检查一次超时会话并回收
  tk := GetTimeTick();
  while is_Running do
  begin
    Z.Core.Check_Soft_Thread_Synchronize(10); // 处理线程同步
    if GetTimeTick() - tk > 1000 then
    begin
      Fixed_Lose_SequPool; // 扫描并清理野指针/超时会话
      tk := GetTimeTick();
    end;
  end;

  // 清理资源
  LF_ExitMainThread();
  LF_FreeApp(app);
  LF_Shutdown();
  DisposeObject(Safe_Pointer);

end.
