import Foundation

enum StatusBarMetricID: String, CaseIterable, Codable, Identifiable, Sendable {
    case rate
    case fiveHour
    case sevenDay
    case iq
    case today
    case total
    case requests
    case running
    case unread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rate: return "实时速率"
        case .fiveHour: return "5 小时额度"
        case .sevenDay: return "7 天额度"
        case .iq: return "模型 IQ"
        case .today: return "今日 Token"
        case .total: return "累计 Token"
        case .requests: return "今日请求"
        case .running: return "运行线程"
        case .unread: return "未读会话"
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .rate: return "例：42.4/s"
        case .fiveHour: return "例：⁵ʰ72%"
        case .sevenDay: return "例：⁷ᵈ38%"
        case .iq: return "例：IQ146"
        case .today: return "例：今84K"
        case .total: return "例：总1.2M"
        case .requests: return "例：次128"
        case .running: return "例：跑3；不可用时显示 —"
        case .unread: return "例：未2"
        }
    }

    var systemImage: String {
        switch self {
        case .rate: return "speedometer"
        case .fiveHour: return "clock"
        case .sevenDay: return "calendar"
        case .iq: return "brain.head.profile"
        case .today: return "sun.max"
        case .total: return "sum"
        case .requests: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .running: return "play.circle"
        case .unread: return "bell.badge"
        }
    }
}

enum StatusBarMetricLabelStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case full
    case compact
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "完整"
        case .compact: return "紧凑"
        case .hidden: return "隐藏标签"
        }
    }
}

enum StatusSummarySectionID: String, CaseIterable, Codable, Identifiable, Sendable {
    case overview
    case usage
    case quota
    case running
    case unread
    case radar
    case crowdRadar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "关键概览"
        case .usage: return "Token 用量"
        case .quota: return "额度"
        case .running: return "运行线程"
        case .unread: return "未读会话"
        case .radar: return "Codex 雷达"
        case .crowdRadar: return "众测雷达"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .usage: return "sum"
        case .quota: return "chart.bar.fill"
        case .running: return "play.circle"
        case .unread: return "bell.badge"
        case .radar: return "scope"
        case .crowdRadar: return "person.3"
        }
    }
}

