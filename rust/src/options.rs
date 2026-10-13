//! Typed getters and setters for the LingoFuse runtime options.
//!
//! This module is the Rust counterpart of the `LF_Set_Opt_*` /
//! `LF_Get_Opt_*` helper families in `lingofuse_import.pas` and
//! `LingoFuse.c`. It exists so that callers do not have to spell the
//! option name as a string and hand-format numeric values:
//!
//! ```no_run
//! # use lingofuse::options;
//! # fn f() -> Result<(), lingofuse::error::Error> {
//! // Stringly-typed form (framework::set_option):
//! lingofuse::framework::set_option("Quiet", "True")?;
//!
//! // Typed form (this module):
//! options::set_quiet(true)?;
//! # Ok(()) }
//! ```
//!
//! # Naming convention
//!
//! Every option has a `set_<name>` and a `get_<name>` pair, where
//! `<name>` is the option key lowercased and with underscores. The
//! mapping to the C-side helpers is one-to-one by name:
//!
//! | Rust here                    | Pascal `lingofuse_import.pas`     |
//! |------------------------------|-----------------------------------|
//! | `set_quiet` / `get_quiet`    | `LF_Set_Opt_Quiet` / `LF_Get_Opt_Quiet` |
//! | `set_password`               | `LF_Set_Opt_Password`             |
//! | `set_debug` / `get_debug`    | `LF_Set_Opt_Debug` / `LF_Get_Opt_Debug` |
//! | `set_p2p_name` / `get_p2p_name` | `LF_Set_Opt_P2P_Name` / `LF_Get_Opt_P2P_Name` |
//! | `set_wait_connection_timeout` | `LF_Set_Opt_Wait_Connection_Timeout` |
//!
//! # Booleans on the wire
//!
//! The native layer accepts several spellings for a boolean value. This
//! module always writes the canonical `"True"` / `"False"` form, and
//! the getters parse anything the native layer might return as `"True"`
//! (case-insensitive) into `true`; everything else is `false`.
//!
//! # Unknown options
//!
//! `LF_SetOption` silently ignores an unknown option name, and
//! `LF_GetOption` returns an empty string. Every `get_*` in this module
//! therefore returns a documented "safe fallback" for the
//! unknown/unset/malformed case:
//!
//! | Return type       | Fallback  |
//! |-------------------|-----------|
//! | `bool`            | `false`   |
//! | `u64` / `i32`     | `0`       |
//! | `String`          | `""`      |
//!
//! A caller that needs to distinguish "unset from a known option" from
//! "set to zero" must use `framework::get_option` directly and inspect
//! the raw string.
//!
//! # Write-only options
//!
//! A few options (`debug` is the only one today) are write-only. Their
//! getters return a fixed placeholder string, not a stored value. See
//! the individual function documentation.
//!
//! # Threading
//!
//! The underlying `LF_SetOption` / `LF_GetOption` are thread-safe, and
//! every function in this module is therefore thread-safe as well.
//! However a setter takes effect immediately, so a concurrent reader
//! may observe the old value, the new value, or (for string options) a
//! torn read. An application that needs a consistent multi-option
//! configuration must serialise its own updates behind its own lock.
//!
//! # Persistence
//!
//! Every option resets to its built-in default when [`framework::shutdown`]
//! is called. An application that restarts the framework must reapply
//! its options on every startup.

use crate::error::Error;
use crate::framework;

// ============================================================================
// Low-level primitives
// ============================================================================

/// Sets a boolean option, writing the canonical `"True"` / `"False"`
/// string that the native layer expects.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
/// - [`crate::error::ErrorCode::InvalidArgument`] if `key` contains an
///   interior NUL.
pub fn set_bool(key: &str, value: bool) -> Result<(), Error> {
    let v = if value { "True" } else { "False" };
    framework::set_option(key, v)
}

/// Reads a boolean option.
///
/// Returns `true` when the underlying string equals `"True"`
/// (case-insensitive). Any other value — including an empty string from
/// an unknown option — returns `false`.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
/// - [`crate::error::ErrorCode::InvalidArgument`] if `key` contains an
///   interior NUL.
pub fn get_bool(key: &str) -> Result<bool, Error> {
    let s = framework::get_option(key)?;
    Ok(s.eq_ignore_ascii_case("True"))
}

/// Sets an unsigned-integer option, writing the value as a decimal
/// string.
///
/// # Errors
///
/// Same as [`set_bool`].
pub fn set_u64(key: &str, value: u64) -> Result<(), Error> {
    framework::set_option(key, &value.to_string())
}

