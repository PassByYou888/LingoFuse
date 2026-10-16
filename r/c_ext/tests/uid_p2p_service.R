# =============================================================================
# uid_p2p_service.R
# -----------------------------------------------------------------------------
# R service used by the UID / P2PName addressing test.
#
# Exposes:
#     whoami      (Call)  -- returns the CALLER's own UID and P2P name,
#                            which the caller can then use to address
#                            itself.
#     echo        (Call)  -- returns the input verbatim.
#     service_id  (Call)  -- returns the fixed string "UidP2PService".
#     log         (Notify) -- writes a line to stdout.
#
# Sets the service's own P2P name to "uid_p2p_server_group" so that
# clients can route calls by group name.
#
# Usage:
#     Rscript uid_p2p_service.R [runtime_dir] [wait_sec]
#
# Defaults: runtime_dir auto-detected; wait_sec = 60.
#
# LF SHUTDOWN CONTRACT
# --------------------
# On exit (timeout or Ctrl+C), runs the full shutdown sequence:
#     1. lf_exit_main_thread
#     2. lf_free_app
#     3. lf_shutdown
#
# The bridge DLL is deliberately NOT unloaded. See api.R for the
# rationale (LF_Shutdown is asynchronous and worker threads may still
# be executing inside the DLL when it returns).
#
# All output and comments are English.
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
    message("[FAIL] Bridge library not found. Build it first.")
    quit(status = 1)
}

args <- commandArgs(trailingOnly = TRUE)
explicit_runtime <- if (length(args) >= 1) args[1] else NULL
runtime_dir <- lf_find_runtime(explicit_runtime, script_dir)
if (is.null(runtime_dir)) {
    message("[FAIL] Could not locate the LingoFuse runtime directory.")
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

# -----------------------------------------------------------------------------
# Load the bridge and the package sources
# -----------------------------------------------------------------------------
suppressPackageStartupMessages({
    if (requireNamespace("jsonlite", quietly = TRUE)) library(jsonlite)
})

dyn.load(bridge_path)
.Call("lf_load_library", runtime_dir)
message("[OK]   Runtime loaded")

# Source the package R files directly so that the test can run before
# the package is installed.
source(file.path(script_dir, "..", "..", "lingofuse", "R", "options.R"),
       local = TRUE)
source(file.path(script_dir, "..", "..", "lingofuse", "R", "api.R"),
       local = TRUE)
message("[OK]   api.R / options.R sourced")

# -----------------------------------------------------------------------------
# Test body
# -----------------------------------------------------------------------------
run_service <- function() {
    app <- NULL
    on.exit({
        lf_cleanup(app, runtime_dir)
    }, add = TRUE)

    app <- lf_create_app("UidP2PService", "UID/P2P test service")
    message("[OK]   App created")

    # ---- whoami --------------------------------------------------------
    # Uses with_context = TRUE to receive the sender's identity.
    # The handler returns a JSON object the caller can parse.
    lf_register_call(app, "whoami", "return caller identity",
        with_context = TRUE,
        handler = function(input, ctx) {
            uid <- ctx$sender_uid
            if (is.null(uid) || length(uid) != 32L) {
                uid_hex <- paste(rep("00", 32), collapse = "")
            } else {
                uid_hex <- paste(sprintf("%02x", as.integer(uid)),
                                 collapse = "")
            }
            p2p_name <- ctx$sender_p2p_name
            if (is.null(p2p_name) || length(p2p_name) != 1L) {
                p2p_name <- ""
            }
            if (requireNamespace("jsonlite", quietly = TRUE)) {
                jsonlite::toJSON(
                    list(uid_hex  = uid_hex,
                         p2p_name = p2p_name),
                    auto_unbox = TRUE)
            } else {
                sprintf('{"uid_hex":"%s","p2p_name":"%s"}',
                        uid_hex, p2p_name)
            }
        })

    # ---- echo ----------------------------------------------------------
    lf_register_call(app, "echo", "echo input verbatim",
        handler = function(input) input)

    # ---- service_id ----------------------------------------------------
    lf_register_call(app, "service_id", "return service id",
        handler = function(input) "UidP2PService")

    # ---- log (Notify) --------------------------------------------------
    lf_register_notify(app, "log", "log a message",
        handler = function(input) {
            cat("[UidP2PService] log: ", input, "\n", sep = "")
        })

    message("[OK]   APIs registered: whoami, echo, service_id, log")

    # ---- Set the service's P2P name ------------------------------------
    lf_set_opt_p2p_name("uid_p2p_server_group")
    message("[OK]   P2P name set to 'uid_p2p_server_group'")

    # ---- Prepare the network -------------------------------------------
    .Call("lf_reset_prepare")
    tag_svc <- .Call("lf_prepare_service",
                     "ipc:uid_p2p_test", "ipc:uid_p2p_test")
    if (tag_svc < 0) stop("prepare_service failed")
    tag_cli <- lf_prepare_client("ipc:uid_p2p_test", app)
    if (tag_cli < 0) stop("prepare_client failed")
    rc <- .Call("lf_prepare_done")
    if (rc != 1L) stop("prepare_done returned ", rc)

    message("[OK]   Service online: UidP2PService @ ipc:uid_p2p_test")
    message("[INFO] Pumping for up to ", wait_sec, " seconds...")
    message("[INFO] Press Ctrl+C to stop early.")

    # ---- Pump loop -----------------------------------------------------
    tryCatch({
        start <- Sys.time()
        while (as.numeric(Sys.time() - start, units = "secs") < wait_sec) {
            lf_poll(100)
        }
    }, interrupt = function(e) {
        message("")
        message("[INFO] Pump loop stopped by Ctrl+C.")
    })

    invisible(TRUE)
}

tryCatch(run_service(),
         error = function(e) {
             message("[FAIL] ", conditionMessage(e))
         })

message("")
message("UidP2PService finished.")
quit(status = 0)