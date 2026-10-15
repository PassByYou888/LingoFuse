// =============================================================================
//  async_call.zig - Modern asynchronous invocation with Zig-idiomatic API.
// -----------------------------------------------------------------------------
//  This module is the Zig counterpart of the C ABI's `LF_Async_*`
//  family, and the analogue of the C++ `lingofuse::callAsync` and Rust
//  `async_call::call_async` families. It hides the raw function-pointer
//  + `void*` plumbing behind a Zig-idiomatic closure API so that
//  asynchronous code does not feel different from the rest of the
//  crate.
//
//  Entry points
//  ------------
//  Every addressing scheme (App name, UID, P2PName) has two styles:
//
//      Style       App name           UID                      P2PName
//      ----------- ------------------ ------------------------ ------------------------
//      Callback    callAsync          callAsyncByUid           callAsyncByP2PName
//      Blocking    callAsyncWait      callAsyncWaitByUid       callAsyncWaitByP2PName
//
//  Plus `callAsyncSequenced` for the FIFO-ordered asynchronous variant
//  of the App-name family.
//
//  Callback style
//  --------------
//  `callAsync` and its siblings return immediately. The user-supplied
//  handler runs on a native `TCompute` worker thread when the response
//  arrives, or synchronously on the caller's thread if the native
//  layer rejects the request before dispatching it (see "Single error
//  path" below).
//
//  Because Zig has no closures, the handler is written as a named or
//  anonymous struct's function, and the caller passes a user-context
//  pointer that is handed back to the handler unchanged. See the
//  `AsyncResultHandler` docstring for the canonical form.
//
//  Blocking style
//  --------------
//  `callAsyncWait` returns only after the callback has fired (or the
//  timeout expires). It returns a plain byte slice, not a `DataHandle`.
//
//  Why `callAsyncWait` returns `[]u8`, not `DataHandle`
//  ----------------------------------------------------
//  The asynchronous family hands the caller a FRAMEWORK-OWNED result
//  handle that is released the instant the callback returns. Any
//  `DataHandle` borrowed from that handle would be dangling the moment
//  the callback body ends. To hand the response to the waiting thread
//  safely, `callAsyncWait` must COPY THE BYTES out inside the callback
//  and deliver the copy.
//
//  A new `DataHandle` cannot be constructed on the waiting side,
//  because the crate has no way to know the API name that the framework
//  originally bound to the result. The only two lossless options are
//  therefore "return raw bytes" (what this module does) or "return a
//  typed value" (which would require the caller to supply a
//  deserialisation target). The former keeps the API surface minimal;
//  callers that want a typed value can decode the bytes with
//  `io.loadsJson` or any other tool.
//
//  Single error path
//  -----------------
//  There are TWO ways an asynchronous call can fail:
//
//      1. The native layer rejects the request before dispatching it
//         (`LF_Async_Call` returns 0). This is the "dispatch failure"
//         case.
//      2. The native layer accepts the request (returns 1), but there
//         is no matching App / API to route it to, so it delivers an
//         EMPTY result handle to the callback. This is the "not found"
//         case.
//
//  Both cases are surfaced as `Error.CallFailed` by the blocking entry
//  points, and both are visible to a callback handler as:
//
//      - Dispatch failure  -> synchronously invoked handler with
//                             `.{ .err = Error.CallFailed }`.
//      - Not found         -> asynchronously invoked handler with
//                             `.{ .ok = <empty handle> }`.
//
//  A callback handler that wants a unified success/failure check
//  should inspect the handle size inside the `.ok` branch (a zero-byte
//  response means "not found"). The blocking entry points perform that
//  check automatically and return `Error.CallFailed`.
//
//  Why `readAllBytes`, not `readString`
//  ------------------------------------
//  The result handle carries the raw response BYTES; it does NOT add a
//  framing NUL. A response whose first byte happens to be 0x00 (any
//  integer whose little-endian form starts with a zero byte, any
//  empty-prefixed payload, etc.) would be truncated at that byte if
//  the reader stopped at the first NUL. `readAllBytes` returns every
//  byte that the framework produced. Callers that know the response is
//  text can still treat the returned slice as a string.
//
//  Platform timing
//  ---------------
//  Zig 0.17 removed `std.Thread.sleep` and the entire `std.time` API
//  surface except `epoch`. This module uses the Windows API directly
//  for both sleeping and monotonic time, matching the existing
//  `cross_call.zig` demo. Porting to POSIX requires replacing the two
//  extern declarations below with their POSIX equivalents; nothing
//  else in this module depends on the platform.
//
//  Array-fill style
//  ----------------
//  This module uses no `**` operator anywhere.
// =============================================================================

