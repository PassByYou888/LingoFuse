# =============================================================================
# abi_test.R
# -----------------------------------------------------------------------------
# STEP 2 test: real LingoFuse C ABI round-trip.
#
# Verifies that the bridge can:
#   1. Load the LingoFuse runtime from an explicit directory.
#   2. Create / write / read / free a DataHandle.
#   3. Create / free an AppHandle, and query its name.
#   4. Handle error paths (missing runtime, use-after-free).
#
# This script does NOT call LF_PrepareDone, does NOT involve the network,
# and does NOT register any API. Those start in STEP 3.
#
# Usage:
#   Rscript c_ext/tests/abi_test.R [runtime_dir]
#
# The runtime directory is resolved by lf_find_runtime(), which consults
# (in order): the first command-line argument, the LINGOFUSE_RUNTIME
# environment variable, the "lingofuse.runtime" R option, and a list of
# relative probes under the script directory and the current working
# directory. No absolute path is hard-coded.
#
# All output and comments are English.
# =============================================================================

# -----------------------------------------------------------------------------
# Locate the bridge library
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
        candidate <- file.path(d, paste0("lfR_bridge", ext))
        if (file.exists(candidate)) {
            bridge_path <- normalizePath(candidate)
            break
        }
    }
    if (!is.null(bridge_path)) break
}

if (is.null(bridge_path)) {
    message("[FAIL] Bridge library not found. Build it first with build.ps1.")
    quit(status = 1)
}
message("[OK]   Bridge library: ", bridge_path)

# -----------------------------------------------------------------------------
# Locate the LingoFuse runtime
# -----------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
explicit_runtime <- if (length(args) >= 1) args[1] else NULL
runtime_dir <- lf_find_runtime(explicit_runtime, script_dir)

if (is.null(runtime_dir)) {
    message("[FAIL] Could not locate the LingoFuse runtime directory.")
    message("       Provide it as the first argument, set the")
    message("       LINGOFUSE_RUNTIME environment variable, or place it")
    message("       in Binary/ relative to this repository.")
    quit(status = 1)
}
message("[INFO] Runtime directory: ", runtime_dir)

# -----------------------------------------------------------------------------
# Load the bridge
# -----------------------------------------------------------------------------
dyn.load(bridge_path)
message("[OK]   dyn.load succeeded")

# -----------------------------------------------------------------------------
# Test harness
# -----------------------------------------------------------------------------
pass_count <- 0L
fail_count <- 0L

check <- function(label, condition, detail = NULL) {
    if (isTRUE(condition)) {
        message("[OK]   ", label)
        pass_count <<- pass_count + 1L
    } else {
        message("[FAIL] ", label)
        if (!is.null(detail)) message("       ", detail)
        fail_count <<- fail_count + 1L
    }
}

expect_error <- function(label, expr) {
    err <- tryCatch({ force(expr); NULL },
                    error = function(e) conditionMessage(e))
    if (is.null(err)) {
        message("[FAIL] ", label, " (no error raised)")
        fail_count <<- fail_count + 1L
    } else {
        message("[OK]   ", label)
        message("       error: ", err)
        pass_count <<- pass_count + 1L
    }
}

# -----------------------------------------------------------------------------
# Load the runtime
# -----------------------------------------------------------------------------
loaded_path <- tryCatch(
    .Call("lf_load_library", runtime_dir),
    error = function(e) {
        message("[FAIL] lf_load_library failed: ", conditionMessage(e))
        message("       last_error: ",
                tryCatch(.Call("lf_last_error"), error = function(e2) "(unavailable)"))
        quit(status = 1)
    }
)
message("[OK]   Runtime loaded: ", loaded_path)

check("lf_is_loaded returns TRUE", isTRUE(.Call("lf_is_loaded")))
check("lf_loaded_path matches", identical(.Call("lf_loaded_path"), loaded_path))

# -----------------------------------------------------------------------------
# DataHandle round-trip
# -----------------------------------------------------------------------------
hnd <- .Call("lf_data_create", "test_api")
check("lf_data_create returns externalptr", inherits(hnd, "externalptr"))

check("fresh handle has size 0",
      identical(as.integer(.Call("lf_data_get_size", hnd)), 0L))
check("fresh handle has pos 0",
      identical(as.integer(.Call("lf_data_get_pos", hnd)), 0L))