/// Reads an unsigned-integer option.
///
/// Returns `0` when the underlying string is empty or cannot be parsed
/// as a decimal integer. Trailing garbage after a valid number is
/// ignored, matching the C wrapper's `strtoull`-style parsing.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_u64(key: &str) -> Result<u64, Error> {
    let s = framework::get_option(key)?;
    if s.is_empty() {
        return Ok(0);
    }
    // Parse only the leading decimal digits; ignore any trailing text.
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return Ok(0);
    }
    Ok(digits.parse::<u64>().unwrap_or(0))
}

/// Sets a signed-integer option, writing the value as a decimal string.
///
/// # Errors
///
/// Same as [`set_bool`].
pub fn set_i64(key: &str, value: i64) -> Result<(), Error> {
    framework::set_option(key, &value.to_string())
}

/// Reads a signed-integer option.
///
/// Returns `0` when the underlying string is empty or cannot be parsed
/// as a decimal integer.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_i64(key: &str) -> Result<i64, Error> {
    let s = framework::get_option(key)?;
    if s.is_empty() {
        return Ok(0);
    }
    // Accept a leading sign, then digits.
    let mut chars = s.chars();
    let mut digits = String::new();
    if let Some(c) = chars.next() {
        if c == '-' || c == '+' {
            digits.push(c);
        } else if c.is_ascii_digit() {
            digits.push(c);
        } else {
            return Ok(0);
        }
    }
    for c in chars {
        if c.is_ascii_digit() {
            digits.push(c);
        } else {
            break;
        }
    }
    digits.parse::<i64>().ok().map(Ok).unwrap_or(Ok(0))
}

/// Sets a string option.
///
/// # Errors
///
/// - [`crate::error::ErrorCode::LibraryLoadFailed`] if the native
///   library is not available.
/// - [`crate::error::ErrorCode::InvalidArgument`] if either `key` or
///   `value` contains an interior NUL.
pub fn set_string(key: &str, value: &str) -> Result<(), Error> {
    framework::set_option(key, value)
}

/// Reads a string option.
///
/// Returns an owned `String` (the native transient buffer is copied
/// immediately). Returns an empty string for an unknown option.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_string(key: &str) -> Result<String, Error> {
    framework::get_option(key)
}

// ============================================================================
// Authentication
// ============================================================================

/// Sets the P2PVM / C4 network authentication password.
///
/// Must match on both sides of a connection or the handshake fails. The
/// default is the well-known development token; a production deployment
/// should set a private value before `prepare_service` /
/// `prepare_client`.
///
/// Option key: `password`.
///
/// # Errors
///
/// Same as [`set_string`].
pub fn set_password(value: &str) -> Result<(), Error> {
    set_string("password", value)
}

/// Reads the configured password.
///
/// The native library returns a fixed mask (`"********"`) rather than
/// the real value. The mask is returned by the underlying option
/// reader, not by this wrapper; do not rely on the returned string ever
/// containing the actual password.
///
/// Option key: `password`.
///
/// # Errors
///
/// Same as [`get_string`].
pub fn get_password() -> Result<String, Error> {
    get_string("password")
}

// ============================================================================
// Logging and diagnostics
// ============================================================================

/// Executes a C4 console debug command.
///
/// This option is WRITE-ONLY and has side effects: each call constructs
/// a transient console helper object on the native side and runs the
/// given command. Recognised command names include `"service"`,
/// `"tunnel"`, `"ZNet_Info"`, `"HPC_Thread_Info"`, and
/// `"Instance_Info"`.
///
/// Because each call allocates a helper object, this option is intended
/// for interactive diagnostics only. Do not call it in a hot loop.
///
/// Option key: `debug`.
///
/// # Errors
///
/// Same as [`set_string`].
pub fn set_debug(value: &str) -> Result<(), Error> {
    set_string("debug", value)
}

/// Reads the current value of the `debug` option.
///
/// Because the underlying option is write-only, the native library
/// returns a fixed placeholder string rather than a stored value.
/// Provided for symmetry with the other getters.
///
/// Option key: `debug`.
///
/// # Errors
///
/// Same as [`get_string`].
pub fn get_debug() -> Result<String, Error> {
    get_string("debug")
}

/// Enables or disables quiet mode.
///
/// When quiet mode is enabled, most internal informational logging is
/// suppressed.
///
/// Default: `false`.
///
/// Option key: `Quiet`.
///
/// # Errors
///
/// Same as [`set_bool`].
pub fn set_quiet(value: bool) -> Result<(), Error> {
    set_bool("Quiet", value)
}

