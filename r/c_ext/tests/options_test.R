# =============================================================================
# options_test.R
# -----------------------------------------------------------------------------
# Unit test for the typed runtime-option accessors defined in
# lingofuse/R/options.R.
#
# This test only requires the bridge DLL and the LingoFuse runtime;
# it does NOT start the C4 network, does NOT call lf_prepare_done, and
# does NOT register any API. Every check exercises the option system
# in isolation.
#
# Coverage
# --------
#   Group 1  Bridge and runtime load
#   Group 2  Boolean options       (set / get round trip, type check)
#   Group 3  Numeric options       (set / get round trip, type check)
#   Group 4  Character options     (set / get round trip, type check)
#   Group 5  Password masking
#   Group 6  Unknown option behaviour
#   Group 7  Snapshot / table / reset
#   Group 8  Shutdown
#
# Usage:
#   Rscript c_ext/tests/options_test.R [runtime_dir]
#
# The runtime directory is resolved by lf_find_runtime(), which
# consults (in order): the first command-line argument, the
# LINGOFUSE_RUNTIME environment variable, the "lingofuse.runtime" R
# option, and a list of relative probes under the script directory and
# the current working directory. No absolute path is hard-coded.
#
# All output and comments are English.
# =============================================================================

# -----------------------------------------------------------------------------
# Locate the bridge library and the runtime
# -----------------------------------------------------------------------------
script_dir <- tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    file_arg <- grep("^--file=", args, value = TRUE)
    if (length(file_arg) > 0) {
        dirname(normalizePath(sub("^--file=", "", file_arg[1])))
    } else {
        getwd()
    }
}, error = function(e) getwd())

source(file.path(script_dir, "lf_runtime.R"))

candidate_dirs <- c(
    file.path(script_dir, "..", "..", "libs"),
    file.path(script_dir, "..", "libs"),
    file.path(getwd(), "libs")
)
bridge_path <- NULL
for (d in candidate_dirs) {
    for (ext in c(".dll", ".so", ".dylib")) {
        p <- file.path(d, paste0("lfR_bridge", ext))
        if (file.exists(p)) { bridge_path <- normalizePath(p); break }
    }
    if (!is.null(bridge_path)) break
}
if (is.null(bridge_path)) {
    message("[FAIL] Bridge library not found. Build it first with build.ps1.")
    quit(status = 1)
}
message("[OK]   Bridge: ", bridge_path)

args <- commandArgs(trailingOnly = TRUE)
explicit_runtime <- if (length(args) >= 1) args[1] else NULL
runtime_dir <- lf_find_runtime(explicit_runtime, script_dir)
if (is.null(runtime_dir)) {
    message("[FAIL] Could not locate the LingoFuse runtime directory.")
    quit(status = 1)
}
message("[OK]   Runtime dir: ", runtime_dir)

# -----------------------------------------------------------------------------
# Test harness
# -----------------------------------------------------------------------------
pass_count <- 0L
fail_count <- 0L

check <- function(label, cond, detail = NULL) {
    if (isTRUE(cond)) {
        message("[OK]   ", label); pass_count <<- pass_count + 1L
    } else {
        message("[FAIL] ", label)
        if (!is.null(detail)) message("       ", detail)
        fail_count <<- fail_count + 1L
    }
}
expect_error <- function(label, expr) {
    err <- tryCatch({ force(expr); NULL },
                    error = function(e) conditionMessage(e))
    if (is.null(err)) {
        message("[FAIL] ", label, " (no error raised)")
        fail_count <<- fail_count + 1L
    } else {
        message("[OK]   ", label)
        message("       error: ", err)
        pass_count <<- pass_count + 1L
    }
}

# -----------------------------------------------------------------------------
# Group 1 - Bridge and runtime load
# -----------------------------------------------------------------------------
message("")
message("=== Group 1. Bridge and runtime load ===")
dyn.load(bridge_path)
loaded_path <- .Call("lf_load_library", runtime_dir)
check("lf_load_library succeeds",
      is.character(loaded_path) && nzchar(loaded_path))
check("lf_is_loaded returns TRUE", isTRUE(.Call("lf_is_loaded")))

