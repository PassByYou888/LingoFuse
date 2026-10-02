//! End-to-end integration test for the Stage 2 safe wrappers.
//!
//! This test file exercises the full public API of the `lingofuse`
//! crate as an **integration consumer** would:
//!
//! 1. Configure runtime options (`set_option`).
//! 2. Prepare a service and a client (`prepare_service`,
//!    `prepare_client`).
//! 3. Start the framework (`prepare_done`).
//! 4. Register a Call API and a Notify API on an [`AppHandle`].
//! 5. Issue a remote call through `try_call` and verify the response.
//! 6. Send a one-way notification and verify delivery.
//! 7. Shut down cleanly (`exit_main_thread`, `shutdown`).
//!
//! # Running
//!
//! Every test here is `#[ignore]`d, for two reasons:
//!
//! - Each test starts the process-global simulated main thread, which
//!   is a singleton resource.
//! - The native framework is not designed to be started, stopped, and
//!   restarted concurrently within a single process.
//!
//! To run the suite, use a **single thread**:
//!
//! ```text
//! cargo test --test framework_e2e -- --ignored --test-threads=1
//! ```
//!
//! The test prints a `[SKIP]` line and returns early when the native
//! library is not available.
//!
//! # What this file does *not* test
//!
//! - **True cross-process networking.** The service and the client live
//!   in the same process here, so `LF_Call` takes the mesh's
//!   local-first routing path. The call still flows through the full
//!   native call chain (pack, dispatch, unpack, invoke callback, pack
//!   result, return), but it does not exercise a TCP or cross-process
//!   IPC hop. Testing that path requires two OS processes and is out of
//!   scope for a Rust integration test.
//!
//! - **Network event callbacks.** Those are tested at the unit level in
//!   `src/network_events.rs` and can only be observed end-to-end when
//!   another process joins the mesh.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use lingofuse::app_handle::AppHandle;
use lingofuse::data_handle::DataHandle;
use lingofuse::framework;
use lingofuse::io;
use lingofuse::sys;

// ============================================================================
// Helpers
// ============================================================================

/// Returns `true` when the native library is available; otherwise
/// prints a `[SKIP]` line and returns `false`.
fn have_native() -> bool {
    match sys::get_library() {
        Ok(_) => true,
        Err(e) => {
            eprintln!("[SKIP] native library not available: {}", e);
            false
        }
    }
}

/// Builds a process-unique IPC endpoint name. The nanosecond timestamp
/// guarantees uniqueness across rapid successive runs; the PID
/// guarantees uniqueness across concurrent test invocations.
fn unique_endpoint(prefix: &str) -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("ipc:{}_{}_{}", prefix, std::process::id(), nanos)
}

// ============================================================================
// Test 1 — same-process service + client, full call + notify flow
// ============================================================================

/// Payload for the `add` API.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct AddArgs {
    a: i32,
    b: i32,
}

