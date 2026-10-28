import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexUsageStagingIntegrityTests: XCTestCase {
    func testNamespacedStageChecksItsFourTablesWithoutScanningSiblingPartitions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try CodexBusinessDatabase(url: root.appendingPathComponent("codex-ledger.sqlite"))
        let stageURL = root.appendingPathComponent("staging/session.sqlite")
        let siblingURL = root.appendingPathComponent("other/usage.sqlite")
        let stageStore = BusinessSQLiteStore(
            containerURL: container.url,
            logicalURL: stageURL,
            module: "exact.swift.stage",
            sourceIdentity: "stage-integrity"
        )
        let siblingStore = BusinessSQLiteStore(
            containerURL: container.url,
            logicalURL: siblingURL,
            module: "fixture",
            sourceIdentity: "sibling-integrity"
        )
        try container.register(stageStore, state: "staging")
        try container.register(siblingStore)
        let stores = [stageStore, siblingStore]
        BusinessSQLiteRoutes.install(stores)
        defer { BusinessSQLiteRoutes.remove(stores) }

        let stage = SQLiteDatabaseDriver(url: stageURL)
        let stageTables = ["manifest", "fingerprints", "events", "chunks"]
        try stage.withConnection { connection in
            for table in stageTables {
                try connection.execute(
                    "CREATE TABLE \(table)(id INTEGER PRIMARY KEY, value INTEGER NOT NULL CHECK(value >= 0));"
                )
                try connection.execute("INSERT INTO \(table)(value) VALUES(0);")
            }
        }
        let sibling = SQLiteDatabaseDriver(url: siblingURL)
        try sibling.execute(
            "CREATE TABLE unrelated_guard(id INTEGER PRIMARY KEY, value INTEGER NOT NULL CHECK(value >= 0));"
        )

        let physical = SQLiteDatabaseDriver(url: container.url, bypassBusinessRoutes: true)
        let siblingTable = SQLiteStoreNamespace.quote(siblingStore.prefix + "unrelated_guard")
        try insertCheckConstraintViolation(
            into: siblingTable,
            using: physical
        )
        let wholeContainerCheck = try physical.readRows("PRAGMA quick_check;") {
            $0.text(0) ?? ""
        }
        XCTAssertNotEqual(wholeContainerCheck, ["ok"], "fixture must make a database-wide check fail")
        XCTAssertTrue(try CodexUsageHistoryIndex.stagingIntegrityIsValid(using: stage))

        for table in stageTables {
            let physicalTable = SQLiteStoreNamespace.quote(stageStore.prefix + table)
            try insertCheckConstraintViolation(into: physicalTable, using: physical)
            XCTAssertFalse(
                try CodexUsageHistoryIndex.stagingIntegrityIsValid(using: stage),
                "stage validation must reject a CHECK violation in \(table)"
            )
            try physical.execute("DELETE FROM \(physicalTable) WHERE value < 0;")
            XCTAssertTrue(try CodexUsageHistoryIndex.stagingIntegrityIsValid(using: stage))
        }
    }

    func testStandaloneStageRetainsWholeDatabaseQuickCheck() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let stageURL = root.appendingPathComponent("stage.sqlite")
        let stage = SQLiteDatabaseDriver(url: stageURL)
        try stage.execute(
            "CREATE TABLE manifest(id INTEGER PRIMARY KEY, value INTEGER NOT NULL CHECK(value >= 0));"
        )
        try stage.execute(
            "CREATE TABLE unrelated_guard(id INTEGER PRIMARY KEY, value INTEGER NOT NULL CHECK(value >= 0));"
        )
        let unrelatedTable = SQLiteStoreNamespace.quote("unrelated_guard")
        try insertCheckConstraintViolation(into: unrelatedTable, using: stage)

        XCTAssertFalse(try CodexUsageHistoryIndex.stagingIntegrityIsValid(using: stage))
    }

    private func insertCheckConstraintViolation(
        into quotedTable: String,
        using database: SQLiteDatabaseDriver
    ) throws {
        try database.withConnection { connection in
            try connection.execute("PRAGMA ignore_check_constraints=ON;")
            try connection.execute("INSERT INTO \(quotedTable)(value) VALUES(-1);")
            try connection.execute("PRAGMA ignore_check_constraints=OFF;")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
