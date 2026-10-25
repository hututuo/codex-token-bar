import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Daily history traffic")
struct HistoryTrafficTests {
    static let rows = [
        TrafficDay(day: "2026-10-20", key: TrafficDay.machineKey, rx: 9_000_000, tx: 1_200_000, sampledMs: 86_400_000),
        TrafficDay(day: "2026-10-20", key: SourceKind.codex.rawValue, rx: 400_000, tx: 50_000, rxTools: 3_000_000,
                   txTools: 20_000, sampledMs: 80_000_000),
        TrafficDay(day: "2026-10-21", key: TrafficDay.machineKey, rx: 5_000, tx: 6_000, sampledMs: 60_000),
        TrafficDay(day: "2026-10-21", key: SourceKind.claudeCode.rawValue, rx: 1_000, tx: 2_000, rxTools: 3_000,
                   txTools: 4_000, sampledMs: 55_000),
    ]

    static func storePath(in directory: TempDirectory) -> String {
        directory.file("store/history.sqlite").path
    }

    static func tables(at path: String) throws -> Set<String> {
        let connection = try SQLiteConnection(path: path, mode: .readOnly)
        defer { connection.close() }
        var names: Set<String> = []
        try connection.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").forEachRow { row in
            if let name = row.string(0) { names.insert(name) }
        }
        return names
    }

    static func pragma(_ name: String, at path: String) throws -> String? {
        let connection = try SQLiteConnection(path: path, mode: .readOnly)
        defer { connection.close() }
        var value: String?
        try connection.prepare("PRAGMA \(name)").forEachRow { value = $0.string(0) }
        return value
    }

    static func columns(of table: String, at path: String) throws -> [String] {
        let connection = try SQLiteConnection(path: path, mode: .readOnly)
        defer { connection.close() }
        var names: [String] = []
        try connection.prepare("PRAGMA table_info(\(table))").forEachRow { row in
            if let name = row.string(1) { names.append(name) }
        }
        return names
    }

    /// Runs `sql` on a new store at `path` built by hand (as an older or newer build left it).
    static func handBuiltStore(at path: String, _ sql: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: path, mode: .readWriteCreate)
        defer { connection.close() }
        try connection.execute(sql)
    }

    static func sorted(_ rows: [TrafficDay]) -> [TrafficDay] {
        rows.sorted { $0.day != $1.day ? $0.day < $1.day : $0.key < $1.key }
    }

    @Test func rowsRoundTripAndUpsertWhileTheFirstDayOnlyMovesEarlier() throws {
        let directory = try TempDirectory()
        let path = Self.storePath(in: directory)
        try HistoryDatabase.saveTraffic(Self.rows.reversed(), at: path)
        let stored = HistoryDatabase.storedTraffic(at: path)
        #expect(stored.days == Self.sorted(Self.rows), "sorted by day, then key")
        #expect(stored.since == "2026-10-20")

        let updated = TrafficDay(day: "2026-10-21", key: TrafficDay.machineKey, rx: 7_000, tx: 8_000, sampledMs: 120_000)
        let later = TrafficDay(day: "2026-10-22", key: SourceKind.gemini.rawValue, rx: 1, tx: 2, sampledMs: 3)
        try HistoryDatabase.saveTraffic([updated, later], at: path)
        let upserted = HistoryDatabase.storedTraffic(at: path)
        #expect(upserted.days == Self.sorted(Self.rows.filter { !($0.day == updated.day && $0.isMachine) } + [updated, later]))
        #expect(upserted.since == "2026-10-20", "a later save never moves the first day")

        let earlier = TrafficDay(day: "2026-10-19", key: TrafficDay.machineKey, rx: 1, tx: 1, sampledMs: 1_000)
        try HistoryDatabase.saveTraffic([earlier], at: path)
        #expect(HistoryDatabase.storedTraffic(at: path).since == "2026-10-19")
        #expect(HistoryDatabase.storedTraffic(at: path).days.count == Self.rows.count + 2)
    }

    @Test func aMissingStoreIsCreatedWithTheFullSchemaOnlyWhenSaving() throws {
        let directory = try TempDirectory()
        let path = Self.storePath(in: directory)
        let read = HistoryDatabase.storedTraffic(at: path)
        #expect(read.days.isEmpty && read.since == nil)
        try HistoryDatabase.saveTraffic([], at: path)
        #expect(!FileManager.default.fileExists(atPath: path), "reading and saving nothing create no store")
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))

        try HistoryDatabase.saveTraffic(Self.rows, at: path)
        #expect(try Self.pragma("user_version", at: path) == String(HistoryDatabase.schemaVersion))
        #expect(try Self.pragma("journal_mode", at: path) == "wal")
        #expect(try Self.tables(at: path).isSuperset(of: [
            "meta", "files", "contributions", "contribution_models", "day_peaks", "price_bindings", "price_tables", "day_traffic",
        ]))
        let analyzer = try HistoryAnalyzer(database: HistoryDatabase(path: path))
        #expect(analyzer.entries.isEmpty)
        #expect(HistoryDatabase.storedTraffic(at: path).days == Self.sorted(Self.rows))
    }

    @Test func aCurrentStoreWithoutTheTableGetsItOnSaveAndOnOpen() throws {
        let directory = try TempDirectory()
        let path = Self.storePath(in: directory)
        _ = try HistoryDatabase(path: path)
        #expect(try Self.tables(at: path).contains("day_traffic"), "every open creates it")

        try Self.handBuiltStore(at: path, "DROP TABLE day_traffic")
        #expect(HistoryDatabase.storedTraffic(at: path).days.isEmpty)
        try HistoryDatabase.saveTraffic(Self.rows, at: path)
        #expect(HistoryDatabase.storedTraffic(at: path).days == Self.sorted(Self.rows))
        #expect(try Self.pragma("user_version", at: path) == "3")

        try Self.handBuiltStore(at: path, "DROP TABLE day_traffic")
        _ = try HistoryDatabase(path: path)
        #expect(try Self.tables(at: path).contains("day_traffic"))
        #expect(try Self.pragma("user_version", at: path) == "3")
    }

    @Test func anOlderStoreOnlyGetsTheTrafficTableAndIsMigratedLaterByANormalOpen() throws {
        let directory = try TempDirectory()
        let path = Self.storePath(in: directory)
        try Self.handBuiltStore(at: path, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, family TEXT NOT NULL, size INTEGER NOT NULL,
                modified INTEGER NOT NULL, version INTEGER NOT NULL, keys BLOB NOT NULL);
            CREATE TABLE contributions (file_id INTEGER NOT NULL, day TEXT NOT NULL, source TEXT NOT NULL,
                requests INTEGER NOT NULL, input INTEGER NOT NULL, cached_input INTEGER NOT NULL,
                cache_write_input INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
                measured_output INTEGER NOT NULL, measured_ms INTEGER NOT NULL, unfinalized INTEGER NOT NULL,
                agents INTEGER NOT NULL, PRIMARY KEY (file_id, day, source)) WITHOUT ROWID;
            CREATE TABLE contribution_models (file_id INTEGER NOT NULL, day TEXT NOT NULL, source TEXT NOT NULL,
                model TEXT NOT NULL, requests INTEGER NOT NULL, output INTEGER NOT NULL, measured_output INTEGER NOT NULL,
                measured_ms INTEGER NOT NULL, PRIMARY KEY (file_id, day, source, model)) WITHOUT ROWID;
            CREATE TABLE day_peaks (day TEXT PRIMARY KEY, peak REAL NOT NULL) WITHOUT ROWID;
            INSERT INTO files VALUES (1, '/gone.jsonl', 'claude', 1, 1, 2, x'');
            INSERT INTO contributions VALUES (1, '2026-10-01', 'claudeCode', 2, 10, 0, 0, 30, 0, 30, 1000, 0, 1);
            PRAGMA user_version = 2;
            """)
        let before = try Self.tables(at: path)
        let contributionColumns = try Self.columns(of: "contributions", at: path)

        try HistoryDatabase.saveTraffic(Self.rows, at: path)
        #expect(try Self.pragma("user_version", at: path) == "2", "saving traffic never migrates")
        #expect(try Self.tables(at: path) == before.union(["day_traffic"]))
        #expect(try Self.columns(of: "contributions", at: path) == contributionColumns)
        let stored = HistoryDatabase.storedTraffic(at: path)
        #expect(stored.days == Self.sorted(Self.rows))
        #expect(stored.since == "2026-10-20")

        let database = try HistoryDatabase(path: path)
        #expect(try Self.pragma("user_version", at: path) == "3", "the history worker's open migrates")
        #expect(try Self.columns(of: "contributions", at: path).contains("cost_micro_usd"))
        #expect(try database.loadEntries()["/gone.jsonl"]?.days.count == 1)
        #expect(HistoryDatabase.storedTraffic(at: path).days == Self.sorted(Self.rows))
    }

    @Test func aNewerStoreIsLeftUntouched() throws {
        let directory = try TempDirectory()
        let path = Self.storePath(in: directory)
        try Self.handBuiltStore(at: path, """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            PRAGMA user_version = 99;
            """)
        #expect(throws: HistoryDatabase.Failure.newerSchema) { try HistoryDatabase.saveTraffic(Self.rows, at: path) }
        #expect(throws: HistoryDatabase.Failure.newerSchema) { _ = try HistoryDatabase(path: path) }
        #expect(try Self.tables(at: path) == ["meta"])
        #expect(try Self.pragma("user_version", at: path) == "99")
        #expect(try Self.pragma("journal_mode", at: path) == "delete")
        #expect(HistoryDatabase.storedTraffic(at: path).days.isEmpty)
    }

    @Test func savingBesideAnOpenHistoryConnectionWorks() throws {
        let directory = try TempDirectory()
        let path = Self.storePath(in: directory)
        let held = try HistoryDatabase(path: path)
        try held.recordPeak(12, day: "2026-10-20")
        try HistoryDatabase.saveTraffic(Self.rows, at: path)
        try held.recordPeak(15, day: "2026-10-21")
        #expect(HistoryDatabase.storedTraffic(at: path).days == Self.sorted(Self.rows))
        #expect(try held.peaks() == ["2026-10-20": 12, "2026-10-21": 15])
        #expect(try held.meta(HistoryDatabase.trafficSinceKey) == "2026-10-20")
    }

    @Test func reanalysisNeverTouchesTraffic() throws {
        let scratch = try HistoryTests.Scratch()
        try scratch.directory.write("claude/p/a.jsonl", HistoryTests.claude([("m1", 100), ("m2", 50)]))
        let (first, days) = try scratch.run()
        #expect(first.filesAnalyzed == 1)
        try HistoryDatabase.saveTraffic(Self.rows, at: scratch.storePath)

        let (bumped, bumpedDays) = try scratch.run(version: HistoryAnalyzer.analysisVersion + 1)
        #expect(bumped.filesAnalyzed == 1, "an analysis version bump re-analyses every file")
        #expect(bumpedDays == days)
        #expect(HistoryDatabase.storedTraffic(at: scratch.storePath).days == Self.sorted(Self.rows))

        let analyzer = try HistoryAnalyzer(database: HistoryDatabase(path: scratch.storePath))
        var options = HistoryAnalyzer.Options(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        options.analysisVersion = HistoryAnalyzer.analysisVersion + 1
        let zoned = try analyzer.run(configuration: scratch.configuration, options: options)
        #expect(zoned.filesAnalyzed == 1, "a time zone change re-analyses every file")
        let stored = HistoryDatabase.storedTraffic(at: scratch.storePath)
        #expect(stored.days == Self.sorted(Self.rows))
        #expect(stored.since == "2026-10-20")
    }

    @Test func fixtureAnalysesKeepTraffic() throws {
        let (directory, copy) = try HistoryTests.fixtureCopy()
        let path = Self.storePath(in: directory)
        let configuration = HistoryTests.configuration(fixtures: copy)
        try HistoryDatabase.saveTraffic(Self.rows, at: path)
        let first = try HistoryScan.run(configuration: configuration, timeZone: HistoryTests.utc, storePath: path)
        #expect(first.filesAnalyzed > 0)
        let again = try HistoryScan.run(configuration: configuration, timeZone: TimeZone(identifier: "Asia/Tokyo")!,
                                        storePath: path)
        #expect(again.filesAnalyzed == first.filesAnalyzed, "a time zone change analyses everything again")
        let stored = HistoryDatabase.storedTraffic(at: path)
        #expect(stored.days == Self.sorted(Self.rows))
        #expect(stored.since == "2026-10-20")
    }

    @Test func clearingHistoryDeletesTraffic() throws {
        let directory = try TempDirectory()
        let path = Self.storePath(in: directory)
        try HistoryDatabase.saveTraffic(Self.rows, at: path)
        #expect(!HistoryDatabase.storedTraffic(at: path).days.isEmpty)
        HistoryDatabase.delete(at: path)
        #expect(!FileManager.default.fileExists(atPath: path))
        let cleared = HistoryDatabase.storedTraffic(at: path)
        #expect(cleared.days.isEmpty && cleared.since == nil)
    }

    #if DEBUG
    @Test func debugBuildsHonourTheSupportFolderOverride() throws {
        let directory = try TempDirectory()
        let name = "AGENT_SPEED_SUPPORT_DIR"
        setenv(name, directory.path, 1)
        defer { unsetenv(name) }
        #expect(HistoryService.defaultStoreURL.path == directory.file("history.sqlite").path)
        setenv(name, "", 1)
        #expect(HistoryService.defaultStoreURL.path.hasSuffix("/Application Support/AgentSpeed/history.sqlite"))
    }
    #endif
}
