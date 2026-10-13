//! End-to-end verification of the asynchronous call family.
//!
//! This file exercises every public entry point of
//! [`lingofuse::async_call`] against the live native library, and
//! verifies the three behavioural contracts that make the asynchronous
//! family safe to use from Rust:
//!
//! 1. **Callback style** — the closure runs on a native worker thread
//!    with a borrowed [`DataHandle`] and returns `Result<DataHandle,
//!    Error>`.
//! 2. **Blocking style** — `call_async_wait` and its siblings return
//!    a copied `Vec<u8>` after the callback fires, honouring an
//!    optional Rust-side timeout.
//! 3. **Single error path** — when the native layer rejects the
//!    request, the closure fires synchronously with `Err`, and the
//!    entry point itself returns the same `Err`.
//!
//! ## Coverage
//!
//! | Test | Contract |
//! |------|----------|
//! | `callback_style_app_name_async_e2e`      | `call_async` + `call_async_sequenced` |
//! | `callback_style_uid_async_e2e`           | `call_async_by_uid` |
//! | `callback_style_p2pname_async_e2e`       | `call_async_by_p2p_name` |
//! | `blocking_style_app_name_async_e2e`      | `call_async_wait` |
//! | `blocking_style_uid_async_e2e`           | `call_async_wait_by_uid` |
//! | `blocking_style_p2pname_async_e2e`       | `call_async_wait_by_p2p_name` |
//! | `dispatch_failure_returns_err_and_fires_callback` | Single error path (no framework) |
//! | `chained_async_roundtrip`                | Fire-and-forget chain |
//! | `fan_out_async_roundtrip`                | N concurrent async calls |
//! | `callback_panic_is_isolated`             | `catch_unwind` at the FFI boundary |
//! | `blocking_style_timeout_returns_err`     | Rust-side timeout |
//!
//! ## Running
//!
//! ```text
//! cargo test --test async_e2e -- --ignored --test-threads=1
//! ```
//!
//! Every test starts the process-global framework, so they must run
//! serially. Each test tears the framework down at the end, so the
//! tests are independent of one another and may be selected
//! individually.
//!
//! ## What this file does *not* test
//!
//! - Cross-process routing. The service and the client share a process
//!   here, so App-name and UID routing take the mesh's local-first
//!   path; P2PName routing still traverses the server-side dispatcher
//!   through the IPC loopback.
//! - Retaining the borrowed `DataHandle` past the callback body. That
//!   is a documented use-after-free and is not testable safely.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use lingofuse::app_handle::AppHandle;
use lingofuse::async_call;
use lingofuse::data_handle::DataHandle;
use lingofuse::error::ErrorCode;
use lingofuse::framework;
use lingofuse::io;
use lingofuse::options;
use lingofuse::sys;
use lingofuse::uid::Uid;

// ============================================================================
// Helpers
// ============================================================================

fn have_native() -> bool {
    match sys::get_library() {
        Ok(_) => true,
        Err(e) => {
            eprintln!("[SKIP] native library not available: {}", e);
            false
        }
    }
}

fn unique_endpoint(prefix: &str) -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("ipc:{}_{}_{}", prefix, std::process::id(), nanos)
}

