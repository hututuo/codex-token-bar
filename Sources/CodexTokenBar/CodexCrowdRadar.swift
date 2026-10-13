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
    let radarBench: CodexRadarBenchResult?

    init(
        model: String,
        effort: String,
        graded: Int,
        passed: Int,
        passRate: Double,
        cells: Int,
        scorePassed: Int? = nil,
        scoreSamples: Int? = nil,
        latestGradedAt: String? = nil,
        radarBench: CodexRadarBenchResult? = nil
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
        self.radarBench = radarBench
    }

    var id: String { "\(model)|\(effort)" }
    var label: String {
        if radarBench != nil { return "\(model) \(effort)".trimmingCharacters(in: .whitespacesAndNewlines) }
        let family = ["Astra", "Sol", "Terra", "Luna"].first { model.localizedCaseInsensitiveContains($0) } ?? model
        let rawLabel = "\(family) \(effort)".trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexRadarPresentationText.compactModelName(rawLabel)
    }
    var iq: Double { radarBench.map { $0.score ?? .nan } ?? passRate * 150 }
    var scoreDisplayText: String {
        if let radarBench { return radarBench.score.map { String(format: "%.1f", $0) } ?? "待测" }
        return String(format: "%.1f", iq)
    }
    var rankingDetailText: String {
        if let radarBench {
            return "雷达分 \(scoreDisplayText) · \(radarBench.coverageText) · 已判 \(radarBench.gradedRunsCount.map { String($0) } ?? "--")"
        }
        return "旧 IQ \(scoreDisplayText) · \(scorePassed)/\(scoreSamples)"
    }
    var rankingAccessibilityText: String {
        if let radarBench {
            return "\(label)，雷达分 \(scoreDisplayText)，覆盖 \(radarBench.coverageText)，已判分 \(radarBench.gradedRunsCount.map { String($0) } ?? "未知")"
        }
        return "\(label)，旧 IQ \(scoreDisplayText)，本口径通过 \(scorePassed)/\(scoreSamples)"
    }
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
    var sourceDiagnostics: [String] = []
    var staleDataDisplayed = false
    let radarBenchBinding: CodexRadarBenchBinding?
    var benchmarkSource: String { radarBenchBinding == nil ? "legacy-iq" : "radar-bench" }
    var isRadarBench: Bool { radarBenchBinding != nil }
    var emptyRankingText: String {
        if staleDataDisplayed { return isRadarBench ? "上次数据 · 暂无成绩" : "上次排名数据" }
        guard isRadarBench else { return "排名待读取" }
        return sourceDiagnostics.isEmpty ? "暂无成绩 · 待测" : "当前档位读取失败"
    }

    func floatingRankingAccessibilityValue(_ leaders: [CodexCrowdRadarModel], start: Int) -> String {
        let values = leaders.enumerated().map { index, model in
            "第\(start + index + 1)名 \(model.rankingAccessibilityText)"
        }.joined(separator: "；")
        let content = values.isEmpty ? emptyRankingText : values
        return staleDataDisplayed ? "陈旧，上次数据，\(content)" : content
    }

    init(
        generatedAt: String,
        taskCount: Int,
        cellCount: Int,
        contributorCount: Int,
        pendingGrades: Int,
        errorGrades: Int,
        models: [CodexCrowdRadarModel],
        recentModels: [CodexCrowdRadarModel]? = nil,
        realtimeAvailable: Bool = true,
        radarBenchBinding: CodexRadarBenchBinding? = nil
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
        self.radarBenchBinding = radarBenchBinding
    }

    var models: [CodexCrowdRadarModel] { realtimeModels }

    func models(for mode: CodexCrowdRadarMode) -> [CodexCrowdRadarModel] {
        if isRadarBench { return realtimeModels }
        switch mode {
        case .realtime:
            return realtimeModels
        case .recent:
            return recentModels.isEmpty ? realtimeModels : recentModels
        }
    }

    func rankedModels(for mode: CodexCrowdRadarMode) -> [CodexCrowdRadarModel] {
        models(for: mode)
            .filter { isRadarBench ? $0.radarBench?.score != nil && $0.radarBench?.failure == nil : $0.scoreSamples >= Self.minimumRankedSampleCount }
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
        if let leftBench = left.radarBench, let rightBench = right.radarBench {
            let leftScore = leftBench.score ?? 0
            let rightScore = rightBench.score ?? 0
            if leftScore != rightScore { return leftScore > rightScore }
            let leftCoverage = leftBench.coverage ?? 0
            let rightCoverage = rightBench.coverage ?? 0
            if leftCoverage != rightCoverage { return leftCoverage > rightCoverage }
            return left.id.utf8.lexicographicallyPrecedes(right.id.utf8)
        }
        let leftScore = left.radarBench?.score ?? left.passRate * 150
        let rightScore = right.radarBench?.score ?? right.passRate * 150
        if leftScore != rightScore {
            return leftScore > rightScore
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
        if normalized.contains("gpt-6-astra") { return 0 }
        if normalized.contains("gpt-6.1-sol") { return 1 }
        if normalized.contains("gpt-6-sol") { return 2 }
        if normalized.contains("gpt-6-luna") { return 3 }
        if normalized.contains("gpt-5.6-sol") { return 4 }
        if normalized.contains("gpt-5.6-terra") { return 5 }
        if normalized.contains("gpt-5.6-luna") { return 6 }
        if normalized.contains("gpt-5.5") { return 7 }
        return 8
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
    private let benchReader: LiveCodexRadarBenchReader

    init(benchReader: LiveCodexRadarBenchReader = LiveCodexRadarBenchReader()) {
        self.benchReader = benchReader
    }
    // The growing live table exceeded 8 MiB in September 2026.
    private static let maxResponseBytes = 32 * 1024 * 1024
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
        try await benchReader.readCrowdRadar()
    }

    // Retained only for explicit historical reads. Never used as a current Bench fallback.
    func readLegacyCrowdRadar() async throws -> CodexCrowdRadarSnapshot {
        async let tableData = readSourceResult(Self.tableSources, signalKeys: ["combos", "tasks", "cells", "baselineGeneratedAt"])
        async let leaderboardData = readSourceResult(Self.leaderboardSources, signalKeys: ["points", "models", "rankings", "modelStats"])
        let payloads = await (tableData, leaderboardData)
        try Task.checkCancellation()
        let failures = [payloads.0.failure, payloads.1.failure].compactMap { $0 }
        guard payloads.0.data != nil || payloads.1.data != nil else {
            throw NSError(domain: "CodexCrowdRadar", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
        }
        var snapshot = try CodexCrowdRadarParser.decode(tableData: payloads.0.data, leaderboardData: payloads.1.data)
        snapshot.sourceDiagnostics = failures
        return snapshot
    }

    private func readSourceResult(_ sources: [(url: URL, budget: TimeInterval)], signalKeys: [String]) async -> (data: Data?, failure: String?) {
        do { return (try await readFirstAvailable(sources, signalKeys: signalKeys), nil) }
        catch { return (nil, "来源：\(sources.map { $0.url.absoluteString }.joined(separator: ", "))\n\(error.localizedDescription)") }
    }

    private func readFirstAvailable(
        _ sources: [(url: URL, budget: TimeInterval)],
        signalKeys: [String]
    ) async throws -> Data {
        var failures: [String] = []
        for source in sources {
            try Task.checkCancellation()
            do {
                let data = try await readWithRetries(source.url, budget: source.budget)
                guard Self.payloadContainsSignal(data, signalKeys: signalKeys) else {
                    try Task.checkCancellation()
                    failures.append("\(source.url.absoluteString)：响应不含所需数据字段")
                    continue
                }
                return data
            } catch {
                if Self.isCancellation(error) { throw error }
                failures.append("\(source.url.absoluteString)：\(error.localizedDescription)")
            }
        }
        throw NSError(domain: "CodexCrowdRadar.Sources", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
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
        return try Self.validateResponseBody(data)
    }

    static func validateResponseBody(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw CodexRadarReaderError.emptyPayload }
        guard data.count <= maxResponseBytes else { throw CodexRadarReaderError.invalidResponse }
        return data
    }
}
