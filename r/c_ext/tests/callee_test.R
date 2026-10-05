# =============================================================================
# callee_test.R
# -----------------------------------------------------------------------------
# STEP 3b test: R acting as a LingoFuse service.
#
# Behavior:
#   1. Load the bridge and the runtime.
#   2. Register two Call APIs: add, echo, and one Notify API: log.
#   3. Start the service on ipc:r_callee.
#   4. Pump the job queue until either:
#        (a) the wait timeout expires (default 60 s), or
#        (b) the user presses Ctrl+C.
#   5. Print all received requests.
#   6. Run the LF shutdown sequence and exit with status 0.
#
# Preconditions:
#   echo_client.exe will connect to the service from a separate
#   process and issue the calls.
#
# Usage:
#   Rscript c_ext/tests/callee_test.R [runtime_dir] [wait_sec]
#
#   runtime_dir   Path to the LingoFuse runtime directory.
#                 Default: D:/CoreLibrary/LingoFuse/Binary
#   wait_sec      Maximum time to pump the job queue, in seconds.
#                 Default: 60
#
# LF SHUTDOWN CONTRACT
# --------------------
# This script starts a LingoFuse service. It therefore MUST, before
# exiting, run the LF shutdown sequence:
#
#   1. lf_exit_main_thread
#   2. lf_app_free(app)
#   3. lf_shutdown
#
# This is enforced by wrapping the entire test body in a helper
# function whose on.exit() handler runs the cleanup on every exit
# path, including a Ctrl+C interrupt. The bridge DLL is deliberately
# NOT unloaded.
#
# SCOPE NOTE
# ----------
# `app` is a LOCAL variable of run_callee_test(), assigned with `<-`.
# Using `<<-` here would write to the global environment instead of
# the local one, leaving the local `app` as NULL and causing the C
# shim to reject it with "Argument 'app' must be an externalptr."
# =============================================================================

script_dir <- tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    file_arg <- grep("^--file=", args, value = TRUE)
    if (length(file_arg) > 0) {
        dirname(normalizePath(sub("^--file=", "", file_arg[1])))
    } else {
        getwd()
    }
}, error = function(e) getwd())

source(file.path(script_dir, "lf_r_api.R"))

# -----------------------------------------------------------------------------
# Locate the bridge library
# -----------------------------------------------------------------------------
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
# Command-line arguments
# -----------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)

runtime_dir <- if (length(args) >= 1) {
    args[1]
} else {
    "D:/CoreLibrary/LingoFuse/Binary"
}
if (!dir.exists(runtime_dir)) {
    message("[FAIL] Runtime directory does not exist: ", runtime_dir)
    quit(status = 1)
}
message("[OK]   Runtime dir: ", runtime_dir)

wait_sec <- 60L
if (length(args) >= 2) {
    parsed <- suppressWarnings(as.integer(args[2]))
    if (is.na(parsed) || parsed <= 0L) {
        message("[FAIL] wait_sec must be a positive integer, got: ", args[2])
        quit(status = 1)
    }
    wait_sec <- parsed
}
message("[OK]   Wait timeout: ", wait_sec, " s")

# -----------------------------------------------------------------------------
# Test body. The LF shutdown sequence is scheduled via on.exit().
# -----------------------------------------------------------------------------
run_callee_test <- function(wait_sec = 60L) {
    app <- NULL
    on.exit({
        lf_cleanup(app, runtime_dir)
    }, add = TRUE)

    # ------------------------------------------------------------------
    # Load bridge and runtime
    # ------------------------------------------------------------------
    dyn.load(bridge_path)
    lf_load(runtime_dir)
    message("[OK]   Runtime loaded")

    # ------------------------------------------------------------------
    # Create app and register APIs
    # ------------------------------------------------------------------
    app <- .Call("lf_app_create", "RService", "R callee STEP 3b test")
    message("[OK]   App created")

    received <- list()

    lf_register_call(app, "add", "Add two ints (JSON)", function(input) {
        received[[length(received) + 1]] <<- list(api = "add", input = input)
        req <- jsonlite::fromJSON(input)
        jsonlite::toJSON(list(result = req$a + req$b), auto_unbox = TRUE)
    })

    lf_register_call(app, "echo", "Echo input verbatim", function(input) {
        received[[length(received) + 1]] <<- list(api = "echo", input = input)
        input
    })

    lf_register_notify(app, "log", "Remote logging", function(input) {
        received[[length(received) + 1]] <<- list(api = "log", input = input)
        cat("[RService] remote log:", input, "\n")
    })

    message("[OK]   APIs registered: add, echo, log")

    # ------------------------------------------------------------------
    # Prepare network
    # ------------------------------------------------------------------
    .Call("lf_reset_prepare")
    tag_svc <- .Call("lf_prepare_service", "ipc:r_callee", "ipc:r_callee")
    if (tag_svc < 0) stop("prepare_service failed")
    tag_cli <- lf_prepare_client("ipc:r_callee", app)
    if (tag_cli < 0) stop("prepare_client failed")
    rc <- .Call("lf_prepare_done")
    if (rc != 1L) stop("prepare_done returned ", rc)
    message("[OK]   Service online: RService @ ipc:r_callee")

    # ------------------------------------------------------------------
    # Pump loop
    #
    # Two exit paths:
    #   (a) the wait timeout expires
    #   (b) the user presses Ctrl+C
    #
    # Both paths are captured by the tryCatch below. The on.exit()
    # handler at the top of this function runs the LF shutdown
    # sequence on either path.
    # ------------------------------------------------------------------
    message("[INFO] Pumping jobs for up to ", wait_sec, " seconds...")
    message("[INFO] Start echo_client.exe in another terminal now.")
    message("[INFO] Press Ctrl+C to stop the pump loop early.")

    completed_normally <- tryCatch({
        start_time <- Sys.time()
        while (as.numeric(Sys.time() - start_time, units = "secs") < wait_sec) {
            lf_poll(100)
        }
        TRUE
    }, interrupt = function(e) {
        # The user pressed Ctrl+C. Return FALSE so the caller can
        # print an informational line, then let the function continue
        # to the report section.
        FALSE
    })

    if (!completed_normally) {
        message("")
        message("[INFO] Pump loop stopped by Ctrl+C.")
    }

    # ------------------------------------------------------------------
    # Report
    # ------------------------------------------------------------------
    message("")
    message("Received requests: ", length(received))
    for (i in seq_along(received)) {
        message("  [", i, "] api=", received[[i]]$api,
                " input=", received[[i]]$input)
    }

    invisible(TRUE)
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
tryCatch(
    run_callee_test(wait_sec),
    error = function(e) {
        message("[FAIL] Unhandled error in callee test: ",
                conditionMessage(e))
    },
    interrupt = function(e) {
        # Ctrl+C arriving outside the pump loop (e.g. during setup)
        # lands here. The on.exit() handler inside run_callee_test
        # still runs, so the LF shutdown sequence is not skipped.
        message("")
        message("[INFO] Interrupted.")
    }
)

message("")
message("STEP 3b callee test finished.")
quit(status = 0)