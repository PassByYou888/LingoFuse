# -*- coding: utf-8 -*-
"""
Python bindings for the LingoFuse dynamic library.

This package exposes the following high-level components:

- DataHandle: RAII wrapper for binary data buffers.
- App: Application with API registration and local execution.
- Server: Easy way to start a C4 service and expose APIs.
- C4: Client that dynamically calls remote APIs via __getattr__.
- Target / AppTarget / UIDTarget / P2PNameTarget: the three addressing
  modes that the C ABI supports for remote invocation.
- NetworkEventListener / NetworkEventQueue: process-global network event
  handling (since LingoFuse v3.0).
- CallFuture / AsyncBridge / await_future: modern async support
  (see the "MODERN ASYNC SUPPORT" section below).
- normalize_uid / to_tp2p_uid: UID conversion utilities for callers
  that need to emit UID-addressed traffic (see the
  "UID NORMALIZATION UTILITIES" section below).

Additionally, module-level convenience functions:

- generate_app_name(): generates a unique name for dynamic apps.
- get_app_name(): retrieves the name from a raw AppHnd.
- set_option() / get_option(): adjust and read runtime parameters.
- get_status() / post_status(): access the internal status queue.
- check_main_thread(), check_app(), check_api(): health checks.
- check_uid(), check_uid_api(): UID health checks (v3 addressing).
- check_p2pname(), check_p2pname_api(): P2P name health checks.
- set_network_event() / clear_network_event(): install or remove
  process-global network event callbacks.
- register_p2p_call(), register_p2p_notify(), unregister_p2p():
  process-wide P2P API registration (independent of any App).
- repair_json_text(): the toolchain-wide JSON repair preprocessor.

All functions are thread-safe. For detailed usage, see the docstrings
in the respective modules and the Pascal import unit
(lingofuse_import.pas).

{!!!!!  THREE ADDRESSING MODES  !!!!!}
Remote invocation can be performed through three orthogonal addressing
modes, each with the same set of call shapes (call / async_call /
sequenced_call / notify / sequenced_notify, plus the modern
call_future / call_async / sequenced_call_future / sequenced_call_async):

    client.app("MyApp").call("api", payload)        # App name
    client.uid(uid_bytes).call("api", payload)      # UID
    client.p2pname("group").notify("api", payload)  # P2PName

The three addressing modes differ only in routing semantics. See
lingofuse/address.py for the full Target contract.

{!!!!!  MODERN ASYNC SUPPORT  !!!!!}
The modern async surface is built on two layers:

    * lingofuse.async_support -- the subsystem. It owns the lifetime
      of every ctypes async callback object, tracks every outstanding
      operation through an explicit state machine (PENDING -> FIRED |
      ABANDONED | NOT_QUEUED), and runs a background reclamation
      thread. Timeouts do NOT cause use-after-free, dispatch failures
      do NOT leak, and callers can distinguish "cancelled" from
      "timed out".

    * lingofuse.address.Target -- the user-facing API. Every Target
      exposes four modern methods in addition to the legacy surface:

          call_future(api, payload, timeout_ms=...) -> CallFuture
          call_async(api, payload, timeout_ms=...)  -> awaitable
          sequenced_call_future(...)                -> CallFuture
          sequenced_call_async(...)                 -> awaitable

      The Future-returning methods never block. The ``async def``
      methods are suitable for use with asyncio via ``await``.

The public objects exported at package level are:

    CallFuture         -- concurrent.futures.Future subclass with
                          an ``abandoned`` flag (True when the
                          timeout fired before the callback arrived).

    AsyncBridge        -- process-wide singleton that owns every
                          outstanding async op. Access via
                          ``AsyncBridge.instance()``; diagnostic
                          counters via ``AsyncBridge.instance().stats()``.

    await_future       -- ``async def`` helper that awaits a
                          CallFuture from inside a coroutine. Used
                          internally by Target.call_async; exposed
                          for callers who build their own Futures.

    run_async_with_future
                       -- low-level factory for callers who need to
                          issue an async request without going
                          through a Target. Takes an ``issue_fn``
                          closure and returns a CallFuture.

    make_legacy_op / make_future_op
                       -- lower-level factory helpers used by the
                          legacy and modern paths respectively. Rarely
                          needed directly; kept public for advanced
                          integration.

Example::

    import asyncio

    from lingofuse import AppTarget

    target = AppTarget("MyApp")

    # Non-blocking, callback-free:
    future = target.call_future("add", {"a": 1, "b": 2}, timeout_ms=3000)
    result = future.result()
    if future.abandoned:
        print("timed out; C side may still be running")

    # asyncio:
    async def main():
        result = await target.call_async(
            "add", {"a": 1, "b": 2}, timeout_ms=3000
        )
        print(result)

    asyncio.run(main())

The subsystem is documented in full in lingofuse/async_support.py.

{!!!!!  UID NORMALIZATION UTILITIES  !!!!!}
The two functions below are the supported way for a caller to prepare
a 32-byte UID for the first argument of ``LF_UID_Sequenced_Notify``,
``LF_UID_Call``, and their siblings:

    normalize_uid(uid) -> bytes
        Accept a UID as bytes / bytearray / memoryview / 64-char hex
        string, and return it as a 32-byte bytes object. Raises
        ValueError / TypeError on malformed input.

    to_tp2p_uid(uid_bytes) -> TP2P_UID
        Convert the 32-byte bytes object into the ``TP2P_UID`` ctypes
        array (``c_ubyte * 32``) that the LF_UID_* C ABI functions
        expect as their first argument.

Both were previously private names inside ``lingofuse.address``.
They were promoted to public because the UID-addressed streaming
protocol requires EVERY service that emits a stream event to prepare
the target session's UID before calling ``LF_UID_Sequenced_Notify``.
Reaching into a private name from another package is fragile; the
public names make the dependency explicit and stable.

The private aliases ``_normalize_uid`` and ``_to_tp2p_uid`` are
retained inside ``lingofuse.address`` for backward compatibility
with code that predates this promotion (notably ``lingofuse/bridge.py``)
and are considered implementation detail. New code MUST use the
public names re-exported here.

{!!!!!  PROCESS-WIDE P2P REGISTRATION  !!!!!}
The module-level functions register_p2p_call / register_p2p_notify
register APIs into the process-wide P2P namespace, which is
independent of any App. Those APIs are reachable via UID addressing
or P2PName addressing without requiring the caller to know the target
App name. They are NOT reachable via App-name addressing.

In contrast, App.register_call / App.register_notify register APIs
into the app-bound namespace, reachable via App-name addressing (and
via UID addressing as well).

{!!!!!  AUTO SENDER IDENTITY (SIDE DATA)  !!!!!}
Every inbound request payload carries two identity fields that the
SENDER'S transport layer injects automatically before transmission
(Pascal side: TC40_LF_Client.Send_* ->
TMemory_Param_Tool.Rebuild_UID_and_P2PName):

    * FromUID      -- the sender's 32-byte session UID.
    * FromP2PName  -- the sender's user-supplied P2P group name.

These two fields are "SIDE DATA". They are NOT properties of the
handle itself. They are metadata that the sender wrote into the
payload header, and the receiver therefore sees them in the
Data_Param of the INPUT handle it receives from the framework.

Because of this design, the two reader functions:

    DataHandle.get_p2p_uid()   -> bytes (exactly 32 bytes)
    DataHandle.get_p2p_name()  -> str   ('' if the sender did not set a name)

work ONLY on INPUT handles:

    * Valid on the Input argument of a Call or Notify callback.
    * Valid on the Input argument of a local call / notify (the
      framework injects identity there too).
    * INVALID on an OUTPUT handle: returns 32 zero bytes / empty
      string, and logs a C-side warning.
    * INVALID on a handle the caller created itself via
      DataHandle(...) or DataHandle.create_permanent(...): those
      handles have no "sender", so the same null result applies.

The identity is populated on ALL command paths: Call, Notify,
Sequenced_Call, Sequenced_Notify, and the UID_* / P2PName_* variants.

{!!!!!  LF_Get_P2P_UID RETURNS A POINTER, NOT A VALUE  !!!!!}
At the C ABI level, LF_Get_P2P_UID returns a POINTER to the 32-byte
UID (Pascal signature:

    function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;

i.e. ``^TUID___``, not ``TUID___``). The pointer is allocated by the
C side and is scheduled for automatic release about 5 seconds after
the call.

The Python high-level accessor ``DataHandle.get_p2p_uid()`` hides
this detail: it copies the 32 bytes immediately with
``ctypes.string_at(ptr, 32)`` and returns a fresh Python ``bytes``
object. Callers of the high-level API do not see the transient
pointer.

Direct callers of the low-level binding in ``lingofuse._lf_native``
must perform the copy themselves and must NOT retain the pointer
beyond the ~5-second window, and must NOT call any deallocation
function on it.

Typical uses of the side-data accessors:

    * Call admission / authorisation (compare against an allow-list).
    * Audit logging (record the caller UID in hex).
    * Session state (key a per-sender dict on the UID).
    * Multi-tenancy (use the P2P group name as the tenant id).
    * whoami probe (echo the caller's UID back to it).

See lingofuse/core.py for the full DataHandle side-data contract.

{!!!!!  DATA HANDLE KINDS  !!!!!}
The library provides two kinds of data handles, both wrapped by the
DataHandle class:

  1. AUTO-RECYCLED (created by the regular constructor):

         dh = DataHandle('my_api')

     - The handle is added to the library's idle pool.
     - The pool scans the handle list periodically (default: once
       every 5 seconds) and frees any handle that has been idle
       (no accessor call) for longer than the configured idle
       timeout (default: 10 minutes).
     - Any accessor (get_size, get_pos, read_*, write_*) refreshes
       the idle timestamp, postponing the timeout.
     - A remote call in flight (internal calling counter > 0) also
       postpones the timeout, regardless of how long the caller
       holds the handle.
     - The destructor calls LF_FreeData, which only marks the handle
       for release; the actual release happens on the next pool
       scan (at most one scan interval later).
     - Recommended for the vast majority of use cases.

  2. PERMANENT (created by the classmethod `create_permanent`):

         dh = DataHandle.create_permanent('my_api')

     - The handle is NOT added to the library's idle pool.
     - The automatic idle-timeout reclaimer will NEVER free it, no
       matter how long it has been idle.
     - The destructor calls LF_FreeData, which releases the record
       IMMEDIATELY (synchronously).
     - Recommended for handles that must survive for the entire
       process lifetime (cached request templates, long-lived scratch
       buffers, global registries, etc.).

Both kinds are released when LF_Shutdown is called at process exit.
See lingofuse.core.DataHandle for the full contract.

{!!!!!  DATA HANDLE RECLAMATION IS CONFIGURABLE  !!!!!}
The two thresholds that govern auto-recycled handles are exposed as
runtime options (see `set_option` below for the full alias list):

    # Scan at most once every 5 seconds (default).
    set_option('DataHandle_Pool_Scan_Interval', '5000')

    # Reclaim after 10 minutes of idle time (default).
    set_option('DataHandle_Idle_Timeout', '600000')

Each of these accepts a millisecond integer. A value of 0 or less
disables that side of the reclamation logic:

    # Disable idle reclamation entirely. Only an explicit
    # LF_FreeData / DataHandle.free() releases a handle.
    set_option('DataHandle_Idle_Timeout', '0')

    # Disable the scan rate limiter. The scanner runs on every
    # progress tick of the simulated main thread.
    set_option('DataHandle_Pool_Scan_Interval', '0')

These options do NOT affect handles created by
`DataHandle.create_permanent`: those are always released
synchronously by the wrapper's destructor and never enter the
idle-reclaim path.

{!!!!!  APP LIFETIME  !!!!!}
- `App.free()` detaches the application but does NOT destroy it
  immediately. The underlying object remains in the global pool until
  `LF.Shutdown()` is called.
- For proper resource cleanup, always call `LF.Shutdown()` or use the
  `full_cleanup()` methods provided by `Server` and `C4` when you are
  done.

{!!!!!  NETWORK EVENT LIFETIME  !!!!!}
- The network event callbacks are process-global (no per-client API).
- They run on a background C worker thread; see
  `lingofuse.network_events` for the full threading contract.
- Install callbacks BEFORE `LF_PrepareDone` and clear them BEFORE
  `LF_Shutdown` to avoid races and to release the Python-side strong
  references held by the module.

{!!!!!  JSON REPAIR PREPROCESSING  !!!!!}
Every JSON read path in the toolchain (lf_io.read_json,
lf_io.read_json_or_bytes, serializers.default_deserializer,
bridge.normalize_json_bytes) routes its decoded text through
lingofuse.json_repair_preprocess.repair_json_text before it hands the
text to json.loads. The policy is a strict three-way decision:

    * Valid JSON       -> returned unchanged, NO log message.
    * Repairable JSON  -> repaired, one WARNING naming the source.
    * Unrepairable     -> returned unchanged, one ERROR naming the
                          source (on strict read paths only; the
                          lenient read paths suppress the error
                          because a non-JSON payload is a legitimate
                          outcome there).

The same entry point is re-exported here as `repair_json_text`, so
that advanced callers -- for example, top-level LLM services that
need to apply the exact same repair semantics to their own JSON text
-- can reuse the policy without duplicating the three-way logic.

The repair engine can be disabled globally by setting the
environment variable LINGOFUSE_JSON_REPAIR=0. When disabled, the
preprocessor only validates and never rewrites; the historical
behaviour of every read path is preserved, including the strict
readers raising on malformed input.

The repair engine itself lives in lingofuse.json_repair. Importing
lingofuse does NOT eagerly import it: the engine is loaded lazily
the first time repair_json_text encounters a malformed payload. A
deployment that strips lingofuse.json_repair will still start
cleanly, and will degrade to validation-only behaviour with a
single load-time WARNING.

{!!!!!  STRING PARAMETERS  !!!!!}
Every string argument passed to an LF_* function from this module is
routed through `lingofuse.lf_io.cstr`, which supplies NUL-terminated
UTF-8 bytes for the c_char_p parameter. This removes the previous
reliance on the hidden NUL byte inside CPython bytes objects and
makes the wire contract explicit.

All comments, docstrings, and log messages are in English.
"""

