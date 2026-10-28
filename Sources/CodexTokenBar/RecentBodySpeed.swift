import Foundation

enum RecentBodySpeed {
    static let lifetime = 1800.0
    static func readings(_ rows: [ModelSpeedSummary], now: Double) -> [ModelSpeedSummary] {
        guard now.isFinite else { return [] }
        return rows.filter { row in
            guard let at = row.lastMeasuredAt, at.isFinite, at <= now, at >= now - lifetime else { return false }
            return row.sampleCount == 1 && row.tokensPerSecond.isFinite && row.tokensPerSecond > 0
                && !row.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && row.model.lowercased() != "unknown"
        }.sorted { ($0.lastMeasuredAt ?? 0) > ($1.lastMeasuredAt ?? 0) }
    }
    static func nextExpiry(_ rows: [ModelSpeedSummary], now: Double) -> Double? {
        readings(rows, now: now).compactMap { $0.lastMeasuredAt.map { $0 + lifetime + 0.002 } }.min()
    }
}
