import Foundation

struct QuotaSelectionAttributionContext: Equatable {
    let sourceState: SharedAccountUsageAttributionState
    let tier: SharedAccountRadarTier
    let model: OfficialAPIPriceModel
    let priceRevision: SharedAccountRadarPriceRevision
    let cycleStart: Date?
    let cycleEnd: Date?
    let localSegmentStart: Date?
    let quotaUpdatedAt: Date?
    let radarSevenDayTotalUSD: Double?
    let radarBasis: String?
    let radarDate: String?
    let radarPricingBasisDate: String?
    let radarUpdatedAt: String?
    let radarSource: String?
    let quotaDataStale: Bool
    let radarDataStale: Bool
    let usagePendingQuotaRefresh: Bool
    let localHistoryAmbiguous: Bool
    let usedHighWatermark: Bool
    let hasFinalAttributionConclusion: Bool

    init(
        sourceState: SharedAccountUsageAttributionState,
        tier: SharedAccountRadarTier,
        model: OfficialAPIPriceModel,
        priceRevision: SharedAccountRadarPriceRevision,
        cycleStart: Date?,
        cycleEnd: Date?,
        localSegmentStart: Date?,
        quotaUpdatedAt: Date?,
        radarSevenDayTotalUSD: Double?,
        radarBasis: String?,
        radarDate: String?,
        radarPricingBasisDate: String?,
        radarUpdatedAt: String?,
        radarSource: String?,
        quotaDataStale: Bool,
        radarDataStale: Bool,
        usagePendingQuotaRefresh: Bool,
        localHistoryAmbiguous: Bool,
        usedHighWatermark: Bool,
        hasFinalAttributionConclusion: Bool
    ) {
        self.sourceState = sourceState
        self.tier = tier
        self.model = model
        self.priceRevision = priceRevision
        self.cycleStart = cycleStart
        self.cycleEnd = cycleEnd
        self.localSegmentStart = localSegmentStart
        self.quotaUpdatedAt = quotaUpdatedAt
        self.radarSevenDayTotalUSD = radarSevenDayTotalUSD
        self.radarBasis = radarBasis
        self.radarDate = radarDate
        self.radarPricingBasisDate = radarPricingBasisDate
        self.radarUpdatedAt = radarUpdatedAt
        self.radarSource = radarSource
        self.quotaDataStale = quotaDataStale
        self.radarDataStale = radarDataStale
        self.usagePendingQuotaRefresh = usagePendingQuotaRefresh
        self.localHistoryAmbiguous = localHistoryAmbiguous
        self.usedHighWatermark = usedHighWatermark
        self.hasFinalAttributionConclusion = hasFinalAttributionConclusion
    }

    init(result: SharedAccountUsageAttributionResult) {
        sourceState = result.state
        tier = result.tier
        model = result.model
        priceRevision = result.priceRevision
        cycleStart = result.cycleStart
        cycleEnd = result.cycleEnd
        localSegmentStart = result.localSegmentStart
        quotaUpdatedAt = result.quotaUpdatedAt
        radarSevenDayTotalUSD = result.radarSevenDayTotalUSD
        radarBasis = result.radarBasis
        radarDate = result.radarDate
        radarPricingBasisDate = result.radarPricingBasisDate
        radarUpdatedAt = result.radarUpdatedAt
        radarSource = result.radarSource
        quotaDataStale = result.quotaDataStale
        radarDataStale = result.radarDataStale
        usagePendingQuotaRefresh = result.usagePendingQuotaRefresh
        localHistoryAmbiguous = result.localHistoryAmbiguous
        usedHighWatermark = result.usedHighWatermark
        hasFinalAttributionConclusion = result.hasFinalAttributionConclusion
    }
}

enum QuotaSelectionAttributionState: Equatable {
    case withinTolerance
    case suspectedNonLocalUsage
    case localEstimateExceedsAccountDrop
    case provisional
    case missingQuotaHistory
    case missingRadarTierBaseline
    case missingCompatiblePriceRevision
}

struct QuotaSelectionAttributionResult: Equatable {
    let state: QuotaSelectionAttributionState
    let tier: SharedAccountRadarTier
    /// Fallback only; known records use their detected models automatically.
    let model: OfficialAPIPriceModel
    let detectedModels: [OfficialAPIPriceModel]
    let fallbackModelCalls: Int
    let excludedModels: [String]
    let excludedCalls: Int
    let priceRevision: SharedAccountRadarPriceRevision
    let accountDropBasis: QuotaConsumptionDropBasis
    let accountDropPercent: Double?
    let localComparableCostUSD: Double?
    let localCurrentOfficialCostUSD: Double
    let radarSevenDayTotalUSD: Double?
    let localSharePercent: Double?
    let nonLocalDifferencePercent: Double?
    let allowsAttributionConclusion: Bool
    let caveats: [String]
    let radarBasis: String?
    let radarDate: String?
    let radarPricingBasisDate: String?
    let radarUpdatedAt: String?
    let radarSource: String?
}

