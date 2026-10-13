# -*- coding: utf-8 -*-
"""
lingofuse.options - Typed shortcuts for the LingoFuse runtime options.

This module exposes one typed getter/setter pair for each runtime
option that the LingoFuse C ABI recognises. The pairs mirror, one for
one, the convenience functions defined by the Pascal-side
``lingofuse_import.pas`` unit:

    Pascal                          Python (this module)
    ----------------------------    -------------------------------
    LF_Set_Opt_Debug / Get          set_opt_debug / get_opt_debug
    LF_Set_Opt_P2P_Name / Get       set_opt_p2p_name / get_opt_p2p_name
    LF_Set_Opt_Password / Get       set_opt_password / get_opt_password
    LF_Set_Opt_Quiet / Get          set_opt_quiet / get_opt_quiet
    ... (16 pairs in total)

Each function is a thin, typed wrapper around the generic
``set_option`` / ``get_option`` helpers re-exported by the package's
``__init__``. Behaviour is byte-for-byte identical: the underlying
call path is always::

    LF_SetOption(cstr(name), cstr(value))
    LF_GetOption(cstr(name))

The only difference is that these functions:

  * accept and return native Python types (bool / int / str) instead
    of the stringly-typed option value;
  * carry the canonical option key internally, so the caller cannot
    misspell it;
  * document the semantics, default value, and known pitfalls of each
    option in its own docstring.

{!!!!!  THE GENERIC set_option / get_option ARE STILL AVAILABLE  !!!!!}
These typed shortcuts are ADDITIVE. The generic ``set_option`` and
``get_option`` remain the primary API for:

  * passing option names dynamically (e.g. from a config file);
  * using an option that has multiple accepted aliases;
  * scripting the options as a data-driven key/value sequence.

Both paths share the same underlying C primitive, so mixing them is
safe.

{!!!!!  UNKNOWN OPTION NAMES ARE SILENTLY IGNORED  !!!!!}
The underlying LF_SetOption has no return value and does not report
an error when it receives an unrecognised option name (see
LF-OPT-001 in the Pascal-side pitfall knowledge base). These typed
shortcuts eliminate that failure mode by hard-coding the canonical
name, but they do NOT change the underlying behaviour: calling a
generic ``set_option("Typo", "x")`` still silently does nothing.

{!!!!!  OPTIONS ARE NOT PERSISTED ACROSS LF_Shutdown  !!!!!}
Every option is reset to its built-in default when LF_Shutdown is
called. An application that restarts the framework must reapply its
options on every startup (see LF-OPT-002). This applies equally to the
typed shortcuts and to the generic helpers.

{!!!!!  get_opt_p2p_name vs DataHandle.get_p2p_name  !!!!!}
These two functions sound similar but are completely unrelated, and
they read from two different sources:

    * ``get_opt_p2p_name()``
        Reads the P2P group name that THIS process has declared for
        itself, through the ``LF_P2P_name`` runtime option. It is a
        LOCAL CONFIGURATION read: it asks "what name did I set for
        myself?". It is thread-safe, does not depend on any incoming
        call, and returns an empty string when no name has been set.

    * ``DataHandle.get_p2p_name()``
        Reads the P2P group name of the SENDER of an incoming request.
        This value is "SIDE DATA": it is the ``FromP2PName`` field
        that the SENDER'S transport layer injects automatically into
        every outbound request payload before transmission (Pascal
        side: TC40_LF_Client.Send_* ->
        TMemory_Param_Tool.Rebuild_UID_and_P2PName). It is valid
        ONLY on the INPUT handle of a registered Call or Notify
        callback, and it returns the PEER's name, not the local one.

    In short:
        get_opt_p2p_name()       -> MY name (local config)
        DataHandle.get_p2p_name() -> the SENDER's name (side data)

    The two are deliberately kept in separate modules and under
    distinct names so that no call site can confuse them.

{!!!!!  THREAD SAFETY  !!!!!}
The underlying LF_SetOption / LF_GetOption are documented as
thread-safe, and every function in this module is therefore safe to
call from any thread. However:

  * A setter takes effect immediately, so a concurrent reader may
    observe the old value, the new value, or (for multi-byte string
    values) a torn read. Applications that require consistent
    multi-field configuration should serialise their option updates
    behind their own lock.

  * A getter for a numeric option (int / uint64) returns 0 when the
    underlying string cannot be parsed. This is a defensive fallback;
    it should not happen in practice because the underlying library
    only stores values that were successfully parsed by the setter.

All comments and docstrings are in English.
"""