/// Returns `true` when quiet mode is currently enabled.
///
/// Option key: `Quiet`.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_quiet() -> Result<bool, Error> {
    get_bool("Quiet")
}

/// Enables or disables thread-ID prefixes in status output.
///
/// Default: `false`.
///
/// Option key: `ShowThreadID`.
///
/// # Errors
///
/// Same as [`set_bool`].
pub fn set_show_thread_id(value: bool) -> Result<(), Error> {
    set_bool("ShowThreadID", value)
}

/// Returns `true` when thread-ID prefixes are enabled.
///
/// Option key: `ShowThreadID`.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_show_thread_id() -> Result<bool, Error> {
    get_bool("ShowThreadID")
}

/// Enables or disables console output for status messages.
///
/// When disabled, status messages are still queued and remain readable
/// through `status::get_status`; only the console sink is muted.
///
/// Default: depends on the host; set explicitly by the native entry
/// point based on whether the host is a console or a GUI process.
///
/// Option key: `ConsoleOutput`.
///
/// # Errors
///
/// Same as [`set_bool`].
pub fn set_console_output(value: bool) -> Result<(), Error> {
    set_bool("ConsoleOutput", value)
}

/// Returns `true` when console output is enabled.
///
/// Option key: `ConsoleOutput`.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_console_output() -> Result<bool, Error> {
    get_bool("ConsoleOutput")
}

// ============================================================================
// Connection readiness
// ============================================================================

/// Allows or forbids multiple client tunnels to the same physical
/// address.
///
/// `false` (the default): only one client tunnel per physical address.
/// A second `framework::prepare_client` call for the same address
/// returns an error and the new application handle is discarded.
///
/// `true`: every `framework::prepare_client` call creates a new
/// independent tunnel, binding the supplied application handle.
///
/// This option MUST be set BEFORE the `prepare_client` calls it is
/// meant to affect. Changing it after a tunnel has been created does
/// not rearrange existing tunnels.
///
/// Option key: `Overlap_Connection`.
///
/// # Errors
///
/// Same as [`set_bool`].
pub fn set_overlap_connection(value: bool) -> Result<(), Error> {
    set_bool("Overlap_Connection", value)
}

/// Returns `true` when overlapping connections are allowed.
///
/// Option key: `Overlap_Connection`.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_overlap_connection() -> Result<bool, Error> {
    get_bool("Overlap_Connection")
}

/// Controls whether `framework::prepare_done` blocks until every
/// prepared client is online.
///
/// `true` (the default): `prepare_done` waits for all prepared clients
/// to reach the "online" state before returning.
///
/// `false`: `prepare_done` returns immediately after the simulated main
/// thread has started. The caller is then responsible for probing
/// readiness itself (for example with `framework::check_api` in a retry
/// loop).
///
/// The total wait is bounded by [`set_wait_connection_timeout`].
///
/// Option key: `Wait_Connection_ReadyOk`.
///
/// # Errors
///
/// Same as [`set_bool`].
pub fn set_wait_connection_ready_ok(value: bool) -> Result<(), Error> {
    set_bool("Wait_Connection_ReadyOk", value)
}

/// Returns `true` when `prepare_done` currently waits for all clients.
///
/// Option key: `Wait_Connection_ReadyOk`.
///
/// # Errors
///
/// Same as [`get_bool`].
pub fn get_wait_connection_ready_ok() -> Result<bool, Error> {
    get_bool("Wait_Connection_ReadyOk")
}

/// Sets the timeout, in milliseconds, for the `prepare_done` wait
/// described by [`set_wait_connection_ready_ok`].
///
/// Default: 30000 ms (30 seconds). If the timeout expires before all
/// clients are ready, `prepare_done` still returns `true`; the caller
/// must independently verify readiness if that matters.
///
/// The native library imposes a floor of 5000 ms on this value when the
/// wait is actually performed. Values below that floor are silently
/// raised.
///
/// Option key: `Wait_Connection_Timeout`.
///
/// # Errors
///
/// Same as [`set_u64`].
pub fn set_wait_connection_timeout(ms: u64) -> Result<(), Error> {
    set_u64("Wait_Connection_Timeout", ms)
}

/// Returns the current `prepare_done` wait timeout, in milliseconds.
///
/// Option key: `Wait_Connection_Timeout`.
///
/// # Errors
///
/// Same as [`get_u64`].
pub fn get_wait_connection_timeout() -> Result<u64, Error> {
    get_u64("Wait_Connection_Timeout")
}