import logging
from typing import Any, Callable, Optional

from .core import DataHandle, App, generate_app_name, get_app_name
from .server import Server
from .client import C4
from .address import (
    Target,
    AppTarget,
    UIDTarget,
    P2PNameTarget,
    AsyncResultHandler,
    normalize_uid,
    to_tp2p_uid,
)
from .async_support import (
    AsyncBridge,
    AsyncOp,
    CallFuture,
    await_future,
    make_future_op,
    make_legacy_op,
    run_async_with_future,
)
from .errors import (
    LingoFuseError,
    ConnectionError,
    TimeoutError,
    RegistrationError,
    SerializationError,
)
from .network_events import (
    set_network_event,
    clear_network_event,
    is_network_event_installed,
    NetworkEventListener,
    NetworkEventQueue,
    get_network_event_queue,
)
from ._lf_native import (
    LF_SetOption as _LF_SetOption,
    LF_GetOption as _LF_GetOption,
)

# Unified LingoFuse payload I/O.
#
# cstr() is the single source of truth for NUL-terminated UTF-8 bytes
# for every LF_* c_char_p parameter in this package. Importing it here
# lets the convenience functions below stop hand-rolling
# `value.encode("utf-8") + b"\x00"`.
from .lf_io import cstr

# Unified JSON repair preprocessing.
#
# repair_json_text() is the single entry point for the toolchain-wide
# JSON repair policy. It is used internally by lf_io, serializers, and
# bridge, and is re-exported here so that advanced callers (for
# example, the top-level LLM services) can apply the exact same
# policy to their own JSON text without duplicating the three-way
# (valid / repairable / unrepairable) decision.
#
# This import does NOT trigger the loading of lingofuse.json_repair:
# the repair engine is loaded lazily, on the first malformed payload
# that repair_json_text sees. Importing lingofuse therefore keeps its
# historical startup cost.
from .json_repair_preprocess import repair_json_text


