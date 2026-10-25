import Foundation
import os
import Testing
@testable import AgentSpeedCore

@Suite("OpenCode")
struct OpencodeTests {
    static let fixtureRoot = Fixtures.root.appendingPathComponent("opencode", isDirectory: true)

    /// Every upsert of a full read of the fixture database, per agent in emission order.
    static func seedFixture() throws -> (source: OpencodeSource, responses: [String: [ResponseRecord]], states: [String: AgentState]) {
        let source = OpencodeSource(root: fixtureRoot.path, fileID: -1)
        #expect(source.refreshAvailability())
        #expect(source.status == .ready)
        var deduper = Deduper()
        let update = source.seed(todayStartMs: 0, deduper: &deduper)
        var responses: [String: [ResponseRecord]] = [:]
        for (upsert, _) in update.upserts {
            #expect(upsert.isCompletion)
            responses[upsert.record.agentId, default: []].append(upsert.record)
        }
        return (source, responses, update.agents)
    }

    @Test func fixtureAgentsMatchExpectations() throws {
        let expected = try #require(try Fixtures.json("parser-expected.json")["opencode"] as? [String: Any])
        #expect(expected.string("database") == "opencode/opencode.db")
        let agents = try #require(expected["agents"] as? [String: [String: Any]])
        let (source, responses, states) = try Self.seedFixture()
        let links = source.parentLinks
        #expect(Set(source.agentStates.keys) == Set(agents.keys))
        for (id, spec) in agents {
            let state = try #require(states[id], "missing \(id)")
            #expect(state.source.rawValue == spec.string("source"), "\(id) source")
            #expect(state.project == spec.string("project"), "\(id) project")
            #expect(state.model == spec.string("model"), "\(id) model")
            #expect(state.isSubagent == (spec["isSubagent"] as? Bool), "\(id) isSubagent")
            #expect(links[id] == spec.string("parentId"), "\(id) parentId")
            #expect(state.phase.rawValue == spec.string("phase"), "\(id) phase")
            #expect(state.inFlightStartMs == spec.int64("inFlightStartMs"), "\(id) inFlightStartMs")
            #expect(state.lastLineMs == spec.int64("lastLineMs"), "\(id) lastLineMs")

            let wanted = try #require(spec["responses"] as? [[String: Any]])
            let actual = responses[id] ?? []
            #expect(actual.count == wanted.count, "\(id) response count")
            for (record, want) in zip(actual, wanted) {
                #expect(record.key == want.string("key"), "\(id) key")
                #expect(record.source == .opencode)
                #expect(record.agentId == id)
                #expect(record.startMs == want.int64("startMs"), "\(record.key) startMs")
                #expect(record.endMs == want.int64("endMs"), "\(record.key) endMs")
                #expect(record.usage.input == want.int("input"), "\(record.key) input")
                #expect(record.usage.cachedInput == want.int("cachedInput"), "\(record.key) cachedInput")
                #expect(record.usage.cacheWriteInput == want.int("cacheWriteInput"), "\(record.key) cacheWriteInput")
                #expect(record.usage.output == want.int("output"), "\(record.key) output")
                #expect(record.usage.reasoning == want.int("reasoning"), "\(record.key) reasoning")
                #expect(record.model == want.string("model"), "\(record.key) model")
                #expect(record.isFinal == (want["final"] as? Bool), "\(record.key) final")
                expectPricingFields(record, want, record.key)
            }
        }
    }

    @Test func sessionListsSubagentUnderItsParent() throws {
        let configuration = MonitorConfiguration(
            enabledSources: [.opencode],
            codexRoot: URL(fileURLWithPath: "/nonexistent/codex"),
            opencodeRoot: Self.fixtureRoot
        )
        let session = TranscriptSession(configuration: configuration)
        #expect(session.hasAvailableRoot)
        let summary = session.seed(todayStartMs: 0)
        #expect(summary.filesDiscovered == 1)
        #expect(Set(session.responses.map(\.key)) == ["msg_oc1", "msg_oc2", "cmp_1", "msg_oc3"])
        let (output, events) = session.advance(nowMs: 1_792_490_750_000, todayStartMs: 1_792_454_400_000, emitsEvents: true)
        #expect(!events.contains { if case .responseCompleted = $0 { true } else { false } }, "seeded rows are not live")
        let agents = SnapshotBuilder.running(output, context: SnapshotContext(session: session, todayStartMs: 0)).agents
        #expect(agents.map(\.id) == ["opencode:ses_sub", "opencode:ses_main"] || agents.map(\.id) == ["opencode:ses_main", "opencode:ses_sub"])
        let child = try #require(agents.first { $0.id == "opencode:ses_sub" })
        #expect(child.parentId == "opencode:ses_main")
        #expect(agents.first?.id == "opencode:ses_main")
        let context = SnapshotContext(session: session, todayStartMs: 0)
        #expect(context.sources[.opencode]?.available == true)
        #expect(context.sources[.opencode]?.sessionCount == 2)
        #expect(context.sources[.opencode]?.rootPath == Self.fixtureRoot.path)
    }

