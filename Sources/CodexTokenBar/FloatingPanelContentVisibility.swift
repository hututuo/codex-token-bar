import Foundation

enum FloatingPanelContentGroup: String, CaseIterable, Identifiable {
    case rateAndBar
    case usageStatus
    case metrics
    case quota
    case radar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rateAndBar:
            return "速率"
        case .usageStatus:
            return "余量"
        case .metrics:
            return "总今次"
        case .quota:
            return "5h/7d"
        case .radar:
            return "Radar"
        }
    }

    var systemImage: String {
        switch self {
        case .rateAndBar:
            return "speedometer"
        case .usageStatus:
            return "sparkles"
        case .metrics:
            return "number"
        case .quota:
            return "chart.bar.fill"
        case .radar:
            return "dot.radiowaves.left.and.right"
        }
    }
}

struct FloatingPanelContentVisibility: Equatable, Sendable {
    static let rateAndBarKey = "floatingPanelShowRateAndBar"
    static let usageStatusKey = "floatingPanelShowUsageStatus"
    static let metricsKey = "floatingPanelShowMetrics"
    static let quotaKey = "floatingPanelShowQuota"
    static let radarKey = "floatingPanelShowRadar"
    static let orderKey = "floatingPanelContentOrderV01"
    static let defaultOrder = FloatingPanelContentGroup.allCases
    static let defaultOrderRaw = encodedOrder(defaultOrder)

    static let `default` = FloatingPanelContentVisibility(
        showRateAndBar: true,
        showUsageStatus: true,
        showMetrics: true,
        showQuota: true,
        showRadar: true
    )

    var showRateAndBar: Bool
    var showUsageStatus: Bool
    var showMetrics: Bool
    var showQuota: Bool
    var showRadar: Bool
    var groupOrder = Self.defaultOrder

    var visibleGroups: [FloatingPanelContentGroup] {
        groupOrder.filter(shows)
    }

    var layoutGroups: [FloatingPanelContentGroup] {
        groupOrder.filter { group in
            switch group {
            case .usageStatus:
                return showsStandaloneUsageStatus
            default:
                return shows(group)
            }
        }
    }

    var embedsUsageStatusInRateRow: Bool {
        showRateAndBar && showUsageStatus
    }

    var showsStandaloneUsageStatus: Bool {
        !showRateAndBar && showUsageStatus
    }

    var needsTopControlInset: Bool {
        !showUsageStatus && !layoutGroups.isEmpty
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
        case .radar:
            return showRadar
        }
    }

    static func order(from raw: String?) -> [FloatingPanelContentGroup] {
        var seen = Set<FloatingPanelContentGroup>()
        let decoded = (raw ?? "")
            .split(separator: ",")
            .compactMap { rawValue -> FloatingPanelContentGroup? in
                let group = FloatingPanelContentGroup(rawValue: String(rawValue))
                guard let group, !seen.contains(group) else { return nil }
                seen.insert(group)
                return group
            }
        let missing = defaultOrder.filter { !seen.contains($0) }
        return decoded + missing
    }

    static func encodedOrder(_ groups: [FloatingPanelContentGroup]) -> String {
        order(from: groups.map(\.rawValue).joined(separator: ","))
            .map(\.rawValue)
            .joined(separator: ",")
    }
}
