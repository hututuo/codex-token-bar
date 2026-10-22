import Foundation

struct CodexRadarBenchSelection: Codable, Equatable, Hashable, Sendable {
    let model: String
    let effort: String
    var id: String { "\(model)|\(effort)" }
}

enum CodexRadarBenchError: LocalizedError, Sendable {
    case invalidContract(String)
    case deadline
    case allSummariesFailed

    var errorDescription: String? {
        switch self {
        case .invalidContract(let detail): return "RadarBench 数据不兼容：\(detail)"
        case .deadline: return "RadarBench 读取超时"
        case .allSummariesFailed: return "RadarBench 所有档位读取失败"
        }
    }
}

struct CodexRadarBenchBinding: Decodable, Equatable, Sendable {
    let enabled: Bool
    let interfaceConfirmed: Bool
    let productionReadVerified: Bool
    let activeDisplaySelection: CodexRadarBenchSelection
    let benchmark: String
    let catalogVersion: String
    let taskSetSHA256: String
    let totalTasks: Int
    let sourceCounts: [String: Int]
    let modelEfforts: [CodexRadarBenchSelection]
    let scoreVersion: String
    let scoreMax: Double

    enum CodingKeys: String, CodingKey {
        case enabled, benchmark
        case interfaceConfirmed = "interface_confirmed"
        case productionReadVerified = "production_read_verified"
        case activeDisplaySelection = "active_display_selection"
        case catalogVersion = "catalog_version"
        case taskSetSHA256 = "task_set_sha256"
        case totalTasks = "total_tasks"
        case sourceCounts = "source_counts"
        case modelEfforts = "model_efforts"
        case scoreVersion = "score_version"
        case scoreMax = "score_max"
    }

    var identity: String { "\(benchmark)|\(catalogVersion)|\(taskSetSHA256)|\(scoreVersion)" }

    func validate() throws {
        guard enabled, interfaceConfirmed, productionReadVerified,
              !benchmark.isEmpty, !catalogVersion.isEmpty,
              taskSetSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              scoreVersion == "radar-bench-v2-150", scoreMax == 150,
              (1...4096).contains(totalTasks),
              !sourceCounts.isEmpty, sourceCounts.values.allSatisfy({ (0...totalTasks).contains($0) }),
              sourceCounts.values.reduce(0, +) == totalTasks,
              !modelEfforts.isEmpty, modelEfforts.count <= 128,
              Set(modelEfforts).count == modelEfforts.count,
              modelEfforts.contains(activeDisplaySelection),
              modelEfforts.allSatisfy({ Self.safeIdentifier($0.model) && Self.safeIdentifier($0.effort) }) else {
            throw CodexRadarBenchError.invalidContract("模型目录或评分版本")
        }
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}

struct CodexRadarBenchMetric: Decodable, Equatable, Sendable {
    let knownTotal: Double?
    let knownSamples: Int?
    let missingSamples: Int?
    let missingReason: String?

    enum CodingKeys: String, CodingKey {
        case knownTotal = "known_total", knownSamples = "known_samples"
        case missingSamples = "missing_samples", missingReason = "missing_reason"
    }

    var knownMean: Double? {
        guard let knownTotal, knownTotal.isFinite, knownTotal >= 0,
              let knownSamples, knownSamples > 0,
              missingSamples.map({ $0 >= 0 }) ?? true else { return nil }
        return knownTotal / Double(knownSamples)
    }

    func matches(sampleCount: Int) -> Bool {
        guard let known = knownSamples, let missing = missingSamples,
              sampleCount >= 0, known >= 0, missing >= 0, known <= sampleCount,
              missing == sampleCount - known else { return false }
        if known == 0 { return knownTotal.map { $0 == 0 } ?? true }
        return knownTotal.map { $0.isFinite && $0 >= 0 } ?? false
    }
}

struct CodexRadarBenchStatistics: Decodable, Equatable, Sendable {
    let sampleCount: Int?
    let costBasis: String?
    let metrics: [String: CodexRadarBenchMetric]

