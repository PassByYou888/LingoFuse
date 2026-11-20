# LingoFuse private-fork playbook

> Chinese version: [LingoFuse_Private_Fork_Playbook.md](LingoFuse_Private_Fork_Playbook.md)

**File name**: `LingoFuse_Private_Fork_Playbook.md`

> This is not a "how to fork the code" technical manual. It discusses a more fundamental question: **in the AI era, when compute becomes pervasive and APIs become cheap, where is an organisation's real leverage?** Privatising LingoFuse looks like a technical act but is essentially an act of organisational governance. And the real barrier to privatisation is not the code but **LF's non-replicable mechanism — implicit contracts and the knowledge system**. The goal of your privatisation is not "taking the code away" but "building your organisation's own implicit-contract system".

---

## 1. Get the values straight first: in the AI era the scarce thing is not compute, it is organisation

### 1.1 An easily overlooked equation

Once AI programming is universal, many people's first reaction is "compute matters". But compute is becoming pervasive:

- You have a compute cluster worth 100 million, and another team spends 100 thousand a year on online APIs — in many business scenarios, **the final output is comparable**.
- Ten people collaborating with online APIs may out-produce a single person with top-tier compute several times over.
- Compute costs are falling, API prices are falling, model capabilities are converging — **compute is no longer the scarce resource; the people who can organise compute are**.

This is "all roads lead to the same place": **in an era of abundant compute, the absolute advantage of compute gets diluted while the relative advantage of organisational efficiency gets amplified.**

### 1.2 The real leverage: governing people, governing frameworks

If compute is not scarce, what is?

- **The person who can organise ten people into one efficient unit**;
- **The framework that lets ten people work under one shared set of contracts**;
- **The governance mechanism that lets the framework keep evolving with AI assistance without losing control**.

So **governing people and governing frameworks is itself the way to meet the AI era**. Privatising LingoFuse is a concrete handle on exactly this: it turns "cross-language collaboration" from a technical option into an **organisational technical dependency and collaboration standard**.

---

## 2. LF's non-replicable mechanism: the real barrier to privatisation

### 2.1 Code can be copied; implicit contracts cannot

[`LF-Architecture-Unreplicable-Backend-Systems.md`](LF-Architecture-Unreplicable-Backend-Systems_en.md) in the LingoFuse main repository makes the core argument: **once implicit-contract density passes a threshold, the cost of fully describing the system ≥ the cost of redesigning an equivalent one.**

What is "implicit-contract density"?

- **Explicit contracts** are what is written in documentation, interface signatures and READMEs: the 59 exported C ABI symbols, the three addressing modes, the handle ownership model, the callback threading model.
- **Implicit contracts** are the defensive designs the expert buried in the core but **never fully wrote into the documentation**: why does `LF_LocalCall` not inject identity? Why does a P2PName async Call never fire its callback when the group name is not found? Why is a sequenced thread released one second rather than five after exit? Why does `LF_Get_P2P_UID` return a pointer instead of a value? Why does `LF_ExitMainThread` clear permanent handles?

These implicit contracts **cannot necessarily be inferred by AI even after reading the source** — they come from real pitfalls, production incidents and the judgement "I know downstream will use it this way".

### 2.2 A replicator can take the code but not "I know downstream will use it this way"

That is the essence of LF's irreplicability:

> **A replicator can obtain the code but not the expert's "I knew downstream would use it this way" from when the core was written.**

The 194 pitfall IDs in the LF knowledge base, the real pitfalls recorded for 18 languages, Julia's shim mechanism, R's four-layer architecture, Ruby's GVL routing, Erlang's 16-branch receive, the opposite ownership of the synchronous and asynchronous handle families — **these are not documentation, they are sedimented experience**. They constitute LF's implicit-contract layer and the barrier any forker truly faces.

### 2.3 The real goal of privatisation: build the organisation's own implicit-contract system

Based on this understanding, recalibrate the goal:

> **Privatisation is not "copy the code and rename it" but "build an organisation-internal technical dependency system, contract system and collaboration standard so the team works inside the private system". More fundamentally, it is "capture, sediment and pass on the organisation's own implicit contracts".**

