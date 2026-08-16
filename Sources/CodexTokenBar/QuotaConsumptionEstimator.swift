import Foundation

enum QuotaConsumptionConfidence: Equatable {
    case measured
    case insufficientQuotaMovement
    case noTokenUsage
}

enum QuotaConsumptionDropBasis: Equatable, Sendable {
    /// Two distinct persisted quota observations inside one reset cycle.
    case observed
    /// A chart-only calculation from carried or interpolated display values.
    case estimated
    case unavailable
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

/// Spark is metered through a separate Codex quota. OpenAI has not published
/// a final Spark-specific rate card, so this is an explicitly labelled API
/// reference rate only; it must never be folded into quota-drop attribution or
/// the primary API-equivalent total.
enum IndependentQuotaReferencePricing {
    static let sparkRevision = "gpt-5.3-codex-spark-reference-api-20260815"
    static let sparkRates = APIPriceRates(
        inputUSDPerMillion: 1.75,
        cachedInputUSDPerMillion: 0.175,
        outputUSDPerMillion: 14.00
    )

    static func costUSD(
        for rawModel: String?,
        breakdown: TokenCacheBreakdown
    ) -> Double? {
        guard OfficialAPIPriceModel.independentQuotaModelName(from: rawModel) != nil else {
            return nil
        }
        return sparkRates.costUSD(for: breakdown)
    }
}

struct ModelAwareAPIPriceEstimate: Equatable, Sendable {
    let costUSD: Double
    let detectedModels: [OfficialAPIPriceModel]
    let fallbackCalls: Int
    /// Models on an independent quota; retained in token/model stats but never priced.
    let excludedModels: [String]
    let excludedCalls: Int

    init(
        costUSD: Double,
        detectedModels: [OfficialAPIPriceModel],
        fallbackCalls: Int,
        excludedModels: [String] = [],
        excludedCalls: Int = 0
    ) {
        self.costUSD = costUSD
        self.detectedModels = detectedModels
        self.fallbackCalls = fallbackCalls
        self.excludedModels = excludedModels
        self.excludedCalls = excludedCalls
    }
}

/// A versioned model-routing rule. Usage events keep their raw model alias;
/// this rule only describes which billable model that alias represents from a
/// given UTC instant onward.
struct ModelPricingRule: Equatable, Sendable {
    let alias: String
    let effectiveFrom: Date
    let targetModel: OfficialAPIPriceModel
    let revision: String
}

enum CodexAutoReviewPricingPolicy {
    static let rules: [ModelPricingRule] = [
        ModelPricingRule(
            alias: "codex-auto-review",
            effectiveFrom: .distantPast,
            targetModel: .gpt54Legacy,
            revision: "codex-auto-review-pre-luna"
        ),
        ModelPricingRule(
            alias: "codex-auto-review",
            effectiveFrom: utcDate(year: 2026, month: 7, day: 30),
            targetModel: .gpt56Luna,
            revision: "codex-auto-review-luna-20260730"
        ),
    ]

    static var currentRule: ModelPricingRule {
        rules.max { lhs, rhs in lhs.effectiveFrom < rhs.effectiveFrom }!
    }

    static func rule(for rawAlias: String?, at date: Date? = nil) -> ModelPricingRule? {
        guard let rawAlias else { return nil }
        let normalizedAlias = canonicalAlias(rawAlias)
        let candidates = rules.filter { canonicalAlias($0.alias) == normalizedAlias }
        guard !candidates.isEmpty else { return nil }

        let effectiveDate = date ?? .distantFuture
        return candidates
            .filter { $0.effectiveFrom <= effectiveDate }
            .max { lhs, rhs in lhs.effectiveFrom < rhs.effectiveFrom }
    }

    static func effectiveModel(for rawAlias: String?, at date: Date? = nil) -> OfficialAPIPriceModel? {
        rule(for: rawAlias, at: date)?.targetModel
    }

    static func isAutoReviewAlias(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let normalized = canonicalAlias(rawValue)
        return rules.contains { canonicalAlias($0.alias) == normalized }
    }

    static func canonicalAlias(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }
}

enum ModelAwareAPIPriceEstimator {
    private struct PricingRow {
        let model: String?
        let breakdown: TokenCacheBreakdown
        let detectedModel: OfficialAPIPriceModel?
    }