fn wait_until<F: FnMut() -> bool>(mut predicate: F) -> bool {
    for _ in 0..30 {
        if predicate() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    false
}

/// Applies the common pre-setup options.
///
/// Called before `reset_prepare` by every test. The three settings are
/// chosen to make the async tests deterministic:
///
/// - `Wait_Connection_ReadyOk = false` so that `prepare_done` does not
///   block waiting for mesh readiness; the tests poll for it themselves.
/// - `Overlap_Connection = true` so that service and client can share
///   the same endpoint within a single process.
/// - `Quiet = true` to keep the test output readable.
fn set_common_options() {
    options::set_wait_connection_ready_ok(false).unwrap();
    options::set_overlap_connection(true).unwrap();
    options::set_quiet(true).unwrap();
}

/// Reads the caller's own UID by calling the `whoami` API, which the
/// harness registers on every test that needs a UID.
fn probe_uid(app_name: &str) -> Uid {
    let mut req = DataHandle::new("whoami").unwrap();
    io::write_json(&mut req, &WhoamiArgs::default()).unwrap();
    req.set_position(0).unwrap();

    let mut resp = framework::call(app_name, &req, 5000)
        .expect("whoami must not fail at the transport level");
    assert!(resp.size().unwrap() > 0, "whoami must return a payload");
    resp.set_position(0).unwrap();
    let who: WhoamiResult = io::read_json(&mut resp).expect("whoami JSON");
    Uid::from_hex(&who.uid_hex).expect("UID must parse")
}

// ============================================================================
// Payloads and handlers
// ============================================================================

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct AddArgs {
    a: i32,
    b: i32,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct AddResult {
    sum: i32,
}

fn add_handler(input: &mut DataHandle, output: &mut DataHandle) {
    let args: AddArgs = match io::read_json(input) {
        Ok(a) => a,
        Err(_) => return,
    };
    let _ = io::write_json(output, &AddResult { sum: args.a + args.b });
}

#[derive(Serialize, Deserialize, Debug, Default)]
struct WhoamiArgs {}

#[derive(Serialize, Deserialize, Debug)]
struct WhoamiResult {
    uid_hex: String,
    p2p_name: String,
}

fn whoami_handler(input: &mut DataHandle, output: &mut DataHandle) {
    let uid = input.p2p_uid().unwrap_or_default();
    let name = input.p2p_name().unwrap_or_default();
    let _ = io::write_json(
        output,
        &WhoamiResult {
            uid_hex: uid.to_hex(),
            p2p_name: name,
        },
    );
}

// ============================================================================
// Test 1 — Callback style, App-name addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn callback_style_app_name_async_e2e() {
    if !have_native() {
        return;
    }

    set_common_options();
    let endpoint = unique_endpoint("rust_async_app_name");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncAppNameE2E", "async app-name").unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(wait_until(|| {
        framework::check_api("RustAsyncAppNameE2E", "add").unwrap_or(false)
    }));

    // --- `call_async` (plain) ---------------------------------------
    let (tx, rx) = mpsc::sync_channel::<Result<AddResult, lingofuse::error::Error>>(1);
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 5, b: 7 }).unwrap();
    req.set_position(0).unwrap();

    async_call::call_async("RustAsyncAppNameE2E", &req, move |result| {
        let payload = result.and_then(|mut h| io::read_json::<AddResult>(&mut h));
        let _ = tx.send(payload);
    })
    .expect("call_async must dispatch");

    drop(req);

    let out = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("call_async must fire within 10s")
        .expect("call_async result must be Ok");
    assert_eq!(out, AddResult { sum: 12 });

    // --- `call_async_sequenced` -------------------------------------
    let (tx, rx) = mpsc::sync_channel::<Result<AddResult, lingofuse::error::Error>>(1);
    let mut req2 = DataHandle::new("add").unwrap();
    io::write_json(&mut req2, &AddArgs { a: 100, b: 200 }).unwrap();
    req2.set_position(0).unwrap();

    async_call::call_async_sequenced("RustAsyncAppNameE2E", &req2, move |result| {
        let payload = result.and_then(|mut h| io::read_json::<AddResult>(&mut h));
        let _ = tx.send(payload);
    })
    .expect("call_async_sequenced must dispatch");

    drop(req2);

    let out2 = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("call_async_sequenced must fire within 10s")
        .expect("call_async_sequenced result must be Ok");
    assert_eq!(out2, AddResult { sum: 300 });

    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 2 — Callback style, UID addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn callback_style_uid_async_e2e() {
    if !have_native() {
        return;
    }

    set_common_options();
    let endpoint = unique_endpoint("rust_async_uid");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncUidE2E", "async uid").unwrap();
    app.register_call("whoami", "identity probe", whoami_handler).unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(wait_until(|| {
        framework::check_api("RustAsyncUidE2E", "whoami").unwrap_or(false)
    }));

    let my_uid = probe_uid("RustAsyncUidE2E");
    assert!(!my_uid.is_null(), "own UID must not be null");

    assert!(
        wait_until(|| framework::check_uid(my_uid).unwrap_or(false)),
        "own UID must become routable",
    );

    // --- `call_async_by_uid` ----------------------------------------
    let (tx, rx) = mpsc::sync_channel::<Result<AddResult, lingofuse::error::Error>>(1);
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 3, b: 4 }).unwrap();
    req.set_position(0).unwrap();

    async_call::call_async_by_uid(my_uid, &req, move |result| {
        let payload = result.and_then(|mut h| io::read_json::<AddResult>(&mut h));
        let _ = tx.send(payload);
    })
    .expect("call_async_by_uid must dispatch");

    drop(req);

    let out = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("call_async_by_uid must fire within 10s")
        .expect("call_async_by_uid result must be Ok");
    assert_eq!(out, AddResult { sum: 7 });

    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 3 — Callback style, P2PName addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn callback_style_p2pname_async_e2e() {
    if !have_native() {
        return;
    }

    const GROUP: &str = "rust_async_p2pname_group";

    options::set_p2p_name(GROUP).unwrap();
    set_common_options();
    let endpoint = unique_endpoint("rust_async_p2pname");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncP2PNameE2E", "async p2pname").unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(
        wait_until(|| framework::check_p2p_name_api(GROUP, "add").unwrap_or(false)),
        "P2P group must become routable",
    );

    // --- `call_async_by_p2p_name` -----------------------------------
    let (tx, rx) = mpsc::sync_channel::<Result<AddResult, lingofuse::error::Error>>(1);
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 11, b: 22 }).unwrap();
    req.set_position(0).unwrap();

    async_call::call_async_by_p2p_name(GROUP, &req, move |result| {
        let payload = result.and_then(|mut h| io::read_json::<AddResult>(&mut h));
        let _ = tx.send(payload);
    })
    .expect("call_async_by_p2p_name must dispatch");

    drop(req);

    let out = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("call_async_by_p2p_name must fire within 10s")
        .expect("call_async_by_p2p_name result must be Ok");
    assert_eq!(out, AddResult { sum: 33 });

    drop(app);
    framework::exit_main_thread();
    framework::shutdown();

    let _ = options::set_p2p_name("");
}

