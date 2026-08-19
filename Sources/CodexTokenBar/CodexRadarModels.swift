import Foundation

enum CodexRadarPresentationText {
    static func actionKey(_ rawValue: String?) -> String {
        (rawValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func action(_ rawValue: String?) -> String {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch actionKey(value) {
        case "wait", "waiting":
            return "等待"
        case "hold":
            return "暂缓"
        case "run":
            return "运行"
        case "go":
            return "可运行"
        case "open":
            return "开放"
        case "closed":
            return "关闭"
        case "use window", "use windows", "usewindow", "usewindows", "use remaining tokens":
            return "速登窗口"
        default:
            return value.isEmpty ? "--" : value
        }
    }

    static func compactModelName(_ rawValue: String) -> String {
        let familyNames = ["Sol", "Luna", "Terra"]
        let tokens = rawValue.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let effortNames = ["ultra", "max", "xhigh", "high", "medium", "low", "minimal"]
        let compactEffort: [String: String] = [
            "ultra": "U", "xhigh": "XH", "high": "H", "medium": "M",
            "low": "L", "minimal": "Min", "max": "max",
        ]
        let isDeepSeek = tokens.contains(where: { $0.caseInsensitiveCompare("DeepSeek") == .orderedSame })
        let isHarness = tokens.first?.caseInsensitiveCompare("DSH") == .orderedSame
        if isDeepSeek || isHarness {
            let effort = effortNames.first(where: { effort in
                tokens.contains(where: { $0.caseInsensitiveCompare(effort) == .orderedSame })
            })
            let variant: String?
            if tokens.contains(where: {
                $0.caseInsensitiveCompare("Flash") == .orderedSame
                    || $0.caseInsensitiveCompare("F") == .orderedSame
            }) {
                variant = "F"
            } else if tokens.contains(where: {
                $0.caseInsensitiveCompare("Pro") == .orderedSame
                    || $0.caseInsensitiveCompare("P") == .orderedSame
            }) {
                variant = "P"
            } else {
                variant = nil
            }
            if let variant {
                return ([isHarness ? "DSH" : "DS", variant, effort].compactMap { $0 }).joined(separator: " ")
            }
            if isHarness {
                return rawValue
                    .replacingOccurrences(of: #"^DSH[\s_-]*"#, with: "DSH ", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return rawValue
                .replacingOccurrences(of: #"^DeepSeek[\s_-]*"#, with: "DS ", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let family = familyNames.first(where: { family in
            tokens.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame })
        }) {
            let effort = effortNames.first(where: { effort in
                tokens.contains(where: { $0.caseInsensitiveCompare(effort) == .orderedSame })
            })
            return effort.map { "\(family) \($0)" } ?? family
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedTokens = tokens.map { $0.lowercased() }
        let effort = effortNames.first(where: { lowercasedTokens.contains($0) })
        let shortEffort = effort.flatMap { compactEffort[$0] }
        if lowercasedTokens.starts(with: ["grok", "4", "6"]) {
            return (["G4.6", shortEffort].compactMap { $0 }).joined(separator: " ")
        }
        if lowercasedTokens.first == "k3" {
            return (["K3", shortEffort].compactMap { $0 }).joined(separator: " ")
        }
        if lowercasedTokens.starts(with: ["glm", "5", "3"]) {
            return (["GLM5.3", shortEffort].compactMap { $0 }).joined(separator: " ")
        }
        return normalized
            .replacingOccurrences(of: #"^GPT-5\.6[\s-]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "GPT-5.5 ", with: "")
            .replacingOccurrences(of: "GPT-5.4 ", with: "5.4 ")
            .replacingOccurrences(of: "xhigh", with: "X high")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CodexRadarSnapshot: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let service: String
    let monitoredAt: String
    let timezone: String
    let windowOpen: Bool?
    let status: String
    let recommendedAction: String
    let window: CodexRadarWindow
    let prediction: CodexRadarPrediction
    let tiboPresence: CodexRadarTiboPresence?
    let recentWindows: [CodexRadarRecentWindow]
    let links: CodexRadarLinks
    let modelIQ: CodexRadarModelIQ
    let codexEnvironment: CodexRadarEnvironment?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case service
        case monitoredAt
        case timezone
        case windowOpen
        case status
        case recommendedAction
        case window
        case prediction
        case tiboPresence
        case recentWindows
        case links
        case modelIQ = "modelIq"
        case codexEnvironment
        case data
        case result
        case snapshot
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasDirectBlocks = container.contains(.window)
            || container.contains(.prediction)
            || container.contains(.modelIQ)
            || container.contains(.codexEnvironment)
            || container.contains(.tiboPresence)
            || container.contains(.recentWindows)
            || container.contains(.recommendedAction)
        if !hasDirectBlocks {
            for key in [CodingKeys.data, .result, .snapshot, .payload] {
                if let nested = container.codexRadarDecodeSafely(CodexRadarSnapshot.self, forKey: key) {
                    self = nested
                    return
                }
            }
        }

        schemaVersion = container.codexRadarString(forKey: .schemaVersion) ?? ""
        service = container.codexRadarString(forKey: .service) ?? ""
        monitoredAt = container.codexRadarString(forKey: .monitoredAt) ?? ""
        timezone = container.codexRadarString(forKey: .timezone) ?? ""
        windowOpen = container.codexRadarBool(forKey: .windowOpen)
        status = container.codexRadarString(forKey: .status) ?? ""
        recommendedAction = container.codexRadarString(forKey: .recommendedAction) ?? ""
        window = container.codexRadarDecodeSafely(CodexRadarWindow.self, forKey: .window) ?? .unavailable
        prediction = container.codexRadarDecodeSafely(CodexRadarPrediction.self, forKey: .prediction) ?? .unavailable
        if let decodedTibo = container.codexRadarDecodeSafely(CodexRadarTiboPresence.self, forKey: .tiboPresence),
           decodedTibo.hasContent {
            tiboPresence = decodedTibo
        } else {
            tiboPresence = nil
        }
        recentWindows = container.codexRadarLossyArray(CodexRadarRecentWindow.self, forKey: .recentWindows)
            .filter(\.hasContent)
        links = container.codexRadarDecodeSafely(CodexRadarLinks.self, forKey: .links) ?? .defaults
        modelIQ = container.codexRadarDecodeSafely(CodexRadarModelIQ.self, forKey: .modelIQ) ?? .unavailable
        if let decodedEnvironment = container.codexRadarDecodeSafely(CodexRadarEnvironment.self, forKey: .codexEnvironment),
           decodedEnvironment.hasContent {
            codexEnvironment = decodedEnvironment
        } else {
            codexEnvironment = nil
        }

        guard hasUsableContent else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Codex Radar payload has no usable content")
            )
        }
    }

    var hasUsableContent: Bool {
        !status.isEmpty
            || !recommendedAction.isEmpty
            || window.hasContent
            || prediction.hasContent
            || modelIQ.hasContent
            || tiboPresence != nil
            || !recentWindows.isEmpty
            || codexEnvironment?.hasContent == true
    }
}

struct CodexRadarWindow: Decodable, Equatable, Sendable {
    let open: Bool?
    let status: String
    let action: String
    let message: String
    let title: String
    let scope: String
    let openedAt: String?
    let closedAt: String?
    let sourceUrl: String?

    private enum CodingKeys: String, CodingKey {
        case open, status, action, message, title, scope, openedAt, closedAt, sourceUrl
    }

    init(
        open: Bool?,
        status: String,
        action: String,
        message: String,
        title: String,
        scope: String,
        openedAt: String?,
        closedAt: String?,
        sourceUrl: String?
    ) {
        self.open = open
        self.status = status
        self.action = action
        self.message = message
        self.title = title
        self.scope = scope
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.sourceUrl = sourceUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        open = container.codexRadarBool(forKey: .open)
        status = container.codexRadarString(forKey: .status) ?? ""
        action = container.codexRadarString(forKey: .action) ?? ""
        message = container.codexRadarString(forKey: .message) ?? ""
        title = container.codexRadarString(forKey: .title) ?? ""
        scope = container.codexRadarString(forKey: .scope) ?? ""
        openedAt = container.codexRadarString(forKey: .openedAt)
        closedAt = container.codexRadarString(forKey: .closedAt)
        sourceUrl = container.codexRadarString(forKey: .sourceUrl)
    }

    fileprivate static let unavailable = CodexRadarWindow(
        open: nil,
        status: "",
        action: "",
        message: "",
        title: "",
        scope: "",
        openedAt: nil,
        closedAt: nil,
        sourceUrl: nil
    )

    var hasContent: Bool {
        open != nil
            || !status.isEmpty
            || !action.isEmpty
            || !message.isEmpty
            || !title.isEmpty
            || !scope.isEmpty
            || sourceUrl != nil
    }
}

struct CodexRadarPrediction: Decodable, Equatable, Sendable {
    let level: String
    let probability24h: Double?
    let probability48h: Double?
    let expectedWindow: String?
    let summary: String
    let summaryEn: String?
    let positiveSignals: [String]
    let negativeSignals: [String]
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case level
        case probability24h = "probability24H"
        case probability48h = "probability48H"
        case expectedWindow
        case summary
        case summaryEn
        case positiveSignals
        case negativeSignals
        case updatedAt
    }

    init(
        level: String,
        probability24h: Double?,
        probability48h: Double?,
        expectedWindow: String?,
        summary: String,
        summaryEn: String?,
        positiveSignals: [String],
        negativeSignals: [String],
        updatedAt: String
    ) {
        self.level = level
        self.probability24h = probability24h
        self.probability48h = probability48h
        self.expectedWindow = expectedWindow
        self.summary = summary
        self.summaryEn = summaryEn
        self.positiveSignals = positiveSignals
        self.negativeSignals = negativeSignals
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = container.codexRadarString(forKey: .level) ?? ""
        probability24h = container.codexRadarDouble(forKey: .probability24h)
        probability48h = container.codexRadarDouble(forKey: .probability48h)
        expectedWindow = container.codexRadarString(forKey: .expectedWindow)
        summary = container.codexRadarString(forKey: .summary) ?? ""
        summaryEn = container.codexRadarString(forKey: .summaryEn)
        positiveSignals = container.codexRadarLossyArray(String.self, forKey: .positiveSignals)
        negativeSignals = container.codexRadarLossyArray(String.self, forKey: .negativeSignals)
        updatedAt = container.codexRadarString(forKey: .updatedAt) ?? ""
    }

    var probability24hPercent: Int? {
        probability24h.map { Int(($0 * 100).rounded()) }
    }

    var probability48hPercent: Int? {
        probability48h.map { Int(($0 * 100).rounded()) }
    }

    fileprivate static let unavailable = CodexRadarPrediction(
        level: "",
        probability24h: nil,
        probability48h: nil,
        expectedWindow: nil,
        summary: "",
        summaryEn: nil,
        positiveSignals: [],
        negativeSignals: [],
        updatedAt: ""
    )

    var hasContent: Bool {
        !level.isEmpty
            || probability24h != nil
            || probability48h != nil
            || !summary.isEmpty
            || !positiveSignals.isEmpty
            || !negativeSignals.isEmpty
    }
}

struct CodexRadarTiboPresence: Decodable, Equatable, Sendable {
    let schemaVersion: String?
    let mode: String?
    let timezone: String?
    let locationLabelZh: String?
    let locationLabelEn: String?
    let probability: Double?
    let confidence: String?
    let evidenceSummaryZh: String?
    let evidenceSummaryEn: String?
    let sourceUrls: [String]
    let shouldDisplay: Bool?
    let safetyNoteZh: String?
    let safetyNoteEn: String?
    let updatedAt: String?
    let observedAt: String?
    let staleAt: String?
    let observationsConsidered: Int?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, timezone, locationLabelZh, locationLabelEn, probability, confidence
        case evidenceSummaryZh, evidenceSummaryEn, sourceUrls, shouldDisplay, safetyNoteZh, safetyNoteEn
        case updatedAt, observedAt, staleAt, observationsConsidered
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.codexRadarString(forKey: .schemaVersion)
        mode = container.codexRadarString(forKey: .mode)
        timezone = container.codexRadarString(forKey: .timezone)
        locationLabelZh = container.codexRadarString(forKey: .locationLabelZh)
        locationLabelEn = container.codexRadarString(forKey: .locationLabelEn)
        probability = container.codexRadarDouble(forKey: .probability)
        confidence = container.codexRadarString(forKey: .confidence)
        evidenceSummaryZh = container.codexRadarString(forKey: .evidenceSummaryZh)
        evidenceSummaryEn = container.codexRadarString(forKey: .evidenceSummaryEn)
        sourceUrls = container.codexRadarLossyArray(String.self, forKey: .sourceUrls)
        shouldDisplay = container.codexRadarBool(forKey: .shouldDisplay)
        safetyNoteZh = container.codexRadarString(forKey: .safetyNoteZh)
        safetyNoteEn = container.codexRadarString(forKey: .safetyNoteEn)
        updatedAt = container.codexRadarString(forKey: .updatedAt)
        observedAt = container.codexRadarString(forKey: .observedAt)
        staleAt = container.codexRadarString(forKey: .staleAt)
        observationsConsidered = container.codexRadarInt(forKey: .observationsConsidered)
    }