payload <- as.raw(c(0x01, 0x02, 0x03, 0x04, 0x05))
written <- .Call("lf_data_write_buffer", hnd, payload)
check("write_buffer reports 5 bytes", identical(as.integer(written), 5L))
check("size is now 5",
      identical(as.integer(.Call("lf_data_get_size", hnd)), 5L))
check("pos is now 5",
      identical(as.integer(.Call("lf_data_get_pos", hnd)), 5L))

.Call("lf_data_set_pos", hnd, 0L)
check("set_pos(0) succeeded",
      identical(as.integer(.Call("lf_data_get_pos", hnd)), 0L))

readback <- .Call("lf_data_read_buffer", hnd, 5L)
check("read_buffer returns 5 bytes", length(readback) == 5L)
check("readback bytes match", identical(readback, payload))

# Read past the end: should return 0 bytes (short read shrinks result).
.Call("lf_data_set_pos", hnd, 5L)
empty <- .Call("lf_data_read_buffer", hnd, 4L)
check("read past end returns 0 bytes", length(empty) == 0L)

# Free the handle. Idempotent.
.Call("lf_data_free", hnd)
.Call("lf_data_free", hnd)
message("[OK]   lf_data_free is idempotent")

expect_error("use-after-free raises an error",
             .Call("lf_data_get_size", hnd))

# -----------------------------------------------------------------------------
# Permanent handle
# -----------------------------------------------------------------------------
hnd_perm <- .Call("lf_data_create_permanent", "perm_api")
check("permanent handle created", inherits(hnd_perm, "externalptr"))
.Call("lf_data_free", hnd_perm)
message("[OK]   permanent handle freed")

# -----------------------------------------------------------------------------
# AppHandle
# -----------------------------------------------------------------------------
app <- .Call("lf_app_create", "AbiTestApp", "STEP 2 ABI test")
check("app handle created", inherits(app, "externalptr"))

# lf_app_name copies the string immediately inside the C shim.
app_name <- tryCatch(
    .Call("lf_app_name", app),
    error = function(e) {
        message("[WARN] lf_app_name raised: ", conditionMessage(e))
        NULL
    }
)
check("app name matches",
      identical(app_name, "AbiTestApp"),
      if (is.null(app_name)) "call returned NULL" else paste("got:", app_name))

.Call("lf_app_free", app)
.Call("lf_app_free", app)
message("[OK]   lf_app_free is idempotent")

expect_error("app use-after-free raises an error",
             .Call("lf_app_name", app))

# -----------------------------------------------------------------------------
# Shutdown
# -----------------------------------------------------------------------------
# LingoFuse starts background threads the moment it is loaded, even if
# LF_PrepareDone is never called. Those threads must be stopped before
# the R process exits, otherwise the operating system's DLL-unload path
# at process exit races with the still-running threads and the process
# terminates with an access violation (exit code 0xC0000005 on Windows).
#
# lf_exit_main_thread is safe to call even when LF_PrepareDone was
# never invoked: it is a no-op if the simulated main thread is not
# running. lf_shutdown is idempotent and releases all remaining library
# resources.
tryCatch(.Call("lf_exit_main_thread"), error = function(e) NULL)
tryCatch(.Call("lf_shutdown"),          error = function(e) NULL)

# The runtime DLL itself is intentionally left mapped until process
# exit. lf_unload_library only clears the bridge's function-pointer
# table (so lf_is_loaded() reports FALSE); the loader pinned the
# runtime at load() time, so Windows will never unmap LingoFuse64.dll
# during the process lifetime.
.Call("lf_unload_library")
check("lf_is_loaded returns FALSE after unload",
      isFALSE(.Call("lf_is_loaded")))

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
# Deliberately no dyn.unload(bridge_path) here. Unloading the bridge DLL
# would cascade into the OS attempting to unmap LingoFuse64.dll while
# its background threads may still be running. The bridge DLL and the
# runtime DLL are both left mapped until process exit, which is the
# only safe release point.
message("")
message(strrep("=", 60))
message("ABI test summary")
message(strrep("=", 60))
message("  Passed : ", pass_count)
message("  Failed : ", fail_count)
message(strrep("=", 60))

if (fail_count > 0L) {
    quit(status = 1)
} else {
    message("")
    message("STEP 2 ABI layer verified. The bridge can now speak to the")
    message("real LingoFuse runtime.")
    message("Next: STEP 3 will add JSON / string I/O and the full API.")
    quit(status = 0)
}