import Foundation
import XCTest
@testable import CodexTokenBar

final class ProviderSyncEngineTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testCodexApplicationMatcherPrefersStableBundleIdentifier() {
        XCTAssertTrue(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: "com.openai.codex",
            localizedName: "Renamed Desktop"
        ))
    }

    func testCodexApplicationMatcherKeepsLegacyAndCurrentNameFallbacks() {
        XCTAssertTrue(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: nil,
            localizedName: "Codex"
        ))
        XCTAssertTrue(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: nil,
            localizedName: "ChatGPT"
        ))
    }

    func testCodexApplicationMatcherRejectsUnrelatedApplications() {
        XCTAssertFalse(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: "com.example.codex-helper",
            localizedName: "Other App"
        ))
        XCTAssertFalse(CodexDesktopApplicationMatcher.matches(
            bundleIdentifier: nil,
            localizedName: nil
        ))
    }

    func testSyncCreatesDisposableBackupAndOnlyMutatesIntendedFiles() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(backupRoot: fixture.backupRoot)

        let snapshot = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )

        let backupPath = try XCTUnwrap(snapshot.lastBackupPath)
        let backup = URL(fileURLWithPath: backupPath)
        XCTAssertTrue(backup.path.hasPrefix(fixture.backupRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("session-jsonl.before.tar").path))
        XCTAssertEqual(try readSQLiteProviders(inDatabase: backup.appendingPathComponent("state_5.sqlite.before")), ["anthropic"])
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "openai")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["openai"])
        XCTAssertEqual(try String(contentsOf: fixture.unrelatedSessionFile, encoding: .utf8), fixture.unrelatedSessionText)
        XCTAssertEqual(try readSessionProvider(at: fixture.archivedSession), "anthropic")
        XCTAssertEqual(
            snapshot.backupRecords.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path },
            [backup.standardizedFileURL.path]
        )
    }

    func testRollbackRestoresSelectedBackupAndRejectsInvalidTargets() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(backupRoot: fixture.backupRoot)

        let synced = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        let backupPath = try XCTUnwrap(synced.lastBackupPath)

        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "openai")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["openai"])

        let rolledBack = try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)

        XCTAssertEqual(rolledBack.lastBackupPath, backupPath)
        XCTAssertEqual(try readSessionProvider(at: fixture.activeSession), "anthropic")
        XCTAssertEqual(try readSQLiteProviders(at: fixture.codexHome), ["anthropic"])
        XCTAssertEqual(try String(contentsOf: fixture.sessionIndex, encoding: .utf8), fixture.originalSessionIndexText)

        let invalidBackup = fixture.backupRoot.appendingPathComponent("invalid-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidBackup, withIntermediateDirectories: true)
        try writeJSON(
            [
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "codex_home": fixture.codexHome.deletingLastPathComponent().path,
                "target_provider": "openai",
                "session_file_count": 1
            ],
            to: invalidBackup.appendingPathComponent("manifest.json")
        )

        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: invalidBackup.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("备份不属于当前 Codex Home"))
        }
        XCTAssertThrowsError(try engine.rollback(codexHome: fixture.codexHome, backupPath: fixture.backupRoot.appendingPathComponent("missing").path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("备份不属于当前 Codex Home"))
        }
    }

    func testVerifyReportsCoherentStatusAfterSyncAndRollback() throws {
        let fixture = try makeFixture()
        let engine = ProviderSyncEngine(backupRoot: fixture.backupRoot)

        let initial = try engine.verify(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai"
        )
        XCTAssertTrue(initial.status.contains("仍有历史或前端工作区状态未同步"))

        let synced = try engine.sync(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "openai",
            dryRunOnly: false
        )
        XCTAssertTrue(synced.status.contains("同步完成并已验证"))

        let backupPath = try XCTUnwrap(synced.lastBackupPath)
        _ = try engine.rollback(codexHome: fixture.codexHome, backupPath: backupPath)

        let restored = try engine.verify(
            codexHome: fixture.codexHome,
            includeArchivedSessions: false,
            targetProviderOverride: "anthropic"
        )
        XCTAssertTrue(restored.status.contains("验证通过"))
    }

    private func makeFixture() throws -> ProviderSyncFixture {
        let root = try makeTemporaryDirectory(named: "ProviderSyncEngine")
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let sessions = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("07", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let activeSession = sessions.appendingPathComponent("thread-a.jsonl")
        try writeSession(id: "thread-a", provider: "anthropic", to: activeSession)

        let unrelatedSessionFile = sessions.appendingPathComponent("keep-me.txt")
        let unrelatedSessionText = "do not touch this session neighbor\n"
        try unrelatedSessionText.write(to: unrelatedSessionFile, atomically: true, encoding: .utf8)

        let archivedSessions = codexHome
            .appendingPathComponent("archived_sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedSessions, withIntermediateDirectories: true)
        let archivedSession = archivedSessions.appendingPathComponent("thread-archived.jsonl")
        try writeSession(id: "thread-archived", provider: "anthropic", to: archivedSession)

        let sessionIndex = codexHome.appendingPathComponent("session_index.jsonl")
        let originalSessionIndexText = #"{"id":"old-thread","thread_name":"Old","updated_at":"2026-07-01T00:00:00.000Z"}"# + "\n"
        try originalSessionIndexText.write(to: sessionIndex, atomically: true, encoding: .utf8)

        try seedStateDatabase(at: codexHome)

        return ProviderSyncFixture(
            codexHome: codexHome,
            backupRoot: backupRoot,
            activeSession: activeSession,
            archivedSession: archivedSession,
            unrelatedSessionFile: unrelatedSessionFile,
            unrelatedSessionText: unrelatedSessionText,
            sessionIndex: sessionIndex,
            originalSessionIndexText: originalSessionIndexText
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func writeSession(id: String, provider: String, to file: URL) throws {
        let lines = [
            encodeLine([
                "timestamp": "2026-07-06T01:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": id,
                    "model_provider": provider
                ]
            ]),
            encodeLine([
                "timestamp": "2026-07-06T01:01:00.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "agent_message",
                    "message": "hello"
                ]
            ])
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func seedStateDatabase(at codexHome: URL) throws {
        let driver = SQLiteDatabaseDriver(url: codexHome.appendingPathComponent("state_5.sqlite"))
        try driver.execute("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            title TEXT,
            first_user_message TEXT,
            preview TEXT,
            source TEXT,
            cwd TEXT,
            archived INTEGER,
            thread_source TEXT,
            model_provider TEXT,
            updated_at INTEGER,
            updated_at_ms INTEGER
        );
        """)
        try driver.execute(
            """
            INSERT INTO threads (
                id, title, first_user_message, preview, source, cwd, archived,
                thread_source, model_provider, updated_at, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text("thread-a"),
                .text("Thread A"),
                .text("first"),
                .text("preview"),
                .text("vscode"),
                .text("/tmp/workspace"),
                .int(0),
                .text("user"),
                .text("anthropic"),
                .int64(1_783_468_800),
                .int64(1_783_468_800_000)
            ]
        )
    }

    private func readSessionProvider(at file: URL) throws -> String? {
        let line = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        let data = try XCTUnwrap(line?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        return payload["model_provider"] as? String
    }

    private func readSQLiteProviders(at codexHome: URL) throws -> [String] {
        try readSQLiteProviders(inDatabase: codexHome.appendingPathComponent("state_5.sqlite"))
    }

    private func readSQLiteProviders(inDatabase database: URL) throws -> [String] {
        let driver = SQLiteDatabaseDriver(url: database, readOnly: true)
        return try driver.readRows("SELECT model_provider FROM threads ORDER BY id ASC;") { statement in
            statement.text(0) ?? ""
        }
    }

    private func encodeLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func writeJSON(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: [.atomic])
    }
}

private struct ProviderSyncFixture {
    let codexHome: URL
    let backupRoot: URL
    let activeSession: URL
    let archivedSession: URL
    let unrelatedSessionFile: URL
    let unrelatedSessionText: String
    let sessionIndex: URL
    let originalSessionIndexText: String
}