// ============================================================================
// Test 4 — Blocking style, App-name addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn blocking_style_app_name_async_e2e() {
    if !have_native() {
        return;
    }

    set_common_options();
    let endpoint = unique_endpoint("rust_async_wait_app_name");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncWaitAppE2E", "async wait app").unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(wait_until(|| {
        framework::check_api("RustAsyncWaitAppE2E", "add").unwrap_or(false)
    }));

    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 40, b: 2 }).unwrap();
    req.set_position(0).unwrap();

    let bytes = async_call::call_async_wait(
        "RustAsyncWaitAppE2E",
        &req,
        Some(Duration::from_secs(10)),
    )
    .expect("call_async_wait must succeed");

    let text = String::from_utf8_lossy(&bytes);
    let out: AddResult = io::loads_json(&text).expect("payload must be valid JSON");
    assert_eq!(out, AddResult { sum: 42 });

    drop(req);
    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 5 — Blocking style, UID addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn blocking_style_uid_async_e2e() {
    if !have_native() {
        return;
    }

    set_common_options();
    let endpoint = unique_endpoint("rust_async_wait_uid");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncWaitUidE2E", "async wait uid").unwrap();
    app.register_call("whoami", "identity probe", whoami_handler).unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(wait_until(|| {
        framework::check_api("RustAsyncWaitUidE2E", "whoami").unwrap_or(false)
    }));

    let my_uid = probe_uid("RustAsyncWaitUidE2E");
    assert!(
        wait_until(|| framework::check_uid(my_uid).unwrap_or(false)),
        "own UID must become routable",
    );

    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 7, b: 8 }).unwrap();
    req.set_position(0).unwrap();

    let bytes = async_call::call_async_wait_by_uid(
        my_uid,
        &req,
        Some(Duration::from_secs(10)),
    )
    .expect("call_async_wait_by_uid must succeed");

    let text = String::from_utf8_lossy(&bytes);
    let out: AddResult = io::loads_json(&text).expect("payload must be valid JSON");
    assert_eq!(out, AddResult { sum: 15 });

    drop(req);
    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 6 — Blocking style, P2PName addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn blocking_style_p2pname_async_e2e() {
    if !have_native() {
        return;
    }

    const GROUP: &str = "rust_async_wait_p2pname_group";

    options::set_p2p_name(GROUP).unwrap();
    set_common_options();
    let endpoint = unique_endpoint("rust_async_wait_p2pname");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncWaitP2PE2E", "async wait p2pname").unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(
        wait_until(|| framework::check_p2p_name_api(GROUP, "add").unwrap_or(false)),
        "P2P group must become routable",
    );

    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 50, b: 50 }).unwrap();
    req.set_position(0).unwrap();

    let bytes = async_call::call_async_wait_by_p2p_name(
        GROUP,
        &req,
        Some(Duration::from_secs(10)),
    )
    .expect("call_async_wait_by_p2p_name must succeed");

    let text = String::from_utf8_lossy(&bytes);
    let out: AddResult = io::loads_json(&text).expect("payload must be valid JSON");
    assert_eq!(out, AddResult { sum: 100 });

    drop(req);
    drop(app);
    framework::exit_main_thread();
    framework::shutdown();

    let _ = options::set_p2p_name("");
}

