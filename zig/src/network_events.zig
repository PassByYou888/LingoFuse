// =============================================================================
//  network_events.zig - Process-global network connect / disconnect events.
// -----------------------------------------------------------------------------
//  This module wraps `LF_Set_Network_Event`, which installs a pair of
//  process-wide callbacks that fire when a LingoFuse client becomes
//  online or goes offline. It mirrors the role of `NetworkEventListener`
//  (C++), `NetworkEvents.cs` (C#), `network_events.py` (Python), and
//  `network_events.rs` (Rust).
//
//  Semantics
//  ---------
//
//      Connect    - Fires the first time a client receives a service
//                   API-info broadcast. This is NOT the TCP handshake;
//                   it is the earliest point at which remote calls can
//                   be routed. Fires once per connection lifecycle, and
//                   again after an auto-reconnect.
//
//      Disconnect - Fires once per physical link loss. An automatic
//                   reconnect does NOT re-fire Disconnect; it fires a
//                   new Connect once the client is back online.
//
//  Threading contract
//  ------------------
//  Callbacks run on a background worker thread owned by the native
//  library. They must:
//
//      - Copy `addr` immediately. This module does it: the handler
//        receives a `[]const u8` derived from `std.mem.span(addr)`,
//        so the caller never needs to worry about the native buffer's
//        lifetime.
//      - Never touch UI directly.
//      - Never call any blocking LingoFuse function (`LF_Call`,
//        `LF_LocalCall`, `LF_PrepareDone`, `LF_Shutdown`). Doing so
//        deadlocks.
//      - Never panic. Zig panics do not unwind cleanly across a
//        `callconv(.c)` boundary, so the trampolines are written to
//        avoid any operation that could panic.
//
//  Replace semantics
//  -----------------
//  `setNetworkEvent` is a **replace** operation, not a patch. Calling
//  it again discards any previously installed handlers, including
//  those whose corresponding argument is null in the new call.
//
//  Global scope
//  ------------
//  `LF_Set_Network_Event` is a process-wide slot. There is no
//  per-client registration.
//
//  Thread safety
//  -------------
//  `setNetworkEvent` / `clearNetworkEvent` are not thread-safe with
//  respect to each other. Call them from a single thread, before any
//  network activity, as the native documentation recommends. The
//  trampolines read the handler slots with plain loads (a single
//  pointer-sized word), which are atomic on all supported platforms.
// =============================================================================

const std = @import("std");
const sys = @import("sys.zig");

/// User handler function type.
///
/// `ctx` is the user-supplied context pointer passed to
/// `setNetworkEvent` (may be null).
///
/// `addr` is a UTF-8 endpoint string. The bytes are owned by this
/// module for the duration of the call only; copy them if you need to
/// keep them beyond the handler's return.
pub const NetworkHandler = *const fn (ctx: ?*anyopaque, addr: []const u8) void;

// -----------------------------------------------------------------------------
// Process-global handler storage
// -----------------------------------------------------------------------------
//
// The two slots are read by the trampolines on every callback. The
// trampolines run on native worker threads and must never block, so
// they use plain loads (a single pointer-sized word, atomic on every
// supported platform).

var g_on_connect: ?NetworkHandler = null;
var g_on_connect_ctx: ?*anyopaque = null;

var g_on_disconnect: ?NetworkHandler = null;
var g_on_disconnect_ctx: ?*anyopaque = null;

// -----------------------------------------------------------------------------
// Trampolines (callconv(.c), never panic)
// -----------------------------------------------------------------------------

fn connectTrampoline(addr: ?[*:0]const u8) callconv(.c) void {
    const handler = g_on_connect orelse return;
    const ctx = g_on_connect_ctx;
    const slice: []const u8 = if (addr) |p| std.mem.span(p) else "";
    handler(ctx, slice);
}

fn disconnectTrampoline(addr: ?[*:0]const u8) callconv(.c) void {
    const handler = g_on_disconnect orelse return;
    const ctx = g_on_disconnect_ctx;
    const slice: []const u8 = if (addr) |p| std.mem.span(p) else "";
    handler(ctx, slice);
}

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------

/// Install the process-global connect and disconnect handlers.
///
/// Passing `null` for either handler disables that event. The
/// corresponding `_ctx` value is passed to the handler unchanged; it
/// may be null.
///
/// # Replace semantics
///
/// This is a **replace** operation. Calling it a second time discards
/// any previously installed handlers, even those whose corresponding
/// argument is null in the new call. To install both handlers, pass
/// both arguments in a single call.
///
/// # Ordering
///
/// The new handler state is published before the native layer is
/// notified, so a callback triggered by the native call already sees
/// the fresh handlers. The trampoline addresses themselves never
/// change, so no further synchronisation is required.
pub fn setNetworkEvent(
    on_connect: ?NetworkHandler,
    on_connect_ctx: ?*anyopaque,
    on_disconnect: ?NetworkHandler,
    on_disconnect_ctx: ?*anyopaque,
) void {
    g_on_connect = on_connect;
    g_on_connect_ctx = on_connect_ctx;
    g_on_disconnect = on_disconnect;
    g_on_disconnect_ctx = on_disconnect_ctx;

    const cp: ?sys.NetworkEventFunc =
        if (on_connect != null) connectTrampoline else null;
    const dp: ?sys.NetworkEventFunc =
        if (on_disconnect != null) disconnectTrampoline else null;

    sys.setNetworkEvent(cp, dp);
}

/// Remove both handlers.
///
/// Equivalent to `setNetworkEvent(null, null, null, null)`.
pub fn clearNetworkEvent() void {
    setNetworkEvent(null, null, null, null);
}

/// Return `true` when at least one handler is currently installed.
pub fn isInstalled() bool {
    return g_on_connect != null or g_on_disconnect != null;
}

/// Return `true` when the connect handler is installed.
pub fn isConnectInstalled() bool {
    return g_on_connect != null;
}

/// Return `true` when the disconnect handler is installed.
pub fn isDisconnectInstalled() bool {
    return g_on_disconnect != null;
}
