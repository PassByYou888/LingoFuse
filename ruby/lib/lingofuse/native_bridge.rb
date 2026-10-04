# frozen_string_literal: true
#
# native_bridge.rb — Ruby wrapper around the lingofuse_ext C extension.
#
# ============================================================================
# PURPOSE
# ============================================================================
# Ruby-side half of the native bridge:
#
#   1. Loads the lingofuse_ext C extension.
#   2. Starts and owns the dispatcher thread.
#   3. Provides register / unregister primitives for Call / Notify APIs
#      and for the process-wide network event handlers.
#
# ============================================================================
# CALLBACK KINDS (must match the C constants)
# ============================================================================
#   0 = Call
#   1 = Notify
#   2 = Network connect
#   3 = Network disconnect
#
# ============================================================================
# EXCEPTION ROUTING
# ============================================================================
# Call / Notify wrappers catch exceptions and forward them to
# CallbackErrorReporter, making the NativeBridge path behave identically
# to the Fiddle fallback from the user's point of view.
#
# Network event wrappers do the same.
#
# ============================================================================
# REF OWNERSHIP
# ============================================================================
# `register*` returns an opaque Integer `ref_addr`. The CALLER owns that
# value and must pass it back to `unregister` when the API is removed.
# This module keeps no global registry of API refs.
#
# Network event refs are the exception: they live in C-side globals
# because LF_Set_Network_Event has no `trigger` argument. This module
# therefore keeps one pair of refs for the process.
#
# ============================================================================

require 'fiddle'

require_relative 'binding'
require_relative 'errors'
require_relative 'data_handle'
require_relative 'callback_error_reporter'

begin
  require 'lingofuse_ext'
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

      # Idempotent. Spawns the dispatcher thread on first call.
      def start
        return if @started
        raise Error, 'lingofuse_ext is not available' unless available?

        @start_lock.synchronize do
          return if @started
          @started = true

          Thread.new do
            if Thread.current.respond_to?(:name=)
              Thread.current.name = 'lingofuse-native-dispatcher'
            end
            loop do
              begin
                wait_for_work(100)
                process_all
              rescue StandardError => e
                warn "[NativeBridge] dispatcher error: #{e.class}: #{e.message}"
              end
            end
          end
        end
      end

      # -----------------------------------------------------------------
      # Call / Notify registration
      # -----------------------------------------------------------------

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

      # -----------------------------------------------------------------
      # Network event registration
      # -----------------------------------------------------------------
      #
      # LF_Set_Network_Event has no `trigger` argument, so the extension
      # holds the process-wide refs in C globals. This method:
      #
      #   1. Frees any previous refs.
      #   2. Installs the new refs into the C globals.
      #   3. Calls LF_Set_Network_Event with the corresponding trampoline
      #      addresses (or 0 to disable a slot).
      #
      # Passing nil for both handlers uninstalls everything.

      def install_network_event(on_connect, on_disconnect)
        raise Error, 'lingofuse_ext is not available' unless available?

        start

        # Uninstall first, so the native side cannot fire through a ref
        # we are about to free.
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

        # Publish the refs to the C side before registering the
        # trampolines with LingoFuse; otherwise a callback could fire
        # between LF_Set_Network_Event and the ref assignment.
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

        # Tell LingoFuse to stop calling the trampolines first.
        LingoFuse::LF_Set_Network_Event.call(0, 0)

        # Then clear the C-side globals.
        set_network_refs(nil, nil)

        # Finally release the Ruby-side refs.
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

      # -----------------------------------------------------------------
      # Wrapper construction
      # -----------------------------------------------------------------

      def build_wrapper(kind, source_label, user_block)
        if kind == KIND_NOTIFY
          lambda do |input_addr|
            input = DataHandle.borrow(
              Fiddle::Pointer.new(Integer(input_addr))
            )
            begin
              user_block.call(input)
            rescue Exception => e # rubocop:disable Lint/RescueException
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
            rescue Exception => e # rubocop:disable Lint/RescueException
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
          rescue Exception => e # rubocop:disable Lint/RescueException
            CallbackErrorReporter.report(label, e)
          end
        end
      end
    end
  end
end