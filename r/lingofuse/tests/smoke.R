# =============================================================================
# tests/smoke.R
# -----------------------------------------------------------------------------
# Package-level smoke test. Executed automatically by R CMD check
# (any *.R file directly under tests/ is run, and a non-zero exit
# status fails the check).
#
# Two halves:
#
#   1. Pure-R checks that never touch the LingoFuse runtime. These
#      always run, so R CMD check has something meaningful to verify
#      even on a machine without the runtime installed.
#
#   2. Runtime-dependent checks. These are skipped unless the
#      LINGOFUSE_RUNTIME environment variable points at a directory
#      containing LingoFuse64.dll (or the platform equivalent).
#
# Version history
# ---------------
#   v1.0  Initial release: DataHandle / App / option argument
#         validation, local dispatch, DataHandle round-trip.
#
#   v2.0  Adds pure-R checks for the new API surface:
#           - v2.0 exported function presence
#           - UID normalization (raw(32) vs 64-char hex)
#           - async task object shape and S3 dispatch
#           - options_table() / options_snapshot() return shapes
#         No runtime is required for any of the new checks; they
#         exercise the R-side validation and object model only.
#
# All user-facing strings are English.
# =============================================================================

suppressPackageStartupMessages(library(lingofuse))

# -----------------------------------------------------------------------------
# Part 1a -- v1.0 pure-R checks
# -----------------------------------------------------------------------------

stopifnot(is.function(lf_load))
stopifnot(is.function(lf_unload))
stopifnot(is.function(lf_is_loaded))
stopifnot(is.function(lf_call))
stopifnot(is.function(lf_notify))
stopifnot(is.function(lf_call_bin))
stopifnot(is.function(lf_local_call))
stopifnot(is.function(lf_local_notify))
stopifnot(is.function(lf_create_app))
stopifnot(is.function(lf_register_call))
stopifnot(is.function(lf_register_notify))
stopifnot(is.function(lf_poll))
stopifnot(is.function(lf_cleanup))

# lf_load rejects an empty string.
stopifnot(inherits(
    tryCatch({ lf_load(""); NULL }, error = function(e) e),
    "error"))

# lf_load rejects a directory that does not exist.
stopifnot(inherits(
    tryCatch({ lf_load("Z:/does/not/exist"); NULL },
             error = function(e) e),
    "error"))

# lf_call rejects a non-string payload.
stopifnot(inherits(
    tryCatch({ lf_call("a", "b", 42L); NULL },
             error = function(e) e),
    "error"))

# lf_call_bin rejects a non-raw payload.
stopifnot(inherits(
    tryCatch({ lf_call_bin("a", "b", "not raw"); NULL },
             error = function(e) e),
    "error"))

# lf_local_call on an unregistered API must error.
stopifnot(inherits(
    tryCatch({ lf_local_call(NULL, "no_such_api_xyz", "{}"); NULL },
             error = function(e) e),
    "error"))

# lf_local_call with a wrong payload type must error.
stopifnot(inherits(
    tryCatch({ lf_local_call(NULL, "no_such_api_xyz", 42L); NULL },
             error = function(e) e),
    "error"))

# lf_create_app rejects an empty name.
stopifnot(inherits(
    tryCatch({ lf_create_app(""); NULL },
             error = function(e) e),
    "error"))

message("tests/smoke.R: v1.0 pure-R checks OK")

# -----------------------------------------------------------------------------
# Part 1b -- v2.0 exported surface is present
# -----------------------------------------------------------------------------

v2_fns <- c(
    # App / DataHandle extras
    "lf_app_bind", "lf_app_unregister", "lf_generate_app_name",
    "lf_data_set_size", "lf_data_get_buffer",
    # UID / P2PName addressing
    "lf_uid_call", "lf_uid_notify", "lf_uid_sequenced_notify",
    "lf_uid_call_bin", "lf_uid_notify_bin",
    "lf_p2pname_call", "lf_p2pname_notify", "lf_p2pname_sequenced_notify",
    "lf_p2pname_call_bin", "lf_p2pname_notify_bin",
    # Health checks
    "lf_check_uid", "lf_check_uid_api",
    "lf_check_p2pname", "lf_check_p2pname_api",
    # P2P registration
    "lf_register_p2p_call", "lf_register_p2p_notify", "lf_unregister_p2p",
    # Local (C engine)
    "lf_c_local_call", "lf_c_local_notify",
    # Options (typed)
    "lf_set_opt_quiet", "lf_get_opt_quiet",
    "lf_set_opt_p2p_name", "lf_get_opt_p2p_name",
    "lf_set_opt_password", "lf_get_opt_password",
    "lf_set_opt_overlap_connection", "lf_get_opt_overlap_connection",
    "lf_options_snapshot", "lf_options_reset", "lf_options_table",
    # Status queue
    "lf_get_status_count", "lf_get_status", "lf_post_status",
    # Async (raw)
    "lf_async_call_raw", "lf_async_release", "lf_async_slot_count",
    # Async (modern)
    "lf_async_call", "lf_async_call_await",
    "lf_async_task", "lf_async_sequenced_task",
    "lf_task_then", "lf_task_catch", "lf_task_finally",
    "lf_task_state", "lf_task_result", "lf_task_error", "lf_task_await"
)
for (f in v2_fns) {
    stopifnot(is.function(get(f, envir = asNamespace("lingofuse"))))
}
message("tests/smoke.R: v2.0 exported surface present")

