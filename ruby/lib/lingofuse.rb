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
#   Core RAII:
#     LingoFuse::DataHandle            RAII wrapper for a data buffer
#     LingoFuse::AppHandle             RAII wrapper for an application
#
#   Unified I/O:
#     LingoFuse::LfIo                  JSON / string / byte I/O policy
#
#   Process-wide facade:
#     LingoFuse::Framework             Network preparation and remote calls
#     LingoFuse::Status                Status queue and health checks
#     LingoFuse::NetworkEvents         Global connect / disconnect handlers
#     LingoFuse::NetworkEventListener  Base class for OO listeners
#     LingoFuse::NetworkEventQueue     Thread-safe producer/consumer queue
#
#   Addressing (v2.0):
#     LingoFuse::Target                Abstract base class
#     LingoFuse::AppTarget             App-name addressing
#     LingoFuse::UIDTarget             UID addressing
#     LingoFuse::P2PNameTarget         P2PName addressing
#
#   Modern async (v2.0):
#     LingoFuse::CallFuture            Thread-safe Future
#     LingoFuse::AsyncOp               Single-op state machine
#     LingoFuse::AsyncBridge           Process-wide singleton manager
#     LingoFuse::AsyncSupport          Factory: run_async_with_future
#
#   Runtime options (v2.0):
#     LingoFuse::Options               16 typed set/get pairs
#
#   Process-wide P2P registration (v2.0):
#     LingoFuse::P2PRegistration       register_call / register_notify /
#                                      unregister / registered?
#
#   Callback marshaling:
#     LingoFuse::NativeBridge          C-extension callback queue
#     LingoFuse::CallbackErrorReporter Unified callback error dispatcher
#
#   Exceptions:
#     LingoFuse::Error                 Base exception
#     LingoFuse::LibraryLoadError      Native library load failure
#     LingoFuse::CallError             Remote call failure
#     LingoFuse::IoError               Byte-level I/O failure
#     LingoFuse::ObjectDisposedError   Use-after-dispose
#     LingoFuse::RegistrationError     API registration rejection
#     LingoFuse::CallbackError         Callback body raised
#     LingoFuse::TimeoutError          Wait window expired
#
# ============================================================================
# NATIVE LIBRARY DISCOVERY
# ============================================================================
# The native LingoFuse shared library (LingoFuse64.dll / liblingofuse.so /
# liblingofuse.dylib) is loaded by the C extension
# (lib/lingofuse_ext.so) at extension-load time. See
# ext/lingofuse_ext/LingoFuse.c for the search order:
#
#     1. The directory that contains the current executable.
#     2. The system loader search path.
#
# For a successful load, the four DLLs must reside in one directory,
# and that directory must be either the executable's directory or on
# PATH:
#
#     LingoFuse64.dll
#     z_ipc_64.dll
#     mimalloc64.dll
#     mimalloc-redirect.dll
#
# ============================================================================
# LOADING ORDER
# ============================================================================
# The requires below follow the module dependency topology:
#
#     errors                          (no dependencies)
#     binding                         (errors)
#     native_bridge                   (errors, binding, callback_error_reporter,
#                                      data_handle)
#     callback_error_reporter         (errors)
#     data_handle                     (errors, binding, native_bridge)
#     app_handle                      (errors, binding, native_bridge,
#                                      data_handle, callback_error_reporter)
#     lf_io                           (errors, data_handle)
#     framework                       (errors, binding, data_handle, app_handle)
#     status                          (errors, binding)
#     network_events                  (errors, binding, native_bridge,
#                                      callback_error_reporter)
#     options                         (errors, native_bridge)
#     async_support                   (errors, native_bridge)
#     address                         (errors, data_handle, lf_io,
#                                      async_support)
#     p2p_registration                (errors, data_handle, native_bridge,
#                                      callback_error_reporter)
#
# Each submodule file also uses require_relative internally, so the
# exact top-level ordering is not load-critical. It is written out in
# full anyway, for clarity and to guarantee a deterministic boot
# sequence in log output.
# ============================================================================

_lf_rb_dir = File.dirname(File.expand_path(__FILE__))

# ---------------------------------------------------------------------------
# Foundation
# ---------------------------------------------------------------------------

require File.join(_lf_rb_dir, 'lingofuse', 'errors')
require File.join(_lf_rb_dir, 'lingofuse', 'callback_error_reporter')

# ---------------------------------------------------------------------------
# Native layer (C extension wrapper)
# ---------------------------------------------------------------------------

require File.join(_lf_rb_dir, 'lingofuse', 'binding')
require File.join(_lf_rb_dir, 'lingofuse', 'native_bridge')

# ---------------------------------------------------------------------------
# RAII wrappers
# ---------------------------------------------------------------------------

require File.join(_lf_rb_dir, 'lingofuse', 'data_handle')
require File.join(_lf_rb_dir, 'lingofuse', 'app_handle')

# ---------------------------------------------------------------------------
# Unified I/O
# ---------------------------------------------------------------------------

require File.join(_lf_rb_dir, 'lingofuse', 'lf_io')

# ---------------------------------------------------------------------------
# Process-wide facade
# ---------------------------------------------------------------------------

require File.join(_lf_rb_dir, 'lingofuse', 'framework')
require File.join(_lf_rb_dir, 'lingofuse', 'status')
require File.join(_lf_rb_dir, 'lingofuse', 'network_events')

# ---------------------------------------------------------------------------
# v2.0 additions
# ---------------------------------------------------------------------------

require File.join(_lf_rb_dir, 'lingofuse', 'options')
require File.join(_lf_rb_dir, 'lingofuse', 'async_support')
require File.join(_lf_rb_dir, 'lingofuse', 'address')
require File.join(_lf_rb_dir, 'lingofuse', 'p2p_registration')

module LingoFuse
  # ---------------------------------------------------------------------------
  # Version of the Ruby binding itself.
  #
  # This is NOT the version of the native LingoFuse runtime. The native
  # runtime reports its own version through the status queue; it is not
  # surfaced through the C ABI.
  #
  # v1.0.0: Fiddle-based binding.
  # v2.0.0: Fully C-extension based; adds three addressing modes,
  #         modern async support (CallFuture / AsyncBridge), typed
  #         runtime options, and process-wide P2P registration.
  # ---------------------------------------------------------------------------
  VERSION = '2.0.0'

  class << self
    # Eagerly loads the native library.
    #
    # Because the library is loaded when the C extension is required,
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
      defined?(LingoFuse::Native) && LingoFuse::Native.loaded?
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
    # The three `has_*` flags let a caller answer "which v2.0 subsystems
    # are available in this build?" without probing each module by hand.
    #
    # @return [Hash{Symbol => String, Boolean}]
    def platform
      {
        ruby: RUBY_VERSION,
        platform: RUBY_PLATFORM,
        library: LingoFuse.platform_library_name,
        version: LingoFuse::VERSION,
        has_async_support: defined?(LingoFuse::AsyncSupport) ? true : false,
        has_address:       defined?(LingoFuse::Address)       ? true : false,
        has_options:       defined?(LingoFuse::Options)       ? true : false,
        has_p2p_reg:       defined?(LingoFuse::P2PRegistration) ? true : false
      }
    end
  end
end