    var hasContent: Bool {
        Self.hasText(mode)
            || Self.hasText(timezone)
            || Self.hasText(locationLabelZh)
            || Self.hasText(locationLabelEn)
            || probability != nil
            || Self.hasText(confidence)
            || !sourceUrls.isEmpty
            || shouldDisplay != nil
            || Self.hasText(safetyNoteZh)
    }

    private static func hasText(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct CodexRadarRecentWindow: Decodable, Equatable, Sendable {
    let title: String?
    let status: String?
    let openedAt: String?
    let closedAt: String?
    let sourceUrl: String?

    var hasContent: Bool {
        [title, status, openedAt, closedAt, sourceUrl]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { !$0.isEmpty }
    }
}

struct CodexRadarLinks: Decodable, Equatable, Sendable {
    let html: String
    let rss: String

    private enum CodingKeys: String, CodingKey { case html, rss }

    init(html: String, rss: String) {
        self.html = html
        self.rss = rss
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        html = container.codexRadarString(forKey: .html) ?? Self.defaults.html
        rss = container.codexRadarString(forKey: .rss) ?? Self.defaults.rss
    }

    fileprivate static let defaults = CodexRadarLinks(
        html: "https://codexradar.com",
        rss: "https://codexradar.com/feed.xml"
    )
}

struct CodexRadarModelIQ: Decodable, Equatable, Sendable {
    let latest: CodexRadarModelIQPoint
    let recentDays: [CodexRadarModelIQPoint]
    let comparisons: [String: CodexRadarModelIQComparison]
    let quotaCalibration: CodexRadarQuotaCalibration?
    let quotaRadar: CodexRadarQuotaRadar?
    let quotaCheck: CodexRadarQuotaCheck?

    private enum CodingKeys: String, CodingKey {
        case latest
        case recentDays
        case comparisons
        case quotaCalibration
        case quotaRadar
        case quotaCheck
    }

    init(
        latest: CodexRadarModelIQPoint,
        recentDays: [CodexRadarModelIQPoint],
        comparisons: [String: CodexRadarModelIQComparison],
        quotaCalibration: CodexRadarQuotaCalibration?,
        quotaRadar: CodexRadarQuotaRadar?,
        quotaCheck: CodexRadarQuotaCheck?
    ) {
        self.latest = latest
        self.recentDays = recentDays
        self.comparisons = comparisons
        self.quotaCalibration = quotaCalibration
        self.quotaRadar = quotaRadar
        self.quotaCheck = quotaCheck
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = container.codexRadarDecodeSafely(CodexRadarModelIQPoint.self, forKey: .latest) ?? .unavailable
        recentDays = container.codexRadarLossyArray(CodexRadarModelIQPoint.self, forKey: .recentDays)
            .filter(\.hasMeasurement)
        comparisons = container.codexRadarLossyDictionary(CodexRadarModelIQComparison.self, forKey: .comparisons)
            .filter { $0.value.latest.hasMeasurement }
        quotaCalibration = container.codexRadarDecodeSafely(CodexRadarQuotaCalibration.self, forKey: .quotaCalibration)
        if let decodedQuota = container.codexRadarDecodeSafely(CodexRadarQuotaRadar.self, forKey: .quotaRadar),
           decodedQuota.hasContent {
            quotaRadar = decodedQuota
        } else {
            quotaRadar = nil
        }
        if let decodedCheck = container.codexRadarDecodeSafely(CodexRadarQuotaCheck.self, forKey: .quotaCheck),
           decodedCheck.hasContent {
            quotaCheck = decodedCheck
        } else {
            quotaCheck = nil
        }
    }

    var primaryModelRow: CodexRadarModelIQComparisonRow {
        allCurrentRows.sorted(by: isPreferredPrimaryModel).first
            ?? CodexRadarModelIQComparisonRow(label: latest.modelDisplayName, point: latest)
    }

    var primaryModelPoint: CodexRadarModelIQPoint? {
        let point = primaryModelRow.point
        return point.hasMeasurement ? point : nil
    }

    var secondaryModelRows: [CodexRadarModelIQComparisonRow] {
        let primary = primaryModelRow
        return allCurrentRows
            .filter { row in
                row.point.modelSeriesID != primary.point.modelSeriesID
            }
            .sorted(by: isPreferredPrimaryModel)
    }

    var comparisonRows: [CodexRadarModelIQComparisonRow] {
        let latestRow = CodexRadarModelIQComparisonRow(label: latest.modelDisplayName, point: latest)
        let comparisonRows = comparisons
            .map { CodexRadarModelIQComparisonRow(label: $0.value.label, point: $0.value.latest) }
            .sorted { lhs, rhs in
                let order = ["GPT-5.5 high", "GPT-5.5 medium", "GPT-5.4 xhigh"]
                let lhsIndex = order.firstIndex(of: lhs.label) ?? Int.max
                let rhsIndex = order.firstIndex(of: rhs.label) ?? Int.max
                if lhsIndex == rhsIndex { return lhs.label < rhs.label }
                return lhsIndex < rhsIndex
        }
        return [latestRow] + comparisonRows
    }

    var chartSeries: [CodexRadarChartSeries] {
        let latestSeries: [CodexRadarChartSeries] = latest.hasMeasurement ? [
            CodexRadarChartSeries(
                id: latest.modelSeriesID,
                label: latest.modelDisplayName,
                points: (recentDays.isEmpty ? [latest] : recentDays).map(CodexRadarChartPoint.init)
            )
        ] : []
        let comparisonSeries = comparisons
            .map { comparison -> CodexRadarChartSeries in
                CodexRadarChartSeries(
                    id: "\(comparison.value.model)-\(comparison.value.reasoningEffort)",
                    label: comparison.value.label,
                    points: (comparison.value.recentDays.isEmpty ? [comparison.value.latest] : comparison.value.recentDays).map(CodexRadarChartPoint.init)
                )
            }
            .sorted { lhs, rhs in
                let order = ["GPT-5.5 high", "GPT-5.5 medium", "GPT-5.4 xhigh"]
                let lhsIndex = order.firstIndex(of: lhs.label) ?? Int.max
                let rhsIndex = order.firstIndex(of: rhs.label) ?? Int.max
                if lhsIndex == rhsIndex { return lhs.label < rhs.label }
                return lhsIndex < rhsIndex
        }
        return latestSeries + comparisonSeries
    }

    private var allCurrentRows: [CodexRadarModelIQComparisonRow] {
        (latest.hasMeasurement ? [CodexRadarModelIQComparisonRow(label: latest.modelDisplayName, point: latest)] : [])
            + comparisons.values.map { CodexRadarModelIQComparisonRow(label: $0.label, point: $0.latest) }
    }

    fileprivate static let unavailable = CodexRadarModelIQ(
        latest: .unavailable,
        recentDays: [],
        comparisons: [:],
        quotaCalibration: nil,
        quotaRadar: nil,
        quotaCheck: nil
    )

    var hasContent: Bool {
        latest.hasMeasurement || !comparisons.isEmpty || quotaRadar?.hasContent == true || quotaCheck != nil
    }

    private func isPreferredPrimaryModel(
        _ lhs: CodexRadarModelIQComparisonRow,
        over rhs: CodexRadarModelIQComparisonRow
    ) -> Bool {
        if lhs.point.score != rhs.point.score {
            return lhs.point.score > rhs.point.score
        }

        switch (lhs.point.costUsd, rhs.point.costUsd) {
        case let (lhsCost?, rhsCost?) where lhsCost != rhsCost:
            return lhsCost < rhsCost
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            break
        }

        let lhsEffortRank = Self.reasoningEffortCostRank(lhs.point.reasoningEffort)
        let rhsEffortRank = Self.reasoningEffortCostRank(rhs.point.reasoningEffort)
        if lhsEffortRank != rhsEffortRank {
            return lhsEffortRank < rhsEffortRank
        }

        return lhs.label < rhs.label
    }

    private static func reasoningEffortCostRank(_ effort: String?) -> Int {
        switch effort?.lowercased() {
        case "minimal":
            return 0
        case "low":
            return 1
        case "medium":
            return 2
        case "high":
            return 3
        case "xhigh":
            return 4
        default:
            return Int.max
        }
    }
}

struct CodexRadarChartSeries: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let points: [CodexRadarChartPoint]
}

struct CodexRadarChartPoint: Equatable, Sendable, Identifiable {
    var id: String { xLabel }

