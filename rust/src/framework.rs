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
//!   `sequenced_notify`, plus the UID- and P2PName-addressed families).
//! - Runtime options (`set_option`, `get_option`).
//! - Application name generation and query (`generate_app_name`,
//!   `get_app_name`).
//! - Health checks (`check_main_thread`, `check_app`, `check_api`, plus
//!   the UID- and P2PName-scoped variants).
//! - Process-wide shutdown (`shutdown`).
//!
//! Every function forwards to exactly one native export. No caching, no
//! state, no lifecycle coordination.
//!
//! # Three addressing schemes
//!
//! LingoFuse routes a request by one of three keys. The three families
//! are parallel and independent; each one has a synchronous and an
//! asynchronous variant, and each one is exposed here under a
//! consistent naming convention:
//!
//! | Scheme   | Key                            | Local-first? | Load-balanced? |
//! |----------|--------------------------------|:------------:|:--------------:|
//! | App name | UTF-8 string                   |      yes     |       no       |
//! | UID      | 32-byte session identifier     |      yes     |       no       |
//! | P2PName  | UTF-8 group name               |      no      |      yes       |
//!
//! - **App name** matches a registered application. A call goes to the
//!   process-local instance first if one exists; otherwise the mesh
//!   forwards it to one of the remote clients that hosts that app.
//!
//! - **UID** matches a specific client session. UID routing is
//!   *session-level*: the UID is regenerated on every reconnect. It can
//!   reach **any** API registered on the target - whether app-bound or
//!   process-wide P2P - without the caller knowing the target's App
//!   name. UID routing is also local-first.
//!
//! - **P2PName** matches a user-defined group of clients. Routing is
//!   **not** local-first: the call is always forwarded to the server,
//!   which owns the load-balancing state (Cycle_Anchor round-robin,
//!   with a FixedSequenced sticky-affinity window controlled by the
//!   `Fixed_Sequenced_Time` option).
//!
//! The naming convention in this module is:
//!
//! - App-name family: bare name, e.g. [`call`], [`notify`].
//! - UID family: `*_by_uid`, e.g. [`call_by_uid`], [`notify_by_uid`].
//! - P2PName family: `*_by_p2p_name`, e.g. [`call_by_p2p_name`],
//!   [`notify_by_p2p_name`].
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
//! returns `Ok(None)` for a size-0 response. The same contract applies
//! to [`call_by_uid`] / [`try_call_by_uid`] and [`call_by_p2p_name`] /
//! [`try_call_by_p2p_name`].
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
use crate::sys::{self, AppHnd, LfP2PUid, NativeLibrary};
use crate::uid::Uid;

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
    // app-name functions, `LF_GetOption`, and the P2P identity
    // accessors).
    let cs = unsafe { CStr::from_ptr(ptr) };
    cs.to_string_lossy().into_owned()
}

