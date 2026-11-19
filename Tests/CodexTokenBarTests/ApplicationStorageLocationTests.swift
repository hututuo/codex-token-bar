import Foundation
import CryptoKit
import XCTest
@testable import CodexTokenBar

final class ApplicationStorageLocationTests: XCTestCase {
    @MainActor
    func testDefaultServicesCannotWriteIntoTheUsersApplicationSupport() throws {
        let keys = ["CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE", "CODEX_TOKEN_BAR_USAGE_CACHE_DIR"]
        let previous = ProcessInfo.processInfo.environment
        for key in keys { unsetenv(key) }
        defer {
            for key in keys {
                if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        XCTAssertTrue(ApplicationStorageLocation.isTestProcess)
        let support = ApplicationStorageLocation.applicationSupport.standardizedFileURL
        let real = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertNotEqual(support, real.standardizedFileURL)
        XCTAssertTrue(support.path.contains("/CodexTokenBarTests-"))
        XCTAssertTrue(MultiClientUsageStore.defaultDatabaseURL.path.hasPrefix(support.path + "/"))
        XCTAssertTrue(try BusinessDatabaseMigration.Configuration.production().container.path.hasPrefix(support.path + "/"))

        let home = support.appendingPathComponent("test-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(home.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let relative = "CodexTokenBarSwift/exact-usage-history-v1/\(digest).sqlite"
        let realIndex = real.appendingPathComponent(relative)
        let before = FileManager.default.fileExists(atPath: realIndex.path)
        _ = try CodexUsageHistoryIndex(codexHome: home)
        XCTAssertEqual(FileManager.default.fileExists(atPath: realIndex.path), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(relative).path))
    }
}
