/**
 * @file app-handle.js
 * @brief RAII wrapper around a native LingoFuse application handle (TAppHnd).
 *
 * RESPONSIBILITY
 * --------------
 * Owns a native application handle and provides a managed API for
 * registering Call / Notify endpoints, unregistering them, invoking
 * them locally, and binding the application to idle clients.
 *
 * CALLBACK MODEL
 * --------------
 * The wrapper presents a user-facing callback signature that receives
 * managed DataHandle instances instead of raw pointers:
 *
 *     (input, output) => void   — Call mode
 *     (input)         => void   — Notify mode
 *
 * The DataHandle instances passed to a user callback BORROW the native
 * handle (owned = false). They must NOT be disposed by the callback
 * body; the native layer releases them as soon as the callback returns.
 *
 * DELEGATE LIFETIME
 * -----------------
 * Koffi callbacks must be registered with `koffi.register` to remain
 * valid for the lifetime of the native registration. This module keeps
 * the registered pointer in a per-instance Map, and calls
 * `koffi.unregister` on it when the API is unregistered or when the
 * AppHandle is disposed.
 *
 * Failing to unregister on dispose would leave the native library
 * holding a pointer to a Koffi trampoline that may be collected at any
 * moment, resulting in a crash on the next invocation.
 *
 * CALLBACK EXCEPTION POLICY
 * -------------------------
 * User callbacks run on native worker threads. An exception escaping a
 * callback would cross into the C stack and could destabilise the
 * process. The wrapper therefore catches every exception and reports
 * it through the shared callback error reporter (see callback-error.js).
 * The native layer sees a callback that completed without producing
 * output.
 *
 * THREAD SAFETY
 * -------------
 * JavaScript is single-threaded per event loop, but native callbacks
 * can be invoked from native worker threads that enter the JS engine
 * on their own. The callbacks installed here only capture their user
 * handler in a closure; they do not touch any mutable state of the
 * AppHandle. This keeps them safe against a concurrent dispose() on
 * the main thread.
 *
 * The JS-level `#registrations` map and `#disposed` flag are only
 * touched from the main thread, so no locking is required.
 *
 * LIFETIME OF THE UNDERLYING APPLICATION
 * --------------------------------------
 * dispose() calls LF_FreeApp, which is the first stage of a two-stage
 * destruction: the native object is detached from all clients and its
 * sequenced threads are stopped, but the object itself remains in the
 * global pool until LF_Shutdown is called. After dispose(), the handle
 * is invalid and must not be reused.
 *
 * ============================================================================
 */

"use strict";

const { getBinding, LfCallFunc, LfNotifyFunc, koffi } = require("./binding");
const { DataHandle } = require("./data-handle");
const {
    LingoFuseError,
    LingoFuseCallError,
    LingoFuseObjectDisposedError,
} = require("./errors");

// ============================================================================
// Callback error reporter (shared with framework.js)
// ============================================================================

/**
 * Optional handler invoked when a user callback raises an unhandled
 * exception. The first argument is a short identifier for the callback
 * site (for example "AppHandle.registerCall[add]"); the second is the
 * value the callback threw, which may be an Error or any other value.
 *
 * framework.js installs a real handler on this slot. When no handler is
 * installed, errors are written to stderr so they are not silently
 * lost.
 *
 * @type {((source: string, err: *) => void) | null}
 */
let _callbackErrorReporter = null;

/**
 * Installs the process-wide callback error reporter. Called by
 * framework.js during module initialisation.
 *
 * @param {(source: string, err: *) => void} fn
 */
function setCallbackErrorReporter(fn) {
    _callbackErrorReporter = fn;
}

/**
 * Reports a swallowed callback error through the installed reporter,
 * or through stderr when no reporter is installed.
 *
 * @param {string} source
 * @param {*} err
 */
function reportCallbackError(source, err) {
    if (_callbackErrorReporter) {
        try {
            _callbackErrorReporter(source, err);
        } catch (_) {
            // A broken reporter must not be allowed to escape into the
            // native worker thread. Drop the secondary failure.
        }
        return;
    }
    try {
        const detail = err instanceof Error ? err.stack ?? err.message : String(err);
        process.stderr.write(`[LingoFuse] Callback error in ${source}: ${detail}\n`);
    } catch (_) {
        // Even stderr may be unavailable in some embeddings. Ignore.
    }
}

// ============================================================================
// AppHandle
// ============================================================================

/**
 * RAII wrapper around a native LingoFuse application handle.
 */
class AppHandle {
    // --------------------------------------------------------------------
    // Private state
    // --------------------------------------------------------------------