from __future__ import annotations

from ._lf_native import LF_GetOption, LF_SetOption
from .lf_io import cstr


# ======================================================================
# Internal helpers
# ----------------------------------------------------------------------
# These four helpers are the ONLY place in this module that touches
# the raw C ABI. Every public function below delegates to one of them.
#
# The naming convention is intentionally explicit:
#
#     _set_str / _get_str   -> raw string pass-through
#     _set_bool / _get_bool -> Boolean <-> "True" / "False"
#     _set_int / _get_int   -> int <-> decimal string
#
# The Boolean wire form ("True" / "False") matches the value produced
# by the Pascal-side umlBoolToStr and consumed by the underlying
# EStrToBool. It also matches the form used by the existing generic
# set_option / get_option wrappers in lingofuse/__init__.py, so the
# two APIs are interchangeable on the wire.
# ======================================================================

def _set_str(name: str, value: str) -> None:
    """Write ``value`` into the named runtime option, verbatim."""
    LF_SetOption(cstr(name), cstr(value))


def _get_str(name: str) -> str:
    """
    Read the named runtime option as a UTF-8 string.

    Returns an empty string when the option is unknown, when it has no
    value, or when the underlying C string is NULL. ctypes copies the
    transient C buffer into a fresh Python bytes object on the call
    boundary, so the returned str is fully detached and safe to retain.
    """
    ptr = LF_GetOption(cstr(name))
    if not ptr:
        return ""
    return ptr.decode("utf-8", errors="replace")


def _set_bool(name: str, value: bool) -> None:
    """Write a Boolean value as the canonical "True" / "False" string."""
    _set_str(name, "True" if value else "False")


def _get_bool(name: str) -> bool:
    """
    Read a Boolean value.

    The comparison is case-insensitive to match the parsing rules of
    the underlying C code (EStrToBool accepts "True", "true", "TRUE"
    and similarly for False). An empty or unrecognised value yields
    False, which matches the behaviour of the Pascal-side
    ``LF_Get_Opt_*`` helpers.
    """
    return _get_str(name).strip().lower() == "true"


def _set_int(name: str, value: int) -> None:
    """
    Write an integer value as a decimal string.

    The value is coerced with ``int(value)`` first, so that a Python
    bool (which is an int subclass) or a numeric string is written in
    its canonical decimal form.
    """
    _set_str(name, str(int(value)))


def _get_int(name: str) -> int:
    """
    Read an integer value.

    Returns 0 when the stored value is empty or not parseable as a
    decimal integer. This mirrors the Pascal-side helpers, which
    leave the destination variable unchanged on a parse failure and
    therefore also yield a zero-initialised value in the common case.
    """
    raw = _get_str(name)
    try:
        return int(raw)
    except (ValueError, TypeError):
        return 0


# ======================================================================
# Authentication
# ======================================================================

def set_opt_password(value: str) -> None:
    """
    Set the P2PVM / C4 network authentication password.

    The password must match on both sides of a connection, or the
    handshake will fail. The default is the well-known development
    token; a production deployment should set a private one before
    calling ``LF_PrepareService`` / ``LF_PrepareClient``.

    Alias accepted by the underlying library: ``passwd``.
    Corresponding Pascal helper: ``LF_Set_Opt_Password``.
    """
    _set_str("password", value)


def get_opt_password() -> str:
    """
    Read the configured password.

    The underlying library returns a fixed mask (``'********'``) for
    this option, regardless of the actual password. This is a
    deliberate security measure: the real value is never exposed
    through the option-reading API. The return type of this helper is
    therefore a string, but its content is always the mask.

    Corresponding Pascal helper: ``LF_Get_Opt_Password``.
    """
    return _get_str("password")


# ======================================================================
# Logging and diagnostics
# ======================================================================

def set_opt_debug(value: str) -> None:
    """
    Execute a C4 console debug command.

    This option is WRITE-ONLY and has side effects: each call
    constructs a transient console helper object on the Pascal side
    and runs the given command. Recognised command names include
    ``'service'``, ``'tunnel'``, ``'ZNet_Info'``, ``'HPC_Thread_Info'``,
    ``'Instance_Info'``, and any other command registered with the C4
    console dispatcher.

    Because each call allocates a helper object, this option is
    intended for interactive diagnostics only. Do not call it in a
    hot loop.

    Corresponding Pascal helper: ``LF_Set_Opt_Debug``.
    """
    _set_str("debug", value)