# Module-level logger for the process-wide P2P callback adapters.
_log = logging.getLogger("lingofuse")


# ======================================================================
# Runtime options
# ----------------------------------------------------------------------
# === Authentication ===
# - "password" / "passwd"
#     Sets the C4 P2PVM authentication token (string).
#
# === Logging & Debugging ===
# - "Quiet"
#     Enable/disable quiet mode (boolean). When enabled, most
#     internal log messages are suppressed.
# - "ShowThreadID" / "ShowThread" / "Show_Thread"
#     Show thread IDs in log output (boolean).
# - "ConsoleOutput" / "Console_Output"
#     Enable or disable console logging (boolean).
#
# === Connection Readiness ===
# - "Overlap_Connection" / "Overlap_Client" / "OverlapConnection" /
#   "OverlapClient" / "OverlapConnect"
#     Controls whether multiple client tunnels to the same remote
#     address are allowed.
#     - False (default): only one tunnel per address. Subsequent
#       LF_PrepareClient calls with a different appHnd will ignore
#       the new appHnd.
#     - True: each LF_PrepareClient call creates a new independent
#       tunnel, binding the provided appHnd.
# - "Wait_Connection_ReadyOk" / "Wait_API_Prepare_Done" /
#   "API_Prepare_Done_Wait" / "WaitConnect" / "Wait_Ready" /
#   "WaitReady"
#     If True, LF_PrepareDone blocks until all prepared clients are
#     connected and their applications are online (boolean).
#     Default is True. When enabled, LF_PrepareDone will not return
#     until every client is fully ready, or the timeout (see below)
#     expires.
# - "Wait_Connection_Timeout" / "Wait_TimeOut" /
#   "API_Prepare_Done_TimeOut" / "WaitTimeOut"
#     Timeout in milliseconds for the above wait (integer).
#     Default is 30,000 ms (30 seconds). If the timeout is reached
#     before all clients are ready, LF_PrepareDone still returns
#     success (1) but some clients may be offline.
#
# === IPC (Inter-Process Communication) ===
# - "IPC_Serv_ThreadCount" / "IPC_ThreadCount" /
#   "IPC_Server_ThreadCount"
#     Number of threads in the IPC server thread pool (integer).
# - "IPC_Serv_MaxQueueLength" / "IPC_MaxQueueLength" /
#   "IPC_Server_MaxQueueLength"
#     Maximum length of the IPC message queue (integer).
# - "IPC_Serv_MaxMsgSize" / "IPC_MaxMsgSize" /
#   "IPC_Server_MaxMsgSize"
#     Maximum size (in bytes) of a single IPC message (integer).
#
# === Sequenced Notifications ===
# - "Fixed_Sequenced_Time" / "Fixed_Sequenced_Life"
#     Idle timeout (in milliseconds) for sequenced notification
#     fallback. When selecting a client for a sequenced notification,
#     if the candidate with the oldest timestamp is older than this
#     value, the system falls back to the newest client to avoid
#     starvation (integer).
#
# === P2P Group Name ===
# - "LF_P2P_name" / "P2P_name" / "LF_P2P" / "P2P"
#     The sender's user-supplied P2P group name (string). Injected
#     into every outbound request payload, and reported to the
#     server via the Update_UID command. Used by P2PName routing to
#     dispatch a call to any client in the group.
#
#     {!!!!!  NOT TO BE CONFUSED WITH DataHandle.get_p2p_name  !!!!!}
#     This option controls the LOCAL configuration: the P2P name
#     that THIS process declares for itself. It is unrelated to
#     ``DataHandle.get_p2p_name()``, which reads the SENDER'S P2P
#     name from the INPUT handle of a registered callback (side
#     data injected by the sender's transport layer). See the
#     module docstring section "AUTO SENDER IDENTITY (SIDE DATA)".
#
# === Data Handle Pool ===
# - "DataHandle_Idle_Timeout" / "Data_Idle_Timeout" / "Idle_Timeout"
#     Idle timeout (in milliseconds) for automatic reclamation of
#     non-permanent data handles (integer).
#       >  0 : ENABLED. A tracked handle that has not been accessed
#              for this long becomes a candidate for release on the
#              next pool scan. Default is 600,000 ms (10 minutes).
#       <= 0 : DISABLED. The idle-reclaim branch is skipped entirely;
#              only an explicit LF_FreeData / DataHandle.free() call
#              releases a handle.
#     Any accessor call on a handle refreshes its idle timer. A
#     remote call in flight (internal calling counter > 0) also
#     postpones the timeout. This option does NOT affect handles
#     created by DataHandle.create_permanent.
#
# - "DataHandle_Pool_Scan_Interval" / "Data_Scan_Interval" /
#   "DataHandle_Scan_Interval"
#     Minimum interval (in milliseconds) between two consecutive
#     scans of the data-handle pool (integer).
#       >  0 : ENABLED. The scanner returns immediately if fewer
#              than this many milliseconds have elapsed since the
#              last scan. Default is 5,000 ms (5 seconds).
#       <= 0 : DISABLED. The scanner runs on every progress tick,
#              without rate-limiting.
#     The scanner is driven by the simulated main thread; its
#     effective call frequency is bounded below by the main thread's
#     tick granularity, not by this value alone.
#
# === Async Subsystem (environment variables, NOT LF_SetOption keys) ===
# - "LINGOFUSE_ASYNC_RECLAIM_GRACE"
#     Seconds to keep an abandoned async op alive after its timeout
#     fires, giving any in-flight C callback a chance to arrive on a
#     still-valid Python object. Default: 60. Must be >= 0.
# - "LINGOFUSE_ASYNC_RECLAIM_PERIOD"
#     Seconds between reclamation sweeps in the AsyncBridge
#     background thread. Default: 1.0. Must be > 0.05.
#   Both are read ONCE at lingofuse.async_support import time. They
#   are listed here for operator discoverability only.
#
# === JSON Repair Preprocessing ===
# - Not an LF_SetOption key. Controlled by the environment variable
#   LINGOFUSE_JSON_REPAIR (see lingofuse.json_repair_preprocess):
#     - unset / "1"    : repair is enabled (default).
#     - "0" / "false"  : repair is disabled; only validation runs,
#                        and malformed payloads are never rewritten.
#   This option is listed here so that operators reading this module
#   as the entry point of the package can find the full set of
#   runtime controls in one place.
# ======================================================================

