//
//  AsyncSupport.swift
//  LingoFuse
//
//  Modern async/await support for LingoFuse remote invocation.
//
//  WHAT THIS FILE PROVIDES
//  -----------------------
//  A Swift-native async surface on top of the C ABI's callback-based
//  asynchronous family (LF_Async_Call, LF_Async_Sequenced_Call,
//  LF_UID_Async_Call, LF_UID_Async_Sequenced_Call,
//  LF_P2PNAME_Async_Call, LF_P2PNAME_Async_Sequenced_Call).
//
//  Every `Target` conformer automatically gains:
//
//      callAsync(_:_:) async throws -> DataHandle
//      sequencedCallAsync(_:_:) async throws -> DataHandle
//      sequencedCall(_:_:timeoutMs:) throws -> DataHandle  (sync)
//
//  And `Framework` gains three top-level entry points:
//
//      Framework.callAsync(_:_:) async throws -> DataHandle
//      Framework.callAsyncByUid(_:_:) async throws -> DataHandle
//      Framework.callAsyncByP2PName(_:_:) async throws -> DataHandle
//
//  The user writes ordinary Swift:
//
//      let response = try await target.callAsync("add", param)
//      let result: AddResult = try LfIo.readJson(response)
//      response.dispose()
//
//  No callback, no Unmanaged, no void*, no trampoline at the call site.
//
//  DESIGN
//  ------
//  This file does NOT modify `Target.swift`. Instead, it declares a
//  narrower protocol:
//
//      public protocol AsyncTarget: Target, Sendable {
//          func _rawAsyncCall(_:_:data:onResult:) -> Int32
//          func _rawAsyncSequencedCall(_:_:data:onResult:) -> Int32
//      }
//
//  and adds conformance for the three concrete Target structs. The
//  public async methods are then defined once as an extension on
//  `AsyncTarget`, so all three addressing modes share a single
//  implementation.
//
//  CALLBACK BRIDGING
//  -----------------
//  A `CheckedContinuation` is the Swift-native way to bridge a
//  callback-based C API into an `async` function. Each in-flight
//  request is associated with one continuation; the C worker thread
//  resumes it exactly once when the result arrives.
//
//  The continuation is carried across the C ABI as the callback's
//  opaque `data` pointer:
//
//      AsyncCallContext (heap) --Unmanaged.passRetained--> void*
//          |
//          v  native worker thread
//      trampoline --Unmanaged.takeRetainedValue--> AsyncCallContext
//          |
//          v
//      copy the result bytes out of the framework-owned handle,
//      build a caller-owned DataHandle, and resume the continuation.
//
//  The result handle delivered to the C callback is OWNED BY THE
//  FRAMEWORK and is released the instant the callback returns. This
//  file copies the bytes into a fresh DataHandle BEFORE resuming, so
//  the caller never observes a dangling handle.
//
//  TIMEOUT POLICY
//  --------------
//  The asynchronous methods do NOT take a timeout parameter, matching
//  the C++ and Rust bindings. The C ABI has no timeout on its async
//  family, and the native transport layer guarantees that every
//  dispatched async request eventually produces a callback (with
//  either a result or an empty payload).
//
//  Callers that need a hard deadline should wrap the call in a
//  `withThrowingTaskGroup` or use `Task.withTimeout` at a higher
//  layer. The C-side request is NOT cancelled by such a wrapper; its
//  result is simply dropped when it arrives.
//
//  The SYNCHRONOUS `sequencedCall(_:_:timeoutMs:)` is an exception:
//  because it blocks the calling thread, a timeout is mandatory.
//  See its docstring for the exact contract.
//
//  THREADING
//  ---------
//  The trampoline runs on a native worker thread (NOT the caller's
//  thread and NOT the simulated main thread). It performs only:
//
//      - copy the result bytes out of the framework-owned handle
//      - resume the continuation
//
//  No user code runs on the worker thread. The continuation resumes
//  the awaiting Swift task on whatever executor it was running on;
//  the Swift runtime handles the thread hop automatically.
//
//  A `@convention(c)` closure is used for the trampoline, NOT
//  `@_cdecl`. This is the same choice made for `AppHandle.swift`:
//  `@_cdecl` duplicates its C symbol in every object file that
//  references it, and the Windows linker rejects the duplicate.
//