Forking the code is only step one. True privatisation equips the organisation with:

- **The ability to capture implicit contracts**: turning upstream implicit contracts (through pitfalls, tests, source reading) into organisational knowledge;
- **A carrier to sediment implicit contracts**: build systems, binding packages, generators, CI gates, pitfall records;
- **A mechanism to pass implicit contracts on**: so newcomers and AI-assisted developers work inside the organisation's implicit-contract system instead of re-hitting the same pits.

**The depth of privatisation should be decided by "how many of its own implicit contracts the organisation needs to sediment", not by technical difficulty.**

---

## 3. Privatisation tiers: by depth of implicit-contract sedimentation, not technical difficulty

| Tier | Scope | Implicit-contract layer captured | When it applies |
|------|------|------------------|----------|
| **L0 brand layer** | Rename packages, namespaces, docs, examples; core untouched | Almost nothing captured | The organisation only needs to "look like its own" |
| **L1 binding layer** | Privatise the multi-language bindings and package distribution; use the official prebuilt dynamic library | Captures **language-boundary** implicit contracts (callback threads, handle ownership, side data) | Small multi-language teams relying on official capability |
| **L2 dynamic-library layer** | Fork the core dynamic library, establish a patch set and an upgrade system | Captures **technical-root** implicit contracts (C4 scheduling, dual tunnels, StableIO, handle pool) | Core changes are needed; long-term maintenance |
| **L3 engineering layer** | L2 + customized Tools + internal pipeline + governance | Captures **organisation-collaboration** implicit contracts (single source of contract truth, gates, audits, upgrade cadence) | Multi-team collaboration, long-term production engineering |

**The key judgement**: most teams only need to start at L1. **Only when "the depth of implicit contracts the organisation needs to sediment" exceeds "the upstream capability boundary" is L2/L3 worth it.** Privatising for privatisation's sake is a projection of organisational control urges, not a business-value choice.

---

## 4. Stage one: dynamic-library build privatisation — capturing the technical root's implicit contracts

### 4.1 Learn the official build first: establish a "shared language", also the starting point for capturing implicit contracts

Do not start by changing things. First get through the official path:

1. Prepare the FPC / Lazarus toolchain and build the dynamic library per `src/CONTRIBUTING.md`;
2. Run the official `test/` mechanism tests and the `cpp/test` functional tests;
3. Record the build environment, compiler version and dependency versions into a **build baseline document**;
4. **During building and testing, record every "why is it this way" into the organisation's pitfall knowledge base** — that is where implicit-contract capture begins.

**The organisational meaning of this step**: it turns "building" from an individual skill into an organisational capability. **Without a shared language there is no shared governance; without capturing implicit contracts there is no real privatisation.**

**Acceptance**: you can build a dynamic library from source whose behaviour matches the official prebuilt one, and pass the official tests; and the organisation holds a "build-time implicit-contract list" (compiler traps, platform differences, dependency behaviour).

### 4.2 Patch layering: not code layering but a layering of implicit-contract responsibility

Recommended repository structure:

```
lingofuse-private/
├── upstream/                 # official mirror (read-only, for syncing)
├── private/                  # the private fork's main repository
│   ├── branding/             # brand, namespace, copyright (owned by the branding group)
│   ├── build/                # build scripts and CI (owned by the framework group)
│   ├── private-api/          # private API extensions (owned by the API group)
│   ├── core-patches/         # core patches (framework group + upstream PRs)
│   ├── implicit-contracts/   # ★ implicit-contract knowledge base (pitfall records, source interpretation, behavioural conventions)
│   └── tests-private/        # private acceptance tests (owned by the test group)
└── upgrade/                  # upgrade tooling and checklists (owned by the framework group)
```

**The key addition**: the `implicit-contracts/` directory. This is the organisation's own implicit-contract repository — records of upstream pitfalls, source interpretations, behavioural conventions and failure cases. **It is not documentation; it is sedimented organisational experience.**

**Patch layering is in essence the layering of implicit-contract responsibility**: each layer corresponds to one team's boundary of responsibility and to the ownership of one class of implicit contract. The more concentrated and fewer the patches, the lower the marginal cost of upgrading; the more complete the implicit-contract records, the stronger the organisation's ability to absorb upstream changes.

