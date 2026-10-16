# =============================================================================
# async.R
# -----------------------------------------------------------------------------
# Modern asynchronous API for the lingofuse R package.
#
# Design goals
# ------------
# The C ABI's asynchronous family (LF_Async_Call and its five variants)
# is callback-based: the caller provides a C function pointer, and the
# result is delivered on a worker thread. Exposing that shape directly
# to R users would force them to:
#
#   - handle a numeric callback_id,
#   - remember that the id is meaningless after completion,
#   - build their own on_success / on_error closure pair,
#   - understand the underlying C-side slot lifetime.
#
# That is exactly the "break in the flow" this module exists to remove.
# It offers three layers of increasing convenience, all built on the
# same primitives and all interoperable:
#
#   1. Callback style
#
#          lf_async_call("Calc", "add", payload,
#                        on_success = function(r, ud) print(r),
#                        on_error   = function(e, k, ud) message(e))
#
#      The id is returned invisibly. Nothing else is required from
#      the user.
#
#   2. Promise style
#
#          t <- lf_async_task("Calc", "add", payload)
#          lf_task_then(t, function(r, t) print(r))
#          lf_task_catch(t, function(e, k, t) message(e))
#          lf_task_finally(t, function(t) cat("done\n"))
#
#      The task object carries the result, the error, the state, and
#      the handler chain. Handlers may be attached at any time, before
#      or after completion.
#
#   3. Blocking style
#
#          result <- lf_async_call_await("Calc", "add", payload)
#
#      Issues the request and pumps the event loop until the result
#      arrives. Looks and feels like a synchronous call, but keeps the
#      underlying async dispatch (which means it works with the same
#      timeout semantics as the other two styles).
#
# All three styles share the same R-side slot table (see api.R,
# section 15-17) and the same C-side lifetime contract. Switching
# between them is free.
#
# Relationship to the pump loop
# -----------------------------
# Every asynchronous result is delivered to R through lf_poll(). This
# module does NOT change that; it only registers the appropriate slot
# handler with .lf_state$async_slots. The pump loop still has to run:
#
#   - lf_async_call / lf_async_task need the user to call lf_poll()
#     periodically (or to call lf_task_await / lf_async_call_await,
#     which pump internally).
#   - lf_async_call_await and lf_task_await pump internally and
#     therefore do not require any external loop.
#
# Task object
# -----------
# A LingoFuseTask is an environment, not a list. This is deliberate:
# a list would be copied on every mutation, and the handler chain
# (then / catch / finally) must accumulate across calls. An
# environment gives the task reference semantics, so every function
# in this module that takes a task sees the same state.
#
# Public S3 methods:
#   print.LingoFuseTask
#
# All comments and user-facing strings are English.
# =============================================================================


# =============================================================================
# Section 1 -- Task object
# =============================================================================

# Create a new LingoFuseTask environment
#
# `id` is the C-side callback id, or 0 for a dispatch failure.
# `target` is a human-readable target description (App name, UID hex,
# or P2P group name), used only for printing.
#
# Internal: not exported, not documented.
.lf_new_task <- function(id, api_name, target, timeout_ms) {
    t <- new.env(parent = emptyenv())
    t$id              <- id
    t$api_name        <- api_name
    t$target          <- target
    t$timeout_ms      <- timeout_ms
    t$state           <- "pending"   # "pending" / "done" / "error"
    t$result          <- NULL
    t$error           <- NULL
    t$error_kind      <- 0L
    t$then_handlers   <- list()
    t$catch_handlers  <- list()
    t$finally_handlers <- list()
    class(t) <- c("LingoFuseTask", "environment")
    t
}

# Compute a POSIXct deadline for a task slot.
#
# A timeout of 0 or a negative value is treated as "no timeout": the
# deadline is set far in the future so that the reaper in api.R never
# fires. This keeps the slot format uniform without forcing every
# consumer to special-case a NULL deadline.
#
# Internal: not exported, not documented.
.lf_task_deadline <- function(timeout_ms) {
    if (is.null(timeout_ms) || !is.numeric(timeout_ms) ||
        length(timeout_ms) != 1L || is.na(timeout_ms) ||
        timeout_ms <= 0) {
        return(Sys.time() + 365.25 * 24 * 3600 * 100)
    }
    Sys.time() + timeout_ms / 1000
}

