import Foundation

struct FloatingPanelPresentationRow: Equatable, Identifiable {
    let groups: [FloatingPanelContentGroup]

    var id: String { groups.map(\.rawValue).joined(separator: "|") }
    var group: FloatingPanelContentGroup { groups[0] }
    var isPaged: Bool { groups.count > 1 }
}

struct FloatingPanelPresentationModel: Equatable {
    let rows: [FloatingPanelPresentationRow]
    let rateBarUsageStatus: String?
    let standaloneUsageStatus: String?
    let needsTopSafetyInset: Bool
    let accessibilityParts: [String]

    var accessibilityValue: String {
        accessibilityParts.isEmpty ? "未显示内容" : accessibilityParts.joined(separator: "；")
    }

    init(
        snapshot: TokenDisplaySnapshot,
        visibility: FloatingPanelContentVisibility,
        radarSnapshot: CodexRadarSnapshot? = nil,
        radarPresentation: CodexRadarPresentationState? = nil,
        fallbackPriceModel: OfficialAPIPriceModel = .gpt56Sol
    ) {
        let radarPresentation = radarPresentation ?? CodexRadarPresentationState(snapshot: radarSnapshot)
        rows = visibility.layoutRows.map { FloatingPanelPresentationRow(groups: $0.groups) }
        let resolvedCompactUsageStatus = Self.radarFunUsageStatus(
            for: radarPresentation.snapshot,
            base: snapshot.compactUsageStatus
        ) ?? snapshot.compactUsageStatus
        let resolvedStandaloneUsageStatus = Self.radarFunUsageStatus(
            for: radarPresentation.snapshot,
            base: snapshot.standaloneUsageStatus
        ) ?? snapshot.standaloneUsageStatus
        rateBarUsageStatus = visibility.embedsUsageStatusInRateRow
            ? resolvedCompactUsageStatus
            : nil
        standaloneUsageStatus = visibility.showsStandaloneUsageStatus
            ? resolvedStandaloneUsageStatus
            : nil
        needsTopSafetyInset = visibility.needsTopControlInset

        var parts: [String] = []
        if visibility.showRateAndBar {
            parts.append(String(format: "实时速率 %.1f token 每秒", snapshot.rate))
        }
        if visibility.showMetrics {
            parts.append("累计 \(snapshot.consumedTokensText) token")
            parts.append("今天 \(snapshot.todayTokensText) token")
            parts.append("今天 \(snapshot.todayRequestsText) 次请求")
        }
        if visibility.showRunningThreads {
            parts.append(RunningThreadPresentation(summary: snapshot.runningThreads).accessibilityText)
        }
        if visibility.showTodayModelShare {
            parts.append(FloatingTodayModelUsagePresentation.accessibilityText(
                page: .share,
                rows: snapshot.todayModelBreakdowns,
                fallbackModel: fallbackPriceModel,
                showPlaceholders: snapshot.hasPreciseTokenUsage
            ))
        }
        if visibility.showTodayModelCost {
            parts.append(FloatingTodayModelUsagePresentation.accessibilityText(
                page: .cost,
                rows: snapshot.todayModelBreakdowns,
                fallbackModel: fallbackPriceModel,
                showPlaceholders: snapshot.hasPreciseTokenUsage
            ))
        }
        if visibility.showUsageStatus {
            parts.append(resolvedCompactUsageStatus)
        }
        if visibility.showQuota, let fiveHour = snapshot.quota.fiveHour {
            parts.append("5 小时额度剩余 \(fiveHour.remainingPercent)%，\(fiveHour.accessibleResetText) 重置")
        }
        if visibility.showQuota, let sevenDay = snapshot.quota.sevenDay {
            parts.append("7 天额度剩余 \(sevenDay.remainingPercent)%，\(sevenDay.accessibleResetText) 重置")
        }
        if visibility.showRadar {
            if let radarSnapshot = radarPresentation.snapshot {
                parts.append("雷达建议 \(CodexRadarPresentationText.actionDisplay(snapshot: radarSnapshot))")
                if let primary = radarSnapshot.modelIQ.primaryModelPoint {
                    parts.append(primary.scoreDisplayText)
                }
                if let compactAccessibility = radarPresentation.compactAccessibilityText {
                    parts.append(compactAccessibility)
                }
            } else if let compactAccessibility = radarPresentation.compactAccessibilityText {
                parts.append(compactAccessibility)
            } else {
                parts.append("雷达等待读取")
            }
        }
        accessibilityParts = parts
    }

    private static func radarFunUsageStatus(for snapshot: CodexRadarSnapshot?, base: String) -> String? {
        guard CodexRadarPresentationText.effectiveAction(snapshot: snapshot) == "速登窗口" else {
            return nil
        }
        let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "加快蹬" }
        if let openingParenthesis = normalized.firstIndex(of: "("), openingParenthesis != normalized.startIndex {
            return "加快蹬\(normalized[openingParenthesis...])"
        }
        if normalized == "节奏待读取" {
            return "加快蹬"
        }
        return "加快蹬 · \(normalized)"
    }
}
