//! Process-wide facade over the LingoFuse C ABI.
//!
//! This module is the Rust counterpart of the C++ `lingofuse::Framework`
//! free-function set and the C# `Framework` static class. It exposes
//! every process-wide operation that the native library provides but
//! that does not fit the [`crate::data_handle::DataHandle`] or
//! [`crate::app_handle::AppHandle`] abstractions:
//!
//! - Network preparation (`reset_prepare`, `prepare_service`,
//!   `prepare_client`, `prepare_done`, `exit_main_thread`).
//! - Remote invocation (`call`, `try_call`, `notify`,
//!   `sequenced_notify`).
//! - Runtime options (`set_option`).
//! - Application name generation and query (`generate_app_name`,
//!   `get_app_name`).
//! - Health checks (`check_main_thread`, `check_app`, `check_api`).
//! - Process-wide shutdown (`shutdown`).
//!
//! Every function forwards to exactly one native export. No caching, no
//! state, no lifecycle coordination.
//!
//! # The `prepare_done` contract
//!
//! `LF_PrepareDone` returns `1` only once per process. A second call
//! without an intervening [`shutdown`] returns `0`, which is **not a
//! failure**. The Rust wrapper exposes this as
//! `Result<bool, Error>`: `Ok(true)` on the first successful start,
//! `Ok(false)` on the second call.
//!
//! # The `call` timeout contract
//!
//! The C ABI documents that `LF_Call` **never returns a null handle**.
//! On timeout or unreachable target it returns a size-0 handle.
//! [`call`] therefore returns the handle unchanged; callers that want
//! a clean "did it succeed?" answer should use [`try_call`], which
//! returns `Ok(None)` for a size-0 response.
//!
//! # Testing
//!
//! Tests that mutate process-global native state (setting options,
//! preparing the network, exiting the main thread, shutting the
//! framework down) are marked `#[ignore]`. Run them in isolation with:
//!
//! ```text
//! cargo test --lib -- --ignored --test-threads=1
//! ```
//!
//! # Example
//!
//! ```no_run
//! use lingofuse::{data_handle::DataHandle, framework};
//!
//! # fn main() -> Result<(), lingofuse::error::Error> {
//! framework::reset_prepare();
//! framework::prepare_service("ipc:example", "ipc:example")?;
//! framework::prepare_client("ipc:example", None)?;
//! let _started = framework::prepare_done()?;
//!
//! let mut param = DataHandle::new("ping")?;
//! param.write_bytes(b"hello")?;
//! param.set_position(0)?;
//! if let Some(_resp) = framework::try_call("OtherApp", &param, 3000)? {
//!     // ... use the response ...
//! }
//! # Ok(()) }
//! ```

use std::ffi::{CStr, CString};

use crate::app_handle::AppHandle;
use crate::data_handle::DataHandle;
use crate::error::{Error, ErrorCode};
use crate::sys::{self, AppHnd, NativeLibrary};

// ============================================================================
// Internal helpers
// ============================================================================

/// Resolves the native library, mapping a load failure into the crate's
/// error type.
fn lib() -> Result<&'static NativeLibrary, Error> {
    sys::get_library().map_err(Error::from_load)
}

/// Converts a Rust `&str` to a `CString`, mapping an interior NUL to
/// [`ErrorCode::InvalidArgument`].
fn cstr(op: &str, field: &str, s: &str) -> Result<CString, Error> {
    CString::new(s).map_err(|_| {
        Error::invalid_argument(op, format!("{} contains an interior NUL", field))
    })
}

/// Copies a NUL-terminated UTF-8 string returned by the native layer
/// into an owned `String`.
///
/// # Safety
///
/// `ptr` must be either null or a pointer to a NUL-terminated UTF-8
/// string that remains valid for the duration of the call.
unsafe fn copy_cstr(ptr: *const std::os::raw::c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    // SAFETY: forwarded from the caller. The native library documents
    // every string it returns as UTF-8, NUL-terminated, with a
    // documented minimum lifetime (typically 5 seconds for the two
    // app-name functions).
    let cs = unsafe { CStr::from_ptr(ptr) };
    cs.to_string_lossy().into_owned()
}

// ============================================================================
// Network preparation
// ============================================================================

