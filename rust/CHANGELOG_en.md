# Delivery: `CHANGELOG.md`

> Chinese version: [CHANGELOG.md](CHANGELOG.md)

```markdown
# Changelog

This file records every important change in the `lingofuse` Rust binding.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version numbers follow [Semantic Versioning](https://semver.org/).

---

## [0.3.0] - 2026-10-13

### Summary

This upgrade raises the Rust binding's coverage of the native C ABI from **37 / 59** to **59 / 59**, and introduces three brand-new modules (`uid` / `options` / `p2p`) plus a modernized asynchronous calling module (`async_call`). All existing APIs stay backward compatible; this release is purely additive.

It adds 22 safe wrappers for C ABI exports, 38 typed option getters/setters, and a closure-based async API, so Rust callers can use every LingoFuse mechanism without touching `unsafe`.

---

### Added

#### New modules

| Module | Purpose |
|------|------|
| `lingofuse::uid` | A safe newtype for the 32-byte P2P session identifier, with hex conversion and `Debug` / `Display` |
| `lingofuse::options` | Typed option getters/setters mirroring the native `LF_Set_Opt_*` / `LF_Get_Opt_*` family |
| `lingofuse::p2p` | Process-wide P2P API registration (independent of any App) |
| `lingofuse::async_call` | Modernized async calling: closure style plus blocking style |

#### New C ABI wrappers (22)

**Data-handle identity accessors (2)**
- `LF_Get_P2P_UID`
- `LF_Get_P2P_Name`

**Process-wide P2P registration (3)**
- `LF_Register_P2P_Call`
- `LF_Register_P2P_Notify`
- `LF_Unregister_P2P`

**App-name-addressed async (2)**
- `LF_Async_Call`
- `LF_Async_Sequenced_Call`

**UID addressing (5)**
- `LF_UID_Call`
- `LF_UID_Async_Call`
- `LF_UID_Async_Sequenced_Call`
- `LF_UID_Notify`
- `LF_UID_Sequenced_Notify`

**P2PName addressing (5)**
- `LF_P2PNAME_Call`
- `LF_P2PNAME_Async_Call`
- `LF_P2PNAME_Async_Sequenced_Call`
- `LF_P2PNAME_Notify`
- `LF_P2PNAME_Sequenced_Notify`

**Additional queries (4)**
- `LF_Check_UID`
- `LF_Check_UID_Api`
- `LF_Check_P2PNAME`
- `LF_Check_P2PNAME_Api`

**Option reading (1)**
- `LF_GetOption`

#### New public APIs

**`uid` module**
- The `Uid` type: `Copy` / `Eq` / `Hash` / `Default`, with `from_bytes` / `from_slice` / `from_hex` / `as_bytes` / `to_bytes` / `to_hex` / `is_null`
- The `Uid::NULL` constant
- The constants `UID_LEN` (32) / `UID_HEX_LEN` (64)

**`options` module**
- Low-level primitives: `set_bool` / `get_bool` / `set_u64` / `get_u64` / `set_i64` / `get_i64` / `set_string` / `get_string`
- Typed families (each with a getter/setter):
  - `debug` (write-only)
  - `password` (reading returns a mask)
  - `quiet` / `show_thread_id` / `console_output`
  - `overlap_connection` / `wait_connection_ready_ok` / `wait_connection_timeout`
  - `ipc_serv_thread_count` / `ipc_serv_max_queue_length` / `ipc_serv_max_msg_size`
  - `fixed_sequenced_time`
  - `p2p_name`
  - `data_handle_idle_timeout` / `data_handle_pool_scan_interval`
  - `no_reponse_cmd_null_flush_threshold`

**`p2p` module**
- `register_p2p_call<F>` / `register_p2p_notify<F>` / `unregister_p2p`

**`async_call` module**
- Callback style: `call_async` / `call_async_sequenced` / `call_async_by_uid` / `call_async_by_p2p_name`
- Blocking style: `call_async_wait` / `call_async_wait_by_uid` / `call_async_wait_by_p2p_name`
- The type alias `AsyncCallback`

**Additions to the `framework` module**
- `get_option(option: &str) -> Result<String, Error>`
- `call_by_uid` / `try_call_by_uid` / `notify_by_uid` / `sequenced_notify_by_uid`
- `call_by_p2p_name` / `try_call_by_p2p_name` / `notify_by_p2p_name` / `sequenced_notify_by_p2p_name`
- `check_uid` / `check_uid_api` / `check_p2p_name` / `check_p2p_name_api`

**Additions to the `data_handle` module**
- `DataHandle::p2p_uid(&self) -> Result<Uid, Error>`
- `DataHandle::p2p_name(&self) -> Result<String, Error>`

#### New `sys`-layer types

- `LfP2PUid`: a `#[repr(C)]` 32-byte struct used to pass argument-role UIDs by value
- `LfAsyncCallOnResult`: the async callback prototype

