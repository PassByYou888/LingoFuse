# =============================================================================
# async_test.R
# -----------------------------------------------------------------------------
# Unit test for the modern asynchronous layer (lingofuse/R/async.R and
# the async-related pieces of lingofuse/R/api.R).
#
# Design
# ------
# True end-to-end asynchronous behaviour requires a running peer in
# another process. That scenario lives in the two-process test suite
# (uid_p2p_test.R). This file focuses on the R-side state machine,
# which is fully testable in a single process:
#
#   Group 1  Bridge and runtime load
#   Group 2  Task object creation and immediate-state queries
#   Group 3  Handler chain (then / catch / finally) with manual resolve
#   Group 4  Handler chain with manual reject
#   Group 5  Handler registration after completion (immediate fire)
#   Group 6  Dispatch failure path (invalid App name)
#   Group 7  Slot table lifecycle (add / release / count)
#   Group 8  Timeout path (reaper fires on a synthetic slot)
#   Group 9  lf_task_await on a synthetic task
#   Group 10 Shutdown
#
# The synthetic-slot tests (Groups 3, 4, 5, 8, 9) bypass the C side
# entirely: they create a task, inject the appropriate handler into
# .lf_state$async_slots, and call the internal .lf_task_resolve /
# .lf_task_reject functions directly. This is exactly the path the
# pump loop uses, so the behaviour observed is the behaviour the user
# sees.
#
# Usage:
#   Rscript c_ext/tests/async_test.R [runtime_dir]
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
    message("[FAIL] Bridge library not found. Build it first with build.ps1.")
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
# Load the bridge
# -----------------------------------------------------------------------------
message("")
message("=== Group 1. Bridge and runtime load ===")
dyn.load(bridge_path)
loaded_path <- .Call("lf_load_library", runtime_dir)
check("lf_load_library succeeds",
      is.character(loaded_path) && nzchar(loaded_path))
check("lf_is_loaded returns TRUE", isTRUE(.Call("lf_is_loaded")))

# -----------------------------------------------------------------------------
# Source the package R files directly
# -----------------------------------------------------------------------------
# The standalone bridge is loaded directly, so the lingofuse package
# does not have to be installed for this test to run. We source the
# two files that define the async layer. api.R depends on options.R
# only for the typed option accessors, which are not exercised here;
# it is safe to source api.R alone.
api.path     <- file.path(script_dir, "..", "..", "lingofuse", "R", "api.R")
async.path   <- file.path(script_dir, "..", "..", "lingofuse", "R", "async.R")
options.path <- file.path(script_dir, "..", "..", "lingofuse", "R", "options.R")

for (p in c(api.path, options.path, async.path)) {
    if (!file.exists(p)) {
        message("[FAIL] missing R source: ", p)
        quit(status = 1)
    }
}

# api.R declares @useDynLib via roxygen, but sourcing it directly does
# not run roxygen. We supply a no-op shim so that the source() call
# succeeds. The actual .Call symbols are provided by dyn.load above.
# The `@useDynLib` line lives in a roxygen comment block, not in code,
# so nothing needs to be shimmed here. We just source in the right
# order.
source(options.path, local = TRUE)
source(api.path, local = TRUE)
source(async.path, local = TRUE)
message("[OK]   options.R / api.R / async.R sourced")

# The sourced api.R expects its state environment to exist. It
# creates .lf_state on load, and async.R uses it. Both are now in
# the global environment after source().

# -----------------------------------------------------------------------------
# Group 2 - Task object creation and immediate-state queries
# -----------------------------------------------------------------------------
message("")
message("=== Group 2. Task object creation and immediate-state queries ===")

# A task is created by the internal helper, not by the public
# entry points, so that no C-side request is issued. This isolates
# the R-side state machine.
t <- .lf_new_task(id = 1, api_name = "echo", target = "TestApp",
                  timeout_ms = 5000)

check("task is a LingoFuseTask",
      inherits(t, "LingoFuseTask"))
check("task is an environment",
      is.environment(t))