# ---- State transitions ------------------------------------------------------
#
# .lf_task_resolve and .lf_task_reject are the only places that mutate
# a task from "pending" to a terminal state. Both are invoked from the
# pump loop, on the R main thread; no locking is required.

.lf_task_resolve <- function(t, result) {
    if (t$state != "pending") return(invisible(NULL))
    t$state  <- "done"
    t$result <- result

    for (fn in t$then_handlers) {
        tryCatch(fn(result, t),
                 error = function(e) {
                     message("[lingofuse task then handler] ",
                             conditionMessage(e))
                 })
    }
    for (fn in t$finally_handlers) {
        tryCatch(fn(t),
                 error = function(e) {
                     message("[lingofuse task finally handler] ",
                             conditionMessage(e))
                 })
    }
    invisible(NULL)
}

.lf_task_reject <- function(t, error, error_kind) {
    if (t$state != "pending") return(invisible(NULL))
    t$state      <- "error"
    t$error      <- if (is.null(error)) "unknown error" else as.character(error)[1]
    t$error_kind <- if (is.null(error_kind)) 0L else as.integer(error_kind)[1]

    for (fn in t$catch_handlers) {
        tryCatch(fn(t$error, t$error_kind, t),
                 error = function(e) {
                     message("[lingofuse task catch handler] ",
                             conditionMessage(e))
                 })
    }
    for (fn in t$finally_handlers) {
        tryCatch(fn(t),
                 error = function(e) {
                     message("[lingofuse task finally handler] ",
                             conditionMessage(e))
                 })
    }
    invisible(NULL)
}

# ---- Internal dispatch ------------------------------------------------------
#
# Every task-returning entry point delegates here. `dispatch_fn` is a
# zero-argument closure that issues the C-side request and returns a
# callback id. The task is registered with the R-side slot table
# BEFORE the id can ever be delivered back to us, because the C side
# only delivers results through lf_poll, which is called by the user
# (or by lf_task_await).

.lf_task_dispatch <- function(dispatch_fn, api_name, target, timeout_ms) {
    id <- 0
    tryCatch(id <- dispatch_fn(),
             error = function(e) {
                 id <<- 0
             })
    if (is.null(id) || !is.numeric(id) || length(id) != 1L || id <= 0) {
        # Dispatch failed. Return an already-failed task; no slot was
        # ever installed on the C side, so nothing needs cleanup.
        t <- .lf_new_task(0, api_name, target, timeout_ms)
        t$state      <- "error"
        t$error      <- "async dispatch failed"
        t$error_kind <- 0L
        return(t)
    }

    t <- .lf_new_task(as.numeric(id), api_name, target, timeout_ms)
    slot <- list(
        id        = as.numeric(id),
        on_success = function(result, ud) .lf_task_resolve(t, result),
        on_error   = function(err, kind, ud) .lf_task_reject(t, err, kind),
        user_data  = NULL,
        deadline   = .lf_task_deadline(timeout_ms)
    )
    .lf_state$async_slots[[as.character(id)]] <- slot
    t
}


# =============================================================================
# Section 2 -- Callback-style entry points
# -----------------------------------------------------------------------------
# These take on_success / on_error closures directly and return the
# callback id invisibly. They are the closest thing to the C ABI's
# natural shape, with the ergonomics that make them pleasant in R.
#
# Callback signatures:
#
#     on_success <- function(result, user_data)
#     on_error   <- function(error_message, error_kind, user_data)
#
# error_kind:
#     0 = dispatch failed (callback never installed on the C side)
#     1 = R-side timeout (reaper fired)
#     2 = C-side error (reserved; the current bridge never produces it)
#     3 = unknown (reserved)
# =============================================================================

