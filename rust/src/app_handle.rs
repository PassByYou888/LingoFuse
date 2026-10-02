//! RAII wrapper around a native LingoFuse application handle.
//!
//! [`AppHandle`] owns a `TAppHnd` and provides a safe Rust API for
//! registering Call / Notify endpoints, unregistering them, invoking
//! them locally, and binding the application to idle clients.
//!
//! # Callback model
//!
//! Callbacks registered through this layer are Rust closures with one
//! of the following signatures:
//!
//! ```text
//! Call   : Fn(&mut DataHandle, &mut DataHandle) + Send + Sync + 'static
//! Notify : Fn(&mut DataHandle) + Send + Sync + 'static
//! ```
//!
//! The `DataHandle` instances passed to the closure are **borrowed**:
//! the native layer owns the underlying resource and releases it as
//! soon as the closure returns. Do not attempt to keep them beyond the
//! closure body, and do not call `dispose()` on them.
//!
//! # Callback contract
//!
//! The native callback runs on a worker thread owned by the native
//! library. Three rules follow:
//!
//! 1. **Do not block.** A long-running callback occupies a worker
//!    thread from the native pool.
//! 2. **Do not call any blocking LingoFuse function** (`LF_Call`,
//!    `LF_LocalCall`, `LF_PrepareDone`, `LF_Shutdown`) from inside a
//!    callback. Doing so deadlocks the native scheduler.
//! 3. **Do not panic.** The wrapper catches every panic before it can
//!    cross the FFI boundary, but a caught panic still aborts the
//!    current callback. Prefer returning an error payload over
//!    unwinding.
//!
//! ## Panic isolation
//!
//! The trampoline that the native layer invokes wraps the user closure
//! in [`std::panic::catch_unwind`]. A panic is therefore converted into
//! a silent no-op rather than undefined behaviour at the FFI boundary.
//! Since Rust 1.81, a panic that crosses an `extern "C"` boundary
//! aborts the process; older toolchains make it UB. Catching is not
//! optional.
//!
//! # Memory model
//!
//! Each registered API owns a small context object that is `Box`ed and
//! leaked to the native layer as the callback's `trigger` pointer. The
//! `Box` is **never reclaimed**, even when the API is unregistered or
//! when the [`AppHandle`] is dropped.
//!
//! This is a deliberate trade-off:
//!
//! - The native library can invoke a callback at any time after
//!   registration, including concurrently with an unregister call. A
//!   reclaim would create a use-after-free window.
//! - The cost is bounded: a context is a few dozen bytes, and the
//!   number of registered APIs per application is typically small
//!   (single digits to low tens).
//! - `LF_Shutdown` releases the native side of the callback registry,
//!   but the leaked `Box` remains until the process exits. For any
//!   realistic program this is negligible.
//!
//! If you have an application that registers and unregisters APIs in a
//! tight loop, contact the maintainers: a reference-counted scheme
//! (with the associated reentrancy analysis) would be needed.
//!
//! # Threading
//!
//! [`AppHandle`] is **not** `Send` or `Sync`. The native library is
//! thread-safe, but the safe wrapper deliberately constrains handle
//! ownership to a single thread so that the Rust borrow checker can
//! prevent races on the handle itself. Callbacks still run on native
//! worker threads; the closure they invoke must be `Send + Sync`.
//!
//! # Lifetime
//!
//! `Drop` calls `LF_FreeApp`, which is the **first stage** of a
//! two-stage destruction: the native object is detached from all
//! clients and its sequenced threads are stopped, but the underlying
//! `TLF_App` remains alive in the global pool until `LF_Shutdown` is
//! called. After `Drop`, the handle is invalid and must not be reused.

