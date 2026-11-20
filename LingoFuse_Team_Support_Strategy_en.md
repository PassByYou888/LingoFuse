# LingoFuse per-language team onboarding support strategy

> Chinese version: [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md)

**File name**: `LingoFuse_Team_Support_Strategy.md`

> This strategy was rebuilt after a deep analysis of the READMEs of LingoFuse's 18 language bindings, `LingoFuse_MultiLanguage_Complete_Guide.md`, the main repository README and the LingoFuse-Tools knowledge base. Core position: **support does not mean doing everything for a team; it means respecting the capability boundaries of the target language, using LF to patch the weaknesses, connect the strengths, and state the contracts clearly**.

---

## 1. Knowledge-base insight summary (the factual basis of this strategy)

Six facts distilled from the LF knowledge base that directly constrain the support strategy:

| # | Insight | Implication for the support strategy |
|:-:|------|------------------|
| 1 | **Only C++ has GitHub-hosted CI among the 18 bindings**; the rest rely on local test scripts | The support strategy must front-load "CI is missing"; teams must own regression verification themselves |
| 2 | **Large test suites ≠ production validation** (Ruby 331, Fortran 474, Julia 431); they validate binding compatibility, not business load | What support delivers is a "mechanism PoC path", not a "production-ready promise" |
| 3 | **Callback threading model, handle ownership and cleanup order are cross-language shared contracts**; only the API names differ | Support must include "shared-contract training", otherwise any language team hits the same set of pitfalls |
| 4 | **Platform hard limits are dense**: Java JDK 22+, Julia `--threads=2`, Zig pinned to 0.17.0, Erlang OTP 27+, PHP Caller only, Flutter Web unusable | The first screen of the support checklist must list the limits so teams do not invest in the wrong stack |
| 5 | **iOS/Android/WASM cannot run a Service**; mobile can only act as a Caller | When Dart/Swift builds the front end, the Service must be deployed on a server, and the support strategy must say so |
| 6 | **The three tool lines in LingoFuse-Tools cover 17 native FFIs + 20+ JSON flavours**, but the generators run no CI and output must be verified manually | Toolchain support must distinguish "code generation" from "production validation" |

---

## 2. Language clusters and support strategy

Clustering is based not on "language strength" alone but on **ecosystem structure + the actual limits recorded in the LF knowledge base**.

### Cluster one: strong implementation languages — C++, Rust, Zig

**Knowledge-base facts**: strong local implementation capability (compression/encryption/decoding/algorithms) but lacking a high-level UI ecosystem; C++ has Qt but a steep learning curve, Rust's egui/iced are early, Zig's ecosystem is thin. C++ is the only one with CI; Rust panics must go through `catch_unwind`; Zig is pinned to 0.17.0.

**Support strategy: base system + local core + high-level UI incentive**
- **We provide**: the LF transport layer, service discovery, handle pool, lifecycle management, high-level UI host templates (FMX/LCL/WPF/JavaFX/Web rendering).
- **They implement**: compression, encryption, decoding, CV algorithms, compute kernels and other local cores.
- **Support deliverables**: base-system skeleton + local implementation interfaces + high-level UI host templates + binary large-object (image/frame/matrix) transport PoC.
- **Front-loaded limits**: C++ must call `LF_LoadLibrary` first and use MSVC `/utf-8`; Rust `catch_unwind`; Zig 0.17.0.

### Cluster two: backend-strong languages — Go, Erlang

**Knowledge-base facts**: Go excels at high concurrency and Erlang at OTP fault tolerance, but both lack front-end presentation; the Go Service side needs `CGO_ENABLED=1`; Erlang needs 16-branch receive, binary wire format and OTP 27+, and a NIF crash takes BEAM down.