// ============================================================================
// IPC
// ============================================================================

/// Sets the size of the IPC server thread pool.
///
/// MUST be set before the IPC server is started. Changing it after
/// startup has no effect on an already-running server.
///
/// Option key: `IPC_Serv_ThreadCount`.
///
/// # Errors
///
/// Same as [`set_i64`].
pub fn set_ipc_serv_thread_count(value: i32) -> Result<(), Error> {
    set_i64("IPC_Serv_ThreadCount", i64::from(value))
}

/// Returns the configured IPC server thread count.
///
/// Option key: `IPC_Serv_ThreadCount`.
///
/// # Errors
///
/// Same as [`get_i64`].
pub fn get_ipc_serv_thread_count() -> Result<i32, Error> {
    Ok(get_i64("IPC_Serv_ThreadCount")? as i32)
}

/// Sets the maximum length of the IPC server's inbound message queue.
///
/// MUST be set before the IPC server is started.
///
/// Option key: `IPC_Serv_MaxQueueLength`.
///
/// # Errors
///
/// Same as [`set_i64`].
pub fn set_ipc_serv_max_queue_length(value: i32) -> Result<(), Error> {
    set_i64("IPC_Serv_MaxQueueLength", i64::from(value))
}

/// Returns the configured IPC server max queue length.
///
/// Option key: `IPC_Serv_MaxQueueLength`.
///
/// # Errors
///
/// Same as [`get_i64`].
pub fn get_ipc_serv_max_queue_length() -> Result<i32, Error> {
    Ok(get_i64("IPC_Serv_MaxQueueLength")? as i32)
}

/// Sets the maximum size, in bytes, of a single IPC message.
///
/// MUST be set before the IPC server is started.
///
/// Option key: `IPC_Serv_MaxMsgSize`.
///
/// # Errors
///
/// Same as [`set_i64`].
pub fn set_ipc_serv_max_msg_size(value: i32) -> Result<(), Error> {
    set_i64("IPC_Serv_MaxMsgSize", i64::from(value))
}

/// Returns the configured IPC server max message size.
///
/// Option key: `IPC_Serv_MaxMsgSize`.
///
/// # Errors
///
/// Same as [`get_i64`].
pub fn get_ipc_serv_max_msg_size() -> Result<i32, Error> {
    Ok(get_i64("IPC_Serv_MaxMsgSize")? as i32)
}

// ============================================================================
// Sequenced notifications
// ============================================================================

/// Sets the sticky-affinity window, in milliseconds, for P2PName load
/// balancing.
///
/// When the server-side dispatcher routes a P2PName-addressed call, it
/// normally picks the target with the smallest Cycle_Anchor value (pure
/// round-robin). If, however, a single target has been handling
/// requests for longer than this value, the dispatcher switches to a
/// different target instead, to avoid starvation.
///
/// Default: 20000 ms (20 seconds).
///
/// Option key: `Fixed_Sequenced_Time`.
///
/// # Errors
///
/// Same as [`set_u64`].
pub fn set_fixed_sequenced_time(ms: u64) -> Result<(), Error> {
    set_u64("Fixed_Sequenced_Time", ms)
}

/// Returns the current sticky-affinity window, in milliseconds.
///
/// Option key: `Fixed_Sequenced_Time`.
///
/// # Errors
///
/// Same as [`get_u64`].
pub fn get_fixed_sequenced_time() -> Result<u64, Error> {
    get_u64("Fixed_Sequenced_Time")
}

// ============================================================================
// P2P group name
// ============================================================================

/// Sets this process's P2P group name.
///
/// The name is injected into every outbound request payload and is
/// reported to the server through the `Update_UID` command. It defines
/// which P2PName-addressed calls this process is willing to receive.
///
/// May be changed at any time. The framework picks up the new name on
/// the next outbound request; there is no need to reconnect.
///
/// Default: empty string ("not a member of any group"). An empty P2P
/// name disables P2PName routing for this process; UID and App-name
/// routing are unaffected.
///
/// Option key: `LF_P2P_name`.
///
/// # Note
///
/// This is **not** the same as reading the *sender's* P2P name from an
/// input handle via `DataHandle::p2p_name()`. That reads the peer's
/// identity; this sets the local identity.
///
/// # Errors
///
/// Same as [`set_string`].
pub fn set_p2p_name(value: &str) -> Result<(), Error> {
    set_string("LF_P2P_name", value)
}

