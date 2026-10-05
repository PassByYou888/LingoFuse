# =============================================================================
# api.R
# -----------------------------------------------------------------------------
# Public API for the lingofuse R package.
#
# LF SHUTDOWN CONTRACT (see LF-CLEAN-001 / Z.LingoFuse.md §2.11)
# ---------------------------------------------------------------
# Before process exit, any code that has started LingoFuse must run:
#
#   1. lf_exit_main_thread
#   2. lf_app_free(app)     (if an App was created)
#   3. lf_shutdown
#
# lf_cleanup() below runs those three steps. The bridge DLL itself is
# NOT unloaded: LF_Shutdown is asynchronous, and removing the DLL from
# the process while a C4 worker thread is still executing inside it
# produces an access violation.
#
# REENTRANCY (see LF-CB-002 in the Pascal guide)
# ----------------------------------------------
# LF_Call is not reentrant on a single thread. Calling lf_call() from
# the same thread that services the callback produces a deadlock: the
# caller blocks waiting for a response, while the callback blocks
# waiting for the caller to run the pump loop.
#
# For in-process self-tests, use lf_local_call() / lf_local_notify().
# They dispatch to the registered handler directly, without going
# through the C4 mesh, and therefore do not need a pump loop.
# =============================================================================

# -----------------------------------------------------------------------------
# Package-level documentation
# -----------------------------------------------------------------------------
#
# The "_PACKAGE" sentinel tells roxygen2 to generate a package-level
# help page. @useDynLib is placed in the same roxygen block so that
# roxygen2 emits a single useDynLib() directive in NAMESPACE.

#' lingofuse: R bindings for the LingoFuse RPC framework
#'
#' Native R bindings for LingoFuse, a cross-language, cross-process,
#' cross-machine RPC framework. Call any function written in another
#' LingoFuse-aware language, or expose R functions to be called by
#' them.
#'
#' The package is a thin R layer over a C++ bridge that talks to the
#' LingoFuse runtime through its C ABI. The runtime itself is
#' distributed separately: see \code{inst/README.md} in the installed
#' package for the file layout, and the \code{LINGOFUSE_RUNTIME}
#' environment variable for automatic loading at package attach time.
#'
#' @keywords internal
#' @useDynLib lingofuse, .registration = TRUE, .fixes = "C_"
"_PACKAGE"

# -----------------------------------------------------------------------------
# Package-private state
# -----------------------------------------------------------------------------

.lf_state <- new.env(parent = emptyenv())
.lf_state$handlers <- list()             # api_name -> list(handler, bin)
.lf_state$running <- FALSE
.lf_state$main_thread_started <- FALSE

# -----------------------------------------------------------------------------
# Runtime lifecycle
# -----------------------------------------------------------------------------

#' Load the LingoFuse runtime from an explicit directory
#'
#' @param runtime_dir Absolute path to the directory that contains
#'   \code{LingoFuse64.dll} (or \code{liblingofuse.so} /
#'   \code{liblingofuse.dylib}) together with its dependencies
#'   (\code{z_ipc_64.dll}, \code{mimalloc64.dll}, ...).
#'
#' @return The path of the loaded runtime, invisibly.
#'
#' @details
#' The bridge DLL and the LingoFuse runtime are two distinct shared
#' libraries. The bridge DLL is installed by \code{R CMD INSTALL};
#' the runtime is a separate distribution. \code{lf_load()} tells the
#' bridge where the runtime lives.
#'
#' If the \code{LINGOFUSE_RUNTIME} environment variable was set before
#' \code{library(lingofuse)} was called, the package has already
#' loaded the runtime and this function is a no-op.
#'
#' @export
lf_load <- function(runtime_dir) {
    if (missing(runtime_dir) || !is.character(runtime_dir) ||
        length(runtime_dir) != 1L || !nzchar(runtime_dir)) {
        stop("lf_load: runtime_dir must be a non-empty string")
    }
    if (!dir.exists(runtime_dir)) {
        stop("lf_load: runtime_dir does not exist: ", runtime_dir)
    }
    invisible(.Call("lf_load_library", runtime_dir))
}

#' Unload the LingoFuse runtime
#'
#' Safe to call even if the runtime was never loaded. Does NOT stop
#' the simulated main thread; use \code{lf_cleanup()} for that.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_unload <- function() {
    .Call("lf_unload_library")
    invisible(NULL)
}

#' Is the LingoFuse runtime loaded?
#'
#' @return \code{TRUE} if the runtime has been loaded, \code{FALSE}
#'   otherwise.
#' @export
lf_is_loaded <- function() {
    isTRUE(.Call("lf_is_loaded"))
}

