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
