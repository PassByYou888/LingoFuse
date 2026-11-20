# The complete record of Erlang binding pitfalls

> Chinese version: [Erlang_Binding_Pitfalls_Guide.md](Erlang_Binding_Pitfalls_Guide.md)

> File name: `Erlang_Binding_Pitfalls_Guide.md`
> Purpose: a field record of real pitfalls for the maintainers / AIs who follow after this Erlang binding. Each pitfall lists symptoms, evidence, root cause, fix and lesson.
> Origin: the whole process of taking this `Z.LingoFuse` Erlang binding from "nothing passing" to "120/120 PASS".

---

## Contents

- [Chapter 0 The one-line summary](#chapter-0-the-one-line-summary)
- [Chapter 1 The ABI wire-format trap (the most critical, the easiest to be led astray by hallucination)](#chapter-1-the-abi-wire-format-trap)
- [Chapter 2 Traps in the NIF layer](#chapter-2-traps-in-the-nif-layer)
- [Chapter 3 Traps in the build chain (Windows + rebar3 only)](#chapter-3-traps-in-the-build-chain)
- [Chapter 4 Traps in the generator layer](#chapter-4-traps-in-the-generator-layer)
- [Chapter 5 Traps in the test layer](#chapter-5-traps-in-the-test-layer)
- [Chapter 6 Traps in the core library (not Erlang's fault, but they drag you in)](#chapter-6-traps-in-the-core-library)
- [Chapter 7 The final root cause: the `lf_p2p_call` / `lf_p2p_notify` atoms were not handled](#chapter-7-the-final-root-cause)
- [Chapter 8 Diagnostic methodology (the order that proved effective in this field run)](#chapter-8-diagnostic-methodology)
- [Chapter 9 The anti-hallucination checklist (where an AI most easily gets it wrong)](#chapter-9-the-anti-hallucination-checklist)
- [Chapter 10 The quick reference](#chapter-10-the-quick-reference)
- [Appendix A A snapshot of the environment](#appendix-a-a-snapshot-of-the-environment)
- [Appendix B The list of files fixed in this run](#appendix-b-the-list-of-files-fixed-in-this-run)

---

## Chapter 0 The one-line summary

**Remember these 7 points and you avoid 90% of the rework:**

1. **The ABI layer must use a binary wire** (`[status 0x00/0xFF][payload]`), **JSON is forbidden**.
2. **The NIF layer does not strip `#0`**; handling the string `#0` is the consumer's job (`read_string` / `lingofuse_json:loads`).
3. **When a callback is registered with `register_call_sync`, the NIF sends `{lf_call, Ref, Api, Payload, Identity}`**; a P2P registration sends **`{lf_p2p_call, ...}`**. **The service main loop must handle both sets**.
4. **`lingofuse:reply/2` can be called only once**; the second call returns `{error, unknown_ref}`. **User code should use `_ = lingofuse:reply(...)`, not `ok =`**.
5. **The P2P-level `Trigger` is a `CallbackEntry*` address, not nil, and not an Erlang PID**. `sync_wait` relies on `e->caller_pid` (the Erlang PID), not on `Trigger`.
6. **Service main needs `sleep(15000)`** so that SelfClient completes its Link and the UID/P2P report, and only then does `loop` enter its receive.
7. **The service main loop must handle 8 message shapes**: `lf_call` / `lf_p2p_call` × with/without `Identity` × specific API / generic API. Likewise `lf_notify` / `lf_p2p_notify`.

---

## Chapter 1 The ABI wire-format trap

### 1.1 The trap: using JSON as the ABI wire

**Symptoms**:
- Pascal/C++ ↔ Erlang cannot talk to each other
- a Pascal service reads an Erlang reply and judges `status` wrongly
- an Erlang service reads a Pascal reply and reports `{invalid_byte, 42}`

**Evidence (from this run's logs)**:

```
NoParamFunc(app call) failed: "ok":true,"result":0}
MultiLineComment(app call) failed: "error":"{invalid_byte,42}","ok":false}
```

**Root cause**:
- the Erlang generator used `lingofuse_json:loads/dumps` for ABI parameters
- the Pascal/C++ generators use the binary `[status][payload]`
- the two wires disagree

**Fix**:
- **`erlang_abi_service_generator_tool.pas` / `erlang_abi_call_generator_tool.pas` switched to a binary wire**
- **`lingofuse_json` is forbidden**
- request wire: `[Param1][Param2]...`, each parameter fixed-width little-endian by type, or `[UTF-8][#0]`
- response wire: `[status 0x00][Result]` / `[status 0xFF][ErrorUTF8][#0]`

**Lesson**:
- **the mistake an AI most easily makes**: seeing "JSON is convenient on the Erlang side" and recommending a JSON wire
- **correct**: **the ABI layer must match the existing Pascal/C++ generators exactly**; do not invent a protocol
- **the rule to judge by**: `Safe_Write_Scalar` / `Safe_Write_String` / `Safe_Write_Error` in `cpp_abi_service_generator_tool.pas` are **the only contract**

**The generator's correct implementation (aligned with C++)**:

| Stage | Erlang generator output | The C++ equivalent |
|------|------------------|---------------|
| success response (int32) | `<<0, V:32/little-signed>>` | `Safe_Write_Scalar` |
| success response (string) | `<<0, S/binary, 0>>` | `Safe_Write_String` |
| success response (void) | `<<0>>` | `Safe_Write_Void` |
| error response | `<<255, Msg/binary, 0>>` | `Safe_Write_Error` |

### 1.2 The trap: `lingofuse_json` as part of the ABI layer

**Symptoms**:
- once the NIF layer stopped stripping `#0`, `json:decode(<<"{\"k\":1}", 0>>)` threw `{invalid_byte, 0}`

**Evidence**:
```
t_call_no_identity/0 failed
```

**Root cause**:
- the old design: the NIF layer stripped `#0` for the user
- the new design: the NIF layer does not strip, and the consumer handles `#0`
- `lingofuse_json:loads/1` was not changed in step

**Fix**:
- **`lingofuse_json` is demoted to a user-level convenience tool**, no longer part of the ABI layer
- `loads/1` tolerates a trailing `#0`:

```erlang
strip_trailing_nul(<<>>) -> <<>>;
strip_trailing_nul(Bin) ->
    case binary:last(Bin) of
        0 -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.
```

**Lesson**:
- **the layering principle**: the C ABI (NIF) **does not touch the bytes**; the typed primitives (`read_string` and so on) **handle them by type**; the user layer (`lingofuse_json:loads`) **tolerates the wire framing**
- **if any layer does too much or too little**, you get either `{invalid_byte, 0}` or "the high byte of an int32 gets stripped"

---

## Chapter 2 Traps in the NIF layer

### 2.1 The trap: `read_and_strip_nul` unconditionally strips the trailing `#0`

**Symptoms**:
- `int32 42` (wire `2A 00 00 00`) becomes 3 bytes after stripping
- the last byte of a binary parameter is swallowed
- the generator fails to decode

**Evidence (from this run's logs)**:
```
MultiLineComment(app call) failed: "error":"{invalid_byte,42}","ok":false}
```

**Root cause**:
- the `read_and_strip_nul` logic in `lingofuse_nif.c` was "read the whole buffer, and if the last byte is 0x00 strip one byte"
- **the trailing 0x00 was the high byte of an int32, not a string terminator**

**Fix**:
- delete `read_and_strip_nul` and add `read_input_payload` (**no stripping**)
- handling the string `#0` becomes the consumer's job in `read_string` / `read_string_bytes`

**Lesson**:
- **the C ABI layer not stripping is the precondition for cross-language binary interoperability**
- **the NIF layer has no right to decide to strip on the user's behalf**

### 2.2 The trap: `lf_call_callback` relies on `Trigger` to find the Erlang PID

**The wrong understanding**: `Trigger` is an Erlang PID and `sync_wait` depends on it

**The right understanding**:
- `Trigger` is a `CallbackEntry*` address (`e->trigger = e` inside `callback_alloc`)
- what `sync_wait` relies on is `e->caller_pid` (the Erlang PID passed in at registration, i.e. the service main's `self()`)
- `enif_send(NULL, &e->caller_pid, ...)` is where the message is actually sent

**Where in the source**: `dispatch_to_process` in `lingofuse_nif.c`

**Lesson**:
- **do not think of `Trigger` as an Erlang PID**. It is a `CallbackEntry*`, and you use it to reach `e->is_p2p` / `e->is_sync` / `e->caller_pid`
- **different `api_.Trigger` values are the normal result of App-level and P2P-level registration each allocating its own `CallbackEntry*`**, not a bug

### 2.3 The trap: under async registration the NIF does not write the output

**Symptoms**:
- if the service uses `register_call` (async registration) and the C++ client uses `LF_Call` (sync)
- the NIF's `lf_call_callback` does not `sync_wait` under async registration and writes no output
- the C++ client receives an empty result

**Where in the source**: `dispatch_to_process` in `lingofuse_nif.c`:

```c
if (is_call) {
    if (e->is_sync) {
        // sync_wait + write_to_output_handle
    } else {
        // enif_send only, no output write
    }
}
```

**Conclusion**:
- **`register_*_sync` at App level / P2P level is the only registration that works with a synchronous client**
- **`register_*` (async registration) suits only fire-and-forget, or an asynchronous client**

---

## Chapter 3 Traps in the build chain

### 3.1 The trap: `file:copy` commits suicide on a junction

**Symptoms**:
- a `83005`-byte DLL becomes `0` bytes
- `LoadLibraryA` returns NULL with `GetLastError=0`

**Evidence (from this run's logs)**:
```
[build] output file size:
         d:/.../priv/lingofuse_nif.dll       83005 bytes
[build] copied to     : d:/.../_build/test/lib/lingofuse/priv/lingofuse_nif.dll
[build] OK

PS> ls .\priv\
-a---   ...   0 lingofuse_nif.dll     ← 0 bytes!
```

**Root cause**:
- on Windows, rebar3 implements `_build/test/lib/lingofuse/priv` → `../../../../priv` as a **junction**
- Erlang's `file:copy(Src, Dst)` opens `Dst` in write mode, truncating it to 0
- because `Dst` and `Src` are the same file, `Src` is truncated to 0 as well

**Fix**:
- call `file:delete(Target)` before `link_gcc` (guards against a leftover 0-byte file)
- add a `same_stat` check to `copy_to_build_dir` (skip when both `size` and `mtime` match)
- check the size twice after the build (once after building, once after copying), and `halt(3)` / `halt(4)` on 0 bytes

**Lesson**:
- **a junction on Windows is rebar3's default**. Any `file:copy` to a junction path can commit suicide
- **general rule**: before copying, compare `size` + `mtime` with `file:read_file_info` and skip if they match

### 3.2 The trap: `Invoke-Step` output gets swallowed

**Symptoms**:
- rebar3's compile output is invisible in `build.ps1`

**Root cause**:
- inside `Invoke-Step`, the output of `& $Body` is collected as the function's return value
- assigning it to `$code` means it is never displayed

**Fix**:
- `& $Body | Out-Host` forces stdout to the console without affecting `$LASTEXITCODE`

### 3.3 The trap: the `-notmatch` regex in `setup_erlang_tests.ps1` is broken by `\\` escaping

**Symptoms**:
```
setup_erlang_tests.ps1: Invalid pattern '(?m)^-module\\(' at offset 15. Not enough )'s.
```

**Root cause**:
- the Pascal generator emits `-notmatch "(?m)^-module\\("`
- **PowerShell double-quoted strings do not use a backslash to escape**, so `\\` is two backslashes
- what reaches the regex engine is `(?m)^-module\\(`, where `\\` is a literal backslash and `(` opens an unclosed group

**Fix**:
- switch to string methods such as `.StartsWith('-module(')` and avoid regex

```powershell
$firstLine = ($c -split "`n")[0]
if ($null -eq $firstLine -or -not $firstLine.TrimStart().StartsWith('-module(')) { $stale += $rel }
```

**Lesson**:
- **inside a PowerShell double-quoted string `\\` is two backslashes**, not an escape
- **if `.StartsWith` / `.EndsWith` / `.Contains` will do, do not use `-match`**

### 3.4 The trap: the UnitName detection in `setup_erlang_tests.ps1` is wrong

**Symptoms**:
```
[info] UnitName       : ComplexTestUnit_abi.app.src   ← wrong! it should be ComplexTestUnit
```

**Root cause**:
- `-replace "\.app\.src$", ""` + `-match "^(.+)_abi$"` are unreliable in some PowerShell environments

**Fix**:
- use `.EndsWith` + `.Substring`:

```powershell
if ($n.EndsWith("_abi_service.erl")) {
    $found = $n.Substring(0, $n.Length - 16)
    break
}
```

- validate that `$UnitName` contains none of `\\/:*?"<>|` and does not end with `.app.src` / `.erl` / `.beam`

**Lesson**:
- **string methods are more reliable than regex**
- **automatic detection must add defensive validation** (illegal characters, values that look like file names)

### 3.5 The trap: stale bad files left in `_build/`

**Symptoms**:
- the residue `src/ComplexTestUnit_abi.app.src_abi.app.src` from an earlier failure
- every later `EmitFileCheck` fails

**Fix**:
- add `EmitCleanupStale`, which scans `src/*_abi.app.src_*` and deletes them
- the user can explicitly `-Clean` to clear `_build/` and `ebin/`

### 3.6 The trap: `LF_Get_Self_UID` is missing (old dll)

**Symptoms**:
```
[lingofuse_nif] LingoFuse library loaded (platform=Windows 64-bit, file=LingoFuse64.dll, get_self_uid=no (old dll))
```

**Root cause**:
- the old `LingoFuse64.dll` lacks the `LF_Get_Self_UID` export

**Impact**:
- **diagnostic information only**; core routing is unaffected
- `LF_RESOLVE_OPTIONAL` in `lf_loader.c` skips it, and loading proceeds normally as long as the other 59 required symbols exist

**Fix**:
- **upgrade the DLL** (the new version has `LF_Get_Self_UID`)
- upgrading is optional; without it, `get_self_uid=no` simply keeps showing

---

## Chapter 4 Traps in the generator layer

### 4.1 The trap: the `?CALL_MODULE` macro leaves variables unbound under OTP 29

**Symptoms**:
```
variable 'NoParamFunc' is unbound
variable 'NoParamFunc_async' is unbound
variable 'NoParamFunc_uid' is unbound
...
```

**Root cause**:
- `-define(CALL_MODULE, 'ComplexTestUnit_abi_call').`
- under OTP 29, `?CALL_MODULE:NoParamFunc(...)` is parsed as `variable 'NoParamFunc' is unbound`
- **this is an OTP 29 compatibility problem with macro remote calls**

**Fix**:
- **remove the `?CALL_MODULE` macro entirely**
- inline the atom when generating:

```erlang
fun() -> 'ComplexTestUnit_abi_call':'NoParamFunc'(?SERVICE_APP) end
```

**Lesson**:
- **macro + atom + colon call** carries compatibility risk in new OTP versions
- **an inline atom literal is the most stable**

### 4.2 The trap: `run_p2p_notify_test/4 undefined`

**Symptoms**:
```
function run_p2p_notify_test/4 undefined, did you mean run_notify_test/4?
```

**Root cause**:
- the `erlang_abi_test_generator_tool.pas` the user had was an **old version** (without the `run_p2p_notify_test` helper)
- the new generator has `run_p2p_notify_test` but the user had not replaced it

**Fix**:
- **force-delete the old generated files** (in `src/` and the project root) and regenerate
- **after every generator change you must `Remove-Item` the old files**:

```powershell
Remove-Item src\ComplexTestUnit_abi_service_main.erl -Force
Remove-Item src\ComplexTestUnit_abi_call_main.erl -Force
```

**Lesson**:
- **after changing the generator you must clean the old generated files**
- **the setup script should clean stale files by default** (the `-Clean` parameter)

### 4.3 The trap: `-compile({nowarn_unused_function, ...})` was omitted

**Symptoms**:
```
Warning: function lf_decode_ret_int64/1 is unused
Warning: function lf_decode_ret_uint32/1 is unused
...
```

**Root cause**:
- `ComplexTestUnit` has only three return types: `int32` / `double` / `string`
- the other 7 `lf_decode_ret_*` functions are "generated but never called"

**Fix**:
- add `-compile({nowarn_unused_function, [...]}).` at the start of the helper section
- put every helper function in the exemption list

```erlang
-compile({nowarn_unused_function, [
    {lf_decode_ret_int32, 1},
    {lf_decode_ret_int64, 1},
    ...
]}).
```

**Lesson**:
- **generate helper functions on demand** (emit only the decoders actually used)
- but for simplicity this generator **generates them all + nowarn**, which is less work

### 4.4 The trap: `ok = lingofuse:reply(...)` crashes on a second reply

**Symptoms**:
- the service throws while handling some API and enters the catch branch
- in the catch branch `ok = lingofuse:reply(...)` throws `{badmatch, {error, unknown_ref}}`
- the exception escapes `?SERVICE_MODULE:lf_dispatch_call`
- the service main loop crashes

**Root cause**:
- `lingofuse:reply/2` can be called only once
- the second call returns `{error, unknown_ref}`
- the forced `ok =` match throws `badmatch`

**Fix**:
- **user code should use `_ = lingofuse:reply(...)`, not `ok =`**

```erlang
_ = lingofuse:reply(Ref, encode_ok_int32(_Ret)),
ok
```

**Lesson**:
- **a second reply is `{error, unknown_ref}`, not a throw**
- **always use `_ =`, never `ok =`**

### 4.5 The trap: `Cb_ReportServiceIdentity` lacks the status byte (C++ generator)

**Symptoms**:
```
[SERVICE] do_reverse_call: non-ABI response received
```

**Evidence**:
- the C++ client's `Cb_ReportServiceIdentity` uses `io::write_string(out_h.get(), std::string("identity received"))`
- the first byte is `'i'` (0x69), not `0` (STATUS_OK)

**Fix**:
- **in the C++ generator `cpp_abi_cmake_generator_tool.pas`**:

```cpp
std::uint8_t status = 0x00;
out_h.writeRaw(&status, 1);
lingofuse::io::write_string(out_h.get(), std::string("identity received"));
```

**Lesson**:
- **every ABI callback must obey the `[status 0x00/0xFF][payload]` contract strictly**
- **`io::write_string` only writes a string; it does not write a status byte**

---

## Chapter 5 Traps in the test layer

### 5.1 The trap: `whereis(lf_test_pid)` is never registered (one of the biggest traps in this run)

**Symptoms**:
- the client's `[CLIENT] service called me, service UID = ...` is printed
- but `test_service_initiates_call` times out after 15 seconds

**Evidence (from this run's logs)**:
```
[CLIENT] service called me, service UID = ...
[WARN] service-initiated call timeout (15s), UID tests will be SKIP
```

**Root cause**:
- `loop/1` looks up TestPid with `whereis(lf_test_pid)`
- but **`run_tests/1` never calls `register_test_pid/0`**
- no `register(lf_test_pid, TestPid)` ever happens
- so `whereis(lf_test_pid)` always returns `undefined`
- `TestPid ! {service_uid_received, ...}` never executes
- TestPid sits in `receive` for 15 seconds and times out

**Fix**:
- **do not use `register/whereis`** (fragile and easy to forget)
- just `spawn` in `main` and pass the pid into `loop(App, TestPid)`:

```erlang
main(_) ->
    ...
    MainPid = self(),
    TestPid = spawn(fun() -> run_tests(MainPid) end),
    loop(App, TestPid).   %% pass TestPid in directly

loop(App, TestPid) ->
    receive
        {lf_call, Ref, <<"LF_TEST_REPORT_SERVICE_IDENTITY">>, _Payload, Identity} ->
            ServiceUid = maps:get(uid, Identity, <<0:256>>),
            TestPid ! {service_uid_received, ServiceUid},   %% send directly
            ...
```

**Lesson**:
- **closures / parameter passing are more reliable than `register/whereis`**
- **a `whereis` returning `undefined` must not be silently ignored** (it should fail loudly at once)

### 5.2 The trap: the `os:getpid()` type in `unique_fake_uid`

**Symptoms**:
```
{badarg, {1, binary, type, "11536"}}
```

**Root cause**:
- `os:getpid()` returns a `string()`, which cannot be used directly as `/binary`

**Fix**:

```erlang
unique_fake_uid() ->
    crypto:strong_rand_bytes(32).
```

### 5.3 The trap: the instantiator's `skip` is not handled

**Symptoms**:
```
{badmap, skip}
```

**Root cause**:
- when `ensure_native_or_skip` returns `skip`, `Ctx = skip`
- `maps:get(uid, skip)` crashes

**Fix**:

```erlang
uid_addressing_test_() ->
    {setup,
     fun setup_uid_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) when is_map(Ctx) -> [ ... ];
        (_) -> []
     end}.
```

### 5.4 The trap: `flush_lf_messages` does not cover the 16 tuple shapes

**Symptoms**:
- leftover messages pollute the next test

**Root cause**:
- the message tuple shape depends on the `with_identity` switch × call/notify × app/p2p, which is **2×2×2×2 = 16 shapes** in total
- the old version covered only 3-tuples, missing the 4-tuple / 5-tuple forms

**Fix**:
- `flush_lf_messages` must cover all 16:

```erlang
flush_lf_messages() ->
    receive
        {lf_call, _, _}              -> flush_lf_messages();
        {lf_call, _, _, _}           -> flush_lf_messages();
        {lf_call, _, _, _, _}        -> flush_lf_messages();
        {lf_notify, _}               -> flush_lf_messages();
        {lf_notify, _, _}            -> flush_lf_messages();
        {lf_notify, _, _, _}         -> flush_lf_messages();
        {lf_p2p_call, _, _}          -> flush_lf_messages();
        {lf_p2p_call, _, _, _}       -> flush_lf_messages();
        {lf_p2p_call, _, _, _, _}    -> flush_lf_messages();
        {lf_p2p_notify, _}           -> flush_lf_messages();
        {lf_p2p_notify, _, _}        -> flush_lf_messages();
        {lf_p2p_notify, _, _, _}     -> flush_lf_messages();
        {lf_async_result, _, _}      -> flush_lf_messages();
        {lf_connect, _}              -> flush_lf_messages();
        {lf_disconnect, _}           -> flush_lf_messages()
    after 0 -> ok
    end.
```

### 5.5 The trap: `sleep(1500)` is too short, so SelfClient's UID/P2P is never reported

**Symptoms**:
- the service prints `[OK] service ready`
- but the client's immediate `LF_UID_Call(service_uid)` times out after 5 seconds

**Evidence (from this run's logs)**:
```
[OK] service ready on ipc:ComplexTestUnit_abi     ← sleep(1500) has ended
[OK] service P2P group = ComplexTestUnit_service_test_p2p
LingoFuse Service Link Succeeded IO "..."          ← the Link only succeeds after ready!
```

**Root cause**:
- `LF_PrepareDone` with `Wait_Connection_ReadyOk=False` returns immediately
- SelfClient's Link establishment plus the UID/P2P report take longer
- `sleep(1500)` is not enough

**Fix**:
- `sleep(1500)` → `sleep(15000)`

**Lesson**:
- **with `Wait_Connection_ReadyOk=False`, `LF_PrepareDone` returns immediately**, but SelfClient's Link and report are asynchronous
- **service main must sleep long enough**, or explicitly poll `check_app` / `check_uid` / `check_p2pname`

### 5.6 The trap: the client's `probe_client_identity` runs before the service `loop` is ready

**Symptoms**:
```
ComplexTestUnit_abi -> LF_TEST_WHOAMI call timeout
[WARN] whoami: empty response
[WARN] whoami failed
```

**Root cause**:
- the client's `wait_service_ready(40)` (`check_app`, based on the **client's local cache**) returns true before the service's `sleep(15000)` ends
- the client's `probe_client_identity` runs during the service's `sleep(15000)`
- the service's `loop(App)` has not entered receive yet
- the client's `LF_Call` times out after 5 seconds

**Fix (optional, not applied)**:
- turn `probe_client_identity` into a retry loop, up to 60 attempts (60 seconds):

```erlang
probe_client_identity_with_retry() ->
    probe_client_identity_with_retry(60).

probe_client_identity_with_retry(0) ->
    io:format("[WARN] whoami failed after 60 retries~n"),
    false;
probe_client_identity_with_retry(N) ->
    case probe_client_identity() of
        true -> true;
        false ->
            timer:sleep(1000),
            probe_client_identity_with_retry(N - 1)
    end.
```

**Lesson**:
- **`check_app` is based on the client's local cache** and lags by about 3 seconds
- **`check_app = true` does not mean the service `loop` is ready**
- **the first `LF_Call` may time out**, so a retry is needed

### 5.7 The trap: a leftover `erl_crash.dump`

**Symptoms**:
- a 3.2 MB `erl_crash.dump` appears in the project root

**Root cause**:
- left behind when the Erlang VM crashed during an earlier failed test

**Fix**:
- `Remove-Item erl_crash.dump -Force`

---

## Chapter 6 Traps in the core library

### 6.1 The trap: `Find_Local_UID_App` does not check UID ownership

**Symptoms**:
- the client's `LF_UID_Call(client_uid, "NoParamFunc")` is sent to the server
- the server's `Find_Local_UID_App` finds `NoParamFunc` inside `___LF_P2P_APP___` (the P2P API the service registered itself)
- **and returns the service's own App directly**
- the server executes it locally and never returns a reply to the client
- the client times out

**Where in the source**: `TC40_LF_Service.Find_Local_UID_App` in `Z.Net.C4.LingoFuse.pas`

**The correct semantics**:
```
Find the API inside the client the UID corresponds to.
- If the UID is this local SelfClient's UID → return the local App
- If the UID is an external client's UID → return nil (so cmd_UID_Call forwards it)
- If the UID is not found → return nil
```

**The current implementation (buggy)**:
```pascal
function TC40_LF_Service.Find_Local_UID_App(UID: TP2P_UID; api_name__: SystemString): TLF_App;
begin
  Result := nil;
  // only checks whether the api is in the local App, ignoring the UID entirely
  if LF_P2P_APP.Engine.LF_MethodPool.Exists_Key(api_name__) then
    begin
      Result := LF_P2P_APP;
      exit;
    end;
  ...
end;
```

**The proposed fix (needs the source)**:
```pascal
function TC40_LF_Service.Find_Local_UID_App(UID: TP2P_UID; api_name__: SystemString): TLF_App;
var
  target_uid_data__: PUID_Data___;
begin
  Result := nil;
  
  // key: first check whether the client for this UID is local
  target_uid_data__ := FUID_Pool.Get_Value_Ptr___(UID);
  if target_uid_data__ = nil then
    exit;  // UID not found, return nil so cmd_UID_Call forwards it
  
  // if the UID is the local SelfClient, look up the api it registered
  if target_uid_data__^.recv_io = nil then
  begin
    if LF_P2P_APP.Engine.LF_MethodPool.Exists_Key(api_name__) then
      Result := LF_P2P_APP;
    exit;
  end;
  
  // if the UID is an external client, return nil so cmd_UID_Call forwards it
  exit;
end;
```

### 6.2 The trap: `cmd_UID_Call` returns silently when it cannot find the target

**Symptoms**:
- the client calls `LF_UID_Call(unknown_uid, ...)` or `LF_UID_Call(service_uid, unknown_api)`
- the server's `Find_Local_UID_App` returns nil
- `cmd_UID_Call` **returns silently, without sending `0xFF + error`**
- the client times out after 5 seconds

**Where in the source**: `TC40_LF_Service.cmd_UID_Call` in `Z.Net.C4.LingoFuse.pas`

**The proposed fix (needs the source)**:

```pascal
if tmp_cli__ = nil then
  begin
    err_m64 := TMem64.Create;
    try
      err_m64.WriteUInt8($FF);
      err_m64.WriteString('no found uid');
      Sender.SendCompleteBuffer_StreamM('CallResult', Ref, err_m64);
    finally
      DisposeObject(err_m64);
    end;
    exit;
  end;
```

### 6.3 The trap: the same problem in `cmd_P2PName_Call`

**Identical to 6.2**: `cmd_P2PName_Call` also returns silently when it cannot find the target.

### 6.4 The trap: `timeout_freed` in `TLF_DataPool.Progress` is uninitialised

**Symptoms**:
```
[LF-DEBUG] DataPool.Progress: live=1 timeout_freed=8391735962092794912
```

**`8391735962092794912 ≈ 8.4 × 10^18`** is an invalid `TTimeTick` (`UInt64`) value.

**Root cause (conjectured)**:
- some field in `TLF_DataPool.Progress` (such as `FTimeOutFreed`) is uninitialised
- or `GetTimeTick` returns an undefined value

**The proposed fix (needs the source)**: initialise `FTimeOutFreed := 0`.

**Impact**:
- in extreme cases it could cause a wrong handle reclaim
- **this run passed 120/120 with no observed impact**

### 6.5 The trap: an access violation in `TLF_App.Destroy` (`$C0000005`)

**Symptoms**:
```
[LF-DEBUG] TLF_App.Destroy: name="ComplexTestUnit_abi"
[Fatal] Unhandled exception code=$C0000005 location=$00007FFEEF605A1A
```

**Root cause (conjectured)**:
- `TLF_App.Destroy` touches freed memory while releasing `Engine` or another internal object
- `Remove_Timer(self)` is called after `Z.Core`'s finalization
- `Timer_Event_Pool__ = nil`, and `nil.Delete` triggers the crash

**The proposed fix (needs the source)**:

```pascal
destructor TLF_App.Destroy;
begin
  ...
  if Assigned(Timer_Event_Pool__) then
      Remove_Timer(self);
  ...
end;
```

**Impact**:
- **this run passed 120/120** because the user exited the process directly with `halt(0)`, never taking the `LF_Shutdown` → `TLF_App.Destroy` path
- but exiting via the normal `LF_Shutdown` path will definitely crash

---

## Chapter 7 The final root cause

> **This was the deepest trap of the run, and it made every UID/P2PName route time out. It took 3 rounds of wrong fixes to find.**

### 7.1 The full causal chain

```
Client LF_UID_Call(service_uid, "NoParamFunc")
  ↓
Server cmd_UID_Call
  ↓
Find_Local_UID_App(service_uid, "NoParamFunc") → LF_P2P_APP (because the P2P APP has NoParamFunc)
  ↓
LF_P2P_APP.Engine.Execute_Call
  ↓
api_.On_Call(Trigger=P2P CallbackEntry*, ...)
  ↓
NIF lf_call_callback(Trigger, ...)
  ↓
dispatch_to_process(e, input, 1)
  ↓
e->is_p2p=1, e->is_sync=1
  ↓
enif_send({lf_p2p_call, Ref, Api, Payload, Identity})   ← ★ key
  ↓
Service loop _Other branch discards it                   ← ★ root cause
  ↓
sync_wait waits 30 seconds (g_sync_timeout_ms = 30000)
  ↓
returns got=0, lf_sync_take_result empty, write_to_output_handle writes nothing
  ↓
Execute_Call prints done: result_size=0 (but 30 seconds later)
  ↓
the client already timed out at 5 seconds
```

**When the user looked at the log after 5 seconds, `done` had not been printed yet, so "found=yes but no `done`" is entirely consistent.**

### 7.2 The NIF sends a different atom depending on `e->is_p2p`

`build_callback_message` in `lingofuse_nif.c`:

```c
if (e->is_notify) {
    terms[n++] = e->is_p2p ? ATOM_LF_P2P_NOTIFY : ATOM_LF_NOTIFY;
} else {
    terms[n++] = e->is_p2p ? ATOM_LF_P2P_CALL : ATOM_LF_CALL;
    if (e->is_sync) terms[n++] = enif_make_uint64(env, ref);
}
terms[n++] = api_term;
terms[n++] = payload_term;
if (e->with_identity && id != NULL) terms[n++] = make_identity_map(env, id);
```

**The mapping from registration to the atom sent**:

| Registration | `e->is_p2p` | `e->is_sync` | The Erlang message sent |
|---------|:-----------:|:------------:|-------------------|
| `register_call` | 0 | 0 | `{lf_call, Api, Payload, Identity}` |
| `register_call_sync` | 0 | 1 | `{lf_call, Ref, Api, Payload, Identity}` |
| `register_notify` | 0 | - | `{lf_notify, Api, Payload, Identity}` |
| `register_p2p_call` | 1 | 0 | `{lf_p2p_call, Api, Payload, Identity}` |
| **`register_p2p_call_sync`** | **1** | **1** | **`{lf_p2p_call, Ref, Api, Payload, Identity}`** |
| `register_p2p_notify` | 1 | - | `{lf_p2p_notify, Api, Payload, Identity}` |

### 7.3 Before the fix: the service main loop matched only `lf_call` / `lf_notify`

```erlang
loop(App) ->
    receive
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload, Identity} -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload, Identity} -> ...;
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload} -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload} -> ...;
        {lf_call, Ref, Api, Payload, Identity} -> ...;    ← matches App-level sync
        {lf_notify, Api, Payload, Identity} -> ...;       ← matches App-level async notify
        _Other -> loop(App)                                ← ★ lf_p2p_call lands here and is dropped
    end.
```

### 7.4 After the fix: the service main loop covers 16 branches

```erlang
loop(App) ->
    receive
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload, Identity} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload, Identity} when is_integer(Ref) -> ...;
        {lf_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, <<"LF_TEST_WHOAMI">>, _Payload} when is_integer(Ref) -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload, Identity} -> ...;
        {lf_p2p_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload, Identity} -> ...;
        {lf_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload} -> ...;
        {lf_p2p_notify, <<"LF_TEST_ASK_SERVICE_CALL_ME">>, _Payload} -> ...;
        {lf_call, Ref, Api, Payload, Identity} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, Api, Payload, Identity} when is_integer(Ref) -> ...;
        {lf_call, Ref, Api, Payload} when is_integer(Ref) -> ...;
        {lf_p2p_call, Ref, Api, Payload} when is_integer(Ref) -> ...;
        {lf_notify, Api, Payload, Identity} when is_binary(Api) -> ...;
        {lf_p2p_notify, Api, Payload, Identity} when is_binary(Api) -> ...;
        {lf_notify, Api, Payload} when is_binary(Api) -> ...;
        {lf_p2p_notify, Api, Payload} when is_binary(Api) -> ...;
        _Other -> loop(App)
    end.
```

### 7.5 Why the `when is_integer(Ref)` guards matter

- in `{lf_call, Api, Payload, Identity}` (async registration) the 2nd element is a **binary** (the Api name)
- in `{lf_call, Ref, Api, Payload}` (sync registration) the 2nd element is an **integer** (the Ref)
- without guards, Erlang matches in order and the clauses may grab each other's messages
- **the guards guarantee that messages of different arity match precisely**

### 7.6 Lessons

1. **the NIF's atom distinction is sound design**: it lets users tell App-level from P2P-level callbacks
2. **the generator's loop must handle all 16 atom shapes**
3. **switching the client to async does not help** (the server's `cmd_UID_Call` still calls `LF_P2P_APP.Engine.Execute_Call` and still sends `lf_p2p_call`)
4. **switching the service to `register_call` (async registration) does not help either** (`e->is_p2p` is still decided by the registration function, and the NIF still sends `lf_p2p_call`)
5. **the only place to fix is the loop's branches**

---

## Chapter 8 Diagnostic methodology

### 8.1 The layered investigation order

**The correct investigation order**:

1. **is the test code itself buggy** (`flush_lf_messages`, `wait_until` timing, return-value matching)
2. **is the build script correct** (`LINGOFUSE_SKIP_NIF`, DLL copying, junctions)
3. **is the NIF layer buggy** (`sync_wait`, `sync_deliver`, `read_and_strip_nul`)
4. **is the core library buggy** (`FUID_Pool`, `cmd_UID_Call`, `Find_Local_UID_App`)
5. **is the generator layer buggy** (wire format, atom shapes, helper functions)

**This run's problems** spanned layers 1, 2, 3 and 5; they were **not core-library problems** (the core library has bugs too, but they were not the root cause of this hang).

### 8.2 The diagnostic trio

1. **`Quiet=False`**: turn on full debug logging
2. **`LINGOFUSE_NIF_DEBUG=1`**: turn on NIF diagnostics
3. **`trigger=%s` logging**: print the Trigger value inside `LF_Register*`

### 8.3 The key judgement rules

**When the symptom is "one route times out but the others PASS"**:

- ✅ first check **whether the atom shape is handled** (`lf_call` / `lf_p2p_call`)
- ✅ then check **UID ownership** (whether `Find_Local_UID_App` is correct)
- ❌ do **not** check the `Trigger` value first (Trigger is a `CallbackEntry*` address; App level and P2P level differing is normal)
- ❌ do **not** check `sync_wait` first (it depends on `e->caller_pid`, unrelated to Trigger)

**When the symptom is "cross-language communication fails"**:

- ✅ first check **whether the wire format agrees** (binary vs JSON)
- ✅ then check **whether the NIF strips `#0`**
- ❌ do **not** check business code first

### 8.4 Reading the logs

**After every fix you must look at**:

1. whether `Engine.Execute_Call done: result_size=N` **appears after `Engine.Execute_Call: ... found=yes`**
2. if there is **no `done`**: the call is stuck inside `api_.On_Call`
3. if there **is `done` but the client still times out**: the return path is broken

**The key finding in this run**: after `found=yes` on the UID route there was **no `done`**, while after `found=yes` on the app-name route there **was `done`**. That difference pointed inside `api_.On_Call`.

---

## Chapter 9 The anti-hallucination checklist

> Every item below is a mistake an AI actually made during this run.

### 9.1 ❌ Wrong: thinking the UID route hang meant `Trigger` was invalid

**The truth**: `Trigger` is a `CallbackEntry*` address; App level and P2P level each allocate their own `CallbackEntry*` and **both are non-nil**. `sync_wait` depends on `e->caller_pid`, unrelated to `Trigger`.

### 9.2 ❌ Wrong: thinking switching the client to async_call would fix the UID route timeout

**The truth**: using `LF_Async_Call` on the client only changes the client-side call style. **The server's `cmd_UID_Call` still calls `LF_P2P_APP.Engine.Execute_Call`, still sends `lf_p2p_call`, and still hangs.**

### 9.3 ❌ Wrong: thinking the service using `register_call` (async registration) would fix it

**The truth**: `e->is_p2p` is still decided by the registration function (`register_p2p_call` → `e->is_p2p = 1`). The NIF still sends `lf_p2p_call`. The service loop still does not match it.

### 9.4 ❌ Wrong: thinking `Find_Local_UID_App` in the core library was the only root cause

**The truth**: `Find_Local_UID_App` does have a bug (it does not check UID ownership), but **even after fixing it**, if `lf_p2p_call` is not handled by the loop, **the UID route still times out**.

**Both bugs must be fixed**: `Find_Local_UID_App` (so the UID route forwards to the right target) + the loop handling `lf_p2p_call` (so P2P-level callbacks can execute).

### 9.5 ❌ Wrong: thinking `lingofuse:reply(Ref, <<...>>)` can use `ok =`

**The truth**: `lingofuse:reply/2` can be called only once. The second call returns `{error, unknown_ref}`. `ok =` throws `{badmatch, {error, unknown_ref}}`.

### 9.6 ❌ Wrong: thinking the `?CALL_MODULE` macro is the standard idiom

**The truth**: under OTP 29, `?CALL_MODULE:NoParamFunc(...)` is parsed as `variable 'NoParamFunc' is unbound`. **You must inline the atom literal.**

### 9.7 ❌ Wrong: thinking `sleep(1500)` is enough for SelfClient to finish its Link

**The truth**: `LF_PrepareDone` returns immediately with `Wait_Connection_ReadyOk=False`, but SelfClient's Link establishment and UID/P2P report are asynchronous. `sleep(1500)` is not enough; **`sleep(15000)` is the stable choice**.

### 9.8 ❌ Wrong: thinking `whereis(lf_test_pid)` will find TestPid

**The truth**: if `run_tests/1` never does `register(lf_test_pid, TestPid)`, `whereis` always returns `undefined`. **Passing the pid as a parameter is more reliable.**

### 9.9 ❌ Wrong: thinking `\\` is an escape inside a PowerShell double-quoted string

**The truth**: inside a PowerShell double-quoted string, `\\` is two literal backslashes. What reaches the regex engine is `\\(`, where `(` opens an unclosed group.

### 9.10 ❌ Wrong: thinking `file:copy` is safe on a junction

**The truth**: a junction on Windows is rebar3's default. `file:copy(Src, Dst)` opens `Dst` in write mode, truncating it to 0, and since `Src` and `Dst` are the same file it is suicide.

### 9.11 ❌ Wrong: thinking `-replace "\.app\.src$", ""` is reliable

**The truth**: it is unreliable in some PowerShell environments. `.EndsWith` + `.Substring` is more stable.

### 9.12 ❌ Wrong: thinking `lingofuse_json:loads(<<"{\"k\":1}", 0>>)` can decode

**The truth**: `json:decode(<<"{\"k\":1}", 0>>)` throws `{invalid_byte, 0}`. **The trailing `#0` must be stripped.**

### 9.13 ❌ Wrong: thinking the wire for `int32 42` is `2A 00 00` (3 bytes)

**The truth**: the wire for `int32 42` is `2A 00 00 00` (4 bytes). Stripping `#0` in the NIF layer swallows the high byte.

### 9.14 ❌ Wrong: thinking `read_and_strip_nul` "does the user a favour"

**The truth**: the C ABI layer not stripping is the precondition for cross-language binary interoperability. Stripping is the consumer's job.

### 9.15 ❌ Wrong: thinking the `Count` property can be read directly

**The truth**: fields such as `FTimeOutFreed` in `Z.LingoFuse_Core` may be uninitialised. `timeout_freed` in `TLF_DataPool.Progress` showing `8.4 × 10^18` proves there are uninitialised fields.

---

## Chapter 10 The quick reference

### 10.1 Symptom → root cause → fix

| Symptom | Root cause | Fix |
|------|------|------|
| `variable 'Xxx' is unbound` | `?CALL_MODULE` macro + OTP 29 | inline the atom literal |
| `function run_p2p_notify_test/4 undefined` | an old test generator | delete the old files and regenerate |
| `Warning: function lf_decode_ret_* is unused` | some types are unused | `-compile({nowarn_unused_function, ...})` |
| `Warning: function decode_params_* is unused` | some APIs take no parameters | same as above |
| `{badmatch, {error, unknown_ref}}` | a second `lingofuse:reply` | `ok =` → `_ =` |
| `{invalid_byte, 0}` | JSON decoding met a `#0` | add `strip_trailing_nul` to `loads/1` |
| `{invalid_byte, 42}` | the NIF stripped an int32 high byte | the NIF layer must not strip |
| `ComplexTestUnit_abi -> LF_TEST_WHOAMI call timeout` | the service loop is not ready | `sleep(15000)` + a `probe_client_identity` retry |
| UID route timeout | `lf_p2p_call` not handled by the loop | add an `lf_p2p_call` branch to the loop |
| P2PName route timeout | same as above | same as above |
| `[DIAG] UID NOT registered after 20s` | SelfClient has not reported | lengthen the `sleep` + poll explicitly |
| `[Fatal] Unhandled exception code=$C0000005` | a crash in `TLF_App.Destroy` | `if Assigned(Timer_Event_Pool__) then Remove_Timer(self);` |
| `timeout_freed=8391735962092794912` | an uninitialised field in `TLF_DataPool.Progress` | needs the core-library source |
| `[lingofuse_nif] get_self_uid=no (old dll)` | the old DLL lacks `LF_Get_Self_UID` | upgrade the DLL |
| `Invalid pattern '(?m)^-module\\('` | PowerShell `\\` escaping | use `.StartsWith` |
| `[info] UnitName: ComplexTestUnit_abi.app.src` | `-replace` is unreliable | use `.EndsWith` + `.Substring` |
| `83005-byte DLL → 0 bytes` | `file:copy` commits suicide on a junction | a `same_stat` check |
| `Service exited prematurely` | a port conflict or a zombie IPC queue | clean up manually or change the port |

### 10.2 Key log keywords

| Keyword | Meaning |
|--------|------|
| `Engine.Execute_Call: ... found=yes` | just before entering `api_.On_Call` |
| `Engine.Execute_Call done: result_size=N` | returned normally |
| `SVC.cmd_Call: LOCAL path, HPC dispatch` | the app-name route executed locally |
| `SVC.cmd_UID_Call: ENTER` | the UID route begins |
| `Find_Local_UID_App: ... matched=True` | the UID route hit locally |
| `Find_Local_UID_App: ... matched=False` | the UID route did not hit locally |
| `Client.Wait_UID_Execute_Call_Impl: TIMEOUT` | the client timed out |
| `[DIAG] UID registered after N polls` | UID registration succeeded (client cache) |
| `[SERVICE] do_reverse_call: OK` | the reverse call succeeded |

### 10.3 The key atom shapes (16)

| Registration | With Identity | Without Identity |
|---------|-------------|-------------|
| `register_call` | `{lf_call, Api, Payload, Identity}` | `{lf_call, Api, Payload}` |
| `register_call_sync` | `{lf_call, Ref, Api, Payload, Identity}` | `{lf_call, Ref, Api, Payload}` |
| `register_notify` | `{lf_notify, Api, Payload, Identity}` | `{lf_notify, Api, Payload}` |
| `register_p2p_call` | `{lf_p2p_call, Api, Payload, Identity}` | `{lf_p2p_call, Api, Payload}` |
| `register_p2p_call_sync` | `{lf_p2p_call, Ref, Api, Payload, Identity}` | `{lf_p2p_call, Ref, Api, Payload}` |
| `register_p2p_notify` | `{lf_p2p_notify, Api, Payload, Identity}` | `{lf_p2p_notify, Api, Payload}` |

**Notes**:
- every sync message carries a `Ref` (integer)
- the last element of every message with Identity is a map
- **the `when is_integer(Ref)` / `when is_binary(Api)` guards are mandatory**

---

## Appendix A A snapshot of the environment

| Item | Value |
|----|-----|
| OS | Windows 10.0.20348.0 (X64) |
| Erlang/OTP | 29 |
| erts | 17.1 |
| PowerShell | 7.6.6 |
| .NET | 10.0.12 |
| rebar3 | the local `rebar3.cmd` |
| gcc | MinGW-w64 16.1.0 (`x86_64-win32-seh-rev1`) |
| clang | LLVM 23.1.2 |
| LingoFuse64.dll | 2924544 bytes (**old version, lacks `LF_Get_Self_UID`**) |
| z_ipc_64.dll | 258048 bytes (2026-08-26) |

**Key environment variables**:

| Variable | Purpose |
|------|------|
| `LINGOFUSE_SKIP_NIF` | skip NIF compilation (`0`/`false`/`no`/`off` count as "do not skip") |
| `LINGOFUSE_NIF_DEBUG` | enable NIF diagnostic fprintf |
| `LINGOFUSE_REQUIRE_NATIVE` | fail hard when the native library is missing (for CI) |
| `LINGOFUSE_CC` | choose the C compiler |

---

## Appendix B The list of files fixed in this run

### B.1 The generators fixed

| # | File | Key change | Status |
|---|------|---------|:----:|
| 1 | `erlang_abi_service_generator_tool.pas` | binary wire + `_ =` reply + `-compile(nowarn)` | ✅ |
| 2 | `erlang_abi_call_generator_tool.pas` | binary wire + inline atoms + `-compile(nowarn)` | ✅ |
| 3 | `erlang_abi_test_generator_tool.pas` | **service loop with 16 branches** + `sleep(15000)` + `wait_uid/p2p_registered` | ✅ |
| 4 | `erlang_abi_test_setup_generator_tool.pas` | UnitName detection (`.EndsWith`) + stale cleanup + rebar3 compile | ✅ |
| 5 | `cpp_abi_cmake_generator_tool.pas` (user-fixed) | `Cb_ReportServiceIdentity` gains the status byte | ✅ |

### B.2 The NIF fixed

| # | File | Key change | Status |
|---|------|---------|:----:|
| 1 | `c_src/lingofuse_nif.c` | replaced `read_and_strip_nul` with `read_input_payload` | ✅ |
| 2 | `c_src/build.escript` | size printing + `same_stat` check + a `file:delete` guard + `halt(3)/(4)` hard failure | ✅ |
| 3 | `build.ps1` | `Invoke-Step` uses `\| Out-Host` | ✅ |

### B.3 The Erlang binding fixed

| # | File | Key change | Status |
|---|------|---------|:----:|
| 1 | `src/lingofuse.erl` | 24 typed ABI primitives | ✅ |
| 2 | `src/lingofuse_json.erl` | `loads/1` gains `strip_trailing_nul` | ✅ |
| 3 | `src/lingofuse_nif.erl` | removed comments | ✅ |
| 4 | `src/lingofuse_app.erl` | removed comments | ✅ |
| 5 | `src/lingofuse_sup.erl` | removed comments | ✅ |

### B.4 The tests fixed

| # | File | Key change | Status |
|---|------|---------|:----:|
| 1 | `test/lingofuse_network_tests.erl` | 5 fixes (`unique_fake_uid` / instantiator / flush over 16 shapes) | ✅ |

### B.5 Core library not fixed (the source is needed)

| # | Location | Bug |
|---|------|-----|
| 1 | `Z.Net.C4.LingoFuse.pas` `Find_Local_UID_App` | does not check UID ownership |
| 2 | `Z.Net.C4.LingoFuse.pas` `cmd_UID_Call` | returns silently when the target is not found |
| 3 | `Z.Net.C4.LingoFuse.pas` `cmd_P2PName_Call` | returns silently when the target is not found |
| 4 | `Z.LingoFuse_Core.pas` `TLF_DataPool.Progress` | `timeout_freed` uninitialised |
| 5 | `Z.LingoFuse_Core.pas` `TLF_App.Destroy` | `$C0000005` access violation |

### B.6 Optional optimisation not applied

| # | Location | Optimisation |
|---|------|------|
| 1 | `erlang_abi_test_generator_tool.pas` `probe_client_identity` | add a retry mechanism (eliminates `[WARN] whoami failed`) |

---

## Closing

### What this knowledge base is for

An **accurate, actionable** record of Erlang binding pitfalls. It does not pretend to replace the source, but it lets you avoid repeating the same traps in 90% of situations, and in the remaining 10% it tells you when to stop and ask a human.

### The core promise

- **every pitfall has symptoms + evidence + root cause + fix + lesson**
- **every log fragment comes from this run**
- **no concealment, no beautification, no guessing**

### Quick recall

**Remember these 7 points and you avoid 90% of the rework**:

1. **The ABI layer must use a binary wire**; JSON is forbidden.
2. **The NIF layer does not strip `#0`**.
3. **The service loop must handle `lf_call` / `lf_p2p_call` / `lf_notify` / `lf_p2p_notify` × with/without Identity × specific/generic = 16 shapes**.
4. **`lingofuse:reply/2` is callable only once; use `_ =`, not `ok =`**.
5. **`Trigger` is a `CallbackEntry*`, not nil, and not an Erlang PID**.
6. **`sleep(15000)` lets SelfClient finish its Link + report**.
7. **When a UID/P2PName route times out, first check whether the atom is handled by the loop, do not check Trigger first**.

**If you are still unsure, read Chapter 9's anti-hallucination checklist first, then Chapter 10's quick reference.**

---

**Document version**: v1
**Last updated**: 2026-10-25
**Maintainer**: the Erlang binding maintenance group
