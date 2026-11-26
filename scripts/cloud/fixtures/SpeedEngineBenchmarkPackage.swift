// swift-tools-version: 6.0
import PackageDescription

// Cloud-only harness: use the exact production targets and release settings,
// compiling only the injected benchmark rather than unrelated DEBUG-only tests.
let package = Package(
    name: "SpeedEngineBenchmark",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CZstd", path: "Sources/CZstd", publicHeadersPath: "include"),
        .target(name: "SharedSourceIO", path: "Sources/SharedSourceIO"),
        .target(name: "AgentSpeedCore", dependencies: ["CZstd", "SharedSourceIO"],
                path: "Vendor/AgentSpeed/macos/Sources/AgentSpeedCore"),
        .testTarget(name: "AgentSpeedCoreTests", dependencies: ["AgentSpeedCore"],
                    path: "Vendor/AgentSpeed/macos/Tests/AgentSpeedCoreTests",
                    sources: ["SpeedEngineBenchmarkTests.swift"])
    ]
)