### 4.3 PR strategy: borrow upstream's strength while bringing upstream implicit contracts home

If a change has general value (performance, stability, cross-platform fixes), **submit a PR to Lao Zhang**. This is not "pleasing upstream" but an organisational strategy:

- General improvements go upstream → upstream absorbs them → private patches shrink → upgrade cost drops;
- Private business, branding and private protocols stay in the private layer → upstream stays unpolluted;
- The technical lineage is preserved → the private branch does not drift further and further away;
- **The PR discussion itself is a process of implicit-contract capture** — upstream authors' feedback, maintainers' judgements and pitfall discussions are knowledge the organisation can sediment.

**Organisational meaning**: the PR strategy is "borrowing upstream's strength" so the organisation need not reinvent wheels for general problems; at the same time PR discussion is the window through which the organisation captures upstream implicit contracts.

### 4.4 Upgrade system: control the marginal cost of upgrading, and continuously recalibrate implicit contracts

LingoFuse is a dynamically updated project, so privatisation must leave an upgrade channel:

1. **Keep the `upstream` remote** and fetch periodically;
2. **Base the private branch on upstream tags/commits**, never detached for long;
3. **Replay patches layer by layer**, checking each layer on every upgrade;
4. **Build an upgrade checklist**: upstream diff → patch conflicts → replay → build → official tests → private tests → binding tests → generator tests;
5. **The minimal-change principle**: whatever can be solved by configuration, bindings or generators must not touch the core dynamic library;
6. **Dual-library comparison testing**: run the same test set against the official and private libraries and confirm the behavioural differences are within expectations;
7. **Update `implicit-contracts/` on every upgrade**: what new implicit contracts did upstream add? Did existing contracts change? Did the organisation capture them?

**Organisational meaning**: the upgrade system is about **controlling the marginal cost of upgrading and continuously recalibrating implicit contracts**. The smaller the cost each upstream update imposes and the more complete the captured implicit contracts, the more sustainable privatisation becomes.

**Acceptance**: after an upstream release, you can complete sync, patch replay, build and both test suites within a controllable time (say 1–3 person-days); and `implicit-contracts/` records the new implicit contracts captured by this upgrade.

---

## 5. Stage two: multi-language binding privatisation — capturing language-boundary implicit contracts

### 5.1 Language priority: the team reach, and the coverage of implicit contracts

Do not privatise 18 languages at once. Choose by actual team usage:

- **First priority**: C++, Python, TypeScript, C# (covering algorithms, scripting, front end, desktop);
- **Second**: Go, Java, Rust, Swift, Dart;
- **On demand**: Julia, R, Fortran, Erlang, Ruby, Zig, PHP.

**Organisational meaning**: the criterion for prioritising languages is not "which language is strong" but "**which teams in the organisation can a language reach, and which class of implicit contracts therefore needs capturing**". Privatising bindings is essentially expanding the organisation's technical reach and, with it, the coverage of its implicit contracts.

Each language's privatisation must capture that language boundary's implicit contracts:

- **Python**: async handle callbacks release on return, strong references in ctypes callbacks, `@expose` decorator semantics;
- **C++**: `LF_LoadLibrary()` must be called first, MSVC `/utf-8`, `AsyncResult` err/value semantics;
- **TypeScript**: `exports` must include `./dist/`, `AsyncBridge` timers must not `unref`, `param` deferred dispose;
- **C#**: libraries must not have a `Main`, `TaskCompletionSource` must use `RunContinuationsAsynchronously`;
- **Go**: `sys.LoadLibrary()` must be called first, `CGO_ENABLED=1`, deadlock watchdog;
- **Java**: JDK 22+ FFM, `LibraryLoader.selectPlatformFileName()` must be called first;
- **Rust**: `catch_unwind`, `ABI_TARGET_APP` / `ABI_TIMEOUT` are atomics;
- **Julia**: forced `--threads=2`, `@threadcall` concurrency constrained by libuv;
- **Erlang**: 16-branch receive, binary wire format, NIF crashes dragging BEAM down, OTP 27+.

