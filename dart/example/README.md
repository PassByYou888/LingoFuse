# LingoFuse Dart Binding — Examples

> 本目录是 LingoFuse Dart 绑定的**示例索引与上手文档**。
>
> 与主 `README.md`（讲"如何编译、如何集成、API 是什么"）不同，本文件专注
> **"如何跑起来、如何验证、如何写自己的"**。
>
> **阅读建议**：先看主 `README.md` 的[快速开始](../README.md#快速开始最小示例)一节，
> 确认框架能启动；再回到本文件，选择与你的场景匹配的示例。

---

## 目录

- [这些示例从哪里来](#这些示例从哪里来)
- [示例清单](#示例清单)
- [运行前置条件](#运行前置条件)
- [通用运行流程](#通用运行流程)
- [示例详解](#示例详解)
  - [phase4 — C 桥接层探针](#phase4--c-桥接层探针)
  - [phase5 — Framework 层探针](#phase5--framework-层探针)
  - [phase6 — 现代 async API 探针](#phase6--现代-async-api-探针)
  - [phase7 — 三套寻址探针](#phase7--三套寻址探针)
  - [hello_async — 教学 demo](#hello_async--教学-demo)
- [如何写自己的示例（PoC）](#如何写自己的示例poc)
- [项目结构约定](#项目结构约定)
- [常见问题](#常见问题)

---

## 这些示例从哪里来

LingoFuse Dart 绑定的**官方示例全部位于 `bin/` 目录**，与 `test/` 下的单元/集成
测试并列。这样设计的原因是：

1. **示例即测试**：`bin/` 下的每个探针都是**自包含的端到端验证**，既能在
   开发过程中回归，也能作为用户的上手模板。
2. **不额外维护两份代码**：如果示例和测试分离，容易发生"测试通过但示例过时"
   的漂移。
3. **每个示例独立可运行**：`dart run bin/xxx.dart` 即可跑通，无隐藏依赖。

本目录（`example/`）作为**索引和阅读入口**存在，本身不放置额外的源代码。
未来如果出现不适合放在 `bin/` 的复杂场景（例如需要多个独立进程协作的
demo），会以子目录的形式放在这里。

---

## 示例清单

| 文件 | 类型 | 运行前置 | 覆盖内容 | 通过标准 |
|---|---|---|---|---|
| `bin/lf_probe.dart` | 探针 | 仅有 DLL | 最小 FFI 加载验证 | 全部 `[OK]` |
| `bin/phase1_test.dart` | 探针 | 仅有 DLL | DataHandle 基础 I/O | `failed: 0` |
| `bin/phase2_test.dart` | 探针 | 仅有 DLL | 网络准备 + caller 侧 | `failed: 0` |
| `bin/phase3_test.dart` | 探针 | 完整框架 | Server + 远程调用 | 全部 `[OK]` |
| `bin/phase4_bridge_probe.dart` | 探针 | 桥接 DLL | C 桥接层 ABI | `passed: 21` |
| `bin/phase5_framework_test.dart` | 探针 | 桥接 DLL | 类型化 option + 参数校验 | `passed: 28` |
| `bin/phase6_async_probe.dart` | 探针 | 完整框架 | 现代 async API | `passed: 31` |
| `bin/phase7_addressing_probe.dart` | 探针 | 完整框架 | 三套寻址 | `passed: 25` |
| `bin/hello_async.dart` | 教学 demo | 完整框架 | 五种 async 场景 | 输出完整文本 |

**术语说明**：

- **仅有 DLL**：只需 `LingoFuse64.dll` 可被 OS loader 找到；不需要启动框架。
- **桥接 DLL**：额外需要 `lf_dart_bridge.dll`；不需要启动框架。
- **完整框架**：需要启动 LingoFuse 框架（`Framework.prepareDone()`）。

---

## 运行前置条件

按主 `README.md` 的[环境准备](../README.md#环境准备)一节完成，重点确认三项：

```powershell
# 1. Dart SDK 可用
dart --version
# 应输出: Dart SDK version: 3.6.x (stable) ...

# 2. LingoFuse 核心库可被找到
$env:PATH -split ';' | Select-String 'LingoFuse'
# 应输出包含: D:\CoreLibrary\LingoFuse\Binary

# 3. 桥接 DLL 已编译
Test-Path D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll
# 应输出: True
```

如果第 3 项为 `False`，按主 `README.md` 的[编译 C 桥接 DLL](../README.md#编译-c-桥接-dll)
一节重新编译。

---

## 通用运行流程

所有示例的运行方式一致：

```powershell
cd D:\CoreLibrary\LingoFuse\dart
dart run bin\<示例名>.dart
```

**示例**：

```powershell
dart run bin\phase4_bridge_probe.dart
dart run bin\hello_async.dart
```

**退出码约定**：

- 探针（`phase4` / `phase5` / `phase6` / `phase7`）：
  - 全部通过 → 退出码 `0`
  - 有任何失败 → 退出码 `1`，并在末尾输出 `=== Summary ===` 与失败数量
- `hello_async`：始终退出码 `0`（它是演示，不是验证）。

**输出约定**：

探针输出分三段：

```
=== Phase N <description> ===

[Setup] ...            ← 前置：启动桥接 / 声明组名 / 启动框架
[1] ...                ← 逐项验证，每项输出 [OK] / [FAIL]
[2] ...
[Cleanup] ...          ← 释放资源

=== Summary ===
  passed: N
  failed: 0
```

任何 `[FAIL]` 行都会附带诊断信息（实际值、异常类型等）。

---

## 示例详解

### phase4 — C 桥接层探针

**文件**：`bin/phase4_bridge_probe.dart`

**验证目标**：`lf_dart_bridge.dll` 的 C ABI 是否正确。

**运行**：

```powershell
dart run bin\phase4_bridge_probe.dart
```

**覆盖内容**：

| 段 | 内容 |
|---|---|
| `[1]` | `BridgeHost.start()` |
| `[2]` | `lfBridgeVersion` / `lfBridgeIsInitialized` |
| `[3]` | `lfBridgeCreateData` / `WriteBuffer` / `ReadBuffer` / `GetSize` / `FreeData` |
| `[4]` | `lfBridgeGetP2PUid` / `GetP2PName` 在**自建句柄**上的行为（应返回 32 零字节 + 空串） |
| `[5]` | `lfBridgeWriteUid` / `ReadUid` 的字节精确往返 |
| `[6]` | `lfBridgeFreeData` |
| `[7]` | `lfBridgeStatsJson` |
| `[8]` | `BridgeHost.stop()` |

**它验证了什么**：

- **Dart FFI 与 C 桥接的类型映射**正确（Pointer、Int32、Int64、Uint8*）。
- **UID 二进制 I/O** 在桥接层无损（因为 Dart FFI 无法直接传 32 字节结构体，必须
  经桥接重打包）。
- **P2P 身份在非 input 句柄上返回零值**，符合 LF 契约。

**典型失败**：

- `[FAIL] create_data returns non-null` → 桥接 DLL 未正确编译或未加载。
- `[FAIL] self-created handle yields 32 zero bytes` → 桥接层的 `lf_bridge_get_p2p_uid`
  实现有问题（不应把 P2P 身份的读取限制搞错）。

---

### phase5 — Framework 层探针

**文件**：`bin/phase5_framework_test.dart`

**验证目标**：`Framework` 的类型化选项接口与参数校验。

**运行**：

```powershell
dart run bin\phase5_framework_test.dart
```

**覆盖内容**：

| 段 | 内容 |
|---|---|
| `[1]` | 16 个 `setOpt*` 完整调用（无异常） |
| `[2]` | 类型化 getter 在**桥接未启动**时返回安全回退值（`false` / `0` / `""`） |
| `[3]` | UID 长度校验与桥接状态**独立**（31/33 字节 → `RangeError`） |
| `[4]` | 桥接未启动时，桥接方法抛 `StateError`（含明确操作提示） |
| `[5]` | `LingoFuseStatus.checkUid` 的长度校验与桥接状态**独立** |
| `[6]` | `LfIo.tryReadJson` 在三种输入下的行为（合法 / 非法 / 空） |
| `[7]` | 对不存在目标的 `Framework.call` 返回 size=0 句柄；`tryCall` 返回 null |

**它验证了什么**：

- **参数校验与运行时状态解耦**——即使桥接未启动，UID 长度错误也会在
  FFI 调用前被拒；这让用户能在**不启动框架**的环境中验证自己代码的参数正确性。
- **类型化 getter 是"永不抛异常"的安全接口**——`getOptQuiet()` 在桥接未启动时
  返回 `false` 而不是抛 `StateError`。
- **`tryCall` 的 null 契约**——`tryCall` 在超时/无目标时返回 `null` 而非 size=0 句柄。

**典型失败**：

- `[FAIL] all 16 typed setters completed` → 某个 option 名拼写错误（LF 的 option
  名是大小写不敏感但**拼写敏感**的；未知 option 被静默忽略，不报错）。
- `[FAIL] Framework.getOption returns "" when bridge is down` → 桥接状态探测有 bug。

---

### phase6 — 现代 async API 探针

**文件**：`bin/phase6_async_probe.dart`

**验证目标**：`Target` / `CallPromise` / `AsyncBridge` 的完整 async 语义。

**运行**：

```powershell
dart run bin\phase6_async_probe.dart
```

**覆盖内容**：

| 段 | 内容 | 使用 `P2PNameTarget` 的原因 |
|---|---|---|
| `[1]` | Promise 风格（`.call(...).future`） | P2PName 不做本地查找，避免主 isolate 死锁 |
| `[2]` | JSON 风格（`.callJson<T>(...).future`） | 同上 |
| `[3]` | Callback 风格（`.callAsync(api, payload, cb)`） | 同上 |
| `[4]` | 短超时（1ms）→ promise.abandoned=true | 验证超时状态机 |
| `[5]` | 缺失 API → 空字节或超时 | 验证错误路径 |
| `[6]` | **序列化 async**（`Framework.p2pnameCallAsyncSequenced`） | 验证 FIFO 顺序 |
| `[7]` | **BridgeHost 层 UID 长度校验**（应抛 `RangeError`） | 验证跨层异常类型一致 |

**它验证了什么**：

- **Promise / Callback / JSON 三种调用形状语义一致**（同一 request 走不同包装）。
- **超时状态机正确**——超时后 promise 既 settle 又标记 `abandoned`，且 native
  请求**不被取消**（late callback 被静默丢弃）。
- **序列化 async 真的做序列化**——[6] 组连发 3 条 sequenced async，逐条验证
  响应里 `seq=0/1/2` 顺序正确。**这是防止退化回归的关键测试**。
- **跨层异常类型一致**——`Framework._checkUidLength` 与 `BridgeHost._checkUidLength`
  都抛 `RangeError`（早期版本 BridgeHost 抛 `ArgumentError`，导致用户 catch
  `RangeError` 时漏掉一层）。

**为什么必须用 `P2PNameTarget`**：

`AppTarget` / `UIDTarget` 的 async 路由是 **local-first** 的。当 Dart 主 isolate
发起 async 调用时，如果本进程命中本地 App，Pascal 会在**调用者线程上同步执行
handler**。Handler 是 bridge 的 Protocol A trampoline，它 `Dart_PostCObject` 后
阻塞等 Dart 回信——但 Dart 主 isolate 还卡在 FFI 调用里 → **双向死锁**。

`P2PNameTarget` 永远走服务端转发，服务端在**独立原生线程**上执行 handler，不
占用 Dart 主 isolate。**详见主 `README.md` 的[故障排查](../README.md#故障排查)一节。**

**典型失败**：

- 探针卡死在 `[1] Promise style` 而不输出任何结果 → 大概率是误用了 `AppTarget`
  或 `UIDTarget`。**检查是否把 target 声明改成了非 P2PName**。
- `[FAIL] sequenced async preserves FIFO order` → `Framework.p2pnameCallAsyncSequenced`
  退化成了非序列化调用（回归）。

---

### phase7 — 三套寻址探针

**文件**：`bin/phase7_addressing_probe.dart`

**验证目标**：`AppTarget` / `UIDTarget` / `P2PNameTarget` 三种寻址模式。

**运行**：

```powershell
dart run bin\phase7_addressing_probe.dart
```

**覆盖内容**：

| 段 | 内容 | 说明 |
|---|---|---|
| `[1]` | `AppTarget` 静态属性 | 只验证 `hashKey` / `describe`，**不发起调用**（避免死锁） |
| `[2]` | `UIDTarget` 参数校验 | 31 / 33 字节 → `RangeError`；非 hex → `RangeError` |
| `[3]` | `UIDTarget` 死路由 | 用一个不存在的 UID 调用，验证 promise 会 settle 而非永久挂起 |
| `[4]` | `P2PNameTarget` 端到端调用 | 唯一实际发起网络调用的寻址模式 |
| `[5]` | 跨类型 `hashKey` 不冲突 | `app:` / `uid:` / `p2p:` 前缀保证不同寻址模式的 key 不会撞 |

**它验证了什么**：

- **三套寻址的 API 表面一致**——`hashKey`、`describe`、调用形状完全相同。
- **UID 参数校验严格**——不做静默截断/补零，长度不对立刻 `RangeError`。
- **死路由不会永久挂起**——对不存在的 UID 调用，promise 会在超时后 settle，
  用户不会被卡死。
- **`hashKey` 可用作 Map / Set 的 key**——不同寻址模式不会误判为同一目标。

**为什么 `[1]` 不发起调用**：

`AppTarget` 的 async 调用在主 isolate 上会死锁（同上）。探针故意只验证静态属性，
把实际调用留给 `[4] P2PNameTarget`。这是**故意的设计**，不是遗漏。

**典型失败**：

- `[FAIL] dead-route settled` → UID 路由层有 bug，未对不存在的目标返回空响应。

---

### hello_async — 教学 demo

**文件**：`bin/hello_async.dart`

**定位**：**不是验证，是教学**。展示现代 async API 的**五种典型用法**。

**运行**：

```powershell
dart run bin\hello_async.dart
```

**覆盖内容**：

| 段 | 场景 | 教学重点 |
|---|---|---|
| `[1]` | **Erlang 风格** | 业务代码直接写在 `callAsync` 回调里，无 await 断裂 |
| `[2]` | **Promise 风格** | `await target.callJson<T>(...).future`，链式清晰 |
| `[3]` | **嵌套调用** | 第一个回调里发起第二个调用，业务逻辑自然链式 |
| `[4]` | **超时放弃** | 1.5s 超时 vs 3s handler，`promise.abandoned=true` |
| `[5]` | **服务端错误** | handler 返回 `{"error": "..."}` 被正确识别 |

**服务端注册的 API**：

```dart
app.registerCall('add', 'Add two integers', serverAdd);
app.registerCall('greet', 'Greet a name', serverGreet);
app.registerCall('getUser', 'Look up a user by id', serverGetUser);
app.registerCall('slow', 'Sleep for a given number of milliseconds', serverSlow);
```

**客户端调用**：

```dart
final client = P2PNameTarget('hello_async_group');

// Erlang 风格
client.callAsync('greet', {'name': 'World'}, (result, error) {
  if (error != null) { print('[error] $error'); return; }
  final reply = decodeJsonResult(result);
  print('[reply] greeting = ${reply['greeting']}');
});

// Promise 风格
final sum = await client.callJson<Map<String, dynamic>>(
  'add',
  payload: {'a': 17, 'b': 25},
  timeoutMs: 5000,
).future;
print('[reply] ${sum['sum']}');
```

**它演示了什么**：

- **回调与业务代码同一处**——不需要跳出到另一个函数体。
- **`CallPromise` 是 thenable**——`await promise` 和 `await promise.future` 等价。
- **`callJson<T>` 自动处理 NUL 帧**——LingoFuse 的字符串约定不影响用户代码。
- **超时是可恢复的**——`abandoned` 标志让业务层能区分"超时"与"错误"。
- **服务端业务错误与传输错误分离**——`{"error": "..."}` 由业务层识别，
  传输层只负责送达。

**输出示例**：

```
=== Hello, Async ===

[boot] starting BridgeHost...
[boot] declaring P2P group "hello_async_group"...
[boot] creating AppHandle and registering APIs...
[boot] starting framework on "ipc:hello_async"...
[boot] waiting for the mesh to converge...
[boot] ready; client = p2pname("hello_async_group")

[1] Erlang feel: client.callAsync(api, payload, (result, error) { ... })
    [reply] greeting = Hello, World!

[2] Promise style: await client.callJson<Map>(...).future
    [reply] 42

[3] Nested call: inside the getUser callback, call greet(user.name)
    [getUser] id=2 name=Bob
    [greet]    Hello, Bob!

[4] Timeout: a 1.5s budget against a 3s handler
    [timeout] Async call to p2pname("hello_async_group") was abandoned...

[5] Error path: getUser(999) returns a JSON error
    [server-error] user 999 not found

[cleanup] stopping the framework...

=== done ===
```

---

## 如何写自己的示例（PoC）

**官方探针验证的是"机制"，你的 PoC 验证的是"业务"。** 两者不能相互替代。

### 最小 PoC 模板

新建 `bin/my_poc.dart`：

```dart
// My LingoFuse PoC: <describe your scenario here>.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const String kAppName = 'MyPocService';
const String kGroupName = 'my_poc_group';
const String kEndpoint = 'ipc:my_poc';

// ---------------------------------------------------------------------------
// Server-side business logic
// ---------------------------------------------------------------------------

/// <describe what this handler does>
Uint8List onMyApi(Uint8List input) {
  final req = decodeJsonPayload(input) as Map<String, dynamic>;
  // ... your business logic ...
  return encodeJsonPayload({'result': 'ok'});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  // --- 1. Boot ---
  await BridgeHost.start();
  Framework.setOptP2PName(kGroupName);

  final app = AppHandle(kAppName, 'My PoC');
  app.registerCall('myApi', 'My API', onMyApi);

  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService(kEndpoint, kEndpoint);
  Framework.prepareClient(kEndpoint, app: app);
  Framework.prepareDone();

  // Wait for the P2P name to propagate.
  await Future.delayed(const Duration(milliseconds: 2000));

  // --- 2. Exercise your scenario ---
  final target = P2PNameTarget(kGroupName);
  final reply = await target
      .callJson<Map<String, dynamic>>(
        'myApi',
        payload: {'input': 'hello'},
        timeoutMs: 5000,
      )
      .future;

  print('result: ${reply['result']}');

  // --- 3. Cleanup ---
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Object? decodeJsonPayload(Uint8List bytes) {
  final nulIndex = bytes.indexOf(0);
  final payload = nulIndex >= 0 ? bytes.sublist(0, nulIndex) : bytes;
  if (payload.isEmpty) return null;
  return jsonDecode(utf8.decode(payload));
}

Uint8List encodeJsonPayload(Object? value) {
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}
```

运行：

```powershell
dart run bin\my_poc.dart
```

### PoC 覆盖清单（建议按顺序推进）

| 阶段 | 目标 | 参考示例 |
|---|---|---|
| **1. 本机单进程** | 服务端和客户端同进程，P2PName 路由 | `bin/hello_async.dart` |
| **2. 本机双进程** | 两个独立 Dart 进程，通过 IPC 通信 | 复制 `my_poc.dart` 为 `my_server.dart` / `my_client.dart`，分别运行 |
| **3. 跨语言** | Dart server + Python/C++ client（或反之） | 主 `README.md` 的[跨语言互操作](../README.md#跨语言互操作)一节 |
| **4. 负载均衡** | 多个同 P2PName 的 Dart 进程，观察任务分发 | 启动 N 个 `my_server.dart`，客户端连发 100 次调用 |
| **5. 长时间运行** | 让 server 跑 24h，观察内存/线程 | 在 `my_server.dart` 主循环加内存快照 |

### 关键注意点（写 PoC 时反复会踩）

1. **服务端注册前必须 `await BridgeHost.start()`**——否则 `registerCall` 抛 `StateError`。
2. **P2P 组名要在 `prepareClient` 前设置**——`Framework.setOptP2PName` 需早于
   客户端连接，否则第一次广播不含该组名。
3. **P2P 名传播需要 ~2 秒**——`client -> server -> broadcast` 是两跳，别急着调用。
4. **从主 isolate 发起的 async 调用必须用 `P2PNameTarget`**——`AppTarget` /
   `UIDTarget` 的 async 会死锁。
5. **同步调用（`Framework.call`）需在子 isolate 中执行**——否则阻塞 Dart 事件
   循环，bridge 回调无法送达。
6. **清理顺序不能乱**——`app.dispose()` → `exitMainThread()` → `shutdown()` →
   `BridgeHost.stop()`。

---

## 项目结构约定

```
dart/
├── bin/          官方探针 + 教学 demo + 你的 PoC
├── test/         单元测试 + 集成测试（机制层验证）
├── example/      本文件（索引与上手文档）
├── native/       备用原生库目录（见下方说明）
└── tool/         辅助工具目录（见下方说明）
```

### `bin/` 与 `test/` 的分工

| 目录 | 目的 | 典型内容 |
|---|---|---|
| `bin/` | **可运行的示例/探针** | 端到端验证、教学 demo、你的 PoC |
| `test/` | **自动化测试** | 单元测试、集成测试，`dart test` 驱动 |

**两者不重叠**：`bin/` 下的探针可以手动运行来观察输出，`test/` 下的测试由 CI
批量执行。同一逻辑可以在两处都有，但通常选择一种。

### `native/` 与 `tool/` 的用途

这两个目录目前为空，用于以下**可选**场景：

- **`native/`**：当你需要打包一个**不依赖系统 PATH** 的发布版时，可以把
  `LingoFuse64.dll` / `z_ipc_64.dll` / `mimalloc64.dll` 复制到这里，
  并在加载代码里增加 `native/` 作为搜索路径候选。
- **`tool/`**：放置辅助脚本，例如：
  - 打包脚本（把 `bin/` 下的某个 PoC 连同依赖打成独立的 zip）
  - 性能基准脚本
  - 自动生成 PoC 模板的脚本

**如果你不使用这两个目录**，可以安全删除。它们不会影响主流程。

---

## 常见问题

### `dart run bin/xxx.dart` 报 `Could not load lf_dart_bridge.dll`

按主 `README.md` 的[故障排查](../README.md#故障排查)一节处理。最常见的三种原因：

1. `lf_dart_bridge.dll` 未编译 → 按[编译 C 桥接 DLL](../README.md#编译-c-桥接-dll)
2. DLL 未放在搜索路径 → 放在 `dart/` 根、`dart/bridge/`、或设置环境变量
3. 依赖 DLL 缺失 → `z_ipc_64.dll` / `mimalloc64.dll` 需在 PATH 中

### 探针卡死不动，无输出

**99% 是死锁**。检查：

- 是不是把 `P2PNameTarget` 改成了 `AppTarget` / `UIDTarget`？
- 是不是在 Dart 主 isolate 里发起了同步调用？

参考 `bin/phase6_async_probe.dart` 头部注释关于"为何必须用 P2PName"的说明。

### `phase6` 通过数比预期少

本文件列的预期是 **31 项通过**（含 [1]~[7] 全部组 + `[Cleanup]`）。如果少于 31：

- 检查是不是跑的是旧版本（早于 v2.0 final 的 `phase6` 只有 24 项）。
- `dart run bin\phase6_async_probe.dart` 重新拉一次最新代码。

### `hello_async` 的 `[4] Timeout` 段没打印超时

- 检查目标机器是否比预期慢很多（比如 CI 环境），1.5s 可能不够覆盖 3s handler
  **加** propagation 延迟。可以临时把 `timeoutMs` 调大，或把 `serverSlow` 的
  睡眠时长调小。
- 如果完全不超时（直接输出 `[unexpected] the call resolved`），说明 handler
  执行比 1.5s 还快——大概率是 `serverSlow` 的 busy-wait 被优化掉了，重新编译。

### 探针跑完后进程没退出

- 检查 `[Cleanup]` 段是否完整打印。如果卡在 `BridgeHost.instance.stop()`，
  说明有 native 线程未正确 join——这是 bug，请报告。
- 如果退出码是 `0` 但 shell 仍显示"正在运行"，可能是 Windows 上 DLL 卸载
  延迟，等 1~2 秒即可。

### 想修改探针来测试自己的场景

推荐做法：

1. **复制** `bin/hello_async.dart` 为 `bin/my_poc.dart`。
2. 修改 `kAppName` / `kGroupName` / `kEndpoint` 为你的名字。
3. 替换 `serverXxx` 函数为你的业务逻辑。
4. 替换 `[1]` ~ `[5]` 调用段为你的场景。

**不要直接修改官方探针文件**——升级绑定时会被覆盖。使用独立的文件名。

---

*Document version: 1.0*
*Target LingoFuse Dart binding: v0.2.0 (v2.0 特性升级)*
*Last updated: 2026-10-15*
