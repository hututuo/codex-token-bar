import Foundation
import XCTest
@testable import CodexTokenBar

/// New recovery work must not revoke access to a previously verified generation.
/// Uses the production migration/router, not a direct-SQL replacement for it.
final class PublishedLedgerAdmissionTests: XCTestCase {
    override func tearDown() {
        BusinessSQLiteRoutes.deactivate()
        super.tearDown()
    }

    private func readyLedger() throws -> (URL, BusinessDatabaseMigration.Configuration, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("published-ledger-admission-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let c = BusinessDatabaseMigration.Configuration(
            container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support,
            exact: root.appendingPathComponent("exact", isDirectory: true),
            legacyExact: root.appendingPathComponent("legacy", isDirectory: true)
        )
        let quota = support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota, bypassBusinessRoutes: true).execute(
            "CREATE TABLE preserved(id INTEGER PRIMARY KEY, amount INTEGER); INSERT INTO preserved VALUES(42,123)"
        )
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        // Include a post-upgrade record that an old backup cannot replace.
        try SQLiteDatabaseDriver(url: quota).execute("INSERT INTO preserved VALUES(43,789)")
        BusinessSQLiteRoutes.deactivate()
        return (root, c, quota)
    }

    private func addLateSource(_ c: BusinessDatabaseMigration.Configuration) throws -> URL {
        let late = c.support.appendingPathComponent("body-speed-late.sqlite")
        try SQLiteDatabaseDriver(url: late, bypassBusinessRoutes: true).execute(
            "CREATE TABLE preserved(id INTEGER PRIMARY KEY, amount INTEGER); INSERT INTO preserved VALUES(77,456)"
        )
        return late
    }

    private func assertPriorGenerationAvailable(
        _ c: BusinessDatabaseMigration.Configuration, quota: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let raw = SQLiteDatabaseDriver(url: c.container, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try raw.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") {
            $0.text(0)
        }.first ?? nil, "ready", file: file, line: line)
        // Assert routing before any access can accidentally reopen the old file.
        let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: quota), file: file, line: line)
        XCTAssertEqual(store.containerURL, c.container, file: file, line: line)
        let published = SQLiteDatabaseDriver(url: quota, readOnly: true, createsFileIfMissing: false)
        XCTAssertEqual(try published.readRows("SELECT amount FROM preserved ORDER BY id") {
            $0.int(0)
        }, [123, 789], file: file, line: line)
        let original = SQLiteDatabaseDriver(url: quota, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try original.readRows("SELECT amount FROM preserved ORDER BY id") {
            $0.int(0)
        }, [123], "The original source remains unchanged", file: file, line: line)
    }

    func testLowSpaceLateImportDoesNotHidePreviouslyPublishedLedger() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        // An operation may report deferred/failed; published availability is independent.
        do { try BusinessDatabaseMigration.migrate(c, availableBytes: 0) } catch {}
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT amount FROM preserved") { $0.int(0) }, [456])
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try assertPriorGenerationAvailable(c, quota: quota)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true).readRows(
            "SELECT amount FROM preserved"
        ) { $0.int(0) }, [456])
    }

    func testInterruptedLateImportPreservesPublishedAccessAndDoesNotDuplicateOnRetry() throws {
        let (_, c, quota) = try readyLedger()
        let late = try addLateSource(c)
        enum Interrupted: Error { case beforeActivation }
        do {
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32,
                beforeActivation: { throw Interrupted.beforeActivation })
        } catch {}
        try assertPriorGenerationAvailable(c, quota: quota)
        for _ in 0..<3 {
            BusinessSQLiteRoutes.deactivate()
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
            try assertPriorGenerationAvailable(c, quota: quota)
            XCTAssertEqual(try SQLiteDatabaseDriver(url: late, readOnly: true).readRows(
                "SELECT amount FROM preserved"
            ) { $0.int(0) }, [456])
        }
    }
}
