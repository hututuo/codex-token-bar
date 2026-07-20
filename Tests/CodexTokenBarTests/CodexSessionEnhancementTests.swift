import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexSessionEnhancementTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSettingsRoundTripAndClampConversationWidth() throws {
        let suite = "CodexSessionEnhancementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = CodexSessionEnhancementSettings.default
        settings.pasteFix = true
        settings.conversationViewMaxWidth = 9_999

        settings.save(defaults: defaults)
        let loaded = CodexSessionEnhancementSettings.load(defaults: defaults)

        XCTAssertTrue(loaded.pasteFix)
        XCTAssertEqual(loaded.conversationViewMaxWidth, 4_000)
        XCTAssertEqual(loaded.enabledFeatureCount, 5)
    }

    func testBindingRequestSupportsEverySessionEnhancementAction() throws {
        let export = try JSONDecoder().decode(
            CodexThreadDeleteBindingRequest.self,
            from: Data(#"{"id":"1","owner":"swift","action":"exportMarkdown","threadId":"019f5a7c-1234-7abc-8def-0123456789ab","title":"测试"}"#.utf8)
        )
        let move = try JSONDecoder().decode(
            CodexThreadDeleteBindingRequest.self,
            from: Data(#"{"id":"2","owner":"swift","action":"moveThreadWorkspace","threadId":"019f5a7c-1234-7abc-8def-0123456789ab","title":"测试","targetCwd":"/tmp/project"}"#.utf8)
        )

        XCTAssertEqual(export.action, .exportMarkdown)
        XCTAssertEqual(move.action, .moveThreadWorkspace)
        XCTAssertEqual(move.targetCwd, "/tmp/project")
    }

    func testMarkdownExportReadsTimestampedUserAndAssistantMessages() async throws {
        let fixture = try makeFixture()
        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )

        let result = try await executor.exportMarkdown(
            threadID: fixture.threadID,
            fallbackTitle: "备用标题"
        )

        XCTAssertEqual(result.filename, "真实会话-\(fixture.threadID).md")
        XCTAssertTrue(result.markdown.hasPrefix("# 真实会话\n"))
        XCTAssertTrue(result.markdown.contains("### User"))
        XCTAssertTrue(result.markdown.contains("你好，Codex"))
        XCTAssertTrue(result.markdown.contains("### Assistant"))
        XCTAssertTrue(result.markdown.contains("已经完成"))
        XCTAssertTrue(result.markdown.contains("2026"))
    }

    func testProjectMoveUpdatesDatabaseAndRolloutSessionMetaTogether() async throws {
        let fixture = try makeFixture()
        let target = fixture.home.appendingPathComponent("Target Project")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )

        let result = try await executor.moveThreadWorkspace(
            threadID: fixture.threadID,
            targetCwd: target.path
        )

        XCTAssertEqual(result.previousCwd, fixture.originalCwd)
        XCTAssertEqual(result.targetCwd, target.path)
        let database = SQLiteDatabaseDriver(url: fixture.dataSource.stateDatabase, readOnly: true)
        let cwd = try database.readRows(
            "SELECT cwd FROM threads WHERE id = ?1",
            bindings: [.text(fixture.threadID)]
        ) { $0.text(0) ?? "" }.first
        XCTAssertEqual(cwd, target.path)
        let rollout = try String(contentsOf: fixture.rolloutURL, encoding: .utf8)
        let firstLine = try XCTUnwrap(rollout.split(whereSeparator: \.isNewline).first)
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
        )
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["cwd"] as? String, target.path)
    }

    func testProjectMoveRejectsMissingDirectoryWithoutChangingSource() async throws {
        let fixture = try makeFixture()
        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )

        do {
            _ = try await executor.moveThreadWorkspace(
                threadID: fixture.threadID,
                targetCwd: fixture.home.appendingPathComponent("Missing").path
            )
            XCTFail("Expected missing directory to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("目标项目目录不可用"))
        }

        let database = SQLiteDatabaseDriver(url: fixture.dataSource.stateDatabase, readOnly: true)
        let cwd = try database.readRows(
            "SELECT cwd FROM threads WHERE id = ?1",
            bindings: [.text(fixture.threadID)]
        ) { $0.text(0) ?? "" }.first
        XCTAssertEqual(cwd, fixture.originalCwd)
    }

    private struct Fixture: Sendable {
        let home: URL
        let dataSource: CodexDataSource
        let threadID: String
        let originalCwd: String
        let rolloutURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionEnhancementTests-\(UUID().uuidString)")
        temporaryDirectories.append(home)
        let sessions = home.appendingPathComponent("sessions/2026/07/20")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let threadID = "019f5a7c-1234-7abc-8def-0123456789ab"
        let originalCwd = home.appendingPathComponent("Original Project").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: originalCwd),
            withIntermediateDirectories: true
        )
        let rolloutURL = sessions.appendingPathComponent("rollout-\(threadID).jsonl")
        let events = [
            #"{"timestamp":"2026-07-20T12:00:00.000Z","type":"session_meta","payload":{"id":"\#(threadID)","cwd":"\#(originalCwd)"}}"#,
            #"{"timestamp":"2026-07-20T12:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"你好，Codex"}]}}"#,
            #"{"timestamp":"2026-07-20T12:02:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"已经完成"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(events.utf8).write(to: rolloutURL)

        let dataSource = CodexDataSource(codexHome: home, origin: .userSelected)
        let database = SQLiteDatabaseDriver(url: dataSource.stateDatabase)
        try database.execute(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, cwd TEXT, rollout_path TEXT)"
        )
        try database.execute(
            "INSERT INTO threads (id, title, cwd, rollout_path) VALUES (?1, ?2, ?3, ?4)",
            bindings: [
                .text(threadID),
                .text("真实会话"),
                .text(originalCwd),
                .text(rolloutURL.path),
            ]
        )
        return Fixture(
            home: home,
            dataSource: dataSource,
            threadID: threadID,
            originalCwd: originalCwd,
            rolloutURL: rolloutURL
        )
    }
}
