# 文档矫正日志（.md 全量审计）

> 范围：`Z:\temp3` 下全部 `.md`（188 个文件，其中中文原文 101 个、`_en.md` 87 个）。
> 顺序：先中文版，再英文版。
> 修订前原件备份：工作区 `backup\`（保持相对路径），可逐文件回滚。

## 审计方法

1. **自动化结构审计**：解析全部 `.md` 的相对链接与 `#锚点`，逐条核对目标文件是否存在、锚点 slug 是否与目标标题一致（跳过代码块内的伪链接）。共检查 623 条链接。
2. **接口名比对**：从 `src\Z.LingoFuse_Export.pas`、各语言头文件与绑定源码中提取全部 `LF_*` 标识符（代码内 502 个），与文档中出现的 `LF_*` 做差集，筛出"文档里有、源码里没有"的名字，逐条人工核对。
3. **计数一致性**：对可枚举的断言（踩坑 ID 条数、导出符号数、语言数、章节数）用脚本实测，与正文声明比对。
4. **跨文档一致性**：同一机制在 Pascal 指南、多语言指南、Z.LingoFuse.md 中的表述互校。

## 已修正项（中文版）

| # | 文件 | 问题 | 修正 | 依据 |
|---|------|------|------|------|
| 1 | `LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md` | 目录与基线表 5 处锚点 `#4-c-1` 指向不存在的标题 | 改为 `#4-c`（对应 `## 4. C#`） | 标题实际 slug |
| 2 | 同上 | 2 处锚点 `#19-browser-javascript` 指向不存在的标题 | 改为 `#19-浏览器-javascript`（对应 `## 19. 浏览器 JavaScript`） | 标题实际 slug |
| 3 | `ruby\README.md` | 目录 4 条 9.8–9.11 锚点多写一段 `-v20-`，跳转失效 | 改为 `#98-lingofuseaddressv20-新增` 等实际 slug | 标题 `### 9.8 \`LingoFuse::Address\`（v2.0 新增）` |
| 4 | `LingoFuse_MultiLanguage_Complete_Guide.md`（§18.6）、`LingoFuse_P2P_Distributed_Load_Concept.md`（§7.1）、`pascal\LingoFuse_Pascal_Complete_Guide.md`（§18.6） | 序列化族清单列出 `LF_Sequenced_Call`，**该函数不存在** | 删除该项（保留 `LF_Sequenced_Notify`、`LF_Async_Sequenced_Call`） | **Sequenced Call 只有异步形态**：导出符号中仅有 `LF_Async_Sequenced_Call` / `LF_UID_Async_Sequenced_Call` / `LF_P2PNAME_Async_Sequenced_Call`；同步侧只有 `LF_Sequenced_Notify` 一族 |
| 5 | `LingoFuse_MultiLanguage_Complete_Guide.md`（附录 E.3） | Pascal 行"异步 Notify"写成 `LF_Async_Notify`，**该函数不存在** | 改为 `—（无）` | 导出符号里通知族只有 `LF_Notify` / `LF_UID_Notify` / `LF_P2PNAME_Notify`，均为单向即时发送，无异步版本 |
| 6 | `LingoFuse_MultiLanguage_Complete_Guide.md`（§12 图）、`pascal\LingoFuse_Pascal_Complete_Guide.md`（§12 图） | Mermaid 回调名写成 `Do_LF_Network_Connect_Th___` | 改为 `Do_LF_Network_Connect_Worker` | `Z.Net.C4.LingoFuse.pas` 实际过程名，且 `TCompute.RunC(..., Do_LF_Network_Connect_Worker)` |
| 7 | `cpp\LingoFuse_Cpp_Knowledge_Base.md`（§1.8 同步/异步孪生表） | `LF_UID_Sequenced_Call`、`LF_P2PNAME_Sequenced_Call` 两个同步名不存在 | 同步列改为 `—`，并在表后补一段说明：Sequenced Call 只有异步形态，同步侧只有单向有序通知 | 头文件与导出符号 |
| 8 | `pascal\LingoFuse_Pascal_Complete_Guide.md` | 全篇声称踩坑 ID 共 **95** 条、v6.0 为 92 条 | 改为 **97** 条、v6.0 为 **94** 条（正文 2 处 + 附录 B 合计行） | 实测：19 个前缀分组计数 7+5+8+7+2+3+1+3+3+2+2+3+3+4+5+18+12+8+1 = 97，与附录 B 各行数字完全一致，仅合计数与 v6.0 基数算错 |
| 9 | `LingoFuse_MultiLanguage_Complete_Guide.md`（附录 B.1） | 表内漏 `LF-JSON` 行；`LF-R` 写 5（实际 6）；合计写 194 | 补 `LF-JSON \| 3` 行、`LF-R` 改 6、合计改 **192**，附注改"v7.0 为 97；v2.0 新增 95 条" | 实测全篇唯一 ID 数 192；按前缀分组与表行逐一核对 |
| 10 | 同上（文档版本节） | "194 条 ID……通用机制（150 条）与语言专属（44 条）"、"ID 总览（194 条）" | 改为 "192 条 ID……通用机制（99 条）与语言专属（93 条）"、"ID 总览（192 条）" | 通用前缀实测 99 条、语言专属前缀实测 93 条 |
| 11 | `readme.md`（4 处）、`LingoFuse_Private_Fork_Playbook.md`（1 处） | 引用"194 条踩坑 ID" | 改为"192 条踩坑 ID" | 同步第 9–10 项修正 |
| 12 | `doc\LF_WaitOnResult.md` | 把发送队列的放行条件写成"第一行就是检查 `FWaitOnResult`，True 就 exit"，读者会误以为清掉这一个标志就能恢复发送 | 补充为**与 `FAllSendProcessing` / `FReceiveProcessing` / `FBigStreamSending` 等 7 个标志做或运算**，任一为真即 exit | `sec.Net.imp_IO.inc` 的 `TPeerIO.Internal_Process_Send_Buffer` 开头正是这组复合条件 |

