// swift-tools-version: 5.9
//
// Package manifest for the LingoFuse Swift binding.
//
// Platform floor: macOS 12.0. This is the lowest deployment target that
// Swift 6.3 (Xcode 26.6) still supports, which lets the same package
// build for both Apple Silicon (arm64) and Intel (x86_64) Macs. Setting
// the floor at macOS 12.0 also prevents the toolchain from silently
// dropping the x86_64 architecture when the host runs on Apple Silicon.
//
// Products:
//   - LingoFuse      : the library (RAII wrappers + JSON I/O + facade)
//   - CrossService   : coordinator process for the cross-demo suite
//   - CrossNode      : worker node registering add / inv_seri
//   - CrossCall      : concurrent load-test client
//
// The three executables are wire-compatible with the C++ / C# / Pascal
// cross-demo binaries. Any combination of languages can be mixed.

import PackageDescription

let package = Package(
    name: "LingoFuse",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "LingoFuse",
            targets: ["LingoFuse"]
        ),
        .executable(
            name: "CrossService",
            targets: ["CrossService"]
        ),
        .executable(
            name: "CrossNode",
            targets: ["CrossNode"]
        ),
        .executable(
            name: "CrossCall",
            targets: ["CrossCall"]
        ),
    ],
    targets: [
        // -----------------------------------------------------------------
        // C target: the LingoFuse C ABI.
        // -----------------------------------------------------------------
        .target(
            name: "CLingoFuse",
            path: "Sources/CLingoFuse",
            publicHeadersPath: "include"
        ),

        // -----------------------------------------------------------------
        // Swift target: RAII wrappers, JSON I/O, process-wide facade.
        // -----------------------------------------------------------------
        .target(
            name: "LingoFuse",
            dependencies: ["CLingoFuse"],
            path: "Sources/LingoFuse"
        ),

        // -----------------------------------------------------------------
        // Cross-demo executables.
        // -----------------------------------------------------------------
        .executableTarget(
            name: "CrossService",
            dependencies: ["LingoFuse"],
            path: "Sources/CrossService"
        ),
        .executableTarget(
            name: "CrossNode",
            dependencies: ["LingoFuse"],
            path: "Sources/CrossNode"
        ),
        .executableTarget(
            name: "CrossCall",
            dependencies: ["LingoFuse"],
            path: "Sources/CrossCall"
        ),

        // -----------------------------------------------------------------
        // Test target.
        // -----------------------------------------------------------------
        .testTarget(
            name: "LingoFuseTests",
            dependencies: ["LingoFuse", "CLingoFuse"],
            path: "Tests/LingoFuseTests"
        ),
    ]
)