    static func estimate(
        events: [TokenCacheAttributionEvent]?,
        fallbackBreakdown: TokenCacheBreakdown,
        fallbackModel: OfficialAPIPriceModel,
        rates: (OfficialAPIPriceModel) -> APIPriceRates
    ) -> ModelAwareAPIPriceEstimate {
        guard let events, !events.isEmpty else {
            return fallback(
                breakdown: fallbackBreakdown,
                model: fallbackModel,
                rates: rates
            )
        }
        return estimate(
            rows: events.map { event in
                PricingRow(
                    model: event.model,
                    breakdown: event.breakdown,
                    detectedModel: OfficialAPIPriceModel.detected(
                        from: event.model,
                        at: event.start
                    )
                )
            },
            fallbackBreakdown: fallbackBreakdown,
            fallbackModel: fallbackModel,
            rates: rates
        )
    }

    static func estimate(
        modelBreakdowns: [ModelTokenBreakdown],
        fallbackBreakdown: TokenCacheBreakdown,
        fallbackModel: OfficialAPIPriceModel,
        rates: (OfficialAPIPriceModel) -> APIPriceRates
    ) -> ModelAwareAPIPriceEstimate {
        estimate(
            rows: modelBreakdowns.map { row in
                PricingRow(
                    model: row.model,
                    breakdown: row.breakdown,
                    detectedModel: OfficialAPIPriceModel.detected(from: row.model)
                )
            },
            fallbackBreakdown: fallbackBreakdown,
            fallbackModel: fallbackModel,
            rates: rates
        )
    }

    private static func estimate(
        rows: [PricingRow],
        fallbackBreakdown: TokenCacheBreakdown,
        fallbackModel: OfficialAPIPriceModel,
        rates: (OfficialAPIPriceModel) -> APIPriceRates
    ) -> ModelAwareAPIPriceEstimate {
        guard !rows.isEmpty else {
            return fallback(
                breakdown: fallbackBreakdown,
                model: fallbackModel,
                rates: rates
            )
        }
        let independentRows = rows.compactMap { row -> (String, TokenCacheBreakdown)? in
            guard let name = OfficialAPIPriceModel.independentQuotaModelName(from: row.model) else {
                return nil
            }
            return (name, row.breakdown)
        }
        let excludedBreakdown = independentRows.map(\.1).combined
        let excludedModels = independentRows.reduce(into: [String]()) { names, row in
            if !names.contains(row.0) { names.append(row.0) }
        }
        let excludedCalls = independentRows.reduce(0) { total, row in
            total + max(row.1.calls, 0)
        }
        let coveredBreakdown = rows.map(\.breakdown).combined
        guard coveredBreakdown.inputTokens == fallbackBreakdown.inputTokens,
              coveredBreakdown.cachedInputTokens == fallbackBreakdown.cachedInputTokens,
              coveredBreakdown.outputTokens == fallbackBreakdown.outputTokens,
              coveredBreakdown.calls == fallbackBreakdown.calls else {
            return fallback(
                breakdown: fallbackBreakdown.subtracting(excludedBreakdown),
                model: fallbackModel,
                rates: rates,
                excludedModels: excludedModels,
                excludedCalls: excludedCalls
            )
        }
        var grouped: [OfficialAPIPriceModel: [TokenCacheBreakdown]] = [:]
        var fallbackBreakdowns: [TokenCacheBreakdown] = []
        for row in rows {
            if OfficialAPIPriceModel.independentQuotaModelName(from: row.model) != nil {
                // Collected above so incomplete model rows can also fail closed
                // without charging this independent quota to the fallback.
            } else if let detected = row.detectedModel {
                grouped[detected, default: []].append(row.breakdown)
            } else {
                fallbackBreakdowns.append(row.breakdown)
            }
        }
        let knownCost = grouped.reduce(0.0) { partial, entry in
            partial + rates(entry.key).costUSD(for: entry.value.combined)
        }
        let unknownBreakdown = fallbackBreakdowns.combined
        return ModelAwareAPIPriceEstimate(
            costUSD: knownCost + rates(fallbackModel).costUSD(for: unknownBreakdown),
            detectedModels: OfficialAPIPriceModel.allCases.filter { grouped[$0] != nil },
            fallbackCalls: unknownBreakdown.calls,
            excludedModels: excludedModels,
            excludedCalls: excludedCalls
        )
    }

