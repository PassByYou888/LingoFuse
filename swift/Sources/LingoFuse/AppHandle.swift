//
//  AppHandle.swift
//  LingoFuse
//
//  RAII wrapper around a native LingoFuse application handle (TAppHnd).
//
//  See the top of the delivered code for the full contract. This file
//  is the corrected version: the callback contexts are internal (not
//  private nested types) so that the top-level @_cdecl trampolines can
//  dispatch to them without protocol glue.
//

import Foundation
import CLingoFuse

// ========================================================================
// Callback context boxes
// ========================================================================

/// Boxed Call-mode handler. The instance is stored in AppHandle's
/// internal dictionary and passed to the native layer through the
/// `trigger` pointer as an Unmanaged reference.
internal final class LfCallContext {
    let apiName: String
    let handler: (DataHandle, DataHandle) -> Void

    init(apiName: String, handler: @escaping (DataHandle, DataHandle) -> Void) {
        self.apiName = apiName
        self.handler = handler
    }

    func invoke(input: TDataHnd?, output: TDataHnd?) {
        guard let input = input, let output = output else { return }
        let inHandle = DataHandle.borrow(input)
        let outHandle = DataHandle.borrow(output)
        handler(inHandle, outHandle)
    }
}

/// Boxed Notify-mode handler.
internal final class LfNotifyContext {
    let apiName: String
    let handler: (DataHandle) -> Void

    init(apiName: String, handler: @escaping (DataHandle) -> Void) {
        self.apiName = apiName
        self.handler = handler
    }

    func invoke(input: TDataHnd?) {
        guard let input = input else { return }
        let inHandle = DataHandle.borrow(input)
        handler(inHandle)
    }
}

// ========================================================================
// C callback trampolines
// ========================================================================

@_cdecl("lf_swift_call_trampoline")
internal func swiftCallTrampoline(
    trigger: UnsafeMutableRawPointer?,
    input: TDataHnd?,
    output: TDataHnd?
) {
    guard let trigger = trigger else { return }
    let ctx = Unmanaged<LfCallContext>
        .fromOpaque(trigger)
        .takeUnretainedValue()
    ctx.invoke(input: input, output: output)
}

@_cdecl("lf_swift_notify_trampoline")
internal func swiftNotifyTrampoline(
    trigger: UnsafeMutableRawPointer?,
    input: TDataHnd?
) {
    guard let trigger = trigger else { return }
    let ctx = Unmanaged<LfNotifyContext>
        .fromOpaque(trigger)
        .takeUnretainedValue()
    ctx.invoke(input: input)
}

// ========================================================================
// AppHandle
// ========================================================================

public final class AppHandle {

    private var rawHandle: TAppHnd?
    private let appName: String
    private var disposed: Bool = false
    private let lock = NSLock()

    private var callContexts: [String: LfCallContext] = [:]
    private var notifyContexts: [String: LfNotifyContext] = [:]

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    public init(name: String, description: String = "") throws {
        let raw = LF_CreateApp(name, description)
        guard let handle = raw else {
            throw LingoFuseError.generic(
                message: "LF_CreateApp returned null for '\(name)'"
            )
        }
        self.rawHandle = handle
        self.appName = name
    }

    deinit {
        dispose()
    }

    // ------------------------------------------------------------------
    // Identity and state
    // ------------------------------------------------------------------

    public var name: String { return appName }

    public var raw: TAppHnd { return currentRaw("raw") }

    public var isValid: Bool { return !disposed && rawHandle != nil }

    // ------------------------------------------------------------------
    // API registration
    // ------------------------------------------------------------------