    let rawLabel: String
    let xLabel: String
    let value: Double

    init(rawLabel: String, xLabel: String, value: Double) {
        self.rawLabel = rawLabel
        self.xLabel = xLabel
        self.value = value
    }

    init(point: CodexRadarModelIQPoint) {
        self.init(rawLabel: point.date, xLabel: Self.shortDateLabel(point.date), value: point.score)
    }

    static func shortDateLabel(_ raw: String) -> String {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4,
              parts[0].count == 4,
              parts[0].allSatisfy(\.isNumber),
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              Self.isValidGregorianDate(year: year, month: month, day: day)
        else {
            return raw
        }

        var label = "\(month).\(day)"
        if parts.count == 4 {
            guard parts[3] == "am" || parts[3] == "pm" else { return raw }
            label += " \(parts[3])"
        }
        return label
    }

    private static func isValidGregorianDate(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }
}

enum CodexRadarQuotaWindow: String, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case sevenDay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: "5 小时"
        case .sevenDay: "7 天"
        }
    }

    var shortTitle: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        }
    }
}

struct CodexRadarModelIQComparison: Decodable, Equatable, Sendable {
    let label: String
    let model: String
    let reasoningEffort: String
    let latest: CodexRadarModelIQPoint
    let recentDays: [CodexRadarModelIQPoint]