# -----------------------------------------------------------------------------
# Part 1c -- UID normalization (pure R)
# -----------------------------------------------------------------------------
#
# lf_uid_call validates its uid argument before ever calling the
# bridge. We can therefore exercise the validation without a runtime.

# Wrong length (raw)
stopifnot(inherits(
    tryCatch({ lf_uid_call(raw(31), "api", "{}"); NULL },
             error = function(e) e),
    "error"))
stopifnot(inherits(
    tryCatch({ lf_uid_call(raw(33), "api", "{}"); NULL },
             error = function(e) e),
    "error"))

# Wrong type
stopifnot(inherits(
    tryCatch({ lf_uid_call(12345, "api", "{}"); NULL },
             error = function(e) e),
    "error"))
stopifnot(inherits(
    tryCatch({ lf_uid_call(TRUE, "api", "{}"); NULL },
             error = function(e) e),
    "error"))

# Wrong hex length
stopifnot(inherits(
    tryCatch({ lf_uid_call("abcd", "api", "{}"); NULL },
             error = function(e) e),
    "error"))

# Non-hex characters in a 64-char string
stopifnot(inherits(
    tryCatch({ lf_uid_call(paste(rep("z", 64), collapse = ""),
                           "api", "{}"); NULL },
             error = function(e) e),
    "error"))

# NA in a hex string
stopifnot(inherits(
    tryCatch({ lf_uid_call(NA_character_, "api", "{}"); NULL },
             error = function(e) e),
    "error"))

# Same rules apply to lf_check_uid / lf_check_uid_api
stopifnot(inherits(
    tryCatch({ lf_check_uid(raw(31)); NULL },
             error = function(e) e),
    "error"))
stopifnot(inherits(
    tryCatch({ lf_check_uid_api("too short", "api"); NULL },
             error = function(e) e),
    "error"))

message("tests/smoke.R: UID normalization validation OK")

# -----------------------------------------------------------------------------
# Part 1d -- Task object shape (pure R)
# -----------------------------------------------------------------------------
#
# lf_async_task returns a task object even when the underlying
# dispatch fails. With no runtime loaded (or with an unknown App
# name), the task transitions immediately to the "error" state. We
# only verify the class hierarchy and the accessor contract; the
# actual dispatch semantics are covered by the standalone
# async_test.R script.

t_fail <- tryCatch(
    lf_async_task("__smoke_no_such_app__", "no_op", "{}",
                  timeout_ms = 100),
    error = function(e) e)

if (inherits(t_fail, "LingoFuseTask")) {
    stopifnot(is.environment(t_fail))
    stopifnot(is.character(lf_task_state(t_fail)))
    stopifnot(lf_task_state(t_fail) %in% c("pending", "error"))
    # print() must not error.
    invisible(capture.output(print(t_fail)))
    # Handler attachment must not error, even after a failure.
    invisible(lf_task_then(t_fail, function(r, tt) NULL))
    invisible(lf_task_catch(t_fail, function(e, k, tt) NULL))
    invisible(lf_task_finally(t_fail, function(tt) NULL))
}
message("tests/smoke.R: task object shape OK")

# -----------------------------------------------------------------------------
# Part 1e -- options_table / options_snapshot shapes (pure R)
# -----------------------------------------------------------------------------
#
# Both helpers work even when the runtime is not loaded: the
# underlying getters return "" for every option, which the type
# converters interpret as FALSE / 0. No runtime is required.

tbl <- lf_options_table()
stopifnot(is.data.frame(tbl))
stopifnot(all(c("key", "type", "current", "default", "notes")
              %in% names(tbl)))
stopifnot(nrow(tbl) >= 15L)

snap <- lf_options_snapshot()
stopifnot(is.list(snap))
stopifnot("Quiet" %in% names(snap))
stopifnot("Wait_Connection_Timeout" %in% names(snap))

message("tests/smoke.R: options helpers shapes OK")

# -----------------------------------------------------------------------------
# Part 2 -- runtime-dependent checks
# -----------------------------------------------------------------------------
#
# Skipped unless LINGOFUSE_RUNTIME points at a valid directory.

