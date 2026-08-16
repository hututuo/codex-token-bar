import Foundation

struct SubscriptionSavingsEstimate: Equatable {
    let apiEquivalentUSD: Double
    let subscriptionCostUSD: Double?
    let netSavingsUSD: Double?
    let billingMonths: Int
    let monthlyPlanUSD: Double?
    let normalizedPlanName: String
    /// Fallback only; recorded models are priced automatically when present.
    let priceModel: OfficialAPIPriceModel
    let detectedModels: [OfficialAPIPriceModel]
    let fallbackModelCalls: Int
    let excludedModels: [String]
    let excludedCalls: Int
    let firstUsageAt: Date
}

enum SubscriptionSavingsEstimator {
    static func estimate(
        breakdown: TokenCacheBreakdown,
        modelBreakdowns: [ModelTokenBreakdown] = [],
        firstUsageAt: Date?,
        planLabel: String,
        priceModel: OfficialAPIPriceModel,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SubscriptionSavingsEstimate? {
        guard breakdown.totalTokens > 0,
              let firstUsageAt,
              firstUsageAt <= now else { return nil }

        let billingMonths = billingMonthCount(from: firstUsageAt, through: now, calendar: calendar)
        guard billingMonths > 0 else { return nil }

        let apiPrice = ModelAwareAPIPriceEstimator.estimate(
            modelBreakdowns: modelBreakdowns,
            fallbackBreakdown: breakdown,
            fallbackModel: priceModel,
            rates: { $0.currentPriceRates }
        )
        let apiEquivalentUSD = apiPrice.costUSD
        let normalizedPlanName = normalizedPlanName(planLabel)
        let monthlyPlanUSD = monthlyPlanPriceUSD(planLabel)
        let subscriptionCostUSD = monthlyPlanUSD.map { $0 * Double(billingMonths) }
        let netSavingsUSD = subscriptionCostUSD.map { apiEquivalentUSD - $0 }

        return SubscriptionSavingsEstimate(
            apiEquivalentUSD: apiEquivalentUSD,
            subscriptionCostUSD: subscriptionCostUSD,
            netSavingsUSD: netSavingsUSD,
            billingMonths: billingMonths,
            monthlyPlanUSD: monthlyPlanUSD,
            normalizedPlanName: normalizedPlanName,
            priceModel: priceModel,
            detectedModels: apiPrice.detectedModels,
            fallbackModelCalls: apiPrice.fallbackCalls,
            excludedModels: apiPrice.excludedModels,
            excludedCalls: apiPrice.excludedCalls,
            firstUsageAt: firstUsageAt
        )
    }

    static func billingMonthCount(
        from firstUsageAt: Date,
        through now: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard firstUsageAt <= now else { return 0 }
        let first = calendar.dateComponents([.year, .month], from: firstUsageAt)
        let last = calendar.dateComponents([.year, .month], from: now)
        guard let firstYear = first.year,
              let firstMonth = first.month,
              let lastYear = last.year,
              let lastMonth = last.month else { return 0 }
        return max((lastYear - firstYear) * 12 + lastMonth - firstMonth + 1, 0)
    }

    static func monthlyPlanPriceUSD(_ planLabel: String) -> Double? {
        let normalized = planLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("enterprise")
            || normalized.contains("edu")
            || normalized.contains("health")
            || normalized.contains("gov")
            || normalized.contains("待读取")
            || normalized.contains("unknown") {
            return nil
        }
        if normalized.contains("business") || normalized.contains("team") { return 25 }
        if normalized.contains("plus") { return 20 }
        if normalized.contains("pro") { return 200 }
        if normalized == "free" || normalized.contains("免费") { return 0 }
        return nil
    }

    private static func normalizedPlanName(_ planLabel: String) -> String {
        let trimmed = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "套餐未知" : trimmed.uppercased()
    }
}

struct SubscriptionSavingsPresentation: Equatable {
    let valueText: String
    let labelText: String
    let helpText: String

    init(estimate: SubscriptionSavingsEstimate?) {
        guard let estimate else {
            valueText = "待读取"
            labelText = "累计薅到（估）"
            helpText = "等待精确 token、首次使用时间和套餐信息。"
            return
        }

        if let netSavingsUSD = estimate.netSavingsUSD,
           let subscriptionCostUSD = estimate.subscriptionCostUSD,
           let monthlyPlanUSD = estimate.monthlyPlanUSD {
            valueText = Self.compactMoney(netSavingsUSD)
            labelText = "累计薅到（估）"
            helpText = "\(Self.pricingDescription(estimate))：API 等值 \(Self.fullMoney(estimate.apiEquivalentUSD)) − \(estimate.normalizedPlanName) \(estimate.billingMonths) 个月套餐成本 \(Self.fullMoney(subscriptionCostUSD))（\(Self.fullMoney(monthlyPlanUSD))/月）= \(Self.fullMoney(netSavingsUSD))。历史套餐变化未计入。"
        } else {
            valueText = Self.compactMoney(estimate.apiEquivalentUSD)
            labelText = "API 等值（估）"
            helpText = "\(Self.pricingDescription(estimate))为 \(Self.fullMoney(estimate.apiEquivalentUSD))；\(estimate.normalizedPlanName) 没有公开固定月费，暂不计算净节省。"
        }
    }

