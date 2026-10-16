# =============================================================================
# options.R
# -----------------------------------------------------------------------------
# Typed accessors for the LingoFuse runtime options.
#
# Every option recognised by LF_SetOption / LF_GetOption has one
# setter / getter pair here. The setter accepts a native R value
# (logical / numeric / character) and converts it to the string form
# the runtime expects. The getter converts the runtime's string form
# back to the corresponding native R type.
#
# Design rationale
# ----------------
# The runtime option system is stringly typed at the C ABI:
#
#     LF_SetOption("Quiet", "True")
#     LF_GetOption("Quiet")     ->  "True"
#
# This is compact and easy to extend, but it puts the burden of
# remembering the key name, the value format, and the type on the
# caller. Every time a user writes `lf_set_option("waitConTime")`
# instead of `lf_set_option("Wait_Connection_Timeout")`, the call
# silently does nothing (LF-OPT-001: unknown option names are
# ignored).
#
# The accessors in this file eliminate that whole class of bug: the
# key name and the value format are baked into the function name, so
# a typo becomes a missing-function error at load time rather than a
# silent no-op at run time.
#
# The stringly-typed interface remains available (lf_set_option /
# lf_get_option, defined in api.R) for advanced users who need
# dynamic key selection.
#
# Option lifetime
# ---------------
# Options are process-global. They are NOT persisted across
# LF_Shutdown; an application that restarts the framework must
# reapply its options (LF-OPT-002). lf_options_reset() reapplies the
# documented defaults but does NOT restart the framework.
#
# Boolean encoding
# ----------------
# The runtime reads boolean options with EStrToBool, which accepts
# "True" / "False" case-insensitively. The setters below emit the
# canonical "True" / "False" spelling; the getters accept any
# capitalisation on the way back.
#
# Return-value visibility
# -----------------------
# Setters return NULL invisibly. Getters return the native R value.
# All functions call lf_set_option / lf_get_option, which require
# the runtime to be loaded; calling them before lf_load() is a no-op
# that returns the empty / zero defaults (see .lf_opt_get_* helpers).
#
# All user-facing strings are English.
# =============================================================================


# =============================================================================
# Documented defaults
# -----------------------------------------------------------------------------
# These are the values the runtime uses when an option has never been
# set. They match the constants listed in the Pascal reference guide
# (section 0.6, "Key default values"). Options that are platform-
# dependent (the three IPC_* keys) or write-only (debug) are NOT
# listed here, because resetting them to a fixed value would be
# wrong or meaningless.
#
# lf_options_reset() iterates over this list.
# =============================================================================

LF_OPTION_DEFAULTS <- list(
    password                            = "DTC40@ZSERVER",
    Quiet                               = FALSE,
    ShowThreadID                        = TRUE,
    ConsoleOutput                       = TRUE,
    Overlap_Connection                  = FALSE,
    Wait_Connection_ReadyOk             = TRUE,
    Wait_Connection_Timeout             = 30000,
    Fixed_Sequenced_Time                = 20000,
    LF_P2P_name                         = "",
    DataHandle_Idle_Timeout             = 600000,
    DataHandle_Pool_Scan_Interval       = 5000,
    No_Reponse_Cmd_NULL_Flush_Threshold = 5000
)


# =============================================================================
# Internal helpers
# -----------------------------------------------------------------------------
# The four .lf_opt_* functions below are the ONLY place in this file
# that touches lf_set_option / lf_get_option. Every public accessor
# delegates to one of them.
#
# The helpers never throw on a missing runtime: lf_get_option returns
# "" for an unknown key or when the runtime is not loaded, and the
# boolean / numeric getters interpret "" as FALSE / 0. This keeps the
# accessors safe to call at any point in the process lifetime.
# =============================================================================

.lf_opt_set_str <- function(key, value) {
    if (is.null(value)) value <- ""
    if (!is.character(value) || length(value) != 1L) {
        stop("option '", key, "' requires a length-1 character value")
    }
    lf_set_option(key, value)
}