def set_option(option: str, value: str) -> None:
    """
    Adjust a runtime option.

    All changes take effect immediately. Unknown options are silently
    ignored. For a full list of keys, see the module docstring above
    or the Pascal import unit.

    Both string arguments are passed through lingofuse.lf_io.cstr,
    which supplies the NUL-terminated UTF-8 bytes expected by the
    underlying c_char_p parameters.
    """
    _LF_SetOption(cstr(option), cstr(value))


def get_option(option: str) -> str:
    """
    Read the current value of a runtime option.

    Returns the option's current value as a UTF-8 ``str``. Unknown
    option names yield an empty string, matching the underlying
    library's behaviour.

    The underlying LF_GetOption returns a pointer to a transient
    buffer that is released ~5 seconds after the call. ctypes
    automatically copies the C string into a fresh Python bytes
    object on the return boundary, so the returned str is fully
    detached from that buffer and safe to retain.

    This function is the read-side companion of ``set_option``. Both
    are routed through lingofuse.lf_io.cstr so that the wire contract
    for c_char_p parameters is explicit and consistent across the
    package.
    """
    ptr = _LF_GetOption(cstr(option))
    if not ptr:
        return ""
    return ptr.decode("utf-8", errors="replace")


# ======================================================================
# Status and diagnostic functions
# ======================================================================