check("initial state is 'pending'",
      identical(lf_task_state(t), "pending"))
check("lf_task_error returns NULL while pending",
      is.null(lf_task_error(t)))

# lf_task_result must raise while the task is pending.
err <- tryCatch({ lf_task_result(t); NULL },
                error = function(e) conditionMessage(e))
check("lf_task_result raises while pending",
      !is.null(err))

# print() must not error.
out <- capture.output(print(t))
check("print.LingoFuseTask produces output",
      length(out) > 0L && any(grepl("LingoFuseTask", out)))

# -----------------------------------------------------------------------------
# Group 3 - Handler chain with manual resolve
# -----------------------------------------------------------------------------
message("")
message("=== Group 3. Handler chain with manual resolve ===")

t <- .lf_new_task(id = 2, api_name = "add", target = "TestApp",
                  timeout_ms = 5000)
fired_then <- 0L
fired_finally <- 0L
last_result <- NULL

lf_task_then(t, function(r, tt) {
    fired_then <<- fired_then + 1L
    last_result <<- r
})
lf_task_finally(t, function(tt) {
    fired_finally <<- fired_finally + 1L
})

check("then handler registered, not yet fired",
      identical(fired_then, 0L))

# Simulate the pump loop resolving the task.
.lf_task_resolve(t, "the_result")

check("state is 'done' after resolve",
      identical(lf_task_state(t), "done"))
check("then handler fired exactly once",
      identical(fired_then, 1L))
check("finally handler fired exactly once",
      identical(fired_finally, 1L))
check("then handler received the result",
      identical(last_result, "the_result"))
check("lf_task_result returns the result",
      identical(lf_task_result(t), "the_result"))

# Second resolve must be a no-op.
fired_then_before <- fired_then
.lf_task_resolve(t, "second_result")
check("second resolve is a no-op",
      identical(fired_then, fired_then_before))

# -----------------------------------------------------------------------------
# Group 4 - Handler chain with manual reject
# -----------------------------------------------------------------------------
message("")
message("=== Group 4. Handler chain with manual reject ===")

t <- .lf_new_task(id = 3, api_name = "fail", target = "TestApp",
                  timeout_ms = 5000)
fired_catch <- 0L
fired_finally <- 0L
last_err <- NULL
last_kind <- NULL

lf_task_catch(t, function(e, k, tt) {
    fired_catch <<- fired_catch + 1L
    last_err <<- e
    last_kind <<- k
})
lf_task_finally(t, function(tt) {
    fired_finally <<- fired_finally + 1L
})

.lf_task_reject(t, "something broke", 1L)

check("state is 'error' after reject",
      identical(lf_task_state(t), "error"))
check("catch handler fired exactly once",
      identical(fired_catch, 1L))
check("finally handler fired exactly once",
      identical(fired_finally, 1L))
check("catch handler received the message",
      identical(last_err, "something broke"))
check("catch handler received error_kind",
      identical(last_kind, 1L))
check("lf_task_error returns the message",
      identical(lf_task_error(t), "something broke"))

err <- tryCatch({ lf_task_result(t); NULL },
                error = function(e) conditionMessage(e))
check("lf_task_result raises on a failed task",
      !is.null(err) && grepl("something broke", err))

# -----------------------------------------------------------------------------
# Group 5 - Handler registration after completion
# -----------------------------------------------------------------------------
message("")
message("=== Group 5. Handler registration after completion ===")

t <- .lf_new_task(id = 4, api_name = "add", target = "TestApp",
                  timeout_ms = 5000)
.lf_task_resolve(t, "late_result")

fired_late <- 0L
lf_task_then(t, function(r, tt) {
    fired_late <<- fired_late + 1L
})
check("then handler registered after completion fires immediately",
      identical(fired_late, 1L))

t2 <- .lf_new_task(id = 5, api_name = "fail", target = "TestApp",
                   timeout_ms = 5000)
