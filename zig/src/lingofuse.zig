// =============================================================================
//  lingofuse.zig - Public surface of the LingoFuse Zig binding.
// -----------------------------------------------------------------------------
//  This is the module root that downstream projects import. It
//  re-exports the stable public API of every layer of the binding.
//
//  Layering (from lowest to highest)
//  ---------------------------------
//
//      sys            Raw C ABI. Use only if you need direct access
//                     to a native function that has no wrapper.
//
//      Error          The error set returned by every fallible wrapper.
//
//      DataHandle     RAII wrapper around a native data buffer.
//
//      AppHandle      RAII wrapper around a native application.
//
//      framework      Process-wide facade.
//
//      io             Unified JSON / string / byte I/O. The single
//                     sanctioned path for moving structured data to
//                     and from a DataHandle.
//
//      network_events Process-global connect / disconnect handlers.
//
//      status         Status queue helpers (getStatusCount /
//                     getStatus / drainStatus / postStatus).
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
// =============================================================================

/// Raw C ABI access. Use only if a higher-level wrapper does not
/// already cover the operation you need.
pub const sys = @import("sys.zig");

/// The error set returned by every fallible wrapper in this binding.
pub const Error = @import("error.zig").Error;

/// RAII data handle.
pub const DataHandle = @import("data_handle.zig").DataHandle;

/// RAII application handle.
pub const AppHandle = @import("app_handle.zig").AppHandle;

/// Handler signatures accepted by `AppHandle.registerCall` and
/// `AppHandle.registerNotify`. Re-exported at the top level so that a
/// caller does not need to reach into `app_handle.zig` to name them.
pub const CallHandler = @import("app_handle.zig").CallHandler;
pub const NotifyHandler = @import("app_handle.zig").NotifyHandler;

/// Process-wide facade: loader lifecycle, network preparation, remote
/// invocation, runtime options, health checks, status queue, and
/// shutdown.
pub const framework = @import("framework.zig");

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
/// instead. It is exported for tests and for advanced callers that need
/// to bypass the io layer's framing.
pub const json_c = @import("json_c.zig");

/// Process-global network connect / disconnect event handlers.
pub const network_events = @import("network_events.zig");

/// Status queue helpers: getStatusCount, getStatus, drainStatus, postStatus.
pub const status = @import("status.zig");
