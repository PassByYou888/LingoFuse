# frozen_string_literal: true
#
# p2p_registration.rb — Process-wide P2P API registration.
#
# ============================================================================
# WHY THIS FILE EXISTS
# ============================================================================
# LingoFuse supports TWO independent registration namespaces:
#
#   1. APP-BOUND (AppHandle#register_call / #register_notify):
#        * APIs are owned by a specific AppHandle.
#        * Reachable via App-name addressing (and via UID addressing).
#        * Lifetime is tied to the AppHandle: freeing the app detaches
#          its APIs from the mesh.
#
#   2. PROCESS-WIDE P2P (this file):
#        * APIs are owned by the process, not by any AppHandle.
#        * Reachable ONLY via UID addressing or P2PName addressing.
#          NOT reachable via App-name addressing, even if a registered
#          name happens to match an App name.
#        * Lifetime extends to the process: the APIs survive until
#          LF_Shutdown is called. They are NOT affected by
#          AppHandle#dispose.
#
# The two namespaces are orthogonal. A process can host App-bound APIs,
# process-wide P2P APIs, or both simultaneously.
#
# Typical use of the process-wide namespace: globally-discoverable
# utility APIs (health probes, capability discovery, identity echo,
# etc.) that any client in the mesh can call by UID or by P2PName
# without requiring the caller to know the target App name.
#
# ============================================================================
# REGISTRY LIFETIME
# ============================================================================
# The C extension's create_ref returns an Integer address that must be
# kept alive for as long as LingoFuse might invoke the callback. The C
# side holds only a raw function-pointer plus this trigger pointer; it
# does NOT hold a Ruby reference.
#
# This file therefore keeps a module-level Hash mapping
#   api_name (String) => ref_addr (Integer)
# for every currently registered P2P API. The Hash is guarded by a
# mutex. unregister(name) removes the entry and calls free_ref on the
# address; no other code path releases a P2P ref.
#
# ============================================================================
# DISPATCHER LIFECYCLE (IMPORTANT)
# ============================================================================
# P2P registration and App-level registration share the SAME native
# dispatcher thread, which is started by LingoFuse::NativeBridge.start.
# The App-level path (NativeBridge.register) already starts it; the P2P
# path must do the same, otherwise a process that ONLY registers P2P
# APIs (and never registers an App-level API) would leave the dispatcher
# unstarted. In that case, every remote callback would be enqueued by
# the C trampoline and never dequeued by Ruby, producing a silent hang
# on the caller side.
#
# register_api therefore:
#   1. Verifies lingofuse_ext is available (same guard as the App path),
#      so the error message is actionable when the extension is missing.
#   2. Calls NativeBridge.start before create_ref, so the dispatcher
#      thread is running by the time the C side can fire a callback.
#
# start is idempotent (guarded by @start_lock in native_bridge.rb), so
# concurrent registrations from multiple threads are safe.
#
# ============================================================================
# CALLBACK SIGNATURES
# ============================================================================
# Call    : block { |input, output| ... }  — both are DataHandle objects
# Notify  : block { |input| ... }          — input is a DataHandle
#
# Both input and output are BORROWED handles: they are owned by the
# framework and MUST NOT be disposed by the callback. They are valid
# ONLY for the duration of the callback invocation.
#
# Exceptions raised inside a callback are caught and forwarded to
# LingoFuse::CallbackErrorReporter. They never propagate into the C
# stack.
#
# ============================================================================
# THREAD SAFETY
# ============================================================================
# Registration / unregistration is thread-safe (guarded by @mutex).
# Callbacks run on the Ruby dispatcher thread (see
# lib/lingofuse/native_bridge.rb); they do NOT run on the caller
# thread and do NOT run on the C worker thread.
#
# All comments and messages are in English.
# ============================================================================

require 'fiddle'

require_relative 'errors'
require_relative 'data_handle'
require_relative 'callback_error_reporter'
require_relative 'native_bridge'