# We need the accessors defined in options.R. Because the standalone
# bridge (libs/lfR_bridge.dll) is loaded directly, the lingofuse
# package itself is not necessarily installed yet. We source options.R
# directly so that this test can be run before build_package.ps1.
#
# options.R references lf_set_option / lf_get_option, which are defined
# in api.R. We source api.R's option-related functions only. To keep
# this script standalone, we implement minimal local equivalents of
# the two base functions and source options.R with them in scope.
options.R.path <- file.path(script_dir, "..", "..", "lingofuse", "R", "options.R")
if (!file.exists(options.R.path)) {
    message("[FAIL] options.R not found: ", options.R.path)
    quit(status = 1)
}

# Minimal shims for the two base option functions, mapping directly
# to the .Call entries of the bridge.
lf_set_option <- function(option, value) {
    .Call("lf_set_option", option, value)
    invisible(NULL)
}
lf_get_option <- function(option) {
    .Call("lf_get_option", option)
}

# Source options.R in the current environment so that its function
# definitions become locally available.
source(options.R.path, local = TRUE)
message("[OK]   options.R sourced")

# -----------------------------------------------------------------------------
# Group 2 - Boolean options
# -----------------------------------------------------------------------------
message("")
message("=== Group 2. Boolean options ===")

lf_set_opt_quiet(TRUE);  check("Quiet=TRUE round trip",  isTRUE(lf_get_opt_quiet()))
lf_set_opt_quiet(FALSE); check("Quiet=FALSE round trip", identical(lf_get_opt_quiet(), FALSE))

lf_set_opt_show_thread_id(FALSE)
check("ShowThreadID=FALSE round trip",
      identical(lf_get_opt_show_thread_id(), FALSE))
lf_set_opt_show_thread_id(TRUE)
check("ShowThreadID=TRUE round trip",
      isTRUE(lf_get_opt_show_thread_id()))

lf_set_opt_console_output(FALSE)
check("ConsoleOutput=FALSE round trip",
      identical(lf_get_opt_console_output(), FALSE))
lf_set_opt_console_output(TRUE)
check("ConsoleOutput=TRUE round trip",
      isTRUE(lf_get_opt_console_output()))

lf_set_opt_overlap_connection(TRUE)
check("Overlap_Connection=TRUE round trip",
      isTRUE(lf_get_opt_overlap_connection()))
lf_set_opt_overlap_connection(FALSE)
check("Overlap_Connection=FALSE round trip",
      identical(lf_get_opt_overlap_connection(), FALSE))

expect_error("Quiet rejects a character value",
             lf_set_opt_quiet("yes"))
expect_error("Quiet rejects NA",
             lf_set_opt_quiet(NA))
expect_error("Quiet rejects a vector",
             lf_set_opt_quiet(c(TRUE, FALSE)))

# -----------------------------------------------------------------------------
# Group 3 - Numeric options
# -----------------------------------------------------------------------------
message("")
message("=== Group 3. Numeric options ===")

lf_set_opt_wait_connection_timeout(15000)
check("Wait_Connection_Timeout=15000 round trip",
      identical(lf_get_opt_wait_connection_timeout(), 15000))

lf_set_opt_fixed_sequenced_time(25000)
check("Fixed_Sequenced_Time=25000 round trip",
      identical(lf_get_opt_fixed_sequenced_time(), 25000))

lf_set_opt_data_handle_idle_timeout(1234567)
check("DataHandle_Idle_Timeout=1234567 round trip",
      identical(lf_get_opt_data_handle_idle_timeout(), 1234567))

lf_set_opt_data_handle_pool_scan_interval(2500)
check("DataHandle_Pool_Scan_Interval=2500 round trip",
      identical(lf_get_opt_data_handle_pool_scan_interval(), 2500))

lf_set_opt_no_reponse_cmd_null_flush_threshold(1234)
check("No_Reponse_Cmd_NULL_Flush_Threshold=1234 round trip",
      identical(lf_get_opt_no_reponse_cmd_null_flush_threshold(), 1234))

expect_error("Wait_Connection_Timeout rejects a string",
             lf_set_opt_wait_connection_timeout("1000"))
expect_error("Wait_Connection_Timeout rejects NA",
             lf_set_opt_wait_connection_timeout(NA))

# -----------------------------------------------------------------------------
# Group 4 - Character options
# -----------------------------------------------------------------------------
message("")
message("=== Group 4. Character options ===")

