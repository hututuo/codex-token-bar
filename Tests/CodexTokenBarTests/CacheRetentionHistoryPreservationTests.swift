import Foundation
import XCTest
@testable import CodexTokenBar

final class CacheRetentionHistoryPreservationTests: XCTestCase {
    func testDamagedV2HistoryStructureIsNotSilentlyRecreated() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("RetentionDamage-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("retention.sqlite")
        _ = try CacheRetentionDatabase(url:url)
        let driver=SQLiteDatabaseDriver(url:url)
        try driver.execute("DROP TABLE retention_pair_history")
        XCTAssertThrowsError(try CacheRetentionDatabase(url:url))
        XCTAssertEqual(try driver.readRows("SELECT COUNT(*) FROM sqlite_master WHERE name='retention_pair_history'") { $0.int(0) }.first,0)
    }

    func testVersionOneMigrationPreservesPairsCheckpointAndOwnRounds() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let records = engineRecords(nextFirstCached: 90)
        let parser = try parse(records)
        let sourceKey = CacheRetentionIdentity.hash("/synthetic/legacy-retention.jsonl")
        let checkpoint = CacheRetentionCheckpoint(
            generation: "legacy-generation",
            offset: UInt64(try jsonl(records).count),
            prefixDigest: "legacy-prefix-digest",
            parser: parser
        )
        let pair = try XCTUnwrap(parser.pairs(source: sourceKey, generation: checkpoint.generation)
            .first { $0.eligible })
        let point = try XCTUnwrap(pair.point)
        let url = fixture.root.appendingPathComponent("private/retention.sqlite")
        try createVersionOneSidecar(url, sourceKey: sourceKey, checkpoint: checkpoint, pair: pair)

