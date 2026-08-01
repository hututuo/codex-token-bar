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
        case .iq: return "今日模型榜"
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
        case .fiveHour: return "例：5H72%"
        case .sevenDay: return "例：7D38%"
        case .iq: return "例：1 Sol·XH / 2 Luna·H"
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
    let fiveHourWindowOfficiallyAbsent: Bool
    let modelRankings: [StatusBarModelRankingEntry]
    let todayTokens: Int?
    let totalTokens: Int?
    let requests: Int?
    let runningThreads: RunningThreadSummary
    let unreadThreadCount: Int?

    init(
        rate: Double?,
        fiveHourRemainingPercent: Int?,
        sevenDayRemainingPercent: Int?,
        fiveHourAvailability: AccountQuotaWindowAvailability? = nil,
        modelRankings: [StatusBarModelRankingEntry],
        todayTokens: Int?,
        totalTokens: Int?,
        requests: Int?,
        runningThreads: RunningThreadSummary,
        unreadThreadCount: Int?
    ) {
        self.rate = rate.flatMap { $0.isFinite ? max(0, $0) : nil }
        let normalizedFiveHour = fiveHourRemainingPercent.map { min(100, max(0, $0)) }
        let normalizedSevenDay = sevenDayRemainingPercent.map { min(100, max(0, $0)) }
        self.fiveHourRemainingPercent = normalizedFiveHour
        self.sevenDayRemainingPercent = normalizedSevenDay
        let resolvedFiveHourAvailability = normalizedFiveHour == nil
            ? (fiveHourAvailability ?? (normalizedSevenDay != nil ? .absent : .unavailable))
            : .measured
        self.fiveHourWindowOfficiallyAbsent = resolvedFiveHourAvailability == .absent
        self.modelRankings = Array(modelRankings.prefix(2))
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
        unreadThreadCount: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let quotaReadFailed = snapshot.quota.staleDataDisplayed
        var radarCalendar = calendar
        let radarTimeZoneIdentifier = radar.snapshot?.timezone
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let radarTimeZone = TimeZone(identifier: radarTimeZoneIdentifier) {
            radarCalendar.timeZone = radarTimeZone
        }
        self.init(
            rate: rateAvailable ? snapshot.rate : nil,
            fiveHourRemainingPercent: quotaReadFailed
                ? nil
                : snapshot.quota.fiveHour?.remainingPercent,
            sevenDayRemainingPercent: quotaReadFailed
                ? nil
                : snapshot.quota.sevenDay?.remainingPercent,
            fiveHourAvailability: quotaReadFailed
                ? .unavailable
                : snapshot.quota.resolvedFiveHourAvailability,
            modelRankings: radar.staleDataDisplayed
                ? []
                : Self.modelRankings(
                    from: radar.snapshot?.modelIQ,
                    now: now,
                    calendar: radarCalendar
                ),
            todayTokens: snapshot.hasPreciseTokenUsage ? snapshot.todayTokens : nil,
            totalTokens: snapshot.hasPreciseTokenUsage ? snapshot.consumedTokens : nil,
            requests: snapshot.hasPreciseTokenUsage ? snapshot.todayRequests : nil,
            runningThreads: snapshot.runningThreads,
            unreadThreadCount: unreadThreadCount
        )
    }

    private static func modelRankings(
        from modelIQ: CodexRadarModelIQ?,
        now: Date,
        calendar: Calendar
    ) -> [StatusBarModelRankingEntry] {
        guard let modelIQ else { return [] }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year, let month = today.month, let day = today.day else {
            return []
        }
        let todayKey = String(format: "%04d-%02d-%02d", year, month, day)
        return ([modelIQ.primaryModelRow] + modelIQ.secondaryModelRows)
            .filter { row in
                let point = row.point
                let validSampleCount = point.validTasks ?? point.tasks
                return point.hasMeasurement
                    && String(point.date.prefix(10)) == todayKey
                    && validSampleCount > 0
            }
            .compactMap(StatusBarModelRankingEntry.init)
            .prefix(2)
            .map { $0 }
    }
}

