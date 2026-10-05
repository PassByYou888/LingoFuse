# =============================================================================
# tests/smoke.R
# -----------------------------------------------------------------------------
# Package-level smoke test. Executed automatically by R CMD check
# (any *.R file directly under tests/ is run, and a non-zero exit
# status fails the check).
#
# The script has two halves:
#
#   1. Pure-R checks that never touch the LingoFuse runtime. These
#      always run, so R CMD check has something meaningful to verify
#      even on a machine without the runtime installed.
#
#   2. Runtime-dependent checks. These are skipped unless the
#      LINGOFUSE_RUNTIME environment variable points at a directory
#      containing LingoFuse64.dll (or the platform equivalent).
#
# The script does NOT call quit(). R CMD check runs tests/*.R in a
# dedicated subprocess and treats the subprocess exit status as the
# test result. A stopifnot() failure raises an R error, which makes
# the subprocess exit non-zero, which fails the check. A successful
# run simply falls off the end of the file.
# =============================================================================

suppressPackageStartupMessages(library(lingofuse))

# -----------------------------------------------------------------------------
# Part 1 — pure-R checks (no runtime needed)
# -----------------------------------------------------------------------------

# The exported surface must be present as functions.
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

message("tests/smoke.R: pure-R checks OK")

# -----------------------------------------------------------------------------
# Part 2 — runtime-dependent checks (skipped when LINGOFUSE_RUNTIME unset)
# -----------------------------------------------------------------------------

runtime_dir <- Sys.getenv("LINGOFUSE_RUNTIME", unset = "")
if (!nzchar(runtime_dir) || !dir.exists(runtime_dir)) {
    message("tests/smoke.R: LINGOFUSE_RUNTIME not set; ",
            "skipping runtime tests")
} else {
    lf_load(runtime_dir)
    stopifnot(isTRUE(lf_is_loaded()))

    app <- lf_create_app("RCheckApp", "R CMD check smoke test")
    stopifnot(!is.null(app))

    # Register a handler and call it via lf_local_call (bypasses mesh).
    lf_register_call(app, "echo", "echo payload back", function(input) input)

    res <- lf_local_call(app, "echo", "hello")
    stopifnot(identical(res, "hello"))

    # Binary handler.
    lf_register_call(app, "echo_bin", "echo raw payload back",
                     function(input) input, bin = TRUE)
    res_bin <- lf_local_call(app, "echo_bin", as.raw(c(1L, 2L, 3L)))
    stopifnot(identical(res_bin, as.raw(c(1L, 2L, 3L))))

    # Duplicate registration must fail (this exercises the ordering fix
    # in lf_register_call: the R-side table must NOT be polluted).
    ok <- tryCatch({
        lf_register_call(app, "echo", "duplicate", function(input) "x")
        FALSE
    }, error = function(e) TRUE)
    stopifnot(ok)

    # After the failed duplicate, the original handler must still work.
    res2 <- lf_local_call(app, "echo", "still here")
    stopifnot(identical(res2, "still here"))

    # Notify API.
    notify_seen <- new.env(parent = emptyenv())
    notify_seen$value <- NULL
    lf_register_notify(app, "sink", "record a value", function(input) {
        notify_seen$value <- input
    })
    lf_local_notify(app, "sink", "notify-payload")
    stopifnot(identical(notify_seen$value, "notify-payload"))

    # DataHandle round-trip.
    hnd <- lf_data_create("dummy")
    stopifnot(identical(lf_data_get_size(hnd), 0L))
    n <- lf_data_write(hnd, as.raw(c(0x0A, 0x0B, 0x0C)))
    stopifnot(identical(n, 3L))
    stopifnot(identical(lf_data_get_size(hnd), 3L))
    lf_data_set_pos(hnd, 0)
    back <- lf_data_read(hnd, 3L)
    stopifnot(identical(back, as.raw(c(0x0A, 0x0B, 0x0C))))
    lf_data_free(hnd)

    # Clean shutdown.
    lf_free_app(app)
    lf_cleanup(NULL)

    message("tests/smoke.R: all checks passed")
}