    enum CodingKeys: String, CodingKey {
        case sampleCount = "sample_count", costBasis = "cost_basis", metrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampleCount = try? c.decodeIfPresent(Int.self, forKey: .sampleCount)
        costBasis = try? c.decodeIfPresent(String.self, forKey: .costBasis)
        var valid: [String: CodexRadarBenchMetric] = [:]
        if let count = sampleCount, count >= 0,
           let container = try? c.nestedContainer(keyedBy: CodexRadarFlexibleCodingKey.self, forKey: .metrics) {
            for key in container.allKeys {
                if let metric = try? container.decode(CodexRadarBenchMetric.self, forKey: key), metric.matches(sampleCount: count) {
                    valid[key.stringValue] = metric
                }
            }
        }
        metrics = valid
    }

    var isValid: Bool {
        guard let sampleCount, sampleCount >= 0 else { return false }
        return metrics.values.allSatisfy { $0.matches(sampleCount: sampleCount) }
    }
    var averageMinutes: Double? { isValid ? metrics["elapsed_ms"]?.knownMean.map { $0 / 60_000 } : nil }
    var averageAPIEquivalentUSD: Double? {
        guard isValid, costBasis == "official_standard_api_equivalent"
                || costBasis?.hasPrefix("official_standard_api_equivalent;") == true else { return nil }
        return metrics["api_equivalent_usd"]?.knownMean
    }
}

struct CodexRadarBenchHistoryPoint: Decodable, Equatable, Sendable {
    let at: String
    let score: Double?
    let coverage: Int
    let requiredTasks: Int
    let scoreStatus: String

    enum CodingKeys: String, CodingKey {
        case at, score, coverage
        case requiredTasks = "required_tasks", scoreStatus = "score_status"
    }
}

struct CodexRadarBenchHistory: Decodable, Equatable, Sendable {
    let schema: String
    let scoreVersion: String
    let scoreMax: Double
    let model: String
    let effort: String
    let timeZone: String
    let bucket: String
    let updatedBucket: String?
    let points: [CodexRadarBenchHistoryPoint]

    enum CodingKeys: String, CodingKey {
        case schema, model, effort, bucket, points
        case scoreVersion = "score_version", scoreMax = "score_max", timeZone = "time_zone"
        case updatedBucket = "updated_bucket"
    }