/// Clears the preparation queue.
///
/// Running services and clients are not affected. Only the pending list
/// of services and clients to be created by the next [`prepare_done`]
/// is cleared.
pub fn reset_prepare() {
    if let Ok(lib) = lib() {
        // SAFETY: zero-argument function; the native layer is
        // documented as thread-safe.
        unsafe { (lib.lf_reset_prepare)() };
    }
}

/// Prepares a C4 service.
///
/// # Parameters
///
/// - `listening_addr`: The local binding address. May be a TCP address
///   (`"0.0.0.0:9898"`) or an IPC name (`"ipc:my_service"`).
/// - `physics_addr`: The address advertised to clients. Usually equal
///   to `listening_addr`.
///
/// # Return value
///
/// The internal tag assigned to this service. It is a positive integer
/// on success.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if either address contains an
///   interior NUL.
/// - [`ErrorCode::Generic`] if the native layer rejects the address
///   (usually a duplicate).
pub fn prepare_service(
    listening_addr: &str,
    physics_addr: &str,
) -> Result<i32, Error> {
    let lib = lib()?;
    let c_listen = cstr("framework::prepare_service", "listening_addr", listening_addr)?;
    let c_physics = cstr("framework::prepare_service", "physics_addr", physics_addr)?;

    // SAFETY: both strings are valid UTF-8, NUL-terminated.
    let tag = unsafe {
        (lib.lf_prepare_service)(c_listen.as_ptr(), c_physics.as_ptr())
    };
    if tag < 0 {
        return Err(Error::new(
            ErrorCode::Generic,
            format!(
                "framework::prepare_service: native layer rejected \
                 address '{}' (duplicate?)",
                listening_addr
            ),
        ));
    }
    Ok(tag)
}

/// Prepares a C4 client.
///
/// # Parameters
///
/// - `physics_addr`: The address of the target service.
/// - `app`: The application to expose, or `None` for a pure consumer.
///
/// # Return value
///
/// The internal tag assigned to this client. It is a positive integer
/// on success.
///
/// # Duplicate addresses
///
/// Without `Overlap_Connection=True`, the same physical address can
/// host only one client per process. A second [`prepare_client`] on the
/// same address returns an error and **silently discards** the app.
/// Set `Overlap_Connection=True` via [`set_option`] **before** the call
/// to allow multiple independent tunnels to the same address.
///
/// # Errors
///
/// Same as [`prepare_service`].
pub fn prepare_client(
    physics_addr: &str,
    app: Option<&AppHandle>,
) -> Result<i32, Error> {
    let lib = lib()?;
    let c_addr = cstr("framework::prepare_client", "physics_addr", physics_addr)?;

    let app_hnd: AppHnd = match app {
        Some(a) => a.raw().ok_or_else(|| {
            Error::null_handle("framework::prepare_client: app is disposed")
        })?,
        None => AppHnd::NULL,
    };

    // SAFETY: the string is valid UTF-8, NUL-terminated; `app_hnd` is
    // either NULL or a live handle.
    let tag = unsafe { (lib.lf_prepare_client)(c_addr.as_ptr(), app_hnd) };
    if tag < 0 {
        return Err(Error::new(
            ErrorCode::Generic,
            format!(
                "framework::prepare_client: native layer rejected \
                 address '{}' (duplicate?)",
                physics_addr
            ),
        ));
    }
    Ok(tag)
}

/// Starts the framework with the prepared services and clients.
///
/// # Return value
///
/// - `Ok(true)` on the first successful start.
/// - `Ok(false)` on a second call without an intervening [`shutdown`].
///   **This is not a failure**: the framework is already running.
///
/// # Blocking
///
/// By default (`Wait_Connection_ReadyOk=True`), this call blocks until
/// every prepared client is online, or until `Wait_Connection_Timeout`
/// milliseconds have elapsed. Configure both via [`set_option`] before
/// calling.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
pub fn prepare_done() -> Result<bool, Error> {
    let lib = lib()?;
    // SAFETY: zero-argument function.
    let ret = unsafe { (lib.lf_prepare_done)() };
    Ok(ret == 1)
}

/// Requests the simulated main thread to exit.
///
/// # Pitfall
///
/// This also **flushes the data-handle pool**, releasing every
/// outstanding handle — including handles created with
/// [`DataHandle::create_permanent`]. Do not use any data handle after
/// this call has returned.
///
/// This does not release all resources; call [`shutdown`] for a full
/// cleanup.
pub fn exit_main_thread() {
    if let Ok(lib) = lib() {
        // SAFETY: zero-argument function.
        unsafe { (lib.lf_exit_main_thread)() };
    }
}

