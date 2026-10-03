//
//  Errors.swift
//  LingoFuse
//
//  Structured exception hierarchy for the LingoFuse Swift binding.
//
//  Every failure raised by this module is a `LingoFuseError`. The enum
//  has one case per failure mode documented in the C ABI and the C#
//  reference binding. Callers may catch `LingoFuseError` for a single
//  catch-all handler, or pattern-match a specific case for fine-grained
//  recovery.
//
//  Argument validation errors that are unrelated to the native layer
//  (nil arguments, out-of-range sizes) use the standard Swift error
//  cases defined here, not the foundation types TypeError / RangeError
//  which are JavaScript-specific.
//

import Foundation

/// The single error type produced by the LingoFuse Swift binding.
public enum LingoFuseError: Error, CustomStringConvertible {

    /// Unclassified failure.
    case generic(message: String)

    /// The native library could not be located or loaded.
    case libraryLoadFailed(libraryName: String, underlying: Error?)

    /// An operation was attempted on a null or already-disposed handle.
    case nullHandle(operation: String)

    /// A caller-supplied argument failed validation.
    case invalidArgument(operation: String, detail: String)

    /// A write into a data handle wrote fewer bytes than requested.
    case writeFailed(operation: String, expected: Int, actual: Int64)

    /// A read from a data handle returned fewer bytes than requested.
    case readFailed(operation: String, expected: Int, actual: Int)

    /// A remote call failed (null handle, timeout, or unreachable target).
    case callFailed(operation: String, targetApp: String?, targetApi: String?)

    /// `registerCall` / `registerNotify` was rejected by the native layer.
    case registrationFailed(operation: String, apiName: String)

    /// The framework is not running (the simulated main thread is not active).
    case notConnected(operation: String)

    /// A remote call timed out.
    case timeout(targetApp: String)

    /// An operation was attempted on an object that has been disposed.
    case objectDisposed(objectName: String)

    public var description: String {
        switch self {
        case .generic(let m):
            return "LingoFuse: \(m)"

        case .libraryLoadFailed(let name, let underlying):
            let tail = underlying.map { ": \($0)" } ?? ""
            return "LingoFuse library load failed for '\(name)'\(tail)"

        case .nullHandle(let op):
            return "\(op): handle is null or already disposed"

        case .invalidArgument(let op, let detail):
            return "\(op): invalid argument — \(detail)"

        case .writeFailed(let op, let expected, let actual):
            return "\(op): requested \(expected) bytes, wrote \(actual)"

        case .readFailed(let op, let expected, let actual):
            return "\(op): requested \(expected) bytes, only \(actual) available"

        case .callFailed(let op, let app, let api):
            let target = [app, api]
                .compactMap { $0 }
                .joined(separator: "/")
            return target.isEmpty
                ? "\(op): call failed"
                : "\(op): call to '\(target)' failed"

        case .registrationFailed(let op, let name):
            return "\(op): registration of '\(name)' was rejected " +
                   "(duplicate API name?)"

        case .notConnected(let op):
            return "\(op): the framework is not running"

        case .timeout(let app):
            return "call to '\(app)' timed out or reached an unreachable target"

        case .objectDisposed(let name):
            return "\(name) has already been disposed"
        }
    }
}