.lf_task_reject(t2, "late_error", 1L)
fired_catch_late <- 0L
lf_task_catch(t2, function(e, k, tt) {
    fired_catch_late <<- fired_catch_late + 1L
})
check("catch handler registered after failure fires immediately",
      identical(fired_catch_late, 1L))

# -----------------------------------------------------------------------------
# Group 6 - Dispatch failure path
# -----------------------------------------------------------------------------
message("")
message("=== Group 6. Dispatch failure path ===")

# Call lf_async_call with an App name that was never registered.
# The result is one of:
#   (a) id == 0 : dispatch rejected outright. on_error must fire
#                 synchronously with error_kind == 0.
#   (b) id > 0  : dispatch accepted; the request will hang until the
#                 R-side timeout (we use a short one), at which point
#                 on_error fires with error_kind == 1.
# Both are acceptable; the test accepts either.

err_called <- FALSE
err_msg <- NULL
err_kind <- NULL

lf_async_call("__no_such_app_async_test__", "no_op", "{}",
              on_success = function(r, ud) {
                  message("       (unexpected success: ", r, ")")
              },
              on_error = function(e, k, ud) {
                  err_called <<- TRUE
                  err_msg    <<- e
                  err_kind   <<- k
              },
              timeout_ms = 300)

# If dispatch was rejected, on_error already fired. If not, pump
# briefly so that the reaper can fire.
for (i in 1:20) {
    lf_poll(50)
    if (err_called) break
}

check("on_error fired for an unreachable target",
      err_called,
      "neither immediate nor timeout error was delivered")
if (err_called) {
    message("       error message: ", err_msg)
    message("       error kind   : ", err_kind)
    check("error_kind is 0 (dispatch fail) or 1 (timeout)",
          err_kind %in% c(0L, 1L))
}

# -----------------------------------------------------------------------------
# Group 7 - Slot table lifecycle
# -----------------------------------------------------------------------------
message("")
message("=== Group 7. Slot table lifecycle ===")

before <- lf_async_slot_count()
check("async slot count is a number", is.numeric(before))

# Register a synthetic slot and confirm the count grows.
t <- .lf_new_task(id = 7777, api_name = "synthetic", target = "x",
                  timeout_ms = 60000)
.lf_state$async_slots[["7777"]] <- list(
    id         = 7777,
    on_success = function(r, ud) NULL,
    on_error   = function(e, k, ud) NULL,
    user_data  = NULL,
    deadline   = Sys.time() + 60
)

# The slot count reported by the C side is independent of the R-side
# table, so we do not assert equality with .lf_state. We only test
# the R-side table itself.
check("R-side slot table grew",
      "7777" %in% names(.lf_state$async_slots))

# Release the C-side slot (id 7777 was never registered on the C
# side, so the call is a harmless no-op there) and remove the
# R-side entry.
.Call("lf_async_release", 7777)
.lf_state$async_slots[["7777"]] <- NULL
check("R-side slot table shrank",
      !("7777" %in% names(.lf_state$async_slots)))

# -----------------------------------------------------------------------------
# Group 8 - Timeout path (synthetic slot)
# -----------------------------------------------------------------------------
message("")
message("=== Group 8. Timeout path (synthetic slot) ===")

# Create a task with a very short deadline and inject it into the
# slot table. The reaper in lf_poll must then fire its on_error with
# error_kind == 1.

t <- .lf_new_task(id = 8888, api_name = "synthetic", target = "x",
                  timeout_ms = 50)
reaped <- FALSE
reaped_kind <- NULL
reaped_msg <- NULL

.lf_state$async_slots[["8888"]] <- list(
    id         = 8888,
    on_success = function(r, ud) .lf_task_resolve(t, r),
    on_error   = function(e, k, ud) {
        reaped      <<- TRUE
        reaped_kind <<- k
        reaped_msg  <<- e
        .lf_task_reject(t, e, k)
    },
    user_data  = NULL,
    deadline   = .lf_task_deadline(50)
)

# Sleep long enough that the deadline has certainly passed, then
# pump once.
Sys.sleep(0.15)
lf_poll(0)