    func matches(binding: CodexRadarBenchBinding, selection: CodexRadarBenchSelection) -> Bool {
        guard schema == "radar-bench-public-history-v1-150-daily", scoreVersion == binding.scoreVersion,
              scoreMax == binding.scoreMax, model == selection.model, effort == selection.effort,
              timeZone == "UTC", bucket == "day", points.count <= 3660,
              Set(points.map { String($0.at.prefix(10)) }).count == points.count else { return false }
        let validPoints = points.allSatisfy { point in
            point.at.range(of: #"^\d{4}-\d{2}-\d{2}T00:00:00(?:\.000)?Z$"#, options: .regularExpression) != nil
                && CodexRadarWindowCountdownParser.isValidDeadline(point.at)
                && point.requiredTasks == binding.totalTasks
                && CodexRadarBenchSummary.validScore(score: point.score, coverage: point.coverage,
                    required: point.requiredTasks, status: point.scoreStatus)
        }
        guard validPoints else { return false }
        if points.isEmpty { return updatedBucket == nil }
        guard let updatedBucket,
              updatedBucket.range(of: #"^\d{4}-\d{2}-\d{2}T00:00:00(?:\.000)?Z$"#, options: .regularExpression) != nil,
              CodexRadarWindowCountdownParser.isValidDeadline(updatedBucket) else { return false }
        return String(updatedBucket.prefix(10)) == points.map { String($0.at.prefix(10)) }.max()
    }
}

struct CodexRadarBenchSummary: Decodable, Sendable {
    let schema: String
    let benchmark: String
    let scoreVersion: String
    let scoreMax: Double
    let catalogVersion: String
    let taskSetSHA256: String
    let model: String
    let effort: String
    let score: Double?
    let coverage: Int
    let requiredTasks: Int
    let scoreStatus: String
    let gradedRunsCount: Int
    let sourceCounts: [String: Int]
    let scoringPolicyVersion: String
    let statistics: CodexRadarBenchStatistics?
    let history: CodexRadarBenchHistory?

    enum CodingKeys: String, CodingKey {
        case schema, benchmark, model, effort, score, coverage, statistics, history
        case scoreVersion = "score_version", scoreMax = "score_max", catalogVersion = "catalog_version"
        case taskSetSHA256 = "task_set_sha256", requiredTasks = "required_tasks", scoreStatus = "score_status"
        case gradedRunsCount = "graded_runs_count", sourceCounts = "source_counts"
        case scoringPolicyVersion = "scoring_policy_version"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.score) else { throw CodexRadarBenchError.invalidContract("缺少成绩字段") }
        schema = try c.decode(String.self, forKey: .schema)
        benchmark = try c.decode(String.self, forKey: .benchmark)
        scoreVersion = try c.decode(String.self, forKey: .scoreVersion)
        scoreMax = try c.decode(Double.self, forKey: .scoreMax)
        catalogVersion = try c.decode(String.self, forKey: .catalogVersion)
        taskSetSHA256 = try c.decode(String.self, forKey: .taskSetSHA256)
        model = try c.decode(String.self, forKey: .model)
        effort = try c.decode(String.self, forKey: .effort)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        coverage = try c.decode(Int.self, forKey: .coverage)
        requiredTasks = try c.decode(Int.self, forKey: .requiredTasks)
        scoreStatus = try c.decode(String.self, forKey: .scoreStatus)
        gradedRunsCount = try c.decode(Int.self, forKey: .gradedRunsCount)
        sourceCounts = try c.decode([String: Int].self, forKey: .sourceCounts)
        scoringPolicyVersion = try c.decode(String.self, forKey: .scoringPolicyVersion)
        // Optional statistics must not hide a healthy score when upstream evidence is missing.
        statistics = try? c.decodeIfPresent(CodexRadarBenchStatistics.self, forKey: .statistics)
        history = try? c.decodeIfPresent(CodexRadarBenchHistory.self, forKey: .history)
    }

    // v6 adds source_scores/detail_metrics; the validated score contract is unchanged.
    static let supportedSchemas: Set<String> = [
        "radar-bench-public-summary-v5-150-daily-graded-count",
        "radar-bench-public-summary-v6-150-details"
    ]

    func result(binding: CodexRadarBenchBinding, selection: CodexRadarBenchSelection) throws -> CodexRadarBenchResult {
        try binding.validate()
        guard Self.supportedSchemas.contains(schema),
              binding.modelEfforts.contains(selection),
              scoreVersion == binding.scoreVersion, scoreMax == binding.scoreMax,
              benchmark == binding.benchmark, catalogVersion == binding.catalogVersion,
              taskSetSHA256 == binding.taskSetSHA256, sourceCounts == binding.sourceCounts,
              requiredTasks == binding.totalTasks, model == selection.model, effort == selection.effort,
              scoringPolicyVersion == "radar-bench-v2-last3-per-task-equal-weight-150",
              gradedRunsCount >= coverage,
              Self.validScore(score: score, coverage: coverage, required: requiredTasks, status: scoreStatus) else {
            throw CodexRadarBenchError.invalidContract("档位、题池、成绩或评分口径")
        }
        return CodexRadarBenchResult(score: score, coverage: coverage, requiredTasks: requiredTasks,
            scoreStatus: scoreStatus, gradedRunsCount: gradedRunsCount, statistics: statistics.flatMap { $0.isValid ? $0 : nil },
            history: history.flatMap { $0.matches(binding: binding, selection: selection) ? $0 : nil }, failure: nil)
    }

    static func validScore(score: Double?, coverage: Int, required: Int, status: String) -> Bool {
        guard required > 0, (0...required).contains(coverage) else { return false }
        if coverage == 0 { return score == nil && status == "missing_current_result" }
        guard let score, score.isFinite, (0...150).contains(score) else { return false }
        return status == (coverage == required ? "complete" : "provisional")
    }
}

struct CodexRadarBenchResult: Equatable, Sendable {
    let score: Double?
    let coverage: Int?
    let requiredTasks: Int
    let scoreStatus: String?
    let gradedRunsCount: Int?
    let statistics: CodexRadarBenchStatistics?
    let history: CodexRadarBenchHistory?
    let failure: String?

