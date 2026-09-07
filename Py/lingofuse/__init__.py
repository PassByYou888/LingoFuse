# -*- coding: utf-8 -*-
"""
Python bindings for the LingoFuse dynamic library.

This package exposes the following high-level components:
- DataHandle: RAII wrapper for binary data buffers.
- App: Application with API registration and local execution.
- Server: Easy way to start a C4 service and expose APIs.
- C4: Client that dynamically calls remote APIs via __getattr__.

Additionally, module-level convenience functions:
- generate_app_name(): generates a unique name for dynamic apps.
- get_app_name(): retrieves the name from a raw AppHnd.
- set_option(): adjusts runtime parameters.
- get_status() / post_status(): access the internal status queue.
- check_main_thread(), check_app(), check_api(): health checks.

All functions are thread-safe. For detailed usage, see the docstrings
in the respective modules and the Pascal import unit (lingofuse_import.pas).

{!!!!!  APP LIFETIME  !!!!!}
- `App.free()` detaches the application but does NOT destroy it immediately.
  The underlying object remains in the global pool until `LF.Shutdown()` is called.
- For proper resource cleanup, always call `LF.Shutdown()` or use the
  `full_cleanup()` methods provided by `Server` and `C4` when you are done.
"""
from .core import DataHandle, App, generate_app_name, get_app_name
from .server import Server
from .client import C4
from .errors import LingoFuseError, ConnectionError, TimeoutError, RegistrationError
from ._lf_native import LF_SetOption as _LF_SetOption

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
# - "Overlap_Connection" / "Overlap_Client" / "OverlapConnection" / "OverlapClient" / "OverlapConnect"
#     Controls whether multiple client tunnels to the same remote address are allowed.
#     - False (default): only one tunnel per address. Subsequent LF_PrepareClient
#       calls with a different appHnd will ignore the new appHnd.
#     - True: each LF_PrepareClient call creates a new independent tunnel,
#       binding the provided appHnd.
# - "Wait_Connection_ReadyOk" / "Wait_API_Prepare_Done" /
#   "API_Prepare_Done_Wait" / "WaitConnect" / "Wait_Ready" /
#   "WaitReady"
#     If True, LF_PrepareDone blocks until all prepared clients
#     are connected and their applications are online (boolean).
#     Default is True. When enabled, LF_PrepareDone will not return until
#     every client is fully ready, or the timeout (see below) expires.
# - "Wait_Connection_Timeout" / "Wait_TimeOut" /
#   "API_Prepare_Done_TimeOut" / "WaitTimeOut"
#     Timeout in milliseconds for the above wait (integer).
#     Default is 30,000 ms (30 seconds). If the timeout is reached before
#     all clients are ready, LF_PrepareDone still returns success (1) but
#     some clients may be offline.
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
#     Idle timeout (in milliseconds) for sequenced notification fallback.
#     When selecting a client for a sequenced notification, if the candidate
#     with the oldest timestamp is older than this value, the system falls
#     back to the newest client to avoid starvation (integer).

def set_option(option: str, value: str) -> None:
    """
    Adjust a runtime option.

    All changes take effect immediately. Unknown options are silently ignored.
    For a full list of keys, see the docstring above or the Pascal import unit.
    """
    _LF_SetOption(option.encode("utf-8") + b'\x00', value.encode("utf-8") + b'\x00')

# ---- Status and diagnostic functions ----
def get_status_num() -> int:
    """
    Return the number of pending log messages in the internal status buffer.

    The buffer holds up to 1000 messages; older ones are discarded.
    """
    from ._lf_native import LF_GetStatusCount
    return LF_GetStatusCount()

def get_status() -> str:
    """
    Retrieve the next log message from the status queue.

    The returned pointer is valid only until the next call to this function.
    We immediately decode it to a Python string.

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

    This is useful for merging external logs with LingoFuse's internal logs.

    {!!!!!  IMPORTANT  !!!!!}
    This function also relies on the main thread to process the queue.
    Before `LF.PrepareDone`, messages may not appear in the buffer.
    """
    from ._lf_native import LF_PostStatus
    LF_PostStatus(status.encode("utf-8") + b'\x00')

def check_main_thread() -> bool:
    """Check whether the simulated main thread is currently active."""
    from ._lf_native import LF_CheckMainThread
    return LF_CheckMainThread() != 0

def check_app(app_name: str) -> bool:
    """
    Check whether an application with the given name is available
    (locally or remotely). This is a quick lookup, but may not reflect
    recent changes. Useful for probing availability before a call.
    """
    from ._lf_native import LF_CheckApp
    return LF_CheckApp(app_name.encode("utf-8") + b'\x00') != 0

def check_api(app_name: str, api_name: str) -> bool:
    """
    Check whether a specific API is available on the network for the given application.

    This function searches both local and remote instances of the application
    to determine if the API is exported. The lookup is based on cached information
    and may not reflect recent changes. It is useful for probing availability
    before making a call, but does not guarantee that the API will still be
    available at the moment of the actual call.

    Args:
        app_name: Application name (UTF-8, case-insensitive).
        api_name: API name (UTF-8, case-insensitive).

    Returns:
        True if the API is available on at least one instance of the application,
        False otherwise.
    """
    from ._lf_native import LF_CheckApi
    return LF_CheckApi(app_name.encode("utf-8") + b'\x00', api_name.encode("utf-8") + b'\x00') != 0

__all__ = [
    "DataHandle", "App",
    "generate_app_name", "get_app_name",
    "Server", "C4",
    "LingoFuseError", "ConnectionError", "TimeoutError", "RegistrationError",
    "set_option",
    "get_status_num", "get_status", "post_status",
    "check_main_thread", "check_app", "check_api",
]