//! Process-wide P2P API registration.
//!
//! This module is the Rust counterpart of the `LF_Register_P2P_*` /
//! `LF_Unregister_P2P` family in `LingoFuse.h`. It lets a process
//! publish Call / Notify handlers on a namespace that is **independent
//! of any App**.
//!
//! # What "process-wide P2P" means
//!
//! An API registered through [`register_p2p_call`] or
//! [`register_p2p_notify`] lives on the process-wide
//! `LF_P2P_APP` and is reachable through **UID addressing** and
//! **P2PName addressing only**. It is **not** reachable by App-name
//! addressing, even if the API name happens to match a registered App
//! name.
//!
//! The intended use is for utility APIs that any client in the mesh
//! should be able to call without knowing the target's App name:
//! health probes, capability discovery, identity echo, and similar
//! "who am I talking to?" helpers.
//!
//! # Comparison with `AppHandle::register_call`
//!
//! | Aspect           | `AppHandle::register_call`   | `register_p2p_call`        |
//! |------------------|------------------------------|----------------------------|
//! | Namespace        | The App's own namespace      | Process-wide P2P namespace |
//! | Reachable by     | App name, UID, P2PName       | UID, P2PName               |
//! | Bound to an App  | Yes (the `AppHandle`)        | No (process-global)        |
//! | Registered on    | `LF_RegisterCall`            | `LF_Register_P2P_Call`     |
//! | Unregistered by  | `AppHandle::unregister`      | `unregister_p2p`           |
//! | Lifetime         | Until `AppHandle` drops      | Until `LF_Shutdown`        |
//!
//! # Callback contract
//!
//! The callback rules are **identical** to those in
//! [`crate::app_handle`]:
//!
//! 1. **Do not block.** A long-running callback occupies a worker
//!    thread from the native pool.
//! 2. **Do not call any blocking LingoFuse function** (`framework::call`,
//!    `AppHandle::local_call`, `framework::prepare_done`,
//!    `framework::shutdown`) from inside a callback. Doing so deadlocks
//!    the native scheduler.
//! 3. **Do not panic.** The wrapper catches every panic before it can
//!    cross the FFI boundary, but a caught panic still aborts the
//!    current callback.
//!
//! # Memory model
//!
//! Each registered P2P API owns a small context object that is `Box`ed
//! and leaked to the native layer as the callback's `trigger` pointer.
//! The `Box` is **never reclaimed**, even when the API is unregistered.
//! This is the same trade-off documented in [`crate::app_handle`]: the
//! native layer may invoke a callback at any time, including
//! concurrently with an unregister call, so a reclaim would create a
//! use-after-free window.
//!
//! # Threading
//!
//! The functions in this module may be called from any thread. The
//! native library is thread-safe, and the module holds no shared state
//! of its own.
//!
//! # Example
//!
//! ```no_run
//! use lingofuse::{data_handle::DataHandle, io, p2p};
//!
//! # fn main() -> Result<(), lingofuse::error::Error> {
//! p2p::register_p2p_call("whoami", "echo caller identity",
//!     |input: &mut DataHandle, output: &mut DataHandle| {
//!         // `input` is the sender's handle; `output` is the response.
//!         let uid = input.p2p_uid().unwrap_or_default();
//!         let name = input.p2p_name().unwrap_or_default();
//!         let payload = serde_json::json!({
//!             "uid_hex": uid.to_hex(),
//!             "p2p_name": name,
//!         });
//!         let _ = io::write_json(output, &payload);
//!     })?;
//! # Ok(()) }
//! ```

use std::ffi::{c_void, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::data_handle::DataHandle;
use crate::error::Error;
use crate::sys::{
    self, DataHnd, LfCallFunc, LfNotifyFunc,
};

// ============================================================================
// Context objects (leaked as the `trigger` pointer)
// ============================================================================

/// The context behind a registered P2P Call API.
///
/// The native layer stores a raw pointer to a `Box<CallContext>` as the
/// callback's `trigger` parameter. See the module documentation for why
/// the `Box` is leaked rather than reclaimed.
struct CallContext {
    handler: Box<dyn Fn(&mut DataHandle, &mut DataHandle) + Send + Sync + 'static>,
}

/// The context behind a registered P2P Notify API.
struct NotifyContext {
    handler: Box<dyn Fn(&mut DataHandle) + Send + Sync + 'static>,
}

// ============================================================================
// Trampolines
// ============================================================================

/// The `extern "C"` function the native layer invokes for a P2P Call
/// API.
///
/// # Safety
///
/// - `trigger` must be a pointer produced by `Box::into_raw` on a
///   [`CallContext`]. It is `'static` from the native layer's point of
///   view because the `Box` is never reclaimed.
/// - `input` and `output` are valid `TDataHnd` values for the duration
///   of the callback, as documented by the native library.
unsafe extern "C" fn call_trampoline(
    trigger: *mut c_void,
    input: DataHnd,
    output: DataHnd,
) {
    if trigger.is_null() {
        return;
    }

    // SAFETY: forwarded from the caller; see the function doc.
    let ctx: &CallContext = unsafe { &*(trigger as *const CallContext) };

    // Catch every panic so it cannot cross the FFI boundary.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: `input` / `output` are valid for the callback
        // duration, per the native contract.
        let Ok(mut ih) = DataHandle::from_raw(input, false) else {
            return;
        };
        let Ok(mut oh) = DataHandle::from_raw(output, false) else {
            return;
        };
        (ctx.handler)(&mut ih, &mut oh);
    }));
}

