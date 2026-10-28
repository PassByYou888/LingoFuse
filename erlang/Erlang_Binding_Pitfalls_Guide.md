# Erlang 绑定踩坑全记录

> 文件名：`Erlang_Binding_Pitfalls_Guide.md`
> 定位：面向后续 Erlang 绑定维护者/AI 的实战踩坑档案。每条坑都附症状、证据、根因、修复、教训。
> 来源：本次 `Z.LingoFuse` Erlang 绑定从"零通过"到"120/120 PASS"完整过程。

---

## 目录

- [第 0 章 一句话速记](#第-0-章-一句话速记)
- [第 1 章 ABI wire 格式坑（最关键，最容易被幻觉带偏）](#第-1-章-abi-wire-格式坑最关键最容易被幻觉带偏)
- [第 2 章 NIF 层坑](#第-2-章-nif-层坑)
- [第 3 章 构建链坑（Windows + rebar3 专属）](#第-3-章-构建链坑windows--rebar3-专属)
- [第 4 章 生成器层坑](#第-4-章-生成器层坑)
- [第 5 章 测试层坑](#第-5-章-测试层坑)
- [第 6 章 核心库坑（非 Erlang 责任，但会被牵连）](#第-6-章-核心库坑非-erlang-责任但会被牵连)
- [第 7 章 最终根因：`lf_p2p_call` / `lf_p2p_notify` atom 未处理](#第-7-章-最终根因lf_p2p_call--lf_p2p_notify-atom-未处理)
- [第 8 章 诊断方法论（本次实战验证有效的顺序）](#第-8-章-诊断方法论本次实战验证有效的顺序)
- [第 9 章 反幻觉清单（AI 最容易写错的地方）](#第-9-章-反幻觉清单ai-最容易写错的地方)
- [第 10 章 速查表](#第-10-章-速查表)
- [附录 A 环境信息快照](#附录-a-环境信息快照)
- [附录 B 本次修复的文件清单](#附录-b-本次修复的文件清单)

---

## 第 0 章 一句话速记

**记住这 7 条，可以避免 90% 的返工：**

1. **ABI 层必须二进制 wire**（`[status 0x00/0xFF][payload]`），**禁止 JSON**。
2. **NIF 层不 strip `#0`**，字符串 `#0` 处理由消费方（`read_string` / `lingofuse_json:loads`）负责。
3. **回调注册用 `register_call_sync` 时，NIF 会发 `{lf_call, Ref, Api, Payload, Identity}`**；P2P 注册时发 **`{lf_p2p_call, ...}`**。**Service main loop 必须两套都处理**。
4. **`lingofuse:reply/2` 只能调用一次**，第二次返回 `{error, unknown_ref}`。**用户代码用 `_ = lingofuse:reply(...)` 而非 `ok =`**。
5. **P2P 级的 `Trigger` 是 `CallbackEntry*` 地址，非 nil，也不是 Erlang PID**。`sync_wait` 依赖 `e->caller_pid`（Erlang PID），与 `Trigger` 无关。
6. **Service main 需要 `sleep(15000)`** 让 SelfClient 完成 Link + UID/P2P 上报，然后 `loop` 再进入 receive。
7. **Service main loop 必须处理 8 种消息形态**：`lf_call` / `lf_p2p_call` × 有/无 `Identity` × 具体 API / 通用 API。同理 `lf_notify` / `lf_p2p_notify`。

---

## 第 1 章 ABI wire 格式坑（最关键，最容易被幻觉带偏）

### 1.1 坑：用 JSON 做 ABI wire

**症状**：
- Pascal/C++ ↔ Erlang 互不通
- Pascal service 读到 Erlang 回复时 `status` 判断错误
- Erlang service 读到 Pascal 回复时报 `{invalid_byte, 42}`

**证据（本次实战日志）**：

```
NoParamFunc(app call) failed: "ok":true,"result":0}
MultiLineComment(app call) failed: "error":"{invalid_byte,42}","ok":false}
```

**根因**：
- Erlang 生成器用 `lingofuse_json:loads/dumps` 处理 ABI 参数
- Pascal/C++ 生成器用二进制 `[status][payload]`
- 两边 wire 不一致

**修复**：
- **`erlang_abi_service_generator_tool.pas` / `erlang_abi_call_generator_tool.pas` 改为二进制 wire**
- **禁止 `lingofuse_json`**
- 请求 wire：`[Param1][Param2]...`，每个参数按类型 little-endian 定长 / `[UTF-8][#0]`
- 响应 wire：`[status 0x00][Result]` / `[status 0xFF][ErrorUTF8][#0]`

**教训**：
- **AI 最容易犯的错**：看到"Erlang 侧用 JSON 方便"，就推荐 JSON wire
- **正确**：**ABI 层必须与已存在的 Pascal/C++ 生成器严格一致**，不能自创协议
- **判断规则**：`cpp_abi_service_generator_tool.pas` 的 `Safe_Write_Scalar` / `Safe_Write_String` / `Safe_Write_Error` 是**唯一契约**

**本次生成器的正确实现（对齐 C++）**：

| 环节 | Erlang 生成器输出 | C++ 生成器对应 |
|------|------------------|---------------|
| 成功响应（int32） | `<<0, V:32/little-signed>>` | `Safe_Write_Scalar` |
| 成功响应（string） | `<<0, S/binary, 0>>` | `Safe_Write_String` |
| 成功响应（void） | `<<0>>` | `Safe_Write_Void` |
| 错误响应 | `<<255, Msg/binary, 0>>` | `Safe_Write_Error` |

### 1.2 坑：`lingofuse_json` 作为 ABI 层的一部分

**症状**：
- NIF 层不再 strip `#0` 后，`json:decode(<<"{\"k\":1}", 0>>)` 抛 `{invalid_byte, 0}`

**证据**：
```
t_call_no_identity/0 失败
```

**根因**：
- 旧设计：NIF 层帮用户 strip `#0`
- 新设计：NIF 层不 strip，`#0` 由消费方处理
- `lingofuse_json:loads/1` 未同步改

**修复**：
- **`lingofuse_json` 降级为用户层便利工具**，不再是 ABI 层的一部分
- `loads/1` 容忍末尾 `#0`：

```erlang
strip_trailing_nul(<<>>) -> <<>>;
strip_trailing_nul(Bin) ->
    case binary:last(Bin) of
        0 -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.
```

**教训**：
- **分层原则**：C ABI（NIF）**不干预字节**；类型化原语（`read_string` 等）**按类型处理**；用户层（`lingofuse_json:loads`）**容忍 wire framing**
- **任何一层多做或少做**，都会导致 `{invalid_byte, 0}` 或 `strip 掉 int32 高位字节`

---

## 第 2 章 NIF 层坑

### 2.1 坑：`read_and_strip_nul` 无条件剥末尾 `#0`

**症状**：
- `int32 42`（wire `2A 00 00 00`）被 strip 后变 3 字节
- 二进制参数末位字节被吞
- 生成器解码失败

**证据（本次实战日志）**：
```
MultiLineComment(app call) failed: "error":"{invalid_byte,42}","ok":false}
```

**根因**：
- `lingofuse_nif.c` 的 `read_and_strip_nul` 逻辑是"读完整 buffer，若末尾是 0x00 就 strip 一字节"
- **末尾 0x00 是 int32 的高位字节，不是字符串 terminator**

**修复**：
- 删 `read_and_strip_nul`，新增 `read_input_payload`（**不 strip**）
- 字符串 `#0` 的处理由消费方 `read_string` / `read_string_bytes` 负责

**教训**：
- **C ABI 层不 strip，是跨语言二进制互通的前提**
- **NIF 层无权替用户决定 strip**

### 2.2 坑：`lf_call_callback` 依赖 `Trigger` 找 Erlang PID

**错误理解**：`Trigger` 是 Erlang PID，`sync_wait` 依赖它

**正确理解**：
- `Trigger` 是 `CallbackEntry*` 地址（在 `callback_alloc` 里 `e->trigger = e`）
- `sync_wait` 依赖的是 `e->caller_pid`（注册时传入的 Erlang PID，即 Service main 的 `self()`）
- `enif_send(NULL, &e->caller_pid, ...)` 才是发消息的位置

**源码位置**：`lingofuse_nif.c` 的 `dispatch_to_process`

**教训**：
- **不要把 `Trigger` 想成 Erlang PID**。它是 `CallbackEntry*`，通过它找 `e->is_p2p` / `e->is_sync` / `e->caller_pid`
- **`api_.Trigger` 值不同是 App 级注册和 P2P 级注册各自分配独立 `CallbackEntry*` 的正常结果**，不是 bug

### 2.3 坑：`async` 注册模式下 NIF 不写 output

**症状**：
- 如果 Service 用 `register_call`（async 注册），C++ client 用 `LF_Call`（sync）
- NIF 的 `lf_call_callback` 在 async 注册时不 `sync_wait`，不写 output
- C++ client 收到空 result

**源码位置**：`lingofuse_nif.c` 的 `dispatch_to_process`：

```c
if (is_call) {
    if (e->is_sync) {
        // sync_wait + write_to_output_handle
    } else {
        // 只 enif_send，不写 output
    }
}
```

**结论**：
- **App 级 / P2P 级的 `register_*_sync` 是唯一能配合同步 client 的注册方式**
- **`register_*`（async 注册）只适合 fire-and-forget，或配合异步 client**

---

## 第 3 章 构建链坑（Windows + rebar3 专属）

### 3.1 坑：`file:copy` 在 junction 上自杀

**症状**：
- `83005` 字节的 DLL 变成 `0` 字节
- `LoadLibraryA` 返回 NULL + `GetLastError=0`

**证据（本次实战日志）**：
```
[build] output file size:
         d:/.../priv/lingofuse_nif.dll       83005 bytes
[build] copied to     : d:/.../_build/test/lib/lingofuse/priv/lingofuse_nif.dll
[build] OK

PS> ls .\priv\
-a---   ...   0 lingofuse_nif.dll     ← 0 字节！
```

**根因**：
- rebar3 在 Windows 上用 **junction** 实现 `_build/test/lib/lingofuse/priv` → `../../../../priv`
- Erlang `file:copy(Src, Dst)` 打开 `Dst`（write 模式）时截断为 0
- 因为 `Dst` 和 `Src` 是同一文件，`Src` 也被截断成 0

**修复**：
- `link_gcc` 前先 `file:delete(Target)`（防 0 字节残留）
- `copy_to_build_dir` 加 `same_stat` 判断（`size` + `mtime` 都相同就 skip）
- build 完成后两次尺寸校验（build 后、copy 后各一次），`0` 字节时 `halt(3)` / `halt(4)`

**教训**：
- **Windows 上的 junction 是 rebar3 的默认实现**。任何 `file:copy` 到 junction 路径的操作都可能自杀
- **通用规则**：复制前用 `file:read_file_info` 比较 `size` + `mtime`，相同则跳过

### 3.2 坑：`Invoke-Step` 输出被吞

**症状**：
- `build.ps1` 里看不到 rebar3 编译输出

**根因**：
- `Invoke-Step` 内部 `& $Body` 的输出被收集到函数返回值
- 赋给 `$code` 后不再显示

**修复**：
- `& $Body | Out-Host` 强制 stdout 走控制台，不影响 `$LASTEXITCODE`

### 3.3 坑：`setup_erlang_tests.ps1` 的 `-notmatch` 正则被 `\\` 转义搞坏

**症状**：
```
setup_erlang_tests.ps1: Invalid pattern '(?m)^-module\\(' at offset 15. Not enough )'s.
```

**根因**：
- Pascal 生成器输出 `-notmatch "(?m)^-module\\("`
- PowerShell 双引号字符串**不用反斜杠转义**，所以 `\\` 是两个反斜杠
- 传给 regex 引擎的是 `(?m)^-module\\(`，`\\` 是字面反斜杠，`(` 是未闭合分组

**修复**：
- 改用 `.StartsWith('-module(')` 等字符串方法，避免 regex

```powershell
$firstLine = ($c -split "`n")[0]
if ($null -eq $firstLine -or -not $firstLine.TrimStart().StartsWith('-module(')) { $stale += $rel }
```

**教训**：
- **PowerShell 双引号字符串里 `\\` 是两个反斜杠**，不是转义
- **能用 `.StartsWith` / `.EndsWith` / `.Contains` 就别用 `-match`**

### 3.4 坑：`setup_erlang_tests.ps1` 的 UnitName 检测错

**症状**：
```
[info] UnitName       : ComplexTestUnit_abi.app.src   ← 错！应该是 ComplexTestUnit
```

**根因**：
- `-replace "\.app\.src$", ""` + `-match "^(.+)_abi$"` 在某些 PowerShell 环境下不可靠

**修复**：
- 用 `.EndsWith` + `.Substring`：

```powershell
if ($n.EndsWith("_abi_service.erl")) {
    $found = $n.Substring(0, $n.Length - 16)
    break
}
```

- 校验 `$UnitName` 不能含 `\\/:*?"<>|`，不能以 `.app.src` / `.erl` / `.beam` 结尾

**教训**：
- **用字符串方法比 regex 可靠**
- **自动检测必须加防御性校验**（非法字符、看起来像文件名的值）

### 3.5 坑：`_build/` 里残留的错误文件

**症状**：
- 之前失败留下的 `src/ComplexTestUnit_abi.app.src_abi.app.src` 残留
- 后续 `EmitFileCheck` 全 fail

**修复**：
- 新增 `EmitCleanupStale`，扫 `src/*_abi.app.src_*` 并删除
- 用户可显式 `-Clean` 清 `_build/` 和 `ebin/`

### 3.6 坑：`LF_Get_Self_UID` 缺失（old dll）

**症状**：
```
[lingofuse_nif] LingoFuse library loaded (platform=Windows 64-bit, file=LingoFuse64.dll, get_self_uid=no (old dll))
```

**根因**：
- 旧版 `LingoFuse64.dll` 缺 `LF_Get_Self_UID` 导出

**影响**：
- **只是诊断信息**，不影响核心路由
- `lf_loader.c` 的 `LF_RESOLVE_OPTIONAL` 会跳过它，其他 59 个必需符号存在就正常加载

**修复**：
- **升级 DLL**（新版本有 `LF_Get_Self_UID`）
- 不升级也可以，只是 `get_self_uid=no` 会一直显示

---

## 第 4 章 生成器层坑

### 4.1 坑：`?CALL_MODULE` macro 在 OTP 29 下变量未绑定

**症状**：
```
variable 'NoParamFunc' is unbound
variable 'NoParamFunc_async' is unbound
variable 'NoParamFunc_uid' is unbound
...
```

**根因**：
- `-define(CALL_MODULE, 'ComplexTestUnit_abi_call').`
- `?CALL_MODULE:NoParamFunc(...)` 在 OTP 29 下被识别为 `variable 'NoParamFunc' is unbound`
- **这是 OTP 29 对 macro remote call 的兼容性问题**

**修复**：
- **彻底移除 `?CALL_MODULE` macro**
- 生成时内联 atom：

```erlang
fun() -> 'ComplexTestUnit_abi_call':'NoParamFunc'(?SERVICE_APP) end
```

**教训**：
- **macro + atom + 冒号调用**在 OTP 新版本有兼容性风险
- **内联 atom 字面量最稳定**

### 4.2 坑：`run_p2p_notify_test/4 undefined`

**症状**：
```
function run_p2p_notify_test/4 undefined, did you mean run_notify_test/4?
```

**根因**：
- 用户手上的 `erlang_abi_test_generator_tool.pas` 是**旧版本**（没有 `run_p2p_notify_test` helper）
- 新版本生成器有 `run_p2p_notify_test` 但用户没替换

**修复**：
- **强制删除旧生成文件**（`src/` 和项目根目录），重新生成
- **每次改生成器后必须 `Remove-Item` 旧文件**：

```powershell
Remove-Item src\ComplexTestUnit_abi_service_main.erl -Force
Remove-Item src\ComplexTestUnit_abi_call_main.erl -Force
```

**教训**：
- **生成器改动后必须清理旧生成文件**
- **setup 脚本应该默认清理旧文件**（`-Clean` 参数）

### 4.3 坑：`-compile({nowarn_unused_function, ...})` 遗漏

**症状**：
```
Warning: function lf_decode_ret_int64/1 is unused
Warning: function lf_decode_ret_uint32/1 is unused
...
```

**根因**：
- `ComplexTestUnit` 只有 `int32` / `double` / `string` 三种返回类型
- 其他 7 个 `lf_decode_ret_*` 函数"生成了但没被调用"

**修复**：
- 在 helper 区开头加 `-compile({nowarn_unused_function, [...]}).`
- 把全部 helper 函数纳入豁免列表

```erlang
-compile({nowarn_unused_function, [
    {lf_decode_ret_int32, 1},
    {lf_decode_ret_int64, 1},
    ...
]}).
```

**教训**：
- **helper 函数按需生成**（只生成实际用到的解码函数）
- 但本生成器为简化，**统一生成全部 + nowarn** 更省事

### 4.4 坑：`ok = lingofuse:reply(...)` 二次 reply 崩

**症状**：
- Service 处理某个 API 抛异常，进入 catch 分支
- catch 分支里 `ok = lingofuse:reply(...)` 抛 `{badmatch, {error, unknown_ref}}`
- 异常逃出 `?SERVICE_MODULE:lf_dispatch_call`
- Service main loop 崩溃

**根因**：
- `lingofuse:reply/2` 只能调用一次
- 第二次返回 `{error, unknown_ref}`
- `ok =` 强制匹配会抛 `badmatch`

**修复**：
- **用户代码用 `_ = lingofuse:reply(...)` 而非 `ok =`**

```erlang
_ = lingofuse:reply(Ref, encode_ok_int32(_Ret)),
ok
```

**教训**：
- **二次 reply 是 `{error, unknown_ref}`，不是 throw**
- **永远用 `_ =` 而非 `ok =`**

### 4.5 坑：`Cb_ReportServiceIdentity` 缺 status byte（C++ 生成器）

**症状**：
```
[SERVICE] do_reverse_call: non-ABI response received
```

**证据**：
- C++ client 的 `Cb_ReportServiceIdentity` 用 `io::write_string(out_h.get(), std::string("identity received"))`
- 首字节是 `'i'` (0x69)，不是 `0` (STATUS_OK)

**修复**：
- **C++ 生成器 `cpp_abi_cmake_generator_tool.pas`**：

```cpp
std::uint8_t status = 0x00;
out_h.writeRaw(&status, 1);
lingofuse::io::write_string(out_h.get(), std::string("identity received"));
```

**教训**：
- **所有 ABI 回调必须严格遵守 `[status 0x00/0xFF][payload]` 契约**
- **`io::write_string` 只是写字符串，不写 status byte**

---

## 第 5 章 测试层坑

### 5.1 坑：`whereis(lf_test_pid)` 未注册（本次实战最大坑之一）

**症状**：
- Client 的 `[CLIENT] service called me, service UID = ...` 打印了
- 但 `test_service_initiates_call` 15 秒超时

**证据（本次实战日志）**：
```
[CLIENT] service called me, service UID = ...
[WARN] service-initiated call timeout (15s), UID tests will be SKIP
```

**根因**：
- `loop/1` 里用 `whereis(lf_test_pid)` 找 TestPid
- 但 **`run_tests/1` 从未调用 `register_test_pid/0`**
- 从未 `register(lf_test_pid, TestPid)`
- 所以 `whereis(lf_test_pid)` 永远返回 `undefined`
- `TestPid ! {service_uid_received, ...}` 永远不执行
- TestPid 一直卡在 `receive` 15 秒，超时

**修复**：
- **不要用 `register/whereis`**（脆弱且容易忘）
- 直接在 `main` 里 `spawn` 后 `loop(App, TestPid)` 传 pid 进去：

```erlang
main(_) ->
    ...
    MainPid = self(),
    TestPid = spawn(fun() -> run_tests(MainPid) end),
    loop(App, TestPid).   %% 直接把 TestPid 传进去

loop(App, TestPid) ->
    receive
        {lf_call, Ref, <<"LF_TEST_REPORT_SERVICE_IDENTITY">>, _Payload, Identity} ->
            ServiceUid = maps:get(uid, Identity, <<0:256>>),
            TestPid ! {service_uid_received, ServiceUid},   %% 直发
            ...
```

**教训**：
- **闭包/参数传递比 `register/whereis` 可靠**
- **`whereis` 返回 `undefined` 时不能静默忽略**（应该立刻报错）

### 5.2 坑：`unique_fake_uid` 的 `os:getpid()` 类型

**症状**：
```
{badarg, {1, binary, type, "11536"}}
```

**根因**：
- `os:getpid()` 返回 `string()`，不能直接 `/binary`

**修复**：

```erlang
unique_fake_uid() ->
    crypto:strong_rand_bytes(32).
```

### 5.3 坑：instantiator 的 `skip` 未处理

**症状**：
```
{badmap, skip}
```

**根因**：
- `ensure_native_or_skip` 返回 `skip` 时，`Ctx = skip`
- `maps:get(uid, skip)` 崩溃

**修复**：

```erlang
uid_addressing_test_() ->
    {setup,
     fun setup_uid_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) when is_map(Ctx) -> [ ... ];
        (_) -> []
     end}.
```

### 5.4 坑：`flush_lf_messages` 未覆盖 16 种 tuple 形态

**症状**：
- 残留消息污染下一次测试

**根因**：
- 消息 tuple 形态取决于 `with_identity` 开关 × call/notify × app/p2p，共 **2×2×2×2 = 16 种**
- 旧版只覆盖了 3-tuple，漏了 4-tuple / 5-tuple

**修复**：
- `flush_lf_messages` 必须覆盖全部 16 种：

```erlang
flush_lf_messages() ->
    receive
        {lf_call, _, _}              -> flush_lf_messages();
        {lf_call, _, _, _}           -> flush_lf_messages();
        {lf_call, _, _, _, _}        -> flush_lf_messages();
        {lf_notify, _}               -> flush_lf_messages();
        {lf_notify, _, _}            -> flush_lf_messages();
        {lf_notify, _, _, _}         -> flush_lf_messages();
        {lf_p2p_call, _, _}          -> flush_lf_messages();
        {lf_p2p_call, _, _, _}       -> flush_lf_messages();
        {lf_p2p_call, _, _, _, _}    -> flush_lf_messages();
        {lf_p2p_notify, _}           -> flush_lf_messages();
        {lf_p2p_notify, _, _}        -> flush_lf_messages();
        {lf_p2p_notify, _, _, _}     -> flush_lf_messages();
        {lf_async_result, _, _}      -> flush_lf_messages();
        {lf_connect, _}              -> flush_lf_messages();
        {lf_disconnect, _}           -> flush_lf_messages()
    after 0 -> ok
    end.
```

### 5.5 坑：`sleep(1500)` 太短导致 SelfClient UID/P2P 未上报

**症状**：
- Service `[OK] service ready` 打印了
- 但 Client 立即 `LF_UID_Call(service_uid)` 5 秒超时

**证据（本次实战日志）**：
```
[OK] service ready on ipc:ComplexTestUnit_abi     ← sleep(1500) 结束
[OK] service P2P group = ComplexTestUnit_service_test_p2p
LingoFuse Service Link Succeeded IO "..."          ← Link 在 ready 之后才成功！
```

**根因**：
- `LF_PrepareDone` 用 `Wait_Connection_ReadyOk=False` 立即返回
- SelfClient 的 Link 建立 + UID/P2P 上报需要更久
- `sleep(1500)` 不够

**修复**：
- `sleep(1500)` → `sleep(15000)`

**教训**：
- **`Wait_Connection_ReadyOk=False` 时 `LF_PrepareDone` 立即返回**，但 SelfClient 的 Link 和上报是异步的
- **Service main 必须 sleep 足够久**，或显式轮询 `check_app` / `check_uid` / `check_p2pname`

### 5.6 坑：Client 的 `probe_client_identity` 早于 Service `loop` 就绪

**症状**：
```
ComplexTestUnit_abi -> LF_TEST_WHOAMI call timeout
[WARN] whoami: empty response
[WARN] whoami failed
```

**根因**：
- Client 的 `wait_service_ready(40)`（`check_app`，基于 **Client 本地缓存**）在 Service `sleep(15000)` 结束前就返回 true
- Client 的 `probe_client_identity` 在 Service `sleep(15000)` 期间执行
- Service `loop(App)` 还没进入 receive
- Client `LF_Call` 5 秒超时

**修复（可选，未修）**：
- `probe_client_identity` 改为重试机制，最多重试 60 次（60 秒）：

```erlang
probe_client_identity_with_retry() ->
    probe_client_identity_with_retry(60).

probe_client_identity_with_retry(0) ->
    io:format("[WARN] whoami failed after 60 retries~n"),
    false;
probe_client_identity_with_retry(N) ->
    case probe_client_identity() of
        true -> true;
        false ->
            timer:sleep(1000),
            probe_client_identity_with_retry(N - 1)
    end.
```

**教训**：
- **`check_app` 基于 Client 本地缓存**，有约 3 秒延迟
- **`check_app = true` 不代表 Service `loop` 就绪**
- **首次 `LF_Call` 可能超时**，需要重试

### 5.7 坑：`erl_crash.dump` 残留

**症状**：
- 项目根目录出现 3.2 MB 的 `erl_crash.dump`

**根因**：
- 之前测试失败时 Erlang VM 崩溃留下的

**修复**：
- `Remove-Item erl_crash.dump -Force`

---

## 第 6 章 核心库坑（非 Erlang 责任，但会被牵连）

### 6.1 坑：`Find_Local_UID_App` 不检查 UID 归属

**症状**：
- Client 的 `LF_UID_Call(client_uid, "NoParamFunc")` 发给 Server
- Server 的 `Find_Local_UID_App` 发现 `NoParamFunc` 在 `___LF_P2P_APP___` 里（Service 自己注册的 P2P API）
- **直接返回 Service 自己的 App**
- Server 就地执行，不回包给 Client
- Client timeout

**源码位置**：`Z.Net.C4.LingoFuse.pas` 的 `TC40_LF_Service.Find_Local_UID_App`

**正确的语义**：
```
在 UID 对应的客户端里找 API。
- 如果 UID 是本地 SelfClient 的 UID → 返回本地 App
- 如果 UID 是外部 Client 的 UID → 返回 nil（让 cmd_UID_Call 转发）
- 如果 UID 找不到 → 返回 nil
```

**当前实现（有 bug）**：
```pascal
function TC40_LF_Service.Find_Local_UID_App(UID: TP2P_UID; api_name__: SystemString): TLF_App;
begin
  Result := nil;
  // 只查 api 是否在本地 App 里，完全不管 UID
  if LF_P2P_APP.Engine.LF_MethodPool.Exists_Key(api_name__) then
    begin
      Result := LF_P2P_APP;
      exit;
    end;
  ...
end;
```

**修复方案（需要源码）**：
```pascal
function TC40_LF_Service.Find_Local_UID_App(UID: TP2P_UID; api_name__: SystemString): TLF_App;
var
  target_uid_data__: PUID_Data___;
begin
  Result := nil;
  
  // 关键：先查 UID 对应的客户端是否在本地
  target_uid_data__ := FUID_Pool.Get_Value_Ptr___(UID);
  if target_uid_data__ = nil then
    exit;  // UID 找不到，返回 nil 让 cmd_UID_Call 转发
  
  // 如果 UID 是本地 SelfClient，则查它注册的 api
  if target_uid_data__^.recv_io = nil then
  begin
    if LF_P2P_APP.Engine.LF_MethodPool.Exists_Key(api_name__) then
      Result := LF_P2P_APP;
    exit;
  end;
  
  // 如果 UID 是外部客户端，返回 nil 让 cmd_UID_Call 转发
  exit;
end;
```

### 6.2 坑：`cmd_UID_Call` 找不到目标时静默返回

**症状**：
- Client 调用 `LF_UID_Call(unknown_uid, ...)` 或 `LF_UID_Call(service_uid, unknown_api)`
- Server 的 `Find_Local_UID_App` 返回 nil
- `cmd_UID_Call` **静默返回，没有回 `0xFF + error`**
- Client 5 秒后 timeout

**源码位置**：`Z.Net.C4.LingoFuse.pas` 的 `TC40_LF_Service.cmd_UID_Call`

**修复方案（需要源码）**：

```pascal
if tmp_cli__ = nil then
  begin
    err_m64 := TMem64.Create;
    try
      err_m64.WriteUInt8($FF);
      err_m64.WriteString('no found uid');
      Sender.SendCompleteBuffer_StreamM('CallResult', Ref, err_m64);
    finally
      DisposeObject(err_m64);
    end;
    exit;
  end;
```

### 6.3 坑：`cmd_P2PName_Call` 同样问题

**与 6.2 相同**，`cmd_P2PName_Call` 找不到目标时也静默返回。

### 6.4 坑：`TLF_DataPool.Progress` 的 `timeout_freed` 未初始化

**症状**：
```
[LF-DEBUG] DataPool.Progress: live=1 timeout_freed=8391735962092794912
```

**`8391735962092794912 ≈ 8.4 × 10^18`**，这是 `TTimeTick`（`UInt64`）的非法值。

**根因（推测）**：
- `TLF_DataPool.Progress` 里某个字段（如 `FTimeOutFreed`）未初始化
- 或者是 `GetTimeTick` 返回未定义值

**修复方案（需要源码）**：初始化 `FTimeOutFreed := 0`。

**影响**：
- 极端情况下可能导致错误的 handle 回收
- **本次测试 120/120 PASS，未见实际影响**

### 6.5 坑：`TLF_App.Destroy` 访问冲突（`$C0000005`）

**症状**：
```
[LF-DEBUG] TLF_App.Destroy: name="ComplexTestUnit_abi"
[Fatal] Unhandled exception code=$C0000005 location=$00007FFEEF605A1A
```

**根因（推测）**：
- `TLF_App.Destroy` 释放 `Engine` 或其他内部对象时访问了已释放内存
- `Remove_Timer(self)` 在 `Z.Core` 的 finalization 之后调用
- `Timer_Event_Pool__ = nil`，`nil.Delete` 触发崩溃

**修复方案（需要源码）**：

```pascal
destructor TLF_App.Destroy;
begin
  ...
  if Assigned(Timer_Event_Pool__) then
      Remove_Timer(self);
  ...
end;
```

**影响**：
- **本次测试 120/120 PASS**，因为用户用 `halt(0)` 直接退出进程，没走 `LF_Shutdown` → `TLF_App.Destroy` 路径
- 但如果正常 `LF_Shutdown` 路径退出，必崩

---

## 第 7 章 最终根因：`lf_p2p_call` / `lf_p2p_notify` atom 未处理

> **这是本次实战最深的坑，导致 UID/P2PName 路由全部 timeout。找到它花了 3 轮错误修复。**

### 7.1 完整因果链

```
Client LF_UID_Call(service_uid, "NoParamFunc")
  ↓
Server cmd_UID_Call
  ↓
Find_Local_UID_App(service_uid, "NoParamFunc") → LF_P2P_APP（因为 P2P APP 有 NoParamFunc）
  ↓
LF_P2P_APP.Engine.Execute_Call
  ↓
api_.On_Call(Trigger=P2P CallbackEntry*, ...)
  ↓
NIF lf_call_callback(Trigger, ...)
  ↓
dispatch_to_process(e, input, 1)
  ↓
e->is_p2p=1, e->is_sync=1
  ↓
enif_send({lf_p2p_call, Ref, Api, Payload, Identity})   ← ★ 关键
  ↓
Service loop _Other 分支丢弃                            ← ★ 根因
  ↓
sync_wait 等 30 秒（g_sync_timeout_ms = 30000）
  ↓
返回 got=0, lf_sync_take_result 空, write_to_output_handle 不写
  ↓
Execute_Call 打印 done: result_size=0（但 30 秒后）
  ↓
Client 5 秒已 timeout
```

**用户 5 秒看日志时 `done` 还没打印，所以"有 `found=yes` 无 `done`"完全符合。**

### 7.2 NIF 按 `e->is_p2p` 发送不同 atom

`lingofuse_nif.c` 的 `build_callback_message`：

```c
if (e->is_notify) {
    terms[n++] = e->is_p2p ? ATOM_LF_P2P_NOTIFY : ATOM_LF_NOTIFY;
} else {
    terms[n++] = e->is_p2p ? ATOM_LF_P2P_CALL : ATOM_LF_CALL;
    if (e->is_sync) terms[n++] = enif_make_uint64(env, ref);
}
terms[n++] = api_term;
terms[n++] = payload_term;
if (e->with_identity && id != NULL) terms[n++] = make_identity_map(env, id);
```

**注册方式与发送 atom 的映射**：

| 注册方式 | `e->is_p2p` | `e->is_sync` | 发送的 Erlang 消息 |
|---------|:-----------:|:------------:|-------------------|
| `register_call` | 0 | 0 | `{lf_call, Api, Payload, Identity}` |
| `register_call_sync` | 0 | 1 | `{lf_call, Ref, Api, Payload, Identity}` |
| `register_notify` | 0 | - | `{lf_notify, Api, Payload, Identity}` |
| `register_p2p_call` | 1 | 0 | `{lf_p2p_call, Api, Payload, Identity}` |
| **`register_p2p_call_sync`** | **1** | **1** | **`{lf_p2p_call, Ref, Api, Payload, Identity}`** |
| `register_p2p_notify` | 1 | - | `{lf_p2p_notify, Api, Payload, Identity}` |

### 7.3 修复前：Service main loop 只匹配 `lf_call` / `lf_notify`

```erlang
loop(App) ->
    receive
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload, Identity} -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload, Identity} -> ...;
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload} -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload} -> ...;
        {lf_call, Ref, Api, Payload, Identity} -> ...;    ← 匹配 App 级 sync
        {lf_notify, Api, Payload, Identity} -> ...;       ← 匹配 App 级 async notify
        _Other -> loop(App)                                ← ★ lf_p2p_call 落这里被丢弃
    end.
```

### 7.4 修复后：Service main loop 扩展 16 个分支

```erlang
loop(App) ->
    receive
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload, Identity} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload, Identity} when is_integer(Ref) -> ...;
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload} when is_integer(Ref) -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload, Identity} -> ...;
        {lf_p2p_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload, Identity} -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload} -> ...;
        {lf_p2p_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload} -> ...;
        {lf_call, Ref, Api, Payload, Identity} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, Api, Payload, Identity} when is_integer(Ref) -> ...;
        {lf_call, Ref, Api, Payload} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, Api, Payload} when is_integer(Ref) -> ...;
        {lf_notify, Api, Payload, Identity} when is_binary(Api) -> ...;
        {lf_p2p_notify, Api, Payload, Identity} when is_binary(Api) -> ...;
        {lf_notify, Api, Payload} when is_binary(Api) -> ...;
        {lf_p2p_notify, Api, Payload} when is_binary(Api) -> ...;
        _Other -> loop(App)
    end.
```

### 7.5 为什么 `when is_integer(Ref)` 守卫很重要

- `{lf_call, Api, Payload, Identity}`（async 注册）的第 2 元素是 **binary**（Api 名）
- `{lf_call, Ref, Api, Payload}`（sync 注册）的第 2 元素是 **integer**（Ref）
- 没有守卫时，Erlang 会按顺序匹配，可能相互抢匹配
- **加守卫保证不同 arity 的消息精确匹配**

### 7.6 教训

1. **NIF 的 atom 区分是合理设计**，让用户能区分 App 级和 P2P 级回调
2. **生成器的 loop 必须处理全部 16 种 atom 形态**
3. **改 Client 用 async 不能解决**（Server 端的 `cmd_UID_Call` 依然调 `LF_P2P_APP.Engine.Execute_Call`，依然发 `lf_p2p_call`）
4. **改 Service 用 `register_call`（async 注册）也不能解决**（`e->is_p2p` 依然由注册函数决定，NIF 依然发 `lf_p2p_call`）
5. **唯一的修复点是 loop 分支**

---

## 第 8 章 诊断方法论（本次实战验证有效的顺序）

### 8.1 分层排查顺序

**正确的排查顺序**：

1. **测试代码本身是否有 bug**（`flush_lf_messages`、`wait_until` 时序、返回值匹配）
2. **构建脚本是否正确**（`LINGOFUSE_SKIP_NIF`、DLL 复制、junction）
3. **NIF 层是否有 bug**（`sync_wait`、`sync_deliver`、`read_and_strip_nul`）
4. **核心库是否有 bug**（`FUID_Pool`、`cmd_UID_Call`、`Find_Local_UID_App`）
5. **生成器层是否有 bug**（wire 格式、atom 形态、helper 函数）

**本次问题**横跨 1、2、3、5 层，**不是核心库问题**（虽然核心库也有 bug，但不是本次卡死根因）。

### 8.2 诊断三件套

1. **`Quiet=False`**：打开完整 debug 日志
2. **`LINGOFUSE_NIF_DEBUG=1`**：打开 NIF 诊断
3. **`trigger=%s` 日志**：在 `LF_Register*` 里打印 Trigger 值

### 8.3 关键判断法

**当现象是"某条路由 timeout 但其他路由 PASS"**：

- ✅ 先查 **atom 形态是否被处理**（`lf_call` / `lf_p2p_call`）
- ✅ 再查 **UID 归属**（`Find_Local_UID_App` 是否正确）
- ❌ **不要**先查 `Trigger` 值（Trigger 是 `CallbackEntry*` 地址，App 级和 P2P 级不同是正常的）
- ❌ **不要**先查 `sync_wait`（它依赖 `e->caller_pid`，与 Trigger 无关）

**当现象是"跨语言不通"**：

- ✅ 先查 **wire 格式是否一致**（二进制 vs JSON）
- ✅ 再查 **NIF 是否 strip `#0`**
- ❌ **不要**先查业务代码

### 8.4 日志观察法

**每次修复后必须看**：

1. `Engine.Execute_Call: ... found=yes` **之后有没有 `Engine.Execute_Call done: result_size=N`**
2. 如果**没有 `done`**：说明卡在 `api_.On_Call` 内部
3. 如果**有 `done` 但 Client 还是 timeout**：说明返回路径有问题

**本次实战的关键发现**：UID 路由 `found=yes` 后**没有 `done`**，App 名路由 `found=yes` 后**有 `done`**。差异指向 `api_.On_Call` 内部。

---

## 第 9 章 反幻觉清单（AI 最容易写错的地方）

> 以下每一条都是本次实战中 AI 犯过的错。

### 9.1 ❌ 错误：以为 UID 路由卡死是 `Trigger` 无效

**真相**：`Trigger` 是 `CallbackEntry*` 地址，App 级和 P2P 级各自分配独立 `CallbackEntry*`，**都非 nil**。`sync_wait` 依赖的是 `e->caller_pid`，与 `Trigger` 无关。

### 9.2 ❌ 错误：以为改 Client 用 async_call 能解决 UID 路由 timeout

**真相**：Client 用 `LF_Async_Call` 只是改了 Client 侧调用方式。**Server 端的 `cmd_UID_Call` 依然调 `LF_P2P_APP.Engine.Execute_Call`，依然发 `lf_p2p_call`，依然卡死**。

### 9.3 ❌ 错误：以为 Service 用 `register_call`（async 注册）能解决

**真相**：`e->is_p2p` 依然由注册函数决定（`register_p2p_call` → `e->is_p2p = 1`）。NIF 依然发 `lf_p2p_call`。Service loop 依然不匹配。

### 9.4 ❌ 错误：以为核心库 `Find_Local_UID_App` 是唯一根因

**真相**：`Find_Local_UID_App` 确实有 bug（不检查 UID 归属），但**即使修复它**，如果 `lf_p2p_call` 不被 loop 处理，**UID 路由依然 timeout**。

**两个 bug 都要修**：`Find_Local_UID_App`（让 UID 路由转发到正确目标）+ loop 处理 `lf_p2p_call`（让 P2P 级回调能执行）。

### 9.5 ❌ 错误：以为 `lingofuse:reply(Ref, <<...>>)` 可以用 `ok =`

**真相**：`lingofuse:reply/2` 只能调用一次。第二次返回 `{error, unknown_ref}`。`ok =` 会抛 `{badmatch, {error, unknown_ref}}`。

### 9.6 ❌ 错误：以为 `?CALL_MODULE` macro 是标准写法

**真相**：OTP 29 下 `?CALL_MODULE:NoParamFunc(...)` 会被识别为 `variable 'NoParamFunc' is unbound`。**必须内联 atom 字面量**。

### 9.7 ❌ 错误：以为 `sleep(1500)` 足够让 SelfClient 完成 Link

**真相**：`LF_PrepareDone` 用 `Wait_Connection_ReadyOk=False` 时立即返回，但 SelfClient 的 Link 建立 + UID/P2P 上报是异步的。`sleep(1500)` 不够，**`sleep(15000)` 才稳**。

### 9.8 ❌ 错误：以为 `whereis(lf_test_pid)` 能找到 TestPid

**真相**：如果 `run_tests/1` 从未 `register(lf_test_pid, TestPid)`，`whereis` 永远返回 `undefined`。**用参数传递 pid 更可靠**。

### 9.9 ❌ 错误：以为 `PowerShell` 双引号字符串里 `\\` 是转义

**真相**：PowerShell 双引号字符串里 `\\` 是两个字面反斜杠。传给 regex 引擎的是 `\\(`，`(` 是未闭合分组。

### 9.10 ❌ 错误：以为 `file:copy` 在 junction 上是安全的

**真相**：Windows 上的 junction 是 rebar3 的默认实现。`file:copy(Src, Dst)` 打开 `Dst`（write 模式）时截断为 0，`Src` 和 `Dst` 是同一文件 → 自杀。

### 9.11 ❌ 错误：以为 `-replace "\.app\.src$", ""` 可靠

**真相**：某些 PowerShell 环境下不可靠。用 `.EndsWith` + `.Substring` 更稳。

### 9.12 ❌ 错误：以为 `lingofuse_json:loads(<<"{\"k\":1}", 0>>)` 能解码

**真相**：`json:decode(<<"{\"k\":1}", 0>>)` 抛 `{invalid_byte, 0}`。**必须 strip 末尾 `#0`**。

### 9.13 ❌ 错误：以为 `int32 42` 的 wire 是 `2A 00 00`（3 字节）

**真相**：`int32 42` 的 wire 是 `2A 00 00 00`（4 字节）。NIF 层 strip `#0` 会吞掉高位字节。

### 9.14 ❌ 错误：以为 `read_and_strip_nul` 是"帮用户方便"

**真相**：C ABI 层不 strip，是跨语言二进制互通的前提。strip 由消费方负责。

### 9.15 ❌ 错误：以为 `Count` 属性可以直接读

**真相**：`Z.LingoFuse_Core` 的 `FTimeOutFreed` 等字段可能未初始化。`TLF_DataPool.Progress` 的 `timeout_freed` 显示 `8.4 × 10^18` 说明有未初始化字段。

---

## 第 10 章 速查表

### 10.1 症状 → 根因 → 修复

| 症状 | 根因 | 修复 |
|------|------|------|
| `variable 'Xxx' is unbound` | `?CALL_MODULE` macro + OTP 29 | 内联 atom 字面量 |
| `function run_p2p_notify_test/4 undefined` | 旧版 test generator | 删除旧文件，重新生成 |
| `Warning: function lf_decode_ret_* is unused` | 有些类型未用到 | `-compile({nowarn_unused_function, ...})` |
| `Warning: function decode_params_* is unused` | 有些 API 无参数 | 同上 |
| `{badmatch, {error, unknown_ref}}` | 二次 `lingofuse:reply` | `ok =` → `_ =` |
| `{invalid_byte, 0}` | JSON 解码遇 `#0` | `loads/1` 加 `strip_trailing_nul` |
| `{invalid_byte, 42}` | NIF strip 了 int32 高位字节 | NIF 层不 strip |
| `ComplexTestUnit_abi -> LF_TEST_WHOAMI call timeout` | Service loop 未就绪 | `sleep(15000)` + `probe_client_identity` 重试 |
| UID 路由 timeout | `lf_p2p_call` 未被 loop 处理 | loop 加 `lf_p2p_call` 分支 |
| P2PName 路由 timeout | 同上 | 同上 |
| `[DIAG] UID NOT registered after 20s` | SelfClient 未上报 | 延长 `sleep` + 显式轮询 |
| `[Fatal] Unhandled exception code=$C0000005` | `TLF_App.Destroy` 崩溃 | `if Assigned(Timer_Event_Pool__) then Remove_Timer(self);` |
| `timeout_freed=8391735962092794912` | `TLF_DataPool.Progress` 未初始化字段 | 需要核心库源码 |
| `[lingofuse_nif] get_self_uid=no (old dll)` | 旧版 DLL 缺 `LF_Get_Self_UID` | 升级 DLL |
| `Invalid pattern '(?m)^-module\\('` | PowerShell `\\` 转义 | 用 `.StartsWith` |
| `[info] UnitName: ComplexTestUnit_abi.app.src` | `-replace` 不可靠 | 用 `.EndsWith` + `.Substring` |
| `83005 字节 DLL → 0 字节` | `file:copy` 在 junction 上自杀 | `same_stat` 检查 |
| `Service exited prematurely` | 端口冲突或 IPC 僵尸队列 | 手动清理或换端口 |

### 10.2 关键日志关键词

| 关键词 | 含义 |
|--------|------|
| `Engine.Execute_Call: ... found=yes` | 进入 `api_.On_Call` 前 |
| `Engine.Execute_Call done: result_size=N` | 正常返回 |
| `SVC.cmd_Call: LOCAL path, HPC dispatch` | App 名路由本地执行 |
| `SVC.cmd_UID_Call: ENTER` | UID 路由开始 |
| `Find_Local_UID_App: ... matched=True` | UID 路由命中本地 |
| `Find_Local_UID_App: ... matched=False` | UID 路由未命中本地 |
| `Client.Wait_UID_Execute_Call_Impl: TIMEOUT` | Client 超时 |
| `[DIAG] UID registered after N polls` | UID 注册成功（Client 缓存） |
| `[SERVICE] do_reverse_call: OK` | 反向调用成功 |

### 10.3 关键的 atom 形态（16 种）

| 注册方式 | 有 Identity | 无 Identity |
|---------|-------------|-------------|
| `register_call` | `{lf_call, Api, Payload, Identity}` | `{lf_call, Api, Payload}` |
| `register_call_sync` | `{lf_call, Ref, Api, Payload, Identity}` | `{lf_call, Ref, Api, Payload}` |
| `register_notify` | `{lf_notify, Api, Payload, Identity}` | `{lf_notify, Api, Payload}` |
| `register_p2p_call` | `{lf_p2p_call, Api, Payload, Identity}` | `{lf_p2p_call, Api, Payload}` |
| `register_p2p_call_sync` | `{lf_p2p_call, Ref, Api, Payload, Identity}` | `{lf_p2p_call, Ref, Api, Payload}` |
| `register_p2p_notify` | `{lf_p2p_notify, Api, Payload, Identity}` | `{lf_p2p_notify, Api, Payload}` |

**注意**：
- 所有 sync 消息都有 `Ref`（integer）
- 所有带 Identity 的消息最后一个是 map
- **`when is_integer(Ref)` / `when is_binary(Api)` 守卫是必须的**

---

## 附录 A 环境信息快照

| 项 | 值 |
|----|-----|
| OS | Windows 10.0.20348.0 (X64) |
| Erlang/OTP | 29 |
| erts | 17.1 |
| PowerShell | 7.6.6 |
| .NET | 10.0.12 |
| rebar3 | 本地 `rebar3.cmd` |
| gcc | MinGW-w64 16.1.0 (`x86_64-win32-seh-rev1`) |
| clang | LLVM 23.1.2 |
| LingoFuse64.dll | 2924544 bytes（**旧版，缺 `LF_Get_Self_UID`**） |
| z_ipc_64.dll | 258048 bytes (2026-08-26) |

**关键环境变量**：

| 变量 | 用途 |
|------|------|
| `LINGOFUSE_SKIP_NIF` | 跳过 NIF 编译（`0`/`false`/`no`/`off` 视为不跳过） |
| `LINGOFUSE_NIF_DEBUG` | 开启 NIF 诊断 fprintf |
| `LINGOFUSE_REQUIRE_NATIVE` | 原生库缺失时硬失败（CI 用） |
| `LINGOFUSE_CC` | 指定 C 编译器 |

---

## 附录 B 本次修复的文件清单

### B.1 已修复的生成器

| # | 文件 | 关键改动 | 状态 |
|---|------|---------|:----:|
| 1 | `erlang_abi_service_generator_tool.pas` | 二进制 wire + `_ =` reply + `-compile(nowarn)` | ✅ |
| 2 | `erlang_abi_call_generator_tool.pas` | 二进制 wire + 内联 atom + `-compile(nowarn)` | ✅ |
| 3 | `erlang_abi_test_generator_tool.pas` | **Service loop 16 分支** + `sleep(15000)` + `wait_uid/p2p_registered` | ✅ |
| 4 | `erlang_abi_test_setup_generator_tool.pas` | UnitName 检测（`.EndsWith`）+ stale 清理 + rebar3 编译 | ✅ |
| 5 | `cpp_abi_cmake_generator_tool.pas`（用户已修） | `Cb_ReportServiceIdentity` 加 status byte | ✅ |

### B.2 已修复的 NIF

| # | 文件 | 关键改动 | 状态 |
|---|------|---------|:----:|
| 1 | `c_src/lingofuse_nif.c` | 删 `read_and_strip_nul` → `read_input_payload` | ✅ |
| 2 | `c_src/build.escript` | 尺寸打印 + `same_stat` 判断 + `file:delete` 防线 + `halt(3)/(4)` 硬失败 | ✅ |
| 3 | `build.ps1` | `Invoke-Step` 用 `\| Out-Host` | ✅ |

### B.3 已修复的 Erlang 绑定

| # | 文件 | 关键改动 | 状态 |
|---|------|---------|:----:|
| 1 | `src/lingofuse.erl` | 24 个类型化 ABI 原语 | ✅ |
| 2 | `src/lingofuse_json.erl` | `loads/1` 加 `strip_trailing_nul` | ✅ |
| 3 | `src/lingofuse_nif.erl` | 移除注释 | ✅ |
| 4 | `src/lingofuse_app.erl` | 移除注释 | ✅ |
| 5 | `src/lingofuse_sup.erl` | 移除注释 | ✅ |

### B.4 已修复的测试

| # | 文件 | 关键改动 | 状态 |
|---|------|---------|:----:|
| 1 | `test/lingofuse_network_tests.erl` | 5 处修复（`unique_fake_uid` / instantiator / flush 16 形态） | ✅ |

### B.5 未修的核心库（需提供源码）

| # | 位置 | Bug |
|---|------|-----|
| 1 | `Z.Net.C4.LingoFuse.pas` `Find_Local_UID_App` | 不检查 UID 归属 |
| 2 | `Z.Net.C4.LingoFuse.pas` `cmd_UID_Call` | 找不到时静默返回 |
| 3 | `Z.Net.C4.LingoFuse.pas` `cmd_P2PName_Call` | 找不到时静默返回 |
| 4 | `Z.LingoFuse_Core.pas` `TLF_DataPool.Progress` | `timeout_freed` 未初始化 |
| 5 | `Z.LingoFuse_Core.pas` `TLF_App.Destroy` | `$C0000005` 访问冲突 |

### B.6 未修的可选优化

| # | 位置 | 优化 |
|---|------|------|
| 1 | `erlang_abi_test_generator_tool.pas` `probe_client_identity` | 加重试机制（消除 `[WARN] whoami failed`） |

---

## 结语

### 本知识库的定位

一份**准确的、可操作的** Erlang 绑定踩坑档案。它不假装能替代源码，但能让你在 90% 的场景下避免重复踩坑，并在剩下 10% 的场景下知道该停下来问人。

### 核心承诺

- **每条坑都有症状 + 证据 + 根因 + 修复 + 教训**
- **所有日志片段来自本次实战**
- **不掩盖、不美化、不猜测**

### 快速回忆

**记住这 7 条，可以避免 90% 的返工**：

1. **ABI 层必须二进制 wire**，禁止 JSON。
2. **NIF 层不 strip `#0`**。
3. **Service loop 必须处理 `lf_call` / `lf_p2p_call` / `lf_notify` / `lf_p2p_notify` × 有/无 Identity × 具体/通用 = 16 种**。
4. **`lingofuse:reply/2` 只能一次，用 `_ =` 而非 `ok =`**。
5. **`Trigger` 是 `CallbackEntry*`，非 nil，也不是 Erlang PID**。
6. **`sleep(15000)` 让 SelfClient 完成 Link + 上报**。
7. **遇到 UID/P2PName 路由 timeout，先查 atom 是否被 loop 处理，不要先查 Trigger**。

**如果还不确定，先看第 9 章反幻觉清单，再看第 10 章速查表。**

---

**文档版本**：v1
**最后更新**：2026-10-25
**维护者**：Erlang 绑定维护组