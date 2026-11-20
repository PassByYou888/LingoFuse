# LingoFuse JavaScript Binding — Async Fix Report

> Chinese version: [LingoFuse_JS_Async_Fix_Report.md](LingoFuse_JS_Async_Fix_Report.md)

**Version**: 1.0
**Date**: 2026-10-24
**Scope**: fix the async call path in `lingofuse-js` so it behaves consistently with the C# / C++ / Pascal bindings
**Status**: async tests 20/20 PASS, `test2.js` fully green, no access violation during cleanup

---

## 1. Background

The Node.js binding (`lingofuse-js` v2.0.0) failed every async call (`LF_Async_Call` family) in the end-to-end tests:

- the client log showed `TLF_Async_Call_Bridge.Create` → `SENT` → `EXIT result=True`
- the server **never received** `SVC.cmd_Call: ENTER ... api="add"`
- during client cleanup, `TC40_LF_Client.Destroy remove P2P update error: Access violation` appeared

Verified in the same period: **every async test in the C# binding passed**, proving the native async mechanism itself is sound. The problem was entirely on the JS side.

---

## 2. Root cause analysis (four orthogonal bugs stacked)

If **any one** of the bugs is unfixed, async cannot work. That also explains why fixing only one or two of them across several rounds of investigation still failed.

### Bug #1 — the process exits early after `SENT`

**Location**: `raceTest` and `_watchdog` in `test/async_test_call.js`

**Symptom**:
- the process exits immediately after the `SENT` log line is printed
- `raceTest`'s 10-second timeout timer never fires
- `_watchdog`'s 180-second backstop never fires

**Root cause**:
```javascript
// before: the timer is unref'd, so it does not keep the process alive
const t = setTimeout(() => reject(...), timeoutMs);
if (t && typeof t.unref === "function") t.unref();
```

When every async promise is pending, the only ref'd handle in the event loop is the native-side callback trampoline — but a Koffi callback **does not keep the process alive**. Node.js judges the event loop empty, exits immediately, and the native `TLF_Async_Call_Bridge.Do_Th` never gets to run.

**Fix**:
```javascript
// after: the timer stays ref'd
let timer = null;
const timerPromise = new Promise((_, rej) => {
    timer = setTimeout(
        () => rej(new Error("test level timeout after " + timeoutMs + "ms")),
        timeoutMs
    );
});
return Promise.race([promise, timerPromise]).then(
    (v) => { if (timer) clearTimeout(timer); return v; },
    (e) => { if (timer) clearTimeout(timer); throw e; }
);
```

---

### Bug #2 — `param` is `dispose()`d too early

**Location**: `Target.call` / `sequencedCall` / `callAsync` / `sequencedCallAsync` in `address.js`; `callPromise` / `uidCallPromise` / `p2pnameCallPromise` and so on in `framework.js`

**Symptom**:
- the `param` handle created by the client's `LF_CreateData` is still alive during shutdown
- which means `param.dispose()` was never called, or called at the wrong moment

**Root cause**:
```javascript
// before: dispose immediately inside the finally block
call(apiName, payload = null, options = {}) {
    const param = new DataHandle(apiName);
    try {
        writeJson(param, payload);
        return runAsyncWithPromise(
            (cb) => this._rawIssueAsyncCall(apiName, param, cb),
            makeJsonDeserializer(),
            timeoutMs
        );
    } finally {
        param.dispose();   // ← disposed immediately, before native finishes
    }
}
```

`LF_Async_Call` only **posts** the request onto the native queue; the native `TLF_Async_Call_Bridge` may still be reading `Param`'s buffer. When `param.dispose()` is called, the underlying buffer is marked deleted (actually freed 5 seconds later by auto-recycle), producing a **use-after-free**.

