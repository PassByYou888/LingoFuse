//
//  main.swift
//  CrossService
//
//  Coordinator process for the IPC endpoint "ipc:cross".
//
//  See the module header delivered earlier for the full contract.
//  This version adds the mandatory LF_LoadLibrary() call and a
//  fatal-and-pause helper so that a startup failure is visible even
//  when the executable is launched by double-clicking.
//

import Foundation
import LingoFuse

// -------------------------------------------------------------------
// Fatal handler
//
// Writes the message to stderr and pauses for 10 seconds so the user
// can read it before the console window closes. Using a timed sleep
// instead of readLine() makes the pause independent of stdin.
// -------------------------------------------------------------------
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

print("=== Cross Service (Coordinator) ===")

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
print("[Service] Native library loaded.")

let endpoint = "ipc:cross"

// -------------------------------------------------------------------
// 1. Options.
// -------------------------------------------------------------------
Framework.setOption("Wait_Connection_ReadyOk", "True")
Framework.setOption("Overlap_Connection", "True")
Framework.setOption("Wait_Connection_Timeout", "10000")

Framework.resetPrepare()

// -------------------------------------------------------------------
// 2. Service endpoint.
// -------------------------------------------------------------------
do {
    let serviceTag = try Framework.prepareService(
        listeningAddr: endpoint,
        physicsAddr: endpoint
    )
    print("[Service] Endpoint created, tag=\(serviceTag)")
} catch {
    fatalAndPause("[FATAL] prepareService failed: \(error)")
}

// -------------------------------------------------------------------
// 3. Consumer-only client.
// -------------------------------------------------------------------
do {
    let clientTag = try Framework.prepareClient(
        physicsAddr: endpoint,
        app: nil
    )
    print("[Service] Consumer-only client, tag=\(clientTag)")
} catch {
    fatalAndPause("[FATAL] prepareClient failed: \(error)")
}

// -------------------------------------------------------------------
// 4. Start the framework.
// -------------------------------------------------------------------
let started = Framework.prepareDone()
if !started && !Status.checkMainThread() {
    fatalAndPause(
        "[FATAL] prepareDone failed and main thread is not running.\n" +
        "        Check the native log output above."
    )
}

print("IPC service '\(endpoint)' is running. Press Enter to exit...")
_ = readLine()
print("Shutting down...")

// -------------------------------------------------------------------
// Cleanup order: LF-CLEAN-001.
// -------------------------------------------------------------------
NetworkEvents.clearNetworkEvent()
Framework.exitMainThread()
Framework.shutdown()
LF_FreeLibrary()

print("Bye.")