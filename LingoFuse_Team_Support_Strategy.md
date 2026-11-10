# LingoFuse 各语言团队接入支持策略

**文件名**：`LingoFuse_Team_Support_Strategy.md`

> 本策略基于对 LingoFuse 18 种语言绑定 README、`LingoFuse_MultiLanguage_Complete_Guide.md`、主仓库 README 与 LingoFuse-Tools 知识库的深度分析后重建。核心立场：**支持不是包办，而是尊重目标语言的能力边界，用 LF 把短板补上、长板接上、契约讲清楚**。

---

## 一、知识库洞察摘要（支持策略的事实基础）

从 LF 知识库体系提炼出六条对支持策略有直接约束力的事实：

| # | 洞察 | 对支持策略的含义 |
|:-:|------|------------------|
| 1 | **18 种绑定中仅 C++ 有 GitHub 托管 CI**，其余为本地测试脚本 | 支持策略必须把“CI 缺失”前置，团队需自行承担回归验证 |
| 2 | **测试规模大 ≠ 生产验证**（Ruby 331、Fortran 474、Julia 431），验证的是绑定层兼容性而非业务负载 | 支持交付的是“机理 PoC 路径”，不是“生产可用承诺” |
| 3 | **回调线程模型、Handle 所有权、清理顺序是跨语言共性契约**，各语言只是 API 名不同 | 支持必须包含“共性契约培训”，否则任何语言团队都会踩同一组坑 |
| 4 | **平台硬门槛密集**：Java JDK 22+、Julia `--threads=2`、Zig 锁定 0.17.0、Erlang OTP 27+、PHP 仅 Caller、Flutter Web 不可用 | 支持清单首屏必须列限制，避免团队在错误栈上投入 |
| 5 | **iOS/Android/WASM 无法运行 Service**，移动端只能作为 Caller | Dart/Swift 做前端时，Service 必须部署在服务器，支持策略要明确 |
| 6 | **LingoFuse-Tools 三条工具线覆盖 17 种原生 FFI + 20+ 种 JSON**，但生成器不跑 CI、产物需人工验证 | 工具链支持要区分“代码生成”与“生产验证”两件事 |

---

## 二、语言分群与支持策略

分群依据不是单纯“语言强弱”，而是**生态结构 + LF 知识库中的实际限制**。

### 群一：强实现语言 —— C++、Rust、Zig

**知识库事实**：局部实现能力强（压缩/加密/解码/算法），但缺高级 UI 生态；C++ 有 Qt 但学习曲线陡，Rust 的 egui/iced 早期，Zig 生态薄。C++ 唯一有 CI；Rust panic 必须 `catch_unwind`；Zig 锁定 0.17.0。

**支持策略：基础系统 + 局部核心 + 高级 UI 激励**
- **我们提供**：LF 通讯层、服务发现、句柄池、生命周期管理、高级 UI 宿主模板（FMX/LCL/WPF/JavaFX/Web 渲染）。
- **他们实现**：压缩、加密、解码、CV 算法、计算内核等局部核心。
- **支持交付**：基础系统骨架 + 局部实现接口 + 高级 UI 宿主模板 + 二进制大对象（图片/帧/矩阵）传输 PoC。
- **限制前置**：C++ 先 `LF_LoadLibrary`、MSVC `/utf-8`；Rust `catch_unwind`；Zig 0.17.0。

### 群二：后台强项语言 —— Go、Erlang

**知识库事实**：Go 高并发、Erlang OTP 容错能力强，但缺前端展示；Go Service 侧需 `CGO_ENABLED=1`；Erlang 需 16 分支 receive、二进制 wire、OTP 27+，NIF 崩溃会拖垮 BEAM。

**支持策略：让路后台 + 前端支持（Web/CS）**
- **让他们专注**：Go 做高并发服务，Erlang 做 OTP 容错服务。
- **我们补**：Web 前端（TS/JS 渲染前端）或 CS 前端（Pascal LCL/FMX、C# WPF、JavaFX），让后台结果可展示、可操作、可监控。
- **支持交付**：后台 Service 模板 + Web/CS 前端宿主模板 + 前端事件→LF Call→后台服务→结果回填范式 + 二进制/JSON 双通道示例。
- **限制前置**：Go `CGO_ENABLED=1`；Erlang OTP 27+、16 分支 receive、NIF 隔离。