runtime_dir <- Sys.getenv("LINGOFUSE_RUNTIME", unset = "")
if (!nzchar(runtime_dir) || !dir.exists(runtime_dir)) {
    message("tests/smoke.R: LINGOFUSE_RUNTIME not set; ",
            "skipping runtime tests")
} else {
    lf_load(runtime_dir)
    stopifnot(isTRUE(lf_is_loaded()))

    app <- lf_create_app("RCheckApp", "R CMD check smoke test")
    stopifnot(!is.null(app))

    # ---- register + dispatch via lf_local_call (bypasses mesh) ----------
    lf_register_call(app, "echo", "echo payload back",
                     function(input) input)

    res <- lf_local_call(app, "echo", "hello")
    stopifnot(identical(res, "hello"))

    # ---- binary handler -------------------------------------------------
    lf_register_call(app, "echo_bin", "echo raw payload back",
                     function(input) input, bin = TRUE)
    res_bin <- lf_local_call(app, "echo_bin", as.raw(c(1L, 2L, 3L)))
    stopifnot(identical(res_bin, as.raw(c(1L, 2L, 3L))))

    # ---- with_context = TRUE gives the handler a ctx argument ----------
    ctx_seen <- NULL
    lf_register_call(app, "ctx_probe", "probe side data",
        with_context = TRUE,
        handler = function(input, ctx) {
            ctx_seen <<- ctx
            "ok"
        })
    res_ctx <- lf_local_call(app, "ctx_probe", "x")
    # lf_local_call (R-side dispatch) does not itself build the ctx
    # list because it bypasses the Job path; the important assertion
    # here is only that a with_context = TRUE registration is accepted
    # and callable. The Job-path ctx construction is verified by
    # uid_p2p_client.R.
    stopifnot(identical(res_ctx, "ok"))

    # ---- duplicate registration must fail -------------------------------
    ok <- tryCatch({
        lf_register_call(app, "echo", "duplicate",
                         function(input) "x")
        FALSE
    }, error = function(e) TRUE)
    stopifnot(ok)

    # ---- after the failed duplicate, the original handler still works ---
    res2 <- lf_local_call(app, "echo", "still here")
    stopifnot(identical(res2, "still here"))

    # ---- Notify API -----------------------------------------------------
    notify_seen <- new.env(parent = emptyenv())
    notify_seen$value <- NULL
    lf_register_notify(app, "sink", "record a value",
                       function(input) {
                           notify_seen$value <- input
                       })
    lf_local_notify(app, "sink", "notify-payload")
    stopifnot(identical(notify_seen$value, "notify-payload"))

    # ---- DataHandle round-trip ------------------------------------------
    hnd <- lf_data_create("dummy")
    stopifnot(identical(lf_data_get_size(hnd), 0L))
    n <- lf_data_write(hnd, as.raw(c(0x0A, 0x0B, 0x0C)))
    stopifnot(identical(n, 3L))
    stopifnot(identical(lf_data_get_size(hnd), 3L))
    lf_data_set_pos(hnd, 0)
    back <- lf_data_read(hnd, 3L)
    stopifnot(identical(back, as.raw(c(0x0A, 0x0B, 0x0C))))
    # set_size growth
    lf_data_set_size(hnd, 8)
    stopifnot(identical(lf_data_get_size(hnd), 8L))
    lf_data_set_size(hnd, 2)
    stopifnot(identical(lf_data_get_size(hnd), 2L))
    lf_data_free(hnd)

    # ---- options round trip (safe ones only) ----------------------------
    original_quiet <- lf_get_opt_quiet()
    on.exit(lf_set_opt_quiet(original_quiet), add = TRUE)
    lf_set_opt_quiet(TRUE)
    stopifnot(isTRUE(lf_get_opt_quiet()))
    lf_set_opt_quiet(FALSE)
    stopifnot(identical(lf_get_opt_quiet(), FALSE))

    # password is masked on read
    lf_set_opt_password("smoke_test_secret")
    stopifnot(identical(lf_get_opt_password(), "********"))

    # unknown option name returns ""
    stopifnot(identical(lf_get_option("__no_such_option__"), ""))

    # ---- status queue count is a non-negative number --------------------
    n <- lf_get_status_count()
    stopifnot(is.numeric(n) && length(n) == 1L && n >= 0)

    # ---- async slot count is a non-negative number ----------------------
    n_slots <- lf_async_slot_count()
    stopifnot(is.numeric(n_slots) && length(n_slots) == 1L && n_slots >= 0)

    # ---- release an unknown async id must not error ---------------------
    invisible(lf_async_release(999999))

    # ---- clean shutdown -------------------------------------------------
    lf_free_app(app)
    lf_cleanup(NULL)

    message("tests/smoke.R: all runtime checks passed")
}