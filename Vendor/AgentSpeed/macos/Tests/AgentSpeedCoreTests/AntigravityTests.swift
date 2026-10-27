import Foundation
import Testing
@testable import AgentSpeedCore

/// A conversation database written the way the language server writes it: WAL mode, the agy 1.4.4 schema, blobs
/// built with `AntigravityBlobEncoder`. The writer connection stays open (keeping `-wal` and `-shm`) until `close()`.
/// Used by one task at a time.
final class ConversationWriter: @unchecked Sendable {
    static let schema = """
        PRAGMA user_version=1;
        CREATE TABLE trajectory_meta(trajectory_id TEXT,cascade_id TEXT,trajectory_type INTEGER,source INTEGER);
        CREATE TABLE steps(idx INTEGER,step_type INTEGER,status INTEGER,has_subtrajectory INTEGER,metadata BLOB,\
        error_details BLOB,permissions BLOB,task_details BLOB,render_info BLOB,step_payload BLOB,step_format INTEGER);
        CREATE TABLE gen_metadata(idx INTEGER,data BLOB,size INTEGER);
        CREATE TABLE executor_metadata(idx INTEGER,data BLOB);
        CREATE TABLE parent_references(idx INTEGER,data BLOB);
        CREATE TABLE trajectory_metadata_blob(id TEXT,data BLOB);
        CREATE TABLE battle_mode_infos(idx INTEGER,data BLOB);
        """

    let path: String
    private var connection: SQLiteConnection?

    init(path: String, trajectory: [UInt8]) throws {
        self.path = path
        let connection = try SQLiteConnection(path: path, mode: .readWriteCreate)
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute(Self.schema)
        self.connection = connection
        try insert("INSERT INTO trajectory_metadata_blob VALUES ('t', ?1)", trajectory)
    }

    /// Reopens an existing database for writing.
    init(reopening path: String) throws {
        self.path = path
        connection = try SQLiteConnection(path: path, mode: .readWriteCreate)
    }

    func step(_ idx: Int64, type: Int64, status: Int64, _ metadata: [UInt8]) throws {
        try insert("INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES (\(idx), \(type), \(status), ?1, x'0a00')",
                   metadata)
    }

    /// Rewrites a step in place, as the server does when a step progresses.
    func update(_ idx: Int64, status: Int64, _ metadata: [UInt8]) throws {
        try insert("UPDATE steps SET status = \(status), metadata = ?1 WHERE idx = \(idx)", metadata)
    }

    func generation(_ idx: Int64, _ data: [UInt8], size: Int64? = nil) throws {
        try insert("INSERT INTO gen_metadata VALUES (\(idx), ?1, \(size ?? Int64(data.count)))", data)
    }

    func executor(_ idx: Int64, _ data: [UInt8]) throws {
        try insert("INSERT INTO executor_metadata VALUES (\(idx), ?1)", data)
    }

    /// Checkpoints and closes like an exiting language server: no `-wal` or `-shm` stays behind.
    func close() throws {
        try connection?.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        connection?.close()
        connection = nil
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func insert(_ sql: String, _ blob: [UInt8]) throws {
        let statement = try connection!.prepare(sql)
        blob.withUnsafeBytes { statement.bind(1, blob: $0) }
        try statement.run()
    }
}

@Suite("Antigravity")
struct AntigravityTests {
    typealias AG = AntigravityBlobEncoder
    static let planner = AntigravityStep.plannerResponse
    static let userInput = AntigravityStep.userInput
    static let runCommand: Int64 = 21

