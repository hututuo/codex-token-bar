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

    init(title: String, estimate: QuotaConsumptionEstimate) {
        self.title = title
        accessibilityLabel = "\(title) 额度估算"

        switch estimate.confidence {
        case .measured:
            detail = "\(estimate.quotaEstimatorBudgetText) · 降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
            accessibilityText = "反推总额度 \(estimate.quotaEstimatorBudgetText)，下降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
        case .insufficientQuotaMovement:
            detail = "下降太小"
            accessibilityText = "额度下降太小，不能反推"
        case .noTokenUsage:
            detail = "无 token"
            accessibilityText = "没有 token 用量"
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
    let cacheHitText: String
    let fiveHourChip: QuotaConsumptionEstimatePresentation
    let sevenDayChip: QuotaConsumptionEstimatePresentation
    let budgetRatioText: String
    let showsRatioWarning: Bool
    let ratioWarningText: String?
    let ratioWarningDetailText: String?
    let accessibilityValue: String

    init(selection: QuotaConsumptionSelection) {
        costText = selection.breakdown.quotaEstimatorCostText(selection.priceCard)
        timeRangeText = selection.quotaEstimatorTimeRangeText
        cacheHitText = "命中 \(selection.breakdown.cacheHitRate.percentString)"
        fiveHourChip = QuotaConsumptionEstimatePresentation(title: "5h", estimate: selection.fiveHour)
        sevenDayChip = QuotaConsumptionEstimatePresentation(title: "7d", estimate: selection.sevenDay)
        budgetRatioText = selection.quotaEstimatorBudgetRatioText
        showsRatioWarning = selection.hasDivergentBudgetRatio
        ratioWarningText = selection.hasDivergentBudgetRatio ? "偏离 6x，误差可能较大" : nil
        ratioWarningDetailText = selection.hasDivergentBudgetRatio
            ? "可能因 7d 下降太少、颗粒度太低或其他误差。"
            : nil
        accessibilityValue = "本段消耗 \(costText)，5 小时 \(fiveHourChip.accessibilityText)，7 天 \(sevenDayChip.accessibilityText)，倍率 \(budgetRatioText)"
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
