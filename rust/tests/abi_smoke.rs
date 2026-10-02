//! Smoke tests for the Stage 1 C-ABI layer.
//!
//! These tests exercise the low-level [`lingofuse::sys`] surface without
//! the Stage 2 safe wrappers. They verify that:
//!
//! 1. The native library loads and every symbol resolves.
//! 2. A data handle can be created, written to, rewound, and read back.
//! 3. A permanent data handle releases synchronously.
//! 4. A registered Call API can be invoked through the local-execution
//!    path and returns the expected result.
//! 5. The status queue is reachable.
//! 6. (optional, `#[ignore]`) The full network preparation cycle runs
//!    end-to-end.
//!
//! ## Running
//!
//! ```text
//! cargo test --test abi_smoke
//! ```
//!
//! The network test is `#[ignore]`d because it starts the simulated main
//! thread, which is process-global. To run it, use:
//!
//! ```text
//! cargo test --test abi_smoke -- --ignored --test-threads=1
//! ```
//!
//! ## Skipping when the native library is absent
//!
//! Integration tests cannot be "skipped" in the Rust test harness the
//! way pytest allows. The convention used here is:
//!
//! - A helper [`try_lib`] returns `None` when the native library is not
//!   available and prints a `[SKIP]` line to stderr.
//! - Every test calls the helper at its top and returns early when it
//!   receives `None`.
//!
//! This keeps `cargo test` green on machines without the native
//! runtime, while still running the full suite on machines that have
//! it. Run with `--nocapture` to see the `[SKIP]` lines.
//!
//! ## Threading
//!
//! Only the `#[ignore]`d network test touches process-global framework
//! state (`LF_PrepareDone`, `LF_Shutdown`). The other tests are safe to
//! run in parallel: they create and free their own handles, and the
//! native library is documented as thread-safe.

use std::ffi::CString;
use std::os::raw::c_void;
use std::ptr;

use lingofuse::sys::{
    self, AppHnd, DataHnd, LfCallFunc, NativeLibrary,
};

// ============================================================================
// Helpers
// ============================================================================

/// Attempts to load the native library. Returns `None` and prints a
/// `[SKIP]` line when the library is unavailable, so that every test
/// can start with the same guard:
///
/// ```ignore
/// let Some(lib) = try_lib() else { return; };
/// ```
fn try_lib() -> Option<&'static NativeLibrary> {
    match sys::get_library() {
        Ok(lib) => Some(lib),
        Err(e) => {
            eprintln!(
                "[SKIP] LingoFuse native library not available: {}",
                e
            );
            None
        }
    }
}

/// Builds a `CString` from a Rust string literal, panicking on an
/// interior NUL (which would indicate a bug in the test itself, not in
/// the library under test).
fn cs(s: &str) -> CString {
    CString::new(s).expect("interior NUL in test string")
}

// ============================================================================
// Test 1 — library loads and a couple of representative symbols resolve
// ============================================================================

#[test]
fn native_library_loads_and_symbols_resolve() {
    let Some(lib) = try_lib() else { return; };

    // `LF_CheckMainThread` is a zero-argument `i32`-returning function.
    // It is safe to call before `LF_PrepareDone`; it must return 0 or 1,
    // never anything else.
    let running = unsafe { (lib.lf_check_main_thread)() };
    assert!(
        running == 0 || running == 1,
        "LF_CheckMainThread returned {}, expected 0 or 1",
        running
    );

    // `LF_GetStatusCount` is also zero-argument. It must return a
    // non-negative count.
    let count = unsafe { (lib.lf_get_status_count)() };
    assert!(count >= 0, "LF_GetStatusCount returned {}", count);

    // `LF_CheckApp` on a name that is certainly absent must return 0.
    // This exercises a string-parameter path.
    let name = cs("__definitely_absent__rust_smoke_test__");
    let present = unsafe { (lib.lf_check_app)(name.as_ptr()) };
    assert_eq!(
        present, 0,
        "LF_CheckApp reported a fictitious app as present"
    );
}

// ============================================================================
// Test 2 — data handle byte round-trip
// ============================================================================