#### New unit tests

**76 new unit tests** were added in total, covering:

- `uid`: hex round-trip, `from_slice` length validation, `Copy` semantics, `Debug` / `Display` formatting, `Hash` / `Eq` (17)
- `options`: bool / integer / string round-trips, fallback for unknown options, interior-NUL validation (17)
- `p2p`: register / unregister round-trip, duplicate-name rejection, interior-NUL validation (7)
- `data_handle`: P2P identity accessor behaviour on owning / borrowed / disposed handles (5)
- `framework`: `get_option`, UID / P2PName queries, the `uid_to_lf` bridge, disposed-param short-circuiting (15)
- `async_call`: the trampoline, dispatch failure paths, every branch of `recv_with_timeout` (15)

#### New integration tests

| File | Tests | Coverage |
|------|:------:|---------|
| `tests/options_e2e.rs` | 6 | Full round-trip of typed options + consistency with raw `get_option` |
| `tests/identity_e2e.rs` | 1 | P2P identity side data (reading UID / P2PName inside the callback; output handle is NULL / empty) |
| `tests/addressing_e2e.rs` | 5 | Synchronous calls over all three addressing schemes + process-wide P2P registration + the 4 additional queries |
| `tests/async_e2e.rs` | 10 | The whole async family (callback style + blocking style + dispatch failure + chaining + fan-out + panic isolation) |

#### New build / test script layer

`test.ps1` expands from 4 layers to 8:
- Kept: `unit` / `ignored` / `abi` / `e2e`
- Added: `e2e_opts` / `e2e_ident` / `e2e_addr` / `e2e_async`

Per-layer runs are supported, for example `.\test.ps1 -Layer e2e_addr,e2e_async`.

---

### Changed

#### `sys::bindings`

- Added the `LfP2PUid` struct with a `NULL` constant, `from_bytes`, `is_null` and `Default`
- Added the `LfAsyncCallOnResult` callback typedef
- Added 22 function-pointer typedefs
- The existing 37 typedefs are unchanged word for word

#### `sys::loader`

- `NativeLibrary` field count: **37 → 59**
- `resolve!` entries in `load_native()`: **37 → 59**
- The order of fields and `resolve!` entries **strictly mirrors** the `RESOLVE` sequence in `LingoFuse.c`, in 14 groups, for easy cross-auditing
- The export count printed by the `Debug` implementation is updated from `37` to `59`
- A load failure is still cached (no retry); the singleton semantics are unchanged

#### `sys::mod`

- Re-exports now include `LfP2PUid` and `LfAsyncCallOnResult`
- The module documentation gains a "export inventory" section listing per-group counts for all 14 groups

#### `framework`

- All 16 existing functions are kept (signatures, documentation and error semantics completely unchanged)
- 13 new public functions (see the "Added" section above)
- Internally a new helper `uid_to_lf(Uid) -> LfP2PUid` bridges `Uid` to the ABI struct

#### `data_handle`

- The module documentation gains a "P2P identity side data" section explaining the side-data injection mechanism, the valid-handle table and the 5-second pointer invalidation rule
- Internally `p2p_uid` copies 32 bytes out of `*const LfP2PUid` and drops the pointer immediately, never exposing it to callers
- Internally `p2p_name` copies through `CStr::from_ptr` straight into a `String`
- The `Send` / `Sync` implementations are kept

#### `lib.rs`

- 4 new `pub mod`s: `options` / `p2p` / `async_call` / `uid`
- Two new crate documentation sections: "Address schemes" (the three addressing schemes) and "Async result ownership" (framework-owned handles must not cross a callback boundary)
- The status table is updated to Stage 3

#### `test.ps1`

- `$layers` expands from 4 to 8
- The `$validLayers` array is extended accordingly (laid out over several lines)
- The `all` expansion includes all 8 layers
- Other logic (native detection, loops, reporting) is unchanged word for word
- Fully backward compatible with the old invocation forms

---

### Fixed

#### Product code

**`async_call::extract_payload` included a trailing `\0` when reading results**

`call_async_wait` / `call_async_wait_by_uid` / `call_async_wait_by_p2p_name` used `read_all_bytes` to extract the response bytes, which copied the NUL terminator at the end of the JSON text along with the payload. Downstream parsers then failed with `io::loads_json: trailing characters`.

**Fix**: switched to `read_string`. That function stops at the first NUL and returns pure JSON text; for raw payloads without a NUL it keeps the fault-tolerant semantics (read everything that remains).

#### Compile errors found at delivery

The following three were found and corrected during delivery and are all merged into v0.3.0:

- `Error::null_handle(&format!(...))` in `src/async_call.rs` was missing a reference
- `ErrorCode` in the top-level `use crate::error::{Error, ErrorCode}` of `src/p2p.rs` was unused
- The test module in `src/p2p.rs` was missing `use crate::error::ErrorCode`

---

### Known limitations / design decisions

This section records decisions made explicitly during this upgrade that may be revisited later.

#### `call_async_wait` returns `Vec<u8>` instead of a `DataHandle`

The callback handle delivered to the async family is owned by the framework and freed as soon as the callback returns. Wrapping it in an owning `DataHandle` and sending it across the callback boundary would cause a use-after-free. There are only two safe options:

1. copy the bytes inside the callback (this implementation)
2. have the caller provide a deserialization target

This release chooses option 1; returning raw bytes is **a deliberate contract**, not a defect. Callers can decode with `io::loads_json` into a concrete type.

#### `LF_Shutdown` does not reset options

The native `LF_Shutdown` cleans up network state, the App pool and the handle pool, but **does not reset the option store**. Option values survive a shutdown. The "not persisted" wording in the C header means "the application layer must re-apply them", not "the native layer zeroes them".

This release's tests therefore contain no assertion that "options return to defaults after shutdown".

#### Calling with a null UID

The C ABI documentation says a null UID is "a legal argument that simply matches no client". The actual wire behaviour, however, is outside the stable contract: the dispatcher may return an empty response, a lookup error or a size=0 handle, depending on routing-table state.

The Rust binding **makes no assertion** about the result of a call with a null UID. The query API is well defined (`check_uid(Uid::NULL)` returns `false`) and is therefore still tested.

#### The `debug` option needs the framework running

`debug` is an option that "executes a command on write" rather than a plain string store. Some commands (`RegInfo`, `service`, `tunnel`) depend on the simulated main thread running. Calling them before the framework starts blocks.

This release's `options` module only provides setter / getter interfaces and adds no extra protection; callers must ensure correct timing themselves.

#### Context Box leak in P2P registration

`p2p::register_p2p_call` / `register_p2p_notify` leak a small `Box<Context>` per registration. This is **a deliberate trade-off** consistent with the `app_handle` layer: the native layer may invoke the callback at any moment (including concurrently with unregister), so reclaiming it would open a use-after-free window. The cost is bounded (a few dozen bytes per registration) and harmless in normal use.

#### Async calls have no timeout / no cancellation

The C ABI async family has no timeout parameter and no cancellation handle. Callback-style entry points therefore have no timeout either; the blocking entry points' `timeout` is **a pure Rust-side** implementation (`mpsc::recv_timeout`), which returns `Err(Timeout)` and abandons the callback on expiry, but the native request **is not** cancelled.

Callers needing a hard timeout should track outstanding requests at a higher layer and give up after the configured interval.

#### Single-process end-to-end testing

All new integration tests run the server and the client **in the same process**. App-name and UID addressing therefore take the mesh's local-first path; P2PName addressing still goes through the server dispatcher (IPC loopback). Full cross-process validation needs two OS processes and is out of scope here.

---

### Unchanged

The following parts were **not** touched in this release; they can be evaluated separately if the need arises:

- the `error` module (`Error` / `ErrorCode` / source chain) is completely unchanged
- the `io` module is completely unchanged
- the `app_handle` module is completely unchanged (`AppHandle` still does not implement `Send` / `Sync`)
- the `network_events` / `status` modules are completely unchanged
- `Cargo.toml` gains no new dependencies (only `std` plus the existing `libloading` / `serde` / `serde_json`)
- `rust-version = "1.70"` / `edition = "2021"` are unchanged
- the three example programs under `examples/` are untouched

---

### Test matrix (v0.3.0 completion state)

| Layer | File | Tests | Notes |
|-------|------|:------:|------|
| `unit` | `cargo test --lib` | 122 passed / 23 ignored | Parallel-safe unit tests covering every module |
| `ignored` | `--ignored --test-threads=1` | 23 passed | Tests touching process-wide native state |
| `abi` | `tests/abi_smoke.rs` | 5 passed / 1 ignored | Stage 1, the C ABI layer |
| `e2e` | `tests/framework_e2e.rs` | 2 passed | Stage 2 end-to-end |
| `e2e_opts` | `tests/options_e2e.rs` | 6 passed | New: typed options |
| `e2e_ident` | `tests/identity_e2e.rs` | 1 passed | New: P2P identity side data |
| `e2e_addr` | `tests/addressing_e2e.rs` | 5 passed | New: three addressing schemes + P2P registration |
| `e2e_async` | `tests/async_e2e.rs` | 10 passed | New: the async call family |
| **Total** | | **174** | |

Every layer runs in a single `.\test.ps1` invocation.

---

### C ABI coverage comparison