struct StatusBarModelRankingEntry: Equatable, Sendable {
    let modelName: String
    let reasoningEffortCode: String
    let reasoningEffortAccessibilityText: String

    init(modelName: String, reasoningEffort: String) {
        self.modelName = Self.shortModelName(modelName) ?? "—"
        self.reasoningEffortCode = Self.compactReasoningEffort(reasoningEffort)
        self.reasoningEffortAccessibilityText = reasoningEffort.isEmpty ? "未知" : reasoningEffort
    }

    init?(row: CodexRadarModelIQComparisonRow) {
        guard row.point.hasMeasurement,
              let modelName = Self.shortModelName(
                [row.point.model, row.label].compactMap { $0 }.joined(separator: " ")
              )
        else {
            return nil
        }
        let pointEffort = row.point.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effort = pointEffort.isEmpty
            ? Self.reasoningEffort(in: row.label) ?? ""
            : pointEffort
        self.modelName = modelName
        self.reasoningEffortCode = Self.compactReasoningEffort(effort)
        self.reasoningEffortAccessibilityText = effort.isEmpty ? "未知" : effort
    }

    var compactText: String {
        "\(modelName)·\(reasoningEffortCode)"
    }

    private static func shortModelName(_ rawValue: String) -> String? {
        let tokens = rawValue.components(separatedBy: CharacterSet.alphanumerics.inverted)
        for family in ["Sol", "Luna", "Terra"] {
            if tokens.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) {
                return family
            }
        }

        let normalized = rawValue.lowercased()
        for version in ["5.6", "5.5", "5.4"] where normalized.contains("gpt-\(version)") {
            return version
        }

        let compact = CodexRadarPresentationText.compactModelName(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = compact.split(whereSeparator: \.isWhitespace).first,
              candidate != "--",
              candidate.caseInsensitiveCompare("model") != .orderedSame,
              candidate.caseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        return String(candidate.prefix(8))
    }

    private static func reasoningEffort(in rawValue: String) -> String? {
        let tokens = rawValue
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
        return ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            .first(where: tokens.contains)
    }

    private static func compactReasoningEffort(_ rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "max": return "MAX"
        case "xhigh": return "XH"
        case "high": return "H"
        case "medium": return "M"
        case "low": return "L"
        case "minimal": return "MIN"
        case "ultra": return "U"
        default: return "—"
        }
    }
}

struct StatusBarMetricLine: Equatable, Sendable {
    let text: String
    let isSecondary: Bool

    init(text: String, isSecondary: Bool = false) {
        self.text = text
        self.isSecondary = isSecondary
    }
}

struct StatusBarMetricColumn: Equatable, Sendable {
    let top: StatusBarMetricLine
    let bottom: StatusBarMetricLine
}

enum StatusBarMetricSegmentLayout: Equatable, Sendable {
    case inline
    case quotaLine(StatusBarMetricLine)
    case stackedLines(top: StatusBarMetricLine, bottom: StatusBarMetricLine)
}

struct StatusBarMetricSegment: Equatable, Sendable {
    let id: StatusBarMetricID
    let text: String
    let accessibilityText: String
    let layout: StatusBarMetricSegmentLayout

    init(
        id: StatusBarMetricID,
        text: String,
        accessibilityText: String,
        layout: StatusBarMetricSegmentLayout = .inline
    ) {
        self.id = id
        self.text = text
        self.accessibilityText = accessibilityText
        self.layout = layout
    }
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