### 群三：综合工程化语言 —— Java、C#

**知识库事实**：工程化、企业级、大型系统构建能力最强；Java 需 JDK 22+ FFM，C# 库不能有 `Main`，两者都有成熟 UI 框架（JavaFX/WPF）。

**支持策略：主体工程地位 + Pascal 工具链退居工具环节**
- **尊重他们的能力**：Java/C# 负责大型业务系统、企业级框架、综合工程化主体。
- **Pascal 退居工具环节**：不抢主体，提供 LF 代码生成器、调试工具、脚手架、MCP 工具，供 Java/C# 开发者使用。
- **支持交付**：Java/C# 主体工程模板 + Pascal 工具链（代码生成/调试/脚手架）+ LF 接入示例 + 工程化最佳实践。
- **限制前置**：Java JDK 22+；C# 库无 `Main`；Pascal 工具链需说明使用方式。

### 群四：专业 API 节点 —— Julia、R、Fortran、Python、Ruby、PHP（仅 Caller）

**知识库事实**：专业计算、统计、数值、脚本、算法能力强；各有硬限制：Julia `--threads=2`、R 不可重入且不能 CRAN、Fortran 编译器同源、Python 异步 handle 回调返回即释放、Ruby `at_exit` 清理顺序、PHP 仅经 `bridge.py` 做 Caller。

**支持策略：前沿 API 封装 + 明确为 API 供给方 + UI 不强制**
- **明确角色**：任何服务器+前端架构需要 API，找他们。他们提供统计计算、数值内核、算法服务、脚本胶水、Web/API 服务。
- **我们补**：最前沿 API 封装（异步/Future、类型安全、JSON/HTTP 桥接、Notebook/CLI 集成、P2P 注册、UID 寻址）。
- **UI 不强制**：普通 OS 自带窗口/CLI/Notebook 即可。
- **支持交付**：前沿 API 封装模板 + Notebook/CLI 集成示例 + 简单 OS 原生对话框示例 + 该语言清理顺序与线程模型。
- **限制前置**：Julia `--threads=2`；R `lf_local_call` + `future::plan("sequential")`；Fortran 编译器同源；PHP 仅 Caller。

### 群五：前端 UI 宿主 —— Dart、Delphi（UI 形态）、Pascal（UI）、TS/JS（前端）、Swift

**知识库事实**：有成熟高级 UI 框架（Flutter、VCL/FMX、LCL、Web 渲染、SwiftUI）；Flutter Web 不可用、Swift macOS/Linux 待测、TS/JS 浏览器仅 Caller；移动端无法运行 Service。

**支持策略：UI 层面尊重其能力 + 作为 UI 供给方**
- **尊重他们的能力**：他们就是前端 UI 供给方，为群一提供高级 UI 宿主与渲染引擎级界面，为群二提供 Web/CS 前端宿主，为群三提供跨端 UI 补充。
- **自身业务也由 LF 调度**：用本语言 UI 开发业务界面，LF 调用群四 API 节点与群一专业节点。
- **支持交付**：UI 宿主模板 + 渲染引擎级 UI 示例（实时图像/视频/可视化）+ UI 事件→LF Call→结果回填范式 + 二进制对象显示 PoC。
- **限制前置**：Swift macOS/Linux 待测；Dart Flutter Web 不可用；TS/JS 浏览器仅 Caller；Delphi 后台形态归群四，UI 形态归群五，需明确区分。

### 群六：工具链与服务方 —— Pascal 后台形态、LingoFuse-Tools

**知识库事实**：Pascal 是 LF 主场（原生 FFI、核心引擎来源）；LingoFuse-Tools 覆盖 17 种原生 FFI + 20+ 种 JSON，但生成器不跑 CI、产物需人工验证。

