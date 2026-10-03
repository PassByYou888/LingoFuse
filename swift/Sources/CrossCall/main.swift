//
//  main.swift
//  CrossCall
//
//  Concurrent client / load tester for the "ipc:cross" endpoint.
//
//  See the module header delivered earlier for the full contract.
//  This version adds the mandatory LF_LoadLibrary() call and a
//  fatal-and-pause helper.
//

import Foundation
import LingoFuse

func fatalAndPause(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    FileHandle.standardError.write(
        "The window will close in 10 seconds.\n".data(using: .utf8)!
    )
    FileHandle.standardError.write(
        "Run from an existing PowerShell window to see errors immediately.\n"
            .data(using: .utf8)!
    )
    Thread.sleep(forTimeInterval: 10)
    exit(1)
}

print("=== Cross Call (Client) ===")

// -------------------------------------------------------------------
// 0. Load the native library.
// -------------------------------------------------------------------
if LF_LoadLibrary() != 1 {
    fatalAndPause(
        "[FATAL] LF_LoadLibrary() failed.\n" +
        "        Place LingoFuse64.dll, z_ipc_64.dll, and mimalloc64.dll\n" +
        "        next to the executable, or add their directory to PATH."
    )
}
print("[Call] Native library loaded.")

// -------------------------------------------------------------------
// Configuration
// -------------------------------------------------------------------

let targetApp = "demo"
let endpoint = "ipc:cross"

let workerThreads = 32
let testSeconds: Double = 10.0
let callTimeoutMs: UInt64 = 1000
let pauseMs = 1
let logEveryNthCall: Int64 = 5000

let numberMin: Int32 = 1
let numberMax: Int32 = 1000

// -------------------------------------------------------------------
// Thread-safe line output
// -------------------------------------------------------------------

private let logLock = NSLock()
private func log(_ message: String) {
    logLock.lock()
    print(message)
    logLock.unlock()
}

// -------------------------------------------------------------------
// Statistics
// -------------------------------------------------------------------

final class Stats {
    private let lock = NSLock()
    private var _total: Int64 = 0
    private var _success: Int64 = 0
    private var _failed: Int64 = 0
    private var _addCalls: Int64 = 0
    private var _invSeriCalls: Int64 = 0

    func recordAdd(ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        _total += 1; _addCalls += 1
        if ok { _success += 1 } else { _failed += 1 }
    }

    func recordInvSeri(ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        _total += 1; _invSeriCalls += 1
        if ok { _success += 1 } else { _failed += 1 }
    }

    var total: Int64 { lock.lock(); defer { lock.unlock() }; return _total }
    var success: Int64 { lock.lock(); defer { lock.unlock() }; return _success }
    var failed: Int64 { lock.lock(); defer { lock.unlock() }; return _failed }
    var addCalls: Int64 { lock.lock(); defer { lock.unlock() }; return _addCalls }
    var invSeriCalls: Int64 { lock.lock(); defer { lock.unlock() }; return _invSeriCalls }
}