/// Response for the `add` API.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct AddResult {
    sum: i32,
}

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn same_process_service_and_client() {
    if !have_native() {
        return;
    }

    // ------------------------------------------------------------------
    // 1. Options
    // ------------------------------------------------------------------
    //
    // `Wait_Connection_ReadyOk=False` lets `prepare_done` return
    // immediately instead of waiting up to 30 seconds for mesh
    // propagation. The test performs its own readiness loop below.
    //
    // `Overlap_Connection=True` is required because this process hosts
    // both a service and a client on the same physical address.
    //
    // `Quiet=True` silences the native layer's own console chatter, so
    // the test output stays readable.
    framework::set_option("Wait_Connection_ReadyOk", "False").unwrap();
    framework::set_option("Overlap_Connection", "True").unwrap();
    framework::set_option("Quiet", "True").unwrap();

    // ------------------------------------------------------------------
    // 2. Prepare the mesh
    // ------------------------------------------------------------------
    let endpoint = unique_endpoint("rust_e2e");

    framework::reset_prepare();

    let app = AppHandle::new("RustE2EApp", "Rust Stage 2 end-to-end test").unwrap();

    // ------------------------------------------------------------------
    // 3. Register the APIs
    // ------------------------------------------------------------------
    //
    // Registration must happen **before** `prepare_client`, so that the
    // mesh broadcast carries the API list.

    // -- Call API: `add` --
    app.register_call("add", "Add two i32 values", |input, output| {
        let args: AddArgs = match io::read_json(input) {
            Ok(a) => a,
            Err(_) => return,
        };
        let _ = io::write_json(output, &AddResult { sum: args.a + args.b });
    })
    .unwrap();

    // -- Notify API: `log` --
    //
    // The handler increments a shared counter so the test can verify
    // delivery. It does not touch the input payload; receiving the
    // notification at all is the assertion.
    let log_count = Arc::new(AtomicUsize::new(0));
    let log_count_clone = log_count.clone();
    app.register_notify("log", "Increment the log counter", move |_input| {
        log_count_clone.fetch_add(1, Ordering::SeqCst);
    })
    .unwrap();

    // ------------------------------------------------------------------
    // 4. Prepare the service and the client
    // ------------------------------------------------------------------
    let service_tag =
        framework::prepare_service(&endpoint, &endpoint).expect("prepare_service failed");
    assert!(service_tag >= 0, "prepare_service returned {}", service_tag);

    let client_tag =
        framework::prepare_client(&endpoint, Some(&app)).expect("prepare_client failed");
    assert!(client_tag >= 0, "prepare_client returned {}", client_tag);

    // ------------------------------------------------------------------
    // 5. Start the framework
    // ------------------------------------------------------------------
    let started = framework::prepare_done().expect("prepare_done failed");
    assert!(
        started,
        "the first prepare_done must return Ok(true); got Ok(false)"
    );

    assert!(
        framework::check_main_thread().unwrap(),
        "the simulated main thread must be running after prepare_done"
    );

    // ------------------------------------------------------------------
    // 6. Call roundtrip: `add(40, 2) -> {sum: 42}`
    // ------------------------------------------------------------------

    // Build the request handle. The handle's API name determines which
    // API the native layer dispatches to.
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 40, b: 2 }).unwrap();
    req.set_position(0).unwrap();

    // Retry loop: the mesh may need a moment to make the app visible
    // even after `prepare_done` returned. `try_call` returns `Ok(None)`
    // for a size-0 response, which in this case means "app not yet
    // routable".
    let mut response: Option<DataHandle> = None;
    for attempt in 0..30 {
        match framework::try_call("RustE2EApp", &req, 3000).unwrap() {
            Some(r) => {
                response = Some(r);
                break;
            }
            None => {
                // Rewind the request in case the previous attempt
                // advanced its cursor. (It should not, but this is
                // cheap insurance.)
                req.set_position(0).unwrap();
                std::thread::sleep(Duration::from_millis(200));
                let _ = attempt;
            }
        }
    }

    let mut response =
        response.expect("call to RustE2EApp.add did not succeed within 6 seconds");

    // Verify the response payload.
    assert!(
        response.size().unwrap() > 0,
        "response handle must be non-empty"
    );
    response.set_position(0).unwrap();
    let out: AddResult = io::read_json(&mut response).expect("failed to parse response as JSON");
    assert_eq!(out, AddResult { sum: 42 }, "40 + 2 must equal 42");

    // ------------------------------------------------------------------
    // 7. Notify roundtrip: one fire, one delivery
    // ------------------------------------------------------------------
    let mut notif = DataHandle::new("log").unwrap();
    io::write_json(&mut notif, &serde_json::json!({ "msg": "hello" })).unwrap();
    notif.set_position(0).unwrap();

    framework::notify("RustE2EApp", &notif).expect("notify failed");

    // The notification is delivered asynchronously; give it a moment.
    // We do not assert an exact delay, only eventual delivery.
    let mut delivered = 0usize;
    for _ in 0..50 {
        delivered = log_count.load(Ordering::SeqCst);
        if delivered > 0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        delivered, 1,
        "the log notify handler must have fired exactly once"
    );

    // ------------------------------------------------------------------
    // 8. Teardown
    // ------------------------------------------------------------------
    //
    // Drop the handles first so that no data-handle pool flush races
    // with their destruction.
    drop(notif);
    drop(response);
    drop(req);
    drop(app);

    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 2 — consumer-only call to an absent app returns Ok(None)
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn consumer_only_call_to_absent_app_returns_none() {
    if !have_native() {
        return;
    }

    framework::set_option("Wait_Connection_ReadyOk", "False").unwrap();
    framework::set_option("Quiet", "True").unwrap();

    let endpoint = unique_endpoint("rust_e2e_consumer");

    framework::reset_prepare();

    // Pure consumer: no AppHandle, just a client connection.
    framework::prepare_service(&endpoint, &endpoint).expect("prepare_service failed");
    framework::prepare_client(&endpoint, None).expect("prepare_client failed");

    let started = framework::prepare_done().expect("prepare_done failed");
    assert!(started, "prepare_done must return Ok(true)");

    // Call a name that is guaranteed to be absent.
    let mut req = DataHandle::new("nonexistent_api").unwrap();
    req.write_bytes(b"{}").unwrap();
    req.set_position(0).unwrap();

    let response = framework::try_call(
        "__definitely_absent_app_rust_e2e__",
        &req,
        1000,
    )
    .expect("try_call must not fail on an absent target");

    assert!(
        response.is_none(),
        "calling an absent app must produce Ok(None), not Ok(Some)"
    );

    drop(req);
    framework::exit_main_thread();
    framework::shutdown();
}