import Foundation

enum FloatingPanelContentGroup: String, CaseIterable, Identifiable {
    case rateAndBar
    case usageStatus
    case metrics
    case quota

    var id: String { rawValue }
}

struct FloatingPanelContentVisibility: Equatable, Sendable {
    static let rateAndBarKey = "floatingPanelShowRateAndBar"
    static let usageStatusKey = "floatingPanelShowUsageStatus"
    static let metricsKey = "floatingPanelShowMetrics"
    static let quotaKey = "floatingPanelShowQuota"

    static let `default` = FloatingPanelContentVisibility(
        showRateAndBar: true,
        showUsageStatus: true,
        showMetrics: true,
        showQuota: true
    )

    var showRateAndBar: Bool
    var showUsageStatus: Bool
    var showMetrics: Bool
    var showQuota: Bool

    var visibleGroups: [FloatingPanelContentGroup] {
        FloatingPanelContentGroup.allCases.filter(shows)
    }

    func shows(_ group: FloatingPanelContentGroup) -> Bool {
        switch group {
        case .rateAndBar:
            return showRateAndBar
        case .usageStatus:
            return showUsageStatus
        case .metrics:
            return showMetrics
        case .quota:
            return showQuota
        }
    }
}