    private enum CodingKeys: String, CodingKey {
        case label
        case model
        case reasoningEffort
        case latest
        case recentDays
    }

    init(
        label: String,
        model: String,
        reasoningEffort: String,
        latest: CodexRadarModelIQPoint,
        recentDays: [CodexRadarModelIQPoint]
    ) {
        self.label = label
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.latest = latest
        self.recentDays = recentDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = container.codexRadarDecodeSafely(CodexRadarModelIQPoint.self, forKey: .latest) ?? .unavailable
        label = container.codexRadarString(forKey: .label) ?? latest.modelDisplayName
        model = container.codexRadarString(forKey: .model) ?? latest.model ?? ""
        reasoningEffort = container.codexRadarString(forKey: .reasoningEffort) ?? latest.reasoningEffort ?? ""
        recentDays = container.codexRadarLossyArray(CodexRadarModelIQPoint.self, forKey: .recentDays)
            .filter(\.hasMeasurement)
    }
}

struct CodexRadarModelIQComparisonRow: Equatable, Sendable {
    let label: String
    let point: CodexRadarModelIQPoint
}

struct CodexRadarModelIQPoint: Decodable, Equatable, Sendable, Identifiable {
    var id: String { "\(date)-\(model ?? "")-\(reasoningEffort ?? "")-\(score)" }