**Support strategy: leave the backend alone + provide the front end (Web/CS)**
- **Let them focus**: Go on high-concurrency services, Erlang on OTP fault-tolerant services.
- **We fill in**: a Web front end (TS/JS-rendered) or a CS front end (Pascal LCL/FMX, C# WPF, JavaFX), so backend results can be displayed, operated and monitored.
- **Support deliverables**: backend Service templates + Web/CS front-end host templates + the paradigm "front-end event → LF Call → backend service → result fill-back" + binary/JSON dual-channel examples.
- **Front-loaded limits**: Go `CGO_ENABLED=1`; Erlang OTP 27+, 16-branch receive, NIF isolation.

### Cluster three: comprehensive engineering languages — Java, C#

**Knowledge-base facts**: strongest at engineering, enterprise-grade and large-system construction; Java needs JDK 22+ FFM, C# libraries must not have a `Main`, and both have mature UI frameworks (JavaFX/WPF).

**Support strategy: principal engineering role + Pascal toolchain demoted to a tooling role**
- **Respect their capability**: Java/C# own large business systems, enterprise frameworks and the comprehensive engineering core.
- **Pascal demoted to tooling**: do not compete for the principal role; provide LF code generators, debugging tools, scaffolding and MCP tools for Java/C# developers.
- **Support deliverables**: Java/C# principal-engine templates + the Pascal toolchain (code generation/debugging/scaffolding) + LF integration examples + engineering best practices.
- **Front-loaded limits**: Java JDK 22+; C# libraries with no `Main`; the Pascal toolchain's usage must be documented.

### Cluster four: specialist API nodes — Julia, R, Fortran, Python, Ruby, PHP (Caller only)

**Knowledge-base facts**: strong at specialist computation, statistics, numerics, scripting and algorithms; each has hard limits: Julia `--threads=2`, R non-reentrant and not CRAN-eligible, Fortran compiler must be the same lineage, Python async handle callbacks release on return, Ruby's `at_exit` cleanup order, PHP only acts as a Caller through `bridge.py`.

**Support strategy: cutting-edge API wrappers + explicit role as API suppliers + no mandatory UI**
- **Define the role**: any server-plus-frontend architecture needs APIs — go to them. They provide statistical computation, numeric kernels, algorithm services, script glue and Web/API services.
- **We fill in**: cutting-edge API wrappers (async/Future, type safety, JSON/HTTP bridging, Notebook/CLI integration, P2P registration, UID addressing).
- **No mandatory UI**: the OS's own windows, a CLI or a Notebook will do.
- **Support deliverables**: cutting-edge API wrapper templates + Notebook/CLI integration examples + simple OS-native dialog examples + that language's cleanup order and threading model.
- **Front-loaded limits**: Julia `--threads=2`; R `lf_local_call` + `future::plan("sequential")`; Fortran same-lineage compiler; PHP Caller only.

### Cluster five: front-end UI hosts — Dart, Delphi (UI form), Pascal (UI), TS/JS (front end), Swift

**Knowledge-base facts**: mature high-level UI frameworks exist (Flutter, VCL/FMX, LCL, Web rendering, SwiftUI); Flutter Web is unusable, Swift on macOS/Linux is untested, TS/JS in browsers is Caller only; mobile cannot run a Service.

**Support strategy: respect their capability at the UI layer + act as UI suppliers**
- **Respect their capability**: they are the front-end UI suppliers — providing high-level UI hosts and render-engine-grade interfaces to cluster one, Web/CS front-end hosts to cluster two, and cross-platform UI supplements to cluster three.
- **Their own business is also scheduled by LF**: build business interfaces in their UI language while LF calls cluster-four API nodes and cluster-one specialist nodes.
- **Support deliverables**: UI host templates + render-engine-grade UI examples (live images/video/visualization) + the paradigm "UI event → LF Call → result fill-back" + binary-object display PoC.
- **Front-loaded limits**: Swift on macOS/Linux untested; Dart Flutter Web unusable; TS/JS in browsers Caller only; Delphi's backend form belongs to cluster four and its UI form to cluster five — the distinction must be explicit.

### Cluster six: toolchain and service side — Pascal backend form, LingoFuse-Tools

**Knowledge-base facts**: Pascal is LF's home ground (native FFI, source of the core engine); LingoFuse-Tools covers 17 native FFIs + 20+ JSON flavours, but the generators run no CI and output requires manual verification.

**Support strategy: toolchain supply + mechanism PoC path**
- **Pascal backend form**: supported as an API node (Python-like wrappers + EasyCS backend examples).
- **LingoFuse-Tools**: provide the code generators (ABI/JSON/MCP lines), debugging tools and scaffolding for all teams; make it explicit that "generated artefacts require manual verification".
- **Support deliverables**: toolchain usage guide + generator sources and pitfall records + mechanism PoC path (run `test/` first, then an App-layer PoC).

---

## 3. Cross-cutting support: shared cross-language contracts

Whichever cluster a team belongs to, onboarding onto LF must explain five groups of shared contracts — the high-frequency pitfall areas the knowledge base keeps stressing:

| Contract | Content | How to support |
|------|------|----------|
| **Callback threading model** | Callbacks run on native worker threads; never block; never call synchronous LF functions | Shared-contract training + language-specific examples |
| **Handle ownership** | The synchronous family belongs to the caller; the async family belongs to the framework and is released immediately when the callback returns; async handles must never be retained across threads | Ownership quick-reference + correct/incorrect examples per language |
| **Cleanup order** | `ExitMainThread → FreeApp → Shutdown`; each language adds extra steps (Ruby `at_exit`, Node/Java `AsyncBridge.shutdownInstance`, Julia `stop_callback_consumer`) | A cleanup-order checklist per language |
| **Side data** | Valid only on the callback Input; `LF_Get_P2P_UID` returns a pointer that expires in 5 seconds; `LF_LocalCall` injects no identity | A side-data usage matrix + code examples per language |
| **Three addressing modes** | App name is local-first; UID is universal routing; P2PName is not local-first; App-name calls never reach P2P registrations | An addressing decision tree + a hit matrix |

---

## 4. Deliverables checklist

Onboard each team with the following, nothing omitted:

| Deliverable | Content | Clusters |
|--------|------|--------|
| **Limits checklist** | Hard thresholds for that language (version, platform, CI status) | All |
| **Service/call templates** | Dual engineering templates for Service and Call | All |
| **UI or API host templates** | Clusters one/two/three/five get UI hosts; cluster four gets Notebook/CLI | By cluster |
| **Shared-contract training** | Callback threads, handle ownership, cleanup order, side data, the three addressing modes | All |
| **Mechanism PoC path** | Run `test/` first, then an App-layer PoC | All |
| **Binary/JSON dual-channel examples** | Binary handles + JSON bridging | Clusters one/two/four |
| **Toolchain usage guide** | The three LingoFuse-Tools lines + notes on verifying generated artefacts | All |

---

## 5. Implementation roadmap

1. **Cluster first, assign work second**: label cluster one through six before onboarding, avoiding "C++ only gets a CLI" or "R is forced to learn Qt".
2. **Give cluster one the high-level UI incentive**: it is what their language ecosystem lacks most and what makes them willing to do local implementation.
3. **Give cluster two front-end support**: a Web or CS front end that makes backend capability displayable and interactive.
4. **Give cluster three the principal engineering role, with Pascal demoted to tooling**: provide code generators, debugging tools and scaffolding.
5. **Define cluster four explicitly as API suppliers**: any server-plus-frontend architecture needing APIs goes to them; no mandatory UI.
6. **Respect cluster five's capability at the UI layer**: as front-end UI suppliers, providing hosts and render-engine-grade interfaces to clusters one and two.
7. **Cluster six supplies the toolchain and the mechanism PoC path**: Pascal backend form as an API node, Tools for code generation and debugging.
8. **Front-load the limits**: JDK 22+, Julia `--threads=2`, Zig 0.17.0, Erlang OTP 27+, PHP Caller only, Flutter Web unusable — all must appear on the first screen of the onboarding checklist.
9. **Unify the verification path**: run LF's `test/` mechanism tests first, then the team's own App-layer PoC; verify UI hosts and specialist nodes in separate processes; verify backend and front end in separate processes; verify an API node's API before discussing UI.
10. **Draw the AI assistance boundary clearly**: AI may take over the interface layer and the boilerplate layer (Tools generators, pitfall-record retrieval, test completion); architecture-layer decisions (topology, route selection, resource boundaries) remain with humans.