.lf_opt_get_str <- function(key) {
    lf_get_option(key)
}

.lf_opt_set_bool <- function(key, value) {
    if (!is.logical(value) || length(value) != 1L || is.na(value)) {
        stop("option '", key, "' requires a length-1 logical (TRUE / FALSE)")
    }
    lf_set_option(key, if (value) "True" else "False")
}

.lf_opt_get_bool <- function(key) {
    raw <- lf_get_option(key)
    if (!nzchar(raw)) return(FALSE)
    identical(tolower(raw), "true")
}

.lf_opt_set_num <- function(key, value) {
    if (!is.numeric(value) || length(value) != 1L || is.na(value)) {
        stop("option '", key, "' requires a length-1 numeric value")
    }
    # format() with scientific = FALSE keeps large integers in plain
    # decimal form, which is what the runtime expects for the *_ms
    # and *_Timeout style options.
    lf_set_option(key, format(value, scientific = FALSE, trim = TRUE))
}

.lf_opt_get_num <- function(key) {
    raw <- lf_get_option(key)
    if (!nzchar(raw)) return(0)
    v <- suppressWarnings(as.numeric(raw))
    if (is.na(v)) return(0)
    v
}


# =============================================================================
# Section 1 -- Authentication
# =============================================================================

#' Set the P2PVM / C4 authentication password
#'
#' The password must match on both sides of a connection, or the
#' handshake will fail. The runtime ships with a well-known default
#' (see \code{LF_OPTION_DEFAULTS}); a production deployment should
#' set a private value before calling \code{lf_prepare_service} or
#' \code{lf_prepare_client}.
#'
#' @param value A length-1 character vector.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_password <- function(value) {
    .lf_opt_set_str("password", value)
    invisible(NULL)
}

#' Read the configured password
#'
#' The runtime deliberately returns a fixed mask (\code{"********"})
#' rather than the actual value; the mask is returned by the
#' underlying C option reader, not by this wrapper.
#'
#' @return A length-1 character vector. Always the mask on a working
#'   runtime.
#' @export
lf_get_opt_password <- function() {
    .lf_opt_get_str("password")
}


# =============================================================================
# Section 2 -- Logging and diagnostics
# =============================================================================

#' Execute a C4 console debug command
#'
#' This option is WRITE-ONLY and has side effects: each call
#' constructs a transient console helper object and runs the given
#' command. Recognised command names include \code{"service"},
#' \code{"tunnel"}, \code{"ZNet_Info"}, \code{"HPC_Thread_Info"}.
#'
#' Because each call allocates a helper object, this option is for
#' interactive diagnostics only. Do NOT call it in a hot loop.
#'
#' @param value A length-1 character vector containing the command.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_debug <- function(value) {
    .lf_opt_set_str("debug", value)
    invisible(NULL)
}

#' Read the current value of the debug option
#'
#' The underlying option is write-only; the runtime returns a fixed
#' placeholder string rather than a stored value. Provided for
#' symmetry with the other getters.
#'
#' @return A length-1 character vector (typically a placeholder).
#' @export
lf_get_opt_debug <- function() {
    .lf_opt_get_str("debug")
}

#' Enable or disable quiet mode
#'
#' When quiet mode is on, most internal informational logging is
#' suppressed. The default is \code{FALSE}.
#'
#' @param value A length-1 logical.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_quiet <- function(value) {
    .lf_opt_set_bool("Quiet", value)
    invisible(NULL)
}

#' Return \code{TRUE} if quiet mode is enabled
#' @return A length-1 logical.
#' @export
lf_get_opt_quiet <- function() {
    .lf_opt_get_bool("Quiet")
}

#' Enable or disable thread-ID prefixes in status output
#'
#' When enabled, every status message is prefixed with the numeric ID
#' of the thread that produced it. The default is \code{TRUE}.
#'
#' @param value A length-1 logical.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_show_thread_id <- function(value) {
    .lf_opt_set_bool("ShowThreadID", value)
    invisible(NULL)
}

