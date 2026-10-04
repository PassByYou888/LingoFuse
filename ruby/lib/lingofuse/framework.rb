# frozen_string_literal: true
#
# framework.rb — Process-wide facade over the LingoFuse C ABI.
#
# Uses Fiddle (not FFI). All native calls go through Fiddle::Function
# objects created in binding.rb.
#
# ============================================================================
# CONTRACTS
# ============================================================================
#   - prepare_done returns true only once per process. A second call
#     without an intervening shutdown returns false, which is NOT a
#     failure.
#
#   - call never returns nil. On timeout or unreachable target, the
#     native layer returns a size-0 handle. Use try_call for a
#     nil-on-failure contract.
#
#   - shutdown is idempotent.
#
# ============================================================================
# TIMEOUT UNITS
# ============================================================================
# All timeouts are in MILLISECONDS.
#
# ============================================================================
# DEADLOCK WARNING
# ============================================================================
# Do not call call / notify / sequenced_notify from inside a callback.
#

require 'fiddle'

require_relative 'binding'
require_relative 'errors'
require_relative 'data_handle'
require_relative 'app_handle'

module LingoFuse
  module Framework
    class << self
      # -----------------------------------------------------------------
      # Network preparation
      # -----------------------------------------------------------------

      def reset_prepare
        LingoFuse::LF_ResetPrepare.call
        nil
      end

      def prepare_service(listening_addr, physics_addr)
        listen_ptr = LingoFuse.cstr_ptr(listening_addr)
        physics_ptr = LingoFuse.cstr_ptr(physics_addr)

        tag = LingoFuse::LF_PrepareService.call(listen_ptr, physics_ptr)
        if tag.negative?
          raise Error,
                "prepare_service rejected address '#{listening_addr}' " \
                '(duplicate or invalid).'
        end
        tag
      end

      def prepare_client(physics_addr, app = nil)
        app_raw =
          if app.nil?
            nil
          else
            raise ArgumentError, 'app must be a LingoFuse::AppHandle' unless app.is_a?(AppHandle)
            app.raw
          end

        addr_ptr = LingoFuse.cstr_ptr(physics_addr)
        tag = LingoFuse::LF_PrepareClient.call(addr_ptr, app_raw)

        if tag.negative?
          raise Error,
                "prepare_client rejected address '#{physics_addr}' " \
                '(duplicate? set Overlap_Connection=True to allow ' \
                'multiple tunnels to the same address).'
        end
        tag
      end

      def prepare_done
        LingoFuse::LF_PrepareDone.call == 1
      end

      def exit_main_thread
        LingoFuse::LF_ExitMainThread.call
        nil
      end

      # -----------------------------------------------------------------
      # Runtime options
      # -----------------------------------------------------------------

      def set_option(option, value)
        opt_ptr = LingoFuse.cstr_ptr(option)
        val_ptr = LingoFuse.cstr_ptr(value)
        LingoFuse::LF_SetOption.call(opt_ptr, val_ptr)
        nil
      end

      # -----------------------------------------------------------------
      # App name generation and query
      # -----------------------------------------------------------------

      def generate_app_name
        ptr = LingoFuse::LF_Generate_AppName.call
        LingoFuse.read_cstr(ptr)
      end

      def get_app_name(app)
        raise ArgumentError, 'app must be a LingoFuse::AppHandle' unless app.is_a?(AppHandle)
        raise ObjectDisposedError.new('AppHandle') unless app.valid?

        ptr = LingoFuse::LF_Get_AppName.call(app.raw)
        LingoFuse.read_cstr(ptr)
      end

      # -----------------------------------------------------------------
      # Remote invocation
      # -----------------------------------------------------------------

      def call(app_name, param, timeout_ms = 5000)
        raise ArgumentError, 'param must be a LingoFuse::DataHandle' unless param.is_a?(DataHandle)
        raise ObjectDisposedError.new('DataHandle') unless param.valid?

        t = Integer(timeout_ms)
        raise ArgumentError, 'timeout_ms must be non-negative' if t.negative?

        name_ptr = LingoFuse.cstr_ptr(app_name)
        raw = LingoFuse::LF_Call.call(name_ptr, param.raw, t)

        if raw.nil? || (raw.respond_to?(:to_i) && raw.to_i.zero?)
          raise CallError.new(
            'LF_Call returned a null handle.',
            target_app: app_name.to_s
          )
        end
        DataHandle.from_raw(raw, true)
      end

      def try_call(app_name, param, timeout_ms = 5000)
        response = call(app_name, param, timeout_ms)
        if response.size.zero?
          response.dispose
          return nil
        end
        response
      end

      def notify(app_name, param)
        raise ArgumentError, 'param must be a LingoFuse::DataHandle' unless param.is_a?(DataHandle)
        raise ObjectDisposedError.new('DataHandle') unless param.valid?

        name_ptr = LingoFuse.cstr_ptr(app_name)
        LingoFuse::LF_Notify.call(name_ptr, param.raw)
        nil
      end

      def sequenced_notify(app_name, param)
        raise ArgumentError, 'param must be a LingoFuse::DataHandle' unless param.is_a?(DataHandle)
        raise ObjectDisposedError.new('DataHandle') unless param.valid?

        name_ptr = LingoFuse.cstr_ptr(app_name)
        LingoFuse::LF_Sequenced_Notify.call(name_ptr, param.raw)
        nil
      end

      # -----------------------------------------------------------------
      # Shutdown
      # -----------------------------------------------------------------

      def shutdown
        LingoFuse::LF_Shutdown.call
        nil
      end
    end
  end
end