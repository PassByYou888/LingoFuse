# frozen_string_literal: true
#
# callback_error_reporter.rb — Process-wide dispatcher for exceptions
# raised inside user callbacks.
#
# ============================================================================
# PURPOSE
# ============================================================================
# Both the NativeBridge path (C extension) and the Fiddle fallback path
# route user-callback exceptions through this module. The user installs
# a single handler:
#
#     LingoFuse::CallbackErrorReporter.handler = ->(source, err) { ... }
#
# The handler may be invoked from any Ruby thread that runs a callback —
# the dispatcher thread (NativeBridge) or the calling thread (Fiddle
# fallback / LocalCall). It must therefore be thread-safe and must not
# itself raise.
#
# ============================================================================
# DEFAULT BEHAVIOUR
# ============================================================================
# When no handler is installed, the reporter writes a one-line
# diagnostic to $stderr. That write goes through the Ruby-level
# $stderr object; it does NOT go through the C-level fprintf that the
# extension uses for last-resort reporting.
#
# ============================================================================
# WHY THIS FILE EXISTS ON ITS OWN
# ============================================================================
# app_handle.rb requires native_bridge.rb (the C extension wrapper).
# native_bridge.rb needs CallbackErrorReporter to forward exceptions
# from the wrapper. If CallbackErrorReporter lived inside app_handle.rb,
# native_bridge.rb would have to require app_handle.rb, creating a
# require cycle. Isolating the reporter here removes the cycle.
#
# ============================================================================

require 'thread'

module LingoFuse
  module CallbackErrorReporter
    @handler = nil
    @mutex   = Mutex.new

    class << self
      # Installs a handler. Passing nil removes the current handler.
      #
      # @param callable [#call, nil]
      # @raise [ArgumentError] when callable is neither nil nor callable
      def handler=(callable)
        unless callable.nil? || callable.respond_to?(:call)
          raise ArgumentError,
                'CallbackErrorReporter.handler must respond to #call or be nil'
        end
        @mutex.synchronize { @handler = callable }
      end

      # Returns the currently installed handler, or nil.
      #
      # @return [#call, nil]
      def handler
        @mutex.synchronize { @handler }
      end

      # Dispatches one report. Never raises.
      #
      # @param source [String] short identifier of the callback site
      # @param error  [Object] the value the callback raised
      def report(source, error)
        local = @mutex.synchronize { @handler }

        if local
          begin
            local.call(source, error)
          rescue Exception # rubocop:disable Lint/RescueException
            # A broken handler must not escape into the C stack.
          end
          return
        end

        begin
          detail =
            if error.is_a?(Exception)
              "#{error.class}: #{error.message}"
            else
              error.to_s
            end
          $stderr.write("[LingoFuse] Callback error in #{source}: #{detail}\n")
        rescue Exception # rubocop:disable Lint/RescueException
          # Even stderr may be unavailable in some embeddings.
        end
      end
    end
  end
end