    var coverageText: String { coverage.map { "\($0)/\(requiredTasks) 题" } ?? "覆盖未知" }
    var statusText: String {
        if failure != nil { return score == nil ? "读取失败" : "陈旧" }
        switch scoreStatus {
        case "missing_current_result": return "待测"
        case "provisional": return "阶段分"
        case "complete": return "完整覆盖"
        default: return "未知"
        }
    }

    func withFailure(_ message: String) -> Self {
        Self(score: score, coverage: coverage, requiredTasks: requiredTasks, scoreStatus: scoreStatus,
             gradedRunsCount: gradedRunsCount, statistics: statistics, history: history, failure: message)
    }
}

private actor CodexRadarBenchCache {
    private var identity = ""
    private var results: [CodexRadarBenchSelection: CodexRadarBenchResult] = [:]
    func previous(for binding: CodexRadarBenchBinding) -> [CodexRadarBenchSelection: CodexRadarBenchResult] {
        identity == binding.identity ? results : [:]
    }
    func save(_ values: [CodexRadarBenchSelection: CodexRadarBenchResult], identity expected: String) {
        if identity != expected { identity = expected; results = [:] }
        for (key, value) in values where value.failure == nil { results[key] = value }
    }
}

struct LiveCodexRadarBenchReader: CodexCrowdRadarReading, Sendable {
    private static let maximumResponseBytes = 2 * 1024 * 1024
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let roundBudget: TimeInterval
    private let requestBudget: TimeInterval
    private let maximumConcurrent: Int
    private let cache = CodexRadarBenchCache()

    init(transport: @escaping Transport = LiveCodexRadarBenchReader.networkTransport,
         roundBudget: TimeInterval = 20, requestBudget: TimeInterval = 5, maximumConcurrent: Int = 6) {
        self.transport = transport
        self.roundBudget = min(20, max(0.01, roundBudget))
        self.requestBudget = min(5, max(0.01, requestBudget))
        self.maximumConcurrent = min(6, max(1, maximumConcurrent))
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration, delegate: CodexRadarBenchRedirectDelegate(), delegateQueue: nil)
    }()

