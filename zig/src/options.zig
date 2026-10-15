// =============================================================================
//  options.zig - Typed getters and setters for the LingoFuse runtime options.
// -----------------------------------------------------------------------------
//  This module is the Zig counterpart of the `LF_Set_Opt_*` / `LF_Get_Opt_*`
//  helper families in `lingofuse_import.pas` and `LingoFuse.c`. It
//  exists so that callers do not have to spell the option name as a
//  string and hand-format numeric values:
//
//      // Stringly-typed form (framework.setOption):
//      framework.setOption("Quiet", "True");
//
//      // Typed form (this module):
//      try options.setQuiet(true);
//
//  Layering
//  --------
//  This module calls `sys.setOption` / `sys.getOption` directly. It
//  does NOT depend on `framework.zig`, so it can be compiled and tested
//  in isolation. The stringly-typed `framework.setOption` remains
//  available for callers that want raw access.
//
//  Naming convention
//  -----------------
//  Every option has a `setXxx` and a `getXxx` pair, where `Xxx` is the
//  option key's Pascal-case form. The mapping to the C-side helpers is
//  one-to-one by name:
//
//      Zig here                       Pascal lingofuse_import.pas
//      ----------------------------   ---------------------------------
//      setQuiet / getQuiet            LF_Set_Opt_Quiet / LF_Get_Opt_Quiet
//      setPassword / getPassword      LF_Set_Opt_Password
//      setDebug / getDebug            LF_Set_Opt_Debug / LF_Get_Opt_Debug
//      setP2PName / getP2PName        LF_Set_Opt_P2P_Name / LF_Get_Opt_P2P_Name
//      ...                            ...
//
//  Booleans on the wire
//  --------------------
//  The native layer accepts several spellings for a boolean value. This
//  module always writes the canonical `"True"` / `"False"` form, and
//  the getters parse anything the native layer might return as `"True"`
//  (case-insensitive) into `true`; everything else is `false`.
//
//  Unknown options
//  ---------------
//  `LF_SetOption` silently ignores an unknown option name, and
//  `LF_GetOption` returns an empty string. Every `getXxx` in this
//  module therefore returns a documented "safe fallback" for the
//  unknown / unset / malformed case:
//
//      bool          -> false
//      u64 / i64     -> 0
//      i32 (from i64) -> 0
//      []u8 / [:0]u8 -> "" (empty slice)
//
//  A caller that needs to distinguish "unset from a known option" from
//  "set to zero" must use `getString` directly and inspect the raw
//  string.
//
//  Write-only options
//  ------------------
//  A few options (`debug` is the only one today) are write-only. Their
//  getters return a fixed placeholder string, not a stored value.
//
//  Threading
//  ---------
//  The underlying `LF_SetOption` / `LF_GetOption` are thread-safe, and
//  every function in this module is therefore thread-safe as well.
//  However a setter takes effect immediately, so a concurrent reader
//  may observe the old value, the new value, or (for string options) a
//  torn read. An application that needs a consistent multi-option
//  configuration must serialise its own updates behind its own lock.
//
//  Persistence
//  -----------
//  Every option resets to its built-in default when `LF_Shutdown` is
//  called. An application that restarts the framework must reapply its
//  options on every startup.
//
//  Array-fill style
//  ----------------
//  This module uses no `**` operator anywhere. Fixed-size stack buffers
//  are used to format numeric values before writing them to the native
//  layer.
// =============================================================================
const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const util = @import("util.zig");

// =============================================================================
// Low-level primitives
// =============================================================================

/// Set a boolean option, writing the canonical `"True"` / `"False"`
/// string that the native layer expects.
///
/// Unknown `key` values are silently ignored by the native layer.
///
/// # Errors
///
/// This function never returns an error today (the native API returns
/// void), but the error-union return type is kept for API uniformity
/// and to allow a future validation layer without a signature change.
pub fn setBool(key: [:0]const u8, value: bool) Error!void {
    const v: [:0]const u8 = if (value) "True" else "False";
    sys.setOption(key.ptr, v.ptr);
}

/// Read a boolean option.
///
/// Returns `true` when the underlying string equals `"True"`
/// (case-insensitive). Any other value -- including an empty string
/// from an unknown option -- returns `false`.
///
/// # Errors
///
/// - `Error.OutOfMemory` if the internal copy allocation fails.
pub fn getBool(alloc: std.mem.Allocator, key: [:0]const u8) Error!bool {
    const s = try getString(alloc, key);
    defer alloc.free(s);
    return std.ascii.eqlIgnoreCase(s, "True");
}