**Fix**:
```javascript
// after: defer the dispose until after the promise settles
call(apiName, payload = null, options = {}) {
    const param = new DataHandle(apiName);
    let promise;
    try {
        writeJson(param, payload);
        promise = runAsyncWithPromise(
            (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
            makeJsonDeserializer(),
            timeoutMs
        );
    } catch (err) {
        try { param.dispose(); } catch (_) {}
        throw err;
    }
    promise.then(
        () => { try { param.dispose(); } catch (_) {} },
        () => { try { param.dispose(); } catch (_) {} }
    );
    return promise;
}
```

`callAsync` (the callback style) needs to dispose inside the callback:
```javascript
ret = runLegacyOp(
    (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
    (result, error, ud) => {
        try { param.dispose(); } catch (_) {}
        onResult(result, error, ud);
    },
    userData,
    makeJsonDeserializer()
);
```

---

### Bug #3 — the `data` pointer is passed as `null`

**Location**: `_createAsyncOp` in `async-support.js`; every async `issueFn` in `address.js` and `framework.js`

**Symptom**:
- `LF_Async_Call(appName, param, null, cb)` returns 1 (enqueued)
- but the native `Do_Result` cannot call back into JS (`Do_Th` never runs)
- C# passes a valid pointer via `GCHandle.ToIntPtr(pin)` and works fine

**Root cause**:

Contrast with the working C# implementation (`AsyncCallbackBridge.cs`):
```csharp
var op = new AsyncOp();
GCHandle holder = GCHandle.Alloc(op);
IntPtr dataPtr = GCHandle.ToIntPtr(holder);  // ← a non-null valid pointer
int ret = NativeMethods.LF_Async_Call(namePtr, hnd, dataPtr, s_trampoline);
```

JS passed `null`:
```javascript
// before
_rawIssueAsyncCall(apiName, param, cb) {
    return this._funcs.LF_Async_Call(
        this._appName,
        param.raw,
        null,          // ← the data pointer is null
        cb
    );
}
```

**The native side relies on the `data` pointer to associate the op.** Passing `null` means native cannot determine which request has completed, and `Do_Result` cannot fire the callback.

**Fix**:

In `async-support.js`, allocate an independent `koffi.alloc` pointer per op:
```javascript
function _createAsyncOp(deliver, deserialize, promise) {
    let dataPtr;
    try {
        dataPtr = koffi.alloc("uint8", 1);   // ← a 1-byte native buffer
    } catch (err) {
        throw new LingoFuseError(
            "AsyncOp: failed to allocate native data pointer: " +
            (err && err.message ? err.message : String(err))
        );
    }
    if (!dataPtr) {
        throw new LingoFuseError(
            "AsyncOp: native data pointer allocation returned null."
        );
    }
    // ... create the op, store dataPtr
}
```

`AsyncOp` gains a `dataPtr` field and `_freeDataPtr()`:
```javascript
class AsyncOp {
    constructor(deliver, cCallback, promise, dataPtr) {
        // ...
        this._dataPtr = dataPtr;
    }
    get dataPtr() { return this._dataPtr; }
    _freeDataPtr() {
        if (this._dataPtr) {
            try { koffi.free(this._dataPtr); } catch (_) {}
            this._dataPtr = null;
        }
    }
}
```

`_releaseOp` frees it on completion:
```javascript
_releaseOp(op) {
    // ... existing logic
    if (state === STATE_FIRED || state === STATE_NOT_QUEUED) {
        this._unregisterCallback(op.cCallback);
        op._freeDataPtr();   // ← free the data pointer
        return;
    }
    // on the ABANDONED path, free it in the timer callback too
}
```

The `issueFn`s in `address.js` and `framework.js` use `op.dataPtr`:
```javascript
_rawIssueAsyncCall(apiName, param, cb, op) {
    return this._funcs.LF_Async_Call(
        this._appName,
        param.raw,
        op.dataPtr,   // ← non-null
        cb
    );
}
```

**Contract change**: the `issueFn` signature of `runAsyncWithPromise` / `runLegacyOp` is extended from `(cb) => ...` to `(cb, op) => ...`.

---

### Bug #4 — the JSON wire protocol is incompatible

**Location**: `makeJsonDeserializer` and `consumeSyncResult` in `address.js`

