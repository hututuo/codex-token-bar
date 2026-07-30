import Foundation
import XCTest
@testable import CodexTokenBar

final class SessionCatalogIndexTests: XCTestCase {
    func testHotRefreshSkipsEveryUnchangedFirstLineAndParsesOnlyChangedFile() throws {
        let fixture = try makeFixture()
        let first = try fixture.writeRollout(
            name: "first.jsonl",
            threadID: "thread-first"
        )
        let second = try fixture.writeRollout(
            name: "second.jsonl",
            threadID: "thread-second"
        )
        let probe = SessionCatalogParserProbe()
        let candidates = [
            candidate(first),
            candidate(second),
        ]

        let cold = try fixture.index.synchronizeSessionCatalog(
            candidates: candidates,
            parser: probe.parse
        )
        XCTAssertEqual(cold.changedFiles, 2)
        XCTAssertEqual(cold.unchangedFiles, 0)
        XCTAssertEqual(cold.parsedFirstLines, 2)
        XCTAssertEqual(Set(probe.takeParsedPaths()), Set([first.path, second.path]))

        let hot = try fixture.index.synchronizeSessionCatalog(
            candidates: candidates,
            parser: probe.parse
        )
        XCTAssertEqual(hot.changedFiles, 0)
        XCTAssertEqual(hot.unchangedFiles, 2)
        XCTAssertEqual(hot.parsedFirstLines, 0)
        XCTAssertTrue(probe.takeParsedPaths().isEmpty)

        let originalFingerprint = try XCTUnwrap(
            hot.entries.first { $0.path == first.path }
        )
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("new-body-only\n".utf8))
        try handle.close()

        let changed = try fixture.index.synchronizeSessionCatalog(
            candidates: candidates,
            parser: probe.parse
        )
        XCTAssertEqual(changed.changedFiles, 1)
        XCTAssertEqual(changed.unchangedFiles, 1)
        XCTAssertEqual(changed.parsedFirstLines, 1)
        XCTAssertEqual(probe.takeParsedPaths(), [first.path])
        let changedEntry = try XCTUnwrap(
            changed.entries.first { $0.path == first.path }
        )
        XCTAssertEqual(
            changedEntry.firstLineEndOffset,
            originalFingerprint.firstLineEndOffset
        )
        XCTAssertEqual(
            changedEntry.firstLineSHA256,
            originalFingerprint.firstLineSHA256
        )
        XCTAssertGreaterThan(changedEntry.sizeBytes, originalFingerprint.sizeBytes)
    }

    func testDeleteAndArchiveMovePublishOnlyCurrentPaths() throws {
        let fixture = try makeFixture()
        let moving = try fixture.writeRollout(
            name: "moving.jsonl",
            threadID: "thread-moving"
        )
        let deleting = try fixture.writeRollout(
            name: "deleting.jsonl",
            threadID: "thread-deleting"
        )
        let probe = SessionCatalogParserProbe()
        _ = try fixture.index.synchronizeSessionCatalog(
            candidates: [candidate(moving), candidate(deleting)],
            parser: probe.parse
        )
        _ = probe.takeParsedPaths()

        try FileManager.default.removeItem(at: deleting)
        let archiveRoot = fixture.root.appendingPathComponent(
            "archived_sessions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: archiveRoot,
            withIntermediateDirectories: true
        )
        let archived = archiveRoot.appendingPathComponent(moving.lastPathComponent)
        try FileManager.default.moveItem(at: moving, to: archived)

        let result = try fixture.index.synchronizeSessionCatalog(
            candidates: [candidate(archived, archived: true)],
            parser: probe.parse
        )
        XCTAssertEqual(result.changedFiles, 1)
        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertEqual(result.parsedFirstLines, 1)
        XCTAssertEqual(probe.takeParsedPaths(), [archived.path])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.path, archived.path)
        XCTAssertEqual(result.entries.first?.metadata.threadID, "thread-moving")
        XCTAssertEqual(result.entries.first?.archived, true)
    }

    func testReplacementAndTruncationReparseFirstLineAndReplaceMetadata() throws {
        let fixture = try makeFixture()
        let rollout = try fixture.writeRollout(
            name: "replace.jsonl",
            threadID: "thread-original",
            body: String(repeating: "body\n", count: 20)
        )
        let probe = SessionCatalogParserProbe()
        _ = try fixture.index.synchronizeSessionCatalog(
            candidates: [candidate(rollout)],
            parser: probe.parse
        )
        _ = probe.takeParsedPaths()

        try fixture.rolloutData(
            threadID: "thread-replaced",
            body: "short\n"
        ).write(to: rollout, options: .atomic)
        let replaced = try fixture.index.synchronizeSessionCatalog(
            candidates: [candidate(rollout)],
            parser: probe.parse
        )
        XCTAssertEqual(replaced.parsedFirstLines, 1)
        XCTAssertEqual(probe.takeParsedPaths(), [rollout.path])
        XCTAssertEqual(replaced.entries.first?.metadata.threadID, "thread-replaced")

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.truncate(atOffset: 0)
        try handle.write(
            contentsOf: fixture.rolloutData(
                threadID: "thread-truncated",
                body: ""
            )
        )
        try handle.close()
        let truncated = try fixture.index.synchronizeSessionCatalog(
            candidates: [candidate(rollout)],
            parser: probe.parse
        )
        XCTAssertEqual(truncated.parsedFirstLines, 1)
        XCTAssertEqual(probe.takeParsedPaths(), [rollout.path])
        XCTAssertEqual(
            truncated.entries.first?.metadata.threadID,
            "thread-truncated"
        )
    }

    func testInterruptedPublishKeepsOldSnapshotAndNextRefreshRetries() throws {
        let fixture = try makeFixture()
        let rollout = try fixture.writeRollout(
            name: "atomic.jsonl",
            threadID: "thread-before"
        )
        let probe = SessionCatalogParserProbe()
        let candidates = [candidate(rollout)]
        let initial = try fixture.index.synchronizeSessionCatalog(
            candidates: candidates,
            parser: probe.parse
        )
        let initialGeneration = try XCTUnwrap(
            initial.entries.first?.lastSeenGeneration
        )
        _ = probe.takeParsedPaths()

        try fixture.rolloutData(
            threadID: "thread-after",
            body: "changed\n"
        ).write(to: rollout, options: .atomic)
        CodexUsageHistoryIndex.failNextSessionCatalogPublishForTesting()
        XCTAssertThrowsError(
            try fixture.index.synchronizeSessionCatalog(
                candidates: candidates,
                parser: probe.parse
            )
        )
        XCTAssertEqual(probe.takeParsedPaths(), [rollout.path])
        let preserved = try fixture.index.sessionCatalogEntries()
        XCTAssertEqual(preserved.first?.metadata.threadID, "thread-before")
        XCTAssertEqual(preserved.first?.lastSeenGeneration, initialGeneration)

        let retried = try fixture.index.synchronizeSessionCatalog(
            candidates: candidates,
            parser: probe.parse
        )
        XCTAssertEqual(retried.parsedFirstLines, 1)
        XCTAssertEqual(probe.takeParsedPaths(), [rollout.path])
        XCTAssertEqual(retried.entries.first?.metadata.threadID, "thread-after")
        XCTAssertNotEqual(
            retried.entries.first?.lastSeenGeneration,
            initialGeneration
        )
    }

    private func candidate(
        _ file: URL,
        archived: Bool = false
    ) -> CodexUsageHistoryIndex.SessionCatalogCandidate {
        CodexUsageHistoryIndex.SessionCatalogCandidate(
            file: file,
            archived: archived
        )
    }

    private func makeFixture() throws -> SessionCatalogIndexFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-token-bar-session-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let databaseURL = root.appendingPathComponent("usage-index.sqlite")
        return SessionCatalogIndexFixture(
            root: root,
            index: try CodexUsageHistoryIndex(
                sessionCatalogTestingDatabaseURL: databaseURL
            )
        )
    }
}

