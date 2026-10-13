//! End-to-end verification of the P2P identity side data.
//!
//! This file covers the `DataHandle::p2p_uid` / `DataHandle::p2p_name`
//! accessors, which read the sender's injected identity from the
//! **input** handle of a registered callback.
//!
//! The test brings up a same-process service + client pair, sets a
//! known P2P group name, registers a `whoami` API, and calls it. The
//! callback inspects:
//!
//! 1. `input.p2p_uid()` — must be a non-zero 32-byte UID.
//! 2. `input.p2p_name()` — must match the configured P2P group name.
//! 3. `output.p2p_uid()` — must be `Uid::NULL`.
//! 4. `output.p2p_name()` — must be the empty string.
//!
//! The callback writes the observed identity back to the caller, which
//! verifies the round-trip independently.
//!
//! # Running
//!
//! ```text
//! cargo test --test identity_e2e -- --ignored --test-threads=1
//! ```
//!
//! # What this file does *not* test
//!
//! - Cross-process identity propagation. The service and the client
//!   share a process here, so the mesh takes its local-first routing
//!   path. Local calls still inject identity (documented behaviour),
//!   so the assertion is meaningful; but a cross-process hop would
//!   require two OS processes and is out of scope for a Rust
//!   integration test.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use lingofuse::app_handle::AppHandle;
use lingofuse::data_handle::DataHandle;
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

/// Polls a predicate every 200 ms, up to 30 times (6 seconds total).
///
/// Used to wait for the mesh broadcast to reach the local cache. The
/// broadcast delay is documented as approximately 3 seconds, so 6
/// seconds gives a comfortable margin.
fn wait_until<F: FnMut() -> bool>(mut predicate: F) -> bool {
    for _ in 0..30 {
        if predicate() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    false
}

// ============================================================================
// Payloads
// ============================================================================

/// Empty request payload for `whoami`.
#[derive(Serialize, Deserialize, Debug, Default)]
struct WhoamiArgs {}

/// Response payload describing the caller's identity as observed by
/// the callback, plus a second pair of fields describing what the
/// callback observed on the **output** handle (which must be zero /
/// empty).
#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct WhoamiResult {
    /// Hex form of `input.p2p_uid()`.
    input_uid_hex: String,
    /// `input.p2p_name()`.
    input_name: String,
    /// `true` when `input.p2p_uid()` was a non-null UID.
    input_uid_is_non_null: bool,
    /// Hex form of `output.p2p_uid()`.
    output_uid_hex: String,
    /// `output.p2p_name()`.
    output_name: String,
    /// `true` when `output.p2p_uid()` was `Uid::NULL`.
    output_uid_is_null: bool,
}

// ============================================================================
// Test 1 — callback reads the sender's identity
// ============================================================================

