# =============================================================================
# caller_test.R
# -----------------------------------------------------------------------------
# STEP 3a test: R acting as a LingoFuse caller.
#
# Preconditions:
#   test_service.exe must be running in ANOTHER terminal.
#   It registers:
#       App: RTestService
#       API: echo   -- returns input verbatim
#       API: add    -- parses {"a": int, "b": int} -> {"result": int}
#
# Usage:
#   Rscript c_ext/tests/caller_test.R [runtime_dir]
#
#   runtime_dir   Path to the LingoFuse runtime directory. When omitted,
#                 lf_find_runtime() consults the LINGOFUSE_RUNTIME
#                 environment variable, the "lingofuse.runtime" option,
#                 and a list of relative probes under the script
#                 directory and the current working directory.
#
# LF SHUTDOWN CONTRACT
# --------------------
# This script establishes a client connection to a LingoFuse service.
# It therefore MUST, before exiting, run the LF shutdown sequence:
#
#   1. lf_exit_main_thread
#   2. lf_shutdown
#
# This is enforced by wrapping the entire test body in a helper
# function whose on.exit() handler runs the cleanup on every exit
# path, including early returns, R errors, and interrupts. The
# bridge DLL is deliberately NOT unloaded: see lf_r_api.R for the
# rationale.
# =============================================================================

# -----------------------------------------------------------------------------
# Locate the bridge library
# -----------------------------------------------------------------------------
script_dir <- tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    file_arg <- grep("^--file=", args, value = TRUE)
    if (length(file_arg) > 0) {
        dirname(normalizePath(sub("^--file=", "", file_arg[1])))
    } else getwd()
}, error = function(e) getwd())

source(file.path(script_dir, "lf_runtime.R"))

candidates <- c(
    file.path(script_dir, "..", "..", "libs"),
    file.path(script_dir, "..", "libs"),
    file.path(getwd(), "libs")
)

bridge_path <- NULL
for (d in candidates) {
    for (ext in c(".dll", ".so", ".dylib")) {
        p <- file.path(d, paste0("lfR_bridge", ext))
        if (file.exists(p)) { bridge_path <- normalizePath(p); break }
    }
    if (!is.null(bridge_path)) break
}
if (is.null(bridge_path)) {
    message("[FAIL] Bridge library not found. Build it first.")
    quit(status = 1)
}
message("[OK]   Bridge: ", bridge_path)

# -----------------------------------------------------------------------------
# Runtime directory
# -----------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)

# Runtime directory resolution.
#
# The first command-line argument, when present, is treated as an
# explicit runtime directory path. Otherwise lf_find_runtime() consults
# the LINGOFUSE_RUNTIME environment variable, the "lingofuse.runtime"
# option, and finally a list of relative probes under the script
# directory and the current working directory.
explicit_runtime <- if (length(args) >= 1) args[1] else NULL
runtime_dir <- lf_find_runtime(explicit_runtime, script_dir)
if (is.null(runtime_dir)) {
    message("[FAIL] Could not locate the LingoFuse runtime directory.")
    message("       Provide it as the first argument, set the")
    message("       LINGOFUSE_RUNTIME environment variable, or place it")
    message("       in Binary/ relative to this repository.")
    quit(status = 1)
}
message("[OK]   Runtime dir: ", runtime_dir)

# -----------------------------------------------------------------------------
# Test harness (shared state, closure-captured)
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

