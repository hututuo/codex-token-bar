import Foundation
import XCTest
@testable import CodexTokenBar

final class CacheRetentionPipelineTests: XCTestCase {
    func testParserUsesPreviousLastAndNextFirstUsage() throws {
        let records = makeRecords([
            .init(id: turnA, start: 1_700_000_000, first: .init(input: 100, cached: 80), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_220, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99))
        ])

        let pairs = try parse(records).pairs(source: "source", generation: "generation")

        XCTAssertEqual(pairs.count, 1)
        let pair = try XCTUnwrap(pairs.first)
        let point = try XCTUnwrap(pair.point)
        XCTAssertTrue(pair.eligible)
        XCTAssertEqual(point.previousCached, 95)
        XCTAssertEqual(point.cached, 90)
    }

    func testInvalidFirstUsageCannotBeReplacedByLaterValidUsage() throws {
        let records = makeRecords([
            .init(id: turnA, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_220, first: .init(input: 0, cached: 0), last: .init(input: 100, cached: 99))
        ])

        let pair = try XCTUnwrap(parse(records).pairs(source: "source", generation: "generation").first)

        XCTAssertFalse(pair.eligible)
        XCTAssertNil(pair.point)
        XCTAssertTrue(pair.reasons.contains("first_usage_invalid"))
    }

    func testZeroCachedTokensRemainEligibleAsLowReuseEvidence() throws {
        let records = makeRecords([
            .init(id: turnA, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_220, first: .init(input: 100, cached: 0), last: .init(input: 100, cached: 20))
        ])

        let pair = try XCTUnwrap(parse(records).pairs(source: "source", generation: "generation").first)
        let point = try XCTUnwrap(pair.point)

        XCTAssertTrue(pair.eligible)
        XCTAssertEqual(point.cached, 0)
        XCTAssertFalse(point.highReuse)
    }

    func testBadMiddleTurnPoisonsAdjacentPairsWithoutBridging() throws {
        let records = makeRecords([
            .init(id: turnA, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_220, first: .init(input: 0, cached: 0), last: .init(input: 100, cached: 99)),
            .init(id: turnC, start: 1_700_000_440, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99))
        ])

        let pairs = try parse(records).pairs(source: "source", generation: "generation")

        XCTAssertEqual(pairs.count, 2)
        XCTAssertFalse(pairs[0].eligible)
        XCTAssertFalse(pairs[1].eligible)
        XCTAssertEqual(pairs.map(\.previousID), [CacheRetentionIdentity.hash(turnA), CacheRetentionIdentity.hash(turnB)])
        XCTAssertEqual(pairs.map(\.nextID), [CacheRetentionIdentity.hash(turnB), CacheRetentionIdentity.hash(turnC)])
        XCTAssertFalse(pairs.contains { $0.previousID == CacheRetentionIdentity.hash(turnA) && $0.nextID == CacheRetentionIdentity.hash(turnC) })
    }

    func testPaginatedForkExcludesInheritedPrefixAndPairsTwoOwnedUUIDTurns() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let records = makeRecords([
            .init(id: parentTurn, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: ownTurnA, start: 1_700_000_220, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99)),
            .init(id: ownTurnB, start: 1_700_000_440, first: .init(input: 100, cached: 85), last: .init(input: 100, cached: 98))
        ], metadata: forkMetadata(childID: childID, parentID: parentID, boundary: 100))
        let file = fixture.sessions.appendingPathComponent("rollout-\(childID).jsonl")
        try jsonl(records).write(to: file)

        let metadata = try XCTUnwrap(PaginatedHistoryBoundary.metadata(file: file))
        var parser = CacheRetentionParser(metadata: metadata)
        for record in records {
            parser.consume(try json(record), knownSubagents: [])
        }
        let pairs = parser.pairs(source: "fork", generation: "fork-generation")

        XCTAssertFalse(metadata.isMainFork)
        XCTAssertNotNil(metadata.childCreatedMilliseconds)
        XCTAssertEqual(parser.turns.filter(parser.isOwn).map(\.id), [ownTurnA, ownTurnB].map(CacheRetentionIdentity.hash))
        XCTAssertEqual(pairs.count, 2)
        XCTAssertFalse(pairs[0].eligible, "The inherited parent-to-child boundary is never sampled")
        XCTAssertTrue(pairs[1].eligible, "The two turns proven to be owned by this fork still form a valid pair")
        XCTAssertEqual(pairs[1].previousID, CacheRetentionIdentity.hash(ownTurnA))
        XCTAssertEqual(pairs[1].nextID, CacheRetentionIdentity.hash(ownTurnB))
    }

    func testStableUUIDCopiesDeduplicateConflictsInvalidateAndRemovalResolves() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("private/cache-retention.sqlite")
        let firstFile = fixture.sessions.appendingPathComponent("rollout-copy-a.jsonl")
        let secondFile = fixture.sessions.appendingPathComponent("rollout-copy-b.jsonl")
        let original = engineRecords(nextFirstCached: 90)
        try jsonl(original).write(to: firstFile)
        let engine = try CacheRetentionEngine(source: fixture.source, databaseURL: databaseURL)

        let firstFailures = try await engine.synchronize(progress: { _, _ in })
        let first = try await engine.snapshot(scope: .init())
        XCTAssertEqual(firstFailures, 0)
        XCTAssertEqual(first.points.count, 1)

        try jsonl(original).write(to: secondFile)
        let duplicateFailures = try await engine.synchronize(progress: { _, _ in })
        let duplicate = try await engine.snapshot(scope: .init())
        XCTAssertEqual(duplicateFailures, 0)
        XCTAssertEqual(duplicate.points.count, 1, "Identical stable turn UUID evidence has one representative")
        XCTAssertEqual(duplicate.sourceCount, 1)

        try jsonl(engineRecords(nextFirstCached: 80)).write(to: secondFile)
        let conflictFailures = try await engine.synchronize(progress: { _, _ in })
        let conflict = try await engine.snapshot(scope: .init())
        XCTAssertEqual(conflictFailures, 0)
        XCTAssertTrue(conflict.points.isEmpty, "Conflicting evidence for a stable pair invalidates every copy")

        try FileManager.default.removeItem(at: secondFile)
        let removalFailures = try await engine.synchronize(progress: { _, _ in })
        let resolved = try await engine.snapshot(scope: .init())
        XCTAssertEqual(removalFailures, 0)
        XCTAssertEqual(resolved.points.count, 1, "Removing the conflicting source restores the remaining evidence")
        XCTAssertEqual(resolved.points.first?.cached, 90)
    }

    func testEngineAppendPartialTailTruncateAndSameSizeRewritePreserveCorrectCounts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("private/cache-retention.sqlite")
        let file = fixture.sessions.appendingPathComponent("rollout-engine.jsonl")
        let originalRecords = engineRecords(nextFirstCached: 90)
        let originalData = try jsonl(originalRecords)
        try originalData.write(to: file)
        let engine = try CacheRetentionEngine(source: fixture.source, databaseURL: databaseURL)
        let sync1 = try await engine.synchronize(progress: { _, _ in })
        let initial = try await engine.snapshot(scope: .init())
        XCTAssertEqual(sync1, 0)
        XCTAssertEqual(initial.points.count, 1)
        XCTAssertEqual(initial.ownRoundCount, 2)

        let sourceKey = CacheRetentionIdentity.hash(CodexRolloutReader.logicalURL(file).standardizedFileURL.path)
        let database = try CacheRetentionDatabase(url: databaseURL)
        let initialCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        let thirdRound = RoundSpec(id: turnC, start: 1_700_000_440,
            first: .init(input: 100, cached: 85), last: .init(input: 100, cached: 98))
        let thirdRecords = roundRecords(thirdRound, startingOrdinal: 100)
        let taskLine = try json(thirdRecords[0])
        let split = max(1, taskLine.count / 2)
        try append(Data(taskLine.prefix(split)), to: file)

        let partialFailures = try await engine.synchronize(progress: { _, _ in })
        let partial = try await engine.snapshot(scope: .init())
        let partialCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertEqual(partialFailures, 0)
        XCTAssertEqual(partial.points.count, 1)
        XCTAssertEqual(partial.ownRoundCount, 2)
        XCTAssertEqual(partialCheckpoint.offset, initialCheckpoint.offset, "An unterminated JSON line is not committed")
        XCTAssertEqual(partialCheckpoint.generation, initialCheckpoint.generation)

        var completion = Data(taskLine.suffix(taskLine.count - split))
        completion.append(10)
        for record in thirdRecords.dropFirst() {
            completion.append(try json(record))
            completion.append(10)
        }
        try append(completion, to: file)

        let appendFailures = try await engine.synchronize(progress: { _, _ in })
        let appended = try await engine.snapshot(scope: .init())
        let appendCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertEqual(appendFailures, 0)
        XCTAssertEqual(appended.points.count, 2)
        XCTAssertEqual(appended.ownRoundCount, 3)
        XCTAssertEqual(appendCheckpoint.generation, initialCheckpoint.generation, "A valid append resumes the existing parser generation")

        try originalData.write(to: file)
        try setModificationDate(1_700_000_001, for: file)
        let truncateFailures = try await engine.synchronize(progress: { _, _ in })
        let truncated = try await engine.snapshot(scope: .init())
        let truncatedCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertEqual(truncateFailures, 0)
        XCTAssertEqual(truncated.points.count, 1)
        XCTAssertEqual(truncated.ownRoundCount, 2)
        XCTAssertNotEqual(truncatedCheckpoint.generation, appendCheckpoint.generation)

        let rewrittenData = try jsonl(engineRecords(nextFirstCached: 80))
        XCTAssertEqual(rewrittenData.count, originalData.count, "The replacement exercises same-size invalidation")
        try rewrittenData.write(to: file)
        try setModificationDate(1_700_000_002, for: file)
        let rewriteFailures = try await engine.synchronize(progress: { _, _ in })
        let rewritten = try await engine.snapshot(scope: .init())
        let rewrittenCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertEqual(rewriteFailures, 0)
        XCTAssertEqual(rewritten.points.count, 1)
        XCTAssertEqual(rewritten.ownRoundCount, 2)
        XCTAssertEqual(rewritten.points.first?.cached, 80)
        XCTAssertNotEqual(rewrittenCheckpoint.generation, truncatedCheckpoint.generation)
    }

    func testEngineHandlesCompleteAndPartialLinesAcrossReadChunks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.sessions.appendingPathComponent("rollout-chunks.jsonl")
        var records = engineRecords(nextFirstCached: 90)
        records.insert(["type": "response_item", "payload": ["type": "message", "role": "assistant", "text": String(repeating: "边界", count: 50_000)]], at: 1)
        var data = try jsonl(records)
        let trailing = try json(["type": "response_item", "payload": ["type": "message", "role": "assistant", "text": String(repeating: "尾", count: 60_000)]])
        data.append(trailing.prefix(100_000))
        try data.write(to: file)
        let engine = try CacheRetentionEngine(source: fixture.source, databaseURL: fixture.root.appendingPathComponent("chunks.sqlite"))
        let firstFailures = try await engine.synchronize(progress: { _, _ in })
        let first = try await engine.snapshot(scope: .init())
        XCTAssertEqual(firstFailures, 0)
        XCTAssertEqual(first.points.count, 1)
        var remainder = Data(trailing.dropFirst(100_000)); remainder.append(10)
        try append(remainder, to: file)
        let secondFailures = try await engine.synchronize(progress: { _, _ in })
        let second = try await engine.snapshot(scope: .init())
        XCTAssertEqual(secondFailures, 0)
        XCTAssertEqual(second.points, first.points)
    }

    func testRepeatedTurnIdentitiesRemainDistinctRawPairsAndCannotAbortPublication() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let records = makeRecords([
            .init(id: turnA, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_220, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99)),
            .init(id: turnA, start: 1_700_000_440, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_660, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99))
        ])
        let pairs = try parse(records).pairs(source: "repeat", generation: "generation")
        XCTAssertEqual(Set(pairs.map(\.id)).count, 3)
        XCTAssertTrue(pairs.allSatisfy { !$0.eligible })
        try jsonl(records).write(to: fixture.sessions.appendingPathComponent("rollout-repeat.jsonl"))
        let engine = try CacheRetentionEngine(source: fixture.source, databaseURL: fixture.root.appendingPathComponent("repeated.sqlite"))
        let failures = try await engine.synchronize(progress: { _, _ in })
        let snapshot = try await engine.snapshot(scope: .init())
        XCTAssertEqual(failures, 0)
        XCTAssertTrue(snapshot.points.isEmpty)
    }

    func testFutureSidecarVersionIsRejectedWithoutFileMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("private/cache-retention.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = SQLiteDatabaseDriver(url: databaseURL)
        try existing.execute("CREATE TABLE sentinel(value TEXT NOT NULL);")
        try existing.execute("INSERT INTO sentinel(value) VALUES('preserve');")
        try existing.execute("PRAGMA user_version=99;")
        let bytesBefore = try Data(contentsOf: databaseURL)
        let observationBefore = try SourceFileObservation.read(at: databaseURL)

        do {
            _ = try CacheRetentionEngine(source: fixture.source, databaseURL: databaseURL)
            XCTFail("A future sidecar schema must be rejected")
        } catch CacheRetentionError.unsupportedVersion {
            // Expected: the sidecar writer is never opened.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let bytesAfter = try Data(contentsOf: databaseURL)
        let observationAfter = try SourceFileObservation.read(at: databaseURL)
        XCTAssertEqual(bytesAfter, bytesBefore)
        XCTAssertTrue(observationBefore.matches(observationAfter))
    }

    private struct UsageSpec {
        var input: Int
        var cached: Int
    }

    private struct RoundSpec {
        var id: String
        var start: Int
        var first: UsageSpec
        var last: UsageSpec
    }

    private struct Fixture {
        var root: URL
        var home: URL
        var sessions: URL
        var source: CodexDataSource
    }

    private let sessionID = "019ff8b9-1111-7000-8000-000000000099"
    private let turnA = "019ff8b9-1111-7000-8000-000000000001"
    private let turnB = "019ff8b9-1111-7000-8000-000000000002"
    private let turnC = "019ff8b9-1111-7000-8000-000000000003"
    private let childID = "019ff8b9-09e7-75c1-b9a5-14fe7b60065a"
    private let parentID = "019ff8b8-0000-7000-8000-000000000000"
    private let parentTurn = "019ff8b8-0001-7000-8000-000000000001"
    private let ownTurnA = "019ff8b9-0ace-7c02-9f89-4358b15cceda"
    private let ownTurnB = "019ff8b9-0acf-7c02-9f89-4358b15cceda"

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-retention-pipeline-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sqliteHome = root.appendingPathComponent("sqlite-home", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteHome, withIntermediateDirectories: true)
        try "sqlite_home = \"\(sqliteHome.path)\"\n".write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return Fixture(root: root, home: home, sessions: sessions,
            source: CodexDataSource(codexHome: home, origin: .userSelected))
    }

    private func makeRecords(_ rounds: [RoundSpec], metadata: [String: Any]? = nil) -> [[String: Any]] {
        var records: [[String: Any]] = [["type": "session_meta", "payload": metadata ?? ["id": sessionID]]]
        var ordinal = 1
        for round in rounds {
            let values = roundRecords(round, startingOrdinal: ordinal)
            records.append(contentsOf: values)
            ordinal += values.count
        }
        return records
    }

    private func engineRecords(nextFirstCached: Int) -> [[String: Any]] {
        makeRecords([
            .init(id: turnA, start: 1_700_000_000, first: .init(input: 100, cached: 80), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_220, first: .init(input: 100, cached: nextFirstCached), last: .init(input: 100, cached: 99))
        ])
    }

    private func roundRecords(_ round: RoundSpec, startingOrdinal: Int) -> [[String: Any]] {
        let start = round.start
        let end = start + 100
        func envelope(_ type: String, _ payload: [String: Any], _ timestamp: Int, _ ordinal: Int) -> [String: Any] {
            ["type": type, "payload": payload, "timestamp": timestamp, "ordinal": ordinal]
        }
        func usage(_ value: UsageSpec) -> [String: Any] {
            ["input_tokens": value.input, "cached_input_tokens": value.cached]
        }
        let startRecord = envelope("event_msg", ["type": "task_started", "turn_id": round.id, "started_at": start], start, startingOrdinal)
        let userRecord = envelope("response_item", ["type": "message", "role": "user"], start + 1, startingOrdinal + 1)
        let contextRecord = envelope("turn_context", ["turn_id": round.id, "model": "gpt-5.6"], start + 2, startingOrdinal + 2)
        let firstRecord = envelope("event_msg", ["type": "token_count", "info": [
            "last_token_usage": usage(round.first),
            "total_token_usage": ["total_tokens": 1_000 + startingOrdinal + 3]
        ]], start + 3, startingOrdinal + 3)
        let lastRecord = envelope("event_msg", ["type": "token_count", "info": [
            "last_token_usage": usage(round.last),
            "total_token_usage": ["total_tokens": 1_000 + startingOrdinal + 4]
        ]], start + 4, startingOrdinal + 4)
        let completeRecord = envelope("event_msg", ["type": "task_complete", "turn_id": round.id, "completed_at": end], end, startingOrdinal + 5)
        return [startRecord, userRecord, contextRecord, firstRecord, lastRecord, completeRecord]
    }

    private func forkMetadata(childID: String, parentID: String, boundary: Int) -> [String: Any] {
        ["id": childID, "forked_from_id": parentID, "history_mode": "paginated",
         "subagent_history_start_ordinal": boundary]
    }

    private func parse(_ records: [[String: Any]]) throws -> CacheRetentionParser {
        var parser = CacheRetentionParser(metadata: nil)
        for record in records {
            parser.consume(try json(record), knownSubagents: [])
        }
        return parser
    }

    private func json(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    private func jsonl(_ records: [[String: Any]]) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try json(record))
            data.append(10)
        }
        return data
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func setModificationDate(_ seconds: TimeInterval, for file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
    }
}
