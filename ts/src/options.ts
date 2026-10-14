// =============================================================================
//  options.ts
// -----------------------------------------------------------------------------
//  Typed shortcuts for the LingoFuse runtime options.
//
//  This module exposes one typed getter/setter pair for each runtime
//  option that the LingoFuse C ABI recognises. The pairs mirror, one
//  for one, the convenience functions defined by the Pascal-side
//  lingofuse_import.pas unit and by the JavaScript binding's
//  lingofuse-js/options module:
//
//      Pascal / C#                     TypeScript (this module)
//      ------------------------------- -------------------------------
//      LF_Set_Opt_Debug / Get          setOptDebug / getOptDebug
//      LF_Set_Opt_P2P_Name / Get       setOptP2PName / getOptP2PName
//      LF_Set_Opt_Password / Get       setOptPassword / getOptPassword
//      LF_Set_Opt_Quiet / Get          setOptQuiet / getOptQuiet
//      ... (16 pairs in total)
//
//  THREE HARD RULES
//  ----------------
//
//  [1] SETTERS ARE ASYNCHRONOUS AFTER prepareDone().
//      Once the simulated main thread is running, LF_SetOption is
//      posted to that thread and applied on the next tick. A getter
//      called immediately after a setter may still observe the old
//      value. Callers that need to confirm a write must yield for at
//      least one main-thread tick (100-150 ms is a safe budget).
//      Before prepareDone() the setter is synchronous.
//
//  [2] UNKNOWN OPTION NAMES ARE SILENTLY IGNORED.
//      LF_SetOption has no return value and does not report an error
//      when it receives an unrecognised option name. The typed
//      shortcuts below eliminate that failure mode by hard-coding the
//      canonical name. Generic setOption(name, value) in framework.ts
//      remains available for dynamic names, and it retains the silent
//      failure behaviour.
//
//  [3] OPTIONS ARE NOT PERSISTED ACROSS LF_Shutdown.
//      Every option is reset to its built-in default when the framework
//      is shut down. An application that restarts the framework must
//      reapply its options on every startup.
//
//  THE OPTION CONSTANTS
//  --------------------
//  The Option object below lists the canonical option name for each
//  pair, along with the aliases the native parser also accepts. The
//  typed shortcuts hard-code the canonical name; the constants are
//  provided for callers that pass names to framework.setOption() /
//  framework.getOption() directly.
//
//  All code and documentation are in English.
// =============================================================================

import { getBinding } from "./binding";
import type { NativeFunctions } from "./binding";

// -----------------------------------------------------------------------------
//  Internal helpers
// -----------------------------------------------------------------------------

let _funcs: NativeFunctions | null = null;
function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

/**
 * Write a string option value. No validation; the native parser is
 * responsible for interpreting the value.
 */
function _setStr(name: string, value: string): void {
    funcs().LF_SetOption(name, value);
}

/**
 * Read a string option value. The native LF_GetOption returns a UTF-8
 * string; unknown option names yield an empty string. Koffi's `str`
 * return type copies the string on the call boundary, so the value is
 * safe to retain.
 */
function _getStr(name: string): string {
    const v = funcs().LF_GetOption(name);
    return typeof v === "string" ? v : "";
}

/** Write a boolean option using the canonical "True" / "False" spelling. */
function _setBool(name: string, value: boolean): void {
    _setStr(name, value ? "True" : "False");
}

/**
 * Read a boolean option. The native parser is case-insensitive on
 * values, but every writer in this binding emits the canonical
 * "True" / "False" spellings, so a simple lowercase comparison is
 * sufficient.
 */
function _getBool(name: string): boolean {
    return _getStr(name).trim().toLowerCase() === "true";
}

/** Write an integer option. Throws on a non-finite number. */
function _setInt(name: string, value: number): void {
    const n = Number(value);
    if (!Number.isFinite(n)) {
        throw new TypeError(
            `Option '${name}': expected a finite number, got ${value}.`);
    }
    _setStr(name, String(Math.trunc(n)));
}

