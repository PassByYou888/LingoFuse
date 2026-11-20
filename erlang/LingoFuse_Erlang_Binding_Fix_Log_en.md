# LingoFuse Erlang Binding — Complete Fix Record

> What this document is: the complete technical archive of this multi-round fix effort.
> Coverage: the base library (C NIF + Erlang), the build chain, the test suite, and the cross-language ABI contract.
> How it is recorded: for each round, the root cause, the evidence, the fix and the verification, plus layered rules of thumb.
> Open items are collected at the end.

---

## Contents

- [0. Starting point and goals](#0-starting-point-and-goals)
- [1. The core cross-language ABI problem](#1-the-core-cross-language-abi-problem)
- [2. Overview of the fix rounds](#2-overview-of-the-fix-rounds)
- [3. Base library fixes (C NIF + Erlang)](#3-base-library-fixes-c-nif--erlang)
- [4. Build chain fixes](#4-build-chain-fixes)
- [5. Test suite fixes](#5-test-suite-fixes)
- [6. The layering principle](#6-the-layering-principle)
- [7. Key lessons learned](#7-key-lessons-learned)
- [8. Open items and follow-up plan](#8-open-items-and-follow-up-plan)
- [Appendix A: file change list](#appendix-a-file-change-list)
- [Appendix B: environment information](#appendix-b-environment-information)

---

## 0. Starting point and goals

### 0.1 The user's original requirement

Apply a unified correction to the following four Erlang generator files:

```
erlang_abi_call_generator_tool.pas
erlang_abi_service_generator_tool.pas
erlang_abi_test_generator_tool.pas
erlang_abi_test_setup_generator_tool.pas
```

Hard constraints:

1. Code in English throughout, conversation in Chinese.
2. Remove every comment.
3. Remove the `.md` generation functions.
4. Escape single quotes as `#39`.
5. **The ABI interface must interoperate and interwork across languages**.
6. Tests follow the C++/Pascal pattern: start the service + call; if it runs through, it passes.
7. Report base library bugs immediately; do not paper over them.
8. LingoFuse must adopt the "ABI first, high-level interface second" design model.

### 0.2 The current state these key logs exposed

**Log A (Pascal call ↔ Erlang service)**:

```
client UID = 7B227032705F6E616D65223A22222C227569645F686578223A22374643354344
NoParamFunc(app call) failed: "ok":true,"result":0}
MultiLineComment(app call) failed: "error":"{invalid_byte,42}","ok":false}
```

**Log B (Erlang call ↔ Pascal service)**:

```
NoParamFunc(app sync) PASS
uid sync SKIP (timeout)
p2p sync SKIP (timeout)
```

**Log C (diag_full.ps1)**:

```
D:\...\priv\lingofuse_nif.dll
    size = 0 bytes
    LOAD : FAIL  err=0
```

---

## 1. The core cross-language ABI problem

### 1.1 How the problem layers

This effort exposed **three** layers of problems, each independent:

| Layer | Problem | Impact |
|---|---|---|
| **generator layer** | the Erlang generator used JSON at the ABI layer while the Pascal/C++ generators used binary | Pascal ↔ Erlang could not talk at all |
| **NIF base library layer** | `read_and_strip_nul` unconditionally stripped the trailing `#0`, breaking the binary ABI | the last byte of int32 / int64 arguments was swallowed |
| **build chain layer** | `file:copy` killed itself on a junction | an 83005-byte DLL became 0 bytes |

### 1.2 Root-cause evidence for each of the three layers

**Generator layer**: `handle_call_*` in `erlang_abi_service_generator_tool.pas` used `lingofuse_json:loads(Payload)`, and the server replied with `lingofuse_json:dumps(#{ok=>true,...})` plus `#0`. The Pascal side's C ABI is binary `[status][result]`, and reading `{` (0x7B) made it conclude `status=ERROR`.

**NIF layer**: `read_and_strip_nul` in `lingofuse_nif.c` was used in `dispatch_to_process` and `lf_async_result_cb`; its logic was "read the whole buffer, and if the last byte is 0x00 strip one byte". For `int32 42` (`2A 00 00 00`) → after stripping it became 3 bytes → generator decoding failed.

**Build chain layer**: on Windows rebar3 implements `_build/test/lib/lingofuse/priv` → `../../../../priv` as a junction. When Erlang's `file:copy(Src, Dst)` opens `Dst` in write mode it truncates it to 0, and since `Dst` and `Src` are the same file → suicide.

---

## 2. Overview of the fix rounds

| Round | File | Change |
|:---:|---|---|
| **1** | `lingofuse_nif.c` | delete `read_and_strip_nul`, add `read_input_payload` (no stripping) |
| **2** | `lingofuse.erl` | add 24 typed ABI read/write primitives (`write_int32/2` … `read_string/1`) |
| **3** | `lingofuse_json.erl` | demote to a user-layer utility; `read_nul_framed` forwards to `lingofuse:read_string_bytes/1` |
| **4** | `lingofuse_nif.erl` / `lingofuse_app.erl` / `lingofuse_sup.erl` | remove comments, all English |
| **4.1** | `c_src/build.escript` | `-shared -static` (failed) |
| **4.2** | `c_src/build.escript` | `-shared -static-libgcc` (failed) |
| **4.3** | `c_src/build.escript` | print `.o` / `.dll` sizes + split the `-I` flags |
| **4.4** | `c_src/build.escript` | `file:delete(Target)` before `link_gcc` + a `same_stat` check in `copy_to_build_dir` |
| **5** | `lingofuse_network_tests.erl` | fix `unique_fake_uid`, the instantiators' `(_) -> []`, and make `t_p2p_register_*` unique |
| **6** | `lingofuse_json.erl` | `loads/1` strips the trailing `#0` (tolerating wire framing) |
| **pending** | `lingofuse_abi_tests` / `json_tests` / `sync_tests` / `async_tests` / `identity_tests` / `options_tests` | comment removal only |
| **pending** | the 4 generators | switch to typed primitives such as `lingofuse:read_int32/1` |

---

## 3. Base library fixes (C NIF + Erlang)

### 3.1 `lingofuse_nif.c` — delete `read_and_strip_nul`

**The old implementation**:

```c
static int read_and_strip_nul(ErlNifEnv* env,
                              TDataHnd hnd,
                              ERL_NIF_TERM* out_term)
{
    // ... read the whole buffer ...
    if (bin.data[size - 1] == 0) {
        size_t new_size = (size_t)(size - 1);
        // strip the trailing byte
    }
    // ...
}
```

**Why it was wrong**: the NIF layer has no authority to decide stripping on the user's behalf. The wire for `(int32 42)` is `2A 00 00 00`, and the trailing 0x00 is int32's high-order byte, not a string terminator.

**The fix**: replaced by `read_input_payload`, which **preserves the bytes intact** and returns them as-is after `LF_SetPos`.

**Impact audit**:

| Scenario | Old behaviour | New behaviour |
|------|-------|-------|
| `(string "abc")` | `61 62 63 00` → `61 62 63` | `61 62 63 00` (stripped by `loads/1` at the user layer) |
| `(int32 42)` | `2A 00 00 00` → `2A 00 00` (wrong) | `2A 00 00 00` (correct) |
| `(int32 1, int32 2)` | one byte short | the full 8 bytes |
| `(string "abc")` with a trailing `#0` | `61 62 63` | `61 62 63 00` (handled at the user layer) |

**The key assertion**: **the C ABI layer must not strip — that is the precondition for cross-language binary interop**.

### 3.2 `lingofuse.erl` — 24 typed ABI primitives

**The new API (12 writes + 12 reads)**:

```erlang
-spec write_int8(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint8(data_handle(), integer()) -> ok | abi_io_error().
-spec write_int16(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint16(data_handle(), integer()) -> ok | abi_io_error().
-spec write_int32(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint32(data_handle(), integer()) -> ok | abi_io_error().
-spec write_int64(data_handle(), integer()) -> ok | abi_io_error().
-spec write_uint64(data_handle(), integer()) -> ok | abi_io_error().
-spec write_single(data_handle(), float() | integer()) -> ok | abi_io_error().
-spec write_double(data_handle(), float() | integer()) -> ok | abi_io_error().
-spec write_string(data_handle(), binary()) -> ok | abi_io_error().
-spec write_string_bytes(data_handle(), binary()) -> ok | abi_io_error().

-spec read_int8(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint8(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_int16(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint16(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_int32(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint32(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_int64(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_uint64(data_handle()) -> {ok, integer()} | abi_io_error().
-spec read_single(data_handle()) -> {ok, float()} | abi_io_error().
-spec read_double(data_handle()) -> {ok, float()} | abi_io_error().
-spec read_string(data_handle()) -> {ok, binary()} | abi_io_error().
-spec read_string_bytes(data_handle()) -> {ok, binary()} | abi_io_error().
```

**Core implementation points**:

- all of them use little-endian byte order (`little-signed` / `little-unsigned` / `little-float`)
- reads go through `read_buffer/2` plus binary pattern matching; an insufficient byte count returns `{error, truncated}`
- `read_string/1` = `read_string_bytes/1`: scan for `#0`, and on finding it `set_pos(Hnd, Pos + NulPos + 1)`; with no `#0`, read all the remaining bytes
- `write_string/2` = `write_string_bytes/2`: `<<Bin/binary, 0>>` appends `#0`

**The exported type**:

```erlang
-type abi_io_error() ::
    {error, lf_not_loaded}
    | {error, short_write}
    | {error, truncated}
    | {error, eof}
    | {error, no_nul_terminator}
    | {error, term()}.
```

**Design intent**: the generators (to be delivered in round 5) will use these primitives in place of the JSON wire.

### 3.3 `lingofuse_json.erl` — demoted + tolerant of wire framing

**Positioning change**: demoted from "part of the ABI layer" to "a user-layer convenience utility".

**The core fix** (round 6):

```erlang
-spec loads(binary()) -> term().
loads(Bin) when is_binary(Bin) ->
    json:decode(strip_trailing_nul(Bin)).

strip_trailing_nul(<<>>) ->
    <<>>;
strip_trailing_nul(Bin) ->
    case binary:last(Bin) of
        0 -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.
```

**Why it is needed**: the NIF layer no longer strips (3.1), so in `t_call_no_identity/0` `Payload = <<"{\"k\":1}", 0>>`, and `json:decode` throws `{invalid_byte, 0}` on the `#0`.

**Symmetry check**:

| Function | Behaviour |
|------|------|
| `dumps/1` | does not add `#0` |
| `write_json/2` | adds `#0` (through `write_string_bytes/2`) |
| `loads/1` | **tolerates `#0`** (fixed in this round) |
| `read_json/1` | relies on `read_string_bytes/1` to strip |
| `read_json_or_bytes/1` | same as above |

**`loads/1` was the only gap in this symmetry, and this round closed it**.

**Impact on `t_loads_invalid/0`**: `loads(<<"not json">>)` has no `#0`, `strip_trailing_nul` does not fire, and `json:decode` still throws → **the test still PASSes** (nothing broken).

---

## 4. Build chain fixes

### 4.1 The symptom

```
[build] output file size:
         d:/.../priv/lingofuse_nif.dll       83005 bytes
[build] copied to     : d:/.../_build/test/lib/lingofuse/priv/lingofuse_nif.dll
[build] OK

PS> ls .\priv\
-a---   ...   0 lingofuse_nif.dll     ← 0 bytes!
```

`LoadLibraryA` returned NULL with `GetLastError=0` → DllMain returned FALSE.

### 4.2 The diagnostic process (three iterations)

**Round 4.1**: `-shared -static`

- failed. `-static` globally static-links and changes the PE structure, so the Windows loader cannot load it.

**Round 4.2**: `-shared -static-libgcc`

- failed. Still not a PE structure problem.

**Round 4.3**: added `.o` / `.dll` size printing + split the `-I` flags

- exposed the key fact: **after linking it is 83005 bytes, but `priv/lingofuse_nif.dll` is 0 bytes**.

**Round 4.4**: the `same_stat` check + three lines of defence

- final diagnosis: **`file:copy` committed suicide**.

### 4.3 The `file:copy` suicide mechanism

On Windows rebar3 implements `_build/test/lib/lingofuse/priv` → `../../../../priv` as a junction:

```
_build/test/lib/lingofuse/priv/lingofuse_nif.dll
         ≡  (the same file)
priv/lingofuse_nif.dll
```

Erlang's `file:copy(Src, Dst)` internally:

```erlang
{ok, Fd1} = file:open(Src, [read, raw, binary]),    %% Src = 83005 bytes
{ok, Fd2} = file:open(Dst, [write, raw, binary]),   %% ← truncates to 0 on open
copy_loop(Fd1, Fd2)                                  %% reads 0 bytes → writes 0 bytes
```

Because `Dst` and `Src` are the same file, **`Src` gets truncated to 0 as well**.

### 4.4 The fix

**Three lines of defence**:

**Defence 1: delete `Target` before `link_gcc`**

```erlang
link_gcc(CC, Objs, Target) ->
    _ = file:delete(Target),
    Args = link_flags_gcc() ++ ["-o", Target | Objs],
    run(CC, Args).
```

This keeps a leftover 0-byte file from affecting gcc's `-o` behaviour.

**Defence 2: a `same_stat` check in `copy_to_build_dir`**

```erlang
maybe_copy(Target, Dest) ->
    case filelib:is_dir(filename:dirname(Dest)) of
        false -> info("skip (no dir)", filename:dirname(Dest));
        true ->
            case same_stat(Target, Dest) of
                true ->
                    info("skip (same file)", Dest);
                false ->
                    case file:copy(Target, Dest) of
                        {ok, _} -> info("copied to", Dest);
                        {error, R} -> io:format(standard_error, "...")
                    end
            end
    end.

same_stat(P1, P2) ->
    case {file:read_file_info(P1), file:read_file_info(P2)} of
        {{ok, I1}, {ok, I2}} ->
            I1#file_info.size =:= I2#file_info.size andalso
            I1#file_info.mtime =:= I2#file_info.mtime;
        _ -> false
    end.
```

When `Dest` and `Target` are already the same file (junction/symlink), **skip the copy**.

**Defence 3: two size checks after the build**

```erlang
%% after build
case filelib:file_size(Target) of
    0 -> err("post-build check: ~s is 0 bytes", [Target]), halt(3);
    _ -> ok
end,

copy_to_build_dir(RootDir, Target),

%% after copy
case filelib:file_size(Target) of
    0 -> err("post-copy check: ~s is 0 bytes (copy truncated it)", [Target]), halt(4);
    _ -> ok
end,
```

**Any future truncation path will now fail hard** instead of silently producing a 0-byte DLL.

### 4.5 `build.ps1` — fixing the hidden `Invoke-Step` output

**Problem**: `build.ps1` could not see rebar3's output.

**Root cause**:

```powershell
$code = Invoke-Step -Label 'rebar3 compile' -Body { & $Rebar3 compile }
```

The output of `& $Body` inside `Invoke-Step` was collected into the function's return value → assigned to `$code` and never displayed.

**The fix**: `& $Body | Out-Host`

```powershell
try {
    & $Body | Out-Host
    if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
} catch { ... }
```

`| Out-Host` forces stdout to the console, and it **does not affect `$LASTEXITCODE`** (PowerShell's automatic variable tracks native commands).

---

## 5. Test suite fixes

### 5.1 `lingofuse_network_tests.erl` — five fixes

**Fix 1: `unique_fake_uid/0`**

Old:

```erlang
unique_fake_uid() ->
    N = erlang:unique_integer([positive, monotonic]),
    Seed = crypto:hash(sha256,
                       <<(os:getpid())/binary,      %% ← os:getpid() returns string()
                         (integer_to_binary(N))/binary,
                         (erlang:system_time(nanosecond))/integer>>),
    Seed.
```

`os:getpid()` returns a `string()`, which cannot be used with `/binary` directly → `{badarg, {1, binary, type, "11536"}}`.

New:

```erlang
unique_fake_uid() ->
    crypto:strong_rand_bytes(32).
```

Straight 32 random bytes, no type conversion involved.

**Fix 2: add a `(_) -> []` branch to the three instantiators**

Old:

```erlang
uid_addressing_test_() ->
    {setup,
     fun setup_uid_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) -> [ ... ] end}.       %% ← Ctx = skip makes maps:get crash
```

When `ensure_native_or_skip` returns `skip`, `Ctx = skip` and `maps:get(uid, skip)` → `{badmap, skip}`.

New:

```erlang
uid_addressing_test_() ->
    {setup,
     fun setup_uid_framework/0,
     fun cleanup_framework/1,
     fun(Ctx) when is_map(Ctx) -> [ ... ];
        (_) -> []
     end}.
```

**Fix 3: make the `t_p2p_register_*` API names unique**

Old:

```erlang
Api = <<"eunit_p2p_call_api">>,
```

If the P2P registry is not cleared after `LF_Shutdown`, a re-run fails on the duplicate name.

New:

```erlang
Api = <<"eunit_p2p_call_api_", (unique_api_suffix())/binary>>,

unique_api_suffix() ->
    iolist_to_binary(
      io_lib:format("~s_~p",
                    [os:getpid(),
                     erlang:unique_integer([positive, monotonic])])).
```

**Fix 4: make `flush_lf_messages` cover 4-tuples / 5-tuples**

Old:

```erlang
flush_lf_messages() ->
    receive
        {lf_call, _, _, _}      -> flush_lf_messages();
        {lf_call, _, _}         -> flush_lf_messages();
        {lf_notify, _, _}       -> flush_lf_messages();   %% only matches the 3-tuple
        {lf_notify, _}          -> flush_lf_messages();
        ...
    after 0 -> ok
    end.
```

New:

```erlang
flush_lf_messages() ->
    receive
        {lf_call, _, _}              -> flush_lf_messages();
        {lf_call, _, _, _}           -> flush_lf_messages();
        {lf_call, _, _, _, _}        -> flush_lf_messages();
        {lf_notify, _}               -> flush_lf_messages();
        {lf_notify, _, _}            -> flush_lf_messages();
        {lf_notify, _, _, _}         -> flush_lf_messages();   %% added
        {lf_p2p_call, _, _}          -> flush_lf_messages();
        {lf_p2p_call, _, _, _}       -> flush_lf_messages();
        {lf_p2p_call, _, _, _, _}    -> flush_lf_messages();
        {lf_p2p_notify, _}           -> flush_lf_messages();
        {lf_p2p_notify, _, _}        -> flush_lf_messages();
        {lf_p2p_notify, _, _, _}     -> flush_lf_messages();   %% added
        {lf_async_result, _, _}      -> flush_lf_messages();
        {lf_connect, _}              -> flush_lf_messages();
        {lf_disconnect, _}           -> flush_lf_messages()
    after 0 -> ok
    end.
```

**Fix 5: remove the `%%` comments from `t_p2p_register_*`**

Pure formatting consistency.

### 5.2 `lingofuse_identity_tests.erl` — fixed in this round

**Problem**: `t_call_no_identity/0`'s `?assertMatch(#{<<"k">> := 1}, lingofuse_json:loads(Payload))`.

`Payload` = `<<"{\"k\":1}", 0>>` (the NIF layer no longer strips). `json:decode(<<"{\"k\":1}", 0>>)` → `{invalid_byte, 0}`.

**Root cause**: `lingofuse_json:loads/1` did not strip the `#0`.

**Fix**: the `strip_trailing_nul/1` of section 3.3.

**Impact audit**:

| Test | Impact | Conclusion |
|------|------|------|
| `t_call_no_identity` | the target of this round's fix | ✅ FAIL → PASS |
| `t_call_with_identity` | checks the `Identity` map, does not call `loads` | ✅ no impact |
| `t_notify_no_identity` | only `?assert(is_binary(Payload))` | ✅ no impact |
| `t_notify_with_identity` | checks the `Identity` map | ✅ no impact |
| `t_p2p_register_unregister` | does not call `loads` | ✅ no impact |

### 5.3 The impact on `lingofuse_json_tests.erl`

How `loads/1`'s `strip_trailing_nul` affects that suite:

| Test | Input | Conclusion |
|------|------|------|
| `t_loads_object` | `<<"{\"a\":1}">>` (no `#0`) | ✅ no impact |
| `t_loads_array` | `<<"[1,2,3]">>` | ✅ no impact |
| `t_loads_null` | `<<"null">>` | ✅ no impact |
| `t_loads_booleans` | `<<"true">>` / `<<"false">>` | ✅ no impact |
| `t_loads_invalid` | `<<"not json">>` (no `#0`) | ✅ still fails (`strip_trailing_nul` does not fire) |

**Conclusion**: this round's `loads/1` fix **breaks none** of the existing tests.

---

## 6. The layering principle

LingoFuse's three layers of `#0` handling must divide the work strictly:

| Layer | Responsibility | Example |
|---|------|------|
| **C ABI (NIF)** | **do not strip**; return the raw wire bytes | `read_input_payload` |
| **typed primitives** (`lingofuse:read_*`) | **parse by type**; for strings scan and strip `#0` | `read_string/1` / `read_int32/1` |
| **user layer** (`lingofuse_json:loads/1`) | **tolerate wire framing**; strip the trailing `#0` | `strip_trailing_nul/1` |

**If any layer does too much or too little**, you get exactly this round's `{invalid_byte, 0}` or a stripped high byte of an int32.

### 6.1 Hard rules for the upcoming generator changes

When modifying `erlang_abi_service_generator_tool.pas` / `erlang_abi_call_generator_tool.pas`:

**Must**:

- use typed primitives such as `lingofuse:read_int32/1` (`read_*` already handle `#0` by type)
- use typed primitives such as `lingofuse:write_int32/2` (`write_*` stay binary)
- align the output format with `cpp_abi_service_generator_tool.pas`'s `Safe_Write_Scalar` / `Safe_Write_String` / `Safe_Write_Error`:
  - success: `<<0, ResultBytes/binary>>`
  - failure: `<<255, ErrBytes/binary, 0>>`

**Must not**:

- use `lingofuse_json:loads` / `dumps` to handle ABI arguments
- hand-assemble binary with `read_buffer` (error-prone, and it bypasses the typed primitives' bounds checks)

### 6.2 The cross-language ABI contract (common to all three layers)

| Dimension | Contract |
|------|------|
| string wire | `[UTF-8 bytes][#0]` |
| integer wire | little-endian fixed length (int32 = 4 B, int64 = 8 B) |
| float wire | little-endian IEEE 754 (single = 4 B, double = 8 B) |
| response status | `0x00 = OK` / `0xFF = ERROR` |
| error message | `[status 0xFF][error UTF-8][#0]` |
| UID passing | 32 raw bytes (not a hex string) |

---

## 7. Key lessons learned

### 7.1 "Looks like a library bug" but is really a caller bug (three times)

| # | Surface symptom | Actual cause |
|:-:|---|---|
| 1 | `LINGOFUSE_SKIP_NIF=0` still skipped the build | `skip_requested/0` did not treat `"0"` as false |
| 2 | four workers crashed with `{badmatch,{ok,4}}` | `lingofuse:write_buffer/2` returns `{ok, N}`, not `ok` |
| 3 | all UID/P2PName calls timed out, judged a "self-client architecture problem" | `FUID_Pool` registration has a race (~3 s propagation) and the test did not wait |

### 7.2 The layered diagnostic order

**The correct order of investigation**:

1. **is the test code itself buggy** (`flush_lf_messages`, `wait_until` timing, return-value matching)
2. **is the build script correct** (`LINGOFUSE_SKIP_NIF`, DLL copying, junctions)
3. **is the NIF layer buggy** (`sync_wait`, `sync_deliver`, `read_and_strip_nul`)
4. **is the core library buggy** (`FUID_Pool`, `cmd_UID_Call`, `Find_Local_UID_App`)

**This effort's problems** spanned layers 1, 2 and 3, but were **not core library problems**.

### 7.3 On the "non-stripping ABI"

**The old design** (wrong): the NIF layer stripped `#0` for users, making things convenient for JSON users.

**The new design** (right): the C ABI layer **does not touch the bytes at all**; handling of `#0` is decided by **the consumer** according to the wire contract.

**Rationale**:

- the same wire can carry JSON (stripped by user-layer `loads`), binary (parsed by type in `read_int32`), or raw bytes (preserved by `read_buffer`).
- the NIF layer cannot know the consumer's intent.
- **the ABI layer must stay semantically neutral**.

### 7.4 On junctions

**Junctions on Windows** are rebar3's default implementation. Any `file:copy` to a junction path may commit suicide.

**General rule**:

- before copying, compare `size` + `mtime` with `file:read_file_info` and skip if identical.
- or copy to a temporary file and then atomically replace it with `file:rename`.

### 7.5 On the test's `flush_lf_messages`

The message tuple shape depends on the `with_identity` switch × call/notify × app/p2p, a total of **2×2×2×2 = 16 shapes**:

| Shape | 3-tuple | 4-tuple | 5-tuple |
|------|:---:|:---:|:---:|
| `lf_call` no Ref no Identity | ✅ | | |
| `lf_call` with Ref no Identity | | ✅ | |
| `lf_call` with Ref with Identity | | | ✅ |
| `lf_call` no Ref with Identity | | ✅ | |
| `lf_notify` no Identity | ✅ | | |
| `lf_notify` with Identity | | ✅ | |
| `lf_p2p_call` the same 4 variants | same as the app versions | | |
| `lf_p2p_notify` the same 2 variants | same as the app versions | | |

**`flush_lf_messages` must cover all 16**, otherwise leftover messages pollute the next test.

---

## 8. Open items and follow-up plan

### 8.1 Files still to deliver (comment removal only)

| File | Status |
|------|:---:|
| `lingofuse_abi_tests.erl` | to deliver |
| `lingofuse_json_tests.erl` | to deliver |
| `lingofuse_sync_tests.erl` | to deliver |
| `lingofuse_async_tests.erl` | to deliver |
| `lingofuse_options_tests.erl` | to deliver |
| `lingofuse_identity_tests.erl` | to deliver |

### 8.2 Generators still to deliver (the core work)

| File | Key change |
|------|---------|
| `erlang_abi_service_generator_tool.pas` | replace JSON with `lingofuse:read_*` / `write_*`; align the wire with `Safe_Write_*` |
| `erlang_abi_call_generator_tool.pas` | consume the service's wire contract |
| `erlang_abi_test_setup_generator_tool.pas` | comment removal and English only |
| `erlang_abi_test_generator_tool.pas` | a large file that depends on the first two |

### 8.3 The intended generator wire contract

**Server `handle_call_*`**:

```erlang
handle_call_Api(Ref, PayloadBin, _Identity) ->
    case decode_params(PayloadBin) of
        {ok, [P1, P2, ...]} ->
            try
                Result = internal_call_Api(P1, P2, ...),
                reply_ok(Ref, encode_result(Result))
            catch
                _:_ -> reply_error(Ref, <<"internal error">>)
            end;
        {error, Reason} ->
            reply_error(Ref, format_reason(Reason))
    end.

decode_params(Bin) ->
    %% use typed primitives such as lingofuse:read_int32/1
    ...
```

**Client `lf_do_sync_call`**:

```erlang
lf_do_sync_call(AppName, Api, Args) ->
    {ok, Data} = lingofuse:create_data(Api),
    try
        ok = encode_params(Data, Args),
        {ok, ResHnd} = lingofuse:call(AppName, Data, ?ABI_TIMEOUT_MS),
        try decode_response(ResHnd)
        after lingofuse:free_data(ResHnd) end
    after lingofuse:free_data(Data) end.
```

**Key point**: **`lingofuse_json` must not appear**.

### 8.4 The acceptance bar

- Pascal service ↔ Erlang call: `app` / `uid` / `p2p` all PASS
- Erlang service ↔ Pascal call: every binary-argument API such as `MultiLineComment(int32)` PASS
- Erlang service ↔ Erlang call: all PASS
- Pascal service ↔ C++ call: unchanged (regression test)

---

## Appendix A: file change list

### A.1 Modified (this effort)

| File | Change |
|------|------|
| `c_src/lingofuse_nif.c` | deleted `read_and_strip_nul` → `read_input_payload`; removed the diagnostic fprintf |
| `src/lingofuse.erl` | added 24 typed primitives; removed `%%` comments |
| `src/lingofuse_json.erl` | `loads/1` gains `strip_trailing_nul`; `read_nul_framed` forwards to `read_string_bytes/1` |
| `src/lingofuse_nif.erl` | removed comments |
| `src/lingofuse_app.erl` | removed comments |
| `src/lingofuse_sup.erl` | removed comments |
| `c_src/build.escript` | size printing + `same_stat` check + `file:delete` defence + `halt(3)/(4)` hard failures |
| `build.ps1` | `Invoke-Step` uses `| Out-Host` |
| `test/lingofuse_network_tests.erl` | five fixes (see §5.1) |

### A.2 Not modified (left as they were)

| File | Status |
|------|:---:|
| `test/lingofuse_abi_tests.erl` | to deliver (comment removal only) |
| `test/lingofuse_json_tests.erl` | to deliver (comment removal only) |
| `test/lingofuse_sync_tests.erl` | to deliver (comment removal only) |
| `test/lingofuse_async_tests.erl` | to deliver (add flush + remove comments) |
| `test/lingofuse_identity_tests.erl` | to deliver (comment removal only) |
| `test/lingofuse_options_tests.erl` | to deliver (comment removal only) |
| `check.ps1` / `clean.ps1` / `check_env.ps1` | unchanged |

---

## Appendix B: environment information

**Operating system**: Windows 10.0.20348.0 (X64)

**Toolchain**:

| Tool | Version |
|------|------|
| Erlang/OTP | 29 |
| erts | 17.1 |
| PowerShell | 7.6.6 |
| .NET | 10.0.12 |
| rebar3 | local `rebar3.cmd` |
| gcc | MinGW-w64 16.1.0 (`x86_64-win32-seh-rev1`) |
| clang | LLVM 23.1.2 |
| LingoFuse64.dll | 2924544 bytes (2026-10-24) |
| z_ipc_64.dll | 258048 bytes (2026-08-26) |

**Key environment variables**:

| Variable | Purpose |
|------|------|
| `LINGOFUSE_SKIP_NIF` | skip the NIF build (`0`/`false`/`no`/`off` count as not skipping) |
| `LINGOFUSE_NIF_DEBUG` | enables the NIF diagnostic fprintf (removed, see §A.1) |
| `LINGOFUSE_REQUIRE_NATIVE` | fail hard when the native library is missing (for CI) |
| `LINGOFUSE_CC` | specify the C compiler (new in this round) |

---

## Versions

- **v1** — as of the completion of round 6 (the `lingofuse_json:loads/1` fix for `#0` tolerance)
- v2 will be appended once the generator changes are finished
