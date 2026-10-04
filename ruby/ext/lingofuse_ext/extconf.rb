# frozen_string_literal: true
#
# extconf.rb — Build configuration for the lingofuse_ext C extension.
#
# This extension is the ONLY way Ruby can safely receive LingoFuse
# callbacks. Fiddle cannot marshal a callback from a native thread onto
# the Ruby interpreter; the VM raises
#
#     [BUG] rb_thread_call_with_gvl() is called by non-ruby thread
#
# and the process deadlocks.
#
# This extension solves the problem by interposing a small native-side
# queue between the LingoFuse callback thread and a dedicated Ruby
# dispatcher thread. The native thread enqueues work and blocks on a
# condition variable; the Ruby thread dequeues and runs the Ruby
# callback, then signals completion.
#
# Build:
#
#     cd ext/lingofuse_ext
#     ruby extconf.rb
#     make
#     make install     # or copy the resulting .so next to lib/
#
# ============================================================================

require 'mkmf'

# The extension needs POSIX threads on every platform. MinGW ships
# winpthreads; on Linux and macOS this is part of libc.
have_library('pthread')
have_header('pthread.h')
have_header('ruby/thread.h')

$CFLAGS << ' -Wall -Wextra -Wno-unused-parameter'
$CFLAGS << ' -std=c99'

# The extension itself does not link against LingoFuse. All LingoFuse
# function pointers are passed in from Ruby through the existing
# Fiddle bindings (lib/lingofuse/binding.rb). This keeps the extension
# free of any dependency on the DLL's location or loader behaviour.

create_makefile('lingofuse_ext')