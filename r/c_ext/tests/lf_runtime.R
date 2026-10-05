# =============================================================================
# lf_runtime.R
# -----------------------------------------------------------------------------
# Runtime directory resolution for LingoFuse R scripts.
#
# This helper is shared by every standalone R script under c_ext/tests/.
# It locates the LingoFuse runtime directory (the directory that holds
# LingoFuse64.dll / LingoFuse32.dll / liblingofuse.so / liblingofuse.dylib
# together with their dependencies) without relying on any hard-coded
# absolute path.
#
# Resolution order:
#
#   1. An explicit path supplied by the caller (typically the first
#      command-line argument).
#   2. The LINGOFUSE_RUNTIME environment variable.
#   3. The "lingofuse.runtime" R option.
#   4. A list of relative probes under the calling script's directory
#      and the current working directory.
#
# The function returns a normalized path on success, or NULL on failure.
# A caller that receives NULL is expected to print a clear diagnostic
# and exit with a non-zero status.
#
# Why relative probes
# -------------------
# The repository layout is fixed:
#
#   <repo>/Binary/                 (the runtime DLLs)
#   <repo>/c_ext/tests/            (this script and the other tests)
#   <repo>/demo/                   (two-process demo)
#   <repo>/lingofuse/              (the R package source)
#
# A script under c_ext/tests/ therefore finds the runtime at
# "../../Binary". A script under demo/ finds it at "../Binary". A
# script launched from the repository root finds it at "./Binary". The
# probe list covers all of these cases and a few conventional
# alternatives ("runtime", "lib") without ever hard-coding an absolute
# path.
#
# All output is English.
# =============================================================================

lf_find_runtime <- function(explicit = NULL, script_dir = NULL) {

    # Internal helper: normalize a candidate directory, or return NULL
    # when the candidate is not a string or does not exist.
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
    #
    # When the caller supplied a path, honour it strictly: either the
    # path exists (and is used) or the function returns NULL without
    # falling through to the other sources. Silent fallback on a
    # mistyped CLI argument would resolve to a different directory
    # than the operator expected, which is worse than a clear failure.
    if (!is.null(explicit) && nzchar(explicit)) {
        resolved <- check_dir(explicit)
        if (!is.null(resolved)) {
            return(resolved)
        }
        message("[INFO] Explicit runtime directory does not exist: ",
                explicit)
        return(NULL)
    }

    # ---- 2. LINGOFUSE_RUNTIME environment variable ---------------------
    env_val <- Sys.getenv("LINGOFUSE_RUNTIME", unset = "")
    if (nzchar(env_val)) {
        resolved <- check_dir(env_val)
        if (!is.null(resolved)) {
            return(resolved)
        }
        message("[INFO] LINGOFUSE_RUNTIME points to a non-existent path: ",
                env_val)
    }

    # ---- 3. "lingofuse.runtime" R option -------------------------------
    opt_val <- getOption("lingofuse.runtime", default = "")
    if (is.character(opt_val) && length(opt_val) == 1L && nzchar(opt_val)) {
        resolved <- check_dir(opt_val)
        if (!is.null(resolved)) {
            return(resolved)
        }
        message("[INFO] getOption('lingofuse.runtime') points to a ",
                "non-existent path: ", opt_val)
    }

    # ---- 4. Relative probes --------------------------------------------
    #
    # Base directories: the calling script's directory (when known) and
    # the current working directory. The script directory is tried
    # first because it is stable across launch locations.
    bases <- character(0)
    if (!is.null(script_dir) && nzchar(script_dir)) {
        bases <- c(bases, script_dir)
    }
    bases <- c(bases, getwd())

    # Relative subpaths under each base. Ordered from the most likely
    # location to the least likely one. The list is deliberately short:
    # only layouts that a normal checkout would produce are probed.
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