#[test]
#[ignore = "starts the process-global framework; run with --ignored --test-threads=1"]
fn identity_roundtrip() {
    if !have_native() {
        return;
    }

    // A stable, non-empty P2P group name so that the injected name is
    // distinguishable from the "unset" default.
    const P2P_GROUP: &str = "rust_identity_e2e_group";

    // Options must be set before `prepare_done`; the P2P name is
    // reported to the server through the initial `Update_UID` command,
    // and is also injected into every outbound payload.
    options::set_p2p_name(P2P_GROUP).unwrap();
    framework::set_option("Wait_Connection_ReadyOk", "False").unwrap();
    framework::set_option("Overlap_Connection", "True").unwrap();
    framework::set_option("Quiet", "True").unwrap();

    let endpoint = unique_endpoint("rust_identity_e2e");

    framework::reset_prepare();

    let app = AppHandle::new("RustIdentityE2EApp", "identity side-data test")
        .unwrap();

    // --- Register the whoami API ------------------------------------
    app.register_call(
        "whoami",
        "echo caller identity and probe output handle",
        |input, output| {
            // The `input` handle carries the injected sender identity.
            let in_uid = input.p2p_uid().unwrap_or_default();
            let in_name = input.p2p_name().unwrap_or_default();

            // The `output` handle carries no side data; both accessors
            // must return the documented zero / empty values.
            let out_uid = output.p2p_uid().unwrap_or_default();
            let out_name = output.p2p_name().unwrap_or_default();

            let payload = WhoamiResult {
                input_uid_hex: in_uid.to_hex(),
                input_name: in_name,
                input_uid_is_non_null: !in_uid.is_null(),
                output_uid_hex: out_uid.to_hex(),
                output_name: out_name,
                output_uid_is_null: out_uid.is_null(),
            };
            let _ = io::write_json(output, &payload);
        },
    )
    .unwrap();

    // --- Mesh setup -------------------------------------------------
    let service_tag = framework::prepare_service(&endpoint, &endpoint)
        .expect("prepare_service failed");
    assert!(service_tag >= 0);

    let client_tag = framework::prepare_client(&endpoint, Some(&app))
        .expect("prepare_client failed");
    assert!(client_tag >= 0);

    let started = framework::prepare_done().expect("prepare_done failed");
    assert!(started, "first prepare_done must return Ok(true)");

    // --- Wait for the mesh broadcast to reach the local cache -------
    //
    // `prepare_done` returns as soon as the simulated main thread has
    // started; the API-info broadcast that makes our own app visible
    // takes a moment to reach the local cache. Without this wait, the
    // first `call` sees an empty routing table and returns a size-0
    // handle even though the app is registered.
    assert!(
        wait_until(|| {
            framework::check_api("RustIdentityE2EApp", "whoami").unwrap_or(false)
        }),
        "App must become visible on the mesh within 6 seconds",
    );

    // --- Call whoami from the same process --------------------------
    let mut req = DataHandle::new("whoami").unwrap();
    io::write_json(&mut req, &WhoamiArgs::default()).unwrap();
    req.set_position(0).unwrap();

    // Local-first routing: the App exists in this process, so the call
    // is served locally. Local calls still inject identity on the
    // input handle (documented behaviour).
    let mut resp = framework::call("RustIdentityE2EApp", &req, 5000)
        .expect("call to whoami must not fail at the transport level");
    assert!(
        resp.size().unwrap() > 0,
        "whoami must return a non-empty response",
    );
    resp.set_position(0).unwrap();

    let result: WhoamiResult = io::read_json(&mut resp)
        .expect("whoami response must be valid JSON");

    // --- Assertions on the input side ------------------------------
    assert!(
        result.input_uid_is_non_null,
        "input.p2p_uid() must be non-null inside a callback",
    );
    assert_eq!(
        result.input_uid_hex.len(),
        64,
        "input UID hex must be 64 characters long",
    );
    assert!(
        result.input_uid_hex.chars().all(|c| c.is_ascii_hexdigit()),
        "input UID hex must contain only hex digits, got {:?}",
        result.input_uid_hex,
    );

    // A freshly generated UID must not be all zeros; the earlier
    // `is_null` check already implies that, but the explicit hex
    // assertion guards against a hypothetical "all-F" bug.
    let all_zero_hex = "0".repeat(64);
    assert_ne!(
        result.input_uid_hex, all_zero_hex,
        "input UID must not be all-zero",
    );

    assert_eq!(
        result.input_name, P2P_GROUP,
        "input.p2p_name() must echo the configured P2P group name",
    );

    // --- Assertions on the output side -----------------------------
    assert!(
        result.output_uid_is_null,
        "output.p2p_uid() must be Uid::NULL inside a callback",
    );
    assert_eq!(
        result.output_uid_hex, all_zero_hex,
        "output UID hex must be all zeros",
    );
    assert!(
        result.output_name.is_empty(),
        "output.p2p_name() must be empty, got {:?}",
        result.output_name,
    );

    // --- Verify the returned UID parses back ------------------------
    let uid = Uid::from_hex(&result.input_uid_hex)
        .expect("returned UID hex must parse");
    assert!(!uid.is_null());
    assert_eq!(uid.to_hex(), result.input_uid_hex);

    // --- Teardown ---------------------------------------------------
    drop(req);
    drop(resp);
    drop(app);

    framework::exit_main_thread();
    framework::shutdown();

    let _ = options::set_p2p_name("");
}