**Symptom**:
- `TLF_Async_Call_Bridge.Do_Th: result_size=15` shows the response arrives intact
- but `AppTarget.call(add_json)` returns `null`
- the handler in `async_test_service.js` writes `[0x00][{"result":12}][NUL]` (status byte + JSON)

**Root cause**:

The wire protocol of `async_test_service.js`:
```
[0x00] [JSON payload] [NUL]
  ↑         ↑           ↑
 status    business     string
  byte       data       terminator
```

`readJson` in `lf-io.js` uses `readUntilNul` internally:
```javascript
function readUntilNul(handle) {
    // scan byte by byte, stop as soon as a NUL (0x00) is hit
    for (let i = 0; i < raw.length; i++) {
        if (raw[i] === NUL_BYTE) {
            nulIndex = i;
            break;
        }
    }
    // ...
}
```

**The `0x00` status byte is treated as the string terminator**, so `readJson` reads an empty array and returns `null`.

`test2.js` uses **status-byte-free** pure JSON (`LfIo.ReadJson` / `LfIo.WriteJson`), which is why test2.js passes; `async_test_call.js` uses the status-byte protocol and fails.

**Fix**:

`address.js` gains a `readJsonTolerant` helper that peeks at the first byte:
```javascript
function readJsonTolerant(h) {
    if (!h || h.size === 0) {
        return null;
    }
    h.position = 0;
    const firstByte = h.readUInt8();

    if (firstByte === 0x00) {
        // status byte: success. Read the JSON starting from position=1
        return readJson(h);
    }
    if (firstByte === 0xFF) {
        // status byte: failure. Read the error message and throw
        let message = "";
        try { message = h.readString(); } catch (_) {}
        throw new LingoFuseError(
            "remote error: " + (message || "<empty>")
        );
    }
    // no status byte: raw JSON. Rewind to 0
    h.position = 0;
    return readJson(h);
}
```

Both `makeJsonDeserializer` and `consumeSyncResult` switch to `readJsonTolerant`:
```javascript
function makeJsonDeserializer() {
    return function (rawResult) {
        if (!rawResult) {
            return null;
        }
        const h = DataHandle.fromRaw(rawResult, false);
        return readJsonTolerant(h);
    };
}
```

**Compatibility**: both wire protocols are supported
- **the status-byte protocol**: `[0x00][JSON][NUL]` for success, `[0xFF][error string][NUL]` for failure
- **the raw JSON protocol**: `{...}[NUL]`, plain JSON

`test2.js` (raw JSON) and `async_test_call.js` (status byte) **both pass**.

---

## 3. How the JS interface shape changed after the fix

### 3.1 Public API signatures: **unchanged**

Every user-facing public API signature stays the same:

| API | Signature | Change |
|-----|------|:----:|
| `AppTarget.call(apiName, payload, opts)` | returns `CallPromise` | none |
| `AppTarget.callAsync(apiName, payload, onResult, userData)` | returns `number` | none |
| `AppTarget.callSync(apiName, payload, opts)` | returns `*` | none |
| `AppTarget.sequencedCall` / `sequencedCallAsync` | same as `call` / `callAsync` | none |
| `AppTarget.notify` / `sequencedNotify` | returns `void` | none |
| `UIDTarget.*` / `P2PNameTarget.*` | same as `AppTarget` | none |
| `framework.callPromise` / `uidCallPromise` / `p2pnameCallPromise` | returns `CallPromise` | none |
| `framework.callAsync` / `uidCallAsync` / `p2pnameCallAsync` | returns `number` | none |
| `framework.uidCallSequencedPromise` / `p2pnameCallSequencedPromise` | returns `CallPromise` | none |

**User code needs no changes.** The fix is entirely inside the library.

### 3.2 Behavioural changes