    static let networkTransport: Transport = { request in
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodexRadarReaderError.invalidResponse }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw CodexRadarReaderError.invalidResponse }
        var data = Data()
        data.reserveCapacity(max(0, min(Int(response.expectedContentLength), maximumResponseBytes)))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw CodexRadarReaderError.invalidResponse }
            if data.count % 1024 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return (data, response)
    }

    static func summaryURL(for selection: CodexRadarBenchSelection) -> URL {
        var url = URLComponents(string: "https://codexradar.com/api/radar-bench-score")!
        url.queryItems = [URLQueryItem(name: "model", value: selection.model), URLQueryItem(name: "effort", value: selection.effort),
            URLQueryItem(name: "view", value: "summary"), URLQueryItem(name: "selection", value: "user-selected-v1")]
        return url.url!
    }

    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot {
        let deadline = Date().addingTimeInterval(roundBudget)
        let bindingData = try await read(URL(string: "https://codexradar.com/data/radar-bench-binding.json")!, deadline: deadline)
        let binding = try JSONDecoder().decode(CodexRadarBenchBinding.self, from: bindingData)
        try binding.validate()
        let previous = await cache.previous(for: binding)
        let fetched = try await readSummaries(binding, deadline: deadline)
        try Task.checkCancellation()
        guard fetched.values.contains(where: { $0.failure == nil }) else { throw CodexRadarBenchError.allSummariesFailed }
        await cache.save(fetched, identity: binding.identity)
        let models = binding.modelEfforts.map { selection in
            var result = fetched[selection] ?? CodexRadarBenchResult(score: nil, coverage: nil, requiredTasks: binding.totalTasks,
                scoreStatus: nil, gradedRunsCount: nil, statistics: nil, history: nil, failure: "读取超时")
            if let failure = result.failure, let saved = previous[selection] { result = saved.withFailure(failure) }
            return CodexCrowdRadarModel(model: selection.model, effort: selection.effort, graded: 0, passed: 0,
                passRate: 0, cells: 0, scorePassed: 0, scoreSamples: 0, radarBench: result)
        }
        var snapshot = CodexCrowdRadarSnapshot(generatedAt: "", taskCount: binding.totalTasks, cellCount: 0,
            contributorCount: 0, pendingGrades: 0, errorGrades: 0, models: models, recentModels: [],
            realtimeAvailable: true, radarBenchBinding: binding)
        snapshot.sourceDiagnostics = models.compactMap { model in model.radarBench?.failure.map { "\(model.label)：\($0)" } }
        return snapshot
    }

    private func readSummaries(_ binding: CodexRadarBenchBinding, deadline: Date) async throws -> [CodexRadarBenchSelection: CodexRadarBenchResult] {
        await withTaskGroup(of: (CodexRadarBenchSelection, CodexRadarBenchResult).self) { group in
            var results: [CodexRadarBenchSelection: CodexRadarBenchResult] = [:]
            var next = 0
            func enqueue(_ selection: CodexRadarBenchSelection) {
                group.addTask {
                    do {
                        let data = try await read(Self.summaryURL(for: selection), deadline: deadline)
                        let summary = try JSONDecoder().decode(CodexRadarBenchSummary.self, from: data)
                        return (selection, try summary.result(binding: binding, selection: selection))
                    } catch {
                        return (selection, CodexRadarBenchResult(score: nil, coverage: nil, requiredTasks: binding.totalTasks,
                            scoreStatus: nil, gradedRunsCount: nil, statistics: nil, history: nil, failure: error.localizedDescription))
                    }
                }
            }
            while next < min(maximumConcurrent, binding.modelEfforts.count) { enqueue(binding.modelEfforts[next]); next += 1 }
            while let (selection, result) = await group.next() {
                results[selection] = result
                if Task.isCancelled || Date() >= deadline { group.cancelAll(); continue }
                if next < binding.modelEfforts.count { enqueue(binding.modelEfforts[next]); next += 1 }
            }
            return results
        }
    }

    private func read(_ url: URL, deadline: Date) async throws -> Data {
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw CodexRadarBenchError.deadline }
        let timeout = min(requestBudget, remaining)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        let preparedRequest = request
        let transport = transport
        let (data, response) = try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await transport(preparedRequest) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CodexRadarBenchError.deadline
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CodexRadarBenchError.deadline }
            return response
        }
        guard (200..<300).contains(response.statusCode) else { throw CodexRadarReaderError.httpStatus(response.statusCode) }
        guard !data.isEmpty else { throw CodexRadarReaderError.emptyPayload }
        guard data.count <= Self.maximumResponseBytes else { throw CodexRadarReaderError.invalidResponse }
        return data
    }
}

private final class CodexRadarBenchRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