/// Set an unsigned-integer option, writing the value as a decimal
/// string.
pub fn setU64(key: [:0]const u8, value: u64) Error!void {
    var buf: [24]u8 = undefined; // enough for 20 digits + NUL
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch
        return Error.WriteFailed;
    if (s.len >= buf.len) return Error.WriteFailed;
    buf[s.len] = 0;
    const v: [:0]const u8 = buf[0..s.len :0];
    sys.setOption(key.ptr, v.ptr);
}

/// Read an unsigned-integer option.
///
/// Returns `0` when the underlying string is empty or cannot be parsed
/// as a decimal integer. Trailing garbage after a valid number is
/// ignored, matching the C wrapper's `strtoull`-style parsing.
pub fn getU64(alloc: std.mem.Allocator, key: [:0]const u8) Error!u64 {
    const s = try getString(alloc, key);
    defer alloc.free(s);
    return parseLeadingU64(s);
}

/// Set a signed-integer option, writing the value as a decimal string.
pub fn setI64(key: [:0]const u8, value: i64) Error!void {
    var buf: [24]u8 = undefined; // enough for "-" + 19 digits + NUL
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch
        return Error.WriteFailed;
    if (s.len >= buf.len) return Error.WriteFailed;
    buf[s.len] = 0;
    const v: [:0]const u8 = buf[0..s.len :0];
    sys.setOption(key.ptr, v.ptr);
}

/// Read a signed-integer option.
///
/// Returns `0` when the underlying string is empty or cannot be parsed
/// as a decimal integer.
pub fn getI64(alloc: std.mem.Allocator, key: [:0]const u8) Error!i64 {
    const s = try getString(alloc, key);
    defer alloc.free(s);
    return parseLeadingI64(s);
}

/// Set a string option.
///
/// The string is copied by the native layer; the caller retains
/// ownership of `value`.
pub fn setString(key: [:0]const u8, value: [:0]const u8) Error!void {
    sys.setOption(key.ptr, value.ptr);
}

/// Read a string option.
///
/// Returns an allocator-owned, NUL-terminated slice. The native pointer
/// is copied immediately, so the returned slice is safe to retain.
/// Returns an empty string for an unknown option.
///
/// # Ownership
///
/// The caller owns the returned slice and must free it with
/// `alloc.free`.
pub fn getString(
    alloc: std.mem.Allocator,
    key: [:0]const u8,
) Error![:0]u8 {
    const ptr = sys.getOption(key.ptr);
    return util.copyCstrOrEmpty(alloc, ptr);
}

// =============================================================================
// Internal parsing helpers
// =============================================================================

/// Parse the leading decimal digits of `s` as a `u64`.
///
/// Trailing non-digit characters are ignored. An empty leading digit
/// run, or an overflow, returns 0.
fn parseLeadingU64(s: []const u8) u64 {
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (c < '0' or c > '9') break;
    }
    if (end == 0) return 0;
    return std.fmt.parseInt(u64, s[0..end], 10) catch 0;
}

/// Parse the leading signed decimal of `s` as an `i64`.
///
/// A leading `-` or `+` is accepted. Trailing non-digit characters
/// are ignored. An empty leading digit run, or an overflow, returns 0.
fn parseLeadingI64(s: []const u8) i64 {
    if (s.len == 0) return 0;

    var start: usize = 0;
    if (s[0] == '-' or s[0] == '+') start = 1;

    var end: usize = start;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (c < '0' or c > '9') break;
    }
    if (end == start) return 0;
    return std.fmt.parseInt(i64, s[0..end], 10) catch 0;
}

// =============================================================================
// Authentication
// =============================================================================

/// Set the P2PVM / C4 network authentication password.
///
/// Must match on both sides of a connection or the handshake fails. The
/// default is the well-known development token; a production deployment
/// should set a private value before `prepareService` /
/// `prepareClient`.
pub fn setPassword(value: [:0]const u8) Error!void {
    return setString("password", value);
}

/// Read the configured password.
///
/// The native library deliberately returns a fixed mask rather than the
/// real value. Do not rely on the returned string ever containing the
/// actual password.
pub fn getPassword(alloc: std.mem.Allocator) Error![:0]u8 {
    return getString(alloc, "password");
}

// =============================================================================
// Logging and diagnostics
// =============================================================================

