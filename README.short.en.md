# LingoFuse

**Cross-language RPC foundation — no IDL, no stubs, no HTTP service.**
Call a function written in any of 18 languages from any other language, on the same machine or across machines. MIT.

```cpp
// C++
int Add(int a, int b);
```

```python
# Python — calls the same function, no .proto, no generated stub
print(LF_Call("math", "Add", 1, 2))   # => 3
```

## What you get

- **18 first-party bindings** — Pascal, C++, Rust, Go, Java, Python, C#, TypeScript, JavaScript, Swift, Zig, Erlang, Ruby, Fortran, Julia, R, Dart, PHP. All on one C ABI, one wire format, one handle-ownership model.
- **Two transports, one API** — same-machine shared-memory IPC, and a TCP mesh with built-in service discovery, load balancing, FIFO ordering and reconnect.
- **Zero IDL** — declare a normal function; other languages call it by name. No `.proto`, no generated stubs, no gateway per language pair.
- **Generators** — 17 native-FFI languages, 20+ JSON-ABI languages, plus declaration-to-MCP.

## Try it in 60 seconds (Windows, nothing to compile)

1. Download `LingoFuse64.dll` and the generator tools from [Releases · pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build)
2. Put them on `PATH`
3. Run the prebuilt tests in [test/](test/) and read the numbers from your own hardware

Linux / macOS: build from source — [src/CONTRIBUTING.md](src/CONTRIBUTING_en.md). **Not verified yet**; CI is on the roadmap.

## Read before adopting

This is frontier infrastructure, not plug-and-play. It solves the hard part and leaves you the complex part:

- callbacks run on worker threads — never call a blocking LF function inside a callback
- no App-layer abstraction, no cross-platform toolchain hand-holding, no support SLA (single maintainer)
- Windows prebuilt only, for now

## Where to go next

| | |
|---|---|
| Full README | [readme_en.md](readme_en.md) |
| Mechanism knowledge base (v4.0) | [Z.LingoFuse_en.md](Z.LingoFuse_en.md) |
| Kernel & application notes (17 pieces) | [doc/](doc/) |
| P2P distributed load concepts | [LingoFuse_P2P_Distributed_Load_Concept_en.md](LingoFuse_P2P_Distributed_Load_Concept_en.md) |
| Tests and verification | [test/](test/) |
| LLM entry point | [llms.txt](llms.txt) |
| Why it is hard to replicate | [LF-Architecture-Unreplicable-Backend-Systems_en.md](LF-Architecture-Unreplicable-Backend-Systems_en.md) |