#' Return \code{TRUE} if thread-ID prefixes are enabled
#' @return A length-1 logical.
#' @export
lf_get_opt_show_thread_id <- function() {
    .lf_opt_get_bool("ShowThreadID")
}

#' Enable or disable console output for status messages
#'
#' When enabled, the runtime writes every status message to the
#' process's standard output. When disabled, messages are still
#' queued and remain readable through \code{lf_get_status}; only the
#' console sink is muted.
#'
#' @param value A length-1 logical.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_console_output <- function(value) {
    .lf_opt_set_bool("ConsoleOutput", value)
    invisible(NULL)
}

#' Return \code{TRUE} if console output is enabled
#' @return A length-1 logical.
#' @export
lf_get_opt_console_output <- function() {
    .lf_opt_get_bool("ConsoleOutput")
}


# =============================================================================
# Section 3 -- Connection readiness
# =============================================================================

#' Allow or forbid multiple client tunnels to the same address
#'
#' \code{FALSE} (the default) permits only one client tunnel per
#' physical address. A second \code{lf_prepare_client} for the same
#' address returns \code{-1} and the new application handle is
#' discarded.
#'
#' \code{TRUE} makes every \code{lf_prepare_client} create a new
#' independent tunnel, binding the supplied application handle.
#'
#' This option MUST be set BEFORE the \code{lf_prepare_client} calls
#' it is meant to affect.
#'
#' @param value A length-1 logical.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_overlap_connection <- function(value) {
    .lf_opt_set_bool("Overlap_Connection", value)
    invisible(NULL)
}

#' Return \code{TRUE} if overlapping connections are allowed
#' @return A length-1 logical.
#' @export
lf_get_opt_overlap_connection <- function() {
    .lf_opt_get_bool("Overlap_Connection")
}

#' Control whether \code{lf_prepare_done} waits for all clients
#'
#' \code{TRUE} (the default) makes \code{lf_prepare_done} wait until
#' every prepared client reaches the "online" state, or the timeout
#' (see \code{lf_set_opt_wait_connection_timeout}) expires.
#'
#' \code{FALSE} makes \code{lf_prepare_done} return immediately after
#' the simulated main thread starts. The caller is then responsible
#' for probing readiness itself (for example, in a retry loop around
#' \code{lf_check_api}).
#'
#' @param value A length-1 logical.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_wait_connection_ready_ok <- function(value) {
    .lf_opt_set_bool("Wait_Connection_ReadyOk", value)
    invisible(NULL)
}

#' Return \code{TRUE} if \code{lf_prepare_done} waits for all clients
#' @return A length-1 logical.
#' @export
lf_get_opt_wait_connection_ready_ok <- function() {
    .lf_opt_get_bool("Wait_Connection_ReadyOk")
}

#' Set the timeout (in ms) for the \code{lf_prepare_done} wait
#'
#' The default is 30000 ms. The runtime imposes a floor of 5000 ms
#' when the wait is actually performed; values below the floor are
#' silently raised.
#'
#' If the timeout expires before all clients are ready,
#' \code{lf_prepare_done} still returns \code{1}; the caller must
#' independently verify readiness if that matters.
#'
#' @param value_ms A length-1 numeric (milliseconds).
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_wait_connection_timeout <- function(value_ms) {
    .lf_opt_set_num("Wait_Connection_Timeout", value_ms)
    invisible(NULL)
}

#' Return the current \code{lf_prepare_done} wait timeout, in ms
#' @return A length-1 numeric.
#' @export
lf_get_opt_wait_connection_timeout <- function() {
    .lf_opt_get_num("Wait_Connection_Timeout")
}


# =============================================================================
# Section 4 -- IPC server
# -----------------------------------------------------------------------------
# These options must be set before the IPC server is started. Changing
# them afterwards has no effect on an already-running server. Their
# defaults are platform-dependent.
# =============================================================================