.lf_async_call_cb <- function(raw_fn, api_name, target, payload,
                              on_success, on_error, timeout_ms, user_data) {
    if (!is.null(on_success) && !is.function(on_success)) {
        stop("on_success must be NULL or a function")
    }
    if (!is.null(on_error) && !is.function(on_error)) {
        stop("on_error must be NULL or a function")
    }

    id <- 0
    tryCatch(id <- raw_fn(),
             error = function(e) id <<- 0)
    if (is.null(id) || !is.numeric(id) || length(id) != 1L || id <= 0) {
        if (is.function(on_error)) {
            tryCatch(on_error("async dispatch failed", 0L, user_data),
                     error = function(e) {
                         message("[lingofuse async on_error] ",
                                 conditionMessage(e))
                     })
        }
        return(invisible(0))
    }

    slot <- list(
        id        = as.numeric(id),
        on_success = if (is.null(on_success)) NULL
                     else function(result, ud) on_success(result, ud),
        on_error   = if (is.null(on_error)) NULL
                     else function(err, kind, ud) on_error(err, kind, ud),
        user_data  = user_data,
        deadline   = .lf_task_deadline(timeout_ms)
    )
    .lf_state$async_slots[[as.character(id)]] <- slot
    invisible(as.numeric(id))
}

#' Issue an asynchronous call by App name (callback style)
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param payload Payload as a length-1 string.
#' @param on_success Optional function \code{(result, user_data)}.
#' @param on_error Optional function
#'   \code{(error_message, error_kind, user_data)}.
#' @param timeout_ms R-side timeout, milliseconds. \code{0} disables
#'   the timeout.
#' @param user_data Opaque value forwarded to both callbacks.
#' @return The callback id, invisibly (0 on dispatch failure).
#' @export
lf_async_call <- function(app_name, api_name, payload,
                          on_success = NULL, on_error = NULL,
                          timeout_ms = 5000L, user_data = NULL) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_async_call: payload must be a length-1 string")
    }
    .lf_async_call_cb(
        raw_fn = function() {
            lf_async_call_raw(app_name, api_name, payload, timeout_ms)
        },
        api_name = api_name,
        target   = app_name,
        payload  = payload,
        on_success = on_success,
        on_error   = on_error,
        timeout_ms = timeout_ms,
        user_data  = user_data
    )
}

#' Issue an asynchronous sequenced call by App name (callback style)
#'
#' Same semantics as \code{lf_async_call}, with FIFO ordering per
#' (app_name, api_name) pair on the target side.
#'
#' @inheritParams lf_async_call
#' @return The callback id, invisibly.
#' @export
lf_async_sequenced_call <- function(app_name, api_name, payload,
                                    on_success = NULL, on_error = NULL,
                                    timeout_ms = 5000L, user_data = NULL) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_async_sequenced_call: payload must be a length-1 string")
    }
    .lf_async_call_cb(
        raw_fn = function() {
            lf_async_sequenced_call_raw(app_name, api_name, payload,
                                        timeout_ms)
        },
        api_name = api_name,
        target   = app_name,
        payload  = payload,
        on_success = on_success,
        on_error   = on_error,
        timeout_ms = timeout_ms,
        user_data  = user_data
    )
}

#' Issue an asynchronous call by UID (callback style)
#'
#' @param uid Length-32 raw vector or 64-character hex string.
#' @inheritParams lf_async_call
#' @return The callback id, invisibly.
#' @export
lf_uid_async_call <- function(uid, api_name, payload,
                              on_success = NULL, on_error = NULL,
                              timeout_ms = 5000L, user_data = NULL) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_uid_async_call: payload must be a length-1 string")
    }
    uid_raw <- .lf_normalize_uid(uid)
    .lf_async_call_cb(
        raw_fn = function() {
            lf_uid_async_call_raw(uid_raw, api_name, payload, timeout_ms)
        },
        api_name = api_name,
        target   = paste0("uid:", paste(sprintf("%02x", as.integer(uid_raw)),
                                        collapse = "")),
        payload  = payload,
        on_success = on_success,
        on_error   = on_error,
        timeout_ms = timeout_ms,
        user_data  = user_data
    )
}

#' Issue an asynchronous sequenced call by UID (callback style)
#'
#' @inheritParams lf_uid_async_call
#' @return The callback id, invisibly.
#' @export
lf_uid_async_sequenced_call <- function(uid, api_name, payload,
                                        on_success = NULL, on_error = NULL,
                                        timeout_ms = 5000L,
                                        user_data = NULL) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_uid_async_sequenced_call: payload must be a length-1 string")
    }
    uid_raw <- .lf_normalize_uid(uid)
    .lf_async_call_cb(
        raw_fn = function() {
            lf_uid_async_sequenced_call_raw(uid_raw, api_name, payload,
                                            timeout_ms)
        },
        api_name = api_name,
        target   = paste0("uid:",
                          paste(sprintf("%02x", as.integer(uid_raw)),
                                collapse = "")),
        payload  = payload,
        on_success = on_success,
        on_error   = on_error,
        timeout_ms = timeout_ms,
        user_data  = user_data
    )
}