    private static func fallback(
        breakdown: TokenCacheBreakdown,
        model: OfficialAPIPriceModel,
        rates: (OfficialAPIPriceModel) -> APIPriceRates,
        excludedModels: [String] = [],
        excludedCalls: Int = 0
    ) -> ModelAwareAPIPriceEstimate {
        ModelAwareAPIPriceEstimate(
            costUSD: rates(model).costUSD(for: breakdown),
            detectedModels: [],
            fallbackCalls: breakdown.calls,
            excludedModels: excludedModels,
            excludedCalls: excludedCalls
        )
    }
}

private extension TokenCacheBreakdown {
    func subtracting(_ excluded: TokenCacheBreakdown) -> TokenCacheBreakdown {
        TokenCacheBreakdown(
            inputTokens: max(inputTokens - max(excluded.inputTokens, 0), 0),
            cachedInputTokens: max(cachedInputTokens - max(excluded.cachedInputTokens, 0), 0),
            outputTokens: max(outputTokens - max(excluded.outputTokens, 0), 0),
            reasoningOutputTokens: max(reasoningOutputTokens - max(excluded.reasoningOutputTokens, 0), 0),
            totalTokens: max(totalTokens - max(excluded.totalTokens, 0), 0),
            calls: max(calls - max(excluded.calls, 0), 0)
        )
    }
}

enum OfficialAPIPriceModel: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case gpt56Sol
    case gpt56Terra
    case gpt56Luna
    case gpt53Codex
    case gpt52Codex
    case gpt54Legacy
    case gpt54MiniLegacy

