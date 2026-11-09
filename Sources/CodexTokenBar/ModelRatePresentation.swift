import SwiftUI

/// Current animation contributions, never historical measured TPS or billable usage.
struct ModelRateContribution: Codable, Equatable, Sendable {
    var model: String
    var tokensPerSecond: Double
}

struct ModelRateSlice: Identifiable {
    var model: String
    var tokensPerSecond: Double
    var share: Double
    var id: String { model }
    var color: Color { ModelUsagePresentation.color(for: model) }
}

/// One reader per client. Source identity and sample time survive presentation;
/// model aliases never erase the client that supplied a contribution.
struct ModelRateSource: Codable, Sendable {
    var client: String
    var sourceKey: String
    var observedAt: Double
    var available: Bool
    var rates: [ModelRateContribution]
    var total: Double? = nil
}

struct LiveModelRateRow: Identifiable {
    var client: String
    var model: String
    var rawModels: [String]
    var colorKey: String
    var tokensPerSecond: Double
    var share: Double
    var barFraction: Double
    var id: String { client + ":" + model }
    var label: String { ModelUsagePresentation.label(for: model) }
    var clientLabel: String { SpeedColorOverrides.clientTitle("client:" + client) }
    var color: Color { ModelUsagePresentation.color(for: colorKey) }
    var valueText: String { LiveRateSnapshot.rateDisplayText(tokensPerSecond) }
}

struct LiveModelRateSnapshot {
    var sources: [ModelRateSource]
    var mode: ActivitySpeedDisplayMode
    var grouping: SpeedColorGrouping
    var enabled: Bool
    var available: Bool
    var total: Double
    var rows: [LiveModelRateRow]
    var modelRates: [ModelRateContribution]
    var colorRates: [ModelRateContribution]
    var sourceKey: String { sources.map { $0.client + ":" + $0.sourceKey }.joined(separator: "|") }
    var status: String { !enabled ? "实时速率已关闭" : !available ? "实时速率不可用" : total == 0 ? "等待新增输出" : "当前活动速率" }
    var valueText: String { available ? LiveRateSnapshot.rateDisplayText(total) : "—" }
}

enum ModelRatePresentation {
    static func modelKey(_ raw: String) -> String {
        let key = ModelUsagePresentation.autoReviewUnderlyingModelKey(for: raw) ?? ModelUsagePresentation.key(for: raw)
        let identity = ModelPresentationIdentity.resolve(key)
        return identity.kind == "known" || identity.kind == "source" ? identity.key : key
    }
    /// The numeric normalization used by the ring, legend and activity history.
    /// A reader's reported total is authoritative; missing attribution is unknown.
    static func normalized(_ rates: [ModelRateContribution], total: Double? = nil) -> [ModelRateContribution] {
        var sums: [String: Double] = [:]
        for row in rates where row.tokensPerSecond.isFinite && row.tokensPerSecond > 1e-9 {
            let key = modelKey(row.model)
            sums[key, default: 0] += row.tokensPerSecond
        }
        let known = sums.values.reduce(0, +)
        let target = total ?? known
        guard known.isFinite, target.isFinite, target > 0 else { return [] }
        if known > target { for key in sums.keys { sums[key]! *= target / known } }
        if target - known > 1e-9 { sums["unknown", default: 0] += target - known }
        return sums.keys.sorted().map { .init(model: $0, tokensPerSecond: sums[$0]!) }
    }

    static func snapshot(sources: [ModelRateSource], enabled: Bool, mode: ActivitySpeedDisplayMode,
                         grouping: SpeedColorGrouping) -> LiveModelRateSnapshot {
        var rows: [LiveModelRateRow] = []
        for source in sources.sorted(by: { $0.client < $1.client }) where enabled && source.available {
            for rate in normalized(source.rates, total: source.total) {
                let raw = source.rates.filter {
                    modelKey($0.model) == rate.model
                }.map(\.model)
                rows.append(.init(client: source.client, model: rate.model, rawModels: Array(Set(raw)).sorted(),
                    colorKey: grouping == .client ? "client:" + source.client : rate.model,
                    tokensPerSecond: rate.tokensPerSecond, share: 0, barFraction: 0))
            }
        }
        let total = rows.reduce(0) { $0 + $1.tokensPerSecond }
        if !total.isFinite { rows = [] }
        let safeTotal = total.isFinite ? total : 0
        let maximum = rows.map(\.tokensPerSecond).max() ?? 0
        for index in rows.indices {
            rows[index].share = safeTotal > 0 ? rows[index].tokensPerSecond / safeTotal : 0
            rows[index].barFraction = maximum > 0 ? rows[index].tokensPerSecond / maximum : 0
        }
        rows.sort { ($0.colorKey, $0.model, $0.client) < ($1.colorKey, $1.model, $1.client) }
        return .init(sources: sources, mode: mode, grouping: grouping, enabled: enabled,
            available: enabled && sources.contains(where: \.available), total: safeTotal, rows: rows,
            modelRates: normalized(rows.map { .init(model: $0.model, tokensPerSecond: $0.tokensPerSecond) }),
            colorRates: normalized(rows.map { .init(model: $0.colorKey, tokensPerSecond: $0.tokensPerSecond) }))
    }

    static func slices(_ rates: [ModelRateContribution]) -> [ModelRateSlice] {
        var grouped: [String: Double] = [:]
        for rate in rates where rate.tokensPerSecond.isFinite && rate.tokensPerSecond > 0 {
            grouped[ModelUsagePresentation.key(for: rate.model), default: 0] += rate.tokensPerSecond
        }
        let total = grouped.values.reduce(0, +)
        guard total.isFinite, total > 0 else { return [] }
        return grouped.keys.sorted().map { .init(model: $0, tokensPerSecond: grouped[$0]!, share: grouped[$0]! / total) }
    }

    static func stops(_ rates: [ModelRateContribution]) -> [Gradient.Stop] {
        let slices = slices(rates)
        guard !slices.isEmpty else { return [.init(color: ModelUsagePresentation.color(for: "unknown"), location: 0), .init(color: ModelUsagePresentation.color(for: "unknown"), location: 1)] }
        var edge = 0.0
        return slices.flatMap { slice -> [Gradient.Stop] in
            let start = edge; edge += slice.share
            return [.init(color: slice.color, location: start), .init(color: slice.color, location: min(1, edge))]
        }
    }
}
