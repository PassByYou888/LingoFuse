library LingoFuse;

{$I ..\pascal\zNetV2\source\Z.Define.inc}

uses
  // ==========================================================================
  // mimalloc - compact general-purpose memory allocator, drop-in replacement
  // for the C runtime malloc. Prebuilt binaries are published here:
  //   https://github.com/microsoft/mimalloc/releases
  //
  // --------------------------------------------------------------------------
  // Linux x64
  // --------------------------------------------------------------------------
  //  1. Download:
  //       wget https://github.com/microsoft/mimalloc/releases/download/v1.15.2/mimalloc-v1.15.2-linux-x64.tar.gz
  //  2. Extract:
  //       tar -xzf mimalloc-v1.15.2-linux-x64.tar.gz
  //       cd mimalloc-v1.15.2-linux-x64
  //  3. Install the shared library system-wide so the linker can find it:
  //       sudo cp -a lib/libmimalloc.so*              /usr/local/lib/
  //       sudo cp -a lib/mimalloc-1.15/libmimalloc.a /usr/local/lib/     # optional, static linking only
  //       sudo cp -a include/mimalloc-1.15            /usr/local/include/ # optional, C/C++ mi_* APIs only
  //       sudo ldconfig
  //  4. Verify:
  //       ldconfig -p | grep mimalloc
  //
  //  If you do not want a system-wide install, skip step 3 and add
  //  -Fl/path/to/mimalloc-v1.15.2-linux-x64/lib to the FPC command line.
  //
  // --------------------------------------------------------------------------
  // Windows x86 / x64
  // --------------------------------------------------------------------------
  //  This project ships the mimalloc DLLs renamed by bitness, so the 32-bit
  //  and 64-bit builds can co-exist in one deployment folder:
  //
  //      mimalloc32.dll  <-> 32-bit build of mimalloc.dll
  //      mimalloc64.dll  <-> 64-bit build of mimalloc.dll
  //
  //  Deployment: copy the DLL that matches the bitness of your EXE next to
  //  the executable. The Windows loader searches the EXE directory first, so
  //  no PATH change is required.
  //
  //      :: 64-bit EXE
  //      copy mimalloc64.dll  C:\path\to\myapp\
  //
  //      :: 32-bit EXE
  //      copy mimalloc32.dll  C:\path\to\myapp\
  //
  //  Example deployment folder:
  //
  //      C:\path\to\myapp\
  //        myapp.exe
  //        mimalloc64.dll    (only if myapp.exe is 64-bit)
  //        mimalloc32.dll    (only if myapp.exe is 32-bit)
  //
  //  The two redirect DLLs are only required when mimalloc is linked
  //  statically together with the mimalloc-override mechanism (i.e. you
  //  want mimalloc to replace the CRT's malloc at process startup):
  //
  //      mimalloc-redirect.dll     (64-bit)
  //      mimalloc-redirect32.dll   (32-bit)
  //
  //  The standard "external 'mimalloc64.dll'" linkage used by mimalloc4p
  //  does NOT require either redirect DLL, so for this unit you normally
  //  only ship mimalloc32.dll or mimalloc64.dll.
  // ==========================================================================
  mimalloc4p,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Z.LingoFuse_Export;

exports
  // ---- Data handles ---------------------------------------------------------
  LF_CreateData,
  LF_CreateData_Permanent,
  LF_FreeData,
  LF_GetBuffer,
  LF_WriteBuffer,
  LF_ReadBuffer,
  LF_GetPos,
  LF_SetPos,
  LF_GetSize,
  LF_SetSize,
  LF_Get_P2P_UID,
  LF_Get_P2P_Name,

  // ---- Application handles --------------------------------------------------
  LF_CreateApp,
  LF_FreeApp,
  LF_Generate_AppName,
  LF_Get_AppName,
  LF_BindApp,

  // ---- API registration (app-bound) -----------------------------------------
  LF_RegisterCall,
  LF_RegisterNotify,
  LF_Unregister,

  // ---- API registration (process-wide P2P) ----------------------------------
  LF_Register_P2P_Call,
  LF_Register_P2P_Notify,
  LF_Unregister_P2P,

  // ---- Local execution ------------------------------------------------------
  LF_LocalCall,
  LF_LocalNotify,

  // ---- Network preparation --------------------------------------------------
  LF_PrepareService,
  LF_PrepareClient,
  LF_ResetPrepare,
  LF_PrepareDone,
  LF_ExitMainThread,

  // ---- Remote invocation by app name ----------------------------------------
  LF_Call,
  LF_Async_Call,
  LF_Async_Sequenced_Call,
  LF_Notify,
  LF_Sequenced_Notify,

  // ---- Remote invocation by UID ---------------------------------------------
  LF_UID_Call,
  LF_UID_Async_Call,
  LF_UID_Async_Sequenced_Call,
  LF_UID_Notify,
  LF_UID_Sequenced_Notify,

  // ---- Remote invocation by P2P name ----------------------------------------
  LF_P2PNAME_Call,
  LF_P2PNAME_Async_Call,
  LF_P2PNAME_Async_Sequenced_Call,
  LF_P2PNAME_Notify,
  LF_P2PNAME_Sequenced_Notify,

  // ---- Health checks --------------------------------------------------------
  LF_CheckMainThread,
  LF_CheckApp,
  LF_CheckApi,
  LF_Check_UID,
  LF_Check_UID_Api,
  LF_Check_P2PNAME,
  LF_Check_P2PNAME_Api,

  // ---- Runtime options ------------------------------------------------------
  LF_SetOption,
  LF_GetOption,

  // ---- Status / diagnostics -------------------------------------------------
  LF_GetStatusCount,
  LF_GetStatus,
  LF_PostStatus,

  // ---- Network events -------------------------------------------------------
  LF_Set_Network_Event,

  // ---- Shutdown -------------------------------------------------------------
  LF_Shutdown;

begin
end.
