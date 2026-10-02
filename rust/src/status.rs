//! Status queue and health-check helpers for the LingoFuse runtime.
//!
//! This module exposes the diagnostic surface of the native library:
//!
//! - The bounded status queue (`get_status_count`, `get_status`,
//!   `drain_status`, `post_status`).
//!
//! The health-check functions (`check_main_thread`, `check_app`,
//! `check_api`) live in [`crate::framework`] because they describe the
//! readiness of the framework rather than its diagnostics.
//!
//! # Status queue
//!
//! The native library maintains a bounded FIFO of log messages, up to
//! **1000 entries**. Older entries are dropped when the buffer is full.
//!
//! # Main-thread dependency
//!
//! The queue is processed by the native simulated main thread. Before
//! [`crate::framework::prepare_done`], the queue may be empty or contain
//! stale data. Applications should not rely on status messages during
//! initialisation.
//!
//! Injection is **not** subject to the same restriction: `post_status`
//! queues the message even when the simulated main thread is not yet
//! running. The message becomes observable once the main thread starts
//! processing the queue.
//!
//! # Static-buffer hazard
//!
//! The native `LF_GetStatus` returns a pointer into a process-wide
//! static buffer that is overwritten by the very next call. This
//! wrapper copies the string into an owned `String` before returning,
//! so callers never observe a dangling pointer.
//!
//! # ABI limitation
//!
//! The native ABI cannot distinguish "empty queue" from "empty message":
//! both produce an empty string. Callers that need to distinguish the
//! two must call [`get_status_count`] first.
//!
//! # Testing
//!
//! The test that posts a message is marked `#[ignore]` because it
//! mutates process-global native state (the queue), which would race
//! with any other test that also touches the native framework. Run it
//! in isolation with:
//!
//! ```text
//! cargo test --lib -- --ignored --test-threads=1
//! ```
//!
//! # Example
//!
//! ```no_run
//! use lingofuse::status;
//!
//! # fn main() -> Result<(), lingofuse::error::Error> {
//! status::post_status("starting up")?;
//! for msg in status::drain_status(64)? {
//!     println!("[LF] {}", msg);
//! }
//! # Ok(()) }
//! ```

use std::ffi::{c_char, CStr, CString};

use crate::error::Error;
use crate::sys;

// ============================================================================
// Internal helpers
// ============================================================================

/// Resolves the native library, mapping a load failure into the crate's
/// error type.
fn lib() -> Result<&'static sys::NativeLibrary, Error> {
    sys::get_library().map_err(Error::from_load)
}

/// Copies a NUL-terminated UTF-8 string returned by the native layer
/// into an owned `String`.
///
/// # Safety
///
/// `ptr` must be either null or a pointer to a NUL-terminated UTF-8
/// string that remains valid for the duration of the call.
unsafe fn copy_cstr(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    // SAFETY: forwarded from the caller. The native library documents
    // every string it returns as UTF-8, NUL-terminated.
    let cs = unsafe { CStr::from_ptr(ptr) };
    cs.to_string_lossy().into_owned()
}

// ============================================================================
// Status queue
// ============================================================================

/// Returns the number of pending log messages in the status queue.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
pub fn get_status_count() -> Result<i32, Error> {
    let lib = lib()?;
    // SAFETY: zero-argument function.
    Ok(unsafe { (lib.lf_get_status_count)() })
}

/// Retrieves the next log message from the status queue.
///
/// Returns an empty string when the queue is empty.
///
/// # Static-buffer hazard
///
/// The native pointer is into a process-wide static buffer that the
/// next call to this function overwrites. This wrapper copies the
/// string immediately, so the returned `String` is safe to hold.
///
/// # ABI limitation
///
/// An empty queue and an empty message both produce `""`. Use
/// [`get_status_count`] first to disambiguate.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
pub fn get_status() -> Result<String, Error> {
    let lib = lib()?;
    // SAFETY: zero-argument function returning a NUL-terminated UTF-8
    // string in a static buffer. We copy it immediately.
    let ptr = unsafe { (lib.lf_get_status)() };
    Ok(unsafe { copy_cstr(ptr) })
}

/// Drains up to `max_messages` pending status messages in FIFO order.
///
/// Stops early when the native queue returns an empty message, matching
/// the historical behaviour of the C# binding. An empty string can
/// only be observed through the queue in a corner case (a user
/// explicitly posting an empty message, or a race with another
/// producer), so this early-exit rule keeps the common path efficient.
///
/// # Parameters
///
/// - `max_messages`: upper bound on the number of messages to retrieve.
///   A value of `0` returns an empty vector without touching the queue.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
pub fn drain_status(max_messages: usize) -> Result<Vec<String>, Error> {
    if max_messages == 0 {
        return Ok(Vec::new());
    }

    let pending = get_status_count()?;
    if pending <= 0 {
        return Ok(Vec::new());
    }

    let count = std::cmp::min(pending as usize, max_messages);
    let mut messages = Vec::with_capacity(count);

    for _ in 0..count {
        let msg = get_status()?;
        if msg.is_empty() {
            break;
        }
        messages.push(msg);
    }

    Ok(messages)
}

/// Injects a custom log message into the status queue.
///
/// The native side queues the message even when the simulated main
/// thread is not yet running. The queue is bounded at 1000 entries;
/// older entries are dropped when the buffer is full.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
/// - [`crate::error::ErrorCode::InvalidArgument`] if `message`
///   contains an interior NUL.
pub fn post_status(message: &str) -> Result<(), Error> {
    let lib = lib()?;
    let c_msg = CString::new(message).map_err(|_| {
        Error::invalid_argument(
            "status::post_status",
            "message contains an interior NUL",
        )
    })?;
    // SAFETY: valid UTF-8, NUL-terminated string.
    unsafe { (lib.lf_post_status)(c_msg.as_ptr()) };
    Ok(())
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn have_native() -> bool {
        match lib() {
            Ok(_) => true,
            Err(e) => {
                eprintln!("[SKIP] native library not available: {}", e);
                false
            }
        }
    }

    #[test]
    fn get_status_count_succeeds() {
        if !have_native() {
            return;
        }
        // Read-only: safe to run concurrently with other tests.
        let n = get_status_count().unwrap();
        assert!(n >= 0, "status count must be non-negative, got {}", n);
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn post_status_accepts_a_message() {
        if !have_native() {
            return;
        }
        post_status("rust status test: hello").unwrap();
    }

    #[test]
    fn post_status_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        // The interior-NUL check happens before any native call, so
        // this test never touches the native queue and is safe to run
        // in parallel.
        let err = post_status("bad\0message").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn get_status_succeeds() {
        if !have_native() {
            return;
        }
        // Read-only: consumes one message from the queue but does not
        // add anything. Safe under the test harness's concurrency
        // because no other test in this file produces messages.
        let _ = get_status().unwrap();
    }

    #[test]
    fn drain_status_with_zero_is_a_noop() {
        if !have_native() {
            return;
        }
        // Does not touch the native queue: the function short-circuits
        // on `max_messages == 0`.
        let v = drain_status(0).unwrap();
        assert!(v.is_empty());
    }

    #[test]
    fn drain_status_succeeds() {
        if !have_native() {
            return;
        }
        // Read-only drain of a bounded batch.
        let _ = drain_status(16).unwrap();
    }
}