/// Execute a C4 console debug command.
///
/// This option is WRITE-ONLY and has side effects: each call constructs
/// a transient console helper object on the native side and runs the
/// given command. Recognised command names include `"service"`,
/// `"tunnel"`, `"ZNet_Info"`, `"HPC_Thread_Info"`, and
/// `"Instance_Info"`.
///
/// Because each call allocates a helper object, this option is intended
/// for interactive diagnostics only. Do not call it in a hot loop.
pub fn setDebug(value: [:0]const u8) Error!void {
    return setString("debug", value);
}

/// Read the current value of the `debug` option.
///
/// Because the underlying option is write-only, the native library
/// returns a fixed placeholder string rather than a stored value.
pub fn getDebug(alloc: std.mem.Allocator) Error![:0]u8 {
    return getString(alloc, "debug");
}

/// Enable or disable quiet mode.
///
/// When quiet mode is enabled, most internal informational logging is
/// suppressed. Default: `false`.
pub fn setQuiet(value: bool) Error!void {
    return setBool("Quiet", value);
}

/// Return `true` when quiet mode is currently enabled.
pub fn getQuiet(alloc: std.mem.Allocator) Error!bool {
    return getBool(alloc, "Quiet");
}

/// Enable or disable thread-ID prefixes in status output.
/// Default: `false`.
pub fn setShowThreadId(value: bool) Error!void {
    return setBool("ShowThreadID", value);
}

/// Return `true` when thread-ID prefixes are enabled.
pub fn getShowThreadId(alloc: std.mem.Allocator) Error!bool {
    return getBool(alloc, "ShowThreadID");
}

/// Enable or disable console output for status messages.
///
/// When disabled, status messages are still queued and remain readable
/// through `status.getStatus`; only the console sink is muted.
pub fn setConsoleOutput(value: bool) Error!void {
    return setBool("ConsoleOutput", value);
}

/// Return `true` when console output is enabled.
pub fn getConsoleOutput(alloc: std.mem.Allocator) Error!bool {
    return getBool(alloc, "ConsoleOutput");
}

// =============================================================================
// Connection readiness
// =============================================================================

/// Allow or forbid multiple client tunnels to the same physical
/// address.
///
/// `false` (the default): only one client tunnel per physical address.
/// A second `prepareClient` call for the same address returns an error
/// and the new application handle is discarded.
///
/// `true`: every `prepareClient` call creates a new independent tunnel,
/// binding the supplied application handle.
///
/// This option MUST be set BEFORE the `prepareClient` calls it is meant
/// to affect. Changing it after a tunnel has been created does not
/// rearrange existing tunnels.
pub fn setOverlapConnection(value: bool) Error!void {
    return setBool("Overlap_Connection", value);
}

/// Return `true` when overlapping connections are allowed.
pub fn getOverlapConnection(alloc: std.mem.Allocator) Error!bool {
    return getBool(alloc, "Overlap_Connection");
}

/// Control whether `prepareDone` blocks until every prepared client is
/// online.
///
/// `true` (the default): `prepareDone` waits for all prepared clients
/// to reach the "online" state before returning.
///
/// `false`: `prepareDone` returns immediately after the simulated main
/// thread has started. The caller is then responsible for probing
/// readiness itself.
pub fn setWaitConnectionReadyOk(value: bool) Error!void {
    return setBool("Wait_Connection_ReadyOk", value);
}

/// Return `true` when `prepareDone` currently waits for all clients.
pub fn getWaitConnectionReadyOk(alloc: std.mem.Allocator) Error!bool {
    return getBool(alloc, "Wait_Connection_ReadyOk");
}

/// Set the timeout, in milliseconds, for the `prepareDone` wait
/// described by `setWaitConnectionReadyOk`.
///
/// Default: 30000 ms (30 seconds). If the timeout expires before all
/// clients are ready, `prepareDone` still returns `true`; the caller
/// must independently verify readiness if that matters.
pub fn setWaitConnectionTimeout(ms: u64) Error!void {
    return setU64("Wait_Connection_Timeout", ms);
}

/// Return the current `prepareDone` wait timeout, in milliseconds.
pub fn getWaitConnectionTimeout(alloc: std.mem.Allocator) Error!u64 {
    return getU64(alloc, "Wait_Connection_Timeout");
}

// =============================================================================
// IPC
// =============================================================================

