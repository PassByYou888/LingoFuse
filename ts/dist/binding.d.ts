import koffi = require("koffi");
/** Platform-specific shared library file name. */
export declare function selectPlatformFileName(): string;
/** Ordered list of candidate absolute paths for the native library. */
export declare function buildSearchPaths(): readonly string[];
/** Callback prototype for Call-mode (request-response) APIs. */
export declare const LfCallFuncProto: koffi.TypeObject;
/** Callback prototype for Notify-mode (one-way) APIs. */
export declare const LfNotifyFuncProto: koffi.TypeObject;
/** Callback prototype for network connect / disconnect events. */
export declare const LfNetworkEventFuncProto: koffi.TypeObject;
/** Pointer types derived from the callback prototypes. */
export declare const LfCallFuncPtr: koffi.TypeObject;
export declare const LfNotifyFuncPtr: koffi.TypeObject;
export declare const LfNetworkEventFuncPtr: koffi.TypeObject;
/**
 * Function table for the 36 exported LingoFuse functions.
 *
 * FFI-boundary parameters are typed as `any`; the interface exists to
 * name the functions and to pin their return types.
 */
export interface NativeFunctions {
    LF_CreateData(methodName: string): any;
    LF_FreeData(hnd: any): void;
    LF_GetBuffer(hnd: any): any;
    LF_WriteBuffer(hnd: any, buff: Uint8Array, size: any): any;
    LF_ReadBuffer(hnd: any, buff: Uint8Array, size: any): any;
    LF_GetPos(hnd: any): any;
    LF_SetPos(hnd: any, pos: any): void;
    LF_GetSize(hnd: any): any;
    LF_SetSize(hnd: any, size: any): void;
    LF_CreateApp(appName: string, desc: string): any;
    LF_FreeApp(appHnd: any): void;
    LF_Generate_AppName(): string;
    LF_Get_AppName(appHnd: any): string;
    LF_BindApp(appHnd: any): number;
    LF_RegisterCall(appHnd: any, methodName: string, desc: string, trigger: any, onCall: any): number;
    LF_RegisterNotify(appHnd: any, methodName: string, desc: string, trigger: any, onNotify: any): number;
    LF_Unregister(appHnd: any, methodName: string): number;
    LF_LocalCall(appHnd: any, param: any): any;
    LF_LocalNotify(appHnd: any, param: any): void;
    LF_ResetPrepare(): void;
    LF_PrepareService(listeningAddr: string, physicsAddr: string): number;
    LF_PrepareClient(physicsAddr: string, appHnd: any): number;
    LF_PrepareDone(): number;
    LF_ExitMainThread(): void;
    LF_Call(appName: string, param: any, timeoutMs: any): any;
    LF_Notify(appName: string, param: any): void;
    LF_Sequenced_Notify(appName: string, param: any): void;
    LF_SetOption(option: string, value: string): void;
    LF_GetStatusCount(): number;
    LF_GetStatus(): string;
    LF_PostStatus(status: string): void;
    LF_CheckMainThread(): number;
    LF_CheckApp(appName: string): number;
    LF_CheckApi(appName: string, apiName: string): number;
    LF_Shutdown(): void;
    LF_Set_Network_Event(onConnect: any, onDisconnect: any): void;
}
/** Binding singleton contents. */
export interface Binding {
    readonly koffi: typeof koffi;
    readonly libraryName: string;
    readonly platform: string;
    readonly funcs: NativeFunctions;
}
/** Return the binding singleton, loading the library on first call. */
export declare function getBinding(): Binding;
/** Returns true when the native binding has been successfully loaded. */
export declare function isLoaded(): boolean;
/**
 * Expose the Koffi module for advanced use (custom types, direct
 * declarations). Normal application code should not need this.
 */
export { koffi };
//# sourceMappingURL=binding.d.ts.map