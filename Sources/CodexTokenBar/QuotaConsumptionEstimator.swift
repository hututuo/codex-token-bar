import Foundation

enum QuotaConsumptionConfidence: Equatable {
    case measured
    case insufficientQuotaMovement
    case noTokenUsage
}

enum OfficialAPIPriceModel: String, CaseIterable, Identifiable {
    case gpt55
    case gpt54
    case gpt54Mini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpt55: "GPT-5.5"
        case .gpt54: "GPT-5.4"
        case .gpt54Mini: "GPT-5.4 mini"
        }
    }

    var inputUSDPerMillion: Double {
        switch self {
        case .gpt55: 5.00
        case .gpt54: 2.50
        case .gpt54Mini: 0.75
        }
    }

    var cachedInputUSDPerMillion: Double {
        switch self {
        case .gpt55: 0.50
        case .gpt54: 0.25
        case .gpt54Mini: 0.075
        }
    }

    var outputUSDPerMillion: Double {
        switch self {
        case .gpt55: 30.00
        case .gpt54: 15.00
        case .gpt54Mini: 4.50
        }
    }
}

enum QuotaConsumptionPriceCard: Equatable {
    case officialAPI(OfficialAPIPriceModel)

    var title: String {
        switch self {
        case .officialAPI(let model):
            "官方 API · \(model.title)"
        }
    }

    func costUSD(for breakdown: TokenCacheBreakdown) -> Double {
        switch self {
        case .officialAPI(let model):
            let cachedInput = max(0, min(breakdown.cachedInputTokens, breakdown.inputTokens))
            let uncachedInput = max(0, breakdown.inputTokens - cachedInput)
            return (
                Double(uncachedInput) * model.inputUSDPerMillion
                + Double(cachedInput) * model.cachedInputUSDPerMillion
                + Double(breakdown.outputTokens) * model.outputUSDPerMillion
            ) / 1_000_000
        }
    }
}

struct QuotaConsumptionEstimate: Equatable {
    let selectedCostUSD: Double
    let impliedWindowBudgetUSD: Double?
    let quotaDropPercent: Double
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let calls: Int
    let cacheHitRate: Double
    let confidence: QuotaConsumptionConfidence
}

enum QuotaConsumptionEstimator {
    static func estimate(
        breakdown: TokenCacheBreakdown,
        quotaStartPercent: Double?,
        quotaEndPercent: Double?,
        priceCard: QuotaConsumptionPriceCard
    ) -> QuotaConsumptionEstimate {
        estimate(
            breakdown: breakdown,
            quotaDropPercent: max((quotaStartPercent ?? 0) - (quotaEndPercent ?? 0), 0),
            priceCard: priceCard
        )
    }

    static func estimate(
        breakdown: TokenCacheBreakdown,
        quotaDropPercent: Double?,
        priceCard: QuotaConsumptionPriceCard
    ) -> QuotaConsumptionEstimate {
        let selectedCost = priceCard.costUSD(for: breakdown)
        let drop = max(quotaDropPercent ?? 0, 0)
        let confidence: QuotaConsumptionConfidence
        let impliedBudget: Double?

        if breakdown.totalTokens <= 0 && breakdown.inputTokens <= 0 && breakdown.outputTokens <= 0 {
            confidence = .noTokenUsage
            impliedBudget = nil
        } else if drop <= 0.0001 {
            confidence = .insufficientQuotaMovement
            impliedBudget = nil
        } else {
            confidence = .measured
            impliedBudget = selectedCost / (drop / 100)
        }

        return QuotaConsumptionEstimate(
            selectedCostUSD: selectedCost,
            impliedWindowBudgetUSD: impliedBudget,
            quotaDropPercent: drop,
            inputTokens: breakdown.inputTokens,
            cachedInputTokens: breakdown.cachedInputTokens,
            outputTokens: breakdown.outputTokens,
            calls: breakdown.calls,
            cacheHitRate: breakdown.cacheHitRate,
            confidence: confidence
        )
    }
}

struct QuotaConsumptionSelection: Equatable {
    let startIndex: Int
    let endIndex: Int
    let bucketCount: Int
    let startDate: Date
    let endDate: Date
    let priceCard: QuotaConsumptionPriceCard
    let breakdown: TokenCacheBreakdown
    let fiveHour: QuotaConsumptionEstimate
    let sevenDay: QuotaConsumptionEstimate
}