struct StatusSummaryConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let versionKey = "statusSummaryConfigurationVersion"
    static let orderKey = "statusSummarySectionOrderV01"
    static let selectionKey = "statusSummarySectionSelectionV01"
    static let defaultOrder = StatusSummarySectionID.allCases
    static let defaultSelection = Set(StatusSummarySectionID.allCases)
    static let defaultOrderRaw = encodedOrder(defaultOrder)
    static let defaultSelectionRaw = encodedSelection(defaultSelection, orderedBy: defaultOrder)
    static let `default` = StatusSummaryConfiguration(
        version: currentVersion,
        orderedSectionIDs: defaultOrder,
        selectedSectionIDs: defaultSelection
    )

    let version: Int
    let orderedSectionIDs: [StatusSummarySectionID]
    let selectedSectionIDs: Set<StatusSummarySectionID>

    init(
        version: Int = currentVersion,
        orderedSectionIDs: [StatusSummarySectionID] = defaultOrder,
        selectedSectionIDs: Set<StatusSummarySectionID> = defaultSelection
    ) {
        self.version = version
        self.orderedSectionIDs = Self.normalizedOrder(orderedSectionIDs)
        self.selectedSectionIDs = selectedSectionIDs
    }

    init(
        version: Int = currentVersion,
        orderRaw: String,
        selectionRaw: String
    ) {
        self.init(
            version: version,
            orderedSectionIDs: Self.order(from: orderRaw),
            selectedSectionIDs: Self.selection(from: selectionRaw)
        )
    }

    var visibleSectionIDs: [StatusSummarySectionID] {
        orderedSectionIDs.filter(selectedSectionIDs.contains)
    }

    static func order(from rawValue: String) -> [StatusSummarySectionID] {
        normalizedOrder(decodedSectionIDs(from: rawValue))
    }

    static func selection(from rawValue: String) -> Set<StatusSummarySectionID> {
        Set(decodedSectionIDs(from: rawValue))
    }

    static func encodedOrder(_ order: [StatusSummarySectionID]) -> String {
        normalizedOrder(order).map(\.rawValue).joined(separator: ",")
    }

    static func encodedSelection(
        _ selection: Set<StatusSummarySectionID>,
        orderedBy order: [StatusSummarySectionID]
    ) -> String {
        normalizedOrder(order)
            .filter(selection.contains)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private static func decodedSectionIDs(from rawValue: String) -> [StatusSummarySectionID] {
        rawValue
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { rawComponent in
                StatusSummarySectionID(
                    rawValue: rawComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private static func normalizedOrder(
        _ order: [StatusSummarySectionID]
    ) -> [StatusSummarySectionID] {
        var seen = Set<StatusSummarySectionID>()
        var result = order.filter { seen.insert($0).inserted }
        result.append(contentsOf: StatusSummarySectionID.allCases.filter { seen.insert($0).inserted })
        return result
    }
}

struct StatusBarMetricConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let versionKey = "statusBarMetricConfigurationVersion"
    static let orderKey = "statusBarMetricOrderV01"
    static let selectionKey = "statusBarMetricSelectionV01"
    static let showsIconKey = "statusBarMetricShowsIconV01"
    static let labelStyleKey = "statusBarMetricLabelStyleV01"
    static let defaultShowsIcon = true
    static let defaultLabelStyle = StatusBarMetricLabelStyle.compact
    static let defaultOrder = StatusBarMetricID.allCases
    static let defaultSelection: Set<StatusBarMetricID> = [
        .rate,
        .fiveHour,
        .sevenDay,
        .iq
    ]
    static let defaultOrderRaw = encodedOrder(defaultOrder)
    static let defaultSelectionRaw = encodedSelection(
        defaultSelection,
        orderedBy: defaultOrder
    )
    static let `default` = StatusBarMetricConfiguration(
        version: currentVersion,
        orderedMetricIDs: defaultOrder,
        selectedMetricIDs: defaultSelection,
        showsIcon: defaultShowsIcon,
        labelStyle: defaultLabelStyle
    )

    let version: Int
    let orderedMetricIDs: [StatusBarMetricID]
    let selectedMetricIDs: Set<StatusBarMetricID>
    let showsIcon: Bool
    let labelStyle: StatusBarMetricLabelStyle

    init(
        version: Int = currentVersion,
        orderedMetricIDs: [StatusBarMetricID] = defaultOrder,
        selectedMetricIDs: Set<StatusBarMetricID> = defaultSelection,
        showsIcon: Bool = defaultShowsIcon,
        labelStyle: StatusBarMetricLabelStyle = defaultLabelStyle
    ) {
        self.version = version
        self.orderedMetricIDs = Self.normalizedOrder(orderedMetricIDs)
        self.selectedMetricIDs = selectedMetricIDs
        self.showsIcon = showsIcon
        self.labelStyle = labelStyle
    }

    init(
        version: Int = currentVersion,
        orderRaw: String,
        selectionRaw: String,
        showsIcon: Bool,
        labelStyle: StatusBarMetricLabelStyle = defaultLabelStyle
    ) {
        self.init(
            version: version,
            orderedMetricIDs: Self.order(from: orderRaw),
            selectedMetricIDs: Self.selection(from: selectionRaw),
            showsIcon: showsIcon,
            labelStyle: labelStyle
        )
    }

    var visibleMetricIDs: [StatusBarMetricID] {
        orderedMetricIDs.filter(selectedMetricIDs.contains)
    }

    static func order(from rawValue: String) -> [StatusBarMetricID] {
        normalizedOrder(decodedMetricIDs(from: rawValue))
    }

    static func selection(from rawValue: String) -> Set<StatusBarMetricID> {
        Set(decodedMetricIDs(from: rawValue))
    }

    static func encodedOrder(_ order: [StatusBarMetricID]) -> String {
        normalizedOrder(order).map(\.rawValue).joined(separator: ",")
    }

    static func encodedSelection(
        _ selection: Set<StatusBarMetricID>,
        orderedBy order: [StatusBarMetricID]
    ) -> String {
        let normalized = normalizedOrder(order)
        return normalized
            .filter(selection.contains)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private static func decodedMetricIDs(from rawValue: String) -> [StatusBarMetricID] {
        rawValue
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { rawComponent in
                StatusBarMetricID(rawValue: rawComponent.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    private static func normalizedOrder(_ order: [StatusBarMetricID]) -> [StatusBarMetricID] {
        var seen = Set<StatusBarMetricID>()
        var result = order.filter { seen.insert($0).inserted }
        result.append(contentsOf: StatusBarMetricID.allCases.filter { seen.insert($0).inserted })
        return result
    }
}

struct StatusBarMetricValues: Equatable, Sendable {
    let rate: Double?
    let fiveHourRemainingPercent: Int?
    let sevenDayRemainingPercent: Int?
    let iqScore: Double?
    let todayTokens: Int?
    let totalTokens: Int?
    let requests: Int?
    let runningThreads: RunningThreadSummary
    let unreadThreadCount: Int?

    init(
        rate: Double?,
        fiveHourRemainingPercent: Int?,
        sevenDayRemainingPercent: Int?,
        iqScore: Double?,
        todayTokens: Int?,
        totalTokens: Int?,
        requests: Int?,
        runningThreads: RunningThreadSummary,
        unreadThreadCount: Int?
    ) {
        self.rate = rate.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.fiveHourRemainingPercent = fiveHourRemainingPercent.map { min(100, max(0, $0)) }
        self.sevenDayRemainingPercent = sevenDayRemainingPercent.map { min(100, max(0, $0)) }
        self.iqScore = iqScore.flatMap { $0.isFinite ? $0 : nil }
        self.todayTokens = todayTokens.map { max(0, $0) }
        self.totalTokens = totalTokens.map { max(0, $0) }
        self.requests = requests.map { max(0, $0) }
        self.runningThreads = runningThreads
        self.unreadThreadCount = unreadThreadCount.map { max(0, $0) }
    }

    init(
        snapshot: TokenDisplaySnapshot,
        radar: CodexRadarPresentationState,
        rateAvailable: Bool = true,
        unreadThreadCount: Int?
    ) {
        self.init(
            rate: rateAvailable ? snapshot.rate : nil,
            fiveHourRemainingPercent: snapshot.quota.fiveHour?.remainingPercent,
            sevenDayRemainingPercent: snapshot.quota.sevenDay?.remainingPercent,
            iqScore: radar.snapshot?.modelIQ.primaryModelPoint?.score,
            todayTokens: snapshot.hasPreciseTokenUsage ? snapshot.todayTokens : nil,
            totalTokens: snapshot.hasPreciseTokenUsage ? snapshot.consumedTokens : nil,
            requests: snapshot.hasPreciseTokenUsage ? snapshot.todayRequests : nil,
            runningThreads: snapshot.runningThreads,
            unreadThreadCount: unreadThreadCount
        )
    }
}

struct StatusBarMetricSegment: Equatable, Sendable {
    let id: StatusBarMetricID
    let text: String
    let accessibilityText: String
}

struct StatusBarMetricsPresentation: Equatable, Sendable {
    static let separator = " · "

    let segments: [StatusBarMetricSegment]

    var text: String {
        segments.map(\.text).joined(separator: Self.separator)
    }

    var accessibilityValue: String {
        guard !segments.isEmpty else {
            return "当前没有可显示的状态栏指标"
        }
        return segments.map(\.accessibilityText).joined(separator: "；")
    }

    static func make(
        values: StatusBarMetricValues,
        configuration: StatusBarMetricConfiguration
    ) -> StatusBarMetricsPresentation {
        StatusBarMetricsPresentation(
            segments: configuration.visibleMetricIDs.map { metric in
                segment(
                    for: metric,
                    values: values,
                    labelStyle: configuration.labelStyle
                )
            }
        )
    }

    private static func segment(
        for metric: StatusBarMetricID,
        values: StatusBarMetricValues,
        labelStyle: StatusBarMetricLabelStyle
    ) -> StatusBarMetricSegment {
        switch metric {
        case .rate:
            let rate = values.rate.map { String(format: "%.1f", $0) }
            let value = rate.map { "\($0)/s" } ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "速率",
                    compact: "",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: rate.map {
                    "实时速率 \($0) token 每秒"
                } ?? "实时速率暂不可用"
            )
        case .fiveHour:
            let value = values.fiveHourRemainingPercent.map { "\($0)%" } ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "5h",
                    compact: "⁵ʰ",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.fiveHourRemainingPercent.map {
                    "5 小时额度剩余 \($0)%"
                } ?? "5 小时额度暂不可用"
            )
        case .sevenDay:
            let value = values.sevenDayRemainingPercent.map { "\($0)%" } ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "7d",
                    compact: "⁷ᵈ",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.sevenDayRemainingPercent.map {
                    "7 天额度剩余 \($0)%"
                } ?? "7 天额度暂不可用"
            )
        case .iq:
            let scoreText = values.iqScore.map { CodexRadarModelIQPoint.display($0) } ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "模型 IQ",
                    compact: "IQ",
                    value: scoreText,
                    style: labelStyle
                ),
                accessibilityText: values.iqScore == nil ? "模型 IQ 暂不可用" : "模型 IQ \(scoreText)"
            )
        case .today:
            let value = values.todayTokens.map(compactCount) ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "今日",
                    compact: "今",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.todayTokens.map {
                    "今日 \($0) token"
                } ?? "今日 token 暂不可用"
            )
        case .total:
            let value = values.totalTokens.map(compactCount) ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "累计",
                    compact: "总",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.totalTokens.map {
                    "累计 \($0) token"
                } ?? "累计 token 暂不可用"
            )
        case .requests:
            let value = values.requests.map { String($0) } ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "请求",
                    compact: "次",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.requests.map {
                    "今日 \($0) 次请求"
                } ?? "今日请求数暂不可用"
            )
        case .running:
            let running = RunningThreadPresentation(summary: values.runningThreads)
            let value = running.hasCounts ? "\(values.runningThreads.total)" : "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "运行",
                    compact: "跑",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: running.accessibilityText
            )
        case .unread:
            let value = values.unreadThreadCount.map(String.init) ?? "—"
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "未读",
                    compact: "未",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.unreadThreadCount.map {
                    "未读会话 \($0) 个"
                } ?? "未读会话暂不可用"
            )
        }
    }

    private static func labeledValue(
        full: String,
        compact: String,
        value: String,
        style: StatusBarMetricLabelStyle
    ) -> String {
        switch style {
        case .full:
            return "\(full)\(value)"
        case .compact:
            return "\(compact)\(value)"
        case .hidden:
            return value
        }
    }

    private static func compactCount(_ value: Int) -> String {
        let units: [(threshold: Int, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K")
        ]
        guard let unit = units.first(where: { value >= $0.threshold }) else {
            return "\(value)"
        }
        let scaled = Double(value) / Double(unit.threshold)
        let formatted = String(format: "%.1f", scaled)
        let trimmed = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
        return "\(trimmed)\(unit.suffix)"
    }
}
