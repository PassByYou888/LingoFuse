//! Modern asynchronous invocation with closures.
//!
//! This module is the Rust counterpart of the C ABI's `LF_Async_*`
//! family, and the analogue of the C++ `lingofuse::callAsync` family.
//! It hides the raw function-pointer + `void*` plumbing behind a
//! Rust-idiomatic closure API so that asynchronous code does not feel
//! different from the rest of the crate.
//!
//! # Four entry points, two styles
//!
//! Every addressing scheme (App name, UID, P2PName) has two entry
//! points:
//!
//! | Style       | App name                  | UID                            | P2PName                                |
//! |-------------|---------------------------|--------------------------------|----------------------------------------|
//! | Callback    | [`call_async`]            | [`call_async_by_uid`]          | [`call_async_by_p2p_name`]             |
//! | Blocking    | [`call_async_wait`]       | [`call_async_wait_by_uid`]     | [`call_async_wait_by_p2p_name`]        |
//!
//! Plus [`call_async_sequenced`] for the FIFO-ordered asynchronous
//! variant of the App-name family.
//!
//! ## Callback style
//!
//! [`call_async`] and its siblings return immediately. The user closure
//! runs on a native `TCompute` worker thread when the response arrives,
//! or synchronously on the caller's thread if the native layer rejects
//! the request before dispatching it (see "Single error path" below).
//!
//! ```no_run
//! use lingofuse::{async_call, io};
//! use lingofuse::data_handle::DataHandle;
//!
//! # fn main() -> Result<(), lingofuse::error::Error> {
//! # let mut req = DataHandle::new("add")?;
//! async_call::call_async("Calculator", &req, move |result| {
//!     match result {
//!         Ok(mut resp) => {
//!             if let Ok(v) = io::read_json::<serde_json::Value>(&mut resp) {
//!                 println!("result: {}", v);
//!             }
//!         }
//!         Err(e) => eprintln!("async failed: {}", e),
//!     }
//! })?;
//! # Ok(()) }
//! ```
//!
//! ## Blocking style
//!
//! [`call_async_wait`] returns only after the callback has fired (or
//! the timeout expires). This is the closest asynchronous analogue of
//! the synchronous [`crate::framework::call`]. Unlike `framework::call`,
//! however, it returns a **plain byte vector**, not a [`DataHandle`]:
//!
//! ```no_run
//! use std::time::Duration;
//! use lingofuse::{async_call, io};
//! use lingofuse::data_handle::DataHandle;
//!
//! # fn main() -> Result<(), lingofuse::error::Error> {
//! # let mut req = DataHandle::new("add")?;
//! let bytes = async_call::call_async_wait(
//!     "Calculator", &req, Some(Duration::from_secs(5)),
//! )?;
//! let v: serde_json::Value = io::loads_json(&String::from_utf8_lossy(&bytes))?;
//! # Ok(()) }
//! ```
//!
//! # Why `call_async_wait` returns `Vec<u8>`, not `DataHandle`
//!
//! The asynchronous family hands the caller a **framework-owned**
//! result handle that is released the instant the callback returns.
//! Any `DataHandle` borrowed from that handle would be dangling the
//! moment the callback body ends. To hand the response to the waiting
//! thread safely, [`call_async_wait`] must **copy the bytes** out
//! inside the callback and deliver the copy.
//!
//! A new `DataHandle` cannot be constructed on the waiting side,
//! because the crate has no way to know the API name that the framework
//! originally bound to the result. The only two lossless options are
//! therefore "return raw bytes" (what this module does) or "return a
//! typed value" (which would require the caller to supply a
//! deserialisation target). The former keeps the API surface minimal;
//! callers that want a typed value can decode the bytes with
//! [`crate::io::loads_json`] or any other tool.
//!
//! # Single error path
//!
//! If the native layer refuses to dispatch the request (`LF_Async_Call`
//! returns 0), the framework will never invoke the callback. The
//! wrapper handles this by:
//!
//! 1. Invoking the user closure **synchronously, on the caller's
//!    thread**, with `Err(Error)`.
//! 2. Returning the same failure as `Err` from the entry point.
//!
//! This gives the caller a single, unified error path:
//!
//! - Use `?` on the return value for the synchronous dispatch error.
//! - Use `match result` inside the closure for the asynchronous
//!   transport error.
//!
//! Both surface the same `ErrorCode::CallFailed` for the "not
//! dispatched" case, so a caller that only cares about success/failure
//! can rely on either.
//!
//! # No timeout, no cancellation
//!
//! The underlying C ABI family has no timeout parameter and no
//! cancellation handle. The callback style therefore has no timeout
//! either. The blocking style accepts an optional timeout, but that
//! timeout is implemented **on the Rust side**: after it expires,
//! [`call_async_wait`] returns `Err(ErrorCode::Timeout)` and abandons
//! the callback. The native request is **not** cancelled; it may still
//! complete and fire a callback that finds a closed channel.
//!
//! # Threading
//!
//! The callback may run on:
//!
//! - a native `TCompute` worker thread, on the success path; or
//! - the caller's own thread, on the dispatch-failure path.
//!
//! Both cases are documented in the closure contract below.
//!
//! # Callback contract
//!
//! Inside the closure:
//!
//! | Do | Do not |
//! |----|--------|
//! | Read or copy the result | Block (sleep, network I/O, lock waits) |
//! | Post to your own thread-safe queue | Call [`crate::framework::call`] / `notify` / `local_call` / `prepare_done` / `shutdown` |
//! | Log / increment atomics | Touch UI components |
//! | Return promptly | Retain the borrowed `DataHandle` past the callback body |
//! |  | Call `LF_FreeData` on it |
//!
//! The wrapper catches any panic raised by the closure (see
//! [`std::panic::catch_unwind`]) and converts it to a stderr message,
//! so a misbehaving callback cannot corrupt the FFI boundary.
//!
//! # Sequencing
//!
//! [`call_async_sequenced`] guarantees FIFO order per `(app, api)`
//! pair. It uses the same callback contract as [`call_async`].

