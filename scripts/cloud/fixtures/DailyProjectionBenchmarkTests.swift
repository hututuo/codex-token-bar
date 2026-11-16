import Darwin
import XCTest
@testable import CodexTokenBar

/// Injected unchanged into two exact revisions on one hosted runner. Uses only
/// the stable ledger API and synthetic rows, never the user's database.
final class DailyProjectionBenchmarkTests: XCTestCase {
    func testIdenticalSyntheticDailyProjection() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["DAILY_BENCHMARK_ROWS"] ?? "3650")!
        XCTAssertTrue([3650, 36500].contains(count))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-projection-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let now = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            .addingTimeInterval(3600)
        let events = (0..<count).map { index in
            ClientUsageEvent(client: .claudeCode, eventID: "benchmark-\(index)", sessionID: "synthetic",
                model: "claude-opus-5", timestamp: Calendar.current.date(byAdding: .day, value: -(index % 365), to: now)!,
                inputTokens: 1000, outputTokens: 100, cacheReadTokens: 900, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest(events)

        func peakBytes() -> Int64 {
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            // Darwin ru_maxrss is bytes, and is a cumulative process high-water
            // mark. It includes XCTest and fixture setup, not only the query.
            return Int64(usage.ru_maxrss)
        }
        func read(_ phase: String) throws -> [ClientTrendBucket] {
            let before = peakBytes()
            let start = DispatchTime.now().uptimeNanoseconds
            let rows = try ledger.dailyBuckets(now: now)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let after = peakBytes()
            let record: [String: Any] = [
                "source": environment["DAILY_BENCHMARK_SOURCE"] ?? "",
                "trial": Int(environment["DAILY_BENCHMARK_TRIAL"] ?? "0")!,
                "fixtureRows": count, "phase": phase, "milliseconds": elapsed,
                "resultRows": rows.count, "requests": rows.reduce(0) { $0 + $1.requests },
                "tokens": rows.reduce(Int64(0)) { $0 + $1.tokens },
                "processPeakBytesBefore": before, "processPeakBytesAfter": after,
                "processPeakGrowthBytes": max(0, after - before)
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("DAILY_PROJECTION_BENCHMARK " + String(decoding: data, as: UTF8.self))
            return rows
        }

        let first = try read("first")
        let cached = try read("unchanged")
        XCTAssertEqual(first, cached)
        XCTAssertEqual(first.count, 365)
        XCTAssertEqual(first.reduce(0) { $0 + $1.requests }, count)
        XCTAssertEqual(first.reduce(Int64(0)) { $0 + $1.tokens }, Int64(count * 1100))
        var changed = events[0]
        changed.outputTokens += 100
        _ = try ledger.ingest([changed])
        let updated = try read("incremental")
        XCTAssertEqual(updated.reduce(0) { $0 + $1.requests }, count)
        XCTAssertEqual(updated.reduce(Int64(0)) { $0 + $1.tokens }, Int64(count * 1100 + 100))
        XCTAssertEqual(Array(first.dropLast()), Array(updated.dropLast()))
    }
}
