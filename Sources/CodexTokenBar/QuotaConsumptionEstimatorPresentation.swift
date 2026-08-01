import Foundation

enum RecentChartQuotaEstimateAffordancePresentation {
    static let headerLabel = "点击图表估算额度"
    static let headerHelp = "第一下定起点，移动鼠标实时预览，第二下固定终点；再次点击重新选择。"
    static let inlineInstruction = "第一下定起点，移动实时预览，第二下固定终点；第三下重新选择。"
    static let hoverInstruction = "点击起点/终点可估算额度"
    static let hoverAccessibilityPrompt = "点击图表可估算额度"

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

        guard estimate.quotaDropBasis != .unavailable else {
            detail = "\(title) 样本不足"
            accessibilityText = "选区内缺少足够的 \(Self.accessibilityWindowName(title))额度样本"
            return
        }

        switch estimate.confidence {
        case .measured:
            if estimate.comparisonUsesConservativeBuckets {
                detail = "≈\(estimate.quotaEstimatorBudgetText) · 边界暂算降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
                accessibilityText = "额度观测位于聚合桶边界，本机用量按首尾整桶保守计入，暂算总额度 \(estimate.quotaEstimatorBudgetText)，暂算下降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
            } else if estimate.quotaDropEstimated {
                detail = "≈\(estimate.quotaEstimatorBudgetText) · 暂算降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
                accessibilityText = "根据沿用或插值额度暂算总额度 \(estimate.quotaEstimatorBudgetText)，暂算下降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
            } else {
                detail = "\(estimate.quotaEstimatorBudgetText) · 降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
                accessibilityText = "反推总额度 \(estimate.quotaEstimatorBudgetText)，下降 \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)"
            }
        case .insufficientQuotaMovement:
            let prefix = if estimate.comparisonUsesConservativeBuckets {
                "边界暂算降"
            } else if estimate.quotaDropEstimated {
                "暂算降"
            } else {
                "降"
            }
            detail = "\(prefix) \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent) · 不反推"
            let dropDescription = if estimate.comparisonUsesConservativeBuckets {
                "额度观测位于聚合桶边界，本机用量按首尾整桶保守计入，暂算下降"
            } else if estimate.quotaDropEstimated {
                "根据沿用或插值额度暂算下降"
            } else {
                "额度下降"
            }
            accessibilityText = "\(dropDescription) \(estimate.quotaDropPercent.quotaEstimatorOneDecimalPercent)，不能反推总额度"
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

struct QuotaConsumptionComparisonCoveragePresentation: Equatable {
    let sectionTitle: String
    let sourceTitle: String

    init(
        basis: QuotaConsumptionDropBasis,
        usesConservativeBuckets: Bool = false
    ) {
        switch basis {
        case .observed:
            if usesConservativeBuckets {
                sectionTitle = "7d 保守整桶归因统计"
                sourceTitle = "保守整桶计入范围"
            } else {
                sectionTitle = "7d 观测覆盖内归因统计"
                sourceTitle = "额度观测覆盖"
            }
        case .estimated:
            sectionTitle = "7d 暂算覆盖内归因统计"
            sourceTitle = "额度暂算覆盖"
        case .unavailable:
            sectionTitle = "7d 可比范围内归因统计"
            sourceTitle = "额度可比范围"
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
        costText = selection.fullCurrentAPIPriceEstimate.costUSD.quotaEstimatorMoneyText
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
        let budgetRatioIsProvisional = selection.fiveHour.quotaDropEstimated
            || selection.sevenDay.quotaDropEstimated
            || selection.fiveHour.comparisonUsesConservativeBuckets
            || selection.sevenDay.comparisonUsesConservativeBuckets
        let rawBudgetRatioText = selection.quotaEstimatorBudgetRatioText
        budgetRatioText = budgetRatioIsProvisional
            && selection.sevenDayToFiveHourBudgetRatio != nil
            ? "≈\(rawBudgetRatioText)"
            : rawBudgetRatioText
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

struct QuotaSelectionAttributionPresentation: Equatable {
    let accountTitle: String
    let localTitle = "本机折算"
    let differenceTitle: String

    let accountText: String
    let localText: String
    let differenceText: String
    let stateText: String
    let localFormula: String
    let differenceFormula: String
    let accessibilityValue: String

    init(result: QuotaSelectionAttributionResult) {
        switch result.accountDropBasis {
        case .observed:
            accountTitle = "账号实降"
        case .estimated:
            accountTitle = "账号暂降"
        case .unavailable:
            accountTitle = "账号下降"
        }
        accountText = result.accountDropPercent.map {
            result.accountDropBasis == .estimated ? "≈\(Self.percent($0))" : Self.percent($0)
        } ?? "--"
        localText = result.localSharePercent.map { "≈\(Self.percent($0))" } ?? "--"

        switch result.state {
        case .suspectedNonLocalUsage:
            differenceTitle = "疑似他人"
            differenceText = result.nonLocalDifferencePercent
                .map { "≈\(Self.percent(max($0, 0)))" } ?? "--"
            stateText = "正差超过 2 个百分点"
        case .withinTolerance:
            differenceTitle = "差额"
            differenceText = result.nonLocalDifferencePercent.map(Self.signedPercent) ?? "--"
            stateText = "差值在估算误差内"
        case .localEstimateExceedsAccountDrop:
            differenceTitle = "本机估高"
            differenceText = result.nonLocalDifferencePercent
                .map { Self.percent(abs($0)) } ?? "--"
            stateText = "本机估值高于账号实降"
        case .provisional:
            differenceTitle = "暂算差额"
            differenceText = result.nonLocalDifferencePercent.map(Self.signedPercent) ?? "--"
            stateText = "安全基线未完全覆盖，不归因到他人"
        case .missingQuotaHistory:
            differenceTitle = "差额"
            differenceText = "--"
            stateText = "选区 7 天额度样本不足"
        case .missingRadarTierBaseline:
            differenceTitle = "差额"
            differenceText = "--"
            stateText = "Radar 套餐总额缺失"
        case .missingCompatiblePriceRevision:
            differenceTitle = "差额"
            differenceText = "--"
            stateText = "Radar 价格版本未知"
        }

        if let localCost = result.localComparableCostUSD,
           let radarTotal = result.radarSevenDayTotalUSD,
           let localShare = result.localSharePercent {
            localFormula = "本机占比 = \(Self.money(localCost)) ÷ \(Self.money(radarTotal)) × 100 = \(Self.percent(localShare))"
        } else {
            localFormula = "本机占比 = 本机同基准金额 ÷ Radar \(result.tier.title) 7 天总额 × 100"
        }

        let accountTerm = switch result.accountDropBasis {
        case .observed: "账号实降"
        case .estimated: "账号暂算下降"
        case .unavailable: "账号下降"
        }
        if let account = result.accountDropPercent,
           let local = result.localSharePercent,
           let difference = result.nonLocalDifferencePercent {
            let label = result.allowsAttributionConclusion ? "非本机差额" : "暂算差额"
            differenceFormula = "\(label) = \(accountTerm) \(Self.percent(account)) − 本机 \(Self.percent(local)) = \(Self.signedPercent(difference))"
        } else {
            differenceFormula = "差额 = \(accountTerm) − 本机折算占比"
        }

        accessibilityValue = [
            "\(accountTitle) \(accountText)",
            "本机折算 \(localText)",
            "\(differenceTitle) \(differenceText)",
            stateText,
        ].joined(separator: "，")
    }

    static func percent(_ value: Double) -> String {
        value.quotaEstimatorOneDecimalPercent
    }

    static func signedPercent(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%+d%%", Int(value))
        }
        return String(format: "%+.1f%%", value)
    }

    static func money(_ value: Double) -> String {
        "$\(QuotaConsumptionEstimate.quotaEstimatorMoneyString(value))"
    }
}

extension OfficialAPIPriceModel {
    var quotaEstimateShortTitle: String {
        switch self {
        case .gpt56Sol: "Sol"
        case .gpt56Terra: "Terra"
        case .gpt56Luna: "Luna"
        }
    }
}

extension ModelAwareAPIPriceEstimate {
    func pricingModelText(fallbackModel: OfficialAPIPriceModel) -> String {
        let detected = detectedModels.map(\.quotaEstimateShortTitle)
        guard !detected.isEmpty else {
            return "未知回退 \(fallbackModel.quotaEstimateShortTitle)"
        }
        let automatic = "自动 · \(detected.joined(separator: "/"))"
        guard fallbackCalls > 0 else { return automatic }
        return "\(automatic) + 未知→\(fallbackModel.quotaEstimateShortTitle)"
    }
}

extension QuotaSelectionAttributionResult {
    var pricingModelText: String {
        ModelAwareAPIPriceEstimate(
            costUSD: localCurrentOfficialCostUSD,
            detectedModels: detectedModels,
            fallbackCalls: fallbackModelCalls
        ).pricingModelText(fallbackModel: model)
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

extension Double {
    var quotaEstimatorMoneyText: String {
        "$\(QuotaConsumptionEstimate.quotaEstimatorMoneyString(self))"
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