    let date: String
    let score: Double
    let status: String
    let passed: Int
    let tasks: Int
    let invalid: Int
    let totalTokens: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let wallSeconds: Int
    let wallTimeHuman: String
    let model: String?
    let reasoningEffort: String?
    let validTasks: Int?
    let costUsd: Double?
    private let scoreAvailable: Bool

    private enum CodingKeys: String, CodingKey {
        case date, score, status, passed, tasks, invalid, totalTokens, inputTokens, cachedInputTokens
        case outputTokens, wallSeconds, wallTimeHuman, model, reasoningEffort, validTasks, costUsd
    }

    init(
        date: String,
        score: Double,
        status: String,
        passed: Int,
        tasks: Int,
        invalid: Int,
        totalTokens: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        wallSeconds: Int,
        wallTimeHuman: String,
        model: String?,
        reasoningEffort: String?,
        validTasks: Int?,
        costUsd: Double?,
        scoreAvailable: Bool = true
    ) {
        self.date = date
        self.score = score
        self.status = status
        self.passed = passed
        self.tasks = tasks
        self.invalid = invalid
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.wallSeconds = wallSeconds
        self.wallTimeHuman = wallTimeHuman
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.validTasks = validTasks
        self.costUsd = costUsd
        self.scoreAvailable = scoreAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedScore = container.codexRadarDouble(forKey: .score)
        date = container.codexRadarString(forKey: .date) ?? ""
        score = decodedScore ?? 0
        status = container.codexRadarString(forKey: .status) ?? ""
        passed = container.codexRadarInt(forKey: .passed) ?? 0
        tasks = container.codexRadarInt(forKey: .tasks) ?? 0
        invalid = container.codexRadarInt(forKey: .invalid) ?? 0
        totalTokens = container.codexRadarInt(forKey: .totalTokens) ?? 0
        inputTokens = container.codexRadarInt(forKey: .inputTokens) ?? 0
        cachedInputTokens = container.codexRadarInt(forKey: .cachedInputTokens) ?? 0
        outputTokens = container.codexRadarInt(forKey: .outputTokens) ?? 0
        wallSeconds = container.codexRadarInt(forKey: .wallSeconds) ?? 0
        wallTimeHuman = container.codexRadarString(forKey: .wallTimeHuman) ?? ""
        model = container.codexRadarString(forKey: .model)
        reasoningEffort = container.codexRadarString(forKey: .reasoningEffort)
        validTasks = container.codexRadarInt(forKey: .validTasks)
        costUsd = container.codexRadarDouble(forKey: .costUsd)
        scoreAvailable = decodedScore != nil
    }