/// Bridges the crate's safe [`Uid`] newtype into the raw
/// [`LfP2PUid`] ABI struct.
///
/// The two types have identical 32-byte layouts; this helper exists so
/// that the rest of this module does not need to touch `LfP2PUid`'s
/// `bytes` field directly. A future revision may move this into
/// `uid.rs` as a public `Uid::to_lf()` method; until then it stays
/// private to `framework`.
#[inline]
fn uid_to_lf(uid: Uid) -> LfP2PUid {
    LfP2PUid { bytes: uid.to_bytes() }
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
/// outstanding handle - including handles created with
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

/// Reads a global runtime option.
///
/// # Return value
///
/// The option value as an owned `String`. The native pointer is valid
/// for only about 5 seconds; this function copies it immediately, so
/// the returned value is safe to hold indefinitely.
///
/// # Unknown options
///
/// Unknown option names return an empty string. The native layer
/// performs no validation, so a caller that needs to distinguish "unset
/// from known option" must inspect the result. Boolean options are
/// returned as the strings `"True"` / `"False"`.
///
/// # Write-only options
///
/// A few options (for example `debug`) are write-only; their getter
/// returns a fixed placeholder string rather than a stored value. See
/// the C header for the exact list.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `option` contains an interior
///   NUL.
pub fn get_option(option: &str) -> Result<String, Error> {
    let lib = lib()?;
    let c_opt = cstr("framework::get_option", "option", option)?;

    // SAFETY: `c_opt` is a valid UTF-8, NUL-terminated string. The
    // returned pointer targets a transient buffer released about 5
    // seconds after this call; we copy it immediately.
    let ptr = unsafe { (lib.lf_get_option)(c_opt.as_ptr()) };
    // SAFETY: forwarded to `copy_cstr`; the pointer is either null or a
    // NUL-terminated UTF-8 string valid for the duration of the call.
    Ok(unsafe { copy_cstr(ptr) })
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

/// Returns `true` when a client with the given UID is registered.
///
/// # Cache semantics
///
/// Same as [`check_app`]: the answer is backed by a broadcast-updated
/// cache with approximately 3 seconds of propagation delay.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
pub fn check_uid(uid: Uid) -> Result<bool, Error> {
    let lib = lib()?;
    let lf_uid = uid_to_lf(uid);
    // SAFETY: `LfP2PUid` is a `#[repr(C)]` 32-byte struct passed by
    // value, matching the Pascal `array[0..31] of Byte` convention.
    Ok(unsafe { (lib.lf_check_uid)(lf_uid) != 0 })
}

/// Returns `true` when a client with the given UID exposes the named
/// API.
///
/// Same cache semantics as [`check_app`].
///
/// # Errors
///
/// Same as [`check_uid`], plus [`ErrorCode::InvalidArgument`] if
/// `api_name` contains an interior NUL.
pub fn check_uid_api(uid: Uid, api_name: &str) -> Result<bool, Error> {
    let lib = lib()?;
    let c_api = cstr("framework::check_uid_api", "api_name", api_name)?;
    let lf_uid = uid_to_lf(uid);
    // SAFETY: `lf_uid` is a valid argument-role struct; `c_api` is a
    // valid UTF-8, NUL-terminated string.
    Ok(unsafe { (lib.lf_check_uid_api)(lf_uid, c_api.as_ptr()) != 0 })
}

/// Returns `true` when a client with the given P2P group name is
/// registered.
///
/// Same cache semantics as [`check_app`].
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `p2p_name` contains an interior
///   NUL.
pub fn check_p2p_name(p2p_name: &str) -> Result<bool, Error> {
    let lib = lib()?;
    let c_name = cstr("framework::check_p2p_name", "p2p_name", p2p_name)?;
    // SAFETY: valid UTF-8, NUL-terminated string.
    Ok(unsafe { (lib.lf_check_p2pname)(c_name.as_ptr()) != 0 })
}

/// Returns `true` when a client in the given P2P group exposes the
/// named API.
///
/// Same cache semantics as [`check_app`].
///
/// # Errors
///
/// Same as [`check_p2p_name`], plus [`ErrorCode::InvalidArgument`] if
/// `api_name` contains an interior NUL.
pub fn check_p2p_name_api(
    p2p_name: &str,
    api_name: &str,
) -> Result<bool, Error> {
    let lib = lib()?;
    let c_name = cstr("framework::check_p2p_name_api", "p2p_name", p2p_name)?;
    let c_api = cstr("framework::check_p2p_name_api", "api_name", api_name)?;
    // SAFETY: both strings are valid UTF-8, NUL-terminated.
    Ok(unsafe {
        (lib.lf_check_p2pname_api)(c_name.as_ptr(), c_api.as_ptr()) != 0
    })
}

// ============================================================================
// Remote invocation - App-name addressing
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
// Remote invocation - UID addressing
// ============================================================================
//
// UID addressing routes to the exact client whose tunnel established the
// given 32-byte session identifier. It is session-level: the UID is
// regenerated on every reconnect, so a caller that caches a UID MUST
// re-probe it after a link loss.
//
// UID routing is LOCAL-FIRST, matching App-name routing. A UID can
// address any API registered on the target - whether app-bound or
// process-wide P2P - without the caller knowing the target's App name.
//
// A null UID is a valid argument: it simply matches no client, and the
// synchronous `call` family returns a size-0 handle. The function does
// not reject it.

/// Performs a synchronous remote call addressed by session UID.
///
/// Same timeout and ownership contract as [`call`]. See [`try_call_by_uid`]
/// for the `Option`-based variant.
///
/// # Errors
///
/// Same as [`call`], minus the `app_name` validation (there is no App
/// name argument).
pub fn call_by_uid(
    uid: Uid,
    param: &DataHandle,
    timeout_ms: u64,
) -> Result<DataHandle, Error> {
    let lib = lib()?;
    let param_hnd = param
        .raw()
        .ok_or_else(|| Error::null_handle("framework::call_by_uid: param"))?;
    let lf_uid = uid_to_lf(uid);

    // SAFETY: `lf_uid` is a valid argument-role struct; `param_hnd` is
    // live.
    let res = unsafe { (lib.lf_uid_call)(lf_uid, param_hnd, timeout_ms) };
    if res.is_null() {
        return Err(Error::call_failed(
            "framework::call_by_uid",
            "native layer returned a null handle",
        ));
    }

    DataHandle::from_raw(res, true)
}

/// Like [`call_by_uid`], but returns `Ok(None)` for a size-0 response.
///
/// # Errors
///
/// Same as [`call_by_uid`].
pub fn try_call_by_uid(
    uid: Uid,
    param: &DataHandle,
    timeout_ms: u64,
) -> Result<Option<DataHandle>, Error> {
    let response = call_by_uid(uid, param, timeout_ms)?;
    if response.size()? == 0 {
        return Ok(None);
    }
    Ok(Some(response))
}

/// Sends a one-way notification addressed by session UID.
///
/// Delivery order is **not** guaranteed. Use
/// [`sequenced_notify_by_uid`] when FIFO ordering is required.
///
/// # Errors
///
/// Same as [`notify`], minus the App-name validation.
pub fn notify_by_uid(uid: Uid, param: &DataHandle) -> Result<(), Error> {
    let lib = lib()?;
    let param_hnd = param
        .raw()
        .ok_or_else(|| Error::null_handle("framework::notify_by_uid: param"))?;
    let lf_uid = uid_to_lf(uid);

    // SAFETY: `lf_uid` is a valid argument-role struct; `param_hnd` is
    // live.
    unsafe { (lib.lf_uid_notify)(lf_uid, param_hnd) };
    Ok(())
}

/// Sends a FIFO-ordered one-way notification addressed by session UID.
///
/// FIFO ordering is guaranteed only for the same `(uid, api_name)`
/// pair. Different pairs are independent.
///
/// # Errors
///
/// Same as [`notify_by_uid`].
pub fn sequenced_notify_by_uid(
    uid: Uid,
    param: &DataHandle,
) -> Result<(), Error> {
    let lib = lib()?;
    let param_hnd = param.raw().ok_or_else(|| {
        Error::null_handle("framework::sequenced_notify_by_uid: param")
    })?;
    let lf_uid = uid_to_lf(uid);

    // SAFETY: `lf_uid` is a valid argument-role struct; `param_hnd` is
    // live.
    unsafe { (lib.lf_uid_sequenced_notify)(lf_uid, param_hnd) };
    Ok(())
}

// ============================================================================
// Remote invocation - P2PName addressing
// ============================================================================
//
// P2PName addressing routes to any client in a user-defined group. It is
// NOT local-first: the call is always forwarded to the server, which
// owns the load-balancing state.
//
// Target selection on the server uses one of two strategies:
//
// - Load balancing (Cycle_Anchor): the target with the smallest anchor
//   value is chosen, then its anchor is advanced.
// - Sticky affinity (FixedSequenced), governed by the
//   `Fixed_Sequenced_Time` runtime option (default 20 seconds).

/// Performs a synchronous remote call addressed by P2P group name.
///
/// Same timeout and ownership contract as [`call`]. See
/// [`try_call_by_p2p_name`] for the `Option`-based variant.
///
/// # Errors
///
/// Same as [`call`], with `p2p_name` in place of `app_name`.
pub fn call_by_p2p_name(
    p2p_name: &str,
    param: &DataHandle,
    timeout_ms: u64,
) -> Result<DataHandle, Error> {
    let lib = lib()?;
    let c_name = cstr("framework::call_by_p2p_name", "p2p_name", p2p_name)?;
    let param_hnd = param.raw().ok_or_else(|| {
        Error::null_handle("framework::call_by_p2p_name: param")
    })?;

    // SAFETY: `c_name` is valid; `param_hnd` is live.
    let res =
        unsafe { (lib.lf_p2pname_call)(c_name.as_ptr(), param_hnd, timeout_ms) };
    if res.is_null() {
        return Err(Error::call_failed(
            "framework::call_by_p2p_name",
            "native layer returned a null handle",
        ));
    }

    DataHandle::from_raw(res, true)
}

/// Like [`call_by_p2p_name`], but returns `Ok(None)` for a size-0
/// response.
///
/// # Errors
///
/// Same as [`call_by_p2p_name`].
pub fn try_call_by_p2p_name(
    p2p_name: &str,
    param: &DataHandle,
    timeout_ms: u64,
) -> Result<Option<DataHandle>, Error> {
    let response = call_by_p2p_name(p2p_name, param, timeout_ms)?;
    if response.size()? == 0 {
        return Ok(None);
    }
    Ok(Some(response))
}

/// Sends a one-way notification addressed by P2P group name.
///
/// Delivery order is **not** guaranteed. Use
/// [`sequenced_notify_by_p2p_name`] when FIFO ordering is required.
///
/// # Errors
///
/// Same as [`notify`], with `p2p_name` in place of `app_name`.
pub fn notify_by_p2p_name(
    p2p_name: &str,
    param: &DataHandle,
) -> Result<(), Error> {
    let lib = lib()?;
    let c_name = cstr("framework::notify_by_p2p_name", "p2p_name", p2p_name)?;
    let param_hnd = param.raw().ok_or_else(|| {
        Error::null_handle("framework::notify_by_p2p_name: param")
    })?;

    // SAFETY: `c_name` is valid; `param_hnd` is live.
    unsafe { (lib.lf_p2pname_notify)(c_name.as_ptr(), param_hnd) };
    Ok(())
}

/// Sends a FIFO-ordered one-way notification addressed by P2P group
/// name.
///
/// FIFO ordering is guaranteed only for the same `(p2p_name, api_name)`
/// pair. Different pairs are independent.
///
/// # Errors
///
/// Same as [`notify_by_p2p_name`].
pub fn sequenced_notify_by_p2p_name(
    p2p_name: &str,
    param: &DataHandle,
) -> Result<(), Error> {
    let lib = lib()?;
    let c_name = cstr(
        "framework::sequenced_notify_by_p2p_name",
        "p2p_name",
        p2p_name,
    )?;
    let param_hnd = param.raw().ok_or_else(|| {
        Error::null_handle("framework::sequenced_notify_by_p2p_name: param")
    })?;

    // SAFETY: `c_name` is valid; `param_hnd` is live.
    unsafe { (lib.lf_p2pname_sequenced_notify)(c_name.as_ptr(), param_hnd) };
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
/// 3. Frees all remaining data handles - **including any permanent
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

    // -----------------------------------------------------------------
    // Existing tests (unchanged)
    // -----------------------------------------------------------------

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

    // -----------------------------------------------------------------
    // New: options
    // -----------------------------------------------------------------

    #[test]
    fn get_option_returns_string() {
        if !have_native() {
            return;
        }
        // Read-only against the process-global option store. The key
        // is guaranteed to exist and to have a stable string form.
        let s = get_option("Quiet").unwrap();
        // Accept either "True" or "False"; the getter returns one of
        // them for a boolean option. Anything else would indicate a
        // version mismatch.
        assert!(
            s == "True" || s == "False",
            "unexpected Quiet option value: {:?}",
            s
        );
    }

    #[test]
    fn get_option_unknown_key_returns_empty_string() {
        if !have_native() {
            return;
        }
        // The native layer treats unknown keys as empty strings; it
        // does not error.
        let s = get_option("__definitely_absent_option__").unwrap();
        assert!(s.is_empty(), "unexpected non-empty value: {:?}", s);
    }

    #[test]
    fn get_option_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        let err = get_option("Quiet\0bad").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    // -----------------------------------------------------------------
    // New: UID and P2PName health checks (read-only)
    // -----------------------------------------------------------------

    #[test]
    fn check_uid_for_null_uid_is_false() {
        if !have_native() {
            return;
        }
        // The null UID can never match a registered client.
        let present = check_uid(Uid::NULL).unwrap();
        assert!(!present, "null UID must not be present");
    }

    #[test]
    fn check_uid_api_for_null_uid_is_false() {
        if !have_native() {
            return;
        }
        let present = check_uid_api(Uid::NULL, "some_api").unwrap();
        assert!(!present, "null UID must not expose any API");
    }

    #[test]
    fn check_p2p_name_for_absent_group_is_false() {
        if !have_native() {
            return;
        }
        let present =
            check_p2p_name("__definitely_absent_group_in_tests__").unwrap();
        assert!(!present, "absent P2P group must not be present");
    }

    #[test]
    fn check_p2p_name_api_for_absent_group_is_false() {
        if !have_native() {
            return;
        }
        let present = check_p2p_name_api(
            "__definitely_absent_group_in_tests__",
            "__also_absent__",
        )
        .unwrap();
        assert!(!present, "absent P2P group must not expose any API");
    }

    #[test]
    fn check_uid_api_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        let err = check_uid_api(Uid::NULL, "bad\0name").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn check_p2p_name_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        let err = check_p2p_name("bad\0name").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    // -----------------------------------------------------------------
    // New: UID and P2PName invocation guards (disposed-param short-circuit)
    // -----------------------------------------------------------------

    #[test]
    fn call_by_uid_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("uid_call_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = call_by_uid(Uid::NULL, &param, 100).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn notify_by_uid_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("uid_notify_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = notify_by_uid(Uid::NULL, &param).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn sequenced_notify_by_uid_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("uid_seq_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = sequenced_notify_by_uid(Uid::NULL, &param).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn call_by_p2p_name_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("p2p_call_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = call_by_p2p_name("any_group", &param, 100).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn notify_by_p2p_name_with_disposed_param_fails_cleanly() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("p2p_notify_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = notify_by_p2p_name("any_group", &param).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn call_by_p2p_name_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("p2p_nul_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        // The NUL check runs before any native call, so this test is
        // safe under the parallel harness.
        let err = call_by_p2p_name("bad\0group", &param, 100).unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
        // Keep `param` alive until after the assertion; silence an
        // unused-variable warning without affecting behaviour.
        let _ = param.set_position(0);
    }

    // -----------------------------------------------------------------
    // uid_to_lf bridge
    // -----------------------------------------------------------------

    #[test]
    fn uid_to_lf_preserves_bytes_and_nulls() {
        // Pure-data test; does not require the native library.
        let uid = Uid::from_hex(
            "0123456789abcdef0123456789abcdef\
             0123456789abcdef0123456789abcdef",
        )
        .unwrap();
        let lf = uid_to_lf(uid);
        assert_eq!(lf.bytes, uid.to_bytes());

        let null_lf = uid_to_lf(Uid::NULL);
        assert!(null_lf.is_null());
    }
}