const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const DataHandle = @import("data_handle.zig").DataHandle;
const Uid = @import("uid.zig").Uid;

// -----------------------------------------------------------------------------
// Platform timing / sleeping
// -----------------------------------------------------------------------------
//
// Both symbols are provided by `kernel32` on Windows and are linked by
// default. The project currently targets Windows x64; see the module
// docstring for the porting note.

extern "c" fn Sleep(dwMilliseconds: u32) void;
extern "c" fn GetTickCount64() u64;

/// Suspend the calling thread for `ms` milliseconds.
inline fn sleepMillis(ms: u32) void {
    Sleep(ms);
}

/// Monotonic clock, in milliseconds since system boot.
///
/// Unlike `clock()` from the C standard library, `GetTickCount64` is
/// guaranteed monotonic and wall-clock-based, which is what the
/// timeout loop needs.
inline fn nowMillis() u64 {
    return GetTickCount64();
}

// =============================================================================
// AsyncResult
// =============================================================================

/// The outcome of an asynchronous call, delivered to the user handler.
///
/// A tagged union with two variants:
///
///     .ok  : DataHandle    a borrowed handle; valid only inside the handler
///     .err : Error         a transport-level failure or dispatch rejection
///
/// # Ownership of the `.ok` handle
///
/// The handle is BORROWED from the framework. It is valid only inside
/// the handler body; the framework releases the underlying buffer the
/// instant the handler returns. Copy whatever data you need before
/// returning.
///
/// # Not-found case
///
/// The native layer may accept a request (dispatch succeeded) but have
/// no matching App / API to route it to. In that case the handler is
/// invoked asynchronously with `.{ .ok = <empty handle> }`. A handler
/// that wants to distinguish "not found" from "empty response" should
/// check `handle.size() == 0`.
///
/// # Dispatch-failure case
///
/// When the native layer rejects the request before dispatching it, the
/// handler is invoked SYNCHRONOUSLY on the caller's thread with
/// `.{ .err = Error.CallFailed }`. The entry point itself also returns
/// `Error.CallFailed`.
pub const AsyncResult = union(enum) {
    ok: DataHandle,
    err: Error,
};

/// User handler for asynchronous results.
///
/// # Contract
///
/// - Must not block.
/// - Must not call any blocking LingoFuse function.
/// - Must return promptly.
/// - Must not call `deinit` on the borrowed `.ok` handle.
/// - Must not retain the borrowed `.ok` handle past its own return.
///
/// # Canonical form
///
/// Zig has no closures, so the handler is written as a named or
/// anonymous struct's function and the caller passes a `ctx` pointer
/// that carries any captured state. This mirrors
/// `std.Thread.spawn(.{}, fn, args)`:
///
///     const Biz = struct {
///         fn handle(ctx: ?*anyopaque, r: async_call.AsyncResult) void {
///             const s: *SharedState = @ptrCast(@alignCast(ctx orelse return));
///             switch (r) {
///                 .ok => |h| { ... s.sum = ...; s.done.store(true, .release); },
///                 .err => |e| { std.debug.print("{}\n", .{e}); s.done.store(true, .release); },
///             }
///         }
///     };
///
///     try async_call.callAsync("Calculator", &req, &state, Biz.handle);
pub const AsyncResultHandler = *const fn (
    ctx: ?*anyopaque,
    result: AsyncResult,
) void;

// =============================================================================
// Internal context
// =============================================================================