#' Set the IPC server thread-pool size
#' @param value A length-1 numeric.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_ipc_serv_thread_count <- function(value) {
    .lf_opt_set_num("IPC_Serv_ThreadCount", value)
    invisible(NULL)
}

#' Return the configured IPC server thread count
#' @return A length-1 numeric (0 if unset).
#' @export
lf_get_opt_ipc_serv_thread_count <- function() {
    .lf_opt_get_num("IPC_Serv_ThreadCount")
}

#' Set the maximum IPC server inbound queue length
#' @param value A length-1 numeric.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_ipc_serv_max_queue_length <- function(value) {
    .lf_opt_set_num("IPC_Serv_MaxQueueLength", value)
    invisible(NULL)
}

#' Return the configured IPC server max queue length
#' @return A length-1 numeric (0 if unset).
#' @export
lf_get_opt_ipc_serv_max_queue_length <- function() {
    .lf_opt_get_num("IPC_Serv_MaxQueueLength")
}

#' Set the maximum size, in bytes, of a single IPC message
#' @param value A length-1 numeric.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_ipc_serv_max_msg_size <- function(value) {
    .lf_opt_set_num("IPC_Serv_MaxMsgSize", value)
    invisible(NULL)
}

#' Return the configured IPC server max message size
#' @return A length-1 numeric (0 if unset).
#' @export
lf_get_opt_ipc_serv_max_msg_size <- function() {
    .lf_opt_get_num("IPC_Serv_MaxMsgSize")
}


# =============================================================================
# Section 5 -- Sequenced notifications
# =============================================================================

#' Set the P2PName sticky-affinity window, in ms
#'
#' When the server-side dispatcher routes a P2PName-addressed call, it
#' normally picks the target with the smallest Cycle_Anchor value
#' (round-robin). If a single target has been handling requests for
#' longer than this value, the dispatcher switches to a different
#' target instead, to avoid starvation.
#'
#' The default is 20000 ms.
#'
#' @param value_ms A length-1 numeric (milliseconds).
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_fixed_sequenced_time <- function(value_ms) {
    .lf_opt_set_num("Fixed_Sequenced_Time", value_ms)
    invisible(NULL)
}

#' Return the current sticky-affinity window, in ms
#' @return A length-1 numeric.
#' @export
lf_get_opt_fixed_sequenced_time <- function() {
    .lf_opt_get_num("Fixed_Sequenced_Time")
}


# =============================================================================
# Section 6 -- P2P group name
# =============================================================================

#' Set this process's P2P group name
#'
#' The name is injected into every outbound request payload and is
#' reported to the server through the \code{Update_UID} command. It
#' defines which P2PName-addressed calls this process is willing to
#' receive.
#'
#' The default is the empty string, meaning "not a member of any
#' group". An empty P2P name disables P2PName routing for this
#' process (UID and App-name routing are unaffected).
#'
#' \strong{Not to be confused with} \code{DataHandle.get_p2p_name()}.
#' That accessor reads the SENDER's P2P name from the INPUT handle of
#' a registered callback; the P2P name being set here is the LOCAL
#' declaration. In short:
#' \itemize{
#'   \item \code{lf_get_opt_p2p_name()} reads MY name (local config).
#'   \item \code{DataHandle$get_p2p_name()} reads the SENDER's name.
#' }
#'
#' @param value A length-1 character vector.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_p2p_name <- function(value) {
    .lf_opt_set_str("LF_P2P_name", value)
    invisible(NULL)
}

#' Return this process's configured P2P group name
#' @return A length-1 character vector (empty if unset).
#' @export
lf_get_opt_p2p_name <- function() {
    .lf_opt_get_str("LF_P2P_name")
}


# =============================================================================
# Section 7 -- Data handle pool
# =============================================================================

