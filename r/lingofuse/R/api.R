# =============================================================================
# api.R
# -----------------------------------------------------------------------------
# Public API for the lingofuse R package (v2.0).
#
# Version history
# ---------------
#   v1.0  Initial release: runtime lifecycle, App, network preparation,
#         health checks, App-name invocation, local dispatch, DataHandle,
#         API registration (App bound), poll loop, cleanup, runtime
#         directory resolution.
#
#   v2.0  Complete coverage of the 59-symbol C ABI, plus a modern
#         asynchronous layer.
#
#         New in v2.0:
#           - Runtime status queue (count / get / post)
#           - generate_app_name / app_bind / app_unregister
#           - data_set_size / data_get_buffer
#           - UID addressing (call / notify / sequenced_notify, + _bin)
#           - P2PName addressing (call / notify / sequenced_notify, + _bin)
#           - UID / P2PName health checks
#           - Process-wide P2P registration namespace
#           - Local execution through the C engine
#           - Network events (set / clear)
#           - Raw asynchronous dispatch (used by async.R's modern layer)
#           - lf_poll dispatches all four job kinds: Call, Notify,
#             AsyncResult, NetEvent
#
# LF SHUTDOWN CONTRACT
# --------------------
# Before process exit, any code that has started LingoFuse must run:
#
#   1. lf_exit_main_thread
#   2. lf_free_app(app)     (if an App was created)
#   3. lf_shutdown
#
# lf_cleanup() below runs those three steps and additionally releases
# the R-side async slot bookkeeping. The bridge DLL is NOT unloaded:
# LF_Shutdown is asynchronous, and removing the DLL from the process
# while a C4 worker thread is still executing inside it produces an
# access violation.
#
# REENTRANCY (LF-CB-002)
# ----------------------
# LF_Call is not reentrant on a single thread. Calling lf_call() from
# the same thread that services the callback produces a deadlock: the
# caller blocks waiting for a response, while the callback blocks
# waiting for the caller to run the pump loop.
#
# For in-process self-tests, use lf_local_call() / lf_local_notify().
# They dispatch to the registered handler directly, without going
# through the C4 mesh, and therefore do not need a pump loop.
#
# All comments and user-facing strings are English.
# =============================================================================


# =============================================================================
# Package-level documentation
# =============================================================================
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


# =============================================================================
# Package-private state
# -----------------------------------------------------------------------------
# .lf_state holds every mutable table the R layer needs. It is an
# environment, so mutations via `<<-` or direct assignment propagate
# to every closure.
#
# Tables:
#   app_handlers        -- api_name -> list(handler, bin) for App-bound
#                          registrations (populated by lf_register_call
#                          and lf_register_notify).
#   p2p_handlers        -- api_name -> list(handler, bin) for process-wide
#                          P2P registrations.
#   async_slots         -- callback_id (as character) -> list(
#                              id, on_success, on_error, deadline,
#                              user_data, state).
#   running             -- flag consulted by lf_run.
#   main_thread_started -- set to TRUE after a successful lf_prepare_done.
#   net_on_connect      -- R function installed via lf_set_network_event.
#   net_on_disconnect   -- R function installed via lf_set_network_event.
# =============================================================================

.lf_state <- new.env(parent = emptyenv())
.lf_state$app_handlers        <- list()
.lf_state$p2p_handlers        <- list()
.lf_state$async_slots         <- list()
.lf_state$running             <- FALSE
.lf_state$main_thread_started <- FALSE
.lf_state$net_on_connect      <- NULL
.lf_state$net_on_disconnect   <- NULL


# =============================================================================
# Internal helpers
# =============================================================================

# ---- UID normalization ------------------------------------------------------
#
# The C side of the bridge expects exactly 32 bytes for every UID
# parameter. This helper accepts either a length-32 raw vector or a
# 64-character hexadecimal string, and returns the canonical raw
# vector. Anything else is rejected with a clear error message.

.lf_normalize_uid <- function(uid) {
    if (is.raw(uid)) {
        if (length(uid) != 32L) {
            stop("UID must be a length-32 raw vector (got ",
                 length(uid), ")")
        }
        return(uid)
    }
    if (is.character(uid) && length(uid) == 1L && !is.na(uid)) {
        if (nchar(uid) != 64L) {
            stop("UID hex string must be 64 characters (got ",
                 nchar(uid), ")")
        }
        if (grepl("[^0-9a-fA-F]", uid)) {
            stop("UID hex string contains non-hex characters")
        }
        pairs <- substring(uid, seq(1L, 63L, by = 2L),
                                seq(2L, 64L, by = 2L))
        return(as.raw(strtoi(pairs, base = 16L)))
    }
    stop("UID must be a length-32 raw vector or a 64-character hex string")
}

# ---- Bridge library lookup --------------------------------------------------
#
# Used by abi_test.R and by test scripts that want to confirm the
# bridge DLL is reachable. Kept private to the package.

.lf_find_bridge <- function() {
    candidates <- c(
        file.path(getwd(), "libs"),
        file.path(getwd(), "..", "libs"),
        file.path(system.file(package = "lingofuse"), "libs")
    )
    for (d in candidates) {
        for (ext in c(".dll", ".so", ".dylib")) {
            p <- file.path(d, paste0("lfR_bridge", ext))
            if (file.exists(p)) return(normalizePath(p))
        }
    }
    NULL
}


# =============================================================================
# Section 1 -- Runtime lifecycle
# =============================================================================

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


# =============================================================================
# Section 2 -- Application
# =============================================================================

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

#' Bind an application to all currently unbound clients
#'
#' Must be called after \code{lf_prepare_done()} returns 1 and while
#' the simulated main thread is active. A client is eligible for
#' binding only if it has no App attached yet.
#'
#' @param app Application handle.
#'
#' @return An integer: the number of clients bound. 0 means no free
#'   client was available.
#' @export
lf_app_bind <- function(app) {
    .Call("lf_app_bind", app)
}

