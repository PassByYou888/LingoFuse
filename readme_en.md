# LingoFuse

> Chinese version: [readme.md](readme.md)

> **A distributed-systems foundation. Cross-language, cross-process, cross-machine; supports both backend and frontend at the same time.**
>
> No IDL, no stub generation, no HTTP services. A function written in any language can be called directly by any other language.
>
> **Positioning**: LingoFuse is not just "cross-language RPC" — it is the communication substrate for **multi-application composition in frontier programs** and for **multi-physical-hardware composition**, and the collaboration substrate for **multi-language team ecosystem complementarity**.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Languages](https://img.shields.io/badge/languages-18%20first--party%20%2B%2030%20via%20tools-blue)]()
[![Latency](https://img.shields.io/badge/same--machine%20IPC-%3C1ms-brightgreen)]()

> **A note from the author**: LingoFuse is a framework I use myself, open-sourced under MIT on the side. It has no funding goal, no commercialisation roadmap and no community-operations plan — the purpose of open-sourcing is to **help everyone**, nothing else. Its kernel was forged in **single-day PB-scale real traffic**, not assembled in a lab. I could not find an equivalent combination in the open-source ecosystem, which is why it can build architectures others cannot — for why it is not cheaply replicable, see [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems_en.md). Branch projects (pasAgent-v3, cppAgent, etc.) will go stale, but LF as the foundation will not. Few stars, low popularity — but this is a growing project that keeps evolving. See [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake) below.

---

## Where you are now

If this is your first time opening this repository, read in this order — each step takes only a few minutes, and by the end you will know whether to go deeper or pick another solution.

1. **[What this is](#what-this-is)** — three minutes on exactly what problem LingoFuse solves
2. **[Usage threshold](#usage-threshold-this-is-frontier-tech-not-plug-and-play)** — honestly: it is not for everyone; first confirm you are a target user
3. **[Why it is needed](#why-it-is-needed)** — how it differs from gRPC / REST / message queues
4. **[Quick start](#quick-start)** — the shortest path on Windows, with nothing to compile
5. **[Language support](#language-support)** — pick the language you know best and continue in its directory

If you have already decided to use it, jump straight to [Language support](#language-support) or [Quick start](#quick-start). If you want to understand the internals, pick one of the 17 short notes in [Technical notes · kernel and applications](#technical-notes--kernel-and-applications) — each stands alone; the fuller mechanism knowledge base is [Z.LingoFuse.md](Z.LingoFuse_en.md). If you want to see all documents at once, jump to [Document index](#document-index). If you are a team lead, read [Multi-language team collaboration strategy](#multi-language-team-collaboration-strategy) and [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake) first.

---

## What this is

LingoFuse is a **distributed-systems foundation**.

When most people first hear "cross-language RPC" they think of gRPC, REST, HTTP POST — solutions to "**process A calls one function in process B**", a **point-to-point** problem. LingoFuse solves something else: "**how do multiple processes, multiple machines, multiple kinds of hardware, multiple languages and multiple applications compose into one runnable system**".

In other words, it provides a foundation for both sides at once:

- **Distributed backend foundation**: how servers, backend services, AI Agent backends, compute nodes and storage nodes discover, route, load-balance, reconnect and keep stable sessions with one another. Backends may share a language or differ; they may be on one machine or across machines and IDCs.
- **Distributed frontend foundation**: how clients, Agent front ends, devices, browsers, mobile and embedded systems attach to the system — via native FFI (desktop/mobile/embedded) or HTTP bridging (browsers/constrained devices). The front end may be one machine or tens of thousands of devices.

Cross-language, cross-process and cross-machine are its **technical means**, not its positioning. The real positioning: **make "distributed composition" a default capability rather than infrastructure that must be assembled separately.**

Why "foundation" rather than "framework"? Because a framework dictates what building you put up; a foundation does not — but it guarantees the building will not collapse. And the foundation grew out of real production traffic (see [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake) below), rather than being designed on paper.

### The two kinds of AI-era composition problem it targets

LingoFuse addresses two kinds of composition problem taking shape in the AI era:

**Multi-application composition** — a system is no longer one giant application but **a composition of multiple Agents / applications / services**. A coding Agent, a data-querying Agent, a computing Agent and a hardware-interface Agent, written in different languages, running on different machines, need to call and cooperate with one another with state isolation and fault isolation. LingoFuse makes their communication as simple as an in-process function call — no gateway, IDL or stub code per combination.

**Multi-physical-hardware composition** — a system is no longer one machine but **a composition of machines, hardware kinds and compute types**. GPU nodes for inference, CPU clusters for data processing, embedded devices for acquisition, workstations for visualization. They need to compose into one unified compute pool, dispatched by task, routed by load and transported by data shape (binary frames, video frames, matrices, tensors). LingoFuse's C4 mesh, P2P load, sequenced family and binary handles are designed for exactly this.

If you are interested in the mechanics of P2P distributed load (the three addressing modes, UID universal routing, local short-circuit, server-side local handling, the sequenced family and high-traffic computation), read [LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept_en.md) — it explains the concepts clearly, but it is not an API manual.

### The core promise in one sentence

**A function written in any language can be called directly by any other language; an application on any machine can compose directly with an application on any other machine.**

- No IDL
- No stub generation
- No HTTP services
- Same-machine IPC latency claimed < 1 ms
- Native cross-machine support with built-in service discovery, load balancing, FIFO ordering and reconnection
- First-party bindings for 18 languages, 20+ languages covered through code generators

**Transport security**: same-machine IPC mode (shared memory) is **plaintext** — it works only between local processes, data never leaves the machine, no encryption layer, in pursuit of minimal latency. **TCP mode uses symmetric encryption by default**: the non-IPC branch uses the `SwitchDefaultPerformance` profile, which enables fast encryption and picks an algorithm at random (15 available, including modern ones such as AES-256 and ChaCha and historical ones such as DES and Blowfish); **the current default profile does not enable frame integrity checking (`hsNone`)**, so by default it is "encrypted but unauthenticated" — enough to prevent casual reading of frames, with limited protection against active tampering. **Cross-mesh isolation relies on the password, not on encryption itself** — meshes with different passwords are mutually invisible and unroutable (see [doc/LF_Network_Join.md](doc/LF_Network_Join_en.md)). **Production must change the default password, and sensitive data needs application-layer integrity checks or a higher security encryption profile.**

**It is not universal glue.** Before adopting it, read [Usage threshold](#usage-threshold-this-is-frontier-tech-not-plug-and-play), [Tests and verification](#tests-and-verification) and [Project status and boundaries](#project-status-and-boundaries).

---

## Why it is called RPC: where LF's definition comes from

LingoFuse's positioning did not appear from nowhere; it evolved out of ZNetV2 — understanding that evolution is how you understand "why it is called LingoFuse".

### ZNetV2: an industrial-grade communication engine tempered by single-day PB-scale traffic

[ZNetV2](https://github.com/PassByYou888/ZNetV2) is the communication framework in the PassByYou888 stack aimed at large-scale server-side data throughput. It has **been tempered by single-day PB-scale real production traffic** — the C4 service mesh, dual tunnels, StableIO, the HPC thread pool, command bridge, swap space, handle pool, soft sync and zero-copy mapping were all hammered out of ZNetV2's real production traffic.

But ZNetV2 is **weak** at multi-language collaboration. It was not designed for "multi-language composition" but for "large-scale server-side data throughput". Its interface is native Pascal; other languages must write their own glue.

### The AI era: a single language is no longer enough

The AI era changed one thing: **a single language is no longer adequate**.

The coding Agent may be TypeScript, the data Agent Python, the high-performance compute Agent C++, the hardware-interface Agent C#, the analytics Agent R or Julia, the presentation Agent Dart or Swift. **No single language covers every scenario** — each has its ecosystem strengths and weaknesses.

So a **cross-language collaboration foundation** is needed — one that does not serve one language but treats all equally, and does not serve one scenario but covers both multi-application and multi-hardware composition.

### LF breaks ground: described uniformly as RPC

LingoFuse is that cross-language collaboration foundation. It was born from the "industrial-grade communication engine" kernel of ZNetV2, but its **structural form is very close to RPC** — request-response, one-way notification, sequenced calls, async callbacks, all standard RPC abstractions. At the same time, **it also supports IPC** — same-machine shared memory with latency < 1 ms, which a pure network RPC framework cannot do.

So we use **RPC as the uniform description** of LingoFuse:

- It has RPC's call abstractions (Call / Notify / Sequenced / Async);
- It has RPC's service discovery and load balancing;
- **It also swallows IPC** — shared memory on the same machine, TCP across machines, one API surface, two transport forms;
- **It also swallows multi-language** — 18 bindings sharing one wire format, one handle ownership model, one side-data semantic.

**That is why LingoFuse needs its definition**: it is neither a pure RPC framework nor a pure IPC library but a distributed-systems foundation that "uses RPC as the uniform description to swallow IPC and multi-language collaboration". ZNetV2 is its technical root, RPC its public abstraction, multi-language its user surface — three in one is LingoFuse.

---

## Project nature: personal, open-source, purposeless, sharing for its own sake

> This section answers "what LingoFuse is" even more fundamentally than "what this is". Without it, everything below is easy to misread.

### It is a framework the author uses himself

LingoFuse is not a product written for a startup, a story written for fundraising, or a tutorial written for a community. It is **the framework Lao Zhang uses himself** — he needed a foundation that let his programs in different languages, on different machines, with different hardware talk to one another; nothing on the market did it, so he wrote one.

"Personal use" determines many of its properties: single-person maintenance, no business-layer wrapping, no cross-platform toolchain adaptation, no "install and run", no community operations. These are not defects but the natural result of "a personal framework open-sourced on the side". **It owes no one product-grade delivery.**

### Open-sourced under MIT, to help everyone

The MIT licence means: take it, change it, sell it, no thanks needed. No extra terms, no commercial licensing, no "open-source vs enterprise" dual track.

Why MIT? Because **the purpose of open source is sharing itself**. Lao Zhang does not lack the money this project might bring and does not expect fame from it. He open-sourced it because he knows others in the world need this — people tortured by gRPC's IDL, people tortured by REST's latency, people who want to compose GPU nodes, CPU clusters, embedded devices and workstations into one system, people in the AI era who need multi-Agent collaboration but do not want to write a gateway per combination.

### Vibe-assisted programming + documentation, but not hands-off vibe

LingoFuse's development made heavy use of AI assistance — reading source, organizing documentation, generating test cases, tidying code structure, filling in boilerplate. Lao Zhang calls this AI assistance system "Jarvis".

**But Jarvis is not the driver; it is the construction crew.** Interface design (the 59 exported C ABI symbols, the API shapes of 18 bindings, the handle ownership model, the P2P identity side-data semantics), architectural decisions (C4 mesh scheduling logic, the dual-tunnel system, StableIO reconnect semantics, HPC thread-pool boundaries, the command-bridge pairing matrix) and documentation thinking (why [Z.LingoFuse.md](Z.LingoFuse_en.md) unfolds in the order "threads → callbacks → handles → P2P identity", why [llms.txt](llms.txt) keeps details such as Julia's shim mechanism) — all were proposed by a human.

**Why large architectures cannot be handed to AI? Because large architectures need controllability.** Controllable means every boundary, interface and failure mode must be explainable, measurable and coverable by a human. Nobody has worked night shifts for what AI generates; nobody has carried a production incident for it. Past a certain system size, "looks right" and "is really right in production" are separated by an entire gulf of implicit contracts.

**AI's role in the LF ecosystem is accelerator, not architect.** The premise for a human to be the architect is that LF provides **interface rules a human can audit**. This is expanded in "What AI can and cannot do" under [Usage threshold](#usage-threshold-this-is-frontier-tech-not-plug-and-play).

### LF is language-equal: there is no Pascal bonus

**Let us be clear first: LingoFuse has no Pascal bonus.**

Pascal is the **implementation language** of the core engine — the C4 mesh, dual tunnels, StableIO, HPC thread pool and command bridge were written in Pascal. But **an implementation language is not a privileged language**. LingoFuse exposes **C ABI exported symbols**, which are **completely equal** for all 18 bindings:

- **Equal at the C ABI surface**: Pascal / C++ / Rust / Go / Java / Python / C# / TypeScript / JavaScript / Swift / Zig / Erlang / Ruby / Fortran / Julia / R / Dart / PHP — all 18 bindings access **the same C ABI**. No language has a "native privileged channel".
- **Equal wire format**: all bindings share one wire format — UTF-8 + NUL, little-endian, compact JSON without `\uXXXX` escapes. Cross-language interop is **byte-level**, never "some language first".
- **Equal handle ownership**: the synchronous family belongs to the caller, the async family to the framework — the same rule for all 18. It does not change because "some language is the underlying implementation".
- **Equal side-data semantics**: UID / P2PName are side data written by the sender and read from the callback's `input` — identical for all 18.
- **Equal testing**: each language has its own independent test suite and can run standard tests. There is no "native C ABI first", no "scripting language downgraded", no "implementation-language privilege".
- **Equal generators**: `code_decl_to_abi` covers 17 native-FFI languages and `code_decl_to_json_abi` covers 20+ — the generator favours no language; the Service / Call / Test code it generates is equivalent for every target language.

**Why this must be said**: in many projects where the kernel is implemented in one language, the implementation language naturally acquires a "home-field bonus" — kernel language first, others second-class. **LingoFuse is not like that.** Pascal is merely an implementation language that any other language could replace; the kernel it writes is exposed through the C ABI and used equally by 18 languages.

**"Pascal backend form" in the team strategy is not a statement of language status**: references in `LingoFuse_Team_Complementarity_Strategy.md` to "the Pascal backend form as an API node" and "Pascal demoted to tooling" are about **division of team labour** — let the Pascal team do toolchains and backend nodes, let Java/C# teams do the comprehensive engineering core. That is **team role**, not **language status**. LingoFuse itself treats Pascal and Python identically: what Python can do Pascal can do, and vice versa.

**One sentence**: **LF is language-equal, with no Pascal bonus.** Pascal is an implementation language, not a privileged one; all 18 bindings are first-party, with no primary/secondary; the C ABI is the only entry point and the same rules apply to every language.

### No equivalent combination found in the open-source ecosystem

LingoFuse's combination — zero IDL + 18 native FFIs + binary wire format + handle ownership + P2P side data + dual tunnels + StableIO + HPC + command bridge + C4 mesh + sequenced family — has no fully equivalent combination in the open-source world.

gRPC has IDL, stubs and multi-language support, but no handle ownership model, no P2P side data, no C4 mesh, no dual tunnels. REST / HTTP POST work across machines but have no FIFO, no service discovery, no zero-copy. Message queues (Kafka / RabbitMQ / NATS) are distributed but have no native FFI, no zero-IDL, no handle ownership. In-process solutions (PyO3 / napi-rs) are low-latency but neither cross-language nor cross-machine.

**Finding no equivalent combination means two things**: it can build architectures others cannot — free of the "standard RPC architecture" straitjacket, Lao Zhang can design to real needs; and **it is not cheaply replicable**. On the second point, [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems_en.md) has the full argument — the core is **implicit-contract density**: the expert embeds defensive design in the kernel without documenting it, and AI generating the periphery from the surface interface unknowingly depends on those hidden behaviours. Once density passes a threshold, the cost of fully describing the system ≥ the cost of redesigning an equivalent one. **A replicator can get the code but not the expert's "I knew downstream would use it this way".**

### Why replication is hard: the system is vast

**LingoFuse's system is itself vast and dense, hard to replicate** — it is not something "read the source once" can copy:

- **18 language bindings**: each has its own FFI boundary handling, callback threading model, handle ownership implementation, cleanup order and platform traps. 18 bindings means 18 sets of implicit contracts; reading them one by one takes years.
- **C4 service mesh**: multi-node discovery, cross-node routing, dual tunnels, StableIO reconnect semantics, HPC thread-pool scheduling, command-bridge pairing matrix.
- **Kernel mechanisms**: handle pool, soft sync, zero-copy mapping, sequenced family, swap space, swap-the-container-under-lock-and-work-outside, TBigList iterator semantics, TCritical recycle pool, thread-pool pick policy.
- **Knowledge base**: 194 pitfall IDs, 17 technical notes, deployment guides for 18 languages, Z.LingoFuse.md v4.0 rebuilt from source.

These **cannot be reconstructed by AI from training data** — because no such architecture exists in the training data. AI can read the source and replicate the surface interface; it cannot replicate "why Julia forces `--threads=2`", "why R's `LF_Call` is not reentrant", "why async-family handles are released the moment the callback returns" — the implicit contracts.

**Privatisation will naturally sediment the organisation's own implicit contracts** — if adopters add organisation-specific mechanisms in their private branch (business-specific defensive checks, custom routing stickiness, custom cleanup order, internally agreed status codes, hidden fields for tracing), those become the organisation's implicit contracts, which AI cannot infer from public source. This is not "designed to be unreplicable"; rather **any real privatisation naturally sediments organisation-specific implicit contracts** — which is the core point of `LingoFuse_Private_Fork_Playbook.md`: the goal of privatisation is not copying code but building the organisation's own implicit-contract system.

### The kernel: tempered by single-day PB-scale traffic

LingoFuse's core is not "an RPC framework someone wrote". Its kernel — the C4 engine, handle pool, soft sync, thread pool, zero-copy, sequenced family, dual tunnels, StableIO, HPC, command bridge, swap space — was **hammered out of single-day PB-scale real traffic**.

This is no lab toy. It is a distributed kernel that grew in real production through high concurrency, heavy traffic, long runtimes and every edge case. Its design trade-offs (stability over concurrency performance, pooled recycling, swap-the-container-under-lock-and-work-outside, zero-copy mapping, soft sync instead of kernel sync) were **forced by real traffic**, not copied from textbooks.

### Branch projects go stale; LF does not

Many branch projects sit on top of LingoFuse — pasAgent, pasAgent-v3, cppAgent, csharpAgent and the forthcoming tsAgent. They are **buildings erected on LF**, experiments and demos the author made while chasing frontier technology.

**Buildings go stale; foundations do not.** pasAgent-v3's multimodal capability, cppAgent's C++ ecosystem access, csharpAgent's .NET runtime — those specific Agent implementations will be updated, replaced and retired as AI technology evolves. But the LF beneath them is the framework the author **custom-built over years of chasing frontier technology** — it chases no single wave but the long-term trend of "multi-application + multi-hardware composition".

### Few stars, low popularity, but a genuinely growing project

GitHub star count is not the right metric for an infrastructure project. LingoFuse has few stars and little popularity — consistent with its nature: it chases no trends, panders to no crowd, markets nothing. Its readers are architects and integration engineers, not people who "want a demo running in five minutes".

**But do not be fooled by appearances.** LingoFuse is a genuine **growing project**: its positioning is "distributed-systems foundation", whose value rises as AI-era demand for multi-application and multi-hardware composition explodes. Its kernel came out of PB-scale traffic, an engineering foundation that does not depreciate with star counts. Its 18 bindings, 20+ generator coverage, complete test system and complete knowledge base are **capabilities already built**, not slides.

**It does not need to be popular now; it needs to be ready when needed.** AI Agent boom, multi-language composition boom, multi-hardware boom, edge computing boom — any wave in the world's tech circles could lift it.

---

## Usage threshold: this is frontier tech, not plug-and-play

First, the nature of the thing: **LingoFuse is frontier infrastructure, not a business framework.** It solves low-level problems most teams never touch — cross-language byte-level interop, C4 mesh scheduling, FFI bindings for 18 languages, multi-threaded callback safety, the handle ownership model. **These things let it do what others cannot, and they demand far more of users than an ordinary library.**

### It solves the hardest problems

- **Language-agnostic wire format**: byte streams written by a CrossNode in any language can be read back exactly by a CrossCall in any language.
- **Strongly typed calls with zero IDL**: C++ declares `int Add(int a, int b)`, and C# / Rust / Swift / Java can call `Add(1, 2)` directly — no `.proto`, no stubs.
- **Real service discovery + load balancing + FIFO + reconnection**: no etcd, no Nginx, no hand-written retry.
- **18 language bindings**: from ASM-level C ABI to Dart / Julia / R, each with its own passing test system.
- **Multi-application / multi-hardware distributed composition**: backend services, AI Agents, compute nodes, clients and devices all compose, route and isolate on one foundation.
- **Multi-language ecosystem complementarity**: not every language doing full stack, but collaborating by team strategy — see [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy_en.md) and [LingoFuse_Team_Complementarity_Strategy.md](LingoFuse_Team_Complementarity_Strategy_en.md).

### It leaves you the most complex burden

LingoFuse **does not** do the following:

- **No business-layer wrapping**. It gives you `LF_Call` / `LF_Notify` / `LF_RegisterCall`; how you structure your App layer, split services and enforce permissions is your engineering decision.
- **No thread abstraction**. Callbacks run on TCompute worker threads, not the main thread; never call blocking LF functions inside a callback or you self-deadlock; synchronous callbacks need `LF_Sync` driven by the main thread. These are not things "one read of the docs" tells you; they need repeated debugging in your own code to become muscle memory.
- **No cross-platform toolchain adaptation**. Each binding has compile-time traps: Java needs JDK 22+, Fortran needs C++ and Fortran compilers from the same distribution, Ruby needs DevKit, Julia forces `--threads=2` and Swift's macOS / Linux paths are still being verified. You must handle these yourself.
- **No "install and run"**. The core dynamic library and generator tools have **prebuilt artefacts** (see [Quick start](#quick-start)), but if your platform has no prebuilt version you must still build it. [Binary/](Binary/) provides only Windows 32/64-bit prebuilt libraries; Linux / macOS need building per [src/CONTRIBUTING.md](src/CONTRIBUTING_en.md).
- **No community support**. Single-person maintenance: issues get answered, but no SLA is promised; no Stack Overflow Q&A, no third-party tutorials.

### Four questions to self-test before adopting

1. **Can you build the LingoFuse core dynamic library yourself?** Prebuilt artefacts can carry you past this step — but only if your platform and target-language combination are covered. If not, you still need to be able to build.
2. **Can you understand the callback threading model and systematically avoid deadlocks in your own code?** LingoFuse runs callbacks on worker threads — the basis of all correctness and the easiest place to err. If nobody on the team can explain "why you cannot call `LF_Call` in a callback", do not use it yet.
3. **When problems arise, will you read source rather than comments?** The docs include the 194 pitfall IDs of [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide_en.md), generator reports for 20+ languages and [Z.LingoFuse.md](Z.LingoFuse_en.md) v4.0 — but **comments are second-hand information**. Only source can explain the truly bizarre behaviours.
4. **Are you willing to do an App-layer PoC rather than trust any number in the README?** [test/](test/) provides mechanism-level race-stability tests, not your business-layer tests. Latency, concurrency and success rates in the README are based on the author's hardware and scenarios, not yours.

**If the answer to any of the above is "no" or "not willing", choose gRPC / REST / an in-process solution instead.** LingoFuse will not solve these for you — it provides the foundation; you design the building.

**Conversely**: if you can answer "yes" to all four and genuinely need cross-language, cross-process, zero-IDL, low-latency native RPC, or need to compose multiple applications/hardware into a distributed system, LingoFuse is one of the most serious implementations you will find.

### What AI can and cannot do: be careful with "AI-driven LingoFuse"

**The conclusion first: do not have AI "drive" LingoFuse to build your project from scratch. That route multiplies the schedule by several times.**

AI can do a lot in the LingoFuse ecosystem — read generator sources, read pitfall records, drive the Tools generators via MCP, write App-layer code to the contracts, write test assertions. These are capabilities LingoFuse explicitly designs for AI. But AI cannot do one thing: **design your architecture**.

LingoFuse does not prescribe how your App layer is split — how services divide, how the mesh topology is laid out, who owns handle lifetimes, how the callback thread pool isolates from your business pool, when to use P2P groups versus UID routing, how firewall / ports / certificates are configured across machines. These are engineering decisions LingoFuse deliberately leaves to you — not because it cannot, but because only your business context can decide.

Faced with these, AI will — honestly, following the "standard RPC architecture" in its training data — hand you a plausible plan missing critical constraints. You may discover 48 hours later that it chose the wrong topology (P2P group routing where you needed UID targeting), or missed the iron rule "never call blocking LF in a callback", and deadlocked under load. **That is the peculiar predicament of LingoFuse's frontier-tech nature:** the lower-level the problem it solves, the more easily AI's "common sense" misleads you — because most training data contains no such architecture.

**The right way**: get LingoFuse running first (see the PoC path in [Tests and verification](#tests-and-verification)) → design the first architecture yourself (even a draft must state clearly "which process is the service, which is the call, who is responsible for what, which addressing the routes use") → write a minimal cross-language call by hand in your most familiar language and confirm the wire format, callback threads and handle ownership behave as expected → **then** bring AI in to accelerate Tools usage, read pitfall records, add tests, generate boilerplate.

**That way AI is an accelerator, not the driver.** You own whether the architecture is right; AI owns whether the code is fast. That is also how LF itself is developed — Lao Zhang uses "Jarvis" to assist with code, documentation and tests, but interface design, architecture decisions and documentation thinking are all human. **Humans set architecture and direction; AI helps execute and organize.**

On "why an equivalent LF remains engineering-infeasible to replicate even with AI having read all source and docs", see [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems_en.md).

---

## Why it is needed

The current reality of cross-language, cross-process calls:

- **gRPC**: needs IDL, stub generation, gateways; cross-language, but no direct support for "multi-application / multi-hardware composition".
- **REST**: high latency, no streaming, no service discovery.
- **HTTP POST**: naturally cross-machine but no ordering guarantees, no service discovery.
- **In-process calls**: extremely low latency but neither cross-language nor cross-machine.

### Two kinds of composition problem that existing solutions do not address directly

**Multi-application composition** — in an AI system, the coding Agent, data Agent and compute Agent are written in different languages and run on different machines. They must discover, route and isolate one another. Existing solutions either wrap every Agent as an HTTP service (high operational cost, no native FIFO, no native back-pressure) or build a centralized message bus (single point, single language).

**Multi-physical-hardware composition** — GPU nodes, CPU clusters, embedded devices and workstations must compose into one compute pool. Existing solutions rely on K8s + message queues (unfriendly to data shapes: video frames, matrices and tensors need binary channels) or hand-written sockets (extremely high engineering cost).

LingoFuse's design targets both at once: **C4 mesh** for multi-node discovery and routing, **P2P load + sequenced family** for multi-worker composition, **binary handles + zero-copy** for heavy-traffic data shapes, **18 bindings** for multi-language composition, **HTTP bridging** for constrained platforms (browser / mobile / embedded).

### Stability before concurrency performance

LingoFuse puts application stability first and concurrency performance second. This is not a temporary trade-off but a trend every future version will keep. A communication layer that occasionally crashes, loses messages or deadlocks under high concurrency is worthless however low its latency. Therefore this project **makes no horizontal concurrency-performance comparisons in the main README**; measured data lives in [test/](test/).

---

## Quick start

### Path A: use prebuilt artefacts directly (Windows, recommended first try)

If you are on Windows and just want to get it running before deciding, **you need to compile nothing**. Download from [release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build):

- **Generator tools** (Windows prebuilt): executables for `code_decl_to_abi` / `code_decl_to_json_abi` / `code_decl_to_mcp`;
- **Dynamic libraries** (Windows prebuilt): `LingoFuse64.dll` / `LingoFuse32.dll` / `z_ipc_*.dll` / `mimalloc*.dll`.

Put the libraries on `PATH` or next to the executable and run the generators. **This is the shortest path.** Platform/language combinations not covered by prebuilt artefacts (Linux / macOS libraries, generator tools for some languages) still require building from source per path B.

[Binary/readme.md](Binary/readme_en.md) lists every DLL's role and the PATH configuration; if you hit "module not found" on Windows, read the VC++ redistributable section there first.

### Path B: build from source and verify

**Step one: clone**

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
# then add the LingoFuse/Binary directory to the system PATH
```

**Step two: read the test guides and run the prebuilt executables**

Go into [test/](test/) — it has three guides: [LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide_en.md) on functional tests, [LingoFuse_Stress_Test_Guide.md](test/LingoFuse_Stress_Test_Guide_en.md) on stress, [LingoFuse_Concurrent_Notify_Demo.md](test/LingoFuse_Concurrent_Notify_Demo_en.md) on concurrent notify. Unzip [test.zip](test/test.zip) and run the prebuilt executables. **What you get is real data from your own hardware.**

**Step three: enter the language directory you use and run that language's tests per its README**

All 18 bindings **have independent test systems** and can run standard tests:

- C++ in [cpp/test/](cpp/test/) (functional) + [cpp/Stress/](cpp/Stress/) (stress) + [cpp/Conc/](cpp/Conc/) (concurrency)
- Python in [Py/lingofuse/](Py/lingofuse/) (pytest)
- C# in [csharp/test/](csharp/test/) (in-house TestCase/TestRunner)
- Rust in [rust/tests/](rust/tests/) (cargo test)
- Go in [go/test/](go/test/) (go test)
- Java in [java/src/test/](java/src/test/) (JUnit 5)
- TypeScript / JavaScript in [ts/test/](ts/test/) and [js/test/](js/test/) (Node tests)
- Swift in [swift/Tests/](swift/Tests/) (XCTest)
- Zig in [zig/tests/](zig/tests/) and [zig/examples/](zig/examples/) (zig build test + smoke programs)
- Erlang in [erlang/test/](erlang/test/) (EUnit)
- Ruby in [ruby/test/](ruby/test/) (minitest)
- Fortran in [fortran/c_ext/](fortran/c_ext/) (in-house assertions)
- Julia in [julia/test/](julia/test/) (in-house assertions)
- R in [r/c_ext/tests/](r/c_ext/tests/) (in-house assertions + five-step chain)
- Dart in [dart/test/](dart/test/) (Dart test)
- Pascal in [pascal/](pascal/) (in-house suite)

Pick your language, enter its directory and run the tests per its README. **There is no "one language's tests take priority" — all languages can run standard tests.**

**Step four: build a PoC with your own business scenario**

LingoFuse provides race-stability tests (mechanism level), not your App-layer tests. Simulate your own App layer and verify LF's behaviour in your business scenario.

---

## Language support

### First-party bindings (in-repo)

Each language directory has its own README, test system and examples. Pick the one you know best and click through:

| Language | Directory | Status | One line |
|------|-----|------|-------------|
| C# / .NET | [csharp/](csharp/) | 🟢 Production ready | v5.1, ~60 tests (in-house TestCase/TestRunner), P/Invoke + RAII + unified JSON I/O + `CallbackDispatcher` + callback-style async |
| C++ | [cpp/](cpp/) | 🟢 Production ready | Native C ABI at zero overhead, async model + side-data reading |
| Dart | [dart/](dart/) | 🟢 Production ready | Full caller + server capability, Flutter mobile works; C bridge solves cross-thread synchronous callbacks |
| Erlang | [erlang/](erlang/) | 🟢 Production ready | OTP 27+, cross-platform NIF build, full C ABI wrapping, zero runtime dependency |
| Fortran | [fortran/](fortran/) | 🟢 Production ready | 474 assertions, `iso_c_binding` + C++ bridge, Fortran 2008 |
| Go | [go/](go/) | 🟢 Production ready | purego without cgo, cross-compile friendly; deadlock watchdog compensating runtime misjudgement |
| Java | [java/](java/) | 🟢 Production ready | JDK 22+ FFM API, pure Java without JNI; 145 tests, `ArenaReaper` handles timeout stubs |
| JavaScript | [js/](js/) | 🟢 Production ready | v2.0, 223 tests, CommonJS + ESM dual entry, byte-level interop with TS |
| Julia | [julia/](julia/) | 🟢 Production ready | C shim + `@threadcall` cross-thread callback isolation, **forces `--threads=2`** |
| Pascal | [pascal/](pascal/) | 🟢 Production ready | Native FFI; full guide in [LingoFuse_Pascal_Complete_Guide.md](pascal/LingoFuse_Pascal_Complete_Guide_en.md) |
| Python | [Py/](Py/) | 🟢 Production ready | Works after `pip install -e .`, includes `@expose` decorator and HTTP gateway; knowledge base includes handle ownership + side-data corrections |
| R | [r/](r/) | 🟢 Production ready | Four-layer architecture + Job queue cross-thread callbacks; RAII handles; string / binary dual mode; R 4.6.1 + Rtools45 |
| Ruby | [ruby/](ruby/) | 🟢 Production ready | v2.0, 331 tests, Fiddle + C extension, full caller / server two-way capability |
| Rust | [rust/](rust/) | 🟢 Production ready | v2.0, 174 tests, closure-style async, `call_async_wait` returns `Vec<u8>` |
| Swift | [swift/](swift/) | 🟢 Production ready | v1.1, 261 XCTest cases, `@convention(c)` callbacks, C++ ↔ Swift byte-level two-way interop verified |
| TypeScript | [ts/](ts/) | 🟢 Production ready | v2.0, 223 tests, supports Node / Deno / Bun, three styles × three addressing modes |
| Zig | [zig/](zig/) | 🟢 Production ready | Pinned Zig 0.17.0, `c/lf_json.cpp` keeps JSON byte-identical, ~50 test blocks plus smoke programs |
| PHP | [php/](php/) | 🟡 Caller access | Through the [Py/lingofuse/bridge.py](Py/lingofuse/bridge.py) HTTP gateway; caller only |

**The global view**: if you want to know "why a language has to do it this way" — why Julia forces `--threads=2`, why Ruby needs a hand-written C extension, why R cannot be published on CRAN — [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide_en.md) has 194 pitfall IDs and 18 bindings laid out one by one; [LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0_en.md) has per-language toolchains, hard version requirements and deployment checklists.

> **Again**: the 18 languages above are all **first-party bindings** of equal standing; there is no "home language" or "second-class language". Pascal is the kernel's implementation language, but at the binding layer it is exactly like the others — `LF_CreateData` / `LF_Call` / `LF_Get_P2P_UID` all go through the same C ABI. See "LF is language-equal: there is no Pascal bonus" under [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake).

> These 18 languages are not an isolated list but a system collaborating by ecosystem complementarity. See [Multi-language team collaboration strategy](#multi-language-team-collaboration-strategy) below.

---

## Multi-language team collaboration strategy

LingoFuse's 18 bindings are not "every language does full stack" but **a system collaborating by ecosystem complementarity**. Onboarding support and the "servitude" strategy are two complementary documents.

### [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy_en.md) — team onboarding support strategy

- **Clustering**: strong implementation languages (C++ / Rust / Zig), backend-strong languages (Go / Erlang), comprehensive engineering languages (Java / C#), specialist API nodes (Julia / R / Fortran / Python / Ruby), front-end UI suppliers (Dart / Delphi / Pascal UI / TS/JS / Swift), toolchain and service side (Pascal backend form / LingoFuse-Tools).
- **Filling weaknesses**: strong implementation languages lack high-level UI → LF provides UI hosts; backend languages lack a front end → LF provides Web/CS front ends; closed ecosystems lack frontier APIs → LF provides modern API wrappers; engineering languages take the core → the toolchain supports them.
- **Deliverables**: limits checklist, service/call templates, UI or API host templates, shared-contract training, mechanism PoC path, binary/JSON dual-channel examples, toolchain usage guide.
- **Roadmap**: cluster first then assign work; give class A high-level UI incentives, class B front-end support, class C the principal engineering role, class D an explicit API-supplier role, class E respect at the UI layer, class F toolchain and mechanism PoC paths.

### [LingoFuse_Team_Complementarity_Strategy.md](LingoFuse_Team_Complementarity_Strategy_en.md) — ecosystem complementarity and value-maximisation strategy

- **Internal "servitude" is not pejorative**; it means letting each language team contribute willingly in its strongest field while using a unified architecture to cover its weaknesses, maximising overall system value.
- **Core operating principle**: fix the target language's weaknesses and let a unified full-stack language height do high-end development across the board.
- **Class-based "servitude" strategy**: class A strong implementation languages do the local core + high-level UI incentive; class B backend languages do the backend core + front-end support; class C engineering languages do the principal engineering + toolchain support; class D specialist API nodes do statistics/numerics/algorithm services; class E front-end UI languages act as UI suppliers; class F scripting/glue languages act as API nodes.
- **Per-language table**: "what we let them do / what we fill in / UI form" for every language at a glance.

**Note**: "the Pascal backend form as an API node" and "Pascal demoted to tooling" in the team strategy are **division of team roles**, not **language status**. LingoFuse itself treats all 18 languages equally; see "LF is language-equal: there is no Pascal bonus" under [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake).

---

## Code generator system · LingoFuse-Tools

LingoFuse's first-party bindings are **hand-written**. Rolling the same API set across a dozen languages turns hand-writing into repetitive labour — and a single byte off in any language's wire format makes cross-language interop fail silently.

[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) solves exactly this: **starting from one API declaration (a Pascal unit or C header), it automatically produces multi-language service / call code, test programs and build scripts**.

Tools is not a single generator but **three parallel tool lines** sharing one parser, one LV1 model and one type system:

- **`code_decl_to_abi`** — the LingoFuse binary ABI. For scenarios where both ends are LF-native, with high concurrency and numeric/binary-heavy payloads.
- **`code_decl_to_json_abi`** — HTTP + JSON (through `bridge.py`). For browsers, external HTTP clients, or languages with no LF binding.
- **`code_decl_to_mcp`** — MCP. Exposes functions as tools AI Agents can call.

> One declaration, three paths. Change the declaration once and ABI / JSON / MCP artefacts refresh together. You never get "ABI changed this function but MCP still has the old signature".

### Target languages covered by the generators

Tools covers **20+ target languages**, each with service side, call side, test programs and a `setup_*_tests.ps1` environment script. Its backend is designed to be **infinitely extensible** — adding a language is a mechanical 8-step process, not an architecture change. Service / Call support for the main target languages (full matrix and platform support in the [LingoFuse-Tools repository](https://github.com/PassByYou888/LingoFuse-Tools)):

- **Both Service and Call**: C#, C++, Dart, Erlang, Fortran, Go, Java, Julia, Node.js, Pascal, Python, R, Ruby, Rust, Swift, TypeScript, Zig
- **Call only** (cannot act as a Service because the native library cannot be loaded): JavaScript (browser), PHP, Delphi

**Key boundary**: the Service side must run on desktop / server (Windows / Linux / macOS). **iOS / Android / WASM / embedded cannot run a Service** — the LingoFuse native library does not support those platforms. When mobile needs an interface, deploy the Service on a server and let mobile act as a Caller through bridging.

**Generators are equal across languages**: the 17 native-FFI languages covered by `code_decl_to_abi` produce artefacts of exactly equal standing — a C++ Service and a Python Service speak the same wire protocol, a Rust Call and a Swift Call read the same bytes. The generator favours no language and has no special path because "some language implements the kernel".

### The generators are not a black box

The Tools repository also carries three classes of readable assets: generator sources (each language's service / call / test / setup generator is an independent implementation unit), the input contract (which declarations are extracted and which silently dropped, documented in more detail than most IDL docs), and pitfall records per language (where "I thought" was overturned by measurement — wire-format misalignment, callback thread hangs, `int64` precision loss in JS, `bridge.py` precheck cache delays causing `-3` errors, etc.).

AI can read those generator sources and pitfall records to take over the **use** of the toolchain — but not your **architecture**. See "What AI can and cannot do" under [Usage threshold](#usage-threshold-this-is-frontier-tech-not-plug-and-play).

### Relationship with the first-party bindings

The first-party bindings are hand-written, 18 of them, each with an independent test system; the Tools-generated bindings come from Pascal / C declarations, 20+, each with test programs and setup scripts. **The two do not conflict** — Tools-generated bindings share the same wire-format contract; one of the generator's core design constraints is "byte-for-byte alignment with C++". If your project needs one language, use the first-party binding; if you need the same API set across many languages, use Tools.

👉 **[Visit the LingoFuse-Tools repository for generator sources, input contracts and pitfall records](https://github.com/PassByYou888/LingoFuse-Tools)**

---

## Technical notes · kernel and applications

Seventeen short notes, each about one mechanism or one application decision. No repetition of the full documents — only "why it is designed this way" and "where the pitfall is". Each has a concise flow diagram and a contract table.

**LF kernel: how the mechanisms work**

- [LF_Handle_Ownership.md](doc/LF_Handle_Ownership_en.md) — synchronous-family handles are yours, async-family handles are the framework's; mixing them always blows up
- [LF_Simulated_Main_Thread.md](doc/LF_Simulated_Main_Thread_en.md) — LF builds a background thread to drive C4, but **deliberately does not** drive `LF_Sync`
- [LF_WaitOnResult.md](doc/LF_WaitOnResult_en.md) — only one Call may be in flight per IO; Notify is unaffected
- [LF_Sequenced_FIFO.md](doc/LF_Sequenced_FIFO_en.md) — FIFO comes from "one thread per `(App, API)`", a very fine granularity; mixing calls scrambles it
- [LF_ZeroCopy_Decode.md](doc/LF_ZeroCopy_Decode_en.md) — decoding does not do a single memcpy; it maps with zero copy
- [LF_SwapUnderLock.md](doc/LF_SwapUnderLock_en.md) — LF never iterates inside a lock; it swaps the container inside and works outside
- [LF_TBigList_Iterator.md](doc/LF_TBigList_Iterator_en.md) — `Next` moves before it checks, so `while Next` skips the first node
- [LF_ThreadPool_Pick.md](doc/LF_ThreadPool_Pick_en.md) — let idle workers absorb new tasks first; expand only when truly short
- [LF_TCritical_Reuse.md](doc/LF_TCritical_Reuse_en.md) — create a hundred thousand critical sections and handles barely rise, thanks to the recycle pool
- [LF_P2P_Identity.md](doc/LF_P2P_Identity_en.md) — UID and P2PName are **side data sent by the sender**, not something looked up

**LF applications: decisions built on these mechanisms**

- [LF_Cmd_Model_Choice.md](doc/LF_Cmd_Model_Choice_en.md) — ask "is a response needed" first, then "is throughput sufficient"; the model follows
- [LF_Route_Choice.md](doc/LF_Route_Choice_en.md) — App name finds a service, UID finds a client, P2PName finds a group; a wrong choice does not error, it drifts
- [LF_Startup_Order.md](doc/LF_Startup_Order_en.md) — the startup order must not be scrambled; scrambling is silent failure (connection up but calls never work)
- [LF_Error_In_Callback.md](doc/LF_Error_In_Callback_en.md) — throwing in a callback equals not throwing; convey errors at the protocol layer
- [LF_Reconnect_Strategy.md](doc/LF_Reconnect_Strategy_en.md) — LF only gives disconnect signals; reconnecting is the application's business
- [LF_Concurrent_Send.md](doc/LF_Concurrent_Send_en.md) — `Send*` is thread-safe, handles are not — whoever creates uses and frees
- [LF_Debug_Mode.md](doc/LF_Debug_Mode_en.md) — three debug switches (Quiet / ConsoleOutput / debug) each govern their own area and must be set separately

**Joining the network and security**

- [LF_Network_Join.md](doc/LF_Network_Join_en.md) — joining is mandatory and the password is the only credential; both IPC and TCP require it, and meshes with different passwords cannot see each other

**How to read**: if you just "want to use it", read the seven **application** notes first — they map directly onto architecture decisions; if you "want to know what happens underneath", read the ten **kernel** notes — they explain where the seemingly counter-intuitive constraints of the application layer come from. Joining and security is a separate topic, see [LF_Network_Join.md](doc/LF_Network_Join_en.md).

**A fuller mechanism knowledge base**: [Z.LingoFuse.md](Z.LingoFuse_en.md) is v4.0, rebuilt from source, covering the thread panorama, callback execution context, the handle ownership model, P2P identity side-data semantics, integration guides for difficult languages (Julia / Erlang / R), a counter-example collection and an honest uncertainty list — aimed at deep integrators and architects. If you want the answers to "why async-family handles are released the moment the callback returns", "why Julia forces `--threads=2`", "why R's `LF_Call` is not reentrant", this is it.

---

## Document index

If you want all documents at once, here is the complete index of the root and doc directories.

### Root core documents

| Document | Content |
|------|------|
| [llms.txt](llms.txt) | LLM entry point: a knowledge-base summary for AI |
| [Z.LingoFuse.md](Z.LingoFuse_en.md) | Internal mechanism knowledge base v4.0 (source-rebuilt) |
| [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems_en.md) | Why an equivalent LF is engineering-infeasible to replicate cheaply |
| [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide_en.md) | Multi-language complete guide (v2.0, 194 pitfall IDs) |
| [LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0_en.md) | Per-language deployment guide (v3.0) |
| [LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept_en.md) | P2P distributed load concepts |
| [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy_en.md) | Multi-language team onboarding support strategy |
| [LingoFuse_Team_Complementarity_Strategy.md](LingoFuse_Team_Complementarity_Strategy_en.md) | Ecosystem complementarity and value maximisation |
| [LingoFuse_Private_Fork_Playbook.md](LingoFuse_Private_Fork_Playbook_en.md) | Privatisation playbook |
| [optimal_and_correct_technology_stack_selection.md](optimal_and_correct_technology_stack_selection_en.md) | Tech-stack selection reference (the lesson of Hejlsberg choosing Go) |

### doc/ directory: kernel and application notes

| Document | One line |
|------|--------|
| [LF_Handle_Ownership.md](doc/LF_Handle_Ownership_en.md) | Synchronous handles are yours, async handles are the framework's |
| [LF_Simulated_Main_Thread.md](doc/LF_Simulated_Main_Thread_en.md) | The simulated main thread deliberately does not drive LF_Sync |
| [LF_WaitOnResult.md](doc/LF_WaitOnResult_en.md) | Only one Call may be in flight per IO |
| [LF_Sequenced_FIFO.md](doc/LF_Sequenced_FIFO_en.md) | FIFO via one thread per (App, API) |
| [LF_ZeroCopy_Decode.md](doc/LF_ZeroCopy_Decode_en.md) | Decoding does not do a single memcpy |
| [LF_SwapUnderLock.md](doc/LF_SwapUnderLock_en.md) | Swap the container inside the lock, work outside |
| [LF_TBigList_Iterator.md](doc/LF_TBigList_Iterator_en.md) | Next moves before it checks |
| [LF_ThreadPool_Pick.md](doc/LF_ThreadPool_Pick_en.md) | Idle workers first; expand only when short |
| [LF_TCritical_Reuse.md](doc/LF_TCritical_Reuse_en.md) | Critical sections have a recycle pool |
| [LF_P2P_Identity.md](doc/LF_P2P_Identity_en.md) | UID/P2PName are side data sent by the sender |
| [LF_Cmd_Model_Choice.md](doc/LF_Cmd_Model_Choice_en.md) | Ask whether a response is needed, then whether throughput suffices |
| [LF_Route_Choice.md](doc/LF_Route_Choice_en.md) | App name finds a service, UID a client, P2PName a group |
| [LF_Startup_Order.md](doc/LF_Startup_Order_en.md) | The startup order must not be scrambled |
| [LF_Error_In_Callback.md](doc/LF_Error_In_Callback_en.md) | Throwing in a callback equals not throwing |
| [LF_Reconnect_Strategy.md](doc/LF_Reconnect_Strategy_en.md) | Reconnecting is the application's business |
| [LF_Concurrent_Send.md](doc/LF_Concurrent_Send_en.md) | Send* is thread-safe, handles are not |
| [LF_Debug_Mode.md](doc/LF_Debug_Mode_en.md) | Three debug switches, each with its own area |
| [LF_Network_Join.md](doc/LF_Network_Join_en.md) | Joining is mandatory; the password is the only credential |

---

## Agent runtimes

LingoFuse is a **communication foundation**. The foundation itself does not do applications, but many buildings can stand on it.

Agent runtimes built on LingoFuse:

- [LingoFuse-pasAgent](https://github.com/PassByYou888/LingoFuse-pasAgent) (Pascal) — text Agent, 129+ LLM backends
- [LingoFuse-pasAgent-v3](https://github.com/PassByYou888/LingoFuse-pasAgent-v3) (Pascal) — multimodal Agent, 250+ backends, dual-language code generation
- [LingoFuse-cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent) (C++) — C++ ecosystem Agent access
- [LingoFuse-csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) (C# / .NET) — .NET Agent runtime + LLM client SDK
- LingoFuse-tsAgent (TypeScript) — **coming soon**; the current TS/JS bindings are a pure communication layer without an Agent runtime. To build Agents in TS/JS today, use mature frameworks such as Mastra or the Vercel AI SDK and call other languages' functions through LingoFuse's TS bindings.

On branch projects going stale: the Agent runtimes above are **buildings erected on LF**, experiments and demos the author made while chasing frontier technology. They will be updated, replaced and retired as AI technology evolves — which is normal. **Buildings go stale; foundations do not.** LF itself chases no single wave but the long-term trend of "multi-application + multi-hardware composition". See "Branch projects go stale; LF does not" under [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake).

---

## Related projects

- [zIPC](https://github.com/PassByYou888/zIPC) — the same-machine IPC engine underneath LingoFuse. Use it directly when you need only same-machine IPC without a full RPC mesh.
- [ZNetV2](https://github.com/PassByYou888/ZNetV2) — LingoFuse's **technical root**. It has been tempered by single-day PB-scale real traffic and is the industrial-grade communication engine from before multi-language collaboration; LingoFuse evolved from it, swallowing IPC and multi-language collaboration with RPC's unified abstraction (see [Why it is called RPC](#why-it-is-called-rpc-where-lfs-definition-comes-from)).
- [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) — the code generator system producing multi-language bindings from API declarations. Three tool lines: `code_decl_to_abi` (binary ABI), `code_decl_to_json_abi` (HTTP/JSON), `code_decl_to_mcp` (MCP tool provider).

---

## Tests and verification

**The [test/](test/) directory is authoritative.**

If you are unsure about any claim in the README — latency, ordering, stability, behaviour under concurrency — do not guess; verify with the artefacts in [test/](test/).

test/ provides part of the PoC (proof of concept) work. When using the LingoFuse system in a product, note: the author provides race-stability tests (the most important mechanism-level tests), not your App-layer tests; users need the skill to build and compile LF (LingoFuse is developed by Lao Zhang; if it goes unmaintained for long, users must build it themselves to keep up with generation updates).

**Every language has its own test system, runnable by users. All languages can run standard tests.** The 18 bindings each ship an independent suite — C++ functional/stress/concurrency, Python pytest, C# in-house TestCase/TestRunner, Rust cargo test, Go go test, Java JUnit, TypeScript/JavaScript Node tests, Swift XCTest, Zig zig build test, Erlang EUnit, Ruby minitest, Fortran in-house assertions, Julia in-house assertions, R in-house assertions + two-process demo, Dart Dart test, Pascal in-house suite. **There is no "one language's tests take priority"** — pick your language, enter its directory and run per its README.

### Putting testing capability in users' hands

LingoFuse is a combination of 18 languages × Windows / Linux / macOS × IPC / TCP / cross-machine deployment. Rather than cramming those combinations into some hosted environment, **testing capability is put directly in users' hands**: test/ provides complete guides (Markdown) and prebuilt executables ([test.zip](test/test.zip)). Unzip, run and observe on your own machine and you get **real data from your own hardware**.

### Test guides and executables

- [LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide_en.md) — functional tests: 82 items covering the C++ RAII layer and the serialization layer. Executables: `test_lingofuse` / `test_lingofuse_json`.
- [LingoFuse_Stress_Test_Guide.md](test/LingoFuse_Stress_Test_Guide_en.md) — stress tests: Call / Notify / mixed modes, reporting throughput, latency and stability. Executables: `StressService` / `StressClient` / `StressMonitor`.
- [LingoFuse_Concurrent_Notify_Demo.md](test/LingoFuse_Concurrent_Notify_Demo_en.md) — concurrent Notify: 20 batches × 10000 messages, zero loss, including the completion-barrier pattern. Executables: `ConcService` / `ConcClient`.

### Test scale at a glance

| Language | Framework | Tests | Platform verified |
|------|----------|:------:|----------|
| Ruby | minitest | 331 | Windows x64; Linux / macOS untested |
| Fortran | in-house assertions | 474 | Windows x64; Linux / macOS untested |
| Julia | in-house assertions | 431 + 4 scenarios | Windows x64; Linux / macOS untested |
| Swift | XCTest | 261 | Windows; macOS / Linux untested |
| TypeScript | Node tests | 223 | Windows / Linux / macOS |
| JavaScript | Node tests | 223 | Windows / Linux / macOS |
| R | in-house assertions + two-process demo | 211 + five-step chain | Windows x64 (R 4.6.1 + Rtools45) |
| Rust | cargo test | 174 | Windows / Linux / macOS |
| Python | pytest | 155 | Windows / Linux / macOS |
| Java | JUnit 5 | 145 | Windows / Linux |
| Zig | Zig test + smoke programs | ~50 test blocks | Windows x64; Linux / macOS / 32-bit untested |
| C# | in-house TestCase/TestRunner | ~60 | Windows |
| C++ | in-house | 82 + stress + concurrency | Windows / Linux |
| Erlang | EUnit | four suites | Windows; Linux / macOS untested |
| Go | go test | 18 | Windows / Linux / macOS |
| Dart | Dart test | full suite | Windows / Linux / macOS |
| Pascal | in-house | full development suite | Windows / Linux |

Note on figures: the "tests" column counts test items / suites per language; the "assertion counts" in each language README (e.g. Fortran's 474 assertions) may exceed the item counts here. **Exact numbers are whatever the test code in each directory and actual runs say; the numbers here may lag code evolution, so the source is authoritative.** See each language directory for details.

---

## Cross-language interop (Cross Demo)

LingoFuse's core idea is **"a function written in any language can be called directly by any other language"**. To validate that promise, **every binding ships three programs named "Cross"**: `CrossService` (coordinator / beacon) creates the IPC endpoint `ipc:cross`; `CrossNode` (worker) registers the `add` / `inv_seri` APIs of the `demo` application; `CrossCall` (load-test client) hammers the `demo` application with 32 threads for 10 seconds.

Shared wire-format contract: `add (int32 a, int32 b) -> int32`; `inv_seri (uint8, uint16, uint32, uint64, string(NUL), float) -> reversed types`. String = UTF-8 + NUL; integers = little-endian; floats = IEEE 754 little-endian. **If a `CrossCall` in any language correctly reads bytes written by a `CrossNode` in another language, those two languages are 100% interoperable.**

Cross Demo locations: Pascal in [pascal/cross_demo/](pascal/cross_demo/), C++ in [cpp/CrossDemo/](cpp/CrossDemo/), C# in [csharp/CrossService/](csharp/CrossService/) / [csharp/CrossNode/](csharp/CrossNode/) / [csharp/CrossCall/](csharp/CrossCall/), Swift in [swift/Sources/CrossService/](swift/Sources/CrossService/) / [swift/Sources/CrossNode/](swift/Sources/CrossNode/) / [swift/Sources/CrossCall/](swift/Sources/CrossCall/), Zig in [zig/examples/](zig/examples/) ([cross_service.zig](zig/examples/cross_service.zig) / [cross_node.zig](zig/examples/cross_node.zig) / [cross_call.zig](zig/examples/cross_call.zig)), Erlang in [erlang/cross/](erlang/cross/), Ruby in [ruby/cross/](ruby/cross/), Fortran in [fortran/cross_demo/](fortran/cross_demo/), Julia in [julia/example/](julia/example/) ([CrossService.jl](julia/example/CrossService.jl) / [CrossNode.jl](julia/example/CrossNode.jl) / [CrossCall.jl](julia/example/CrossCall.jl)), R in [r/c_ext/tests/cross_node.R](r/c_ext/tests/cross_node.R) (with [r/c_ext/tests/cross_client.cpp](r/c_ext/tests/cross_client.cpp)), Rust in [rust/examples/](rust/examples/), Go in [go/cross/](go/cross/) ([README](go/cross/README.md)), TypeScript in [ts/cross/](ts/cross/), JavaScript in [js/cross/](js/cross/), Python in [Py/cross/](Py/cross/) ([Cross_Demo_Guide_zh.md](Py/cross/Cross_Demo_Guide_zh_en.md)), Java in [java/src/main/java/lingofuse/demo/cross/](java/src/main/java/lingofuse/demo/cross/), Dart in [dart/bin/](dart/bin/) (the probe includes Cross scenarios).

Verified interop directions: Swift ↔ C++, Zig ↔ C++ / C# / Rust / Go / Python / JavaScript, Erlang ↔ C++ / C# / Python / JavaScript, Ruby ↔ C++ / C# / Python / JavaScript, Fortran ↔ C++, Julia ↔ C++ / C# / Pascal / Python / JavaScript, R ↔ C++, Pascal ↔ C++, C# ↔ C++, Rust ↔ C++ — all byte-compatible or verified.

---

## Dependencies

### Prebuilt dynamic libraries (Windows, recommended)

Download the Windows prebuilt libraries from [release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build): Windows 64-bit needs `LingoFuse64.dll` + `z_ipc_64.dll` + `mimalloc64.dll`; Windows 32-bit needs `LingoFuse32.dll` + `z_ipc_32.dll` + `mimalloc32.dll`.

**Linux / macOS libraries** must be built yourself per [src/CONTRIBUTING.md](src/CONTRIBUTING_en.md). The prebuilt libraries in [Binary/](Binary/) match the Windows artefacts from `release pre_build`; if you already downloaded from `pre_build` you need not copy from [Binary/](Binary/).

### The in-repo Binary/ directory

[Binary/](Binary/) provides Windows 32/64-bit prebuilt libraries (same origin as pre_build); on Linux the artefacts are `liblingofuse.so` + `libz_ipc.so` + `libmimalloc.so` (optional), on macOS `liblingofuse.dylib` + `libz_ipc.dylib` + `libmimalloc.dylib` (optional).

**Deployment**: add [Binary/](Binary/) to the system `PATH`, or copy the libraries next to the executable.

On Windows you need the **VC++ 2015-2022 redistributable** ([latest supported Visual C++ redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170), [vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe), [vc_redist.x86.exe](https://aka.ms/vs/17/release/vc_redist.x86.exe)). Detailed runtime dependency notes are in [Binary/readme.md](Binary/readme_en.md).

---

## Building the core dynamic library

If your platform / architecture is not covered by `release pre_build` or [Binary/](Binary/) (e.g. Linux / macOS libraries, generator tools for a specific architecture), build from source.

[src/](src/) is the only build entry point for the LingoFuse core dynamic library (`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`). Prepare the FPC / Lazarus toolchain, then build in one shot.

Build docs: [src/CONTRIBUTING.md](src/CONTRIBUTING_en.md) (build environment setup and workflow overview — the entry for a first compile), [src/CONTRIBUTING_lazbuild.md](src/CONTRIBUTING_lazbuild_en.md) (one-shot lazbuild CLI build; includes manual LoongArch64 steps), [src/FPC_3.3.1_Package_Info.md](src/FPC_3.3.1_Package_Info_en.md) (FPC 3.3.1 environment package info), [src/Lazarus_Change_FPC.md](src/Lazarus_Change_FPC_en.md) (switching FPC versions in Lazarus).

One-shot build:

```bash
cd src
lazbuild LingoFuse.lpi
```

**Note**: the FPC toolchain is version-pinned — all build machines must use the same FPC 3.3.1 sources, otherwise you get `PPU version mismatch`. See [src/CONTRIBUTING.md](src/CONTRIBUTING_en.md). **The Linux / macOS build path is not systematically verified** — the current source contains Windows-style backslashes in include paths, which Linux FPC does not parse; using those platforms requires editing the build scripts, see [src/CONTRIBUTING.md](src/CONTRIBUTING_en.md).

---

## Project status and boundaries

This table lists **capabilities already built**, not "planned capabilities". LF has few stars, but its 18 bindings, 20+ generator coverage, complete test system and complete knowledge base are **working artefacts**. Do not measure an infrastructure project by star count; see "Few stars, low popularity, but a genuinely growing project" under [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake).

- **Core communication layer**: ✅ Stable (C4 engine, binary frames, handles, soft sync and thread pool all in place)
- **Eighteen first-party bindings**: ✅ Production ready (C# / C++ / Dart / Erlang / Fortran / Go / Java / JavaScript / Julia / Pascal / Python / R / Ruby / Rust / Swift / TypeScript / Zig / PHP; PHP as caller)
- **Multi-language team collaboration strategy**: ✅ Complete ([LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy_en.md) + [LingoFuse_Team_Complementarity_Strategy.md](LingoFuse_Team_Complementarity_Strategy_en.md))
- **HTTP bridging**: ✅ Available (`bridge.py` gateway covering Node.js / PHP / browsers)
- **Code generator system**: ✅ Complete ([LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools): three lines ABI / JSON / MCP, 20+ target languages)
- **AI knowledge base**: ✅ Complete (covers every interface, can help AI take over the interface and boilerplate layers — not the architecture layer, see [Usage threshold](#usage-threshold-this-is-frontier-tech-not-plug-and-play))
- **Internal mechanism knowledge base**: ✅ Complete ([Z.LingoFuse.md](Z.LingoFuse_en.md) v4.0, aimed at difficult languages, including handle ownership + P2P identity side data)
- **P2P distributed concepts**: ✅ Complete ([LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept_en.md))
- **Joining and password**: ✅ Documented ([doc/LF_Network_Join.md](doc/LF_Network_Join_en.md)) — but the default password, failure behaviour and multi-server unification rules still need source verification
- **Architectural irreplicability**: ✅ Complete ([LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems_en.md) — implicit-contract density, AI takeover boundaries)
- **LLM entry point**: ✅ Complete ([llms.txt](llms.txt))
- **Technical notes (kernel + applications)**: ✅ Complete (17 notes + 1 joining document)
- **Test system**: ✅ 18 languages each with an independent suite users can run; **all languages can run standard tests**
- **Cross-platform support**: ⚠️ **Windows verified; Linux / macOS must be verified by you** — cross-platform multi-language programming support is currently lacking (some bindings are incomplete off Windows; the Linux / macOS build path is unverified), and cross-platform mixed-language scenarios need your own verification
- **Transport security**: ⚠️ IPC mode (shared memory) is plaintext (works only between local processes); TCP mode uses symmetric encryption by default (the `SwitchDefaultPerformance` profile, 15 algorithms including historical ones such as DES), and the current default profile does not enable frame integrity checking (`hsNone`); **production must change the default password**, and sensitive data needs application-layer integrity checking or a higher security encryption profile
- **Prebuilt artefacts**: ✅ Windows available ([release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build): generator tools + libraries; Linux / macOS require your own build)
- **tsAgent**: 🚧 Coming soon (TypeScript / JavaScript Agent runtime)

---

## Licence

**MIT** — take it, change it, sell it, no need to thank me.

**This is not a pleasantry.** LingoFuse was born to share, not to make money. MIT is the legal expression of that attitude — no extra terms, no commercial licensing, no "open-source vs enterprise" dual track. See [Project nature](#project-nature-personal-open-source-purposeless-sharing-for-its-own-sake).

---

## About the author

**Lao Zhang (QQ: 600585)**

Annoyed that cross-language calls demanded a pile of glue code, he built LingoFuse. Then annoyed that every language needed hand-written bindings, he finished the code generators too. Then he fed the knowledge base to AI and let AI take over the interfaces entirely.

**Let all programming languages speak as equals** — not a slogan, but something happening right now.

### I am human, and I typed this out myself

LingoFuse is a project **hand-built by a real human author**. AI played an **assisting role** — helping organize documentation, generate test cases, tidy code structure. But the project's **soul** — architecture decisions, the design of byte-level cross-language interop, C4 mesh scheduling logic, how a dozen-plus bindings attach — all came from a real human's repeated late-night debugging and thinking.

**The interfaces and architecture were Lao Zhang's; so was the documentation thinking.** "Jarvis" (Lao Zhang's AI assistance system) executes, organizes, adds tests and generates boilerplate — but Jarvis is not the driver, it is the construction crew. LF's knowledge base is so detailed because Lao Zhang knows where integrators will get stuck — learned from real pitfalls across a dozen-plus bindings, not inferred by AI from training data.

You can read **["LingoFuse · Fourteen Languages Field Notes"](https://zpascal.net/imhuman.html)**, which records the full process:

> Those dark windows on the screen are from two straight nights of work. No editing, no scripted compositing, no staged shots. Some commands I typed wrong three times before they ran; some environments I installed until dawn before discovering a version problem. Errors were errors, warnings were warnings, passes were passes.

The notes record real details: paging line by line through the 71 KB `NativeMethods.cs` in VS 2022, a C++ binding build with 14 projects and 0 warnings, a stress panel showing 46,515 cumulative calls and a 100.00% success rate, a Dart environment that took nearly two hours to install but ran its tests in 8 seconds, environments installed until dawn before finding a version problem.

**AI is a tool, not the author.** From the first line of core code to the eighteenth binding, this project rests on one real human's judgement, trial and persistence.

### Why open-source

Because of **sharing itself**. Lao Zhang does not lack the money this project might bring and does not expect fame from it. He open-sourced it because he knows others in the world need this — people tortured by gRPC's IDL, people tortured by REST's latency, people who want to compose GPU nodes, CPU clusters, embedded devices and workstations into one system, people in the AI era who need multi-Agent collaboration but do not want to write a gateway per combination.

**LingoFuse was never positioned to make money; it exists to be shared.** That is why MIT, why no community operations, why no chasing trends — it simply puts the foundation there for whoever needs it.

### Few stars, but a growing project

GitHub star count is not the right metric for an infrastructure project. LF has few stars, but: it chases the long-term trend of "multi-application + multi-hardware composition", not a single wave; its kernel came out of single-day PB-scale real traffic, not a lab; its 18 bindings, 20+ generator coverage, complete test system and complete knowledge base are **working artefacts**.

**It does not need to be popular now; it needs to be ready when needed.** Any wave in the world's tech circles could lift it.

You are welcome to say hi, to criticise, to send PRs — **a Star is the best encouragement.**

---

*The project began in 2026 and keeps evolving. File issues for problems; for urgent matters add Q (600585).*

**Before adopting, be sure to: run [test/](test/), build a PoC, verify your own scenario.**


