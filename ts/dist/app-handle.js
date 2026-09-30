"use strict";
// =============================================================================
//  app-handle.ts
// -----------------------------------------------------------------------------
//  RAII wrapper around a native TAppHnd.
//
//  Callback registration:
//      koffi.register() requires the callback pointer type built from the
//      matching koffi.proto(). Passing koffi.pointer("void") raises:
//          TypeError: Unexpected void * type, expected <callback> * type
//      The correct pointer types (LfCallFuncPtr / LfNotifyFuncPtr) are
//      declared and exported by binding.ts.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.AppHandle = exports.reportCallbackError = exports.setCallbackErrorReporter = void 0;
const binding_1 = require("./binding");
const data_handle_1 = require("./data-handle");
const errors_1 = require("./errors");
/** Internal slot shared with framework.ts for error reporting. */
let _callbackErrorReporter = null;
/** Install the process-wide callback error reporter. */
function setCallbackErrorReporter(fn) {
    _callbackErrorReporter = fn;
}
exports.setCallbackErrorReporter = setCallbackErrorReporter;
/** Report a swallowed callback error through the installed reporter. */
function reportCallbackError(source, err) {
    if (_callbackErrorReporter !== null) {
        try {
            _callbackErrorReporter(source, err);
        }
        catch {
            // A broken reporter must not escape into the native worker.
        }
        return;
    }
    try {
        const detail = err instanceof Error ? err.stack ?? err.message : String(err);
        process.stderr.write(`[LingoFuse] Callback error in ${source}: ${detail}\n`);
    }
    catch {
        // stderr may be unavailable in some embeddings. Ignore.
    }
}
exports.reportCallbackError = reportCallbackError;
class AppHandle {
    #binding;
    #handle;
    #name;
    #disposed;
    #registrations;
    /**
     * Create a new application with the given name and description.
     *
     * @throws {LingoFuseError} When the native side fails to allocate
     *         the application.
     */
    constructor(name, description = "") {
        if (typeof name !== "string") {
            throw new TypeError("AppHandle: name must be a string.");
        }
        const desc = description ?? "";
        const binding = (0, binding_1.getBinding)();
        this.#binding = binding;
        this.#name = name;
        this.#disposed = false;
        this.#registrations = new Map();
        const raw = binding.funcs.LF_CreateApp(name, desc);
        if (raw === null || raw === undefined) {
            throw new errors_1.LingoFuseError(`Failed to create application '${name}'.`, errors_1.ErrorCode.Generic);
        }
        this.#handle = raw;
    }
    get name() { return this.#name; }
    get raw() { return this.#handle; }
    get isValid() {
        return !this.#disposed && this.#handle !== null && this.#handle !== undefined;
    }
    // ---- API registration ----
    /** Register a Call (request-response) API. */
    registerCall(apiName, description, handler) {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.registerCall: apiName must be a string.");
        }
        if (typeof handler !== "function") {
            throw new TypeError("AppHandle.registerCall: handler must be a function.");
        }
        const desc = description ?? "";
        this.#ensureNotDisposed();
        const key = apiName.toLowerCase();
        const bridge = binding_1.koffi.register((trigger, input, output) => {
            const inH = data_handle_1.DataHandle.fromRaw(input, false);
            const outH = data_handle_1.DataHandle.fromRaw(output, false);
            try {
                handler(inH, outH);
            }
            catch (err) {
                reportCallbackError(`AppHandle.registerCall[${apiName}]`, err);
            }
        }, binding_1.LfCallFuncPtr);
        const result = this.#binding.funcs.LF_RegisterCall(this.#handle, apiName, desc, null, bridge);
        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }
        try {
            binding_1.koffi.unregister(bridge);
        }
        catch { /* ignore */ }
        return false;
    }
    /** Register a Notify (one-way) API. */
    registerNotify(apiName, description, handler) {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.registerNotify: apiName must be a string.");
        }
        if (typeof handler !== "function") {
            throw new TypeError("AppHandle.registerNotify: handler must be a function.");
        }
        const desc = description ?? "";
        this.#ensureNotDisposed();
        const key = apiName.toLowerCase();
        const bridge = binding_1.koffi.register((trigger, input) => {
            const inH = data_handle_1.DataHandle.fromRaw(input, false);
            try {
                handler(inH);
            }
            catch (err) {
                reportCallbackError(`AppHandle.registerNotify[${apiName}]`, err);
            }
        }, binding_1.LfNotifyFuncPtr);
        const result = this.#binding.funcs.LF_RegisterNotify(this.#handle, apiName, desc, null, bridge);
        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }
        try {
            binding_1.koffi.unregister(bridge);
        }
        catch { /* ignore */ }
        return false;
    }
    /** Unregister a previously registered API. */
    unregister(apiName) {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.unregister: apiName must be a string.");
        }
        this.#ensureNotDisposed();
        const key = apiName.toLowerCase();
        const result = this.#binding.funcs.LF_Unregister(this.#handle, apiName);
        if (result === 1) {
            const bridge = this.#registrations.get(key);
            this.#registrations.delete(key);
            if (bridge !== undefined) {
                try {
                    binding_1.koffi.unregister(bridge);
                }
                catch { /* ignore */ }
            }
            return true;
        }
        return false;
    }
    // ---- Local execution ----
    /**
     * Invoke a Call API locally. The result handle has size 0 when the
     * target API is not registered.
     */
    localCall(param) {
        if (!(param instanceof data_handle_1.DataHandle)) {
            throw new TypeError("AppHandle.localCall: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();
        const result = this.#binding.funcs.LF_LocalCall(this.#handle, param.raw);
        if (result === null || result === undefined) {
            throw new errors_1.LingoFuseCallError("LF_LocalCall returned a null handle.", { targetApp: this.#name });
        }
        return data_handle_1.DataHandle.fromRaw(result, true);
    }
    /** Invoke a Notify API locally. */
    localNotify(param) {
        if (!(param instanceof data_handle_1.DataHandle)) {
            throw new TypeError("AppHandle.localNotify: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();
        this.#binding.funcs.LF_LocalNotify(this.#handle, param.raw);
    }
    // ---- Client binding ----
    /**
     * Bind the application to all currently unbound clients. Must be
     * called after prepareDone() returned 1.
     */
    bind() {
        this.#ensureNotDisposed();
        return this.#binding.funcs.LF_BindApp(this.#handle);
    }
    // ---- Lifetime ----
    /**
     * Stage one of two-stage destruction: detaches the application
     * from all clients and stops its sequenced threads. The native
     * object remains in the global pool until shutdown() is called.
     */
    dispose() {
        if (this.#disposed)
            return;
        this.#disposed = true;
        for (const bridge of this.#registrations.values()) {
            try {
                binding_1.koffi.unregister(bridge);
            }
            catch { /* ignore */ }
        }
        this.#registrations.clear();
        const handle = this.#handle;
        this.#handle = null;
        if (handle !== null && handle !== undefined) {
            this.#binding.funcs.LF_FreeApp(handle);
        }
    }
    // ---- Internal ----
    #ensureNotDisposed() {
        if (this.#disposed || this.#handle === null || this.#handle === undefined) {
            throw new errors_1.LingoFuseObjectDisposedError("AppHandle");
        }
    }
}
exports.AppHandle = AppHandle;
//# sourceMappingURL=app-handle.js.map