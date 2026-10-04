# frozen_string_literal: true
#
# lingofuse.rb — Public entry point for the LingoFuse Ruby binding.
#
# Add lib/ to your Ruby load path and require the top-level module:
#
#     require 'lingofuse'
#
# The following symbols become available:
#
#     LingoFuse::DataHandle           RAII wrapper for a data buffer
#     LingoFuse::AppHandle            RAII wrapper for an application
#     LingoFuse::LfIo                 Unified JSON / string / byte I/O
#     LingoFuse::Framework            Process-wide ABI facade
#     LingoFuse::Status               Status queue and health checks
#     LingoFuse::NetworkEvents        Global connect / disconnect handlers
#     LingoFuse::NetworkEventListener Base class for OO listeners
#     LingoFuse::NetworkEventQueue    Thread-safe producer/consumer queue
#     LingoFuse::NativeBridge         C-extension callback marshaling
#     LingoFuse::CallbackErrorReporter
#
#     LingoFuse::Error                Base exception
#     LingoFuse::LibraryLoadError     Native library load failure
#     LingoFuse::CallError            Remote call failure
#     LingoFuse::IoError              Byte-level I/O failure
#     LingoFuse::ObjectDisposedError  Use-after-dispose
#     LingoFuse::RegistrationError    API registration rejection
#     LingoFuse::CallbackError        Callback body raised
#
# ============================================================================
# NATIVE LIBRARY DISCOVERY
# ============================================================================
# The native LingoFuse shared library (LingoFuse64.dll / liblingofuse.so /
# liblingofuse.dylib) is located by lib/lingofuse/binding.rb. That file is
# the only place in this project that calls Fiddle.dlopen.
#
# binding.rb searches a list of standard locations, so callers normally do
# not have to set anything. See the header of binding.rb for the exact
# search order. Setting LINGOFUSE_LIB_PATH is an explicit override that
# always wins.
#
# ============================================================================
# LOADING STRATEGY
# ============================================================================
# Every child file is loaded through an absolute path computed from this
# file's own location, so the load is independent of the working
# directory and of $LOAD_PATH.
#
# ============================================================================

_lf_rb_dir = File.dirname(File.expand_path(__FILE__))

require File.join(_lf_rb_dir, 'lingofuse', 'errors')
require File.join(_lf_rb_dir, 'lingofuse', 'binding')
require File.join(_lf_rb_dir, 'lingofuse', 'data_handle')
require File.join(_lf_rb_dir, 'lingofuse', 'app_handle')
require File.join(_lf_rb_dir, 'lingofuse', 'lf_io')
require File.join(_lf_rb_dir, 'lingofuse', 'framework')
require File.join(_lf_rb_dir, 'lingofuse', 'status')
require File.join(_lf_rb_dir, 'lingofuse', 'network_events')

module LingoFuse
  # Version of the Ruby binding itself.
  #
  # This is NOT the version of the native LingoFuse runtime. The native
  # runtime reports its own version through the status queue; it is not
  # surfaced through the C ABI.
  VERSION = '1.0.0'

  class << self
    # Eagerly loads the native library.
    #
    # Because the library is loaded when this module is first required,
    # this method is a no-op at runtime. It is provided for symmetry with
    # the C++ binding (LF_LoadLibrary) and the JavaScript binding
    # (lf.loadLibrary()).
    #
    # @return [Boolean] always true
    def load_library
      true
    end

    # Returns true when the native library has been loaded.
    #
    # @return [Boolean]
    def loaded?
      defined?(LingoFuse::LF_CreateData) ? true : false
    end

    # Returns the platform-specific library file name that would be (or
    # was) loaded on this system.
    #
    # @return [String]
    def library_name
      LingoFuse.platform_library_name
    end

    # Returns a short description of the current runtime, for diagnostics
    # and log headers.
    #
    # @return [Hash{Symbol => String}]
    def platform
      {
        ruby: RUBY_VERSION,
        platform: RUBY_PLATFORM,
        library: LingoFuse.platform_library_name
      }
    end
  end
end