// ============================================================================
// Test 7 — Dispatch failure: single error path
// ============================================================================

#[test]
#[ignore = "starts no framework; the point is that dispatch fails; run with --ignored --test-threads=1"]
fn dispatch_failure_returns_err_and_fires_callback() {
    if !have_native() {
        return;
    }

    // Deliberately do NOT call `prepare_done`. With no running main
    // thread, `LF_Async_Call` rejects the request (returns 0). This
    // exercises the documented "single error path" behaviour.
    //
    // The previous test in the file may have left the framework shut
    // down; calling `shutdown` is idempotent, so we do it defensively
    // to guarantee the "not running" precondition.
    framework::shutdown();

    let mut param = match DataHandle::new("add") {
        Ok(h) => h,
        Err(e) if e.code() == ErrorCode::LibraryLoadFailed => return,
        Err(e) => panic!("unexpected construction failure: {}", e),
    };
    io::write_json(&mut param, &AddArgs { a: 1, b: 2 }).unwrap();
    param.set_position(0).unwrap();

    // The callback must fire exactly once, synchronously, on this
    // thread, with an error.
    let entered = Arc::new(AtomicBool::new(false));
    let entered_clone = Arc::clone(&entered);

    let returned = async_call::call_async(
        "__no_such_app_in_dispatch_failure_test__",
        &param,
        move |result| {
            entered_clone.store(true, Ordering::SeqCst);
            match result {
                Ok(_) => panic!("dispatch failure must not deliver Ok"),
                Err(e) => assert_eq!(e.code(), ErrorCode::CallFailed),
            }
        },
    );

    assert!(
        returned.is_err(),
        "call_async must return Err on dispatch failure",
    );
    assert_eq!(
        returned.unwrap_err().code(),
        ErrorCode::CallFailed,
    );
    assert!(
        entered.load(Ordering::SeqCst),
        "callback must have been invoked synchronously on dispatch failure",
    );

    drop(param);
}