import Foundation
import CLingoFuse

// ========================================================================
// Private: context carried across the C ABI
// ========================================================================

/// The Swift-side state of a single in-flight asynchronous call.
///
/// One instance is allocated per `callAsync` / `sequencedCallAsync`
/// invocation, handed to the C ABI as the trampoline's `data` pointer,
/// and consumed by the trampoline when the callback fires.
///
/// The continuation is resumed EXACTLY ONCE, either by the trampoline
/// (on success) or by the caller's dispatch-failure branch (on a
/// non-1 return from the C ABI). The two paths are mutually exclusive.
private final class AsyncCallContext {

    /// The API name, used only for error messages.
    let apiName: String

    /// A human-readable description of the target, used only for
    /// error messages.
    let targetDescription: String

    /// The continuation to resume with the result (or an error).
    let continuation: CheckedContinuation<DataHandle, Error>

    init(
        apiName: String,
        targetDescription: String,
        continuation: CheckedContinuation<DataHandle, Error>
    ) {
        self.apiName = apiName
        self.targetDescription = targetDescription
        self.continuation = continuation
    }
}

// ========================================================================
// Private: the single async trampoline
// ========================================================================

/// The C-ABI callback used for every asynchronous call across every
/// addressing mode.
///
/// Lives on the Swift ABI as a value of type `LF_AsyncCallOnResult`.
/// It is passed to `LF_Async_Call` (and its siblings) at dispatch
/// time; the native layer receives a plain function pointer.
///
/// {!!!!!  NO LOCAL CAPTURES  !!!!!}
/// A `@convention(c)` closure MUST NOT capture any local state. The
/// closure below refers only to the `AsyncCallContext` TYPE, which is
/// a type reference rather than a value capture, so it is legal.
private let swiftAsyncCallTrampoline: LF_AsyncCallOnResult = { userData, rawResult in

    // Reclaim the context. `takeRetainedValue` balances the
    // `Unmanaged.passRetained` performed by the caller before dispatch.
    guard let userData = userData else { return }
    let ctx = Unmanaged<AsyncCallContext>
        .fromOpaque(userData)
        .takeRetainedValue()

    // A null result pointer means the native layer could not allocate
    // a result handle. This is a transport-level failure; surface it
    // as a normal Swift error.
    guard let raw = rawResult else {
        ctx.continuation.resume(throwing: LingoFuseError.callFailed(
            operation: "Target.callAsync",
            targetApp: ctx.targetDescription,
            targetApi: ctx.apiName
        ))
        return
    }

    // The handle at `raw` is OWNED BY THE FRAMEWORK and is released
    // the instant this trampoline returns. We copy its bytes into a
    // fresh, caller-owned handle before resuming.
    do {
        let borrowed = DataHandle.borrow(raw)
        let bytes = try borrowed.readAllBytes()

        let copy = try DataHandle(apiName: ctx.apiName)
        try copy.writeBytes(bytes)
        // Reset the cursor so the caller can immediately read from
        // the beginning (the natural expectation for a response).
        copy.position = 0

        ctx.continuation.resume(returning: copy)
    } catch {
        ctx.continuation.resume(throwing: error)
    }
}

// ========================================================================
// Private: box for the blocking synchronous variant
// ========================================================================

/// Thread-safe cell used to carry a single result from an inner Task
/// to the blocking caller of `sequencedCall(_:_:timeoutMs:)`.
///
/// The `abandoned` flag handles the timeout race: if the caller has
/// already given up, a late-arriving success result is disposed
/// instead of stored, so no DataHandle leaks.
private final class BlockingResultBox: @unchecked Sendable {

