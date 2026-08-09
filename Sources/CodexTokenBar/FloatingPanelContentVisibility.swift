import Foundation

enum FloatingPanelContentGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case rateAndBar
    case usageStatus
    case metrics
    case runningThreads
    case todayModelShare
    case todayModelCost
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
        case .runningThreads:
            return "运行线程"
        case .todayModelShare:
            return "今日模型占比"
        case .todayModelCost:
            return "今日模型费用"
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
        case .runningThreads:
            return "point.3.connected.trianglepath.dotted"
        case .todayModelShare:
            return "chart.pie.fill"
        case .todayModelCost:
            return "dollarsign.circle"
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
        case .runningThreads:
            return "与总今次相邻时吸附到右侧"
        case .todayModelShare:
            return "按今日 Token 计算各模型占比"
        case .todayModelCost:
            return "按真实模型和缓存价格计算 API 等值"
        default:
            return nil
        }
    }

    var supportsPaging: Bool {
        switch self {
        case .rateAndBar, .usageStatus:
            return false
        case .metrics, .runningThreads, .todayModelShare, .todayModelCost,
             .quota, .radar, .crowdRadar:
            return true
        }
    }
}

struct FloatingPanelPagePair: Equatable, Hashable, Identifiable, Sendable {
    let first: FloatingPanelContentGroup
    let second: FloatingPanelContentGroup

    var id: String { "\(first.rawValue)|\(second.rawValue)" }
    var groups: [FloatingPanelContentGroup] { [first, second] }

    func contains(_ group: FloatingPanelContentGroup) -> Bool {
        first == group || second == group
    }

    func partner(of group: FloatingPanelContentGroup) -> FloatingPanelContentGroup? {
        if first == group { return second }
        if second == group { return first }
        return nil
    }
}

struct FloatingPanelLayoutRow: Equatable, Identifiable, Sendable {
    let groups: [FloatingPanelContentGroup]

    var id: String { groups.map(\.rawValue).joined(separator: "|") }
    var primaryGroup: FloatingPanelContentGroup { groups[0] }
    var isPaged: Bool { groups.count > 1 }
}

enum FloatingPanelContentDropPlacement: Equatable, Sendable {
    case before
    case after
}

struct FloatingPanelContentVisibility: Equatable, Sendable {
    static let rateAndBarKey = "floatingPanelShowRateAndBar"
    static let usageStatusKey = "floatingPanelShowUsageStatus"
    static let metricsKey = "floatingPanelShowMetrics"
    static let runningThreadsKey = "floatingPanelShowRunningThreads"
    static let todayModelShareKey = "floatingPanelShowTodayModelShare"
    static let todayModelCostKey = "floatingPanelShowTodayModelCost"
    static let quotaKey = "floatingPanelShowQuota"
    static let radarKey = "floatingPanelShowRadar"
    static let crowdRadarKey = "floatingPanelShowCrowdRadar"
    static let orderKey = "floatingPanelContentOrderV01"
    static let pagePairsKey = "floatingPanelPagePairsV01"
    static let pageNavigationArrowsKey = "floatingPanelShowPageNavigationArrows"
    static let defaultOrder: [FloatingPanelContentGroup] = [
        .rateAndBar,
        .usageStatus,
        .metrics,
        .runningThreads,
        .todayModelShare,
        .todayModelCost,
        .radar,
        .crowdRadar,
        .quota,
    ]
    static let defaultOrderRaw = encodedOrder(defaultOrder)
    static let defaultPagePairs = [
        FloatingPanelPagePair(first: .todayModelShare, second: .todayModelCost),
    ]
    static let defaultPagePairsRaw = encodedPagePairs(defaultPagePairs)

    static let `default` = FloatingPanelContentVisibility(
        showRateAndBar: true,
        showUsageStatus: true,
        showMetrics: true,
        showRunningThreads: true,
        showTodayModelShare: true,
        showTodayModelCost: true,
        showQuota: true,
        showRadar: true,
        showCrowdRadar: true,
        showPageNavigationArrows: true
    )

    var showRateAndBar: Bool
    var showUsageStatus: Bool
    var showMetrics: Bool
    var showRunningThreads: Bool
    var showTodayModelShare: Bool
    var showTodayModelCost: Bool
    var showQuota: Bool
    var showRadar: Bool
    var showCrowdRadar: Bool
    var showPageNavigationArrows: Bool
    var groupOrder = Self.defaultOrder
    var pagePairs = Self.defaultPagePairs