def get_opt_debug() -> str:
    """
    Read the current value of the debug option.

    Because the underlying option is write-only, the library returns
    a fixed placeholder string (``'(no value: debug is write-only)'``)
    rather than a stored value. This helper is provided for symmetry
    with the other getters and for callers that iterate over the full
    option table.

    Corresponding Pascal helper: ``LF_Get_Opt_Debug``.
    """
    return _get_str("debug")


def set_opt_quiet(value: bool) -> None:
    """
    Enable or disable quiet mode.

    When quiet mode is enabled, most internal informational logging is
    suppressed. Debug-level logs emitted by ``LF_Debug_Log`` (see the
    Pascal-side export unit) are gated by this flag through
    ``C40_QuietMode``.

    The default is ``False`` (logging enabled).

    Related pitfall IDs: LF-OPT-001 (silent unknown option),
    LF-OPT-002 (options are not persisted across LF_Shutdown).

    Corresponding Pascal helper: ``LF_Set_Opt_Quiet``.
    """
    _set_bool("Quiet", value)


def get_opt_quiet() -> bool:
    """
    Return True if quiet mode is currently enabled.

    Corresponding Pascal helper: ``LF_Get_Opt_Quiet``.
    """
    return _get_bool("Quiet")


def set_opt_show_thread_id(value: bool) -> None:
    """
    Enable or disable thread-ID prefixes in status output.

    When enabled, every status message emitted by the Z.Status
    subsystem is prefixed with the numeric ID of the thread that
    produced it. This is useful for multi-threaded diagnostics but
    adds a small per-message cost.

    The default is ``True``.

    Alias accepted by the underlying library: ``ShowThread``.
    Corresponding Pascal helper: ``LF_Set_Opt_ShowThreadID``.
    """
    _set_bool("ShowThreadID", value)


def get_opt_show_thread_id() -> bool:
    """
    Return True if thread-ID prefixes are currently enabled.

    Corresponding Pascal helper: ``LF_Get_Opt_ShowThreadID``.
    """
    return _get_bool("ShowThreadID")


def set_opt_console_output(value: bool) -> None:
    """
    Enable or disable console output for status messages.

    When enabled, the Z.Status subsystem writes every status message
    to the process's standard output (or console, depending on the
    platform). When disabled, status messages are still queued and
    remain readable through ``get_status`` / ``get_status_num``; only
    the console sink is muted.

    The default depends on the host: True for a console application,
    False for a library loaded into a GUI process. The library entry
    point sets this explicitly at initialisation time.

    Alias accepted by the underlying library: ``Console_Output``.
    Corresponding Pascal helper: ``LF_Set_Opt_ConsoleOutput``.
    """
    _set_bool("ConsoleOutput", value)


def get_opt_console_output() -> bool:
    """
    Return True if console output is currently enabled.

    Corresponding Pascal helper: ``LF_Get_Opt_ConsoleOutput``.
    """
    return _get_bool("ConsoleOutput")


# ======================================================================
# Connection readiness
# ======================================================================

def set_opt_overlap_connection(value: bool) -> None:
    """
    Allow or forbid multiple client tunnels to the same physical
    address.

    ``False`` (the default) permits only one client tunnel per
    physical address. A second ``LF_PrepareClient`` call for the same
    address returns -1 and the new application handle is discarded.

    ``True`` makes every ``LF_PrepareClient`` call create a new
    independent tunnel, binding the supplied application handle.

    This option MUST be set BEFORE the ``LF_PrepareClient`` calls it
    is meant to affect. Changing it after a tunnel has been created
    does not rearrange existing tunnels.

    Related pitfall IDs: LF-APP-005, LF-APP-006, LF-NET-001,
    LF-OPT-003.

    Corresponding Pascal helper: ``LF_Set_Opt_Overlap_Connection``.
    """
    _set_bool("Overlap_Connection", value)


def get_opt_overlap_connection() -> bool:
    """
    Return True if overlapping connections are currently allowed.

    Corresponding Pascal helper: ``LF_Get_Opt_Overlap_Connection``.
    """
    return _get_bool("Overlap_Connection")