use std::collections::HashSet;
use std::ffi::{c_void, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

use crate::data_handle::DataHandle;
use crate::error::{Error, ErrorCode};
use crate::sys::{self, AppHnd, DataHnd, LfCallFunc, LfNotifyFunc, NativeLibrary};

// ============================================================================
// Context objects (leaked as the `trigger` pointer)
// ============================================================================

/// The context behind a registered Call API.
///
/// The native layer stores a raw pointer to a `Box<CallContext>` as the
/// callback's `trigger` parameter. See the module documentation for why
/// the `Box` is leaked rather than reclaimed.
struct CallContext {
    /// The user-supplied closure.
    ///
    /// `Box<dyn Fn ...>` so that a capturing closure of any shape can
    /// be stored uniformly. `Send + Sync` because the callback runs on
    /// a native worker thread.
    handler: Box<dyn Fn(&mut DataHandle, &mut DataHandle) + Send + Sync + 'static>,
}

/// The context behind a registered Notify API.
struct NotifyContext {
    handler: Box<dyn Fn(&mut DataHandle) + Send + Sync + 'static>,
}

// ============================================================================
// Trampolines
// ============================================================================

/// The `extern "C"` function the native layer invokes for a Call API.
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
    // A null trigger would indicate a bug in this crate; refuse to
    // proceed rather than dereference a null pointer.
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

/// The `extern "C"` function the native layer invokes for a Notify API.
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
// AppHandle
// ============================================================================

/// RAII wrapper around a native LingoFuse application handle.
///
/// See the module documentation for the callback contract, the memory
/// model, and the threading rules.
///
/// # Example
///
/// ```no_run
/// use lingofuse::app_handle::AppHandle;
/// use lingofuse::{data_handle::DataHandle, io};
///
/// # fn main() -> Result<(), lingofuse::error::Error> {
/// let app = AppHandle::new("Calculator", "Simple calculator")?;
///
/// app.register_call("add", "Add two i32 values", |input, output| {
///     #[derive(serde::Deserialize, serde::Serialize)]
///     struct Args { a: i32, b: i32 }
///     #[derive(serde::Serialize)]
///     struct Result_ { result: i32 }
///
///     if let Ok(args) = io::read_json::<Args>(input) {
///         let _ = io::write_json(output, &Result_ { result: args.a + args.b });
///     }
/// })?;
///
/// # Ok(()) }
/// ```
pub struct AppHandle {
    /// The `'static` function table. Resolved once at construction.
    lib: &'static NativeLibrary,

    /// The raw native handle, or `None` after the handle has been
    /// disposed.
    raw: Option<AppHnd>,

    /// The application name. Kept for diagnostics and for the `name()`
    /// accessor.
    name: String,

    /// The set of API names currently registered through this handle.
    ///
    /// Used only as a local optimisation to detect duplicate names
    /// before calling into the native layer, and to keep `unregister`
    /// idempotent. The native layer performs its own authoritative
    /// duplicate check.
    registrations: Mutex<HashSet<String>>,
}

impl AppHandle {
    // -----------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------

    /// Creates a new application with the given name and description.
    ///
    /// # Errors
    ///
    /// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
    ///   available.
    /// - [`ErrorCode::InvalidArgument`] if `name` contains an interior
    ///   NUL.
    /// - [`ErrorCode::Generic`] if the native allocator fails.
    pub fn new(name: &str, description: &str) -> Result<Self, Error> {
        let lib = sys::get_library().map_err(Error::from_load)?;
        let c_name = CString::new(name).map_err(|_| {
            Error::invalid_argument(
                "AppHandle::new",
                "name contains an interior NUL",
            )
        })?;
        let c_desc = CString::new(description).map_err(|_| {
            Error::invalid_argument(
                "AppHandle::new",
                "description contains an interior NUL",
            )
        })?;

        // SAFETY: `lib` is a valid `'static` function table; both
        // strings are UTF-8, NUL-terminated. See the contract in
        // `bindings.rs`.
        let hnd = unsafe { (lib.lf_create_app)(c_name.as_ptr(), c_desc.as_ptr()) };
        if hnd.is_null() {
            return Err(Error::new(
                ErrorCode::Generic,
                format!("LF_CreateApp failed for name '{}'", name),
            ));
        }

        Ok(AppHandle {
            lib,
            raw: Some(hnd),
            name: name.to_string(),
            registrations: Mutex::new(HashSet::new()),
        })
    }

    // -----------------------------------------------------------------
    // Identity and state
    // -----------------------------------------------------------------

    /// Returns the application name passed to [`AppHandle::new`].
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Returns the raw native handle, or `None` after disposal.
    ///
    /// # Safety (caller responsibility)
    ///
    /// The returned pointer is valid only as long as the [`AppHandle`]
    /// has not been dropped.
    pub fn raw(&self) -> Option<AppHnd> {
        self.raw
    }

    /// Returns `true` while the handle is valid and not yet disposed.
    pub fn is_valid(&self) -> bool {
        self.raw.is_some()
    }

    // -----------------------------------------------------------------
    // API registration
    // -----------------------------------------------------------------

    /// Registers a Call (request-response) API.
    ///
    /// The `handler` runs on a native worker thread. See the module
    /// documentation for the callback contract.
    ///
    /// # Errors
    ///
    /// - [`ErrorCode::NullHandle`] if the handle has been disposed.
    /// - [`ErrorCode::InvalidArgument`] if `api_name` or `description`
    ///   contains an interior NUL.
    /// - [`ErrorCode::RegistrationFailed`] if the native layer rejects
    ///   the registration (usually a duplicate API name).
    pub fn register_call<F>(
        &self,
        api_name: &str,
        description: &str,
        handler: F,
    ) -> Result<(), Error>
    where
        F: Fn(&mut DataHandle, &mut DataHandle) + Send + Sync + 'static,
    {
        let hnd = self.require_handle("AppHandle::register_call")?;
        let c_name = CString::new(api_name).map_err(|_| {
            Error::invalid_argument(
                "AppHandle::register_call",
                "api_name contains an interior NUL",
            )
        })?;
        let c_desc = CString::new(description).map_err(|_| {
            Error::invalid_argument(
                "AppHandle::register_call",
                "description contains an interior NUL",
            )
        })?;

        // Box the context and leak it as the trigger pointer. See the
        // module documentation for the rationale.
        let ctx = Box::new(CallContext {
            handler: Box::new(handler),
        });
        let trigger = Box::into_raw(ctx) as *mut c_void;

        // SAFETY: `hnd` is live, both C strings are valid, `trigger`
        // is a leaked `Box<CallContext>` pointer, and `call_trampoline`
        // has the exact `LfCallFunc` signature.
        let result = unsafe {
            (self.lib.lf_register_call)(
                hnd,
                c_name.as_ptr(),
                c_desc.as_ptr(),
                trigger,
                call_trampoline as LfCallFunc,
            )
        };

        if result != 1 {
            // The native layer refused the registration. The trigger
            // has not been stored, so reclaiming it here is safe.
            //
            // SAFETY: `trigger` was produced by `Box::into_raw` above
            // and never handed to the native layer (the registration
            // failed). Reclaiming is therefore correct.
            unsafe {
                drop(Box::from_raw(trigger as *mut CallContext));
            }
            return Err(Error::registration_failed(
                "AppHandle::register_call",
                api_name,
            ));
        }

        self.registrations
            .lock()
            .expect("registrations mutex poisoned")
            .insert(api_name.to_string());
        Ok(())
    }

    /// Registers a Notify (one-way) API.
    ///
    /// Same contract as [`AppHandle::register_call`], minus the output
    /// handle.
    pub fn register_notify<F>(
        &self,
        api_name: &str,
        description: &str,
        handler: F,
    ) -> Result<(), Error>
    where
        F: Fn(&mut DataHandle) + Send + Sync + 'static,
    {
        let hnd = self.require_handle("AppHandle::register_notify")?;
        let c_name = CString::new(api_name).map_err(|_| {
            Error::invalid_argument(
                "AppHandle::register_notify",
                "api_name contains an interior NUL",
            )
        })?;
        let c_desc = CString::new(description).map_err(|_| {
            Error::invalid_argument(
                "AppHandle::register_notify",
                "description contains an interior NUL",
            )
        })?;

        let ctx = Box::new(NotifyContext {
            handler: Box::new(handler),
        });
        let trigger = Box::into_raw(ctx) as *mut c_void;

        // SAFETY: as in `register_call`.
        let result = unsafe {
            (self.lib.lf_register_notify)(
                hnd,
                c_name.as_ptr(),
                c_desc.as_ptr(),
                trigger,
                notify_trampoline as LfNotifyFunc,
            )
        };

        if result != 1 {
            // SAFETY: see `register_call`.
            unsafe {
                drop(Box::from_raw(trigger as *mut NotifyContext));
            }
            return Err(Error::registration_failed(
                "AppHandle::register_notify",
                api_name,
            ));
        }

        self.registrations
            .lock()
            .expect("registrations mutex poisoned")
            .insert(api_name.to_string());
        Ok(())
    }

    /// Unregisters a previously registered API.
    ///
    /// Returns `Ok(true)` if the API was found and removed, `Ok(false)`
    /// otherwise.
    ///
    /// # Propagation delay
    ///
    /// The local effect is immediate. A network broadcast propagates
    /// the removal to remote peers within approximately 3 seconds.
    /// During that window a remote caller may still route to this API
    /// and receive an empty response.
    ///
    /// # Note
    ///
    /// The callback context behind the unregistered API is **not**
    /// reclaimed (see the module documentation). A subsequent
    /// registration with the same name creates a fresh context.
    pub fn unregister(&self, api_name: &str) -> Result<bool, Error> {
        let hnd = self.require_handle("AppHandle::unregister")?;
        let c_name = CString::new(api_name).map_err(|_| {
            Error::invalid_argument(
                "AppHandle::unregister",
                "api_name contains an interior NUL",
            )
        })?;

        // SAFETY: `hnd` is live and `c_name` is a valid UTF-8,
        // NUL-terminated string.
        let result = unsafe { (self.lib.lf_unregister)(hnd, c_name.as_ptr()) };

        if result == 1 {
            self.registrations
                .lock()
                .expect("registrations mutex poisoned")
                .remove(api_name);
        }
        Ok(result == 1)
    }

    // -----------------------------------------------------------------
    // Local execution
    // -----------------------------------------------------------------

    /// Invokes a Call API locally within the same process.
    ///
    /// The `param` handle is **not** consumed by this call; the caller
    /// retains ownership. The returned [`DataHandle`] owns the response
    /// and must be dropped by the caller.
    ///
    /// When the target API is not registered, the returned handle has
    /// size `0`. Callers that need to distinguish "empty response" from
    /// "missing API" should check [`DataHandle::size`].
    ///
    /// # Errors
    ///
    /// - [`ErrorCode::NullHandle`] if the handle has been disposed, or
    ///   if `param` is not valid.
    /// - [`ErrorCode::CallFailed`] if the native layer returns a null
    ///   handle (an unexpected transport-level failure).
    pub fn local_call(&self, param: &DataHandle) -> Result<DataHandle, Error> {
        let hnd = self.require_handle("AppHandle::local_call")?;
        let param_hnd = param
            .raw()
            .ok_or_else(|| Error::null_handle("AppHandle::local_call: param"))?;

        // SAFETY: `hnd` and `param_hnd` are both live.
        let res = unsafe { (self.lib.lf_local_call)(hnd, param_hnd) };
        if res.is_null() {
            return Err(Error::call_failed(
                "AppHandle::local_call",
                "native layer returned a null handle",
            ));
        }

        DataHandle::from_raw(res, true)
    }

    /// Invokes a Notify API locally within the same process.
    ///
    /// The `param` handle is **not** consumed by this call.
    ///
    /// # Errors
    ///
    /// Same as [`AppHandle::local_call`], minus the return-value case.
    pub fn local_notify(&self, param: &DataHandle) -> Result<(), Error> {
        let hnd = self.require_handle("AppHandle::local_notify")?;
        let param_hnd = param
            .raw()
            .ok_or_else(|| Error::null_handle("AppHandle::local_notify: param"))?;

        // SAFETY: `hnd` and `param_hnd` are both live.
        unsafe { (self.lib.lf_local_notify)(hnd, param_hnd) };
        Ok(())
    }

    // -----------------------------------------------------------------
    // Client binding
    // -----------------------------------------------------------------

    /// Binds the application to all currently unbound clients.
    ///
    /// Must be called **after** the framework has started (i.e. after
    /// [`crate::framework::prepare_done`] returned `Ok(true)`).
    ///
    /// Returns the number of clients bound. Zero means either the main
    /// thread is not active, or all clients already host an
    /// application.
    ///
    /// # Errors
    ///
    /// - [`ErrorCode::NullHandle`] if the handle has been disposed.
    pub fn bind(&self) -> Result<i32, Error> {
        let hnd = self.require_handle("AppHandle::bind")?;
        // SAFETY: `hnd` is live.
        Ok(unsafe { (self.lib.lf_bind_app)(hnd) })
    }

    // -----------------------------------------------------------------
    // Lifetime
    // -----------------------------------------------------------------

    /// Performs the first stage of the two-stage native destruction.
    ///
    /// The application is detached from all clients and its sequenced
    /// threads are stopped. The underlying native object remains in the
    /// global pool until [`crate::framework::shutdown`] is called.
    ///
    /// Normally you never need to call this: [`Drop`] calls it
    /// automatically. Call it explicitly only to release the handle
    /// **before** the `AppHandle` goes out of scope.
    ///
    /// After this call the handle is invalid; every method that requires
    /// a live handle produces [`ErrorCode::NullHandle`].
    ///
    /// # Leaked contexts
    ///
    /// The callback contexts behind every registered API are **not**
    /// reclaimed, even by this method. See the module documentation.
    pub fn dispose(&mut self) {
        if let Some(hnd) = self.raw.take() {
            // SAFETY: `hnd` was created by `LF_CreateApp`, was not
            // previously freed, and has just been removed from
            // `self.raw`.
            unsafe { (self.lib.lf_free_app)(hnd) };

            // Clear the local registration bookkeeping. The leaked
            // contexts remain alive; only the bookkeeping is released.
            if let Ok(mut regs) = self.registrations.lock() {
                regs.clear();
            }
        }
    }

    // -----------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------

    fn require_handle(&self, op: &str) -> Result<AppHnd, Error> {
        self.raw.ok_or_else(|| Error::null_handle(op))
    }
}

impl Drop for AppHandle {
    fn drop(&mut self) {
        self.dispose();
    }
}

impl std::fmt::Debug for AppHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppHandle")
            .field("name", &self.name)
            .field("valid", &self.is_valid())
            .finish_non_exhaustive()
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::io;
    use serde::{Deserialize, Serialize};

    /// Skips the test silently when the native library is not present.
    fn try_app(name: &str) -> Option<AppHandle> {
        match AppHandle::new(name, "stage-2 test") {
            Ok(a) => Some(a),
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => {
                eprintln!("[SKIP] native library not available: {}", e);
                None
            }
            Err(e) => panic!("unexpected construction failure: {}", e),
        }
    }

    #[derive(Serialize, Deserialize, Debug, PartialEq)]
    struct AddArgs {
        a: i32,
        b: i32,
    }

    #[derive(Serialize, Deserialize, Debug, PartialEq)]
    struct AddResult {
        sum: i32,
    }

    #[test]
    fn create_app_and_read_name() {
        let Some(app) = try_app("RustTestAppName") else {
            return;
        };
        assert_eq!(app.name(), "RustTestAppName");
        assert!(app.is_valid());
        assert!(!app.raw().unwrap().is_null());
    }

    #[test]
    fn register_call_succeeds() {
        let Some(app) = try_app("RustTestAppRegCall") else {
            return;
        };
        let r = app.register_call("add", "add", |_in, _out| {});
        assert!(r.is_ok(), "register_call failed: {:?}", r.err());
    }

    #[test]
    fn register_notify_succeeds() {
        let Some(app) = try_app("RustTestAppRegNotify") else {
            return;
        };
        let r = app.register_notify("log", "log", |_in| {});
        assert!(r.is_ok(), "register_notify failed: {:?}", r.err());
    }

    #[test]
    fn duplicate_registration_fails() {
        let Some(app) = try_app("RustTestAppDup") else {
            return;
        };
        app.register_call("dup", "first", |_in, _out| {}).unwrap();
        let second = app.register_call("dup", "second", |_in, _out| {});
        assert!(second.is_err(), "duplicate registration must fail");
        assert_eq!(
            second.unwrap_err().code(),
            ErrorCode::RegistrationFailed
        );
    }

    #[test]
    fn unregister_after_register() {
        let Some(app) = try_app("RustTestAppUnreg") else {
            return;
        };
        app.register_call("gone", "gone", |_in, _out| {}).unwrap();
        assert!(app.unregister("gone").unwrap());
        // Second unregister is a no-op and returns false.
        assert!(!app.unregister("gone").unwrap());
        // Registering the same name again now succeeds.
        app.register_call("gone", "back", |_in, _out| {}).unwrap();
    }

    #[test]
    fn local_call_roundtrip() {
        let Some(app) = try_app("RustTestAppLocal") else {
            return;
        };
        app.register_call("add", "add two ints", |input, output| {
            let args: AddArgs = match io::read_json(input) {
                Ok(a) => a,
                Err(_) => return,
            };
            let _ = io::write_json(output, &AddResult { sum: args.a + args.b });
        })
        .unwrap();

        let mut req = DataHandle::new("add").unwrap();
        io::write_json(&mut req, &AddArgs { a: 5, b: 7 }).unwrap();
        // The local-call path reads the request from the current
        // cursor, which is at the end after a write. Rewind first.
        req.set_position(0).unwrap();

        let mut res = app.local_call(&req).unwrap();
        assert!(res.size().unwrap() > 0, "response must not be empty");
        res.set_position(0).unwrap();
        let out: AddResult = io::read_json(&mut res).unwrap();
        assert_eq!(out, AddResult { sum: 12 });
    }

    #[test]
    fn local_notify_is_delivered() {
        use std::sync::atomic::{AtomicI32, Ordering};
        use std::sync::Arc;

        let Some(app) = try_app("RustTestAppNotify") else {
            return;
        };
        let counter = Arc::new(AtomicI32::new(0));
        let c = counter.clone();
        app.register_notify("count", "increment counter", move |_input| {
            c.fetch_add(1, Ordering::SeqCst);
        })
        .unwrap();

        let mut req = DataHandle::new("count").unwrap();
        io::write_json(&mut req, &serde_json::json!({})).unwrap();
        req.set_position(0).unwrap();

        app.local_notify(&req).unwrap();
        assert_eq!(counter.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn callback_panic_does_not_abort() {
        let Some(app) = try_app("RustTestAppPanic") else {
            return;
        };
        app.register_call("boom", "always panics", |_in, _out| {
            panic!("intentional panic for test");
        })
        .unwrap();

        let mut req = DataHandle::new("boom").unwrap();
        req.write_bytes(&[0]).unwrap();
        req.set_position(0).unwrap();

        // The trampoline catches the panic. The result is an empty
        // response, not an abort.
        let res = app.local_call(&req).unwrap();
        assert_eq!(res.size().unwrap(), 0);
    }

    #[test]
    fn dispose_invalidates_handle() {
        let Some(mut app) = try_app("RustTestAppDispose") else {
            return;
        };
        app.dispose();
        assert!(!app.is_valid());
        let err = app.register_call("x", "x", |_in, _out| {}).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }
}