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
 * REPLACEMENT / RELEASE ORDER (important):
 * The native library holds a RAW FUNCTION POINTER to each installed
 * trampoline. The Koffi registration and the native registration have
 * separate lifetimes, and the native side must always be told to drop
 * its reference BEFORE the Koffi registration is released:
 *
 *   unregister(apiName):
 *       1. LF_Unregister(handle, apiName)   -> native drops the pointer
 *       2. koffi.unregister(bridge)         -> release the trampoline
 *
 *   dispose():
 *       1. LF_FreeApp(handle)               -> native drops every pointer
 *       2. koffi.unregister(bridge)*        -> release the trampolines
 *
 * Reversing either order would leave the native library holding a
 * pointer to a freed Koffi trampoline for the duration of the native
 * call. Any callback arriving in that window would jump to freed
 * memory and crash the process. Failing to release at all would leak
 * the Koffi trampoline object and its backing libuv handle, which
 * keeps the Node event loop alive.
 *
 * CALLBACK EXCEPTION POLICY
 * -------------------------
 * User callbacks run on native worker threads. An exception escaping a
 * callback would cross into the C stack and could destabilise the
 * process. The wrapper therefore catches every exception and reports
 * it through the shared callback error reporter (see callback-error.js).
 *
 * For Call-mode APIs, the wrapper additionally writes the standard
 * wire-protocol error envelope into the output handle:
 *
 *     [0xFF][error message][NUL]
 *
 * This matches the behaviour of the C++ / Pascal / C# / Rust / Java
 * code generators and lets the caller distinguish a remote-side crash
 * from an empty response. For Notify-mode APIs, there is no output
 * handle and the exception is only logged.
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
     * Exception policy: if the handler throws, the wrapper reports the
     * exception through the shared callback error reporter AND writes
     * the standard wire-protocol error envelope into the output handle:
     *
     *     [0xFF][error message][NUL]
     *
     * The caller of the API therefore sees a well-formed error reply
     * (status byte 0xFF followed by a UTF-8 message) instead of an
     * empty response. This is the same behaviour as the C++ / Pascal /
     * C# / Rust / Java code generators, so a Node.js service and a
     * C++ client interoperate on the failure path exactly as on the
     * success path.
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
                    try {
                        // Reset the buffer to discard any partial write
                        // the handler may have performed before throwing,
                        // then emit the wire-protocol error envelope.
                        outH.size = 0;
                        outH.position = 0;
                        outH.writeUInt8(0xFF);
                        outH.writeString(
                            err instanceof Error ? err.message : String(err)
                        );
                    } catch (_) {
                        // If we cannot even write the error envelope,
                        // there is nothing more we can do. The exception
                        // has already been reported through the logger.
                    }
                }
            },
            koffi.pointer(LfCallFunc)
        );

        let result;
        try {
            result = this.#funcs.LF_RegisterCall(
                this.#handle,
                apiName,
                desc,
                null,
                bridge
            );
        } catch (err) {
            // The native call threw before accepting the bridge. The
            // bridge was never handed to the native library, so it is
            // safe (and required) to release it here.
            try {
                koffi.unregister(bridge);
            } catch (_) {
                // Best-effort cleanup.
            }
            throw err;
        }

        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }

        // Registration rejected (most likely a duplicate name). The
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
     * Exception policy: if the handler throws, the wrapper reports the
     * exception through the shared callback error reporter. There is no
     * output handle in Notify mode, so no wire-protocol reply is
     * written; the exception is only logged. This matches the C++ /
     * Pascal / C# / Rust / Java generators.
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

        let result;
        try {
            result = this.#funcs.LF_RegisterNotify(
                this.#handle,
                apiName,
                desc,
                null,
                bridge
            );
        } catch (err) {
            try {
                koffi.unregister(bridge);
            } catch (_) {
                // Best-effort cleanup.
            }
            throw err;
        }

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
     * Release order:
     *   1. LF_Unregister(handle, apiName)  -> native drops the pointer
     *   2. koffi.unregister(bridge)        -> release the trampoline
     *
     * The native call MUST complete first. Releasing the Koffi
     * trampoline while the native library still holds a pointer to it
     * would leave the native side with a dangling function pointer for
     * the duration of the LF_Unregister call.
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

        // Step 1: tell the native library to drop the API. Only after
        // this call returns is it safe to release the Koffi trampoline.
        const result = this.#funcs.LF_Unregister(this.#handle, apiName);

        if (result === 1) {
            // Step 2: release the trampoline.
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
     * Release order (see the file header for the rationale):
     *   1. LF_FreeApp(handle)          -> native drops every pointer
     *   2. koffi.unregister(bridge)*   -> release every trampoline
     *
     * The native call MUST run first. Releasing the Koffi trampolines
     * before LF_FreeApp would leave the native library holding dangling
     * function pointers for the duration of the FreeApp call (which
     * detaches clients, stops sequenced threads and removes the update
     * timer); any callback that fires in that window would jump to
     * freed memory.
     *
     * Even if LF_FreeApp raises, the trampolines are still released in
     * a finally-equivalent path so that no libuv handle is leaked and
     * the Node event loop can drain.
     *
     * Safe to call multiple times. After the first call, all methods
     * that require a live handle throw LingoFuseObjectDisposedError.
     */
    dispose() {
        if (this.#disposed) {
            return;
        }
        this.#disposed = true;

        // Capture and clear the mutable state up front. Re-entrant
        // calls from a callback body will observe an already-disposed
        // handle and return immediately.
        const handle = this.#handle;
        this.#handle = null;

        const bridges = Array.from(this.#registrations.values());
        this.#registrations.clear();

        // Step 1: detach the application on the native side. After
        // this call returns, the native library no longer holds any
        // pointer to the Koffi trampolines registered through this
        // handle.
        if (handle !== null && handle !== undefined) {
            try {
                this.#funcs.LF_FreeApp(handle);
            } catch (_) {
                // LF_FreeApp has no documented failure mode, but a
                // throwing native call must not prevent us from
                // releasing the Koffi registrations below.
            }
        }

        // Step 2: release the Koffi trampolines now that the native
        // library no longer references them.
        for (const bridge of bridges) {
            try {
                koffi.unregister(bridge);
            } catch (_) {
                // Best-effort cleanup.
            }
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