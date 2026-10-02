#!/usr/bin/env bash
# ============================================================
#  LingoFuse Dart Bridge Build (Unix)
#  Compiles lf_dart_bridge.so (Linux) or lf_dart_bridge.dylib
#  (macOS) using the system compiler.
# ============================================================

set -e

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BRIDGE_DIR"

echo "============================================================"
echo "  LingoFuse Dart Bridge Build (Unix)"
echo "============================================================"
echo

# ---- 1. Check required source files --------------------------------
REQUIRED=(
    "lf_dart_bridge.h"
    "lf_dart_bridge.c"
    "dart_api.h"
    "dart_api_dl.h"
    "dart_api_dl.c"
    "dart_native_api.h"
    "dart_tools_api.h"
    "dart_version.h"
    "internal/dart_api_dl_impl.h"
    "../headers/LingoFuse.h"
)

MISSING=0
for f in "${REQUIRED[@]}"; do
    if [ ! -f "$f" ]; then
        echo "[FAIL] Missing: $f"
        MISSING=1
    fi
done
if [ "$MISSING" -ne 0 ]; then
    echo
    echo "See README.md, section 'Compiling the C bridge', for the"
    echo "list of files that must be copied from D:\\dart-sdk\\include."
    exit 1
fi

echo "[OK]   All source files present"

# ---- 2. Compile -----------------------------------------------------
OS_NAME="$(uname -s)"
case "$OS_NAME" in
    Linux*)  OUT="lf_dart_bridge.so" ;;
    Darwin*) OUT="lf_dart_bridge.dylib" ;;
    *)
        echo "[FAIL] Unsupported OS: $OS_NAME"
        exit 1
        ;;
esac

CC="${CC:-cc}"

echo
echo "[INFO] Compiling $OUT with $CC ..."
echo

# Linux needs -lpthread and -ldl; macOS has them built in.
if [ "$OS_NAME" = "Linux" ]; then
    EXTRA_LIBS="-lpthread -ldl"
else
    EXTRA_LIBS=""
fi

$CC -O2 -fPIC -shared -Wall \
    -I. \
    -I../headers \
    lf_dart_bridge.c \
    dart_api_dl.c \
    $EXTRA_LIBS \
    -o "$OUT"

if [ $? -ne 0 ]; then
    echo "[FAIL] Compilation failed"
    exit 1
fi

# ---- 3. Verify output ----------------------------------------------
if [ ! -f "$OUT" ]; then
    echo "[FAIL] Compilation reported success but $OUT was not created"
    exit 1
fi

SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")
echo
echo "[OK]   Built: $BRIDGE_DIR/$OUT"
echo "[INFO] Size:  $SIZE bytes"