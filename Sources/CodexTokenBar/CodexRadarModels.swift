import Foundation

extension JSONDecoder {
    static var codexRadar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
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
    let codexEnvironment: CodexRadarEnvironment

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
    let expectedWindow: String
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
        let trimmed = raw.replacingOccurrences(of: "2026-06-", with: "6.")
            .replacingOccurrences(of: "-am", with: " am")
            .replacingOccurrences(of: "-pm", with: " pm")
        if trimmed.hasPrefix("2026-") {
            return String(trimmed.dropFirst(5))
        }
        return trimmed
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
    let totalTokens: Int
    let basisWindow: String
    let basisWindowLabel: String
    let adjustedDelta: Int
    let rawDelta: Int
    let offset: Int
    let rate: Double
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

    func chartSeries(for window: CodexRadarQuotaWindow) -> [CodexRadarChartSeries] {
        [
            CodexRadarChartSeries(
                id: "quota-plus",
                label: "Plus",
                points: trend.map { point in
                    CodexRadarChartPoint(
                        rawLabel: point.date,
                        xLabel: CodexRadarChartPoint.shortDateLabel(point.date),
                        value: point.value(for: window, tier: .plus)
                    )
                }
            ),
            CodexRadarChartSeries(
                id: "quota-5x",
                label: "5x Pro",
                points: trend.map { point in
                    CodexRadarChartPoint(
                        rawLabel: point.date,
                        xLabel: CodexRadarChartPoint.shortDateLabel(point.date),
                        value: point.value(for: window, tier: .fiveX)
                    )
                }
            ),
            CodexRadarChartSeries(
                id: "quota-20x",
                label: "20x Pro",
                points: trend.map { point in
                    CodexRadarChartPoint(
                        rawLabel: point.date,
                        xLabel: CodexRadarChartPoint.shortDateLabel(point.date),
                        value: point.value(for: window, tier: .twentyX)
                    )
                }
            )
        ]
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
    let fiveH: Double
    let sevenD: Double

    var fiveHourDisplayText: String {
        "$\(CodexRadarModelIQPoint.display(fiveH, fractionDigits: 2))"
    }

    var sevenDayDisplayText: String {
        "$\(CodexRadarModelIQPoint.display(sevenD, fractionDigits: 2))"
    }
}

struct CodexRadarQuotaTrendPoint: Decodable, Equatable, Sendable, Identifiable {
    var id: String { date }

    let date: String
    let source: String
    let updatedAt: String
    let fiveHour20x: Double
    let sevenDay20x: Double
    let fiveHour5x: Double
    let fiveHourPlus: Double
    let basisWindow: String
    let basisWindowLabel: String
    let rate: Double
    let rawDelta: Int
    let adjustedDelta: Int
    let offset: Int
    let costUsd: Double
    let totalTokens: Int

    fileprivate func value(for window: CodexRadarQuotaWindow, tier: CodexRadarQuotaTier) -> Double {
        switch (window, tier) {
        case (.fiveHour, .plus):
            return fiveHourPlus
        case (.fiveHour, .fiveX):
            return fiveHour5x
        case (.fiveHour, .twentyX):
            return fiveHour20x
        case (.sevenDay, .plus):
            return sevenDay20x / 20
        case (.sevenDay, .fiveX):
            return sevenDay20x / 4
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
