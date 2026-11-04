import Foundation
import XCTest
@testable import CodexTokenBar

final class SQLiteStoreBindingCacheTests: XCTestCase {
    func testRepeatedQueriesRemainFencedWhenTemporaryAndOwnedIdentifiersChange() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("binding-context-not-opened")
        let store = BusinessSQLiteStore(containerURL: base.appendingPathComponent("codex-ledger.sqlite"),
            logicalURL: base.appendingPathComponent("index.sqlite"), module: "exact.swift", sourceIdentity: "fixture")
        let binding = SQLiteStoreBinding(store: store, names: ["events"])
        let query = "SELECT value FROM events WHERE value=?"
        let owned = try binding.sql(query)
        XCTAssertTrue(owned.contains(store.prefix + "events"))
        for _ in 0..<20 { XCTAssertEqual(try binding.sql(query), owned) }
        let temporaryQuery = "SELECT value FROM temp.work WHERE value=?"
        XCTAssertThrowsError(try binding.sql(temporaryQuery))
        _ = try binding.sql("CREATE TEMP TABLE work(value INTEGER)")
        let temporary = try binding.sql(temporaryQuery)
        XCTAssertNotEqual(temporary, owned)
        XCTAssertEqual(try binding.sql(temporaryQuery), temporary)
        XCTAssertEqual(try binding.sql(query), owned)
        binding.namespace.temporaryObjectNames.remove("work")
        XCTAssertThrowsError(try binding.sql(temporaryQuery), "A cached TEMP query cannot outlive its admitted identifier")
        XCTAssertEqual(try binding.sql(query), owned)
        binding.namespace.objectNames.remove("events")
        XCTAssertThrowsError(try binding.sql(query), "A cached query cannot grant access after its owner context changes")
        XCTAssertThrowsError(try binding.sql("SELECT * FROM main.tb_stores"))
        XCTAssertThrowsError(try binding.sql("SELECT * FROM other_store.events"))
    }
}
