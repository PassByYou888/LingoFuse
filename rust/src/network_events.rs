//! Process-global network connect / disconnect event handlers.
//!
//! This module wraps `LF_Set_Network_Event`, which installs a pair of
//! process-wide callbacks that fire when a LingoFuse client becomes
//! online or goes offline. It mirrors the role of `NetworkEvents.cs`
//! (C#), `network_events.py` (Python), and the `NetworkEventListener`
//! class in the C++/JavaScript bindings.
//!
//! # Semantics
//!
//! | Event | Trigger |
//! |-------|---------|
//! | **Connect** | The first time a client receives a service API-info broadcast. **Not** the TCP handshake; it is the earliest point at which remote calls can be routed. Fires once per connection lifecycle, and again after an auto-reconnect. |
//! | **Disconnect** | Once per physical link loss. An automatic reconnect does **not** emit a Disconnect for the reconnect attempt itself; it emits a new Connect once the client is back online. |
//!
//! # Threading contract
//!
//! Callbacks run on a **background worker thread** owned by the native
//! library. They must:
//!
//! - Copy the endpoint string immediately. This wrapper does that for
//!   you: the handler receives an owned `&str` derived from a copy.
//! - Never touch UI controls directly.
//! - Never call any blocking LingoFuse function (`LF_Call`,
//!   `LF_LocalCall`, `LF_PrepareDone`, `LF_Shutdown`). This would
//!   deadlock.
//! - Never panic. The trampoline wraps every call in
//!   [`std::panic::catch_unwind`], so a panic is caught rather than
//!   crossing the FFI boundary, but the callback is still aborted at
//!   that point.
//!
//! # Replace semantics
//!
//! [`set_network_event`] is a **replace** operation, not a patch.
//! Calling it again discards any previously installed handlers,
//! including those whose corresponding argument is `None` in the new
//! call.
//!
//! # Global scope
//!
//! `LF_Set_Network_Event` is a process-wide slot. There is no
//! per-client registration. Installing new handlers replaces the
//! previous ones entirely.
//!
//! # Testing
//!
//! Every test in this module is marked `#[ignore]` because installing
//! a handler mutates process-global native state, which would race with
//! any other test that also touches the native framework. Run them in
//! isolation with:
//!
//! ```text
//! cargo test --lib -- --ignored --test-threads=1
//! ```
//!
//! # Example
//!
//! ```no_run
//! use lingofuse::network_events::{clear_network_event, set_network_event};
//!
//! # fn main() -> Result<(), lingofuse::error::Error> {
//! set_network_event(
//!     Some(Box::new(|addr| eprintln!("[+] connected: {}", addr))),
//!     Some(Box::new(|addr| eprintln!("[-] disconnected: {}", addr))),
//! )?;
//!
//! // ... run the framework ...
//!
//! clear_network_event()?;
//! # Ok(()) }
//! ```

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use crate::error::Error;
use crate::sys::{self, LfNetworkEventFunc};

// ============================================================================
// Handler storage
// ============================================================================

/// The user-supplied handler type.
///
/// A boxed closure that receives the endpoint string. The `Send + Sync`
/// bound is required because the closure runs on a native worker
/// thread. The `'static` bound is required because the closure is
/// stored in a process-wide slot that outlives any local scope.
pub type NetworkHandler = Box<dyn Fn(&str) + Send + Sync + 'static>;

/// Internal shared representation. `Arc` rather than `Box` so that the
/// trampoline can clone a reference out from under the lock, release
/// the lock, and then invoke the handler. This avoids holding the lock
/// across arbitrary user code.
type SharedHandler = Arc<dyn Fn(&str) + Send + Sync + 'static>;

struct Handlers {
    on_connect: Option<SharedHandler>,
    on_disconnect: Option<SharedHandler>,
}

/// Process-wide handler storage.
///
/// Uses `OnceLock<Mutex<...>>` rather than a bare `Mutex<...>` so that
/// the initialisation itself is guaranteed to be safe even under
/// concurrent first access.
static HANDLERS: OnceLock<Mutex<Handlers>> = OnceLock::new();

fn handlers() -> &'static Mutex<Handlers> {
    HANDLERS.get_or_init(|| {
        Mutex::new(Handlers {
            on_connect: None,
            on_disconnect: None,
        })
    })
}

/// Locks the handler storage, recovering from a poisoned mutex by
/// extracting the inner value. A poisoned mutex means a previous
/// `set_network_event` panicked while holding the lock; the handlers
/// it stored are still valid, and refusing to read them would be more
/// disruptive than proceeding.
fn lock_handlers() -> std::sync::MutexGuard<'static, Handlers> {
    match handlers().lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

// ============================================================================
// Trampolines
// ============================================================================

/// Shared implementation of the two trampolines.
fn dispatch(
    selector: fn(&Handlers) -> Option<SharedHandler>,
    addr: *const c_char,
) {
    if addr.is_null() {
        return;
    }

    // SAFETY: the native library documents the address as a
    // NUL-terminated UTF-8 string valid for the duration of the
    // callback. We copy it into an owned `String` before doing anything
    // else, so no reference to the native buffer survives this function.
    let endpoint: String = unsafe { CStr::from_ptr(addr) }
        .to_string_lossy()
        .into_owned();

    // Clone the `Arc` out from under the lock, then release the lock
    // before invoking the handler. This is important: it means a
    // handler that calls back into `set_network_event` cannot deadlock.
    let handler = {
        let g = lock_handlers();
        selector(&g)
    };

    if let Some(h) = handler {
        // Catch every panic so it cannot cross the FFI boundary.
        let _ = catch_unwind(AssertUnwindSafe(|| h(&endpoint)));
    }
}

