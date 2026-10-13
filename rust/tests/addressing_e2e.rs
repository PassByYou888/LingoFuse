//! End-to-end verification of the three addressing schemes.
//!
//! This file exercises the complete synchronous API surface of the
//! crate across the three routing keys:
//!
//! 1. **App name** — [`framework::call`] / [`try_call`] / [`notify`] /
//!    [`sequenced_notify`].
//! 2. **UID** — [`call_by_uid`] / [`try_call_by_uid`] / [`notify_by_uid`]
//!    / [`sequenced_notify_by_uid`], obtained after a `whoami` probe.
//! 3. **P2PName** — [`call_by_p2p_name`] / [`try_call_by_p2p_name`] /
//!    [`notify_by_p2p_name`] / [`sequenced_notify_by_p2p_name`].
//!
//! In addition, it verifies:
//!
//! - Process-wide P2P registration through [`lingofuse::p2p`].
//! - The four extra query APIs: [`check_uid`], [`check_uid_api`],
//!   [`check_p2p_name`], [`check_p2p_name_api`].
//!
//! # Running
//!
//! ```text
//! cargo test --test addressing_e2e -- --ignored --test-threads=1
//! ```
//!
//! Every test starts the process-global framework, so they must run
//! serially. The `[SKIP]` guard returns early when the native library
//! is not available.
//!
//! # What this file does *not* test
//!
//! - True cross-process routing. The service and the client share a
//!   process here; the App-name and UID families therefore take the
//!   mesh's local-first path. P2PName routing is *not* local-first
//!   even in this configuration, so its assertions exercise the
//!   server-side dispatcher through the IPC loopback.
//! - Asynchronous invocation. That is covered by `async_e2e.rs`.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use lingofuse::app_handle::AppHandle;
use lingofuse::data_handle::DataHandle;
use lingofuse::framework;
use lingofuse::io;
use lingofuse::options;
use lingofuse::p2p;
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

