import Foundation
import SwiftUI

enum ActivityRateUnit: String, CaseIterable, Sendable {
    case tokens = "tok/s", yuan = "CN 元/s"
    static let preferenceKey = "activityRateDisplayUnit"
    static let exchangeRateKey = "activityRateCNYPerUSD"
    static let defaultExchangeRate = 7.2
    static func safeExchangeRate(_ value: Double) -> Double {
        value.isFinite && value >= 0.1 && value <= 100 ? value : defaultExchangeRate
    }
    func value(total: Double, rates: [ModelRateContribution], exchangeRate: Double) -> Double? {
        guard total.isFinite, total >= 0 else { return nil }
        if self == .tokens { return total }
        if total == 0 { return 0 }
        var represented = 0.0, usd = 0.0
        for rate in rates where rate.tokensPerSecond.isFinite && rate.tokensPerSecond > 0 {
            guard let quote = StandardAPIPriceSchedule.currentQuote(for: rate.model) else { return nil }
            represented += rate.tokensPerSecond
            usd += rate.tokensPerSecond * quote.outputUSDPerMillion / 1_000_000
        }
        guard represented >= total - max(0.05, total * 0.001) else { return nil }
        return usd * Self.safeExchangeRate(exchangeRate)
    }
    func text(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if self == .yuan, value > 0, value < 0.0001 { return "<0.0001" }
        return String(format: self == .tokens ? "%.1f" : "%.4f", value)
    }
}

struct ActivityRateHistoryPoint: Equatable, Identifiable {
    var start: TimeInterval
    var modelRates: [ModelRateContribution]
    var id: TimeInterval { start }
    var total: Double { modelRates.reduce(0) { $0 + $1.tokensPerSecond } }
}

/// Bounded, local display history; no content, database writes or extra timer.
/// Five-second time-weighted means. Missing polling intervals remain gaps.
@MainActor
final class LiveActivityRateHistory: ObservableObject {
    @Published private(set) var points: [ActivityRateHistoryPoint] = []
    private struct Bucket { var seconds = 0.0; var tokens: [String: Double] = [:] }
    private var buckets: [Int64: Bucket] = [:]
    private var previousAt: Double?
    private var previousRates: [ModelRateContribution] = []
    private var lastPublishedBucket: Int64?
    func clear() {
        buckets.removeAll(); previousAt = nil; previousRates = []; lastPublishedBucket = nil
        if !points.isEmpty { points = [] }
    }
    func record(now: Double, rates: [ModelRateContribution]) {
        guard now.isFinite, now >= 0 else { return }
        if let previousAt, now < previousAt { clear() }
        if let previousAt {
            var cursor = previousAt
            let end = min(now, previousAt + 2)
            while cursor < end {
                let key = Int64(floor(cursor / 5)) * 5
                let stop = min(end, Double(key + 5))
                let duration = stop - cursor
                var bucket = buckets[key] ?? Bucket()
                bucket.seconds += duration
                for rate in previousRates {
                    bucket.tokens[rate.model, default: 0] += rate.tokensPerSecond * duration
                }
                buckets[key] = bucket
                cursor = stop
            }
        }
        previousAt = now
        let finiteRates = rates.filter { $0.tokensPerSecond.isFinite && $0.tokensPerSecond > 0 }
        previousRates = Array(finiteRates.prefix(63))
        if finiteRates.count > 63 {
            previousRates.append(.init(model: "unknown", tokensPerSecond: finiteRates.dropFirst(63).reduce(0) { $0 + $1.tokensPerSecond }))
        }
        let current = Int64(floor(now / 5)) * 5
        guard lastPublishedBucket != current else { return }
        lastPublishedBucket = current
        buckets = buckets.filter { Double($0.key) >= now - 1800 }
        points = buckets.keys.sorted().filter { $0 < current }.suffix(360).compactMap { key in
            guard let bucket = buckets[key], bucket.seconds > 0 else { return nil }
            return ActivityRateHistoryPoint(start: Double(key), modelRates: bucket.tokens.keys.sorted().map {
                ModelRateContribution(model: $0, tokensPerSecond: bucket.tokens[$0]! / bucket.seconds)
            })
        }
    }
}