#[test]
fn data_handle_byte_roundtrip() {
    let Some(lib) = try_lib() else { return; };

    let name = cs("smoke_roundtrip");
    let hnd = unsafe { (lib.lf_create_data)(name.as_ptr()) };
    assert!(!hnd.is_null(), "LF_CreateData returned NULL");

    // Write four bytes.
    let payload: [u8; 4] = [0x01, 0x02, 0x03, 0x04];
    let written = unsafe {
        (lib.lf_write_buffer)(
            hnd,
            payload.as_ptr() as *const c_void,
            payload.len() as i64,
        )
    };
    assert_eq!(written, 4, "LF_WriteBuffer reported {} bytes", written);

    // The handle's size must now be exactly 4.
    let size = unsafe { (lib.lf_get_size)(hnd) };
    assert_eq!(size, 4, "LF_GetSize reported {}", size);

    // The cursor is now at the end; rewind to the start.
    unsafe { (lib.lf_set_pos)(hnd, 0) };
    let pos = unsafe { (lib.lf_get_pos)(hnd) };
    assert_eq!(pos, 0, "LF_SetPos did not take effect");

    // Read the bytes back.
    let mut back: [u8; 4] = [0; 4];
    let read = unsafe {
        (lib.lf_read_buffer)(
            hnd,
            back.as_mut_ptr() as *mut c_void,
            back.len() as i64,
        )
    };
    assert_eq!(read, 4, "LF_ReadBuffer reported {} bytes", read);
    assert_eq!(back, payload, "round-trip bytes differ");

    // Release the handle.
    unsafe { (lib.lf_free_data)(hnd) };
}

// ============================================================================
// Test 3 — permanent handle lifecycle
// ============================================================================

#[test]
fn permanent_handle_is_synchronous() {
    let Some(lib) = try_lib() else { return; };

    let name = cs("smoke_permanent");
    let hnd = unsafe { (lib.lf_create_data_permanent)(name.as_ptr()) };
    assert!(
        !hnd.is_null(),
        "LF_CreateData_Permanent returned NULL"
    );

    // Write and verify a small payload.
    let payload: [u8; 3] = [0xAA, 0xBB, 0xCC];
    let written = unsafe {
        (lib.lf_write_buffer)(
            hnd,
            payload.as_ptr() as *const c_void,
            payload.len() as i64,
        )
    };
    assert_eq!(written, 3);
    let size = unsafe { (lib.lf_get_size)(hnd) };
    assert_eq!(size, 3);

    // Release synchronously. No further access to `hnd` is allowed
    // afterwards; the smoke test deliberately does not attempt any.
    unsafe { (lib.lf_free_data)(hnd) };
}

// ============================================================================
// Test 4 — local Call round-trip
// ============================================================================

/// A Call-mode callback that reads two little-endian `i32` values from
/// `input` and writes their sum to `output`.
///
/// # Safety
///
/// This function must never unwind. `sys::get_library()` cannot panic
/// because the library is already loaded by the time the callback is
/// invoked; the `Err` branch is nevertheless handled by returning
/// without writing anything, which is a legitimate empty response.
unsafe extern "C" fn add_cb(
    _trigger: *mut c_void,
    input: DataHnd,
    output: DataHnd,
) {
    let lib = match sys::get_library() {
        Ok(l) => l,
        Err(_) => return,
    };

    let mut a: i32 = 0;
    let mut b: i32 = 0;

    let r1 = (lib.lf_read_buffer)(
        input,
        &mut a as *mut i32 as *mut c_void,
        std::mem::size_of::<i32>() as i64,
    );
    let r2 = (lib.lf_read_buffer)(
        input,
        &mut b as *mut i32 as *mut c_void,
        std::mem::size_of::<i32>() as i64,
    );
    if r1 != 4 || r2 != 4 {
        // Malformed request. Return an empty response rather than
        // panicking across the FFI boundary.
        return;
    }

    let sum = a.wrapping_add(b);
    let _ = (lib.lf_write_buffer)(
        output,
        &sum as *const i32 as *const c_void,
        std::mem::size_of::<i32>() as i64,
    );
}