/// Set the size of the IPC server thread pool.
///
/// MUST be set before the IPC server is started. Changing it after
/// startup has no effect on an already-running server.
pub fn setIpcServThreadCount(value: i32) Error!void {
    return setI64("IPC_Serv_ThreadCount", value);
}

/// Return the configured IPC server thread count.
pub fn getIpcServThreadCount(alloc: std.mem.Allocator) Error!i32 {
    const v = try getI64(alloc, "IPC_Serv_ThreadCount");
    return @intCast(v);
}

/// Set the maximum length of the IPC server's inbound message queue.
pub fn setIpcServMaxQueueLength(value: i32) Error!void {
    return setI64("IPC_Serv_MaxQueueLength", value);
}

/// Return the configured IPC server max queue length.
pub fn getIpcServMaxQueueLength(alloc: std.mem.Allocator) Error!i32 {
    const v = try getI64(alloc, "IPC_Serv_MaxQueueLength");
    return @intCast(v);
}

/// Set the maximum size, in bytes, of a single IPC message.
pub fn setIpcServMaxMsgSize(value: i32) Error!void {
    return setI64("IPC_Serv_MaxMsgSize", value);
}

/// Return the configured IPC server max message size.
pub fn getIpcServMaxMsgSize(alloc: std.mem.Allocator) Error!i32 {
    const v = try getI64(alloc, "IPC_Serv_MaxMsgSize");
    return @intCast(v);
}

// =============================================================================
// Sequenced notifications
// =============================================================================

/// Set the sticky-affinity window, in milliseconds, for P2PName load
/// balancing.
///
/// When the server-side dispatcher routes a P2PName-addressed call, it
/// normally picks the target with the smallest Cycle_Anchor value (pure
/// round-robin). If, however, a single target has been handling
/// requests for longer than this value, the dispatcher switches to a
/// different target instead, to avoid starvation.
///
/// Default: 20000 ms (20 seconds).
pub fn setFixedSequencedTime(ms: u64) Error!void {
    return setU64("Fixed_Sequenced_Time", ms);
}

/// Return the current sticky-affinity window, in milliseconds.
pub fn getFixedSequencedTime(alloc: std.mem.Allocator) Error!u64 {
    return getU64(alloc, "Fixed_Sequenced_Time");
}

// =============================================================================
// P2P group name
// =============================================================================

/// Set this process's P2P group name.
///
/// The name is injected into every outbound request payload and is
/// reported to the server through the `Update_UID` command. It defines
/// which P2PName-addressed calls this process is willing to receive.
///
/// May be changed at any time. The framework picks up the new name on
/// the next outbound request; there is no need to reconnect.
///
/// Default: empty string ("not a member of any group"). An empty P2P
/// name disables P2PName routing for this process; UID and App-name
/// routing are unaffected.
///
/// # Note
///
/// This is NOT the same as reading the *sender's* P2P name from an
/// input handle via `DataHandle.p2pName()`. That reads the peer's
/// identity; this sets the local identity.
pub fn setP2PName(value: [:0]const u8) Error!void {
    return setString("LF_P2P_name", value);
}

/// Return this process's configured P2P group name.
///
/// Returns an empty string when no name has been set.
pub fn getP2PName(alloc: std.mem.Allocator) Error![:0]u8 {
    return getString(alloc, "LF_P2P_name");
}

// =============================================================================
// Data handle pool
// =============================================================================

/// Set the idle-reclaim threshold, in milliseconds, for auto-recycled
/// data handles.
///
/// A value greater than zero enables idle reclamation: a handle that
/// has not been accessed for at least this long becomes a candidate
/// for release on the next pool scan. The default is 600000 ms
/// (10 minutes).
///
/// A value of zero disables idle reclamation entirely. In that mode,
/// only an explicit `DataHandle.deinit` releases a handle.
///
/// This option does NOT affect handles created with
/// `DataHandle.createPermanent`: those are released synchronously by
/// `deinit` and never enter the idle-reclaim path.
pub fn setDataHandleIdleTimeout(ms: u64) Error!void {
    return setU64("DataHandle_Idle_Timeout", ms);
}

/// Return the current idle-reclaim threshold, in milliseconds.
pub fn getDataHandleIdleTimeout(alloc: std.mem.Allocator) Error!u64 {
    return getU64(alloc, "DataHandle_Idle_Timeout");
}

