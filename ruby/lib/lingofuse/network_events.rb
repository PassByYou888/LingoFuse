# frozen_string_literal: true
#
# network_events.rb — Process-global connect / disconnect event handlers.
#
# ============================================================================
# TWO BACKENDS
# ============================================================================
# Like AppHandle, this module prefers the C extension and falls back to
# Fiddle when the extension is missing.
#
#   NativeBridge (preferred)
#     The extension holds a pair of process-wide CallbackRefs and
#     exposes two trampolines. Remote callbacks arrive on native worker
#     threads, are queued by the extension, and are dispatched on the
#     Ruby dispatcher thread. Safe.
#
#   Fiddle (fallback)
#     Closures are built directly and passed to LF_Set_Network_Event.
#     The callback fires on a native worker thread, and Fiddle's
#     re-entry into the Ruby VM will deadlock the process.
#     The fallback is retained only so that the module loads on a
#     machine without the extension; it is NOT safe for real network
#     events.
#
# ============================================================================
# SEMANTICS
# ============================================================================
# "Connect"    fires the FIRST time a client receives a service API-info
#              broadcast. Not the TCP handshake.
# "Disconnect" fires once per physical link loss.
#
# ============================================================================
# REPLACE SEMANTICS
# ============================================================================
# set is a REPLACE operation. Calling it again discards any previously
# installed handlers, even those whose argument is nil in the new call.
#
# ============================================================================

require 'fiddle'
require 'thread'

require_relative 'binding'
require_relative 'errors'
require_relative 'callback_error_reporter'
require_relative 'native_bridge'

module LingoFuse
  module NetworkEvents
    @connect_closure    = nil
    @disconnect_closure = nil
    @user_connect       = nil
    @user_disconnect    = nil
    @mutex              = Mutex.new

    class << self
      def set(on_connect: nil, on_disconnect: nil)
        unless on_connect.nil? || on_connect.respond_to?(:call)
          raise ArgumentError, 'on_connect must respond to #call or be nil'
        end
        unless on_disconnect.nil? || on_disconnect.respond_to?(:call)
          raise ArgumentError, 'on_disconnect must respond to #call or be nil'
        end

        if NativeBridge.available?
          set_via_native(on_connect, on_disconnect)
        else
          set_via_fiddle(on_connect, on_disconnect)
        end
      end

      def clear
        if NativeBridge.available?
          @mutex.synchronize do
            NativeBridge.uninstall_network_event
            @user_connect    = nil
            @user_disconnect = nil
          end
        else
          @mutex.synchronize do
            LingoFuse::LF_Set_Network_Event.call(0, 0)
            @connect_closure    = nil
            @disconnect_closure = nil
            @user_connect       = nil
            @user_disconnect    = nil
          end
        end
        nil
      end

      def installed?
        if NativeBridge.available?
          @mutex.synchronize { NativeBridge.network_event_installed? }
        else
          @mutex.synchronize do
            !@connect_closure.nil? || !@disconnect_closure.nil?
          end
        end
      end

      def set_listener(listener)
        if listener.nil?
          clear
          return
        end
        unless listener.is_a?(NetworkEventListener)
          raise ArgumentError,
                'listener must be a LingoFuse::NetworkEventListener or nil'
        end

        set(
          on_connect:    ->(addr) { listener.on_connect(addr) },
          on_disconnect: ->(addr) { listener.on_disconnect(addr) }
        )
      end

      private

      def set_via_native(on_connect, on_disconnect)
        @mutex.synchronize do
          NativeBridge.install_network_event(on_connect, on_disconnect)
          @user_connect    = on_connect
          @user_disconnect = on_disconnect
        end
        nil
      end

      def set_via_fiddle(on_connect, on_disconnect)
        @mutex.synchronize do
          new_connect =
            on_connect.nil? ? nil : build_closure('connect', on_connect)
          new_disconnect =
            on_disconnect.nil? ? nil : build_closure('disconnect', on_disconnect)

          connect_ptr    = new_connect&.to_i || 0
          disconnect_ptr = new_disconnect&.to_i || 0

          LingoFuse::LF_Set_Network_Event.call(connect_ptr, disconnect_ptr)

          @connect_closure    = new_connect
          @disconnect_closure = new_disconnect
          @user_connect       = on_connect
          @user_disconnect    = on_disconnect
        end
        nil
      end

      def build_closure(source, user_callable)
        Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP]
        ) do |addr|
          begin
            endpoint = LingoFuse.read_cstr(addr)
            user_callable.call(endpoint)
          rescue Exception => e # rubocop:disable Lint/RescueException
            CallbackErrorReporter.report("NetworkEvents.#{source}", e)
          end
        end
      end
    end
  end

  # ========================================================================
  # NetworkEventListener
  # ========================================================================

  class NetworkEventListener
    def on_connect(_addr); end
    def on_disconnect(_addr); end
  end

  # ========================================================================
  # NetworkEventQueue
  # ========================================================================

  class NetworkEventQueue
    DEFAULT_MAX_SIZE = 10_000

    @global_instance = nil
    @global_mutex = Mutex.new

    class << self
      def global_instance
        @global_mutex.synchronize do
          @global_instance ||= new
        end
      end
    end

    def initialize(max_size: nil)
      size = max_size.nil? ? DEFAULT_MAX_SIZE : Integer(max_size)
      raise ArgumentError, 'max_size must be positive' if size <= 0

      @queue = Queue.new
      @max_size = size
      @installed = false
      @lock = Mutex.new
    end

    def install
      @lock.synchronize do
        return if @installed

        if NetworkEvents.installed?
          warn '[LingoFuse] NetworkEventQueue#install is overwriting a ' \
               'previously installed network event callback.'
        end

        NetworkEvents.set(
          on_connect:    ->(addr) { enqueue(:connect, addr) },
          on_disconnect: ->(addr) { enqueue(:disconnect, addr) }
        )
        @installed = true
      end
      nil
    end

    def uninstall
      @lock.synchronize do
        return unless @installed
        NetworkEvents.clear
        @installed = false
      end
      nil
    end

    def get(timeout: nil)
      if timeout.nil?
        @queue.pop
      else
        begin
          @queue.pop(true)
        rescue ThreadError
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
          loop do
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise ThreadError, 'queue empty' if remaining <= 0
            begin
              return @queue.pop(true)
            rescue ThreadError
              sleep([remaining, 0.01].min)
            end
          end
        end
      end
    end

    def empty?; @queue.empty?; end
    def size; @queue.size; end

    def clear
      @queue.clear
      nil
    end

    private

    def enqueue(type, addr)
      sleep(0.005) while @queue.size >= @max_size
      @queue.push([type, addr])
    rescue StandardError
      CallbackErrorReporter.report("NetworkEventQueue##{type}", $!)
    end
  end
end