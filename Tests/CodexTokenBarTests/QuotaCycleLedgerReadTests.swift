import XCTest
@testable import CodexTokenBar

final class QuotaCycleLedgerReadTests: XCTestCase {
    private func fixture(_ body: (CodexUsageHistoryIndex, SQLiteDatabaseDriver) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("exact.sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
        let driver = SQLiteDatabaseDriver(url: url)
        try driver.withConnection { db in
            try db.execute("""
                INSERT INTO sources(source_id,path,session_id,size_bytes,modified_at,content_probe,last_seen_generation)
                VALUES(1,'fixture','019fd613-7f7e-7fe3-ab63-452b6064371c',0,0,'','fixture');
                INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,
                    output_tokens,reasoning_output_tokens,model)
                VALUES(1,1,100.1,110,100,80,10,0,'gpt-6.1-sol'),
                      (1,2,100.5,220,200,160,20,0,'gpt-6-luna'),
                      (1,3,101.0,330,300,240,30,0,'gpt-6.1-sol');
                """)
        }
        try body(index, driver)
    }

    func testEmptyIntervalNeedsCurrentCoverageReceiptAndLateCoverageCanRepairIt() throws {
        try fixture { index, driver in
            let from = Date(timeIntervalSince1970: 200), end = Date(timeIntervalSince1970: 300)
            XCTAssertEqual(try index.cycleConsumption(after: from, through: end), .unknown)
            let state = try index.attributionState()
            func certify(_ at: Double) throws {
                try driver.withConnection { db in
                    try UsageIndexCoverageCertificate.publish(epoch: state.provenanceEpoch, generation: state.generation,
                        scanID: "fixture", observedAt: Date(timeIntervalSince1970: at), sourceCount: 1, on: db)
                }
            }
            try certify(299)
            XCTAssertEqual(try index.cycleConsumption(after: from, through: end), .unknown)
            try certify(300)
            XCTAssertEqual(try index.cycleConsumption(after: from, through: end), .absent)
            try driver.execute("UPDATE schema_meta SET value='1' WHERE key='attribution_current_scan_unsafe_cause'")
            XCTAssertEqual(try index.cycleConsumption(after: from, through: end), .unknown)
        }
    }

    func testConsumptionUsesOpenStartClosedEndAndNeverInfersAbsenceFromMissingReceipt() throws {
        try fixture { index, _ in
            func evidence(_ start: Double, _ end: Double) throws -> QuotaCycleConsumption {
                try index.cycleConsumption(after: Date(timeIntervalSince1970: start), through: Date(timeIntervalSince1970: end))
            }
            XCTAssertEqual(try evidence(99, 100.1), .present)
            XCTAssertEqual(try evidence(100.1, 100.4), .unknown)
            XCTAssertEqual(try evidence(100.4, 100.5), .present)
        }
    }

    func testExactCycleCutWithinASecondPreservesTokensPricesAndEveryField() throws {
        try fixture { index, driver in
            let state = try index.attributionState()
            func usage(_ start: Double, _ end: Double) throws -> QuotaCycleUsage {
                QuotaCycleUsage(exactEvents: try index.cycleExactUsage(provenanceEpoch: state.provenanceEpoch,
                    generation: state.generation, from: Date(timeIntervalSince1970: start), before: Date(timeIntervalSince1970: end)))
            }
            let whole = try usage(99, 102), old = try usage(99, 100.5), current = try usage(100.5, 102)
            XCTAssertEqual(whole.total.totalTokens, 660)
            XCTAssertEqual(old.total.totalTokens, 110)
            XCTAssertEqual(current.total.totalTokens, 550)
            XCTAssertEqual([old.total, current.total].combined, whole.total)
            XCTAssertEqual(old.unassignedTokens + current.unassignedTokens, 0)
            XCTAssertEqual(current.rows.count, 2)
            // Publishing a duplicate exclusion changes only the projection.
            try driver.execute("INSERT INTO usage_ledger_duplicates VALUES(1,2,0)")
            XCTAssertEqual(try usage(99, 102).total.totalTokens, 440)
            let physical = try driver.readRows("SELECT COUNT(*) FROM events") { $0.int(0) }.first!
            XCTAssertEqual(physical, 3)
        }
    }
}