    private static func pricingDescription(_ estimate: SubscriptionSavingsEstimate) -> String {
        let models = estimate.detectedModels.map(\.quotaEstimateShortTitle)
        guard !models.isEmpty else {
            if estimate.fallbackModelCalls == 0, !estimate.excludedModels.isEmpty {
                return standaloneExcludedDescription(estimate)
            }
            let fallback = "缺少逐模型历史，按未知模型回退 \(estimate.priceModel.title) 当前 API 单价估算"
            return fallback + excludedDescription(estimate)
        }
        let automatic = "按历史真实模型 \(models.joined(separator: "/")) 的当前 API 单价自动估算"
        let fallback = estimate.fallbackModelCalls > 0
            ? "，另有 \(estimate.fallbackModelCalls) 次未知记录按 \(estimate.priceModel.quotaEstimateShortTitle) 回退"
            : ""
        return automatic + fallback + excludedDescription(estimate)
    }

    private static func excludedDescription(_ estimate: SubscriptionSavingsEstimate) -> String {
        guard !estimate.excludedModels.isEmpty else { return "" }
        return "；\(standaloneExcludedDescription(estimate))"
    }

    private static func standaloneExcludedDescription(_ estimate: SubscriptionSavingsEstimate) -> String {
        "\(estimate.excludedModels.joined(separator: "/")) \(estimate.excludedCalls) 次调用属于独立额度，不参与 API 等值"
    }

    static func compactMoney(_ value: Double) -> String {
        let sign = value < 0 ? "−" : ""
        let amount = abs(value)
        if amount >= 1_000_000 { return "\(sign)$\(String(format: "%.2f", amount / 1_000_000))m" }
        if amount >= 10_000 { return "\(sign)$\(String(format: "%.1f", amount / 1_000))k" }
        if amount >= 1_000 { return "\(sign)$\(String(format: "%.2f", amount / 1_000))k" }
        if amount >= 100 { return "\(sign)$\(String(format: "%.0f", amount))" }
        return "\(sign)$\(String(format: "%.2f", amount))"
    }

    static func fullMoney(_ value: Double) -> String {
        let sign = value < 0 ? "−" : ""
        return "\(sign)$\(String(format: "%.2f", abs(value)))"
    }
}

enum SevenDayAPIValueQuality: Equatable, Sendable {
    /// The current 7d period was covered by a complete, model-aware scan.
    case measured
    /// The exact event stream was unavailable/incomplete; a period-filtered
    /// hourly or recent-bin aggregate was used instead.
    case estimated(source: String)
    /// No trustworthy quota boundary or period usage cache is available.
    case waiting(reason: String)
}

struct SevenDayAPIValueEstimate: Equatable, Sendable {
    let valueUSD: Double?
    let quality: SevenDayAPIValueQuality
    let cycleStart: Date?
    let cycleEnd: Date?
    let detectedModels: [OfficialAPIPriceModel]
    let fallbackModelCalls: Int
    let excludedModels: [String]
    let excludedCalls: Int

    var isAvailable: Bool { valueUSD != nil }

    static func waiting(reason: String) -> SevenDayAPIValueEstimate {
        SevenDayAPIValueEstimate(
            valueUSD: nil,
            quality: .waiting(reason: reason),
            cycleStart: nil,
            cycleEnd: nil,
            detectedModels: [],
            fallbackModelCalls: 0,
            excludedModels: [],
            excludedCalls: 0
        )
    }
}

struct SevenDayAPIValuePresentation: Equatable {
    let valueText: String
    let labelText: String
    let helpText: String

    init(estimate: SevenDayAPIValueEstimate) {
        let label = "本7d API 等值（估）"
        switch estimate.quality {
        case .waiting(let reason):
            valueText = "待读取"
            labelText = "本7d API 等值（待读取）"
            helpText = reason
        case .measured:
            valueText = estimate.valueUSD.map(SubscriptionSavingsPresentation.compactMoney) ?? "待读取"
            labelText = label
            helpText = Self.helpText(for: estimate, quality: "已完成逐事件读取，按历史真实模型的当前 API 单价估算")
        case .estimated(let source):
            valueText = estimate.valueUSD.map(SubscriptionSavingsPresentation.compactMoney) ?? "待读取"
            labelText = "本7d API 等值（估算，精确计算中）"
            helpText = Self.helpText(
                for: estimate,
                quality: "正在精准计算中，先按同周期 " + source + " 快速估算；结果仍可能随精确读取变化"
            )
        }
    }