    var hasMeasurement: Bool { scoreAvailable }

    var modelDisplayName: String {
        guard hasMeasurement else { return "--" }
        let modelText = model?.uppercased() ?? "MODEL"
        guard let reasoningEffort, !reasoningEffort.isEmpty else {
            return modelText
        }
        return "\(modelText) \(reasoningEffort)"
    }

    var modelSeriesID: String {
        "\(model ?? "model")-\(reasoningEffort ?? "default")"
    }

    var scoreDisplayText: String {
        hasMeasurement ? "IQ \(Self.display(score))" : "IQ --"
    }

    var passRatioText: String {
        hasMeasurement && tasks > 0 ? "\(passed)/\(tasks)" : "--"
    }

    var costDisplayText: String {
        guard let costUsd else { return "费用未知" }
        return "$\(Self.display(costUsd, fractionDigits: 2))"
    }

    var totalTokensDisplayText: String {
        guard hasMeasurement, totalTokens > 0 else { return "--" }
        let millions = Double(totalTokens) / 1_000_000
        return "\(Self.display(millions, fractionDigits: 2))M"
    }

    fileprivate static let unavailable = CodexRadarModelIQPoint(
        date: "",
        score: 0,
        status: "",
        passed: 0,
        tasks: 0,
        invalid: 0,
        totalTokens: 0,
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        wallSeconds: 0,
        wallTimeHuman: "",
        model: nil,
        reasoningEffort: nil,
        validTasks: nil,
        costUsd: nil,
        scoreAvailable: false
    )

    static func display(_ value: Double, fractionDigits: Int = 1) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.\(fractionDigits)f", value)
    }
}

struct CodexRadarQuotaCalibration: Decodable, Equatable, Sendable {
    let schemaVersion: String?
    let date: String
    let source: String
    let status: String
    let primaryWindow: String?
    let globalConcurrency: Int?
    let checkedAtBefore: String?
    let checkedAtAfter: String?
    let tasks: Int?
    let validTasks: Int?
    let costUsd: Double?
    let totalTokens: Int?
}

struct CodexRadarQuotaRadar: Decodable, Equatable, Sendable {
    let date: String
    let source: String
    let updatedAt: String
    let basisDate: String
    let costUsd: Double?
    let totalTokens: Int?
    let basisWindow: String
    let basisWindowLabel: String
    let adjustedDelta: Int?
    let rawDelta: Int?
    let offset: Int?
    let rate: Double?
    let endpoint: String?
    let sourceKind: String?
    let tasks: Int?
    let fiveHourPolicy: String?
    let sevenDayPolicy: String?
    let rows: [CodexRadarQuotaRow]
    let trend: [CodexRadarQuotaTrendPoint]

    private enum CodingKeys: String, CodingKey {
        case date, source, updatedAt, basisDate, costUsd, totalTokens, basisWindow, basisWindowLabel
        case adjustedDelta, rawDelta, offset, rate, endpoint, sourceKind, tasks
        case fiveHourPolicy, sevenDayPolicy, rows, trend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = container.codexRadarString(forKey: .date) ?? ""
        source = container.codexRadarString(forKey: .source) ?? ""
        updatedAt = container.codexRadarString(forKey: .updatedAt) ?? ""
        basisDate = container.codexRadarString(forKey: .basisDate) ?? ""
        costUsd = container.codexRadarDouble(forKey: .costUsd)
        totalTokens = container.codexRadarInt(forKey: .totalTokens)
        basisWindow = container.codexRadarString(forKey: .basisWindow) ?? ""
        basisWindowLabel = container.codexRadarString(forKey: .basisWindowLabel) ?? ""
        adjustedDelta = container.codexRadarInt(forKey: .adjustedDelta)
        rawDelta = container.codexRadarInt(forKey: .rawDelta)
        offset = container.codexRadarInt(forKey: .offset)
        rate = container.codexRadarDouble(forKey: .rate)
        endpoint = container.codexRadarString(forKey: .endpoint)
        sourceKind = container.codexRadarString(forKey: .sourceKind)
        tasks = container.codexRadarInt(forKey: .tasks)
        fiveHourPolicy = container.codexRadarString(forKey: .fiveHourPolicy)
        sevenDayPolicy = container.codexRadarString(forKey: .sevenDayPolicy)
        rows = container.codexRadarLossyArray(CodexRadarQuotaRow.self, forKey: .rows)
            .filter(\.hasContent)
        trend = container.codexRadarLossyArray(CodexRadarQuotaTrendPoint.self, forKey: .trend)
            .filter(\.hasContent)
    }

    var hasContent: Bool {
        !rows.isEmpty || !trend.isEmpty
    }