#' Issue an asynchronous call by P2P group name (callback style)
#'
#' @param p2p_name P2P group name.
#' @inheritParams lf_async_call
#' @return The callback id, invisibly.
#' @export
lf_p2pname_async_call <- function(p2p_name, api_name, payload,
                                  on_success = NULL, on_error = NULL,
                                  timeout_ms = 5000L, user_data = NULL) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_p2pname_async_call: payload must be a length-1 string")
    }
    .lf_async_call_cb(
        raw_fn = function() {
            lf_p2pname_async_call_raw(p2p_name, api_name, payload,
                                      timeout_ms)
        },
        api_name = api_name,
        target   = paste0("p2p:", p2p_name),
        payload  = payload,
        on_success = on_success,
        on_error   = on_error,
        timeout_ms = timeout_ms,
        user_data  = user_data
    )
}

#' Issue an asynchronous sequenced call by P2P group name
#'
#' @inheritParams lf_p2pname_async_call
#' @return The callback id, invisibly.
#' @export
lf_p2pname_async_sequenced_call <- function(p2p_name, api_name, payload,
                                            on_success = NULL,
                                            on_error = NULL,
                                            timeout_ms = 5000L,
                                            user_data = NULL) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_p2pname_async_sequenced_call: payload must be a length-1 string")
    }
    .lf_async_call_cb(
        raw_fn = function() {
            lf_p2pname_async_sequenced_call_raw(p2p_name, api_name, payload,
                                                timeout_ms)
        },
        api_name = api_name,
        target   = paste0("p2p:", p2p_name),
        payload  = payload,
        on_success = on_success,
        on_error   = on_error,
        timeout_ms = timeout_ms,
        user_data  = user_data
    )
}


# =============================================================================
# Section 3 -- Promise-style entry points (LingoFuseTask)
# =============================================================================

#' Issue an asynchronous call by App name (task style)
#'
#' Returns a \code{LingoFuseTask} immediately. The task's state and
#' result are updated when the response arrives (via the pump loop).
#' Handlers may be attached with \code{lf_task_then},
#' \code{lf_task_catch}, and \code{lf_task_finally} at any time.
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param payload Payload as a length-1 string.
#' @param timeout_ms R-side timeout, milliseconds. \code{0} disables
#'   the timeout.
#' @return A \code{LingoFuseTask}.
#' @export
lf_async_task <- function(app_name, api_name, payload,
                          timeout_ms = 5000L) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_async_task: payload must be a length-1 string")
    }
    .lf_task_dispatch(
        dispatch_fn = function() {
            lf_async_call_raw(app_name, api_name, payload, timeout_ms)
        },
        api_name   = api_name,
        target     = app_name,
        timeout_ms = timeout_ms
    )
}

#' Issue an asynchronous sequenced call by App name (task style)
#' @inheritParams lf_async_task
#' @return A \code{LingoFuseTask}.
#' @export
lf_async_sequenced_task <- function(app_name, api_name, payload,
                                    timeout_ms = 5000L) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_async_sequenced_task: payload must be a length-1 string")
    }
    .lf_task_dispatch(
        dispatch_fn = function() {
            lf_async_sequenced_call_raw(app_name, api_name, payload,
                                        timeout_ms)
        },
        api_name   = api_name,
        target     = app_name,
        timeout_ms = timeout_ms
    )
}

#' Issue an asynchronous call by UID (task style)
#' @param uid Length-32 raw vector or 64-character hex string.
#' @inheritParams lf_async_task
#' @return A \code{LingoFuseTask}.
#' @export
lf_uid_async_task <- function(uid, api_name, payload,
                              timeout_ms = 5000L) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_uid_async_task: payload must be a length-1 string")
    }
    uid_raw <- .lf_normalize_uid(uid)
    .lf_task_dispatch(
        dispatch_fn = function() {
            lf_uid_async_call_raw(uid_raw, api_name, payload, timeout_ms)
        },
        api_name   = api_name,
        target     = paste0("uid:",
                            paste(sprintf("%02x", as.integer(uid_raw)),
                                  collapse = "")),
        timeout_ms = timeout_ms
    )
}