    static var fixtures: [String: Any] {
        get throws { try #require(try Fixtures.json("parser-expected.json")["antigravity"] as? [String: Any]) }
    }

    static var stores: [URL] {
        ["antigravity-cli", "antigravity", "antigravity-ide"].map {
            Fixtures.root.appendingPathComponent("antigravity", isDirectory: true).appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Every file of the fixtures' `order` and then every database of `antigravity.order`, one shared dedupe set.
    static func readFixtureDatabases() throws -> [String: (parser: TranscriptParser, responses: [ResponseRecord])] {
        var deduper = Deduper()
        let (_, files) = try ParserFixtureTests.runFixtures(deduper: &deduper)
        let order = try #require(try fixtures["order"] as? [String])
        var results: [String: (parser: TranscriptParser, responses: [ResponseRecord])] = [:]
        for (index, relative) in order.enumerated() {
            let path = Fixtures.root.appendingPathComponent(relative).path
            var parser = TranscriptParser(family: .antigravity, agentId: path, fileID: FileID(files.count + index))
            var reader = TranscriptReader(path: path)
            let (batch, read) = reader.readDatabase()
            #expect(!read.failed, "\(relative) readable")
            // A closed WAL database is read immutable and the connection dropped; a rollback-journal one stays open.
            #expect(reader.hasOpenConnection == !AntigravityDatabase.headerSaysWAL(path), "\(relative) connection")
            var keys: [String] = []
            var latest: [String: ResponseRecord] = [:]
            parser.consume(.antigravity(batch), deduper: &deduper) { upsert in
                if latest[upsert.record.key] == nil { keys.append(upsert.record.key) }
                latest[upsert.record.key] = upsert.record
            }
            results[relative] = (parser, keys.compactMap { latest[$0] })
        }
        return results
    }

    static func listing(_ url: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        return (enumerator?.allObjects as? [String] ?? []).sorted()
    }

    @Test func fixtureDatabasesMatchExpectationsAndCreateNoFiles() throws {
        let tree = Fixtures.root.appendingPathComponent("antigravity")
        let before = Self.listing(tree)
        let results = try Self.readFixtureDatabases()
        #expect(Self.listing(tree) == before, "reading must not create -wal, -shm or journal files")

        let databases = try #require(try Self.fixtures["databases"] as? [String: [String: Any]])
        #expect(databases.count == results.count)
        for (relative, spec) in databases {
            let result = try #require(results[relative], "missing \(relative)")
            let state = result.parser.state
            if spec["unsupported"] as? Bool == true {
                #expect(result.parser.isUnsupported, "\(relative) unsupported")
                #expect(state.lastLineMs == nil && result.responses.isEmpty, "\(relative) contributes nothing")
                continue
            }
            #expect(!result.parser.isUnsupported, "\(relative) supported")
            #expect(state.source.rawValue == spec.string("source"), "\(relative) source")
            #expect(state.project == spec.string("project"), "\(relative) project")
            #expect(state.model == spec.string("model"), "\(relative) model")
            #expect(state.isSubagent == (spec["isSubagent"] as? Bool), "\(relative) isSubagent")
            #expect(state.phase.rawValue == spec.string("phase"), "\(relative) phase")
            #expect(state.inFlightStartMs == spec.int64("inFlightStartMs"), "\(relative) inFlightStartMs")
            #expect(state.lastLineMs == spec.int64("lastLineMs"), "\(relative) lastLineMs")
            #expect(state.malformedLines == spec.int("malformedLines"), "\(relative) malformedLines")
            let expected = try #require(spec["responses"] as? [[String: Any]])
            #expect(result.responses.count == expected.count, "\(relative) response count")
            for (actual, wanted) in zip(result.responses, expected) {
                #expect(actual.key == wanted.string("key"), "\(relative) key")
                #expect(actual.startMs == wanted.int64("startMs"), "\(relative) \(actual.key) startMs")
                #expect(actual.endMs == wanted.int64("endMs"), "\(relative) \(actual.key) endMs")
                #expect(actual.usage.input == wanted.int("input"), "\(relative) \(actual.key) input")
                #expect(actual.usage.cachedInput == wanted.int("cachedInput"), "\(relative) \(actual.key) cachedInput")
                #expect(actual.usage.cacheWriteInput == wanted.int("cacheWriteInput"), "\(relative) \(actual.key) cacheWriteInput")
                #expect(actual.usage.output == wanted.int("output"), "\(relative) \(actual.key) output")
                #expect(actual.usage.reasoning == wanted.int("reasoning"), "\(relative) \(actual.key) reasoning")
                #expect(actual.model == wanted.string("model"), "\(relative) \(actual.key) model")
                #expect(actual.source == .antigravity && actual.isFinal == (wanted["final"] as? Bool), "\(relative) \(actual.key)")
                expectPricingFields(actual, wanted, "\(relative) \(actual.key)")
            }
        }
    }

    @Test func parentLinksPreferTheCopyInTheSameStore() throws {
        let results = try Self.readFixtureDatabases()
        let databases = try #require(try Self.fixtures["databases"] as? [String: [String: Any]])
        let path = { (relative: String) in Fixtures.root.appendingPathComponent(relative).path }
        let members = results.filter { !$0.value.parser.isUnsupported }.map { relative, result in
            AgentParents.Member(id: path(relative), family: .antigravity, thread: result.parser.state.thread)
        }
        let parents = AgentParents.resolve(members)
        for (relative, spec) in databases where spec["unsupported"] == nil {
            #expect(parents[path(relative)] == spec.string("parentFile").map(path), "\(relative) parentFile")
        }
    }

    @Test func discoveryFindsOnlyConversationDatabases() throws {
        let wanted = try #require(try Self.fixtures["discover"] as? [String])
        var configuration = MonitorConfiguration()
        configuration.automaticRoots = [.antigravity: Self.stores]
        let prefix = Fixtures.root.path + "/"
        var found: [String] = []
        for root in configuration.resolvedRoots(for: .antigravity) {
            #expect(MonitorConfiguration.isReadable(root: root, family: .antigravity))
            var index = DirectoryIndex(root: root, names: .antigravityDatabase)
            found += index.scan().map { String($0.dropFirst(prefix.count)) }
        }
        #expect(found.sorted() == wanted)
        #expect(TranscriptNames.isConversationDatabase("E4D3C2B1-A0F9-4E8D-B7C6-A5F4E3D2C1B0.db"))
        #expect(!TranscriptNames.isConversationDatabase("5e2d1c0b-9a8f-4e7d-8c6b-5a4f3e2d1c0b.db-wal"))
        #expect(!TranscriptNames.isConversationDatabase("conversation_summaries.db"))
        #expect(!TranscriptNames.isConversationDatabase("5e2d1c0b-9a8f-4e7d-8c6b-5a4f3e2d1c0g.db"))
    }

    @Test func settingNamesOneStoreOrItsConversationsFolderAndNeverABackup() {
        let store = URL(fileURLWithPath: "/u/.gemini/antigravity-ide", isDirectory: true)
        let viaStore = MonitorConfiguration(antigravityRoot: store).resolvedRoots(for: .antigravity)
        let viaFolder = MonitorConfiguration(antigravityRoot: store.appendingPathComponent("conversations/")).resolvedRoots(for: .antigravity)
        #expect(viaStore == ["/u/.gemini/antigravity-ide/conversations"])
        #expect(viaFolder == viaStore)
        for backup in ["/u/.gemini/antigravity-backup", "/u/.gemini/antigravity-backup/conversations"] {
            let roots = MonitorConfiguration(antigravityRoot: URL(fileURLWithPath: backup)).resolvedRoots(for: .antigravity)
            #expect(roots.allSatisfy { !MonitorConfiguration.isReadable(root: $0, family: .antigravity) }, "\(backup)")
            #expect(!LiveMonitor.isReadableAntigravityStore(URL(fileURLWithPath: backup)))
        }
        #expect(TranscriptLocations.defaultAntigravityStores.map(\.lastPathComponent) == ["antigravity-cli", "antigravity", "antigravity-ide"])
    }

    @Test func backupStoreIsNeverReadByTheSession() throws {
        let configuration = MonitorConfiguration(
            enabledSources: [.antigravity],
            antigravityRoot: Fixtures.root.appendingPathComponent("antigravity/antigravity-backup", isDirectory: true)
        )
        let session = TranscriptSession(configuration: configuration)
        #expect(!session.hasAvailableRoot)
        #expect(session.seed(todayStartMs: 0).filesDiscovered == 0)
        let report = try HistoryScan.run(configuration: configuration, timeZone: HistoryTests.utc)
        #expect(report.filesDiscovered == 0 && report.days.isEmpty)
    }

    // MARK: - Live behaviour

    static func plannerDone(_ created: Int64, _ finished: Int64, output: UInt64, id: String) -> [UInt8] {
        let thinking = min(10, output)
        return AG.step(created: created, finished: finished, completed: finished + 20,
                       usage: AG.usage(input: 1000, output: output, cache: 500, thinking: thinking, response: output - thinking,
                                       responseId: id))
    }

    @Test func incrementalReadsFollowAConversationThatIsBeingWritten() throws {
        let directory = try TempDirectory()
        let path = directory.file("conversations/0f0e0d0c-0b0a-4908-8706-050403020100.db").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let t0: Int64 = 1_792_573_200_000
        let writer = try ConversationWriter(path: path, trajectory: AG.trajectory(created: t0, uris: ["file:///w/live"]))
        try writer.step(0, type: Self.userInput, status: 3, AG.step(created: t0 + 100, completed: t0 + 110))
        try writer.step(1, type: Self.planner, status: 8, AG.step(created: t0 + 150, usage: AG.usage(input: 10, output: 2)))

        var reader = TranscriptReader(path: path)
        var parser = TranscriptParser(family: .antigravity, agentId: path, fileID: 0)
        var deduper = Deduper()
        var upserts: [ResponseUpsert] = []
        func read() {
            let (batch, result) = reader.readDatabase()
            #expect(!result.failed)
            if result.didReset { parser = TranscriptParser(family: .antigravity, agentId: path, fileID: 0) }
            parser.consume(.antigravity(batch), deduper: &deduper) { upserts.append($0) }
        }

        read()
        #expect(reader.hasOpenConnection, "a live database keeps its mode=ro connection")
        #expect(parser.state.project == "live")
        #expect(parser.state.phase == .generating && parser.state.inFlightStartMs == t0 + 150)
        #expect(upserts.isEmpty, "an open planner row is still in flight")

        try writer.update(1, status: 3, Self.plannerDone(t0 + 150, t0 + 2150, output: 300, id: "r1"))
        try writer.step(2, type: Self.runCommand, status: 2, AG.step(created: t0 + 2200, started: t0 + 2210))
        read()
        #expect(upserts.count == 1 && upserts[0].isCompletion && upserts[0].record.key == "r1")
        #expect(upserts[0].record.startMs == t0 + 150 && upserts[0].record.endMs == t0 + 2150)
        #expect(upserts[0].record.model == nil)
        #expect(parser.state.phase == .tools)

        // The generation naming the model arrives later: the response is updated, not completed again.
        try writer.generation(0, AG.generation([1], responseModel: "gemini-3.1-flash"))
        try writer.update(2, status: 3, AG.step(created: t0 + 2200, completed: t0 + 4000, started: t0 + 2210))
        read()
        #expect(upserts.count == 2 && !upserts[1].isCompletion && upserts[1].record.model == "gemini-3.1-flash")
        #expect(parser.state.model == "gemini-3.1-flash")
        #expect(parser.state.phase == .generating && parser.state.inFlightStartMs == t0 + 4000)

        read()
        #expect(upserts.count == 2, "an unchanged database emits nothing")

        try writer.step(3, type: Self.planner, status: 3, Self.plannerDone(t0 + 4050, t0 + 5050, output: 90, id: "r2"))
        try writer.executor(0, AG.executor(reason: 4, lastStep: 3, model: "gemini-3.1-pro"))
        read()
        #expect(upserts.count == 3 && upserts[2].isCompletion && upserts[2].record.model == "gemini-3.1-pro")
        #expect(parser.state.phase == .idle)

        // The server exits: everything checkpointed, no -wal. The next read is immutable and creates nothing.
        try writer.close()
        let before = Self.listing(directory.url)
        read()
        #expect(Self.listing(directory.url) == before)
        #expect(!reader.hasOpenConnection)
        #expect(upserts.count == 3)

        // Reopened and continued: a new -wal; the connection opens mode=ro again.
        let resumed = try ConversationWriter(reopening: path)
        try resumed.step(4, type: Self.userInput, status: 3, AG.step(created: t0 + 9000, completed: t0 + 9010))
        try resumed.step(5, type: Self.planner, status: 3, Self.plannerDone(t0 + 9050, t0 + 9950, output: 40, id: "r3"))
        read()
        #expect(upserts.count == 4 && upserts[3].record.key == "r3")
        #expect(parser.state.malformedLines == 0)
        try resumed.close()
    }

    @Test func readsStayConsistentWhileTheServerWrites() async throws {
        let directory = try TempDirectory()
        let path = directory.file("conversations/1f0e0d0c-0b0a-4908-8706-050403020100.db").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let t0: Int64 = 1_792_573_200_000
        let writer = try ConversationWriter(path: path, trajectory: AG.trajectory(created: t0, uris: ["file:///w/busy"]))
        let count = 120
        let writing = Task.detached {
            for index in 0..<count {
                let idx = Int64(index)
                try writer.step(idx, type: Self.planner, status: 3,
                                Self.plannerDone(t0 + idx * 100, t0 + idx * 100 + 50, output: 20, id: "busy-\(index)"))
            }
        }
        var reader = TranscriptReader(path: path)
        var parser = TranscriptParser(family: .antigravity, agentId: path, fileID: 0)
        var deduper = Deduper()
        var completions: [String] = []
        func read() {
            let (batch, result) = reader.readDatabase()
            #expect(!result.failed)
            parser.consume(.antigravity(batch), deduper: &deduper) { if $0.isCompletion { completions.append($0.record.key) } }
        }
        while completions.count < count {
            read()
            if completions.count < count { try await Task.sleep(for: .milliseconds(2)) }
            if Task.isCancelled { break }
        }
        try await writing.value
        read()
        #expect(completions == (0..<count).map { "busy-\($0)" }, "every response exactly once, in order")
        try writer.close()
    }

    @Test func malformedAndForeignFilesContributeNothing() throws {
        let directory = try TempDirectory()
        let folder = directory.file("store/conversations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let garbage = folder.appendingPathComponent("2f0e0d0c-0b0a-4908-8706-050403020100.db")
        try Data("not a database at all, just text".utf8).write(to: garbage)
        var reader = TranscriptReader(path: garbage.path)
        let (batch, result) = reader.readDatabase()
        #expect(batch == nil && result.failed)
        #expect(Self.listing(folder).count == 1)

        // A database whose rows carry undecodable metadata: each counts once, also when re-read while open.
        let path = folder.appendingPathComponent("3f0e0d0c-0b0a-4908-8706-050403020100.db").path
        let writer = try ConversationWriter(path: path, trajectory: AG.trajectory(created: 1_000_000))
        try writer.step(0, type: Self.planner, status: 8, [0x0A, 0x05, 0x01])
        try writer.step(1, type: Self.planner, status: 3, AG.step(created: 1_000_100, finished: 1_000_200,
                                                                   usage: AG.usage(input: 10_000_001, output: 3)))
        var databaseReader = TranscriptReader(path: path)
        var parser = TranscriptParser(family: .antigravity, agentId: path, fileID: 0)
        var deduper = Deduper()
        for _ in 0..<3 {
            let (rows, _) = databaseReader.readDatabase()
            parser.consume(.antigravity(rows), deduper: &deduper) { _ in Issue.record("no response expected") }
        }
        #expect(parser.state.malformedLines == 2)
        try writer.close()
    }

    // MARK: - Session

    static func session(store: URL, clock: Int64 = 1_792_573_400_000) -> TranscriptSession {
        TranscriptSession(configuration: MonitorConfiguration(enabledSources: [.antigravity], antigravityRoot: store),
                          clock: { clock })
    }

    @Test func olderDatabasesAreReadCompletelyOffTheLiveLoopOnTheirFirstChange() throws {
        let directory = try TempDirectory()
        let store = directory.file("antigravity")
        let folder = store.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t0: Int64 = 1_792_573_200_000
        let path = folder.appendingPathComponent("4f0e0d0c-0b0a-4908-8706-050403020100.db").path
        let writer = try ConversationWriter(path: path, trajectory: AG.trajectory(created: t0, uris: ["file:///w/old"]))
        try writer.step(0, type: Self.planner, status: 3, Self.plannerDone(t0 + 100, t0 + 900, output: 50, id: "old-1"))
        try writer.close()
        let yesterday = Date(timeIntervalSince1970: TimeInterval(t0) / 1000 - 86_400)
        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: path)

        let session = Self.session(store: store, clock: t0 + 60_000)
        var jobs: [WholeFileRead] = []
        session.wholeFileReads = { jobs.append($0) }
        let summary = session.seed(todayStartMs: t0)
        #expect(summary.filesDiscovered == 1 && summary.filesRead == 0, "an older database is not opened at startup")
        #expect(session.responses.isEmpty && session.openDatabaseCount == 0)

        // The server continues the conversation; FSEvents reports its WAL, which stands for the database.
        let resumed = try ConversationWriter(reopening: path)
        try resumed.step(1, type: Self.planner, status: 3, Self.plannerDone(t0 + 1000, t0 + 1800, output: 70, id: "old-2"))
        let wal = try #require(realpath(path + "-wal", nil))
        let canonicalWAL = String(cString: wal)
        free(wal)
        #expect(!session.handleChanges(atCanonicalPaths: [canonicalWAL]))
        #expect(jobs.count == 1, "the first change schedules a complete read")
        for job in jobs { session.completeWholeFileRead(job.perform()) }
        #expect(Set(session.responses.map(\.key)) == ["old-1", "old-2"])
        let (output, events) = session.advance(nowMs: t0 + 60_000, todayStartMs: t0, emitsEvents: true)
        #expect(output.agents.map(\.agent.project) == ["old"])
        #expect(events.count == 2, "both responses end within two minutes of the clock")

        // Later changes are incremental and inline, at most once per 500 ms.
        let now = { Clock.milliseconds(Date()) }
        try resumed.step(2, type: Self.planner, status: 3, Self.plannerDone(t0 + 2000, t0 + 2600, output: 9, id: "old-3"))
        Thread.sleep(forTimeInterval: 0.55)
        #expect(session.pollRecentFiles(nowMs: now()))
        #expect(session.responses.count == 3 && jobs.count == 1)
        try resumed.step(3, type: Self.planner, status: 3, Self.plannerDone(t0 + 3000, t0 + 3600, output: 9, id: "old-4"))
        session.pollRecentFiles(nowMs: now())
        #expect(session.responses.count == 3, "a read within 500 ms of the previous one waits")
        Thread.sleep(forTimeInterval: 0.55)
        #expect(session.readDirtyDatabases())
        #expect(session.responses.count == 4)
        #expect(session.openDatabaseCount == 1, "a live database keeps its connection")
        try resumed.close()
    }

    @Test func connectionsAreCappedAndUnsupportedDatabasesWarn() throws {
        let directory = try TempDirectory()
        let store = directory.file("antigravity")
        let folder = store.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t0: Int64 = 1_792_573_200_000
        var writers: [ConversationWriter] = []
        for index in 0..<18 {
            let id = String(format: "%08x-0000-4000-8000-000000000000", index)
            let writer = try ConversationWriter(path: folder.appendingPathComponent("\(id).db").path,
                                                trajectory: AG.trajectory(created: t0, uris: ["file:///w/p\(index)"]))
            try writer.step(0, type: Self.planner, status: 3, Self.plannerDone(t0 + 100, t0 + 900, output: 5, id: "cap-\(index)"))
            writers.append(writer)
        }
        let unsupported = try SQLiteConnection(path: folder.appendingPathComponent("aaaaaaaa-0000-4000-8000-000000000000.db").path,
                                               mode: .readWriteCreate)
        try unsupported.execute("CREATE TABLE trajectory_steps(idx INTEGER, payload BLOB)")
        unsupported.close()

        let session = Self.session(store: store)
        _ = session.seed(todayStartMs: 0)
        #expect(session.responses.count == 18)
        #expect(session.openDatabaseCount == TranscriptSession.maxOpenDatabases, "open WAL databases are capped")
        let context = SnapshotContext(session: session, todayStartMs: 0)
        #expect(context.warnings.contains(.unsupportedFormat(.antigravity)))
        #expect(session.sessionCounts(todayStartMs: 0)[.antigravity] == 18)
        for writer in writers { try writer.close() }
    }

    @Test func historyReadsEveryDatabaseIncludingTheirWAL() throws {
        let directory = try TempDirectory()
        let store = directory.file("antigravity")
        let folder = store.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t0: Int64 = 1_792_573_200_000
        let path = folder.appendingPathComponent("5f0e0d0c-0b0a-4908-8706-050403020100.db").path
        let writer = try ConversationWriter(path: path, trajectory: AG.trajectory(created: t0))
        try writer.step(0, type: Self.planner, status: 3, Self.plannerDone(t0 + 100, t0 + 1100, output: 50, id: "h-1"))
        let configuration = MonitorConfiguration(enabledSources: [.antigravity], antigravityRoot: store)
        let storePath = directory.file("history.sqlite").path
        func run() throws -> (HistoryAnalyzer.Report, [DailyUsage]) {
            let analyzer = try HistoryAnalyzer(database: HistoryDatabase(path: storePath))
            let report = try analyzer.run(configuration: configuration, options: HistoryAnalyzer.Options(timeZone: HistoryTests.utc))
            return (report, analyzer.days(sources: [.antigravity]))
        }
        let (first, days) = try run()
        #expect(first.filesAnalyzed == 1 && days.map(\.totals.output) == [50])
        #expect(days.first?.measuredMs == 1000)
        #expect(try run().0.filesAnalyzed == 0, "an unchanged database and WAL are reused")
        // Only the WAL changes (the server has not checkpointed): the database is analysed again.
        try writer.step(1, type: Self.planner, status: 3, Self.plannerDone(t0 + 2000, t0 + 2500, output: 7, id: "h-2"))
        let (second, more) = try run()
        #expect(second.filesAnalyzed == 1 && more.map(\.totals.output) == [57])
        try writer.close()
    }
}
