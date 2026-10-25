import Foundation
import XCTest
@testable import CodexTokenBar

final class BodySpeedTrendStoreTests: XCTestCase {
    func testWeightedSparseBucketsRemainModelSpecificAndReingestIsIdempotent() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = 1_728_000.0
        let now = base + 86_400
        let values = [
            body(id: "a", model: "model-a", endedAt: base + 60, tokens: 100, duration: 2),
            body(id: "b", model: "model-a", endedAt: base + 360, tokens: 300, duration: 6),
            body(id: "c", model: "model-a", endedAt: base + 1_860, tokens: 50, duration: 1),
            body(id: "d", model: "model-b", endedAt: base + 7_260, tokens: 200, duration: 4)
        ]
        try store.ingest(samples: values + values, now: now)

        let fiveMinute = try store.read(now: now, days: 1)
        XCTAssertEqual(fiveMinute.count, 4)
        XCTAssertTrue(fiveMinute.allSatisfy { $0.tokensPerSecond == 50 })
        XCTAssertEqual(Set(fiveMinute.map(\.model)), ["model-a", "model-b"])

        let thirtyMinute = try store.read(now: now, days: 7)
        XCTAssertEqual(thirtyMinute.count, 3)
        let combined = try XCTUnwrap(thirtyMinute.first { $0.model == "model-a" && $0.bucketStart == Int64(base) })
        XCTAssertEqual(combined.outputTokens, 400)
        XCTAssertEqual(combined.durationSeconds, 8)
        XCTAssertEqual(combined.sampleCount, 2)
        XCTAssertEqual(combined.tokensPerSecond, 50)

        let twoHour = try store.read(now: now, days: 30)
        XCTAssertEqual(twoHour.count, 2)
    }

    func testBodyQualityControlsTrendButLowQualitySamplesStayInHistory() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 2_000_000.0 + 60
        let small = body(id: "small", model: "model-a", endedAt: now, tokens: 3, duration: 1)
        let warned = body(
            id: "warned", model: "model-a", endedAt: now + 300,
            tokens: 100, duration: 2, warning: "network pause"
        )
        let unknown = body(id: "unknown", model: "unknown", endedAt: now + 600, tokens: 100, duration: 2)
        let future = body(id: "future", model: "model-a", endedAt: now + 3_600, tokens: 100, duration: 2)
        var nonfinite = body(id: "nonfinite", model: "model-a", endedAt: now + 600, tokens: 100, duration: 2)
        nonfinite.tokensPerSecond = .infinity

        try store.ingest(samples: [small, warned, unknown, future, nonfinite], now: now + 600)

        let trend = try store.read(now: now + 600, days: 1)
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend[0].outputTokens, 3)
        XCTAssertEqual(trend[0].tokensPerSecond, 3)
        let history = try store.loadSamples(now: now + 600)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.first?.id, "small")
        XCTAssertTrue(history.contains { $0.id == "warned" && !$0.bodyQuality.included })
        XCTAssertTrue(history.contains { $0.id == "unknown" })
    }

    func testRawExpiryDoesNotDeleteNinetyDayTrend() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 3_000_000.0 + 60
        let value = body(id: "history", model: "model-a", endedAt: now, tokens: 100, duration: 2)
        try store.ingest(samples: [value], now: now, retentionDays: 15)
        XCTAssertEqual(try store.retentionDays(), 15)

        let later = now + 20 * 86_400
        try store.ingest(samples: [], now: later, retentionDays: 15)
        XCTAssertTrue(try store.loadSamples(now: later, retentionDays: 15).isEmpty)
        let trend = try store.read(now: later, days: 30)
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend[0].sampleCount, 1)
    }

    func testSameIDCorrectionMovesTheWeightedContribution() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 4_000_000.0 + 60
        let old = body(id: "same", model: "model-a", endedAt: now, tokens: 100, duration: 2)
        let corrected = body(id: "same", model: "model-b", endedAt: now, tokens: 200, duration: 4)

        try store.ingest(samples: [old], now: now)
        try store.ingest(samples: [corrected], now: now)

        let points = try store.read(now: now, days: 1)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].model, "model-b")
        XCTAssertEqual(points[0].outputTokens, 200)
        XCTAssertEqual(points[0].tokensPerSecond, 50)
    }

    private func makeStore() throws -> (BodySpeedTrendStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try BodySpeedTrendStore(url: directory.appendingPathComponent("speed-trend.sqlite"))
        return (store, directory)
    }

    private func body(
        id: String,
        model: String,
        endedAt: Double,
        tokens: Int,
        duration: Double,
        warning: String? = nil
    ) -> ObservedSpeedSample {
        ObservedSpeedSample(
            id: id,
            threadID: "thread",
            turnID: "turn",
            itemID: id,
            model: model,
            startedAt: endedAt - duration,
            endedAt: endedAt,
            outputTokens: tokens,
            outputCharacters: tokens,
            outputBytes: tokens,
            chunkCount: 4,
            durationSeconds: duration,
            tokensPerSecond: Double(tokens) / duration,
            confidence: "medium",
            networkWarning: warning,
            source: "test",
            measurementKind: "completed_body",
            tokenizer: "o200k_base",
            bodyPhase: "final_answer",
            qualityReason: nil
        )
    }
}

