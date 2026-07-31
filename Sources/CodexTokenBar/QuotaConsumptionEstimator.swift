import Foundation

enum QuotaConsumptionConfidence: Equatable {
    case measured
    case insufficientQuotaMovement
    case noTokenUsage
}

struct APIPriceRates: Equatable, Sendable {
    let inputUSDPerMillion: Double
    let cachedInputUSDPerMillion: Double
    let outputUSDPerMillion: Double

    func costUSD(for breakdown: TokenCacheBreakdown) -> Double {
        let cachedInput = max(0, min(breakdown.cachedInputTokens, breakdown.inputTokens))
        let uncachedInput = max(0, breakdown.inputTokens - cachedInput)
        return (
            Double(uncachedInput) * inputUSDPerMillion
            + Double(cachedInput) * cachedInputUSDPerMillion
            + Double(max(breakdown.outputTokens, 0)) * outputUSDPerMillion
        ) / 1_000_000
    }
}

enum OfficialAPIPriceModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case gpt56Sol
    case gpt56Terra
    case gpt56Luna

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpt56Sol: "GPT-5.6 Sol"
        case .gpt56Terra: "GPT-5.6 Terra"
        case .gpt56Luna: "GPT-5.6 Luna"
        }
    }

    var currentPriceRates: APIPriceRates {
        switch self {
        case .gpt56Sol:
            APIPriceRates(inputUSDPerMillion: 5.00, cachedInputUSDPerMillion: 0.50, outputUSDPerMillion: 30.00)
        case .gpt56Terra:
            APIPriceRates(inputUSDPerMillion: 2.00, cachedInputUSDPerMillion: 0.20, outputUSDPerMillion: 12.00)
        case .gpt56Luna:
            APIPriceRates(inputUSDPerMillion: 0.20, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.20)
        }
    }

    var inputUSDPerMillion: Double {
        currentPriceRates.inputUSDPerMillion
    }

    var cachedInputUSDPerMillion: Double {
        currentPriceRates.cachedInputUSDPerMillion
    }

    var outputUSDPerMillion: Double {
        currentPriceRates.outputUSDPerMillion
    }

    /// Reads both the current model IDs and values written by releases before
    /// GPT-5.6 family names became available. The storage key itself remains
    /// unchanged so chart, savings and shared-account estimates stay aligned.
    static func storedValue(for rawValue: String?) -> OfficialAPIPriceModel {
        if let rawValue, let current = OfficialAPIPriceModel(rawValue: rawValue) {
            return current
        }
        switch rawValue {
        case "gpt55":
            return .gpt56Sol
        case "gpt54":
            return .gpt56Terra
        case "gpt54Mini":
            return .gpt56Luna
        default:
            return .gpt56Sol
        }
    }

    // Source-compatible aliases for tests and integrations compiled against
    // the old enum spelling. New persisted values always use GPT-5.6 IDs.
    static let gpt55: OfficialAPIPriceModel = .gpt56Sol
    static let gpt54: OfficialAPIPriceModel = .gpt56Terra
    static let gpt54Mini: OfficialAPIPriceModel = .gpt56Luna
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
            model.currentPriceRates.costUSD(for: breakdown)
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
