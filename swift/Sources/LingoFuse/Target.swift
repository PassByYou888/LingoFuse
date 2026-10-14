//
//  Target.swift
//  LingoFuse
//
//  Addressing abstraction for remote invocation.
//
//  THE THREE ADDRESSING MODES
//  --------------------------
//  LingoFuse routes a remote call by one of three keys:
//
//      App name    A human-readable string identifying a logical app.
//                  Local-first: if the caller process itself hosts an
//                  App with the matching name, the call is serviced
//                  locally without touching the network.
//
//      UID         A 32-byte session identifier. Routes to the exact
//                  client whose TunnelLink produced that UID. Also
//                  local-first. The UID is regenerated on every
//                  reconnect; callers that cache one MUST re-probe
//                  after a link loss.
//
//      P2PName     A user-supplied group name. Routes to any client
//                  in the group, chosen by server-side load balancing
//                  (Cycle_Anchor) or sticky affinity (FixedSequenced).
//                  NOT local-first: even when the caller itself is in
//                  the group, the call is forwarded to the server for
//                  dispatch.
//
//  Each mode has its own C ABI family:
//
//      AppTarget      -> LF_Call / LF_Notify / LF_Sequenced_Notify
//      UidTarget      -> LF_UID_Call / LF_UID_Notify / LF_UID_Sequenced_Notify
//      P2PNameTarget  -> LF_P2PNAME_Call / LF_P2PNAME_Notify / LF_P2PNAME_Sequenced_Notify
//
//  This file unifies the three families behind a single `Target`
//  protocol so that the call syntax is identical regardless of the
//  addressing mode, and so that future additions (async, sequenced
//  call, cancellation) can be defined ONCE on the protocol and
//  inherited automatically by all three concrete types.
//
//  SYNC / ASYNC SPLIT
//  ------------------
//  This file defines the SYNCHRONOUS surface only:
//
//      call(_:_:)              / call(_:_:timeoutMs:)
//      tryCall(_:_:)           / tryCall(_:_:timeoutMs:)
//      notify(_:_:)
//      sequencedNotify(_:_:)
//
//  The ASYNCHRONOUS surface is defined by an extension in
//  `AsyncSupport.swift` (a separate file), which adds:
//
//      callAsync(_:_:) -> DataHandle   (async throws)
//      sequencedCallAsync(_:_:) -> DataHandle  (async throws)
//      sequencedCall(_:_:) -> DataHandle  (sync, blocking)
//
//  This file does NOT define them, and does NOT need to be modified
//  when they are added. Any type that conforms to `Target` inherits
//  the async methods automatically.
//
//  USAGE
//  -----
//      let calculator = AppTarget("Calculator")
//      let param = try DataHandle(apiName: "add")
//      try LfIo.writeJson(param, AddArgs(a: 5, b: 7))
//      param.position = 0
//
//      let response = try calculator.call("add", param)
//      if response.size > 0 {
//          let result: AddResult = try LfIo.readJson(response)
//      }
//
//  Or, in an async context (after AsyncSupport.swift is in place):
//
//      let response = try await calculator.callAsync("add", param)
//
//  ADDRESSING SEMANTICS
//  --------------------
//  The three concrete Target types differ ONLY in the routing key.
//  Every other aspect of the call (serialization, framing, error
//  handling, ownership) is identical. See `LingoFuse.md` for the
//  full routing semantics of each mode.
//

import Foundation
import CLingoFuse

// ========================================================================
// Target protocol
// ========================================================================

/// A routing key for remote invocation.
///
/// Conformers provide three private "raw hooks" that forward to the
/// C ABI function family for their addressing mode. The public call
/// surface (`call`, `tryCall`, `notify`, `sequencedNotify`) is defined
/// once as an extension and shared by every conformer.
///
/// The hooks are prefixed with an underscore to mark them as
/// implementation details of the protocol. Application code should
/// never call them directly.
public protocol Target: CustomStringConvertible {

    /// Default timeout, in milliseconds, applied by the public
    /// convenience methods when the caller does not supply one.
    ///
    /// The value is chosen at construction time and is never mutated.
    var defaultTimeoutMs: UInt64 { get }

    // ------------------------------------------------------------------
    // Raw hooks (protocol implementation details)
    // ------------------------------------------------------------------
    //
    // Each hook forwards to the C ABI function of the same name for
    // this addressing mode. Returning `TDataHnd?` rather than
    // `TDataHnd` mirrors the C ABI's nullability: a null pointer is
    // possible only in pathological allocation-failure scenarios, and
    // the public methods translate it into `LingoFuseError.callFailed`.

    /// Forwards to the synchronous Call primitive for this addressing
    /// mode. Returns the raw result handle, or `nil` on a null return.
    func _rawCall(
        _ apiName: String,
        _ param: DataHandle,
        timeoutMs: UInt64
    ) -> TDataHnd?

    /// Forwards to the one-way Notify primitive for this addressing mode.
    func _rawNotify(_ apiName: String, _ param: DataHandle)

    /// Forwards to the FIFO-ordered one-way Notify primitive for this
    /// addressing mode.
    func _rawSequencedNotify(_ apiName: String, _ param: DataHandle)
}