#' Last error reported by the runtime
#'
#' @return A length-1 character vector. The string may be empty if no
#'   error has been recorded.
#' @export
lf_last_error <- function() {
    .Call("lf_last_error")
}

# -----------------------------------------------------------------------------
# Application
# -----------------------------------------------------------------------------

#' Create a LingoFuse application
#'
#' @param name Application name. Case-insensitive on the wire; must be
#'   unique within the mesh.
#' @param description Optional human-readable description.
#'
#' @return An external pointer handle. Must be released with
#'   \code{lf_free_app()}.
#' @export
lf_create_app <- function(name, description = "") {
    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
        stop("lf_create_app: name must be a non-empty string")
    }
    if (!is.character(description) || length(description) != 1L) {
        stop("lf_create_app: description must be a length-1 string")
    }
    .Call("lf_app_create", name, description)
}

#' Detach an application and stop its sequenced notification threads
#'
#' The underlying object remains in the global pool until the process
#' exits (or until \code{lf_shutdown()} is called). After this call
#' the handle is invalid.
#'
#' @param app Application handle returned by \code{lf_create_app()}.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_free_app <- function(app) {
    .Call("lf_app_free", app)
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Network preparation
# -----------------------------------------------------------------------------

#' Prepare a client connection
#'
#' @param endpoint Target address, e.g. \code{"ipc:my_service"} or
#'   \code{"127.0.0.1:9898"}.
#' @param app Optional application handle to expose on the mesh. When
#'   \code{NULL} (the default) a pure consumer tunnel is created and
#'   no application is registered.
#'
#' @return The internal tag assigned to the client, invisibly. A
#'   negative value indicates a duplicate or invalid address.
#' @export
lf_prepare_client <- function(endpoint, app = NULL) {
    if (is.null(app)) {
        invisible(.Call("lf_prepare_client", endpoint))
    } else {
        invisible(.Call("lf_prepare_client_with_app", endpoint, app))
    }
}

#' Prepare a listening service
#'
#' @param listen_addr Local binding address.
#' @param physics_addr Address advertised to clients. Defaults to
#'   \code{listen_addr}.
#'
#' @return The internal tag assigned to the service, invisibly.
#' @export
lf_prepare_service <- function(listen_addr, physics_addr = listen_addr) {
    invisible(.Call("lf_prepare_service", listen_addr, physics_addr))
}

#' Start the LingoFuse main thread
#'
#' Starts the simulated main thread with all services and clients
#' prepared so far. Must be called exactly once per process; a second
#' call without an intervening \code{lf_shutdown()} returns 0.
#'
#' @return \code{1} on success. \code{0} indicates the main thread was
#'   already running (not a failure).
#' @export
lf_prepare_done <- function() {
    rc <- .Call("lf_prepare_done")
    if (rc == 1L) {
        .lf_state$main_thread_started <- TRUE
    }
    rc
}

# -----------------------------------------------------------------------------
# Health checks
# -----------------------------------------------------------------------------

#' Is the simulated main thread running?
#'
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_main_thread <- function() {
    isTRUE(.Call("lf_check_main_thread"))
}

#' Is an application visible on the mesh?
#'
#' @param app_name Application name.
#'
#' @return \code{TRUE} or \code{FALSE}. The underlying lookup uses a
#'   broadcast-updated cache with an approximate 3-second delay; do
#'   not treat the result as authoritative.
#' @export
lf_check_app <- function(app_name) {
    isTRUE(.Call("lf_check_app", app_name))
}

#' Is an API visible for a given application?
#'
#' @param app_name Application name.
#' @param api_name API name.
#'
#' @return \code{TRUE} or \code{FALSE}. Same cache-delay caveat as
#'   \code{lf_check_app()}.
#' @export
lf_check_api <- function(app_name, api_name) {
    isTRUE(.Call("lf_check_api", app_name, api_name))
}

# -----------------------------------------------------------------------------
# Remote invocation - string mode
# -----------------------------------------------------------------------------

#' Synchronous remote call (string payload)
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param payload Payload as a string (typically JSON). A trailing NUL
#'   terminator is appended automatically.
#' @param timeout_ms Timeout in milliseconds. \code{0} means "wait
#'   forever".
#'
#' @return The response as a string. An empty string indicates a
#'   timeout or an unreachable target.
#' @export
lf_call <- function(app_name, api_name, payload, timeout_ms = 5000) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_call: payload must be a length-1 string")
    }
    .Call("lf_call", app_name, api_name, payload, as.numeric(timeout_ms))
}