/** Read an integer option. Returns 0 when the value cannot be parsed. */
function _getInt(name: string): number {
    const v = _getStr(name);
    if (v.length === 0) return 0;
    const n = Number.parseInt(v, 10);
    return Number.isFinite(n) ? n : 0;
}

// -----------------------------------------------------------------------------
//  Option name constants
// -----------------------------------------------------------------------------

/**
 * Canonical runtime option names.
 *
 * The types are `as const` so that `Option.QUIET` has the literal type
 * `"Quiet"` rather than the widened `string`. This lets the helpers in
 * address.ts and the tests refer to specific values with full type
 * safety.
 *
 * Each JSDoc block lists the aliases the native parser also accepts.
 * The typed shortcuts below always use the canonical spelling.
 */
export const Option = {
    /** C4 P2PVM authentication token. Alias: "passwd". */
    PASSWORD: "password",
    /** Quiet mode: suppress most log output. */
    QUIET: "Quiet",
    /** Show thread IDs in log output. Aliases: "ShowThread", "Show_Thread". */
    SHOW_THREAD_ID: "ShowThreadID",
    /** Enable or disable console output. Alias: "Console_Output". */
    CONSOLE_OUTPUT: "ConsoleOutput",
    /**
     * Allow multiple client tunnels to the same remote address.
     * Aliases: "Overlap_Client", "OverlapConnection", "OverlapClient",
     * "OverlapConnect".
     */
    OVERLAP_CONNECTION: "Overlap_Connection",
    /**
     * Block PrepareDone until all prepared clients are ready.
     * Aliases: "Wait_API_Prepare_Done", "API_Prepare_Done_Wait",
     * "WaitConnect", "Wait_Ready", "WaitReady".
     */
    WAIT_CONNECTION_READY_OK: "Wait_Connection_ReadyOk",
    /**
     * Timeout (milliseconds) for the above wait.
     * Aliases: "Wait_TimeOut", "API_Prepare_Done_TimeOut", "WaitTimeOut".
     */
    WAIT_CONNECTION_TIMEOUT: "Wait_Connection_Timeout",
    /**
     * Number of threads in the IPC server thread pool.
     * Aliases: "IPC_ThreadCount", "IPC_Server_ThreadCount".
     */
    IPC_SERV_THREAD_COUNT: "IPC_Serv_ThreadCount",
    /**
     * Maximum IPC message queue length.
     * Aliases: "IPC_MaxQueueLength", "IPC_Server_MaxQueueLength".
     */
    IPC_SERV_MAX_QUEUE_LENGTH: "IPC_Serv_MaxQueueLength",
    /**
     * Maximum size of a single IPC message, in bytes.
     * Aliases: "IPC_MaxMsgSize", "IPC_Server_MaxMsgSize".
     */
    IPC_SERV_MAX_MSG_SIZE: "IPC_Serv_MaxMsgSize",
    /**
     * Sequenced Notify sticky-affinity window (milliseconds).
     * Alias: "Fixed_Sequenced_Life".
     */
    FIXED_SEQUENCED_TIME: "Fixed_Sequenced_Time",
    /**
     * Local P2P group name.
     * Alias: "P2P_name".
     */
    P2P_NAME: "LF_P2P_name",
    /**
     * Idle-reclaim threshold for auto-recycled data handles
     * (milliseconds).
     */
    DATA_HANDLE_IDLE_TIMEOUT: "DataHandle_Idle_Timeout",
    /**
     * Minimum interval between two consecutive data handle pool scans
     * (milliseconds).
     */
    DATA_HANDLE_POOL_SCAN_INTERVAL: "DataHandle_Pool_Scan_Interval",
    /**
     * Null-flush threshold for no-response commands.
     *
     * SPELLING NOTE: the option key uses the historical spelling
     * "Reponse" (without the second 's'). Both the function name and
     * the option key are intentional.
     */
    NO_REPONSE_CMD_NULL_FLUSH_THRESHOLD:
        "No_Reponse_Cmd_NULL_Flush_Threshold",
    /** Write-only C4 console command. */
    DEBUG: "debug",
} as const;