extension QuotaConsumptionSelection {
    var sevenDayToFiveHourBudgetRatio: Double? {
        guard let fiveHourBudget = fiveHour.impliedWindowBudgetUSD,
              let sevenDayBudget = sevenDay.impliedWindowBudgetUSD,
              fiveHourBudget > 0 else { return nil }
        return sevenDayBudget / fiveHourBudget
    }

    var hasDivergentBudgetRatio: Bool {
        guard let ratio = sevenDayToFiveHourBudgetRatio else { return false }
        return ratio < 4.5 || ratio > 7.5
    }
}

struct RecentChartConsumptionSelectionState: Equatable {
    private(set) var startIndex: Int?
    private(set) var fixedEndIndex: Int?

    mutating func click(index: Int, validCount: Int) {
        guard validCount > 0, (0..<validCount).contains(index) else { return }
        if startIndex == nil || fixedEndIndex != nil {
            startIndex = index
            fixedEndIndex = nil
        } else {
            fixedEndIndex = index
        }
    }

    mutating func reset() {
        startIndex = nil
        fixedEndIndex = nil
    }

    mutating func clamp(validCount: Int) {
        guard validCount > 0 else {
            reset()
            return
        }
        if let startIndex, !(0..<validCount).contains(startIndex) {
            reset()
            return
        }
        if let fixedEndIndex, !(0..<validCount).contains(fixedEndIndex) {
            self.fixedEndIndex = nil
        }
    }

    func activeEndIndex(hoveredIndex: Int?, fallbackEndIndex: Int) -> Int? {
        fixedEndIndex ?? hoveredIndex ?? startIndex ?? fallbackEndIndex
    }
}

extension RecentChartPreparedData {
    func quotaConsumptionSelection(
        startIndex: Int,
        endIndex: Int,
        priceCard: QuotaConsumptionPriceCard
    ) -> QuotaConsumptionSelection? {
        guard !bins.isEmpty else { return nil }
        let lower = max(0, min(startIndex, endIndex))
        let upper = min(bins.count - 1, max(startIndex, endIndex))
        guard lower <= upper,
              let start = bins[safe: lower]?.start,
              let endStart = bins[safe: upper]?.start else { return nil }

        let breakdown = (lower...upper)
            .map { cacheBreakdowns[safe: $0] ?? .empty }
            .combined
        let fiveHourDrop = cumulativeQuotaDrop(fiveHourRemainingPercents, lower: lower, upper: upper)
        let sevenDayDrop = cumulativeQuotaDrop(sevenDayRemainingPercents, lower: lower, upper: upper)

        return QuotaConsumptionSelection(
            startIndex: lower,
            endIndex: upper,
            bucketCount: upper - lower + 1,
            startDate: start,
            endDate: endStart.addingTimeInterval(bucketInterval),
            priceCard: priceCard,
            breakdown: breakdown,
            fiveHour: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: fiveHourDrop,
                priceCard: priceCard
            ),
            sevenDay: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: sevenDayDrop,
                priceCard: priceCard
            )
        )
    }

    private func cumulativeQuotaDrop(_ values: [Double?], lower: Int, upper: Int) -> Double? {
        let availableValues = sanitizedQuotaDropValues(values[lower...upper].compactMap { $0 })
        guard availableValues.count >= 2 else { return nil }

        return zip(availableValues, availableValues.dropFirst())
            .reduce(0) { partial, pair in
                partial + max(pair.0 - pair.1, 0)
            }
    }

    private func sanitizedQuotaDropValues(_ values: [Double]) -> [Double] {
        values.enumerated().compactMap { index, value in
            let previous = index > 0 ? values[index - 1] : nil
            let next = index + 1 < values.count ? values[index + 1] : nil
            if isFullUsageSpike(value, previous: previous, next: next) {
                return nil
            }
            return value
        }
    }

    private func isFullUsageSpike(_ value: Double, previous: Double?, next: Double?) -> Bool {
        guard value <= 1, let previous, previous >= 95 else { return false }
        return next == nil || (next ?? 0) >= 95
    }
}