    private let lock = NSLock()
    private var value: Result<DataHandle, Error>?
    private var abandoned = false

    func set(_ r: Result<DataHandle, Error>) {
        lock.lock()
        let giveUp = abandoned
        if !giveUp {
            value = r
        }
        lock.unlock()

        if giveUp {
            // Late arrival after timeout. Dispose any handle we
            // received so it does not leak.
            if case .success(let handle) = r {
                handle.dispose()
            }
        }
    }

    /// Reads and consumes the stored value. Returns nil if the caller
    /// gave up before the value was stored.
    func take() -> Result<DataHandle, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let v = value
        value = nil
        return v
    }

    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
    }
}

// ========================================================================
// AsyncTarget protocol
// ========================================================================

/// A `Target` that also exposes the C ABI's asynchronous call family.
///
/// Conformers provide two private "raw hooks" that forward to the
/// asynchronous C ABI functions for their addressing mode. The public
/// async surface (`callAsync`, `sequencedCallAsync`, `sequencedCall`)
/// is defined once as an extension on this protocol.
///
/// Application code never implements this protocol directly. The
/// three concrete target structs (`AppTarget`, `UidTarget`,
/// `P2PNameTarget`) are the only conformers.
public protocol AsyncTarget: Target, Sendable {

    // ------------------------------------------------------------------
    // Raw hooks (protocol implementation details)
    // ------------------------------------------------------------------

    /// Forwards to the asynchronous Call primitive for this addressing
    /// mode. Returns 1 if the request was queued, 0 otherwise.
    func _rawAsyncCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32

    /// Forwards to the asynchronous sequenced Call primitive for this
    /// addressing mode. Returns 1 if the request was queued, 0
    /// otherwise.
    func _rawAsyncSequencedCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32
}

// ========================================================================
// Conformances
// ========================================================================

extension AppTarget: AsyncTarget {

    public func _rawAsyncCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32 {
        return LF_Async_Call(appName, param.raw, data, onResult)
    }

    public func _rawAsyncSequencedCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32 {
        return LF_Async_Sequenced_Call(appName, param.raw, data, onResult)
    }
}

extension UidTarget: AsyncTarget {

    public func _rawAsyncCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32 {
        return uid.withCValue { tp2p in
            return LF_UID_Async_Call(tp2p, param.raw, data, onResult)
        }
    }

    public func _rawAsyncSequencedCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32 {
        return uid.withCValue { tp2p in
            return LF_UID_Async_Sequenced_Call(tp2p, param.raw, data, onResult)
        }
    }
}

extension P2PNameTarget: AsyncTarget {

    public func _rawAsyncCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32 {
        return LF_P2PNAME_Async_Call(groupName, param.raw, data, onResult)
    }

    public func _rawAsyncSequencedCall(
        _ apiName: String,
        _ param: DataHandle,
        data: UnsafeMutableRawPointer?,
        onResult: LF_AsyncCallOnResult?
    ) -> Int32 {
        return LF_P2PNAME_Async_Sequenced_Call(groupName, param.raw, data, onResult)
    }
}

// ========================================================================
// Public async surface
// ========================================================================

extension AsyncTarget {

    // ------------------------------------------------------------------
    // callAsync
    // ------------------------------------------------------------------