**支持策略：工具链供给 + 机理 PoC 路径**
- **Pascal 后台形态**：作为 API 节点支持（类 Python 封装 + EasyCS 后台示例）。
- **LingoFuse-Tools**：提供代码生成器（ABI/JSON/MCP 三条线）、调试工具、脚手架，供所有团队使用；明确“生成物需人工验证”。
- **支持交付**：工具链使用指南 + 生成器源码与踩坑记录 + 机理 PoC 路径（先跑 `test/`，再做 App 层 PoC）。

---

## 三、横切支持：跨语言共性契约

无论哪个群，接入 LF 都必须讲清五组共性契约，这是知识库反复强调的踩坑高发区：

| 契约 | 内容 | 支持方式 |
|------|------|----------|
| **回调线程模型** | 回调在 native worker 线程执行；禁止阻塞；禁止调用同步 LF 函数 | 共性契约培训 + 语言专属示例 |
| **Handle 所有权** | 同步族归调用者；异步族归框架，回调返回立即释放；异步 handle 禁止跨线程保留 | 所有权速查表 + 各语言正确/错误示例 |
| **清理顺序** | `ExitMainThread → FreeApp → Shutdown`；各语言还有额外步骤（Ruby `at_exit`、Node/Java `AsyncBridge.shutdownInstance`、Julia `stop_callback_consumer`） | 各语言清理顺序清单 |
| **侧数据** | 只在回调 Input 有效；`LF_Get_P2P_UID` 返回指针，5 秒失效；`LF_LocalCall` 不注入身份 | 侧数据使用矩阵 + 各语言代码示例 |
| **三套寻址** | App 名本地优先；UID 万能路由；P2PName 不做本地优先；App 名调用不命中 P2P 注册 | 寻址选择决策树 + 命中矩阵 |

---

## 四、支持交付物清单

每个团队接入时，按下表交付，不遗漏：

| 交付物 | 内容 | 适用群 |
|--------|------|--------|
| **限制清单** | 该语言硬门槛（版本、平台、CI 状态） | 全部 |
| **服务/调用模板** | Service/Call 双工程模板 | 全部 |
| **UI 或 API 宿主模板** | 群一/二/三/五给 UI 宿主；群四给 Notebook/CLI | 按群 |
| **共性契约培训** | 回调线程、Handle 所有权、清理顺序、侧数据、三套寻址 | 全部 |
| **机理 PoC 路径** | 先跑 `test/`，再做 App 层 PoC | 全部 |
| **二进制/JSON 双通道示例** | 二进制句柄 + JSON 桥接 | 群一/二/四 |
| **工具链使用指南** | LingoFuse-Tools 三条线 + 生成物验证说明 | 全部 |

---

## 五、落地路线

1. **先分群再派活**：接入前先标群一至群六，避免“C++ 只拿 CLI”或“R 被逼学 Qt”。
2. **群一给高级 UI 激励**：这是他们语言生态最缺的，也是让他们乐意做局部实现的关键。
3. **群二给前端支持**：Web 或 CS 前端，让后台能力可展示、可交互。
4. **群三给主体工程地位，Pascal 退居工具环节**：提供代码生成器、调试工具、脚手架。
5. **群四明确为 API 供给方**：任何服务器+前端架构需要 API 找他们，UI 不强制。
6. **群五在 UI 层面尊重其能力**：作为前端 UI 供给方，为群一/二提供宿主与渲染引擎界面。
7. **群六提供工具链与机理 PoC 路径**：Pascal 后台形态作 API 节点，Tools 作代码生成与调试。
8. **限制前置**：JDK 22+、Julia `--threads=2`、Zig 0.17.0、Erlang OTP 27+、PHP 仅 Caller、Flutter Web 不可用，必须在接入清单首屏提示。
9. **验证路径统一**：先跑 LF `test/` 机理测试，再做本团队 App 层 PoC；UI 宿主与专业节点分进程验证；后台与前端分进程验证；API 节点先验证 API 再谈 UI。
10. **AI 辅助边界明确**：AI 可接管接口层和样板层（Tools 生成器、踩坑记录检索、测试补全），架构层决策（拓扑、路由选择、资源边界）由人类负责。