    @Test func unsupportedDatabaseIsReported() throws {
        let directory = try TempDirectory()
        let writer = try SQLiteConnection(path: directory.file("opencode.db").path, mode: .readWriteCreate)
        try writer.execute("CREATE TABLE session (id text PRIMARY KEY)")
        let session = TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.opencode], opencodeRoot: directory.url))
        #expect(!session.hasAvailableRoot)
        #expect(session.opencodeLocation.available)
        let context = SnapshotContext(session: session, todayStartMs: 0)
        #expect(context.warnings == [.unsupportedFormat(.opencode)])
        _ = session.seed(todayStartMs: 0)
        #expect(session.responses.isEmpty)
    }

    // MARK: - Incremental reading

    /// A WAL database with OpenCode's tables, written like OpenCode does while the source reads it.
    final class LiveDatabase {
        let directory: TempDirectory
        private(set) var writer: SQLiteConnection

        init() throws {
            directory = try TempDirectory()
            writer = try SQLiteConnection(path: directory.file("opencode.db").path, mode: .readWriteCreate)
            try writer.execute("PRAGMA journal_mode = WAL")
            try writer.execute("""
                CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL,
                  directory text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL);
                CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
                  seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
                CREATE INDEX session_message_time_created_idx ON session_message (time_created);
                CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
                """)
        }

        /// Closes like OpenCode does when it quits: the last connection checkpoints and removes `-wal` and `-shm`
        /// (the system SQLite keeps them, so they are removed here).
        func closeWriter() throws {
            try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            writer.close()
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(at: directory.file("opencode.db" + suffix))
            }
        }

        func reopenWriter() throws {
            writer = try SQLiteConnection(path: directory.file("opencode.db").path, mode: .readWriteCreate)
        }

        func addSession(_ id: String, at ms: Int64, parent: String? = nil) throws {
            let statement = try writer.prepare(
                "INSERT INTO session_v2 VALUES (?1, 'p', ?2, ?1, '/work/atlas', '2.0', ?3, ?3)")
            statement.bind(1, id)
            if let parent { statement.bind(2, parent) }
            statement.bind(3, ms)
            try statement.run()
        }

        func touchSession(_ id: String, at ms: Int64) throws {
            let statement = try writer.prepare("UPDATE session_v2 SET time_updated = ?2 WHERE id = ?1")
            statement.bind(1, id)
            statement.bind(2, ms)
            try statement.run()
        }

        func upsertRow(_ id: String, session: String, seq: Int64, type: String, created: Int64, updated: Int64, data: String) throws {
            let statement = try writer.prepare("""
                INSERT INTO session_message VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(id) DO UPDATE SET time_updated = excluded.time_updated, data = excluded.data
                """)
            statement.bind(1, id)
            statement.bind(2, session)
            statement.bind(3, type)
            statement.bind(4, seq)
            statement.bind(5, created)
            statement.bind(6, updated)
            statement.bind(7, data)
            try statement.run()
            try touchSession(session, at: updated)
        }

        static func assistant(created: Int64, streamed: Int64? = nil, output: Int = 100, finish: String = "stop") -> String {
            let streamedPart = streamed.map { #","streamed":\#($0),"completed":\#($0 + 5)"# } ?? ""
            return #"{"time":{"created":\#(created)\#(streamedPart)},"model":{"id":"m"},"finish":"\#(finish)","tokens":{"input":10,"output":\#(output),"reasoning":0,"cache":{"read":0,"write":0}},"content":[{"type":"text","text":"secret"}]}"#
        }
    }

    @Test func inFlightRowBecomesExactlyOneResponse() throws {
        let db = try LiveDatabase()
        let base: Int64 = 1_792_490_000_000
        try db.addSession("ses_a", at: base)
        try db.upsertRow("u1", session: "ses_a", seq: 1, type: "user", created: base + 10, updated: base + 10, data: #"{"time":{"created":1}}"#)
        try db.upsertRow("a1", session: "ses_a", seq: 2, type: "assistant", created: base + 20, updated: base + 20,
                         data: LiveDatabase.assistant(created: base + 20))

        let source = OpencodeSource(root: db.directory.path, fileID: -1)
        #expect(source.refreshAvailability())
        var deduper = Deduper()
        let seeded = source.seed(todayStartMs: base, deduper: &deduper)
        #expect(seeded.upserts.isEmpty)
        #expect(seeded.agents["opencode:ses_a"]?.phase == .generating)
        #expect(seeded.agents["opencode:ses_a"]?.inFlightStartMs == base + 20)

        // Streaming updates without `streamed` yet, then the stream ends.
        try db.upsertRow("a1", session: "ses_a", seq: 2, type: "assistant", created: base + 20, updated: base + 900,
                         data: LiveDatabase.assistant(created: base + 20))
        #expect(source.refresh(deduper: &deduper).upserts.isEmpty)
        try db.upsertRow("a1", session: "ses_a", seq: 2, type: "assistant", created: base + 20, updated: base + 3000,
                         data: LiveDatabase.assistant(created: base + 20, streamed: base + 2990, finish: "tool-calls"))
        let finished = source.refresh(deduper: &deduper)
        #expect(finished.upserts.count == 1)
        #expect(finished.upserts.first?.upsert.isCompletion == true)
        #expect(finished.upserts.first?.upsert.record.endMs == base + 2990)
        #expect(finished.upserts.first?.project == "atlas")
        #expect(finished.agents["opencode:ses_a"]?.phase == .tools)

        // Reading again, or a touch that changes nothing relevant, never repeats it.
        #expect(source.refresh(deduper: &deduper).upserts.isEmpty)
        try db.upsertRow("a1", session: "ses_a", seq: 2, type: "assistant", created: base + 20, updated: base + 3100,
                         data: LiveDatabase.assistant(created: base + 20, streamed: base + 2990, finish: "tool-calls"))
        #expect(source.refresh(deduper: &deduper).upserts.isEmpty)
        #expect(source.refreshIfChanged(deduper: &deduper)?.upserts.isEmpty ?? true)

        // A later correction of the same row replaces it (an update, not a second completion).
        try db.upsertRow("a1", session: "ses_a", seq: 2, type: "assistant", created: base + 20, updated: base + 3200,
                         data: LiveDatabase.assistant(created: base + 20, streamed: base + 2990, output: 140, finish: "tool-calls"))
        let corrected = source.refresh(deduper: &deduper)
        #expect(corrected.upserts.count == 1)
        #expect(corrected.upserts.first?.upsert.isCompletion == false)
        #expect(corrected.upserts.first?.upsert.record.usage.output == 140)

        try db.upsertRow("i1", session: "ses_a", seq: 3, type: "idle", created: base + 4000, updated: base + 4000, data: #"{"time":{"created":1}}"#)
        #expect(source.refresh(deduper: &deduper).agents["opencode:ses_a"]?.phase == .idle)
    }

    @Test func cleanlyClosedDatabaseIsReadImmutably() throws {
        let db = try LiveDatabase()
        let base: Int64 = 1_792_490_000_000
        try db.addSession("ses_a", at: base)
        try db.upsertRow("a1", session: "ses_a", seq: 1, type: "assistant", created: base + 10, updated: base + 900,
                         data: LiveDatabase.assistant(created: base + 10, streamed: base + 800))
        try db.closeWriter()
        let names = { try FileManager.default.contentsOfDirectory(atPath: db.directory.path).sorted() }
        let closed = try names()
        #expect(closed == ["opencode.db"], "OpenCode's clean close removes -wal and -shm")

        let path = db.directory.file("opencode.db").path
        #expect(OpencodeDatabase.headerSaysWAL(path))
        #expect(try OpencodeDatabase(path: path).isImmutable, "a WAL database without -wal is opened immutably")
        let afterProbe = try names()
        #expect(afterProbe == ["opencode.db"])
        let source = OpencodeSource(root: db.directory.path, fileID: -1)
        #expect(source.refreshAvailability())
        #expect(source.status == .ready)
        var deduper = Deduper()
        let seeded = source.seed(todayStartMs: base, deduper: &deduper)
        #expect(seeded.upserts.map(\.upsert.record.key) == ["a1"])
        let afterRead = try names()
        #expect(afterRead == ["opencode.db"], "an immutable read creates nothing")

        // OpenCode starts again: a -wal appears, the immutable connection is dropped and `mode=ro` sees the new row.
        try db.reopenWriter()
        try db.upsertRow("a2", session: "ses_a", seq: 2, type: "assistant", created: base + 2000, updated: base + 3000,
                         data: LiveDatabase.assistant(created: base + 2000, streamed: base + 2900))
        #expect(FileManager.default.fileExists(atPath: db.directory.file("opencode.db-wal").path))
        #expect(try !OpencodeDatabase(path: path).isImmutable)
        let refreshed = try #require(source.refreshIfChanged(deduper: &deduper))
        #expect(refreshed.upserts.map(\.upsert.record.key) == ["a2"])
        #expect(source.status == .ready)

        let report = try HistoryScan.run(
            configuration: MonitorConfiguration(enabledSources: [.opencode], opencodeRoot: db.directory.url),
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(report.days.map(\.totals.requests) == [2])
    }

    @Test func rollbackJournalDatabasesOpenReadOnly() throws {
        let path = Fixtures.root.appendingPathComponent("opencode/opencode.db").path
        #expect(!OpencodeDatabase.headerSaysWAL(path))
        #expect(try !OpencodeDatabase(path: path).isImmutable)
    }

    @Test func historyReadsACleanlyClosedDatabase() throws {
        let db = try LiveDatabase()
        let base: Int64 = 1_792_490_000_000
        try db.addSession("ses_h", at: base)
        try db.upsertRow("h1", session: "ses_h", seq: 1, type: "assistant", created: base + 10, updated: base + 900,
                         data: LiveDatabase.assistant(created: base + 10, streamed: base + 800))
        try db.closeWriter()
        let before = try FileManager.default.contentsOfDirectory(atPath: db.directory.path).sorted()
        #expect(before == ["opencode.db"])
        let report = try HistoryScan.run(
            configuration: MonitorConfiguration(enabledSources: [.opencode], opencodeRoot: db.directory.url),
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(report.days.map(\.totals.requests) == [1])
        let names = try FileManager.default.contentsOfDirectory(atPath: db.directory.path).sorted()
        #expect(names == ["opencode.db"])
    }

    @Test func concurrentWritesAreReadExactlyOnce() async throws {
        let db = try LiveDatabase()
        let base: Int64 = 1_792_490_000_000
        try db.addSession("ses_main", at: base)
        let source = OpencodeSource(root: db.directory.path, fileID: -1)
        source.refreshAvailability()
        var deduper = Deduper()
        _ = source.seed(todayStartMs: base, deduper: &deduper)

        let total = 300
        let path = db.directory.file("opencode.db").path
        let done = OSAllocatedUnfairLock(initialState: false)
        let writer = Task.detached {
            defer { done.withLock { $0 = true } }
            let connection = try SQLiteConnection(path: path, mode: .readWriteCreate)
            for index in 0..<total {
                let created = base + Int64(index) * 1000
                let child = "ses_c\(index / 50)"
                if index % 50 == 0 {
                    let session = try connection.prepare(
                        "INSERT INTO session_v2 VALUES (?1, 'p', 'ses_main', ?1, '/w/x', '2.0', ?2, ?2)")
                    session.bind(1, child)
                    session.bind(2, created)
                    try session.run()
                }
                let insert = try connection.prepare("INSERT INTO session_message VALUES (?1, ?2, 'assistant', ?3, ?4, ?4, ?5)")
                insert.bind(1, "row\(index)")
                insert.bind(2, child)
                insert.bind(3, Int64(index))
                insert.bind(4, created)
                insert.bind(5, LiveDatabase.assistant(created: created))
                try insert.run()
                let finish = try connection.prepare("UPDATE session_message SET time_updated = ?2, data = ?3 WHERE id = ?1")
                finish.bind(1, "row\(index)")
                finish.bind(2, created + 900)
                finish.bind(3, LiveDatabase.assistant(created: created, streamed: created + 800))
                try finish.run()
                let touch = try connection.prepare("UPDATE session_v2 SET time_updated = ?2 WHERE id = ?1")
                touch.bind(1, child)
                touch.bind(2, created + 900)
                try touch.run()
                if index % 10 == 0 { try await Task.sleep(for: .milliseconds(1)) }
            }
        }

        var completions: [String: Int] = [:]
        var updates = 0
        func drain(_ update: OpencodeSource.Update) {
            for (upsert, _) in update.upserts {
                if upsert.isCompletion { completions[upsert.record.key, default: 0] += 1 } else { updates += 1 }
            }
        }
        var reads = 0
        while !done.withLock({ $0 }) {
            drain(source.refresh(deduper: &deduper))
            reads += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        try await writer.value
        drain(source.refresh(deduper: &deduper))
        #expect(reads > 1)
        #expect(completions.count == total)
        #expect(completions.values.allSatisfy { $0 == 1 })
        #expect(updates == 0)
        #expect(source.parentLinks["opencode:ses_c0"] == "opencode:ses_main")
    }
}
