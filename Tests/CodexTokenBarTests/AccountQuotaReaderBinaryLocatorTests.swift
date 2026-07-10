import Foundation
import XCTest
@testable import CodexTokenBar

final class AccountQuotaReaderBinaryLocatorTests: XCTestCase {
    func testExplicitOverrideWinsOverRegisteredAppScanAndPATH() throws {
        let fixture = try makeFixture()
        let override = try fixture.writeExecutable("override/codex")
        let registeredApp = try fixture.writeApp("Elsewhere/Renamed.app")
        _ = try fixture.writeApp("Applications/ChatGPT.app")
        let pathBinary = try fixture.writeExecutable("bin/codex")

        let found = try locate(
            fixture: fixture,
            environment: [
                CodexBinaryLocator.overrideEnvironmentKey: override.path,
                "PATH": pathBinary.deletingLastPathComponent().path
            ],
            registeredApplications: [
                CodexApplicationCandidate(
                    url: registeredApp,
                    bundleIdentifier: CodexApplicationLocator.bundleIdentifier
                )
            ]
        )

        XCTAssertEqual(found, override.resolvingSymlinksInPath().path)
    }

    func testRegisteredRenamedAppOutsideStandardRootsIsDiscovered() throws {
        let fixture = try makeFixture()
        let registeredApp = try fixture.writeApp("Custom Location/My Renamed App.app")

        let found = try locate(
            fixture: fixture,
            registeredApplications: [
                CodexApplicationCandidate(
                    url: registeredApp,
                    bundleIdentifier: CodexApplicationLocator.bundleIdentifier
                )
            ]
        )

        XCTAssertEqual(found, fixture.codexBinary(in: registeredApp).path)
    }

    func testSystemAndUserApplicationsDiscoverRenamedAppsWithoutDependingOnName() throws {
        let fixture = try makeFixture()
        let systemApp = try fixture.writeApp("Applications/OpenAI Desktop Renamed.app")

        let found = try locate(fixture: fixture)

        XCTAssertEqual(found, fixture.codexBinary(in: systemApp).path)
    }

    func testUserApplicationsDiscoversRenamedAppWhenSystemRootHasNone() throws {
        let fixture = try makeFixture()
        let userApp = try fixture.writeApp("UserApplications/Another Name.app")

        let found = try locate(fixture: fixture)

        XCTAssertEqual(found, fixture.codexBinary(in: userApp).path)
    }

    func testLegacyAndCurrentNamesRemainCompatible() throws {
        let fixture = try makeFixture()
        let currentApp = try fixture.writeApp("Applications/ChatGPT.app")
        _ = try fixture.writeApp("UserApplications/Codex.app")

        let found = try locate(fixture: fixture)

        XCTAssertEqual(found, fixture.codexBinary(in: currentApp).path)
    }

    func testScanSkipsEarlierForeignBundleAndSelectsTargetBundle() throws {
        let fixture = try makeFixture()
        _ = try fixture.writeApp(
            "Applications/A-Fake.app",
            bundleIdentifier: "com.example.fake"
        )
        let targetApp = try fixture.writeApp("Applications/Z-Renamed.app")

        let found = try locate(fixture: fixture)

        XCTAssertEqual(found, fixture.codexBinary(in: targetApp).path)
    }

    func testRegisteredForeignBundleDoesNotOverrideTargetApplication() throws {
        let fixture = try makeFixture()
        let foreignApp = try fixture.writeApp(
            "Elsewhere/ChatGPT.app",
            bundleIdentifier: "com.example.other"
        )
        let targetApp = try fixture.writeApp("Applications/Renamed.app")

        let found = try locate(
            fixture: fixture,
            registeredApplications: [
                CodexApplicationCandidate(
                    url: foreignApp,
                    bundleIdentifier: "com.example.other"
                )
            ]
        )

        XCTAssertEqual(found, fixture.codexBinary(in: targetApp).path)
    }

