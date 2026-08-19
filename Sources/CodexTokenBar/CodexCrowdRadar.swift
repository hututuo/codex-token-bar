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
        let rawLabel = "\(family) \(effort)".trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexRadarPresentationText.compactModelName(rawLabel)
    }
    var iq: Double { passRate * 150 }
}

struct CodexCrowdRadarSnapshot: Equatable, Sendable {
    static let minimumRankedSampleCount = 45

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
            return realtimeModels
        case .recent:
            return recentModels.isEmpty ? realtimeModels : recentModels
        }
    }

    func rankedModels(for mode: CodexCrowdRadarMode) -> [CodexCrowdRadarModel] {
        models(for: mode)
            .filter { $0.scoreSamples >= Self.minimumRankedSampleCount }
            .sorted(by: Self.ranksBefore)
    }

    var rankedModels: [CodexCrowdRadarModel] {
        rankedModels(for: .realtime)
    }

    func rankedModels(page: Int, pageSize: Int = 3) -> [CodexCrowdRadarModel] {
        let safePage = max(0, page)
        let safePageSize = max(1, pageSize)
        return Array(rankedModels.dropFirst(safePage * safePageSize).prefix(safePageSize))
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
    private static let sourceAttemptLimit = 3
    private static let retryDelays: [TimeInterval] = [0.25, 0.75]

    private static let tableSources: [(url: URL, budget: TimeInterval)] = [
        (URL(string: "https://codexradar.com/api/intelligence-efficiency")!, 12),
        (URL(string: "https://api.codexradar.com/api/v1/table")!, 6)
    ]
    private static let leaderboardSources: [(url: URL, budget: TimeInterval)] = [
        (URL(string: "https://codexradar.com/data/intelligence-efficiency.json")!, 12),
        (URL(string: "https://api.codexradar.com/api/v1/leaderboard")!, 6)
    ]

    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot {
        async let tableData: Data? = try? readFirstAvailable(
            Self.tableSources,
            signalKeys: ["combos", "tasks", "cells", "baselineGeneratedAt"]
        )
        async let leaderboardData: Data? = try? readFirstAvailable(
            Self.leaderboardSources,
            signalKeys: ["points", "models", "rankings", "modelStats"]
        )
        let payloads = await (tableData, leaderboardData)
        try Task.checkCancellation()
        guard payloads.0 != nil || payloads.1 != nil else {
            throw CodexRadarReaderError.invalidResponse
        }
        return try CodexCrowdRadarParser.decode(
            tableData: payloads.0,
            leaderboardData: payloads.1
        )
    }

    private func readFirstAvailable(
        _ sources: [(url: URL, budget: TimeInterval)],
        signalKeys: [String]
    ) async throws -> Data {
        var lastError: Error = CodexRadarReaderError.invalidResponse
        for source in sources {
            try Task.checkCancellation()
            do {
                let data = try await readWithRetries(source.url, budget: source.budget)
                guard Self.payloadContainsSignal(data, signalKeys: signalKeys) else {
                    try Task.checkCancellation()
                    lastError = CodexRadarReaderError.invalidResponse
                    continue
                }
                return data
            } catch {
                if Self.isCancellation(error) { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled
            || error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    private static func payloadContainsSignal(_ data: Data, signalKeys: [String]) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        let signals = Set(signalKeys.map { canonicalKey($0) })
        func containsSignal(_ value: Any, depth: Int) -> Bool {
            guard let object = value as? [String: Any] else { return false }
            if object.keys.contains(where: { signals.contains(canonicalKey($0)) }) {
                return true
            }
            guard depth < 4 else { return false }
            return ["data", "result", "snapshot", "payload", "response", "body"]
                .compactMap { object[$0] }
                .contains { containsSignal($0, depth: depth + 1) }
        }
        return containsSignal(root, depth: 0)
    }

    private static func canonicalKey(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func readWithRetries(_ url: URL, budget: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(budget)
        var lastError: Error = CodexRadarReaderError.invalidResponse
        for attempt in 0..<Self.sourceAttemptLimit {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                return try await read(url, timeoutInterval: min(6, remaining))
            } catch {
                if Self.isCancellation(error) { throw error }
                lastError = error
                guard attempt + 1 < Self.sourceAttemptLimit else { break }
                let delay = Self.retryDelays[attempt]
                let sleepNanos = UInt64(max(0, min(delay, deadline.timeIntervalSinceNow)) * 1_000_000_000)
                if sleepNanos > 0 {
                    try await Task.sleep(nanoseconds: sleepNanos)
                }
            }
        }
        throw lastError
    }

    private func read(_ url: URL, timeoutInterval: TimeInterval = 18) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = min(18, timeoutInterval)
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