#[test]
fn local_call_roundtrip() {
    let Some(lib) = try_lib() else { return; };

    // --- Create the hosting application. ---
    let app_name = cs("RustSmokeApp");
    let app_desc = cs("Stage-1 smoke test");
    let app = unsafe {
        (lib.lf_create_app)(app_name.as_ptr(), app_desc.as_ptr())
    };
    assert!(!app.is_null(), "LF_CreateApp returned NULL");

    // --- Register the Call API. ---
    let api_name = cs("add");
    let api_desc = cs("Add two i32 values");
    let registered = unsafe {
        (lib.lf_register_call)(
            app,
            api_name.as_ptr(),
            api_desc.as_ptr(),
            ptr::null_mut(),
            add_cb as LfCallFunc,
        )
    };
    assert_eq!(
        registered, 1,
        "LF_RegisterCall returned {}, expected 1",
        registered
    );

    // --- Build the request. ---
    let req = unsafe { (lib.lf_create_data)(api_name.as_ptr()) };
    assert!(!req.is_null(), "LF_CreateData returned NULL");

    let a: i32 = 5;
    let b: i32 = 7;
    unsafe {
        (lib.lf_write_buffer)(
            req,
            &a as *const i32 as *const c_void,
            4,
        );
        (lib.lf_write_buffer)(
            req,
            &b as *const i32 as *const c_void,
            4,
        );
    }

    // --- Invoke the API locally. ---
    let res = unsafe { (lib.lf_local_call)(app, req) };
    assert!(!res.is_null(), "LF_LocalCall returned NULL");

    let res_size = unsafe { (lib.lf_get_size)(res) };
    assert_eq!(
        res_size, 4,
        "expected a 4-byte result, got {} bytes",
        res_size
    );

    let mut sum: i32 = 0;
    let read = unsafe {
        (lib.lf_read_buffer)(
            res,
            &mut sum as *mut i32 as *mut c_void,
            4,
        )
    };
    assert_eq!(read, 4);
    assert_eq!(sum, 12, "5 + 7 must equal 12");

    // --- Release everything. ---
    unsafe {
        (lib.lf_free_data)(req);
        (lib.lf_free_data)(res);
        (lib.lf_free_app)(app);
    }
}

// ============================================================================
// Test 5 — status queue is reachable
// ============================================================================

#[test]
fn status_queue_is_reachable() {
    let Some(lib) = try_lib() else { return; };

    // Reading the count is always safe, even before PrepareDone.
    let _ = unsafe { (lib.lf_get_status_count)() };

    // Posting a message before PrepareDone is documented as safe; the
    // message is queued and becomes observable once the main thread
    // processes the queue. This test does not assert observability.
    let msg = cs("rust smoke test: status message posted");
    unsafe { (lib.lf_post_status)(msg.as_ptr()) };
}

// ============================================================================
// Test 6 — full network preparation cycle (opt-in)
// ============================================================================
//
// This test starts the process-global simulated main thread and shuts
// it down again. It must not run concurrently with any other test that
// touches the framework, hence the `#[ignore]` attribute. Run it with:
//
//     cargo test --test abi_smoke -- --ignored --test-threads=1

#[test]
#[ignore = "touches process-global framework state; run with --ignored --test-threads=1"]
fn network_prepare_and_shutdown_cycle() {
    let Some(lib) = try_lib() else { return; };

    // Build a unique IPC endpoint so that repeated runs do not collide.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let endpoint = format!(
        "ipc:rust_smoke_{}_{}",
        std::process::id(),
        nanos
    );
    let endpoint_c = cs(&endpoint);

    // Do not block waiting for readiness: the test only needs the
    // framework to start and stop cleanly.
    let k = cs("Wait_Connection_ReadyOk");
    let v = cs("False");
    unsafe {
        (lib.lf_reset_prepare)();
        (lib.lf_set_option)(k.as_ptr(), v.as_ptr());
    }

    // Prepare one service and one pure-consumer client on the same
    // endpoint (self-connected).
    let tag_service = unsafe {
        (lib.lf_prepare_service)(
            endpoint_c.as_ptr(),
            endpoint_c.as_ptr(),
        )
    };
    assert!(
        tag_service >= 0,
        "LF_PrepareService returned {}",
        tag_service
    );

    let tag_client = unsafe {
        (lib.lf_prepare_client)(endpoint_c.as_ptr(), AppHnd::NULL)
    };
    assert!(
        tag_client >= 0,
        "LF_PrepareClient returned {}",
        tag_client
    );

    // Start the framework. The first call must return 1.
    let done = unsafe { (lib.lf_prepare_done)() };
    assert_eq!(done, 1, "LF_PrepareDone returned {}", done);

    // The main thread is now running.
    let running = unsafe { (lib.lf_check_main_thread)() };
    assert_eq!(running, 1, "LF_CheckMainThread returned {}", running);

    // A second call must return 0, not fail. The framework is already
    // running.
    let done2 = unsafe { (lib.lf_prepare_done)() };
    assert_eq!(
        done2, 0,
        "second LF_PrepareDone returned {}, expected 0",
        done2
    );

    // Shut down cleanly.
    unsafe {
        (lib.lf_exit_main_thread)();
        (lib.lf_shutdown)();
    }
}