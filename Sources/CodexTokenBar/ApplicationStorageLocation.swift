import Foundation

/// Default paths for application-owned files. XCTest/Swift Testing may create
/// production services without specifying a database URL; their defaults must
/// never become legacy inputs in the user's real ledger on the next launch.
enum ApplicationStorageLocation {
    static let isTestProcess: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || process.arguments.first?.contains(".xctest/") == true
            || process.processName.hasSuffix("PackageTests")
    }()

    private static let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexTokenBarTests-\(UUID().uuidString)", isDirectory: true)

    static func directory(_ directory: FileManager.SearchPathDirectory,
                          fileManager: FileManager = .default) -> URL? {
        if isTestProcess {
            return testRoot.appendingPathComponent(
                directory == .cachesDirectory ? "Caches" : "Application Support", isDirectory: true)
        }
        return fileManager.urls(for: directory, in: .userDomainMask).first
    }

    static var applicationSupport: URL {
        directory(.applicationSupportDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }
}