private struct SessionCatalogIndexFixture {
    let root: URL
    let index: CodexUsageHistoryIndex

    func writeRollout(
        name: String,
        threadID: String,
        body: String = "body\n"
    ) throws -> URL {
        let sessions = root.appendingPathComponent(
            "sessions/2026/07/31",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessions,
            withIntermediateDirectories: true
        )
        let file = sessions.appendingPathComponent(name)
        try rolloutData(threadID: threadID, body: body).write(
            to: file,
            options: .atomic
        )
        return file
    }

    func rolloutData(threadID: String, body: String) -> Data {
        Data(
            "\(threadID)|/project/\(threadID)|session-\(threadID)|-|-|cli\n\(body)"
                .utf8
        )
    }
}

private final class SessionCatalogParserProbe {
    private var parsedPaths: [String] = []

    func parse(
        _ file: URL
    ) throws -> CodexUsageHistoryIndex.SessionCatalogMetadata {
        parsedPaths.append(file.path)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var line = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[..<newline])
                break
            }
            line.append(chunk)
        }
        let fields = String(decoding: line, as: UTF8.self).split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard fields.count == 6 else {
            throw SessionCatalogParserProbeError.invalidFirstLine
        }
        func optional(_ field: Substring) -> String? {
            field == "-" ? nil : String(field)
        }
        return CodexUsageHistoryIndex.SessionCatalogMetadata(
            threadID: String(fields[0]),
            cwd: String(fields[1]),
            sessionID: optional(fields[2]),
            forkedFromID: optional(fields[3]),
            parentThreadID: optional(fields[4]),
            source: String(fields[5])
        )
    }

    func takeParsedPaths() -> [String] {
        defer { parsedPaths.removeAll(keepingCapacity: true) }
        return parsedPaths
    }
}

private enum SessionCatalogParserProbeError: Error {
    case invalidFirstLine
}