/// Waits until a predicate becomes true, polling every 200 ms up to 30
/// times (6 seconds total). The mesh broadcast needs up to ~3 seconds to
/// reach the local cache.
fn wait_until<F: FnMut() -> bool>(mut predicate: F) -> bool {
    for _ in 0..30 {
        if predicate() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    false
}

/// Waits for the notify counter to reach a target value.
fn wait_for_counter(counter: &Arc<AtomicUsize>, target: usize) -> bool {
    for _ in 0..50 {
        if counter.load(Ordering::SeqCst) >= target {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

// ============================================================================
// Shared payloads and handlers
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

/// A Call-mode handler that adds two integers. Registered under several
/// different API names across the tests below.
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

/// A Call-mode handler that echoes the caller's identity. The UID is
/// read from the **input** handle, where the framework injected it.
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
// Test 1 — App-name addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn app_name_addressing_e2e() {
    if !have_native() {
        return;
    }

    options::set_wait_connection_ready_ok(false).unwrap();
    options::set_overlap_connection(true).unwrap();
    options::set_quiet(true).unwrap();

    let endpoint = unique_endpoint("rust_app_name");

    framework::reset_prepare();

    let app = AppHandle::new("RustAppNameE2E", "app-name addressing").unwrap();

    app.register_call("add", "add two ints", add_handler).unwrap();

    let notify_count = Arc::new(AtomicUsize::new(0));
    let notify_clone = Arc::clone(&notify_count);
    app.register_notify("log", "increment counter", move |_input| {
        notify_clone.fetch_add(1, Ordering::SeqCst);
    })
    .unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    // --- Wait for the App to be visible on the mesh ------------------
    assert!(
        wait_until(|| framework::check_api("RustAppNameE2E", "add").unwrap_or(false)),
        "App must become visible on the mesh within 6 seconds",
    );
    assert!(framework::check_app("RustAppNameE2E").unwrap());

    // --- `call` (blocking) ------------------------------------------
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 10, b: 20 }).unwrap();
    req.set_position(0).unwrap();

    let mut resp = framework::call("RustAppNameE2E", &req, 5000).unwrap();
    assert!(resp.size().unwrap() > 0);
    resp.set_position(0).unwrap();
    let out: AddResult = io::read_json(&mut resp).unwrap();
    assert_eq!(out, AddResult { sum: 30 });

    // --- `try_call` (Option-returning) ------------------------------
    let mut req2 = DataHandle::new("add").unwrap();
    io::write_json(&mut req2, &AddArgs { a: 100, b: 200 }).unwrap();
    req2.set_position(0).unwrap();

    let mut resp2 = framework::try_call("RustAppNameE2E", &req2, 5000)
        .unwrap()
        .expect("try_call must succeed for a registered app");
    resp2.set_position(0).unwrap();
    let out2: AddResult = io::read_json(&mut resp2).unwrap();
    assert_eq!(out2, AddResult { sum: 300 });

    // --- `notify` (best-effort one-way) -----------------------------
    let before = notify_count.load(Ordering::SeqCst);
    let mut nreq = DataHandle::new("log").unwrap();
    io::write_json(&mut nreq, &serde_json::json!({ "msg": "notify" })).unwrap();
    nreq.set_position(0).unwrap();

    framework::notify("RustAppNameE2E", &nreq).unwrap();
    assert!(
        wait_for_counter(&notify_count, before + 1),
        "notify must reach the handler",
    );

    // --- `sequenced_notify` (FIFO one-way) --------------------------
    let before = notify_count.load(Ordering::SeqCst);
    let mut sreq = DataHandle::new("log").unwrap();
    io::write_json(&mut sreq, &serde_json::json!({ "msg": "seq" })).unwrap();
    sreq.set_position(0).unwrap();

    framework::sequenced_notify("RustAppNameE2E", &sreq).unwrap();
    assert!(
        wait_for_counter(&notify_count, before + 1),
        "sequenced_notify must reach the handler",
    );

    // --- Teardown ---------------------------------------------------
    drop(sreq);
    drop(nreq);
    drop(resp2);
    drop(req2);
    drop(resp);
    drop(req);
    drop(app);

    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 2 — UID addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn uid_addressing_e2e() {
    if !have_native() {
        return;
    }

    options::set_wait_connection_ready_ok(false).unwrap();
    options::set_overlap_connection(true).unwrap();
    options::set_quiet(true).unwrap();

    let endpoint = unique_endpoint("rust_uid");

    framework::reset_prepare();

    let app = AppHandle::new("RustUidE2E", "uid addressing").unwrap();

    app.register_call("whoami", "echo caller identity", whoami_handler)
        .unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    let notify_count = Arc::new(AtomicUsize::new(0));
    let notify_clone = Arc::clone(&notify_count);
    app.register_notify("log", "increment counter", move |_input| {
        notify_clone.fetch_add(1, Ordering::SeqCst);
    })
    .unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    // --- Obtain our own UID via `whoami` ----------------------------
    let probe = |label: &str| -> WhoamiResult {
        let mut req = DataHandle::new("whoami").unwrap();
        io::write_json(&mut req, &WhoamiArgs::default()).unwrap();
        req.set_position(0).unwrap();

        let mut resp = framework::call("RustUidE2E", &req, 5000)
            .unwrap_or_else(|e| panic!("whoami ({}) call failed: {}", label, e));
        assert!(
            resp.size().unwrap() > 0,
            "whoami ({}) must return a non-empty response",
            label,
        );
        resp.set_position(0).unwrap();
        io::read_json(&mut resp)
            .unwrap_or_else(|e| panic!("whoami ({}) parse failed: {}", label, e))
    };

    // Wait for the App and API to appear on the mesh before probing.
    assert!(wait_until(|| framework::check_api("RustUidE2E", "whoami").unwrap_or(false)));

    let who = probe("first");
    let my_uid = Uid::from_hex(&who.uid_hex).expect("returned UID must be valid hex");
    assert!(!my_uid.is_null(), "our own UID must not be null");

    // A second probe must return the same UID, because the mesh
    // session has not been reconnected.
    let who2 = probe("second");
    assert_eq!(
        who2.uid_hex, who.uid_hex,
        "UID must be stable within a session",
    );

    // --- Wait for the UID to be routable ----------------------------
    assert!(
        wait_until(|| framework::check_uid(my_uid).unwrap_or(false)),
        "our own UID must become routable within 6 seconds",
    );

    // --- `call_by_uid` ----------------------------------------------
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 3, b: 4 }).unwrap();
    req.set_position(0).unwrap();

    let mut resp = framework::call_by_uid(my_uid, &req, 5000).unwrap();
    assert!(resp.size().unwrap() > 0);
    resp.set_position(0).unwrap();
    let out: AddResult = io::read_json(&mut resp).unwrap();
    assert_eq!(out, AddResult { sum: 7 });

    // --- `try_call_by_uid` ------------------------------------------
    let mut req2 = DataHandle::new("add").unwrap();
    io::write_json(&mut req2, &AddArgs { a: 50, b: 60 }).unwrap();
    req2.set_position(0).unwrap();

    let mut resp2 = framework::try_call_by_uid(my_uid, &req2, 5000)
        .unwrap()
        .expect("try_call_by_uid must succeed");
    resp2.set_position(0).unwrap();
    let out2: AddResult = io::read_json(&mut resp2).unwrap();
    assert_eq!(out2, AddResult { sum: 110 });

    // --- `notify_by_uid` --------------------------------------------
    let before = notify_count.load(Ordering::SeqCst);
    let mut nreq = DataHandle::new("log").unwrap();
    io::write_json(&mut nreq, &serde_json::json!({"msg": "uid-notify"})).unwrap();
    nreq.set_position(0).unwrap();

    framework::notify_by_uid(my_uid, &nreq).unwrap();
    assert!(
        wait_for_counter(&notify_count, before + 1),
        "notify_by_uid must reach the handler",
    );

    // --- `sequenced_notify_by_uid` ----------------------------------
    let before = notify_count.load(Ordering::SeqCst);
    let mut sreq = DataHandle::new("log").unwrap();
    io::write_json(&mut sreq, &serde_json::json!({"msg": "uid-seq"})).unwrap();
    sreq.set_position(0).unwrap();

    framework::sequenced_notify_by_uid(my_uid, &sreq).unwrap();
    assert!(
        wait_for_counter(&notify_count, before + 1),
        "sequenced_notify_by_uid must reach the handler",
    );

    // Note on null UID routing:
    //
    // The C ABI documents null UID as "a valid argument that simply
    // matches no client". In practice the actual wire behaviour is not
    // part of the stable contract — depending on the routing tables,
    // the dispatcher may return an empty response, a lookup error, or
    // a size-0 handle. The Rust binding deliberately does not assert
    // on any particular outcome, and this test does not either. The
    // negative query test (`check_uid(Uid::NULL) == false`) lives in
    // the query test below, where the contract is well-defined.

    // --- Teardown ---------------------------------------------------
    drop(sreq);
    drop(nreq);
    drop(resp2);
    drop(req2);
    drop(resp);
    drop(req);
    drop(app);

    framework::exit_main_thread();
    framework::shutdown();
}

