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
