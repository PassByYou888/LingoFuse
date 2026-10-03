//
//  Status.swift
//  LingoFuse
//
//  Status queue and health-check helpers for the LingoFuse runtime.
//
//  The native library maintains a bounded FIFO of log messages, up to
//  1000 entries. Older entries are dropped when the buffer is full.
//
//  MAIN-THREAD DEPENDENCY
//  ----------------------
//  The queue is processed by the native simulated main thread. Before
//  Framework.prepareDone(), the queue may be empty or contain stale
//  data. Injection is NOT subject to the same restriction: postStatus
//  queues the message even when the main thread is not yet running.
//
//  STATIC BUFFER HAZARD
//  --------------------
//  The native LF_GetStatus returns a pointer into a process-wide static
//  buffer that the next call overwrites. This wrapper copies the string
//  immediately, so callers never observe a dangling pointer.
//

import Foundation
import CLingoFuse

public enum Status {

    // ------------------------------------------------------------------
    // Status queue
    // ------------------------------------------------------------------

    /// Returns the number of pending log messages in the status queue.
    public static func getStatusCount() -> Int32 {
        return LF_GetStatusCount()
    }

    /// Retrieves the next log message from the status queue, or an
    /// empty string when the queue is empty.
    public static func getStatus() -> String {
        guard let ptr = LF_GetStatus() else { return "" }
        return String(cString: ptr)
    }

    /// Drains up to `maxMessages` pending status messages in FIFO order.
    /// Stops early when the native queue returns an empty message.
    public static func drainStatus(maxMessages: Int = 64) -> [String] {
        if maxMessages <= 0 { return [] }
        let pending = Int(getStatusCount())
        if pending <= 0 { return [] }

        let count = min(pending, maxMessages)
        var messages: [String] = []
        messages.reserveCapacity(count)

        for _ in 0..<count {
            let msg = getStatus()
            if msg.isEmpty { break }
            messages.append(msg)
        }
        return messages
    }

    /// Injects a custom log message into the status queue. The message
    /// is queued even when the simulated main thread is not yet running.
    public static func postStatus(_ message: String) {
        LF_PostStatus(message)
    }

    // ------------------------------------------------------------------
    // Health checks
    // ------------------------------------------------------------------

    /// Returns true when the simulated main thread is currently running.
    public static func checkMainThread() -> Bool {
        return LF_CheckMainThread() != 0
    }

    /// Probes whether an application with the given name is available.
    ///
    /// The lookup uses a local cache updated by network broadcasts with
    /// an approximate 3-second delay. False negatives immediately after
    /// registration, and false positives shortly after unregistration,
    /// are both normal.
    public static func checkApp(_ appName: String) -> Bool {
        return LF_CheckApp(appName) != 0
    }

    /// Probes whether the named API is available for the given
    /// application. Same cache-based caveat as checkApp.
    public static func checkApi(_ appName: String, _ apiName: String) -> Bool {
        return LF_CheckApi(appName, apiName) != 0
    }
}