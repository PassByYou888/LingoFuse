# frozen_string_literal: true
#
# address.rb — The three addressing modes for LingoFuse remote calls.
#
# ============================================================================
# WHY THIS FILE EXISTS
# ============================================================================
# LingoFuse's C ABI supports three orthogonal addressing modes for remote
# invocation:
#
#     AppTarget      — address a logical App by its name.
#     UIDTarget      — address a specific session by its 32-byte UID.
#     P2PNameTarget  — address a group of clients sharing a P2P group name.
#
# All three share the same call shapes. This file defines the shared
# surface once and implements only the addressing-specific hooks in each
# subclass. Callers therefore write the same call code regardless of
# which mode they are using.
#
# ============================================================================
# ROUTING SEMANTICS
# ============================================================================
#
#     Target          Routing key        Local-first?    Load-balanced?
#     ------------    ----------------   ------------    --------------
#     AppTarget       App name (String)  YES             N/A
#     UIDTarget       UID (32 bytes)     YES             N/A
#     P2PNameTarget   Group name (Str)   NO              YES (server side)
#
# "Local-first" means: if the caller process itself hosts a matching
# App / client for the addressing key, the call is serviced locally
# without touching the network.
#
# P2PName deliberately opts out of local-first routing: the server-side
# dispatcher owns the load-balancing state, and short-cutting locally
# would defeat it.
#
# ============================================================================
# UID ARGUMENTS
# ============================================================================
# A UID may be supplied as:
#
#   * a 32-byte Ruby String (binary), or
#   * a 64-character hexadecimal String.
#
# The wrapper normalises both forms to a 32-byte binary String before
# passing it to the C extension.
#
# {!!!!!  UID IS NOT SIDE DATA HERE  !!!!!}
# The UID passed to a UIDTarget is an ARGUMENT VALUE the caller already
# possesses — typically the result of a prior "whoami" probe. It is
# distinct from the SIDE DATA that a receiver reads from a callback's
# INPUT handle via DataHandle#get_p2p_uid. Both are 32-byte values of
# the same wire type, but they come from two different sources:
#
#   UIDTarget(uid).call(...)             — I know the peer's UID.
#   inp.get_p2p_uid                      — I received a request; this
#                                          is who sent it.
#
# ============================================================================
# PAYLOAD SERIALIZATION
# ============================================================================
# Payloads are serialized with LingoFuse::LfIo.dumps_json and
# deserialized with LingoFuse::LfIo.loads_json. This is the same
# toolchain-wide policy used elsewhere:
#
#   * compact JSON,
#   * ensure_ascii: false (literal UTF-8 for non-ASCII),
#   * a trailing NUL is NOT appended to the business payload — the
#     Pascal side frames the wire envelope itself.
#
# ============================================================================
# CALLBACK LIFETIME (ASYNC PATH)
# ============================================================================
# The result handle delivered to a callback is OWNED BY THE FRAMEWORK
# and is released IMMEDIATELY after the callback returns. The Ruby proc
# installed by call_future reads the handle and copies everything it
# needs before returning. See lib/lingofuse/async_support.rb for the
# full lifetime contract.
#
# ============================================================================
# THREAD SAFETY
# ============================================================================
# Target instances are immutable after construction and can be shared
# across threads. A single Target instance does NOT serialize concurrent
# calls: two threads calling target.call(...) issue two independent
# requests. The underlying C library serializes them internally per
# connection.
#
# The call_future method is safe to call from any thread and from any
# Fiber. The returned CallFuture is thread-safe.
#
# All comments and messages are in English.
# ============================================================================

require_relative 'errors'
require_relative 'data_handle'
require_relative 'lf_io'
require_relative 'async_support'