def get_status_num() -> int:
    """
    Return the number of pending log messages in the internal status
    buffer.

    The buffer holds up to 1000 messages; older ones are discarded.
    """
    from ._lf_native import LF_GetStatusCount
    return LF_GetStatusCount()


def get_status() -> str:
    """
    Retrieve the next log message from the status queue.

    The returned pointer is valid only until the next call to this
    function. We immediately decode it to a Python string.

    {!!!!!  IMPORTANT  !!!!!}
    This function relies on the simulated main thread to process the
    status queue. If the main thread is not running (i.e., before
    `LF.PrepareDone` is called), the queue may be empty or stale.
    Only rely on this function after the framework is fully initialised.
    """
    from ._lf_native import LF_GetStatus
    ptr = LF_GetStatus()
    if not ptr:
        return ""
    return ptr.decode("utf-8", errors="replace")


def post_status(status: str) -> None:
    """
    Inject a user-supplied message into the status queue.

    This is useful for merging external logs with LingoFuse's internal
    logs.

    {!!!!!  IMPORTANT  !!!!!}
    This function also relies on the main thread to process the queue.
    Before `LF.PrepareDone`, messages may not appear in the buffer.

    The status string is passed through lingofuse.lf_io.cstr, which
    supplies the NUL-terminated UTF-8 bytes expected by the underlying
    c_char_p parameter.
    """
    from ._lf_native import LF_PostStatus
    LF_PostStatus(cstr(status))


