# =============================================================================
# uid_p2p_client.R
# -----------------------------------------------------------------------------
# R client used by the UID / P2PName addressing test.
#
# Connects to ipc:uid_p2p_test, discovers its own UID and P2P name
# through the service's whoami API, then exercises:
#
#     Group 1  Bridge + runtime load, client prepare
#     Group 2  Wait for the service to become visible
#     Group 3  whoami discovery (caller UID + P2P name)
#     Group 4  UID addressing via one-way notify
#     Group 5  P2PName addressing (round-trip and timeout)
#     Group 6  UID health check
#     Group 7  P2PName health check
#     Group 8  Cleanup
#
# The client registers its own App ("UidP2PClient") with a client_echo
# API, so that a UID call targeting the client's own session has a
# handler to hit.
#
# Design note: Group 4 uses lf_uid_notify rather than lf_uid_call.
# When the calling process itself IS the target UID, the local-lookup
# step (which searches for *other* clients holding that UID) does not
# short-circuit, so the request travels to the server and is routed
# back to us. A synchronous lf_uid_call in that scenario would block
# this thread inside the call, preventing it from pumping the Job
# queue that the response would arrive on -- a guaranteed timeout.
# The one-way form avoids that deadlock and exercises the same UID
# routing decision.
#
# Usage:
#     Rscript uid_p2p_client.R [runtime_dir]
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
    message("[FAIL] Bridge library not found. Build it first.")
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

