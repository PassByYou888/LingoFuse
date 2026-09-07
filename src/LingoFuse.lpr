(*
 * ============================================================================
 * LingoFuse – Dynamic Library Interface for the LingoFuse RPC Framework
 * ============================================================================
 *
 * This library provides a C‑ABI (cdecl) export layer for the LingoFuse
 * distributed RPC system. It allows applications written in any language
 * (C, C++, C#, Python, Java, Rust, Go, etc.) to create, register, and
 * invoke remote APIs over a network, using the underlying C4 service mesh
 * for discovery, load‑balancing, and fault tolerance.
 *
 * The exported functions are thread‑safe and can be called concurrently
 * from multiple threads. The library manages its own internal state,
 * including a simulated main thread that drives the network progress loop.
 *
 * ===========================================================================
 * 1. EXPORTED FUNCTION GROUPS
 * ===========================================================================
 *
 *   – Data Handles (LF_CreateData, LF_FreeData, LF_GetBuffer, ...)
 *     Manage opaque binary data buffers that hold serialised parameters
 *     and results for API calls.
 *
 *   – Application Handles (LF_CreateApp, LF_FreeApp)
 *     Create and destroy logical application instances that group APIs.
 *
 *   – API Registration (LF_RegisterCall, LF_RegisterNotify, LF_Unregister)
 *     Expose Call (request‑response) or Notify (one‑way) APIs inside an
 *     application.
 *
 *   – Local Execution (LF_LocalCall, LF_LocalNotify)
 *     Invoke APIs directly within the same process, bypassing the network.
 *
 *   – Network Preparation (LF_ResetPrepare, LF_PrepareService,
 *     LF_PrepareClient, LF_PrepareDone, LF_ExitMainThread)
 *     Set up and tear down the distributed communication layer.
 *
 *   – Remote Invocation (LF_Call, LF_Notify, LF_Sequenced_Notify)
 *     Call or notify remote applications, with optional ordering guarantee.
 *
 *   – Runtime Options (LF_SetOption)
 *     Adjust authentication, logging, timeouts, and IPC parameters.
 *
 *   – Status/Diagnostics (LF_GetStatusCount, LF_GetStatus, LF_PostStatus)
 *     Retrieve or inject log messages.
 *
 *   – Health Checks (LF_CheckMainThread, LF_CheckApp)
 *     Query whether the simulated main thread is running or if an
 *     application is available.
 *
 *   – Shutdown (LF_Shutdown)
 *     Gracefully terminate all network activity and release resources.
 *
 * ===========================================================================
 * 2. THREAD SAFETY & CALLBACK RESTRICTIONS
 * ===========================================================================
 *
 *   – All exported functions are thread‑safe. You may call them from any
 *     thread without external locking.
 *
 *   – However, for a given data handle (TDataHnd), concurrent writes must
 *     be serialised; concurrent reads are safe.
 *
 *   – Callbacks registered with LF_RegisterCall / LF_RegisterNotify are
 *     executed on internal library threads (the simulated main thread or
 *     background workers). Inside a callback, you MUST NOT call any
 *     blocking LingoFuse function (LF_Call, LF_LocalCall, LF_PrepareDone)
 *     as this will cause a deadlock. Offload heavy work to separate
 *     threads.
 *
 * ===========================================================================
 * 3. IMPORTANT USAGE NOTES
 * ===========================================================================
 *
 *   – All string parameters (API names, descriptions, addresses) must be
 *     UTF‑8 encoded and null‑terminated (PAnsiChar).
 *   – Data handles must be freed explicitly with LF_FreeData; although the
 *     library has an automatic idle‑timeout reclaimer, it is not immediate.
 *   – Application handles must be freed with LF_FreeApp.
 *   – Call LF_Shutdown before unloading the library to ensure clean
 *     resource release.
 *   – The library is designed to be loaded once per process. Multiple
 *     instances in the same process are not supported.
 *
 * ===========================================================================
 * 4. COMPATIBILITY
 * ===========================================================================
 *
 *   – Supported platforms: Windows (32/64‑bit), Linux, macOS.
 *   – Compiled with Free Pascal / Delphi, compatible with any C‑ABI caller.
 *   – The library name is automatically resolved by the import unit; the
 *     actual file names are LingoFuse64.dll (Windows 64), LingoFuse32.dll
 *     (Windows 32), liblingofuse.so (Linux), liblingofuse.dylib (macOS).
 *
 * ===========================================================================
 * 5. EXAMPLE (C)
 * ===========================================================================
 *
 *   #include <stdint.h>
 *   typedef void* TDataHnd;
 *   typedef void* TAppHnd;
 *
 *   extern void LF_Call(...); // etc.
 *
 *   static void __cdecl AddCallback(void* trigger, void* input, void* output) {
 *       int a, b;
 *       LF_ReadBuffer(input, &a, sizeof(a));
 *       LF_ReadBuffer(input, &b, sizeof(b));
 *       int sum = a + b;
 *       LF_WriteBuffer(output, &sum, sizeof(sum));
 *   }
 *
 *   int main() {
 *       TAppHnd app = LF_CreateApp("Calculator", "Simple calculator");
 *       LF_RegisterCall(app, "add", "Add two integers", NULL, AddCallback);
 *       LF_ResetPrepare();
 *       LF_PrepareService("0.0.0.0", "127.0.0.1:9898");
 *       LF_PrepareClient("127.0.0.1:9898", app);
 *       if (LF_PrepareDone() == 1) {
 *           TDataHnd data = LF_CreateData("add");
 *           int a=5, b=7;
 *           LF_WriteBuffer(data, &a, sizeof(a));
 *           LF_WriteBuffer(data, &b, sizeof(b));
 *           TDataHnd result = LF_Call("Calculator", data, 5000);
 *           // ... read result ...
 *           LF_FreeData(data);
 *           LF_FreeData(result);
 *       }
 *       LF_FreeApp(app);
 *       LF_Shutdown();
 *       return 0;
 *   }
 *
 * ===========================================================================
 * For detailed documentation of each function, refer to the Pascal import
 * unit `lingofuse_import` or the source unit `Z.LingoFuse_Export`.
 * ===========================================================================
 *)

library LingoFuse;

{$I ..\pascal\zNetV2\source\Z.Define.inc}

uses
  mimalloc4p,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Z.LingoFuse_Export;

exports
  LF_CreateData,
  LF_FreeData,
  LF_GetBuffer,
  LF_WriteBuffer,
  LF_ReadBuffer,
  LF_GetPos,
  LF_SetPos,
  LF_GetSize,
  LF_SetSize,
  LF_CreateApp,
  LF_FreeApp,
  LF_Generate_AppName,
  LF_Get_AppName,
  LF_BindApp,
  LF_RegisterCall,
  LF_RegisterNotify,
  LF_Unregister,
  LF_LocalCall,
  LF_LocalNotify,
  LF_PrepareService,
  LF_PrepareClient,
  LF_ResetPrepare,
  LF_PrepareDone,
  LF_ExitMainThread,
  LF_Call,
  LF_Notify,
  LF_Sequenced_Notify,
  LF_CheckMainThread,
  LF_CheckApp,
  LF_CheckApi,
  LF_SetOption,
  LF_GetStatusCount,
  LF_GetStatus,
  LF_PostStatus,
  LF_Shutdown;

begin
end.