**These are not documentation; they are implicit contracts the organisation must capture during privatisation.** They belong in `implicit-contracts/`, not only in one person's memory.

**Acceptance goal**: each priority language has a private package, private namespace and private tests, and can call the private dynamic library end to end; and that language's implicit contracts are recorded in the organisational knowledge base.

### 5.2 AI assistance: AI does the mechanical work, humans own the contracts

AI suits mechanical work, but **must not alter wire-format contracts**:

- **AI does**: renaming (package names, namespaces, class names, function prefixes), deleting comments, unifying style, adding tests, running test suites;
- **Humans do**: wire format, byte protocol, callback threading model, handle ownership, cleanup order, side-data semantics — these are **organisational contracts** AI must never change on its own;
- **Humans + AI together**: capture implicit contracts from upstream source and pitfall records and sediment them into `implicit-contracts/`.

**Organisational meaning**: AI is an accelerator, not a contract maker. **Contracts are set by humans, mechanical work is done by AI, implicit contracts are captured by humans + AI** — that is the boundary between organisation and AI in privatisation.

### 5.3 Passing tests: the smallest unit of organisational trust, and the validation of implicit contracts

Acceptance criteria for each language's privatisation:

1. The private package can be built/installed against the private dynamic library;
2. The official test suite for that language (or an equivalent subset) passes fully;
3. Private end-to-end tests pass: Service registration, Call/Notify, the three addressing modes, binary large-object transport;
4. Cross-language interoperation with at least one other language works;
5. The private package's version number, license and NOTICE file are complete;
6. **That language's implicit contracts are recorded in `implicit-contracts/` with corresponding test coverage**.

**Organisational meaning**: tests are **the smallest unit of organisational trust** and the means of validating implicit contracts. Without passing tests, privatisation only "looks like its own" rather than being "trustable by the organisation"; without implicit contracts recorded in the knowledge base, the organisation re-hits the same pits on the next upgrade.

### 5.4 Private packages and distribution: control the entry point and you control collaboration, and the spread of implicit contracts

- Build internal package repositories (npm/private registry, private PyPI, private NuGet feed, private Maven repository, private Cargo registry, etc.);
- Prefix package names with the company prefix to avoid clashing with official packages;
- Keep the MIT LICENSE and upstream copyright notices, adding a NOTICE stating it is based on LingoFuse;
- Bind version numbers to the private dynamic-library version, forming a version matrix;
- **Ship an implicit-contract summary for that language inside the package** (e.g. `IMPLICIT_CONTRACTS.md`), so users meet the organisational contracts the moment they install.

**Organisational meaning**: the package repository is **the entry point of organisational dependency**. Control the entry point and you control where organisational collaboration starts, and the propagation path of implicit contracts.

**Acceptance**: teams `install` the private package, not the official one; the private package locates the private dynamic library automatically; the private package ships an implicit-contract summary.

---

## 6. Stage three: engineering and Tools privatisation — solidifying implicit contracts into the organisational operating system

### 6.1 Team division of labour: from verbal agreement to tool enforcement, and the landing of implicit-contract responsibility

When the team splits into a framework group, an API group and a UI group, privatisation turns the division of labour from "verbal agreement" into "tool enforcement":

- **Framework group**: maintains the private dynamic library, bindings, build and upgrade systems; it is **the guardian of the technical root's implicit contracts**;
- **API group**: defines private API contracts, generates Service/Call code, maintains interface versions; it is **the guardian of interface-boundary implicit contracts**;
- **UI group**: uses private UI host templates and integrates AI APIs (face, detection, OCR, speech, agents); it is **the guardian of UI-integration implicit contracts**;
- **Test/ops group**: runs the private CI, produces test reports, audits dependencies; it is **the guardian of gate and audit implicit contracts**.

**Organisational meaning**: the value of privatisation is making the division of labour **executable, auditable and sustainable**, and giving every class of implicit contract a clear owner — rather than leaving it in meeting minutes.

### 6.2 Modifying the generator: the generator is the compiler of organisational contracts and the solidifying carrier of implicit contracts

