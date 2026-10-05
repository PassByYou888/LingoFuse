# =============================================================================
# zzz.R
# -----------------------------------------------------------------------------
# Package load / unload hooks.
#
# Design decision:
#
#   * .onLoad() is the place where the runtime is actually loaded, but
#     it is SILENT. R's "Writing R Extensions" manual (see ?.onAttach
#     and the "Good practice" section) explicitly asks package authors
#     not to emit startup messages from .onLoad(): at that point the
#     user has not yet attached the package, and messages written here
#     are lost in the noise of the package loading chain.
#
#   * .onAttach() is the place where user-facing messages belong. It
#     reads the outcome recorded by .onLoad() from .lf_state and emits
#     a single packageStartupMessage.
#
#   * Both functions are silent when no runtime is configured. There
#     is no "call lf_load(dir)" reminder, because that reminder would
#     fire on every roxygenise(), pkgload::load_all() and devtools
#     call, turning the message into noise rather than help.
# =============================================================================

.onLoad <- function(libname, pkgname) {
    # Reset the per-session load status. NULL means "no message".
    .lf_state$load_status <- NULL

    # ------------------------------------------------------------------
    # Guard: during roxygen2 / pkgload dev-time loading, the package's
    # own DLL may not yet be registered when .onLoad runs. Detect that
    # and skip the auto-load attempt.
    # ------------------------------------------------------------------
    if (!is.loaded("lf_load_library")) {
        return(invisible())
    }

    # ------------------------------------------------------------------
    # Auto-load the runtime only when the user has configured a
    # location. Two sources are consulted, in order:
    #
    #   1. The LINGOFUSE_RUNTIME environment variable.
    #   2. The "lingofuse.runtime" R option.
    #
    # No configuration => no message, no auto-load. The user calls
    # lf_load(dir) explicitly when ready.
    # ------------------------------------------------------------------
    runtime <- Sys.getenv("LINGOFUSE_RUNTIME", unset = "")
    if (!nzchar(runtime)) {
        runtime <- getOption("lingofuse.runtime", default = "")
    }
    if (!nzchar(runtime)) {
        return(invisible())
    }

    if (!dir.exists(runtime)) {
        .lf_state$load_status <- list(
            kind    = "missing",
            runtime = runtime
        )
        return(invisible())
    }

    ok <- tryCatch({
        .Call("lf_load_library", runtime)
        TRUE
    }, error = function(e) {
        .lf_state$load_status <- list(
            kind    = "failed",
            runtime = runtime,
            error   = conditionMessage(e)
        )
        FALSE
    })

    if (ok) {
        .lf_state$load_status <- list(
            kind    = "loaded",
            runtime = runtime
        )
    }

    invisible()
}

.onAttach <- function(libname, pkgname) {
    status <- .lf_state$load_status
    if (is.null(status)) {
        return(invisible())
    }

    if (identical(status$kind, "loaded")) {
        packageStartupMessage("lingofuse: runtime loaded from ",
                              status$runtime)
    } else if (identical(status$kind, "missing")) {
        packageStartupMessage(
            "lingofuse: configured runtime directory does not exist: ",
            status$runtime)
    } else if (identical(status$kind, "failed")) {
        packageStartupMessage(
            "lingofuse: failed to load LingoFuse runtime from '",
            status$runtime, "': ", status$error)
    }

    invisible()
}

.onUnload <- function(libpath) {
    # ------------------------------------------------------------------
    # SAFETY: if LingoFuse was ever started (i.e. lf_prepare_done
    # returned 1), unloading the bridge DLL here would be a use-after-
    # free. LF_Shutdown is asynchronous: C4 worker threads may still be
    # executing inside the DLL when it returns. Freeing the DLL at that
    # point removes the code from the address space while a thread is
    # still running inside it, producing an access violation.
    #
    # When the main thread has never been started, there are no such
    # threads and the DLL can be safely unloaded.
    # ------------------------------------------------------------------
    ever_started <- isTRUE(.lf_state$main_thread_started)

    if (ever_started) {
        tryCatch(.Call("lf_exit_main_thread"), error = function(e) NULL)
        tryCatch(.Call("lf_shutdown"), error = function(e) NULL)
        packageStartupMessage(
            "lingofuse: LF was running. The bridge DLL is left loaded; ",
            "the OS will reclaim it at process exit.")
        return(invisible())
    }

    library.dynam.unload("lingofuse", libpath)
}