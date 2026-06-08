// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTokenDashboard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexTokenDashboard", targets: ["CodexTokenDashboard"])
    ],
    dependencies: [
        .package(url: "https://github.com/narner/TiktokenSwift.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CodexTokenDashboard",
            dependencies: ["TiktokenSwift"],
            path: "Sources/CodexTokenDashboard"
        )
    ]
)