    /** @type {object} The declared native functions. */
    #funcs;

    /** @type {object|null} Raw native handle pointer, or null. */
    #handle;

    /** @type {string} Application name passed to the constructor. */
    #name;

    /** @type {boolean} True after dispose() has been called. */
    #disposed;

    /**
     * Registered Koffi callback pointers indexed by a lower-cased API
     * name. Each entry records the bridge pointer so that we can call
     * koffi.unregister on it during unregister() and dispose().
     *
     * @type {Map<string, object>}
     */
    #registrations;

    // --------------------------------------------------------------------
    // Construction
    // --------------------------------------------------------------------

    /**
     * Creates a new application with the given name and description.
     *
     * @param {string} name
     *   Application name. Must be a string. Should be unique on the
     *   mesh; case-insensitive matching applies at lookup time.
     * @param {string} [description=""]
     *   Optional human-readable description. A null value is treated
     *   as an empty string.
     * @throws {TypeError} When name is not a string.
     * @throws {import('./errors').LingoFuseError}
     *   When the native side fails to allocate the application.
     */
    constructor(name, description = "") {
        if (typeof name !== "string") {
            throw new TypeError("AppHandle: name must be a string.");
        }
        const desc = description ?? "";

        const binding = getBinding();
        this.#funcs = binding.funcs;
        this.#name = name;
        this.#disposed = false;
        this.#registrations = new Map();

        const raw = this.#funcs.LF_CreateApp(name, desc);
        if (raw === null || raw === undefined) {
            throw new LingoFuseError(
                `Failed to create application '${name}'.`
            );
        }
        this.#handle = raw;
    }

    // --------------------------------------------------------------------
    // Identity and state
    // --------------------------------------------------------------------

    /**
     * Application name passed to the constructor.
     *
     * @returns {string}
     */
    get name() {
        return this.#name;
    }

    /**
     * Raw native pointer. Null after dispose().
     *
     * @returns {object|null}
     */
    get raw() {
        return this.#handle;
    }

    /**
     * True while the handle is valid and not yet disposed.
     *
     * @returns {boolean}
     */
    get isValid() {
        return !this.#disposed && this.#handle !== null && this.#handle !== undefined;
    }

    // ====================================================================
    // API registration
    // ====================================================================