LingoFuse-Tools is the key to engineering. Privatisation requires modifying the generator to work the company's way:

- **Naming rules**: private namespace, class names, function prefixes, file names;
- **Directory structure**: generate service/call/test/setup per company engineering standards;
- **Template customization**: logging, error handling, configuration, CI scripts, Dockerfile;
- **Private API contracts**: inject company standards into the input declarations; generated artefacts carry version and audit marks;
- **Test templates**: generate private acceptance tests wired into internal CI;
- **Documentation templates**: generate internal API docs and change records;
- **Implicit-contract injection**: inject comments and defensive checks for organisational implicit contracts at key points in generated code (e.g. "never call synchronous LF functions inside a callback", "async handle callbacks release on return"), **so implicit contracts move from the knowledge base into everyone's daily work**.

**Organisational meaning**: the generator is **the compiler of organisational contracts and the solidifying carrier of implicit contracts**. Changing the generator changes the organisation's collaboration rules — rules move from documents into tools, from tools into daily work, and implicit contracts move from the knowledge base into every generated line of code.

**Note**: the generator itself runs no CI; **you must build your own CI to validate generated artefacts**. After changing the generator, run full-language generation + compilation + testing with a representative set of declarations.

### 6.3 Automated pipeline: every gate is an organisational promise and an implicit-contract checkpoint

Recommended pipeline:

```
API declarations → private generator → Service/Call/Test/Docs → compile → unit tests → cross-language interop tests → private package publish → internal docs update
```

Every step needs an acceptance gate: a generated artefact failing to compile, a failing test, or an inconsistent wire format fails the pipeline. At the same time, **every gate is also an implicit-contract checkpoint**:

- Compile gate: checks platform/compiler implicit contracts (e.g. MSVC `/utf-8`);
- Unit-test gate: checks handle ownership and callback-threading implicit contracts;
- Cross-language interop gate: checks wire format, side data and the three addressing modes;
- Publish gate: checks the version matrix, license, NOTICE and the implicit-contract summary.

**Organisational meaning**: every gate in the pipeline is **the smallest promise of organisational quality and an implicit-contract checkpoint**. The clearer the gates, the more reliable the collaboration; the more complete the implicit-contract checks, the less likely the organisation derails on an upstream upgrade.

### 6.4 Governance mechanism: the core interface of the organisational operating system and the governance of implicit contracts

The internal notion of "enslavement/rule" means **using the privatised system to form a unified technical dependency and collaboration standard**, so teams work with the same toolchain:

- **Unified entry point**: teams obtain dependencies only from the private package repository;
- **Unified contracts**: API declarations are the single source of truth; the generator produces uniform code;
- **Unified UI hosts**: the UI group uses private UI templates and AI API integration templates;
- **Unified audit**: private API registry, version matrix, dependency audit, change records;
- **Unified roles**: framework group owns the foundation, API group the contracts, UI group the hosts, test group the gates;
- **Unified upgrade**: upstream syncing is executed centrally by the framework group; teams do not fork individually;
- **Unified implicit-contract system**: `implicit-contracts/` is the single source of truth for organisational implicit contracts; every team contributes and consults.

**Governance boundary**: unified does not mean rigid. The privatised system must leave extension points, allowing teams to innovate within the contracts but never to bypass the private packages, the private generator, the private test gates or the implicit-contract system.

**Organisational meaning**: the governance mechanism is **the core interface of the organisational operating system and the governance system of implicit contracts**. It defines what can be done, what must follow the unified path and what can be innovated — the watershed that turns privatisation from a "technical fork" into an "organisational capability".

### 6.5 Acceptance checklist

- The private generator can produce Service/Call/Test for at least four priority languages per company standards;
- The generated artefacts compile and pass unit tests and cross-language interop;
- Private CI covers: dynamic-library build, binding tests, generator tests, end-to-end tests;
- The private package repository is usable and the version matrix is clear;
- Internal docs, API registry and audit records are complete;
- **`implicit-contracts/` is established, covering five classes of implicit contract — technical root, language boundary, interface boundary, UI integration, gate audit — with corresponding test coverage**.

---

## 7. Risks, boundaries and recommendations