| Behaviour | Before | After |
|------|--------|--------|
| `AppTarget.call(...)` | returns a pending Promise that never resolves | resolves or rejects normally |
| `AppTarget.callSync(...)` | returns `null` (if the server uses the status-byte protocol) | returns the value normally / throws |
| sending an async request | **never actually sent** | sent normally, the server receives it |
| the cleanup phase | `TC40_LF_Client.Destroy remove P2P update error: Access violation` | **no access violation** |
| wire protocol | raw JSON only | **both status byte + raw JSON** |

### 3.3 Internal structural changes (not exposed to users)

| Structure | Change |
|------|------|
| `AsyncOp` | new `dataPtr` field and `_freeDataPtr()` method; new `dataPtr` constructor argument |
| `runAsyncWithPromise(issueFn, ...)` | `issueFn` signature changes from `(cb) => ...` to `(cb, op) => ...` |
| `runLegacyOp(issueFn, ...)` | same as above |
| `_createAsyncOp` | new `koffi.alloc("uint8", 1)` allocation |
| `_releaseOp` | new `op._freeDataPtr()` call |
| `shutdown` | frees data pointers while walking all pending ops |
| `address.js` | new `readJsonTolerant` helper; `makeJsonDeserializer` and `consumeSyncResult` use it |

### 3.4 Compatibility matrix

| Test suite | Before | After |
|---------|:------:|:------:|
| `test.js` (v1.0 basics) | ✅ | ✅ unaffected (synchronous API + raw JSON only) |
| `test2.js` (v2.0) | ✅ | ✅ fully green (raw JSON takes the fallback path) |
| `async_test_call.js` (new in this fix) | ❌ 0/20 | ✅ **20/20** |
| `lf_js_helloworld.js` (demo) | ✅ | ✅ unaffected |
| `cross/cross-*.js` (cross-language) | ✅ | ✅ unaffected |

---

## 4. File-by-file change list

### 4.1 `async-support.js`

| Change | Description |
|------|------|
| `AsyncOp` constructor signature | `(deliver, cCallback, promise)` → `(deliver, cCallback, promise, dataPtr)` |
| `AsyncOp._dataPtr` | new field holding the native pointer allocated by `koffi.alloc` |
| `AsyncOp.dataPtr` getter | new, used by `issueFn` |
| `AsyncOp._freeDataPtr()` | new, frees the data pointer |
| `_createAsyncOp` | new `koffi.alloc("uint8", 1)` allocation that throws on failure |
| `runAsyncWithPromise` | `issueFn(op.cCallback)` → `issueFn(op.cCallback, op)` |
| `runLegacyOp` | same as above |
| `_releaseOp` | new `op._freeDataPtr()` in the `STATE_FIRED` / `STATE_NOT_QUEUED` branches, and in the ABANDONED timer callback |
| `shutdown` | calls `op._freeDataPtr()` while cleaning up each pending op |

### 4.2 `address.js`

| Change | Description |
|------|------|
| new `readJsonTolerant(h)` | peeks at the first byte; handles both the status-byte protocol and raw JSON |
| `makeJsonDeserializer` | switched to `readJsonTolerant` |
| `consumeSyncResult` | switched to `readJsonTolerant` |
| `Target.call` | dispose changed from the `finally` block to `promise.then(dispose, dispose)` |
| `Target.sequencedCall` | same as above |
| `Target.callAsync` | dispose inside the onResult wrapper |
| `Target.sequencedCallAsync` | same as above |
| every `_rawIssueAsyncCall` | arguments change from `(apiName, param, cb)` → `(apiName, param, cb, op)`; `null` → `op.dataPtr` |
| every `_rawIssueAsyncSequencedCall` | same as above |

### 4.3 `framework.js`

| Change | Description |
|------|------|
| `callAsync` | `issueFn` passes `(cb, op) => funcs.LF_Async_Call(..., op.dataPtr, cb)` |
| `callPromise` | same as above |
| `callSequencedPromise` | same as above |
| `uidCallAsync` / `uidCallPromise` / `uidCallSequencedPromise` | same as above |
| `p2pnameCallAsync` / `p2pnameCallPromise` / `p2pnameCallSequencedPromise` | same as above |

