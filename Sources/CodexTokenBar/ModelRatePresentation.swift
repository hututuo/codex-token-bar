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

enum ModelRatePresentation {
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