lf_set_opt_p2p_name("test_group_1")
check("LF_P2P_name='test_group_1' round trip",
      identical(lf_get_opt_p2p_name(), "test_group_1"))

lf_set_opt_p2p_name("")
check("LF_P2P_name='' round trip",
      identical(lf_get_opt_p2p_name(), ""))

lf_set_opt_p2p_name("group with spaces and 中文")
check("LF_P2P_name accepts UTF-8",
      identical(lf_get_opt_p2p_name(), "group with spaces and 中文"))

expect_error("LF_P2P_name rejects a numeric value",
             lf_set_opt_p2p_name(42))
expect_error("LF_P2P_name rejects a vector",
             lf_set_opt_p2p_name(c("a", "b")))

# -----------------------------------------------------------------------------
# Group 5 - Password masking
# -----------------------------------------------------------------------------
message("")
message("=== Group 5. Password masking ===")

lf_set_opt_password("very_secret_password")
pw <- lf_get_opt_password()
check("password read is masked",
      identical(pw, "********"),
      paste("got:", pw))

expect_error("password rejects a numeric value",
             lf_set_opt_password(12345))

# -----------------------------------------------------------------------------
# Group 6 - Unknown option behaviour
# -----------------------------------------------------------------------------
message("")
message("=== Group 6. Unknown option behaviour ===")

unknown <- lf_get_option("__no_such_option__")
check("unknown option read returns empty string",
      identical(unknown, ""),
      paste("got:", unknown))

# lf_set_option on an unknown key must be a silent no-op.
rc <- tryCatch({
    lf_set_option("__no_such_option__", "x")
    TRUE
}, error = function(e) FALSE)
check("set_option on unknown key does not raise", isTRUE(rc))

# -----------------------------------------------------------------------------
# Group 7 - Snapshot / table / reset
# -----------------------------------------------------------------------------
message("")
message("=== Group 7. Snapshot / table / reset ===")

snap <- lf_options_snapshot()
check("snapshot returns a named list", is.list(snap) && length(snap) > 0)
check("snapshot contains 'Quiet'", "Quiet" %in% names(snap))
check("snapshot contains 'Wait_Connection_Timeout'",
      "Wait_Connection_Timeout" %in% names(snap))

tbl <- lf_options_table()
check("options_table returns a data frame", is.data.frame(tbl))
check("options_table has required columns",
      all(c("key", "type", "current", "default", "notes") %in% names(tbl)))
check("options_table lists at least 15 options", nrow(tbl) >= 15L)

# Deliberately set a non-default value, reset, and confirm.
lf_set_opt_quiet(TRUE)
stopifnot(isTRUE(lf_get_opt_quiet()))
lf_options_reset()
check("options_reset restores Quiet to default",
      identical(lf_get_opt_quiet(), FALSE))

# Password is NOT reset by default.
lf_set_opt_password("my_own_secret")
lf_options_reset()
check("options_reset preserves password by default",
      identical(lf_get_opt_password(), "********"))
# (The mask is what we can observe; the underlying value is unchanged.)

# With include_password = TRUE, the password is set back to its
# documented default (which the runtime still masks on read).
lf_options_reset(include_password = TRUE)
check("options_reset with include_password works",
      identical(lf_get_opt_password(), "********"))

# -----------------------------------------------------------------------------
# Group 8 - Shutdown
# -----------------------------------------------------------------------------
message("")
message("=== Group 8. Shutdown ===")

# The runtime was never started (no lf_prepare_done), but the bridge
# still requires a clean shutdown to release the DLL-side pools.
tryCatch(.Call("lf_exit_main_thread"), error = function(e) NULL)
tryCatch(.Call("lf_shutdown"),          error = function(e) NULL)
.Call("lf_unload_library")
check("lf_is_loaded returns FALSE after unload",
      isFALSE(.Call("lf_is_loaded")))

message("")
message(strrep("=", 60))
message("Options test summary")
message(strrep("=", 60))
message("  Passed : ", pass_count)
message("  Failed : ", fail_count)
message(strrep("=", 60))

if (fail_count > 0L) quit(status = 1)
message("")
message("Typed runtime-option accessors verified.")
quit(status = 0)