#' Remove an API from an application
#'
#' Removal is immediate locally. Remote peers may still see the API
#' for about 3 seconds until the broadcast propagates.
#'
#' @param app Application handle.
#' @param api_name API name to remove.
#'
#' @return \code{TRUE} if the API was found and removed, \code{FALSE}
#'   otherwise.
#' @export
lf_app_unregister <- function(app, api_name) {
    if (!is.character(api_name) || length(api_name) != 1L) {
        stop("lf_app_unregister: api_name must be a length-1 string")
    }
    isTRUE(.Call("lf_app_unregister", app, api_name) == 1L)
}

#' Generate a globally unique application name
#'
#' The name is built from active C4 tunnel addresses, process name
#' (with PID), and a high-resolution timestamp. Two consecutive calls
#' always return distinct strings.
#'
#' The underlying C API returns a pointer valid for about 5 seconds.
#' This wrapper copies the string into R immediately, so the caller
#' receives a fully detached R character vector.
#'
#' @return A length-1 character vector.
#' @export
lf_generate_app_name <- function() {
    .Call("lf_generate_app_name")
}


# =============================================================================
# Section 3 -- Network preparation
# =============================================================================

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

#' Signal the simulated main thread to exit gracefully
#'
#' After this call, no further Call / Notify jobs will be dispatched.
#' The runtime itself remains loaded until \code{lf_shutdown()}.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_exit_main_thread <- function() {
    .Call("lf_exit_main_thread")
    invisible(NULL)
}


# =============================================================================
# Section 4 -- Health checks
# =============================================================================

#' Is the simulated main thread running?
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_main_thread <- function() {
    isTRUE(.Call("lf_check_main_thread"))
}

#' Is an application visible on the mesh?
#'
#' The underlying lookup uses a broadcast-updated cache with an
#' approximate 3-second delay; do not treat the result as
#' authoritative.
#'
#' @param app_name Application name.
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_app <- function(app_name) {
    isTRUE(.Call("lf_check_app", app_name))
}

#' Is an API visible for a given application?
#'
#' Same cache-delay caveat as \code{lf_check_app()}.
#'
#' @param app_name Application name.
#' @param api_name API name.
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_api <- function(app_name, api_name) {
    isTRUE(.Call("lf_check_api", app_name, api_name))
}

#' Is a client with the given UID currently known to the mesh?
#'
#' The UID may be supplied as a length-32 raw vector or a 64-character
#' hexadecimal string.
#'
#' @param uid UID to check.
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_uid <- function(uid) {
    isTRUE(.Call("lf_check_uid", .lf_normalize_uid(uid)))
}

#' Does a client with the given UID expose the named API?
#'
#' @param uid UID to check.
#' @param api_name API name.
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_uid_api <- function(uid, api_name) {
    isTRUE(.Call("lf_check_uid_api",
                 .lf_normalize_uid(uid), api_name))
}

#' Is a client with the given P2P group name registered?
#'
#' @param p2p_name P2P group name.
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_p2pname <- function(p2p_name) {
    isTRUE(.Call("lf_check_p2pname", p2p_name))
}

#' Does a client in the given P2P group expose the named API?
#'
#' @param p2p_name P2P group name.
#' @param api_name API name.
#' @return \code{TRUE} or \code{FALSE}.
#' @export
lf_check_p2pname_api <- function(p2p_name, api_name) {
    isTRUE(.Call("lf_check_p2pname_api", p2p_name, api_name))
}


# =============================================================================
# Section 5 -- Remote invocation by App name
# =============================================================================

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
#' @param payload Payload as a string.
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
#' @param payload Payload as a string.
#' @return \code{NULL}, invisibly.
#' @export
lf_sequenced_notify <- function(app_name, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_sequenced_notify: payload must be a length-1 string")
    }
    .Call("lf_sequenced_notify", app_name, api_name, payload)
    invisible(NULL)
}

#' Synchronous remote call (binary payload)
#'
#' No NUL terminator is added; the payload is transmitted verbatim.
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#' @param timeout_ms Timeout in milliseconds.
#' @return The response as a raw vector. A zero-length result indicates
#'   a timeout or an unreachable target.
#' @export
lf_call_bin <- function(app_name, api_name, req_raw, timeout_ms = 5000) {
    if (!is.raw(req_raw)) {
        stop("lf_call_bin: req_raw must be a raw vector")
    }
    .Call("lf_call_bin", app_name, api_name, req_raw,
          as.numeric(timeout_ms))
}

#' One-way notification (binary payload)
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#' @return \code{NULL}, invisibly.
#' @export
lf_notify_bin <- function(app_name, api_name, req_raw) {
    if (!is.raw(req_raw)) {
        stop("lf_notify_bin: req_raw must be a raw vector")
    }
    .Call("lf_notify_bin", app_name, api_name, req_raw)
    invisible(NULL)
}


# =============================================================================
# Section 6 -- Remote invocation by UID
# -----------------------------------------------------------------------------
# UID addressing routes to the exact client whose TunnelLink produced
# the given 32-byte UID. A UID is regenerated on every reconnect;
# callers that cache a UID must re-probe after a link loss.
#
# UID routing is LOCAL-FIRST, matching App-name routing.
#
# A UID can address ANY API registered on the target -- whether
# app-bound or process-wide P2P -- without requiring the caller to
# know the target App name.
# =============================================================================

#' Synchronous remote call addressed by UID (string payload)
#'
#' @param uid Length-32 raw vector or 64-character hex string.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @param timeout_ms Timeout in milliseconds.
#' @return The response as a string.
#' @export
lf_uid_call <- function(uid, api_name, payload, timeout_ms = 5000) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_uid_call: payload must be a length-1 string")
    }
    .Call("lf_uid_call", .lf_normalize_uid(uid), api_name, payload,
          as.numeric(timeout_ms))
}

