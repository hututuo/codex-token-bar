import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexDataSourceSQLiteHomeTests: XCTestCase {
    func testDataSourceUsesConfiguredSQLiteHome() throws {
        let fixture = try makeFixture("configured")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codexHome = fixture.appendingPathComponent("home", isDirectory: true)
        let sqliteHome = fixture.appendingPathComponent(
            "sqlite",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sqliteHome,
            withIntermediateDirectories: true
        )
        try "sqlite_home = \"\(sqliteHome.path)\"\n".write(
            to: codexHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let source = CodexDataSource(
            codexHome: codexHome,
            origin: .userSelected
        )

        XCTAssertEqual(
            source.stateDatabase,
            sqliteHome
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .appendingPathComponent("state_5.sqlite")
        )
    }

    func testConfigSQLiteHomeOverridesEnvironment() throws {
        let fixture = try makeFixture("precedence")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codexHome = fixture.appendingPathComponent("home", isDirectory: true)
        let configured = fixture.appendingPathComponent(
            "configured",
            isDirectory: true
        )
        let environment = fixture.appendingPathComponent(
            "environment",
            isDirectory: true
        )
        for directory in [codexHome, configured, environment] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try "sqlite_home = \"\(configured.path)\"\n".write(
            to: codexHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = try CodexSQLiteHomeResolver.resolvedSQLiteHome(
            codexHome: codexHome,
            environment: ["CODEX_SQLITE_HOME": environment.path]
        )

        XCTAssertEqual(
            resolved,
            configured.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testRelativeEnvironmentSQLiteHomeResolvesAgainstEffectiveCwd()
        throws {
        let fixture = try makeFixture("relative-environment")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codexHome = fixture.appendingPathComponent("home", isDirectory: true)
        let cwd = fixture.appendingPathComponent("cwd", isDirectory: true)
        let sqliteHome = cwd.appendingPathComponent(
            "relative/sqlite",
            isDirectory: true
        )
        for directory in [codexHome, sqliteHome] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let resolved = try CodexSQLiteHomeResolver.resolvedSQLiteHome(
            codexHome: codexHome,
            environment: ["CODEX_SQLITE_HOME": "relative/sqlite"],
            currentDirectory: cwd
        )

        XCTAssertEqual(
            resolved,
            sqliteHome.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testInvalidConfiguredSQLiteHomeNeverFallsBackToDecoyDatabase()
        throws {
        let fixture = try makeFixture("invalid-config")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codexHome = fixture.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        try "sqlite_home = \"relative/sqlite\"\n".write(
            to: codexHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let source = CodexDataSource(
            codexHome: codexHome,
            origin: .userSelected
        )

        XCTAssertNotEqual(
            source.stateDatabase,
            codexHome.appendingPathComponent("state_5.sqlite")
        )
        XCTAssertTrue(
            source.stateDatabase.path.contains(
                ".codex-token-bar-invalid-sqlite-home"
            )
        )
    }

    private func makeFixture(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-token-bar-sqlite-home-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