/// The `extern "C"` function the native layer invokes for a P2P Notify
/// API.
///
/// # Safety
///
/// Same contract as [`call_trampoline`], minus the output handle.
unsafe extern "C" fn notify_trampoline(trigger: *mut c_void, input: DataHnd) {
    if trigger.is_null() {
        return;
    }

    // SAFETY: forwarded from the caller.
    let ctx: &NotifyContext = unsafe { &*(trigger as *const NotifyContext) };

    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Ok(mut ih) = DataHandle::from_raw(input, false) else {
            return;
        };
        (ctx.handler)(&mut ih);
    }));
}

// ============================================================================
// Public API
// ============================================================================

/// Registers a process-wide P2P Call (request-response) API.
///
/// The `handler` runs on a native worker thread. See the module
/// documentation for the callback contract.
///
/// # Parameters
///
/// - `api_name`: UTF-8, NUL-terminated API name. Case-insensitive
///   matching applies at lookup time. Must be unique within the
///   process-wide P2P namespace; a duplicate registration returns
///   [`ErrorCode::RegistrationFailed`].
/// - `description`: UTF-8, NUL-terminated description.
/// - `handler`: The callback. See the module documentation.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `api_name` or `description`
///   contains an interior NUL.
/// - [`ErrorCode::RegistrationFailed`] if the native layer rejects the
///   registration (usually a duplicate name in the P2P namespace).
pub fn register_p2p_call<F>(
    api_name: &str,
    description: &str,
    handler: F,
) -> Result<(), Error>
where
    F: Fn(&mut DataHandle, &mut DataHandle) + Send + Sync + 'static,
{
    let lib = sys::get_library().map_err(Error::from_load)?;
    let c_name = CString::new(api_name).map_err(|_| {
        Error::invalid_argument(
            "p2p::register_p2p_call",
            "api_name contains an interior NUL",
        )
    })?;
    let c_desc = CString::new(description).map_err(|_| {
        Error::invalid_argument(
            "p2p::register_p2p_call",
            "description contains an interior NUL",
        )
    })?;

    // Box the context and leak it as the trigger pointer. See the
    // module documentation for the rationale.
    let ctx = Box::new(CallContext {
        handler: Box::new(handler),
    });
    let trigger = Box::into_raw(ctx) as *mut c_void;

    // SAFETY: `lib` is a valid `'static` function table; both strings
    // are UTF-8, NUL-terminated; `trigger` is a leaked
    // `Box<CallContext>` pointer; `call_trampoline` matches the
    // `LfCallFunc` signature exactly.
    let result = unsafe {
        (lib.lf_register_p2p_call)(
            c_name.as_ptr(),
            c_desc.as_ptr(),
            trigger,
            call_trampoline as LfCallFunc,
        )
    };

    if result != 1 {
        // The native layer refused the registration. The trigger has
        // not been stored, so reclaiming it here is safe.
        //
        // SAFETY: `trigger` was produced by `Box::into_raw` above and
        // never handed to the native layer.
        unsafe {
            drop(Box::from_raw(trigger as *mut CallContext));
        }
        return Err(Error::registration_failed(
            "p2p::register_p2p_call",
            api_name,
        ));
    }

    Ok(())
}