    init(
        showRateAndBar: Bool,
        showUsageStatus: Bool,
        showMetrics: Bool,
        showRunningThreads: Bool = false,
        showTodayModelShare: Bool = false,
        showTodayModelCost: Bool = false,
        showQuota: Bool,
        showRadar: Bool,
        showCrowdRadar: Bool = false,
        showPageNavigationArrows: Bool = true,
        groupOrder: [FloatingPanelContentGroup] = Self.defaultOrder,
        pagePairs: [FloatingPanelPagePair] = Self.defaultPagePairs
    ) {
        self.showRateAndBar = showRateAndBar
        self.showUsageStatus = showUsageStatus
        self.showMetrics = showMetrics
        self.showRunningThreads = showRunningThreads
        self.showTodayModelShare = showTodayModelShare
        self.showTodayModelCost = showTodayModelCost
        self.showQuota = showQuota
        self.showRadar = showRadar
        self.showCrowdRadar = showCrowdRadar
        self.showPageNavigationArrows = showPageNavigationArrows
        self.groupOrder = groupOrder
        self.pagePairs = Self.sanitizedPagePairs(pagePairs)
    }

    var visibleGroups: [FloatingPanelContentGroup] {
        groupOrder.filter(shows)
    }

    var layoutGroups: [FloatingPanelContentGroup] {
        var groups = visibleGroups
        if embedsUsageStatusInRateRow {
            groups = Self.collapsingAdjacentPair(
                in: groups,
                first: .rateAndBar,
                second: .usageStatus,
                representative: .rateAndBar
            )
        }
        if embedsRunningThreadsInMetricsRow {
            groups = Self.collapsingAdjacentPair(
                in: groups,
                first: .metrics,
                second: .runningThreads,
                representative: .metrics
            )
        }
        return groups
    }

    var layoutRows: [FloatingPanelLayoutRow] {
        let groups = layoutGroups
        let available = Set(groups)
        let usablePairs = pagePairs.filter {
            available.contains($0.first) && available.contains($0.second)
        }
        var consumed = Set<FloatingPanelContentGroup>()
        var rows: [FloatingPanelLayoutRow] = []
        for group in groups where !consumed.contains(group) {
            if let pair = usablePairs.first(where: { $0.contains(group) }) {
                consumed.formUnion(pair.groups)
                rows.append(FloatingPanelLayoutRow(groups: pair.groups))
            } else {
                consumed.insert(group)
                rows.append(FloatingPanelLayoutRow(groups: [group]))
            }
        }
        return rows
    }

    func editorGroups(for row: FloatingPanelLayoutRow) -> [FloatingPanelContentGroup] {
        guard row.groups.count == 1 else { return row.groups }
        if row.primaryGroup == .rateAndBar, embedsUsageStatusInRateRow {
            return [.rateAndBar, .usageStatus]
        }
        if row.primaryGroup == .metrics, embedsRunningThreadsInMetricsRow {
            return [.metrics, .runningThreads]
        }
        return row.groups
    }

    mutating func setVisible(_ isVisible: Bool, for groups: [FloatingPanelContentGroup]) {
        for group in groups {
            switch group {
            case .rateAndBar:
                showRateAndBar = isVisible
            case .usageStatus:
                showUsageStatus = isVisible
            case .metrics:
                showMetrics = isVisible
            case .runningThreads:
                showRunningThreads = isVisible
            case .todayModelShare:
                showTodayModelShare = isVisible
            case .todayModelCost:
                showTodayModelCost = isVisible
            case .quota:
                showQuota = isVisible
            case .radar:
                showRadar = isVisible
            case .crowdRadar:
                showCrowdRadar = isVisible
            }
        }
    }

