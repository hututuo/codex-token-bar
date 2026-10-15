import Foundation
import XCTest
@testable import CodexTokenBar

final class CacheRetentionRealDataTests: XCTestCase {
    func testFrozenCodexHistoryMatchesQualifiedRetentionBaseline() async throws {
        guard let rawHome = ProcessInfo.processInfo.environment["TOKENBAR_RETENTION_FIXTURE_HOME"],
              !rawHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set TOKENBAR_RETENTION_FIXTURE_HOME to run the frozen-history regression.")
        }

        let home = URL(fileURLWithPath: rawHome, isDirectory: true).standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("archived_sessions").path))
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-retention-real-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let databaseURL = temporaryDirectory.appendingPathComponent("cache-retention.sqlite")
        let engine = try CacheRetentionEngine(source: source, databaseURL: databaseURL)

        let failures = try await engine.synchronize(progress: { _, _ in })
        let snapshot = try await engine.snapshot(scope: .init())
        let analysis = snapshot.analysis
        let p95 = analysis.p95Microseconds.map { String($0) } ?? "nil"
        let drop = analysis.dropMicroseconds.map { String($0) } ?? "nil"
        print("CACHE_RETENTION_REAL_DATA failures=\(failures) sources=\(snapshot.sourceCount) own_rounds=\(snapshot.ownRoundCount) eligible=\(analysis.count) high=\(analysis.highCount) p95_us=\(p95) drop_us=\(drop)")

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(analysis.count, 3_103)
        XCTAssertEqual(analysis.highCount, 2_162)
        XCTAssertEqual(analysis.p95Microseconds, 1_564_000_000)
        XCTAssertEqual(analysis.dropMicroseconds, 2_895_000_000)
    }
}