check("reaper fired on expired slot", reaped)
if (reaped) {
    check("reaper reported error_kind == 1 (timeout)",
          identical(reaped_kind, 1L))
    check("reaper reported 'timeout' as the message",
          identical(reaped_msg, "timeout"))
    check("task state after reaper is 'error'",
          identical(lf_task_state(t), "error"))
}

check("expired slot removed from table",
      !("8888" %in% names(.lf_state$async_slots)))

# -----------------------------------------------------------------------------
# Group 9 - lf_task_await on a synthetic task
# -----------------------------------------------------------------------------
message("")
message("=== Group 9. lf_task_await on a synthetic task ===")

# A task that resolves itself after a short delay, driven by the pump
# loop inside lf_task_await.
t <- .lf_new_task(id = 9999, api_name = "synthetic", target = "x",
                  timeout_ms = 2000)

# Arm the slot so that lf_poll will resolve it once the deadline
# passes.
.lf_state$async_slots[["9999"]] <- list(
    id         = 9999,
    on_success = function(r, ud) .lf_task_resolve(t, r),
    on_error   = function(e, k, ud) .lf_task_reject(t, e, k),
    user_data  = NULL,
    deadline   = Sys.time() + 60
)

# Schedule a background resolve using the same thread of the await
# loop: we install a small delay then call resolve. The pump inside
# lf_task_await is cooperative, so we cannot spin a separate thread
# here. Instead, we use the R-side scheduler: on.exit in a helper.
deferred_resolve <- function(t, delay_seconds, value) {
    # Busy wait, then resolve. Called from the same thread that will
    # subsequently call lf_task_await; but by then the resolve has
    # already happened.
    start <- Sys.time()
    while (as.numeric(Sys.time() - start, units = "secs") < delay_seconds) {
        lf_poll(10)
    }
    .lf_task_resolve(t, value)
}

# The helper is called BEFORE lf_task_await, so it can use lf_poll to
# keep the pump alive while it waits.
result <- tryCatch({
    deferred_resolve(t, 0.3, "eventually")
    lf_task_await(t, timeout_ms = 2000)
}, error = function(e) {
    message("       lf_task_await raised: ", conditionMessage(e))
    NULL
})

check("lf_task_await returns the resolved value",
      identical(result, "eventually"),
      paste("got:", result))

# Now test the await timeout path. Create a task that never resolves.
t2 <- .lf_new_task(id = 9998, api_name = "synthetic", target = "x",
                   timeout_ms = 0)   # no C-side deadline; rely on await
.lf_state$async_slots[["9998"]] <- list(
    id         = 9998,
    on_success = function(r, ud) .lf_task_resolve(t2, r),
    on_error   = function(e, k, ud) .lf_task_reject(t2, e, k),
    user_data  = NULL,
    deadline   = .lf_task_deadline(0)
)

timed_out <- FALSE
tryCatch({
    lf_task_await(t2, timeout_ms = 300)
}, error = function(e) {
    timed_out <<- TRUE
})
check("lf_task_await raises on its own timeout",
      isTRUE(timed_out))
check("task state after await timeout is 'error'",
      identical(lf_task_state(t2), "error"))

# -----------------------------------------------------------------------------
# Group 10 - Shutdown
# -----------------------------------------------------------------------------
message("")
message("=== Group 10. Shutdown ===")

# Clear every synthetic slot so no closure is leaked into shutdown.
.lf_state$async_slots <- list()

tryCatch(.Call("lf_exit_main_thread"), error = function(e) NULL)
tryCatch(.Call("lf_shutdown"),          error = function(e) NULL)
.Call("lf_unload_library")
check("lf_is_loaded returns FALSE after unload",
      isFALSE(.Call("lf_is_loaded")))

message("")
message(strrep("=", 60))
message("Async test summary")
message(strrep("=", 60))
message("  Passed : ", pass_count)
message("  Failed : ", fail_count)
message(strrep("=", 60))

if (fail_count > 0L) quit(status = 1)
message("")
message("Modern asynchronous layer verified.")
quit(status = 0)