    private static func collapsingAdjacentPair(
        in groups: [FloatingPanelContentGroup],
        first: FloatingPanelContentGroup,
        second: FloatingPanelContentGroup,
        representative: FloatingPanelContentGroup
    ) -> [FloatingPanelContentGroup] {
        var didAppendRepresentative = false
        return groups.compactMap { group in
            guard group == first || group == second else {
                return group
            }
            guard !didAppendRepresentative else { return nil }
            didAppendRepresentative = true
            return representative
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

    var embedsRunningThreadsInMetricsRow: Bool {
        guard showMetrics,
              showRunningThreads,
              let metricsIndex = visibleGroups.firstIndex(of: .metrics),
              let runningIndex = visibleGroups.firstIndex(of: .runningThreads)
        else { return false }

        return abs(metricsIndex - runningIndex) == 1
    }

    var showsStandaloneUsageStatus: Bool {
        showUsageStatus && !embedsUsageStatusInRateRow
    }

    var needsTopControlInset: Bool {
        guard let firstRow = layoutRows.first else { return false }
        return !firstRow.groups.contains(.rateAndBar) && !firstRow.groups.contains(.usageStatus)
    }

    func shows(_ group: FloatingPanelContentGroup) -> Bool {
        switch group {
        case .rateAndBar:
            return showRateAndBar
        case .usageStatus:
            return showUsageStatus
        case .metrics:
            return showMetrics
        case .runningThreads:
            return showRunningThreads
        case .todayModelShare:
            return showTodayModelShare
        case .todayModelCost:
            return showTodayModelCost
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
            if group == .runningThreads, let metricsIndex = result.firstIndex(of: .metrics) {
                result.insert(group, at: metricsIndex + 1)
            } else if group == .todayModelShare,
                      let runningThreadsIndex = result.firstIndex(of: .runningThreads) {
                result.insert(group, at: runningThreadsIndex + 1)
            } else if group == .todayModelCost,
                      let modelShareIndex = result.firstIndex(of: .todayModelShare) {
                result.insert(group, at: modelShareIndex + 1)
            } else if group == .crowdRadar, let radarIndex = result.firstIndex(of: .radar) {
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

    static func pagePairs(from raw: String?) -> [FloatingPanelPagePair] {
        guard let raw else { return defaultPagePairs }
        let decoded = raw.split(separator: ",").compactMap { encoded -> FloatingPanelPagePair? in
            let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let first = FloatingPanelContentGroup(rawValue: String(parts[0])),
                  let second = FloatingPanelContentGroup(rawValue: String(parts[1])) else {
                return nil
            }
            return FloatingPanelPagePair(first: first, second: second)
        }
        return sanitizedPagePairs(decoded)
    }

    static func encodedPagePairs(_ pairs: [FloatingPanelPagePair]) -> String {
        sanitizedPagePairs(pairs).map(\.id).joined(separator: ",")
    }

    static func replacingPagePartner(
        in pairs: [FloatingPanelPagePair],
        for group: FloatingPanelContentGroup,
        with partner: FloatingPanelContentGroup?
    ) -> [FloatingPanelPagePair] {
        var next = sanitizedPagePairs(pairs).filter {
            !$0.contains(group) && (partner == nil || !$0.contains(partner!))
        }
        if let partner,
           group != partner,
           group.supportsPaging,
           partner.supportsPaging {
            next.append(FloatingPanelPagePair(first: group, second: partner))
        }
        return sanitizedPagePairs(next)
    }

    static func swappingDefaultPage(
        in pairs: [FloatingPanelPagePair],
        for group: FloatingPanelContentGroup
    ) -> [FloatingPanelPagePair] {
        sanitizedPagePairs(pairs).map { pair in
            guard pair.second == group else { return pair }
            return FloatingPanelPagePair(first: pair.second, second: pair.first)
        }
    }

    static func splittingPage(
        in pairs: [FloatingPanelPagePair],
        group: FloatingPanelContentGroup
    ) -> [FloatingPanelPagePair] {
        sanitizedPagePairs(pairs).filter { !$0.contains(group) }
    }

    static func mergingPage(
        in pairs: [FloatingPanelPagePair],
        group: FloatingPanelContentGroup,
        into target: FloatingPanelContentGroup
    ) -> [FloatingPanelPagePair] {
        replacingPagePartner(in: pairs, for: target, with: group)
    }

    private static func sanitizedPagePairs(
        _ pairs: [FloatingPanelPagePair]
    ) -> [FloatingPanelPagePair] {
        var used = Set<FloatingPanelContentGroup>()
        return pairs.compactMap { pair in
            guard pair.first != pair.second,
                  pair.first.supportsPaging,
                  pair.second.supportsPaging,
                  !used.contains(pair.first),
                  !used.contains(pair.second) else {
                return nil
            }
            used.insert(pair.first)
            used.insert(pair.second)
            return pair
        }
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

    static func movingRow(
        in currentOrder: [FloatingPanelContentGroup],
        groups movingGroups: [FloatingPanelContentGroup],
        relativeTo targetGroups: [FloatingPanelContentGroup],
        placement: FloatingPanelContentDropPlacement
    ) -> [FloatingPanelContentGroup] {
        let normalized = order(from: encodedOrder(currentOrder))
        let movingSet = Set(movingGroups)
        let targetSet = Set(targetGroups)
        guard !movingSet.isEmpty,
              movingSet.isDisjoint(with: targetSet),
              movingSet.isSubset(of: Set(normalized)),
              targetSet.isSubset(of: Set(normalized))
        else { return normalized }

        let movingBlock = normalized.filter(movingSet.contains)
        var remaining = normalized.filter { !movingSet.contains($0) }
        let targetIndices = remaining.indices.filter { targetSet.contains(remaining[$0]) }
        guard let firstTarget = targetIndices.first,
              let lastTarget = targetIndices.last else {
            return normalized
        }
        let insertionIndex = placement == .before ? firstTarget : lastTarget + 1
        remaining.insert(contentsOf: movingBlock, at: min(insertionIndex, remaining.count))
        return order(from: encodedOrder(remaining))
    }
}