// ========================================================================
// Target protocol extension: shared synchronous surface
// ========================================================================

extension Target {

    // ------------------------------------------------------------------
    // call
    // ------------------------------------------------------------------

    /// Performs a synchronous remote call using the target's default
    /// timeout.
    ///
    /// - Returns: A `DataHandle` owning the response. **Never nil**:
    ///   on timeout or unreachable target the native layer returns a
    ///   handle with size `0`. The caller must dispose it.
    ///
    /// - Throws: `LingoFuseError.callFailed` when the native layer
    ///   returns a null handle (an unexpected transport-level failure).
    public func call(_ apiName: String, _ param: DataHandle) throws -> DataHandle {
        return try call(apiName, param, timeoutMs: defaultTimeoutMs)
    }

    /// Performs a synchronous remote call with an explicit timeout.
    ///
    /// - Parameter timeoutMs: Timeout in milliseconds. `0` means "wait
    ///   indefinitely".
    /// - Returns: A `DataHandle` owning the response. **Never nil.**
    /// - Throws: `LingoFuseError.callFailed` on a null return.
    public func call(
        _ apiName: String,
        _ param: DataHandle,
        timeoutMs: UInt64
    ) throws -> DataHandle {
        let raw = _rawCall(apiName, param, timeoutMs: timeoutMs)
        guard let r = raw else {
            throw LingoFuseError.callFailed(
                operation: "Target.call",
                targetApp: description,
                targetApi: apiName
            )
        }
        return DataHandle(internalHandle: r, owned: true)
    }

    // ------------------------------------------------------------------
    // tryCall
    // ------------------------------------------------------------------

    /// Like `call(_:_:)`, but returns `nil` when the native layer
    /// produced an empty (size-0) response. The empty handle is
    /// disposed internally.
    ///
    /// This is the idiomatic Swift way to detect a timeout or an
    /// unreachable target without inspecting the handle size.
    public func tryCall(_ apiName: String, _ param: DataHandle) throws -> DataHandle? {
        return try tryCall(apiName, param, timeoutMs: defaultTimeoutMs)
    }

    /// Like `call(_:_:timeoutMs:)`, but returns `nil` on a size-0
    /// response.
    public func tryCall(
        _ apiName: String,
        _ param: DataHandle,
        timeoutMs: UInt64
    ) throws -> DataHandle? {
        let response = try call(apiName, param, timeoutMs: timeoutMs)
        if response.size == 0 {
            response.dispose()
            return nil
        }
        return response
    }

    // ------------------------------------------------------------------
    // notify / sequencedNotify
    // ------------------------------------------------------------------

    /// Sends a one-way notification using this target's routing key.
    ///
    /// Delivery order is **not** guaranteed. Use
    /// `sequencedNotify(_:_:)` when FIFO ordering is required for a
    /// given `(target, apiName)` pair.
    ///
    /// The `param` handle is **not** consumed by this call.
    public func notify(_ apiName: String, _ param: DataHandle) {
        _rawNotify(apiName, param)
    }

    /// Sends a one-way notification with FIFO ordering guaranteed for
    /// the same `(target, apiName)` pair.
    ///
    /// Different pairs are independent and unordered with respect to
    /// each other.
    ///
    /// The `param` handle is **not** consumed by this call.
    public func sequencedNotify(_ apiName: String, _ param: DataHandle) {
        _rawSequencedNotify(apiName, param)
    }
}

// ========================================================================
// AppTarget
// ========================================================================

/// Addresses a logical App by name.
///
/// Routing is LOCAL-FIRST: if the caller process itself hosts an App
/// with the matching name and the requested API, the call is serviced
/// locally without touching the network.
public struct AppTarget: Target, Sendable, Hashable {

    /// The target App name. Not mutated after construction.
    public let appName: String

    /// Default timeout applied by the convenience overloads.
    public let defaultTimeoutMs: UInt64

    /// Creates a target for the given App name.
    ///
    /// - Parameters:
    ///   - appName: The target App name (UTF-8).
    ///   - defaultTimeoutMs: Default timeout in milliseconds.
    ///     Default: 5,000 ms (5 seconds).
    public init(_ appName: String, defaultTimeoutMs: UInt64 = 5000) {
        self.appName = appName
        self.defaultTimeoutMs = defaultTimeoutMs
    }

    /// Human-readable description, used in error messages and logs.
    /// Format: `app(Name)`.
    public var description: String {
        return "app(\(appName))"
    }

    // ------------------------------------------------------------------
    // Raw hooks
    // ------------------------------------------------------------------

    public func _rawCall(
        _ apiName: String,
        _ param: DataHandle,
        timeoutMs: UInt64
    ) -> TDataHnd? {
        return LF_Call(appName, param.raw, timeoutMs)
    }

    public func _rawNotify(_ apiName: String, _ param: DataHandle) {
        LF_Notify(appName, param.raw)
    }

    public func _rawSequencedNotify(_ apiName: String, _ param: DataHandle) {
        LF_Sequenced_Notify(appName, param.raw)
    }
}

