// =============================================================================
//  status.zig - Status queue helpers for the LingoFuse runtime.
// -----------------------------------------------------------------------------
//  The native library maintains a bounded FIFO of log messages, up to
//  1000 entries. Older entries are dropped when the buffer is full.
//
//  Main-thread dependency
//  ----------------------
//  The queue is processed by the native simulated main thread. Before
//  `framework.prepareDone`, the queue may be empty or contain stale
//  data. Applications should not rely on status messages during
//  initialisation.
//
//  Injection is NOT subject to the same restriction: `postStatus`
//  queues the message even when the simulated main thread is not yet
//  running.
//
//  Static-buffer hazard
//  --------------------
//  The native `LF_GetStatus` returns a pointer into a process-wide
//  static buffer that the very next call overwrites. This wrapper
//  copies the string into an allocator-owned slice before returning,
//  so callers never observe a dangling pointer.
//
//  ABI limitation
//  --------------
//  The native ABI cannot distinguish "empty queue" from "empty
//  message": both produce an empty string. Callers that need to
//  distinguish the two must call `getStatusCount` first.
//
//  Ownership
//  ---------
//  Every function that returns an allocated slice transfers ownership
//  to the caller. Free the returned slice with `alloc.free`.
// =============================================================================

const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;

// -----------------------------------------------------------------------------
// Allocator helper
// -----------------------------------------------------------------------------
//
// `std.mem.Allocator.dupeZ` was removed in Zig 0.17. This local helper
// reproduces its semantics using only `alloc.alloc` and `alloc.free`,
// both of which are stable across Zig releases.
//
// The returned slice is sentinel-terminated: `result[result.len] == 0`
// is guaranteed, and `result.ptr` is a valid `[*:0]u8`.
fn dupeZ(alloc: std.mem.Allocator, s: []const u8) Error![:0]u8 {
    const buf = alloc.alloc(u8, s.len + 1) catch return Error.OutOfMemory;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Return the number of pending log messages in the status queue.
///
/// The count is a snapshot: another thread may consume or produce
/// messages between this call and any subsequent `getStatus`.
pub fn getStatusCount() i32 {
    return sys.getStatusCount();
}

/// Retrieve the next log message from the status queue.
///
/// Returns an empty string when the queue is empty. The caller owns
/// the returned slice and must free it with `alloc.free`.
///
/// # Static-buffer hazard
///
/// The native pointer points into a process-wide static buffer that
/// the next call overwrites. This wrapper copies the string
/// immediately, so the returned slice is safe to hold.
///
/// # ABI limitation
///
/// An empty queue and an empty message both produce `""`. Use
/// `getStatusCount` first if the distinction matters.
pub fn getStatus(alloc: std.mem.Allocator) Error![:0]u8 {
    const ptr = sys.getStatus() orelse return dupeZ(alloc, "");
    const slice = std.mem.span(ptr);
    return dupeZ(alloc, slice);
}

/// Drain up to `max_messages` pending status messages in FIFO order.
///
/// Stops early when the native queue returns an empty message,
/// matching the historical behaviour of the other bindings.
///
/// Returns an allocator-owned slice of allocator-owned strings. The
/// caller must free each string with `alloc.free`, then free the
/// outer slice with `alloc.free`.
///
/// A `max_messages` value of 0 returns an empty slice without
/// touching the queue.
pub fn drainStatus(
    alloc: std.mem.Allocator,
    max_messages: usize,
) Error![][:0]u8 {
    if (max_messages == 0) {
        return alloc.alloc([:0]u8, 0) catch Error.OutOfMemory;
    }

    const pending = getStatusCount();
    if (pending <= 0) {
        return alloc.alloc([:0]u8, 0) catch Error.OutOfMemory;
    }

    const capacity: usize = @min(@as(usize, @intCast(pending)), max_messages);

    // Allocate the worst case, fill it, then shrink if fewer messages
    // were actually available. This avoids the `std.ArrayList` API,
    // whose shape changed across Zig releases.
    const messages = alloc.alloc([:0]u8, capacity) catch
        return Error.OutOfMemory;

    var count: usize = 0;
    errdefer {
        for (messages[0..count]) |m| alloc.free(m);
        alloc.free(messages);
    }

    while (count < capacity) {
        const msg = try getStatus(alloc);
        if (msg.len == 0) {
            alloc.free(msg);
            break;
        }
        messages[count] = msg;
        count += 1;
    }

    if (count == capacity) {
        return messages;
    }

    // Shrink to the actual count.
    //
    // Do NOT special-case `count == 0` here. With `count == 0`, the
    // call below allocates a valid zero-length slice and the
    // `@memcpy` is a no-op, so the same code path handles both the
    // empty and the non-empty cases. The earlier version freed
    // `messages` before the allocation and relied on the empty
    // allocation never failing; if it did fail, the `errdefer`
    // above would double-free `messages`.
    const shrunk = alloc.alloc([:0]u8, count) catch
        return Error.OutOfMemory;
    @memcpy(shrunk, messages[0..count]);
    alloc.free(messages);
    return shrunk;
}

/// Inject a custom log message into the status queue.
///
/// The native side queues the message even when the simulated main
/// thread is not yet running. The queue is bounded at 1000 entries;
/// older entries are dropped when the buffer is full.
///
/// # NUL requirement
///
/// The parameter type `[:0]const u8` accepts a NUL-terminated slice.
/// String literals (`"hello"`) and `alloc.dupeZ` results satisfy it
/// directly. The native `LF_PostStatus` uses C string semantics, so
/// any byte after an interior NUL is silently truncated by the native
/// layer; this wrapper does not additionally validate the content.
pub fn postStatus(message: [:0]const u8) void {
    sys.postStatus(message.ptr);
}
