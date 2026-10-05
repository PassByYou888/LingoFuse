# =============================================================================
# client.R
# -----------------------------------------------------------------------------
# Minimal LingoFuse R client. Run this AFTER server.R is online.
#
# Usage:
#   Rscript demo/client.R [runtime_dir]
#
# Runtime directory resolution (self-contained; no external file, no
# hard-coded absolute path):
#   1. First command-line argument.
#   2. LINGOFUSE_RUNTIME environment variable.
#   3. "lingofuse.runtime" R option.
#   4. Relative probes under the script directory and the CWD.
#
# See the comment block in server.R for the rationale behind inlining
# the resolver: the demo is deliberately self-contained so that it
# does not depend on any package-level export.
# =============================================================================

# -----------------------------------------------------------------------------
# Self-contained runtime directory resolver
# -----------------------------------------------------------------------------
lf_resolve_runtime_dir <- function(explicit = NULL, script_dir = NULL) {
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
        return(check_dir(explicit))
    }

    env_val <- Sys.getenv("LINGOFUSE_RUNTIME", unset = "")
    if (nzchar(env_val)) {
        r <- check_dir(env_val)
        if (!is.null(r)) return(r)
    }

    opt_val <- getOption("lingofuse.runtime", default = "")
    if (is.character(opt_val) && length(opt_val) == 1L && nzchar(opt_val)) {
        r <- check_dir(opt_val)
        if (!is.null(r)) return(r)
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
            r <- check_dir(file.path(base, rel))
            if (!is.null(r)) return(r)
        }
    }

    NULL
}

# -----------------------------------------------------------------------------
# Locate the calling script's directory
# -----------------------------------------------------------------------------
script_dir <- tryCatch({
    file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE),
                     value = TRUE)
    if (length(file_arg) > 0) {
        dirname(normalizePath(sub("^--file=", "", file_arg[1])))
    } else {
        getwd()
    }
}, error = function(e) getwd())

# -----------------------------------------------------------------------------
# Parse command-line arguments
# -----------------------------------------------------------------------------
cli_args <- commandArgs(trailingOnly = TRUE)

explicit_runtime <- if (length(cli_args) >= 1) cli_args[1] else NULL
runtime_dir <- lf_resolve_runtime_dir(explicit_runtime, script_dir)
if (is.null(runtime_dir)) {
    message("[FAIL] Could not locate the LingoFuse runtime directory.")
    message("       Provide it as the first argument, set the")
    message("       LINGOFUSE_RUNTIME environment variable, or place it")
    message("       in Binary/ relative to this repository.")
    quit(status = 1)
}

Sys.setenv(LINGOFUSE_RUNTIME = runtime_dir)
message("[OK]   Runtime dir: ", runtime_dir)

# -----------------------------------------------------------------------------
# Load the package
# -----------------------------------------------------------------------------
suppressPackageStartupMessages(library(lingofuse))
suppressPackageStartupMessages(library(jsonlite))

# -----------------------------------------------------------------------------
# Pure consumer: no app attached
# -----------------------------------------------------------------------------
lf_prepare_client("ipc:r_calc", NULL)
stopifnot(lf_prepare_done() == 1L)

# Wait for the server's app to become visible (broadcast delay ~3 s).
cat("[client] waiting for CalcR...\n")
for (i in 1:50) {
    if (lf_check_api("CalcR", "add")) break
    Sys.sleep(0.2)
}
stopifnot(lf_check_api("CalcR", "add"))

cat("[client] calling add(3,4)...\n")
res <- lf_call("CalcR", "add",
               toJSON(list(a = 3L, b = 4L), auto_unbox = TRUE),
               timeout_ms = 5000)
cat("[client] response:", res, "\n")

lf_cleanup(NULL)