/// The `extern "C"` function the native layer invokes for a connect
/// event.
///
/// # Safety
///
/// `addr` must be either null or a pointer to a NUL-terminated UTF-8
/// string valid for the duration of the call, as documented by the
/// native library.
unsafe extern "C" fn connect_trampoline(addr: *const c_char) {
    dispatch(|h| h.on_connect.clone(), addr);
}

/// The `extern "C"` function the native layer invokes for a disconnect
/// event.
///
/// # Safety
///
/// Same contract as [`connect_trampoline`].
unsafe extern "C" fn disconnect_trampoline(addr: *const c_char) {
    dispatch(|h| h.on_disconnect.clone(), addr);
}

// ============================================================================
// Public API
// ============================================================================

/// Installs the process-global connect and disconnect handlers.
///
/// Passing `None` for either argument disables that event.
///
/// # Replace semantics
///
/// This is a **replace** operation. Calling it a second time discards
/// any previously installed handlers, even those whose corresponding
/// argument is `None` in the new call. To install both handlers, pass
/// both arguments in a single call.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
///
/// # Example
///
/// ```no_run
/// # use lingofuse::network_events::set_network_event;
/// # fn f() -> Result<(), lingofuse::error::Error> {
/// set_network_event(
///     Some(Box::new(|addr| println!("connected: {addr}"))),
///     None,
/// )?;
/// # Ok(()) }
/// ```
pub fn set_network_event(
    on_connect: Option<NetworkHandler>,
    on_disconnect: Option<NetworkHandler>,
) -> Result<(), Error> {
    let lib = sys::get_library().map_err(Error::from_load)?;

    // Install into the process-wide slot first, then publish to the
    // native layer. The two steps must be ordered this way: if the
    // native call were made first, a callback could fire and observe
    // the previous handler set for a brief window.
    let connect_arc = on_connect.map(Arc::from);
    let disconnect_arc = on_disconnect.map(Arc::from);

    let (has_connect, has_disconnect) = {
        let mut g = lock_handlers();
        g.on_connect = connect_arc;
        g.on_disconnect = disconnect_arc;
        (g.on_connect.is_some(), g.on_disconnect.is_some())
    };

    let c_ptr: Option<LfNetworkEventFunc> = if has_connect {
        Some(connect_trampoline)
    } else {
        None
    };
    let d_ptr: Option<LfNetworkEventFunc> = if has_disconnect {
        Some(disconnect_trampoline)
    } else {
        None
    };

    // SAFETY: the two pointers are either null (disabling the event) or
    // valid `LfNetworkEventFunc` items with the exact expected
    // signature. The native layer stores them; we keep the trampolines
    // alive by virtue of being `fn` items (which have `'static`
    // lifetime).
    unsafe { (lib.lf_set_network_event)(c_ptr, d_ptr) };
    Ok(())
}

/// Removes both handlers.
///
/// Equivalent to `set_network_event(None, None)`.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
pub fn clear_network_event() -> Result<(), Error> {
    set_network_event(None, None)
}

/// Returns `true` when at least one handler is currently installed.
pub fn is_network_event_installed() -> bool {
    let g = lock_handlers();
    g.on_connect.is_some() || g.on_disconnect.is_some()
}

// ============================================================================
// Tests
// ============================================================================
//
// Every test is marked `#[ignore]` because installing a handler mutates
// process-global native state, which would race with any other test
// that also touches the native framework. Run them with:
//
//     cargo test --lib -- --ignored --test-threads=1

#[cfg(test)]
mod tests {
    use super::*;

    fn have_native() -> bool {
        match sys::get_library() {
            Ok(_) => true,
            Err(e) => {
                eprintln!("[SKIP] native library not available: {}", e);
                false
            }
        }
    }

    fn reset() {
        let _ = clear_network_event();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn install_and_clear_roundtrip() {
        if !have_native() {
            return;
        }
        reset();

        set_network_event(
            Some(Box::new(|_addr| {})),
            Some(Box::new(|_addr| {})),
        )
        .unwrap();
        assert!(is_network_event_installed());

        clear_network_event().unwrap();
        assert!(!is_network_event_installed());

        reset();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn only_connect_installed() {
        if !have_native() {
            return;
        }
        reset();

        set_network_event(Some(Box::new(|_addr| {})), None).unwrap();
        assert!(is_network_event_installed());

        reset();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn only_disconnect_installed() {
        if !have_native() {
            return;
        }
        reset();

        set_network_event(None, Some(Box::new(|_addr| {}))).unwrap();
        assert!(is_network_event_installed());

        reset();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn set_none_none_clears_previous() {
        if !have_native() {
            return;
        }
        reset();

        set_network_event(Some(Box::new(|_addr| {})), None).unwrap();
        assert!(is_network_event_installed());

        // Replace with an all-None call. The replace semantics mean the
        // previous handler is discarded.
        set_network_event(None, None).unwrap();
        assert!(!is_network_event_installed());

        reset();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn replacing_handler_keeps_installed() {
        if !have_native() {
            return;
        }
        reset();

        set_network_event(Some(Box::new(|_addr| {})), None).unwrap();
        set_network_event(Some(Box::new(|_addr| {})), None).unwrap();
        assert!(is_network_event_installed());

        reset();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn clear_is_idempotent() {
        if !have_native() {
            return;
        }
        reset();
        clear_network_event().unwrap();
        clear_network_event().unwrap();
        assert!(!is_network_event_installed());
    }
}