#' One-way notification addressed by UID (string payload)
#' @param uid Length-32 raw vector or 64-character hex string.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @return \code{NULL}, invisibly.
#' @export
lf_uid_notify <- function(uid, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_uid_notify: payload must be a length-1 string")
    }
    .Call("lf_uid_notify", .lf_normalize_uid(uid), api_name, payload)
    invisible(NULL)
}

#' One-way sequenced notification addressed by UID (string payload)
#' @param uid Length-32 raw vector or 64-character hex string.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @return \code{NULL}, invisibly.
#' @export
lf_uid_sequenced_notify <- function(uid, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_uid_sequenced_notify: payload must be a length-1 string")
    }
    .Call("lf_uid_sequenced_notify",
          .lf_normalize_uid(uid), api_name, payload)
    invisible(NULL)
}

#' Synchronous remote call addressed by UID (binary payload)
#' @param uid Length-32 raw vector or 64-character hex string.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#' @param timeout_ms Timeout in milliseconds.
#' @return The response as a raw vector.
#' @export
lf_uid_call_bin <- function(uid, api_name, req_raw, timeout_ms = 5000) {
    if (!is.raw(req_raw)) {
        stop("lf_uid_call_bin: req_raw must be a raw vector")
    }
    .Call("lf_uid_call_bin", .lf_normalize_uid(uid), api_name, req_raw,
          as.numeric(timeout_ms))
}

#' One-way notification addressed by UID (binary payload)
#' @param uid Length-32 raw vector or 64-character hex string.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#' @return \code{NULL}, invisibly.
#' @export
lf_uid_notify_bin <- function(uid, api_name, req_raw) {
    if (!is.raw(req_raw)) {
        stop("lf_uid_notify_bin: req_raw must be a raw vector")
    }
    .Call("lf_uid_notify_bin",
          .lf_normalize_uid(uid), api_name, req_raw)
    invisible(NULL)
}


# =============================================================================
# Section 7 -- Remote invocation by P2PName
# -----------------------------------------------------------------------------
# P2PName addressing routes to any client in a user-defined group. The
# server-side dispatcher picks a target using load balancing or sticky
# affinity, depending on whether the sequenced variant is used.
#
# IMPORTANT: P2PName routing is NOT local-first. Even when the caller
# process itself hosts a client in the target group, the call is
# forwarded to the server for dispatch.
# =============================================================================

#' Synchronous remote call addressed by P2P group name (string payload)
#' @param p2p_name P2P group name.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @param timeout_ms Timeout in milliseconds.
#' @return The response as a string.
#' @export
lf_p2pname_call <- function(p2p_name, api_name, payload,
                            timeout_ms = 5000) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_p2pname_call: payload must be a length-1 string")
    }
    .Call("lf_p2pname_call", p2p_name, api_name, payload,
          as.numeric(timeout_ms))
}

#' One-way notification addressed by P2P group name (string payload)
#' @param p2p_name P2P group name.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @return \code{NULL}, invisibly.
#' @export
lf_p2pname_notify <- function(p2p_name, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_p2pname_notify: payload must be a length-1 string")
    }
    .Call("lf_p2pname_notify", p2p_name, api_name, payload)
    invisible(NULL)
}

#' One-way sequenced notification addressed by P2P group name
#' @param p2p_name P2P group name.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @return \code{NULL}, invisibly.
#' @export
lf_p2pname_sequenced_notify <- function(p2p_name, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_p2pname_sequenced_notify: payload must be a length-1 string")
    }
    .Call("lf_p2pname_sequenced_notify", p2p_name, api_name, payload)
    invisible(NULL)
}

#' Synchronous remote call addressed by P2P group name (binary payload)
#' @param p2p_name P2P group name.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#' @param timeout_ms Timeout in milliseconds.
#' @return The response as a raw vector.
#' @export
lf_p2pname_call_bin <- function(p2p_name, api_name, req_raw,
                                timeout_ms = 5000) {
    if (!is.raw(req_raw)) {
        stop("lf_p2pname_call_bin: req_raw must be a raw vector")
    }
    .Call("lf_p2pname_call_bin", p2p_name, api_name, req_raw,
          as.numeric(timeout_ms))
}

#' One-way notification addressed by P2P group name (binary payload)
#' @param p2p_name P2P group name.
#' @param api_name Target API name.
#' @param req_raw Request payload as a raw vector.
#' @return \code{NULL}, invisibly.
#' @export
lf_p2pname_notify_bin <- function(p2p_name, api_name, req_raw) {
    if (!is.raw(req_raw)) {
        stop("lf_p2pname_notify_bin: req_raw must be a raw vector")
    }
    .Call("lf_p2pname_notify_bin", p2p_name, api_name, req_raw)
    invisible(NULL)
}


# =============================================================================
# Section 8 -- Local execution
# =============================================================================

# ---- R-side dispatch (no C4 engine) -----------------------------------------
#
# These functions dispatch to the handler registered in this R
# session, without going through the C4 mesh. They are the recommended
# way to perform in-process self-tests, because they do not need a
# pump loop and therefore cannot deadlock.

#' Synchronous in-process call (R-side dispatch)
#'
#' Dispatches directly to the handler registered under \code{api_name},
#' bypassing the C4 mesh. Safe to call from the main thread while a
#' pump loop is running in the same process.
#'
#' @param app Application handle. Accepted for API symmetry with
#'   \code{lf_call()}; the R-side dispatch itself does not use it.
#' @param api_name API name.
#' @param payload Payload as a string (or a raw vector for binary APIs).
#' @param p2p When \code{TRUE}, look up \code{api_name} in the
#'   process-wide P2P handler table instead of the App-bound table.
#'
#' @return The handler's return value, unchanged.
#' @export
lf_local_call <- function(app, api_name, payload, p2p = FALSE) {
    table <- if (isTRUE(p2p)) .lf_state$p2p_handlers
             else                .lf_state$app_handlers
    entry <- table[[api_name]]
    if (is.null(entry) || !is.function(entry$handler)) {
        stop("lf_local_call: no handler registered for '", api_name, "'")
    }
    if (isTRUE(entry$bin)) {
        if (!is.raw(payload)) {
            stop("lf_local_call: payload must be a raw vector for ",
                 "binary API '", api_name, "'")
        }
    } else {
        if (!is.character(payload) || length(payload) != 1L) {
            stop("lf_local_call: payload must be a length-1 string")
        }
    }
    # R-side dispatch has no network request, so there is no sender
    # identity to expose. A with_context handler still receives a
    # context list so that its signature is uniform across the
    # direct-dispatch and the Job-dispatch paths.
    if (isTRUE(entry$with_context)) {
        entry$handler(payload, list(sender_uid = NULL,
                                    sender_p2p_name = ""))
    } else {
        entry$handler(payload)
    }
}

