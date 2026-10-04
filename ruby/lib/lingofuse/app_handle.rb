# frozen_string_literal: true
#
# app_handle.rb — RAII wrapper around a native LingoFuse application handle.
#
# ============================================================================
# TWO REGISTRATION PATHS
# ============================================================================
# register_call / register_notify choose a callback mechanism at runtime:
#
#   1. NativeBridge (preferred)
#      Used when the lingofuse_ext C extension is available. Registers a
#      C trampoline whose address is handed to LingoFuse. Supports both
#      LocalCall AND remote callbacks.
#
#   2. Fiddle::Closure (fallback)
#      Used when the extension is not compiled. Only LocalCall /
#      LocalNotify are safe on this path; remote callbacks would
#      deadlock because Fiddle cannot marshal a callback from a native
#      thread into the Ruby interpreter.
#
# The chosen mechanism is recorded per-API in @closures. The stored
# value is either an Integer (NativeBridge ref_addr) or a Fiddle::Closure
# object. unregister and dispose dispatch on the value's class.
#
# ============================================================================
# CALLBACK LIFETIME (CRITICAL)
# ============================================================================
# Fiddle path: the Closure object must be kept alive for as long as the
# native library holds its function pointer. @closures holds them.
#
# NativeBridge path: the C-side CallbackRef is kept alive by CallbackRef's
# own GC registration of the Proc. The Ruby side must retain the ref_addr
# so that unregister / dispose can call free_ref.
#
# ============================================================================
# EXCEPTION ISOLATION
# ============================================================================
# Exceptions raised inside a user callback are caught at the boundary
# (NativeBridge wrapper or Fiddle closure) and routed through
# LingoFuse::CallbackErrorReporter. The same handler installation works
# for both paths.
#
# ============================================================================

require 'fiddle'
require 'thread'

require_relative 'binding'
require_relative 'data_handle'
require_relative 'errors'
require_relative 'callback_error_reporter'
require_relative 'native_bridge'