/** Union of all canonical option names. */
export type OptionName = (typeof Option)[keyof typeof Option];

/** Canonical string form of a boolean option value. */
export type BooleanOptionValue = "True" | "False";

/**
 * Convert a boolean to the canonical option value string.
 *
 * The native parser is case-insensitive on option names but accepts
 * "True" / "False" as the canonical spellings. Using this helper
 * removes the risk of writing "true" and silently leaving the option
 * unchanged in a build where value matching is case-sensitive.
 */
export function bool(value: boolean): BooleanOptionValue {
    return value ? "True" : "False";
}

// -----------------------------------------------------------------------------
//  Authentication
// -----------------------------------------------------------------------------

/**
 * Set the P2PVM / C4 network authentication password.
 * Underlying option key: "password".
 */
export function setOptPassword(value: string): void {
    if (typeof value !== "string") {
        throw new TypeError("setOptPassword: value must be a string.");
    }
    _setStr(Option.PASSWORD, value);
}

/**
 * Read the configured password. The native side returns a fixed mask
 * ("********"), never the real value.
 */
export function getOptPassword(): string {
    return _getStr(Option.PASSWORD);
}

// -----------------------------------------------------------------------------
//  Logging and diagnostics
// -----------------------------------------------------------------------------

/**
 * Execute a C4 console debug command. Write-only; each call constructs
 * a transient helper object on the Pascal side.
 *
 * WARNING: some commands ("service", "tunnel", "ZNet_Info", ...)
 * perform live queries against the C4 pool and can leave an
 * asynchronous task pending. See the JavaScript binding's test suite
 * for the diagnostic consequences.
 */
export function setOptDebug(value: string): void {
    if (typeof value !== "string") {
        throw new TypeError("setOptDebug: value must be a string.");
    }
    _setStr(Option.DEBUG, value);
}

/**
 * Read the debug option. The native side returns a fixed placeholder
 * because the option is write-only.
 */
export function getOptDebug(): string {
    return _getStr(Option.DEBUG);
}

/** Enable or disable quiet mode. */
export function setOptQuiet(value: boolean): void {
    _setBool(Option.QUIET, Boolean(value));
}

export function getOptQuiet(): boolean {
    return _getBool(Option.QUIET);
}

/** Enable or disable thread-ID prefixes in status output. */
export function setOptShowThreadID(value: boolean): void {
    _setBool(Option.SHOW_THREAD_ID, Boolean(value));
}

export function getOptShowThreadID(): boolean {
    return _getBool(Option.SHOW_THREAD_ID);
}

/** Enable or disable console output for status messages. */
export function setOptConsoleOutput(value: boolean): void {
    _setBool(Option.CONSOLE_OUTPUT, Boolean(value));
}

export function getOptConsoleOutput(): boolean {
    return _getBool(Option.CONSOLE_OUTPUT);
}

// -----------------------------------------------------------------------------
//  Connection readiness
// -----------------------------------------------------------------------------

/** Allow or forbid multiple client tunnels to the same address. */
export function setOptOverlapConnection(value: boolean): void {
    _setBool(Option.OVERLAP_CONNECTION, Boolean(value));
}

export function getOptOverlapConnection(): boolean {
    return _getBool(Option.OVERLAP_CONNECTION);
}

/** Control whether LF_PrepareDone blocks until every client is online. */
export function setOptWaitConnectionReadyOk(value: boolean): void {
    _setBool(Option.WAIT_CONNECTION_READY_OK, Boolean(value));
}

export function getOptWaitConnectionReadyOk(): boolean {
    return _getBool(Option.WAIT_CONNECTION_READY_OK);
}

/** Set the LF_PrepareDone wait timeout, in milliseconds. */
export function setOptWaitConnectionTimeout(valueMs: number): void {
    _setInt(Option.WAIT_CONNECTION_TIMEOUT, valueMs);
}

export function getOptWaitConnectionTimeout(): number {
    return _getInt(Option.WAIT_CONNECTION_TIMEOUT);
}

