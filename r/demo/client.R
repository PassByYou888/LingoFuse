# =============================================================================
# client.R
# -----------------------------------------------------------------------------
# Minimal LingoFuse R client. Run this AFTER server.R is online.
#
# Usage:
#   Rscript demo/client.R [runtime_dir]
# =============================================================================

runtime_dir <- if (length(commandArgs(TRUE)) >= 1) {
    commandArgs(TRUE)[1]
} else {
    "D:/CoreLibrary/LingoFuse/Binary"
}

Sys.setenv(LINGOFUSE_RUNTIME = runtime_dir)
suppressPackageStartupMessages(library(lingofuse))
suppressPackageStartupMessages(library(jsonlite))

# Pure consumer: no app attached.
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