#' Issue an asynchronous sequenced call by UID (task style)
#' @inheritParams lf_uid_async_task
#' @return A \code{LingoFuseTask}.
#' @export
lf_uid_async_sequenced_task <- function(uid, api_name, payload,
                                        timeout_ms = 5000L) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_uid_async_sequenced_task: payload must be a length-1 string")
    }
    uid_raw <- .lf_normalize_uid(uid)
    .lf_task_dispatch(
        dispatch_fn = function() {
            lf_uid_async_sequenced_call_raw(uid_raw, api_name, payload,
                                            timeout_ms)
        },
        api_name   = api_name,
        target     = paste0("uid:",
                            paste(sprintf("%02x", as.integer(uid_raw)),
                                  collapse = "")),
        timeout_ms = timeout_ms
    )
}

#' Issue an asynchronous call by P2P group name (task style)
#' @param p2p_name P2P group name.
#' @inheritParams lf_async_task
#' @return A \code{LingoFuseTask}.
#' @export
lf_p2pname_async_task <- function(p2p_name, api_name, payload,
                                  timeout_ms = 5000L) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_p2pname_async_task: payload must be a length-1 string")
    }
    .lf_task_dispatch(
        dispatch_fn = function() {
            lf_p2pname_async_call_raw(p2p_name, api_name, payload,
                                      timeout_ms)
        },
        api_name   = api_name,
        target     = paste0("p2p:", p2p_name),
        timeout_ms = timeout_ms
    )
}

#' Issue an asynchronous sequenced call by P2P group name (task style)
#' @inheritParams lf_p2pname_async_task
#' @return A \code{LingoFuseTask}.
#' @export
lf_p2pname_async_sequenced_task <- function(p2p_name, api_name, payload,
                                            timeout_ms = 5000L) {
    if (!is.character(payload) || length(payload) != 1L) {
        stop("lf_p2pname_async_sequenced_task: payload must be a length-1 string")
    }
    .lf_task_dispatch(
        dispatch_fn = function() {
            lf_p2pname_async_sequenced_call_raw(p2p_name, api_name, payload,
                                                timeout_ms)
        },
        api_name   = api_name,
        target     = paste0("p2p:", p2p_name),
        timeout_ms = timeout_ms
    )
}


# =============================================================================
# Section 4 -- Task handler attachment
# =============================================================================

.lf_task_assert <- function(t, fn_name) {
    if (!inherits(t, "LingoFuseTask")) {
        stop(fn_name, ": argument is not a LingoFuseTask")
    }
    invisible(NULL)
}

#' Attach a success handler to a task
#'
#' @param t A \code{LingoFuseTask}.
#' @param fn Function \code{(result, task)}. Called exactly once, if
#'   and when the task transitions to "done". If the task has already
#'   completed successfully, \code{fn} is invoked immediately.
#' @return \code{t}, invisibly, for chaining.
#' @export
lf_task_then <- function(t, fn) {
    .lf_task_assert(t, "lf_task_then")
    if (!is.function(fn)) stop("lf_task_then: fn must be a function")
    if (t$state == "pending") {
        t$then_handlers <- c(t$then_handlers, list(fn))
    } else if (t$state == "done") {
        tryCatch(fn(t$result, t),
                 error = function(e) {
                     message("[lingofuse task then handler] ",
                             conditionMessage(e))
                 })
    }
    invisible(t)
}

#' Attach an error handler to a task
#'
#' @param t A \code{LingoFuseTask}.
#' @param fn Function \code{(error_message, error_kind, task)}. Called
#'   exactly once, if and when the task transitions to "error". If the
#'   task has already failed, \code{fn} is invoked immediately.
#' @return \code{t}, invisibly, for chaining.
#' @export
lf_task_catch <- function(t, fn) {
    .lf_task_assert(t, "lf_task_catch")
    if (!is.function(fn)) stop("lf_task_catch: fn must be a function")
    if (t$state == "pending") {
        t$catch_handlers <- c(t$catch_handlers, list(fn))
    } else if (t$state == "error") {
        tryCatch(fn(t$error, t$error_kind, t),
                 error = function(e) {
                     message("[lingofuse task catch handler] ",
                             conditionMessage(e))
                 })
    }
    invisible(t)
}

