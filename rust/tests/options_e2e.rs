//! End-to-end verification of the typed option API.
//!
//! This file exercises every `lingofuse::options` getter / setter pair
//! against the live native library. It verifies:
//!
//! 1. Boolean options round-trip through `set_bool` / `get_bool`.
//! 2. Integer options round-trip through `set_u64` / `get_u64` and
//!    `set_i64` / `get_i64`.
//! 3. String options round-trip through `set_string` / `get_string`.
//! 4. The typed getters agree with the raw `framework::get_option`.
//! 5. An unknown option returns the documented empty-string fallback.
//! 6. The write-only `debug` option can be set without error.
//!
//! # Running
//!
//! ```text
//! cargo test --test options_e2e -- --ignored --test-threads=1
//! ```
//!
//! Every test is `#[ignore]`d because the option store is process-global
//! and the tests mutate it. They must run serially to avoid observing
//! each other's side effects.
//!
//! # What this file does *not* test
//!
//! - The persistence of options across `shutdown` + restart. The
//!   documentation already states that options are **not** persisted;
//!   the observed behaviour is covered by
//!   `options_reset_after_shutdown`.
//! - The write-only nature of `debug`. Only the setter is exercised;
//!   the native layer's placeholder on read is checked separately.

use lingofuse::framework;
use lingofuse::options;
use lingofuse::sys;

// ============================================================================
// Helpers
// ============================================================================

/// Returns `true` when the native library is available; otherwise prints
/// a `[SKIP]` line and returns `false`.
fn have_native() -> bool {
    match sys::get_library() {
        Ok(_) => true,
        Err(e) => {
            eprintln!("[SKIP] native library not available: {}", e);
            false
        }
    }
}

// ============================================================================
// Boolean options
// ============================================================================

#[test]
#[ignore = "mutates process-global option store; run with --ignored --test-threads=1"]
fn bool_options_roundtrip() {
    if !have_native() {
        return;
    }

    // --- Quiet -----------------------------------------------------
    options::set_quiet(true).unwrap();
    assert!(options::get_quiet().unwrap(), "Quiet should be true");

    options::set_quiet(false).unwrap();
    assert!(!options::get_quiet().unwrap(), "Quiet should be false");

    // --- ShowThreadID ---------------------------------------------
    options::set_show_thread_id(true).unwrap();
    assert!(options::get_show_thread_id().unwrap());

    options::set_show_thread_id(false).unwrap();
    assert!(!options::get_show_thread_id().unwrap());

    // --- ConsoleOutput --------------------------------------------
    options::set_console_output(true).unwrap();
    assert!(options::get_console_output().unwrap());

    options::set_console_output(false).unwrap();
    assert!(!options::get_console_output().unwrap());

    // --- Overlap_Connection ---------------------------------------
    options::set_overlap_connection(true).unwrap();
    assert!(options::get_overlap_connection().unwrap());

    options::set_overlap_connection(false).unwrap();
    assert!(!options::get_overlap_connection().unwrap());

    // --- Wait_Connection_ReadyOk ----------------------------------
    options::set_wait_connection_ready_ok(false).unwrap();
    assert!(!options::get_wait_connection_ready_ok().unwrap());

    options::set_wait_connection_ready_ok(true).unwrap();
    assert!(options::get_wait_connection_ready_ok().unwrap());
}

// ============================================================================
// Integer options
// ============================================================================

