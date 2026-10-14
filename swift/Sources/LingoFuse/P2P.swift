//
//  P2P.swift
//  LingoFuse
//
//  Process-wide P2P API registration.
//
//  WHAT "PROCESS-WIDE P2P" MEANS
//  -----------------------------
//  An API registered through `P2P.registerCall` or
//  `P2P.registerNotify` lives on the process-wide `LF_P2P_APP` and is
//  reachable through UID addressing and P2PName addressing ONLY. It is
//  NOT reachable by App-name addressing, even if the API name happens
//  to match a registered App name.
//
//  The intended use is for utility APIs that any client in the mesh
//  should be able to call without knowing the target's App name:
//  health probes, capability discovery, identity echo, and similar
//  "who am I talking to?" helpers.
//
//  COMPARISON WITH AppHandle.registerCall
//  --------------------------------------
//  | Aspect           | AppHandle.registerCall  | P2P.registerCall     |
//  |------------------|-------------------------|----------------------|
//  | Namespace        | The App's own namespace | Process-wide P2P     |
//  | Reachable by     | App name, UID, P2PName  | UID, P2PName         |
//  | Bound to an App  | Yes (the AppHandle)     | No (process-global)  |
//  | Underlying C ABI | LF_RegisterCall         | LF_Register_P2P_Call |
//  | Unregistered by  | AppHandle.unregister    | P2P.unregister       |
//  | Lifetime         | Until AppHandle drops   | Until process exits  |
//
//  CALLBACK CONTRACT (RESTATED)
//  ----------------------------
//  The callback rules are IDENTICAL to those of `AppHandle.registerCall`
//  / `AppHandle.registerNotify`:
//
//  1. Do not block. A long-running callback occupies a worker thread
//     from the native pool.
//
//  2. Do not call any blocking LingoFuse function (`Framework.call`,
//     `AppHandle.localCall`, `Framework.prepareDone`,
//     `Framework.shutdown`) from inside a callback. Doing so deadlocks
//     the native scheduler.
//
//  3. The handler signature is non-throwing. Any error must be caught
//     inside the closure; a `CallbackErrorReporter` handler may be
//     installed to centralise reporting.
//
//  MEMORY MODEL
//  ------------
//  Each registered P2P API owns a small context object that is stored
//  in the module-level `P2PRegistry` and is never released. This is
//  the same trade-off documented in `AppHandle`:
//
//    - The native layer may invoke a callback at any time, including
//      concurrently with an unregister call. A reclaim would create a
//      use-after-free window.
//    - The cost is bounded: a context is a few dozen bytes, and the
//      number of registered P2P APIs per process is typically small.
//    - `Framework.shutdown()` releases the native side of the callback
//      registry, but the leaked Swift context remains until the
//      process exits. For any realistic program this is negligible.
//
//  The registry is guarded by an `NSLock`. This matches the concurrency
//  discipline of `AppHandle` and avoids any Swift 6 strict-concurrency
//  diagnostic on a shared mutable array.
//
//  THREADING
//  ---------
//  Registration is safe to call from any thread, both before and after
//  `Framework.prepareDone()`. The registered callbacks run on
//  TCompute worker threads, matching the contract of every other
//  LingoFuse callback.
//

import Foundation
import CLingoFuse

public enum P2P {

    // ==================================================================
    // Registry
    // ------------------------------------------------------------------
    // Process-lifetime keep-alive for every registered callback
    // context. The registry is guarded by an `NSLock`; the class is
    // marked `@unchecked Sendable` because the lock provides the
    // synchronisation the compiler cannot infer.
    //
    // Nothing in the registry is ever removed. This is deliberate:
    // the native layer holds a raw function pointer to each context,
    // and the C ABI provides no callback-object release hook. See
    // the file-level docstring section "MEMORY MODEL".
    // ==================================================================

    private final class Registry: @unchecked Sendable {
        static let shared = Registry()

        private let lock = NSLock()
        private var contexts: [AnyObject] = []

        func retain(_ ctx: AnyObject) {
            lock.lock()
            contexts.append(ctx)
            lock.unlock()
        }