use std::ffi::{c_void, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::mpsc;
use std::time::Duration;

use crate::data_handle::DataHandle;
use crate::error::{Error, ErrorCode};
use crate::sys::{self, DataHnd, LfP2PUid, NativeLibrary};
use crate::uid::Uid;

// ============================================================================
// The user callback type
// ============================================================================

/// The closure type accepted by every asynchronous entry point.
///
/// The closure takes a single argument, `Result<DataHandle, Error>`:
///
/// - `Ok(handle)`: the framework delivered a response. The handle is
///   **borrowed**; it is valid only inside the closure body.
/// - `Err(e)`: the transport layer reported a failure, or the dispatch
///   was rejected (in which case the closure is invoked synchronously
///   on the caller's thread).
///
/// # `Send + 'static` bounds
///
/// - `Send` is required because the closure runs on a native worker
///   thread.
/// - `'static` is required because the framework stores the closure
///   beyond the current stack frame.
///
/// These are exactly the bounds on [`std::thread::spawn`]'s closure.
pub type AsyncCallback = Box<
    dyn FnOnce(Result<DataHandle, Error>) + Send + 'static
>;

// ============================================================================
// Internal context
// ============================================================================

/// Heap-allocated context carried across the FFI boundary as `void*`.
///
/// The `Option` around the callback is what makes the "dispatch failure
/// invokes the callback synchronously" path possible: the same box can
/// be handed to the trampoline (which `take`s the closure) or reclaimed
/// by `submit_async` (which also `take`s it). The two paths are
/// mutually exclusive and cannot both consume the closure.
struct AsyncContext {
    callback: Option<AsyncCallback>,
}

// ============================================================================
// Trampoline
// ============================================================================

/// The single `extern "C"` function the native layer invokes for every
/// asynchronous result.
///
/// # Safety
///
/// - `data` must be a pointer produced by `Box::into_raw` on an
///   [`AsyncContext`], or null.
/// - `result` must be a valid `DataHnd` for the duration of the
///   callback, as documented by the native library.
///
/// The wrapper guarantees both preconditions: `submit_async` is the
/// only producer of `data`, and the native layer is the only producer
/// of `result`.
unsafe extern "C" fn async_trampoline(data: *mut c_void, result: DataHnd) {
    if data.is_null() {
        return;
    }

    // SAFETY: `data` was produced by `Box::into_raw` in `submit_async`,
    // and the native layer is the only consumer. Taking ownership back
    // here is the contract.
    let mut ctx: Box<AsyncContext> = unsafe { Box::from_raw(data as *mut AsyncContext) };

    let callback = match ctx.callback.take() {
        Some(cb) => cb,
        None => {
            // A second invocation of the same context would be a bug
            // in the native layer; drop the box silently and return.
            return;
        }
    };

    // Build a **borrowed** DataHandle over the framework-owned result.
    // `owned = false` ensures the wrapper's Drop is a no-op.
    let handle = DataHandle::from_raw(result, false);

    // Catch every panic so it cannot cross the FFI boundary. A caught
    // panic still aborts the current callback, but the process stays
    // alive and the native library remains in a consistent state.
    let _ = catch_unwind(AssertUnwindSafe(|| match handle {
        Ok(h) => callback(Ok(h)),
        Err(e) => callback(Err(e)),
    }));

    // `ctx` is dropped here, after the callback has been consumed.
}

// ============================================================================
// Shared submission helper
// ============================================================================

/// Submits an asynchronous request and manages the [`AsyncContext`]
/// lifetime.
///
/// `issue` is the C-ABI call itself, parameterised on the opaque data
/// pointer. It is invoked **exactly once**, synchronously, from this
/// function.
///
/// # Error semantics
///
/// If `issue` returns `1`, the native layer has accepted the request
/// and will (eventually) invoke the trampoline. Ownership of the
/// context has passed to the framework.
///
/// If `issue` returns anything else, the native layer has rejected the
/// request. In that case:
///
/// 1. The context is reclaimed from the native side.
/// 2. The user closure is invoked synchronously, on the caller's
///    thread, with `Err(ErrorCode::CallFailed)`.
/// 3. `submit_async` itself returns `Err(ErrorCode::CallFailed)`.
///
/// The three steps are not redundant: the callback invocation lets
/// callers that use the fire-and-forget style observe the failure in
/// the same `match` they use for transport errors, and the returned
/// `Err` lets callers that use the `?` operator propagate the failure
/// directly.
fn submit_async<F, I>(
    issue: I,
    callback: F,
) -> Result<(), Error>
where
    F: FnOnce(Result<DataHandle, Error>) + Send + 'static,
    I: FnOnce(*mut c_void) -> i32,
{
    // Fail fast if the native library is not available, so that no
    // heap allocation is made for a request that cannot possibly be
    // dispatched.
    let _ = sys::get_library().map_err(Error::from_load)?;

    // Box the context. From this point on, `data` is the unique
    // pointer to it.
    let ctx = Box::new(AsyncContext {
        callback: Some(Box::new(callback)),
    });
    let data = Box::into_raw(ctx) as *mut c_void;

    // Invoke the C ABI call. `issue` is a plain `FnOnce` so it cannot
    // be resumed; the single call is the whole dispatch.
    let ret = issue(data);

    if ret != 1 {
        // SAFETY: `data` was produced by `Box::into_raw` above. The
        // native layer rejected the request (return code != 1), so it
        // did not store the pointer; we own it again.
        let mut ctx = unsafe { Box::from_raw(data as *mut AsyncContext) };

        if let Some(cb) = ctx.callback.take() {
            // Dispatch failure: give the callback the same information
            // the caller will see via the `Err` return, so both
            // observation points are consistent.
            //
            // The callback is invoked on the CALLER's thread, in the
            // same call frame as `submit_async`. This matches the
            // documented "single error path" semantics.
            let _ = catch_unwind(AssertUnwindSafe(|| {
                cb(Err(Error::new(
                    ErrorCode::CallFailed,
                    "async call was not dispatched (native layer returned 0)",
                )));
            }));
        }

        return Err(Error::new(
            ErrorCode::CallFailed,
            "async call was not dispatched (native layer returned 0)",
        ));
    }

    // Success: the framework owns the context and will invoke the
    // trampoline later.
    Ok(())
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Resolves the native library and builds a `CString` for a single
/// string argument.
fn prepare_call<'a>(
    op: &str,
    field: &str,
    name: &'a str,
    param: &DataHandle,
) -> Result<(&'static NativeLibrary, CString, DataHnd), Error> {
    let lib = sys::get_library().map_err(Error::from_load)?;
    let c_name = CString::new(name).map_err(|_| {
        Error::invalid_argument(op, format!("{} contains an interior NUL", field))
    })?;
    let param_hnd = param
        .raw()
        .ok_or_else(|| Error::null_handle(&format!("{}: param", op)))?;
    Ok((lib, c_name, param_hnd))
}

/// Bridges the crate's safe [`Uid`] newtype into the raw ABI struct.
#[inline]
fn uid_to_lf(uid: Uid) -> LfP2PUid {
    LfP2PUid { bytes: uid.to_bytes() }
}

// ============================================================================
// Public API - callback style
// ============================================================================

/// Issues an asynchronous Call by App name.
///
/// The request is dispatched immediately. When the response arrives,
/// `callback` runs on a native worker thread with a borrowed
/// [`DataHandle`].
///
/// # Dispatch failure
///
/// If the native layer rejects the request, the callback runs
/// **synchronously on the caller's thread** with `Err(Error)`, and this
/// function returns `Err(Error)` as well. See the module documentation
/// for the rationale.
///
/// # Ownership
///
/// The framework copies `param`'s payload synchronously inside the call,
/// so the `DataHandle` may be dropped the moment this function returns.
///
/// # Errors
///
/// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
///   available.
/// - [`ErrorCode::InvalidArgument`] if `app_name` contains an interior
///   NUL.
/// - [`ErrorCode::NullHandle`] if `param` is not valid.
/// - [`ErrorCode::CallFailed`] if the native layer rejected the
///   request.
pub fn call_async<F>(
    app_name: &str,
    param: &DataHandle,
    callback: F,
) -> Result<(), Error>
where
    F: FnOnce(Result<DataHandle, Error>) + Send + 'static,
{
    let (lib, c_name, param_hnd) =
        prepare_call("async_call::call_async", "app_name", app_name, param)?;

    // The C string lives on `call_async`'s stack and is captured by
    // reference in the `issue` closure. `submit_async` invokes `issue`
    // synchronously and returns before `c_name` goes out of scope, so
    // the borrow is sound.
    submit_async(
        move |data| {
            // SAFETY: `c_name` is a valid UTF-8, NUL-terminated
            // string; `param_hnd` is a live handle; `data` is the
            // pointer produced by `submit_async`; `async_trampoline`
            // matches the `LfAsyncCallOnResult` signature exactly.
            unsafe {
                (lib.lf_async_call)(
                    c_name.as_ptr(),
                    param_hnd,
                    data,
                    async_trampoline,
                )
            }
        },
        callback,
    )
}

/// Issues an asynchronous Call by App name, with FIFO ordering per
/// `(app, api)` pair.
///
/// Same callback and ownership contract as [`call_async`].
pub fn call_async_sequenced<F>(
    app_name: &str,
    param: &DataHandle,
    callback: F,
) -> Result<(), Error>
where
    F: FnOnce(Result<DataHandle, Error>) + Send + 'static,
{
    let (lib, c_name, param_hnd) = prepare_call(
        "async_call::call_async_sequenced",
        "app_name",
        app_name,
        param,
    )?;

    submit_async(
        move |data| {
            // SAFETY: as in `call_async`.
            unsafe {
                (lib.lf_async_sequenced_call)(
                    c_name.as_ptr(),
                    param_hnd,
                    data,
                    async_trampoline,
                )
            }
        },
        callback,
    )
}

/// Issues an asynchronous Call addressed by session UID.
///
/// Same callback and ownership contract as [`call_async`].
pub fn call_async_by_uid<F>(
    uid: Uid,
    param: &DataHandle,
    callback: F,
) -> Result<(), Error>
where
    F: FnOnce(Result<DataHandle, Error>) + Send + 'static,
{
    let lib = sys::get_library().map_err(Error::from_load)?;
    let param_hnd = param
        .raw()
        .ok_or_else(|| Error::null_handle("async_call::call_async_by_uid: param"))?;
    let lf_uid = uid_to_lf(uid);

    submit_async(
        move |data| {
            // SAFETY: `lf_uid` is an argument-role `LfP2PUid` passed
            // by value; `param_hnd` is live; `data` is the pointer
            // produced by `submit_async`.
            unsafe {
                (lib.lf_uid_async_call)(
                    lf_uid,
                    param_hnd,
                    data,
                    async_trampoline,
                )
            }
        },
        callback,
    )
}

/// Issues an asynchronous Call addressed by P2P group name.
///
/// Same callback and ownership contract as [`call_async`]. Note that
/// P2PName routing is **not** local-first: the server always owns the
/// load-balancing decision.
pub fn call_async_by_p2p_name<F>(
    p2p_name: &str,
    param: &DataHandle,
    callback: F,
) -> Result<(), Error>
where
    F: FnOnce(Result<DataHandle, Error>) + Send + 'static,
{
    let (lib, c_name, param_hnd) = prepare_call(
        "async_call::call_async_by_p2p_name",
        "p2p_name",
        p2p_name,
        param,
    )?;

    submit_async(
        move |data| {
            // SAFETY: as in `call_async`.
            unsafe {
                (lib.lf_p2pname_async_call)(
                    c_name.as_ptr(),
                    param_hnd,
                    data,
                    async_trampoline,
                )
            }
        },
        callback,
    )
}

// ============================================================================
// Public API - blocking style
// ============================================================================

/// Issues an asynchronous Call by App name and blocks until the response
/// arrives, the optional timeout expires, or the dispatch fails.
///
/// # Return value
///
/// The response payload as a fresh `Vec<u8>`, copied out of the
/// framework-owned result handle inside the callback. See the module
/// documentation for why the return type is bytes rather than a
/// [`DataHandle`].
///
/// # Timeout semantics
///
/// The timeout is implemented **on the Rust side**. When it expires,
/// this function returns `Err(ErrorCode::Timeout)` and abandons the
/// callback. The native request is **not** cancelled: it may still
/// complete later, and the abandoned callback will find a closed
/// channel. That is harmless; the closure ignores the send error.
///
/// Passing `None` waits indefinitely (bounded only by the native
/// layer's own behaviour).
///
/// # Blocking warning
///
/// Do **not** call this function from inside a registered callback.
/// The callback runs on a native worker thread that the synchronous
/// dispatch path may need, and blocking it can deadlock. This is the
/// same restriction as for [`crate::framework::call`].
///
/// # Errors
///
/// - Same synchronous validation errors as [`call_async`].
/// - [`ErrorCode::CallFailed`] if the native layer rejected the
///   request, or if the callback channel disconnected without a value.
/// - [`ErrorCode::Timeout`] if the timeout expired before a result
///   arrived.
pub fn call_async_wait(
    app_name: &str,
    param: &DataHandle,
    timeout: Option<Duration>,
) -> Result<Vec<u8>, Error> {
    let (tx, rx) = mpsc::sync_channel::<Result<Vec<u8>, Error>>(1);

    call_async(app_name, param, move |result| {
        let payload = result.and_then(extract_payload);
        // A send failure means the receiver has already given up
        // (timeout, or the dispatch error path). Either way the data
        // is simply discarded.
        let _ = tx.send(payload);
    })?;

    recv_with_timeout(rx, timeout, "async_call::call_async_wait")
}

/// Issues an asynchronous Call addressed by session UID and blocks until
/// the response arrives, the optional timeout expires, or the dispatch
/// fails.
///
/// Same contract as [`call_async_wait`].
pub fn call_async_wait_by_uid(
    uid: Uid,
    param: &DataHandle,
    timeout: Option<Duration>,
) -> Result<Vec<u8>, Error> {
    let (tx, rx) = mpsc::sync_channel::<Result<Vec<u8>, Error>>(1);

    call_async_by_uid(uid, param, move |result| {
        let payload = result.and_then(extract_payload);
        let _ = tx.send(payload);
    })?;

    recv_with_timeout(rx, timeout, "async_call::call_async_wait_by_uid")
}

/// Issues an asynchronous Call addressed by P2P group name and blocks
/// until the response arrives, the optional timeout expires, or the
/// dispatch fails.
///
/// Same contract as [`call_async_wait`].
pub fn call_async_wait_by_p2p_name(
    p2p_name: &str,
    param: &DataHandle,
    timeout: Option<Duration>,
) -> Result<Vec<u8>, Error> {
    let (tx, rx) = mpsc::sync_channel::<Result<Vec<u8>, Error>>(1);

    call_async_by_p2p_name(p2p_name, param, move |result| {
        let payload = result.and_then(extract_payload);
        let _ = tx.send(payload);
    })?;

    recv_with_timeout(rx, timeout, "async_call::call_async_wait_by_p2p_name")
}

// ============================================================================
// Internal helpers for the blocking style
// ============================================================================

/// Copies the payload of a borrowed result handle into a fresh
/// `Vec<u8>`.
///
/// The handle is reset to position 0 before reading, so the copy is
/// independent of whatever position the framework left it in.
///
/// # Wire format
///
/// The framework-owned result handle carries the payload in the same
/// NUL-framed format as any other response: the producer appends a
/// single trailing `\0` byte (see `io::write_json` and
/// `DataHandle::write_string`). Using `read_all_bytes` here would
/// include that terminator and break every downstream JSON parser with
/// a "trailing characters" error. `read_string` stops at the first NUL
/// and therefore yields the exact JSON text without the terminator.
///
/// When the payload has no NUL (for example, a bridge that forwards raw
/// bytes), `read_string` is fault-tolerant and returns the entire
/// remaining buffer unchanged. Both cases are handled correctly.
fn extract_payload(mut handle: DataHandle) -> Result<Vec<u8>, Error> {
    handle.set_position(0)?;
    let text = handle.read_string()?;
    Ok(text.into_bytes())
}

/// Waits for the callback channel to deliver a result, applying the
/// optional timeout and mapping the two `RecvError` variants into the
/// crate's [`Error`] type.
fn recv_with_timeout(
    rx: mpsc::Receiver<Result<Vec<u8>, Error>>,
    timeout: Option<Duration>,
    op: &str,
) -> Result<Vec<u8>, Error> {
    match timeout {
        Some(d) => match rx.recv_timeout(d) {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => Err(Error::new(
                ErrorCode::Timeout,
                format!("{}: timed out after {:?}", op, d),
            )),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(Error::new(
                ErrorCode::CallFailed,
                format!("{}: callback channel disconnected", op),
            )),
        },
        None => match rx.recv() {
            Ok(result) => result,
            Err(_) => Err(Error::new(
                ErrorCode::CallFailed,
                format!("{}: callback channel disconnected", op),
            )),
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;
    use crate::sys;

    fn have_native() -> bool {
        match sys::get_library() {
            Ok(_) => true,
            Err(e) => {
                eprintln!("[SKIP] native library not available: {}", e);
                false
            }
        }
    }

    // -----------------------------------------------------------------
    // submit_async: dispatch failure path
    // -----------------------------------------------------------------

    #[test]
    fn submit_async_dispatch_failure_invokes_callback_and_returns_err() {
        if !have_native() {
            return;
        }

        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let invoked = Arc::new(AtomicBool::new(false));
        let invoked_clone = Arc::clone(&invoked);

        let result = submit_async(
            // Simulate dispatch failure by returning 0 from `issue`.
            // The `issue` closure must still consume the pointer so
            // that the test does not leak an `AsyncContext`; that is
            // handled inside `submit_async`, which reclaims the box
            // on the failure path.
            |_data| 0,
            move |r| {
                invoked_clone.store(true, Ordering::SeqCst);
                assert!(r.is_err(), "callback must receive Err on dispatch failure");
                match r {
                    Err(e) => {
                        assert_eq!(e.code(), ErrorCode::CallFailed);
                    }
                    Ok(_) => unreachable!(),
                }
            },
        );

        assert!(
            result.is_err(),
            "submit_async must return Err on dispatch failure"
        );
        assert_eq!(result.unwrap_err().code(), ErrorCode::CallFailed);
        assert!(
            invoked.load(Ordering::SeqCst),
            "callback must have been invoked synchronously"
        );
    }

    #[test]
    fn submit_async_dispatch_failure_is_observable_via_both_paths() {
        if !have_native() {
            return;
        }

        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;

        let count = Arc::new(AtomicUsize::new(0));
        let count_clone = Arc::clone(&count);

        let returned = submit_async(
            |_data| 0,
            move |_r| {
                count_clone.fetch_add(1, Ordering::SeqCst);
            },
        );

        assert!(returned.is_err(), "dispatch failure must be returned");
        assert_eq!(
            count.load(Ordering::SeqCst),
            1,
            "callback must fire exactly once on dispatch failure"
        );
    }

    // -----------------------------------------------------------------
    // async_trampoline: direct invocation with a null result handle
    // -----------------------------------------------------------------

    #[test]
    fn async_trampoline_delivers_ok_result_with_null_handle() {
        if !have_native() {
            return;
        }

        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let invoked = Arc::new(AtomicBool::new(false));
        let invoked_clone = Arc::clone(&invoked);

        let ctx = Box::new(AsyncContext {
            callback: Some(Box::new(
                move |result: Result<DataHandle, Error>| {
                    invoked_clone.store(true, Ordering::SeqCst);
                    let handle = result.expect("trampoline must deliver Ok");
                    // A NULL DataHnd materialises as an invalid but
                    // well-formed DataHandle; reading from it yields
                    // ErrorCode::NullHandle rather than undefined
                    // behaviour.
                    assert!(!handle.is_valid());
                },
            )),
        });
        let data = Box::into_raw(ctx) as *mut c_void;

        // SAFETY: `data` was produced by `Box::into_raw` above and the
        // trampoline is the sole consumer.
        unsafe { async_trampoline(data, DataHnd::NULL) };

        assert!(invoked.load(Ordering::SeqCst));
    }

    #[test]
    fn async_trampoline_isolates_panic() {
        if !have_native() {
            return;
        }

        // The panic message is written to stderr by the default panic
        // hook; that is expected. What matters is that the process
        // survives and control returns to this test.
        let ctx = Box::new(AsyncContext {
            callback: Some(Box::new(|_r: Result<DataHandle, Error>| {
                panic!("intentional panic for test");
            })),
        });
        let data = Box::into_raw(ctx) as *mut c_void;

        // SAFETY: as above.
        unsafe { async_trampoline(data, DataHnd::NULL) };

        // Reaching this line proves the panic was caught at the FFI
        // boundary and did not propagate.
    }

    #[test]
    fn async_trampoline_handles_null_data_silently() {
        // No native call is made: the null-data guard runs before any
        // library interaction.
        // SAFETY: the trampoline is documented to accept a null
        // `data` pointer and return immediately.
        unsafe { async_trampoline(std::ptr::null_mut(), DataHnd::NULL) };
    }

    #[test]
    fn async_trampoline_handles_already_consumed_context() {
        if !have_native() {
            return;
        }

        // A context whose callback slot has already been taken
        // represents a second invocation of the same trigger. The
        // trampoline must reclaim the box and return without panicking.
        let ctx = Box::new(AsyncContext { callback: None });
        let data = Box::into_raw(ctx) as *mut c_void;

        // SAFETY: as above.
        unsafe { async_trampoline(data, DataHnd::NULL) };

        // Reaching this line proves the `None` branch did not panic
        // and did not leak the box (it was reclaimed by the
        // trampoline).
    }

    // -----------------------------------------------------------------
    // Public entry points: synchronous validation
    // -----------------------------------------------------------------

    #[test]
    fn call_async_rejects_interior_nul_in_app_name() {
        if !have_native() {
            return;
        }
        let param = match DataHandle::new("async_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        let err = call_async("bad\0app", &param, |_r| {}).unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn call_async_rejects_disposed_param() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("async_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = call_async("SomeApp", &param, |_r| {}).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    #[test]
    fn call_async_by_p2p_name_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        let param = match DataHandle::new("async_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        let err = call_async_by_p2p_name("bad\0group", &param, |_r| {})
            .unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn call_async_by_uid_rejects_disposed_param() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("async_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = call_async_by_uid(Uid::NULL, &param, |_r| {}).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    // -----------------------------------------------------------------
    // Blocking style: validation only (a full round-trip requires a
    // live service, which is covered by the framework_e2e tests)
    // -----------------------------------------------------------------

    #[test]
    fn call_async_wait_rejects_interior_nul() {
        if !have_native() {
            return;
        }
        let param = match DataHandle::new("async_wait_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        let err = call_async_wait("bad\0app", &param, None).unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn call_async_wait_by_uid_rejects_disposed_param() {
        if !have_native() {
            return;
        }
        let mut param = match DataHandle::new("async_wait_test") {
            Ok(h) => h,
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
            Err(e) => panic!("unexpected construction failure: {}", e),
        };
        param.dispose();
        let err = call_async_wait_by_uid(Uid::NULL, &param, None).unwrap_err();
        assert_eq!(err.code(), ErrorCode::NullHandle);
    }

    // -----------------------------------------------------------------
    // Pure-data helpers
    // -----------------------------------------------------------------

    #[test]
    fn uid_to_lf_preserves_bytes() {
        let uid = Uid::from_hex(
            "0123456789abcdef0123456789abcdef\
             0123456789abcdef0123456789abcdef",
        )
        .unwrap();
        let lf = uid_to_lf(uid);
        assert_eq!(lf.bytes, uid.to_bytes());
        assert!(!lf.is_null());

        assert!(uid_to_lf(Uid::NULL).is_null());
    }

    #[test]
    fn recv_with_timeout_maps_disconnected_channel() {
        // No native call: this test drives the helper directly.
        let (tx, rx) = mpsc::sync_channel::<Result<Vec<u8>, Error>>(1);
        drop(tx); // Disconnect without sending.

        let err = recv_with_timeout(rx, None, "test_op").unwrap_err();
        assert_eq!(err.code(), ErrorCode::CallFailed);
        assert!(
            err.message().contains("test_op"),
            "message must include the operation name: {}",
            err
        );
    }

    #[test]
    fn recv_with_timeout_maps_timeout() {
        let (_tx, rx) = mpsc::sync_channel::<Result<Vec<u8>, Error>>(1);
        // Keep `_tx` alive but never send, so the channel is not
        // disconnected; the timeout must fire.
        let err = recv_with_timeout(
            rx,
            Some(Duration::from_millis(10)),
            "test_op",
        )
        .unwrap_err();
        assert_eq!(err.code(), ErrorCode::Timeout);
    }

    #[test]
    fn recv_with_timeout_passes_through_value() {
        let (tx, rx) = mpsc::sync_channel::<Result<Vec<u8>, Error>>(1);
        tx.send(Ok(vec![1, 2, 3])).unwrap();
        let bytes = recv_with_timeout(rx, Some(Duration::from_secs(1)), "op")
            .unwrap();
        assert_eq!(bytes, vec![1, 2, 3]);
    }

    #[test]
    fn recv_with_timeout_passes_through_inner_error() {
        let (tx, rx) = mpsc::sync_channel::<Result<Vec<u8>, Error>>(1);
        tx.send(Err(Error::new(ErrorCode::CallFailed, "boom"))).unwrap();
        let err = recv_with_timeout(rx, None, "op").unwrap_err();
        assert_eq!(err.code(), ErrorCode::CallFailed);
        assert_eq!(err.message(), "boom");
    }
}