// ============================================================================
// Runtime options
// ============================================================================

/// Adjusts a global runtime option.
///
/// Unknown option names are **silently ignored** by the native layer
/// (no error, no warning). Double-check the name.
///
/// # Common options
///
/// | Name                      | Type | Default | Purpose |
/// |---------------------------|------|---------|---------|
/// | `Overlap_Connection`      | bool | `False` | Allow multiple clients per address |
/// | `Wait_Connection_ReadyOk` | bool | `True`  | `prepare_done` waits for clients |
/// | `Wait_Connection_Timeout` | int  | `30000` | Wait timeout, milliseconds |
/// | `Quiet`                   | bool | `False` | Suppress internal log output |
/// | `ShowThreadID`            | bool | `False` | Include thread IDs in logs |
/// | `ConsoleOutput`           | bool | auto    | Console logging on/off |
/// | `Fixed_Sequenced_Time`    | int  | `20000` | Sequenced-notify fallback threshold (ms) |
///
/// Boolean values: `"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` /
/// `"No"` (case-insensitive). Use `"True"` / `"False"` by preference.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if either argument contains an
///   interior NUL.
pub fn set_option(option: &str, value: &str) -> Result<(), Error> {
    let lib = lib()?;
    let c_opt = cstr("framework::set_option", "option", option)?;
    let c_val = cstr("framework::set_option", "value", value)?;

    // SAFETY: both strings are valid UTF-8, NUL-terminated.
    unsafe { (lib.lf_set_option)(c_opt.as_ptr(), c_val.as_ptr()) };
    Ok(())
}

// ============================================================================
// Application name generation and query
// ============================================================================

/// Generates a globally unique application name.
///
/// # Preconditions
///
/// Must be called after [`prepare_done`] returned `Ok(true)`. Before
/// that, the generated name lacks the C4 tunnel information and may not
/// be unique on the mesh.
///
/// # Return value
///
/// The name as an owned `String`. The native pointer is valid for only
/// ~5 seconds; this function copies it immediately, so the returned
/// value is safe to hold indefinitely.
///
/// Returns an empty string when the underlying native function returns
/// a null pointer.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
pub fn generate_app_name() -> Result<String, Error> {
    let lib = lib()?;
    // SAFETY: zero-argument function returning a NUL-terminated UTF-8
    // string with a documented 5-second lifetime. We copy it
    // immediately.
    let ptr = unsafe { (lib.lf_generate_app_name)() };
    Ok(unsafe { copy_cstr(ptr) })
}

/// Returns the name of an existing application handle.
///
/// Same 5-second pointer-validity rule as [`generate_app_name`]; this
/// function copies the string immediately.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::NullHandle`] if the handle has been disposed.
pub fn get_app_name(app: &AppHandle) -> Result<String, Error> {
    let lib = lib()?;
    let hnd = app
        .raw()
        .ok_or_else(|| Error::null_handle("framework::get_app_name"))?;

    // SAFETY: `hnd` is live; the returned string is NUL-terminated
    // UTF-8 with a documented 5-second lifetime. We copy it
    // immediately.
    let ptr = unsafe { (lib.lf_get_app_name)(hnd) };
    Ok(unsafe { copy_cstr(ptr) })
}

// ============================================================================
// Health checks
// ============================================================================

/// Returns `true` when the simulated main thread is running.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
pub fn check_main_thread() -> Result<bool, Error> {
    let lib = lib()?;
    // SAFETY: zero-argument function.
    Ok(unsafe { (lib.lf_check_main_thread)() != 0 })
}

/// Returns `true` when the named application is available on the mesh.
///
/// # Cache semantics
///
/// The lookup uses a local cache updated by network broadcasts with an
/// approximate **3-second propagation delay**. False negatives
/// immediately after registration, and false positives shortly after
/// unregistration, are both normal.
///
/// Do not use this as an authoritative existence test for critical
/// paths. Issue the call and handle the timeout instead.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `app_name` contains an interior
///   NUL.
pub fn check_app(app_name: &str) -> Result<bool, Error> {
    let lib = lib()?;
    let c_name = cstr("framework::check_app", "app_name", app_name)?;
    // SAFETY: valid UTF-8, NUL-terminated string.
    Ok(unsafe { (lib.lf_check_app)(c_name.as_ptr()) != 0 })
}