def set_opt_wait_connection_ready_ok(value: bool) -> None:
    """
    Control whether ``LF_PrepareDone`` blocks until every prepared
    client is online.

    ``True`` (the default) makes ``LF_PrepareDone`` wait for all
    prepared clients to reach the "online" state before returning.
    This is the convenient behaviour when the mesh is fully
    controlled and the peers are known to be up.

    ``False`` makes ``LF_PrepareDone`` return immediately after the
    simulated main thread has started. The caller is then responsible
    for probing readiness itself (for example with ``check_app`` in a
    retry loop). This is the recommended setting for deployments
    where the startup order of peers is not predictable.

    The total wait is bounded by ``Wait_Connection_Timeout``.

    Related pitfall IDs: LF-NET-002, LF-NET-004, LF-NET-007.

    Corresponding Pascal helper: ``LF_Set_Opt_Wait_Connection_ReadyOk``.
    """
    _set_bool("Wait_Connection_ReadyOk", value)


def get_opt_wait_connection_ready_ok() -> bool:
    """
    Return True if ``LF_PrepareDone`` currently waits for all clients.

    Corresponding Pascal helper: ``LF_Get_Opt_Wait_Connection_ReadyOk``.
    """
    return _get_bool("Wait_Connection_ReadyOk")


def set_opt_wait_connection_timeout(value_ms: int) -> None:
    """
    Set the timeout, in milliseconds, for the ``LF_PrepareDone`` wait
    described by ``Wait_Connection_ReadyOk``.

    The default is 30,000 ms (30 seconds). If the timeout expires
    before all clients are ready, ``LF_PrepareDone`` still returns 1;
    the caller must independently verify readiness if that matters
    (see LF-NET-007).

    The library imposes a floor of 5,000 ms on this value when the
    wait is actually performed. Values below that floor are silently
    raised.

    Related pitfall IDs: LF-NET-002, LF-NET-007.

    Corresponding Pascal helper: ``LF_Set_Opt_Wait_Connection_Timeout``.
    """
    _set_int("Wait_Connection_Timeout", value_ms)


def get_opt_wait_connection_timeout() -> int:
    """
    Return the current ``LF_PrepareDone`` wait timeout, in ms.

    Corresponding Pascal helper: ``LF_Get_Opt_Wait_Connection_Timeout``.
    """
    return _get_int("Wait_Connection_Timeout")


# ======================================================================
# IPC (Inter-Process Communication)
# ======================================================================

def set_opt_ipc_serv_thread_count(value: int) -> None:
    """
    Set the size of the IPC server thread pool.

    This option MUST be set before the IPC server is started. Changing
    it after startup has no effect on an already-running server.

    The default is platform-dependent.

    Corresponding Pascal helper: ``LF_Set_Opt_IPC_Serv_ThreadCount``.
    """
    _set_int("IPC_Serv_ThreadCount", value)


def get_opt_ipc_serv_thread_count() -> int:
    """
    Return the configured IPC server thread count.

    Corresponding Pascal helper: ``LF_Get_Opt_IPC_Serv_ThreadCount``.
    """
    return _get_int("IPC_Serv_ThreadCount")


def set_opt_ipc_serv_max_queue_length(value: int) -> None:
    """
    Set the maximum length of the IPC server's inbound message queue.

    This option MUST be set before the IPC server is started.

    Corresponding Pascal helper: ``LF_Set_Opt_IPC_Serv_MaxQueueLength``.
    """
    _set_int("IPC_Serv_MaxQueueLength", value)


def get_opt_ipc_serv_max_queue_length() -> int:
    """
    Return the configured IPC server max queue length.

    Corresponding Pascal helper: ``LF_Get_Opt_IPC_Serv_MaxQueueLength``.
    """
    return _get_int("IPC_Serv_MaxQueueLength")


def set_opt_ipc_serv_max_msg_size(value: int) -> None:
    """
    Set the maximum size, in bytes, of a single IPC message.

    This option MUST be set before the IPC server is started.

    Corresponding Pascal helper: ``LF_Set_Opt_IPC_Serv_MaxMsgSize``.
    """
    _set_int("IPC_Serv_MaxMsgSize", value)


def get_opt_ipc_serv_max_msg_size() -> int:
    """
    Return the configured IPC server max message size.

    Corresponding Pascal helper: ``LF_Get_Opt_IPC_Serv_MaxMsgSize``.
    """
    return _get_int("IPC_Serv_MaxMsgSize")


# ======================================================================
# Sequenced notifications
# ======================================================================

