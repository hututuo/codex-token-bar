import Foundation
import XCTest
@testable import CodexTokenBar

final class AppResourcesTests: XCTestCase {
    func testPackagedLayoutResolvesWithoutDeveloperFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Renamed Token Bar.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let bundleURL = resources.appendingPathComponent("CodexTokenBar_CodexTokenBar.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("schema fixture".utf8).write(to: bundleURL.appendingPathComponent("codex-ledger-schema.sql"))
        let bundle = AppResources.resolve(applicationURL: app, resourceURL: resources) {
            XCTFail("An installed app must not consult SwiftPM's build-machine accessor")
            return .main
        }
        XCTAssertEqual(bundle?.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
        let schema = try XCTUnwrap(bundle?.url(forResource: "codex-ledger-schema", withExtension: "sql"))
        XCTAssertEqual(try String(contentsOf: schema, encoding: .utf8), "schema fixture")
    }

    func testMissingPackagedBundleDoesNotFallBackOrTrap() {
        let app = URL(fileURLWithPath: "/missing/Token Bar.app")
        XCTAssertNil(AppResources.resolve(applicationURL: app, resourceURL: app.appendingPathComponent("Contents/Resources")) {
            XCTFail("Missing installed resources must fail gracefully")
            return .main
        })
    }

    func testCommandLineRetainsSwiftPMResourceAccess() throws {
        let bundle = AppResources.resolve(applicationURL: URL(fileURLWithPath: "/missing/cli"), resourceURL: nil) { .main }
        XCTAssertEqual(bundle, .main)
        XCTAssertNoThrow(try AppResources.verifyPackagedResources())
    }
}