### 7.1 Rethinking risks from the "implicit contract" angle

| Risk | Looks like | Is really | Mitigation |
|------|----------|--------|------|
| Upstream sync cost | Technical patch conflicts | **The cost of re-capturing implicit contracts** | Patch layering, minimal change, PR general improvements upstream, update implicit contracts on upgrade |
| Single-author risk | Upstream stops maintaining | **Organisational dependency risk + implicit-contract discontinuity** | Keep the ability to build yourself, establish a private build baseline, sediment upstream implicit contracts into the organisational knowledge base |
| AI assistance overstepping | AI breaks the code | **Implicit contracts bypassed** | Manual review of wire formats and contracts; AI only does mechanical work; implicit contracts captured by humans + AI |
| Excessive forking | High technical complexity | **A projection of organisational control urges** | L1 first, then L2/L3; decide depth by value |
| Governance rigidity | Processes too heavy | **Collaboration loses elasticity** | Leave extension points; innovate within contracts |
| Implicit-contract loss | Documentation incomplete | **Discontinuity of organisational memory** | `implicit-contracts/` as the single source of truth, contributed to and consulted by every team |
| License compliance | Legal risk | **Organisational reputation risk** | Keep the MIT LICENSE and NOTICE |

### 7.2 Candid recommendations

- **Get it running before privatising**: get the official build, official tests and official Cross Demo passing before changing anything;
- **L1 first, then L2/L3**: most teams do not need to change the core dynamic library;
- **Submit general improvements as PRs**: fewer private patches, a preserved technical lineage, and captured upstream implicit contracts;
- **AI does the mechanical work, humans own the contracts**: renaming, deleting comments and running tests go to AI; wire format, threading model and handle ownership are checked by humans; implicit contracts are captured by humans + AI;
- **Value determines depth**: only a project with prospects and long-term collaboration needs deserves L3; otherwise L1 is enough;
- **Implicit contracts are the real barrier**: code can be copied, implicit contracts cannot. The core goal of privatisation is to build the organisation's own implicit-contract system;
- **Avoid playing with yourself**: privatisation must serve business value, not the architect's control urges. **In an era of abundant compute, organisational efficiency is the real leverage — privatisation is a means, not an end.**

---

## 8. Roadmap and overall acceptance

| Stage | Goal | Key deliverables | Organisational acceptance |
|------|------|----------|----------|
| 0 | Value judgement | PoC report, choice of privatisation tier | The business side confirms the value |
| 1 | Dynamic-library privatisation | Private fork, patch layering, build baseline, upgrade checklist, **technical-root implicit-contract list** | Upstream updates sync cheaply; implicit contracts captured |
| 2 | Binding privatisation | Private packages for priority languages, private tests, cross-language interop, **language-boundary implicit-contract list** | Target languages' tests all pass; implicit contracts captured |
| 3 | Engineering privatisation | Private generator, CI pipeline, private package repository, governance mechanism, **`implicit-contracts/` as single source of truth** | Multiple teams collaborate under unified contracts; implicit contracts solidified |
| 4 | Continuous operation | Upgrade cadence, audits, documentation, training, **continuous implicit-contract updates** | Upstream sync and internal delivery stable; organisational memory does not erode |

**Overall acceptance in one sentence**: you can compile the private dynamic library yourself, distribute your own private binding packages, produce engineering-grade code with your own private generator, and complete an upstream upgrade with minimal changes — only then is privatisation successful; and multiple teams collaborating under this system is what makes production engineering successful.

**But the more fundamental acceptance is**:

> **Does this privatisation system really make people in the organisation more efficient, more collaborative and more productive? Has the organisation truly captured, sedimented and passed on its own implicit contracts?**

If the answer is yes, privatisation is worth it; if it only gives the architect a stronger sense of control, it is "playing with yourself". In the AI era compute is pervasive and people are the scarcest resource — **the ultimate goal of privatisation is to organise people, frameworks and implicit contracts better with AI assistance**. LF's non-replicable mechanism tells us: code can be copied, implicit contracts cannot. **What privatisation really needs to build is the organisation's own implicit-contract system — that is the organisation's true moat in the AI era.**