// ============================================================================
// Test 8 — Chained asynchronous calls
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn chained_async_roundtrip() {
    if !have_native() {
        return;
    }

    set_common_options();
    let endpoint = unique_endpoint("rust_async_chain");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncChainE2E", "async chain").unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(wait_until(|| {
        framework::check_api("RustAsyncChainE2E", "add").unwrap_or(false)
    }));

    // The chain: add(4, 6) = 10  ->  add(10, 1) = 11.
    let (tx, rx) = mpsc::channel::<Result<AddResult, lingofuse::error::Error>>();

    let mut first = DataHandle::new("add").unwrap();
    io::write_json(&mut first, &AddArgs { a: 4, b: 6 }).unwrap();
    first.set_position(0).unwrap();

    async_call::call_async("RustAsyncChainE2E", &first, move |result| {
        // --- Step 1 result ----------------------------------------
        let sum1 = match result.and_then(|mut h| io::read_json::<AddResult>(&mut h)) {
            Ok(r) => r.sum,
            Err(_) => return, // dropping tx unblocks the receiver with Disconnected
        };

        // --- Step 2: launch another async call from inside the callback
        let mut second = match DataHandle::new("add") {
            Ok(h) => h,
            Err(_) => return,
        };
        if io::write_json(&mut second, &AddArgs { a: sum1, b: 1 }).is_err() {
            return;
        }
        let _ = second.set_position(0);

        let _ = async_call::call_async(
            "RustAsyncChainE2E",
            &second,
            move |result2| {
                let out = result2.and_then(|mut h| io::read_json::<AddResult>(&mut h));
                let _ = tx.send(out);
            },
        );
    })
    .expect("step 1 must dispatch");

    drop(first);

    let final_result = rx
        .recv_timeout(Duration::from_secs(15))
        .expect("chain must complete within 15s")
        .expect("chain must deliver Ok");
    assert_eq!(
        final_result,
        AddResult { sum: 11 },
        "add(4,6)=10 then add(10,1)=11",
    );

    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 9 — Fan-out: N concurrent async calls
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn fan_out_async_roundtrip() {
    if !have_native() {
        return;
    }

    set_common_options();
    let endpoint = unique_endpoint("rust_async_fanout");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncFanOutE2E", "async fanout").unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(wait_until(|| {
        framework::check_api("RustAsyncFanOutE2E", "add").unwrap_or(false)
    }));

    const N: usize = 8;
    let (tx, rx) = mpsc::channel::<Result<AddResult, lingofuse::error::Error>>();

    for i in 0..N {
        let mut req = DataHandle::new("add").unwrap();
        io::write_json(&mut req, &AddArgs { a: i as i32, b: 100 }).unwrap();
        req.set_position(0).unwrap();

        let tx = tx.clone();
        async_call::call_async("RustAsyncFanOutE2E", &req, move |result| {
            let payload = result.and_then(|mut h| io::read_json::<AddResult>(&mut h));
            let _ = tx.send(payload);
        })
        .expect("each fan-out call must dispatch");

        // `req` may be dropped immediately; the framework copied the
        // payload synchronously.
    }
    // Close the sender-side so that the receiver loop cannot hang
    // forever if a callback is lost.
    drop(tx);

    let mut results = Vec::with_capacity(N);
    for _ in 0..N {
        let r = rx
            .recv_timeout(Duration::from_secs(15))
            .expect("all fan-out calls must complete within 15s")
            .expect("each fan-out result must be Ok");
        results.push(r);
    }

    let mut sums: Vec<i32> = results.iter().map(|r| r.sum).collect();
    sums.sort_unstable();
    for (i, s) in sums.iter().enumerate() {
        assert_eq!(*s, 100 + i as i32, "fan-out result {} mismatch", i);
    }

    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 10 — Callback panic isolation
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn callback_panic_is_isolated() {
    if !have_native() {
        return;
    }

    set_common_options();
    let endpoint = unique_endpoint("rust_async_panic");
    framework::reset_prepare();

    let app = AppHandle::new("RustAsyncPanicE2E", "async panic").unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    assert!(wait_until(|| {
        framework::check_api("RustAsyncPanicE2E", "add").unwrap_or(false)
    }));

    // The callback notifies the test thread and then panics. The panic
    // must be caught at the FFI boundary; the process must survive.
    let (tx, rx) = mpsc::sync_channel::<()>(1);
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 1, b: 1 }).unwrap();
    req.set_position(0).unwrap();

    async_call::call_async("RustAsyncPanicE2E", &req, move |_result| {
        // Notify the test thread first, then panic. The notification
        // is what the test will synchronise on.
        let _ = tx.send(());
        panic!("intentional panic inside async callback");
    })
    .expect("call_async must dispatch");

    drop(req);

    // Block until the callback has begun. Reaching this line proves
    // the callback was invoked.
    rx.recv_timeout(Duration::from_secs(10))
        .expect("callback must fire within 10s");

    // Give the panic a moment to propagate through the trampoline's
    // `catch_unwind`; then prove the process is still healthy by
    // issuing a normal synchronous call.
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        framework::check_main_thread().unwrap(),
        "main thread must still be running after a callback panic",
    );

    let mut req2 = DataHandle::new("add").unwrap();
    io::write_json(&mut req2, &AddArgs { a: 9, b: 9 }).unwrap();
    req2.set_position(0).unwrap();
    let mut resp = framework::call("RustAsyncPanicE2E", &req2, 5000).unwrap();
    resp.set_position(0).unwrap();
    let out: AddResult = io::read_json(&mut resp).unwrap();
    assert_eq!(out, AddResult { sum: 18 });

    drop(resp);
    drop(req2);
    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
}
