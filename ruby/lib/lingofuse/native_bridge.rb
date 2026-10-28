# frozen_string_literal: true
#
# native_bridge.rb — Ruby wrapper around the lingofuse_ext C extension.

require 'fiddle'

require_relative 'binding'
require_relative 'errors'
require_relative 'data_handle'
require_relative 'callback_error_reporter'

begin
  require_relative '../lingofuse_ext'
  LINGOFUSE_EXT_LOADED = true
rescue LoadError => e
  LINGOFUSE_EXT_LOADED = false
  warn "[LingoFuse::NativeBridge] lingofuse_ext not available: #{e.message}"
  warn '[LingoFuse::NativeBridge] Remote callbacks will not be receivable.'
end

module LingoFuse
  module NativeBridge
    KIND_CALL               = 0
    KIND_NOTIFY             = 1
    KIND_NETWORK_CONNECT    = 2
    KIND_NETWORK_DISCONNECT = 3

    @started = false
    @start_lock = Mutex.new
    @stop_requested = false
    @thread = nil

    @net_connect_ref    = nil
    @net_disconnect_ref = nil

    class << self
      def available?
        return false unless LINGOFUSE_EXT_LOADED

        respond_to?(:create_ref) &&
          respond_to?(:free_ref) &&
          respond_to?(:call_trampoline_addr) &&
          respond_to?(:notify_trampoline_addr) &&
          respond_to?(:network_connect_trampoline_addr) &&
          respond_to?(:network_disconnect_trampoline_addr) &&
          respond_to?(:set_network_refs) &&
          respond_to?(:process_all) &&
          respond_to?(:wait_for_work)
      end

      def start
        return if @started
        raise Error, 'lingofuse_ext is not available' unless available?

        @start_lock.synchronize do
          return if @started
          @started = true
          @stop_requested = false

          @thread = Thread.new do
            if Thread.current.respond_to?(:name=)
              Thread.current.name = 'lingofuse-native-dispatcher'
            end
            loop do
              break if @stop_requested
              begin
                wait_for_work(100)
                break if @stop_requested
                process_all
              rescue StandardError => e
                warn "[NativeBridge] dispatcher error: #{e.class}: #{e.message}"
              end
            end
          end
        end
        nil
      end

      def stop
        @stop_requested = true if defined?(@stop_requested)
        if defined?(@thread) && @thread
          @thread.join(2.0)
          if @thread.alive?
            begin
              @thread.kill
            rescue StandardError
            end
            @thread.join(0.5)
          end
          @thread = nil
        end
        @started = false
        nil
      end

      def register_call(app_handle, api_name, description = '', &block)
        register(app_handle, api_name, description, KIND_CALL, &block)
      end

      def register_notify(app_handle, api_name, description = '', &block)
        register(app_handle, api_name, description, KIND_NOTIFY, &block)
      end

      def register(app_handle, api_name, description, kind, &user_block)
        raise ArgumentError, 'a block is required' unless user_block
        raise Error, 'lingofuse_ext is not available' unless available?

        start

        source_label =
          if kind == KIND_NOTIFY
            "AppHandle.register_notify[#{api_name}]"
          else
            "AppHandle.register_call[#{api_name}]"
          end

        wrapper  = build_wrapper(kind, source_label, user_block)
        ref_addr = create_ref(wrapper, kind)

        trampoline_addr =
          (kind == KIND_NOTIFY) ? notify_trampoline_addr : call_trampoline_addr

        ref_ptr        = Fiddle::Pointer.new(ref_addr)
        trampoline_ptr = Fiddle::Pointer.new(trampoline_addr)

        name_ptr = LingoFuse.cstr_ptr(api_name.to_s)
        desc_ptr = LingoFuse.cstr_ptr(description.to_s)

        result =
          if kind == KIND_NOTIFY
            LingoFuse::LF_RegisterNotify.call(
              app_handle, name_ptr, desc_ptr, ref_ptr, trampoline_ptr
            )
          else
            LingoFuse::LF_RegisterCall.call(
              app_handle, name_ptr, desc_ptr, ref_ptr, trampoline_ptr
            )
          end

        if result != 1
          free_ref(ref_addr)
          raise RegistrationError.new(
            "Failed to register API '#{api_name}'",
            api_name: api_name.to_s
          )
        end

        ref_addr
      end

      def unregister(ref_addr)
        return unless available?
        return if ref_addr.nil?
        free_ref(ref_addr)
        nil
      end

      def install_network_event(on_connect, on_disconnect)
        raise Error, 'lingofuse_ext is not available' unless available?

        start

        uninstall_network_event

        connect_ref    = nil
        disconnect_ref = nil

        connect_ref = create_ref(
          build_network_wrapper(KIND_NETWORK_CONNECT, on_connect),
          KIND_NETWORK_CONNECT
        ) if on_connect

        disconnect_ref = create_ref(
          build_network_wrapper(KIND_NETWORK_DISCONNECT, on_disconnect),
          KIND_NETWORK_DISCONNECT
        ) if on_disconnect

        set_network_refs(connect_ref, disconnect_ref)

        connect_tramp =
          connect_ref ? network_connect_trampoline_addr : 0
        disconnect_tramp =
          disconnect_ref ? network_disconnect_trampoline_addr : 0

        LingoFuse::LF_Set_Network_Event.call(connect_tramp, disconnect_tramp)

        @net_connect_ref    = connect_ref
        @net_disconnect_ref = disconnect_ref
        nil
      end

      def uninstall_network_event
        return unless available?

        LingoFuse::LF_Set_Network_Event.call(0, 0)

        set_network_refs(nil, nil)

        free_ref(@net_connect_ref)    if @net_connect_ref
        free_ref(@net_disconnect_ref) if @net_disconnect_ref
        @net_connect_ref    = nil
        @net_disconnect_ref = nil
        nil
      end

      def network_event_installed?
        !@net_connect_ref.nil? || !@net_disconnect_ref.nil?
      end

      private

      def build_wrapper(kind, source_label, user_block)
        if kind == KIND_NOTIFY
          lambda do |input_addr|
            input = DataHandle.borrow(
              Fiddle::Pointer.new(Integer(input_addr))
            )
            begin
              user_block.call(input)
            rescue Exception => e
              CallbackErrorReporter.report(source_label, e)
            end
          end
        else
          lambda do |input_addr, output_addr|
            input  = DataHandle.borrow(
              Fiddle::Pointer.new(Integer(input_addr))
            )
            output = DataHandle.borrow(
              Fiddle::Pointer.new(Integer(output_addr))
            )
            begin
              user_block.call(input, output)
            rescue Exception => e
              CallbackErrorReporter.report(source_label, e)
            end
          end
        end
      end

      def build_network_wrapper(kind, user_block)
        label =
          if kind == KIND_NETWORK_CONNECT
            'NetworkEvents.connect'
          else
            'NetworkEvents.disconnect'
          end

        lambda do |addr|
          begin
            user_block.call(addr)
          rescue Exception => e
            CallbackErrorReporter.report(label, e)
          end
        end
      end
    end
  end
end