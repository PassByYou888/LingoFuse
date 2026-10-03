//
//  Framework.swift
//  LingoFuse
//
//  Process-wide facade over the LingoFuse C ABI.
//
//  Exposes network preparation, remote invocation, runtime options,
//  application name generation, and process-wide shutdown. Every
//  function forwards to exactly one native export.
//
//  CONTRACTS
//  ---------
//  - prepareDone() returns true only once per process. A second call
//    without an intervening shutdown() returns false, which is NOT a
//    failure.
//  - call() never returns a null handle. On timeout or unreachable
//    target the native layer returns a size-0 handle. Use tryCall() for
//    a nil-on-failure contract.
//  - shutdown() is idempotent.
//

import Foundation
import CLingoFuse

public enum Framework {

    // ------------------------------------------------------------------
    // Network preparation
    // ------------------------------------------------------------------

    /// Clears the preparation queue. Running services and clients are
    /// not affected.
    public static func resetPrepare() {
        LF_ResetPrepare()
    }

    /// Prepares a C4 service.
    ///
    /// - Returns: the internal tag assigned to this service (>= 0).
    /// - Throws: `.generic` on a duplicate address.
    @discardableResult
    public static func prepareService(
        listeningAddr: String,
        physicsAddr: String
    ) throws -> Int32 {
        let tag = LF_PrepareService(listeningAddr, physicsAddr)
        if tag < 0 {
            throw LingoFuseError.generic(
                message: "prepareService rejected address '\(listeningAddr)' (duplicate?)"
            )
        }
        return tag
    }

    /// Prepares a C4 client.
    ///
    /// - Parameters:
    ///   - physicsAddr: address of the target service.
    ///   - app: optional application to expose; nil for a pure consumer.
    /// - Returns: the internal tag assigned to this client (>= 0).
    /// - Throws: `.generic` on a duplicate address. Set
    ///   `Overlap_Connection=True` via setOption before this call to
    ///   allow multiple independent tunnels to the same address.
    @discardableResult
    public static func prepareClient(
        physicsAddr: String,
        app: AppHandle? = nil
    ) throws -> Int32 {
        let appHnd: TAppHnd? = app?.raw
        let tag = LF_PrepareClient(physicsAddr, appHnd)
        if tag < 0 {
            throw LingoFuseError.generic(
                message: "prepareClient rejected address '\(physicsAddr)' (duplicate?)"
            )
        }
        return tag
    }

    /// Starts the framework.
    ///
    /// - Returns: true on the first successful start; false on a second
    ///   call without an intervening shutdown(). A false return is NOT
    ///   a failure.
    @discardableResult
    public static func prepareDone() -> Bool {
        return LF_PrepareDone() == 1
    }

    /// Requests the simulated main thread to exit.
    ///
    /// [PITFALL] This also flushes the data handle pool, releasing every
    /// outstanding handle — including permanent handles. Do not use any
    /// data handle after this call has returned.
    public static func exitMainThread() {
        LF_ExitMainThread()
    }

    // ------------------------------------------------------------------
    // Runtime options
    // ------------------------------------------------------------------

    /// Adjusts a global runtime option. Unknown option names are
    /// silently ignored by the native layer.
    public static func setOption(_ option: String, _ value: String) {
        LF_SetOption(option, value)
    }

    // ------------------------------------------------------------------
    // Application name generation and query
    // ------------------------------------------------------------------

    /// Generates a globally unique application name.
    ///
    /// Must be called after prepareDone() returned true. The native
    /// pointer is valid for ~5 seconds; this function copies it
    /// immediately.
    public static func generateAppName() -> String {
        guard let ptr = LF_Generate_AppName() else { return "" }
        return String(cString: ptr)
    }

    /// Returns the name of an existing application handle.
    ///
    /// Same 5-second rule as generateAppName; copied immediately.
    public static func getAppName(_ app: AppHandle) throws -> String {
        guard app.isValid else {
            throw LingoFuseError.objectDisposed(objectName: "AppHandle")
        }
        guard let ptr = LF_Get_AppName(app.raw) else { return "" }
        return String(cString: ptr)
    }

    // ------------------------------------------------------------------
    // Remote invocation
    // ------------------------------------------------------------------

    /// Performs a synchronous remote call.
    ///
    /// - Returns: a DataHandle owning the response. Never nil; on
    ///   timeout or unreachable target the handle has size 0. The caller
    ///   must dispose it.
    /// - Throws: `.callFailed` when the native layer returns a null
    ///   handle (an unexpected transport-level failure).
    public static func call(
        _ appName: String,
        _ param: DataHandle,
        timeoutMs: UInt64 = 5000
    ) throws -> DataHandle {
        let result = LF_Call(appName, param.raw, timeoutMs)
        guard let r = result else {
            throw LingoFuseError.callFailed(
                operation: "Framework.call",
                targetApp: appName,
                targetApi: nil
            )
        }
        return DataHandle(internalHandle: r, owned: true)
    }

    /// Like `call`, but returns nil when the native layer produced an
    /// empty (size-0) response. The empty handle is disposed
    /// internally.
    public static func tryCall(
        _ appName: String,
        _ param: DataHandle,
        timeoutMs: UInt64 = 5000
    ) throws -> DataHandle? {
        let response = try call(appName, param, timeoutMs: timeoutMs)
        if response.size == 0 {
            response.dispose()
            return nil
        }
        return response
    }

    /// Sends a one-way notification. Delivery order is not guaranteed.
    public static func notify(_ appName: String, _ param: DataHandle) {
        LF_Notify(appName, param.raw)
    }

    /// Sends a one-way notification with FIFO ordering guaranteed for
    /// the same (app, api) pair.
    public static func sequencedNotify(_ appName: String, _ param: DataHandle) {
        LF_Sequenced_Notify(appName, param.raw)
    }

    // ------------------------------------------------------------------
    // Health checks
    // ------------------------------------------------------------------

    public static func checkMainThread() -> Bool {
        return LF_CheckMainThread() != 0
    }

    public static func checkApp(_ appName: String) -> Bool {
        return LF_CheckApp(appName) != 0
    }

    public static func checkApi(_ appName: String, _ apiName: String) -> Bool {
        return LF_CheckApi(appName, apiName) != 0
    }

    // ------------------------------------------------------------------
    // Shutdown
    // ------------------------------------------------------------------

    /// Gracefully terminates the framework, releasing all resources.
    ///
    /// After shutdown, every AppHandle still alive becomes invalid. The
    /// framework may be re-initialized by calling resetPrepare,
    /// prepareService, prepareClient, prepareDone again. Safe to call
    /// multiple times.
    public static func shutdown() {
        LF_Shutdown()
    }
}