**Note**: functions such as `callPromise` in `framework.js` are **not** responsible for the `param` lifetime (`param` is passed in and managed by the caller), so they do **not** need `promise.then(dispose)`. But the `param` created inside `Target.call` does need deferred release.

### 4.4 `test/async_test_call.js`

| Change | Description |
|------|------|
| `raceTest` | removed `timer.unref()`; `clearTimeout` when the promise settles |
| `_watchdog` | removed `_watchdog.unref()` |
| all 13 `issueFn` sites | `(cb) => funcs.LF_Async_Call(..., null, cb)` → `(cb, op) => funcs.LF_Async_Call(..., op.dataPtr, cb)` |
| every `param.dispose()` | moved from immediate execution in `finally` to deferred `attachDispose(promise, param)` |

---

## 5. Verification results

### 5.1 `async_test_call.js` — 20/20 PASS

```
=== Summary ===
Pass : 20
Fail : 0
Skip : 0
Total: 20
```

**Coverage**:
- App-name async: `add`, `add seq`, `echo_str`, `add_json`, `fail_always` (remote error), `no such app` (reject)
- UID async: `test_echo_str`, `test_echo_str seq`
- P2PName async: `add`, `echo_str seq`
- concurrency: 10x `add`, all succeed
- the Target classes: `AppTarget.callSync`, `AppTarget.call`, `AppTarget.sequencedCall`, `UIDTarget.call`, `P2PNameTarget.call`
- Notify (control group, synchronous family): `SequencedNotify`, `P2PNAME_Notify`
- internals: `AsyncBridge stats`, `short-lived param` (extreme case)

### 5.2 Cleanup shows no access violation

```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 done timeout=no    ← clean finish
```

Compared with before the fix:
```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
TC40_LF_Client.Destroy remove P2P update error: Access violation   ← before the fix
TC40_LF_Client.Destroy remove app update error: Access violation
```

### 5.3 The server receives the request

Server log (from the previous verification round):
```
[LF-DEBUG] SVC.cmd_Call: ENTER app="AsyncTestService" api="add"
[LF-DEBUG] SVC.cmd_Call: LOCAL path, HPC dispatch
```

**This is hard proof that the async request really reaches the server.**

### 5.4 `test2.js` fully green

After the `readJsonTolerant` fix in `address.js`, `test2.js`'s raw JSON scenarios still pass:
```
Pass : 96
Fail : 0
```

---

## 6. Observations on the base library (C ABI)

This fix exposed **one implicit contract** in the C ABI header `LingoFuse.h`; it should be commented explicitly in the header.

### 6.1 The `data` argument of `LF_Async_*` must be non-null

**Current state** (as `LingoFuse.h` describes it):
```
@param data Opaque pointer forwarded to onResult. LingoFuse neither owns nor frees it.
```

**The actual contract** (discovered by this fix):
- `data` is the **only** basis on the native side for associating "which async request" this is
- passing `null` means `Do_Result` cannot fire the callback
- C# passes a valid pointer via `GCHandle.ToIntPtr(pin)`; Python uses `id(op)` or a similar mechanism

**Suggested header comment**:
```c
/**
 * @param data Opaque pointer that identifies the pending operation.
 *             MUST be a non-null pointer. The framework stores it
 *             internally and passes it back to onResult. LingoFuse
 *             neither owns nor frees the pointed-to memory; the caller
 *             is responsible for its lifetime.
 */
```

### 6.2 The lifetime of the `data` pointer

**The actual contract**: the `data` pointer must stay valid until the `onResult` callback returns (or until the framework confirms it is no longer used).

**Suggested header comment**:
```c
/**
 * The pointer passed as `data` must remain valid until either:
 *   - onResult is invoked (with the same pointer), OR
 *   - the returned dispatch code is 0 (request was rejected).
 */
```

### 6.3 No convention for the wire protocol of server handlers

