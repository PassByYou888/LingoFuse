// =============================================================================
//  lingofuse.zig - Public surface of the LingoFuse Zig binding.
// -----------------------------------------------------------------------------
//  This is the module root that downstream projects import. It
//  re-exports the stable public API of every layer of the binding.
//
//  Layering (from lowest to highest)
//  ---------------------------------
//
//      sys             Raw C ABI. Use only if you need direct access
//                      to a native function that has no wrapper.
//
//      Error           The error set returned by every fallible wrapper.
//
//      Uid             32-byte P2P session identifier value type. Used
//                      by the UID-addressed call family and by the
//                      side-data identity accessors.
//
//      DataHandle      RAII wrapper around a native data buffer.
//
//      AppHandle       RAII wrapper around a native application.
//
//      framework       Process-wide facade: loader lifecycle, network
//                      preparation, remote invocation (all three
//                      addressing schemes), runtime options, health
//                      checks, status queue, shutdown.
//
//      io              Unified JSON / string / byte I/O. The single
//                      sanctioned path for moving structured data to
//                      and from a DataHandle.
//
//      network_events  Process-global connect / disconnect handlers.
//
//      status          Status queue helpers (getStatusCount /
//                      getStatus / drainStatus / postStatus).
//
//      options         Typed getters / setters for the runtime options.
//
//      p2p             Process-wide P2P API registration, independent
//                      of any App.
//
//      async_call      Modern asynchronous invocation with a
//                      Zig-idiomatic handler API. Callback and
//                      blocking styles for all three addressing
//                      schemes.
//
//  Loader contract
//  ---------------
//  The binding does NOT auto-load the native runtime. A caller must
//  invoke `framework.init()` before any other native call, and
//  `framework.deinit()` on exit.
//
//  Strings
//  -------
//  Every string parameter is UTF-8. Sentinel-terminated slices
//  (`[:0]const u8`) are used for API names, application names, and
//  option values. Raw byte slices (`[]const u8`) are used for binary
//  payloads and for JSON text that must not be truncated at a NUL.
//
//  Array-fill style
//  ----------------
//  No module in this binding uses the `**` array-repeat operator. Zig
//  requires `**` to have matching whitespace on both sides, and any
//  tool that normalises whitespace (an editor, a Markdown round-trip)
//  can silently break that rule. `@splat` and `@memset` are used
//  instead.
// =============================================================================

// =============================================================================
// Raw C ABI
// =============================================================================

/// Raw C ABI access. Use only if a higher-level wrapper does not
/// already cover the operation you need.
pub const sys = @import("sys.zig");

// =============================================================================
// Error set
// =============================================================================

/// The error set returned by every fallible wrapper in this binding.
pub const Error = @import("error.zig").Error;

// =============================================================================
// Core value types
// =============================================================================

/// 32-byte LingoFuse P2P session identifier.
///
/// The `Uid` type unifies the two ABI roles of the Pascal type
/// `TP2P_UID___`:
///
///   - `Uid.toLf()` produces the argument-role `extern struct` used by
///     `LF_UID_Call`, `LF_Check_UID`, and the other UID-addressed
///     functions.
///   - `Uid.fromPtr(p)` copies the 32 bytes out of the return-role
///     pointer returned by `LF_Get_P2P_UID`. The raw pointer is never
///     exposed to the caller.
pub const Uid = @import("uid.zig").Uid;

// =============================================================================
// RAII handles
// =============================================================================

/// RAII data handle.
pub const DataHandle = @import("data_handle.zig").DataHandle;

/// RAII application handle.
pub const AppHandle = @import("app_handle.zig").AppHandle;

/// Handler signatures accepted by `AppHandle.registerCall` and
/// `AppHandle.registerNotify`. Re-exported at the top level so that a
/// caller does not need to reach into `app_handle.zig` to name them.
pub const CallHandler = @import("app_handle.zig").CallHandler;
pub const NotifyHandler = @import("app_handle.zig").NotifyHandler;

// =============================================================================
// Process-wide facade
// =============================================================================

/// Process-wide facade: loader lifecycle, network preparation, remote
/// invocation (all three addressing schemes), runtime options, health
/// checks, status queue, and shutdown.
pub const framework = @import("framework.zig");

// =============================================================================
// Unified I/O
// =============================================================================

/// Unified JSON / string / byte I/O for data handles.
///
/// This is the SINGLE sanctioned path for moving structured data to
/// and from a `DataHandle`. Every service that touches a DataHandle
/// should use the helpers in this module instead of calling
/// `DataHandle.writeBytes` / `DataHandle.readBytes` directly.
pub const io = @import("io.zig");

/// Raw C ABI declarations for the lf_json library, the C++ nlohmann/json
/// wrapper that `io.zig` uses as its JSON engine.
///
/// Callers normally do not touch this module directly; use `io.zig`
/// instead. It is exported for tests and for advanced callers that
/// need to bypass the io layer's framing.
pub const json_c = @import("json_c.zig");

// =============================================================================
// Diagnostics
// =============================================================================

/// Process-global network connect / disconnect event handlers.
pub const network_events = @import("network_events.zig");

/// Status queue helpers: getStatusCount, getStatus, drainStatus,
/// postStatus.
pub const status = @import("status.zig");

// =============================================================================
// Typed options
// =============================================================================

/// Typed getters and setters for the LingoFuse runtime options.
///
/// This module mirrors the `LF_Set_Opt_*` / `LF_Get_Opt_*` helper
/// families that the Pascal and C++ bindings expose, and lets Zig
/// callers avoid the stringly-typed `framework.setOption` form.
///
/// Example:
///
///     try options.setQuiet(true);
///     try options.setWaitConnectionTimeout(10_000);
///     const p2p = try options.getP2PName(alloc);
///     defer alloc.free(p2p);
pub const options = @import("options.zig");

// =============================================================================
// Process-wide P2P registration
// =============================================================================

/// Process-wide P2P API registration.
///
/// APIs registered here live on the process-wide `LF_P2P_APP` and are
/// reachable through UID and P2PName addressing only. They are NOT
/// reachable by App-name addressing, even if the API name happens to
/// match a registered App name.
///
/// Typical use: globally-discoverable utility APIs (health probes,
/// capability discovery, identity echo) that any client in the mesh
/// can call by UID or by P2PName without knowing the target's App
/// name.
pub const p2p = @import("p2p.zig");

// =============================================================================
// Asynchronous invocation
// =============================================================================

/// Modern asynchronous invocation.
///
/// Two styles:
///
///   - Callback: `callAsync` / `callAsyncByUid` / `callAsyncByP2PName`
///     dispatch the request and deliver the result to a user handler
///     on a native worker thread. Because Zig has no closures, the
///     handler is written as a named or anonymous struct's function
///     and receives a `user_ctx` pointer that carries any captured
///     state.
///   - Blocking: `callAsyncWait` / `callAsyncWaitByUid` /
///     `callAsyncWaitByP2PName` wait for the callback to fire (or a
///     Zig-side timeout to expire) and return the response bytes as a
///     plain `[]u8`.
pub const async_call = @import("async_call.zig");