extension BodySpeedTrendStoreTests {
    func testDistributionUsesBucketQuantilesRatherThanWeightedMeanAndPreservesStoredTotals() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = 1_728_000.0
        var samples: [ObservedSpeedSample] = []
        for (i, rate) in [10, 20, 40, 100].enumerated() {
            let duration = i == 0 ? 10.0 : 2.0
            for j in 0..<2 {
                samples.append(body(id: "\(i)/\(j)", model: "sol", endedAt: base + Double(i * 300 + 30 + j),
                                    tokens: Int(Double(rate) * duration), duration: duration))
            }
        }
        // A different model's sparse buckets cannot satisfy Sol's distribution gate.
        samples.append(body(id: "other", model: "luna", endedAt: base + 30, tokens: 200, duration: 2))
        try store.ingest(samples: samples, now: base + 1_800)
        let stored = try store.read(now: base + 1_800, days: 1)
        let values = try store.readDistribution(now: base + 1_800, days: 1)
        let p = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(p.lowerQuartile, 17.5)
        XCTAssertEqual(p.median, 30)
        XCTAssertEqual(p.upperQuartile, 55)
        XCTAssertEqual(p.bucketCount, 4)
        XCTAssertEqual(p.sampleCount, 8)
        XCTAssertEqual(p.bucketEnd, Int64(base + 1_800))
        XCTAssertEqual(p.isPartial, false)
        XCTAssertNotEqual(p.median, p.tokensPerSecond)
        XCTAssertEqual(try store.read(now: base + 1_800, days: 1), stored)
    }

    func testDistributionExcludesActiveFiveMinuteBucketAndReportsPartialDisplayInterval() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = 1_728_000.0
        var samples = (0..<3).flatMap { i in
            (0..<2).map { j in body(id: "\(i)/\(j)", model: "sol", endedAt: base + Double(i * 300 + 30 + j), tokens: 80, duration: 2) }
        }
        samples.append(body(id: "active", model: "sol", endedAt: base + 910, tokens: 800, duration: 2))
        try store.ingest(samples: samples, now: base + 930)
        for days in [1, 7, 30] {
            let points = try store.readDistribution(now: base + 930, days: days)
            let p = try XCTUnwrap(points.first)
            XCTAssertEqual(p.sampleCount, 6)
            XCTAssertEqual(p.median, 40)
            XCTAssertEqual(p.bucketEnd, Int64(base + 900))
            XCTAssertEqual(p.isPartial, true)
        }
    }

    func testDistributionRequiresThreeNonemptyBucketsAndSixSamples() throws {
        let base: Int64 = 1_728_000
        func p(_ i: Int64, _ n: Int64) -> BodySpeedTrendPoint {
            .init(bucketStart: base + i * 300, model: "sol", outputTokens: n * 100,
                  durationSeconds: Double(n) * 2, sampleCount: n, tokensPerSecond: 50)
        }
        XCTAssertTrue(try BodySpeedTrendStore.distributions([p(0, 5), p(1, 5)], width: 1800, completedThrough: base + 1800).isEmpty)
        XCTAssertTrue(try BodySpeedTrendStore.distributions([p(0, 1), p(1, 1), p(2, 1)], width: 1800, completedThrough: base + 1800).isEmpty)
        XCTAssertEqual(try BodySpeedTrendStore.distributions([p(0, 2), p(1, 2), p(2, 2)], width: 1800, completedThrough: base + 1800).count, 1)
    }
}