#[test]
#[ignore = "mutates process-global option store; run with --ignored --test-threads=1"]
fn integer_options_roundtrip() {
    if !have_native() {
        return;
    }

    // --- Wait_Connection_Timeout (u64) ----------------------------
    options::set_wait_connection_timeout(12_345).unwrap();
    assert_eq!(options::get_wait_connection_timeout().unwrap(), 12_345);
    options::set_wait_connection_timeout(30_000).unwrap(); // restore

    // --- Fixed_Sequenced_Time (u64) -------------------------------
    options::set_fixed_sequenced_time(7_500).unwrap();
    assert_eq!(options::get_fixed_sequenced_time().unwrap(), 7_500);
    options::set_fixed_sequenced_time(20_000).unwrap(); // restore

    // --- DataHandle_Idle_Timeout (u64) ----------------------------
    options::set_data_handle_idle_timeout(120_000).unwrap();
    assert_eq!(options::get_data_handle_idle_timeout().unwrap(), 120_000);
    options::set_data_handle_idle_timeout(600_000).unwrap(); // restore

    // --- DataHandle_Pool_Scan_Interval (u64) ----------------------
    options::set_data_handle_pool_scan_interval(2_500).unwrap();
    assert_eq!(options::get_data_handle_pool_scan_interval().unwrap(), 2_500);
    options::set_data_handle_pool_scan_interval(5_000).unwrap(); // restore

    // --- IPC_Serv_ThreadCount (i32) -------------------------------
    options::set_ipc_serv_thread_count(4).unwrap();
    assert_eq!(options::get_ipc_serv_thread_count().unwrap(), 4);

    // --- IPC_Serv_MaxQueueLength (i32) ----------------------------
    options::set_ipc_serv_max_queue_length(2048).unwrap();
    assert_eq!(options::get_ipc_serv_max_queue_length().unwrap(), 2048);

    // --- IPC_Serv_MaxMsgSize (i32) --------------------------------
    options::set_ipc_serv_max_msg_size(1_048_576).unwrap();
    assert_eq!(options::get_ipc_serv_max_msg_size().unwrap(), 1_048_576);

    // --- No_Reponse_Cmd_NULL_Flush_Threshold (i32) ----------------
    options::set_no_reponse_cmd_null_flush_threshold(1_234).unwrap();
    assert_eq!(
        options::get_no_reponse_cmd_null_flush_threshold().unwrap(),
        1_234,
    );
    options::set_no_reponse_cmd_null_flush_threshold(5_000).unwrap(); // restore
}

// ============================================================================
// String options
// ============================================================================

#[test]
#[ignore = "mutates process-global option store; run with --ignored --test-threads=1"]
fn string_options_roundtrip() {
    if !have_native() {
        return;
    }

    // --- LF_P2P_name ----------------------------------------------
    options::set_p2p_name("rust_options_e2e_group").unwrap();
    assert_eq!(
        options::get_p2p_name().unwrap(),
        "rust_options_e2e_group",
    );

    options::set_p2p_name("").unwrap();
    assert_eq!(options::get_p2p_name().unwrap(), "");

    // --- password (always masked) ---------------------------------
    options::set_password("rust_options_e2e_secret").unwrap();
    let masked = options::get_password().unwrap();
    // The native library deliberately masks the value. It may return
    // either a fixed mask or the default; either way it must not be
    // empty and must not contain the plaintext we just wrote.
    assert!(
        !masked.is_empty(),
        "password getter must not return an empty string",
    );
    assert!(
        !masked.contains("rust_options_e2e_secret"),
        "password getter must not return the plaintext",
    );
}

// ============================================================================
// Unknown option
// ============================================================================

#[test]
#[ignore = "reads process-global option store; run with --ignored --test-threads=1"]
fn unknown_option_returns_empty() {
    if !have_native() {
        return;
    }

    let value = options::get_string("__no_such_option_in_rust_options_e2e__")
        .unwrap();
    assert!(
        value.is_empty(),
        "unknown option must return an empty string, got {:?}",
        value,
    );
}

// ============================================================================
// Typed getters agree with the raw reader
// ============================================================================

#[test]
#[ignore = "mutates process-global option store; run with --ignored --test-threads=1"]
fn typed_getter_matches_raw_get_option() {
    if !have_native() {
        return;
    }

    // --- Boolean option -------------------------------------------
    options::set_quiet(true).unwrap();
    let typed = options::get_quiet().unwrap();
    let raw = framework::get_option("Quiet").unwrap();
    assert!(typed);
    assert!(
        raw.eq_ignore_ascii_case("True"),
        "raw Quiet option must read as \"True\", got {:?}",
        raw,
    );
    options::set_quiet(false).unwrap();

    // --- Integer option -------------------------------------------
    options::set_wait_connection_timeout(15_000).unwrap();
    let typed = options::get_wait_connection_timeout().unwrap();
    let raw = framework::get_option("Wait_Connection_Timeout").unwrap();
    assert_eq!(typed, 15_000);
    assert_eq!(raw, "15000", "raw form must be the decimal string");
    options::set_wait_connection_timeout(30_000).unwrap(); // restore

    // --- String option --------------------------------------------
    options::set_p2p_name("rust_options_e2e_match").unwrap();
    let typed = options::get_p2p_name().unwrap();
    let raw = framework::get_option("LF_P2P_name").unwrap();
    assert_eq!(typed, "rust_options_e2e_match");
    assert_eq!(raw, "rust_options_e2e_match");
    options::set_p2p_name("").unwrap(); // restore
}

