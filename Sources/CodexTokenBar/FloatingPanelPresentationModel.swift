import Foundation

struct FloatingPanelPresentationRow: Equatable, Identifiable {
    let group: FloatingPanelContentGroup

    var id: FloatingPanelContentGroup { group }
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
        radarPresentation: CodexRadarPresentationState? = nil
    ) {
        let radarPresentation = radarPresentation ?? CodexRadarPresentationState(snapshot: radarSnapshot)
        rows = visibility.layoutGroups.map(FloatingPanelPresentationRow.init(group:))
        rateBarUsageStatus = visibility.embedsUsageStatusInRateRow ? snapshot.compactUsageStatus : nil
        standaloneUsageStatus = visibility.showsStandaloneUsageStatus ? snapshot.standaloneUsageStatus : nil
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
        if visibility.showUsageStatus {
            parts.append(snapshot.compactUsageStatus)
        }
        if visibility.showQuota, let fiveHour = snapshot.quota.fiveHour {
            parts.append("5 小时额度剩余 \(fiveHour.remainingPercent)%，\(fiveHour.accessibleResetText) 重置")
        }
        if visibility.showQuota, let sevenDay = snapshot.quota.sevenDay {
            parts.append("7 天额度剩余 \(sevenDay.remainingPercent)%，\(sevenDay.accessibleResetText) 重置")
        }
        if visibility.showRadar {
            if let radarSnapshot = radarPresentation.snapshot {
                parts.append("雷达建议 \(CodexRadarPresentationText.action(radarSnapshot.recommendedAction))")
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
}