final class AtomicFlag {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

// -------------------------------------------------------------------
// Remote call wrappers
// -------------------------------------------------------------------

func remoteAdd(_ a: Int32, _ b: Int32) -> Int32? {
    do {
        let param = try DataHandle(apiName: "add")
        defer { param.dispose() }
        try param.writeInt32(a)
        try param.writeInt32(b)
        param.position = 0

        let response = try Framework.call(targetApp, param, timeoutMs: callTimeoutMs)
        defer { response.dispose() }
        if response.size < 4 { return nil }
        return try response.readInt32()
    } catch {
        return nil
    }
}

func remoteInvSeri() -> String? {
    do {
        let b:   UInt8  = 200
        let w:   UInt16 = 0x10
        let c:   UInt32 = 0x2F
        let u64: UInt64 = 0x3F
        let s:   String = "hello world"
        let f:   Float  = 3.14

        let param = try DataHandle(apiName: "inv_seri")
        defer { param.dispose() }

        try param.writeUInt8(b)
        try param.writeUInt16(w)
        try param.writeUInt32(c)
        try param.writeUInt64(u64)
        try param.writeString(s)
        try param.writeSingle(f)
        param.position = 0

        let response = try Framework.call(targetApp, param, timeoutMs: callTimeoutMs)
        defer { response.dispose() }
        if response.size == 0 { return nil }

        let rf   = try response.readSingle()
        let rs   = try response.readString()
        let ru64 = try response.readUInt64()
        let rc   = try response.readUInt32()
        let rw   = try response.readUInt16()
        let rb   = try response.readUInt8()

        return "reply: [\(rb), \(rw), \(rc), \(ru64), \"\(rs)\", \(rf)]" +
               "  original: [\(b), \(w), \(c), \(u64), \"\(s)\", \(f)]"
    } catch {
        return nil
    }
}

// -------------------------------------------------------------------
// Worker thread body
// -------------------------------------------------------------------

func workerBody(index: Int, stop: AtomicFlag, stats: Stats) {
    var rng = SystemRandomNumberGenerator()
    var iter: Int64 = 0

    while !stop.value {
        iter += 1
        let doLog = (iter % logEveryNthCall == 0)

        let choice = Int.random(in: 0...1, using: &rng)
        if choice == 0 {
            let a = Int32.random(in: numberMin...numberMax, using: &rng)
            let b = Int32.random(in: numberMin...numberMax, using: &rng)
            let result = remoteAdd(a, b)
            stats.recordAdd(ok: result != nil)

            if doLog {
                if let sum = result {
                    log("[Call \(index)] add(\(a), \(b)) = \(sum)")
                } else {
                    log("[Call \(index)] add(\(a), \(b)) timed out or failed.")
                }
            }
        } else {
            let result = remoteInvSeri()
            stats.recordInvSeri(ok: result != nil)

            if doLog {
                if let r = result {
                    log("[Call \(index)] \(r)")
                } else {
                    log("[Call \(index)] inv_seri timed out or failed.")
                }
            }
        }

        if pauseMs > 0 {
            Thread.sleep(forTimeInterval: Double(pauseMs) / 1000.0)
        }
    }
}

// -------------------------------------------------------------------
// Main
// -------------------------------------------------------------------

Framework.setOption("Wait_Connection_ReadyOk", "True")
Framework.setOption("Overlap_Connection", "True")
Framework.setOption("Wait_Connection_Timeout", "10000")

Framework.resetPrepare()

do {
    let clientTag = try Framework.prepareClient(
        physicsAddr: endpoint,
        app: nil
    )
    print("[Call] Client tag=\(clientTag)")
} catch {
    fatalAndPause("[FATAL] prepareClient failed: \(error)\n" +
                  "        Is CrossService running on \(endpoint)?")
}

let started = Framework.prepareDone()
if !started && !Status.checkMainThread() {
    fatalAndPause("[FATAL] prepareDone failed and main thread is not running.")
}

print("[Call] Connected to \(endpoint). " +
      "Starting \(Int(testSeconds))-second load test with " +
      "\(workerThreads) threads...")

let stop = AtomicFlag()
let stats = Stats()
let group = DispatchGroup()

let startTime = Date()

for i in 0..<workerThreads {
    let idx = i
    DispatchQueue.global().async(group: group) {
        workerBody(index: idx, stop: stop, stats: stats)
    }
}

Thread.sleep(forTimeInterval: testSeconds)
stop.set()
group.wait()

let elapsed = Date().timeIntervalSince(startTime)

let total         = stats.total
let success       = stats.success
let failed        = stats.failed
let addCalls      = stats.addCalls
let invSeriCalls  = stats.invSeriCalls

let successRate: Double = total > 0
    ? 100.0 * Double(success) / Double(total)
    : 0.0
let throughput: Double = elapsed > 0
    ? Double(total) / elapsed
    : 0.0
let successThroughput: Double = elapsed > 0
    ? Double(success) / elapsed
    : 0.0

print("")
print("[Call] Load test summary")
print(String(format: "         duration          : %.3f s", elapsed))
print("         total calls       : \(total)")
print(String(format: "         success           : %ld (%.2f %%)", success, successRate))
print("         failed            : \(failed)")
print("         add calls         : \(addCalls)")
print("         inv_seri calls    : \(invSeriCalls)")
print(String(format: "         throughput        : %.2f calls/s", throughput))
print(String(format: "         success throughput: %.2f calls/s", successThroughput))
print("")

print("[Call] Press Enter to exit...")
_ = readLine()

// -------------------------------------------------------------------
// Cleanup order: LF-CLEAN-001.
// -------------------------------------------------------------------
NetworkEvents.clearNetworkEvent()
Framework.exitMainThread()
Framework.shutdown()
LF_FreeLibrary()

print("[Call] Bye.")