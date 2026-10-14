# frozen_string_literal: true
#
# options.rb — Typed shortcuts for the LingoFuse runtime options.
#
# ============================================================================
# WHY THIS FILE EXISTS
# ============================================================================
# The C extension exposes two generic option primitives:
#
#     LingoFuse::Native.lf_set_option(name, value)  -> void
#     LingoFuse::Native.lf_get_option(name)         -> String
#
# Both operate on stringly-typed (name, value) pairs, matching the
# underlying C ABI exactly. This file layers a typed Ruby surface on
# top of them:
#
#   * Boolean options round-trip as Ruby true / false.
#   * Integer options round-trip as Ruby Integer.
#   * String options round-trip as Ruby String.
#
# The typed names are the ONLY sanctioned way for application code to
# touch runtime options: they carry the canonical option key internally,
# so a caller cannot misspell it, and they carry the correct value
# coercion, so a caller cannot accidentally write "yes" instead of
# "True".
#
# ============================================================================
# NAME MIRROR — PASCAL HELPERS
# ============================================================================
# Every function name in this module maps 1:1 to a Pascal helper in
# lingofuse_import.pas:
#
#     Pascal LF_Set_Opt_Quiet          <-> Ruby Options.set_opt_quiet
#     Pascal LF_Get_Opt_Quiet          <-> Ruby Options.get_opt_quiet
#     ... (16 pairs in total)
#
# The mapping is intentional: a developer reading the Pascal source
# can locate the corresponding Ruby function by name alone, with no
# lookup table.
#
# ============================================================================
# UNKNOWN OPTIONS
# ============================================================================
# LF_SetOption silently ignores an unknown option name, and LF_GetOption
# returns an empty string for one. The typed wrappers here DO NOT change
# that behaviour. A misspelled option key (for example, "quiet" instead
# of "Quiet") still produces no error; the corresponding get_ returns
# the fallback value documented below.
#
# Callers who need to distinguish "unset" from "set to zero" must call
# LingoFuse::Native.lf_get_option directly and inspect the returned
# string.
#
# ============================================================================
# FALLBACK VALUES
# ============================================================================
# For each typed getter, the fallback value returned when the underlying
# option is empty, unset, or not parseable is:
#
#     set_opt_xxx / get_opt_xxx type    fallback
#     ------------------------------    --------
#     Boolean                            false
#     Integer                            0
#     String                             ""
#
# None of the getters raise on a malformed value. A malformed INTEGER
# string (for example, "abc") is treated as 0; a malformed BOOLEAN
# string (any value other than "True", case-insensitive) is treated
# as false.
#
# ============================================================================
# NOT PERSISTED ACROSS SHUTDOWN
# ============================================================================
# Every option resets to its built-in default when LF_Shutdown is
# called. An application that restarts the framework must reapply its
# options on every startup. This is a property of the underlying C
# library, not of this wrapper.
#
# ============================================================================
# THREAD SAFETY
# ============================================================================
# The underlying LF_SetOption / LF_GetOption are documented as
# thread-safe. Every function here is therefore safe to call from any
# thread.
#
# A setter takes effect immediately, so a concurrent reader may observe
# the old value, the new value, or (for multi-byte string values) a
# torn read. Applications that require consistent multi-field
# configuration should serialise their own option updates behind their
# own lock.
#
# All comments and messages are in English.
# ============================================================================

require_relative 'errors'
require_relative 'native_bridge'