/// Returns `true` when the named API is available on the mesh.
///
/// Same cache semantics as [`check_app`].
///
/// # Errors
///
/// Same as [`check_app`].
pub fn check_api(app_name: &str, api_name: &str) -> Result<bool, Error> {
    let lib = lib()?;
    let c_app = cstr("framework::check_api", "app_name", app_name)?;
    let c_api = cstr("framework::check_api", "api_name", api_name)?;
    // SAFETY: both strings are valid UTF-8, NUL-terminated.
    Ok(unsafe { (lib.lf_check_api)(c_app.as_ptr(), c_api.as_ptr()) != 0 })
}

// ============================================================================
// Remote invocation
// ============================================================================

/// Performs a synchronous remote call.
///
/// # Return value
///
/// A [`DataHandle`] owning the response. **Never fails with a null
/// handle**: on timeout or unreachable target, the native layer returns
/// a handle with size `0`. Check [`DataHandle::size`] to distinguish a
/// failure from a valid empty response, or use [`try_call`] for a clean
/// `Option`-based API.
///
/// The caller must drop the returned handle to release the underlying
/// resource.
///
/// # Parameters
///
/// - `app_name`: Target application name.
/// - `param`: Input handle. **Not consumed**; the caller retains
///   ownership.
/// - `timeout_ms`: Timeout in milliseconds. `0` means "wait
///   indefinitely".
///
/// # Deadlock warning
///
/// Do not call this function from inside a registered callback. See the
/// [`crate::app_handle`] module documentation.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `app_name` contains an interior
///   NUL.
/// - [`ErrorCode::NullHandle`] if `param` is not valid.
/// - [`ErrorCode::CallFailed`] if the native layer returns a null
///   handle (an unexpected transport-level failure).
pub fn call(
    app_name: &str,
    param: &DataHandle,
    timeout_ms: u64,
) -> Result<DataHandle, Error> {
    let lib = lib()?;
    let c_name = cstr("framework::call", "app_name", app_name)?;
    let param_hnd = param
        .raw()
        .ok_or_else(|| Error::null_handle("framework::call: param"))?;

    // SAFETY: `c_name` is valid; `param_hnd` is live.
    let res = unsafe { (lib.lf_call)(c_name.as_ptr(), param_hnd, timeout_ms) };
    if res.is_null() {
        return Err(Error::call_failed(
            "framework::call",
            "native layer returned a null handle",
        ));
    }

    DataHandle::from_raw(res, true)
}

/// Like [`call`], but returns `Ok(None)` when the native layer produced
/// an empty (size-0) response.
///
/// This is the idiomatic Rust way to detect a timeout or unreachable
/// target. It mirrors the C++ `tryCall` helper and the C#
/// `Framework.TryCall` method.
///
/// # Ownership
///
/// When the function returns `Ok(Some(handle))`, the caller owns the
/// handle and must drop it. When it returns `Ok(None)`, the underlying
/// empty handle has already been released by this function.
///
/// # Errors
///
/// Same as [`call`], minus the [`ErrorCode::CallFailed`] case (a null
/// handle is still an error, not `None`).
pub fn try_call(
    app_name: &str,
    param: &DataHandle,
    timeout_ms: u64,
) -> Result<Option<DataHandle>, Error> {
    let response = call(app_name, param, timeout_ms)?;
    if response.size()? == 0 {
        return Ok(None);
    }
    Ok(Some(response))
}

/// Sends a one-way notification.
///
/// Delivery order is **not** guaranteed. Use [`sequenced_notify`] when
/// FIFO ordering is required for a given `(app_name, api_name)` pair.
///
/// The `param` handle is **not** consumed by this call.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `app_name` contains an interior
///   NUL.
/// - [`ErrorCode::NullHandle`] if `param` is not valid.
pub fn notify(app_name: &str, param: &DataHandle) -> Result<(), Error> {
    let lib = lib()?;
    let c_name = cstr("framework::notify", "app_name", app_name)?;
    let param_hnd = param
        .raw()
        .ok_or_else(|| Error::null_handle("framework::notify: param"))?;

    // SAFETY: `c_name` is valid; `param_hnd` is live.
    unsafe { (lib.lf_notify)(c_name.as_ptr(), param_hnd) };
    Ok(())
}