module LingoFuse
  class AppHandle
    # @return [String] application name passed to the constructor
    attr_reader :name

    # @return [Boolean] true when the NativeBridge path is being used
    def self.native_bridge_available?
      NativeBridge.available?
    end

    def initialize(name, description = '')
      raise ArgumentError, 'AppHandle name must not be nil' if name.nil?

      @name = name.to_s
      @disposed = false
      @closures = {}
      @mutex = Mutex.new

      name_ptr = LingoFuse.cstr_ptr(@name)
      desc_ptr = LingoFuse.cstr_ptr(description.to_s)

      raw = LingoFuse::LF_CreateApp.call(name_ptr, desc_ptr)
      if null_ptr?(raw)
        raise Error, "Failed to create application '#{@name}'."
      end
      @handle = raw
    end

    # @return [Fiddle::Pointer, Integer, nil] raw native pointer
    def raw
      @handle
    end

    # @return [Boolean] true while the handle is valid and not disposed
    def valid?
      !@disposed && !null_ptr?(@handle)
    end

    # ==================================================================
    # API registration
    # ==================================================================

    def register_call(api_name, description = '', &block)
      raise ArgumentError, 'register_call requires a block' unless block

      ensure_not_disposed!
      key = api_name.to_s.downcase

      @mutex.synchronize do
        if @closures.key?(key)
          raise RegistrationError.new(
            "Call API '#{api_name}' is already registered.",
            api_name: api_name.to_s
          )
        end

        stored =
          if NativeBridge.available?
            NativeBridge.register_call(
              @handle, api_name.to_s, description.to_s, &block
            )
          else
            register_via_fiddle(
              :call, api_name.to_s, description.to_s, block
            )
          end

        @closures[key] = stored
      end
      true
    end

    def register_notify(api_name, description = '', &block)
      raise ArgumentError, 'register_notify requires a block' unless block

      ensure_not_disposed!
      key = api_name.to_s.downcase

      @mutex.synchronize do
        if @closures.key?(key)
          raise RegistrationError.new(
            "Notify API '#{api_name}' is already registered.",
            api_name: api_name.to_s
          )
        end

        stored =
          if NativeBridge.available?
            NativeBridge.register_notify(
              @handle, api_name.to_s, description.to_s, &block
            )
          else
            register_via_fiddle(
              :notify, api_name.to_s, description.to_s, block
            )
          end

        @closures[key] = stored
      end
      true
    end

    def unregister(api_name)
      ensure_not_disposed!
      key = api_name.to_s.downcase

      @mutex.synchronize do
        name_ptr = LingoFuse.cstr_ptr(api_name.to_s)
        result = LingoFuse::LF_Unregister.call(@handle, name_ptr)

        if result == 1
          release_closure(@closures.delete(key))
          true
        else
          false
        end
      end
    end

    # ==================================================================
    # Local execution
    # ==================================================================

    def local_call(param)
      raise ArgumentError, 'local_call requires a DataHandle' unless param.is_a?(DataHandle)
      ensure_not_disposed!

      raw = LingoFuse::LF_LocalCall.call(@handle, param.raw)
      if null_ptr?(raw)
        raise CallError.new(
          'LF_LocalCall returned a null handle.',
          target_app: @name
        )
      end
      DataHandle.from_raw(raw, true)
    end

    def local_notify(param)
      raise ArgumentError, 'local_notify requires a DataHandle' unless param.is_a?(DataHandle)
      ensure_not_disposed!

      LingoFuse::LF_LocalNotify.call(@handle, param.raw)
      nil
    end

    # ==================================================================
    # Client binding
    # ==================================================================

    def bind
      ensure_not_disposed!
      LingoFuse::LF_BindApp.call(@handle)
    end

    # ==================================================================
    # Lifetime
    # ==================================================================

    def dispose
      @mutex.synchronize do
        return if @disposed
        @disposed = true

        @closures.each_value { |stored| release_closure(stored) }
        @closures.clear

        handle = @handle
        @handle = nil
        LingoFuse::LF_FreeApp.call(handle) unless null_ptr?(handle)
      end
      nil
    end
    alias close dispose

    # ==================================================================
    # Private
    # ==================================================================

    private

    def null_ptr?(p)
      p.nil? || (p.respond_to?(:to_i) && p.to_i.zero?)
    end

    def ensure_not_disposed!
      return unless @disposed || null_ptr?(@handle)
      raise ObjectDisposedError.new('AppHandle')
    end

    # Frees a stored closure / ref.
    #   - Integer  -> NativeBridge ref_addr
    #   - other    -> Fiddle::Closure; nothing to free, GC handles it
    def release_closure(stored)
      return if stored.nil?
      return unless stored.is_a?(Integer)
      NativeBridge.unregister(stored)
    end

    # Fiddle fallback. Only reached when the C extension is missing.
    def register_via_fiddle(kind, api_name, description, user_block)
      closure =
        if kind == :notify
          build_notify_closure(api_name, user_block)
        else
          build_call_closure(api_name, user_block)
        end

      name_ptr = LingoFuse.cstr_ptr(api_name)
      desc_ptr = LingoFuse.cstr_ptr(description)

      result =
        if kind == :notify
          LingoFuse::LF_RegisterNotify.call(
            @handle, name_ptr, desc_ptr, nil, closure.to_i
          )
        else
          LingoFuse::LF_RegisterCall.call(
            @handle, name_ptr, desc_ptr, nil, closure.to_i
          )
        end

      if result != 1
        raise RegistrationError.new(
          "Failed to register API '#{api_name}'",
          api_name: api_name
        )
      end

      closure
    end

    def build_call_closure(source, user_block)
      Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_trigger, input, output|
        begin
          in_handle  = DataHandle.borrow(input)
          out_handle = DataHandle.borrow(output)
          user_block.call(in_handle, out_handle)
        rescue Exception => e # rubocop:disable Lint/RescueException
          CallbackErrorReporter.report(
            "AppHandle.register_call[#{source}]", e
          )
        end
      end
    end

    def build_notify_closure(source, user_block)
      Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_trigger, input|
        begin
          in_handle = DataHandle.borrow(input)
          user_block.call(in_handle)
        rescue Exception => e # rubocop:disable Lint/RescueException
          CallbackErrorReporter.report(
            "AppHandle.register_notify[#{source}]", e
          )
        end
      end
    end
  end
end