/// Heap-allocated context carried across the FFI boundary as `void*`.
///
/// Ownership is unambiguous:
///
/// - On a successful dispatch, the framework owns the context and the
///   trampoline destroys it after the user handler returns.
/// - On a dispatch failure, the entry point destroys it right after
///   invoking the handler synchronously.
///
/// Unlike `app_handle.zig` / `p2p.zig`, the async context is NEVER
/// leaked. The lifecycle is bounded by the callback invocation.
const AsyncContext = struct {
    handler: AsyncResultHandler,
    user_ctx: ?*anyopaque,
};

fn allocContext(
    handler: AsyncResultHandler,
    user_ctx: ?*anyopaque,
) Error!*AsyncContext {
    const alloc = std.heap.page_allocator;
    const c = alloc.create(AsyncContext) catch return Error.OutOfMemory;
    c.* = .{ .handler = handler, .user_ctx = user_ctx };
    return c;
}

fn freeContext(c: *AsyncContext) void {
    std.heap.page_allocator.destroy(c);
}

// =============================================================================
// Trampoline
// =============================================================================

/// The single `extern "C"` function the native layer invokes for every
/// asynchronous result.
///
/// # Safety
///
/// - `data` must be a pointer produced by `allocContext`, or null.
/// - `result` must be a valid `DataHnd` for the duration of the
///   callback, as documented by the native library.
///
/// The wrapper guarantees both preconditions: `allocContext` is the
/// only producer of `data`, and the native layer is the only producer
/// of `result`.
///
/// The trampoline destroys the context after invoking the user
/// handler, so on the success path the framework never needs to call
/// back into Zig for cleanup.
fn asyncTrampoline(
    data: ?*anyopaque,
    result: sys.DataHnd,
) callconv(.c) void {
    const raw = data orelse return;
    const c: *AsyncContext = @ptrCast(@alignCast(raw));

    // Wrap the framework-owned result handle as a BORROWED DataHandle.
    // `owned = false` ensures that DataHandle.deinit is a no-op, which
    // is required because the framework owns the buffer.
    const h = DataHandle.fromRaw(result, false);

    c.handler(c.user_ctx, .{ .ok = h });

    freeContext(c);
}

// =============================================================================
// Callback style
// =============================================================================