| 13 | `doc\LF_ThreadPool_Pick.md` | 把 `Do_Pick` 的放行条件画成"空闲 worker > 0 **或** Task_Runing > 上限"，读者会以为上限判断默认生效 | 图示改为"空闲 worker > 0？"并标注"上限分支默认未编译"，另加一段编译期说明 | `Z.Core.ComputeThread.inc` 中该分支被 `{$IFDEF LimitMaxComputeThread}` 包住，而 `Z.Define.inc` 里是 `{$UNDEF LimitMaxComputeThread}` → 默认构建不存在这道判断 |
| 14 | 14 个文件 26 处（`LingoFuse_MultiLanguage_Complete_Guide.md`、`pascal\LingoFuse_Pascal_Complete_Guide.md`、`Z.LingoFuse.md`、`doc\LF_Debug_Mode.md`、`readme.md`、`csharp`、`dart`、`js`、`ts`、`r`、`ruby`、`rust` README、`cpp` KB） | `Quiet` 默认写成 `False`、`ShowThreadID` 默认写成 `True`，**两个方向都反了** | 全部改为 `Quiet=True`、`ShowThreadID=False`，并在三篇文档的选项表后补一段"为什么默认值是这样"的源码依据说明 | `Z.LingoFuse_Export.pas` initialization（库加载即生效）：`:2164 C40SetQuietMode(True)`、`:2162 Z.status.StatusThreadID := False`、`ConsoleOutput := True`；`Z.Status.pas:1242` 内部初值虽为 `True`，但被导出层覆盖；确认 18 个语言绑定均无加载期反向设置（仅测试代码显式 set） |
| 15 | `doc\LF_Cmd_Model_Choice.md` | 把超时说成"`FWaitOnResult` 不会自动复位，一次超时整条连接就废"；双隧道只写了一个属性名 | 补全：超时分支只退出、不碰标志；复位点只有"响应回来"（`FillWaitOnResultBuffer` 末 `FWaitOnResult := False`，`Z.Net.imp_IO.inc:1664`）和 IO 重建（`TPeerIO.Create`），故分"对端最终会回"与"对端不回"两种情况；双隧道写法改为 `TDTClient_NoAuth` / `TDTClient_VirtualAuth`（`DoubleChannelFramework` 只是框架属性名） | `Z.Net.C4.LingoFuse.pas:3566-3579` 超时分支、`Z.Net.imp_IO.inc:1664/2332`、`Z.Net.imp_API.inc:594-598` |
| 16 | `doc\LF_Route_Choice.md` | `local_call` 只写"不注入身份、不路由"；P2PName 表把"粘性 20 秒"当成本调用族的属性 | `local_call` 补充语义：吃**已绑定的 App 句柄**、直接在当前线程执行、无 `Rebuild_UID_and_P2PName`、不会回退网络；粘性改为"仅 Sequenced 变体"并说明 `P2PNAME_Call` 每次走 `Find_P2PName_LoadBalance`、只有 `P2PNAME_Async_Sequenced_Call` 走 `Find_P2PName_FixedSequenced`（`Fixed_Sequenced_Time` 默认 20000 ms） | `Z.LingoFuse_Export.pas:483-507`；`Z.Net.C4.LingoFuse.pas:2406/2458/2510/2565` |
| 17 | `doc\LF_Sequenced_FIFO.md` | 表里"`sequenced_notify` 与 `sequenced_call` 混着调"写成 ✅ FIFO，与正文"两个 Pool 各一线程、彼此无顺序"自相矛盾 | 该行改 ❌；并补一段：UID/P2PName 变体的顺序线程**在目标客户端**（`cmd_UID_Sequenced_Call` → `Post_Call2(target_app, ...)`），Key 仍是 `App.Name.apiName`，因此 p2p 负载均衡分到不同客户端就没有全局顺序 | `Z.LingoFuse_Core.pas:1174`（`Post_Call2` 拼 Key）、`Z.Net.C4.LingoFuse.pas:3308/3402` |
| 18 | `doc\LF_Concurrent_Send.md` | 线程安全矩阵两行写错：`shutdown` 标"必须在主线程调"、设置选项标"内部投递到主线程" | 改为"任意线程可调，但禁止在回调里调（会死锁）"与"有模拟主线程时投递、否则就地执行"，并加依据段 | `cpp\LingoFuse.h:198-223`（所有导出函数线程安全、回调内禁调 5 个 API）；`Z.LingoFuse_Export.pas:1968-1976`（`Simulator_Main_Thread_Activted` 分支） |
| 19 | `doc\LF_Error_In_Callback.md` | 只说"异常被吞、Output 保持空" | 补源码细节：进回调前备份 `input_^`/`output_^`，异常分支**恢复备份**，所以写了一半的 Output 会被整段丢弃 | `Z.LingoFuse_Core.pas:886-902` |
| 20 | `doc\LF_Handle_Ownership.md` | "释放走池化回收"笼统 | 分清两条路径：同步句柄 `auto_recycle=True` 的 `Free_Data` 只置 `deleted___`，由主线程扫描器真回收；异步 `auto_recycle=False` 走 `Free_Data___`，在 `OnResult_` 返回后一行立即 dispose | `Z.LingoFuse_Core.pas:677-686`；`Z.Net.C4.LingoFuse.pas:4417-4421` |
| 21 | `doc\LF_Simulated_Main_Thread.md` | 说"只做两件事"，漏掉初始化阶段 | 补：稳态循环前先 `C40Progress(10)` 轮询各 client `Connected`/`LF_AppIsOnline`，直到全部在线或超 `Wait_Connection_Timeout`；`LF_PrepareDone` 的阻塞等待就是它在做，失败则 `Init_Succeeded=False` 直接清理 | `Z.LingoFuse_Export.pas:963-1001,1020-1050` |
| 22 | `doc\LF_P2P_Identity.md` | **本条为误判，见第 29 项的返工**：原文引用的警告措辞与源码不符（`P2P info is only available on the callback "input" parameter.`），当时据此判定"整条警告是编造的" | 结论修正为"警告真实存在，措辞需校正"，最终处理见第 29 项 | `Z.LingoFuse_Core.pas:769-790`（`DoStatus('[warning] Get_P2P_UID(): P2P Info only backcall "input" parameter.')`） |
| 23 | `doc\LF_SwapUnderLock.md` | 过程名大小写与源码不符（`moveAllTo` / `swapInstance` / `queueTool` / `syncQueue`） | 统一为 `MoveAllTo` / `SwapInstance` / `Queue_Tool` / `SyncQueue__` | `lingofuse_import.pas:511,591`；`sec.Core.OrderData.inc:31`；`Z.LingoFuse_Core.pas` 的 `Queue_Tool` |
| 24 | `doc\LF_TBigList_Iterator.md` | 正文结论（"`Next` 先移动再判断、`while(Next())` 漏首节点"）正确，但 C++/Python 示例把 `current` 初始化成 `nullptr`、首次 `Next` 才落到 `first`——恰好把语义演示反了 | 示例改为构造即 `current = first`；`Next()` 一次性完成"先移动 → 再结算上一轮 `Discard`（删刚处理完的那个）→ 最后判断结束"；Python 增加 `valid` 属性并修正两处 `if it.next()` 起手写法 | `Z.Core.BigList.inc:45-63`（`p := p^.Next` → `Result := I < EI` → `if Is_Discard then Remove_P(p^.Prev)`） |
| 25 | `doc\LF_Reconnect_Strategy.md` | "连接状态 LinkOk 布尔标志"（公开 API 里没有这个）；"call 超时默认 30 秒" | 改为公开查询 `LF_CheckApp` / `LF_Check_UID` 返回 1/0（内部依据 `LinkOk`/`Connected`）；超时改为"由调用方传入，`0` 表示无限等"，并标注源码依据 | `Z.LingoFuse_Export.pas:1797-1810`；`Z.Net.C4.LingoFuse.pas:3569`（`TimeOut__ > 0` 才判超时） |
| 26 | `doc\LF_Network_Join.md` | "默认 password 材料有矛盾，待核实"；"password 错误时 prepareDone 行为未知" | 核实默认值 `'DTC40@ZSERVER'`；核实 password 不匹配时 `prepareDone` 表现是"等满 `Wait_Connection_Timeout` 后返回 0"，并把这两条从"不确定清单"移出 | `sec.Net.C4.pas:7347`；`Z.LingoFuse_Export.pas:963-1045` |
| 27 | `Z.LingoFuse.md`（2 处：§2.9.2 表、§2.9 命令表）、`Py\readme.md`（§3.5.2 表）、`LingoFuse_P2P_Distributed_Load_Concept.md`（§2.2 表） | 四处都把"`LF_LocalCall` / `LF_LocalNotify` 回调的 `Input`"标成"✅ 也经过 `Rebuild_UID_and_P2PName` 注入"，与多语言指南/Pascal 指南的 `LF-LOCAL-001` 结论直接冲突 | 四处统一改为 ❌：`LF_LocalCall` 走 `EncryptToMem` → `Execute_Call`，不注入；`FromUID` 为 `Null_UID()`，且因 `Data_Param` 非 nil **静默返回、不报警告**；另注明"若传入的是网络收到的句柄，身份随载荷原样保留" | `Z.LingoFuse_Export.pas:483-507`；`Z.LingoFuse_Core.pas:300-307`（`EncryptToMem` 序列化 `FromUID`）；对照 `LingoFuse_MultiLanguage_Complete_Guide.md` §5.6 |
| 28 | `Z.LingoFuse.md:467` | Notify 回调异常日志写成 `'execute notify-mode api "%s" execpet!'`，少了 `(stdcall)` | 补全为 `'execute notify-mode api "%s" (stdcall) execpet!'` | `Z.LingoFuse_Core.pas:974` |
| 29 | `doc\LF_P2P_Identity.md`（本轮返工） | 上一轮误判"警告是编造的"并删掉了警告说明——实际 `TLF_Data.Get_P2P_UID` 里确有 `DoStatus`（此前 grep 被 `-First 10` 截断而漏检）；但原文引用的措辞也不是真实字符串 | 恢复"会打警告"，把引文校正为真实文本 `[warning] Get_P2P_UID(): P2P Info only backcall "input" parameter.`；同时把行为拆成两类：无 `Data_Param` 的句柄（`Result_` / 空句柄）→ 警告 + `Null_UID()`；有 `Data_Param` 但没注入的（自建句柄、`local_call` 的 Input）→ 静默全零。陷阱表相应行恢复 | `Z.LingoFuse_Core.pas:769-790`（`Get_P2P_UID` / `Get_P2P_Name` 两条 `DoStatus`） |
| 30 | 全部中文文档（选项名一致性审计） | —（未发现错误，记录为已核结论） | 从 `TSetOpt_Inst.DoRun` 提取**全部 16 组键 / 49 个别名**（`Quiet`、`ConsoleOutput`、`ShowThreadID`、`Overlap_*`、`Wait_Connection_*`、`IPC_Serv_*`、`Fixed_Sequenced_Time`、`DataHandle_*`、`No_Reponse_Cmd_NULL_Flush_Threshold`、`LF_P2P_name`、`password`、`debug`），与全部中文文档的选项表逐项比对：文档里出现的选项名**全部能被识别**；Ruby 的 `set_opt_wait_connection_ready_ok` 等 snake_case 方法内部 `_set_bool('Wait_Connection_ReadyOk', ...)` 映射到规范键，不构成错误 | `Z.LingoFuse_Export.pas:1847-1957`；`ruby\lib\lingofuse\options.rb:216-297` |

