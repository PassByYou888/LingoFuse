# frozen_string_literal: true
#
# status.rb — Status queue and health checks for the LingoFuse runtime.
#
# Uses Fiddle (not FFI). Every native call goes through a
# Fiddle::Function created in binding.rb.
#
# Status queue: bounded FIFO of up to 1000 messages, processed by the
# simulated main thread. Before Framework.prepare_done, the queue may be
# empty or stale. post_status queues the message even when the main
# thread is not yet running.
#
# LF_GetStatus returns a pointer into a process-wide static buffer that
# the next call overwrites; this wrapper copies the string immediately.
#

require 'fiddle'

require_relative 'binding'
require_relative 'errors'

module LingoFuse
  module Status
    class << self
      def get_status_count
        LingoFuse::LF_GetStatusCount.call
      end

      def get_status
        ptr = LingoFuse::LF_GetStatus.call
        LingoFuse.read_cstr(ptr)
      end

      def drain_status(max_messages = 64)
        m = Integer(max_messages)
        return [] if m.zero?
        raise ArgumentError, 'max_messages must be non-negative' if m.negative?

        pending = get_status_count
        return [] if pending <= 0

        count = [pending, m].min
        messages = []
        count.times do
          msg = get_status
          break if msg.empty?
          messages << msg
        end
        messages
      end

      def post_status(message)
        ptr = LingoFuse.cstr_ptr(message)
        LingoFuse::LF_PostStatus.call(ptr)
        nil
      end

      def check_main_thread
        LingoFuse::LF_CheckMainThread.call != 0
      end

      def check_app(app_name)
        ptr = LingoFuse.cstr_ptr(app_name)
        LingoFuse::LF_CheckApp.call(ptr) != 0
      end

      def check_api(app_name, api_name)
        app_ptr = LingoFuse.cstr_ptr(app_name)
        api_ptr = LingoFuse.cstr_ptr(api_name)
        LingoFuse::LF_CheckApi.call(app_ptr, api_ptr) != 0
      end
    end
  end
end