/// Set the minimum interval, in milliseconds, between two consecutive
/// scans of the data-handle pool.
///
/// A value greater than zero enables rate-limiting. Default: 5000 ms
/// (5 seconds). A value of zero disables the rate limiter; the scanner
/// then runs on every progress tick of the simulated main thread,
/// which can be a significant CPU cost under a busy main loop.
pub fn setDataHandlePoolScanInterval(ms: u64) Error!void {
    return setU64("DataHandle_Pool_Scan_Interval", ms);
}

/// Return the current data-handle pool scan interval, in milliseconds.
pub fn getDataHandlePoolScanInterval(alloc: std.mem.Allocator) Error!u64 {
    return getU64(alloc, "DataHandle_Pool_Scan_Interval");
}

// =============================================================================
// Command flushing
// =============================================================================

/// Set the null-flush threshold for no-response commands.
///
/// The protocol periodically sends a NULL command to force the server
/// to acknowledge pending one-way Notify messages. After every N
/// no-response commands, one NULL command is emitted as a flush point.
///
/// Default: 5000.
///
/// # Note
///
/// The option key uses the historical spelling `Reponse` (without the
/// second 's'). This is intentional and matches the native layer.
pub fn setNoReponseCmdNullFlushThreshold(value: i32) Error!void {
    return setI64("No_Reponse_Cmd_NULL_Flush_Threshold", value);
}

/// Return the current null-flush threshold.
pub fn getNoReponseCmdNullFlushThreshold(
    alloc: std.mem.Allocator,
) Error!i32 {
    const v = try getI64(alloc, "No_Reponse_Cmd_NULL_Flush_Threshold");
    return @intCast(v);
}

// =============================================================================
// Tests
// =============================================================================
//
// This module's public API requires the native runtime (it calls
// `sys.setOption` / `sys.getOption`). The tests below therefore only
// cover the PURE helper functions, which can be exercised without a
// loaded native library. Integration coverage of the public API lives
// in `examples/options_smoke.zig`.

const testing = std.testing;

test "parseLeadingU64: empty input returns 0" {
    try testing.expectEqual(@as(u64, 0), parseLeadingU64(""));
}

test "parseLeadingU64: decimal digits" {
    try testing.expectEqual(@as(u64, 0), parseLeadingU64("0"));
    try testing.expectEqual(@as(u64, 42), parseLeadingU64("42"));
    try testing.expectEqual(
        @as(u64, 18446744073709551615),
        parseLeadingU64("18446744073709551615"),
    );
}

test "parseLeadingU64: trailing garbage is ignored" {
    try testing.expectEqual(@as(u64, 42), parseLeadingU64("42abc"));
    try testing.expectEqual(@as(u64, 42), parseLeadingU64("42 43"));
    try testing.expectEqual(@as(u64, 0), parseLeadingU64("abc42"));
}

test "parseLeadingU64: leading minus returns 0" {
    // The Rust binding's strtoull-style parser would wrap -1 to
    // UINT64_MAX; the Zig binding deliberately rejects the minus
    // sign, because a negative value in an unsigned option is a
    // configuration error, not a wrap-around.
    try testing.expectEqual(@as(u64, 0), parseLeadingU64("-1"));
}

test "parseLeadingU64: overflow returns 0" {
    try testing.expectEqual(
        @as(u64, 0),
        parseLeadingU64("99999999999999999999999"),
    );
}

test "parseLeadingI64: empty input returns 0" {
    try testing.expectEqual(@as(i64, 0), parseLeadingI64(""));
}

test "parseLeadingI64: signed decimal" {
    try testing.expectEqual(@as(i64, 0), parseLeadingI64("0"));
    try testing.expectEqual(@as(i64, 42), parseLeadingI64("42"));
    try testing.expectEqual(@as(i64, -42), parseLeadingI64("-42"));
    try testing.expectEqual(@as(i64, 42), parseLeadingI64("+42"));
}

test "parseLeadingI64: trailing garbage is ignored" {
    try testing.expectEqual(@as(i64, -42), parseLeadingI64("-42xyz"));
    try testing.expectEqual(@as(i64, 42), parseLeadingI64("42 43"));
}

test "parseLeadingI64: bare sign returns 0" {
    try testing.expectEqual(@as(i64, 0), parseLeadingI64("-"));
    try testing.expectEqual(@as(i64, 0), parseLeadingI64("+"));
}

test "parseLeadingI64: overflow returns 0" {
    try testing.expectEqual(
        @as(i64, 0),
        parseLeadingI64("99999999999999999999999"),
    );
}
