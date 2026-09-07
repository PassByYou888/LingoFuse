(*
 * =============================================================================
 * lingofuse_helper – High‑Level Object‑Oriented Wrapper for LingoFuse
 * =============================================================================
 *
 * This unit provides a convenient, object‑oriented layer on top of the
 * low‑level `lingofuse_import` unit. It defines two main classes:
 *
 *   – `TDataHandle` : manages a LingoFuse data handle (TDataHnd) with
 *                     automatic memory management (optional ownership) and
 *                     thread‑safe access to its internal state.
 *   – `TAppHandle`  : manages a LingoFuse application handle (TAppHnd) and
 *                     provides method‑based API registration.
 *
 * Additionally, the `LF` class offers static (class) methods that mirror
 * the low‑level functions but operate on these high‑level handles and
 * often include extra convenience (e.g., automatic client preparation).
 *
 * This unit is designed to be used by Pascal developers who prefer an
 * object‑oriented style over flat procedure calls. It hides the complexity
 * of handle lifetime and thread synchronisation, but you must still
 * understand the underlying LingoFuse threading model and callback
 * restrictions.
 *
 * =============================================================================
 * KEY CONCEPTS (INHERITED FROM LINGOFUSE)
 * =============================================================================
 *
 *   – Data Handle (TDataHandle) : A wrapper around a TDataHnd that
 *     automatically frees the handle when the object is destroyed if
 *     `FOwned` is True. If `FOwned` is False, the caller is responsible
 *     for freeing the underlying handle (and must avoid double‑free).
 *     The handle also uses an internal critical section to protect its
 *     own state (`FHandle` and `FDisposed`), but note that concurrent
 *     writes to the same underlying buffer must still be serialised by
 *     the caller.
 *
 *   – Application Handle (TAppHandle) : Wraps a TAppHnd and provides
 *     methods to register Call/Notify APIs using either plain procedures
 *     or object methods. It also offers local call/notification methods.
 *
 *   – Static LF class : Provides global operations such as preparing the
 *     network, making remote calls, and shutting down the library. Many
 *     methods accept or return high‑level handles, freeing you from
 *     manual handle management.
 *
 * =============================================================================
 * THREAD SAFETY (INHERITED)
 * =============================================================================
 *
 *   - All methods of `TDataHandle`, `TAppHandle`, and the static `LF`
 *     class are thread‑safe with respect to the object's own state.
 *     The internal critical sections protect the handle pointer and
 *     disposal flag.
 *
 *   - However, for a given underlying data handle, concurrent writes
 *     are NOT safe. You must use external synchronisation if multiple
 *     threads write to the same `TDataHandle` instance.
 *
 *   - Callbacks registered via `TAppHandle.RegisterCall` (non‑sync) are
 *     executed on background threads. They must be thread‑safe and MUST
 *     NOT call blocking LingoFuse functions. Use the `Sync` variants if
 *     you need to access UI components or non‑thread‑safe objects.
 *
 * =============================================================================
 * TYPICAL USAGE (OBJECT‑ORIENTED STYLE)
 * =============================================================================
 *
 *   // 1. Create an application
 *   var App: TAppHandle;
 *   begin
 *     App := TAppHandle.Create('MyApp', 'Example app');
 *
 *   // 2. Register a Call API using an object method
 *   type
 *     TMyService = class
 *       procedure Echo(Input, Output: TDataHandle);
 *     end;
 *   procedure TMyService.Echo(Input, Output: TDataHandle);
 *   var S: string;
 *   begin
 *     S := Input.ReadString;             // read input (UTF‑8)
 *     Output.WriteStringNullTerminated(S); // write back with trailing #0
 *   end;
 *   var Service: TMyService;
 *   ...
 *   App.RegisterCall('echo', 'Echo service', Service.Echo);
 *
 *   // 3. Prepare network (remote access)
 *   LF.ResetPrepare;
 *   LF.PrepareService('0.0.0.0', '127.0.0.1:9898');   // listen
 *   LF.PrepareClient('127.0.0.1:9898', App);          // connect & expose App
 *   if LF.PrepareDone then
 *     WriteLn('Network ready');
 *
 *   // 4. Make a local call
 *   var Data, Res: TDataHandle;
 *   begin
 *     Data := TDataHandle.Create('echo');
 *     Data.WriteStringNullTerminated('Hello');
 *     Res := App.LocalCall(Data);
 *     WriteLn(Res.ReadString);   // writes 'Hello'
 *     Data.Free;
 *     Res.Free;
 *   end;
 *
 *   // 5. Remote call (same syntax)
 *   Data := TDataHandle.Create('add');
 *   Data.WriteInt32(5).WriteInt32(7);
 *   Res := LF.CallApp('Calculator', Data, 5000);
 *   if Res.Size > 0 then
 *     WriteLn('Result: ', Res.ReadInt32);
 *   Data.Free;
 *   Res.Free;
 *
 *   // 6. Clean up
 *   App.Free;
 *   LF.Shutdown;
 *
 * =============================================================================
 * IMPORTANT PITFALLS
 * =============================================================================
 *
 *   {!!!!!  DATA HANDLE OWNERSHIP  !!!!!}
 *   - By default, a TDataHandle owns its underlying handle (FOwned=True)
 *     and will free it upon destruction. If you create a TDataHandle from
 *     an existing handle with `Owned=False`, you are responsible for
 *     freeing the handle yourself, or you must ensure the handle is not
 *     freed twice.
 *
 *   {!!!!!  CALLBACK OBJECT LIFETIME  !!!!!}
 *   - If you register an object method as a callback, the object must
 *     outlive the callback. If the object is destroyed while a callback
 *     is still pending or executing, the application will crash. Use
 *     weak references or ensure proper synchronisation.
 *
 *   {!!!!!  SYNC VS NON‑SYNC  !!!!!}
 *   - Use `RegisterCallSync` / `RegisterNotifySync` only when you need
 *     to update UI or access thread‑sensitive resources. They are slower
 *     because they queue the callback to the main thread. For high‑
 *     throughput APIs, prefer the non‑sync variants.
 *
 *   {!!!!!  REMOTE CALL TIMEOUT  !!!!!}
 *   - `LF.CallApp` accepts a timeout in milliseconds. A timeout of 0
 *     means infinite wait. On timeout, the returned handle has size 0.
 *     Always check `Data.Size` to detect failures.
 *
 *   {!!!!!  OVERLAP CONNECTION BEHAVIOR  !!!!!}
 *   - The behaviour of `LF.PrepareClient` regarding duplicate addresses
 *     is controlled by the global `Overlap_Connection` option (see
 *     `LF.SetOption`). When `Overlap_Connection = False` (the default),
 *     only one client tunnel is created per address. Subsequent calls
 *     to `LF.PrepareClient` with a **different** `App` will **silently
 *     ignore** the new application handle. The existing tunnel is reused,
 *     and the new `App` is never bound. To host multiple applications
 *     on the same remote service, set `Overlap_Connection = True` before
 *     calling `LF.PrepareClient`, or use `LF.BindApp` to change the
 *     application on an existing client.
 *
 *   {!!!!!  STATUS FUNCTIONS DEPEND ON MAIN THREAD  !!!!!}
 *   - `LF.GetStatus` and `LF.PostStatus` rely on the simulated main
 *     thread to process the status queue. If the main thread has not
 *     been started (i.e., `LF.PrepareDone` has not been called), these
 *     functions will have limited or no effect. Use them only after
 *     the framework is fully initialised.
 *
 * =============================================================================
 * DEPENDENCIES
 * =============================================================================
 *
 *   - This unit depends on `lingofuse_import`, which in turn loads the
 *     LingoFuse dynamic library (LingoFuse64.dll / liblingofuse.so).
 *   - Uses `SyncObjs` for TCriticalSection.
 *
 * =============================================================================
 * COMPATIBILITY
 * =============================================================================
 *
 *   Works with Delphi 2009+ and Free Pascal 3.0+ on Windows, Linux, macOS.
 * =============================================================================
 *)
