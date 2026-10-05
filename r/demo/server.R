# =============================================================================
# server.R
# -----------------------------------------------------------------------------
# Minimal LingoFuse R service. Run this in one terminal, then run
# client.R in another.
#
# Usage:
#   Rscript demo/server.R [runtime_dir] [wait_sec]
# =============================================================================

runtime_dir <- if (length(commandArgs(TRUE)) >= 1) {
    commandArgs(TRUE)[1]
} else {
    "D:/CoreLibrary/LingoFuse/Binary"
}
wait_sec <- if (length(commandArgs(TRUE)) >= 2) {
    as.integer(commandArgs(TRUE)[2])
} else {
    60L
}

Sys.setenv(LINGOFUSE_RUNTIME = runtime_dir)
suppressPackageStartupMessages(library(lingofuse))
suppressPackageStartupMessages(library(jsonlite))

app <- lf_create_app("CalcR", "R calculator demo")

lf_register_call(app, "add", "add two integers", function(input) {
    req <- fromJSON(input)
    toJSON(list(result = req$a + req$b), auto_unbox = TRUE)
})

lf_prepare_service("ipc:r_calc", "ipc:r_calc")
lf_prepare_client("ipc:r_calc", app)
stopifnot(lf_prepare_done() == 1L)

cat("[server] online: CalcR @ ipc:r_calc\n")
cat("[server] pumping for up to ", wait_sec, " seconds. Ctrl+C to stop.\n")

tryCatch({
    start <- Sys.time()
    while (as.numeric(Sys.time() - start, units = "secs") < wait_sec) {
        lf_poll(100)
    }
}, interrupt = function(e) NULL)

cat("[server] shutting down\n")
lf_cleanup(app)