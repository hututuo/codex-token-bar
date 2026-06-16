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
        .executableTarget(
            name: "CodexTokenBar",
            dependencies: [
                "TiktokenSwift",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CodexTokenBar"
        ),
        .testTarget(
            name: "CodexTokenBarTests",
            dependencies: ["CodexTokenBar"],
            path: "Tests/CodexTokenBarTests"
        )
    ]
)
