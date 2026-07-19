import Foundation

extension JSONDecoder {
    static var codexRadar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

enum CodexRadarPresentationText {
    static func action(_ rawValue: String?) -> String {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch value.lowercased() {
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
        default:
            return value.isEmpty ? "--" : value
        }
    }

    static func compactModelName(_ rawValue: String) -> String {
        let familyNames = ["Sol", "Luna", "Terra"]
        let tokens = rawValue.components(separatedBy: CharacterSet.alphanumerics.inverted)
        if let family = familyNames.first(where: { family in
            tokens.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame })
        }) {
            let effortNames = ["max", "xhigh", "high", "medium", "low", "minimal"]
            let effort = effortNames.first(where: { effort in
                tokens.contains(where: { $0.caseInsensitiveCompare(effort) == .orderedSame })
            })
            return effort.map { "\(family) \($0)" } ?? family
        }
        return rawValue
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
    let windowOpen: Bool
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        service = try container.decode(String.self, forKey: .service)
        monitoredAt = try container.decode(String.self, forKey: .monitoredAt)
        timezone = try container.decode(String.self, forKey: .timezone)
        windowOpen = try container.decode(Bool.self, forKey: .windowOpen)
        status = try container.decode(String.self, forKey: .status)
        recommendedAction = try container.decode(String.self, forKey: .recommendedAction)
        window = try container.decode(CodexRadarWindow.self, forKey: .window)
        prediction = try container.decode(CodexRadarPrediction.self, forKey: .prediction)
        tiboPresence = try container.decodeIfPresent(CodexRadarTiboPresence.self, forKey: .tiboPresence)
        recentWindows = try container.decodeIfPresent([CodexRadarRecentWindow].self, forKey: .recentWindows) ?? []
        links = try container.decode(CodexRadarLinks.self, forKey: .links)
        modelIQ = try container.decode(CodexRadarModelIQ.self, forKey: .modelIQ)
        codexEnvironment = try container.decodeIfPresent(CodexRadarEnvironment.self, forKey: .codexEnvironment)
    }
}

struct CodexRadarWindow: Decodable, Equatable, Sendable {
    let open: Bool
    let status: String
    let action: String
    let message: String
    let title: String
    let scope: String
    let openedAt: String?
    let closedAt: String?
    let sourceUrl: String?
}

struct CodexRadarPrediction: Decodable, Equatable, Sendable {
    let level: String
    let probability24h: Double
    let probability48h: Double
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decode(String.self, forKey: .level)
        probability24h = try container.decode(Double.self, forKey: .probability24h)
        probability48h = try container.decode(Double.self, forKey: .probability48h)
        expectedWindow = try container.decodeIfPresent(String.self, forKey: .expectedWindow)
        summary = try container.decode(String.self, forKey: .summary)
        summaryEn = try container.decodeIfPresent(String.self, forKey: .summaryEn)
        positiveSignals = try container.decodeIfPresent([String].self, forKey: .positiveSignals) ?? []
        negativeSignals = try container.decodeIfPresent([String].self, forKey: .negativeSignals) ?? []
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }

    var probability24hPercent: Int {
        Int((probability24h * 100).rounded())
    }

    var probability48hPercent: Int {
        Int((probability48h * 100).rounded())
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
}

struct CodexRadarRecentWindow: Decodable, Equatable, Sendable {
    let title: String?
    let status: String?
    let openedAt: String?
    let closedAt: String?
    let sourceUrl: String?
}

struct CodexRadarLinks: Decodable, Equatable, Sendable {
    let html: String
    let rss: String
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
        latest = try container.decode(CodexRadarModelIQPoint.self, forKey: .latest)
        recentDays = try container.decodeIfPresent([CodexRadarModelIQPoint].self, forKey: .recentDays) ?? []
        comparisons = try container.decodeIfPresent([String: CodexRadarModelIQComparison].self, forKey: .comparisons) ?? [:]
        quotaCalibration = try container.decodeIfPresent(CodexRadarQuotaCalibration.self, forKey: .quotaCalibration)
        quotaRadar = try container.decodeIfPresent(CodexRadarQuotaRadar.self, forKey: .quotaRadar)
        quotaCheck = try container.decodeIfPresent(CodexRadarQuotaCheck.self, forKey: .quotaCheck)
    }

    var primaryModelRow: CodexRadarModelIQComparisonRow {
        allCurrentRows.sorted(by: isPreferredPrimaryModel).first
            ?? CodexRadarModelIQComparisonRow(label: latest.modelDisplayName, point: latest)
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
        let latestSeries = CodexRadarChartSeries(
            id: latest.modelSeriesID,
            label: latest.modelDisplayName,
            points: (recentDays.isEmpty ? [latest] : recentDays).map(CodexRadarChartPoint.init)
        )
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
        return [latestSeries] + comparisonSeries
    }

    private var allCurrentRows: [CodexRadarModelIQComparisonRow] {
        [CodexRadarModelIQComparisonRow(label: latest.modelDisplayName, point: latest)]
            + comparisons.map { CodexRadarModelIQComparisonRow(label: $0.value.label, point: $0.value.latest) }
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
        label = try container.decode(String.self, forKey: .label)
        model = try container.decode(String.self, forKey: .model)
        reasoningEffort = try container.decode(String.self, forKey: .reasoningEffort)
        latest = try container.decode(CodexRadarModelIQPoint.self, forKey: .latest)
        recentDays = try container.decodeIfPresent([CodexRadarModelIQPoint].self, forKey: .recentDays) ?? []
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

    var modelDisplayName: String {
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
        "IQ \(Self.display(score))"
    }

    var passRatioText: String {
        "\(passed)/\(tasks)"
    }

    var costDisplayText: String {
        guard let costUsd else { return "费用未知" }
        return "$\(Self.display(costUsd, fractionDigits: 2))"
    }

    var totalTokensDisplayText: String {
        let millions = Double(totalTokens) / 1_000_000
        return "\(Self.display(millions, fractionDigits: 2))M"
    }

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
    let costUsd: Double
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
        return normalized.contains("hidden") || normalized.contains("paused") || normalized.contains("disabled")
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
    let costUsd: Double
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
}

struct CodexRadarEnvironment: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let type: String
    let updatedAt: String
    let statusIncidents24h: Int
    let officialUpdates24h: Int
    let communityMentions24h: Int
    let issueOrLimitAnomalies24h: Int
    let complaintPressure: String
    let resetCard: CodexRadarResetCard
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