#' Set the idle-reclaim threshold for auto-recycled data handles, in ms
#'
#' A value greater than zero enables idle reclamation: a handle that
#' has not been accessed for at least this long becomes a candidate
#' for release on the next pool scan. The default is 600000 ms
#' (10 minutes).
#'
#' A value of zero disables idle reclamation entirely. This option
#' does NOT affect handles created by
#' \code{lf_data_create_permanent}: those are released synchronously
#' by \code{lf_data_free} and never enter the idle-reclaim path.
#'
#' @param value_ms A length-1 numeric (milliseconds).
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_data_handle_idle_timeout <- function(value_ms) {
    .lf_opt_set_num("DataHandle_Idle_Timeout", value_ms)
    invisible(NULL)
}

#' Return the current idle-reclaim threshold, in ms
#' @return A length-1 numeric.
#' @export
lf_get_opt_data_handle_idle_timeout <- function() {
    .lf_opt_get_num("DataHandle_Idle_Timeout")
}

#' Set the minimum interval between two data-handle pool scans, in ms
#'
#' The default is 5000 ms. A value of zero disables the rate limiter;
#' the scanner then runs on every progress tick of the simulated main
#' thread. The scanner is driven by the main thread, so its effective
#' frequency is bounded below by the main thread's tick granularity.
#'
#' @param value_ms A length-1 numeric (milliseconds).
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_data_handle_pool_scan_interval <- function(value_ms) {
    .lf_opt_set_num("DataHandle_Pool_Scan_Interval", value_ms)
    invisible(NULL)
}

#' Return the current data-handle pool scan interval, in ms
#' @return A length-1 numeric.
#' @export
lf_get_opt_data_handle_pool_scan_interval <- function() {
    .lf_opt_get_num("DataHandle_Pool_Scan_Interval")
}


# =============================================================================
# Section 8 -- Command flushing
# =============================================================================

#' Set the null-flush threshold for one-way commands
#'
#' The protocol periodically sends a NULL command to force the server
#' to acknowledge pending one-way Notify messages. After every
#' \code{value} no-response commands, one NULL command is emitted as
#' a flush point. The default is 5000.
#'
#' Note the option key uses the historical spelling "Reponse"
#' (without the second 's'). This is intentional and matches the
#' Pascal helper name.
#'
#' @param value A length-1 numeric (integer).
#' @return \code{NULL}, invisibly.
#' @export
lf_set_opt_no_reponse_cmd_null_flush_threshold <- function(value) {
    .lf_opt_set_num("No_Reponse_Cmd_NULL_Flush_Threshold", value)
    invisible(NULL)
}

#' Return the current null-flush threshold
#' @return A length-1 numeric.
#' @export
lf_get_opt_no_reponse_cmd_null_flush_threshold <- function() {
    .lf_opt_get_num("No_Reponse_Cmd_NULL_Flush_Threshold")
}


# =============================================================================
# Section 9 -- Convenience: snapshot / reset / table
# =============================================================================

#' Read every readable option at once
#'
#' Returns a named list whose names match the option keys and whose
#' values are already converted to their native R types. Useful for
#' logging the current configuration at startup or for tests that
#' need to snapshot and restore the global option state.
#'
#' The \code{debug} option is deliberately excluded (it is write-only
#' and cannot be meaningfully read back).
#'
#' @return A named list.
#' @export
lf_options_snapshot <- function() {
    list(
        password                            = lf_get_opt_password(),
        Quiet                               = lf_get_opt_quiet(),
        ShowThreadID                        = lf_get_opt_show_thread_id(),
        ConsoleOutput                       = lf_get_opt_console_output(),
        Overlap_Connection                  = lf_get_opt_overlap_connection(),
        Wait_Connection_ReadyOk             = lf_get_opt_wait_connection_ready_ok(),
        Wait_Connection_Timeout             = lf_get_opt_wait_connection_timeout(),
        IPC_Serv_ThreadCount                = lf_get_opt_ipc_serv_thread_count(),
        IPC_Serv_MaxQueueLength             = lf_get_opt_ipc_serv_max_queue_length(),
        IPC_Serv_MaxMsgSize                 = lf_get_opt_ipc_serv_max_msg_size(),
        Fixed_Sequenced_Time                = lf_get_opt_fixed_sequenced_time(),
        LF_P2P_name                         = lf_get_opt_p2p_name(),
        DataHandle_Idle_Timeout             = lf_get_opt_data_handle_idle_timeout(),
        DataHandle_Pool_Scan_Interval       = lf_get_opt_data_handle_pool_scan_interval(),
        No_Reponse_Cmd_NULL_Flush_Threshold = lf_get_opt_no_reponse_cmd_null_flush_threshold()
    )
}

