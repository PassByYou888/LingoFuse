# Pascal Service Guide for LingoFuse HTTP Bridge (bridge.py)

**文件名：** `Pascal_Service_Guide_for_bridge.md`  
**版本：** v1.0  
**适用对象：** 使用 Pascal（Free Pascal / Delphi）开发 LingoFuse 服务端，并通过 `bridge.py` 对外提供 HTTP 接口的开发者。

---

## 1. 环境准备

在开始编写 Pascal 服务之前，您需要准备好 Python 环境和 LingoFuse 动态库。

### 1.1 安装 Python 依赖

项目使用 Python 编写的桥接器 `bridge.py`，需要安装 Flask 和 LingoFuse Python 绑定（已包含在 `lingofuse` 包中）。执行以下脚本（在 Windows PowerShell 中）：

```powershell
.\install_deps.ps1
```

该脚本会自动安装 Flask 并检查动态库是否存在。

### 1.2 初始化环境变量

运行以下脚本，将当前目录加入 `PYTHONPATH`，并将 `Binary` 目录（存放动态库）加入系统 `PATH`：

```powershell
.\init_demo_env.ps1
```

若您没有使用 PowerShell，也可以手动设置：

```bash
export PYTHONPATH="/path/to/Py:$PYTHONPATH"
export PATH="/path/to/Binary:$PATH"
```

### 1.3 确认动态库

确保 LingoFuse 动态库（Windows: `LingoFuse64.dll`，Linux: `liblingofuse.so`，macOS: `liblingofuse.dylib`）位于系统搜索路径中（`PATH` 或当前目录）。`init_demo_env.ps1` 会自动添加 `Binary` 目录。

---

## 2. 项目目录结构

```
Py/
├── init_demo_env.ps1                      # 环境初始化脚本
├── install_deps.ps1                       # 依赖安装脚本
├── LingoFuse_Python_Binding_Migration_Record.md  # 迁移记录（可忽略）
├── cross/                                 # Cross 示例（Python 示例）
│   ├── cross_bridge.py                    # Python 适配器（不用于 Pascal）
│   ├── cross_call.py
│   ├── Cross_Demo_Guide_zh.md
│   ├── cross_node.py
│   ├── cross_service.py
│   ├── nodejs/
│   ├── php/
│   └── webjs/
└── lingofuse/                             # 核心绑定和桥接器
    ├── bridge.py                          # ★ HTTP 网关（您需要启动的）
    ├── Bridge_User_Guide.md               # bridge.py 英文使用文档
    ├── client.py                          # LingoFuse 客户端封装
    ├── core.py                            # 数据句柄封装
    ├── errors.py                          # 异常定义
    ├── serializers.py                     # 序列化工具
    ├── server.py                          # Python 服务端框架（Pascal 不用）
    ├── test_bridge.py                     # 测试脚本
    ├── test_lingofuse.py                  # 单元测试
    ├── _lf_native.py                      # 底层 ctypes 绑定
    └── __init__.py                        # 包入口
```

您只需要关注：

- `lingofuse/bridge.py` —— 您要启动的 HTTP 网关。
- 您的 Pascal 源代码（`bridge_service.lpr` 和 `bridge_compute.lpr`）—— 自己编写或使用提供的示例。

---

## 3. Pascal 服务端开发规范

### 3.1 API 注册

在 Pascal 中，使用 `LF_RegisterCallEx` 注册一个 Call 类型的 API。回调函数必须符合 `TLF_Call_Event` 声明（`cdecl` 约定）：

```pascal
procedure MyAPICallback(Trigger: Pointer; Input: Pointer; Output: TDataHnd); cdecl;
```

- **Input**：包含 HTTP 请求体的 `TDataHnd`，内容是 UTF-8 字符串（以 `\0` 结尾）。您可以使用 `LF_ReadString(Input)` 读取整个 JSON 字符串。
- **Output**：用于返回数据的 `TDataHnd`，您需要使用 `LF_WriteString(Output, JSONString)` 写入响应（该函数自动追加 `\0`）。

**示例（表达式计算器）**：

