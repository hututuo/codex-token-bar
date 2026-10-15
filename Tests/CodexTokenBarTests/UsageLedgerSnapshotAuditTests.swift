import XCTest
@testable import CodexTokenBar

/// Opt-in audit of an operator-created SQLite backup, never the live index.
final class UsageLedgerSnapshotAuditTests: XCTestCase {
    func testMigrateFrozenSnapshotAndRetainAllNumbersWithZeroSources() throws {
        guard let path=ProcessInfo.processInfo.environment["TOKEN_BAR_AUDIT_INDEX_COPY"] else {
            throw XCTSkip("Requires an explicit isolated SQLite backup copy")
        }
        let url=URL(fileURLWithPath:path).standardizedFileURL
        guard url.path.contains("/runs/20261016-ledger-retention-fix/audit-copy/"),
              !url.path.contains("/Library/"), !url.path.contains("/before/") else {
            XCTFail("Audit accepts only the isolated audit-copy directory");return
        }
        let driver=SQLiteDatabaseDriver(url:url,readOnly:true,createsFileIfMissing:false)
        let before=try driver.readRows("SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM events") { ($0.int(0)!,$0.int(1)!) }.first!
        let index=try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL:url)
        let migrated=try index.compactTotals(todayStart:Date(timeIntervalSince1970:0),before:Date.distantFuture)
        XCTAssertEqual(migrated.totalTokens,before.1)
        let result=try index.synchronize(files:[],sessionID:{ _ in "unused" }) { _,_,_,_,_ in
            XCTFail("Empty-source audit must not parse raw files")
            throw CocoaError(.fileReadUnknown)
        }
        let after=try driver.readRows("SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM events") { ($0.int(0)!,$0.int(1)!) }.first!
        XCTAssertEqual(after.0,before.0);XCTAssertEqual(after.1,before.1)
        XCTAssertEqual(try index.compactTotals(todayStart:Date(timeIntervalSince1970:0),before:Date.distantFuture).totalTokens,before.1)
        let certificate=try XCTUnwrap(index.coverageCertificate())
        XCTAssertEqual(certificate.generation,result.attributionGeneration)
        XCTAssertEqual(certificate.sourceCount,0)
        let report:[String:Any]=["before_events":before.0,"after_events":after.0,"before_tokens":before.1,"after_tokens":after.1,"compact_tokens":migrated.totalTokens,"coverage_generation":certificate.generation,"coverage_source_count":certificate.sourceCount,"inventory_digest":certificate.inventoryDigest]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url.deletingLastPathComponent().appendingPathComponent("swift-audit.json"))
    }
    func testMigrateFrozenRetentionSnapshotAndRetainSamplesWithZeroSources() throws {
        guard let path=ProcessInfo.processInfo.environment["TOKEN_BAR_AUDIT_RETENTION_COPY"] else {
            throw XCTSkip("Requires an explicit isolated retention SQLite backup copy")
        }
        let url=URL(fileURLWithPath:path).standardizedFileURL
        guard url.path.contains("/runs/20261016-ledger-retention-fix/audit-copy/"),
              !url.path.contains("/Library/"), !url.path.contains("/before/") else {
            XCTFail("Audit accepts only the isolated audit-copy directory");return
        }
        let driver=SQLiteDatabaseDriver(url:url,readOnly:true,createsFileIfMissing:false)
        let before=try driver.readRows("SELECT COUNT(*) FROM retention_pairs") { $0.int(0)! }.first!
        let database=try CacheRetentionDatabase(url:url)
        let snapshot=try database.snapshot(scope:.init(),now:Date())
        try database.removeMissing([])
        let reopened=try CacheRetentionDatabase(url:url)
        let retained=try reopened.snapshot(scope:.init(),now:Date())
        XCTAssertEqual(retained.points,snapshot.points)
        XCTAssertEqual(retained.ownRoundCount,snapshot.ownRoundCount)
        let after=try driver.readRows("SELECT COUNT(*) FROM retention_all_pairs") { $0.int(0)! }.first!
        XCTAssertEqual(after,before)
        let report:[String:Any]=["before_pair_facts":before,"after_pair_facts":after,
            "before_chart_points":snapshot.points.count,"after_chart_points":retained.points.count,
            "before_own_rounds":snapshot.ownRoundCount,"after_own_rounds":retained.ownRoundCount]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url.deletingLastPathComponent().appendingPathComponent("retention-swift-audit.json"))
    }

}
