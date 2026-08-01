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

    static func detected(from rawValue: String?) -> OfficialAPIPriceModel? {
        guard let rawValue else { return nil }
        let key = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch key {
        case "gpt-5.6-sol", "gpt5.6-sol", "gpt56-sol", "gpt56sol", "gpt-5.5", "gpt55":
            return .gpt56Sol
        case "gpt-5.6-terra", "gpt5.6-terra", "gpt56-terra", "gpt56terra", "gpt-5.4", "gpt54":
            return .gpt56Terra
        case "gpt-5.6-luna", "gpt5.6-luna", "gpt56-luna", "gpt56luna", "gpt-5.4-mini", "gpt54mini":
            return .gpt56Luna
        default:
            return nil
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
        confidence: QuotaConsumptionConfidence
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
        quotaDropBasis: QuotaConsumptionDropBasis? = nil,
        comparisonBreakdown: TokenCacheBreakdown? = nil,
        comparisonStartDate: Date? = nil,
        comparisonEndDate: Date? = nil,
        comparisonUsesConservativeBuckets: Bool = false
    ) -> QuotaConsumptionEstimate {
        let selectedCost = priceCard.costUSD(for: breakdown)
        let resolvedBasis = quotaDropBasis
            ?? (quotaDropPercent == nil ? .unavailable : .observed)
        let resolvedComparisonBreakdown = comparisonBreakdown ?? breakdown
        let comparableCost = priceCard.costUSD(for: resolvedComparisonBreakdown)
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
        let end = endStart.addingTimeInterval(bucketInterval)
        let fiveHourDrop = quotaDropResolution(
            values: fiveHourRemainingPercents,
            observations: fiveHourQuotaObservations,
            lower: lower,
            upper: upper,
            selectionStart: start,
            selectionEnd: end,
            fullSelectionBreakdown: breakdown
        )
        let sevenDayDrop = quotaDropResolution(
            values: sevenDayRemainingPercents,
            observations: sevenDayQuotaObservations,
            lower: lower,
            upper: upper,
            selectionStart: start,
            selectionEnd: end,
            fullSelectionBreakdown: breakdown
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
                quotaDropBasis: fiveHourDrop.basis,
                comparisonBreakdown: fiveHourDrop.comparisonBreakdown,
                comparisonStartDate: fiveHourDrop.comparisonStartDate,
                comparisonEndDate: fiveHourDrop.comparisonEndDate,
                comparisonUsesConservativeBuckets: fiveHourDrop.comparisonUsesConservativeBuckets
            ),
            sevenDay: QuotaConsumptionEstimator.estimate(
                breakdown: breakdown,
                quotaDropPercent: sevenDayDrop.percent,
                priceCard: priceCard,
                quotaDropBasis: sevenDayDrop.basis,
                comparisonBreakdown: sevenDayDrop.comparisonBreakdown,
                comparisonStartDate: sevenDayDrop.comparisonStartDate,
                comparisonEndDate: sevenDayDrop.comparisonEndDate,
                comparisonUsesConservativeBuckets: sevenDayDrop.comparisonUsesConservativeBuckets
            )
        )
    }

    private func quotaDropResolution(
        values: [Double?],
        observations: [QuotaHistoryObservation],
        lower: Int,
        upper: Int,
        selectionStart: Date,
        selectionEnd: Date,
        fullSelectionBreakdown: TokenCacheBreakdown
    ) -> RecentChartQuotaDropResolution {
        if quotaObservationProvenanceAvailable,
           let observed = observedQuotaDropResolution(
               observations: observations,
               lower: lower,
               upper: upper,
               selectionStart: selectionStart,
               selectionEnd: selectionEnd
           ) {
            return observed
        }

        // Display values are sampled at each bucket's end. Include the value
        // immediately before the selected first bucket so this provisional drop
        // spans the same full interval as `fullSelectionBreakdown`.
        let boundaryLower = quotaObservationProvenanceAvailable && lower > 0
            ? lower - 1
            : lower
        let estimatedDrop = cumulativeQuotaDrop(
            values,
            lower: boundaryLower,
            upper: upper
        )
        let estimatedComparisonBreakdown: TokenCacheBreakdown
        let estimatedComparisonStart: Date?
        let estimatedComparisonEnd: Date?
        if quotaObservationProvenanceAvailable, let estimatedDrop {
            let firstCoveredIndex = max(lower, estimatedDrop.firstBoundaryIndex + 1)
            let lastCoveredIndex = min(upper, estimatedDrop.lastBoundaryIndex)
            guard firstCoveredIndex <= lastCoveredIndex else {
                return RecentChartQuotaDropResolution(
                    percent: nil,
                    basis: .unavailable,
                    comparisonBreakdown: .empty,
                    comparisonStartDate: nil,
                    comparisonEndDate: nil,
                    comparisonUsesConservativeBuckets: false
                )
            }
            estimatedComparisonBreakdown = (firstCoveredIndex...lastCoveredIndex)
                .map { cacheBreakdowns[safe: $0] ?? .empty }
                .combined
            estimatedComparisonStart = bins[safe: firstCoveredIndex]?.start
            estimatedComparisonEnd = bins[safe: lastCoveredIndex]?.start
                .addingTimeInterval(bucketInterval)
        } else {
            estimatedComparisonBreakdown = fullSelectionBreakdown
            estimatedComparisonStart = estimatedDrop == nil ? nil : selectionStart
            estimatedComparisonEnd = estimatedDrop == nil ? nil : selectionEnd
        }
        return RecentChartQuotaDropResolution(
            percent: estimatedDrop?.percent,
            basis: estimatedDrop == nil
                ? .unavailable
                : .estimated,
            comparisonBreakdown: estimatedComparisonBreakdown,
            comparisonStartDate: estimatedComparisonStart,
            comparisonEndDate: estimatedComparisonEnd,
            comparisonUsesConservativeBuckets: false
        )
    }

    private func observedQuotaDropResolution(
        observations: [QuotaHistoryObservation],
        lower: Int,
        upper: Int,
        selectionStart: Date,
        selectionEnd: Date
    ) -> RecentChartQuotaDropResolution? {
        let observations = observationSlice(
            observations,
            from: selectionStart,
            through: selectionEnd
        )
        let adjacentObservations = zip(observations, observations.dropFirst())
        guard observations.count >= 2,
              let first = observations.first,
              observations.dropFirst().allSatisfy({
                  sameQuotaCycle(first, $0)
              }),
              adjacentObservations.allSatisfy({ pair in
                  pair.1.remainingPercent <= pair.0.remainingPercent + 0.0001
              }),
              let last = observations.last else {
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

        let percent = zip(availableValues, availableValues.dropFirst())
            .reduce(0) { partial, pair in
                partial + max(pair.0.value - pair.1.value, 0)
            }
        return (
            percent: percent,
            firstBoundaryIndex: availableValues[0].index,
            lastBoundaryIndex: availableValues[availableValues.count - 1].index
        )
    }

    private func sanitizedQuotaDropValues(
        _ values: [(index: Int, value: Double)]
    ) -> [(index: Int, value: Double)] {
        values.enumerated().compactMap { offset, item in
            let previous = offset > 0 ? values[offset - 1].value : nil
            let next = offset + 1 < values.count ? values[offset + 1].value : nil
            if isFullUsageSpike(item.value, previous: previous, next: next) {
                return nil
            }
            return item
        }
    }

    private func isFullUsageSpike(_ value: Double, previous: Double?, next: Double?) -> Bool {
        guard value <= 1, let previous, previous >= 95 else { return false }
        return next == nil || (next ?? 0) >= 95
    }
}
