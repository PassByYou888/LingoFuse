//
//  NetworkEvents.swift
//  LingoFuse
//
//  Process-global connect / disconnect event handlers.
//
//  SEMANTICS
//  ---------
//  - Connect: fires the FIRST time a client receives a service API-info
//    broadcast. NOT the TCP handshake. Fires once per connection
//    lifecycle, and again after an auto-reconnect.
//  - Disconnect: fires once per physical link loss. An automatic
//    reconnect does NOT emit a Disconnect for the reconnect attempt.
//
//  THREADING
//  ---------
//  Callbacks run on a background worker thread owned by the native
//  library. Do not touch UI controls directly; marshal to the main
//  thread with DispatchQueue.main.async.
//
//  REPLACE SEMANTICS
//  -----------------
//  setNetworkEvent is a REPLACE operation. Calling it again discards
//  any previously installed handlers, including those whose
//  corresponding argument is nil in the new call.
//

import Foundation
import CLingoFuse

// ========================================================================
// Process-wide handler state
// ========================================================================

private let networkEventLock = NSLock()
private var _connectHandler: ((String) -> Void)?
private var _disconnectHandler: ((String) -> Void)?

// ========================================================================
// C trampolines (top-level; @_cdecl requires a global function)
// ========================================================================

@_cdecl("lf_swift_network_connect_trampoline")
internal func swiftNetworkConnectTrampoline(addr: UnsafePointer<CChar>?) {
    guard let addr = addr else { return }
    let endpoint = String(cString: addr)

    networkEventLock.lock()
    let handler = _connectHandler
    networkEventLock.unlock()

    if let h = handler {
        h(endpoint)
    }
}

@_cdecl("lf_swift_network_disconnect_trampoline")
internal func swiftNetworkDisconnectTrampoline(addr: UnsafePointer<CChar>?) {
    guard let addr = addr else { return }
    let endpoint = String(cString: addr)

    networkEventLock.lock()
    let handler = _disconnectHandler
    networkEventLock.unlock()

    if let h = handler {
        h(endpoint)
    }
}

// ========================================================================
// Public API
// ========================================================================

public enum NetworkEvents {

    /// Installs the process-global connect and disconnect handlers.
    /// Passing nil for either argument disables that event.
    public static func setNetworkEvent(
        onConnect: ((String) -> Void)?,
        onDisconnect: ((String) -> Void)?
    ) {
        networkEventLock.lock()
        _connectHandler = onConnect
        _disconnectHandler = onDisconnect
        networkEventLock.unlock()

        let c: LF_NetworkEventFunc? = (onConnect == nil)
            ? nil
            : swiftNetworkConnectTrampoline
        let d: LF_NetworkEventFunc? = (onDisconnect == nil)
            ? nil
            : swiftNetworkDisconnectTrampoline

        LF_Set_Network_Event(c, d)
    }

    /// Removes both handlers. Safe to call multiple times.
    public static func clearNetworkEvent() {
        setNetworkEvent(onConnect: nil, onDisconnect: nil)
    }

    /// Returns true when at least one handler is currently installed.
    public static var isNetworkEventInstalled: Bool {
        networkEventLock.lock()
        defer { networkEventLock.unlock() }
        return _connectHandler != nil || _disconnectHandler != nil
    }
}