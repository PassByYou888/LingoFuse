# =============================================================================
# cross_node.R
# -----------------------------------------------------------------------------
# STEP 4: R as a LingoFuse CrossDemo worker node.
#
# Wire format (raw little-endian binary, NOT JSON):
#
#   demo.add       int32 a (4 bytes LE)
#                  int32 b (4 bytes LE)
#                  -> int32 (a + b), 4 bytes LE
#
#   demo.inv_seri  uint8  (1 byte)
#                  uint16 (2 bytes LE)
#                  uint32 (4 bytes LE)
#                  uint64 (8 bytes LE)
#                  string (UTF-8, NUL-terminated)
#                  float  (4 bytes LE IEEE 754)
#                  -> same values in reverse order:
#                     float, string, uint64, uint32, uint16, uint8
#
# Usage:
#   Rscript c_ext/tests/cross_node.R [runtime_dir] [wait_sec]
#
#   runtime_dir   Path to the LingoFuse runtime directory. When omitted,
#                 lf_find_runtime() consults the LINGOFUSE_RUNTIME
#                 environment variable, the "lingofuse.runtime" option,
#                 and a list of relative probes under the script
#                 directory and the current working directory.
#   wait_sec      Maximum time to pump the job queue, in seconds.
#                 Default: 60
#
# LF SHUTDOWN CONTRACT
# --------------------
# This script starts a LingoFuse service. It therefore MUST, before
# exiting, run the LF shutdown sequence:
#
#   1. lf_exit_main_thread
#   2. lf_app_free(app)
#   3. lf_shutdown
#
# This is enforced by wrapping the entire test body in a helper
# function whose on.exit() handler runs the cleanup on every exit
# path, including a Ctrl+C interrupt. The bridge DLL is deliberately
# NOT unloaded.
#
# SCOPE NOTE
# ----------
# `app` is a LOCAL variable of run_cross_node(), assigned with `<-`.
# See callee_test.R for the full explanation of why `<<-` would be
# wrong here.
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

source(file.path(script_dir, "lf_runtime.R"))
source(file.path(script_dir, "lf_r_api.R"))

# -----------------------------------------------------------------------------
# Locate bridge and runtime
# -----------------------------------------------------------------------------
candidates <- c(
    file.path(script_dir, "..", "..", "libs"),
    file.path(script_dir, "..", "libs"),
    file.path(getwd(), "libs")
)
bridge_path <- NULL
for (d in candidates) {
    for (ext in c(".dll", ".so", ".dylib")) {
        p <- file.path(d, paste0("lfR_bridge", ext))
        if (file.exists(p)) { bridge_path <- normalizePath(p); break }
    }
    if (!is.null(bridge_path)) break
}
if (is.null(bridge_path)) { message("[FAIL] Bridge not found"); quit(status = 1) }

args <- commandArgs(trailingOnly = TRUE)

# Runtime directory resolution.
#
# The first command-line argument, when present, is treated as an
# explicit runtime directory path. Otherwise lf_find_runtime() consults
# the LINGOFUSE_RUNTIME environment variable, the "lingofuse.runtime"
# option, and finally a list of relative probes under the script
# directory and the current working directory.
explicit_runtime <- if (length(args) >= 1) args[1] else NULL
runtime_dir <- lf_find_runtime(explicit_runtime, script_dir)
if (is.null(runtime_dir)) {
    message("[FAIL] Could not locate the LingoFuse runtime directory.")
    message("       Provide it as the first argument, set the")
    message("       LINGOFUSE_RUNTIME environment variable, or place it")
    message("       in Binary/ relative to this repository.")
    quit(status = 1)
}
message("[OK]   Runtime dir: ", runtime_dir)

wait_sec <- 60L
if (length(args) >= 2) {
    parsed <- suppressWarnings(as.integer(args[2]))
    if (is.na(parsed) || parsed <= 0L) {
        message("[FAIL] wait_sec must be a positive integer, got: ", args[2])
        quit(status = 1)
    }
    wait_sec <- parsed
}

# -----------------------------------------------------------------------------
# Little-endian read/write helpers
# -----------------------------------------------------------------------------

u8_raw    <- function(x)  as.raw(x %% 256L)
u16_raw   <- function(x)  {
    x <- as.numeric(x)
    as.raw(c(x %% 256, (x %/% 256) %% 256))
}
u32_raw   <- function(x)  {
    x <- as.numeric(x)
    as.raw(c(x %% 256, (x %/% 256) %% 256,
             (x %/% 65536) %% 256, (x %/% 16777216) %% 256))
}
u64_raw   <- function(x)  {
    lo <- x %% 4294967296
    hi <- x %/% 4294967296
    c(u32_raw(lo), u32_raw(hi))
}
str_raw   <- function(s)  {
    bytes <- charToRaw(enc2utf8(s))
    c(bytes, as.raw(0))
}
f32_raw   <- function(x)  {
    con <- rawConnection(raw(0), "wb")
    on.exit(close(con))
    writeBin(as.numeric(x), con, size = 4, endian = "little")
    rawConnectionValue(con)
}