/// Sends a one-way notification with FIFO ordering guaranteed for the
/// same `(app_name, api_name)` pair.
///
/// Different pairs are independent and unordered with respect to each
/// other.
///
/// The `param` handle is **not** consumed by this call.
///
/// # Errors
///
/// Same as [`notify`].
pub fn sequenced_notify(
    app_name: &str,
    param: &DataHandle,
) -> Result<(), Error> {
    let lib = lib()?;
    let c_name = cstr("framework::sequenced_notify", "app_name", app_name)?;
    let param_hnd = param.raw().ok_or_else(|| {
        Error::null_handle("framework::sequenced_notify: param")
    })?;

    // SAFETY: `c_name` is valid; `param_hnd` is live.
    unsafe { (lib.lf_sequenced_notify)(c_name.as_ptr(), param_hnd) };
    Ok(())
}

// ============================================================================
// Shutdown
// ============================================================================

/// Gracefully terminates the framework, releasing all resources.
///
/// # Steps performed
///
/// 1. Clears the network-event callbacks.
/// 2. Stops all sequenced-notification threads.
/// 3. Frees all remaining data handles — **including any permanent
///    handle still alive**.
/// 4. Exits the simulated main thread.
/// 5. Clears the global application pool.
/// 6. Unloads the IPC library.
///
/// # After shutdown
///
/// - Every [`AppHandle`] still alive becomes invalid.
/// - The framework may be re-initialised by calling the preparation
///   functions again (`reset_prepare`, `prepare_service`,
///   `prepare_client`, `prepare_done`).
/// - The process-wide "started" flag is reset, so the next
///   [`prepare_done`] returns `Ok(true)` again.
///
/// Safe to call multiple times.
pub fn shutdown() {
    if let Ok(lib) = lib() {
        // SAFETY: zero-argument function.
        unsafe { (lib.lf_shutdown)() };
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

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
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn set_option_accepts_known_keys() {
        if !have_native() {
            return;
        }
        set_option("Quiet", "True").unwrap();
        set_option("ShowThreadID", "False").unwrap();
        set_option("Overlap_Connection", "True").unwrap();
        set_option("Wait_Connection_ReadyOk", "False").unwrap();
    }

    #[test]
    fn set_option_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        // The interior-NUL check happens before any native call, so
        // this test never touches the native framework and is safe to
        // run in parallel with everything else.
        let err = set_option("Quiet", "a\0b").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn check_main_thread_returns_bool() {
        if !have_native() {
            return;
        }
        // Read-only.
        let _ = check_main_thread().unwrap();
    }

    #[test]
    fn check_app_for_absent_name_is_false() {
        if !have_native() {
            return;
        }
        // Read-only.
        let _ = check_app("__definitely_absent_in_tests__").unwrap();
    }

    #[test]
    fn check_api_for_absent_pair_is_false() {
        if !have_native() {
            return;
        }
        // Read-only.
        let _ = check_api(
            "__definitely_absent_in_tests__",
            "__also_absent__",
        )
        .unwrap();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn reset_prepare_is_safe_without_framework() {
        if !have_native() {
            return;
        }
        reset_prepare();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn exit_main_thread_is_safe_without_framework() {
        if !have_native() {
            return;
        }
        exit_main_thread();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn shutdown_is_idempotent() {
        if !have_native() {
            return;
        }
        shutdown();
        shutdown();
    }

    #[test]
    fn get_app_name_rejects_disposed_handle() {
        if !have_native() {
            return;
        }
        // The disposed-handle check happens before any native call
        // (`app.raw()` is `None`), so this test never touches the
        // native framework.
        let mut app = match AppHandle::new("RustTestFrameworkDisposed", "") {
            Ok(a) => a,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        app.dispose();
        let err = get_app_name(&app).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn call_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        // Same pattern: the disposed-handle check short-circuits before
        // the native `LF_Call`.
        let mut param = match DataHandle::new("call_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = call("SomeApp", &param, 100).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn notify_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("notify_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = notify("SomeApp", &param).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn sequenced_notify_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("seq_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = sequenced_notify("SomeApp", &param).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }
}