```pascal
procedure do_exp_Call(Trigger: Pointer; Input: Pointer; Output: TDataHnd); cdecl;
var
  jsonStr: string;
  jo: TZ_JsonObject;
  argsArr: TZ_JsonArray;
  expr: string;
  tmp: string;
  resObj: TZ_JsonObject;
begin
  jsonStr := LF_ReadString(Input);
  if jsonStr = '' then
  begin
    LF_WriteString(Output, '{"code":-1,"error":"Request body is empty"}');
    Exit;
  end;
  // 解析 JSON ...
  // 处理业务逻辑 ...
  // 返回 JSON 结果
  resObj := TZ_JsonObject.Create;
  resObj.I['code'] := 0;
  resObj.S['result'] := tmp;
  LF_WriteString(Output, resObj.ToJSONString(False));
  resObj.Free;
end;
```

### 3.2 JSON 格式约定

为了与桥接器及各种 HTTP 客户端良好配合，**请求和响应均采用 JSON 格式**，并遵循以下结构：

- **请求**：至少包含一个 `args` 数组（参数列表），例如 `{"args": ["1+2*3"]}`。您也可以自定义字段，但推荐统一。
- **成功响应**：`{"code":0, "result": <任意类型>}`。
- **错误响应**：`{"code":-1, "error": "错误描述"}`。

桥接器不会解析 JSON，但客户端（如浏览器）会依赖这些字段来判断成功与否，因此请严格遵守。

### 3.3 字符串读写（与 `\0` 的关系）

- **`LF_ReadString(Input)`**：自动从当前位置读取直到遇到 `\0`，若没有 `\0` 则读至缓冲区末尾（容错）。`bridge.py` 会在请求体后追加一个 `\0`，所以您无需担心。
- **`LF_WriteString(Output, S)`**：自动在 `S` 后追加一个 `\0`，保证其他 LingoFuse 端（如 `bridge.py`）正确读取。`bridge.py` 在返回 HTTP 响应前会剥离末尾的 `\0`，确保 HTTP 客户端得到纯净的 JSON。

### 3.4 路径与端点

- **应用名（app）**：在 `LF_CreateAppEx` 中指定，例如 `'pas'`。这是 LingoFuse 网络中的唯一标识。
- **API 名（api）**：在 `LF_RegisterCallEx` 中指定，例如 `'exp'`。
- **HTTP 路径**：桥接器使用 `/<app>/<api>` 格式。例如，您的应用名为 `pas`，API 名为 `exp`，则 HTTP 请求路径为 `/pas/exp`。
- 您也可以启动 `bridge.py` 时带 `--app pas`，这样客户端可直接使用 `/exp`（无需在路径中指定应用名），但显式路径更清晰。

---

## 4. 启动完整服务

### 4.1 编译 Pascal 程序

您需要两个 Pascal 程序：

- **信标（bridge_service）**：提供服务注册发现，仅监听 IPC 端点。
- **计算节点（bridge_compute）**：注册实际 API，连接信标。

使用 Free Pascal 编译（假设已配置好单元搜索路径）：

```bash
lazbuild -B bridge_service.lpr
lazbuild -B bridge_compute.lpr
```

确保 LingoFuse 动态库可被加载（在 `PATH` 或程序目录中）。

### 4.2 启动顺序（三个终端）

| 终端  | 启动命令                                                                     | 说明                                                           |
| ----- | ---------------------------------------------------------------------------- | -------------------------------------------------------------- |
| 终端1 | `./bridge_service`                                                           | 信标，输出 `[OK] Beacon started on endpoint: ipc:compute_grid` |
| 终端2 | `./bridge_compute`                                                           | 计算节点，输出 `[OK] Compute node connected to beacon...`      |
| 终端3 | `python lingofuse/bridge.py --endpoint ipc:compute_grid --debug --port 8081` | HTTP 网关，无需指定 `--app`（由路径决定）                      |

---

- 注意:**bridge.py不能拿直接启动,需要通过下列命令行指定参数**
- `./python lingofuse/bridge.py --endpoint ipc:compute_grid --debug --port 8081`


所有程序保持运行，不要关闭。

---

## 5. 测试调用