module LingoFuse
  module Options
    # ==================================================================
    # Internal helpers
    # ==================================================================
    # All option I/O funnels through these two private methods.
    # `lf_set_option` and `lf_get_option` live in LingoFuse::Native,
    # which is defined by the C extension at load time.

    class << self
      # -----------------------------------------------------------------
      # Low-level plumbing (private)
      # -----------------------------------------------------------------

      def _set_string(name, value)
        LingoFuse::Native.lf_set_option(name, value.to_s)
        nil
      end

      def _get_string(name)
        raw = LingoFuse::Native.lf_get_option(name)
        return '' if raw.nil?
        raw
      end

      def _set_bool(name, value)
        canonical = value ? 'True' : 'False'
        _set_string(name, canonical)
      end

      def _get_bool(name)
        raw = _get_string(name)
        raw.strip.casecmp?('True')
      end

      def _set_int(name, value)
        _set_string(name, Integer(value).to_s)
      end

      def _get_int(name)
        raw = _get_string(name)
        return 0 if raw.empty?
        Integer(raw, 10)
      rescue ArgumentError
        0
      end

      # -----------------------------------------------------------------
      # Authentication
      # -----------------------------------------------------------------

      # Set the P2PVM / C4 network authentication password.
      #
      # Must match on both sides of a connection, or the handshake fails.
      # The default is the well-known development token; a production
      # deployment should set a private value before calling
      # Framework.prepare_service / prepare_client.
      #
      # Underlying option key : "password"  (alias "passwd")
      def set_opt_password(value)
        _set_string('password', value.to_s)
      end

      # Read the configured password.
      #
      # The library deliberately returns a fixed mask ("********")
      # rather than the real value. The mask is produced by the C side,
      # not by this wrapper.
      def get_opt_password
        _get_string('password')
      end

      # -----------------------------------------------------------------
      # Logging and diagnostics
      # -----------------------------------------------------------------

      # Execute a C4 console debug command.
      #
      # WRITE-ONLY: each call constructs a transient console helper on
      # the Pascal side and runs the given command. Recognised command
      # names include "service", "tunnel", "ZNet_Info", "HPC_Thread_Info",
      # and "Instance_Info".
      #
      # Because each call allocates a helper object, this option is
      # intended for interactive diagnostics only. Do NOT call it in a
      # hot loop.
      #
      # Underlying option key : "debug"
      def set_opt_debug(value)
        _set_string('debug', value.to_s)
      end

      # Read the debug option.
      #
      # Because the underlying option is write-only, the library returns
      # a fixed placeholder string rather than a stored value.
      def get_opt_debug
        _get_string('debug')
      end

      # Enable or disable quiet mode.
      #
      # When enabled, most internal informational logging is suppressed.
      # The default is false (logging enabled).
      #
      # Underlying option key : "Quiet"
      def set_opt_quiet(value)
        _set_bool('Quiet', value)
      end

      # Return true if quiet mode is currently enabled.
      def get_opt_quiet
        _get_bool('Quiet')
      end

      # Enable or disable thread-ID prefixes in status output.
      #
      # Underlying option key : "ShowThreadID"
      def set_opt_show_thread_id(value)
        _set_bool('ShowThreadID', value)
      end

      # Return true if thread-ID prefixes are currently enabled.
      def get_opt_show_thread_id
        _get_bool('ShowThreadID')
      end

      # Enable or disable console output for status messages.
      #
      # When disabled, status messages are still queued and remain
      # readable through Status.get_status; only the console sink is
      # muted.
      #
      # Underlying option key : "ConsoleOutput"
      def set_opt_console_output(value)
        _set_bool('ConsoleOutput', value)
      end

      # Return true if console output is currently enabled.
      def get_opt_console_output
        _get_bool('ConsoleOutput')
      end

      # -----------------------------------------------------------------
      # Connection readiness
      # -----------------------------------------------------------------

      # Allow or forbid multiple client tunnels to the same physical
      # address.
      #
      # false (default): only one tunnel per physical address.
      # true: every prepare_client call creates a new independent tunnel.
      #
      # This option MUST be set BEFORE the prepare_client calls it is
      # meant to affect.
      #
      # Underlying option key : "Overlap_Connection"
      def set_opt_overlap_connection(value)
        _set_bool('Overlap_Connection', value)
      end

      # Return true if overlapping connections are currently allowed.
      def get_opt_overlap_connection
        _get_bool('Overlap_Connection')
      end

      # Control whether Framework.prepare_done blocks until every
      # prepared client is online.
      #
      # true (default): prepare_done waits for all prepared clients.
      # false:          prepare_done returns immediately; the caller
      #                 must probe readiness itself.
      #
      # The total wait is bounded by set_opt_wait_connection_timeout.
      #
      # Underlying option key : "Wait_Connection_ReadyOk"
      def set_opt_wait_connection_ready_ok(value)
        _set_bool('Wait_Connection_ReadyOk', value)
      end

      # Return true if Framework.prepare_done currently waits for all
      # clients.
      def get_opt_wait_connection_ready_ok
        _get_bool('Wait_Connection_ReadyOk')
      end

      # Set the timeout, in milliseconds, for the prepare_done wait
      # described by set_opt_wait_connection_ready_ok.
      #
      # Default: 30000 ms (30 seconds). The library imposes a floor of
      # 5000 ms when the wait is actually performed.
      #
      # Underlying option key : "Wait_Connection_Timeout"
      def set_opt_wait_connection_timeout(value_ms)
        _set_int('Wait_Connection_Timeout', value_ms)
      end

      # Return the current prepare_done wait timeout, in ms.
      def get_opt_wait_connection_timeout
        _get_int('Wait_Connection_Timeout')
      end

      # -----------------------------------------------------------------
      # IPC (Inter-Process Communication)
      # -----------------------------------------------------------------

      # Set the size of the IPC server thread pool.
      #
      # MUST be set before the IPC server is started.
      #
      # Underlying option key : "IPC_Serv_ThreadCount"
      def set_opt_ipc_serv_thread_count(value)
        _set_int('IPC_Serv_ThreadCount', value)
      end

      # Return the configured IPC server thread count.
      def get_opt_ipc_serv_thread_count
        _get_int('IPC_Serv_ThreadCount')
      end

      # Set the maximum length of the IPC server's inbound message queue.
      #
      # MUST be set before the IPC server is started.
      #
      # Underlying option key : "IPC_Serv_MaxQueueLength"
      def set_opt_ipc_serv_max_queue_length(value)
        _set_int('IPC_Serv_MaxQueueLength', value)
      end

      # Return the configured IPC server max queue length.
      def get_opt_ipc_serv_max_queue_length
        _get_int('IPC_Serv_MaxQueueLength')
      end

      # Set the maximum size, in bytes, of a single IPC message.
      #
      # MUST be set before the IPC server is started.
      #
      # Underlying option key : "IPC_Serv_MaxMsgSize"
      def set_opt_ipc_serv_max_msg_size(value)
        _set_int('IPC_Serv_MaxMsgSize', value)
      end

      # Return the configured IPC server max message size.
      def get_opt_ipc_serv_max_msg_size
        _get_int('IPC_Serv_MaxMsgSize')
      end

      # -----------------------------------------------------------------
      # Sequenced notifications
      # -----------------------------------------------------------------

      # Set the sticky-affinity window, in milliseconds, for P2PName
      # load balancing.
      #
      # When the server-side dispatcher routes a P2PName-addressed call,
      # it normally picks the target with the smallest Cycle_Anchor
      # value (pure round-robin). If a single target has been handling
      # requests for longer than this value, the dispatcher switches to
      # a different target instead, to avoid starvation.
      #
      # Default: 20000 ms (20 seconds).
      #
      # Underlying option key : "Fixed_Sequenced_Time"
      def set_opt_fixed_sequenced_time(value_ms)
        _set_int('Fixed_Sequenced_Time', value_ms)
      end

      # Return the current sticky-affinity window, in ms.
      def get_opt_fixed_sequenced_time
        _get_int('Fixed_Sequenced_Time')
      end

      # -----------------------------------------------------------------
      # P2P group name
      # -----------------------------------------------------------------

      # Set this process's P2P group name.
      #
      # The name is injected into every outbound request payload and is
      # reported to the server through the Update_UID command. It defines
      # which P2PName-addressed calls this process is willing to receive.
      #
      # May be changed at any time; the framework picks up the new name
      # on the next outbound request.
      #
      # Default: empty string ("not a member of any group").
      #
      # {!!!!!  THIS IS THE LOCAL DECLARATION  !!!!!}
      # The value set here is the name THIS process declares for itself.
      # It is distinct from the P2P name that a RECEIVER reads from a
      # callback's INPUT handle via DataHandle#get_p2p_name. That value
      # is SIDE DATA injected by the SENDER'S transport layer.
      #
      # Underlying option key : "LF_P2P_name"
      def set_opt_p2p_name(value)
        _set_string('LF_P2P_name', value.to_s)
      end

      # Return this process's configured P2P group name.
      #
      # {!!!!!  NOT TO BE CONFUSED WITH DataHandle#get_p2p_name  !!!!!}
      # This reads the LOCAL configuration: the name this process set
      # for itself. It is unrelated to DataHandle#get_p2p_name, which
      # reads the SENDER's P2P name from the INPUT handle of a callback.
      #
      # Returns an empty string when no name has been set.
      def get_opt_p2p_name
        _get_string('LF_P2P_name')
      end

      # -----------------------------------------------------------------
      # Data handle pool
      # -----------------------------------------------------------------

      # Set the idle-reclaim threshold, in milliseconds, for auto-recycled
      # data handles.
      #
      # A value greater than zero enables idle reclamation. The default
      # is 600000 ms (10 minutes).
      #
      # A value of zero disables idle reclamation entirely. In that mode,
      # only an explicit DataHandle#dispose releases a handle.
      #
      # This option does NOT affect handles created through
      # DataHandle.create_permanent: those are released synchronously.
      #
      # Underlying option key : "DataHandle_Idle_Timeout"
      def set_opt_data_handle_idle_timeout(value_ms)
        _set_int('DataHandle_Idle_Timeout', value_ms)
      end

      # Return the current idle-reclaim threshold, in ms.
      def get_opt_data_handle_idle_timeout
        _get_int('DataHandle_Idle_Timeout')
      end

      # Set the minimum interval, in milliseconds, between two
      # consecutive scans of the data-handle pool.
      #
      # A value greater than zero enables rate-limiting. Default:
      # 5000 ms (5 seconds).
      #
      # A value of zero disables the rate limiter. The scanner then runs
      # on every progress tick of the simulated main thread.
      #
      # Underlying option key : "DataHandle_Pool_Scan_Interval"
      def set_opt_data_handle_pool_scan_interval(value_ms)
        _set_int('DataHandle_Pool_Scan_Interval', value_ms)
      end

      # Return the current data-handle pool scan interval, in ms.
      def get_opt_data_handle_pool_scan_interval
        _get_int('DataHandle_Pool_Scan_Interval')
      end

      # -----------------------------------------------------------------
      # Command flushing
      # -----------------------------------------------------------------

      # Set the null-flush threshold for no-response commands.
      #
      # The LingoFuse protocol periodically sends a NULL command to
      # force the server to acknowledge pending one-way Notify messages.
      # After every N no-response commands, one NULL command is emitted.
      #
      # Default: 5000.
      #
      # {!!!!!  SPELLING NOTE  !!!!!}
      # The option key uses the historical spelling "Reponse" (without
      # the second 's'). This is intentional and matches the Pascal
      # helper name LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold.
      #
      # Underlying option key : "No_Reponse_Cmd_NULL_Flush_Threshold"
      def set_opt_no_reponse_cmd_null_flush_threshold(value)
        _set_int('No_Reponse_Cmd_NULL_Flush_Threshold', value)
      end

      # Return the current null-flush threshold.
      def get_opt_no_reponse_cmd_null_flush_threshold
        _get_int('No_Reponse_Cmd_NULL_Flush_Threshold')
      end

      # -----------------------------------------------------------------
      # Diagnostics
      # -----------------------------------------------------------------

      # Return a Hash of every option's current value, keyed by its
      # canonical typed name (Symbol). Intended for diagnostics, log
      # headers, and configuration dumps.
      #
      # Note: get_opt_password always returns the library's mask
      # ("********"), not the real value.
      def to_h
        {
          password: get_opt_password,
          debug: get_opt_debug,
          quiet: get_opt_quiet,
          show_thread_id: get_opt_show_thread_id,
          console_output: get_opt_console_output,
          overlap_connection: get_opt_overlap_connection,
          wait_connection_ready_ok: get_opt_wait_connection_ready_ok,
          wait_connection_timeout: get_opt_wait_connection_timeout,
          ipc_serv_thread_count: get_opt_ipc_serv_thread_count,
          ipc_serv_max_queue_length: get_opt_ipc_serv_max_queue_length,
          ipc_serv_max_msg_size: get_opt_ipc_serv_max_msg_size,
          fixed_sequenced_time: get_opt_fixed_sequenced_time,
          p2p_name: get_opt_p2p_name,
          data_handle_idle_timeout: get_opt_data_handle_idle_timeout,
          data_handle_pool_scan_interval: get_opt_data_handle_pool_scan_interval,
          no_reponse_cmd_null_flush_threshold: get_opt_no_reponse_cmd_null_flush_threshold
        }
      end
    end
  end

  # --------------------------------------------------------------------
  # Top-level aliases
  # --------------------------------------------------------------------
  # Provide LingoFuse.set_opt_xxx / LingoFuse.get_opt_xxx so callers can
  # write the shortcuts without spelling out the intermediate module.

  class << self
    # --- Authentication -------------------------------------------------
    def set_opt_password(value);  Options.set_opt_password(value);  end
    def get_opt_password;         Options.get_opt_password;         end

    # --- Logging and diagnostics ----------------------------------------
    def set_opt_debug(value);     Options.set_opt_debug(value);     end
    def get_opt_debug;            Options.get_opt_debug;            end
    def set_opt_quiet(value);     Options.set_opt_quiet(value);     end
    def get_opt_quiet;            Options.get_opt_quiet;            end
    def set_opt_show_thread_id(value)
      Options.set_opt_show_thread_id(value)
    end
    def get_opt_show_thread_id;   Options.get_opt_show_thread_id;   end
    def set_opt_console_output(value)
      Options.set_opt_console_output(value)
    end
    def get_opt_console_output;   Options.get_opt_console_output;   end

    # --- Connection readiness -------------------------------------------
    def set_opt_overlap_connection(value)
      Options.set_opt_overlap_connection(value)
    end
    def get_opt_overlap_connection; Options.get_opt_overlap_connection; end
    def set_opt_wait_connection_ready_ok(value)
      Options.set_opt_wait_connection_ready_ok(value)
    end
    def get_opt_wait_connection_ready_ok
      Options.get_opt_wait_connection_ready_ok
    end
    def set_opt_wait_connection_timeout(value_ms)
      Options.set_opt_wait_connection_timeout(value_ms)
    end
    def get_opt_wait_connection_timeout
      Options.get_opt_wait_connection_timeout
    end

    # --- IPC -----------------------------------------------------------
    def set_opt_ipc_serv_thread_count(value)
      Options.set_opt_ipc_serv_thread_count(value)
    end
    def get_opt_ipc_serv_thread_count
      Options.get_opt_ipc_serv_thread_count
    end
    def set_opt_ipc_serv_max_queue_length(value)
      Options.set_opt_ipc_serv_max_queue_length(value)
    end
    def get_opt_ipc_serv_max_queue_length
      Options.get_opt_ipc_serv_max_queue_length
    end
    def set_opt_ipc_serv_max_msg_size(value)
      Options.set_opt_ipc_serv_max_msg_size(value)
    end
    def get_opt_ipc_serv_max_msg_size
      Options.get_opt_ipc_serv_max_msg_size
    end

    # --- Sequenced notifications ----------------------------------------
    def set_opt_fixed_sequenced_time(value_ms)
      Options.set_opt_fixed_sequenced_time(value_ms)
    end
    def get_opt_fixed_sequenced_time
      Options.get_opt_fixed_sequenced_time
    end

    # --- P2P group name -------------------------------------------------
    def set_opt_p2p_name(value);  Options.set_opt_p2p_name(value);  end
    def get_opt_p2p_name;         Options.get_opt_p2p_name;         end

    # --- Data handle pool -----------------------------------------------
    def set_opt_data_handle_idle_timeout(value_ms)
      Options.set_opt_data_handle_idle_timeout(value_ms)
    end
    def get_opt_data_handle_idle_timeout
      Options.get_opt_data_handle_idle_timeout
    end
    def set_opt_data_handle_pool_scan_interval(value_ms)
      Options.set_opt_data_handle_pool_scan_interval(value_ms)
    end
    def get_opt_data_handle_pool_scan_interval
      Options.get_opt_data_handle_pool_scan_interval
    end

    # --- Command flushing -----------------------------------------------
    def set_opt_no_reponse_cmd_null_flush_threshold(value)
      Options.set_opt_no_reponse_cmd_null_flush_threshold(value)
    end
    def get_opt_no_reponse_cmd_null_flush_threshold
      Options.get_opt_no_reponse_cmd_null_flush_threshold
    end
  end
end