/// Issue an asynchronous Call by App name.
///
/// The request is dispatched immediately. When the response arrives,
/// `handler` runs on a native worker thread with a borrowed
/// `DataHandle`.
///
/// # Dispatch failure
///
/// If the native layer rejects the request, the handler runs
/// SYNCHRONOUSLY ON THE CALLER'S THREAD with
/// `.{ .err = Error.CallFailed }`, and this function returns
/// `Error.CallFailed` as well. See the module documentation for the
/// rationale.
///
/// # Ownership
///
/// The framework copies `param`'s payload synchronously inside the
/// call, so the `DataHandle` may be dropped the moment this function
/// returns.
///
/// # Errors
///
/// - `Error.NullHandle` if `param` is not valid.
/// - `Error.OutOfMemory` if the context allocation fails.
/// - `Error.CallFailed` if the native layer rejected the request.
pub fn callAsync(
    app_name: [:0]const u8,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.asyncCall(
        app_name.ptr,
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

/// Issue an asynchronous sequenced Call by App name.
///
/// Same contract as `callAsync`. FIFO ordering is guaranteed per
/// `(app, api)` pair by the native layer.
pub fn callAsyncSequenced(
    app_name: [:0]const u8,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.asyncSequencedCall(
        app_name.ptr,
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

/// Issue an asynchronous Call addressed by session UID.
///
/// Same callback and ownership contract as `callAsync`.
pub fn callAsyncByUid(
    uid: Uid,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.uidAsyncCall(
        uid.toLf(),
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

/// Issue an asynchronous Call addressed by P2P group name.
///
/// Same callback and ownership contract as `callAsync`. Note that
/// P2PName routing is NOT local-first: the server always owns the
/// load-balancing decision.
pub fn callAsyncByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.p2pnameAsyncCall(
        p2p_name.ptr,
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

// =============================================================================
// Blocking style
// =============================================================================
//
// The blocking entry points are built on top of the callback style.
// A small `Waiter` object is shared between the calling thread and the
// callback trampoline; the callback fills it in and sets a flag, the
// caller polls the flag and copies the result out.
//
// The Waiter is deliberately a pair of optional fields plus a single
// atomic bool, rather than a tagged union, so that the memory-ordering
// rules are trivial to reason about: the `done` flag is the only
// synchronising primitive, and the `.release` / `.acquire` pair
// ensures the payload and err fields are visible the moment `done`
// reads as true.

const Waiter = struct {
    /// Set to `true` by the callback when the result is ready.
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// The response bytes, copied out of the framework-owned handle.
    /// Owned by the waiting thread once `done` is true.
    payload: ?[]u8 = null,

    /// The transport error, or null on success.
    err: ?Error = null,
};

/// The internal handler used by the blocking entry points.
///
/// It copies the response bytes out of the borrowed handle with
/// `readAllBytes`. The result handle carries the raw response BYTES
/// and does NOT add a framing NUL; using `io.readString` here would
/// truncate any response whose first byte happened to be 0x00 (any
/// integer whose little-endian form starts with a zero byte, any
/// empty-prefixed payload, etc.).
///
/// # Empty response is a failure
///
/// The native layer may accept a request (return 1 from
/// `LF_Async_Call`) but have no matching App / API to route it to, in
/// which case it delivers an empty result handle to the callback. An
/// empty response is therefore surfaced as `Error.CallFailed`, matching
/// the C++ / Rust bindings' `tryCall` semantics. This makes the
/// blocking entry points' single error path cover both the dispatch
/// failure and the not-found case.
fn waitHandler(ctx: ?*anyopaque, result: AsyncResult) void {
    const raw = ctx orelse return;
    const w: *Waiter = @ptrCast(@alignCast(raw));

    switch (result) {
        .ok => |h| {
            var hh = h;
            const bytes = hh.readAllBytes(std.heap.page_allocator) catch {
                w.err = Error.ReadFailed;
                w.done.store(true, .release);
                return;
            };

            // Empty response -> App / API not found, or the producer
            // returned a zero-length payload. Either way it is a
            // failure for the blocking caller.
            if (bytes.len == 0) {
                std.heap.page_allocator.free(bytes);
                w.err = Error.CallFailed;
                w.done.store(true, .release);
                return;
            }

            w.payload = bytes;
            w.done.store(true, .release);
        },
        .err => |e| {
            w.err = e;
            w.done.store(true, .release);
        },
    }
}

/// Poll the waiter until it is done or the timeout expires.
///
/// On success, the caller owns the returned slice and must free it with
/// `std.heap.page_allocator.free`.
///
/// # Timeout semantics
///
/// A timeout of `null` waits indefinitely. Otherwise the polling loop
/// checks the wall-clock elapsed time after every 1 ms sleep and
/// returns `Error.Timeout` when the deadline is exceeded. The native
/// request is NOT cancelled; if the callback fires later it will find
/// a stale waiter, but it does nothing with it.
fn waitForResult(w: *Waiter, timeout_ms: ?u64) Error![]u8 {
    const start_ms: u64 = nowMillis();

    while (!w.done.load(.acquire)) {
        if (timeout_ms) |t| {
            const elapsed: u64 = nowMillis() - start_ms;
            if (elapsed >= t) return Error.Timeout;
        }
        // Sleep 1 ms between polls. The native callback path is
        // latency-bound (typically sub-millisecond once the response
        // is in memory), so 1 ms is a reasonable trade-off between
        // CPU burn and wake-up latency.
        sleepMillis(1);
    }

    if (w.err) |e| return e;
    return w.payload orelse Error.ReadFailed;
}

/// Issue an asynchronous Call by App name and block until the response
/// arrives, the optional timeout expires, or the dispatch fails.
///
/// # Return value
///
/// The response payload as a fresh `[]u8`, copied out of the
/// framework-owned result handle inside the callback. The slice is
/// the raw response BYTES; the framework does not append a framing
/// NUL. See the module documentation for why the return type is bytes
/// rather than a `DataHandle`.
///
/// # Ownership
///
/// The caller owns the returned slice and must free it with
/// `std.heap.page_allocator.free`.
///
/// # Timeout semantics
///
/// The timeout is implemented ON THE ZIG SIDE. When it expires, this
/// function returns `Error.Timeout` and abandons the callback. The
/// native request is NOT cancelled. Passing `null` waits indefinitely.
///
/// # Blocking warning
///
/// Do NOT call this function from inside a registered callback. The
/// callback runs on a native worker thread that the synchronous
/// dispatch path may need, and blocking it can deadlock. This is the
/// same restriction as for `framework.call`.
///
/// # Errors
///
/// - `Error.NullHandle` if `param` is not valid.
/// - `Error.OutOfMemory` if the context or the response copy fails.
/// - `Error.CallFailed` if the native layer rejected the request, or
///   if the request was accepted but no matching App / API was found
///   (empty response).
/// - `Error.ReadFailed` if the response could not be decoded.
/// - `Error.Timeout` if the timeout expired.
pub fn callAsyncWait(
    app_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    var w = Waiter{};
    try callAsync(app_name, param, &w, waitHandler);
    return waitForResult(&w, timeout_ms);
}

/// Issue an asynchronous Call addressed by session UID and block until
/// the response arrives, the optional timeout expires, or the dispatch
/// fails.
///
/// Same contract as `callAsyncWait`.
pub fn callAsyncWaitByUid(
    uid: Uid,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    var w = Waiter{};
    try callAsyncByUid(uid, param, &w, waitHandler);
    return waitForResult(&w, timeout_ms);
}

/// Issue an asynchronous Call addressed by P2P group name and block
/// until the response arrives, the optional timeout expires, or the
/// dispatch fails.
///
/// Same contract as `callAsyncWait`.
pub fn callAsyncWaitByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    var w = Waiter{};
    try callAsyncByP2PName(p2p_name, param, &w, waitHandler);
    return waitForResult(&w, timeout_ms);
}

// =============================================================================
// Tests
// =============================================================================
//
// This module's public API requires the native runtime. The unit tests
// below only cover the pure-data parts: the tagged union's shape and
// the waiter's polling logic. Integration coverage lives in
// `examples/async_smoke.zig`.

const testing = std.testing;

test "AsyncResult.ok carries a DataHandle value" {
    const h = DataHandle.fromRaw(null, false);
    const r: AsyncResult = .{ .ok = h };

    const hh = switch (r) {
        .ok => |x| x,
        .err => unreachable,
    };
    try testing.expect(!hh.isValid());
}

test "AsyncResult.err carries an Error value" {
    const r: AsyncResult = .{ .err = Error.CallFailed };

    const e = switch (r) {
        .ok => unreachable,
        .err => |x| x,
    };
    try testing.expectEqual(Error.CallFailed, e);
}

test "Waiter initial state is pending" {
    const w = Waiter{};
    try testing.expect(!w.done.load(.acquire));
    try testing.expect(w.payload == null);
    try testing.expect(w.err == null);
}

test "waitForResult returns the payload once the waiter is done" {
    var w = Waiter{};

    const alloc = testing.allocator;
    const payload = try alloc.alloc(u8, 3);
    @memcpy(payload, "abc");
    w.payload = payload;
    w.done.store(true, .release);

    const got = try waitForResult(&w, null);
    defer alloc.free(got);

    try testing.expectEqualStrings("abc", got);
}

test "waitForResult returns the error once the waiter is done" {
    var w = Waiter{};
    w.err = Error.CallFailed;
    w.done.store(true, .release);

    const e = waitForResult(&w, null);
    try testing.expectError(Error.CallFailed, e);
}

test "waitForResult times out on a pending waiter" {
    var w = Waiter{};

    const e = waitForResult(&w, 0);
    try testing.expectError(Error.Timeout, e);
}
