#!/usr/bin/env bash
#
# build.sh - Build lf_dart_bridge.so (Linux) or lf_dart_bridge.dylib
#            (macOS).
#
# Mirrors build.ps1 in structure and diagnostics. The compiler is
# chosen from the CC environment variable; if unset, `cc` is used,
# which on most systems is a symlink to gcc or clang.
#
# Steps:
#   1. Verify that all required source and header files are present.
#   2. Compile lf_dart_bridge.c and dart_api_dl.c into a shared
#      library.
#   3. Inspect the library with nm and assert that the expected number
#      of lf_bridge_* symbols are exported, and that a list of
#      critical symbols is present.
#   4. Copy the library to the dart/ parent directory.
#
# Usage:
#   ./build.sh               incremental build
#   ./build.sh --clean       rebuild from scratch
#   ./build.sh --help        show this message
#
# All output is in English.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$SCRIPT_DIR"
DART_DIR="$(cd "$BRIDGE_DIR/.." && pwd)"
OBJ_DIR="$BRIDGE_DIR/obj"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Minimum number of lf_bridge_* exports expected. Must match build.ps1.
MIN_EXPORT_COUNT=80

# Symbols that must always be present. Must match build.ps1.
CRITICAL_EXPORTS=(
    lf_bridge_init
    lf_bridge_shutdown
    lf_bridge_is_initialized
    lf_bridge_create_data
    lf_bridge_free_data
    lf_bridge_get_p2p_uid
    lf_bridge_get_p2p_name
    lf_bridge_create_app
    lf_bridge_register_call
    lf_bridge_register_notify
    lf_bridge_register_p2p_call
    lf_bridge_complete
    lf_bridge_prepare_done
    lf_bridge_call
    lf_bridge_call_async
    lf_bridge_uid_call
    lf_bridge_p2pname_call
    lf_bridge_set_opt_quiet
    lf_bridge_get_opt_quiet
    lf_bridge_set_network_event
    lf_bridge_stats_json
)

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_GRAY=$'\033[90m'
    C_RESET=$'\033[0m'
else
    C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_GRAY='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

section() {
    printf '\n%s%s%s\n' "$C_CYAN" '==================================================================' "$C_RESET"
    printf '%s  %s%s\n' "$C_CYAN" "$1" "$C_RESET"
    printf '%s%s%s\n' "$C_CYAN" '==================================================================' "$C_RESET"
}
ok()   { printf '%s  [OK]   %s%s\n' "$C_GREEN"  "$1" "$C_RESET"; }
warn() { printf '%s  [WARN] %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
fail() { printf '%s  [FAIL] %s%s\n' "$C_RED"    "$1" "$C_RESET"; }
info() { printf '%s         %s%s\n' "$C_GRAY"   "$1" "$C_RESET"; }

usage() {
    cat <<'EOF'
Build script for lf_dart_bridge.{so,dylib} on Linux / macOS.

USAGE:
    ./build.sh [OPTIONS]

OPTIONS:
    -c, --clean     Remove obj/ and the output library, then rebuild.
    -s, --skip-export-check
                    Skip the nm-based export verification step.
    -h, --help      Show this message.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

CLEAN=0
SKIP_EXPORT_CHECK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clean)              CLEAN=1 ;;
        -s|--skip-export-check)  SKIP_EXPORT_CHECK=1 ;;
        -h|--help)               usage; exit 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1"; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

UNAME_S="$(uname -s)"
case "$UNAME_S" in
    Linux*)
        OUT_NAME="lf_dart_bridge.so"
        EXTRA_LIBS="-lpthread -ldl"
        NM_FLAG="-D --defined-only"
        NM_GREP=' T lf_bridge_'
        ;;
    Darwin*)
        OUT_NAME="lf_dart_bridge.dylib"
        EXTRA_LIBS=""
        NM_FLAG="-gU"
        NM_GREP=' T _lf_bridge_'
        ;;
    *)
        printf '[FATAL] Unsupported OS: %s\n' "$UNAME_S" >&2
        exit 1
        ;;
esac

OUT_PATH="$BRIDGE_DIR/$OUT_NAME"
OUT_PATH_IN_DART="$DART_DIR/$OUT_NAME"

CC="${CC:-cc}"

# ---------------------------------------------------------------------------
# Step 1 -- Verify required files
# ---------------------------------------------------------------------------

section 'LingoFuse Dart Bridge Build (Unix)'

printf '  Step 1: verifying required files\n'
REQUIRED_FILES=(
    "$BRIDGE_DIR/lf_dart_bridge.h"
    "$BRIDGE_DIR/lf_dart_bridge.c"
    "$BRIDGE_DIR/dart_api.h"
    "$BRIDGE_DIR/dart_api_dl.h"
    "$BRIDGE_DIR/dart_api_dl.c"
    "$BRIDGE_DIR/dart_native_api.h"
    "$BRIDGE_DIR/dart_tools_api.h"
    "$BRIDGE_DIR/dart_version.h"
    "$BRIDGE_DIR/internal/dart_api_dl_impl.h"
    "$DART_DIR/headers/LingoFuse.h"
)
MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        fail "missing: $f"
        MISSING=1
    fi
done
if [[ $MISSING -ne 0 ]]; then
    printf '\n'
    info 'Ensure all Dart SDK headers have been copied into bridge/, and'
    info 'that headers/LingoFuse.h is present in the parent directory.'
    info 'See README.md, section "Compiling the C bridge DLL".'
    exit 1
fi
ok "all ${#REQUIRED_FILES[@]} required files present"

# ---------------------------------------------------------------------------
# Step 2 -- Verify the compiler
# ---------------------------------------------------------------------------