    var columns: [StatusBarMetricColumn] {
        var columns: [StatusBarMetricColumn] = []
        var pendingLine: StatusBarMetricLine?

        func flushPendingLine() {
            guard let line = pendingLine else { return }
            columns.append(
                StatusBarMetricColumn(
                    top: line,
                    bottom: StatusBarMetricLine(text: "")
                )
            )
            pendingLine = nil
        }

        var index = 0
        while index < segments.count {
            let segment = segments[index]
            switch segment.layout {
            case .inline:
                let line = StatusBarMetricLine(text: segment.text)
                if let previous = pendingLine {
                    columns.append(StatusBarMetricColumn(top: previous, bottom: line))
                    pendingLine = nil
                } else {
                    pendingLine = line
                }
            case .quotaLine(let line):
                flushPendingLine()
                var bottom = StatusBarMetricLine(text: "")
                if index + 1 < segments.count,
                   case .quotaLine(let nextLine) = segments[index + 1].layout {
                    bottom = nextLine
                    index += 1
                }
                columns.append(StatusBarMetricColumn(top: line, bottom: bottom))
            case .stackedLines(let top, let bottom):
                flushPendingLine()
                columns.append(StatusBarMetricColumn(top: top, bottom: bottom))
            }
            index += 1
        }

        flushPendingLine()
        return columns
    }

    static func make(
        values: StatusBarMetricValues,
        configuration: StatusBarMetricConfiguration
    ) -> StatusBarMetricsPresentation {
        StatusBarMetricsPresentation(
            segments: configuration.visibleMetricIDs.compactMap { metric in
                if metric == .fiveHour, values.fiveHourWindowOfficiallyAbsent {
                    return nil
                }
                return segment(
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
            let unitsLine = labelStyle == .hidden
                ? StatusBarMetricLine(text: "")
                : StatusBarMetricLine(text: "tok/s", isSecondary: true)
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
                } ?? "实时速率暂不可用",
                layout: .stackedLines(
                    top: StatusBarMetricLine(text: rate ?? "—"),
                    bottom: unitsLine
                )
            )
        case .fiveHour:
            let value = values.fiveHourRemainingPercent.map { "\($0)%" } ?? "—"
            let label = quotaColumnLabel(full: "5h", compact: "5", style: labelStyle)
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "5h",
                    compact: "5H",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.fiveHourRemainingPercent.map {
                    "5 小时额度剩余 \($0)%"
                } ?? "5 小时额度暂不可用",
                layout: .quotaLine(
                    StatusBarMetricLine(text: joinedColumnLabel(label, value: value))
                )
            )
        case .sevenDay:
            let value = values.sevenDayRemainingPercent.map { "\($0)%" } ?? "—"
            let label = quotaColumnLabel(full: "7d", compact: "7", style: labelStyle)
            return StatusBarMetricSegment(
                id: metric,
                text: labeledValue(
                    full: "7d",
                    compact: "7D",
                    value: value,
                    style: labelStyle
                ),
                accessibilityText: values.sevenDayRemainingPercent.map {
                    "7 天额度剩余 \($0)%"
                } ?? "7 天额度暂不可用",
                layout: .quotaLine(
                    StatusBarMetricLine(text: joinedColumnLabel(label, value: value))
                )
            )
        case .iq:
            let rankingLines = (0..<2).map { index -> String in
                guard values.modelRankings.indices.contains(index) else {
                    return "\(index + 1) —"
                }
                return "\(index + 1) \(values.modelRankings[index].compactText)"
            }
            let accessibilityText: String
            if values.modelRankings.isEmpty {
                accessibilityText = "今日模型榜暂不可用"
            } else {
                accessibilityText = "今日模型榜，" + values.modelRankings.enumerated().map { index, entry in
                    "第 \(index + 1) 名 \(entry.modelName)，思考强度 \(entry.reasoningEffortAccessibilityText)"
                }.joined(separator: "；")
            }
            return StatusBarMetricSegment(
                id: metric,
                text: rankingLines.joined(separator: " / "),
                accessibilityText: accessibilityText,
                layout: .stackedLines(
                    top: StatusBarMetricLine(text: rankingLines[0]),
                    bottom: StatusBarMetricLine(text: rankingLines[1])
                )
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

    private static func quotaColumnLabel(
        full: String,
        compact: String,
        style: StatusBarMetricLabelStyle
    ) -> String {
        switch style {
        case .full: return full
        case .compact: return compact
        case .hidden: return ""
        }
    }

    private static func joinedColumnLabel(_ label: String, value: String) -> String {
        label.isEmpty ? value : "\(label) \(value)"
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