    var rowsForDisplay: [CodexRadarQuotaRow] {
        let order = ["Plus", "5x Pro", "20x Pro"]
        return rows.sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs.tier) ?? Int.max
            let rhsIndex = order.firstIndex(of: rhs.tier) ?? Int.max
            if lhsIndex == rhsIndex { return lhs.tier < rhs.tier }
            return lhsIndex < rhsIndex
        }
    }

    var availableWindows: [CodexRadarQuotaWindow] {
        CodexRadarQuotaWindow.allCases.filter(isWindowAvailable)
    }

    func resolvedWindow(_ requested: CodexRadarQuotaWindow) -> CodexRadarQuotaWindow? {
        if isWindowAvailable(requested) { return requested }
        return availableWindows.first
    }

    func isWindowAvailable(_ window: CodexRadarQuotaWindow) -> Bool {
        switch window {
        case .fiveHour:
            guard !Self.policyHidesWindow(fiveHourPolicy) else { return false }
            return rows.contains { $0.fiveH != nil }
                || trend.contains { $0.fiveHour20x != nil || $0.fiveHour5x != nil || $0.fiveHourPlus != nil }
        case .sevenDay:
            guard !Self.policyHidesWindow(sevenDayPolicy) else { return false }
            return rows.contains { $0.sevenD != nil }
                || trend.contains { $0.sevenDay20x != nil }
        }
    }

    func chartSeries(for window: CodexRadarQuotaWindow) -> [CodexRadarChartSeries] {
        guard isWindowAvailable(window) else { return [] }
        return [
            CodexRadarChartSeries(
                id: "quota-plus",
                label: "Plus",
                points: trend.compactMap { point in
                    guard let value = point.value(for: window, tier: .plus) else { return nil }
                    return CodexRadarChartPoint(
                        rawLabel: point.date,
                        xLabel: CodexRadarChartPoint.shortDateLabel(point.date),
                        value: value
                    )
                }
            ),
            CodexRadarChartSeries(
                id: "quota-5x",
                label: "5x Pro",
                points: trend.compactMap { point in
                    guard let value = point.value(for: window, tier: .fiveX) else { return nil }
                    return CodexRadarChartPoint(
                        rawLabel: point.date,
                        xLabel: CodexRadarChartPoint.shortDateLabel(point.date),
                        value: value
                    )
                }
            ),
            CodexRadarChartSeries(
                id: "quota-20x",
                label: "20x Pro",
                points: trend.compactMap { point in
                    guard let value = point.value(for: window, tier: .twentyX) else { return nil }
                    return CodexRadarChartPoint(
                        rawLabel: point.date,
                        xLabel: CodexRadarChartPoint.shortDateLabel(point.date),
                        value: value
                    )
                }
            )
        ].filter { !$0.points.isEmpty }
    }

    private static func policyHidesWindow(_ policy: String?) -> Bool {
        let normalized = policy?.lowercased() ?? ""
        return ["hidden", "paused", "disabled", "cancelled", "canceled", "removed", "retired"]
            .contains { normalized.contains($0) }
    }
}

private enum CodexRadarQuotaTier {
    case plus
    case fiveX
    case twentyX
}

struct CodexRadarQuotaRow: Decodable, Equatable, Sendable, Identifiable {
    var id: String { tier }

    let tier: String
    let basis: String
    let fiveH: Double?
    let sevenD: Double?

    private enum CodingKeys: String, CodingKey { case tier, basis, fiveH, sevenD }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = container.codexRadarString(forKey: .tier) ?? ""
        basis = container.codexRadarString(forKey: .basis) ?? ""
        fiveH = container.codexRadarDouble(forKey: .fiveH)
        sevenD = container.codexRadarDouble(forKey: .sevenD)
    }

    var hasContent: Bool {
        !tier.isEmpty && (fiveH != nil || sevenD != nil)
    }

    var fiveHourDisplayText: String {
        guard let fiveH else { return "--" }
        return "$\(CodexRadarModelIQPoint.display(fiveH, fractionDigits: 2))"
    }

    var sevenDayDisplayText: String {
        guard let sevenD else { return "--" }
        return "$\(CodexRadarModelIQPoint.display(sevenD, fractionDigits: 2))"
    }
}

struct CodexRadarQuotaTrendPoint: Decodable, Equatable, Sendable, Identifiable {
    var id: String { date }

    let date: String
    let source: String
    let updatedAt: String
    let fiveHour20x: Double?
    let sevenDay20x: Double?
    let fiveHour5x: Double?
    let fiveHourPlus: Double?
    let basisWindow: String
    let basisWindowLabel: String
    let rate: Double?
    let rawDelta: Int?
    let adjustedDelta: Int?
    let offset: Int?
    let costUsd: Double?
    let totalTokens: Int?

    fileprivate func value(for window: CodexRadarQuotaWindow, tier: CodexRadarQuotaTier) -> Double? {
        switch (window, tier) {
        case (.fiveHour, .plus):
            return fiveHourPlus
        case (.fiveHour, .fiveX):
            return fiveHour5x
        case (.fiveHour, .twentyX):
            return fiveHour20x
        case (.sevenDay, .plus):
            return sevenDay20x.map { $0 / 20 }
        case (.sevenDay, .fiveX):
            return sevenDay20x.map { $0 / 4 }
        case (.sevenDay, .twentyX):
            return sevenDay20x
        }
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case source
        case updatedAt
        case fiveHour20x = "fiveH20X"
        case sevenDay20x = "sevenD20X"
        case fiveHour5x = "fiveH5X"
        case fiveHourPlus = "fiveHPlus"
        case basisWindow
        case basisWindowLabel
        case rate
        case rawDelta
        case adjustedDelta
        case offset
        case costUsd
        case totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = container.codexRadarString(forKey: .date) ?? ""
        source = container.codexRadarString(forKey: .source) ?? ""
        updatedAt = container.codexRadarString(forKey: .updatedAt) ?? ""
        fiveHour20x = container.codexRadarDouble(forKey: .fiveHour20x)
        sevenDay20x = container.codexRadarDouble(forKey: .sevenDay20x)
        fiveHour5x = container.codexRadarDouble(forKey: .fiveHour5x)
        fiveHourPlus = container.codexRadarDouble(forKey: .fiveHourPlus)
        basisWindow = container.codexRadarString(forKey: .basisWindow) ?? ""
        basisWindowLabel = container.codexRadarString(forKey: .basisWindowLabel) ?? ""
        rate = container.codexRadarDouble(forKey: .rate)
        rawDelta = container.codexRadarInt(forKey: .rawDelta)
        adjustedDelta = container.codexRadarInt(forKey: .adjustedDelta)
        offset = container.codexRadarInt(forKey: .offset)
        costUsd = container.codexRadarDouble(forKey: .costUsd)
        totalTokens = container.codexRadarInt(forKey: .totalTokens)
    }