unit lingofuse_helper;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$CODEPAGE UTF8}
  {$packrecords c}
  {$PACKENUM 4}
{$endif}
{$R-}
{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  lingofuse_import;

type
  { * Alias for TCriticalSection, used internally for thread safety. }
  TCritical = TCriticalSection;

  { * LF: The main class providing high‑level LingoFuse functionality.
    * Contains nested classes TDataHandle and TAppHandle, and static methods
    * for global operations. }
  LF = class
  public
    type
    { * TDataHandle: Manages a LingoFuse data handle (TDataHnd).
      * It provides type‑safe read/write methods and automatic handle
      * freeing on destruction if Owned=True. It also uses an internal lock
      * to protect its own state (FHandle, FDisposed) from concurrent
      * access, but does NOT serialise writes to the underlying buffer.
      *
      * @Example:
      *   var d := TDataHandle.Create('echo');
      *   d.WriteStringNullTerminated('Hello');
      *   // ... use d in a call ...
      *   d.Free;   // frees the underlying handle
      * }
      TDataHandle = class
      private
        FHandle: TDataHnd___;      // underlying opaque handle
        FOwned: boolean;           // if True, LF_FreeData is called on destruction
        FDisposed: boolean;        // prevents double freeing
        FLock: TCritical;          // protects FHandle and FDisposed
        function IsValid: boolean; inline;
      public
        constructor Create(const MethodName: string); overload;
        constructor Create(AHandle: TDataHnd___; const Owned: boolean = False); overload;
        destructor Destroy; override;

        function WriteBuffer(const Buffer; Size: int64): int64;
        function ReadBuffer(var Buffer; Size: int64): int64;

        { ---- Convenience Write Methods (return Self for chaining) ---- }
        function WriteInt8(Value: int8): TDataHandle;
        function WriteUInt8(Value: uint8): TDataHandle;
        function WriteInt16(Value: int16): TDataHandle;
        function WriteUInt16(Value: uint16): TDataHandle;
        function WriteInt32(Value: int32): TDataHandle;
        function WriteUInt32(Value: uint32): TDataHandle;
        function WriteInt64(Value: int64): TDataHandle;
        function WriteUInt64(Value: uint64): TDataHandle;
        function WriteSingle(Value: single): TDataHandle;
        function WriteDouble(Value: double): TDataHandle;
        { * Writes a null‑terminated UTF‑8 string (appends #0). }
        function WriteStringNullTerminated(const Value: string): TDataHandle;
        { * Alias for WriteStringNullTerminated. }
        function WriteString(const Value: string): TDataHandle;
        function WriteStringBytes(const Value: TBytes): TDataHandle;

        { ---- Convenience Read Methods (with out parameters) ---- }
        function ReadInt8(var Value: int8): boolean; overload;
        function ReadUInt8(var Value: uint8): boolean; overload;
        function ReadInt16(var Value: int16): boolean; overload;
        function ReadUInt16(var Value: uint16): boolean; overload;
        function ReadInt32(var Value: int32): boolean; overload;
        function ReadUInt32(var Value: uint32): boolean; overload;
        function ReadInt64(var Value: int64): boolean; overload;
        function ReadUInt64(var Value: uint64): boolean; overload;
        function ReadSingle(var Value: single): boolean; overload;
        function ReadDouble(var Value: double): boolean; overload;

        { ---- Convenience Read Methods (return value directly) ---- }
        function ReadInt8: int8; overload;
        function ReadUInt8: uint8; overload;
        function ReadInt16: int16; overload;
        function ReadUInt16: uint16; overload;
        function ReadInt32: int32; overload;
        function ReadUInt32: uint32; overload;
        function ReadInt64: int64; overload;
        function ReadUInt64: uint64; overload;
        function ReadSingle: single; overload;
        function ReadDouble: double; overload;

        { ---- String Reading ---- }
        function ReadStringBytes(out Buff: TBytes): boolean; overload;
        function ReadStringBytes(): TBytes; overload;
        function ReadStringNullTerminated: string;
        function ReadString(out Value: string): boolean; overload;
        function ReadString(): string; overload;

        { ---- Position/Size ---- }
        function GetPos: int64;
        procedure SetPos(Pos_: int64);
        property Pos: int64 read GetPos write SetPos;

        function GetSize: int64;
        procedure SetSize(Size_: int64);
        property Size: int64 read GetSize write SetSize;

        function GetBufferEx(out Size: int64): Pointer;
        function GetBuffer(): Pointer;

        property Handle: TDataHnd___ read FHandle;
      end;

    { * TAppHandle: Manages a LingoFuse application handle (TAppHnd).
      * It provides methods to register Call/Notify APIs using either
      * plain procedures or object methods, and to invoke them locally.
      * The underlying handle is freed automatically on destruction.
      *
      * @Example:
      *   var App := TAppHandle.Create('MyApp', 'Example');
      *   App.RegisterCall('echo', 'Echo', MyEchoMethod);
      *   // ...
      *   App.Free;
      * }
      TAppHandle = class
      private
        FHandle: TAppHnd___;   // underlying application handle
        FName: string;         // cached application name for convenience
      public
        constructor Create(const AppName, Desc: string);

        { * LF_FreeApp: Detaches an application from all clients and stops its
          * sequenced notification threads, but does NOT immediately destroy the
          * underlying TLF_App object. The object remains alive in the global
          * LF_App_Pool until LF_Shutdown is called, which then frees it forcibly.
          *
          * This two‑phase destruction prevents dangling pointers while allowing
          * other components (e.g., network broadcasts) to continue referencing the
          * application data safely. After calling LF_FreeApp, the handle should be
          * considered invalid and not used for further registrations or calls.
          *
          * @param appHnd  The application handle to detach (can be nil).
          * @see LF_Shutdown  for final cleanup.
          * }
        destructor Destroy; override;

        { * Binds this application to all currently unbound clients.
          * Returns the number of clients bound (0 if none or if the
          * application is already bound). }
        function Bind: integer;

        { * Registers a Call API with a plain cdecl callback (Trigger + TLF_Call_Event). }
        function RegisterCall(const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean; overload;
        { * Registers a Call API with an object method (non‑sync, background thread). }
        function RegisterCall(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean; overload;
        { * Registers a Call API with an object method (sync, main thread). }
        function RegisterCallSync(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;

        { * Registers a Notify API with a plain cdecl callback. }
        function RegisterNotify(const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean; overload;
        { * Registers a Notify API with an object method (non‑sync). }
        function RegisterNotify(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean; overload;
        { * Registers a Notify API with an object method (sync). }
        function RegisterNotifySync(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;

        function Unregister(const MethodName: string): boolean;

        function LocalCall(Param: TDataHandle): TDataHandle;
        procedure LocalNotify(Param: TDataHandle);

        property Handle: TAppHnd___ read FHandle;
        property Name: string read FName;
      end;

  public
    { ---- Static (class) methods for global operations ---- }

    class function Generate_AppName: string;
    class procedure ResetPrepare;

    class function PrepareService(const ListeningAddr, PhysicsAddr: string): integer; overload;
    class function PrepareService(const ListeningAddr, PhysicsAddr: string; App: TAppHandle): integer; overload;
    { * Prepares a client. Note: behaviour depends on global Overlap_Connection
      * setting (see LF.SetOption). If Overlap_Connection=False (default), only
      * one client per address is created and subsequent calls with a different
      * App will be ignored. }
    class function PrepareClient(const PhysicsAddr: string; App: TAppHandle): integer;
    class function PrepareDone: boolean;
    class procedure ExitMainThread;

    class function CallApp(const AppName: string; Param: TDataHandle; TimeoutMs: uint64): TDataHandle;
    class procedure NotifyApp(const AppName: string; Param: TDataHandle);
    class procedure SequencedNotifyApp(const AppName: string; Param: TDataHandle);

    class procedure SetOption(const Option, Value: string);
    class function Sync: integer;
    class procedure Shutdown;

    class function GetStatus: string;
    class function Get_Status_Num: integer;
    class procedure PostStatus(const Status: string);

    class function CheckMainThread: boolean;
    class function CheckApp(const AppName: string): boolean;
    class function CheckApi(AppName, ApiName: string): boolean;
  end;

  { * Alias for LF, for convenience. }
  LingoFuse = LF;

  (* LF___: A compatibility class that mirrors the low‑level functions
   * as static methods. It is provided for migration from older code
   * that used the low‑level import directly.
   *
   * {!!!!!  RECOMMENDATION  !!!!!}
   * For new development, use the higher‑level `LF` class and its nested
   * handles (`TDataHandle`, `TAppHandle`) instead of this compatibility
   * class. The `LF___` class is provided only to ease migration of
   * existing code that directly called the low‑level `LF_*` functions.
   *
   * All methods in this class simply forward to the corresponding
   * functions in `lingofuse_import`. They are fully thread‑safe, but
   * you must manage handle lifetimes manually.
   *)
  LF___ = class
  public
    { ---- Data Handle Operations ---- }

    { * Creates a new data handle with the given API name.
      * @param MethodName  Null‑terminated UTF‑8 API name.
      * @return The new opaque handle.
      * @note You must free the handle with LF_FreeData when done.
      * @see LF_FreeData
      * }
    class function LF_CreateData(MethodName: pansichar): TDataHnd___; static;

    { * Convenience wrapper for LF_CreateData accepting a Pascal string.
      * @param MethodName  Pascal string API name.
      * @return The new opaque handle.
      * }
    class function LF_CreateDataEx(MethodName: string): TDataHnd___; static;

    { * Frees a data handle and releases all associated memory.
      * @param Hnd  The handle to free (can be nil).
      * }
    class procedure LF_FreeData(Hnd: TDataHnd___); static;

    { * Returns a pointer to the raw internal buffer.
      * The pointer is valid until the handle is freed or resized.
      * @param Hnd  The data handle.
      * @return Pointer to the buffer, or nil if empty.
      * }
    class function LF_GetBuffer(Hnd: TDataHnd___): Pointer; static;

    { * Returns a pointer to the buffer at a given byte offset.
      * @param Hnd     The data handle.
      * @param Offset  Byte offset from the start.
      * @return Pointer at the offset, or nil if handle is invalid.
      * }
    class function LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer; static;

    { * Writes binary data to the buffer at the current position.
      * @param Hnd    The data handle.
      * @param Buff   Source data pointer.
      * @param Size   Number of bytes to write.
      * @return Number of bytes actually written.
      * }
    class function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; static;

    { * Reads binary data from the buffer at the current position.
      * @param Hnd    The data handle.
      * @param Buff   Destination buffer pointer.
      * @param Size   Maximum number of bytes to read.
      * @return Number of bytes actually read.
      * }
    class function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; static;

    { ---- Convenience Write Helpers ---- }
    { * Writes an 8‑bit signed integer. Returns True on success. }
    class function LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean; static;
    { * Writes an 8‑bit unsigned integer. }
    class function LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean; static;
    { * Writes a 16‑bit signed integer. }
    class function LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean; static;
    { * Writes a 16‑bit unsigned integer. }
    class function LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean; static;
    { * Writes a 32‑bit signed integer. }
    class function LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean; static;
    { * Writes a 32‑bit unsigned integer. }
    class function LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean; static;
    { * Writes a 64‑bit signed integer. }
    class function LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean; static;
    { * Writes a 64‑bit unsigned integer. }
    class function LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean; static;
    { * Writes a 32‑bit floating‑point value. }
    class function LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean; static;
    { * Writes a 64‑bit floating‑point value. }
    class function LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean; static;
    { * Writes a null‑terminated UTF‑8 string. }
    class function LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean; static;
    { * Writes raw bytes as a null‑terminated sequence. }
    class function LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean; static;

    { ---- Convenience Read Helpers (with out parameters) ---- }
    class function LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean; overload; static;
    class function LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean; overload; static;
    class function LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean; overload; static;
    class function LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean; overload; static;
    class function LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean; overload; static;
    class function LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean; overload; static;
    class function LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean; overload; static;
    class function LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean; overload; static;
    class function LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean; overload; static;
    class function LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean; overload; static;

    { ---- Convenience Read Helpers (return value directly) ---- }
    class function LF_ReadInt8(Hnd: TDataHnd___): int8; overload; static;
    class function LF_ReadUInt8(Hnd: TDataHnd___): uint8; overload; static;
    class function LF_ReadInt16(Hnd: TDataHnd___): int16; overload; static;
    class function LF_ReadUInt16(Hnd: TDataHnd___): uint16; overload; static;
    class function LF_ReadInt32(Hnd: TDataHnd___): int32; overload; static;
    class function LF_ReadUInt32(Hnd: TDataHnd___): uint32; overload; static;
    class function LF_ReadInt64(Hnd: TDataHnd___): int64; overload; static;
    class function LF_ReadUInt64(Hnd: TDataHnd___): uint64; overload; static;
    class function LF_ReadSingle(Hnd: TDataHnd___): single; overload; static;
    class function LF_ReadDouble(Hnd: TDataHnd___): double; overload; static;

    { ---- String Reading ---- }
    class function LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean; overload; static;
    class function LF_ReadStringBytes(Hnd: TDataHnd___): TBytes; overload; static;
    class function LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean; overload; static;
    class function LF_ReadString(Hnd: TDataHnd___): string; overload; static;

    { ---- Position/Size ---- }
    class function LF_GetPos(Hnd: TDataHnd___): int64; static;
    class procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64); static;
    class function LF_GetSize(Hnd: TDataHnd___): int64; static;
    class procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64); static;

    { ---- Application Management ---- }
    class function LF_CreateApp(AppName, Desc: pansichar): TAppHnd___; static;
    class function LF_CreateAppEx(AppName, Desc: string): TAppHnd___; static;

    { * LF_FreeApp: Detaches an application from all clients and stops its
      * sequenced notification threads, but does NOT immediately destroy the
      * underlying TLF_App object. The object remains alive in the global
      * LF_App_Pool until LF_Shutdown is called, which then frees it forcibly.
      *
      * This two‑phase destruction prevents dangling pointers while allowing
      * other components (e.g., network broadcasts) to continue referencing the
      * application data safely. After calling LF_FreeApp, the handle should be
      * considered invalid and not used for further registrations or calls.
      *
      * @param appHnd  The application handle to detach (can be nil).
      * @see LF_Shutdown  for final cleanup.
      * }
    class procedure LF_FreeApp(appHnd: TAppHnd___); static;

    { * Generates a globally unique application name.
      * The name is built from active C4 tunnels, process name, and timestamp.
      * The returned PAnsiChar is valid for 5 seconds; caller must copy it
      * immediately.
      * @return A unique null‑terminated UTF‑8 string.
      * }
    class function LF_Generate_AppName(): pansichar; static;
    class function LF_Generate_AppNameEx(): string; static;

    { * Retrieves the name of an application handle.
      * The returned PAnsiChar is valid for 5 seconds; caller must copy it.
      * @param appHnd  The application handle.
      * @return The application name as UTF‑8.
      * }
    class function LF_Get_AppName(appHnd: TAppHnd___): pansichar; static;
    class function LF_Get_AppNameEx(appHnd: TAppHnd___): string; static;

    { * Binds an application to all currently unbound LingoFuse clients.
      * @param appHnd  The application handle.
      * @return Number of clients bound (0 if none).
      * }
    class function LF_BindApp(appHnd: TAppHnd___): integer; static;

    { ---- API Registration ---- }
    class function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer; static;
    class function LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer; static;
    class function LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer; static;
    class function LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer; static;
    class function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; static;
    class function LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; static;
    class function LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer; static;
    class function LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer; static;

    { * Unregisters an API by name.
      * @param appHnd      The application handle.
      * @param MethodName  API name to remove.
      * @return 1 if removed, 0 if not found.
      * }
    class function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): integer; static;
    class function LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer; static;

    { ---- Local Calls ---- }
    class function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___; static;
    class procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___); static;

    { ---- Network Preparation ---- }
    class procedure LF_ResetPrepare; static;
    class function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): integer; static;
    class function LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer; static;
    class function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): integer; static;
    class function LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer; overload; static;
    class function LF_PrepareClientEx(PhysicsAddr_: string): integer; overload; static;
    class function LF_PrepareDone: integer; static;
    class procedure LF_ExitMainThread; static;

    { ---- Remote Calls ---- }
    class function LF_Call(AppName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class function LF_CallEx(AppName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class procedure LF_Notify(AppName: pansichar; Param: TDataHnd___); static;
    class procedure LF_NotifyEx(AppName: string; Param: TDataHnd___); static;

    { * Sequenced notification (FIFO order per (app, api)). }
    class procedure LF_Sequenced_Notify(AppName: pansichar; Param: TDataHnd___); static;
    class procedure LF_Sequenced_NotifyEx(AppName: string; Param: TDataHnd___); static;

    { ---- Options ---- }
    { * Sets a runtime option. See LF.SetOption for keys. }
    class procedure LF_SetOption(Option, Value: pansichar); static;
    class procedure LF_SetOptionEx(Option, Value: string); static;

    { ---- Synchronisation ---- }
    class function LF_Sync: integer; static;

    { ---- Shutdown ---- }
    class procedure LF_Shutdown; static;

    { ---- Status (read the WARNING above for LF.GetStatus/PostStatus) ---- }
    class function LF_GetStatusCount(): integer; static;
    class function LF_GetStatusEx: string; static;
    class procedure LF_PostStatusEx(const Status: string); static;

    { ---- Queries ---- }
    class function LF_CheckMainThreadEx: boolean; static;
    class function LF_CheckAppEx(const AppName: string): boolean; static;
    class function LF_CheckApiEx(const AppName, ApiName: string): boolean; static;
  end;

  { * Alias for LF___, for compatibility. }
  LingoFuse___ = LF___;

implementation

{ ----------------------------------------------------------------------------
  TDataHandle implementation
  ---------------------------------------------------------------------------- }

function LF.TDataHandle.IsValid: boolean;
begin
  Result := (FHandle <> nil) and not FDisposed;
end;

constructor LF.TDataHandle.Create(const MethodName: string);
begin
  inherited Create;
  FHandle := LF_CreateDataEx(MethodName);
  FOwned := True;
  FDisposed := False;
  FLock := TCritical.Create;
end;

constructor LF.TDataHandle.Create(AHandle: TDataHnd___; const Owned: boolean = False);
begin
  inherited Create;
  FHandle := AHandle;
  FOwned := Owned;
  FDisposed := False;
  FLock := TCritical.Create;
end;

destructor LF.TDataHandle.Destroy;
begin
  FLock.Enter;
  try
    if not FDisposed then
    begin
      if FOwned and (FHandle <> nil) then
        LF_FreeData(FHandle);
      FHandle := nil;
      FDisposed := True;
    end
  finally
    FLock.Leave;
  end;
  FLock.Free;
  inherited;
end;

function LF.TDataHandle.WriteBuffer(const Buffer; Size: int64): int64;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_WriteBuffer(FHandle, @Buffer, Size);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadBuffer(var Buffer; Size: int64): int64;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadBuffer(FHandle, @Buffer, Size);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt8(Value: int8): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteInt8(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt8(Value: uint8): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteUInt8(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt16(Value: int16): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteInt16(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt16(Value: uint16): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteUInt16(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt32(Value: int32): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteInt32(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt32(Value: uint32): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteUInt32(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt64(Value: int64): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteInt64(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt64(Value: uint64): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteUInt64(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteSingle(Value: single): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteSingle(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteDouble(Value: double): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteDouble(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteStringNullTerminated(const Value: string): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteString(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteString(const Value: string): TDataHandle;
begin
  Result := WriteStringNullTerminated(Value);
end;

function LF.TDataHandle.WriteStringBytes(const Value: TBytes): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then
      LF_WriteStringBytes(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt8(var Value: int8): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadInt8(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt8(var Value: uint8): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadUInt8(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt16(var Value: int16): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadInt16(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt16(var Value: uint16): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadUInt16(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt32(var Value: int32): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadInt32(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt32(var Value: uint32): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadUInt32(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt64(var Value: int64): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadInt64(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt64(var Value: uint64): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadUInt64(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadSingle(var Value: single): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadSingle(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadDouble(var Value: double): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadDouble(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt8: int8;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadInt8(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt8: uint8;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadUInt8(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt16: int16;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadInt16(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt16: uint16;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadUInt16(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt32: int32;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadInt32(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt32: uint32;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadUInt32(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt64: int64;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadInt64(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt64: uint64;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_ReadUInt64(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadSingle: single;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0.0
    else
      Result := LF_ReadSingle(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadDouble: double;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0.0
    else
      Result := LF_ReadDouble(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadStringBytes(out Buff: TBytes): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := False
    else
      Result := LF_ReadStringBytes(FHandle, Buff);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadStringBytes(): TBytes;
begin
  FLock.Enter;
  try
    if not IsValid then
      SetLength(Result, 0)
    else
      Result := LF_ReadStringBytes(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadStringNullTerminated: string;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := ''
    else
      Result := LF_ReadString(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadString(out Value: string): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
    begin
      Value := '';
      Result := False;
    end
    else
      Result := LF_ReadString(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadString(): string;
begin
  Result := ReadStringNullTerminated();
end;

function LF.TDataHandle.GetPos: int64;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_GetPos(FHandle);
  finally
    FLock.Leave;
  end;
end;

procedure LF.TDataHandle.SetPos(Pos_: int64);
begin
  FLock.Enter;
  try
    if IsValid then
      LF_SetPos(FHandle, Pos_);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.GetSize: int64;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := 0
    else
      Result := LF_GetSize(FHandle);
  finally
    FLock.Leave;
  end;
end;

procedure LF.TDataHandle.SetSize(Size_: int64);
begin
  FLock.Enter;
  try
    if IsValid then
      LF_SetSize(FHandle, Size_);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.GetBufferEx(out Size: int64): Pointer;
begin
  FLock.Enter;
  try
    if not IsValid then
    begin
      Size := 0;
      Result := nil;
    end
    else
    begin
      Result := LF_GetBuffer(FHandle);
      Size := LF_GetSize(FHandle);
    end;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.GetBuffer(): Pointer;
begin
  FLock.Enter;
  try
    if not IsValid then
      Result := nil
    else
      Result := LF_GetBuffer(FHandle);
  finally
    FLock.Leave;
  end;
end;

{ ----------------------------------------------------------------------------
  TAppHandle implementation
  ---------------------------------------------------------------------------- }

constructor LF.TAppHandle.Create(const AppName, Desc: string);
begin
  inherited Create;
  FHandle := LF_CreateAppEx(AppName, Desc);
  FName := AppName;
end;

destructor LF.TAppHandle.Destroy;
begin
  if FHandle <> nil then
    LF_FreeApp(FHandle);
  inherited;
end;

function LF.TAppHandle.Bind: integer;
begin
  if FHandle = nil then
    Result := 0
  else
    Result := LF_BindApp(FHandle);
end;

function LF.TAppHandle.RegisterCall(const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean;
begin
  if FHandle = nil then
    Result := False
  else
    Result := LF_RegisterCallEx(FHandle, MethodName, Desc, Trigger, OnCall) = 1;
end;

function LF.TAppHandle.RegisterCall(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin
  if FHandle = nil then
    Result := False
  else
    Result := LF_RegisterCall_M(FHandle, MethodName, Desc, OnCall) = 1;
end;

function LF.TAppHandle.RegisterCallSync(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin
  if FHandle = nil then
    Result := False
  else
    Result := LF_RegisterSyncCall_M(FHandle, MethodName, Desc, OnCall) = 1;
end;

function LF.TAppHandle.RegisterNotify(const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean;
begin
  if FHandle = nil then
    Result := False
  else
    Result := LF_RegisterNotifyEx(FHandle, MethodName, Desc, Trigger, OnNotify) = 1;
end;

function LF.TAppHandle.RegisterNotify(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin
  if FHandle = nil then
    Result := False
  else
    Result := LF_RegisterNotify_M(FHandle, MethodName, Desc, OnNotify) = 1;
end;

function LF.TAppHandle.RegisterNotifySync(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin
  if FHandle = nil then
    Result := False
  else
    Result := LF_RegisterSyncNotify_M(FHandle, MethodName, Desc, OnNotify) = 1;
end;

function LF.TAppHandle.Unregister(const MethodName: string): boolean;
begin
  if FHandle = nil then
    Result := False
  else
    Result := LF_UnregisterEx(FHandle, MethodName) = 1;
end;

function LF.TAppHandle.LocalCall(Param: TDataHandle): TDataHandle;
var
  Res: TDataHnd___;
begin
  if FHandle = nil then
    Result := TDataHandle.Create(nil, True)
  else
  begin
    Res := LF_LocalCall(FHandle, Param.Handle);
    Result := TDataHandle.Create(Res, True);
  end;
end;

procedure LF.TAppHandle.LocalNotify(Param: TDataHandle);
begin
  if FHandle <> nil then
    LF_LocalNotify(FHandle, Param.Handle);
end;

{ ----------------------------------------------------------------------------
  Static LF class methods (forwarding with convenience)
  ---------------------------------------------------------------------------- }

class function LF.Generate_AppName: string;
begin
  Result := LF_Generate_AppNameEx();
end;

class procedure LF.ResetPrepare;
begin
  LF_ResetPrepare;
end;

class function LF.PrepareService(const ListeningAddr, PhysicsAddr: string): integer;
begin
  Result := LF_PrepareServiceEx(ListeningAddr, PhysicsAddr);
end;

class function LF.PrepareService(const ListeningAddr, PhysicsAddr: string; App: TAppHandle): integer;
begin
  Result := LF_PrepareServiceEx(ListeningAddr, PhysicsAddr);
  if Result <> 0 then
    PrepareClient(PhysicsAddr, App);
end;

class function LF.PrepareClient(const PhysicsAddr: string; App: TAppHandle): integer;
begin
  if Assigned(App) then
    Result := LF_PrepareClientEx(PhysicsAddr, App.Handle)
  else
    Result := LF_PrepareClientEx(PhysicsAddr);
end;

class function LF.PrepareDone: boolean;
begin
  Result := LF_PrepareDone = 1;
end;

class procedure LF.ExitMainThread;
begin
  LF_ExitMainThread;
end;

class function LF.CallApp(const AppName: string; Param: TDataHandle; TimeoutMs: uint64): TDataHandle;
var
  Res: TDataHnd___;
begin
  Res := LF_CallEx(AppName, Param.Handle, TimeoutMs);
  Result := TDataHandle.Create(Res, True);
end;

class procedure LF.NotifyApp(const AppName: string; Param: TDataHandle);
begin
  LF_NotifyEx(AppName, Param.Handle);
end;

class procedure LF.SequencedNotifyApp(const AppName: string; Param: TDataHandle);
begin
  LF_Sequenced_NotifyEx(AppName, Param.Handle);
end;

class procedure LF.SetOption(const Option, Value: string);
begin
  LF_SetOptionEx(Option, Value);
end;

class function LF.Sync: integer;
begin
  Result := LF_Sync;
end;

class procedure LF.Shutdown;
begin
  LF_Shutdown;
end;

class function LF.GetStatus: string;
begin
  Result := LF_GetStatusEx;
end;

class function LF.Get_Status_Num: integer;
begin
  Result := LF_GetStatusCount;
end;

class procedure LF.PostStatus(const Status: string);
begin
  LF_PostStatusEx(Status);
end;

class function LF.CheckMainThread: boolean;
begin
  Result := LF_CheckMainThreadEx;
end;

class function LF.CheckApp(const AppName: string): boolean;
begin
  Result := LF_CheckAppEx(AppName);
end;

class function LF.CheckApi(AppName, ApiName: string): boolean;
begin
  Result := LF_CheckApiEx(AppName, ApiName);
end;

{ ----------------------------------------------------------------------------
  LF___ compatibility class – forwards to lingofuse_import
  ---------------------------------------------------------------------------- }
class function LF___.LF_CreateData(MethodName: pansichar): TDataHnd___;
begin
  Result := lingofuse_import.LF_CreateData(MethodName);
end;

class function LF___.LF_CreateDataEx(MethodName: string): TDataHnd___;
begin
  Result := lingofuse_import.LF_CreateDataEx(MethodName);
end;

class procedure LF___.LF_FreeData(Hnd: TDataHnd___);
begin
  lingofuse_import.LF_FreeData(Hnd);
end;

class function LF___.LF_GetBuffer(Hnd: TDataHnd___): Pointer;
begin
  Result := lingofuse_import.LF_GetBuffer(Hnd);
end;

class function LF___.LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer;
begin
  Result := lingofuse_import.LF_GetBufferOffset(Hnd, Offset);
end;

class function LF___.LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin
  Result := lingofuse_import.LF_WriteBuffer(Hnd, Buff, Size);
end;

class function LF___.LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin
  Result := lingofuse_import.LF_ReadBuffer(Hnd, Buff, Size);
end;

class function LF___.LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean;
begin
  Result := lingofuse_import.LF_WriteInt8(Hnd, Value);
end;

class function LF___.LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean;
begin
  Result := lingofuse_import.LF_WriteUInt8(Hnd, Value);
end;

class function LF___.LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean;
begin
  Result := lingofuse_import.LF_WriteInt16(Hnd, Value);
end;

class function LF___.LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean;
begin
  Result := lingofuse_import.LF_WriteUInt16(Hnd, Value);
end;

class function LF___.LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean;
begin
  Result := lingofuse_import.LF_WriteInt32(Hnd, Value);
end;

class function LF___.LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean;
begin
  Result := lingofuse_import.LF_WriteUInt32(Hnd, Value);
end;

class function LF___.LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean;
begin
  Result := lingofuse_import.LF_WriteInt64(Hnd, Value);
end;

class function LF___.LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean;
begin
  Result := lingofuse_import.LF_WriteUInt64(Hnd, Value);
end;

class function LF___.LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean;
begin
  Result := lingofuse_import.LF_WriteSingle(Hnd, Value);
end;

class function LF___.LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean;
begin
  Result := lingofuse_import.LF_WriteDouble(Hnd, Value);
end;

class function LF___.LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean;
begin
  Result := lingofuse_import.LF_WriteString(Hnd, Value);
end;

class function LF___.LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean;
begin
  Result := lingofuse_import.LF_WriteStringBytes(Hnd, Value);
end;

class function LF___.LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean;
begin
  Result := lingofuse_import.LF_ReadInt8(Hnd, Value);
end;

class function LF___.LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean;
begin
  Result := lingofuse_import.LF_ReadUInt8(Hnd, Value);
end;

class function LF___.LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean;
begin
  Result := lingofuse_import.LF_ReadInt16(Hnd, Value);
end;

class function LF___.LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean;
begin
  Result := lingofuse_import.LF_ReadUInt16(Hnd, Value);
end;

class function LF___.LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean;
begin
  Result := lingofuse_import.LF_ReadInt32(Hnd, Value);
end;

class function LF___.LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean;
begin
  Result := lingofuse_import.LF_ReadUInt32(Hnd, Value);
end;

class function LF___.LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean;
begin
  Result := lingofuse_import.LF_ReadInt64(Hnd, Value);
end;

class function LF___.LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean;
begin
  Result := lingofuse_import.LF_ReadUInt64(Hnd, Value);
end;

class function LF___.LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean;
begin
  Result := lingofuse_import.LF_ReadSingle(Hnd, Value);
end;

class function LF___.LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean;
begin
  Result := lingofuse_import.LF_ReadDouble(Hnd, Value);
end;

class function LF___.LF_ReadInt8(Hnd: TDataHnd___): int8;
begin
  Result := lingofuse_import.LF_ReadInt8(Hnd);
end;

class function LF___.LF_ReadUInt8(Hnd: TDataHnd___): uint8;
begin
  Result := lingofuse_import.LF_ReadUInt8(Hnd);
end;

class function LF___.LF_ReadInt16(Hnd: TDataHnd___): int16;
begin
  Result := lingofuse_import.LF_ReadInt16(Hnd);
end;

class function LF___.LF_ReadUInt16(Hnd: TDataHnd___): uint16;
begin
  Result := lingofuse_import.LF_ReadUInt16(Hnd);
end;

class function LF___.LF_ReadInt32(Hnd: TDataHnd___): int32;
begin
  Result := lingofuse_import.LF_ReadInt32(Hnd);
end;

class function LF___.LF_ReadUInt32(Hnd: TDataHnd___): uint32;
begin
  Result := lingofuse_import.LF_ReadUInt32(Hnd);
end;

class function LF___.LF_ReadInt64(Hnd: TDataHnd___): int64;
begin
  Result := lingofuse_import.LF_ReadInt64(Hnd);
end;

class function LF___.LF_ReadUInt64(Hnd: TDataHnd___): uint64;
begin
  Result := lingofuse_import.LF_ReadUInt64(Hnd);
end;

class function LF___.LF_ReadSingle(Hnd: TDataHnd___): single;
begin
  Result := lingofuse_import.LF_ReadSingle(Hnd);
end;

class function LF___.LF_ReadDouble(Hnd: TDataHnd___): double;
begin
  Result := lingofuse_import.LF_ReadDouble(Hnd);
end;

class function LF___.LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean;
begin
  Result := lingofuse_import.LF_ReadStringBytes(Hnd, Buff);
end;

class function LF___.LF_ReadStringBytes(Hnd: TDataHnd___): TBytes;
begin
  Result := lingofuse_import.LF_ReadStringBytes(Hnd);
end;

class function LF___.LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean;
begin
  Result := lingofuse_import.LF_ReadString(Hnd, Value);
end;

class function LF___.LF_ReadString(Hnd: TDataHnd___): string;
begin
  Result := lingofuse_import.LF_ReadString(Hnd);
end;

class function LF___.LF_GetPos(Hnd: TDataHnd___): int64;
begin
  Result := lingofuse_import.LF_GetPos(Hnd);
end;

class procedure LF___.LF_SetPos(Hnd: TDataHnd___; Pos_: int64);
begin
  lingofuse_import.LF_SetPos(Hnd, Pos_);
end;

class function LF___.LF_GetSize(Hnd: TDataHnd___): int64;
begin
  Result := lingofuse_import.LF_GetSize(Hnd);
end;

class procedure LF___.LF_SetSize(Hnd: TDataHnd___; Size_: int64);
begin
  lingofuse_import.LF_SetSize(Hnd, Size_);
end;

class function LF___.LF_CreateApp(AppName, Desc: pansichar): TAppHnd___;
begin
  Result := lingofuse_import.LF_CreateApp(AppName, Desc);
end;

class function LF___.LF_CreateAppEx(AppName, Desc: string): TAppHnd___;
begin
  Result := lingofuse_import.LF_CreateAppEx(AppName, Desc);
end;

class procedure LF___.LF_FreeApp(appHnd: TAppHnd___);
begin
  lingofuse_import.LF_FreeApp(appHnd);
end;

class function LF___.LF_Generate_AppName(): pansichar;
begin
  Result := lingofuse_import.LF_Generate_AppName();
end;

class function LF___.LF_Generate_AppNameEx(): string;
begin
  Result := lingofuse_import.LF_Generate_AppNameEx();
end;

class function LF___.LF_Get_AppName(appHnd: TAppHnd___): pansichar;
begin
  Result := lingofuse_import.LF_Get_AppName(appHnd);
end;

class function LF___.LF_Get_AppNameEx(appHnd: TAppHnd___): string;
begin
  Result := lingofuse_import.LF_Get_AppNameEx(appHnd);
end;

class function LF___.LF_BindApp(appHnd: TAppHnd___): integer;
begin
  Result := lingofuse_import.LF_BindApp(appHnd);
end;

class function LF___.LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin
  Result := lingofuse_import.LF_RegisterCall(appHnd, MethodName, Desc, Trigger, OnCall);
end;

class function LF___.LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin
  Result := lingofuse_import.LF_RegisterCallEx(appHnd, MethodName, Desc, Trigger, OnCall);
end;

class function LF___.LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin
  Result := lingofuse_import.LF_RegisterCall_M(appHnd, MethodName, Desc, OnCall);
end;

class function LF___.LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin
  Result := lingofuse_import.LF_RegisterSyncCall_M(appHnd, MethodName, Desc, OnCall);
end;

class function LF___.LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin
  Result := lingofuse_import.LF_RegisterNotify(appHnd, MethodName, Desc, Trigger, OnNotify);
end;

class function LF___.LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin
  Result := lingofuse_import.LF_RegisterNotifyEx(appHnd, MethodName, Desc, Trigger, OnNotify);
end;

class function LF___.LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin
  Result := lingofuse_import.LF_RegisterNotify_M(appHnd, MethodName, Desc, OnNotify);
end;

class function LF___.LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin
  Result := lingofuse_import.LF_RegisterSyncNotify_M(appHnd, MethodName, Desc, OnNotify);
end;

class function LF___.LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): integer;
begin
  Result := lingofuse_import.LF_Unregister(appHnd, MethodName);
end;

class function LF___.LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer;
begin
  Result := lingofuse_import.LF_UnregisterEx(appHnd, MethodName);
end;

class function LF___.LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___;
begin
  Result := lingofuse_import.LF_LocalCall(appHnd, Param);
end;

class procedure LF___.LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___);
begin
  lingofuse_import.LF_LocalNotify(appHnd, Param);
end;

class procedure LF___.LF_ResetPrepare;
begin
  lingofuse_import.LF_ResetPrepare;
end;

class function LF___.LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): integer;
begin
  Result := lingofuse_import.LF_PrepareService(ListeningAddr_, PhysicsAddr_);
end;

class function LF___.LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer;
begin
  Result := lingofuse_import.LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_);
end;

class function LF___.LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): integer;
begin
  Result := lingofuse_import.LF_PrepareClient(PhysicsAddr_, appHnd);
end;

class function LF___.LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer;
begin
  Result := lingofuse_import.LF_PrepareClientEx(PhysicsAddr_, appHnd);
end;

class function LF___.LF_PrepareClientEx(PhysicsAddr_: string): integer;
begin
  Result := lingofuse_import.LF_PrepareClientEx(PhysicsAddr_);
end;

class function LF___.LF_PrepareDone: integer;
begin
  Result := lingofuse_import.LF_PrepareDone;
end;

class procedure LF___.LF_ExitMainThread;
begin
  lingofuse_import.LF_ExitMainThread;
end;

class function LF___.LF_Call(AppName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin
  Result := lingofuse_import.LF_Call(AppName, Param, Timeout_);
end;

class function LF___.LF_CallEx(AppName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin
  Result := lingofuse_import.LF_CallEx(AppName, Param, Timeout_);
end;

class procedure LF___.LF_Notify(AppName: pansichar; Param: TDataHnd___);
begin
  lingofuse_import.LF_Notify(AppName, Param);
end;

class procedure LF___.LF_NotifyEx(AppName: string; Param: TDataHnd___);
begin
  lingofuse_import.LF_NotifyEx(AppName, Param);
end;

class procedure LF___.LF_Sequenced_Notify(AppName: pansichar; Param: TDataHnd___);
begin
  lingofuse_import.LF_Sequenced_Notify(AppName, Param);
end;

class procedure LF___.LF_Sequenced_NotifyEx(AppName: string; Param: TDataHnd___);
begin
  lingofuse_import.LF_Sequenced_NotifyEx(AppName, Param);
end;

class procedure LF___.LF_SetOption(Option, Value: pansichar);
begin
  lingofuse_import.LF_SetOption(Option, Value);
end;

class procedure LF___.LF_SetOptionEx(Option, Value: string);
begin
  lingofuse_import.LF_SetOptionEx(Option, Value);
end;

class function LF___.LF_Sync: integer;
begin
  Result := lingofuse_import.LF_Sync;
end;

class procedure LF___.LF_Shutdown;
begin
  lingofuse_import.LF_Shutdown;
end;

class function LF___.LF_GetStatusCount(): integer;
begin
  Result := lingofuse_import.LF_GetStatusCount;
end;

class function LF___.LF_GetStatusEx: string;
begin
  Result := lingofuse_import.LF_GetStatusEx;
end;

class procedure LF___.LF_PostStatusEx(const Status: string);
begin
  lingofuse_import.LF_PostStatusEx(Status);
end;

class function LF___.LF_CheckMainThreadEx: boolean;
begin
  Result := lingofuse_import.LF_CheckMainThreadEx;
end;

class function LF___.LF_CheckAppEx(const AppName: string): boolean;
begin
  Result := lingofuse_import.LF_CheckAppEx(AppName);
end;

class function LF___.LF_CheckApiEx(const AppName, ApiName: string): boolean;
begin
  Result := lingofuse_import.LF_CheckApiEx(AppName, ApiName);
end;

end.