// ============================================================================
// Test 3 — P2PName addressing
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn p2pname_addressing_e2e() {
    if !have_native() {
        return;
    }

    const GROUP: &str = "rust_p2pname_e2e_group";

    options::set_p2p_name(GROUP).unwrap();
    options::set_wait_connection_ready_ok(false).unwrap();
    options::set_overlap_connection(true).unwrap();
    options::set_quiet(true).unwrap();

    let endpoint = unique_endpoint("rust_p2pname");

    framework::reset_prepare();

    let app = AppHandle::new("RustP2PNameE2E", "p2pname addressing").unwrap();

    app.register_call("add", "add two ints", add_handler).unwrap();

    let notify_count = Arc::new(AtomicUsize::new(0));
    let notify_clone = Arc::clone(&notify_count);
    app.register_notify("log", "increment counter", move |_input| {
        notify_clone.fetch_add(1, Ordering::SeqCst);
    })
    .unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    // --- Wait for the group to appear on the mesh -------------------
    assert!(
        wait_until(|| framework::check_p2p_name(GROUP).unwrap_or(false)),
        "P2P group must become routable within 6 seconds",
    );
    assert!(
        wait_until(|| framework::check_p2p_name_api(GROUP, "add").unwrap_or(false)),
        "P2P group API 'add' must become routable",
    );

    // --- `call_by_p2p_name` -----------------------------------------
    let mut req = DataHandle::new("add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 11, b: 22 }).unwrap();
    req.set_position(0).unwrap();

    let mut resp = framework::call_by_p2p_name(GROUP, &req, 5000).unwrap();
    assert!(
        resp.size().unwrap() > 0,
        "call_by_p2p_name must return a non-empty response",
    );
    resp.set_position(0).unwrap();
    let out: AddResult = io::read_json(&mut resp).unwrap();
    assert_eq!(out, AddResult { sum: 33 });

    // --- `try_call_by_p2p_name` -------------------------------------
    let mut req2 = DataHandle::new("add").unwrap();
    io::write_json(&mut req2, &AddArgs { a: 1, b: 2 }).unwrap();
    req2.set_position(0).unwrap();

    let mut resp2 = framework::try_call_by_p2p_name(GROUP, &req2, 5000)
        .unwrap()
        .expect("try_call_by_p2p_name must succeed");
    resp2.set_position(0).unwrap();
    let out2: AddResult = io::read_json(&mut resp2).unwrap();
    assert_eq!(out2, AddResult { sum: 3 });

    // --- `notify_by_p2p_name` ---------------------------------------
    let before = notify_count.load(Ordering::SeqCst);
    let mut nreq = DataHandle::new("log").unwrap();
    io::write_json(&mut nreq, &serde_json::json!({"msg": "p2p-notify"})).unwrap();
    nreq.set_position(0).unwrap();

    framework::notify_by_p2p_name(GROUP, &nreq).unwrap();
    assert!(
        wait_for_counter(&notify_count, before + 1),
        "notify_by_p2p_name must reach the handler",
    );

    // --- `sequenced_notify_by_p2p_name` -----------------------------
    let before = notify_count.load(Ordering::SeqCst);
    let mut sreq = DataHandle::new("log").unwrap();
    io::write_json(&mut sreq, &serde_json::json!({"msg": "p2p-seq"})).unwrap();
    sreq.set_position(0).unwrap();

    framework::sequenced_notify_by_p2p_name(GROUP, &sreq).unwrap();
    assert!(
        wait_for_counter(&notify_count, before + 1),
        "sequenced_notify_by_p2p_name must reach the handler",
    );

    // --- A nonexistent group must return Ok(None) -------------------
    let absent =
        framework::try_call_by_p2p_name("__absent_group_in_tests__", &req, 1000)
            .unwrap();
    assert!(
        absent.is_none(),
        "calling an absent P2P group must produce Ok(None)",
    );

    // --- Teardown ---------------------------------------------------
    drop(sreq);
    drop(nreq);
    drop(resp2);
    drop(req2);
    drop(resp);
    drop(req);
    drop(app);

    framework::exit_main_thread();
    framework::shutdown();

    // Restore the default P2P name for the next test.
    let _ = options::set_p2p_name("");
}

// ============================================================================
// Test 4 — Process-wide P2P registration
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn p2p_registration_e2e() {
    if !have_native() {
        return;
    }

    const GROUP: &str = "rust_p2p_registration_e2e_group";

    options::set_p2p_name(GROUP).unwrap();
    options::set_wait_connection_ready_ok(false).unwrap();
    options::set_overlap_connection(true).unwrap();
    options::set_quiet(true).unwrap();

    let endpoint = unique_endpoint("rust_p2p_reg");

    framework::reset_prepare();

    let app = AppHandle::new("RustP2PRegE2E", "p2p registration").unwrap();

    // A whoami on the App namespace so the test can obtain its own UID.
    app.register_call("whoami", "identity probe", whoami_handler)
        .unwrap();

    // The P2P namespace registrations. These are reachable only via
    // UID or P2PName addressing.
    p2p::register_p2p_call("p2p_add", "p2p add two ints", add_handler)
        .unwrap();

    let p2p_notify_count = Arc::new(AtomicUsize::new(0));
    let p2p_notify_clone = Arc::clone(&p2p_notify_count);
    p2p::register_p2p_notify(
        "p2p_log",
        "p2p increment counter",
        move |_input| {
            p2p_notify_clone.fetch_add(1, Ordering::SeqCst);
        },
    )
    .unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    // --- Obtain our own UID -----------------------------------------
    assert!(wait_until(|| framework::check_api("RustP2PRegE2E", "whoami").unwrap_or(false)));

    let mut probe_req = DataHandle::new("whoami").unwrap();
    io::write_json(&mut probe_req, &WhoamiArgs::default()).unwrap();
    probe_req.set_position(0).unwrap();

    let mut probe_resp = framework::call("RustP2PRegE2E", &probe_req, 5000).unwrap();
    assert!(probe_resp.size().unwrap() > 0);
    probe_resp.set_position(0).unwrap();
    let who: WhoamiResult = io::read_json(&mut probe_resp).unwrap();
    let my_uid = Uid::from_hex(&who.uid_hex).unwrap();

    assert!(
        wait_until(|| framework::check_uid(my_uid).unwrap_or(false)),
        "own UID must become routable",
    );

    // --- Call the P2P API via UID -----------------------------------
    let mut req = DataHandle::new("p2p_add").unwrap();
    io::write_json(&mut req, &AddArgs { a: 7, b: 8 }).unwrap();
    req.set_position(0).unwrap();

    let mut resp = framework::call_by_uid(my_uid, &req, 5000).unwrap();
    assert!(
        resp.size().unwrap() > 0,
        "P2P API must respond when reached via UID",
    );
    resp.set_position(0).unwrap();
    let out: AddResult = io::read_json(&mut resp).unwrap();
    assert_eq!(out, AddResult { sum: 15 });

    // --- Notify the P2P API via UID ---------------------------------
    let before = p2p_notify_count.load(Ordering::SeqCst);
    let mut nreq = DataHandle::new("p2p_log").unwrap();
    io::write_json(&mut nreq, &serde_json::json!({"msg": "p2p-uid-notify"}))
        .unwrap();
    nreq.set_position(0).unwrap();

    framework::notify_by_uid(my_uid, &nreq).unwrap();
    assert!(
        wait_for_counter(&p2p_notify_count, before + 1),
        "P2P notify via UID must reach the handler",
    );

    // --- Unregister round-trip --------------------------------------
    assert!(p2p::unregister_p2p("p2p_add").unwrap());
    assert!(
        !p2p::unregister_p2p("p2p_add").unwrap(),
        "second unregister must return false",
    );

    // Re-register under the same name to prove that the name is
    // reusable after unregister.
    p2p::register_p2p_call("p2p_add", "re-registered", add_handler).unwrap();

    // --- Teardown ---------------------------------------------------
    let _ = p2p::unregister_p2p("p2p_add");
    let _ = p2p::unregister_p2p("p2p_log");

    drop(nreq);
    drop(resp);
    drop(req);
    drop(probe_resp);
    drop(probe_req);
    drop(app);

    framework::exit_main_thread();
    framework::shutdown();

    let _ = options::set_p2p_name("");
}

// ============================================================================
// Test 5 — Query APIs for UID and P2PName
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn query_api_for_uid_and_p2pname_e2e() {
    if !have_native() {
        return;
    }

    const GROUP: &str = "rust_query_api_e2e_group";

    options::set_p2p_name(GROUP).unwrap();
    options::set_wait_connection_ready_ok(false).unwrap();
    options::set_overlap_connection(true).unwrap();
    options::set_quiet(true).unwrap();

    let endpoint = unique_endpoint("rust_query_api");

    framework::reset_prepare();

    let app = AppHandle::new("RustQueryApiE2E", "query api").unwrap();

    app.register_call("whoami", "identity probe", whoami_handler)
        .unwrap();
    app.register_call("add", "add two ints", add_handler).unwrap();

    framework::prepare_service(&endpoint, &endpoint).unwrap();
    framework::prepare_client(&endpoint, Some(&app)).unwrap();
    framework::prepare_done().unwrap();

    // --- Discover our own UID ---------------------------------------
    assert!(wait_until(|| framework::check_api("RustQueryApiE2E", "whoami").unwrap_or(false)));

    let mut probe_req = DataHandle::new("whoami").unwrap();
    io::write_json(&mut probe_req, &WhoamiArgs::default()).unwrap();
    probe_req.set_position(0).unwrap();

    let mut probe_resp = framework::call("RustQueryApiE2E", &probe_req, 5000).unwrap();
    probe_resp.set_position(0).unwrap();
    let who: WhoamiResult = io::read_json(&mut probe_resp).unwrap();
    let my_uid = Uid::from_hex(&who.uid_hex).unwrap();

    // --- check_uid / check_uid_api ----------------------------------
    assert!(
        wait_until(|| framework::check_uid(my_uid).unwrap_or(false)),
        "check_uid must report our own UID as present",
    );
    assert!(
        wait_until(|| framework::check_uid_api(my_uid, "add").unwrap_or(false)),
        "check_uid_api must report our own UID as exposing 'add'",
    );

    // A null UID must never be reported as present.
    assert!(!framework::check_uid(Uid::NULL).unwrap());
    assert!(!framework::check_uid_api(Uid::NULL, "add").unwrap());

    // --- check_p2p_name / check_p2p_name_api ------------------------
    assert!(
        wait_until(|| framework::check_p2p_name(GROUP).unwrap_or(false)),
        "check_p2p_name must report the configured group as present",
    );
    assert!(
        wait_until(|| framework::check_p2p_name_api(GROUP, "add").unwrap_or(false)),
        "check_p2p_name_api must report the group as exposing 'add'",
    );

    // An absent group must report false.
    assert!(
        !framework::check_p2p_name("__absent_group_in_query_tests__").unwrap(),
    );
    assert!(
        !framework::check_p2p_name_api(
            "__absent_group_in_query_tests__",
            "add",
        )
        .unwrap(),
    );

    // --- check_app / check_api (already covered by test 1, but verify
    //     that the "absent" side still holds here) -------------------
    assert!(!framework::check_app("__absent_app_in_query_tests__").unwrap());
    assert!(
        !framework::check_api("__absent_app_in_query_tests__", "add").unwrap(),
    );

    // --- Teardown ---------------------------------------------------
    drop(probe_resp);
    drop(probe_req);
    drop(app);

    framework::exit_main_thread();
    framework::shutdown();

    let _ = options::set_p2p_name("");
}