def set_opt_fixed_sequenced_time(value_ms: int) -> None:
    """
    Set the sticky-affinity window, in milliseconds, for P2PName
    load balancing.

    When the server-side dispatcher routes a P2PName-addressed call,
    it normally picks the target with the smallest Cycle_Anchor value
    (pure round-robin). If, however, a single target has been handling
    requests for longer than ``Fixed_Sequenced_Time``, the dispatcher
    switches to a different target instead, to avoid starvation.

    The default is 20,000 ms (20 seconds).

    Related pitfall IDs: LF-SEQ-001, LF-ROUTE-006.

    Corresponding Pascal helper: ``LF_Set_Opt_Fixed_Sequenced_Time``.
    """
    _set_int("Fixed_Sequenced_Time", value_ms)


def get_opt_fixed_sequenced_time() -> int:
    """
    Return the current sticky-affinity window, in ms.

    Corresponding Pascal helper: ``LF_Get_Opt_Fixed_Sequenced_Time``.
    """
    return _get_int("Fixed_Sequenced_Time")


# ======================================================================
# P2P group name
# ======================================================================

def set_opt_p2p_name(value: str) -> None:
    """
    Set this process's P2P group name.

    The name is injected into every outbound request payload and is
    reported to the server through the ``Update_UID`` command. It
    defines which P2PName-addressed calls this process is willing to
    receive: a server dispatching to P2PName ``"workers"`` will pick a
    client whose P2P name is ``"workers"``.

    {!!!!!  THIS IS THE LOCAL DECLARATION  !!!!!}
    The value set here is the name THIS process declares for itself.
    It is distinct from the P2P name that OTHER processes will see
    when they receive a request from us, and it is distinct from the
    name this process will read from an incoming request's INPUT
    handle via ``DataHandle.get_p2p_name()``. The sender's P2P name
    that a receiver reads is "SIDE DATA": it is the ``FromP2PName``
    field that OUR transport layer wrote into the outbound payload
    before transmission. The two values coincide only because we are
    the sender.

    See the module docstring section
    "get_opt_p2p_name vs DataHandle.get_p2p_name" for the full
    comparison.

    The value may be changed at any time. The framework picks up the
    new name on the next outbound request; there is no need to
    reconnect.

    The default is an empty string, which means "not a member of any
    group". An empty P2P name disables P2PName routing for this
    process (UID and App-name routing are unaffected).

    Related pitfall IDs: LF-MECH-010, LF-ROUTE-003.

    Corresponding Pascal helper: ``LF_Set_Opt_P2P_Name``.
    """
    _set_str("LF_P2P_name", value)


def get_opt_p2p_name() -> str:
    """
    Return this process's configured P2P group name.

    {!!!!!  NOT TO BE CONFUSED WITH DataHandle.get_p2p_name  !!!!!}
    This function reads the LOCAL configuration: the value this
    process set for itself through ``set_opt_p2p_name``. It answers
    the question "what P2P name have I declared for myself?".

    It is completely unrelated to ``DataHandle.get_p2p_name``, which
    reads the SENDER's P2P name from the INPUT handle of a registered
    callback. That value is "SIDE DATA": it is the ``FromP2PName``
    field that the peer's transport layer injected into the payload
    before transmission. In other words:

        get_opt_p2p_name()        -> MY name (local config)
        DataHandle.get_p2p_name() -> the SENDER's name (side data)

    Both names happen to be of the same underlying wire type (a UTF-8
    string), but they come from two different sources and must not be
    confused at any call site.

    Returns an empty string when no name has been set.

    Corresponding Pascal helper: ``LF_Get_Opt_P2P_Name``.
    """
    return _get_str("LF_P2P_name")


# ======================================================================
# Data handle pool
# ======================================================================

def set_opt_data_handle_idle_timeout(value_ms: int) -> None:
    """
    Set the idle-reclaim threshold, in milliseconds, for auto-recycled
    data handles.

    A value greater than zero enables idle reclamation: a handle that
    has not been accessed for at least this long becomes a candidate
    for release on the next pool scan. The default is 600,000 ms
    (10 minutes).

    A value of zero or less disables idle reclamation entirely. In
    that mode, only an explicit ``DataHandle.free()`` releases a
    handle.

    This option does NOT affect handles created through
    ``DataHandle.create_permanent``: those are released synchronously
    by the wrapper's destructor and never enter the idle-reclaim path.

    Related pitfall IDs: LF-DATA-001, LF-MECH-001.

    Corresponding Pascal helper:
        ``LF_Set_Opt_DataHandle_Idle_Timeout``.
    """
    _set_int("DataHandle_Idle_Timeout", value_ms)