#' One-way notification (string payload)
#'
#' Delivery order is not guaranteed. Use \code{lf_sequenced_notify()}
#' when FIFO ordering per (app, api) pair is required.
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param payload Payload as a string (typically JSON).
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_notify <- function(app_name, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_notify: payload must be a length-1 string")
    }
    .Call("lf_notify", app_name, api_name, payload)
    invisible(NULL)
}

#' One-way notification with FIFO ordering per (app, api) pair
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param payload Payload as a string (typically JSON).
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_sequenced_notify <- function(app_name, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_sequenced_notify: payload must be a length-1 string")
    }
    .Call("lf_sequenced_notify", app_name, api_name, payload)
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Remote invocation - binary mode
# -----------------------------------------------------------------------------

#' Synchronous remote call (binary payload)
#'
#' No NUL terminator is added; the payload is transmitted verbatim.
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#' @param timeout_ms Timeout in milliseconds. \code{0} means "wait
#'   forever".
#'
#' @return The response as a raw vector. A zero-length result indicates
#'   a timeout or an unreachable target.
#' @export
lf_call_bin <- function(app_name, api_name, req_raw, timeout_ms = 5000) {
    if (!is.raw(req_raw)) {
        stop("lf_call_bin: req_raw must be a raw vector")
    }
    .Call("lf_call_bin", app_name, api_name, req_raw, as.numeric(timeout_ms))
}