## 复核结论（未改动，但已核实）

- **"59 个导出符号"是正确的**：`Z.LingoFuse_Export.pas` 中 61 个 `LF_*` 定义里，`LF_Debug_Log` / `LF_Debug_Log_Enabled` 属调试钩子，不在 59 个对外符号内；其余文档出现该数字处均无误。
- **"17 篇技术短文"是对的**：`doc/` 下 18 篇 = 17 篇机制短文 + 1 篇入网文档（`LF_Network_Join.md`），与 readme 第 638 行的口径一致。
- **"顺序线程退出后延迟释放 1 秒"三处一致**（Pascal 指南、多语言指南、Z.LingoFuse.md 均为 1 秒，且均注明 v6.0/v3.2 的"5 秒"为误写）。
- **中文版共 623 条相对链接，无失效文件链接，无失效锚点**（本轮修复后复测）。
- **核心函数签名与源码一致**：随机核对 `LF_CreateApp` / `LF_RegisterCall` / `LF_PrepareClient` / `LF_Call` / `LF_Async_Call` 等在多语言指南、Pascal 指南、`Z.LingoFuse.md` 中的写法，与 `Z.LingoFuse_Export.pas` 声明逐参数吻合（含 `Desc`、`Trigger`、`Timeout_`、`Data`/`OnResult`）。
- **选项默认值与源码一致**：数据句柄扫描 5 秒、空闲回收 10 分钟（`LF_DataHandle_Pool_Scan_Interval = 5s`、`LF_DataHandle_Idle_Timeout = 600s`）与文档一致。
- **章节交叉引用无悬空**：三篇大文档共 555 个 `§x.y` 引用，全部能在同文档内找到对应编号标题（Pascal 指南 0 处悬空、多语言指南 0 处、`Z.LingoFuse.md` 0 处）。
- **`doc/LF_WaitOnResult.md` 引用的机制名全部真实存在**：`FWaitOnResult`、`Process_Send_Buffer`、`CompleteBuffer_NoWait_Stream`、`Check_Param_And_Send_Queue`、`SendNULL`。
- **`doc/LF_TCritical_Reuse.md` 与源码一致**：`TCritical` 为 `sealed` 类、`Create` 先查 `System_Critical_Recycle_Pool__` 未命中才 `TSystem_Critical.Create` 并 `Inc(System_Critical_Num__)`、`Destroy` 执行 `while LNum > 0 do Release` 后把实例 Push 回池、`LNum` 为递归计数、两个统计函数语义与文中一致。
- **`doc/LF_ZeroCopy_Decode.md` 与源码一致**：`DecryptFromMem` 的 `ProtectedMode=True` 分支走 `ReadPtr`（真拷贝），否则 `tmp.SwapInstance(m64)` 后 `Param.Mapping(tmp.PosAsPtr, i32)`；析构顺序确为 `DisposeObject(Param)` 先、`DisposeObject(tmp)` 后。