# -----------------------------------------------------------------------------
# Test body. Everything that touches the LingoFuse runtime lives here.
# -----------------------------------------------------------------------------
run_caller_test <- function() {
    # The shutdown sequence is scheduled before any LF call, so that an
    # early error (e.g. prepare_client returning -1) still runs it.
    on.exit({
        tryCatch(.Call("lf_exit_main_thread"),
                 error = function(e) {
                     message("[WARN] lf_exit_main_thread: ",
                             conditionMessage(e))
                 })
        tryCatch(.Call("lf_shutdown"),
                 error = function(e) {
                     message("[WARN] lf_shutdown: ",
                             conditionMessage(e))
                 })
        # Do NOT unload the bridge DLL here. See lf_r_api.R for the
        # rationale: LF_Shutdown is asynchronous and unloading the DLL
        # while a C4 worker thread is still executing inside it causes
        # an access violation.
    }, add = TRUE)

    dyn.load(bridge_path)

    res <- .Call("lf_load_library", runtime_dir)
    message("[OK]   Loaded: ", res)

    # ------------------------------------------------------------------
    # Prepare client
    # ------------------------------------------------------------------
    .Call("lf_reset_prepare")
    tag <- .Call("lf_prepare_client", "ipc:r_test")
    check("prepare_client returned a valid tag", tag >= 0,
          paste("tag =", tag))

    rc <- .Call("lf_prepare_done")
    check("prepare_done returned 1", rc == 1L,
          paste("rc =", rc))

    check("check_main_thread is TRUE",
          isTRUE(.Call("lf_check_main_thread")))

    # ------------------------------------------------------------------
    # Wait for the service to appear (broadcast may take ~3s)
    # ------------------------------------------------------------------
    message("[INFO] Waiting for RTestService to become visible...")
    seen <- FALSE
    for (i in 1:30) {
        if (isTRUE(.Call("lf_check_app", "RTestService"))) {
            seen <- TRUE; break
        }
        Sys.sleep(0.2)
    }
    check("RTestService is visible on the mesh", seen)

    if (!seen) {
        message("")
        message("[INFO] If the app is not visible, ensure test_service.exe is")
        message("       running in another terminal:")
        message("         c_ext\\tests\\test_service.exe ", runtime_dir)
        # Return early. The on.exit() handler above will run the
        # shutdown sequence.
        return(invisible(FALSE))
    }

    check("check_api(RTestService, add) is TRUE",
          isTRUE(.Call("lf_check_api", "RTestService", "add")))
    check("check_api(RTestService, echo) is TRUE",
          isTRUE(.Call("lf_check_api", "RTestService", "echo")))

    # ------------------------------------------------------------------
    # Remote call: add
    # ------------------------------------------------------------------
    resp <- .Call("lf_call", "RTestService", "add",
                  '{"a":3,"b":4}', 3000)
    check("add returns a string", is.character(resp) && length(resp) == 1L)
    check("add response contains result:7",
          grepl('"result"\\s*:\\s*7', resp),
          paste("got:", resp))

    resp2 <- .Call("lf_call", "RTestService", "add",
                   '{"a":-10,"b":25}', 3000)
    check("add handles negative integers",
          grepl('"result"\\s*:\\s*15', resp2),
          paste("got:", resp2))

    # ------------------------------------------------------------------
    # Remote call: echo
    # ------------------------------------------------------------------
    msg <- '{"msg":"hello, world"}'
    resp3 <- .Call("lf_call", "RTestService", "echo", msg, 3000)
    check("echo returns the input verbatim",
          identical(resp3, msg),
          paste("got:", resp3))

    # ------------------------------------------------------------------
    # Notify (no response)
    # ------------------------------------------------------------------
    rc_notify <- tryCatch({
        .Call("lf_notify", "RTestService", "echo", '{"event":"ping"}')
        0L
    }, error = function(e) 1L)
    check("notify did not raise", rc_notify == 0L)
    Sys.sleep(0.3)

    rc_seq <- tryCatch({
        .Call("lf_sequenced_notify", "RTestService", "echo", '{"seq":1}')
        0L
    }, error = function(e) 1L)
    check("sequenced_notify did not raise", rc_seq == 0L)
    Sys.sleep(0.3)

    invisible(TRUE)
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
tryCatch(
    run_caller_test(),
    error = function(e) {
        message("[FAIL] Unhandled error in caller test: ",
                conditionMessage(e))
        fail_count <<- fail_count + 1L
    }
)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
message("")
message(strrep("=", 60))
message("Caller test summary")
message(strrep("=", 60))
message("  Passed : ", pass_count)
message("  Failed : ", fail_count)
message(strrep("=", 60))

if (fail_count > 0L) quit(status = 1)
message("")
message("STEP 3a verified: R can call LingoFuse services.")
quit(status = 0)