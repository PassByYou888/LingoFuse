## 一、核心原则：弥补，而非重塑

LingoFuse 是通讯地基，不提供 UI。但它可以成为**“生态补齐器”**：

- **开发者用自己最舒服的语言写核心**（C++ 写算法、Rust 写系统、Python 写脚本、R 写统计、Erlang 写 OTP）。
- **LF 负责把该语言生态里最稀缺的那块能力，通过多语言协作补过来**。
- 不做“让 C++ 团队只拿 CLI 示例”这种事，也不做“让 R 团队去学 Qt”这种事。

据此，团队分三类，策略不同。

---

## 二、三类开发者画像与补齐策略

### A 类：API 强、UI 弱的开发者
**典型语言**：C++、Rust、Python、Go、Zig、Node.js/TS（后端形态）

**真实痛点**：
- 写核心逻辑、算法、服务、协议很强。
- 一要做高级 UI 就痛苦：C++ 的 Qt 学习曲线陡、Rust 的 egui/iced 还在早期、Python 的 Tkinter 不够专业、Go 缺原生桌面 UI、Zig 生态更薄。
- 被误配成“只给 CLI 示例”，开发者拿不到他们真正缺的东西——**渲染引擎级别的高级 UI 测试与宿主**。

**LF 补齐策略：满足核心需求 + 提供高级 UI 测试与渲染引擎级宿主**
- **核心逻辑留在本语言**：算法、协议、服务、性能敏感代码不动。
- **UI 层由 LF 调度到成熟 UI 宿主**：Pascal/LCL、C#/WPF、Java/JavaFX、TS/Web 渲染前端、或专门的实时渲染引擎，按项目需求选择。
- **LF 作为桥梁**：UI 事件触发 LF Call，结果回填 UI；图像帧/张量走 LF 二进制句柄，不做二次序列化。
- **交付物**：
  - “本语言核心节点 + 高级 UI 宿主”双工程模板；
  - 渲染引擎级 UI 示例（实时图像/视频帧显示、交互式可视化、工业级面板）；
  - UI 事件驱动 LF Call 的范式代码；
  - 二进制大对象（图片/帧/矩阵）走 LF 句柄的端到端 PoC。
- **不让 C++/Rust/Python/Go/Zig 团队只拿文本界面**——高级 UI 是他们语言生态里最缺的，必须由 LF 协作补上。

---

### B 类：封闭生态、专业强的开发者
**典型语言**：R、Julia、Fortran、Delphi（后台形态）、Erlang、Ruby

**真实痛点**：
- 生态封闭、工具链偏旧、现代 API 范式缺失（异步/Future/类型安全/JSON Schema/HTTP 桥接）。
- 开发者习惯了 CLI、脚本、OTP 控制台、统计环境，不追求花哨 UI。
- 被误配成“去学前端/学高级 UI”，浪费他们真正的专业能力。

**LF 补齐策略：提供最前沿 API，UI 偏中即可（OS 自带/普通形态）**
- **不强迫做 UI**：UI 用 OS 自带的简单窗口/对话框/CLI/Notebook 即可，重点放在 API。
- **补最前沿 API 封装**：
  - 异步/Future/Promise 范式（R 的 `future`、Julia 的 `Task`、Ruby 的 `CallFuture`、Erlang 的 `receive`）；
  - 类型安全调用（Julia 的 `Target`、Ruby 的 `Options`、Erlang 的类型化选项）；
  - JSON/HTTP 桥接（R 的 `lf_poll`、Erlang 的二进制 wire、Delphi 的 EasyCS 后台）；
  - Notebook/CLI 集成（Julia、R 直接嵌入分析环境）。
- **交付物**：
  - 现代 API 封装模板（异步、类型安全、P2P 注册、UID 寻址）；
  - Notebook/CLI 集成示例；
  - 简单 UI/OS 原生对话框示例（不做渲染引擎级 UI）；
  - 与该语言习惯匹配的清理顺序与线程模型示例（如 R 的 `future::plan("sequential")`、Ruby 的 `at_exit`、Erlang 的 16 分支 receive）。
- **Julia、Delphi 后台形态、R、Erlang 明确“不要求做 UI”**——他们的价值在专业 API，不在界面。

---

### C 类：本身有高级 UI 生态的开发者
**典型语言**：Pascal/Delphi（LCL/VCL/FMX）、C#（WPF/WinForms）、Java（JavaFX）、Swift（SwiftUI）、TS/JS（Web 前端）

**真实定位**：双重角色——既是自身业务开发者，也是 **A 类语言团队借用高级 UI 能力的供给方**。