#' In-process notification (R-side dispatch)
#'
#' Dispatches directly to the handler registered under \code{api_name},
#' bypassing the C4 mesh. The handler's return value is discarded.
#'
#' @inheritParams lf_local_call
#' @return \code{NULL}, invisibly.
#' @export
lf_local_notify <- function(app, api_name, payload, p2p = FALSE) {
    table <- if (isTRUE(p2p)) .lf_state$p2p_handlers
             else                .lf_state$app_handlers
    entry <- table[[api_name]]
    if (is.null(entry) || !is.function(entry$handler)) {
        stop("lf_local_notify: no handler registered for '", api_name, "'")
    }
    if (isTRUE(entry$bin)) {
        if (!is.raw(payload)) {
            stop("lf_local_notify: payload must be a raw vector for ",
                 "binary API '", api_name, "'")
        }
    } else {
        if (!is.character(payload) || length(payload) != 1L) {
            stop("lf_local_notify: payload must be a length-1 string")
        }
    }
    if (isTRUE(entry$with_context)) {
        entry$handler(payload, list(sender_uid = NULL,
                                    sender_p2p_name = ""))
    } else {
        entry$handler(payload)
    }
    invisible(NULL)
}

# ---- C-engine dispatch ------------------------------------------------------
#
# These functions route through LF_LocalCall / LF_LocalNotify and
# therefore dispatch to the C-side registered handlers, NOT to the
# R-side tables.
#
# WARNING: Calling lf_c_local_call from the R main thread will
# deadlock if the target handler is registered in R. The handler
# would be enqueued as a Job that can only be serviced by a
# subsequent lf_poll, but lf_c_local_call is blocking on the SAME
# thread. Use lf_local_call for in-process self-tests.

#' Synchronous local call through the C engine
#'
#' @param app Application handle.
#' @param api_name API name.
#' @param payload Payload as a string.
#'
#' @return The response as a string.
#'
#' @details
#' WARNING: this function blocks the calling thread. If the target
#' handler is registered in R, the call will deadlock (see the
#' package-level "REENTRANCY" section). Use lf_local_call for
#' in-process self-tests.
#'
#' @export
lf_c_local_call <- function(app, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_c_local_call: payload must be a length-1 string")
    }
    .Call("lf_c_local_call", app, api_name, payload)
}

#' In-process notification through the C engine
#'
#' @param app Application handle.
#' @param api_name API name.
#' @param payload Payload as a string.
#' @return \code{NULL}, invisibly.
#' @export
lf_c_local_notify <- function(app, api_name, payload) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_c_local_notify: payload must be a length-1 string")
    }
    .Call("lf_c_local_notify", app, api_name, payload)
    invisible(NULL)
}


# =============================================================================
# Section 9 -- Runtime options (stringly-typed base API)
# -----------------------------------------------------------------------------
# This is the low-level, stringly-typed option interface. Every
# option recognised by the runtime can be reached through it.
#
# The typed wrappers (lf_set_opt_quiet / lf_get_opt_quiet / ...) live
# in options.R and are the recommended entry points for everyday use.
# The functions here remain useful for dynamic key selection and for
# callers who already hold the option key as a string.
# =============================================================================

#' Adjust a runtime option (stringly-typed)
#'
#' @param option The option key (see \code{lf_options_table()} for the
#'   full list).
#' @param value The option value, as a string.
#' @return \code{NULL}, invisibly.
#' @export
lf_set_option <- function(option, value) {
    if (!is.character(option) || length(option) != 1L) {
        stop("lf_set_option: option must be a length-1 string")
    }
    if (!is.character(value) || length(value) != 1L) {
        stop("lf_set_option: value must be a length-1 string")
    }
    .Call("lf_set_option", option, value)
    invisible(NULL)
}

#' Read a runtime option (stringly-typed)
#'
#' @param option The option key.
#' @return A length-1 character vector. An empty string means the
#'   option is unknown or has no value.
#' @export
lf_get_option <- function(option) {
    if (!is.character(option) || length(option) != 1L) {
        stop("lf_get_option: option must be a length-1 string")
    }
    .Call("lf_get_option", option)
}


# =============================================================================
# Section 10 -- Status queue
# =============================================================================

#' Number of pending messages in the runtime's status queue
#'
#' The queue holds up to 1000 messages; older messages are discarded
#' when the limit is reached.
#'
#' @return An integer.
#' @export
lf_get_status_count <- function() {
    as.integer(.Call("lf_get_status_count"))
}

#' Retrieve the next message from the runtime's status queue
#'
#' Returns a pointer to an internal static buffer that is reused by
#' the next call. This wrapper copies the string into R immediately.
#'
#' @return A length-1 character vector. Empty when the queue is empty.
#' @export
lf_get_status <- function() {
    .Call("lf_get_status")
}

#' Inject a custom message into the runtime's status queue
#'
#' @param text A length-1 character vector.
#' @return \code{NULL}, invisibly.
#' @export
lf_post_status <- function(text) {
    if (!is.character(text) || length(text) != 1L) {
        stop("lf_post_status: text must be a length-1 string")
    }
    .Call("lf_post_status", text)
    invisible(NULL)
}