| Group | C ABI exports | Rust wrappers | Coverage |
|------|:------------:|:-----------:|:------:|
| Data handle | 12 | 12 | 100% |
| Application handle | 5 | 5 | 100% |
| API registration (app-bound) | 3 | 3 | 100% |
| API registration (process-wide P2P) | 3 | 3 | 100% |
| Local execution | 2 | 2 | 100% |
| Network preparation | 5 | 5 | 100% |
| Remote invocation (app-name) | 5 | 5 | 100% |
| Remote invocation (UID) | 5 | 5 | 100% |
| Remote invocation (P2PName) | 5 | 5 | 100% |
| Queries | 7 | 7 | 100% |
| Options | 2 | 2 | 100% |
| Status | 3 | 3 | 100% |
| Network events | 1 | 1 | 100% |
| Shutdown | 1 | 1 | 100% |
| **Total** | **59** | **59** | **100%** |

---

### Migration guide

**Upgrading from v0.2 to v0.3 requires no changes to existing code.** This release is purely additive.

If you want to adopt the new APIs, the recommended path is:

1. **Replace scattered string-based option calls with the typed API**

   ```rust
   // before
   framework::set_option("Quiet", "True")?;
   framework::set_option("Wait_Connection_Timeout", "10000")?;

   // after
   options::set_quiet(true)?;
   options::set_wait_connection_timeout(10_000)?;
   ```

2. **Use `Uid` instead of a raw byte array**

   ```rust
   // before: maintain 32 bytes by hand
   let mut uid_bytes = [0u8; 32];
   // ... fill it from somewhere ...

   // after
   let uid = Uid::from_hex("...")?;
   framework::call_by_uid(uid, &req, 3000)?;
   ```

3. **Use callback-style async instead of a hand-rolled thread pool**

   ```rust
   // before: spawn a thread by hand + blocking call
   std::thread::spawn(move || {
       let resp = framework::call("App", &req, 3000)?;
       // ...
   });

   // after
   async_call::call_async("App", &req, move |result| {
       match result {
           Ok(mut resp) => { /* ... */ }
           Err(e)        => eprintln!("{}", e),
       }
   })?;
   ```

4. **Publish process-wide tool APIs through P2P registration**

   ```rust
   p2p::register_p2p_call("whoami", "identity echo", |input, output| {
       let uid = input.p2p_uid().unwrap_or_default();
       let _ = io::write_json(output, &serde_json::json!({
           "uid": uid.to_hex(),
       }));
   })?;
   ```

---

### Acknowledgements

The design of this upgrade draws on LingoFuse's C++ binding (`LingoFuse.hpp`), the Pascal complete guide (`LingoFuse_Pascal_Complete_Guide.md` v5.0) and the internal-mechanism knowledge base (`Z.LingoFuse.md` v3.2). The async model and the `AsyncResult` ownership contract follow the C++ binding directly, merely expressed in idiomatic Rust.

---

## [0.2.0] - 2026-10-02

Initial version. C ABI coverage 37 / 59, including:

- the `sys` layer (bindings / loader)
- `error` / `data_handle` / `io` / `app_handle`
- `framework` (synchronous calls addressed by App name)
- `network_events` / `status`

See `README.md` for detailed API documentation.
```

---

## Delivery confirmation

- **File**: `CHANGELOG.md` (new)
- **Location**: the crate root (next to `README.md` / `Cargo.toml`)
- **Length**: about 380 lines
- **Format**: Keep a Changelog style, with `[0.3.0]` for this upgrade and `[0.2.0]` as the historical anchor
- **Content language**: Chinese
- **Code / file names / API names**: kept as-is in English

### Key information covered by the document

| Section | Content |
|------|------|
| Summary | The core numbers, coverage 37 → 59 |
| Added | 4 new modules, 22 C ABI wrappers, 13 `framework` functions, 2 `data_handle` methods |
| Changed | Concrete changes in 6 source files |
| Fixed | 1 product-code bug + 3 delivery-stage compile errors |
| Known limitations | 6 explicit design decisions (including the `Vec<u8>` return value, shutdown not resetting options, null-UID behaviour) |
| Unchanged | Explicit boundaries (`error` / `io` / `app_handle` / `network_events` / `status` are untouched) |
| Test matrix | The complete inventory of 8 test layers and 174 tests |
| C ABI coverage comparison | Proof of 100% coverage across 14 groups |
| Migration guide | 4 before / after examples |

### Positioning

- Aimed at **developers** (users upgrading to v0.3)
- Aimed at **maintainers** (reviewing design decisions later)
- Aimed at **auditors** (cross-checking C ABI coverage and the test matrix)

### Next step

One item remains: updating `README.md`. Once you confirm this batch is correct, I will deliver `README.md`.