#' Attach a finalisation handler to a task
#'
#' The finaliser runs after every success handler (if the task
#' succeeded) or after every error handler (if it failed). It is
#' invoked exactly once, on the same conditions as the other handler
#' types.
#'
#' @param t A \code{LingoFuseTask}.
#' @param fn Function \code{(task)}.
#' @return \code{t}, invisibly, for chaining.
#' @export
lf_task_finally <- function(t, fn) {
    .lf_task_assert(t, "lf_task_finally")
    if (!is.function(fn)) stop("lf_task_finally: fn must be a function")
    if (t$state == "pending") {
        t$finally_handlers <- c(t$finally_handlers, list(fn))
    } else {
        tryCatch(fn(t),
                 error = function(e) {
                     message("[lingofuse task finally handler] ",
                             conditionMessage(e))
                 })
    }
    invisible(t)
}


# =============================================================================
# Section 5 -- Task state queries
# =============================================================================

#' Return the state of a task
#'
#' @param t A \code{LingoFuseTask}.
#' @return \code{"pending"}, \code{"done"}, or \code{"error"}.
#' @export
lf_task_state <- function(t) {
    .lf_task_assert(t, "lf_task_state")
    t$state
}

#' Return the result of a completed task
#'
#' @param t A \code{LingoFuseTask}.
#' @return The result value (as produced by the C-side handler).
#' @details Raises an error if the task has not completed yet, or if
#'   it failed.
#' @export
lf_task_result <- function(t) {
    .lf_task_assert(t, "lf_task_result")
    if (t$state == "pending") {
        stop("lf_task_result: task is still pending")
    }
    if (t$state == "error") {
        stop("lf_task_result: task failed: ", t$error)
    }
    t$result
}

#' Return the error message of a failed task
#'
#' @param t A \code{LingoFuseTask}.
#' @return A length-1 character vector if the task failed, or
#'   \code{NULL} if it succeeded or is still pending.
#' @export
lf_task_error <- function(t) {
    .lf_task_assert(t, "lf_task_error")
    if (t$state == "error") t$error else NULL
}


# =============================================================================
# Section 6 -- Task await (blocking)
# =============================================================================

#' Block until a task completes, then return its result
#'
#' Pumps the event loop (via \code{lf_poll}) until the task is no
#' longer pending, or the optional additional timeout expires.
#'
#' The task's own deadline (set when the task was created) is
#' honoured by the reaper in the pump loop; if the C-side response
#' does not arrive in time, the task transitions to "error" with
#' \code{error_kind == 1L}, and this function raises the
#' corresponding message.
#'
#' The optional \code{timeout_ms} argument provides an additional
#' safety net: if it is non-NULL and non-zero, \code{lf_task_await}
#' will give up after that many milliseconds even if the task's own
#' deadline has not fired. This is useful when the task was created
#' with \code{timeout_ms = 0} (no C-side timeout) but the caller
#' still wants a bounded wait.
#'
#' @param t A \code{LingoFuseTask}.
#' @param timeout_ms Optional additional timeout in milliseconds.
#'   \code{NULL} (the default) means "no additional limit".
#' @return The task's result on success.
#' @details Raises an error if the task fails or the additional
#'   timeout expires.
#' @export
lf_task_await <- function(t, timeout_ms = NULL) {
    .lf_task_assert(t, "lf_task_await")

    extra_deadline <- NULL
    if (!is.null(timeout_ms) && is.numeric(timeout_ms) &&
        length(timeout_ms) == 1L && !is.na(timeout_ms) &&
        timeout_ms > 0) {
        extra_deadline <- Sys.time() + timeout_ms / 1000
    }

    while (t$state == "pending") {
        lf_poll(50)
        if (!is.null(extra_deadline) && Sys.time() > extra_deadline &&
            t$state == "pending") {
            # Force a local failure. The C side is asked to orphan
            # its slot so that a late response is discarded.
            if (t$id > 0) {
                tryCatch(lf_async_release(t$id),
                         error = function(e) NULL)
            }
            .lf_task_reject(t, "await timeout", 1L)
        }
    }

    if (t$state == "done") return(t$result)
    stop(t$error)
}