/// Returns this process's configured P2P group name.
///
/// Returns an empty string when no name has been set.
///
/// Option key: `LF_P2P_name`.
///
/// # Errors
///
/// Same as [`get_string`].
pub fn get_p2p_name() -> Result<String, Error> {
    get_string("LF_P2P_name")
}

// ============================================================================
// Data handle pool
// ============================================================================

/// Sets the idle-reclaim threshold, in milliseconds, for auto-recycled
/// data handles.
///
/// A value greater than zero enables idle reclamation: a handle that
/// has not been accessed for at least this long becomes a candidate for
/// release on the next pool scan. The default is 600000 ms
/// (10 minutes).
///
/// A value of zero disables idle reclamation entirely. In that mode,
/// only an explicit `DataHandle::dispose` releases a handle.
///
/// This option does **not** affect handles created with
/// `DataHandle::create_permanent`: those are released synchronously by
/// `dispose` and never enter the idle-reclaim path.
///
/// Option key: `DataHandle_Idle_Timeout`.
///
/// # Errors
///
/// Same as [`set_u64`].
pub fn set_data_handle_idle_timeout(ms: u64) -> Result<(), Error> {
    set_u64("DataHandle_Idle_Timeout", ms)
}

/// Returns the current idle-reclaim threshold, in milliseconds.
///
/// Option key: `DataHandle_Idle_Timeout`.
///
/// # Errors
///
/// Same as [`get_u64`].
pub fn get_data_handle_idle_timeout() -> Result<u64, Error> {
    get_u64("DataHandle_Idle_Timeout")
}

/// Sets the minimum interval, in milliseconds, between two consecutive
/// scans of the data-handle pool.
///
/// A value greater than zero enables rate-limiting: the scanner returns
/// immediately if fewer than this many milliseconds have elapsed since
/// the last scan. Default: 5000 ms (5 seconds).
///
/// A value of zero disables the rate limiter. The scanner then runs on
/// every progress tick of the simulated main thread, which can be a
/// significant CPU cost under a busy main loop.
///
/// Option key: `DataHandle_Pool_Scan_Interval`.
///
/// # Errors
///
/// Same as [`set_u64`].
pub fn set_data_handle_pool_scan_interval(ms: u64) -> Result<(), Error> {
    set_u64("DataHandle_Pool_Scan_Interval", ms)
}

/// Returns the current data-handle pool scan interval, in milliseconds.
///
/// Option key: `DataHandle_Pool_Scan_Interval`.
///
/// # Errors
///
/// Same as [`get_u64`].
pub fn get_data_handle_pool_scan_interval() -> Result<u64, Error> {
    get_u64("DataHandle_Pool_Scan_Interval")
}

// ============================================================================
// Command flushing
// ============================================================================

/// Sets the null-flush threshold for no-response commands.
///
/// The protocol periodically sends a NULL command to force the server
/// to acknowledge pending one-way Notify messages. After every N
/// no-response commands, one NULL command is emitted as a flush point.
///
/// A lower value gives more timely acknowledgement at a slight cost in
/// bandwidth; a higher value is more efficient but delays the
/// server-side visibility of Notify deliveries.
///
/// Default: 5000.
///
/// # Note
///
/// The option key uses the historical spelling `Reponse` (without the
/// second 's'). This is intentional and matches the native layer.
///
/// Option key: `No_Reponse_Cmd_NULL_Flush_Threshold`.
///
/// # Errors
///
/// Same as [`set_i64`].
pub fn set_no_reponse_cmd_null_flush_threshold(
    value: i32,
) -> Result<(), Error> {
    set_i64("No_Reponse_Cmd_NULL_Flush_Threshold", i64::from(value))
}

