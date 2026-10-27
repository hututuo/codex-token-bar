import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexBusinessDatabaseTests: XCTestCase {
    func testProofDoesNotDependOnAnotherModulesAutoincrementTable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try CodexBusinessDatabase(url: root.appendingPathComponent("codex-ledger.sqlite"))
        for (index, ddl) in [
            "CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT); INSERT INTO records VALUES(9)",
            "CREATE TABLE records(id TEXT PRIMARY KEY, value BLOB); INSERT INTO records VALUES('kept',x'00ff')",
            "CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT)"
        ].enumerated() {
            let source = root.appendingPathComponent("source-\(index).sqlite")
            let legacy = SQLiteDatabaseDriver(url: source)
            try legacy.execute(ddl)
            let expected = try legacy.withConnection { try CodexBusinessDatabase.proof($0) }
            let store = BusinessSQLiteStore(containerURL: container.url, logicalURL: source, module: "fixture", sourceIdentity: String(index))
            _ = try container.importSnapshot(source, into: store, backupURL: source)
            let namespace = SQLiteStoreNamespace(prefix: store.prefix, objectNames: ["records"])
            XCTAssertEqual(try container.driver.withConnection { try CodexBusinessDatabase.proof($0, namespace: namespace) }, expected)
            let exported = root.appendingPathComponent("export-\(index).sqlite")
            try CodexBusinessDatabase.export(store, to: exported)
            XCTAssertEqual(try SQLiteDatabaseDriver(url: exported).withConnection { try CodexBusinessDatabase.proof($0) }, expected)
        }
    }
    func testNamespacesPreserveCollidingIDsWALBlobNullAndIndependentVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let a = try CodexBusinessDatabase(url:root.appendingPathComponent("codex-ledger.sqlite"))
        var stores: [BusinessSQLiteStore] = []
        for index in 0..<2 {
            let legacy = root.appendingPathComponent("legacy-\(index).sqlite")
            let db = SQLiteDatabaseDriver(url:legacy,enableWAL:true)
            try db.execute("CREATE TABLE schema_meta(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT, n INTEGER, payload BLOB, note TEXT); PRAGMA user_version=\(index+11);")
            try db.execute("INSERT INTO schema_meta VALUES('generation',?)",bindings:[.text(String(index))])
            try db.execute("INSERT INTO events(id,uuid,n,payload,note) VALUES(99,'same-uuid',?, ?,NULL)",bindings:[.int(index+7),.blob(Data([0,255,0,13]))])
            try db.execute("INSERT INTO events(id,uuid,n) VALUES(150,'deleted',1); DELETE FROM events WHERE id=150")
            let store = BusinessSQLiteStore(containerURL:a.url,logicalURL:legacy,module:"exact",sourceIdentity:"home-\(index)")
            _ = try a.importSnapshot(legacy,into:store,backupURL:legacy)
            stores.append(store)
        }
        XCTAssertEqual(try a.driver.readRows("PRAGMA user_version") { $0.int(0) }.first!, 1)
        XCTAssertNoThrow(try CodexBusinessDatabase(url: a.url))
        BusinessSQLiteRoutes.install(stores)
        defer { BusinessSQLiteRoutes.remove(stores) }
        for (index,store) in stores.enumerated() {
            let db = SQLiteDatabaseDriver(url:store.logicalURL)
            XCTAssertEqual(try db.readRows("SELECT n FROM events WHERE id=99") { $0.int(0) }.first!,index+7)
            XCTAssertEqual(try db.readRows("SELECT payload FROM events") { $0.data(0) }.first!,Data([0,255,0,13]))
            XCTAssertEqual(try db.readRows("PRAGMA user_version") { $0.int(0) }.first!,index+11)
            try db.execute("INSERT INTO events(uuid,n) VALUES('new',3)")
            XCTAssertEqual(try db.readRows("SELECT max(id) FROM events") { $0.int(0) }.first!,151)
            try db.execute("INSERT INTO schema_meta(key,value) VALUES('generation','next') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            let names = try db.readRows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") { $0.text(0) ?? "" }
            XCTAssertEqual(names,["events","schema_meta"])
            let backup = root.appendingPathComponent("export-\(index).sqlite")
            try db.execute("VACUUM INTO ?",bindings:[.text(backup.path)])
            let plain = SQLiteDatabaseDriver(url:backup,readOnly:true)
            XCTAssertEqual(try plain.readRows("SELECT max(id) FROM events") { $0.int(0) }.first!,151)
            XCTAssertEqual(try plain.readRows("PRAGMA user_version") { $0.int(0) }.first!,index+11)
        }
        XCTAssertEqual(try a.driver.readRows("PRAGMA user_version") { $0.int(0) }.first!,1)
    }
    func testSQLBinderNeverChangesValuesCommentsOrBindParameters() throws {
        var ns = SQLiteStoreNamespace(prefix:"private_",objectNames:["events","schema_meta"])
        let sql = "SELECT events.id FROM events WHERE text='events' AND note=? -- events\n/* schema_meta */"
        XCTAssertEqual(try ns.bind(sql),"SELECT \"private_events\".id FROM \"private_events\" WHERE text='events' AND note=? -- events\n/* schema_meta */")
        XCTAssertTrue(try ns.bind("CREATE TABLE pending(id INTEGER REFERENCES events(id))").contains("\"private_pending\""))
        XCTAssertThrowsError(try ns.bind("SELECT * FROM events, outside_store"))
        XCTAssertThrowsError(try ns.bind("SELECT name FROM main.sqlite_master"))
        XCTAssertThrowsError(try ns.bind("CREATE INDEX unsafe_idx ON outside_store(id)"))
        XCTAssertThrowsError(try ns.bind("ATTACH DATABASE 'other.sqlite' AS other"))
        XCTAssertThrowsError(try ns.bind("SELECT * FROM temp.events"))
        XCTAssertThrowsError(try ns.bind("SELECT * FROM temp.sqlite_master"))
        XCTAssertTrue(try ns.bind("SELECT * FROM main.events").contains("main.\"private_events\""))

        var temporary = SQLiteStoreNamespace(prefix: "private_", objectNames: [])
        XCTAssertEqual(try temporary.bind("CREATE TEMP TABLE comparison(id INTEGER)"), "CREATE TEMP TABLE \"private_comparison\"(id INTEGER)")
        XCTAssertEqual(try temporary.bind("INSERT INTO temp.comparison VALUES(1)"), "INSERT INTO temp.\"private_comparison\" VALUES(1)")
        XCTAssertEqual(try temporary.bind("SELECT * FROM temp.comparison"), "SELECT * FROM temp.\"private_comparison\"")
        XCTAssertEqual(try temporary.bind("DROP TABLE temp.comparison"), "DROP TABLE temp.\"private_comparison\"")

        var triggerNamespace = SQLiteStoreNamespace(prefix: "private_", objectNames: ["events", "history", "sources", "schema_meta"])
        XCTAssertNoThrow(try triggerNamespace.bind("""
            CREATE TRIGGER retained_event AFTER DELETE ON events BEGIN
                DELETE FROM history WHERE id IN (
                    SELECT s.event_id FROM sources s LEFT JOIN schema_meta m ON m.key=s.meta_key
                );
            END;
            """))

        let store = BusinessSQLiteStore(
            containerURL: FileManager.default.temporaryDirectory.appendingPathComponent("container.sqlite"),
            logicalURL: FileManager.default.temporaryDirectory.appendingPathComponent("events.sqlite"),
            module: "fixture", sourceIdentity: "pragma-binding"
        )
        let binding = SQLiteStoreBinding(store: store, names: ["events"])
        let isolated = try binding.sql("PRAGMA user_version=7; PRAGMA quick_check; PRAGMA journal_mode=DELETE; PRAGMA wal_checkpoint(TRUNCATE);")
        XCTAssertTrue(isolated.contains("UPDATE main.tb_stores SET user_version=7"))
        XCTAssertTrue(isolated.contains("FROM pragma_quick_check"))
        XCTAssertTrue(isolated.contains("PRAGMA main.journal_mode"))
        XCTAssertTrue(isolated.contains("SELECT 0 AS busy,0 AS log,0 AS checkpointed"))
        XCTAssertThrowsError(try binding.sql("PRAGMA query_only=OFF"))
        XCTAssertThrowsError(try binding.sql("PRAGMA main.user_version"))
    }

    func testForeignAndFutureContainerVersionsFailBeforeSchemaChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for version in [0, 2] {
            let url = root.appendingPathComponent("foreign-\(version).sqlite")
            let foreign = SQLiteDatabaseDriver(url: url, bypassBusinessRoutes: true)
            try foreign.execute("CREATE TABLE unrelated(id INTEGER PRIMARY KEY, value TEXT); PRAGMA user_version=\(version);")
            let before = try foreign.readRows("SELECT type,name,sql FROM sqlite_master ORDER BY type,name") {
                ($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? "")
            }
            XCTAssertThrowsError(try CodexBusinessDatabase(url: url))
            let after = try foreign.readRows("SELECT type,name,sql FROM sqlite_master ORDER BY type,name") {
                ($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? "")
            }
            XCTAssertEqual(after.map { "\($0.0)|\($0.1)|\($0.2)" }, before.map { "\($0.0)|\($0.1)|\($0.2)" })
            XCTAssertEqual(try foreign.readRows("PRAGMA user_version") { $0.int(0) }.first!, version)
        }
    }

    func testFullSchemaAndTypedRowsRoundTripIncludingIndexesViewsTriggersAndModuleVersion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let containerURL = root.appendingPathComponent("codex-ledger.sqlite")
        let ledger = try CodexBusinessDatabase(url: containerURL)
        let source = root.appendingPathComponent("legacy.sqlite")
        let legacy = SQLiteDatabaseDriver(url: source, bypassBusinessRoutes: true)
        try legacy.execute("""
            CREATE TABLE parent(
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                payload BLOB,
                note TEXT,
                generated TEXT GENERATED ALWAYS AS (key || '!') STORED
            );
            CREATE TABLE child(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                parent_key TEXT REFERENCES parent(key) ON DELETE CASCADE,
                note TEXT CHECK(note IS NULL OR length(note) > 0)
            );
            CREATE INDEX child_note_ix ON child(note DESC) WHERE note IS NOT NULL;
            CREATE VIEW child_summary AS SELECT parent_key,count(*) AS child_count FROM child GROUP BY parent_key;
            CREATE TRIGGER child_note_update AFTER UPDATE OF note ON child BEGIN
                UPDATE parent SET note=NEW.note WHERE key=NEW.parent_key;
            END;
            CREATE TABLE rowid_holes(key TEXT,value TEXT);
            CREATE TABLE without_rowid(key TEXT PRIMARY KEY,value TEXT) WITHOUT ROWID;
            CREATE TABLE empty_auto(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT);
            CREATE TABLE index_order(key TEXT UNIQUE,value TEXT);
            CREATE INDEX aaa_index_order ON index_order(value);
            PRAGMA user_version=17;
            INSERT INTO parent(key,payload,note) VALUES('key-1',X'00FF000D',CAST(X'610062' AS TEXT));
            INSERT INTO child(parent_key,note) VALUES('key-1',CAST(X'780079' AS TEXT));
            INSERT INTO rowid_holes(rowid,key,value) VALUES(99,'deleted','x'),(150,'retained','y');
            DELETE FROM rowid_holes WHERE rowid=99;
            INSERT INTO without_rowid(key,value) VALUES('stable','value');
            INSERT INTO index_order(key,value) VALUES('unique','indexed');
            """)
        let store = BusinessSQLiteStore(containerURL: containerURL, logicalURL: source, module: "fixture", sourceIdentity: "schema-proof")
        let expected = try legacy.withConnection { try CodexBusinessDatabase.proof($0) }
        let imported = try ledger.importSnapshot(source, into: store, backupURL: source)
        XCTAssertEqual(imported, expected)
        let export = root.appendingPathComponent("round-trip.sqlite")
        try CodexBusinessDatabase.export(store, to: export)
        let actual = try SQLiteDatabaseDriver(url: export, readOnly: true, bypassBusinessRoutes: true).withConnection {
            try CodexBusinessDatabase.proof($0)
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.moduleUserVersion, 17)
        XCTAssertEqual(actual.tableCounts["sqlite_sequence"], Int64(1))
        XCTAssertEqual(try SQLiteDatabaseDriver(url: export, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT rowid FROM rowid_holes") { $0.int64(0) }.first ?? -1, Int64(150))
    }

    func testIdempotentImportPreservesWritesMadeAfterInitialImport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let containerURL = root.appendingPathComponent("codex-ledger.sqlite")
        let ledger = try CodexBusinessDatabase(url: containerURL)
        let source = root.appendingPathComponent("legacy.sqlite")
        let legacy = SQLiteDatabaseDriver(url: source, bypassBusinessRoutes: true)
        try legacy.execute("CREATE TABLE events(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO events VALUES(1,'original');")
        let store = BusinessSQLiteStore(containerURL: containerURL, logicalURL: source, module: "fixture", sourceIdentity: "idempotent")
        _ = try ledger.importSnapshot(source, into: store, backupURL: source)
        BusinessSQLiteRoutes.install([store])
        defer { BusinessSQLiteRoutes.remove([store]) }
        let routed = SQLiteDatabaseDriver(url: source)
        try routed.execute("UPDATE events SET value='newer' WHERE id=1")
        _ = try ledger.importSnapshot(source, into: store, backupURL: source)
        XCTAssertEqual(try routed.readRows("SELECT value FROM events WHERE id=1") { $0.text(0) }.first!, "newer")
    }

    func testCorruptSourceDoesNotRegisterOrAlterDestinationStore() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let containerURL = root.appendingPathComponent("codex-ledger.sqlite")
        let ledger = try CodexBusinessDatabase(url: containerURL)
        let source = root.appendingPathComponent("corrupt.sqlite")
        try Data([0, 1, 2, 3, 255, 0, 7]).write(to: source)
        let store = BusinessSQLiteStore(containerURL: containerURL, logicalURL: source, module: "fixture", sourceIdentity: "corrupt")
        XCTAssertThrowsError(try ledger.importSnapshot(source, into: store, backupURL: source))
        XCTAssertEqual(try ledger.driver.readRows("SELECT count(*) FROM tb_stores") { $0.int(0) }.first!, 0)
    }

    func testImportReadsLiveWALSnapshotWhileSourceConnectionRemainsOpen() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let containerURL = root.appendingPathComponent("codex-ledger.sqlite")
        let ledger = try CodexBusinessDatabase(url: containerURL)
        let source = root.appendingPathComponent("live-wal.sqlite")
        let legacy = SQLiteDatabaseDriver(url: source, bypassBusinessRoutes: true)
        let store = BusinessSQLiteStore(containerURL: containerURL, logicalURL: source, module: "fixture", sourceIdentity: "live-wal")
        try legacy.withConnection { writer in
            try writer.execute("PRAGMA journal_mode=WAL")
            try writer.execute("CREATE TABLE events(key TEXT,value BLOB)")
            try writer.execute("INSERT INTO events(rowid,key,value) VALUES(150,'kept',X'00FF')")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-wal"), "fixture must retain committed WAL pages while writer stays open")
            let proof = try ledger.importSnapshot(source, into: store, backupURL: source)
            XCTAssertEqual(proof.rowCount, 1)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