    func testScanIsBoundedToDirectApplicationChildren() throws {
        let fixture = try makeFixture()
        _ = try fixture.writeApp("Applications/Group/Nested.app")
        let pathBinary = try fixture.writeExecutable("bin/codex")

        let found = try locate(
            fixture: fixture,
            environment: ["PATH": pathBinary.deletingLastPathComponent().path]
        )

        XCTAssertEqual(found, pathBinary.path)
    }

    func testSkipsNonExecutableAndBrokenSymlinkButCanonicalizesValidSymlink() throws {
        let fixture = try makeFixture()
        let nonExecutableApp = try fixture.writeApp("Applications/NotExecutable.app", executable: false)
        let nonExecutableBinary = fixture.codexBinary(in: nonExecutableApp)
        let brokenLink = fixture.root.appendingPathComponent("broken-codex")
        try FileManager.default.createSymbolicLink(
            at: brokenLink,
            withDestinationURL: fixture.root.appendingPathComponent("missing-target")
        )
        let target = try fixture.writeExecutable("real/codex")
        let validLink = fixture.root.appendingPathComponent("linked-bin/codex")
        try FileManager.default.createDirectory(
            at: validLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: validLink, withDestinationURL: target)

        let found = try locate(
            fixture: fixture,
            environment: [
                CodexBinaryLocator.overrideEnvironmentKey: brokenLink.path,
                "PATH": validLink.deletingLastPathComponent().path
            ],
            registeredApplications: [
                CodexApplicationCandidate(
                    url: nonExecutableBinary
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent(),
                    bundleIdentifier: CodexApplicationLocator.bundleIdentifier
                )
            ]
        )

        XCTAssertEqual(found, target.resolvingSymlinksInPath().path)
    }

    func testPATHOrderIsDeterministicAndKnownFallbackComesAfterPATH() throws {
        let fixture = try makeFixture()
        let first = try fixture.writeExecutable("first-bin/codex")
        _ = try fixture.writeExecutable("second-bin/codex")
        _ = try fixture.writeExecutable("known-bin/codex")

        let found = try CodexBinaryLocator.findExecutable(
            environment: [
                "PATH": [
                    first.deletingLastPathComponent().path,
                    fixture.root.appendingPathComponent("second-bin").path
                ].joined(separator: ":")
            ],
            registeredApplications: [],
            applicationRoots: [],
            knownApplicationURLs: [],
            knownCLIPaths: [fixture.root.appendingPathComponent("known-bin/codex").path]
        )

        XCTAssertEqual(found, first.path)
    }

    private func locate(
        fixture: Fixture,
        environment: [String: String] = [:],
        registeredApplications: [CodexApplicationCandidate] = []
    ) throws -> String {
        try CodexBinaryLocator.findExecutable(
            environment: environment,
            registeredApplications: registeredApplications,
            applicationRoots: [
                fixture.root.appendingPathComponent("Applications", isDirectory: true),
                fixture.root.appendingPathComponent("UserApplications", isDirectory: true)
            ],
            knownApplicationURLs: [],
            knownCLIPaths: []
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBinaryLocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root)
    }
}

private struct Fixture {
    let root: URL

    func writeApp(
        _ relativePath: String,
        bundleIdentifier: String = CodexApplicationLocator.bundleIdentifier,
        executable: Bool = true
    ) throws -> URL {
        let appURL = root.appendingPathComponent(relativePath, isDirectory: true)
        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: infoPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try plistData.write(to: infoPlist)
        _ = try createExecutable(
            appURL.appendingPathComponent("Contents/Resources/codex").path,
            executable: executable
        )
        return appURL
    }

    func writeExecutable(_ relativePath: String, executable: Bool = true) throws -> URL {
        try createExecutable(root.appendingPathComponent(relativePath).path, executable: executable)
    }

    func codexBinary(in appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Resources/codex")
    }

    private func createExecutable(_ path: String, executable: Bool) throws -> URL {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }
}