// -----------------------------------------------------------------------------
//  IPC
// -----------------------------------------------------------------------------

/** Set the IPC server thread-pool size. */
export function setOptIpcServThreadCount(value: number): void {
    _setInt(Option.IPC_SERV_THREAD_COUNT, value);
}

export function getOptIpcServThreadCount(): number {
    return _getInt(Option.IPC_SERV_THREAD_COUNT);
}

/** Set the IPC inbound queue length. */
export function setOptIpcServMaxQueueLength(value: number): void {
    _setInt(Option.IPC_SERV_MAX_QUEUE_LENGTH, value);
}

export function getOptIpcServMaxQueueLength(): number {
    return _getInt(Option.IPC_SERV_MAX_QUEUE_LENGTH);
}

/** Set the maximum IPC message size, in bytes. */
export function setOptIpcServMaxMsgSize(value: number): void {
    _setInt(Option.IPC_SERV_MAX_MSG_SIZE, value);
}

export function getOptIpcServMaxMsgSize(): number {
    return _getInt(Option.IPC_SERV_MAX_MSG_SIZE);
}

// -----------------------------------------------------------------------------
//  Sequenced notifications
// -----------------------------------------------------------------------------

/** Set the sticky-affinity window, in milliseconds. */
export function setOptFixedSequencedTime(valueMs: number): void {
    _setInt(Option.FIXED_SEQUENCED_TIME, valueMs);
}

export function getOptFixedSequencedTime(): number {
    return _getInt(Option.FIXED_SEQUENCED_TIME);
}

// -----------------------------------------------------------------------------
//  P2P group name
// -----------------------------------------------------------------------------

/**
 * Set this process's P2P group name.
 *
 * NOT TO BE CONFUSED WITH DataHandle.getP2PName
 * ---------------------------------------------
 * This function sets the LOCAL declaration: the name THIS process
 * declares for itself.
 *
 * DataHandle.getP2PName() reads the SENDER's name from the INPUT handle
 * of a registered callback (side data injected by the sender's
 * transport layer). The two are entirely separate concepts.
 */
export function setOptP2PName(value: string): void {
    if (typeof value !== "string") {
        throw new TypeError("setOptP2PName: value must be a string.");
    }
    _setStr(Option.P2P_NAME, value);
}

/** Return this process's configured P2P group name. */
export function getOptP2PName(): string {
    return _getStr(Option.P2P_NAME);
}

// -----------------------------------------------------------------------------
//  Data handle pool
// -----------------------------------------------------------------------------

/** Set the idle-reclaim threshold for auto-recycled handles, in ms. */
export function setOptDataHandleIdleTimeout(valueMs: number): void {
    _setInt(Option.DATA_HANDLE_IDLE_TIMEOUT, valueMs);
}

export function getOptDataHandleIdleTimeout(): number {
    return _getInt(Option.DATA_HANDLE_IDLE_TIMEOUT);
}

/** Set the minimum interval between two consecutive pool scans, in ms. */
export function setOptDataHandlePoolScanInterval(valueMs: number): void {
    _setInt(Option.DATA_HANDLE_POOL_SCAN_INTERVAL, valueMs);
}

export function getOptDataHandlePoolScanInterval(): number {
    return _getInt(Option.DATA_HANDLE_POOL_SCAN_INTERVAL);
}

// -----------------------------------------------------------------------------
//  Command flushing
// -----------------------------------------------------------------------------

/**
 * Set the null-flush threshold for no-response commands.
 *
 * SPELLING NOTE
 * -------------
 * The option key uses the historical spelling "Reponse" (without the
 * second 's'). Both the function name and the option key are
 * intentional and mirror the Pascal-side LF_Set_Opt_No_Reponse_* API.
 */
export function setOptNoReponseCmdNullFlushThreshold(value: number): void {
    _setInt(Option.NO_REPONSE_CMD_NULL_FLUSH_THRESHOLD, value);
}

export function getOptNoReponseCmdNullFlushThreshold(): number {
    return _getInt(Option.NO_REPONSE_CMD_NULL_FLUSH_THRESHOLD);
}