### 5.1 使用 curl

```bash
curl -X POST http://127.0.0.1:8081/pas/exp \
     -H "Content-Type: application/json" \
     -d '{"args": ["1+2*3"]}'
```

响应示例：

```json
{"code":0,"result":"7"}
```

### 5.2 使用浏览器（`web_demo.html`）

在浏览器中打开项目根目录下的 `web_demo.html`（如果存在），输入表达式并点击计算，它会自动访问 `http://127.0.0.1:8081/pas/exp`。

### 5.3 使用 Python 测试脚本

编辑 `test_bridge.py`，将 `url` 改为 `http://127.0.0.1:8081/pas/exp`，然后运行：

```bash
python test_bridge.py
```

---

## 6. 重要注意事项

1. **字符串编码**：所有请求/响应均为 UTF-8。Pascal 中使用 `LF_WriteString` 和 `LF_ReadString` 自动处理编解码。
2. **超时设置**：`bridge.py` 默认超时 5 秒，若您的处理耗时较长，可通过 `--timeout 10000` 调整（单位毫秒）。
3. **调试模式**：启动桥接器时加 `--debug` 可打印请求/响应内容摘要，便于排查问题。
4. **错误处理**：Pascal 回调中务必捕获异常，返回 JSON 错误（`code=-1`），避免异常导致进程崩溃。
5. **多个 API**：在同一应用下注册多个 API 时，HTTP 路径只需改变 API 名称，例如 `/pas/add`、`/pas/sub`。
6. **IPC 端点冲突**：若 `ipc:compute_grid` 被占用，可修改 Pascal 代码和 bridge.py 的 `--endpoint` 参数为其他名称。

---

## 7. 常见问题

### Q1：桥接器返回 `{"code": -3, "error": "API 'exp' not available for app 'pas'"}`

- 确认 `bridge_compute` 已成功连接到信标（控制台显示 `Ready OK`）。
- 确认 API 注册成功（节点启动时打印 `(call) (exp) ...`）。
- 等待 1-2 秒，让网络广播传播。
- 检查路径是否写错（应为 `/pas/exp`，而非 `/exp`）。

### Q2：返回空响应（HTTP 200，但 body 为空）

- 检查您的回调函数是否真的调用了 `LF_WriteString`。
- 检查是否发生了未捕获的异常，导致函数提前退出。
- 查看 Pascal 控制台是否有错误输出。
- 确认 `LF_ReadString` 能正确读取到请求体（可在回调中打印 jsonStr）。

### Q3：JSON 解析错误（客户端报错）

- 确保您返回的 JSON 字符串是合法的（没有多余的空字符，引号正确转义）。
- `bridge.py` 会自动剥离末尾的 `\0`，但如果您手动写入带多个 `\0` 的字符串，可能导致解析失败，请只用 `LF_WriteString` 写入一个完整的 JSON 对象。

### Q4：如何支持非 JSON 二进制数据？

- 若您想直接传输二进制，可以修改 `bridge.py` 去掉追加 `\0` 的逻辑，并在 Pascal 端使用 `LF_ReadBuffer`/`LF_WriteBuffer` 按长度处理。但这样做会破坏与 JSON 客户端的兼容性，除非您完全掌控两端。

---

## 8. 扩展与定制

- **添加新 API**：在 Pascal 中注册新回调，并在 `bridge.py` 无需任何修改，客户端通过新路径访问即可。
- **自定义序列化**：您可以在 JSON 中嵌入 Base64 编码的二进制数据，或使用 MessagePack 等格式（需双方协商）。
- **生产部署**：建议将 `bridge.py` 部署在 Gunicorn 等生产 WSGI 服务器后，以提升并发性能。

---

## 9. 总结

通过 `bridge.py`，您无需编写任何 HTTP 服务器代码，即可将现有的 LingoFuse Pascal 服务暴露为 Web API。只需遵循本指南中的 JSON 格式和路径规范，您的 Pascal 程序就能轻松融入现代 Web 生态，被浏览器、移动端、微服务等多种客户端调用。

如有更多问题，请参考 `Bridge_User_Guide.md`（英文）和项目中的其他示例。