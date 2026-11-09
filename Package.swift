// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTokenBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexTokenBar", targets: ["CodexTokenBar"]),
        .executable(name: "TokenBarDiagnostics", targets: ["TokenBarDiagnostics"]),
        .executable(name: "TokenBarClaudeLocal", targets: ["TokenBarClaudeLocal"])
    ],
    dependencies: [
        .package(url: "https://github.com/narner/TiktokenSwift.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0")
    ],
    targets: [
        .target(name: "TokenBarDiagnosticsCore", path: "Sources/TokenBarDiagnosticsCore"),
        .executableTarget(name: "TokenBarDiagnostics", dependencies: ["TokenBarDiagnosticsCore"], path: "Sources/TokenBarDiagnostics"),
        .testTarget(name: "TokenBarDiagnosticsCoreTests", dependencies: ["TokenBarDiagnosticsCore"], path: "Tests/TokenBarDiagnosticsCoreTests"),
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ClaudeLocalCaptureCore",
            path: "Sources/ClaudeLocalCaptureCore"
        ),
        .executableTarget(
            name: "TokenBarClaudeLocal",
            dependencies: ["ClaudeLocalCaptureCore"],
            path: "Sources/TokenBarClaudeLocal"
        ),
        .target(name: "SharedSourceIO", path: "Sources/SharedSourceIO"),
        .target(
            name: "AgentSpeedCore",
            dependencies: ["CZstd", "SharedSourceIO"],
            path: "Vendor/AgentSpeed/macos/Sources/AgentSpeedCore"
        ),
        .executableTarget(
            name: "CodexTokenBar",
            dependencies: [
                "TokenBarDiagnosticsCore",
                "TiktokenSwift",
                "CZstd",
                "AgentSpeedCore",
                "SharedSourceIO",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CodexTokenBar",
            resources: [.copy("Resources/o200k_base.tiktoken"), .copy("Resources/activity-speed-schema.sql"), .copy("Resources/codex-ledger-schema.sql"), .copy("Resources/standard-api-price-history.json"), .copy("Resources/model-display-names.json"), .copy("Resources/model-presentation-policy.json"), .copy("Resources/model-presentation-cases.json"), .copy("Resources/model-cost-order.json"), .copy("Resources/ModelTrace"), .copy("Resources/SpeedLeaderboard")]
        ),
        .testTarget(
            name: "AgentSpeedCoreTests",
            dependencies: ["AgentSpeedCore"],
            path: "Vendor/AgentSpeed/macos/Tests/AgentSpeedCoreTests"
        ),
        .testTarget(
            name: "ClaudeLocalCaptureCoreTests",
            dependencies: ["ClaudeLocalCaptureCore"],
            path: "Tests/ClaudeLocalCaptureCoreTests"
        ),
        .testTarget(
            name: "CodexTokenBarTests",
            dependencies: ["CodexTokenBar"],
            path: "Tests/CodexTokenBarTests"
        )
    ]
)