    static let selectableCases: [OfficialAPIPriceModel] = [
        .gpt56Sol,
        .gpt56Terra,
        .gpt56Luna
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpt56Sol: "GPT-5.6 Sol"
        case .gpt56Terra: "GPT-5.6 Terra"
        case .gpt56Luna: "GPT-5.6 Luna"
        case .gpt53Codex: "GPT-5.3 Codex"
        case .gpt52Codex: "GPT-5.2 Codex"
        case .gpt54Legacy: "GPT-5.4"
        case .gpt54MiniLegacy: "GPT-5.4 Mini"
        }
    }

    var currentPriceRates: APIPriceRates {
        // Standard short-context prices published by OpenAI. Long-context,
        // cache-write, priority/service-tier and regional multipliers remain
        // outside this estimate.
        switch self {
        case .gpt56Sol:
            APIPriceRates(inputUSDPerMillion: 5.00, cachedInputUSDPerMillion: 0.50, outputUSDPerMillion: 30.00)
        case .gpt56Terra:
            APIPriceRates(inputUSDPerMillion: 2.00, cachedInputUSDPerMillion: 0.20, outputUSDPerMillion: 12.00)
        case .gpt56Luna:
            APIPriceRates(inputUSDPerMillion: 0.20, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.20)
        case .gpt53Codex, .gpt52Codex:
            APIPriceRates(inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14.00)
        case .gpt54Legacy:
            APIPriceRates(inputUSDPerMillion: 2.50, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15.00)
        case .gpt54MiniLegacy:
            APIPriceRates(inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.50)
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

    static func detected(from rawValue: String?) -> OfficialAPIPriceModel? {
        detected(from: rawValue, at: nil)
    }

    static func detected(
        from rawValue: String?,
        at eventDate: Date?
    ) -> OfficialAPIPriceModel? {
        guard let rawValue else { return nil }
        let key = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if let autoReviewModel = CodexAutoReviewPricingPolicy.effectiveModel(
            for: rawValue,
            at: eventDate
        ) {
            return autoReviewModel
        }
        switch key {
        case "gpt-5.6", "gpt5.6", "gpt56", "gpt-5.6-sol", "gpt5.6-sol", "gpt56-sol", "gpt56sol", "gpt-5.5", "gpt55":
            return .gpt56Sol
        case "gpt-5.6-terra", "gpt5.6-terra", "gpt56-terra", "gpt56terra":
            return .gpt56Terra
        case "gpt-5.6-luna", "gpt5.6-luna", "gpt56-luna", "gpt56luna":
            return .gpt56Luna
        case "gpt-5.3-codex", "gpt5.3-codex", "gpt53-codex", "gpt53codex":
            return .gpt53Codex
        case "gpt-5.2-codex", "gpt5.2-codex", "gpt52-codex", "gpt52codex":
            return .gpt52Codex
        case "gpt-5.4", "gpt54":
            return .gpt54Legacy
        case "gpt-5.4-mini", "gpt54mini":
            return .gpt54MiniLegacy
        default:
            return nil
        }
    }

    /// Returns the canonical model name when the usage belongs to the
    /// independent GPT-5.3 Codex Spark quota. Spark remains in token/model
    /// analytics but is intentionally excluded from every API-dollar estimate.
    static func independentQuotaModelName(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let key = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .filter { $0.isLetter || $0.isNumber }
        return key == "gpt53codexspark" ? "gpt-5.3-codex-spark" : nil
    }

    // Source-compatible aliases for tests and integrations compiled against
    // the old enum spelling. New persisted values always use GPT-5.6 IDs.
    static let gpt55: OfficialAPIPriceModel = .gpt56Sol
    static let gpt54: OfficialAPIPriceModel = .gpt56Terra
    static let gpt54Mini: OfficialAPIPriceModel = .gpt56Luna
}

enum QuotaConsumptionPriceCard: Equatable {
    case officialAPI(OfficialAPIPriceModel)

    var officialAPIModel: OfficialAPIPriceModel {
        switch self {
        case .officialAPI(let model): model
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
    let quotaDropBasis: QuotaConsumptionDropBasis
    let comparisonBreakdown: TokenCacheBreakdown
    let comparisonStartDate: Date?
    let comparisonEndDate: Date?
    let comparisonUsesConservativeBuckets: Bool
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let calls: Int
    let cacheHitRate: Double
    let confidence: QuotaConsumptionConfidence
    let excludedModels: [String]
    let excludedCalls: Int

    var quotaDropObserved: Bool { quotaDropBasis == .observed }
    var quotaDropEstimated: Bool { quotaDropBasis == .estimated }

    init(
        selectedCostUSD: Double,
        impliedWindowBudgetUSD: Double?,
        quotaDropPercent: Double,
        quotaDropObserved: Bool = true,
        quotaDropBasis: QuotaConsumptionDropBasis? = nil,
        comparisonBreakdown: TokenCacheBreakdown? = nil,
        comparisonStartDate: Date? = nil,
        comparisonEndDate: Date? = nil,
        comparisonUsesConservativeBuckets: Bool = false,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        calls: Int,
        cacheHitRate: Double,
        confidence: QuotaConsumptionConfidence,
        excludedModels: [String] = [],
        excludedCalls: Int = 0
    ) {
        self.selectedCostUSD = selectedCostUSD
        self.impliedWindowBudgetUSD = impliedWindowBudgetUSD
        self.quotaDropPercent = quotaDropPercent
        self.quotaDropBasis = quotaDropBasis
            ?? (quotaDropObserved ? .observed : .unavailable)
        self.comparisonBreakdown = comparisonBreakdown ?? TokenCacheBreakdown(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: 0,
            totalTokens: max(inputTokens, 0) + max(outputTokens, 0),
            calls: calls
        )
        self.comparisonStartDate = comparisonStartDate
        self.comparisonEndDate = comparisonEndDate
        self.comparisonUsesConservativeBuckets = comparisonUsesConservativeBuckets
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.calls = calls
        self.cacheHitRate = cacheHitRate
        self.confidence = confidence
        self.excludedModels = excludedModels
        self.excludedCalls = excludedCalls
    }
}

enum QuotaConsumptionEstimator {
    static func estimate(
        breakdown: TokenCacheBreakdown,
        quotaStartPercent: Double?,
        quotaEndPercent: Double?,
        priceCard: QuotaConsumptionPriceCard
    ) -> QuotaConsumptionEstimate {
        let quotaDropPercent: Double? = if let quotaStartPercent, let quotaEndPercent {
            max(quotaStartPercent - quotaEndPercent, 0)
        } else {
            nil
        }
        return estimate(
            breakdown: breakdown,
            quotaDropPercent: quotaDropPercent,
            priceCard: priceCard
        )
    }

    static func estimate(
        breakdown: TokenCacheBreakdown,
        quotaDropPercent: Double?,
        priceCard: QuotaConsumptionPriceCard,
        selectedCostUSD: Double? = nil,
        comparisonCostUSD: Double? = nil,
        quotaDropBasis: QuotaConsumptionDropBasis? = nil,
        comparisonBreakdown: TokenCacheBreakdown? = nil,
        excludedModels: [String] = [],
        excludedCalls: Int = 0,
        comparisonStartDate: Date? = nil,
        comparisonEndDate: Date? = nil,
        comparisonUsesConservativeBuckets: Bool = false
    ) -> QuotaConsumptionEstimate {
        let selectedCost = selectedCostUSD ?? priceCard.costUSD(for: breakdown)
        let resolvedBasis = quotaDropBasis
            ?? (quotaDropPercent == nil ? .unavailable : .observed)
        let resolvedComparisonBreakdown = comparisonBreakdown ?? breakdown
        let comparableCost = comparisonCostUSD
            ?? priceCard.costUSD(for: resolvedComparisonBreakdown)
        let drop = max(quotaDropPercent ?? 0, 0)
        let confidence: QuotaConsumptionConfidence
        let impliedBudget: Double?

        if resolvedComparisonBreakdown.totalTokens <= 0
            && resolvedComparisonBreakdown.inputTokens <= 0
            && resolvedComparisonBreakdown.outputTokens <= 0 {
            confidence = .noTokenUsage
            impliedBudget = nil
        } else if resolvedBasis == .unavailable || drop <= 0.0001 {
            confidence = .insufficientQuotaMovement
            impliedBudget = nil
        } else {
            confidence = .measured
            impliedBudget = comparableCost / (drop / 100)
        }

        return QuotaConsumptionEstimate(
            selectedCostUSD: selectedCost,
            impliedWindowBudgetUSD: impliedBudget,
            quotaDropPercent: drop,
            quotaDropBasis: resolvedBasis,
            comparisonBreakdown: resolvedComparisonBreakdown,
            comparisonStartDate: comparisonStartDate,
            comparisonEndDate: comparisonEndDate,
            comparisonUsesConservativeBuckets: comparisonUsesConservativeBuckets,
            inputTokens: breakdown.inputTokens,
            cachedInputTokens: breakdown.cachedInputTokens,
            outputTokens: breakdown.outputTokens,
            calls: breakdown.calls,
            cacheHitRate: breakdown.cacheHitRate,
            confidence: confidence,
            excludedModels: excludedModels,
            excludedCalls: excludedCalls
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
    let fullAttributionEvents: [TokenCacheAttributionEvent]
    let fiveHourAttributionEvents: [TokenCacheAttributionEvent]
    let sevenDayAttributionEvents: [TokenCacheAttributionEvent]

    init(
        startIndex: Int,
        endIndex: Int,
        bucketCount: Int,
        startDate: Date,
        endDate: Date,
        priceCard: QuotaConsumptionPriceCard,
        breakdown: TokenCacheBreakdown,
        fiveHour: QuotaConsumptionEstimate,
        sevenDay: QuotaConsumptionEstimate,
        fullAttributionEvents: [TokenCacheAttributionEvent] = [],
        fiveHourAttributionEvents: [TokenCacheAttributionEvent] = [],
        sevenDayAttributionEvents: [TokenCacheAttributionEvent] = []
    ) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.bucketCount = bucketCount
        self.startDate = startDate
        self.endDate = endDate
        self.priceCard = priceCard
        self.breakdown = breakdown
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fullAttributionEvents = fullAttributionEvents
        self.fiveHourAttributionEvents = fiveHourAttributionEvents
        self.sevenDayAttributionEvents = sevenDayAttributionEvents
    }
}

extension QuotaConsumptionSelection {
    var fallbackPriceModel: OfficialAPIPriceModel {
        priceCard.officialAPIModel
    }

    var fullCurrentAPIPriceEstimate: ModelAwareAPIPriceEstimate {
        ModelAwareAPIPriceEstimator.estimate(
            events: fullAttributionEvents,
            fallbackBreakdown: breakdown,
            fallbackModel: fallbackPriceModel,
            rates: { $0.currentPriceRates }
        )
    }

    var sevenDayCurrentAPIPriceEstimate: ModelAwareAPIPriceEstimate {
        ModelAwareAPIPriceEstimator.estimate(
            events: sevenDayAttributionEvents,
            fallbackBreakdown: sevenDayAttributionBreakdown,
            fallbackModel: fallbackPriceModel,
            rates: { $0.currentPriceRates }
        )
    }

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

    var sevenDayAttributionBreakdown: TokenCacheBreakdown {
        sevenDay.comparisonBreakdown
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

private struct RecentChartQuotaDropResolution {
    let percent: Double?
    let basis: QuotaConsumptionDropBasis
    let comparisonBreakdown: TokenCacheBreakdown
    let comparisonStartDate: Date?
    let comparisonEndDate: Date?
    let comparisonUsesConservativeBuckets: Bool
}

extension RecentChartPreparedData {
    func quotaConsumptionSelection(
        startIndex: Int,
        endIndex: Int,
        priceCard: QuotaConsumptionPriceCard,
        attributionEvents: [TokenCacheAttributionEvent] = []
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
        let end = endStart.addingTimeInterval(bucketInterval)
        let fiveHourDrop = quotaDropResolution(
            values: fiveHourRemainingPercents,
            observations: fiveHourQuotaObservations,
            lower: lower,
            upper: upper,
            selectionStart: start,
            selectionEnd: end
        )
        let sevenDayDrop = quotaDropResolution(
            values: sevenDayRemainingPercents,
            observations: sevenDayQuotaObservations,
            lower: lower,
            upper: upper,
            selectionStart: start,
            selectionEnd: end
        )
        let fallbackModel = priceCard.officialAPIModel
        let fullEvents = attributionEvents.filter {
            $0.start >= start && $0.start < end
        }
        let fiveHourEvents = attributionEvents.filter {
            $0.start >= (fiveHourDrop.comparisonStartDate ?? start)
                && $0.start < (fiveHourDrop.comparisonEndDate ?? end)
        }
        let sevenDayEvents = attributionEvents.filter {
            $0.start >= (sevenDayDrop.comparisonStartDate ?? start)
                && $0.start < (sevenDayDrop.comparisonEndDate ?? end)
        }
        let fullPrice = ModelAwareAPIPriceEstimator.estimate(
            events: fullEvents,
            fallbackBreakdown: breakdown,
            fallbackModel: fallbackModel,
            rates: { $0.currentPriceRates }
        )
        let fiveHourPrice = ModelAwareAPIPriceEstimator.estimate(
            events: fiveHourEvents,
            fallbackBreakdown: fiveHourDrop.comparisonBreakdown,
            fallbackModel: fallbackModel,
            rates: { $0.currentPriceRates }
        )
        let sevenDayPrice = ModelAwareAPIPriceEstimator.estimate(
            events: sevenDayEvents,
            fallbackBreakdown: sevenDayDrop.comparisonBreakdown,
            fallbackModel: fallbackModel,
            rates: { $0.currentPriceRates }
        )

        return QuotaConsumptionSelection(
            startIndex: lower,
            endIndex: upper,
            bucketCount: upper - lower + 1,
            startDate: start,
            endDate: end,
            priceCard: priceCard,
            breakdown: breakdown,
            fiveHour: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: fiveHourDrop.percent,
                priceCard: priceCard,
                selectedCostUSD: fullPrice.costUSD,
                comparisonCostUSD: fiveHourPrice.costUSD,
                quotaDropBasis: fiveHourDrop.basis,
                comparisonBreakdown: fiveHourDrop.comparisonBreakdown,
                excludedModels: fiveHourPrice.excludedModels,
                excludedCalls: fiveHourPrice.excludedCalls,
                comparisonStartDate: fiveHourDrop.comparisonStartDate,
                comparisonEndDate: fiveHourDrop.comparisonEndDate,
                comparisonUsesConservativeBuckets: fiveHourDrop.comparisonUsesConservativeBuckets
            ),
            sevenDay: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: sevenDayDrop.percent,
                priceCard: priceCard,
                selectedCostUSD: fullPrice.costUSD,
                comparisonCostUSD: sevenDayPrice.costUSD,
                quotaDropBasis: sevenDayDrop.basis,
                comparisonBreakdown: sevenDayDrop.comparisonBreakdown,
                excludedModels: sevenDayPrice.excludedModels,
                excludedCalls: sevenDayPrice.excludedCalls,
                comparisonStartDate: sevenDayDrop.comparisonStartDate,
                comparisonEndDate: sevenDayDrop.comparisonEndDate,
                comparisonUsesConservativeBuckets: sevenDayDrop.comparisonUsesConservativeBuckets
            ),
            fullAttributionEvents: fullEvents,
            fiveHourAttributionEvents: fiveHourEvents,
            sevenDayAttributionEvents: sevenDayEvents
        )
    }

    private func quotaDropResolution(
        values: [Double?],
        observations: [QuotaHistoryObservation],
        lower: Int,
        upper: Int,
        selectionStart: Date,
        selectionEnd: Date
    ) -> RecentChartQuotaDropResolution {
        let selectedObservations = observationSlice(
            observations,
            from: selectionStart,
            through: selectionEnd
        )

        // Persisted observations carry reset provenance. Once any such
        // observation is present in the selected interval, do not fall back to
        // display-value arithmetic when the cycle cannot be proven: doing so
        // can combine the previous cycle's tokens with the latest cycle's drop.
        if selectedObservations.contains(where: { $0.resetsAt != nil }) {
            return observedQuotaDropResolution(
                observations: Array(selectedObservations),
                lower: lower,
                upper: upper
            ) ?? RecentChartQuotaDropResolution(
                percent: nil,
                basis: .unavailable,
                comparisonBreakdown: .empty,
                comparisonStartDate: nil,
                comparisonEndDate: nil,
                comparisonUsesConservativeBuckets: false
            )
        }

        // Without reset provenance, mirror the chart's product heuristic:
        // remove isolated 0/100 glitches, find the latest sustained upward
        // jump, and use only that cycle's suffix for the comparison. The full
        // selection remains untouched by this comparison-only narrowing.
        guard let estimatedDrop = cumulativeQuotaDrop(
            values,
            lower: lower,
            upper: upper
        ) else {
            return RecentChartQuotaDropResolution(
                percent: nil,
                basis: .unavailable,
                comparisonBreakdown: .empty,
                comparisonStartDate: nil,
                comparisonEndDate: nil,
                comparisonUsesConservativeBuckets: false
            )
        }

        let firstCoveredIndex = max(lower, estimatedDrop.firstBoundaryIndex)
        let lastCoveredIndex = min(upper, estimatedDrop.lastBoundaryIndex)
        guard firstCoveredIndex <= lastCoveredIndex,
              let estimatedComparisonStart = bins[safe: firstCoveredIndex]?.start,
              let lastStart = bins[safe: lastCoveredIndex]?.start else {
            return RecentChartQuotaDropResolution(
                percent: nil,
                basis: .unavailable,
                comparisonBreakdown: .empty,
                comparisonStartDate: nil,
                comparisonEndDate: nil,
                comparisonUsesConservativeBuckets: false
            )
        }
        return RecentChartQuotaDropResolution(
            percent: estimatedDrop.percent,
            basis: .estimated,
            comparisonBreakdown: (firstCoveredIndex...lastCoveredIndex)
                .map { cacheBreakdowns[safe: $0] ?? .empty }
                .combined,
            comparisonStartDate: estimatedComparisonStart,
            comparisonEndDate: lastStart.addingTimeInterval(bucketInterval),
            comparisonUsesConservativeBuckets: false
        )
    }

    private func observedQuotaDropResolution(
        observations: [QuotaHistoryObservation],
        lower: Int,
        upper: Int
    ) -> RecentChartQuotaDropResolution? {
        guard let authority = observations.last,
              authority.resetsAt != nil else {
            return nil
        }

        // The final reliable observation defines the cycle at the selection
        // endpoint. Walk backwards only while reset provenance remains within
        // the existing two-minute same-cycle tolerance; anything before the
        // first mismatch belongs to an older cycle and is excluded.
        var cycleSuffix = [authority]
        for observation in observations.dropLast().reversed() {
            guard sameQuotaCycle(observation, authority) else { break }
            cycleSuffix.append(observation)
        }
        cycleSuffix.reverse()

        let adjacentObservations = zip(cycleSuffix, cycleSuffix.dropFirst())
        guard cycleSuffix.count >= 2,
              adjacentObservations.allSatisfy({ pair in
                  pair.1.remainingPercent <= pair.0.remainingPercent + 0.0001
              }),
              let first = cycleSuffix.first,
              let last = cycleSuffix.last else {
            return nil
        }

        // Both partial boundary buckets are included conservatively. This can
        // overstate local usage, but it cannot turn local usage into a false
        // positive "other user" gap. The attribution layer still marks such
        // ranges provisional because bucket-level data cannot split at seconds.
        let comparisonStart = quotaBucketBoundary(for: first.observedAt)
        let lastBoundary = quotaBucketBoundary(for: last.observedAt)
        let firstIsAligned = abs(first.observedAt.timeIntervalSince(comparisonStart)) < 0.5
        let lastIsAligned = abs(last.observedAt.timeIntervalSince(lastBoundary)) < 0.5
        let comparisonEnd = lastIsAligned
            ? lastBoundary
            : lastBoundary.addingTimeInterval(bucketInterval)
        guard comparisonEnd > comparisonStart else { return nil }

        let comparisonBreakdown = (lower...upper)
            .compactMap { index -> TokenCacheBreakdown? in
                guard let binStart = bins[safe: index]?.start,
                      binStart >= comparisonStart,
                      binStart < comparisonEnd else { return nil }
                return cacheBreakdowns[safe: index] ?? .empty
            }
            .combined
        let drop = max(first.remainingPercent - last.remainingPercent, 0)

        return RecentChartQuotaDropResolution(
            percent: drop,
            basis: .observed,
            comparisonBreakdown: comparisonBreakdown,
            comparisonStartDate: comparisonStart,
            comparisonEndDate: comparisonEnd,
            comparisonUsesConservativeBuckets: bucketInterval > 5 * 60 + 0.5
                || !firstIsAligned
                || !lastIsAligned
        )
    }

    private func observationSlice(
        _ observations: [QuotaHistoryObservation],
        from startDate: Date,
        through endDate: Date
    ) -> ArraySlice<QuotaHistoryObservation> {
        var low = 0
        var high = observations.count
        while low < high {
            let middle = low + (high - low) / 2
            if observations[middle].observedAt < startDate {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let lowerBound = low

        low = lowerBound
        high = observations.count
        while low < high {
            let middle = low + (high - low) / 2
            if observations[middle].observedAt <= endDate {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return observations[lowerBound..<low]
    }

    private func sameQuotaCycle(
        _ lhs: QuotaHistoryObservation,
        _ rhs: QuotaHistoryObservation
    ) -> Bool {
        switch (lhs.resetsAt, rhs.resetsAt) {
        case let (left?, right?):
            abs(left.timeIntervalSince(right)) <= 2 * 60
        case (nil, nil), (_?, nil), (nil, _?):
            false
        }
    }

    private func quotaBucketBoundary(for date: Date) -> Date {
        Date(
            timeIntervalSince1970: floor(
                date.timeIntervalSince1970 / bucketInterval
            ) * bucketInterval
        )
    }

    private func cumulativeQuotaDrop(
        _ values: [Double?],
        lower: Int,
        upper: Int
    ) -> (percent: Double, firstBoundaryIndex: Int, lastBoundaryIndex: Int)? {
        guard !values.isEmpty else { return nil }
        let safeLower = max(0, min(lower, values.count - 1))
        let safeUpper = max(safeLower, min(upper, values.count - 1))
        let indexedValues = values[safeLower...safeUpper].enumerated().compactMap { offset, value in
            value.map { (index: safeLower + offset, value: $0) }
        }
        let availableValues = sanitizedQuotaDropValues(indexedValues)
        guard availableValues.count >= 2 else { return nil }

        // A sustained upward move is the only display-only reset evidence we
        // accept. A suffix with fewer than two points cannot support a budget
        // inversion, so it fails closed.
        var currentCycleStart = 0
        for index in 1..<availableValues.count {
            if availableValues[index].value > availableValues[index - 1].value + 5 {
                currentCycleStart = index
            }
        }
        let currentCycleValues = Array(availableValues[currentCycleStart...])
        guard currentCycleValues.count >= 2 else { return nil }

        let percent = zip(currentCycleValues, currentCycleValues.dropFirst())
            .reduce(0) { partial, pair in
                partial + max(pair.0.value - pair.1.value, 0)
            }
        return (
            percent: percent,
            firstBoundaryIndex: currentCycleValues[0].index,
            lastBoundaryIndex: currentCycleValues[currentCycleValues.count - 1].index
        )
    }

    private func sanitizedQuotaDropValues(
        _ values: [(index: Int, value: Double)]
    ) -> [(index: Int, value: Double)] {
        values.enumerated().compactMap { offset, item in
            let previous = offset > 0 ? values[offset - 1].value : nil
            let next = offset + 1 < values.count ? values[offset + 1].value : nil
            if isZeroRemainingSpike(item.value, previous: previous, next: next)
                || isFullRemainingSpike(item.value, previous: previous, next: next) {
                return nil
            }
            return item
        }
    }

    private func isZeroRemainingSpike(_ value: Double, previous: Double?, next: Double?) -> Bool {
        guard value <= 1, let previous, previous >= 95 else { return false }
        return next == nil || (next ?? 0) >= 95
    }

    private func isFullRemainingSpike(_ value: Double, previous: Double?, next: Double?) -> Bool {
        value >= 99
            && previous != nil
            && next != nil
            && (previous ?? 0) <= 95
            && (next ?? 0) <= (previous ?? 0) + 1
    }
}