module LingoFuse
  module Address
    #: Default per-call timeout, in milliseconds, used when the caller
    #: does not supply one. Matches the historical default used by the
    #: Python binding and the C++ wrapper.
    DEFAULT_TIMEOUT_MS = 5000

    # ==================================================================
    # Target — abstract base class
    # ==================================================================
    #
    # Concrete subclasses (AppTarget / UIDTarget / P2PNameTarget) implement
    # four hooks, one per underlying C ABI function family:
    #
    #   _native_call              — synchronous Call
    #   _native_async_call        — asynchronous Call
    #   _native_notify            — one-way Notify
    #   _native_sequenced_notify  — one-way FIFO Notify
    #
    # Every other method — call / call_future / notify / sequenced_notify —
    # is defined ONCE here and reused by every subclass. This keeps the
    # addressing semantics orthogonal to the call-shape semantics.
    class Target
      attr_reader :default_timeout_ms

      def initialize(default_timeout_ms: DEFAULT_TIMEOUT_MS)
        @default_timeout_ms = Integer(default_timeout_ms)
        if @default_timeout_ms.negative?
          raise ArgumentError,
                'default_timeout_ms must be non-negative'
        end
      end

      # -----------------------------------------------------------------
      # Public call shapes
      # -----------------------------------------------------------------

      # Synchronous request/response. Blocks until the result arrives or
      # the timeout expires. Returns the deserialized payload, or nil
      # if the peer returned an empty body.
      #
      # Raises:
      #   LingoFuse::CallError   — the native layer returned a null
      #                            handle (fundamental transport error).
      #   LingoFuse::TimeoutError — the call did not complete within
      #                            the timeout window. Note: the C
      #                            library returns a size-0 handle on
      #                            timeout rather than raising; this
      #                            wrapper converts that into a
      #                            TimeoutError.
      def call(api_name, payload = nil, timeout_ms: nil)
        timeout_ms = timeout_ms || @default_timeout_ms

        with_param_handle(api_name, payload) do |raw|
          result_raw = _native_call(api_name.to_s, raw, timeout_ms)
          return decode_sync_result(api_name, result_raw)
        end
      end

      # Asynchronous request/response. Returns a CallFuture that resolves
      # with the deserialized payload. Never blocks the calling thread.
      #
      # The C ABI encodes the payload synchronously inside the call, so
      # the parameter handle is released before this method returns.
      def call_future(api_name, payload = nil, timeout_ms: nil)
        timeout_ms = timeout_ms || @default_timeout_ms

        with_param_handle(api_name, payload) do |raw|
          trampoline = LingoFuse::NativeBridge.async_call_trampoline_addr
          issue = lambda do |ref_addr|
            _native_async_call(api_name.to_s, raw, ref_addr, trampoline)
          end
          return LingoFuse::AsyncSupport.run_async_with_future(
            issue_fn: issue,
            deserialize: method(:decode_result_from_addr),
            timeout_ms: timeout_ms
          )
        end
      end

      # One-way notification. Returns immediately. No delivery or
      # ordering guarantee.
      def notify(api_name, payload = nil)
        with_param_handle(api_name, payload) do |raw|
          _native_notify(api_name.to_s, raw)
        end
        nil
      end

      # One-way notification with FIFO ordering per (target_key, api)
      # pair. Returns immediately.
      def sequenced_notify(api_name, payload = nil)
        with_param_handle(api_name, payload) do |raw|
          _native_sequenced_notify(api_name.to_s, raw)
        end
        nil
      end

      # -----------------------------------------------------------------
      # Subclass hooks
      # -----------------------------------------------------------------
      # Each hook receives an Integer handle (the raw address of a
      # TDataHnd) and must forward it to the corresponding LingoFuse C
      # ABI function for this addressing mode.
      #
      # The base class provides no implementation: a subclass that
      # forgets a hook fails loudly at call time with NotImplementedError.

      def _native_call(_api_name, _param_raw, _timeout_ms)
        raise NotImplementedError,
              "#{self.class.name} must implement #_native_call"
      end

      def _native_async_call(_api_name, _param_raw, _ref_addr, _trampoline_addr)
        raise NotImplementedError,
              "#{self.class.name} must implement #_native_async_call"
      end

      def _native_notify(_api_name, _param_raw)
        raise NotImplementedError,
              "#{self.class.name} must implement #_native_notify"
      end

      def _native_sequenced_notify(_api_name, _param_raw)
        raise NotImplementedError,
              "#{self.class.name} must implement #_native_sequenced_notify"
      end

      # -----------------------------------------------------------------
      # Diagnostics
      # -----------------------------------------------------------------

      # Short human-readable description of this target, used in
      # exception messages. Subclasses override to include their key.
      def describe
        self.class.name
      end

      private

      # -----------------------------------------------------------------
      # Handle lifecycle
      # -----------------------------------------------------------------

      def with_param_handle(api_name, payload)
        hnd = LingoFuse::DataHandle.new(api_name.to_s)
        begin
          if payload != nil
            bytes = LingoFuse::LfIo.dumps_json(payload)
            unless bytes.empty?
              hnd.write_bytes(bytes)
            end
          end
          yield(handle_addr(hnd))
        ensure
          hnd.dispose
        end
      end

      # Normalise a DataHandle's raw value into an Integer address.
      #
      # DataHandle#raw returns one of:
      #   * Integer        (when the handle was created through the C
      #                     extension's LingoFuse::Native.lf_create_data)
      #   * Fiddle::Pointer (when the handle was created through the
      #                     older Fiddle-based path)
      #   * nil            (already disposed)
      #
      # The C extension's wrapper functions expect an Integer. The
      # Fiddle path accepts either. Converting to Integer here makes
      # both paths work without further branching.
      def handle_addr(hnd)
        r = hnd.raw
        return nil if r.nil?
        r.respond_to?(:to_i) ? r.to_i : r
      end

      # -----------------------------------------------------------------
      # Result decoding
      # -----------------------------------------------------------------

      # Decode a result handle returned by a SYNCHRONOUS call. The
      # caller OWNS this handle and must free it.
      def decode_sync_result(api_name, result_raw)
        if result_raw.nil? || result_raw == 0
          raise LingoFuse::CallError.new(
            "Call to '#{api_name}' on #{describe} returned a null handle",
            target_app: describe
          )
        end

        owned = LingoFuse::DataHandle.from_raw(result_raw, true)
        begin
          bytes = owned.read_all_bytes
          # A zero-size result means the call timed out or the target
          # was unreachable. The C ABI reports this as an empty handle,
          # never as a null pointer; we surface it as TimeoutError.
          raise LingoFuse::TimeoutError.new(
            "Call to '#{api_name}' on #{describe} returned an empty result " \
            "(timeout or unreachable target)"
          ) if bytes.empty?

          bytes_to_object(bytes)
        ensure
          owned.dispose
        end
      end

      # Decode a result handle delivered to an ASYNC callback. The
      # framework owns this handle; the callback MUST NOT free it. This
      # method therefore borrows the handle, reads everything it needs,
      # and lets the framework release it when the callback returns.
      def decode_result_from_addr(result_addr)
        return nil if result_addr.nil?

        view = LingoFuse::DataHandle.borrow(result_addr)
        view.position = 0
        bytes = view.read_all_bytes
        return nil if bytes.empty?

        bytes_to_object(bytes)
      end

      # Convert a raw binary payload into a Ruby object via the
      # toolchain-wide JSON policy.
      def bytes_to_object(bytes)
        return nil if bytes.nil? || bytes.empty?
        text = bytes.encoding == Encoding::UTF_8 ? bytes : bytes.dup.force_encoding(Encoding::UTF_8)
        LingoFuse::LfIo.loads_json(text)
      end
    end

    # ==================================================================
    # AppTarget
    # ==================================================================
    #
    # Addresses a logical App by its name.
    #
    # Routing is LOCAL-FIRST: if the caller process itself hosts an App
    # with the matching name and the requested API, the call is serviced
    # locally without touching the network.
    class AppTarget < Target
      attr_reader :app_name

      def initialize(app_name, default_timeout_ms: DEFAULT_TIMEOUT_MS)
        super(default_timeout_ms: default_timeout_ms)
        raise ArgumentError, 'app_name must not be nil' if app_name.nil?
        @app_name = app_name.to_s
      end

      def describe
        "app(#{@app_name.inspect})"
      end

      def ==(other)
        other.is_a?(AppTarget) && other.app_name == @app_name
      end
      alias eql? ==

      def hash
        [self.class, @app_name].hash
      end

      # -----------------------------------------------------------------
      # Native hooks
      # -----------------------------------------------------------------

      def _native_call(_api_name, param_raw, timeout_ms)
        LingoFuse::Native.lf_call(@app_name, param_raw, timeout_ms)
      end

      def _native_async_call(_api_name, param_raw, ref_addr, trampoline_addr)
        LingoFuse::Native.lf_async_call(
          @app_name, param_raw, ref_addr, trampoline_addr
        )
      end

      def _native_notify(_api_name, param_raw)
        LingoFuse::Native.lf_notify(@app_name, param_raw)
      end

      def _native_sequenced_notify(_api_name, param_raw)
        LingoFuse::Native.lf_sequenced_notify(@app_name, param_raw)
      end
    end

    # ==================================================================
    # UIDTarget
    # ==================================================================
    #
    # Addresses a specific session by its 32-byte UID.
    #
    # Routing is LOCAL-FIRST, matching AppTarget.
    #
    # A UID can address ANY API registered on the target — whether
    # app-bound or process-wide P2P — without requiring the caller to
    # know the target App name.
    #
    # The UID is regenerated on every TunnelLink, so callers that cache
    # a UID must re-probe it after a link loss.
    class UIDTarget < Target
      attr_reader :uid

      def initialize(uid, default_timeout_ms: DEFAULT_TIMEOUT_MS)
        super(default_timeout_ms: default_timeout_ms)
        @uid = normalise_uid(uid)
      end

      def describe
        "uid(#{@uid.unpack1('H*')})"
      end

      def ==(other)
        other.is_a?(UIDTarget) && other.uid == @uid
      end
      alias eql? ==

      def hash
        [self.class, @uid].hash
      end

      # -----------------------------------------------------------------
      # Native hooks
      # -----------------------------------------------------------------

      def _native_call(_api_name, param_raw, timeout_ms)
        LingoFuse::Native.lf_uid_call(@uid, param_raw, timeout_ms)
      end

      def _native_async_call(_api_name, param_raw, ref_addr, trampoline_addr)
        LingoFuse::Native.lf_uid_async_call(
          @uid, param_raw, ref_addr, trampoline_addr
        )
      end

      def _native_notify(_api_name, param_raw)
        LingoFuse::Native.lf_uid_notify(@uid, param_raw)
      end

      def _native_sequenced_notify(_api_name, param_raw)
        LingoFuse::Native.lf_uid_sequenced_notify(@uid, param_raw)
      end

      private

      def normalise_uid(uid)
        raise ArgumentError, 'UID must not be nil' if uid.nil?

        unless uid.is_a?(String)
          raise ArgumentError,
                "UID must be a String, got #{uid.class}"
        end

        b = uid.b  # ensure ASCII-8BIT for byte-length reasoning

        if b.bytesize == 32
          return b
        end

        if b.bytesize == 64 && b.match?(/\A[0-9a-fA-F]{64}\z/)
          return [b].pack('H*')
        end

        raise ArgumentError,
              'UID must be 32 raw bytes or a 64-character hex string, ' \
              "got #{b.bytesize} bytes"
      end
    end

    # ==================================================================
    # P2PNameTarget
    # ==================================================================
    #
    # Addresses a group of clients sharing a user-supplied P2P name.
    #
    # Routing is NOT local-first. Even when the caller process itself
    # hosts a client in the target group, the call is forwarded to the
    # server for dispatch. This preserves the server-side load-balancing
    # state.
    class P2PNameTarget < Target
      attr_reader :group_name

      def initialize(group_name, default_timeout_ms: DEFAULT_TIMEOUT_MS)
        super(default_timeout_ms: default_timeout_ms)
        raise ArgumentError, 'group_name must not be nil' if group_name.nil?
        @group_name = group_name.to_s
      end

      def describe
        "p2pname(#{@group_name.inspect})"
      end

      def ==(other)
        other.is_a?(P2PNameTarget) && other.group_name == @group_name
      end
      alias eql? ==

      def hash
        [self.class, @group_name].hash
      end

      # -----------------------------------------------------------------
      # Native hooks
      # -----------------------------------------------------------------

      def _native_call(_api_name, param_raw, timeout_ms)
        LingoFuse::Native.lf_p2pname_call(@group_name, param_raw, timeout_ms)
      end

      def _native_async_call(_api_name, param_raw, ref_addr, trampoline_addr)
        LingoFuse::Native.lf_p2pname_async_call(
          @group_name, param_raw, ref_addr, trampoline_addr
        )
      end

      def _native_notify(_api_name, param_raw)
        LingoFuse::Native.lf_p2pname_notify(@group_name, param_raw)
      end

      def _native_sequenced_notify(_api_name, param_raw)
        LingoFuse::Native.lf_p2pname_sequenced_notify(@group_name, param_raw)
      end
    end

    # ==================================================================
    # Module-level convenience constructors
    # ==================================================================
    #
    # These mirror LingoFuse.app / LingoFuse.uid / LingoFuse.p2pname
    # at the top level; keeping them here lets callers include the
    # Address module and call the constructors unqualified.

    class << self
      def app(app_name, **kwargs)
        AppTarget.new(app_name, **kwargs)
      end

      def uid(uid, **kwargs)
        UIDTarget.new(uid, **kwargs)
      end

      def p2pname(group_name, **kwargs)
        P2PNameTarget.new(group_name, **kwargs)
      end
    end
  end

  # --------------------------------------------------------------------
  # Top-level aliases
  # --------------------------------------------------------------------
  # Provide LingoFuse::AppTarget, LingoFuse::UIDTarget, etc. so callers
  # do not have to spell out the intermediate Address module.

  Target        = Address::Target        unless const_defined?(:Target, false)
  AppTarget     = Address::AppTarget     unless const_defined?(:AppTarget, false)
  UIDTarget     = Address::UIDTarget     unless const_defined?(:UIDTarget, false)
  P2PNameTarget = Address::P2PNameTarget unless const_defined?(:P2PNameTarget, false)

  class << self
    def app(app_name, **kwargs)
      Address.app(app_name, **kwargs)
    end

    def uid(uid, **kwargs)
      Address.uid(uid, **kwargs)
    end

    def p2pname(group_name, **kwargs)
      Address.p2pname(group_name, **kwargs)
    end
  end
end