# =============================================================================
# Section 11 -- DataHandle
# =============================================================================

#' Create a data handle
#'
#' The underlying handle is added to the runtime's idle pool and will
#' be reclaimed after 10 minutes of inactivity. It must still be
#' released explicitly with \code{lf_data_free()} when no longer
#' needed.
#'
#' @param api_name API name the handle is bound to.
#' @return An external pointer handle.
#' @export
lf_data_create <- function(api_name) {
    .Call("lf_data_create", api_name)
}

#' Create a permanent data handle
#'
#' A permanent handle is never auto-reclaimed. It must be explicitly
#' released with \code{lf_data_free()}.
#'
#' @param api_name API name the handle is bound to.
#' @return An external pointer handle.
#' @export
lf_data_create_permanent <- function(api_name) {
    .Call("lf_data_create_permanent", api_name)
}

#' Release a data handle
#' @param hnd Data handle.
#' @return \code{NULL}, invisibly.
#' @export
lf_data_free <- function(hnd) {
    .Call("lf_data_free", hnd)
    invisible(NULL)
}

#' Append bytes to a data handle
#' @param hnd Data handle.
#' @param data Raw vector to append.
#' @return The number of bytes written, as an integer.
#' @export
lf_data_write <- function(hnd, data) {
    if (!is.raw(data)) stop("lf_data_write: data must be a raw vector")
    as.integer(.Call("lf_data_write_buffer", hnd, data))
}

#' Read up to n bytes from a data handle
#' @param hnd Data handle.
#' @param n Maximum number of bytes to read.
#' @return A raw vector of length at most \code{n}.
#' @export
lf_data_read <- function(hnd, n) {
    .Call("lf_data_read_buffer", hnd, as.numeric(n))
}

#' Total size of a data handle
#' @param hnd Data handle.
#' @return The buffer size in bytes, as an integer.
#' @export
lf_data_get_size <- function(hnd) {
    as.integer(.Call("lf_data_get_size", hnd))
}

#' Resize a data handle
#'
#' Newly allocated space is uninitialized. Growing the buffer does
#' not change its existing contents; shrinking it truncates.
#'
#' @param hnd Data handle.
#' @param size New size in bytes.
#' @return \code{NULL}, invisibly.
#' @export
lf_data_set_size <- function(hnd, size) {
    .Call("lf_data_set_size", hnd, as.numeric(size))
    invisible(NULL)
}

#' Set the read / write position of a data handle
#' @param hnd Data handle.
#' @param pos New position in bytes.
#' @return \code{NULL}, invisibly.
#' @export
lf_data_set_pos <- function(hnd, pos) {
    .Call("lf_data_set_pos", hnd, as.numeric(pos))
    invisible(NULL)
}

#' Return the internal buffer pointer as an externalptr
#'
#' This is a low-level accessor; ordinary payload I/O should use
#' \code{lf_data_read} instead. The returned pointer is not an R
#' object and must not be modified.
#'
#' @param hnd Data handle.
#' @return An externalptr, or \code{NULL} if the handle is empty.
#' @export
lf_data_get_buffer <- function(hnd) {
    .Call("lf_data_get_buffer", hnd)
}


# =============================================================================
# Section 12 -- API registration (App-bound namespace)
# =============================================================================

#' Register a Call API (request-response)
#'
#' @param app Application handle.
#' @param api_name API name.
#' @param description Human-readable description.
#' @param handler Function called on each request. Receives the input
#'   payload (a string by default, a raw vector when \code{bin = TRUE}).
#'   When \code{with_context = TRUE} the handler also receives a second
#'   argument \code{ctx}, a named list with two elements:
#'   \describe{
#'     \item{sender_uid}{Length-32 raw vector, or \code{NULL} if the
#'       runtime did not populate side data for this request.}
#'     \item{sender_p2p_name}{Length-1 character vector; empty string
#'       when the sender did not set a P2P group name.}
#'   }
#' @param bin When \code{TRUE}, the handler works with raw vectors
#'   instead of strings.
#' @param with_context When \code{TRUE}, pass a context list as the
#'   second argument to the handler. Default \code{FALSE} preserves
#'   the historical single-argument signature.
#'
#' @return \code{TRUE}, invisibly.
#' @export
lf_register_call <- function(app, api_name, description = "",
                             handler, bin = FALSE, with_context = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_call: handler must be a function")
    }
    rc <- .Call("lf_register_call", app, api_name, description)
    if (rc != 1L) {
        stop("lf_register_call failed for API '", api_name, "'")
    }
    .lf_state$app_handlers[[api_name]] <- list(
        handler      = handler,
        bin          = isTRUE(bin),
        with_context = isTRUE(with_context)
    )
    invisible(TRUE)
}

#' Register a Notify API (one-way, App-bound)
#'
#' See \code{lf_register_call} for the meaning of \code{bin} and
#' \code{with_context}. The handler's return value is discarded.
#'
#' @inheritParams lf_register_call
#' @return \code{TRUE}, invisibly.
#' @export
lf_register_notify <- function(app, api_name, description = "",
                               handler, bin = FALSE, with_context = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_notify: handler must be a function")
    }
    rc <- .Call("lf_register_notify", app, api_name, description)
    if (rc != 1L) {
        stop("lf_register_notify failed for API '", api_name, "'")
    }
    .lf_state$app_handlers[[api_name]] <- list(
        handler      = handler,
        bin          = isTRUE(bin),
        with_context = isTRUE(with_context)
    )
    invisible(TRUE)
}


# =============================================================================
# Section 13 -- API registration (process-wide P2P namespace)
# -----------------------------------------------------------------------------
# APIs registered here live on the process-wide LF_P2P_APP and are
# reachable via UID and P2PName addressing without requiring the
# caller to know the target App name. They are NOT reachable via
# App-name addressing.
#
# The lifetime of a P2P registration is the process lifetime. It is
# NOT affected by lf_free_app; only lf_shutdown clears it.
# =============================================================================