# =============================================================================
# Section 7 -- Blocking style (one-shot)
# -----------------------------------------------------------------------------
# These entry points issue a request and block until the result
# arrives. They look like synchronous calls but keep the underlying
# async dispatch semantics, including the C-side orphan lifecycle.
#
# All four are simple compositions of lf_*_async_task + lf_task_await,
# provided for ergonomic symmetry with the callback and promise
# styles.
# =============================================================================

#' Issue an asynchronous call by App name and wait for the result
#'
#' @param app_name Target application name.
#' @param api_name Target API name.
#' @param payload Payload as a length-1 string.
#' @param timeout_ms Timeout in milliseconds.
#' @return The result value (deserialized by the caller as needed).
#' @export
lf_async_call_await <- function(app_name, api_name, payload,
                                timeout_ms = 5000L) {
    t <- lf_async_task(app_name, api_name, payload, timeout_ms)
    lf_task_await(t, timeout_ms)
}

#' Issue an asynchronous sequenced call by App name and wait
#' @inheritParams lf_async_call_await
#' @return The result value.
#' @export
lf_async_sequenced_call_await <- function(app_name, api_name, payload,
                                          timeout_ms = 5000L) {
    t <- lf_async_sequenced_task(app_name, api_name, payload, timeout_ms)
    lf_task_await(t, timeout_ms)
}

#' Issue an asynchronous call by UID and wait for the result
#' @param uid Length-32 raw vector or 64-character hex string.
#' @inheritParams lf_async_call_await
#' @return The result value.
#' @export
lf_uid_async_call_await <- function(uid, api_name, payload,
                                    timeout_ms = 5000L) {
    t <- lf_uid_async_task(uid, api_name, payload, timeout_ms)
    lf_task_await(t, timeout_ms)
}

#' Issue an asynchronous sequenced call by UID and wait
#' @inheritParams lf_uid_async_call_await
#' @return The result value.
#' @export
lf_uid_async_sequenced_call_await <- function(uid, api_name, payload,
                                              timeout_ms = 5000L) {
    t <- lf_uid_async_sequenced_task(uid, api_name, payload, timeout_ms)
    lf_task_await(t, timeout_ms)
}

#' Issue an asynchronous call by P2P group name and wait
#' @param p2p_name P2P group name.
#' @inheritParams lf_async_call_await
#' @return The result value.
#' @export
lf_p2pname_async_call_await <- function(p2p_name, api_name, payload,
                                        timeout_ms = 5000L) {
    t <- lf_p2pname_async_task(p2p_name, api_name, payload, timeout_ms)
    lf_task_await(t, timeout_ms)
}

#' Issue an asynchronous sequenced call by P2P group name and wait
#' @inheritParams lf_p2pname_async_call_await
#' @return The result value.
#' @export
lf_p2pname_async_sequenced_call_await <- function(p2p_name, api_name,
                                                  payload,
                                                  timeout_ms = 5000L) {
    t <- lf_p2pname_async_sequenced_task(p2p_name, api_name, payload,
                                         timeout_ms)
    lf_task_await(t, timeout_ms)
}


# =============================================================================
# Section 8 -- S3 methods
# =============================================================================

#' Print a LingoFuseTask
#'
#' Displays the task id, target, current state, and (when completed)
#' its result or error message.
#'
#' @param x A \code{LingoFuseTask} object.
#' @param ... Unused; present for S3 method compatibility.
#' @return \code{x}, invisibly.
#' @export
#' @method print LingoFuseTask
print.LingoFuseTask <- function(x, ...) {
    cat("<LingoFuseTask>\n")
    cat("  id       :", x$id, "\n")
    cat("  api_name :", x$api_name, "\n")
    cat("  target   :", x$target, "\n")
    cat("  state    :", x$state, "\n")
    cat("  timeout  :", x$timeout_ms, "ms\n")
    if (identical(x$state, "done")) {
        cat("  result   : ")
        if (is.character(x$result) && length(x$result) == 1L) {
            cat("'", x$result, "'\n", sep = "")
        } else {
            cat(format(x$result), "\n")
        }
    } else if (identical(x$state, "error")) {
        cat("  error    :", x$error, "\n")
        cat("  kind     :", x$error_kind, "\n")
    }
    invisible(x)
}