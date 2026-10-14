# frozen_string_literal: true
#
# extconf.rb — Build configuration for the lingofuse_ext C extension.
#
# Compiles TWO translation units into one shared object:
#
#   * LingoFuse.c        — dynamic-library loader + 59 forwarders +
#                          helper functions.
#   * lingofuse_ext.c    — Ruby C API surface (rb_lf_* wrappers,
#                          callback marshaling, module init).
#
# Both files live in the same directory ($(srcdir)); mkmf picks up
# every *.c file automatically. No explicit source list is required.
#
# ============================================================================
# WHY THIS FILE DELIBERATELY SKIPS have_library('pthread')
# ============================================================================
# Ruby 4.0 for Windows is built for x64-mingw-ucrt (UCRT). If the active
# C compiler is an external MinGW-Builds build (msvcrt), mkmf's
# have_library() probe tries to link a UCRT-flavoured test program
# against a mismatched CRT and fails with "You have to install
# development tools first", even though -lpthread works fine from a
# plain command line.
#
# On MinGW, pthread is provided by winpthreads, which the Ruby build
# links automatically. No explicit probe is needed. We therefore:
#
#   * check the HEADER (pthread.h) — a compile-only check, not
#     affected by the CRT mismatch;
#   * append -lpthread and -lkernel32 to $libs explicitly so the final
#     link line is self-documenting.
#
# ============================================================================
# WHY -Wno-cast-function-type
# ============================================================================
# LingoFuse.c uses the standard Windows DLL-loading pattern:
#
#     pLF_Foo = (fnLF_Foo)GetProcAddress(hDll, "LF_Foo");
#
# GetProcAddress returns FARPROC (an untyped function pointer). The cast
# to a typed function pointer is required and correct. GCC 8+ emits
# -Wcast-function-type on every such cast; for GetProcAddress this is a
# false positive. We silence it to keep the build output readable.
#
# ============================================================================
# WHY kernel32
# ============================================================================
# LingoFuse.c uses LoadLibraryA / GetModuleFileNameA / FreeLibrary on
# Windows, all of which live in kernel32.dll. MinGW links kernel32 by
# default, but we declare the dependency explicitly so a future
# toolchain change cannot silently drop it.
# ============================================================================

require 'mkmf'

# --- Compiler flags ------------------------------------------------------

$CFLAGS << ' -std=c99'
$CFLAGS << ' -Wall -Wextra -Wno-unused-parameter'
$CFLAGS << ' -Wno-cast-function-type'

$INCFLAGS << ' -I$(srcdir)'

# --- Optional: prefer the DevKit gcc if present ---------------------------
#
# Ruby 4.0 is x64-mingw-ucrt (UCRT). The DevKit's mingw64 gcc is the
# matching compiler. If it is present, force it; otherwise print a
# diagnostic and proceed with whatever RbConfig currently selects.
#
# This is informational only. The build succeeds with either compiler in
# practice, but the DevKit gcc eliminates the CRT mismatch by construction.

arch = RbConfig::CONFIG['arch'].to_s
cc   = RbConfig::CONFIG['CC'].to_s

$stderr.puts "[extconf] Ruby arch : #{arch}"
$stderr.puts "[extconf] RbConfig CC: #{cc}"

if arch =~ /mingw-ucrt/
  devkit_gcc = 'C:/Ruby40-x64/msys64/mingw64/bin/gcc.exe'

  if File.file?(devkit_gcc)
    RbConfig::MAKEFILE_CONFIG['CC'] = devkit_gcc
    $stderr.puts "[extconf] Using DevKit gcc: #{devkit_gcc}"
  elsif cc =~ %r{mingw64} && cc !~ %r{msys64|msys32}
    $stderr.puts ''
    $stderr.puts '[extconf] WARNING: Ruby is built for ' + arch + ' (UCRT),'
    $stderr.puts '[extconf]          but the active C compiler is:'
    $stderr.puts '[extconf]              ' + cc
    $stderr.puts '[extconf]          This compiler likely uses msvcrt, which'
    $stderr.puts '[extconf]          is incompatible with Ruby\'s UCRT runtime.'
    $stderr.puts '[extconf]          Library probes may fail.'
    $stderr.puts '[extconf]'
    $stderr.puts '[extconf]          Recommended fix: install the Ruby DevKit\'s'
    $stderr.puts '[extconf]          MSYS2 toolchain, or prepend this directory'
    $stderr.puts '[extconf]          to PATH for the build session:'
    $stderr.puts '[extconf]              C:\\Ruby40-x64\\msys64\\mingw64\\bin'
    $stderr.puts ''
  end
end

# --- Required headers (compile-only checks; CRT-safe) --------------------

unless have_header('pthread.h')
  abort '[extconf] FATAL: pthread.h not found. Install the Ruby DevKit.'
end

unless have_header('ruby/thread.h')
  abort '[extconf] FATAL: ruby/thread.h not found. ' \
        'Reinstall RubyInstaller with development headers.'
end

# --- Linker flags --------------------------------------------------------

if RUBY_PLATFORM =~ /mingw|mswin/
  # winpthreads (pthread runtime) and kernel32 (LoadLibrary family).
  # Appended to $libs so the final link line is explicit.
  $libs << ' -lpthread'
  $libs << ' -lkernel32'
end

# --- Generate Makefile ---------------------------------------------------

create_makefile('lingofuse_ext')