enum QuotaSelectionAttributionEstimator {
    static let comparisonTolerancePercent = 2.0
    static let quotaBucketDuration: TimeInterval = 5 * 60

    static func estimate(
        selection: QuotaConsumptionSelection,
        context: QuotaSelectionAttributionContext
    ) -> QuotaSelectionAttributionResult {
        let model = selection.fallbackPriceModel
        let attributionBreakdown = selection.sevenDayAttributionBreakdown
        let currentOfficialEstimate = selection.sevenDayCurrentAPIPriceEstimate
        let currentOfficialCost = currentOfficialEstimate.costUSD
        let accountDrop = selection.sevenDay.quotaDropBasis != .unavailable
            ? selection.sevenDay.quotaDropPercent
            : nil
        let radarTotal = context.radarSevenDayTotalUSD.flatMap { total in
            total.isFinite && total > 0 ? total : nil
        }
        let comparableEstimate: ModelAwareAPIPriceEstimate? = if context.priceRevision != .unavailable {
            ModelAwareAPIPriceEstimator.estimate(
                events: selection.sevenDayAttributionEvents,
                fallbackBreakdown: attributionBreakdown,
                fallbackModel: model,
                rates: { context.priceRevision.rates(for: $0) ?? $0.currentPriceRates }
            )
        } else {
            nil
        }
        let radarComparableCost = comparableEstimate?.costUSD
        let radarLocalShare: Double? = if let radarComparableCost, let radarTotal {
            radarComparableCost / radarTotal * 100
        } else {
            nil
        }

        guard let accountDrop else {
            return unavailable(
                .missingQuotaHistory,
                context: context,
                model: model,
                currentOfficialEstimate: currentOfficialEstimate,
                comparableEstimate: comparableEstimate,
                localSharePercent: radarLocalShare,
                radarTotal: radarTotal,
                caveats: ["选区内至少需要两个有效的 7 天额度观测点。"]
            )
        }

        guard let radarTotal else {
            return unavailable(
                .missingRadarTierBaseline,
                context: context,
                model: model,
                currentOfficialEstimate: currentOfficialEstimate,
                comparableEstimate: comparableEstimate,
                accountDrop: accountDrop,
                accountDropBasis: selection.sevenDay.quotaDropBasis,
                caveats: ["Codex Radar 尚未提供所选套餐的 7 天总额。"]
            )
        }

        guard let comparableEstimate else {
            return unavailable(
                .missingCompatiblePriceRevision,
                context: context,
                model: model,
                currentOfficialEstimate: currentOfficialEstimate,
                accountDrop: accountDrop,
                accountDropBasis: selection.sevenDay.quotaDropBasis,
                radarTotal: radarTotal,
                caveats: ["Radar 套餐总额与当前模型价格没有可核对的同版本口径。"]
            )
        }

        let comparableCost = comparableEstimate.costUSD
        let localShare = comparableCost / radarTotal * 100
        let difference = accountDrop - localShare
        let caveats = safetyCaveats(
            selection: selection,
            context: context
        )
        let allowsConclusion = caveats.isEmpty
        let state: QuotaSelectionAttributionState
        if !allowsConclusion {
            state = .provisional
        } else if abs(difference) <= comparisonTolerancePercent {
            state = .withinTolerance
        } else if difference > comparisonTolerancePercent {
            state = .suspectedNonLocalUsage
        } else {
            state = .localEstimateExceedsAccountDrop
        }

        return QuotaSelectionAttributionResult(
            state: state,
            tier: context.tier,
            model: model,
            detectedModels: comparableEstimate.detectedModels,
            fallbackModelCalls: comparableEstimate.fallbackCalls,
            excludedModels: comparableEstimate.excludedModels,
            excludedCalls: comparableEstimate.excludedCalls,
            priceRevision: context.priceRevision,
            accountDropBasis: selection.sevenDay.quotaDropBasis,
            accountDropPercent: accountDrop,
            localComparableCostUSD: comparableCost,
            localCurrentOfficialCostUSD: currentOfficialCost,
            radarSevenDayTotalUSD: radarTotal,
            localSharePercent: localShare,
            nonLocalDifferencePercent: difference,
            allowsAttributionConclusion: allowsConclusion,
            caveats: caveats,
            radarBasis: context.radarBasis,
            radarDate: context.radarDate,
            radarPricingBasisDate: context.radarPricingBasisDate,
            radarUpdatedAt: context.radarUpdatedAt,
            radarSource: context.radarSource
        )
    }