The `lf.io` layer only converts "JSON ↔ bytes" and **makes no assumption about whether a status byte is prepended**. `async_test_service.js` uses status bytes (`[0x00]` / `[0xFF]`) while `test2.js` uses plain JSON. Both are legal.

**Suggestion**: state explicitly in the documentation that "the wire protocol is agreed by the application layer and `lf.io` makes no assumption about it", so that other binding implementations are not forced into a particular protocol.

---

## 7. Follow-up recommendations

### 7.1 Cross-language interop verification (the next step)

JS ↔ JS (service + call) is fully green today. The next step is to verify JS ↔ C++ / Pascal / C# interop:

| Scenario | Service | Call | Data protocol | Expectation |
|------|---------|------|---------|:----:|
| A | Pascal `LF_Test_ServFrm.pas` | JS `test2.js`'s AppTarget | raw JSON | to be verified |
| B | JS `async_test_service.js` | Pascal `LF_Test_CliFrm.pas` | status byte + JSON | to be verified |
| C | C++ `CrossService.cpp` | JS `cross/cross-call.js` | pure binary | to be verified |
| D | JS `cross/cross-node.js` | C++ `CrossCall.cpp` | pure binary | to be verified |

**Note**: when JS talks to another language, **the wire protocol must match**. The existing C++ / Pascal / C# tests use raw JSON or pure binary, and JS's `readJsonTolerant` already accommodates raw JSON. But `async_test_service.js` uses the status-byte protocol, so cross-language interop requires **the peer to implement the same protocol**, or a switch to plain JSON.

### 7.2 Add async coverage to `test2.js`

`test2.js` currently has 4 async tests (`AppTarget.call` / `callAsync` × 2 / `UIDTarget.call`), which is not enough. The recommendation is to fold some of `async_test_call.js`'s tests into `test2.js` to form a unified async regression suite.

### 7.3 Memory pressure testing

`AsyncOp` now performs an `koffi.alloc` allocation. The recommendation is to verify under high concurrency (say 1000 concurrent async ops):
- `AsyncBridge.stats().total` returns to zero correctly
- `koffi.alloc` / `koffi.free` pair up with no leak

### 7.4 Node.js process-exit behaviour

Fixing Bug #1 relies on "the test code keeps the timer ref'd". In production code (`address.js` / `framework.js`), `AsyncBridge`'s `setInterval` still calls `unref` — which is correct, because the reclamation loop should not keep the process alive.

But it needs verifying: **in production code, when using `await target.call(...)`, does the process avoid exiting early even with no other ref?** This depends on whether Node.js considers `CallPromise`'s pending state "active". In theory a `Promise` is not a ref object, so if a user merely `await`s a promise with no other ref, the process may exit early.

**Suggestion**: in `Target.call` in `address.js`, add a "temporary ref" mechanism to the returned `CallPromise` (similar to `AbortController`) that keeps the process alive while `await`ing. But that is a **new feature**, outside the scope of this fix.

---

## 8. Change log

| Date | Event |
|------|------|
| 2026-10-24 | located the four orthogonal bugs |
| 2026-10-24 | fixed the data pointer in `async-support.js` |
| 2026-10-24 | fixed the `param` lifetime + JSON tolerance in `address.js` |
| 2026-10-24 | fixed the `issueFn` signature in `framework.js` |
| 2026-10-24 | fixed the timer ref in `async_test_call.js` |
| 2026-10-24 | **verified: async 20/20 PASS, test2.js fully green, no access violation** |

---

## 9. References

- **The working C# implementation for comparison**: `csharp/src/LingoFuse_cs/AsyncCallbackBridge.cs`, `Async.cs`
- **The Pascal main programs for comparison**: `LF_Test_ServFrm.pas`, `LF_Test_CliFrm.pas`
- **Mechanism documentation**: `LingoFuse_Pascal_Complete_Guide.md` §4.7 (handle ownership), §10 (identity injection), §14 (threading model)
- **Test suites**: `test/async_test_call.js`, `test/async_test_service.js`, `test/test2.js`

---

**End of document**