        let migrated = try CacheRetentionDatabase(url: url)
        XCTAssertEqual(try scalar("PRAGMA user_version;", in: url), 2)
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 1, "Legacy rows are present after migration.")
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_own_turns WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 2, "Migration backfills stable own session/turn identities.")
        XCTAssertEqual(try scalar(
            "SELECT fallback_own_rounds FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 0)

        let snapshot = try migrated.snapshot(scope: .init(), now: Date(timeIntervalSince1970: 1_700_001_000))
        XCTAssertEqual(snapshot.points, [point])
        XCTAssertEqual(snapshot.sourceCount, 1)
        XCTAssertEqual(snapshot.ownRoundCount, 2)
        let migratedCheckpoint = try XCTUnwrap(migrated.checkpoint(sourceKey))
        XCTAssertEqual(migratedCheckpoint.generation, checkpoint.generation)
        XCTAssertEqual(migratedCheckpoint.offset, checkpoint.offset)
        XCTAssertEqual(migratedCheckpoint.prefixDigest, checkpoint.prefixDigest)
    }

    func testDeletedSourceSurvivesRestartAndRestorationAppendResumesCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.sessions.appendingPathComponent("rollout-retained-history.jsonl")
        let originalRecords = engineRecords(nextFirstCached: 90)
        let originalData = try jsonl(originalRecords)
        try originalData.write(to: file)

        let url = fixture.root.appendingPathComponent("private/retention.sqlite")
        var engine: CacheRetentionEngine? = try CacheRetentionEngine(source: fixture.source, databaseURL: url)
        let initialFailures = try await XCTUnwrap(engine).synchronize(progress: { _, _ in })
        XCTAssertEqual(initialFailures, 0)
        let sourceKey = sourceKey(for: file)
        let database = try CacheRetentionDatabase(url: url)
        let before = try await XCTUnwrap(engine).snapshot(scope: .init())
        let checkpointBefore = try XCTUnwrap(database.checkpoint(sourceKey))
        let checkpointBytesBefore = try blob(
            "SELECT checkpoint FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        )
        XCTAssertEqual(before.points.count, 1)
        XCTAssertEqual(before.ownRoundCount, 2)
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 1)

        try FileManager.default.removeItem(at: file)
        let removalFailures = try await XCTUnwrap(engine).synchronize(progress: { _, _ in })
        XCTAssertEqual(removalFailures, 0)
        let removed = try await XCTUnwrap(engine).snapshot(scope: .init())
        XCTAssertEqual(removed.points, before.points)
        XCTAssertEqual(removed.ownRoundCount, before.ownRoundCount)
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_pairs WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 1)
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_own_turns WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 2, "Missing sources keep their stable own-turn projection.")
        XCTAssertEqual(try blob(
            "SELECT checkpoint FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), checkpointBytesBefore)
        XCTAssertEqual(try XCTUnwrap(database.checkpoint(sourceKey)).generation, checkpointBefore.generation)

        // A new engine instance represents an app restart. Its snapshot still
        // includes the complete retained history before the source returns.
        engine = nil
        let restarted = try CacheRetentionEngine(source: fixture.source, databaseURL: url)
        let afterRestart = try await restarted.snapshot(scope: .init())
        XCTAssertEqual(afterRestart.points, before.points)
        XCTAssertEqual(afterRestart.ownRoundCount, before.ownRoundCount)

        try originalData.write(to: file)
        let restorationFailures = try await restarted.synchronize(progress: { _, _ in })
        XCTAssertEqual(restorationFailures, 0)
        let restoredCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertEqual(restoredCheckpoint.generation, checkpointBefore.generation)
        XCTAssertEqual(restoredCheckpoint.offset, checkpointBefore.offset)
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 1, "Publishing a restored source makes it present again.")
        let restored = try await restarted.snapshot(scope: .init())
        XCTAssertEqual(restored.points, before.points)

        let thirdRound = roundRecords(
            .init(id: turnC, start: 1_700_000_440, first: .init(input: 100, cached: 85), last: .init(input: 100, cached: 98)),
            startingOrdinal: 13
        )
        let appended = try jsonl(thirdRound)
        try append(appended, to: file)

        let appendFailures = try await restarted.synchronize(progress: { _, _ in })
        XCTAssertEqual(appendFailures, 0)
        let afterAppend = try await restarted.snapshot(scope: .init())
        let appendedCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertEqual(afterAppend.points.count, 2)
        XCTAssertEqual(afterAppend.ownRoundCount, 3)
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_own_turns WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 3)
        XCTAssertEqual(appendedCheckpoint.generation, checkpointBefore.generation)
        XCTAssertGreaterThan(appendedCheckpoint.offset, checkpointBefore.offset)
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 1)
    }

    func testArchivedPathMoveDoesNotDoubleCountRetainedStableTurns() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalFile = fixture.sessions.appendingPathComponent("rollout-moved.jsonl")
        try jsonl(engineRecords(nextFirstCached: 90)).write(to: originalFile)
        let url = fixture.root.appendingPathComponent("private/moved-retention.sqlite")
        let engine = try CacheRetentionEngine(source: fixture.source, databaseURL: url)

        let initialFailures = try await engine.synchronize(progress: { _, _ in })
        XCTAssertEqual(initialFailures, 0)
        let originalKey = sourceKey(for: originalFile)
        let initial = try await engine.snapshot(scope: .init())
        XCTAssertEqual(initial.ownRoundCount, 2)

        let archivedRoot = fixture.home.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        let archivedFile = archivedRoot.appendingPathComponent(originalFile.lastPathComponent)
        try FileManager.default.moveItem(at: originalFile, to: archivedFile)
        let moveFailures = try await engine.synchronize(progress: { _, _ in })
        let moved = try await engine.snapshot(scope: .init())

        XCTAssertEqual(moveFailures, 0)
        XCTAssertEqual(moved.points.count, initial.points.count)
        for (old, new) in zip(initial.points, moved.points) {
            // The deterministic representative may switch to the archived
            // path; every chart value and stable session identity must agree.
            XCTAssertEqual(new.sessionKey, old.sessionKey)
            XCTAssertEqual(new.model, old.model)
            XCTAssertEqual(new.gapMicroseconds, old.gapMicroseconds)
            XCTAssertEqual(new.startedAtMicroseconds, old.startedAtMicroseconds)
            XCTAssertEqual(new.previousInput, old.previousInput)
            XCTAssertEqual(new.previousCached, old.previousCached)
            XCTAssertEqual(new.input, old.input)
            XCTAssertEqual(new.cached, old.cached)
        }
        XCTAssertEqual(moved.ownRoundCount, 2, "The absent old path and present archive path share stable session/turn evidence")
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(originalKey)], in: url
        ), 0)
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey(for: archivedFile))], in: url
        ), 1)
    }

    func testDifferentForkUUIDsKeepOwnRoundsDistinct() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rounds = [
            RoundSpec(id: parentTurn, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            RoundSpec(id: ownTurnA, start: 1_700_000_220, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99)),
            RoundSpec(id: ownTurnB, start: 1_700_000_440, first: .init(input: 100, cached: 85), last: .init(input: 100, cached: 98)),
        ]
        let firstFile = fixture.sessions.appendingPathComponent("rollout-fork-one.jsonl")
        let secondFile = fixture.sessions.appendingPathComponent("rollout-fork-two.jsonl")
        try jsonl(makeRecords(rounds, metadata: forkMetadata(child: childID))).write(to: firstFile)
        try jsonl(makeRecords(rounds, metadata: forkMetadata(child: otherChildID))).write(to: secondFile)

        let engine = try CacheRetentionEngine(
            source: fixture.source,
            databaseURL: fixture.root.appendingPathComponent("private/fork-identity-retention.sqlite")
        )
        let syncFailures = try await engine.synchronize(progress: { _, _ in })
        XCTAssertEqual(syncFailures, 0)
        let snapshot = try await engine.snapshot(scope: .init())
        XCTAssertEqual(snapshot.ownRoundCount, 4, "Equal turn UUIDs in different fork session UUIDs remain distinct")
    }

    func testForkOwnRoundsAndPairsSurviveDeletionRestartAndAppend() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.sessions.appendingPathComponent("rollout-fork-retained.jsonl")
        let records = makeRecords([
            .init(id: parentTurn, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: ownTurnA, start: 1_700_000_220, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99)),
            .init(id: ownTurnB, start: 1_700_000_440, first: .init(input: 100, cached: 85), last: .init(input: 100, cached: 98)),
        ], metadata: forkMetadata())
        let originalData = try jsonl(records)
        try originalData.write(to: file)

        let url = fixture.root.appendingPathComponent("private/fork-retention.sqlite")
        var engine: CacheRetentionEngine? = try CacheRetentionEngine(source: fixture.source, databaseURL: url)
        let initialFailures = try await XCTUnwrap(engine).synchronize(progress: { _, _ in })
        XCTAssertEqual(initialFailures, 0)
        let sourceKey = sourceKey(for: file)
        let database = try CacheRetentionDatabase(url: url)
        let initial = try await XCTUnwrap(engine).snapshot(scope: .init())
        let checkpointBefore = try XCTUnwrap(database.checkpoint(sourceKey))
        let checkpointBytesBefore = try blob(
            "SELECT checkpoint FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        )
        XCTAssertEqual(initial.points.count, 1)
        XCTAssertEqual(initial.ownRoundCount, 2, "Only the two turns owned by the fork count.")

        try FileManager.default.removeItem(at: file)
        let removalFailures = try await XCTUnwrap(engine).synchronize(progress: { _, _ in })
        XCTAssertEqual(removalFailures, 0)
        let removed = try await XCTUnwrap(engine).snapshot(scope: .init())
        XCTAssertEqual(removed.points, initial.points)
        XCTAssertEqual(removed.ownRoundCount, 2)
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_pairs WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 2)
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_own_turns WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 2, "A deleted fork retains only its own stable turn identities.")
        XCTAssertEqual(try blob(
            "SELECT checkpoint FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), checkpointBytesBefore)
        engine = nil

        let restarted = try CacheRetentionEngine(source: fixture.source, databaseURL: url)
        let afterRestart = try await restarted.snapshot(scope: .init())
        XCTAssertEqual(afterRestart.points, initial.points)
        XCTAssertEqual(afterRestart.ownRoundCount, 2)

        try originalData.write(to: file)
        let restorationFailures = try await restarted.synchronize(progress: { _, _ in })
        XCTAssertEqual(restorationFailures, 0)
        XCTAssertEqual(try XCTUnwrap(database.checkpoint(sourceKey)).generation, checkpointBefore.generation)
        let thirdRound = roundRecords(
            .init(id: turnC, start: 1_700_000_660, first: .init(input: 100, cached: 80), last: .init(input: 100, cached: 98)),
            startingOrdinal: 19
        )
        try append(try jsonl(thirdRound), to: file)
        let appendFailures = try await restarted.synchronize(progress: { _, _ in })
        XCTAssertEqual(appendFailures, 0)

        let appended = try await restarted.snapshot(scope: .init())
        let appendedCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertEqual(appended.points.count, 2)
        XCTAssertEqual(appended.ownRoundCount, 3)
        XCTAssertEqual(appendedCheckpoint.generation, checkpointBefore.generation)
        XCTAssertGreaterThan(appendedCheckpoint.offset, checkpointBefore.offset)
        XCTAssertEqual(try scalar(
            "SELECT present FROM retention_sources WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 1)
    }

    func testForkSamePathRewriteArchivesOwnTurnsAndDeduplicatesAcrossGenerations() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.sessions.appendingPathComponent("rollout-fork-generation-history.jsonl")
        let originalRecords = makeRecords([
            .init(id: parentTurn, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: ownTurnA, start: 1_700_000_220, first: .init(input: 100, cached: 90), last: .init(input: 100, cached: 99)),
            .init(id: ownTurnB, start: 1_700_000_440, first: .init(input: 100, cached: 85), last: .init(input: 100, cached: 98)),
        ], metadata: forkMetadata())
        try jsonl(originalRecords).write(to: file)

        let url = fixture.root.appendingPathComponent("private/fork-generation-retention.sqlite")
        var engine: CacheRetentionEngine? = try CacheRetentionEngine(source: fixture.source, databaseURL: url)
        let initialFailures = try await XCTUnwrap(engine).synchronize(progress: { _, _ in })
        XCTAssertEqual(initialFailures, 0)
        let sourceKey = sourceKey(for: file)
        let database = try CacheRetentionDatabase(url: url)
        let initialCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        let initial = try await XCTUnwrap(engine).snapshot(scope: .init())
        XCTAssertEqual(initial.points.count, 1)
        XCTAssertEqual(initial.ownRoundCount, 2)

        // The rewrite drops ownTurnA and keeps ownTurnB while adding turnC.
        // Stable identity union should retain A, deduplicate B across the two
        // generations, and count C once.
        let rewrittenRecords = makeRecords([
            .init(id: parentTurn, start: 1_700_000_000, first: .init(input: 100, cached: 95), last: .init(input: 100, cached: 95)),
            .init(id: ownTurnB, start: 1_700_000_440, first: .init(input: 100, cached: 85), last: .init(input: 100, cached: 98)),
            .init(id: turnC, start: 1_700_000_660, first: .init(input: 100, cached: 80), last: .init(input: 100, cached: 98)),
        ], metadata: forkMetadata())
        try jsonl(rewrittenRecords).write(to: file)
        let rewriteFailures = try await XCTUnwrap(engine).synchronize(progress: { _, _ in })
        XCTAssertEqual(rewriteFailures, 0)
        let rewrittenCheckpoint = try XCTUnwrap(database.checkpoint(sourceKey))
        XCTAssertNotEqual(rewrittenCheckpoint.generation, initialCheckpoint.generation)
        let rewritten = try await XCTUnwrap(engine).snapshot(scope: .init())
        XCTAssertEqual(rewritten.points.count, 2, "The old A-to-B fact and current B-to-C fact both remain available")
        XCTAssertEqual(rewritten.ownRoundCount, 3, "A and C survive while overlapping B is counted once across generations")
        XCTAssertEqual(try scalar(
            "SELECT own_rounds FROM retention_generation_history WHERE source_key=? AND generation=?;",
            bindings: [.text(sourceKey),.text(initialCheckpoint.generation)], in: url
        ), 2)
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_own_turn_history WHERE source_key=? AND generation=?;",
            bindings: [.text(sourceKey),.text(initialCheckpoint.generation)], in: url
        ), 2)
        XCTAssertEqual(try scalar(
            "SELECT COUNT(*) FROM retention_own_turns WHERE source_key=?;",
            bindings: [.text(sourceKey)], in: url
        ), 2, "The current generation owns B and C")
        let archivedCheckpoint = try JSONDecoder().decode(CacheRetentionCheckpoint.self, from: blob(
            "SELECT checkpoint FROM retention_generation_history WHERE source_key=? AND generation=?;",
            bindings: [.text(sourceKey),.text(initialCheckpoint.generation)], in: url
        ))
        XCTAssertEqual(archivedCheckpoint.generation, initialCheckpoint.generation)

        engine = nil
        let restarted = try CacheRetentionEngine(source: fixture.source, databaseURL: url)
        let afterRestart = try await restarted.snapshot(scope: .init())
        XCTAssertEqual(afterRestart.points, rewritten.points)
        XCTAssertEqual(afterRestart.ownRoundCount, 3)
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
    private let otherChildID = "019ff8b9-09e7-75c1-b9a5-14fe7b60066b"
    private let parentID = "019ff8b8-0000-7000-8000-000000000000"
    private let parentTurn = "019ff8b8-0001-7000-8000-000000000001"
    private let ownTurnA = "019ff8b9-0ace-7c02-9f89-4358b15cceda"
    private let ownTurnB = "019ff8b9-0acf-7c02-9f89-4358b15cceda"

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-retention-preservation-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sqliteHome = root.appendingPathComponent("sqlite-home", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteHome, withIntermediateDirectories: true)
        try "sqlite_home = \"\(sqliteHome.path)\"\n".write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        return Fixture(
            root: root,
            home: home,
            sessions: sessions,
            source: CodexDataSource(codexHome: home, origin: .userSelected)
        )
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

    private func engineRecords(nextFirstCached: Int, session: String? = nil) -> [[String: Any]] {
        makeRecords([
            .init(id: turnA, start: 1_700_000_000, first: .init(input: 100, cached: 80), last: .init(input: 100, cached: 95)),
            .init(id: turnB, start: 1_700_000_220, first: .init(input: 100, cached: nextFirstCached), last: .init(input: 100, cached: 99)),
        ], metadata: session.map { ["id": $0] as [String: Any] })
    }

    private func roundRecords(_ round: RoundSpec, startingOrdinal: Int) -> [[String: Any]] {
        let start = round.start
        let end = start + 100
        func envelope(_ type: String, _ payload: [String: Any], _ timestamp: Int, _ ordinal: Int) -> [String: Any] {
            ["type": type, "payload": payload, "timestamp": timestamp, "ordinal": ordinal]
        }
        func usage(_ value: UsageSpec) -> [String: Int] {
            ["input_tokens": value.input, "cached_input_tokens": value.cached]
        }
        return [
            envelope("event_msg", ["type": "task_started", "turn_id": round.id, "started_at": start], start, startingOrdinal),
            envelope("response_item", ["type": "message", "role": "user"], start + 1, startingOrdinal + 1),
            envelope("turn_context", ["turn_id": round.id, "model": "gpt-5.6"], start + 2, startingOrdinal + 2),
            envelope("event_msg", ["type": "token_count", "info": [
                "last_token_usage": usage(round.first),
                "total_token_usage": ["total_tokens": 1_000 + startingOrdinal + 3],
            ]], start + 3, startingOrdinal + 3),
            envelope("event_msg", ["type": "token_count", "info": [
                "last_token_usage": usage(round.last),
                "total_token_usage": ["total_tokens": 1_000 + startingOrdinal + 4],
            ]], start + 4, startingOrdinal + 4),
            envelope("event_msg", ["type": "task_complete", "turn_id": round.id, "completed_at": end], end, startingOrdinal + 5),
        ]
    }

    private func forkMetadata(child: String? = nil) -> [String: Any] {
        ["id": child ?? childID, "forked_from_id": parentID, "history_mode": "paginated",
         "subagent_history_start_ordinal": 100]
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

    private func sourceKey(for file: URL) -> String {
        CacheRetentionIdentity.hash(CodexRolloutReader.logicalURL(file).standardizedFileURL.path)
    }

    private func scalar(_ sql: String, bindings: [SQLiteBinding] = [], in url: URL) throws -> Int {
        let driver = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        return try XCTUnwrap(driver.readRows(sql, bindings: bindings) { $0.int(0) }.first ?? nil)
    }

    private func blob(_ sql: String, bindings: [SQLiteBinding] = [], in url: URL) throws -> Data {
        let driver = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        return try XCTUnwrap(driver.readRows(sql, bindings: bindings) { $0.data(0) }.first ?? nil)
    }

    private func createVersionOneSidecar(
        _ url: URL,
        sourceKey: String,
        checkpoint: CacheRetentionCheckpoint,
        pair: CacheRetentionPair
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = SQLiteDatabaseDriver(url: url)
        try database.execute("CREATE TABLE retention_meta(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);")
        try database.execute("INSERT INTO retention_meta(id,revision) VALUES(1,7);")
        try database.execute("""
            CREATE TABLE retention_sources(
              source_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, session_key TEXT NOT NULL,
              is_child INTEGER NOT NULL, explicit_child INTEGER NOT NULL, own_rounds INTEGER NOT NULL,
              generation TEXT NOT NULL, checkpoint BLOB NOT NULL);
            """)
        try database.execute("""
            CREATE TABLE retention_pairs(
              pair_key TEXT PRIMARY KEY, source_key TEXT NOT NULL REFERENCES retention_sources(source_key) ON DELETE CASCADE,
              stable_key TEXT, evidence_signature TEXT NOT NULL, eligible INTEGER NOT NULL,
              model TEXT, started_us INTEGER, point BLOB, reasons BLOB NOT NULL);
            """)
        try database.execute("CREATE INDEX retention_pair_identity ON retention_pairs(stable_key,evidence_signature,eligible,pair_key);")
        try database.execute("CREATE INDEX retention_pair_time ON retention_pairs(started_us,pair_key) WHERE eligible=1;")
        try database.execute("CREATE INDEX retention_pair_model ON retention_pairs(model,started_us,pair_key) WHERE eligible=1;")
        try database.execute("""
            INSERT INTO retention_sources(source_key,fingerprint,session_key,is_child,explicit_child,own_rounds,generation,checkpoint)
            VALUES(?,?,?,?,?,?,?,?);
            """, bindings: [
                .text(sourceKey), .text("legacy-fingerprint"), .text(checkpoint.parser.sessionKey),
                .int(checkpoint.parser.excludedSubagent ? 1 : 0), .int(checkpoint.parser.explicitSubagent ? 1 : 0),
                .int(checkpoint.parser.excludedSubagent ? 0 : checkpoint.parser.turns.filter(checkpoint.parser.isOwn).count),
                .text(checkpoint.generation), .blob(try JSONEncoder().encode(checkpoint)),
            ])
        let point = pair.point
        try database.execute("""
            INSERT INTO retention_pairs(pair_key,source_key,stable_key,evidence_signature,eligible,model,started_us,point,reasons)
            VALUES(?,?,?,?,?,?,?,?,?);
            """, bindings: [
                .text(pair.id), .text(sourceKey), .optionalText(pair.stableKey), .text(pair.evidenceSignature),
                .int(pair.eligible ? 1 : 0), .optionalText(point?.model),
                point.map { .int64($0.startedAtMicroseconds) } ?? .null,
                try point.map { .blob(try JSONEncoder().encode($0)) } ?? .null,
                .blob(try JSONEncoder().encode(pair.reasons.sorted())),
            ])
        try database.execute("PRAGMA user_version=1;")
    }
}