    private static func safetyCaveats(
        selection: QuotaConsumptionSelection,
        context: QuotaSelectionAttributionContext
    ) -> [String] {
        var caveats: [String] = []

        if !context.hasFinalAttributionConclusion {
            caveats.append(sourceStateCaveat(context.sourceState))
        }
        if context.quotaDataStale {
            caveats.append("账户额度是保留的旧数据。")
        }
        if context.radarDataStale {
            caveats.append("Radar 套餐基准是保留的旧数据。")
        }
        if context.usagePendingQuotaRefresh {
            caveats.append("本机已有尚未被下一次额度观测覆盖的用量。")
        }
        if context.localHistoryAmbiguous {
            caveats.append("本机精确历史存在无法安全消解的重复或改写。")
        }
        if context.usedHighWatermark {
            caveats.append("整周期归因使用了归档高水位保护，而图表选区只含当前原始桶。")
        }
        if selection.sevenDay.quotaDropEstimated {
            caveats.append("选区 7 天额度下降来自沿用或插值图表值，仅作暂算。")
        }
        if selection.sevenDay.comparisonUsesConservativeBuckets {
            caveats.append("额度观测落在聚合桶内部，本机归因只计入边界完整桶并首尾留一分钟余量，仅作暂算。")
        }
        if let cycleStart = context.cycleStart,
           selection.startDate < cycleStart {
            caveats.append("选区跨到当前 7 天额度周期之前。")
        }
        if let cycleEnd = context.cycleEnd,
           selection.endDate > cycleEnd {
            caveats.append("选区跨过当前 7 天额度重置边界。")
        }
        if let segmentStart = context.localSegmentStart,
           selection.startDate < segmentStart {
            caveats.append("选区跨过账号切换或数据连续性安全基线。")
        }
        if let quotaUpdatedAt = context.quotaUpdatedAt {
            let coveredBoundary = Date(
                timeIntervalSince1970: floor(
                    quotaUpdatedAt.timeIntervalSince1970 / quotaBucketDuration
                ) * quotaBucketDuration
            )
            if selection.endDate > coveredBoundary {
                caveats.append("选区末端尚未被一个完整的额度观测桶覆盖。")
            }
        } else {
            caveats.append("缺少账户额度更新时间。")
        }

        return deduplicated(caveats)
    }

    private static func sourceStateCaveat(
        _ state: SharedAccountUsageAttributionState
    ) -> String {
        switch state {
        case .disabled: "共享账号归因已关闭。"
        case .preciseUsagePending: "精确 token 仍在读取。"
        case .preciseUsageStale: "精确 token 需要刷新。"
        case .attributionStorageUnavailable: "归因安全记录不可用。"
        case .awaitingAccountSwitchBaseline: "正在等待账号或连续性安全基线。"
        case .missingSevenDayQuota: "缺少 7 天额度。"
        case .missingQuotaReset: "缺少 7 天额度重置时间。"
        case .missingStableAccountIdentity: "缺少稳定账号身份。"
        case .missingRadarTierBaseline: "缺少 Radar 套餐基准。"
        case .missingCompatiblePriceRevision: "Radar 价格版本未知。"
        case .awaitingQuotaRefresh: "等待额度与本机用量对齐。"
        case .localHistoryAmbiguous: "本机历史无法安全对账。"
        case .withinTolerance, .suspectedNonLocalUsage, .localEstimateExceedsAccountDrop:
            "当前整周期结论尚未通过安全门禁。"
        }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func unavailable(
        _ state: QuotaSelectionAttributionState,
        context: QuotaSelectionAttributionContext,
        model: OfficialAPIPriceModel,
        currentOfficialEstimate: ModelAwareAPIPriceEstimate,
        comparableEstimate: ModelAwareAPIPriceEstimate? = nil,
        localSharePercent: Double? = nil,
        accountDrop: Double? = nil,
        accountDropBasis: QuotaConsumptionDropBasis = .unavailable,
        radarTotal: Double? = nil,
        caveats: [String]
    ) -> QuotaSelectionAttributionResult {
        QuotaSelectionAttributionResult(
            state: state,
            tier: context.tier,
            model: model,
            detectedModels: (comparableEstimate ?? currentOfficialEstimate).detectedModels,
            fallbackModelCalls: (comparableEstimate ?? currentOfficialEstimate).fallbackCalls,
            excludedModels: (comparableEstimate ?? currentOfficialEstimate).excludedModels,
            excludedCalls: (comparableEstimate ?? currentOfficialEstimate).excludedCalls,
            priceRevision: context.priceRevision,
            accountDropBasis: accountDropBasis,
            accountDropPercent: accountDrop,
            localComparableCostUSD: comparableEstimate?.costUSD,
            localCurrentOfficialCostUSD: currentOfficialEstimate.costUSD,
            radarSevenDayTotalUSD: radarTotal,
            localSharePercent: localSharePercent,
            nonLocalDifferencePercent: nil,
            allowsAttributionConclusion: false,
            caveats: caveats,
            radarBasis: context.radarBasis,
            radarDate: context.radarDate,
            radarPricingBasisDate: context.radarPricingBasisDate,
            radarUpdatedAt: context.radarUpdatedAt,
            radarSource: context.radarSource
        )
    }
}