/// Registers a process-wide P2P Notify (one-way) API.
///
/// Same contract as [`register_p2p_call`], minus the output handle.
///
/// # Errors
///
/// Same as [`register_p2p_call`].
pub fn register_p2p_notify<F>(
    api_name: &str,
    description: &str,
    handler: F,
) -> Result<(), Error>
where
    F: Fn(&mut DataHandle) + Send + Sync + 'static,
{
    let lib = sys::get_library().map_err(Error::from_load)?;
    let c_name = CString::new(api_name).map_err(|_| {
        Error::invalid_argument(
            "p2p::register_p2p_notify",
            "api_name contains an interior NUL",
        )
    })?;
    let c_desc = CString::new(description).map_err(|_| {
        Error::invalid_argument(
            "p2p::register_p2p_notify",
            "description contains an interior NUL",
        )
    })?;

    let ctx = Box::new(NotifyContext {
        handler: Box::new(handler),
    });
    let trigger = Box::into_raw(ctx) as *mut c_void;

    // SAFETY: as in `register_p2p_call`.
    let result = unsafe {
        (lib.lf_register_p2p_notify)(
            c_name.as_ptr(),
            c_desc.as_ptr(),
            trigger,
            notify_trampoline as LfNotifyFunc,
        )
    };

    if result != 1 {
        // SAFETY: see `register_p2p_call`.
        unsafe {
            drop(Box::from_raw(trigger as *mut NotifyContext));
        }
        return Err(Error::registration_failed(
            "p2p::register_p2p_notify",
            api_name,
        ));
    }

    Ok(())
}

/// Removes a process-wide P2P API by name.
///
/// Does **not** affect app-bound APIs of the same name.
///
/// # Return value
///
/// `Ok(true)` if the API was found and removed, `Ok(false)` otherwise.
///
/// # Propagation delay
///
/// The local effect is immediate. A network broadcast propagates the
/// removal to remote peers within approximately 3 seconds. During that
/// window a remote caller may still route to this API and receive an
/// empty response.
///
/// # Note
///
/// The callback context behind the unregistered API is **not**
/// reclaimed (see the module documentation). A subsequent registration
/// with the same name creates a fresh context.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `api_name` contains an interior
///   NUL.
pub fn unregister_p2p(api_name: &str) -> Result<bool, Error> {
    let lib = sys::get_library().map_err(Error::from_load)?;
    let c_name = CString::new(api_name).map_err(|_| {
        Error::invalid_argument(
            "p2p::unregister_p2p",
            "api_name contains an interior NUL",
        )
    })?;

    // SAFETY: `c_name` is a valid UTF-8, NUL-terminated string.
    let result = unsafe { (lib.lf_unregister_p2p)(c_name.as_ptr()) };
    Ok(result == 1)
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn have_native() -> bool {
        match sys::get_library() {
            Ok(_) => true,
            Err(e) => {
                eprintln!("[SKIP] native library not available: {}", e);
                false
            }
        }
    }

    #[test]
    fn register_p2p_call_rejects_interior_nul_in_name() {
        if !have_native() {
            return;
        }
        let err = register_p2p_call("bad\0name", "desc", |_in, _out| {})
            .unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn register_p2p_call_rejects_interior_nul_in_description() {
        if !have_native() {
            return;
        }
        let err = register_p2p_call("some_name", "desc\0bad", |_in, _out| {})
            .unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn register_p2p_notify_rejects_interior_nul_in_name() {
        if !have_native() {
            return;
        }
        let err =
            register_p2p_notify("bad\0name", "desc", |_in| {}).unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn unregister_p2p_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        let err = unregister_p2p("bad\0name").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn register_and_unregister_p2p_call_roundtrip() {
        if !have_native() {
            return;
        }

        let name = "__rust_p2p_call_test__";
        // Ensure a clean slate even if a previous run left the name
        // registered.
        let _ = unregister_p2p(name);

        register_p2p_call(name, "test", |_in, _out| {}).unwrap();
        assert!(unregister_p2p(name).unwrap());

        // A second unregister is a no-op and returns `false`.
        assert!(!unregister_p2p(name).unwrap());
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn register_p2p_call_twice_fails() {
        if !have_native() {
            return;
        }

        let name = "__rust_p2p_dup_test__";
        let _ = unregister_p2p(name);

        register_p2p_call(name, "first", |_in, _out| {}).unwrap();
        let second = register_p2p_call(name, "second", |_in, _out| {});

        assert!(second.is_err(), "duplicate registration must fail");
        assert_eq!(second.unwrap_err().code(), ErrorCode::RegistrationFailed);

        // Clean up so a subsequent test run starts fresh.
        let _ = unregister_p2p(name);
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn register_and_unregister_p2p_notify_roundtrip() {
        if !have_native() {
            return;
        }

        let name = "__rust_p2p_notify_test__";
        let _ = unregister_p2p(name);

        register_p2p_notify(name, "test", |_in| {}).unwrap();
        assert!(unregister_p2p(name).unwrap());
        assert!(!unregister_p2p(name).unwrap());
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn unregister_unknown_p2p_name_returns_false() {
        if !have_native() {
            return;
        }
        // Nothing has registered this name.
        let present = unregister_p2p("__definitely_absent_p2p__").unwrap();
        assert!(!present);
    }
}