module LingoFuse
  module P2PRegistration
    # -------------------------------------------------------------------
    # Callback kinds
    # -------------------------------------------------------------------
    # These MUST match LF_KIND_CALL / LF_KIND_NOTIFY in lingofuse_ext.c.
    # They are redefined here (rather than referenced from NativeBridge)
    # so that this file remains self-contained and does not depend on
    # the exact set of constants NativeBridge chooses to expose.
    KIND_CALL   = 0
    KIND_NOTIFY = 1

    # -------------------------------------------------------------------
    # Module-level registry
    # -------------------------------------------------------------------
    @registry = {}
    @mutex    = Mutex.new

    class << self
      # -----------------------------------------------------------------
      # Registration
      # -----------------------------------------------------------------

      # Register a process-wide P2P Call API.
      #
      # The API becomes reachable via UID addressing or P2PName
      # addressing from any client in the mesh, without requiring the
      # caller to know this process's App name.
      #
      # @param name        [String] unique API name in the P2P namespace
      # @param description [String] human-readable description
      # @yield             callback receiving (input, output) DataHandles
      # @return            [true]
      # @raise [ArgumentError]      if no block is given
      # @raise [Error]              if lingofuse_ext is not available
      # @raise [RegistrationError]  if the name is already registered,
      #                             or if the native layer rejects it
      def register_call(name, description = '', &block)
        register_api(KIND_CALL, name, description, &block)
      end

      # Register a process-wide P2P Notify API.
      #
      # Same reachability and lifetime as register_call; the callback
      # receives only the input handle and produces no response.
      #
      # @yield callback receiving (input) DataHandle
      def register_notify(name, description = '', &block)
        register_api(KIND_NOTIFY, name, description, &block)
      end

      # Remove a previously registered P2P API by name.
      #
      # The removal is immediate locally. Remote peers may still see
      # the API for up to ~3 seconds until the network broadcast
      # propagates.
      #
      # @param name [String] API name
      # @return     [Boolean] true if the API was found and removed
      def unregister(name)
        return false if name.nil?
        key = name.to_s

        ref_addr = @mutex.synchronize { @registry.delete(key) }
        return false if ref_addr.nil?

        result = LingoFuse::Native.lf_unregister_p2p(key)
        LingoFuse::NativeBridge.free_ref(ref_addr)
        result == 1
      rescue StandardError => e
        CallbackErrorReporter.report(
          "P2PRegistration.unregister[#{key}]",
          e
        )
        false
      end

      # -----------------------------------------------------------------
      # Queries
      # -----------------------------------------------------------------

      # Return true if an API with the given name is currently
      # registered in the P2P namespace of this process.
      def registered?(name)
        return false if name.nil?
        @mutex.synchronize { @registry.key?(name.to_s) }
      end

      # Return the names of every currently registered P2P API in this
      # process. The returned Array is a snapshot.
      def registered_names
        @mutex.synchronize { @registry.keys.dup }
      end

      # -----------------------------------------------------------------
      # Internals (private)
      # -----------------------------------------------------------------

      private

      def register_api(kind, name, description, &user_block)
        raise ArgumentError, 'a block is required' if user_block.nil?
        raise ArgumentError, 'name must not be nil'   if name.nil?

        key = name.to_s

        # Reject a duplicate before touching the native layer. The
        # native layer would reject it too, but doing the check here
        # avoids allocating a CallbackRef that would need to be freed
        # immediately on a known-bad path.
        if @mutex.synchronize { @registry.key?(key) }
          raise RegistrationError.new(
            "P2P API '#{name}' is already registered",
            api_name: key
          )
        end

        # Mirror NativeBridge.register (the App-level equivalent) so
        # that the failure mode is identical and the error message is
        # actionable when the C extension is missing.
        unless LingoFuse::NativeBridge.available?
          raise Error, 'lingofuse_ext is not available'
        end

        # Ensure the shared dispatcher thread is running before we
        # hand the C extension a callback ref. Without this, a process
        # that only registers P2P APIs would never start the
        # dispatcher; every remote callback would be enqueued by the
        # C trampoline and never dequeued by Ruby.
        #
        # start is idempotent (guarded by @start_lock in
        # native_bridge.rb), so concurrent registrations are safe.
        LingoFuse::NativeBridge.start

        wrapper         = build_wrapper(kind, key, user_block)
        ref_addr        = LingoFuse::NativeBridge.create_ref(wrapper, kind)
        trampoline_addr = trampoline_for(kind)

        result = dispatch_register(kind, key, description.to_s, ref_addr, trampoline_addr)

        if result != 1
          LingoFuse::NativeBridge.free_ref(ref_addr)
          raise RegistrationError.new(
            "Failed to register P2P #{kind_label(kind)} API '#{name}'",
            api_name: key
          )
        end

        # Store the ref so that unregister can free it later. If a
        # concurrent thread registered the same name between our
        # earlier check and now, our native registration would have
        # already failed (the native layer rejects duplicates), so this
        # branch is defensive only.
        stored = @mutex.synchronize do
          if @registry.key?(key)
            false
          else
            @registry[key] = ref_addr
            true
          end
        end

        unless stored
          LingoFuse::Native.lf_unregister_p2p(key)
          LingoFuse::NativeBridge.free_ref(ref_addr)
          raise RegistrationError.new(
            "P2P API '#{name}' is already registered",
            api_name: key
          )
        end

        true
      end

      def dispatch_register(kind, name, description, ref_addr, trampoline_addr)
        if kind == KIND_NOTIFY
          LingoFuse::Native.lf_register_p2p_notify(
            name, description, ref_addr, trampoline_addr
          )
        else
          LingoFuse::Native.lf_register_p2p_call(
            name, description, ref_addr, trampoline_addr
          )
        end
      end

      def trampoline_for(kind)
        if kind == KIND_NOTIFY
          LingoFuse::NativeBridge.notify_trampoline_addr
        else
          LingoFuse::NativeBridge.call_trampoline_addr
        end
      end

      def kind_label(kind)
        kind == KIND_NOTIFY ? 'Notify' : 'Call'
      end

      # -----------------------------------------------------------------
      # Wrapper construction
      # -----------------------------------------------------------------
      # The wrapper matches the shape used by NativeBridge for
      # App-level registration:
      #
      #   * The trampoline passes the input / output handles as Integer
      #     addresses.
      #   * The wrapper converts each to a DataHandle (borrowed, not
      #     owned) so that the user block receives a convenient object.
      #   * The user block's exceptions are caught and routed to
      #     CallbackErrorReporter, so they never reach the C stack.
      #
      # The Fiddle::Pointer.new(Integer(addr)) construction mirrors
      # native_bridge.rb exactly. If the handle class ever switches to
      # accepting Integer directly, both files must change together.
      def build_wrapper(kind, source, user_block)
        if kind == KIND_NOTIFY
          lambda do |input_addr|
            input = borrow_handle(input_addr)
            begin
              user_block.call(input)
            rescue Exception => e # rubocop:disable Lint/RescueException
              CallbackErrorReporter.report(
                "P2PRegistration.notify[#{source}]", e
              )
            end
          end
        else
          lambda do |input_addr, output_addr|
            input  = borrow_handle(input_addr)
            output = borrow_handle(output_addr)
            begin
              user_block.call(input, output)
            rescue Exception => e # rubocop:disable Lint/RescueException
              CallbackErrorReporter.report(
                "P2PRegistration.call[#{source}]", e
              )
            end
          end
        end
      end

      def borrow_handle(addr)
        return nil if addr.nil?
        DataHandle.borrow(Fiddle::Pointer.new(Integer(addr)))
      end
    end
  end

  # --------------------------------------------------------------------
  # Top-level aliases
  # --------------------------------------------------------------------
  # Provide LingoFuse.register_p2p_call / register_p2p_notify /
  # unregister_p2p so callers can register P2P APIs without spelling
  # out the intermediate module.

  class << self
    def register_p2p_call(name, description = '', &block)
      P2PRegistration.register_call(name, description, &block)
    end

    def register_p2p_notify(name, description = '', &block)
      P2PRegistration.register_notify(name, description, &block)
    end

    def unregister_p2p(name)
      P2PRegistration.unregister(name)
    end
  end
end