printf '\n  Step 2: verifying the C compiler\n'
if ! command -v "$CC" >/dev/null 2>&1; then
    fail "compiler not found: $CC"
    info 'Install a C toolchain (build-essential on Debian/Ubuntu,'
    info 'Xcode Command Line Tools on macOS), or set CC=... to a valid'
    info 'compiler.'
    exit 1
fi
CC_PATH="$(command -v "$CC")"
CC_VERSION_LINE="$("$CC" --version 2>&1 | head -n 1 || true)"
ok "compiler: $CC_PATH"
info "$CC_VERSION_LINE"

# ---------------------------------------------------------------------------
# Step 3 -- Optional clean
# ---------------------------------------------------------------------------

printf '\n  Step 3: cleaning previous build\n'
if [[ $CLEAN -eq 1 ]]; then
    if [[ -d "$OBJ_DIR" ]]; then
        rm -rf "$OBJ_DIR"
        ok "removed $OBJ_DIR"
    else
        info 'no obj/ directory to remove'
    fi
    if [[ -f "$OUT_PATH" ]]; then
        rm -f "$OUT_PATH"
        ok "removed $OUT_PATH"
    fi
    if [[ -f "$OUT_PATH_IN_DART" ]]; then
        rm -f "$OUT_PATH_IN_DART"
        ok "removed $OUT_PATH_IN_DART"
    fi
else
    info 'clean skipped (pass --clean to force a full rebuild)'
fi

# ---------------------------------------------------------------------------
# Step 4 -- Compile
# ---------------------------------------------------------------------------

printf '\n  Step 4: compiling %s\n' "$OUT_NAME"
mkdir -p "$OBJ_DIR"

# shellcheck disable=SC2086  # EXTRA_LIBS is intentionally word-split
(
    cd "$BRIDGE_DIR"
    "$CC" -O2 -fPIC -shared \
        -Wall -Wextra -Wno-unused-parameter \
        -I. \
        -I../headers \
        lf_dart_bridge.c \
        dart_api_dl.c \
        $EXTRA_LIBS \
        -o "$OUT_NAME"
)
COMPILE_RC=$?
if [[ $COMPILE_RC -ne 0 ]]; then
    fail "compilation failed (exit code $COMPILE_RC)"
    exit 1
fi

if [[ ! -f "$OUT_PATH" ]]; then
    fail "$CC reported success but $OUT_PATH does not exist"
    exit 1
fi

# Portable stat for file size (BSD stat uses -f%z, GNU stat uses -c%s).
if stat -c%s "$OUT_PATH" >/dev/null 2>&1; then
    OUT_SIZE="$(stat -c%s "$OUT_PATH")"
elif stat -f%z "$OUT_PATH" >/dev/null 2>&1; then
    OUT_SIZE="$(stat -f%z "$OUT_PATH")"
else
    OUT_SIZE="(unknown)"
fi
ok "built: $OUT_PATH ($OUT_SIZE bytes)"

# ---------------------------------------------------------------------------
# Step 5 -- Verify exports with nm
# ---------------------------------------------------------------------------

if [[ $SKIP_EXPORT_CHECK -eq 0 ]]; then
    printf '\n  Step 5: verifying exported symbols (nm)\n'

    if ! command -v nm >/dev/null 2>&1; then
        warn 'nm not found on PATH; skipping export check'
    else
        # shellcheck disable=SC2086  # NM_FLAG is intentionally word-split
        EXPORT_COUNT="$(nm $NM_FLAG "$OUT_PATH" 2>/dev/null | grep -c "$NM_GREP" || true)"

        if [[ "$EXPORT_COUNT" -ge "$MIN_EXPORT_COUNT" ]]; then
            ok "exported $EXPORT_COUNT lf_bridge_* symbols (minimum: $MIN_EXPORT_COUNT)"
        else
            fail "only $EXPORT_COUNT lf_bridge_* symbols exported; expected at least $MIN_EXPORT_COUNT"
            info 'The bridge header may declare more functions than the .c implements.'
            info 'Re-check lf_dart_bridge.c against lf_dart_bridge.h.'
            exit 1
        fi

        # Spot-check the critical exports.
        MISSING_SYMS=()
        for sym in "${CRITICAL_EXPORTS[@]}"; do
            # macOS prefixes C symbols with a leading underscore; the
            # NM_GREP pattern already accounts for that, so here we
            # only need to check for the symbol name itself.
            if ! nm $NM_FLAG "$OUT_PATH" 2>/dev/null | grep -q "$NM_GREP$sym\$"; then
                MISSING_SYMS+=("$sym")
            fi
        done
        if [[ ${#MISSING_SYMS[@]} -gt 0 ]]; then
            for sym in "${MISSING_SYMS[@]}"; do
                fail "critical export missing: $sym"
            done
            exit 1
        fi
        ok "all ${#CRITICAL_EXPORTS[@]} critical exports present"
    fi
else
    printf '\n  Step 5: export verification skipped (--skip-export-check)\n'
fi

# ---------------------------------------------------------------------------
# Step 6 -- Copy to dart/ parent directory
# ---------------------------------------------------------------------------

printf '\n  Step 6: copying to dart/ parent directory\n'
if [[ "$BRIDGE_DIR" == "$DART_DIR" ]]; then
    warn 'bridge/ and dart/ are the same directory; copy skipped'
else
    cp -f "$OUT_PATH" "$OUT_PATH_IN_DART"
    ok "copied to: $OUT_PATH_IN_DART"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

section 'Build complete'
printf '\n'
ok "LIB  : $OUT_PATH"
ok "copy : $OUT_PATH_IN_DART"
printf '\n'
info 'Next steps:'
info '  1. cd ..'
info '  2. dart test                      # run the offline test suite'
info '  3. dart run bin/lf_probe.dart     # minimal load probe'
printf '\n'

exit 0