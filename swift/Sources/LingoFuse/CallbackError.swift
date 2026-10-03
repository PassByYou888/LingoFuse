//
//  CallbackError.swift
//  LingoFuse
//
//  Process-wide reporter for exceptions thrown by user callbacks.
//
//  User callbacks run on native worker threads. An exception escaping
//  such a callback would cross into the C stack; Swift's @_cdecl
//  trampolines catch every error and route it here.
//
//  The reporter is optional. When no handler is installed, errors are
//  written to stderr so that they are not silently lost.
//

import Foundation

public enum CallbackErrorReporter {

    /// Signature of an installed handler. The first argument names the
    /// callback site (for example "AppHandle.registerCall[add]"); the
    /// second is the thrown error.
    public typealias Handler = (_ source: String, _ error: Error) -> Void

    private static let lock = NSLock()
    private static var _handler: Handler?

    /// Installs a callback error handler. Passing nil removes the handler.
    public static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        _handler = handler
    }

    /// Returns the currently installed handler, if any.
    public static var handler: Handler? {
        lock.lock()
        defer { lock.unlock() }
        return _handler
    }

    /// Internal entry point used by the trampolines in AppHandle and
    /// NetworkEvents.
    internal static func report(source: String, error: Error) {
        lock.lock()
        let h = _handler
        lock.unlock()

        if let h = h {
            // A handler that throws must not escape into the native
            // worker thread.
            h(source, error)
            return
        }

        let line = "[LingoFuse] Callback error in \(source): \(error)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}