    @discardableResult
    public func registerCall(
        _ apiName: String,
        _ description: String = "",
        _ handler: @escaping (DataHandle, DataHandle) -> Void
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if disposed {
            throw LingoFuseError.objectDisposed(objectName: "AppHandle")
        }
        guard let hnd = rawHandle else {
            throw LingoFuseError.nullHandle(operation: "registerCall")
        }

        let ctx = LfCallContext(apiName: apiName, handler: handler)
        let trigger = Unmanaged.passUnretained(ctx).toOpaque()
        let rc = LF_RegisterCall(hnd, apiName, description, trigger,
                                 swiftCallTrampoline)
        if rc != 1 { return false }
        callContexts[apiName.lowercased()] = ctx
        return true
    }

    @discardableResult
    public func registerNotify(
        _ apiName: String,
        _ description: String = "",
        _ handler: @escaping (DataHandle) -> Void
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if disposed {
            throw LingoFuseError.objectDisposed(objectName: "AppHandle")
        }
        guard let hnd = rawHandle else {
            throw LingoFuseError.nullHandle(operation: "registerNotify")
        }

        let ctx = LfNotifyContext(apiName: apiName, handler: handler)
        let trigger = Unmanaged.passUnretained(ctx).toOpaque()
        let rc = LF_RegisterNotify(hnd, apiName, description, trigger,
                                   swiftNotifyTrampoline)
        if rc != 1 { return false }
        notifyContexts[apiName.lowercased()] = ctx
        return true
    }

    @discardableResult
    public func unregister(_ apiName: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if disposed {
            throw LingoFuseError.objectDisposed(objectName: "AppHandle")
        }
        guard let hnd = rawHandle else {
            throw LingoFuseError.nullHandle(operation: "unregister")
        }

        let rc = LF_Unregister(hnd, apiName)
        if rc == 1 {
            let key = apiName.lowercased()
            callContexts.removeValue(forKey: key)
            notifyContexts.removeValue(forKey: key)
            return true
        }
        return false
    }

    // ------------------------------------------------------------------
    // Local execution
    // ------------------------------------------------------------------

    public func localCall(_ param: DataHandle) throws -> DataHandle {
        lock.lock()
        defer { lock.unlock() }

        if disposed {
            throw LingoFuseError.objectDisposed(objectName: "AppHandle")
        }
        guard let hnd = rawHandle else {
            throw LingoFuseError.nullHandle(operation: "localCall")
        }

        let result = LF_LocalCall(hnd, param.raw)
        guard let r = result else {
            throw LingoFuseError.callFailed(
                operation: "localCall",
                targetApp: appName,
                targetApi: nil
            )
        }
        return DataHandle(internalHandle: r, owned: true)
    }

    public func localNotify(_ param: DataHandle) throws {
        lock.lock()
        defer { lock.unlock() }

        if disposed {
            throw LingoFuseError.objectDisposed(objectName: "AppHandle")
        }
        guard let hnd = rawHandle else {
            throw LingoFuseError.nullHandle(operation: "localNotify")
        }
        LF_LocalNotify(hnd, param.raw)
    }

    // ------------------------------------------------------------------
    // Client binding
    // ------------------------------------------------------------------

    @discardableResult
    public func bind() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }

        if disposed {
            throw LingoFuseError.objectDisposed(objectName: "AppHandle")
        }
        guard let hnd = rawHandle else {
            throw LingoFuseError.nullHandle(operation: "bind")
        }
        return LF_BindApp(hnd)
    }

    // ------------------------------------------------------------------
    // Lifetime
    // ------------------------------------------------------------------

    public func dispose() {
        lock.lock()
        defer { lock.unlock() }

        if disposed { return }
        disposed = true

        let handle = rawHandle
        rawHandle = nil

        if let h = handle {
            LF_FreeApp(h)
        }

        // Release contexts AFTER LF_FreeApp returns.
        callContexts.removeAll()
        notifyContexts.removeAll()
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    private func currentRaw(_ operation: String) -> TAppHnd {
        precondition(
            !disposed && rawHandle != nil,
            "\(operation): AppHandle has been disposed"
        )
        return rawHandle!
    }
}