read_u8    <- function(r, off)  as.integer(r[off + 1L])
read_u16   <- function(r, off)  {
    a <- as.integer(r[off + 1L]); b <- as.integer(r[off + 2L])
    a + 256L * b
}
read_u32   <- function(r, off)  {
    a <- as.numeric(r[off + 1L]); b <- as.numeric(r[off + 2L])
    cc <- as.numeric(r[off + 3L]); d <- as.numeric(r[off + 4L])
    a + 256 * b + 65536 * cc + 16777216 * d
}
read_u64   <- function(r, off)  {
    lo <- read_u32(r, off)
    hi <- read_u32(r, off + 4)
    lo + hi * 4294967296
}
read_f32   <- function(r, off)  {
    con <- rawConnection(r[(off + 1L):(off + 4L)], "rb")
    on.exit(close(con))
    readBin(con, "numeric", n = 1L, size = 4L, endian = "little")
}
read_cstr  <- function(r, off)  {
    i <- off
    while (i < length(r) && r[i + 1L] != as.raw(0)) i <- i + 1L
    if (i > off) {
        bytes <- r[(off + 1L):i]
        s <- rawToChar(bytes)
    } else {
        s <- ""
    }
    list(str = s, next_off = i + 1L)
}

# -----------------------------------------------------------------------------
# Test body. The LF shutdown sequence is scheduled via on.exit().
# -----------------------------------------------------------------------------
run_cross_node <- function(wait_sec = 60L) {
    app <- NULL
    on.exit({
        lf_cleanup(app, runtime_dir)
    }, add = TRUE)

    dyn.load(bridge_path)
    lf_load(runtime_dir)
    message("[OK]   Bridge: ", bridge_path)
    message("[OK]   Runtime: ", runtime_dir)

    app <- .Call("lf_app_create", "demo", "R CrossDemo node (STEP 4)")
    received <- list()

    # ---- demo.add ---------------------------------------------------------
    lf_register_call(app, "add", "add(int32,int32)->int32", bin = TRUE,
        handler = function(req) {
            received[[length(received) + 1L]] <<-
                paste("add:", paste(req, collapse = ""))
            if (length(req) < 8L) return(raw(0))
            a <- read_u32(req, 0L)
            b <- read_u32(req, 4L)
            if (a >= 2^31) a <- a - 2^32
            if (b >= 2^31) b <- b - 2^32
            out <- a + b
            if (out < 0) out <- out + 2^32
            u32_raw(out)
        })

    # ---- demo.inv_seri ----------------------------------------------------
    lf_register_call(app, "inv_seri",
        "inv_seri typed sequence reversed", bin = TRUE,
        handler = function(req) {
            received[[length(received) + 1L]] <<-
                paste("inv_seri:", length(req), "bytes")
            p <- 0L
            b   <- read_u8(req, p); p <- p + 1L
            w   <- read_u16(req, p); p <- p + 2L
            cc  <- read_u32(req, p); p <- p + 4L
            u64 <- read_u64(req, p); p <- p + 8L
            cs  <- read_cstr(req, p); p <- cs$next_off
            s   <- cs$str
            f   <- read_f32(req, p)

            message("[RService] inv_seri received: b=", b, " w=", w,
                    " c=", cc, " u64=", u64, " s='", s, "' f=", f)

            c(f32_raw(f), str_raw(s), u64_raw(u64), u32_raw(cc),
              u16_raw(w), u8_raw(b))
        })

    message("[OK]   APIs registered: demo.add, demo.inv_seri")

    # ------------------------------------------------------------------
    # Prepare network
    # ------------------------------------------------------------------
    .Call("lf_reset_prepare")
    tag_svc <- .Call("lf_prepare_service", "ipc:cross", "ipc:cross")
    if (tag_svc < 0) stop("prepare_service failed")
    tag_cli <- lf_prepare_client("ipc:cross", app)
    if (tag_cli < 0) stop("prepare_client failed")
    rc <- .Call("lf_prepare_done")
    if (rc != 1L) stop("prepare_done returned ", rc)

    message("[OK]   demo @ ipc:cross")
    message("[INFO] Pumping for up to ", wait_sec, " seconds.")
    message("[INFO] Start cross_client.exe in another terminal.")
    message("[INFO] Press Ctrl+C to stop the pump loop early.")

    # ------------------------------------------------------------------
    # Pump loop (two exit paths: timeout, Ctrl+C)
    # ------------------------------------------------------------------
    completed_normally <- tryCatch({
        start_time <- Sys.time()
        while (as.numeric(Sys.time() - start_time, units = "secs") < wait_sec) {
            lf_poll(100)
        }
        TRUE
    }, interrupt = function(e) {
        FALSE
    })

    if (!completed_normally) {
        message("")
        message("[INFO] Pump loop stopped by Ctrl+C.")
    }

    # ------------------------------------------------------------------
    # Report
    # ------------------------------------------------------------------
    message("")
    message("Received requests: ", length(received))
    for (i in seq_along(received)) message("  [", i, "] ", received[[i]])

    invisible(TRUE)
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
tryCatch(
    run_cross_node(wait_sec),
    error = function(e) {
        message("[FAIL] Unhandled error in cross_node: ",
                conditionMessage(e))
    },
    interrupt = function(e) {
        message("")
        message("[INFO] Interrupted.")
    }
)

message("")
message("STEP 4 cross_node finished.")
quit(status = 0)