    /// Performs an asynchronous remote call and awaits the response.
    ///
    /// The call returns when the native worker thread delivers the
    /// result, or throws `LingoFuseError.callFailed` if the request
    /// could not be queued. There is no timeout: the C ABI's async
    /// family has none, and the native transport layer guarantees
    /// every dispatched request eventually completes.
    ///
    /// The returned `DataHandle` is a fresh, caller-owned handle with
    /// its cursor reset to 0. The caller MUST dispose it.
    ///
    /// - Parameters:
    ///   - apiName: The remote API name (used for error messages; the
    ///     actual routing key is embedded in `param`).
    ///   - param: The request payload. Its bytes are copied
    ///     synchronously by the native layer during dispatch, so the
    ///     handle may be disposed immediately after this function
    ///     returns.
    ///
    /// - Returns: A new `DataHandle` owning the response.
    ///
    /// - Throws:
    ///   * `LingoFuseError.callFailed` if the native layer rejected
    ///     the dispatch, or if the transport layer reported a
    ///     failure.
    ///   * Any error raised while copying the response out of the
    ///     framework-owned handle.
    public func callAsync(
        _ apiName: String,
        _ param: DataHandle
    ) async throws -> DataHandle {
        return try await withCheckedThrowingContinuation { continuation in
            dispatchAsync(
                apiName: apiName,
                param: param,
                continuation: continuation,
                useSequenced: false
            )
        }
    }

    // ------------------------------------------------------------------
    // sequencedCallAsync
    // ------------------------------------------------------------------

    /// Performs an asynchronous remote call with FIFO ordering
    /// guaranteed for the same `(target, apiName)` pair, and awaits
    /// the response.
    ///
    /// Semantics are identical to `callAsync(_:_:)` except for the
    /// ordering guarantee. Different `(target, apiName)` pairs remain
    /// independent and unordered with respect to each other.
    public func sequencedCallAsync(
        _ apiName: String,
        _ param: DataHandle
    ) async throws -> DataHandle {
        return try await withCheckedThrowingContinuation { continuation in
            dispatchAsync(
                apiName: apiName,
                param: param,
                continuation: continuation,
                useSequenced: true
            )
        }
    }

    // ------------------------------------------------------------------
    // sequencedCall (synchronous, blocking)
    // ------------------------------------------------------------------

    /// Performs a synchronous, FIFO-ordered remote call by blocking
    /// the calling thread until the response arrives or the timeout
    /// expires.
    ///
    /// {!!!!!  BLOCKS THE CALLING THREAD  !!!!!}
    /// This method must NOT be called from within an `async` context
    /// on a shared executor (including the main actor): it blocks the
    /// current thread, which can deadlock the Swift concurrency
    /// runtime under load.
    ///
    /// In an `async` context, ALWAYS prefer `sequencedCallAsync(_:_:)`.
    /// This synchronous variant exists only for compatibility with the
    /// C++ / Rust / Python surface and for callers that are already
    /// on a dedicated thread.
    ///
    /// {!!!!!  TIMEOUT IS MANDATORY  !!!!!}
    /// Unlike `callAsync` / `sequencedCallAsync`, this method DOES
    /// take a timeout. It must, because it blocks a thread: without a
    /// timeout, a lost response would leave the thread blocked
    /// forever. On timeout, the method throws
    /// `LingoFuseError.timeout` and returns control to the caller.
    /// The underlying C request is NOT cancelled; its result is
    /// silently discarded when it eventually arrives.
    ///
    /// - Parameters:
    ///   - apiName: The remote API name.
    ///   - param: The request payload.
    ///   - timeoutMs: Timeout in milliseconds. When `nil`, the
    ///     target's `defaultTimeoutMs` is used.
    ///
    /// - Returns: A new `DataHandle` owning the response.
    ///
    /// - Throws:
    ///   * `LingoFuseError.callFailed` on dispatch failure.
    ///   * `LingoFuseError.timeout` if the response did not arrive
    ///     within `timeoutMs`.
    public func sequencedCall(
        _ apiName: String,
        _ param: DataHandle,
        timeoutMs: UInt64? = nil
    ) throws -> DataHandle {
        let effectiveTimeout = timeoutMs ?? defaultTimeoutMs
        let box = BlockingResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let response = try await sequencedCallAsync(apiName, param)
                box.set(.success(response))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        let deadline = DispatchTime.now() + .milliseconds(Int(effectiveTimeout))
        let outcome = semaphore.wait(timeout: deadline)

        switch outcome {
        case .success:
            guard let result = box.take() else {
                throw LingoFuseError.generic(
                    message: "Target.sequencedCall: no result produced"
                )
            }
            return try result.get()

        case .timedOut:
            // Mark the box as abandoned so that a late success
            // disposes its handle instead of storing it.
            box.abandon()
            throw LingoFuseError.timeout(targetApp: description)
        }
    }