#' One-way notification (binary payload)
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_notify_bin <- function(app_name, api_name, req_raw) {
    if (!is.raw(req_raw)) {
        stop("lf_notify_bin: req_raw must be a raw vector")
    }
    .Call("lf_notify_bin", app_name, api_name, req_raw)
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Local (in-process) invocation
# -----------------------------------------------------------------------------
#
# These functions dispatch to the registered handler directly, without
# going through the C4 mesh. They are safe to call from the same thread
# that runs the pump loop, and therefore are the recommended way to
# perform in-process self-tests.
#
# IMPORTANT: the handler is invoked in the caller's environment, not in
# a background thread. Any side effect the handler has on the caller's
# state will be visible immediately after lf_local_call() returns.

#' Synchronous in-process call
#'
#' Dispatches directly to the handler registered under \code{api_name},
#' bypassing the C4 mesh. Safe to call from the main thread while a
#' pump loop is running in the same process.
#'
#' @param app Application handle. Accepted for API symmetry with
#'   \code{lf_call()}; the dispatch itself does not use it.
#' @param api_name API name.
#' @param payload Payload as a string (or a raw vector for binary APIs).
#'
#' @return The handler's return value, unchanged.
#' @export
lf_local_call <- function(app, api_name, payload) {
    entry <- .lf_state$handlers[[api_name]]
    if (is.null(entry) || !is.function(entry$handler)) {
        stop("lf_local_call: no handler registered for '", api_name, "'")
    }
    if (entry$bin) {
        if (!is.raw(payload)) {
            stop("lf_local_call: payload must be a raw vector for ",
                 "binary API '", api_name, "'")
        }
    } else {
        if (!is.character(payload) || length(payload) != 1L) {
            stop("lf_local_call: payload must be a length-1 string")
        }
    }
    entry$handler(payload)
}

#' In-process notification
#'
#' Dispatches directly to the handler registered under \code{api_name},
#' bypassing the C4 mesh. The return value (if any) is discarded.
#'
#' @param app Application handle. Accepted for API symmetry with
#'   \code{lf_notify()}; the dispatch itself does not use it.
#' @param api_name API name.
#' @param payload Payload as a string (or a raw vector for binary APIs).
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_local_notify <- function(app, api_name, payload) {
    entry <- .lf_state$handlers[[api_name]]
    if (is.null(entry) || !is.function(entry$handler)) {
        stop("lf_local_notify: no handler registered for '", api_name, "'")
    }
    if (entry$bin) {
        if (!is.raw(payload)) {
            stop("lf_local_notify: payload must be a raw vector for ",
                 "binary API '", api_name, "'")
        }
    } else {
        if (!is.character(payload) || length(payload) != 1L) {
            stop("lf_local_notify: payload must be a length-1 string")
        }
    }
    entry$handler(payload)
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# DataHandle
# -----------------------------------------------------------------------------

#' Create a data handle
#'
#' @param api_name API name the handle is bound to.
#'
#' @return An external pointer handle.
#' @export
lf_data_create <- function(api_name) {
    .Call("lf_data_create", api_name)
}

#' Create a permanent data handle
#'
#' A permanent handle is never auto-reclaimed by the runtime. It must
#' be explicitly released with \code{lf_data_free()}.
#'
#' @param api_name API name the handle is bound to.
#'
#' @return An external pointer handle.
#' @export
lf_data_create_permanent <- function(api_name) {
    .Call("lf_data_create_permanent", api_name)
}

#' Release a data handle
#'
#' @param hnd Data handle to release.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_data_free <- function(hnd) {
    .Call("lf_data_free", hnd)
    invisible(NULL)
}

#' Append bytes to a data handle
#'
#' @param hnd Data handle.
#' @param data Raw vector to append.
#'
#' @return The number of bytes written, as an integer.
#' @export
lf_data_write <- function(hnd, data) {
    if (!is.raw(data)) stop("lf_data_write: data must be a raw vector")
    as.integer(.Call("lf_data_write_buffer", hnd, data))
}

#' Read up to n bytes from a data handle
#'
#' @param hnd Data handle.
#' @param n Maximum number of bytes to read.
#'
#' @return A raw vector of length at most \code{n}.
#' @export
lf_data_read <- function(hnd, n) {
    .Call("lf_data_read_buffer", hnd, as.numeric(n))
}

#' Total size of a data handle
#'
#' @param hnd Data handle.
#'
#' @return The buffer size in bytes, as an integer.
#' @export
lf_data_get_size <- function(hnd) {
    as.integer(.Call("lf_data_get_size", hnd))
}

#' Set the read/write position of a data handle
#'
#' @param hnd Data handle.
#' @param pos New position, in bytes.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_data_set_pos <- function(hnd, pos) {
    .Call("lf_data_set_pos", hnd, as.numeric(pos))
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# API registration
# -----------------------------------------------------------------------------

#' Register a Call API (request-response)
#'
#' @param app Application handle.
#' @param api_name API name.
#' @param description Human-readable description.
#' @param handler Function called on each request. Receives the input
#'   payload (a string by default, a raw vector when \code{bin = TRUE})
#'   and must return the response payload in the same form.
#' @param bin When \code{TRUE}, the handler works with raw vectors
#'   instead of strings.
#'
#' @return \code{TRUE}, invisibly.
#' @export
lf_register_call <- function(app, api_name, description = "",
                             handler, bin = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_call: handler must be a function")
    }
    # The C layer rejects duplicate API names by returning 0. Write the
    # R-side handler table only AFTER that check succeeds: otherwise a
    # failed registration would leave the table pointing at the new
    # handler while the C layer kept routing to the old one.
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

#' Register a Notify API (one-way)
#'
#' @param app Application handle.
#' @param api_name API name.
#' @param description Human-readable description.
#' @param handler Function called on each notification. Receives the
#'   input payload (a string by default, a raw vector when
#'   \code{bin = TRUE}). Its return value (if any) is discarded.
#' @param bin When \code{TRUE}, the handler works with raw vectors
#'   instead of strings.
#'
#' @return \code{TRUE}, invisibly.
#' @export
lf_register_notify <- function(app, api_name, description = "",
                               handler, bin = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_notify: handler must be a function")
    }
    # Same ordering as lf_register_call: register with the C layer
    # first, and only populate the R-side table when that succeeds.
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
    msg <- tryCatch(conditionMessage(e),
                    error = function(...) "unknown error")
    escaped <- gsub("\\\\", "\\\\\\\\", msg)
    escaped <- gsub("\"",   "\\\\\"",   escaped)
    escaped <- gsub("\n",   "\\\\n",    escaped)
    escaped <- gsub("\r",   "\\\\r",    escaped)
    escaped <- gsub("\t",   "\\\\t",    escaped)
    sprintf('{"error":"%s"}', escaped)
}

