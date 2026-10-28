# LingoFuse Erlang 绑定修复全记录

> 文档定位：本次多轮修复工作的完整技术档案。
> 覆盖范围：基础库（C NIF + Erlang）、构建链、测试套件、跨语言 ABI 契约。
> 记录方式：每一轮问题的根因、证据、修复、验证，以及分层的经验法则。
> 未完成项在末尾集中列出。

---

## 目录

- [0. 起点与目标](#0-起点与目标)
- [1. 跨语言 ABI 的核心问题](#1-跨语言-abi-的核心问题)
- [2. 修复轮次总览](#2-修复轮次总览)
- [3. 基础库修复（C NIF + Erlang）](#3-基础库修复c-nif--erlang)
- [4. 构建链修复](#4-构建链修复)
- [5. 测试套件修复](#5-测试套件修复)
- [6. 分层原则](#6-分层原则)
- [7. 关键经验教训](#7-关键经验教训)
- [8. 未完成项与后续计划](#8-未完成项与后续计划)
- [附录 A：文件变更清单](#附录-a文件变更清单)
- [附录 B：环境信息](#附录-b环境信息)

---

## 0. 起点与目标

### 0.1 用户原始需求

对以下 4 个 Erlang 生成器文件进行统一修正：

```
erlang_abi_call_generator_tool.pas
erlang_abi_service_generator_tool.pas
erlang_abi_test_generator_tool.pas
erlang_abi_test_setup_generator_tool.pas
```

硬性约束：

1. 代码全英文，对话中文。
2. 移除全部注释。
3. 移除 `.md` 生成函数。
4. 单引号用 `#39` 转义。
5. **ABI 接口必须跨语言互通互调**。
6. 测试参考 C++/Pascal 模式：开 service + call，跑通即通过。
7. 发现基础库 bug 立即提出，不能掩盖。
8. LingoFuse 必须采用「先 ABI、后高级接口」的设计模型。

### 0.2 关键日志暴露的现状

**日志 A（Pascal call ↔ Erlang service）**：

```
client UID = 7B227032705F6E616D65223A22222C227569645F686578223A22374643354344
NoParamFunc(app call) failed: "ok":true,"result":0}
MultiLineComment(app call) failed: "error":"{invalid_byte,42}","ok":false}
```

**日志 B（Erlang call ↔ Pascal service）**：

```
NoParamFunc(app sync) PASS
uid sync SKIP (timeout)
p2p sync SKIP (timeout)
```

**日志 C（diag_full.ps1）**：

```
D:\...\priv\lingofuse_nif.dll
    size = 0 bytes
    LOAD : FAIL  err=0
```

---

## 1. 跨语言 ABI 的核心问题

### 1.1 问题分层

本次暴露出**三层**问题，各自独立：

| 层 | 问题 | 影响 |
|---|---|---|
| **生成器层** | Erlang 生成器在 ABI 层用 JSON，Pascal/C++ 生成器用二进制 | Pascal ↔ Erlang 互不通 |
| **NIF 基础库层** | `read_and_strip_nul` 无条件剥末尾 `#0`，破坏二进制 ABI | int32 / int64 参数末位字节被吞 |
| **构建链层** | `file:copy` 在 junction 上自杀 | 83005 字节 DLL → 0 字节 |

### 1.2 三个层的根因证据

**生成器层**：`erlang_abi_service_generator_tool.pas` 的 `handle_call_*` 用 `lingofuse_json:loads(Payload)`，服务端回 `lingofuse_json:dumps(#{ok=>true,...})` 加 `#0`。Pascal 侧 C ABI `[status][result]` 二进制，读到 `{`（0x7B）判定 `status=ERROR`。

**NIF 层**：`lingofuse_nif.c` 的 `read_and_strip_nul` 在 `dispatch_to_process` 和 `lf_async_result_cb` 中被使用，逻辑是「读完整 buffer，若末尾是 0x00 就 strip 一字节」。对于 `int32 42`（`2A 00 00 00`）→ strip 后变 3 字节 → 生成器解码失败。

**构建链层**：rebar3 在 Windows 上用 junction 实现 `_build/test/lib/lingofuse/priv` → `../../../../priv`。Erlang `file:copy(Src, Dst)` 打开 `Dst`（write 模式）时截断为 0，而 `Dst` 和 `Src` 是同一文件 → 自杀。

---

## 2. 修复轮次总览

| Round | 文件 | 改动 |
|:---:|---|---|
| **1** | `lingofuse_nif.c` | 删 `read_and_strip_nul`，新增 `read_input_payload`（不 strip） |
| **2** | `lingofuse.erl` | 新增 24 个类型化 ABI 读写原语（`write_int32/2` … `read_string/1`） |
| **3** | `lingofuse_json.erl` | 降级为用户层工具，`read_nul_framed` 转发到 `lingofuse:read_string_bytes/1` |
| **4** | `lingofuse_nif.erl` / `lingofuse_app.erl` / `lingofuse_sup.erl` | 移除注释，全英文 |
| **4.1** | `c_src/build.escript` | `-shared -static`（失败） |
| **4.2** | `c_src/build.escript` | `-shared -static-libgcc`（失败） |
| **4.3** | `c_src/build.escript` | 打印 `.o` / `.dll` 尺寸 + `-I` 拆分 |
| **4.4** | `c_src/build.escript` | `link_gcc` 前 `file:delete(Target)` + `copy_to_build_dir` 加 `same_stat` 判断 |
| **5** | `lingofuse_network_tests.erl` | 修 `unique_fake_uid`、instantiator 的 `(_) -> []`、`t_p2p_register_*` 唯一化 |
| **6** | `lingofuse_json.erl` | `loads/1` 剥离末尾 `#0`（容忍 wire framing） |
| **待定** | `lingofuse_abi_tests` / `json_tests` / `sync_tests` / `async_tests` / `identity_tests` / `options_tests` | 仅移除注释 |
| **待定** | 4 个生成器 | 改用 `lingofuse:read_int32/1` 等类型化原语 |

---

## 3. 基础库修复（C NIF + Erlang）

### 3.1 `lingofuse_nif.c` —— 删 `read_and_strip_nul`

**旧实现**：

```c
static int read_and_strip_nul(ErlNifEnv* env,
                              TDataHnd hnd,
                              ERL_NIF_TERM* out_term)
{
    // ... 读到完整 buffer ...
    if (bin.data[size - 1] == 0) {
        size_t new_size = (size_t)(size - 1);
        // strip 掉末尾字节
    }
    // ...
}
```

**为什么错**：NIF 层无权替用户决定 strip。`(int32 42)` 的 wire 是 `2A 00 00 00`，末尾 0x00 是 int32 的高位字节，不是字符串 terminator。

**修复**：改为 `read_input_payload`，**保留完整字节**，仅在 `LF_SetPos` 后按原样返回。

**影响面审计**：

| 场景 | 旧行为 | 新行为 |
|------|-------|-------|
| `(string "abc")` | `61 62 63 00` → `61 62 63` | `61 62 63 00`（用户层 `loads/1` 剥离） |
| `(int32 42)` | `2A 00 00 00` → `2A 00 00`（错） | `2A 00 00 00`（正确） |
| `(int32 1, int32 2)` | 少 1 字节 | 完整 8 字节 |
| `(string "abc")` + `#0` 结尾 | `61 62 63` | `61 62 63 00`（用户层处理） |

**关键断言**：**C ABI 层不 strip，是跨语言二进制互通的前提**。

### 3.2 `lingofuse.erl` —— 24 个类型化 ABI 原语

**新增 API（12 写 + 12 读）**：

```erlang
-spec write_int8(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint8(data_handle(), integer()) -> ok | abi_io_error().
-spec write_int16(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint16(data_handle(), integer()) -> ok | abi_io_error().
-spec write_int32(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint32(data_handle(), integer()) -> ok | abi_io_error().
-spec write_int64(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint64(data_handle(), integer()) -> ok | abi_io_error().
-spec write_single(data_handle(), float() | integer()) -> ok | abi_io_error().
-spec write_double(data_handle(), float() | integer()) -> ok | abi_io_error().
-spec write_string(data_handle(), binary()) -> ok | abi_io_error().
-spec write_string_bytes(data_handle(), binary()) -> ok | abi_io_error().

-spec read_int8(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint8(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_int16(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint16(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_int32(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint32(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_int64(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint64(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_single(data_handle()) -> {ok, float()} | abi_io_error().
-spec read_double(data_handle()) -> {ok, float()} | abi_io_error().
-spec read_string(data_handle()) -> {ok, binary()} | abi_io_error().
-spec read_string_bytes(data_handle()) -> {ok, binary()} | abi_io_error().
```

**核心实现要点**：

- 全部走小端字节序（`little-signed` / `little-unsigned` / `little-float`）
- 读走 `read_buffer/2` + 二进制模式匹配，字节数不足返回 `{error, truncated}`
- `read_string/1` = `read_string_bytes/1`：扫描 `#0`，找到后 `set_pos(Hnd, Pos + NulPos + 1)`；无 `#0` 时读全部剩余
- `write_string/2` = `write_string_bytes/2`：`<<Bin/binary, 0>>` 追加 `#0`

**导出类型**：

```erlang
-type abi_io_error() ::
    {error, lf_not_loaded}
    | {error, short_write}
    | {error, truncated}
    | {error, eof}
    | {error, no_nul_terminator}
    | {error, term()}.
```

**设计意图**：生成器（Round 5 待交付）将用这些原语替代 JSON wire。

### 3.3 `lingofuse_json.erl` —— 降级 + 容忍 wire framing

**定位变更**：从「ABI 层的一部分」降级为「用户层便利工具」。

**核心修复**（Round 6）：

```erlang
-spec loads(binary()) -> term().
loads(Bin) when is_binary(Bin) ->
    json:decode(strip_trailing_nul(Bin)).

strip_trailing_nul(<<>>) ->
    <<>>;
strip_trailing_nul(Bin) ->
    case binary:last(Bin) of
        0 -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.
```

**为什么需要**：NIF 层不再 strip（3.1），所以 `t_call_no_identity/0` 中 `Payload = <<"{\"k\":1}", 0>>`，`json:decode` 遇 `#0` 抛 `{invalid_byte, 0}`。

**对称性检查**：

| 函数 | 行为 |
|------|------|
| `dumps/1` | 不加 `#0` |
| `write_json/2` | 加 `#0`（通过 `write_string_bytes/2`） |
| `loads/1` | **容忍 `#0`**（本轮修复） |
| `read_json/1` | 靠 `read_string_bytes/1` 剥离 |
| `read_json_or_bytes/1` | 同上 |

**`loads/1` 是这套对称里唯一的缺口，本轮已补齐**。

**对 `t_loads_invalid/0` 的影响**：`loads(<<"not json">>)` 无 `#0`，`strip_trailing_nul` 不触发，`json:decode` 仍抛异常 → **测试仍 PASS**（未破坏）。

---

## 4. 构建链修复

### 4.1 问题现象

```
[build] output file size:
         d:/.../priv/lingofuse_nif.dll       83005 bytes
[build] copied to     : d:/.../_build/test/lib/lingofuse/priv/lingofuse_nif.dll
[build] OK

PS> ls .\priv\
-a---   ...   0 lingofuse_nif.dll     ← 0 字节！
```

`LoadLibraryA` 返回 NULL + `GetLastError=0` → DllMain 返回 FALSE。

### 4.2 诊断过程（三次迭代）

**Round 4.1**：`-shared -static`

- 失败。`-static` 全局静态链接改变 PE 结构，Windows Loader 无法加载。

**Round 4.2**：`-shared -static-libgcc`

- 失败。仍不是 PE 结构问题。

**Round 4.3**：新增 `.o` / `.dll` 尺寸打印 + `-I` 拆分

- 暴露关键事实：**link 后 83005 字节，但 `priv/lingofuse_nif.dll` 是 0 字节**。

**Round 4.4**：`same_stat` 检查 + 三处防线

- 最终定位：**`file:copy` 自杀**。

### 4.3 `file:copy` 自杀机制

rebar3 在 Windows 上用 junction 实现 `_build/test/lib/lingofuse/priv` → `../../../../priv`：

```
_build/test/lib/lingofuse/priv/lingofuse_nif.dll
         ≡  （同一文件）
priv/lingofuse_nif.dll
```

Erlang `file:copy(Src, Dst)` 内部：

```erlang
{ok, Fd1} = file:open(Src, [read, raw, binary]),    %% Src = 83005 字节
{ok, Fd2} = file:open(Dst, [write, raw, binary]),   %% ← 打开时截断为 0
copy_loop(Fd1, Fd2)                                  %% 读 0 字节 → 写 0 字节
```

因为 `Dst` 和 `Src` 是同一文件，**`Src` 也被截断成 0**。

### 4.4 修复方案

**3 处防线**：

**防线 1：`link_gcc` 前先删 `Target`**

```erlang
link_gcc(CC, Objs, Target) ->
    _ = file:delete(Target),
    Args = link_flags_gcc() ++ ["-o", Target | Objs],
    run(CC, Args).
```

避免 0 字节残留影响 gcc `-o` 行为。

**防线 2：`copy_to_build_dir` 加 `same_stat` 判断**

```erlang
maybe_copy(Target, Dest) ->
    case filelib:is_dir(filename:dirname(Dest)) of
        false -> info("skip (no dir)", filename:dirname(Dest));
        true ->
            case same_stat(Target, Dest) of
                true ->
                    info("skip (same file)", Dest);
                false ->
                    case file:copy(Target, Dest) of
                        {ok, _} -> info("copied to", Dest);
                        {error, R} -> io:format(standard_error, "...")
                    end
            end
    end.

same_stat(P1, P2) ->
    case {file:read_file_info(P1), file:read_file_info(P2)} of
        {{ok, I1}, {ok, I2}} ->
            I1#file_info.size =:= I2#file_info.size andalso
            I1#file_info.mtime =:= I2#file_info.mtime;
        _ -> false
    end.
```

`Dest` 与 `Target` 已是同一文件（junction/symlink）时**跳过 copy**。

**防线 3：build 完成后两次尺寸校验**

```erlang
%% build 后
case filelib:file_size(Target) of
    0 -> err("post-build check: ~s is 0 bytes", [Target]), halt(3);
    _ -> ok
end,

copy_to_build_dir(RootDir, Target),

%% copy 后
case filelib:file_size(Target) of
    0 -> err("post-copy check: ~s is 0 bytes (copy truncated it)", [Target]), halt(4);
    _ -> ok
end,
```

**任何未来截断路径都会硬失败**，不会静默产出 0 字节 DLL。

### 4.5 `build.ps1` —— `Invoke-Step` 输出隐藏修复

**问题**：`build.ps1` 看不到 rebar3 输出。

**根因**：

```powershell
$code = Invoke-Step -Label 'rebar3 compile' -Body { & $Rebar3 compile }
```

`Invoke-Step` 内部 `& $Body` 的输出被收集到函数返回值 → 赋给 `$code` 后不再显示。

**修复**：`& $Body | Out-Host`

```powershell
try {
    & $Body | Out-Host
    if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
} catch { ... }
```

`| Out-Host` 强制 stdout 走控制台，**不影响 `$LASTEXITCODE`**（PowerShell 自动变量跟踪 native command）。

---

## 5. 测试套件修复

### 5.1 `lingofuse_network_tests.erl` —— 5 处修复

**修复 1：`unique_fake_uid/0`**

旧：

```erlang
unique_fake_uid() ->
    N = erlang:unique_integer([positive, monotonic]),
    Seed = crypto:hash(sha256,
                       <<(os:getpid())/binary,      %% ← os:getpid() 返回 string()
                         (integer_to_binary(N))/binary,
                         (erlang:system_time(nanosecond))/integer>>),
    Seed.
```

`os:getpid()` 返回 `string()`，不能直接 `/binary` → `{badarg, {1, binary, type, "11536"}}`。

新：

```erlang
unique_fake_uid() ->
    crypto:strong_rand_bytes(32).
```

直接 32 字节随机，不依赖任何类型转换。

**修复 2：3 个 instantiator 加 `(_) -> []` 分支**

旧：

```erlang
uid_addressing_test_() ->
    {setup,
     fun setup_uid_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) -> [ ... ] end}.       %% ← Ctx = skip 时 maps:get 崩溃
```

`ensure_native_or_skip` 返回 `skip` 时，`Ctx = skip`，`maps:get(uid, skip)` → `{badmap, skip}`。

新：

```erlang
uid_addressing_test_() ->
    {setup,
     fun setup_uid_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) when is_map(Ctx) -> [ ... ];
        (_) -> []
     end}.
```

**修复 3：`t_p2p_register_*` API 名唯一化**

旧：

```erlang
Api = <<"eunit_p2p_call_api">>,
```

`LF_Shutdown` 后 P2P 注册表若未清空，重跑会重名失败。

新：

```erlang
Api = <<"eunit_p2p_call_api_", (unique_api_suffix())/binary>>,

unique_api_suffix() ->
    iolist_to_binary(
      io_lib:format("~s_~p",
                    [os:getpid(),
                     erlang:unique_integer([positive, monotonic])])).
```

**修复 4：`flush_lf_messages` 覆盖 4-tuple / 5-tuple**

旧：

```erlang
flush_lf_messages() ->
    receive
        {lf_call, _, _, _}      -> flush_lf_messages();
        {lf_call, _, _}         -> flush_lf_messages();
        {lf_notify, _, _}       -> flush_lf_messages();   %% 只匹配 3-tuple
        {lf_notify, _}          -> flush_lf_messages();
        ...
    after 0 -> ok
    end.
```

新：

```erlang
flush_lf_messages() ->
    receive
        {lf_call, _, _}              -> flush_lf_messages();
        {lf_call, _, _, _}           -> flush_lf_messages();
        {lf_call, _, _, _, _}        -> flush_lf_messages();
        {lf_notify, _}               -> flush_lf_messages();
        {lf_notify, _, _}            -> flush_lf_messages();
        {lf_notify, _, _, _}         -> flush_lf_messages();   %% 新增
        {lf_p2p_call, _, _}          -> flush_lf_messages();
        {lf_p2p_call, _, _, _}       -> flush_lf_messages();
        {lf_p2p_call, _, _, _, _}    -> flush_lf_messages();
        {lf_p2p_notify, _}           -> flush_lf_messages();
        {lf_p2p_notify, _, _}        -> flush_lf_messages();
        {lf_p2p_notify, _, _, _}     -> flush_lf_messages();   %% 新增
        {lf_async_result, _, _}      -> flush_lf_messages();
        {lf_connect, _}              -> flush_lf_messages();
        {lf_disconnect, _}           -> flush_lf_messages()
    after 0 -> ok
    end.
```

**修复 5：`t_p2p_register_*` 移除 `%%` 注释**

纯格式统一。

### 5.2 `lingofuse_identity_tests.erl` —— 本轮修复

**问题**：`t_call_no_identity/0` 的 `?assertMatch(#{<<"k">> := 1}, lingofuse_json:loads(Payload))`。

`Payload` = `<<"{\"k\":1}", 0>>`（NIF 层不再 strip）。`json:decode(<<"{\"k\":1}", 0>>)` → `{invalid_byte, 0}`。

**根因**：`lingofuse_json:loads/1` 未剥离 `#0`。

**修复**：3.3 节的 `strip_trailing_nul/1`。

**影响面审计**：

| 测试 | 影响 | 结论 |
|------|------|------|
| `t_call_no_identity` | 本轮修复目标 | ✅ 从 FAIL → PASS |
| `t_call_with_identity` | 检查 `Identity` map，不 `loads` | ✅ 无影响 |
| `t_notify_no_identity` | 只 `?assert(is_binary(Payload))` | ✅ 无影响 |
| `t_notify_with_identity` | 检查 `Identity` map | ✅ 无影响 |
| `t_p2p_register_unregister` | 不 `loads` | ✅ 无影响 |

### 5.3 `lingofuse_json_tests.erl` 影响面

`loads/1` 的 `strip_trailing_nul` 对该套件的影响：

| 测试 | 输入 | 结论 |
|------|------|------|
| `t_loads_object` | `<<"{\"a\":1}">>`（无 `#0`） | ✅ 无影响 |
| `t_loads_array` | `<<"[1,2,3]">>` | ✅ 无影响 |
| `t_loads_null` | `<<"null">>` | ✅ 无影响 |
| `t_loads_booleans` | `<<"true">>` / `<<"false">>` | ✅ 无影响 |
| `t_loads_invalid` | `<<"not json">>`（无 `#0`） | ✅ 仍失败（`strip_trailing_nul` 不触发） |

**结论**：本轮 `loads/1` 修复**不破坏**任何现有测试。

---

## 6. 分层原则

LingoFuse 的三层 `#0` 处理必须严格分工：

| 层 | 责任 | 例子 |
|---|------|------|
| **C ABI（NIF）** | **不 strip**，返回 wire 原始字节 | `read_input_payload` |
| **类型化原语**（`lingofuse:read_*`） | **按类型解析**，字符串扫 `#0` 剥离 | `read_string/1` / `read_int32/1` |
| **用户层**（`lingofuse_json:loads/1`） | **容忍 wire framing**，剥末尾 `#0` | `strip_trailing_nul/1` |

**任何一层多做或少做**，就会出现本轮这种 `{invalid_byte, 0}` 或 `strip 掉 int32 高位字节`。

### 6.1 后续生成器修改的硬性规则

修改 `erlang_abi_service_generator_tool.pas` / `erlang_abi_call_generator_tool.pas` 时：

**必须**：

- 用 `lingofuse:read_int32/1` 等类型化原语（`read_*` 已按类型处理 `#0`）
- 用 `lingofuse:write_int32/2` 等类型化原语（`write_*` 保持二进制）
- 输出格式对齐 `cpp_abi_service_generator_tool.pas` 的 `Safe_Write_Scalar` / `Safe_Write_String` / `Safe_Write_Error`：
  - 成功：`<<0, ResultBytes/binary>>`
  - 失败：`<<255, ErrBytes/binary, 0>>`

**禁止**：

- 用 `lingofuse_json:loads` / `dumps` 处理 ABI 参数
- 用 `read_buffer` 手拼二进制（易错，且绕过类型化原语的边界检查）

### 6.2 跨语言 ABI 契约（三层通用）

| 维度 | 契约 |
|------|------|
| 字符串 wire | `[UTF-8 bytes][#0]` |
| 整数 wire | little-endian 定长（int32=4B，int64=8B） |
| 浮点 wire | little-endian IEEE 754（single=4B，double=8B） |
| 响应 status | `0x00 = OK` / `0xFF = ERROR` |
| 错误消息 | `[status 0xFF][error UTF-8][#0]` |
| UID 传递 | 32 字节 raw（不是 hex 字符串） |

---

## 7. 关键经验教训

### 7.1 「看起来像库 bug」实则是调用方 bug（三次）

| # | 表面现象 | 实际原因 |
|:-:|---|---|
| 1 | `LINGOFUSE_SKIP_NIF=0` 仍 skip build | `skip_requested/0` 未识别 `"0"` 为 false |
| 2 | 4 个 worker 崩溃 `{badmatch,{ok,4}}` | `lingofuse:write_buffer/2` 返回 `{ok, N}` 不是 `ok` |
| 3 | UID/P2PName 全 timeout 判为"self-client 架构问题" | `FUID_Pool` 注册有 race（~3s 传播），测试未等 |

### 7.2 分层诊断顺序

**正确的排查顺序**：

1. **测试代码本身是否有 bug**（`flush_lf_messages`、`wait_until` 时序、返回值匹配）
2. **构建脚本是否正确**（`LINGOFUSE_SKIP_NIF`、DLL 复制、junction）
3. **NIF 层是否有 bug**（`sync_wait`、`sync_deliver`、`read_and_strip_nul`）
4. **核心库是否有 bug**（`FUID_Pool`、`cmd_UID_Call`、`Find_Local_UID_App`）

**本次问题**横跨 1、2、3 三层，但**不是核心库问题**。

### 7.3 关于「不 strip 的 ABI」

**旧设计**（错误）：NIF 层帮用户 strip `#0`，让 JSON 用户方便。

**新设计**（正确）：C ABI 层**完全不干预字节**，`#0` 的处理由**消费方**按 wire 契约自行决定。

**理由**：

- 同一 wire 可能承载 JSON（用户层 `loads` 剥离）、二进制（`read_int32` 按类型解析）、原始字节（`read_buffer` 保留原样）。
- NIF 层无法知道消费方意图。
- **ABI 层必须保持零语义**。

### 7.4 关于 junction

**Windows 上的 junction** 是 rebar3 的默认实现。任何 `file:copy` 到 junction 路径的操作都可能自杀。

**通用规则**：

- 复制前用 `file:read_file_info` 比较 `size` + `mtime`，相同则跳过。
- 或复制到临时文件，再 `file:rename` 原子替换。

### 7.5 关于测试的 `flush_lf_messages`

消息 tuple 形态取决于 `with_identity` 开关 × call/notify × app/p2p，共 **2×2×2×2 = 16 种**：

| 形态 | 3-tuple | 4-tuple | 5-tuple |
|------|:---:|:---:|:---:|
| `lf_call` 无 Ref 无 Identity | ✅ | | |
| `lf_call` 有 Ref 无 Identity | | ✅ | |
| `lf_call` 有 Ref 有 Identity | | | ✅ |
| `lf_call` 无 Ref 有 Identity | | ✅ | |
| `lf_notify` 无 Identity | ✅ | | |
| `lf_notify` 有 Identity | | ✅ | |
| `lf_p2p_call` 同上 4 种 | 同 app 版本 | | |
| `lf_p2p_notify` 同上 2 种 | 同 app 版本 | | |

**`flush_lf_messages` 必须覆盖全部 16 种**，否则残留消息污染下一次测试。

---

## 8. 未完成项与后续计划

### 8.1 待交付文件（仅移除注释）

| 文件 | 状态 |
|------|:---:|
| `lingofuse_abi_tests.erl` | 待交付 |
| `lingofuse_json_tests.erl` | 待交付 |
| `lingofuse_sync_tests.erl` | 待交付 |
| `lingofuse_async_tests.erl` | 待交付 |
| `lingofuse_options_tests.erl` | 待交付 |
| `lingofuse_identity_tests.erl` | 待交付 |

### 8.2 待交付生成器（核心工作）

| 文件 | 关键改动 |
|------|---------|
| `erlang_abi_service_generator_tool.pas` | 用 `lingofuse:read_*` / `write_*` 替代 JSON；wire 对齐 `Safe_Write_*` |
| `erlang_abi_call_generator_tool.pas` | 消费 service 的 wire 契约 |
| `erlang_abi_test_setup_generator_tool.pas` | 仅移除注释、全英文 |
| `erlang_abi_test_generator_tool.pas` | 大文件，依赖前两者 |

### 8.3 生成器 wire 契约（预定）

**服务端 `handle_call_*`**：

```erlang
handle_call_Api(Ref, PayloadBin, _Identity) ->
    case decode_params(PayloadBin) of
        {ok, [P1, P2, ...]} ->
            try
                Result = internal_call_Api(P1, P2, ...),
                reply_ok(Ref, encode_result(Result))
            catch
                _:_ -> reply_error(Ref, <<"internal error">>)
            end;
        {error, Reason} ->
            reply_error(Ref, format_reason(Reason))
    end.

decode_params(Bin) ->
    %% 用 lingofuse:read_int32/1 等类型化原语
    ...
```

**客户端 `lf_do_sync_call`**：

```erlang
lf_do_sync_call(AppName, Api, Args) ->
    {ok, Data} = lingofuse:create_data(Api),
    try
        ok = encode_params(Data, Args),
        {ok, ResHnd} = lingofuse:call(AppName, Data, ?ABI_TIMEOUT_MS),
        try decode_response(ResHnd)
        after lingofuse:free_data(ResHnd) end
    after lingofuse:free_data(Data) end.
```

**关键**：**不出现 `lingofuse_json`**。

### 8.4 验证门槛

- Pascal service ↔ Erlang call：`app` / `uid` / `p2p` 全 PASS
- Erlang service ↔ Pascal call：`MultiLineComment(int32)` 等二进制参数 API 全 PASS
- Erlang service ↔ Erlang call：全 PASS
- Pascal service ↔ C++ call：保持不变（回归测试）

---

## 附录 A：文件变更清单

### A.1 已修改（本次工作）

| 文件 | 变更 |
|------|------|
| `c_src/lingofuse_nif.c` | 删 `read_and_strip_nul` → `read_input_payload`；移除诊断 fprintf |
| `src/lingofuse.erl` | 新增 24 个类型化原语；移除 `%%` 注释 |
| `src/lingofuse_json.erl` | `loads/1` 加 `strip_trailing_nul`；`read_nul_framed` 转发到 `read_string_bytes/1` |
| `src/lingofuse_nif.erl` | 移除注释 |
| `src/lingofuse_app.erl` | 移除注释 |
| `src/lingofuse_sup.erl` | 移除注释 |
| `c_src/build.escript` | 尺寸打印 + `same_stat` 判断 + `file:delete` 防线 + `halt(3)/(4)` 硬失败 |
| `build.ps1` | `Invoke-Step` 用 `| Out-Host` |
| `test/lingofuse_network_tests.erl` | 5 处修复（见 §5.1） |

### A.2 未修改（保持原样）

| 文件 | 状态 |
|------|:---:|
| `test/lingofuse_abi_tests.erl` | 待交付（仅移除注释） |
| `test/lingofuse_json_tests.erl` | 待交付（仅移除注释） |
| `test/lingofuse_sync_tests.erl` | 待交付（仅移除注释） |
| `test/lingofuse_async_tests.erl` | 待交付（补 flush + 移除注释） |
| `test/lingofuse_identity_tests.erl` | 待交付（仅移除注释） |
| `test/lingofuse_options_tests.erl` | 待交付（仅移除注释） |
| `check.ps1` / `clean.ps1` / `check_env.ps1` | 未修改 |

---

## 附录 B：环境信息

**操作系统**：Windows 10.0.20348.0 (X64)

**工具链**：

| 工具 | 版本 |
|------|------|
| Erlang/OTP | 29 |
| erts | 17.1 |
| PowerShell | 7.6.6 |
| .NET | 10.0.12 |
| rebar3 | 本地 `rebar3.cmd` |
| gcc | MinGW-w64 16.1.0 (`x86_64-win32-seh-rev1`) |
| clang | LLVM 23.1.2 |
| LingoFuse64.dll | 2924544 bytes (2026-10-24) |
| z_ipc_64.dll | 258048 bytes (2026-08-26) |

**关键环境变量**：

| 变量 | 用途 |
|------|------|
| `LINGOFUSE_SKIP_NIF` | 跳过 NIF 编译（`0`/`false`/`no`/`off` 视为不跳过） |
| `LINGOFUSE_NIF_DEBUG` | 开启 NIF 诊断 fprintf（已移除，见 §A.1） |
| `LINGOFUSE_REQUIRE_NATIVE` | 原生库缺失时硬失败（CI 用） |
| `LINGOFUSE_CC` | 指定 C 编译器（本轮新增） |

---

## 版本

- **v1** — 截至 Round 6 完成（`lingofuse_json:loads/1` 修复 `#0` 容忍）
- 后续生成器修改完成后追加 v2
