//
//  Framework+UidP2PName.swift
//  LingoFuse
//
//  Synchronous UID- and P2PName-addressed invocation on the
//  process-wide Framework facade.
//
//  COMPLEMENTS Framework.swift
//  ---------------------------
//  Framework.swift provides the App-name-addressed entry points:
//
//      Framework.call(_:_:timeoutMs:)
//      Framework.tryCall(_:_:timeoutMs:)
//      Framework.notify(_:_:)
//      Framework.sequencedNotify(_:_:)
//
//  This file adds the two OTHER addressing modes:
//
//      Framework.callByUid / tryCallByUid / notifyByUid / sequencedNotifyByUid
//      Framework.callByP2PName / tryCallByP2PName / notifyByP2PName /
//          sequencedNotifyByP2PName
//
//  Each method is a thin delegate to the corresponding `Target`
//  struct (`UidTarget` / `P2PNameTarget`). This keeps the routing
//  semantics, error messages, and timeout behaviour defined in ONE
//  place (the Target layer) and inherited automatically by the
//  Framework facade.
//
//  ADDRESSING SEMANTICS
//  --------------------
//  UID addressing     -> local-first; routes to the exact session.
//  P2PName addressing -> NOT local-first; the server picks a target
//                        in the group using Cycle_Anchor load
//                        balancing or the FixedSequenced window.
//
//  Both are described in full in `Target.swift` and in `LingoFuse.md`.
//
//  API NAME PARAMETER
//  ------------------
//  The UID and P2PName C ABI families do NOT take an API-name
//  argument. The routing key and the API name are both encoded in
//  the request payload header by the sender's transport layer
//  (Pascal side: TC40_LF_Client.Send_* ->
//  TMemory_Param_Tool.Rebuild_UID_and_P2PName).
//
//  This file passes the empty string to the underlying Target's
//  `apiName` parameter, which is used only for error messages. Call
//  sites therefore do not need to know the API name separately.
//

import Foundation

extension Framework {

    // ==================================================================
    // UID addressing
    // ==================================================================

    /// Performs a synchronous remote call addressed by session UID.
    ///
    /// Routing is LOCAL-FIRST, matching App-name routing. The UID can
    /// address any API registered on the target -- whether app-bound
    /// (`AppHandle.registerCall`) or process-wide (`P2P.registerCall`)
    /// -- without requiring the caller to know the target App name.
    ///
    /// - Parameters:
    ///   - uid: The target session UID.
    ///   - param: The request payload. Not consumed; the caller
    ///     retains ownership.
    ///   - timeoutMs: Timeout in milliseconds. `0` means "wait
    ///     indefinitely".
    ///
    /// - Returns: A `DataHandle` owning the response. **Never nil**:
    ///   on timeout or unreachable target the native layer returns a
    ///   handle with size `0`. The caller must dispose it.
    ///
    /// - Throws: `LingoFuseError.callFailed` on a null return.
    public static func callByUid(
        _ uid: Uid,
        _ param: DataHandle,
        timeoutMs: UInt64 = 5000
    ) throws -> DataHandle {
        return try UidTarget(uid, defaultTimeoutMs: timeoutMs)
            .call("", param, timeoutMs: timeoutMs)
    }

    /// Like `callByUid(_:_:timeoutMs:)`, but returns `nil` when the
    /// native layer produced an empty (size-0) response. The empty
    /// handle is disposed internally.
    public static func tryCallByUid(
        _ uid: Uid,
        _ param: DataHandle,
        timeoutMs: UInt64 = 5000
    ) throws -> DataHandle? {
        return try UidTarget(uid, defaultTimeoutMs: timeoutMs)
            .tryCall("", param, timeoutMs: timeoutMs)
    }

    /// Sends a one-way notification addressed by session UID.
    ///
    /// Delivery order is **not** guaranteed. Use
    /// `sequencedNotifyByUid(_:_:)` when FIFO ordering is required
    /// for a given `(uid, apiName)` pair.
    public static func notifyByUid(_ uid: Uid, _ param: DataHandle) {
        UidTarget(uid).notify("", param)
    }

    /// Sends a one-way notification addressed by session UID, with
    /// FIFO ordering guaranteed for the same `(uid, apiName)` pair.
    public static func sequencedNotifyByUid(_ uid: Uid, _ param: DataHandle) {
        UidTarget(uid).sequencedNotify("", param)
    }

    // ==================================================================
    // P2PName addressing
    // ==================================================================

    /// Performs a synchronous remote call addressed by P2P group name.
    ///
    /// Routing is **NOT** local-first: even when the caller process
    /// itself hosts a client in the target group, the call is
    /// forwarded to the server for dispatch. The server-side
    /// dispatcher picks a target using Cycle_Anchor load balancing or
    /// the FixedSequenced sticky-affinity window.
    ///
    /// - Parameters:
    ///   - groupName: The target P2P group name.
    ///   - param: The request payload. Not consumed.
    ///   - timeoutMs: Timeout in milliseconds. `0` means "wait
    ///     indefinitely".
    ///
    /// - Returns: A `DataHandle` owning the response. **Never nil.**
    ///
    /// - Throws: `LingoFuseError.callFailed` on a null return.
    public static func callByP2PName(
        _ groupName: String,
        _ param: DataHandle,
        timeoutMs: UInt64 = 5000
    ) throws -> DataHandle {
        return try P2PNameTarget(groupName, defaultTimeoutMs: timeoutMs)
            .call("", param, timeoutMs: timeoutMs)
    }

    /// Like `callByP2PName(_:_:timeoutMs:)`, but returns `nil` on a
    /// size-0 response.
    public static func tryCallByP2PName(
        _ groupName: String,
        _ param: DataHandle,
        timeoutMs: UInt64 = 5000
    ) throws -> DataHandle? {
        return try P2PNameTarget(groupName, defaultTimeoutMs: timeoutMs)
            .tryCall("", param, timeoutMs: timeoutMs)
    }

    /// Sends a one-way notification addressed by P2P group name.
    ///
    /// Delivery order is **not** guaranteed. Use
    /// `sequencedNotifyByP2PName(_:_:)` when FIFO ordering is
    /// required.
    public static func notifyByP2PName(
        _ groupName: String,
        _ param: DataHandle
    ) {
        P2PNameTarget(groupName).notify("", param)
    }

    /// Sends a one-way notification addressed by P2P group name, with
    /// FIFO ordering guaranteed for the same `(groupName, apiName)`
    /// pair.
    public static func sequencedNotifyByP2PName(
        _ groupName: String,
        _ param: DataHandle
    ) {
        P2PNameTarget(groupName).sequencedNotify("", param)
    }
}