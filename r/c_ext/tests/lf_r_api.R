# =============================================================================
# lf_r_api.R
# -----------------------------------------------------------------------------
# High-level R API for the LingoFuse R bridge.
#
# Two handler modes are supported:
#   - string mode (default): handler receives/returns R strings (UTF-8).
#   - binary mode (bin = TRUE): handler receives/returns R raw vectors.
#
# The mode is chosen at registration time; lf_poll dispatches on it.
# All comments and user-facing strings are English.
# =============================================================================

.lf_state <- new.env(parent = emptyenv())
.lf_state$handlers <- list()   # api_name -> list(handler=fn, bin=bool)
.lf_state$running  <- FALSE

# -----------------------------------------------------------------------------
# Runtime lifecycle
# -----------------------------------------------------------------------------

lf_load <- function(runtime_dir) {
    invisible(.Call("lf_load_library", runtime_dir))
}

lf_unload <- function() {
    .Call("lf_unload_library")
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Client preparation
# -----------------------------------------------------------------------------

# Prepare a client connection. When `app` is NULL, a pure consumer
# tunnel is created and no App is exposed on the mesh. When `app` is
# an AppHandle (externalptr), the App is bound to the new tunnel and
# becomes discoverable by other processes.
lf_prepare_client <- function(endpoint, app = NULL) {
    if (is.null(app)) {
        .Call("lf_prepare_client", endpoint)
    } else {
        .Call("lf_prepare_client_with_app", endpoint, app)
    }
}

# -----------------------------------------------------------------------------
# API registration
# -----------------------------------------------------------------------------
#
# The C layer rejects duplicate API names by returning 0. The R-side
# handler table is written only AFTER that check succeeds; otherwise a
# failed registration would leave the table pointing at the new
# handler while the C layer kept routing to the old one.

lf_register_call <- function(app, api_name, description = "",
                             handler, bin = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_call: handler must be a function")
    }
    rc <- .Call("lf_register_call", app, api_name, description)
    if (rc != 1L) {
        stop("lf_register_call failed for API '", api_name, "'")
    }
    .lf_state$handlers[[api_name]] <- list(
        handler = handler,
        bin     = isTRUE(bin)
    )
    invisible(TRUE)
}

lf_register_notify <- function(app, api_name, description = "",
                               handler, bin = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_notify: handler must be a function")
    }
    rc <- .Call("lf_register_notify", app, api_name, description)
    if (rc != 1L) {
        stop("lf_register_notify failed for API '", api_name, "'")
    }
    .lf_state$handlers[[api_name]] <- list(
        handler = handler,
        bin     = isTRUE(bin)
    )
    invisible(TRUE)
}

# -----------------------------------------------------------------------------
# Job pump
# -----------------------------------------------------------------------------

.lf_error_response <- function(e) {
    msg <- tryCatch(conditionMessage(e), error = function(...) "unknown error")
    escaped <- gsub("\\\\", "\\\\\\\\", msg)
    escaped <- gsub("\"",   "\\\\\"",  escaped)
    escaped <- gsub("\n",   "\\\\n",   escaped)
    escaped <- gsub("\r",   "\\\\r",   escaped)
    escaped <- gsub("\t",   "\\\\t",   escaped)
    sprintf('{"error":"%s"}', escaped)
}

lf_poll <- function(timeout_ms = 0) {
    job <- .Call("lf_poll_job", as.numeric(timeout_ms))
    if (is.null(job)) return(FALSE)

    api_name <- .Call("lf_job_api_name", job)
    entry    <- .lf_state$handlers[[api_name]]

    if (is.null(entry) || !is.function(entry$handler)) {
        # No handler: reply with a JSON error (string mode, since we
        # do not know what the caller expects).
        out <- sprintf('{"error":"no handler registered for API \\"%s\\""}',
                       api_name)
        .Call("lf_job_complete", job, out)
        return(TRUE)
    }

    if (entry$bin) {
        input_raw <- .Call("lf_job_get_input_bin", job)
        output_raw <- tryCatch({
            res <- entry$handler(input_raw)
            if (is.null(res)) raw(0) else res
        }, error = function(e) raw(0))
        .Call("lf_job_complete_bin", job, output_raw)
    } else {
        input_str <- .Call("lf_job_get_input", job)
        output_str <- tryCatch({
            res <- entry$handler(input_str)
            if (is.null(res)) "" else as.character(res)[1]
        }, error = function(e) .lf_error_response(e))
        .Call("lf_job_complete", job, output_str)
    }
    return(TRUE)
}

lf_run <- function(max_iterations = 0, timeout_ms = 100) {
    .lf_state$running <- TRUE
    i <- 0
    while (.lf_state$running) {
        lf_poll(timeout_ms)
        i <- i + 1
        if (max_iterations > 0 && i >= max_iterations) break
    }
    invisible(i)
}

lf_stop <- function() {
    .lf_state$running <- FALSE
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Binary client helpers
# -----------------------------------------------------------------------------

lf_call_bin <- function(app_name, api_name, req_raw, timeout_ms = 5000) {
    if (!is.raw(req_raw)) stop("lf_call_bin: req_raw must be a raw vector")
    .Call("lf_call_bin", app_name, api_name, req_raw, as.numeric(timeout_ms))
}

lf_notify_bin <- function(app_name, api_name, req_raw) {
    if (!is.raw(req_raw)) stop("lf_notify_bin: req_raw must be a raw vector")
    .Call("lf_notify_bin", app_name, api_name, req_raw)
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
#
# LF shutdown contract (see LingoFuse_Pascal_Complete_Guide.md LF-CLEAN-001,
# and Z.LingoFuse.md §2.11 LF_Shutdown):
#
#   1. LF_ExitMainThread   -- stop the simulated main thread
#   2. LF_FreeApp(app)     -- detach the application (if any)
#   3. LF_Shutdown         -- release all library resources
#
# The bridge DLL is deliberately NOT unloaded here. LF_Shutdown is
# asynchronous: it returns once the top-level structures have been
# torn down, but C4 worker threads may still be executing inside the
# DLL for a short time afterwards. Calling FreeLibrary (which is what
# dyn.unload() and lf_unload_library() both do) at that point removes
# the DLL code from the process address space while a worker thread
# is still running inside it, producing an access violation.
#
# The correct behaviour is to let the operating system unload the
# DLL during process exit, when all threads have already been torn
# down by the loader. Test scripts therefore never call dyn.unload()
# after LF has been started.
#
# Each step is wrapped in tryCatch so that a failure in one step does
# not prevent the remaining steps from running. The whole function is
# idempotent: calling it twice is safe (LF_ExitMainThread and
# LF_Shutdown are both documented as safe to call multiple times, and
# the app handle is only freed once).
#
# The runtime_dir argument is retained for backward compatibility with
# earlier call sites; it is not used.

lf_cleanup <- function(app = NULL, runtime_dir = NULL) {
    tryCatch(.Call("lf_exit_main_thread"),
             error = function(e) {
                 message("[WARN] lf_cleanup: lf_exit_main_thread: ",
                         conditionMessage(e))
             })

    if (!is.null(app)) {
        tryCatch(.Call("lf_app_free", app),
                 error = function(e) {
                     message("[WARN] lf_cleanup: lf_app_free: ",
                             conditionMessage(e))
                 })
    }

    tryCatch(.Call("lf_shutdown"),
             error = function(e) {
                 message("[WARN] lf_cleanup: lf_shutdown: ",
                         conditionMessage(e))
             })

    # Deliberately do NOT call lf_unload_library / dyn.unload here.
    # See the file-level comment above.
    invisible(NULL)
}