#' Process one pending job from the internal queue
#'
#' Intended to be called repeatedly from a pump loop:
#'
#' \preformatted{
#'   while (running) {
#'       lf_poll(100)
#'   }
#' }
#'
#' @param timeout_ms How long to block waiting for a job. \code{0} means
#'   non-blocking.
#'
#' @return \code{TRUE} if a job was processed, \code{FALSE} if the queue
#'   was empty (or the timeout expired).
#' @export
lf_poll <- function(timeout_ms = 0) {
    job <- .Call("lf_poll_job", as.numeric(timeout_ms))
    if (is.null(job)) return(FALSE)

    api_name <- .Call("lf_job_api_name", job)
    entry    <- .lf_state$handlers[[api_name]]

    if (is.null(entry) || !is.function(entry$handler)) {
        out <- sprintf(
            '{"error":"no handler registered for API \\"%s\\""}',
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
    TRUE
}

#' Run the job pump loop
#'
#' @param max_iterations Stop after this many iterations. \code{0} (the
#'   default) means run until \code{lf_stop()} is called.
#' @param timeout_ms Passed through to \code{lf_poll()}.
#'
#' @return The number of iterations actually performed, invisibly.
#' @export
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

#' Request the job pump loop to stop
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_stop <- function() {
    .lf_state$running <- FALSE
    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

#' Run the full LF shutdown sequence
#'
#' Runs, in order:
#'
#' \enumerate{
#'   \item \code{lf_exit_main_thread}
#'   \item \code{lf_app_free(app)} (when \code{app} is non-NULL)
#'   \item \code{lf_shutdown}
#' }
#'
#' The bridge DLL is NOT unloaded: \code{LF_Shutdown} is asynchronous
#' and worker threads may still be executing inside the DLL when it
#' returns. The operating system unloads the DLL at process exit.
#'
#' Safe to call multiple times.
#'
#' @param app Optional application handle to free. \code{NULL} if the
#'   caller never created one.
#' @param runtime_dir Unused. Retained for backward compatibility with
#'   the historical test harness.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_cleanup <- function(app = NULL, runtime_dir = NULL) {
    tryCatch(.Call("lf_exit_main_thread"), error = function(e) NULL)

    if (!is.null(app)) {
        tryCatch(.Call("lf_app_free", app), error = function(e) NULL)
    }

    tryCatch(.Call("lf_shutdown"), error = function(e) NULL)

    invisible(NULL)
}

# -----------------------------------------------------------------------------
# Runtime directory resolution
# -----------------------------------------------------------------------------

#' Locate the LingoFuse runtime directory
#'
#' Resolves the directory that contains \code{LingoFuse64.dll} (or the
#' platform equivalent) without relying on any hard-coded absolute
#' path. This helper is intended for scripts that do not want to
#' hard-code a runtime location, and for demo programs that ship with
#' the package source tree.
#'
#' @param explicit Optional explicit path. When provided and valid, it
#'   is used immediately. When provided but invalid, the function
#'   returns \code{NULL} instead of falling through to the other
#'   sources, so that a mistyped command-line argument does not
#'   silently resolve to a different directory.
#' @param script_dir Optional directory of the calling script. Used as
#'   the base for the relative probes. Defaults to the current working
#'   directory when \code{NULL}.
#'
#' @return The normalized path on success, or \code{NULL} on failure.
#'
#' @details
#' Resolution order:
#' \enumerate{
#'   \item The explicit argument, if provided.
#'   \item The \code{LINGOFUSE_RUNTIME} environment variable.
#'   \item The \code{lingofuse.runtime} R option.
#'   \item A list of relative probes under \code{script_dir} and the
#'         current working directory.
#' }
#'
#' @export
lf_find_runtime <- function(explicit = NULL, script_dir = NULL) {

    check_dir <- function(path) {
        if (is.null(path) || !is.character(path) || length(path) != 1L ||
            !nzchar(path)) {
            return(NULL)
        }
        if (dir.exists(path)) {
            return(normalizePath(path, winslash = "/", mustWork = FALSE))
        }
        NULL
    }

    # ---- 1. Explicit argument ------------------------------------------
    if (!is.null(explicit) && nzchar(explicit)) {
        resolved <- check_dir(explicit)
        if (!is.null(resolved)) {
            return(resolved)
        }
        return(NULL)
    }

    # ---- 2. Environment variable ---------------------------------------
    env_val <- Sys.getenv("LINGOFUSE_RUNTIME", unset = "")
    if (nzchar(env_val)) {
        resolved <- check_dir(env_val)
        if (!is.null(resolved)) {
            return(resolved)
        }
    }

    # ---- 3. R option ---------------------------------------------------
    opt_val <- getOption("lingofuse.runtime", default = "")
    if (is.character(opt_val) && length(opt_val) == 1L && nzchar(opt_val)) {
        resolved <- check_dir(opt_val)
        if (!is.null(resolved)) {
            return(resolved)
        }
    }

    # ---- 4. Relative probes --------------------------------------------
    bases <- character(0)
    if (!is.null(script_dir) && nzchar(script_dir)) {
        bases <- c(bases, script_dir)
    }
    bases <- c(bases, getwd())

    relatives <- c(
        "Binary",
        "runtime",
        "runtime/Binary",
        "lib",
        "../Binary",
        "../runtime",
        "../runtime/Binary",
        "../../Binary",
        "../../runtime",
        "../../runtime/Binary",
        "../../../Binary"
    )

    for (base in bases) {
        for (rel in relatives) {
            candidate <- file.path(base, rel)
            resolved <- check_dir(candidate)
            if (!is.null(resolved)) {
                return(resolved)
            }
        }
    }

    NULL
}