        #if DEBUG
        /// Number of retained contexts. Debug-only diagnostic; not part
        //  of the public API.
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return contexts.count
        }
        #endif
    }

    // ==================================================================
    // Registration
    // ==================================================================

    /// Registers a process-wide P2P Call (request-response) API.
    ///
    /// The API becomes reachable via UID addressing or P2PName
    /// addressing from any client in the mesh, without requiring the
    /// caller to know the target App name. It is NOT reachable via
    /// App-name addressing.
    ///
    /// - Parameters:
    ///   - apiName:     Unique API name within the process-wide P2P
    ///                  namespace. Case-insensitive on the wire.
    ///   - description: Optional human-readable description.
    ///   - handler:     The callback. Runs on a TCompute worker thread.
    ///                  It MUST NOT block, and MUST NOT call any
    ///                  synchronous LingoFuse function on pain of
    ///                  deadlock. See the file-level docstring for the
    ///                  full contract.
    ///
    /// - Returns: `true` on success. On failure (typically a duplicate
    ///            API name in the P2P namespace), throws
    ///            `LingoFuseError.registrationFailed`.
    ///
    /// - Throws:
    ///   * `LingoFuseError.registrationFailed` if the native layer
    ///     rejects the registration.
    @discardableResult
    public static func registerCall(
        _ apiName: String,
        description: String = "",
        handler: @escaping (DataHandle, DataHandle) -> Void
    ) throws -> Bool {

        let ctx = LfCallContext(apiName: apiName, handler: handler)
        let trigger = Unmanaged.passUnretained(ctx).toOpaque()

        let rc = LF_Register_P2P_Call(
            apiName,
            description,
            trigger,
            swiftCallTrampoline
        )

        if rc != 1 {
            throw LingoFuseError.registrationFailed(
                operation: "P2P.registerCall",
                apiName: apiName
            )
        }

        // Retain the context AFTER the native call succeeds. If the
        // call had failed, the native layer would not hold the
        // pointer, and retaining would leak unnecessarily.
        Registry.shared.retain(ctx)
        return true
    }

    /// Registers a process-wide P2P Notify (one-way) API.
    ///
    /// Same contract as `registerCall`, minus the output handle.
    ///
    /// - Returns: `true` on success. On failure, throws
    ///            `LingoFuseError.registrationFailed`.
    @discardableResult
    public static func registerNotify(
        _ apiName: String,
        description: String = "",
        handler: @escaping (DataHandle) -> Void
    ) throws -> Bool {

        let ctx = LfNotifyContext(apiName: apiName, handler: handler)
        let trigger = Unmanaged.passUnretained(ctx).toOpaque()

        let rc = LF_Register_P2P_Notify(
            apiName,
            description,
            trigger,
            swiftNotifyTrampoline
        )

        if rc != 1 {
            throw LingoFuseError.registrationFailed(
                operation: "P2P.registerNotify",
                apiName: apiName
            )
        }

        Registry.shared.retain(ctx)
        return true
    }

    // ==================================================================
    // Unregistration
    // ==================================================================

    /// Removes a previously registered process-wide P2P API by name.
    ///
    /// Does NOT affect app-bound APIs of the same name.
    ///
    /// The local effect is immediate. A network broadcast propagates
    /// the removal to remote peers within approximately 3 seconds.
    /// During that window, a remote caller may still route to this API
    /// and receive an empty response.
    ///
    /// - Returns: `true` if the API was found and removed,
    ///            `false` otherwise.
    ///
    /// - Note: The Swift-side callback context behind the unregistered
    ///         API is NOT reclaimed. This is deliberate: the native
    ///         layer may still hold the function pointer for the
    ///         duration of the broadcast window, and there is no
    ///         callback-object release hook in the C ABI. A subsequent
    ///         registration with the same name creates a fresh context.
    @discardableResult
    public static func unregister(_ apiName: String) -> Bool {
        return LF_Unregister_P2P(apiName) == 1
    }

    // ==================================================================
    // Diagnostics (debug-only)
    // ==================================================================

    #if DEBUG
    /// Returns the number of callback contexts currently retained by
    /// the module-level registry. This is a DIAGNOSTIC for tests and
    /// for debugging; it is not part of the public API surface and is
    /// compiled out of release builds.
    ///
    /// Because the registry is never pruned, this count monotonically
    /// increases for the lifetime of the process. It is useful for
    /// verifying that a registration actually reached the registry,
    /// not for detecting leaks (by design there is no leak to detect).
    public static var retainedContextCount: Int {
        return Registry.shared.count
    }
    #endif
}