def check_main_thread() -> bool:
    """Check whether the simulated main thread is currently active."""
    from ._lf_native import LF_CheckMainThread
    return LF_CheckMainThread() != 0


def check_app(app_name: str) -> bool:
    """
    Check whether an application with the given name is available
    (locally or remotely). This is a quick lookup, but may not reflect
    recent changes. Useful for probing availability before a call.

    The app name is passed through lingofuse.lf_io.cstr, which
    supplies the NUL-terminated UTF-8 bytes expected by the underlying
    c_char_p parameter.
    """
    from ._lf_native import LF_CheckApp
    return LF_CheckApp(cstr(app_name)) != 0


def check_api(app_name: str, api_name: str) -> bool:
    """
    Check whether a specific API is available on the network for the
    given application.

    This function searches both local and remote instances of the
    application to determine if the API is exported. The lookup is
    based on cached information and may not reflect recent changes.
    It is useful for probing availability before making a call, but
    does not guarantee that the API will still be available at the
    moment of the actual call.

    Both string arguments are passed through lingofuse.lf_io.cstr,
    which supplies the NUL-terminated UTF-8 bytes expected by the
    underlying c_char_p parameters.

    Args:
        app_name: Application name (UTF-8, case-insensitive).
        api_name: API name (UTF-8, case-insensitive).

    Returns:
        True if the API is available on at least one instance of the
        application, False otherwise.
    """
    from ._lf_native import LF_CheckApi
    return LF_CheckApi(cstr(app_name), cstr(api_name)) != 0


# ======================================================================
# UID / P2PName health checks
# ----------------------------------------------------------------------
# These four functions mirror check_app / check_api, but keyed on the
# other two addressing modes:
#
#     * check_uid / check_uid_api         -> UID addressing
#     * check_p2pname / check_p2pname_api -> P2PName addressing
#
# Like check_app / check_api, all four consult a locally cached view
# of the mesh that is updated by periodic broadcasts. The cache lags
# fresh registrations and unregistrations by roughly 3 seconds, so a
# just-registered UID/P2PName may briefly return False and a
# just-unregistered one may briefly return True. Callers that need a
# definitive answer should retry, or fall back to the actual call and
# handle the empty-result case.
#
# All four functions are thread-safe and may be called at any time.
# They are meaningful only after LF_PrepareDone has been called; before
# that, they simply see an empty cache and return False.
#
# {!!!!!  UID HERE IS AN ARGUMENT VALUE, NOT SIDE DATA  !!!!!}
# The UID passed to check_uid / check_uid_api is a VALUE the caller
# already possesses: typically the result of a prior "whoami" probe
# or an out-of-band discovery mechanism. The C ABI declares these
# parameters as TP2P_UID___ (a 32-byte Pascal array), which ctypes
# passes by value in a cdecl call. The ctypes type used for the
# argument is therefore TP2P_UID (a c_ubyte * 32 array).
#
# This is a DIFFERENT role from the LF_Get_P2P_UID RETURN value,
# which is a POINTER to a 32-byte UID. See
# lingofuse/_lf_native.py for the full explanation of the two roles.
# ======================================================================

def _normalize_uid_for_check(uid) -> "Any":
    """
    Normalize the ``uid`` argument accepted by ``check_uid`` and
    ``check_uid_api`` into a ``TP2P_UID`` ctypes array.

    Accepted inputs:
        * 32-byte bytes / bytearray / memoryview.
        * 64-character hexadecimal string.

    Raises ValueError / TypeError for anything else.
    """
    # The public UID utilities are re-exported at package level and
    # also available directly from lingofuse.address. We use the
    # public names here to keep the read path aligned with the rest
    # of the package.
    return to_tp2p_uid(normalize_uid(uid))


def check_uid(uid) -> bool:
    """
    Check whether a client with the given UID is currently known to
    the mesh (locally or via the cached remote view).

    The UID may be supplied as 32 raw bytes, a bytearray, a memoryview,
    or a 64-character hexadecimal string.

    Returns True if the UID is present in the local or cached remote
    view, False otherwise. As with check_app, the cache may lag fresh
    registrations by ~3 seconds.
    """
    from ._lf_native import LF_Check_UID
    return LF_Check_UID(_normalize_uid_for_check(uid)) != 0


def check_uid_api(uid, api_name: str) -> bool:
    """
    Check whether a client with the given UID exposes the named API.

    The UID may be supplied as 32 raw bytes, a bytearray, a memoryview,
    or a 64-character hexadecimal string.

    Returns True if the API is available on at least one client with
    the matching UID, False otherwise.
    """
    from ._lf_native import LF_Check_UID_Api
    return LF_Check_UID_Api(
        _normalize_uid_for_check(uid),
        cstr(api_name),
    ) != 0


