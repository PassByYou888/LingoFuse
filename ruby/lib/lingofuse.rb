# frozen_string_literal: true
#
# lingofuse.rb — Public entry point for the LingoFuse Ruby binding.

_lf_rb_dir = File.dirname(File.expand_path(__FILE__))

require File.join(_lf_rb_dir, 'lingofuse', 'errors')
require File.join(_lf_rb_dir, 'lingofuse', 'callback_error_reporter')

require File.join(_lf_rb_dir, 'lingofuse', 'binding')
require File.join(_lf_rb_dir, 'lingofuse', 'native_bridge')

require File.join(_lf_rb_dir, 'lingofuse', 'data_handle')
require File.join(_lf_rb_dir, 'lingofuse', 'app_handle')

require File.join(_lf_rb_dir, 'lingofuse', 'lf_io')

require File.join(_lf_rb_dir, 'lingofuse', 'framework')
require File.join(_lf_rb_dir, 'lingofuse', 'status')
require File.join(_lf_rb_dir, 'lingofuse', 'network_events')

require File.join(_lf_rb_dir, 'lingofuse', 'options')
require File.join(_lf_rb_dir, 'lingofuse', 'async_support')
require File.join(_lf_rb_dir, 'lingofuse', 'address')
require File.join(_lf_rb_dir, 'lingofuse', 'p2p_registration')

module LingoFuse
  VERSION = '2.0.0'

  class << self
    def load_library
      true
    end

    def loaded?
      defined?(LingoFuse::Native) && LingoFuse::Native.loaded?
    end

    def library_name
      LingoFuse.platform_library_name
    end

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

at_exit do
  begin
    if defined?(LingoFuse::NativeBridge) && LingoFuse::NativeBridge.respond_to?(:stop)
      LingoFuse::NativeBridge.stop
    end
  rescue StandardError
  end

  begin
    if defined?(LingoFuse::Framework)
      LingoFuse::Framework.exit_main_thread
      LingoFuse::Framework.shutdown
    end
  rescue StandardError
  end

  begin
    if defined?(LingoFuse::Native) && LingoFuse::Native.respond_to?(:free_library)
      LingoFuse::Native.free_library
    end
  rescue StandardError
  end
end