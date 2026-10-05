#!/bin/sh
# build.sh - Compile the C shim and the mock LingoFuse implementation
# into a single shared library. The shim's extern LF_* symbols are
# resolved against mock_lf.c at link time.
#
# Requirements: a C compiler (gcc / clang) and pthreads.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

CC=${CC:-cc}

if [ "$(uname -s)" = "Darwin" ]; then
    OUT="liblf_shim_mock.dylib"
    SHARED_FLAGS="-dynamiclib -fPIC"
    EXTRA_LIBS=""
else
    OUT="liblf_shim_mock.so"
    SHARED_FLAGS="-shared -fPIC"
    EXTRA_LIBS="-lpthread"
fi

echo "==> Compiling $OUT"
"$CC" $SHARED_FLAGS -O2 -Wall -Wextra -std=c99 \
    -o "$OUT" \
    lf_shim.c mock_lf.c \
    $EXTRA_LIBS

echo "==> Done: $HERE/$OUT"