def check_p2pname(p2p_name: str) -> bool:
    """
    Check whether at least one client has the given P2P group name.

    Returns True if the group is present in the local or cached remote
    view, False otherwise. Cache lag applies as with check_app.
    """
    from ._lf_native import LF_Check_P2PNAME
    return LF_Check_P2PNAME(cstr(p2p_name)) != 0


def check_p2pname_api(p2p_name: str, api_name: str) -> bool:
    """
    Check whether at least one client in the given P2P group exposes
    the named API.

    Returns True if the API is available on at least one client in
    the group, False otherwise.
    """
    from ._lf_native import LF_Check_P2PNAME_Api
    return LF_Check_P2PNAME_Api(
        cstr(p2p_name),
        cstr(api_name),
    ) != 0


# ======================================================================
# Process-wide P2P API registration
# ----------------------------------------------------------------------
# The functions in this section register APIs into the process-wide
# P2P namespace, which is independent of any App:
#
#     register_p2p_call    -- register a Call API (request / response)
#     register_p2p_notify  -- register a Notify API (one-way)
#     unregister_p2p       -- remove a previously registered API
#
# APIs registered here live on the process-wide LF_P2P_APP and are
# reachable via UID addressing or P2PName addressing without requiring
# the caller to know the target App name. They are NOT reachable via
# App-name addressing, even if the registered API name happens to
# match an App name.
#
# Typical use: register a small set of globally-discoverable utility
# APIs (health probes, capability discovery, identity echo, etc.)
# that any client in the mesh can call by group name or by UID.
#
# Lifetime and keep-alive
# -----------------------
# The C library holds a raw function pointer to each installed
# callback. If the corresponding ctypes callback object is garbage
# collected while the pointer is still live, the next invocation will
# crash. We therefore keep a strong reference to every registered
# callback in the module-level ``_p2p_callbacks`` list, which is
# never cleared until process exit. This matches the contract of
# ``App._callbacks`` for app-bound registration, and is documented
# here so that the difference between the two registration paths is
# explicit.
#
# Threading
# ---------
# Registration is thread-safe and may be performed at any time, both
# before and after LF_PrepareDone. The registered callbacks run on
# TCompute worker threads, matching the contract of every other
# LingoFuse callback. They MUST NOT block, and MUST NOT call any
# synchronous LingoFuse function.
# ======================================================================

#: Strong references to every ctypes callback registered through the
#: process-wide P2P API. The list is intentionally never cleared: the
#: process-wide P2P namespace is by definition tied to the process
#: lifetime, and the underlying library does not provide a way to
#: unregister the callback object itself (only its name).
_p2p_callbacks: list = []


def register_p2p_call(
    api_name: str,
    func: Callable,
    description: str = "",
) -> None:
    """
    Register a process-wide P2P Call API.

    The API becomes reachable via UID addressing or P2PName addressing
    from any client in the mesh, without requiring the caller to know
    the target App name. It is NOT reachable via App-name addressing.

    Args:
        api_name:
            Unique API name within the process-wide P2P namespace.
            Case-insensitive on the wire, stored as provided.
        func:
            The callback. Signature::

                def func(trigger, inp: DataHandle, out: DataHandle) -> None:
                    ...

            It runs on a TCompute worker thread. It MUST NOT block,
            and MUST NOT call any synchronous LingoFuse function
            (LF_Call / LF_Notify / LF_LocalCall / LF_PrepareDone /
            LF_Shutdown), on pain of deadlock.
        description:
            Optional human-readable description.

    Raises:
        RegistrationError:
            If the name is already registered in the process-wide P2P
            namespace, or if the underlying library rejects the
            registration for any other reason.

    {!!!!!  EXCEPTION ISOLATION  !!!!!}
    Any exception raised inside ``func`` is caught and logged to the
    "lingofuse" logger. The exception never escapes into the C stack.
    This mirrors the behaviour of the reference C core
    (Engine.Execute_Call) and of App.register_call.

    {!!!!!  KEEP-ALIVE  !!!!!}
    The ctypes callback object wrapping ``func`` is stored in the
    module-level ``_p2p_callbacks`` list and never released. This is
    required: the C library holds a raw function pointer to it, and
    garbage-collecting the wrapper would leave that pointer dangling.
    """
    # Imported lazily so that the module-level import list stays
    # focused on what every user needs, and so that the low-level
    # binding symbols remain visibly scoped to this function.
    from ._lf_native import LF_Register_P2P_Call, LFCallFunc

    def _adapter(trigger, inp, out):
        # Wrap the raw ctypes handles. owned=False: the framework
        # owns these handles and will release them after the callback
        # returns.
        h_in = DataHandle._from_raw(inp, owned=False)
        h_out = DataHandle._from_raw(out, owned=False)
        try:
            func(trigger, h_in, h_out)
        except Exception:
            # Match the contract of App.register_call: never let an
            # exception escape into the C stack.
            _log.exception(
                "P2P Call callback for API '%s' raised an exception; "
                "the exception has been suppressed",
                api_name,
            )

    c_func = LFCallFunc(_adapter)
    # Keep a strong reference before the native call, so that if the
    # native call itself raises (unlikely but possible on OOM), the
    # wrapper still survives until the process exits.
    _p2p_callbacks.append(c_func)

    ret = LF_Register_P2P_Call(
        cstr(api_name),
        cstr(description),
        None,          # Trigger: unused in the Python binding.
        c_func,
    )
    if ret != 1:
        raise RegistrationError(
            f"Failed to register process-wide P2P Call API "
            f"'{api_name}'"
        )