// ========================================================================
// UidTarget
// ========================================================================

/// Addresses a specific session by its 32-byte UID.
///
/// Routing is LOCAL-FIRST, matching `AppTarget`. The UID is regenerated
/// on every TunnelLink, so callers that cache one must re-probe it
/// after a link loss.
///
/// A UID can address any API registered on the target -- whether
/// app-bound (`AppHandle.registerCall`) or process-wide
/// (`P2P.registerCall`) -- without requiring the caller to know the
/// target App name.
///
/// To learn a client's own UID, use the "whoami" pattern: register a
/// Call API on the target side whose callback reads the caller's UID
/// from its INPUT handle via `DataHandle.p2pUid()`. See the docstring
/// on `DataHandle.p2pUid()` for the full side-data contract.
public struct UidTarget: Target, Sendable, Hashable {

    /// The target UID. Not mutated after construction.
    public let uid: Uid

    /// Default timeout applied by the convenience overloads.
    public let defaultTimeoutMs: UInt64

    /// Creates a target for the given UID.
    ///
    /// - Parameters:
    ///   - uid: The target session UID.
    ///   - defaultTimeoutMs: Default timeout in milliseconds.
    ///     Default: 5,000 ms (5 seconds).
    public init(_ uid: Uid, defaultTimeoutMs: UInt64 = 5000) {
        self.uid = uid
        self.defaultTimeoutMs = defaultTimeoutMs
    }

    /// Human-readable description, used in error messages and logs.
    /// Format: `uid(01234567..89abcdef)`. The null UID renders as
    /// `uid(00000000..00000000)`.
    public var description: String {
        let hex = uid.toHex()
        let prefix = hex.prefix(8)
        let suffix = hex.suffix(8)
        return "uid(\(prefix)..\(suffix))"
    }

    // ------------------------------------------------------------------
    // Raw hooks
    // ------------------------------------------------------------------
    //
    // The C ABI's TP2P_UID argument is a 32-byte struct passed by value.
    // `Uid.withCValue(_:)` materializes the struct on the local stack
    // frame and hands `&struct` to the closure. The struct is not
    // retained anywhere after the closure returns.

    public func _rawCall(
        _ apiName: String,
        _ param: DataHandle,
        timeoutMs: UInt64
    ) -> TDataHnd? {
        return uid.withCValue { tp2p in
            return LF_UID_Call(tp2p, param.raw, timeoutMs)
        }
    }

    public func _rawNotify(_ apiName: String, _ param: DataHandle) {
        uid.withCValue { tp2p in
            LF_UID_Notify(tp2p, param.raw)
        }
    }

    public func _rawSequencedNotify(_ apiName: String, _ param: DataHandle) {
        uid.withCValue { tp2p in
            LF_UID_Sequenced_Notify(tp2p, param.raw)
        }
    }
}

// ========================================================================
// P2PNameTarget
// ========================================================================

/// Addresses a group of clients sharing a user-supplied P2P name.
///
/// Routing is **NOT** local-first: even when the caller process itself
/// hosts a client in the target group, the call is forwarded to the
/// server for dispatch. This preserves the server-side load-balancing
/// state.
///
/// The server-side dispatcher picks a target using one of two
/// strategies:
///
///   - Load balancing (Cycle_Anchor): the target with the smallest
///     anchor value is chosen, then its anchor is advanced.
///
///   - Sticky affinity (FixedSequenced, governed by the runtime option
///     `Fixed_Sequenced_Time`, default 20 seconds).
///
/// The group name is the value clients set via
/// `Options.setP2PName(_:)` (option key `"LF_P2P_name"`).
public struct P2PNameTarget: Target, Sendable, Hashable {

    /// The target P2P group name. Not mutated after construction.
    public let groupName: String

    /// Default timeout applied by the convenience overloads.
    public let defaultTimeoutMs: UInt64

    /// Creates a target for the given P2P group name.
    ///
    /// - Parameters:
    ///   - groupName: The target P2P group name (UTF-8).
    ///   - defaultTimeoutMs: Default timeout in milliseconds.
    ///     Default: 5,000 ms (5 seconds).
    public init(_ groupName: String, defaultTimeoutMs: UInt64 = 5000) {
        self.groupName = groupName
        self.defaultTimeoutMs = defaultTimeoutMs
    }

    /// Human-readable description, used in error messages and logs.
    /// Format: `p2p(group_name)`.
    public var description: String {
        return "p2p(\(groupName))"
    }

    // ------------------------------------------------------------------
    // Raw hooks
    // ------------------------------------------------------------------

    public func _rawCall(
        _ apiName: String,
        _ param: DataHandle,
        timeoutMs: UInt64
    ) -> TDataHnd? {
        return LF_P2PNAME_Call(groupName, param.raw, timeoutMs)
    }

    public func _rawNotify(_ apiName: String, _ param: DataHandle) {
        LF_P2PNAME_Notify(groupName, param.raw)
    }

    public func _rawSequencedNotify(_ apiName: String, _ param: DataHandle) {
        LF_P2PNAME_Sequenced_Notify(groupName, param.raw)
    }
}