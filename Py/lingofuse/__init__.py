# -*- coding: utf-8 -*-
"""
Python bindings for the LingoFuse dynamic library.
"""
from .core import DataHandle, App
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
# - "Wait_Connection_ReadyOk" / "Wait_API_Prepare_Done" /
#   "API_Prepare_Done_Wait" / "WaitConnect" / "Wait_Ready" /
#   "WaitReady"
#     If True, LF_PrepareDone blocks until all prepared clients
#     are connected and their applications are online (boolean).
# - "Wait_Connection_Timeout" / "Wait_TimeOut" /
#   "API_Prepare_Done_TimeOut" / "WaitTimeOut"
#     Timeout in milliseconds for the above wait (integer).
#
# === IPC (Inter‑Process Communication) ===
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
#     fallback. When selecting a client for a sequenced
#     notification, if the candidate with the oldest timestamp
#     is older than this value, the system falls back to the
#     newest client to avoid starvation (integer).
def set_option(option: str, value: str) -> None:
    _LF_SetOption(option.encode("utf-8") + b'\x00', value.encode("utf-8") + b'\x00')

# ---- Status and diagnostic functions ----
def get_status_num() -> int:
    from ._lf_native import LF_GetStatusCount
    return LF_GetStatusCount()

def get_status() -> str:
    """
    Retrieve the next log message from the status queue.

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
    Inject a user‑supplied message into the status queue.

    {!!!!!  IMPORTANT  !!!!!}
    This function also relies on the main thread to process the queue.
    Before `LF.PrepareDone`, messages may not appear in the buffer.
    """
    from ._lf_native import LF_PostStatus
    LF_PostStatus(status.encode("utf-8") + b'\x00')

def check_main_thread() -> bool:
    from ._lf_native import LF_CheckMainThread
    return LF_CheckMainThread() != 0

def check_app(app_name: str) -> bool:
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
        app_name: Application name (UTF‑8, case‑insensitive).
        api_name: API name (UTF‑8, case‑insensitive).

    Returns:
        True if the API is available on at least one instance of the application,
        False otherwise.
    """
    from ._lf_native import LF_CheckApi
    return LF_CheckApi(app_name.encode("utf-8") + b'\x00', api_name.encode("utf-8") + b'\x00') != 0

__all__ = [
    "DataHandle", "App", "Server", "C4",
    "LingoFuseError", "ConnectionError", "TimeoutError", "RegistrationError",
    "set_option",
    "get_status_num", "get_status", "post_status",
    "check_main_thread", "check_app", "check_api",
]