// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTokenBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexTokenBar", targets: ["CodexTokenBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/narner/TiktokenSwift.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0")
    ],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AgentSpeedCore",
            dependencies: ["CZstd"],
            path: "Vendor/AgentSpeed/macos/Sources/AgentSpeedCore"
        ),
        .executableTarget(
            name: "CodexTokenBar",
            dependencies: [
                "TiktokenSwift",
                "CZstd",
                "AgentSpeedCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CodexTokenBar",
            resources: [.copy("Resources/o200k_base.tiktoken"), .copy("Resources/ModelTrace"), .copy("Resources/SpeedLeaderboard")]
        ),
        .testTarget(
            name: "AgentSpeedCoreTests",
            dependencies: ["AgentSpeedCore"],
            path: "Vendor/AgentSpeed/macos/Tests/AgentSpeedCoreTests"
        ),
        .testTarget(
            name: "CodexTokenBarTests",
            dependencies: ["CodexTokenBar"],
            path: "Tests/CodexTokenBarTests"
        )
    ]
)