#' Register a process-wide P2P Call API
#'
#' @param api_name API name (case-insensitive on the wire).
#' @param description Human-readable description.
#' @param handler Function called on each request; same conventions as
#'   the App-bound variant. When \code{with_context = TRUE} the handler
#'   also receives a second argument \code{ctx}, a named list with two
#'   elements:
#'   \describe{
#'     \item{sender_uid}{Length-32 raw vector, or \code{NULL} if the
#'       runtime did not populate side data for this request.}
#'     \item{sender_p2p_name}{Length-1 character vector; empty string
#'       when the sender did not set a P2P group name.}
#'   }
#' @param bin When \code{TRUE}, the handler works with raw vectors.
#' @param with_context When \code{TRUE}, pass a context list as the
#'   second argument to the handler. Default \code{FALSE} preserves
#'   the historical single-argument signature.
#'
#' @return \code{TRUE}, invisibly.
#' @export
lf_register_p2p_call <- function(api_name, description = "",
                                 handler, bin = FALSE,
                                 with_context = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_p2p_call: handler must be a function")
    }
    rc <- .Call("lf_register_p2p_call", api_name, description)
    if (rc != 1L) {
        stop("lf_register_p2p_call failed for API '", api_name, "'")
    }
    .lf_state$p2p_handlers[[api_name]] <- list(
        handler      = handler,
        bin          = isTRUE(bin),
        with_context = isTRUE(with_context)
    )
    invisible(TRUE)
}

#' Register a process-wide P2P Notify API
#'
#' @inheritParams lf_register_p2p_call
#' @return \code{TRUE}, invisibly.
#' @export
lf_register_p2p_notify <- function(api_name, description = "",
                                   handler, bin = FALSE,
                                   with_context = FALSE) {
    if (!is.function(handler)) {
        stop("lf_register_p2p_notify: handler must be a function")
    }
    rc <- .Call("lf_register_p2p_notify", api_name, description)
    if (rc != 1L) {
        stop("lf_register_p2p_notify failed for API '", api_name, "'")
    }
    .lf_state$p2p_handlers[[api_name]] <- list(
        handler      = handler,
        bin          = isTRUE(bin),
        with_context = isTRUE(with_context)
    )
    invisible(TRUE)
}

#' Remove a previously registered process-wide P2P API
#'
#' @param api_name API name.
#' @return \code{TRUE} if the API was found and removed, \code{FALSE}
#'   otherwise.
#' @export
lf_unregister_p2p <- function(api_name) {
    isTRUE(.Call("lf_unregister_p2p", api_name) == 1L)
}


# =============================================================================
# Section 14 -- Network events
# -----------------------------------------------------------------------------
# The two callbacks are process-global (no per-client registration).
# They run on a C4 worker thread and are delivered to R through the
# pump loop: lf_poll() dispatches NetEvent jobs to the callbacks
# installed here.
#
# Network event semantics:
#   "Connect"    is NOT the TCP handshake completion. It fires the
#                first time the client receives a service API-info
#                broadcast, i.e. the earliest point at which remote
#                calls can be routed.
#   "Disconnect" fires once per physical link loss.
#
# Because delivery goes through lf_poll, the callback is invoked on
# the R main thread. There is no cross-thread hazard inside the R
# handler.
# =============================================================================

#' Install process-global network event handlers
#'
#' @param on_connect Called when a client becomes online. Signature:
#'   \code{function(addr)} where \code{addr} is a length-1 character
#'   vector. Pass \code{NULL} to disable the event.
#' @param on_disconnect Called when a client goes offline. Same
#'   signature. Pass \code{NULL} to disable the event.
#'
#' @return \code{NULL}, invisibly.
#' @export
lf_set_network_event <- function(on_connect = NULL, on_disconnect = NULL) {
    if (!is.null(on_connect) && !is.function(on_connect)) {
        stop("lf_set_network_event: on_connect must be NULL or a function")
    }
    if (!is.null(on_disconnect) && !is.function(on_disconnect)) {
        stop("lf_set_network_event: on_disconnect must be NULL or a function")
    }
    .lf_state$net_on_connect    <- on_connect
    .lf_state$net_on_disconnect <- on_disconnect
    .Call("lf_set_network_event_impl",
          !is.null(on_connect),
          !is.null(on_disconnect))
    invisible(NULL)
}

#' Remove both network event handlers
#' @return \code{NULL}, invisibly.
#' @export
lf_clear_network_event <- function() {
    .lf_state$net_on_connect    <- NULL
    .lf_state$net_on_disconnect <- NULL
    .Call("lf_set_network_event_impl", FALSE, FALSE)
    invisible(NULL)
}


# =============================================================================
# Section 15 -- Raw asynchronous dispatch
# -----------------------------------------------------------------------------
# These are the low-level entry points used by the modern async layer
# (async.R). Each returns a positive callback_id on dispatch success
# and 0 on dispatch failure.
#
# The R side must register callbacks for the id via .lf_state$async_slots.
# The pump loop (lf_poll) looks up the slot when an AsyncResult job
# arrives, and the timeout reaper looks up the same table when a slot's
# deadline expires.
#
# Direct users of these functions should prefer the modern wrappers in
# async.R, which manage the slot lifecycle automatically.
# =============================================================================

.lf_async_dispatch <- function(call_name, ..., timeout_ms) {
    id <- .Call(call_name, ..., as.numeric(timeout_ms))
    if (!is.numeric(id) || length(id) != 1L) return(0)
    as.numeric(id)
}