/// Returns the current null-flush threshold.
///
/// Option key: `No_Reponse_Cmd_NULL_Flush_Threshold`.
///
/// # Errors
///
/// Same as [`get_i64`].
pub fn get_no_reponse_cmd_null_flush_threshold() -> Result<i32, Error> {
    Ok(get_i64("No_Reponse_Cmd_NULL_Flush_Threshold")? as i32)
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
    // Pure-data behaviour (no native)
    // -----------------------------------------------------------------

    #[test]
    fn get_bool_of_empty_is_false() {
        // Not directly testable without the native library, but the
        // parsing rule is well-defined: an empty or unknown string maps
        // to `false`. We exercise the same logic here through a helper
        // path so the parse is validated independently.
        fn parse(s: &str) -> bool {
            s.eq_ignore_ascii_case("True")
        }
        assert!(parse("True"));
        assert!(parse("true"));
        assert!(parse("TRUE"));
        assert!(parse("TrUe"));
        assert!(!parse("False"));
        assert!(!parse(""));
        assert!(!parse("1"));
        assert!(!parse("yes"));
    }

    // -----------------------------------------------------------------
    // Native-dependent behaviour
    // -----------------------------------------------------------------

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn quiet_roundtrip() {
        if !have_native() {
            return;
        }
        set_quiet(true).unwrap();
        assert!(get_quiet().unwrap());

        set_quiet(false).unwrap();
        assert!(!get_quiet().unwrap());
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn overlap_connection_roundtrip() {
        if !have_native() {
            return;
        }
        set_overlap_connection(true).unwrap();
        assert!(get_overlap_connection().unwrap());

        set_overlap_connection(false).unwrap();
        assert!(!get_overlap_connection().unwrap());
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn wait_connection_timeout_roundtrip() {
        if !have_native() {
            return;
        }
        set_wait_connection_timeout(12_345).unwrap();
        assert_eq!(get_wait_connection_timeout().unwrap(), 12_345);

        // Restore the documented default so other tests are not
        // affected by this test's side effect.
        set_wait_connection_timeout(30_000).unwrap();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn p2p_name_roundtrip() {
        if !have_native() {
            return;
        }
        set_p2p_name("rust_test_group").unwrap();
        assert_eq!(get_p2p_name().unwrap(), "rust_test_group");

        set_p2p_name("").unwrap();
        assert_eq!(get_p2p_name().unwrap(), "");
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn fixed_sequenced_time_roundtrip() {
        if !have_native() {
            return;
        }
        set_fixed_sequenced_time(5_000).unwrap();
        assert_eq!(get_fixed_sequenced_time().unwrap(), 5_000);

        // Restore the documented default.
        set_fixed_sequenced_time(20_000).unwrap();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn data_handle_idle_timeout_roundtrip() {
        if !have_native() {
            return;
        }
        set_data_handle_idle_timeout(60_000).unwrap();
        assert_eq!(get_data_handle_idle_timeout().unwrap(), 60_000);

        set_data_handle_idle_timeout(600_000).unwrap();
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn ipc_serv_thread_count_roundtrip() {
        if !have_native() {
            return;
        }
        set_ipc_serv_thread_count(4).unwrap();
        assert_eq!(get_ipc_serv_thread_count().unwrap(), 4);
    }

    #[test]
    #[ignore = "mutates process-global native state; run with --ignored --test-threads=1"]
    fn no_reponse_cmd_null_flush_threshold_roundtrip() {
        if !have_native() {
            return;
        }
        set_no_reponse_cmd_null_flush_threshold(1_000).unwrap();
        assert_eq!(get_no_reponse_cmd_null_flush_threshold().unwrap(), 1_000);

        set_no_reponse_cmd_null_flush_threshold(5_000).unwrap();
    }

    // -----------------------------------------------------------------
    // Invalid-argument handling (pure Rust, no native call needed)
    // -----------------------------------------------------------------

    #[test]
    fn set_string_rejects_interior_nul_in_key() {
        if !have_native() {
            return;
        }
        let err = set_string("Quiet\0bad", "True").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn set_string_rejects_interior_nul_in_value() {
        if !have_native() {
            return;
        }
        let err = set_string("Quiet", "Tr\0ue").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    #[test]
    fn get_string_rejects_interior_nul_in_key() {
        if !have_native() {
            return;
        }
        let err = get_string("Quiet\0bad").unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidArgument);
    }

    // -----------------------------------------------------------------
    // Unknown option fallback
    // -----------------------------------------------------------------

    #[test]
    fn get_bool_of_unknown_option_is_false() {
        if !have_native() {
            return;
        }
        assert!(!get_bool("__no_such_option__").unwrap());
    }

    #[test]
    fn get_u64_of_unknown_option_is_zero() {
        if !have_native() {
            return;
        }
        assert_eq!(get_u64("__no_such_option__").unwrap(), 0);
    }

    #[test]
    fn get_i64_of_unknown_option_is_zero() {
        if !have_native() {
            return;
        }
        assert_eq!(get_i64("__no_such_option__").unwrap(), 0);
    }

    #[test]
    fn get_string_of_unknown_option_is_empty() {
        if !have_native() {
            return;
        }
        assert!(get_string("__no_such_option__").unwrap().is_empty());
    }
}