#' Reset the documented defaults for the writable options
#'
#' Applies the values in \code{LF_OPTION_DEFAULTS} (see the constant
#' in this file) to the runtime. The \code{password} option is
#' skipped unless \code{include_password = TRUE}, because resetting a
#' user's authentication secret to the well-known development token
#' is almost never what the caller wants.
#'
#' The three \code{IPC_*} options and the write-only \code{debug}
#' option are not included in \code{LF_OPTION_DEFAULTS} and are
#' therefore left untouched.
#'
#' This function does NOT restart the framework: it only reapplies
#' the option values. To reset the entire runtime, use
#' \code{lf_shutdown} followed by a fresh \code{lf_prepare_*} cycle.
#'
#' @param include_password When \code{FALSE} (the default), the
#'   \code{password} option is left as-is.
#' @return \code{NULL}, invisibly.
#' @export
lf_options_reset <- function(include_password = FALSE) {
    lf_set_opt_quiet(LF_OPTION_DEFAULTS$Quiet)
    lf_set_opt_show_thread_id(LF_OPTION_DEFAULTS$ShowThreadID)
    lf_set_opt_console_output(LF_OPTION_DEFAULTS$ConsoleOutput)
    lf_set_opt_overlap_connection(LF_OPTION_DEFAULTS$Overlap_Connection)
    lf_set_opt_wait_connection_ready_ok(LF_OPTION_DEFAULTS$Wait_Connection_ReadyOk)
    lf_set_opt_wait_connection_timeout(LF_OPTION_DEFAULTS$Wait_Connection_Timeout)
    lf_set_opt_fixed_sequenced_time(LF_OPTION_DEFAULTS$Fixed_Sequenced_Time)
    lf_set_opt_p2p_name(LF_OPTION_DEFAULTS$LF_P2P_name)
    lf_set_opt_data_handle_idle_timeout(
        LF_OPTION_DEFAULTS$DataHandle_Idle_Timeout)
    lf_set_opt_data_handle_pool_scan_interval(
        LF_OPTION_DEFAULTS$DataHandle_Pool_Scan_Interval)
    lf_set_opt_no_reponse_cmd_null_flush_threshold(
        LF_OPTION_DEFAULTS$No_Reponse_Cmd_NULL_Flush_Threshold)

    if (include_password) {
        lf_set_opt_password(LF_OPTION_DEFAULTS$password)
    }

    invisible(NULL)
}

