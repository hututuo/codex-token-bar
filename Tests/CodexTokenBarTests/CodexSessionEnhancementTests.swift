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
        let collector = MarkdownChunkCollector()

        let result = try await executor.exportMarkdown(
            threadID: fixture.threadID,
            fallbackTitle: "备用标题",
            emit: { chunk in await collector.append(chunk) }
        )

        let markdown = await collector.joined()
        XCTAssertEqual(result.filename, "真实会话-\(fixture.threadID).md")
        XCTAssertTrue(result.message.contains(result.filename))
        XCTAssertTrue(markdown.hasPrefix("# 真实会话\n"))
        XCTAssertTrue(markdown.contains("### User"))
        XCTAssertTrue(markdown.contains("你好，Codex"))
        XCTAssertTrue(markdown.contains("### Assistant"))
        XCTAssertTrue(markdown.contains("已经完成"))
        XCTAssertTrue(markdown.contains("2026"))
    }

    func testMarkdownExportSpillsLargeJSONLineAndStreamsCompleteBodyWithoutDataCap() async throws {
        let fixture = try makeFixture()
        let handle = try FileHandle(forWritingTo: fixture.rolloutURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            #"{"payload":{"content":[{"image_url":"https:\/\/example.com\/图.png","type":"input_image"},{"text":"\r\n  开始-"#.utf8
        ))
        let repeatedBytes =
            CodexRolloutLineAccumulator.inMemoryByteThreshold + 128 * 1024
        try handle.write(contentsOf: Data(repeating: 0x7E, count: repeatedBytes))
        try handle.write(contentsOf: Data(
            #"-结束  \r\n","type":"output_text"}],"role":"assistant","type":"message"},"timestamp":null,"type":"response_item"}"#.utf8
        ))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.synchronize()

        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        let collector = MarkdownChunkCollector()
        _ = try await executor.exportMarkdown(
            threadID: fixture.threadID,
            fallbackTitle: "备用标题",
            emit: { chunk in await collector.append(chunk) }
        )

        let markdown = await collector.joined()
        let repeatedByteCount = markdown.utf8.reduce(into: 0) { count, byte in
            if byte == 0x7E { count += 1 }
        }
        XCTAssertEqual(repeatedByteCount, repeatedBytes)
        XCTAssertTrue(markdown.contains("### Assistant"))
        XCTAssertTrue(markdown.contains("[Image link](<https://example.com/图.png>)"))
        XCTAssertTrue(markdown.contains("\n\n  开始-"))
        XCTAssertTrue(markdown.hasSuffix("-结束\n"))
        let maximumChunkBytes = await collector.maximumChunkBytes()
        XCTAssertLessThanOrEqual(
            maximumChunkBytes,
            64 * 1024 + 4,
            "映射的大行正文必须保持分块输出，不能重新拼成整行 String"
        )
    }

    func testLargeMarkdownParserPropagatesTaskCancellation() async throws {
        let line = CodexRolloutLineAccumulator()
        try line.append(Data(
            #"{"payload":{"content":[{"text":""#.utf8
        ))
        try line.append(
            Data(
                repeating: 0x78,
                count: CodexRolloutLineAccumulator.inMemoryByteThreshold
            )
        )
        try line.append(Data(
            #"":","type":"output_text"}],"role":"assistant","type":"message"},"type":"response_item"}"#.utf8
        ))
        guard case .mapped(let mapped) = try line.finish() else {
            return XCTFail("fixture 必须进入匿名落盘映射路径")
        }

        let task = Task {
            withUnsafeCurrentTask { current in
                current?.cancel()
            }
            return try CodexLargeRolloutMessage.parse(mapped)
        }
        do {
            _ = try await task.value
            XCTFail("已取消的大行解析必须抛出 CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testLineAccumulatorAcceptsLineBeyondFormer64MiBLimit() throws {
        let line = CodexRolloutLineAccumulator()
        let chunk = Data(repeating: 0x78, count: 1024 * 1024)
        let formerLimit = 64 * 1024 * 1024
        let expectedBytes = formerLimit + chunk.count
        for _ in 0..<(expectedBytes / chunk.count) {
            try line.append(chunk)
        }
        guard case .mapped(let mapped) = try line.finish() else {
            return XCTFail("超过内存切换点的完整行必须进入匿名映射路径")
        }
        XCTAssertEqual(mapped.count, expectedBytes)
    }

    func testMarkdownExportPropagatesCallerCancellationToDetachedWorker() async throws {
        let fixture = try makeFixture()
        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        let gate = MarkdownCancellationGate()
        let task = Task {
            try await executor.exportMarkdown(
                threadID: fixture.threadID,
                fallbackTitle: "备用标题",
                emit: { _ in await gate.enterAndWait() }
            )
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("调用方取消必须传递给 detached 导出任务")
        } catch is CancellationError {
            // expected
        }
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

    func testProjectMoveLockPathMatchesRustContract() {
        XCTAssertEqual(
            FoundationCodexSessionEnhancementExecutor.workspaceMoveLockRelativePath(
                threadID: "thread-1"
            ),
            "backups_state/codex-token-bar/workspace-move/thread-1.lock"
        )
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

    func testProjectMoveRecoversInterruptedRolloutExchangeBeforeRetry() async throws {
        let fixture = try makeFixture()
        let target = fixture.home.appendingPathComponent("Recovered Target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let retainedURL = try simulateInterruptedWorkspaceMove(
            fixture: fixture,
            targetCwd: target.path,
            databaseAlreadyUpdated: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))

        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        _ = try await executor.moveThreadWorkspace(
            threadID: fixture.threadID,
            targetCwd: target.path
        )

        let database = SQLiteDatabaseDriver(
            url: fixture.dataSource.stateDatabase,
            readOnly: true
        )
        let cwd = try database.readRows(
            "SELECT cwd FROM threads WHERE id = ?1",
            bindings: [.text(fixture.threadID)]
        ) { $0.text(0) ?? "" }.first
        XCTAssertEqual(cwd, target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.home
                .appendingPathComponent(
                    "backups_state/codex-token-bar/workspace-move/\(fixture.threadID).json"
                ).path
        ))
    }

    func testProjectMoveCommitsInterruptedExchangeWhenDatabaseAlreadyAdvanced() async throws {
        let fixture = try makeFixture()
        let target = fixture.home.appendingPathComponent("Committed Target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let retainedURL = try simulateInterruptedWorkspaceMove(
            fixture: fixture,
            targetCwd: target.path,
            databaseAlreadyUpdated: true
        )

        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        _ = try await executor.moveThreadWorkspace(
            threadID: fixture.threadID,
            targetCwd: target.path
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedURL.path))
        let rollout = try String(
            contentsOf: fixture.rolloutURL,
            encoding: .utf8
        )
        let firstLine = try XCTUnwrap(
            rollout.split(whereSeparator: \.isNewline).first
        )
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(firstLine.utf8)
            ) as? [String: Any]
        )
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["cwd"] as? String, target.path)
    }

    func testProjectMoveFailsClosedOnRolloutDatabaseCwdDrift() async throws {
        let fixture = try makeFixture()
        let target = fixture.home.appendingPathComponent("Drift Blocked Target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try rewriteRolloutFirstLineCwd(fixture: fixture, cwd: "/tmp/other-project")

        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        do {
            _ = try await executor.moveThreadWorkspace(
                threadID: fixture.threadID,
                targetCwd: target.path
            )
            XCTFail("漂移状态必须拒绝移动")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("已拒绝覆盖"),
                error.localizedDescription
            )
        }
        // 拒绝必须发生在写 journal 之前，否则 journal 残留会锁死后续恢复。
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(
                "backups_state/codex-token-bar/workspace-move/\(fixture.threadID).json"
            ).path
        ))
    }

    func testNoopMoveHealsRolloutCwdDrift() async throws {
        let fixture = try makeFixture()
        let target = fixture.home.appendingPathComponent("Heal Target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        // 模拟历史漂移：数据库已在目标目录，rollout 首行仍指原目录。
        let database = SQLiteDatabaseDriver(url: fixture.dataSource.stateDatabase)
        try database.execute(
            "UPDATE threads SET cwd = ?1 WHERE id = ?2",
            bindings: [.text(target.path), .text(fixture.threadID)]
        )

        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        let healed = try await executor.moveThreadWorkspace(
            threadID: fixture.threadID,
            targetCwd: target.path
        )
        XCTAssertTrue(
            healed.message.contains("已修复 rollout 项目目录漂移"),
            healed.message
        )
        let rollout = try String(contentsOf: fixture.rolloutURL, encoding: .utf8)
        let firstLine = try XCTUnwrap(rollout.split(whereSeparator: \.isNewline).first)
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
        )
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["cwd"] as? String, target.path)

        let secondPass = try await executor.moveThreadWorkspace(
            threadID: fixture.threadID,
            targetCwd: target.path
        )
        XCTAssertEqual(secondPass.message, "会话已在目标项目目录")
    }

    func testRecoveryRejectsV1JournalWithExplicitDiagnostic() async throws {
        let fixture = try makeFixture()
        let target = fixture.home.appendingPathComponent("V1 Target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let journalDirectory = fixture.home.appendingPathComponent(
            "backups_state/codex-token-bar/workspace-move"
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let journalURL = journalDirectory
            .appendingPathComponent("\(fixture.threadID).json")
        let legacy = """
        {"schemaVersion":1,"codexHome":"\(fixture.home.path)",\
        "stateDatabase":"\(fixture.dataSource.stateDatabase.standardizedFileURL.path)",\
        "threadID":"\(fixture.threadID)",\
        "rolloutRelativePath":"sessions/2026/07/20/rollout-\(fixture.threadID).jsonl",\
        "retainedOriginalName":".provider-session-prefix-workspace-\(fixture.threadID)",\
        "originalCwd":"\(fixture.originalCwd)","targetCwd":"\(target.path)"}
        """
        try Data(legacy.utf8).write(to: journalURL)

        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        do {
            _ = try await executor.moveThreadWorkspace(
                threadID: fixture.threadID,
                targetCwd: target.path
            )
            XCTFail("v1 journal 必须显式拒绝")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("schemaVersion=1"),
                error.localizedDescription
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: journalURL.path),
            "拒绝时必须保留 journal 供人工处理"
        )
    }

    func testRecoveryRestoresFirstLineFromSingleLineRetainedAndKeepsTail() async throws {
        // Tauri 端 prepared 状态：retained 只有首行副本，rollout 首行已改目标，
        // 数据库未提交。恢复必须按首行还原并保留 rollout 尾部与追加事件。
        let fixture = try makeFixture()
        let target = fixture.home.appendingPathComponent("Tauri Prepared Target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let original = try String(contentsOf: fixture.rolloutURL, encoding: .utf8)
        let originalFirstLine = try XCTUnwrap(
            original.split(whereSeparator: \.isNewline).first
        )
        let retainedURL = fixture.rolloutURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".provider-session-prefix-workspace-\(fixture.threadID)"
            )
        try Data((originalFirstLine + "\n").utf8).write(to: retainedURL)
        try rewriteRolloutFirstLineCwd(
            fixture: fixture,
            cwd: target.path,
            appendLine: #"{"type":"event_msg","payload":{"appended":true}}"#
        )
        let journalDirectory = fixture.home.appendingPathComponent(
            "backups_state/codex-token-bar/workspace-move"
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let journalURL = journalDirectory
            .appendingPathComponent("\(fixture.threadID).json")
        let journal = CodexWorkspaceMoveJournal(
            schemaVersion: 2,
            codexHome: fixture.home.path,
            stateDatabase: fixture.dataSource.stateDatabase.standardizedFileURL.path,
            threadID: fixture.threadID,
            rolloutRelativePath:
                "sessions/2026/07/20/rollout-\(fixture.threadID).jsonl",
            retainedOriginalRelativePath:
                "sessions/2026/07/20/.provider-session-prefix-workspace-\(fixture.threadID)",
            originalCwd: fixture.originalCwd,
            targetCwd: target.path
        )
        try JSONEncoder().encode(journal).write(to: journalURL)

        let executor = FoundationCodexSessionEnhancementExecutor(
            dataSourceResolver: { fixture.dataSource }
        )
        _ = try await executor.moveThreadWorkspace(
            threadID: fixture.threadID,
            targetCwd: target.path
        )

        let rollout = try String(contentsOf: fixture.rolloutURL, encoding: .utf8)
        let firstLine = try XCTUnwrap(rollout.split(whereSeparator: \.isNewline).first)
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
        )
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["cwd"] as? String, target.path)
        XCTAssertTrue(rollout.contains(#""appended":true"#), "追加事件必须保留")
        XCTAssertTrue(rollout.contains("你好，Codex"), "既有事件必须保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        let database = SQLiteDatabaseDriver(
            url: fixture.dataSource.stateDatabase,
            readOnly: true
        )
        let cwd = try database.readRows(
            "SELECT cwd FROM threads WHERE id = ?1",
            bindings: [.text(fixture.threadID)]
        ) { $0.text(0) ?? "" }.first
        XCTAssertEqual(cwd, target.path)
    }

    private func rewriteRolloutFirstLineCwd(
        fixture: Fixture,
        cwd: String,
        appendLine: String? = nil
    ) throws {
        let contents = try String(contentsOf: fixture.rolloutURL, encoding: .utf8)
        var lines = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        var event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        var payload = try XCTUnwrap(event["payload"] as? [String: Any])
        payload["cwd"] = cwd
        event["payload"] = payload
        lines[0] = try XCTUnwrap(String(
            data: JSONSerialization.data(
                withJSONObject: event,
                options: [.sortedKeys]
            ),
            encoding: .utf8
        ))
        if let appendLine { lines.append(appendLine) }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: fixture.rolloutURL)
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

    private func simulateInterruptedWorkspaceMove(
        fixture: Fixture,
        targetCwd: String,
        databaseAlreadyUpdated: Bool
    ) throws -> URL {
        let homeDirectory = try ProviderSyncHomeDirectory(
            canonicalURL: fixture.home
        )
        defer { try? homeDirectory.close() }
        let rolloutRelativePath = "sessions/2026/07/20/\(fixture.rolloutURL.lastPathComponent)"
        let retainedName =
            ".provider-session-prefix-workspace-\(fixture.threadID)"
        let journalRelativePath =
            "backups_state/codex-token-bar/workspace-move/\(fixture.threadID).json"
        let journalFile = try homeDirectory.pinFile(
            relativePath: journalRelativePath,
            createParents: true
        )
        let journal = CodexWorkspaceMoveJournal(
            schemaVersion: 2,
            codexHome: fixture.home.path,
            stateDatabase: fixture.dataSource.stateDatabase.standardizedFileURL.path,
            threadID: fixture.threadID,
            rolloutRelativePath: rolloutRelativePath,
            retainedOriginalRelativePath: "sessions/2026/07/20/\(retainedName)",
            originalCwd: fixture.originalCwd,
            targetCwd: targetCwd
        )
        _ = try homeDirectory.createRegularFileAtomically(
            journalFile,
            data: JSONEncoder().encode(journal)
        )
        try homeDirectory.syncParentDirectory(of: journalFile)

        let rolloutFile = try homeDirectory.pinFile(
            relativePath: rolloutRelativePath,
            createParents: false
        )
        let firstLine = try homeDirectory.readRegularFileFirstLine(
            rolloutFile,
            requireSingleLink: true
        )
        var event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstLine.data)
                as? [String: Any]
        )
        var payload = try XCTUnwrap(event["payload"] as? [String: Any])
        payload["cwd"] = targetCwd
        event["payload"] = payload
        let replacementLine = try JSONSerialization.data(
            withJSONObject: event,
            options: [.sortedKeys]
        )
        _ = try homeDirectory.replaceRegularFileFirstLine(
            rolloutFile,
            expectedIdentity: firstLine.identity,
            expectedLine: firstLine.data,
            replacementLine: replacementLine,
            preserving: firstLine.metadata,
            retainedOriginalName: retainedName
        )
        try homeDirectory.syncParentDirectory(of: rolloutFile)

        if databaseAlreadyUpdated {
            let database = SQLiteDatabaseDriver(
                url: fixture.dataSource.stateDatabase
            )
            try database.execute(
                "UPDATE threads SET cwd = ?1 WHERE id = ?2",
                bindings: [.text(targetCwd), .text(fixture.threadID)]
            )
        }

        return fixture.rolloutURL.deletingLastPathComponent()
            .appendingPathComponent(retainedName)
    }
}

private actor MarkdownChunkCollector {
    private var chunks: [String] = []
    private var largestChunkBytes = 0

    func append(_ chunk: String) {
        chunks.append(chunk)
        largestChunkBytes = max(largestChunkBytes, chunk.utf8.count)
    }

    func joined() -> String {
        chunks.joined()
    }

    func maximumChunkBytes() -> Int {
        largestChunkBytes
    }
}

private actor MarkdownCancellationGate {
    private var didEnter = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        guard !isReleased else { return }
        if !didEnter {
            didEnter = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