# -----------------------------------------------------------------------------
# Test body. LF shutdown sequence is scheduled via on.exit.
# -----------------------------------------------------------------------------
run_client <- function() {
    app <- NULL
    on.exit({
        lf_cleanup(app, runtime_dir)
    }, add = TRUE)

    suppressPackageStartupMessages({
        if (requireNamespace("jsonlite", quietly = TRUE)) library(jsonlite)
    })

    dyn.load(bridge_path)
    .Call("lf_load_library", runtime_dir)
    message("[OK]   Runtime loaded")

    # Source package R files directly (test runs pre-install).
    source(file.path(script_dir, "..", "..", "lingofuse", "R", "options.R"),
           local = TRUE)
    source(file.path(script_dir, "..", "..", "lingofuse", "R", "api.R"),
           local = TRUE)

    # ------------------------------------------------------------------
    # Group 1 - Create client App and prepare
    # ------------------------------------------------------------------
    message("")
    message("=== Group 1. Client prepare ===")

    app <- lf_create_app("UidP2PClient", "UID/P2P test client")

    # client_echo: used to exercise UID addressing to our own session.
    lf_register_call(app, "client_echo", "client-side echo",
        handler = function(input) input)

    # client_id: a fixed marker so we can tell client from server.
    lf_register_call(app, "client_id", "return client id",
        handler = function(input) "UidP2PClient")

    lf_register_notify(app, "log", "log a message",
        handler = function(input) {
            cat("[UidP2PClient] log: ", input, "\n", sep = "")
        })

    # The client joins a DIFFERENT P2P group from the server so that
    # P2PName routing is deterministic.
    lf_set_opt_p2p_name("uid_p2p_client_group")

    .Call("lf_reset_prepare")
    tag <- .Call("lf_prepare_client_with_app",
                 "ipc:uid_p2p_test", app)
    check("prepare_client_with_app returned a valid tag", tag >= 0,
          paste("tag =", tag))

    rc <- .Call("lf_prepare_done")
    check("prepare_done returned 1", rc == 1L, paste("rc =", rc))

    check("check_main_thread is TRUE",
          isTRUE(.Call("lf_check_main_thread")))

    # ------------------------------------------------------------------
    # Group 2 - Wait for the service to become visible
    # ------------------------------------------------------------------
    message("")
    message("=== Group 2. Wait for service ===")

    visible <- FALSE
    for (i in 1:50) {
        lf_poll(50)
        if (lf_check_api("UidP2PService", "whoami")) {
            visible <- TRUE
            break
        }
        Sys.sleep(0.1)
    }
    check("UidP2PService is visible with API whoami", visible)

    if (!visible) {
        message("[FAIL] Service not found. Ensure uid_p2p_service.R is running.")
        return(invisible(FALSE))
    }

    # ------------------------------------------------------------------
    # Group 3 - whoami discovery
    # ------------------------------------------------------------------
    message("")
    message("=== Group 3. whoami discovery ===")

    resp <- lf_call("UidP2PService", "whoami", "", 3000)
    check("whoami returns a non-empty string",
          is.character(resp) && length(resp) == 1L && nzchar(resp))

    parsed <- NULL
    if (requireNamespace("jsonlite", quietly = TRUE)) {
        parsed <- tryCatch(jsonlite::fromJSON(resp),
                           error = function(e) NULL)
    }
    check("whoami response parses as JSON", !is.null(parsed))

    if (is.null(parsed)) return(invisible(FALSE))

    uid_hex  <- parsed$uid_hex
    p2p_name <- parsed$p2p_name

    check("whoami returns a 64-char uid_hex",
          is.character(uid_hex) && nchar(uid_hex) == 64L,
          paste("uid_hex =", uid_hex))
    check("whoami returns our configured p2p_name",
          identical(p2p_name, "uid_p2p_client_group"),
          paste("got:", p2p_name))

    message("[INFO] My UID is: ", uid_hex)
    message("[INFO] My P2P name: ", p2p_name)

    # Convert the hex string to a raw(32) for the addressing APIs.
    uid_pairs <- substring(uid_hex, seq(1, 63, 2), seq(2, 64, 2))
    uid_raw <- as.raw(strtoi(uid_pairs, 16L))

    # ------------------------------------------------------------------
    # Group 4 - UID addressing (one-way)
    # ------------------------------------------------------------------
    message("")
    message("=== Group 4. UID addressing (one-way) ===")

    # UID routing designates a specific client. When the calling
    # process itself IS that client, the local-lookup step does not
    # short-circuit (it searches for OTHER clients with that UID), so
    # the request travels to the server and is routed back to us.
    #
    # A synchronous lf_uid_call in that scenario would deadlock: this
    # thread is blocked inside the call, so it cannot pump the Job
    # queue that the response would be delivered through. We
    # therefore test UID addressing with the one-way lf_uid_notify,
    # and observe delivery through the client's own "log" handler.

    # Rebind the "log" handler so that deliveries are observable.
    # (lf_register_notify would raise a duplicate-name error; the
    # handler table is edited directly instead.)
    log_seen <- new.env(parent = emptyenv())
    log_seen$value <- NULL

    .lf_state$app_handlers[["log"]] <- list(
        handler      = function(input) { log_seen$value <- input },
        bin          = FALSE,
        with_context = FALSE)

    # Fire two one-way notifies: one with the raw form, one with the
    # hex form, exercising both UID normalization paths.
    lf_uid_notify(uid_raw, "log", "uid-notify-1")
    lf_uid_notify(uid_hex, "log", "uid-notify-2")

    # Pump until both messages have been observed (or give up after
    # roughly 4 seconds).
    seen_msgs <- character(0)
    for (i in 1:40) {
        lf_poll(100)
        if (!is.null(log_seen$value)) {
            seen_msgs <- c(seen_msgs, log_seen$value)
            log_seen$value <- NULL
        }
        if (length(seen_msgs) >= 2) break
    }
    check("lf_uid_notify(self, log) delivered via the mesh",
          "uid-notify-1" %in% seen_msgs,
          paste("seen:", paste(seen_msgs, collapse = ", ")))
    check("lf_uid_notify accepts a hex string",
          "uid-notify-2" %in% seen_msgs,
          paste("seen:", paste(seen_msgs, collapse = ", ")))

    # A UID call to a nonexistent API cannot be serviced locally and
    # is routed through the server, which finds no matching App and
    # replies with an empty payload. This call is safe because it
    # does not block on a client-side handler.
    resp_missing <- lf_uid_call(uid_raw, "__no_such_api__", "x", 1500)
    check("lf_uid_call on unknown API returns empty",
          identical(resp_missing, ""),
          paste("got:", resp_missing))

    # ------------------------------------------------------------------
    # Group 5 - P2PName addressing
    # ------------------------------------------------------------------
    message("")
    message("=== Group 5. P2PName addressing ===")

    # P2PName routing is NOT local-first. Even though the client
    # itself has the P2P name "uid_p2p_client_group", a P2P call
    # using the SERVER group name goes to the server.
    resp_p2p <- lf_p2pname_call("uid_p2p_server_group", "echo",
                                "hello-p2p", 3000)
    check("lf_p2pname_call(server_group, echo) echoes input",
          identical(resp_p2p, "hello-p2p"),
          paste("got:", resp_p2p))

    resp_id <- lf_p2pname_call("uid_p2p_server_group", "service_id",
                               "", 3000)
    check("lf_p2pname_call(server_group, service_id) hits server",
          identical(resp_id, "UidP2PService"),
          paste("got:", resp_id))

    # A P2P call to a nonexistent group times out (returns empty
    # string). The C side logs "no found p2pname" but does not reply;
    # the R client's LF_Call timeout fires.
    resp_bad <- lf_p2pname_call("__no_such_group__", "echo", "x", 800)
    check("lf_p2pname_call on unknown group returns empty",
          identical(resp_bad, ""),
          paste("got:", resp_bad))

    # ------------------------------------------------------------------
    # Group 6 - UID health check
    # ------------------------------------------------------------------
    message("")
    message("=== Group 6. UID health check ===")

    # The local client pool contains our own session. lf_check_uid
    # must therefore return TRUE for our own UID.
    #
    # Note: lf_check_uid consults a cache updated by broadcasts, so
    # there may be a brief propagation delay for REMOTE UIDs. Our own
    # UID is present locally, so the check is immediate.
    check("lf_check_uid(our own uid) is TRUE",
          isTRUE(lf_check_uid(uid_raw)))

    check("lf_check_uid_api(our own uid, client_echo) is TRUE",
          isTRUE(lf_check_uid_api(uid_raw, "client_echo")))

    check("lf_check_uid_api(our own uid, unknown) is FALSE",
          isFALSE(lf_check_uid_api(uid_raw, "__no_such_api__")))

    # All-zero UID is never registered.
    check("lf_check_uid(all-zero) is FALSE",
          isFALSE(lf_check_uid(raw(32))))

    # ------------------------------------------------------------------
    # Group 7 - P2PName health check
    # ------------------------------------------------------------------
    message("")
    message("=== Group 7. P2PName health check ===")

    # The server is in "uid_p2p_server_group". Both the client and
    # the server are visible to each other through broadcasts, so
    # after a short delay the check should succeed. We pump the loop
    # to let broadcasts propagate.
    for (i in 1:20) {
        lf_poll(50)
        if (lf_check_p2pname("uid_p2p_server_group")) break
        Sys.sleep(0.1)
    }
    check("lf_check_p2pname(server group) is TRUE",
          isTRUE(lf_check_p2pname("uid_p2p_server_group")))

    check("lf_check_p2pname_api(server group, echo) is TRUE",
          isTRUE(lf_check_p2pname_api("uid_p2p_server_group", "echo")))

    check("lf_check_p2pname(unknown group) is FALSE",
          isFALSE(lf_check_p2pname("__no_such_group__")))

    invisible(TRUE)
}

# -----------------------------------------------------------------------------
# Run and report
# -----------------------------------------------------------------------------
tryCatch(run_client(),
         error = function(e) {
             message("[FAIL] Unhandled error: ", conditionMessage(e))
             fail_count <<- fail_count + 1L
         })

message("")
message(strrep("=", 60))
message("UID / P2PName test summary")
message(strrep("=", 60))
message("  Passed : ", pass_count)
message("  Failed : ", fail_count)
message(strrep("=", 60))

if (fail_count > 0L) quit(status = 1)
message("")
message("UID and P2PName addressing verified.")
quit(status = 0)