# =============================================================================
# smoke_test.R
# -----------------------------------------------------------------------------
# STEP 1 smoke test for the LingoFuse R bridge.
#
# Verifies that:
#   1. The shared library built by R CMD SHLIB can be loaded by R.
#   2. The .Call registration table is reachable.
#   3. Scalar arguments round-trip correctly across the R <-> C++ boundary.
#   4. Named lists can be constructed in C++ and consumed in R.
#
# Does NOT touch the real LingoFuse runtime. That starts in STEP 2.
#
# Usage:
#   Rscript c_ext/tests/smoke_test.R
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

candidate_dirs <- c(
    file.path(script_dir, "..", "..", "libs"),
    file.path(script_dir, "..", "libs"),
    file.path(getwd(), "libs"),
    file.path(getwd(), "..", "libs")
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
    message("[FAIL] Could not locate the bridge library.")
    message("       Looked in:")
    for (d in candidate_dirs) message("         ", d)
    message("       Build it first with build.ps1.")
    quit(status = 1)
}

message("[OK]   Bridge library found: ", bridge_path)

loaded_ok <- FALSE
tryCatch({
    dyn.load(bridge_path)
    loaded_ok <- TRUE
}, error = function(e) {
    message("[FAIL] dyn.load failed: ", conditionMessage(e))
})

if (!loaded_ok) quit(status = 1)
message("[OK]   dyn.load succeeded")

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

# --- Test 1: lf_ping ---------------------------------------------------------
result <- tryCatch(.Call("lf_ping"), error = function(e) NULL)
check("lf_ping returns a character vector",
      is.character(result) && length(result) == 1L,
      if (is.null(result)) "call raised an error" else paste("got:", class(result)))
check("lf_ping returns \"pong\"",
      identical(result, "pong"),
      if (is.null(result)) "no value" else paste("got:", result))

# --- Test 2: lf_echo with strings -------------------------------------------
result <- tryCatch(.Call("lf_echo", "hello"), error = function(e) NULL)
check("lf_echo round-trips a string",
      identical(result, "hello"),
      if (is.null(result)) "no value" else paste("got:", result))

# --- Test 3: lf_echo with integers ------------------------------------------
result <- tryCatch(.Call("lf_echo", 42L), error = function(e) NULL)
check("lf_echo round-trips an integer",
      identical(result, 42L),
      if (is.null(result)) "no value" else paste("got:", result))

# --- Test 4: lf_echo with doubles -------------------------------------------
result <- tryCatch(.Call("lf_echo", 3.14159), error = function(e) NULL)
check("lf_echo round-trips a double",
      isTRUE(all.equal(result, 3.14159)),
      if (is.null(result)) "no value" else paste("got:", result))

# --- Test 5: lf_info returns a named list -----------------------------------
# The exact version / stage strings change between bridge revisions, so
# the assertions check only that the fields are non-empty character
# scalars. This keeps the smoke test stable across revisions.
info <- tryCatch(.Call("lf_info"), error = function(e) NULL)
check("lf_info returns a list",
      is.list(info),
      if (is.null(info)) "no value" else paste("got:", class(info)))
check("lf_info list has a non-empty version field",
      is.list(info) && is.character(info$version) &&
          length(info$version) == 1L && nzchar(info$version),
      if (is.list(info)) paste("version =", info$version) else "not a list")
check("lf_info list has a non-empty stage field",
      is.list(info) && is.character(info$stage) &&
          length(info$stage) == 1L && nzchar(info$stage),
      if (is.list(info)) paste("stage =", info$stage) else "not a list")
check("lf_info list has a compiled field",
      is.list(info) && is.character(info$compiled),
      if (is.list(info)) paste("compiled =", info$compiled) else "not a list")

tryCatch(dyn.unload(bridge_path), error = function(e) {
    message("[WARN] dyn.unload failed: ", conditionMessage(e))
})

message("")
message(strrep("=", 60))
message("Smoke test summary")
message(strrep("=", 60))
message("  Passed : ", pass_count)
message("  Failed : ", fail_count)
message(strrep("=", 60))

if (fail_count > 0L) {
    quit(status = 1)
} else {
    message("")
    message("STEP 1 build chain verified. The R <-> C++ pipeline is ready.")
    quit(status = 0)
}