    var hasContent: Bool {
        !date.isEmpty
            && (fiveHour20x != nil || sevenDay20x != nil || fiveHour5x != nil || fiveHourPlus != nil)
    }
}

struct CodexRadarQuotaCheck: Decodable, Equatable, Sendable {
    let schemaVersion: String?
    let date: String?
    let source: String?
    let status: String?
    let checkedAt: String?
    let planType: String?
    let rateLimitResetCreditsAvailableCount: Int?
    let limitReached: Bool?
    let allowed: Bool?

    var hasContent: Bool {
        [schemaVersion, date, source, status, checkedAt, planType]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { !$0.isEmpty }
            || rateLimitResetCreditsAvailableCount != nil
            || limitReached != nil
            || allowed != nil
    }
}

struct CodexRadarEnvironment: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let type: String
    let updatedAt: String
    let statusIncidents24h: Int?
    let officialUpdates24h: Int?
    let communityMentions24h: Int?
    let issueOrLimitAnomalies24h: Int?
    let complaintPressure: String
    let resetCard: CodexRadarResetCard?
    let officialNews: [CodexRadarNewsItem]
    let statusIncidents: [CodexRadarNewsItem]
    let complaintExamples: [CodexRadarComplaintExample]
    let roleCounts: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case type
        case updatedAt
        case statusIncidents24h = "statusIncidents24H"
        case officialUpdates24h = "officialUpdates24H"
        case communityMentions24h = "communityMentions24H"
        case issueOrLimitAnomalies24h = "issueOrLimitAnomalies24H"
        case complaintPressure
        case resetCard
        case officialNews
        case statusIncidents
        case complaintExamples
        case roleCounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.codexRadarString(forKey: .schemaVersion) ?? ""
        type = container.codexRadarString(forKey: .type) ?? ""
        updatedAt = container.codexRadarString(forKey: .updatedAt) ?? ""
        statusIncidents24h = container.codexRadarInt(forKey: .statusIncidents24h)
        officialUpdates24h = container.codexRadarInt(forKey: .officialUpdates24h)
        communityMentions24h = container.codexRadarInt(forKey: .communityMentions24h)
        issueOrLimitAnomalies24h = container.codexRadarInt(forKey: .issueOrLimitAnomalies24h)
        complaintPressure = container.codexRadarString(forKey: .complaintPressure) ?? ""
        resetCard = container.codexRadarDecodeSafely(CodexRadarResetCard.self, forKey: .resetCard)
        officialNews = container.codexRadarLossyArray(CodexRadarNewsItem.self, forKey: .officialNews)
            .filter { !$0.url.isEmpty }
        statusIncidents = container.codexRadarLossyArray(CodexRadarNewsItem.self, forKey: .statusIncidents)
            .filter { !$0.url.isEmpty }
        complaintExamples = container.codexRadarLossyArray(CodexRadarComplaintExample.self, forKey: .complaintExamples)
            .filter { !$0.url.isEmpty && !$0.summaryZh.isEmpty }
        roleCounts = container.codexRadarDecodeSafely([String: Int].self, forKey: .roleCounts) ?? [:]
    }

    var hasContent: Bool {
        statusIncidents24h != nil
            || officialUpdates24h != nil
            || communityMentions24h != nil
            || issueOrLimitAnomalies24h != nil
            || !complaintPressure.isEmpty
            || resetCard != nil
            || !officialNews.isEmpty
            || !statusIncidents.isEmpty
            || !complaintExamples.isEmpty
            || !roleCounts.isEmpty
    }
}

struct CodexRadarResetCard: Decodable, Equatable, Sendable {
    let probability24h: Double
    let probability48h: Double
    let level: String
    let status: String
    let note: String

    private enum CodingKeys: String, CodingKey {
        case probability24h = "probability24H"
        case probability48h = "probability48H"
        case level
        case status
        case note
    }
}

struct CodexRadarNewsItem: Decodable, Equatable, Sendable, Identifiable {
    var id: String { url }

    let titleZh: String?
    let summaryZh: String?
    let summaryEn: String?
    let source: String?
    let account: String?
    let createdAt: String?
    let semanticRole: String?
    let url: String
    let text: String?
}

struct CodexRadarComplaintExample: Decodable, Equatable, Sendable, Identifiable {
    var id: String { url }

    let summaryZh: String
    let summaryEn: String?
    let account: String
    let createdAt: String
    let url: String
    let semanticRole: String
    let predictionRelevance: Int?
}
