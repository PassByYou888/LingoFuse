//
//  main.swift
//  CrossNode
//
//  Worker node that registers the "add" and "inv_seri" Call APIs.
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

print("=== Cross Node (Worker) ===")

// -------------------------------------------------------------------
// 0. Load the native library. This MUST be the first LF_* call.
// -------------------------------------------------------------------
if LF_LoadLibrary() != 1 {
    fatalAndPause(
        "[FATAL] LF_LoadLibrary() failed.\n" +
        "        Place LingoFuse64.dll, z_ipc_64.dll, and mimalloc64.dll\n" +
        "        next to the executable, or add their directory to PATH."
    )
}
print("[Node] Native library loaded.")

let endpoint = "ipc:cross"
let appName = "demo"

// -------------------------------------------------------------------
// Thread-safe line output.
// -------------------------------------------------------------------
private let logLock = NSLock()
private func log(_ message: String) {
    logLock.lock()
    print(message)
    logLock.unlock()
}

// -------------------------------------------------------------------
// 1. Create the application.
// -------------------------------------------------------------------
let app: AppHandle
do {
    app = try AppHandle(name: appName, description: "Swift worker node")
} catch {
    fatalAndPause("[FATAL] AppHandle creation failed: \(error)")
}

// -------------------------------------------------------------------
// 2. Register "add": (int32, int32) -> int32
// -------------------------------------------------------------------
do {
    let ok = try app.registerCall("add", "add(int a, int b) -> int") { input, output in
        guard let a = try? input.readInt32(),
              let b = try? input.readInt32() else {
            log("[Node] add: failed to read parameters")
            return
        }
        let c = a + b
        log("[Node] add(\(a), \(b)) = \(c)")
        try? output.writeInt32(c)
    }
    if !ok {
        fatalAndPause("[FATAL] Failed to register API 'add'")
    }
} catch {
    fatalAndPause("[FATAL] registerCall('add') threw: \(error)")
}

// -------------------------------------------------------------------
// 3. Register "inv_seri": (uint8, uint16, uint32, uint64, string, float)
//                        -> same types reversed
// -------------------------------------------------------------------
do {
    let ok = try app.registerCall(
        "inv_seri",
        "inv_seri() -> reversed typed sequence"
    ) { input, output in
        guard let b   = try? input.readUInt8(),
              let w   = try? input.readUInt16(),
              let c   = try? input.readUInt32(),
              let u64 = try? input.readUInt64(),
              let s   = try? input.readString(),
              let f   = try? input.readSingle() else {
            log("[Node] inv_seri: failed to read data")
            return
        }

        log("[Node] inv_seri received: [\(b), \(w), \(c), \(u64), \"\(s)\", \(f)]")

        try? output.writeSingle(f)
        try? output.writeString(s)
        try? output.writeUInt64(u64)
        try? output.writeUInt32(c)
        try? output.writeUInt16(w)
        try? output.writeUInt8(b)

        log("[Node] inv_seri replied: [\(f), \"\(s)\", \(u64), \(c), \(w), \(b)]")
    }
    if !ok {
        fatalAndPause("[FATAL] Failed to register API 'inv_seri'")
    }
} catch {
    fatalAndPause("[FATAL] registerCall('inv_seri') threw: \(error)")
}

// -------------------------------------------------------------------
// 4. Start the framework.
// -------------------------------------------------------------------
do {
    Framework.setOption("Wait_Connection_ReadyOk", "True")
    Framework.setOption("Overlap_Connection", "True")
    Framework.setOption("Wait_Connection_Timeout", "10000")

    Framework.resetPrepare()

    let clientTag = try Framework.prepareClient(
        physicsAddr: endpoint,
        app: app
    )
    print("[Node] Client tag=\(clientTag)")

    let started = Framework.prepareDone()
    if !started && !Status.checkMainThread() {
        fatalAndPause(
            "[FATAL] prepareDone failed and main thread is not running.\n" +
            "        Is CrossService running on \(endpoint)?"
        )
    }
} catch {
    fatalAndPause("[FATAL] startup failed: \(error)")
}

print("[Node] Registered APIs 'add' and 'inv_seri' " +
      "under application '\(appName)'.")
print("[Node] Online. Press Enter to exit...")
_ = readLine()

// -------------------------------------------------------------------
// Cleanup order: LF-CLEAN-001.
// -------------------------------------------------------------------
print("[Node] Shutting down...")
NetworkEvents.clearNetworkEvent()
Framework.exitMainThread()
app.dispose()
Framework.shutdown()
LF_FreeLibrary()

print("[Node] Bye.")