def get_opt_data_handle_idle_timeout() -> int:
    """
    Return the current idle-reclaim threshold, in ms.

    Corresponding Pascal helper:
        ``LF_Get_Opt_DataHandle_Idle_Timeout``.
    """
    return _get_int("DataHandle_Idle_Timeout")


def set_opt_data_handle_pool_scan_interval(value_ms: int) -> None:
    """
    Set the minimum interval, in milliseconds, between two consecutive
    scans of the data-handle pool.

    A value greater than zero enables rate-limiting: the scanner
    returns immediately if fewer than this many milliseconds have
    elapsed since the last scan. The default is 5,000 ms (5 seconds).

    A value of zero or less disables the rate limiter. The scanner
    then runs on every progress tick of the simulated main thread,
    which can be a significant CPU cost under a busy main loop.

    The scanner is driven by the simulated main thread, so its
    effective call frequency is bounded below by the main thread's
    tick granularity, not by this value alone.

    Corresponding Pascal helper:
        ``LF_Set_Opt_DataHandle_Pool_Scan_Interval``.
    """
    _set_int("DataHandle_Pool_Scan_Interval", value_ms)


def get_opt_data_handle_pool_scan_interval() -> int:
    """
    Return the current data-handle pool scan interval, in ms.

    Corresponding Pascal helper:
        ``LF_Get_Opt_DataHandle_Pool_Scan_Interval``.
    """
    return _get_int("DataHandle_Pool_Scan_Interval")


# ======================================================================
# Command flushing
# ======================================================================

def set_opt_no_reponse_cmd_null_flush_threshold(value: int) -> None:
    """
    Set the null-flush threshold for no-response commands.

    The LingoFuse protocol periodically sends a NULL command to force
    the server to acknowledge pending one-way Notify messages. After
    every ``value`` no-response commands, one NULL command is emitted
    as a flush point.

    A lower value gives more timely acknowledgement at a slight cost
    in bandwidth; a higher value is more efficient but delays the
    server-side visibility of Notify deliveries.

    The default is 5,000.

    {!!!!!  SPELLING NOTE  !!!!!}
    The option key uses the historical spelling ``Reponse`` (without
    the second 's'). The Python helper preserves that spelling in its
    own name so that the two are trivially cross-referenced. The
    function name and the option key are both intentional.

    Corresponding Pascal helper:
        ``LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold``.
    """
    _set_int("No_Reponse_Cmd_NULL_Flush_Threshold", value)


def get_opt_no_reponse_cmd_null_flush_threshold() -> int:
    """
    Return the current null-flush threshold.

    Corresponding Pascal helper:
        ``LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold``.
    """
    return _get_int("No_Reponse_Cmd_NULL_Flush_Threshold")


# ======================================================================
# Public exports
# ======================================================================

__all__ = [
    # Authentication
    "set_opt_password", "get_opt_password",
    # Logging and diagnostics
    "set_opt_debug", "get_opt_debug",
    "set_opt_quiet", "get_opt_quiet",
    "set_opt_show_thread_id", "get_opt_show_thread_id",
    "set_opt_console_output", "get_opt_console_output",
    # Connection readiness
    "set_opt_overlap_connection", "get_opt_overlap_connection",
    "set_opt_wait_connection_ready_ok",
    "get_opt_wait_connection_ready_ok",
    "set_opt_wait_connection_timeout",
    "get_opt_wait_connection_timeout",
    # IPC
    "set_opt_ipc_serv_thread_count", "get_opt_ipc_serv_thread_count",
    "set_opt_ipc_serv_max_queue_length",
    "get_opt_ipc_serv_max_queue_length",
    "set_opt_ipc_serv_max_msg_size", "get_opt_ipc_serv_max_msg_size",
    # Sequenced notifications
    "set_opt_fixed_sequenced_time", "get_opt_fixed_sequenced_time",
    # P2P group name
    "set_opt_p2p_name", "get_opt_p2p_name",
    # Data handle pool
    "set_opt_data_handle_idle_timeout",
    "get_opt_data_handle_idle_timeout",
    "set_opt_data_handle_pool_scan_interval",
    "get_opt_data_handle_pool_scan_interval",
    # Command flushing
    "set_opt_no_reponse_cmd_null_flush_threshold",
    "get_opt_no_reponse_cmd_null_flush_threshold",
]