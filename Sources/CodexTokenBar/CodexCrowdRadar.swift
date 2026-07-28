import Foundation

enum CodexCrowdRadarMode: String, CaseIterable, Identifiable, Sendable {
    case realtime
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realtime:
            return "实时监控"
        case .recent:
            return "近期表现"
        }
    }

    var explanation: String {
        switch self {
        case .realtime:
            return "每格取最新 1 次有效结果"
        case .recent:
            return "每格汇总最近 3 次有效结果"
        }
    }
}

struct CodexCrowdRadarModel: Equatable, Sendable, Identifiable {
    let model: String
    let effort: String
    let graded: Int
    let passed: Int
    let passRate: Double
    let cells: Int
    let scorePassed: Int
    let scoreSamples: Int
    let latestGradedAt: String?

    init(
        model: String,
        effort: String,
        graded: Int,
        passed: Int,
        passRate: Double,
        cells: Int,
        scorePassed: Int? = nil,
        scoreSamples: Int? = nil,
        latestGradedAt: String? = nil
    ) {
        self.model = model
        self.effort = effort
        self.graded = graded
        self.passed = passed
        self.passRate = passRate
        self.cells = cells
        self.scorePassed = scorePassed ?? passed
        self.scoreSamples = scoreSamples ?? graded
        self.latestGradedAt = latestGradedAt
    }

    var id: String { "\(model)|\(effort)" }
    var label: String {
        let family = ["Sol", "Terra", "Luna"].first { model.localizedCaseInsensitiveContains($0) } ?? model
        return "\(family) \(effort)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var iq: Double { passRate * 150 }
}

struct CodexCrowdRadarSnapshot: Equatable, Sendable {
    let generatedAt: String
    let taskCount: Int
    let cellCount: Int
    let contributorCount: Int
    let pendingGrades: Int
    let errorGrades: Int
    let realtimeModels: [CodexCrowdRadarModel]
    let recentModels: [CodexCrowdRadarModel]
    let realtimeAvailable: Bool

    init(
        generatedAt: String,
        taskCount: Int,
        cellCount: Int,
        contributorCount: Int,
        pendingGrades: Int,
        errorGrades: Int,
        models: [CodexCrowdRadarModel],
        recentModels: [CodexCrowdRadarModel]? = nil,
        realtimeAvailable: Bool = true
    ) {
        self.generatedAt = generatedAt
        self.taskCount = taskCount
        self.cellCount = cellCount
        self.contributorCount = contributorCount
        self.pendingGrades = pendingGrades
        self.errorGrades = errorGrades
        self.realtimeModels = models
        self.recentModels = recentModels ?? models
        self.realtimeAvailable = realtimeAvailable
    }

    var models: [CodexCrowdRadarModel] { realtimeModels }

    func models(for mode: CodexCrowdRadarMode) -> [CodexCrowdRadarModel] {
        switch mode {
        case .realtime:
            return realtimeModels.isEmpty ? recentModels : realtimeModels
        case .recent:
            return recentModels.isEmpty ? realtimeModels : recentModels
        }
    }

    func rankedModels(for mode: CodexCrowdRadarMode) -> [CodexCrowdRadarModel] {
        models(for: mode)
            .filter { $0.scoreSamples > 0 }
            .sorted(by: Self.ranksBefore)
    }

    var rankedModels: [CodexCrowdRadarModel] {
        rankedModels(for: .realtime)
    }

    var bestModel: CodexCrowdRadarModel? { rankedModels.first }

    func bestModel(for mode: CodexCrowdRadarMode) -> CodexCrowdRadarModel? {
        rankedModels(for: mode).first
    }

    private static func ranksBefore(
        _ left: CodexCrowdRadarModel,
        _ right: CodexCrowdRadarModel
    ) -> Bool {
        if left.passRate != right.passRate {
            return left.passRate > right.passRate
        }
        let leftModelRank = modelRank(left.model)
        let rightModelRank = modelRank(right.model)
        if leftModelRank != rightModelRank {
            return leftModelRank < rightModelRank
        }
        let leftEffortRank = effortRank(left.effort)
        let rightEffortRank = effortRank(right.effort)
        if leftEffortRank != rightEffortRank {
            return leftEffortRank < rightEffortRank
        }
        return left.id.localizedStandardCompare(right.id) == .orderedAscending
    }

    private static func modelRank(_ model: String) -> Int {
        let normalized = model.lowercased()
        if normalized.contains("gpt-5.6-sol") { return 0 }
        if normalized.contains("gpt-5.6-terra") { return 1 }
        if normalized.contains("gpt-5.6-luna") { return 2 }
        if normalized.contains("gpt-5.5") { return 3 }
        return 4
    }

    private static func effortRank(_ effort: String) -> Int {
        ["ultra", "max", "xhigh", "high", "medium", "low", "minimal"]
            .firstIndex(of: effort.lowercased()) ?? 7
    }
}

protocol CodexCrowdRadarReading: Sendable {
    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot
}

struct LiveCodexCrowdRadarReader: CodexCrowdRadarReading, Sendable {
    private static let maxResponseBytes = 8 * 1024 * 1024

    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot {
        async let tableData: Data? = try? read(
            URL(string: "https://api.codexradar.com/api/v1/table")!
        )
        async let leaderboardData: Data? = try? read(
            URL(string: "https://api.codexradar.com/api/v1/leaderboard")!
        )
        let payloads = await (tableData, leaderboardData)
        guard payloads.0 != nil || payloads.1 != nil else {
            throw CodexRadarReaderError.invalidResponse
        }
        return try CodexCrowdRadarParser.decode(
            tableData: payloads.0,
            leaderboardData: payloads.1
        )
    }

    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await CodexRadarNetworkSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CodexRadarReaderError.invalidResponse
        }
        guard !data.isEmpty else { throw CodexRadarReaderError.emptyPayload }
        guard data.count <= Self.maxResponseBytes else { throw CodexRadarReaderError.invalidResponse }
        return data
    }
}
