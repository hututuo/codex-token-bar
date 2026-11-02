import Foundation
import XCTest
@testable import CodexTokenBar

final class SQLiteWriteMetricsTests: XCTestCase {
    func testActualOuterWriteTransactionsAreMeasuredAcrossTemporaryPathAliases() throws {
        #if !DEBUG
        throw XCTSkip("Write-lock telemetry is absent from release builds")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("write-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { _ = SQLiteWriteMetrics.end(); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.sqlite")
        let driver = SQLiteDatabaseDriver(url: url)
        try driver.execute("CREATE TABLE facts(value INTEGER)")
        let sqlitePath = try XCTUnwrap(driver.readRows("PRAGMA database_list") { $0.text(2) }.first ?? nil)
        let unrelated = SQLiteDatabaseDriver(url: root.appendingPathComponent("unrelated.sqlite"))
        try unrelated.execute("CREATE TABLE facts(value INTEGER)")
        for alias in [url, URL(fileURLWithPath: sqlitePath)] {
            SQLiteWriteMetrics.begin(at: alias)
            try driver.transaction { outer in
                try outer.execute("INSERT INTO facts VALUES(11)")
                try outer.transaction { try $0.execute("INSERT INTO facts VALUES(12)") }
                try outer.readTransaction { _ = try $0.readRows("SELECT COUNT(*) FROM facts") { $0.int(0) } }
            }
            try unrelated.transaction { try $0.execute("INSERT INTO facts VALUES(99)") }
            let metrics = SQLiteWriteMetrics.end()
            XCTAssertEqual(metrics.count, 1, "Only the real outer writer on this physical A is counted")
            XCTAssertGreaterThan(metrics.maximumSeconds, 0)
            XCTAssertEqual(metrics.totalSeconds, metrics.maximumSeconds)
        }
        #endif
    }
}