#' Return a data frame describing every known option
#'
#' Columns:
#' \itemize{
#'   \item \code{key}      -- the option key as passed to
#'                            \code{lf_set_option}.
#'   \item \code{type}     -- \code{"logical"}, \code{"numeric"},
#'                            or \code{"character"}.
#'   \item \code{current}  -- the current value, as a character string
#'                            (so all columns fit in a data frame).
#'   \item \code{default}  -- the documented default, as a character
#'                            string, or \code{NA} when the option
#'                            has no fixed default.
#'   \item \code{notes}    -- a short human-readable description.
#' }
#'
#' This is a diagnostic helper: it does not change any option.
#'
#' @return A data frame.
#' @export
lf_options_table <- function() {
    rows <- list(
        c("password",           "character", lf_get_opt_password(),
          LF_OPTION_DEFAULTS$password,
          "P2PVM authentication; read returns the mask"),
        c("debug",              "character", lf_get_opt_debug(),
          NA_character_,
          "Write-only; runs a C4 debug command"),
        c("Quiet",              "logical",   as.character(lf_get_opt_quiet()),
          as.character(LF_OPTION_DEFAULTS$Quiet),
          "Suppress most internal logging"),
        c("ShowThreadID",       "logical",   as.character(lf_get_opt_show_thread_id()),
          as.character(LF_OPTION_DEFAULTS$ShowThreadID),
          "Prefix status lines with thread IDs"),
        c("ConsoleOutput",      "logical",   as.character(lf_get_opt_console_output()),
          as.character(LF_OPTION_DEFAULTS$ConsoleOutput),
          "Mirror status messages to stdout"),
        c("Overlap_Connection", "logical",   as.character(lf_get_opt_overlap_connection()),
          as.character(LF_OPTION_DEFAULTS$Overlap_Connection),
          "Allow multiple clients on the same address"),
        c("Wait_Connection_ReadyOk", "logical",
          as.character(lf_get_opt_wait_connection_ready_ok()),
          as.character(LF_OPTION_DEFAULTS$Wait_Connection_ReadyOk),
          "Block in lf_prepare_done until all clients are online"),
        c("Wait_Connection_Timeout", "numeric",
          as.character(lf_get_opt_wait_connection_timeout()),
          as.character(LF_OPTION_DEFAULTS$Wait_Connection_Timeout),
          "Timeout for the above wait (ms)"),
        c("IPC_Serv_ThreadCount", "numeric",
          as.character(lf_get_opt_ipc_serv_thread_count()),
          NA_character_,
          "IPC server thread pool size"),
        c("IPC_Serv_MaxQueueLength", "numeric",
          as.character(lf_get_opt_ipc_serv_max_queue_length()),
          NA_character_,
          "IPC inbound queue length"),
        c("IPC_Serv_MaxMsgSize", "numeric",
          as.character(lf_get_opt_ipc_serv_max_msg_size()),
          NA_character_,
          "Maximum single IPC message size (bytes)"),
        c("Fixed_Sequenced_Time", "numeric",
          as.character(lf_get_opt_fixed_sequenced_time()),
          as.character(LF_OPTION_DEFAULTS$Fixed_Sequenced_Time),
          "P2PName sticky-affinity window (ms)"),
        c("LF_P2P_name",        "character", lf_get_opt_p2p_name(),
          LF_OPTION_DEFAULTS$LF_P2P_name,
          "This process's P2P group name"),
        c("DataHandle_Idle_Timeout", "numeric",
          as.character(lf_get_opt_data_handle_idle_timeout()),
          as.character(LF_OPTION_DEFAULTS$DataHandle_Idle_Timeout),
          "Idle-reclaim threshold for auto handles (ms)"),
        c("DataHandle_Pool_Scan_Interval", "numeric",
          as.character(lf_get_opt_data_handle_pool_scan_interval()),
          as.character(LF_OPTION_DEFAULTS$DataHandle_Pool_Scan_Interval),
          "Rate limit between pool scans (ms)"),
        c("No_Reponse_Cmd_NULL_Flush_Threshold", "numeric",
          as.character(lf_get_opt_no_reponse_cmd_null_flush_threshold()),
          as.character(LF_OPTION_DEFAULTS$No_Reponse_Cmd_NULL_Flush_Threshold),
          "Null-flush threshold for one-way commands")
    )

    df <- data.frame(
        key      = vapply(rows, `[`, character(1), 1L),
        type     = vapply(rows, `[`, character(1), 2L),
        current  = vapply(rows, `[`, character(1), 3L),
        default  = vapply(rows, `[`, character(1), 4L),
        notes    = vapply(rows, `[`, character(1), 5L),
        stringsAsFactors = FALSE,
        row.names = NULL
    )
    df
}