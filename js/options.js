/**
 * @file options.js
 * @brief Typed shortcuts for the LingoFuse runtime options.
 *
 * This module exposes one typed getter/setter pair for each runtime
 * option that the LingoFuse C ABI recognises. The pairs mirror, one
 * for one, the convenience functions defined by the Pascal-side
 * lingofuse_import.pas unit and by the C# binding's Lf static class:
 *
 *     Pascal / C#                     JavaScript (this module)
 *     ------------------------------- -------------------------------
 *     LF_Set_Opt_Debug / Get          setOptDebug / getOptDebug
 *     LF_Set_Opt_P2P_Name / Get       setOptP2PName / getOptP2PName
 *     LF_Set_Opt_Password / Get       setOptPassword / getOptPassword
 *     LF_Set_Opt_Quiet / Get          setOptQuiet / getOptQuiet
 *     ... (16 pairs in total)
 *
 * Each function is a thin, typed wrapper around the generic
 * framework.setOption / framework.getOption helpers.
 *
 * {!!!!!  THE GENERIC setOption / getOption ARE STILL AVAILABLE  !!!!!}
 * These typed shortcuts are ADDITIVE. framework.setOption and
 * framework.getOption remain the primary API for dynamic option names
 * and for scripting. Both paths share the same underlying native call,
 * so mixing them is safe.
 *
 * {!!!!!  UNKNOWN OPTION NAMES ARE SILENTLY IGNORED  !!!!!}
 * The underlying LF_SetOption has no return value and does not report
 * an error when it receives an unrecognised option name. These typed
 * shortcuts eliminate that failure mode by hard-coding the canonical
 * name.
 *
 * {!!!!!  OPTIONS ARE NOT PERSISTED ACROSS LF_Shutdown  !!!!!}
 * Every option is reset to its built-in default when the framework is
 * shut down. An application that restarts the framework must reapply
 * its options on every startup.
 *
 * All comments are in English.
 */

"use strict";

const { getBinding } = require("./binding");

// ============================================================================
// Internal helpers
// ============================================================================

let _funcs = null;

function funcs() {
    if (_funcs === null) {
        _funcs = getBinding().funcs;
    }
    return _funcs;
}

function _setStr(name, value) {
    funcs().LF_SetOption(name, value);
}

function _getStr(name) {
    const v = funcs().LF_GetOption(name);
    return typeof v === "string" ? v : "";
}

function _setBool(name, value) {
    _setStr(name, value ? "True" : "False");
}

function _getBool(name) {
    return _getStr(name).trim().toLowerCase() === "true";
}

function _setInt(name, value) {
    const n = Number(value);
    if (!Number.isFinite(n)) {
        throw new TypeError(
            `Option '${name}': expected a finite number, got ${value}.`
        );
    }
    _setStr(name, String(Math.trunc(n)));
}

function _getInt(name) {
    const v = _getStr(name);
    if (v.length === 0) return 0;
    const n = Number.parseInt(v, 10);
    return Number.isFinite(n) ? n : 0;
}

// ============================================================================
// Authentication
// ============================================================================

/**
 * Set the P2PVM / C4 network authentication password.
 * Underlying option key: "password".
 *
 * @param {string} value
 */
function setOptPassword(value) {
    if (typeof value !== "string") {
        throw new TypeError("setOptPassword: value must be a string.");
    }
    _setStr("password", value);
}

/**
 * Read the configured password. The native side returns a fixed mask
 * ("********"), never the real value.
 *
 * @returns {string}
 */
function getOptPassword() {
    return _getStr("password");
}

// ============================================================================
// Logging and diagnostics
// ============================================================================

/**
 * Execute a C4 console debug command. Write-only; each call constructs
 * a transient helper object on the Pascal side.
 *
 * @param {string} value
 */
function setOptDebug(value) {
    if (typeof value !== "string") {
        throw new TypeError("setOptDebug: value must be a string.");
    }
    _setStr("debug", value);
}

/**
 * Read the debug option. The native side returns a fixed placeholder
 * because the option is write-only.
 *
 * @returns {string}
 */
function getOptDebug() {
    return _getStr("debug");
}

/** Enable or disable quiet mode. */
function setOptQuiet(value) {
    _setBool("Quiet", Boolean(value));
}

/** @returns {boolean} */
function getOptQuiet() {
    return _getBool("Quiet");
}

/** Enable or disable thread-ID prefixes in status output. */
function setOptShowThreadID(value) {
    _setBool("ShowThreadID", Boolean(value));
}

/** @returns {boolean} */
function getOptShowThreadID() {
    return _getBool("ShowThreadID");
}

/** Enable or disable console output for status messages. */
function setOptConsoleOutput(value) {
    _setBool("ConsoleOutput", Boolean(value));
}

/** @returns {boolean} */
function getOptConsoleOutput() {
    return _getBool("ConsoleOutput");
}

// ============================================================================
// Connection readiness
// ============================================================================

/** Allow or forbid multiple client tunnels to the same address. */
function setOptOverlapConnection(value) {
    _setBool("Overlap_Connection", Boolean(value));
}

/** @returns {boolean} */
function getOptOverlapConnection() {
    return _getBool("Overlap_Connection");
}

/** Control whether LF_PrepareDone blocks until every client is online. */
function setOptWaitConnectionReadyOk(value) {
    _setBool("Wait_Connection_ReadyOk", Boolean(value));
}

