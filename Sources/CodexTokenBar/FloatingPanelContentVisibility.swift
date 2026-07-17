import Foundation

enum FloatingPanelContentGroup: String, CaseIterable, Identifiable {
    case rateAndBar
    case usageStatus
    case metrics
    case quota
    case radar
    case crowdRadar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rateAndBar:
            return "速率"
        case .usageStatus:
            return "趣味话"
        case .metrics:
            return "总今次"
        case .quota:
            return "5h/7d"
        case .radar:
            return "Radar"
        case .crowdRadar:
            return "众测雷达"
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
        case .crowdRadar:
            return "antenna.radiowaves.left.and.right"
        }
    }

    var settingsSubtitle: String? {
        switch self {
        case .usageStatus:
            return "与速率相邻会吸附，分开时居中"
        default:
            return nil
        }
    }
}

enum FloatingPanelContentDropPlacement {
    case before
    case after
}

struct FloatingPanelContentVisibility: Equatable, Sendable {
    static let rateAndBarKey = "floatingPanelShowRateAndBar"
    static let usageStatusKey = "floatingPanelShowUsageStatus"
    static let metricsKey = "floatingPanelShowMetrics"
    static let quotaKey = "floatingPanelShowQuota"
    static let radarKey = "floatingPanelShowRadar"
    static let crowdRadarKey = "floatingPanelShowCrowdRadar"
    static let orderKey = "floatingPanelContentOrderV01"
    static let defaultOrder: [FloatingPanelContentGroup] = [.rateAndBar, .usageStatus, .metrics, .radar, .crowdRadar, .quota]
    static let defaultOrderRaw = encodedOrder(defaultOrder)

    static let `default` = FloatingPanelContentVisibility(
        showRateAndBar: true,
        showUsageStatus: true,
        showMetrics: true,
        showQuota: true,
        showRadar: true,
        showCrowdRadar: true
    )

    var showRateAndBar: Bool
    var showUsageStatus: Bool
    var showMetrics: Bool
    var showQuota: Bool
    var showRadar: Bool
    var showCrowdRadar: Bool
    var groupOrder = Self.defaultOrder

    init(
        showRateAndBar: Bool,
        showUsageStatus: Bool,
        showMetrics: Bool,
        showQuota: Bool,
        showRadar: Bool,
        showCrowdRadar: Bool = false,
        groupOrder: [FloatingPanelContentGroup] = Self.defaultOrder
    ) {
        self.showRateAndBar = showRateAndBar
        self.showUsageStatus = showUsageStatus
        self.showMetrics = showMetrics
        self.showQuota = showQuota
        self.showRadar = showRadar
        self.showCrowdRadar = showCrowdRadar
        self.groupOrder = groupOrder
    }

    var visibleGroups: [FloatingPanelContentGroup] {
        groupOrder.filter(shows)
    }

    var layoutGroups: [FloatingPanelContentGroup] {
        let groups = visibleGroups
        guard embedsUsageStatusInRateRow else { return groups }

        var didAppendAttachedRateRow = false
        return groups.compactMap { group in
            switch group {
            case .rateAndBar, .usageStatus:
                guard !didAppendAttachedRateRow else { return nil }
                didAppendAttachedRateRow = true
                return .rateAndBar
            default:
                return group
            }
        }
    }

    var embedsUsageStatusInRateRow: Bool {
        guard showRateAndBar,
              showUsageStatus,
              let rateIndex = visibleGroups.firstIndex(of: .rateAndBar),
              let usageIndex = visibleGroups.firstIndex(of: .usageStatus)
        else { return false }

        return abs(rateIndex - usageIndex) == 1
    }

    var showsStandaloneUsageStatus: Bool {
        showUsageStatus && !embedsUsageStatusInRateRow
    }

    var needsTopControlInset: Bool {
        guard let firstGroup = layoutGroups.first else { return false }
        return firstGroup != .rateAndBar && firstGroup != .usageStatus
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
        case .crowdRadar:
            return showCrowdRadar
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
        var result = decoded
        for group in defaultOrder where !seen.contains(group) {
            if group == .crowdRadar, let radarIndex = result.firstIndex(of: .radar) {
                result.insert(group, at: radarIndex + 1)
            } else {
                result.append(group)
            }
        }
        return result
    }

    static func encodedOrder(_ groups: [FloatingPanelContentGroup]) -> String {
        order(from: groups.map(\.rawValue).joined(separator: ","))
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func reorderedOrder(
        _ currentOrder: [FloatingPanelContentGroup],
        moving dragged: FloatingPanelContentGroup,
        relativeTo target: FloatingPanelContentGroup,
        placement: FloatingPanelContentDropPlacement
    ) -> [FloatingPanelContentGroup] {
        var order = order(from: encodedOrder(currentOrder))
        guard dragged != target,
              order.contains(dragged),
              order.contains(target)
        else { return order }

        order.removeAll { $0 == dragged }
        guard let targetIndex = order.firstIndex(of: target) else { return order }
        let insertionIndex: Int
        switch placement {
        case .before:
            insertionIndex = targetIndex
        case .after:
            insertionIndex = min(targetIndex + 1, order.count)
        }
        order.insert(dragged, at: insertionIndex)
        return order
    }
}