## 待办

- [x] `doc/` 18 篇机制短文：逐篇与源码比对完毕（`LF_WaitOnResult`、`LF_ThreadPool_Pick`、`LF_TCritical_Reuse`、`LF_ZeroCopy_Decode`、`LF_Debug_Mode`、`LF_Cmd_Model_Choice`、`LF_Route_Choice`、`LF_Sequenced_FIFO`、`LF_Concurrent_Send`、`LF_Error_In_Callback`、`LF_Handle_Ownership`、`LF_Simulated_Main_Thread`、`LF_P2P_Identity`、`LF_SwapUnderLock`、`LF_TBigList_Iterator`、`LF_Reconnect_Strategy`、`LF_Network_Join`，另 `LF_DataHandle_Lifetime` 等已在第一阶段覆盖）。
- [ ] 中文版剩余：`Z.LingoFuse.md`(3276 行)、`LingoFuse_MultiLanguage_Complete_Guide.md`(6675 行)、`pascal` 指南(3596 行) 的逐章机制叙述；18 个语言 README 的 API 表逐行与头文件签名对照（目前只做了选项默认值与锚点两类）。
- [ ] 英文版阶段：修复英文 TOC 锚点（`pascal` 指南 21 处双连字符、多语言指南 7 处标题与目录不一致、`java` 2 处、`dart\example` 2 处、部署指南 3 处）、`readme_en.md` 与 `src\CONTRIBUTING_en.md` 指向不存在的 `FPC_3.3.1_Package_Info_en.md`、并把中文侧第 4–26 项修正同步到英文版。