**LF 补齐策略：保持自身业务开发 + 作为 UI 宿主/渲染引擎的供给方**
- **自身业务**：用本语言成熟的 UI 框架开发，LF 负责调度后端专业节点。
- **对外供给**：为 C++/Rust/Python/Go 团队提供“高级 UI 宿主模板”和“渲染引擎级 UI 示例”，让他们把 UI 层交给本语言，自己专注核心。
- **交付物**：
  - UI 宿主模板（LCL/WPF/JavaFX/SwiftUI/Web 渲染前端）；
  - 渲染引擎级 UI 示例（实时图像/视频、交互式可视化、专业工具面板）；
  - UI 事件 → LF Call → 结果回填的范式代码；
  - 跨语言二进制大对象显示的端到端 PoC。
- **Swift** 需注明 macOS/Linux 部署路径待实测；**TS/JS 浏览器端**只做 Caller，不做 Service。

---

## 三、逐语言对照表

| 语言 | 归类 | LF 补什么 | UI 形态 | 关键交付 |
|------|:----:|-----------|---------|----------|
| C++ | A | 高级 UI + 渲染引擎宿主 | 由 Pascal/C#/Java/TS 提供 | UI 宿主模板、二进制句柄 PoC、`LF_LoadLibrary`/MSVC `/utf-8` 说明 |
| Rust | A | 高级 UI + 渲染引擎宿主 | 同上 | UI 宿主模板、闭包异步、`catch_unwind` |
| Python | A | 高级 UI + 渲染引擎宿主 | 同上（非 Tkinter） | `@expose`、Future、HTTP 网关、UI 宿主示例 |
| Go | A | 高级 UI + 渲染引擎宿主 | 同上 | Service 侧 `CGO_ENABLED=1`、UI 宿主模板 |
| Zig | A | 高级 UI + 渲染引擎宿主 | 同上 | 锁定 0.17.0、UI 宿主模板 |
| Node.js/TS（后端） | A | 高级 UI + 渲染引擎宿主 | Web 渲染前端 | `exports` 加 `./dist/`、timer 不 `unref` |
| R | B | 最前沿 API | OS 自带/CLI/Notebook | `lf_poll` 循环、`future::plan("sequential")` |
| Julia | B | 最前沿 API | OS 自带/CLI/Notebook | 强制 `--threads=2`、Notebook 集成 |
| Fortran | B | 最前沿 API | OS 自带/CLI | 数值 Service、编译器同源提醒 |
| Delphi（后台） | B | 最前沿 API | OS 自带/CLI/简单窗口 | EasyCS 后台模板、类 Python API |
| Erlang | B | 最前沿 API | OTP 控制台/CLI | 16 分支 receive、二进制 wire、OTP 27+ |
| Ruby | B | 最前沿 API | CLI/简单 Web | `CallFuture`、`at_exit` 清理顺序 |
| Pascal/Delphi（UI 形态） | C | 供给 UI 宿主 | LCL/VCL/FMX 高级 UI | UI 宿主模板、渲染引擎示例 |
| C# | C | 供给 UI 宿主 | WPF/WinForms | `CallbackDispatcher`、库不能有 `Main` |
| Java | C | 供给 UI 宿主 | JavaFX | JDK 22+ FFM、UI 宿主模板 |
| Swift | C | 供给 UI 宿主 | SwiftUI | SPM 模板、macOS/Linux 待测 |
| TS/JS（前端） | C | 供给 Web 渲染 UI | Web 渲染前端 | 浏览器仅 Caller、`bridge.py` |
| Dart | A/C 交界 | 移动 UI + 高级渲染宿主 | Flutter | Flutter Web 不可用、Service 放服务器 |
| PHP | B | 最前沿 API（仅 Caller） | 无 UI | 经 `bridge.py` HTTP/JSON |

---

## 四、落地建议

1. **先定归类，再给模板**：每个团队接入前先标注 A/B/C 类，避免“C++ 团队只拿 CLI”或“R 团队被逼学 Qt”。
2. **A 类必须给高级 UI 测试与渲染引擎宿主**：这是他们语言生态最缺的，不能只给文本界面。
3. **B 类必须给最前沿 API**：异步/Future/类型安全/JSON 桥接/Notebook 集成，UI 偏中即可。
4. **C 类既是开发者也是 UI 供给方**：保持自身业务，同时为 A 类提供 UI 宿主与渲染引擎模板。
5. **限制前置**：JDK 22+、Julia `--threads=2`、Zig 0.17.0、Erlang OTP 27+、PHP 仅 Caller、Flutter Web 不可用，必须在接入清单首屏提示。
6. **验证路径统一**：先跑 LF `test/` 机理测试，再做本团队 App 层 PoC；A 类的 UI 宿主与核心节点分进程验证，B 类先验证 API 再谈 UI，C 类先验证 UI 宿主再接 A 类核心。