    private static func helpText(
        for estimate: SevenDayAPIValueEstimate,
        quality: String
    ) -> String {
        var text = "本 7d 周期"
        if let cycleStart = estimate.cycleStart,
           let cycleEnd = estimate.cycleEnd {
            text += "（\(cycleStart.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))-\(cycleEnd.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))）"
        }
        text += "：\(quality)"
        if let valueUSD = estimate.valueUSD {
            text += "，API 等值 \(SubscriptionSavingsPresentation.fullMoney(valueUSD))"
        }
        if !estimate.detectedModels.isEmpty {
            text += "；模型 \(estimate.detectedModels.map(\.quotaEstimateShortTitle).joined(separator: "/"))"
        }
        if estimate.fallbackModelCalls > 0 {
            text += "；另有 \(estimate.fallbackModelCalls) 次未知记录按回退模型估算"
        }
        if !estimate.excludedModels.isEmpty {
            text += "；\(estimate.excludedModels.joined(separator: "/")) \(estimate.excludedCalls) 次调用属于独立额度，不参与 API 等值"
        }
        return text
    }
}

extension SubscriptionSavingsEstimator {
    /// Estimates the API-equivalent value inside the active 7d quota cycle.
    /// The quota reset boundary is authoritative; a lifetime aggregate is
    /// never substituted when that boundary or period cache is unavailable.
    static func sevenDayAPIValue(
        cacheUsage: TokenCacheUsage,
        quotaSnapshot: AccountQuotaSnapshot?,
        fallbackModel: OfficialAPIPriceModel,
        now: Date = Date()
    ) -> SevenDayAPIValueEstimate {
        guard let resetAt = quotaSnapshot?.sevenDay?.resetsAt,
              resetAt.timeIntervalSince1970.isFinite,
              resetAt > now else {
            return .waiting(reason: "7d 额度重置时间未读取或已过期，暂不把累计历史冒充当前周期。")
        }

        let cycleStart = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let cycleEnd = resetAt
        let eventIsTrustworthy = cacheUsage.attributionEventsComplete
            && !cacheUsage.attributionCurrentScanUnsafeCauseDetected
            && !cacheUsage.attributionSourceMutationDetected
        let periodEvents = cacheUsage.attributionEvents.filter {
            $0.start >= cycleStart && $0.start < cycleEnd
        }

        if eventIsTrustworthy {
            let periodBreakdown = periodEvents.map(\.breakdown).combined
            let price = ModelAwareAPIPriceEstimator.estimate(
                events: periodEvents,
                fallbackBreakdown: periodBreakdown,
                fallbackModel: fallbackModel,
                rates: { $0.currentPriceRates }
            )
            return SevenDayAPIValueEstimate(
                valueUSD: price.costUSD,
                quality: .measured,
                cycleStart: cycleStart,
                cycleEnd: cycleEnd,
                detectedModels: price.detectedModels,
                fallbackModelCalls: price.fallbackCalls,
                excludedModels: price.excludedModels,
                excludedCalls: price.excludedCalls
            )
        }

        let fallbackBuckets: ([TokenCacheBucket], String)
        let recent = periodBuckets(cacheUsage.recentBins, start: cycleStart, end: cycleEnd)
        if !recent.isEmpty {
            fallbackBuckets = (recent, "5分钟桶用量缓存")
        } else {
            // Keep a compatibility fallback for very old snapshots that were
            // written before the five-minute canvas existed. New snapshots
            // always prefer the five-minute path above.
            let hourly = periodBuckets(cacheUsage.hourly, start: cycleStart, end: cycleEnd)
            fallbackBuckets = (hourly, "旧版 hourly 用量缓存")
        }
        guard !fallbackBuckets.0.isEmpty else {
            return SevenDayAPIValueEstimate(
                valueUSD: nil,
                quality: .waiting(reason: "7d 额度边界已读取，但同周期用量缓存仍在读取，暂不显示累计金额。"),
                cycleStart: cycleStart,
                cycleEnd: cycleEnd,
                detectedModels: [],
                fallbackModelCalls: 0,
                excludedModels: [],
                excludedCalls: 0
            )
        }

        let periodBreakdown = fallbackBuckets.0.map(\.breakdown).combined
        let price = ModelAwareAPIPriceEstimator.estimate(
            // Keep any known independent-quota rows out of the aggregate even
            // when the event stream is incomplete. The remaining uncovered
            // bucket usage still uses the selected fallback model.
            modelBreakdowns: periodEvents.map {
                ModelTokenBreakdown(model: $0.model, breakdown: $0.breakdown)
            },
            fallbackBreakdown: periodBreakdown,
            fallbackModel: fallbackModel,
            rates: { $0.currentPriceRates }
        )
        return SevenDayAPIValueEstimate(
            valueUSD: price.costUSD,
            quality: .estimated(source: fallbackBuckets.1),
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            detectedModels: price.detectedModels,
            fallbackModelCalls: price.fallbackCalls,
            excludedModels: price.excludedModels,
            excludedCalls: price.excludedCalls
        )
    }

    private static func periodBuckets(
        _ buckets: [TokenCacheBucket],
        start: Date,
        end: Date
    ) -> [TokenCacheBucket] {
        buckets.filter { bucket in
            bucket.start >= start && bucket.start < end
        }
    }
}