def register_p2p_notify(
    api_name: str,
    func: Callable,
    description: str = "",
) -> None:
    """
    Register a process-wide P2P Notify API.

    The API becomes reachable via UID addressing or P2PName addressing
    from any client in the mesh. It is NOT reachable via App-name
    addressing.

    Args:
        api_name:
            Unique API name within the process-wide P2P namespace.
        func:
            The callback. Signature::

                def func(trigger, inp: DataHandle) -> None:
                    ...

            It runs on a TCompute worker thread. It MUST NOT block,
            and MUST NOT call any synchronous LingoFuse function.
        description:
            Optional human-readable description.

    Raises:
        RegistrationError:
            If the name is already registered in the process-wide P2P
            namespace, or if the underlying library rejects the
            registration for any other reason.

    {!!!!!  EXCEPTION ISOLATION  !!!!!}
    Any exception raised inside ``func`` is caught and logged to the
    "lingofuse" logger. The exception never escapes into the C stack.

    {!!!!!  KEEP-ALIVE  !!!!!}
    See register_p2p_call for the full rationale. The wrapper is kept
    alive in the module-level ``_p2p_callbacks`` list.
    """
    from ._lf_native import LF_Register_P2P_Notify, LFNotifyFunc

    def _adapter(trigger, inp):
        h_in = DataHandle._from_raw(inp, owned=False)
        try:
            func(trigger, h_in)
        except Exception:
            _log.exception(
                "P2P Notify callback for API '%s' raised an exception; "
                "the exception has been suppressed",
                api_name,
            )

    c_func = LFNotifyFunc(_adapter)
    _p2p_callbacks.append(c_func)

    ret = LF_Register_P2P_Notify(
        cstr(api_name),
        cstr(description),
        None,
        c_func,
    )
    if ret != 1:
        raise RegistrationError(
            f"Failed to register process-wide P2P Notify API "
            f"'{api_name}'"
        )


def unregister_p2p(api_name: str) -> bool:
    """
    Remove a previously registered process-wide P2P API.

    The removal is immediate locally. Remote peers may still see the
    API for up to ~3 seconds until the network broadcast propagates.

    Returns True if the API was found and removed, False otherwise.

    Note: the corresponding ctypes callback wrapper stays in
    ``_p2p_callbacks`` even after unregistration. This is deliberate:
    the library does not expose a way to release the callback object
    itself, and keeping the reference is harmless (a few dozen bytes)
    while removing it would risk a use-after-free if the library
    still holds the pointer. Use this function only when you truly
    need to reclaim the API name; for one-shot utilities, leave the
    registration in place for the process lifetime.
    """
    from ._lf_native import LF_Unregister_P2P
    return LF_Unregister_P2P(cstr(api_name)) == 1


# ======================================================================
# Public exports
# ======================================================================

__all__ = [
    # Core RAII wrappers
    "DataHandle", "App",
    # Addressing targets (three modes)
    "Target", "AppTarget", "UIDTarget", "P2PNameTarget",
    "AsyncResultHandler",
    # UID conversion utilities (public as of the current revision)
    "normalize_uid", "to_tp2p_uid",
    # Modern async support
    "AsyncBridge", "AsyncOp", "CallFuture",
    "await_future", "run_async_with_future",
    "make_legacy_op", "make_future_op",
    # Application name helpers
    "generate_app_name", "get_app_name",
    # High-level server / client
    "Server", "C4",
    # Exceptions
    "LingoFuseError", "ConnectionError", "TimeoutError",
    "RegistrationError", "SerializationError",
    # Runtime options
    "set_option", "get_option",
    # Status and diagnostics
    "get_status_num", "get_status", "post_status",
    "check_main_thread", "check_app", "check_api",
    # UID / P2PName health checks
    "check_uid", "check_uid_api",
    "check_p2pname", "check_p2pname_api",
    # Process-wide P2P API registration
    "register_p2p_call", "register_p2p_notify", "unregister_p2p",
    # Network events (since LingoFuse v3.0)
    "set_network_event",
    "clear_network_event",
    "is_network_event_installed",
    "NetworkEventListener",
    "NetworkEventQueue",
    "get_network_event_queue",
    # JSON repair preprocessing
    "repair_json_text",
]