    /**
     * Registers a Call (request-response) API whose handler runs on a
     * native worker thread.
     *
     * @param {string} apiName
     *   API name. Must be a string. Case-insensitive matching applies
     *   at lookup time.
     * @param {string} [description=""]
     *   Optional description. Null is treated as an empty string.
     * @param {(input: DataHandle, output: DataHandle) => void} handler
     *   The user callback. Receives borrowed DataHandle instances for
     *   input and output. Must be a function.
     * @returns {boolean}
     *   true on success, false if the API name is already taken.
     * @throws {TypeError} When apiName or handler is not the right type.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
    registerCall(apiName, description, handler) {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.registerCall: apiName must be a string.");
        }
        if (typeof handler !== "function") {
            throw new TypeError("AppHandle.registerCall: handler must be a function.");
        }
        const desc = description ?? "";
        this.#ensureNotDisposed();

        // The native library stores only the API name as the key for
        // unregistration. Lower-case it here to match the library's
        // case-insensitive semantics.
        const key = apiName.toLowerCase();

        const bridge = koffi.register(
            function (_trigger, input, output) {
                const inH = DataHandle.fromRaw(input, false);
                const outH = DataHandle.fromRaw(output, false);
                try {
                    handler(inH, outH);
                } catch (err) {
                    reportCallbackError(
                        `AppHandle.registerCall[${apiName}]`,
                        err
                    );
                }
            },
            koffi.pointer(LfCallFunc)
        );

        const result = this.#funcs.LF_RegisterCall(
            this.#handle,
            apiName,
            desc,
            null,
            bridge
        );

        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }

        // Registration failed (most likely a duplicate name). The
        // bridge has not been handed to the native library, so we can
        // safely unregister it now.
        try {
            koffi.unregister(bridge);
        } catch (_) {
            // Best-effort cleanup.
        }
        return false;
    }

    /**
     * Registers a Notify (one-way) API whose handler runs on a native
     * worker thread.
     *
     * @param {string} apiName
     * @param {string} [description=""]
     * @param {(input: DataHandle) => void} handler
     *   The user callback. Receives a borrowed DataHandle for the input
     *   payload. Must be a function.
     * @returns {boolean}
     * @throws {TypeError} When apiName or handler is not the right type.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
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

        const bridge = koffi.register(
            function (_trigger, input) {
                const inH = DataHandle.fromRaw(input, false);
                try {
                    handler(inH);
                } catch (err) {
                    reportCallbackError(
                        `AppHandle.registerNotify[${apiName}]`,
                        err
                    );
                }
            },
            koffi.pointer(LfNotifyFunc)
        );

        const result = this.#funcs.LF_RegisterNotify(
            this.#handle,
            apiName,
            desc,
            null,
            bridge
        );

        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }

        try {
            koffi.unregister(bridge);
        } catch (_) {
            // Best-effort cleanup.
        }
        return false;
    }

    /**
     * Unregisters a previously registered API. Local effect is
     * immediate; a network broadcast propagates within a few seconds.
     *
     * @param {string} apiName
     * @returns {boolean}
     *   true if the API was found and removed, false otherwise.
     * @throws {TypeError} When apiName is not a string.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
    unregister(apiName) {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.unregister: apiName must be a string.");
        }
        this.#ensureNotDisposed();

        const key = apiName.toLowerCase();
        const result = this.#funcs.LF_Unregister(this.#handle, apiName);

        if (result === 1) {
            const bridge = this.#registrations.get(key);
            this.#registrations.delete(key);
            if (bridge) {
                try {
                    koffi.unregister(bridge);
                } catch (_) {
                    // Best-effort cleanup.
                }
            }
            return true;
        }
        return false;
    }

    // ====================================================================
    // Local execution
    // ====================================================================

    /**
     * Invokes a Call API locally within the same process. The input
     * handle is not consumed by this call.
     *
     * @param {DataHandle} param  Input data handle.
     * @returns {DataHandle}
     *   A new DataHandle owning the result. The caller is responsible
     *   for disposing it. When the target API is not registered, the
     *   returned handle has size 0.
     * @throws {TypeError} When param is not a DataHandle.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     * @throws {import('./errors').LingoFuseCallError}
     *   When the native layer returns a null handle.
     */
    localCall(param) {
        if (!(param instanceof DataHandle)) {
            throw new TypeError("AppHandle.localCall: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();

        const result = this.#funcs.LF_LocalCall(this.#handle, param.raw);
        if (result === null || result === undefined) {
            throw new LingoFuseCallError(
                "LF_LocalCall returned a null handle.",
                { targetApp: this.#name }
            );
        }
        return DataHandle.fromRaw(result, true);
    }

    /**
     * Invokes a Notify API locally within the same process.
     *
     * @param {DataHandle} param  Input data handle.
     * @throws {TypeError} When param is not a DataHandle.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
    localNotify(param) {
        if (!(param instanceof DataHandle)) {
            throw new TypeError("AppHandle.localNotify: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();
        this.#funcs.LF_LocalNotify(this.#handle, param.raw);
    }

    // ====================================================================
    // Client binding
    // ====================================================================

    /**
     * Binds the application to all currently unbound clients. Must be
     * called after the simulated main thread has started (i.e. after
     * prepareDone() returned 1).
     *
     * @returns {number}
     *   Number of clients bound. Zero means no free client was
     *   available or the main thread is not active.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
    bind() {
        this.#ensureNotDisposed();
        return this.#funcs.LF_BindApp(this.#handle);
    }

    // ====================================================================
    // Lifetime
    // ====================================================================

    /**
     * Performs the first stage of the two-stage native destruction. The
     * application is detached from all clients and its sequenced
     * threads are stopped. The underlying native object remains in the
     * global pool until LF_Shutdown is called.
     *
     * Safe to call multiple times. After the first call, all methods
     * that require a live handle throw LingoFuseObjectDisposedError.
     */
    dispose() {
        if (this.#disposed) {
            return;
        }
        this.#disposed = true;

        // Unregister every Koffi trampoline first. This prevents the
        // native library from calling back into user code through a
        // pointer that may soon be collected.
        const bridges = Array.from(this.#registrations.values());
        this.#registrations.clear();
        for (const bridge of bridges) {
            try {
                koffi.unregister(bridge);
            } catch (_) {
                // Best-effort cleanup.
            }
        }

        const handle = this.#handle;
        this.#handle = null;
        if (handle !== null && handle !== undefined) {
            this.#funcs.LF_FreeApp(handle);
        }
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    /**
     * @private
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
    #ensureNotDisposed() {
        if (
            this.#disposed ||
            this.#handle === null ||
            this.#handle === undefined
        ) {
            throw new LingoFuseObjectDisposedError("AppHandle");
        }
    }
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
    AppHandle,
    setCallbackErrorReporter,
    reportCallbackError,
};