#' Raw asynchronous call by App name
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @param timeout_ms Python-side timeout (used only by the R-side
#'   reaper in the modern wrapper; the C side has no timeout).
#' @return A positive callback_id on success, 0 on dispatch failure.
#' @export
lf_async_call_raw <- function(app_name, api_name, payload,
                              timeout_ms = 5000) {
    .lf_async_dispatch("lf_async_call",
                       app_name, api_name, payload,
                       timeout_ms = timeout_ms)
}

#' Raw asynchronous sequenced call by App name
#' @inheritParams lf_async_call_raw
#' @return A positive callback_id on success, 0 on dispatch failure.
#' @export
lf_async_sequenced_call_raw <- function(app_name, api_name, payload,
                                        timeout_ms = 5000) {
    .lf_async_dispatch("lf_async_sequenced_call",
                       app_name, api_name, payload,
                       timeout_ms = timeout_ms)
}

#' Raw asynchronous call by UID
#' @param uid Length-32 raw vector or 64-character hex string.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @param timeout_ms R-side timeout, milliseconds.
#' @return A positive callback_id on success, 0 on dispatch failure.
#' @export
lf_uid_async_call_raw <- function(uid, api_name, payload,
                                  timeout_ms = 5000) {
    .lf_async_dispatch("lf_uid_async_call",
                       .lf_normalize_uid(uid), api_name, payload,
                       timeout_ms = timeout_ms)
}

#' Raw asynchronous sequenced call by UID
#' @inheritParams lf_uid_async_call_raw
#' @return A positive callback_id on success, 0 on dispatch failure.
#' @export
lf_uid_async_sequenced_call_raw <- function(uid, api_name, payload,
                                            timeout_ms = 5000) {
    .lf_async_dispatch("lf_uid_async_sequenced_call",
                       .lf_normalize_uid(uid), api_name, payload,
                       timeout_ms = timeout_ms)
}

#' Raw asynchronous call by P2P group name
#' @param p2p_name P2P group name.
#' @param api_name Target API name.
#' @param payload Payload as a string.
#' @param timeout_ms R-side timeout, milliseconds.
#' @return A positive callback_id on success, 0 on dispatch failure.
#' @export
lf_p2pname_async_call_raw <- function(p2p_name, api_name, payload,
                                      timeout_ms = 5000) {
    .lf_async_dispatch("lf_p2pname_async_call",
                       p2p_name, api_name, payload,
                       timeout_ms = timeout_ms)
}

#' Raw asynchronous sequenced call by P2P group name
#' @inheritParams lf_p2pname_async_call_raw
#' @return A positive callback_id on success, 0 on dispatch failure.
#' @export
lf_p2pname_async_sequenced_call_raw <- function(p2p_name, api_name,
                                                payload,
                                                timeout_ms = 5000) {
    .lf_async_dispatch("lf_p2pname_async_sequenced_call",
                       p2p_name, api_name, payload,
                       timeout_ms = timeout_ms)
}

#' Cancel a pending asynchronous request on the R side
#'
#' Marks the corresponding C-side slot as orphaned. Any later
#' callback that fires will have its result silently dropped.
#' Idempotent: calling this function twice with the same id is safe.
#'
#' @param callback_id The id returned by one of the *_async_call_raw
#'   functions.
#' @return \code{NULL}, invisibly.
#' @export
lf_async_release <- function(callback_id) {
    .Call("lf_async_release", as.numeric(callback_id))
    invisible(NULL)
}

#' Diagnostic: number of C-side async slots currently tracked
#' @return A numeric scalar.
#' @export
lf_async_slot_count <- function() {
    as.numeric(.Call("lf_async_slot_count"))
}


# =============================================================================
# Section 16 -- Job dispatch helpers (used by lf_poll)
# =============================================================================

# ---- Call / Notify -----------------------------------------------------
#
# Dispatch one Call or Notify job to the R handler table. The
# registry_space tag selects App-bound vs P2P table.

.lf_poll_dispatch_call_or_notify <- function(job) {
    api_name <- .Call("lf_job_api_name", job)
    space    <- .Call("lf_job_registry_space", job)   # 0=App 1=P2P
    table <- if (space == 1L) .lf_state$p2p_handlers
             else             .lf_state$app_handlers
    entry <- table[[api_name]]

    if (is.null(entry) || !is.function(entry$handler)) {
        out <- sprintf(
            '{"error":"no handler registered for API \\"%s\\""}',
            api_name)
        .Call("lf_job_complete", job, out)
        return(invisible(NULL))
    }

    # Build a context list on demand. The two C calls are cheap; we
    # only invoke them when the handler actually opted in via
    # `with_context = TRUE`.
    build_ctx <- function() {
        uid <- tryCatch(.Call("lf_job_sender_uid", job),
                        error = function(e) NULL)
        nm  <- tryCatch(.Call("lf_job_sender_p2p_name", job),
                        error = function(e) "")
        list(sender_uid      = uid,
             sender_p2p_name = nm)
    }

    want_ctx <- isTRUE(entry$with_context)

    if (isTRUE(entry$bin)) {
        input_raw <- .Call("lf_job_get_input_bin", job)
        output_raw <- tryCatch({
            res <- if (want_ctx) entry$handler(input_raw, build_ctx())
                   else         entry$handler(input_raw)
            if (is.null(res)) raw(0) else res
        }, error = function(e) raw(0))
        .Call("lf_job_complete_bin", job, output_raw)
    } else {
        input_str <- .Call("lf_job_get_input", job)
        output_str <- tryCatch({
            res <- if (want_ctx) entry$handler(input_str, build_ctx())
                   else         entry$handler(input_str)
            if (is.null(res)) "" else as.character(res)[1]
        }, error = function(e) .lf_error_response(e))
        .Call("lf_job_complete", job, output_str)
    }
    invisible(NULL)
}

# ---- AsyncResult -------------------------------------------------------

.lf_poll_dispatch_async_result <- function(job) {
    id       <- .Call("lf_job_callback_id", job)
    res      <- .Call("lf_job_result", job)
    err      <- .Call("lf_job_error", job)
    err_kind <- .Call("lf_job_error_kind", job)

    key  <- as.character(id)
    slot <- .lf_state$async_slots[[key]]

    if (!is.null(slot)) {
        .lf_state$async_slots[[key]] <- NULL
        if (nzchar(err)) {
            if (is.function(slot$on_error)) {
                tryCatch(
                    slot$on_error(err, err_kind, slot$user_data),
                    error = function(e) {
                        message("[lingofuse async on_error] ",
                                conditionMessage(e))
                    })
            }
        } else {
            if (is.function(slot$on_success)) {
                tryCatch(
                    slot$on_success(res, slot$user_data),
                    error = function(e) {
                        message("[lingofuse async on_success] ",
                                conditionMessage(e))
                    })
            }
        }
    }
    # Whether or not the R-side slot still existed, the AsyncResult
    # job's work is done. The C-side slot was already removed by the
    # trampoline. No further cleanup is needed.
    invisible(NULL)
}

# ---- NetEvent ----------------------------------------------------------

.lf_poll_dispatch_net_event <- function(job) {
    kind <- .Call("lf_job_event_kind", job)
    addr <- .Call("lf_job_event_addr", job)
    fn <- if (identical(kind, "connect"))
              .lf_state$net_on_connect
          else
              .lf_state$net_on_disconnect
    if (is.function(fn)) {
        tryCatch(
            fn(addr),
            error = function(e) {
                message("[lingofuse net event] ", conditionMessage(e))
            })
    }
    invisible(NULL)
}

# ---- Timeout reaper ----------------------------------------------------
#
# Fires the on_error callback of every async slot whose deadline has
# passed, and tells the C side to orphan its slot. Called by lf_poll
# on every iteration.

.lf_async_reap_expired <- function() {
    if (length(.lf_state$async_slots) == 0L) return(invisible(NULL))
    now <- Sys.time()
    keys <- names(.lf_state$async_slots)
    for (key in keys) {
        slot <- .lf_state$async_slots[[key]]
        if (is.null(slot) || is.null(slot$deadline)) next
        if (now < slot$deadline) next

        .lf_state$async_slots[[key]] <- NULL
        tryCatch(
            .Call("lf_async_release", as.numeric(slot$id)),
            error = function(e) NULL)
        if (is.function(slot$on_error)) {
            tryCatch(
                slot$on_error("timeout", 1L, slot$user_data),
                error = function(e) {
                    message("[lingofuse async timeout] ",
                            conditionMessage(e))
                })
        }
    }
    invisible(NULL)
}


# =============================================================================
# Section 17 -- Pump loop
# =============================================================================

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
#' The pump dispatches all four job kinds:
#' \itemize{
#'   \item Call / Notify -- to the registered R handler.
#'   \item AsyncResult   -- to the on_success / on_error callback
#'                          recorded by the async layer.
#'   \item NetEvent      -- to the function installed via
#'                          \code{lf_set_network_event}.
#' }
#'
#' After processing one job, the pump reaps any async slot whose R-side
#' deadline has expired and fires its on_error callback with the
#' message \code{"timeout"}.
#'
#' @param timeout_ms How long to block waiting for a job. \code{0} means
#'   non-blocking.
#'
#' @return \code{TRUE} if a job was processed, \code{FALSE} if the queue
#'   was empty (or the timeout expired).
#' @export
lf_poll <- function(timeout_ms = 0) {
    job <- .Call("lf_poll_job", as.numeric(timeout_ms))
    if (is.null(job)) {
        .lf_async_reap_expired()
        return(FALSE)
    }

    kind <- .Call("lf_job_kind", job)
    if (kind == 0L || kind == 1L) {
        .lf_poll_dispatch_call_or_notify(job)
    } else if (kind == 2L) {
        .lf_poll_dispatch_async_result(job)
    } else if (kind == 3L) {
        .lf_poll_dispatch_net_event(job)
    } else {
        # Unknown kind: abandon so the worker does not hang.
        tryCatch(.Call("lf_job_abandon", job),
                 error = function(e) NULL)
    }

    .lf_async_reap_expired()
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
#' @return \code{NULL}, invisibly.
#' @export
lf_stop <- function() {
    .lf_state$running <- FALSE
    invisible(NULL)
}


# =============================================================================
# Section 18 -- Cleanup
# =============================================================================

#' Run the full LF shutdown sequence
#'
#' Runs, in order:
#'
#' \enumerate{
#'   \item \code{lf_exit_main_thread}
#'   \item \code{lf_free_app(app)} (when \code{app} is non-NULL)
#'   \item \code{lf_shutdown}
#' }
#'
#' Also clears every R-side bookkeeping table: async slots, handler
#' tables, network event callbacks. The bridge DLL is NOT unloaded:
#' \code{LF_Shutdown} is asynchronous and worker threads may still be
#' executing inside the DLL when it returns.
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

    # Clear every R-side table. The C side is already shutdown; the
    # tables here must not survive into a subsequent lf_prepare cycle.
    .lf_state$app_handlers        <- list()
    .lf_state$p2p_handlers        <- list()
    .lf_state$async_slots         <- list()
    .lf_state$net_on_connect      <- NULL
    .lf_state$net_on_disconnect   <- NULL
    .lf_state$running             <- FALSE
    .lf_state$main_thread_started <- FALSE

    invisible(NULL)
}


# =============================================================================
# Section 19 -- Runtime directory resolution
# =============================================================================

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

    if (!is.null(explicit) && nzchar(explicit)) {
        resolved <- check_dir(explicit)
        if (!is.null(resolved)) {
            return(resolved)
        }
        return(NULL)
    }

    env_val <- Sys.getenv("LINGOFUSE_RUNTIME", unset = "")
    if (nzchar(env_val)) {
        resolved <- check_dir(env_val)
        if (!is.null(resolved)) {
            return(resolved)
        }
    }

    opt_val <- getOption("lingofuse.runtime", default = "")
    if (is.character(opt_val) && length(opt_val) == 1L && nzchar(opt_val)) {
        resolved <- check_dir(opt_val)
        if (!is.null(resolved)) {
            return(resolved)
        }
    }

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