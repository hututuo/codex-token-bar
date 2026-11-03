import Foundation
import XCTest
@testable import CodexTokenBar

/// Actual importer/router checks. The sink is deliberately outside accounting
/// authority; failure must leave exactly the same proved published rows.
final class RecoveryDiagnosticsMigrationTests: XCTestCase {
    private enum Sink { case off, on, unavailable, writeFailure }

    override func tearDown() {
        BusinessSQLiteRoutes.deactivate()
        super.tearDown()
    }

    private func exercise(_ sink: Sink, rows: Int = 64) throws -> Double {
        BusinessSQLiteRoutes.deactivate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-migration-\(UUID().uuidString)")
        defer { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let c = BusinessDatabaseMigration.Configuration(container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support, exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("old"))
        let source = support.appendingPathComponent("quota-history.sqlite")
        let original = SQLiteDatabaseDriver(url: source, enableWAL: false, bypassBusinessRoutes: true)
        try original.withConnection { db in
            try db.execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY,amount INTEGER NOT NULL,payload BLOB NOT NULL)")
            try db.transaction { tx in
                let insert = try tx.prepare("INSERT INTO preserved VALUES(?,?,?)")
                for n in 0..<rows {
                    try insert.execute([.int(n), .int64(Int64.min + Int64(n)), .blob(Data(repeating: UInt8(n % 251), count: 8192))])
                }
            }
        }
        let expected = try original.withConnection { try CodexBusinessDatabase.proof($0) }
        let logs = support.appendingPathComponent("recovery-diagnostics/v1")
        if sink == .unavailable {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data("unowned material".utf8).write(to: logs.appendingPathComponent("owner.marker"))
        }
        let started = ProcessInfo.processInfo.systemUptime
        let log = sink == .off ? nil : RecoveryDiagnostics(root: logs)
        if sink == .unavailable { XCTAssertNil(log) }
        if sink == .on || sink == .writeFailure { XCTAssertNotNil(log) }
        #if DEBUG
        if sink == .writeFailure { log?.failNextFlushForTesting() }
        #endif
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, onProgress: { value in
            log?.record(RecoveryDiagnostics.Phase(rawValue: value.stage.rawValue) ?? .preparing,
                completed: value.completed, total: value.total)
        })
        log?.close()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: source))
        let a = SQLiteDatabaseDriver(url: c.container, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        let actual = try a.withConnection {
            try CodexBusinessDatabase.proof($0, namespace: .init(prefix: store.prefix, objectNames: ["preserved"]))
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try original.withConnection { try CodexBusinessDatabase.proof($0) }, expected)
        XCTAssertEqual(try a.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") { $0.text(0) }, ["ready"])
        // A failed diagnostic sink neither revokes writers nor replaces data
        // subsequently committed by the current app with an older snapshot.
        try SQLiteDatabaseDriver(url: source).execute("UPDATE preserved SET amount=123 WHERE id=0")
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source, readOnly: true).readRows("SELECT amount FROM preserved WHERE id=0") { $0.int64(0) }, [123])
        if sink == .unavailable {
            XCTAssertEqual(try Data(contentsOf: logs.appendingPathComponent("owner.marker")), Data("unowned material".utf8))
        }
        return elapsed
    }

    func testDisabledUnavailableAndWriteFailedDiagnosticsPreserveActualMigrationAndNewAccounting() throws {
        for mode in [Sink.off, .on, .unavailable, .writeFailure] { _ = try exercise(mode) }
    }

    func testDiagnosticCostForActualImporterIsProfiledSeparatelyFromUnitCorrectness() throws {
        guard ProcessInfo.processInfo.environment["TOKENBAR_DIAGNOSTIC_PROFILE"] == "1" else {
            throw XCTSkip("Opt-in hosted paired importer profile; correctness runs separately")
        }
        var off: [Double] = [], on: [Double] = []
        // Alternate the first mode, retaining identical input shape and all
        // typed-proof assertions, so warm-up/drift is not assigned to the sink.
        for n in 0..<7 {
            if n.isMultiple(of: 2) { off.append(try exercise(.off, rows: 256)); on.append(try exercise(.on, rows: 256)) }
            else { on.append(try exercise(.on, rows: 256)); off.append(try exercise(.off, rows: 256)) }
        }
        let baseline = off.sorted()[3], enabled = on.sorted()[3]
        let overhead = (enabled - baseline) / baseline
        let json = try JSONSerialization.data(withJSONObject: ["off": off, "on": on,
            "offMedian": baseline, "onMedian": enabled, "relativeOverhead": overhead,
            "scope": "actual Swift importer and router over synthetic typed input; not energy or installed UI"], options: [.sortedKeys])
        print("TOKENBAR_DIAGNOSTIC_PROFILE " + String(decoding: json, as: UTF8.self))
        XCTAssertLessThanOrEqual(overhead, 0.05, "Retain the profile on failure; do not loosen the diagnostic overhead budget")
    }
}
