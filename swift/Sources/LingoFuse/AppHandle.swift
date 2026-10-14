//
//  AppHandle.swift
//  LingoFuse
//
//  RAII wrapper around a native LingoFuse application handle (TAppHnd).
//
//  CALLBACK BRIDGING
//  -----------------
//  A user-supplied `(DataHandle, DataHandle) -> Void` closure cannot
//  be handed directly to the C ABI, which requires a plain
//  `LF_CallFunc` function pointer. This file bridges the two layers:
//
//    1. The closure is boxed in an `LfCallContext` instance.
//    2. The context is passed to the C ABI as the opaque `trigger`
//       pointer, `Unmanaged.passUnretained`.
//    3. A single `@convention(c)` trampoline (defined below) receives
//       the trigger, reconstitutes the context, and invokes the boxed
//       closure.
//    4. The AppHandle keeps a strong reference to the context for as
//       long as the API is registered, and releases it on unregister
//       or on dispose.
//
//  {!!!!!  TRAMPOLINES ARE `@convention(c)`, NOT `@_cdecl`  !!!!!}
//  See the docstring on `swiftCallTrampoline` for the full rationale:
//  on Windows, `@_cdecl` duplicates the C symbol in every .o file
//  that references it, and lld-link rejects the duplicate. A
//  `@convention(c)` closure has no such problem.
//

import Foundation
import CLingoFuse

// ========================================================================
// Callback context boxes
// ========================================================================

/// Boxed Call-mode handler. The instance is stored in AppHandle's
/// internal dictionary and passed to the native layer through the
/// `trigger` pointer as an `Unmanaged` reference.
internal final class LfCallContext {
    let apiName: String
    let handler: (DataHandle, DataHandle) -> Void

    init(apiName: String,
         handler: @escaping (DataHandle, DataHandle) -> Void) {
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
// ------------------------------------------------------------------------
// These are `@convention(c)` closure constants, NOT `@_cdecl` functions.
//
// {!!!!!  WHY NOT `@_cdecl`  !!!!!}
// On Windows, `@_cdecl` functions emit a C-ABI symbol that Swift IRGen
// writes into EVERY object file that references the function. The
// Windows linker (lld-link) treats the resulting duplicate definitions
// as a hard error, unlike the Darwin and Linux linkers, which merge
// them silently.
//
// `AppHandle.swift` and `P2P.swift` both register callbacks, so both
// reference these trampolines, so a `@_cdecl` version would fail at
// link time with:
//
//     lld-link: error: duplicate symbol: lf_swift_call_trampoline
//         >>> defined at ...apphandle.o
//         >>> defined at ...p2p.o
//
// A `@convention(c)` closure is bound to the Swift ABI: it is a value
// of type `LF_CallFunc` / `LF_NotifyFunc` that is passed to the native
// layer at registration time. It generates no C symbol of its own, so
// cross-file references are ordinary Swift references and cannot
// duplicate.
//
// {!!!!!  NO LOCAL CAPTURES  !!!!!}
// A `@convention(c)` closure MUST NOT capture any local state. The two
// closures below are pure functions of their arguments -- they refer
// only to the `LfCallContext` / `LfNotifyContext` TYPES, which are
// type references rather than value captures, so they are legal
// `@convention(c)` closures.
// ========================================================================

/// The single C-ABI callback used for every registered Call API.
///
/// Lives on the Swift ABI as a value of type `LF_CallFunc`. It is
/// passed to `LF_RegisterCall` (and `LF_Register_P2P_Call`) at
/// registration time; the native layer receives a plain function
/// pointer, exactly as it would from a `@_cdecl` function.
internal let swiftCallTrampoline: LF_CallFunc = { trigger, input, output in
    guard let trigger = trigger else { return }
    let ctx = Unmanaged<LfCallContext>
        .fromOpaque(trigger)
        .takeUnretainedValue()
    ctx.invoke(input: input, output: output)
}

/// The single C-ABI callback used for every registered Notify API.
internal let swiftNotifyTrampoline: LF_NotifyFunc = { trigger, input in
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