/** @returns {boolean} */
function getOptWaitConnectionReadyOk() {
    return _getBool("Wait_Connection_ReadyOk");
}

/** Set the LF_PrepareDone wait timeout, in milliseconds. */
function setOptWaitConnectionTimeout(valueMs) {
    _setInt("Wait_Connection_Timeout", valueMs);
}

/** @returns {number} */
function getOptWaitConnectionTimeout() {
    return _getInt("Wait_Connection_Timeout");
}

// ============================================================================
// IPC
// ============================================================================

/** Set the IPC server thread-pool size. */
function setOptIpcServThreadCount(value) {
    _setInt("IPC_Serv_ThreadCount", value);
}

/** @returns {number} */
function getOptIpcServThreadCount() {
    return _getInt("IPC_Serv_ThreadCount");
}

/** Set the IPC inbound queue length. */
function setOptIpcServMaxQueueLength(value) {
    _setInt("IPC_Serv_MaxQueueLength", value);
}

/** @returns {number} */
function getOptIpcServMaxQueueLength() {
    return _getInt("IPC_Serv_MaxQueueLength");
}

/** Set the maximum IPC message size, in bytes. */
function setOptIpcServMaxMsgSize(value) {
    _setInt("IPC_Serv_MaxMsgSize", value);
}

/** @returns {number} */
function getOptIpcServMaxMsgSize() {
    return _getInt("IPC_Serv_MaxMsgSize");
}

// ============================================================================
// Sequenced notifications
// ============================================================================

/** Set the sticky-affinity window, in milliseconds. */
function setOptFixedSequencedTime(valueMs) {
    _setInt("Fixed_Sequenced_Time", valueMs);
}

/** @returns {number} */
function getOptFixedSequencedTime() {
    return _getInt("Fixed_Sequenced_Time");
}

// ============================================================================
// P2P group name
// ============================================================================

/**
 * Set this process's P2P group name.
 *
 * {!!!!!  NOT TO BE CONFUSED WITH DataHandle.getP2PName  !!!!!}
 * This function sets the LOCAL declaration: the name THIS process
 * declares for itself.
 *
 * DataHandle.getP2PName() reads the SENDER's name from the INPUT handle
 * of a registered callback (side data injected by the sender's
 * transport layer). The two are entirely separate concepts.
 *
 * @param {string} value
 */
function setOptP2PName(value) {
    if (typeof value !== "string") {
        throw new TypeError("setOptP2PName: value must be a string.");
    }
    _setStr("LF_P2P_name", value);
}

/** @returns {string} This process's configured P2P group name. */
function getOptP2PName() {
    return _getStr("LF_P2P_name");
}

// ============================================================================
// Data handle pool
// ============================================================================

/** Set the idle-reclaim threshold for auto-recycled handles, in ms. */
function setOptDataHandleIdleTimeout(valueMs) {
    _setInt("DataHandle_Idle_Timeout", valueMs);
}

/** @returns {number} */
function getOptDataHandleIdleTimeout() {
    return _getInt("DataHandle_Idle_Timeout");
}

/** Set the minimum interval between two consecutive pool scans, in ms. */
function setOptDataHandlePoolScanInterval(valueMs) {
    _setInt("DataHandle_Pool_Scan_Interval", valueMs);
}

/** @returns {number} */
function getOptDataHandlePoolScanInterval() {
    return _getInt("DataHandle_Pool_Scan_Interval");
}

// ============================================================================
// Command flushing
// ============================================================================

/**
 * Set the null-flush threshold for no-response commands.
 *
 * {!!!!!  SPELLING NOTE  !!!!!}
 * The option key uses the historical spelling "Reponse" (without the
 * second 's'). Both the function name and the option key are
 * intentional.
 */
function setOptNoReponseCmdNullFlushThreshold(value) {
    _setInt("No_Reponse_Cmd_NULL_Flush_Threshold", value);
}

/** @returns {number} */
function getOptNoReponseCmdNullFlushThreshold() {
    return _getInt("No_Reponse_Cmd_NULL_Flush_Threshold");
}

// ============================================================================
// Public exports
// ============================================================================

module.exports = {
    // Authentication
    setOptPassword, getOptPassword,
    // Logging and diagnostics
    setOptDebug, getOptDebug,
    setOptQuiet, getOptQuiet,
    setOptShowThreadID, getOptShowThreadID,
    setOptConsoleOutput, getOptConsoleOutput,
    // Connection readiness
    setOptOverlapConnection, getOptOverlapConnection,
    setOptWaitConnectionReadyOk, getOptWaitConnectionReadyOk,
    setOptWaitConnectionTimeout, getOptWaitConnectionTimeout,
    // IPC
    setOptIpcServThreadCount, getOptIpcServThreadCount,
    setOptIpcServMaxQueueLength, getOptIpcServMaxQueueLength,
    setOptIpcServMaxMsgSize, getOptIpcServMaxMsgSize,
    // Sequenced notifications
    setOptFixedSequencedTime, getOptFixedSequencedTime,
    // P2P group name
    setOptP2PName, getOptP2PName,
    // Data handle pool
    setOptDataHandleIdleTimeout, getOptDataHandleIdleTimeout,
    setOptDataHandlePoolScanInterval, getOptDataHandlePoolScanInterval,
    // Command flushing
    setOptNoReponseCmdNullFlushThreshold,
    getOptNoReponseCmdNullFlushThreshold,
};