    // ------------------------------------------------------------------
    // Private dispatch helper
    // ------------------------------------------------------------------

    /// Common implementation of the two async entry points.
    ///
    /// Allocates an `AsyncCallContext`, hands it to the C ABI as the
    /// callback's `data` pointer, and resumes the continuation from
    /// the caller's thread if the C side rejects the dispatch.
    ///
    /// The C side never both rejects the dispatch AND invokes the
    /// callback, so the continuation is resumed exactly once.
    private func dispatchAsync(
        apiName: String,
        param: DataHandle,
        continuation: CheckedContinuation<DataHandle, Error>,
        useSequenced: Bool
    ) {
        let ctx = AsyncCallContext(
            apiName: apiName,
            targetDescription: description,
            continuation: continuation
        )
        let raw = Unmanaged.passRetained(ctx).toOpaque()

        let rc: Int32
        if useSequenced {
            rc = _rawAsyncSequencedCall(
                apiName,
                param,
                data: raw,
                onResult: swiftAsyncCallTrampoline
            )
        } else {
            rc = _rawAsyncCall(
                apiName,
                param,
                data: raw,
                onResult: swiftAsyncCallTrampoline
            )
        }

        if rc != 1 {
            // The native layer never stored the pointer, so no
            // callback will fire. Reclaim the context here and resume
            // the continuation with a normal Swift error.
            let taken = Unmanaged<AsyncCallContext>
                .fromOpaque(raw)
                .takeRetainedValue()
            taken.continuation.resume(throwing: LingoFuseError.callFailed(
                operation: useSequenced
                    ? "Target.sequencedCallAsync"
                    : "Target.callAsync",
                targetApp: description,
                targetApi: apiName
            ))
        }
    }
}

// ========================================================================
// Framework convenience
// ========================================================================

extension Framework {

    /// Asynchronous variant of `Framework.call(_:_:timeoutMs:)`.
    ///
    /// Semantically equivalent to
    /// `AppTarget(appName).callAsync(apiName, param)`.
    ///
    /// There is no timeout parameter: the C ABI's async family has
    /// none. See the file-level docstring for the full rationale.
    ///
    /// - Parameters:
    ///   - appName: The target App name.
    ///   - param: The request payload. Its bytes are copied
    ///     synchronously by the native layer during dispatch.
    ///
    /// - Returns: A new `DataHandle` owning the response.
    public static func callAsync(
        _ appName: String,
        _ param: DataHandle
    ) async throws -> DataHandle {
        // The API name is embedded in `param`; the `apiName:` argument
        // of `AppTarget.callAsync(_:_:)` is only used for error
        // messages. Passing the empty string keeps the error message
        // generic and avoids double-reporting the API name.
        return try await AppTarget(appName).callAsync("", param)
    }

    /// Asynchronous variant of `Framework.callByUid(_:_:timeoutMs:)`.
    ///
    /// Semantically equivalent to
    /// `UidTarget(uid).callAsync("", param)`.
    public static func callAsyncByUid(
        _ uid: Uid,
        _ param: DataHandle
    ) async throws -> DataHandle {
        return try await UidTarget(uid).callAsync("", param)
    }

    /// Asynchronous variant of
    /// `Framework.callByP2PName(_:_:timeoutMs:)`.
    ///
    /// Semantically equivalent to
    /// `P2PNameTarget(groupName).callAsync("", param)`.
    public static func callAsyncByP2PName(
        _ groupName: String,
        _ param: DataHandle
    ) async throws -> DataHandle {
        return try await P2PNameTarget(groupName).callAsync("", param)
    }
}