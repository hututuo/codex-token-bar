import Foundation

struct RecentChartQuotaEstimateModelOptionPresentation: Equatable {
    let groupLabel: String
    let shortTitle: String
    let accessibilityLabel: String
    let accessibilityValue: String
}

enum RecentChartQuotaEstimateAffordancePresentation {
    static let headerLabel = "点击图表估算额度"
    static let headerHelp = "第一下定起点，移动鼠标实时预览，第二下固定终点；再次点击重新选择。"
    static let inlineInstruction = "第一下定起点，移动实时预览，第二下固定终点；第三下重新选择。"
    static let hoverInstruction = "点击起点/终点可估算额度"
    static let hoverAccessibilityPrompt = "点击图表可估算额度"

    static func modelOption(
        for model: OfficialAPIPriceModel,
        selectedModel: OfficialAPIPriceModel
    ) -> RecentChartQuotaEstimateModelOptionPresentation {
        RecentChartQuotaEstimateModelOptionPresentation(
            groupLabel: "官方 API",
            shortTitle: model.quotaEstimateShortTitle,
            accessibilityLabel: "官方 API 定价 \(model.title)",
            accessibilityValue: selectedModel == model ? "已选择" : "未选择"
        )
    }
}

struct QuotaConsumptionEstimatePresentation: Equatable {
    let title: String
    let detail: String
    let accessibilityLabel: String
    let accessibilityText: String

    init(title: String, estimate: QuotaConsumptionEstimate, isQuotaAvailable: Bool = true) {
        self.title = title
        accessibilityLabel = "\(title) 额度估算"

        guard isQuotaAvailable else {
            detail = "无 \(title) 额度"
            accessibilityText = "当前无 \(Self.accessibilityWindowName(title))额度"
            return
        }

        switch estimate.confidence {
        case .measured:
            detail = "\(estimate.quotaEstimatorBudgetText) · 降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
            accessibilityText = "反推总额度 \(estimate.quotaEstimatorBudgetText)，下降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
        case .insufficientQuotaMovement:
            detail = "降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent) · 不反推"
            accessibilityText = "额度下降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)，不能反推总额度"
        case .noTokenUsage:
            detail = "无 token"
            accessibilityText = "没有 token 用量"
        }
    }

    private static func accessibilityWindowName(_ title: String) -> String {
        switch title {
        case "5h": "5 小时"
        case "7d": "7 天"
        default: "\(title) "
        }
    }
}

struct QuotaConsumptionEstimatorOverlayPresentation: Equatable {
    let costTitle = "本段消耗"
    let estimateTitle = "反推总额度"
    let ratioTitle = "倍率"
    let ratioHelpText = "7d/5h，正常约 6x"
    let closeAccessibilityLabel = "关闭额度估算"
    let accessibilityLabel = "额度估算"

    let costText: String
    let timeRangeText: String
    let durationText: String
    let cacheHitText: String
    let fiveHourChip: QuotaConsumptionEstimatePresentation
    let sevenDayChip: QuotaConsumptionEstimatePresentation
    let budgetRatioText: String
    let showsBudgetRatio: Bool
    let showsRatioWarning: Bool
    let ratioWarningText: String?
    let ratioWarningDetailText: String?
    let accessibilityValue: String

    init(
        selection: QuotaConsumptionSelection,
        showsFiveHourQuota: Bool = true,
        showsSevenDayQuota: Bool = true,
        currentFiveHourQuotaPresent: Bool = true,
        currentSevenDayQuotaPresent: Bool = true
    ) {
        costText = selection.breakdown.quotaEstimatorCostText(selection.priceCard)
        timeRangeText = selection.quotaEstimatorTimeRangeText
        durationText = selection.quotaEstimatorDurationText
        cacheHitText = "命中 \(selection.breakdown.cacheHitRate.percentString)"
        fiveHourChip = QuotaConsumptionEstimatePresentation(
            title: "5h",
            estimate: selection.fiveHour,
            isQuotaAvailable: currentFiveHourQuotaPresent
        )
        sevenDayChip = QuotaConsumptionEstimatePresentation(
            title: "7d",
            estimate: selection.sevenDay,
            isQuotaAvailable: currentSevenDayQuotaPresent
        )
        budgetRatioText = selection.quotaEstimatorBudgetRatioText
        showsBudgetRatio = showsFiveHourQuota
            && showsSevenDayQuota
            && currentFiveHourQuotaPresent
            && currentSevenDayQuotaPresent
        showsRatioWarning = showsBudgetRatio && selection.hasDivergentBudgetRatio
        ratioWarningText = showsRatioWarning ? "偏离 6x，误差可能较大" : nil
        ratioWarningDetailText = showsRatioWarning
            ? "可能因 7d 下降太少、颗粒度太低或其他误差。"
            : nil
        var accessibilityParts = [
            "选区 \(timeRangeText)，\(durationText)",
            "本段消耗 \(costText)"
        ]
        if showsFiveHourQuota { accessibilityParts.append("5 小时 \(fiveHourChip.accessibilityText)") }
        if showsSevenDayQuota { accessibilityParts.append("7 天 \(sevenDayChip.accessibilityText)") }
        if showsBudgetRatio { accessibilityParts.append("倍率 \(budgetRatioText)") }
        accessibilityValue = accessibilityParts.joined(separator: "，")
    }
}

extension OfficialAPIPriceModel {
    var quotaEstimateShortTitle: String {
        switch self {
        case .gpt55: "5.5"
        case .gpt54: "5.4"
        case .gpt54Mini: "mini"
        }
    }
}

extension QuotaConsumptionSelection {
    var quotaEstimatorTimeRangeText: String {
        "\(DateFormatter.hourMinute.string(from: startDate))-\(DateFormatter.hourMinute.string(from: endDate))"
    }

    var quotaEstimatorDurationText: String {
        let totalSeconds = max(Int(endDate.timeIntervalSince(startDate).rounded()), 0)
        guard totalSeconds >= 60 else { return "持续 \(totalSeconds)秒" }

        let totalMinutes = totalSeconds / 60
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)天") }
        if hours > 0 { parts.append("\(hours)小时") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes)分钟") }
        return "持续 \(parts.joined())"
    }

    var quotaEstimatorBudgetRatioText: String {
        guard let sevenDayToFiveHourBudgetRatio else { return "--" }
        return String(format: "%.1fx", sevenDayToFiveHourBudgetRatio)
    }
}

extension QuotaConsumptionEstimate {
    var quotaEstimatorBudgetText: String {
        guard let impliedWindowBudgetUSD else { return "--" }
        return "$\(Self.quotaEstimatorMoneyString(impliedWindowBudgetUSD))"
    }

    static func quotaEstimatorMoneyString(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}

extension TokenCacheBreakdown {
    func quotaEstimatorCostText(_ priceCard: QuotaConsumptionPriceCard) -> String {
        "$\(QuotaConsumptionEstimate.quotaEstimatorMoneyString(priceCard.costUSD(for: self)))"
    }
}

extension Double {
    var quotaEstimatorOneDecimalPercent: String {
        if rounded() == self {
            return "\(Int(self))%"
        }
        return String(format: "%.1f%%", self)
    }
}
