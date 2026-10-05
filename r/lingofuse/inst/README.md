# lingofuse (installed package)

This directory is copied verbatim into the installed package. Its
contents are reachable at runtime via `system.file(..., package = "lingofuse")`.

The R package is a thin R layer over a C++ bridge (`lingofuse.dll` /
`liblingofuse.so` / `liblingofuse.dylib`) that speaks the LingoFuse C
ABI. The LingoFuse runtime itself is distributed separately and is
located at process start through:

  1. the LINGOFUSE_RUNTIME environment variable,
  2. the "lingofuse.runtime" R option, or
  3. explicit `lf_load(dir)` / `lf_find_runtime()` calls.

See the repository README for the full layout and usage guide.