import Foundation

protocol CodexRadarReading: Sendable {
    func readRadar() async throws -> CodexRadarSnapshot
}

protocol CodexRadarDetailReading: Sendable {
    func readRadarDetail() async throws -> CodexRadarSnapshot
}

protocol CodexRadarFeedReading: Sendable {
    func readFeed(from url: URL) async throws -> [CodexRadarFeedItem]
}

struct LiveCodexRadarReader: CodexRadarReading, Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let endpoint: URL
    private let transport: Transport

    init(
        endpoint: URL = URL(string: "https://codexradar.com/current.json")!,
        transport: @escaping Transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexRadarReaderError.invalidResponse
            }
            return (data, httpResponse)
        }
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func readRadar() async throws -> CodexRadarSnapshot {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CodexRadarReaderError.httpStatus(response.statusCode)
        }
        guard !data.isEmpty else {
            throw CodexRadarReaderError.emptyPayload
        }
        return try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)
    }
}

struct LiveCodexRadarDetailReader: CodexRadarDetailReading, Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let endpoint: URL
    private let transport: Transport

    init(
        endpoint: URL = URL(string: "https://codexradar.com/api/v1/current")!,
        transport: @escaping Transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexRadarReaderError.invalidResponse
            }
            return (data, httpResponse)
        }
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func readRadarDetail() async throws -> CodexRadarSnapshot {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if endpoint.path == "/api/v1/current" {
            request.setValue(CodexRadarDetailAuthorization.authorizationHeaderValue(), forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CodexRadarReaderError.httpStatus(response.statusCode)
        }
        guard !data.isEmpty else {
            throw CodexRadarReaderError.emptyPayload
        }
        return try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)
    }
}

private enum CodexRadarDetailAuthorization {
    static func authorizationHeaderValue() -> String {
        "Bearer \(token())"
    }

    private static func token() -> String {
        let cipher: [UInt8] = [
            94, 228, 121, 185, 168, 72, 126, 255, 5, 110, 24, 99, 74, 39, 157, 134,
            100, 135, 125, 94, 135, 210, 1, 144, 13, 46, 200, 43, 156, 101, 161, 236,
            160, 80, 7, 176, 218, 251, 217, 188, 109, 99, 36, 171, 48, 39, 199, 14,
            215, 225, 47, 222, 173, 72, 143, 235, 177
        ]
        let mask: [UInt8] = [
            83, 33, 141, 11, 68, 159, 226, 23, 106, 195, 61, 136, 241, 44, 5, 185,
            112, 222, 73, 17, 166, 92, 47
        ]
        let plain = cipher.enumerated().map { index, byte in
            byte ^ mask[(index * 7 + 13) % mask.count] ^ UInt8((index * 31 + 17) & 0xff)
        }
        return String(decoding: plain, as: UTF8.self)
    }
}

struct LiveCodexRadarFeedReader: CodexRadarFeedReading, Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    init(
        transport: @escaping Transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexRadarReaderError.invalidResponse
            }
            return (data, httpResponse)
        }
    ) {
        self.transport = transport
    }

    func readFeed(from url: URL) async throws -> [CodexRadarFeedItem] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CodexRadarReaderError.httpStatus(response.statusCode)
        }
        guard !data.isEmpty else {
            throw CodexRadarReaderError.emptyPayload
        }
        return try CodexRadarFeedParser.parse(data)
    }
}

enum CodexRadarReaderError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case emptyPayload
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Codex Radar 返回了无效响应"
        case .emptyPayload:
            return "Codex Radar 返回了空数据"
        case .httpStatus(let status):
            return "Codex Radar HTTP \(status)"
        }
    }
}

@MainActor
final class CodexRadarStore: ObservableObject {
    static let detailRefreshDefaultsKey = "CodexRadarStore.lastSuccessfulDetailRefreshAt"
    static let detailAttemptDefaultsKey = "CodexRadarStore.lastAttemptedDetailSlotAt"

    @Published private(set) var snapshot: CodexRadarSnapshot?
    @Published private(set) var detailSnapshot: CodexRadarSnapshot?
    @Published private(set) var feedItems: [CodexRadarFeedItem] = []
    @Published private(set) var crowdSnapshot: CodexCrowdRadarSnapshot?
    @Published private(set) var status = "Codex 雷达待读取"
    @Published private(set) var detailStatus = "Codex 雷达详情待读取"
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDetailRefreshing = false
    @Published private(set) var diagnostics: [CodexRadarDiagnostic] = []
    @Published private(set) var detailDiagnostics: [CodexRadarDiagnostic] = []
    @Published private(set) var lastSuccessfulRefreshAt: Date?
    @Published private(set) var lastSuccessfulDetailRefreshAt: Date?
    @Published private(set) var lastAttemptedDetailSlotAt: Date?
    @Published private(set) var lastFailureAt: Date?
    @Published private(set) var lastDetailFailureAt: Date?
    @Published private(set) var staleDataDisplayed = false
    @Published private(set) var detailStaleDataDisplayed = false
    @Published private(set) var feedStaleDataDisplayed = false

    private let reader: any CodexRadarReading
    private let detailReader: any CodexRadarDetailReading
    private let feedReader: any CodexRadarFeedReading
    private let crowdReader: any CodexCrowdRadarReading
    private let refreshInterval: TimeInterval
    private let detailRefreshDefaults: UserDefaults
    private let detailRefreshCalendar: Calendar
    private var timer: Timer?
    private var detailTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var detailRefreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var detailRefreshGeneration = 0

    init(
        reader: any CodexRadarReading = LiveCodexRadarReader(),
        feedReader: any CodexRadarFeedReading = LiveCodexRadarFeedReader(),
        detailReader: any CodexRadarDetailReading = LiveCodexRadarDetailReader(),
        crowdReader: any CodexCrowdRadarReading = LiveCodexCrowdRadarReader(),
        refreshInterval: TimeInterval = 600,
        detailRefreshDefaults: UserDefaults = .standard,
        detailRefreshCalendar: Calendar = .current
    ) {
        self.reader = reader
        self.feedReader = feedReader
        self.detailReader = detailReader
        self.crowdReader = crowdReader
        self.refreshInterval = refreshInterval
        self.detailRefreshDefaults = detailRefreshDefaults
        self.detailRefreshCalendar = detailRefreshCalendar
        if detailRefreshDefaults.object(forKey: Self.detailRefreshDefaultsKey) != nil {
            self.lastSuccessfulDetailRefreshAt = Date(
                timeIntervalSince1970: detailRefreshDefaults.double(forKey: Self.detailRefreshDefaultsKey)
            )
        }
        if detailRefreshDefaults.object(forKey: Self.detailAttemptDefaultsKey) != nil {
            self.lastAttemptedDetailSlotAt = Date(
                timeIntervalSince1970: detailRefreshDefaults.double(forKey: Self.detailAttemptDefaultsKey)
            )
        }
    }

    var detailDisplaySnapshot: CodexRadarSnapshot? {
        detailSnapshot ?? snapshot
    }

    var detailDisplayStatus: String {
        if detailSnapshot != nil || isDetailRefreshing || !detailDiagnostics.isEmpty {
            return detailStatus
        }
        return status
    }

    var detailDisplayDiagnostics: [CodexRadarDiagnostic] {
        detailDiagnostics.isEmpty ? diagnostics : detailDiagnostics
    }

    var detailDisplayStaleDataDisplayed: Bool {
        detailStaleDataDisplayed || (detailSnapshot == nil && staleDataDisplayed)
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        refreshScheduledDetailIfNeeded()
        scheduleNextDetailRefreshTimer()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshScheduledDetailIfNeeded()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detailTimer?.invalidate()
        detailTimer = nil
        refreshGeneration += 1
        detailRefreshGeneration += 1
        refreshTask?.cancel()
        detailRefreshTask?.cancel()
        refreshTask = nil
        detailRefreshTask = nil
        isRefreshing = false
        isDetailRefreshing = false
    }

    func refresh() {
        let trace = RefreshPerformanceProbe.begin("radarStore.refresh", metadata: [
            "alreadyRefreshing": isRefreshing ? "1" : "0",
            "hasSnapshot": snapshot == nil ? "0" : "1"
        ])
        guard !isRefreshing else {
            trace?.end("skipped-refresh-in-flight")
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        status = snapshot == nil ? "正在读取 Codex 雷达..." : "正在更新 Codex 雷达..."

        let reader = reader
        let feedReader = feedReader
        let crowdReader = crowdReader
        refreshTask = Task.detached(priority: .utility) {
            do {
                trace?.mark("currentJSON.begin")
                let snapshot = try await reader.readRadar()
                trace?.mark("currentJSON.end", metadata: [
                    "monitoredAt": snapshot.monitoredAt,
                    "action": snapshot.recommendedAction
                ])
                let feedURL = URL(string: snapshot.links.rss)
                trace?.mark("rss.begin", metadata: ["hasURL": feedURL == nil ? "0" : "1"])
                let feedResult = await Self.readFeedIfAvailable(feedURL, feedReader: feedReader)
                let crowdSnapshot = try? await crowdReader.readCrowdRadar()
                trace?.mark("rss.end", metadata: [
                    "items": String(feedResult.items?.count ?? 0),
                    "failed": feedResult.diagnostic == nil ? "0" : "1"
                ])
                let didPublish = await MainActor.run {
                    guard self.refreshGeneration == generation else {
                        return false
                    }
                    let now = Date()
                    self.snapshot = snapshot
                    if let crowdSnapshot { self.crowdSnapshot = crowdSnapshot }
                    self.lastSuccessfulRefreshAt = now
                    self.staleDataDisplayed = false
                    self.feedStaleDataDisplayed = false
                    self.diagnostics = []

                    if let feedItems = feedResult.items {
                        self.feedItems = feedItems
                    } else if let underlying = feedResult.diagnostic {
                        self.diagnostics = [.rssFailure(underlying: underlying, occurredAt: now)]
                        self.feedStaleDataDisplayed = !self.feedItems.isEmpty
                        self.lastFailureAt = now
                        if self.feedItems.isEmpty {
                            self.feedItems = []
                        }
                    } else {
                        self.feedItems = []
                    }

                    self.status = "Codex 雷达 · 更新于 \(DateFormatter.statusString(from: now))"
                    self.isRefreshing = false
                    self.refreshTask = nil
                    return true
                }
                trace?.end(didPublish ? "ok" : "discarded-stale-generation")
            } catch {
                let didPublish = await MainActor.run {
                    guard self.refreshGeneration == generation else {
                        return false
                    }
                    let now = Date()
                    let diagnostic = CodexRadarDiagnostic.classify(source: .current, error: error, occurredAt: now)
                    self.lastFailureAt = now
                    self.staleDataDisplayed = self.snapshot != nil
                    self.feedStaleDataDisplayed = false
                    self.diagnostics = self.staleDataDisplayed
                        ? [
                            diagnostic,
                            .staleCachedData(source: .current, rawCause: diagnostic.rawCause, occurredAt: now)
                        ]
                        : [diagnostic]
                    self.status = "Codex 雷达读取失败：\(error.localizedDescription)"
                    self.isRefreshing = false
                    self.refreshTask = nil
                    return true
                }
                trace?.end(
                    didPublish ? "failed" : "discarded-stale-generation",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    func refreshScheduledDetailIfNeeded(now: Date = Date()) {
        let latestSlot = CodexRadarDetailRefreshSchedule.latestScheduledSlot(
            before: now,
            calendar: detailRefreshCalendar
        )
        guard !isDetailRefreshing else {
            return
        }
        guard CodexRadarDetailRefreshSchedule.shouldAttempt(
            now: now,
            lastSuccessfulRefreshAt: lastSuccessfulDetailRefreshAt,
            lastAttemptedSlotAt: lastAttemptedDetailSlotAt,
            calendar: detailRefreshCalendar
        ) else {
            return
        }
        lastAttemptedDetailSlotAt = latestSlot
        detailRefreshDefaults.set(latestSlot.timeIntervalSince1970, forKey: Self.detailAttemptDefaultsKey)
        refreshDetail(recordedAt: now)
    }

    func refreshDetail() {
        refreshDetail(recordedAt: Date())
    }

    private func refreshDetail(recordedAt: Date) {
        guard !isDetailRefreshing else { return }
        detailRefreshGeneration += 1
        let generation = detailRefreshGeneration
        isDetailRefreshing = true
        detailStatus = detailSnapshot == nil ? "正在读取 Codex 雷达详情..." : "正在更新 Codex 雷达详情..."

        let detailReader = detailReader
        detailRefreshTask = Task.detached(priority: .utility) {
            do {
                let snapshot = try await detailReader.readRadarDetail()
                await MainActor.run {
                    guard self.detailRefreshGeneration == generation else {
                        return
                    }
                    self.detailSnapshot = snapshot
                    self.lastSuccessfulDetailRefreshAt = recordedAt
                    self.detailRefreshDefaults.set(recordedAt.timeIntervalSince1970, forKey: Self.detailRefreshDefaultsKey)
                    self.detailDiagnostics = []
                    self.detailStaleDataDisplayed = false
                    self.detailStatus = "Codex 雷达详情 · 更新于 \(DateFormatter.statusString(from: recordedAt))"
                    self.isDetailRefreshing = false
                    self.detailRefreshTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self.detailRefreshGeneration == generation else {
                        return
                    }
                    let diagnostic = CodexRadarDiagnostic.classify(source: .current, error: error, occurredAt: recordedAt)
                    self.lastDetailFailureAt = recordedAt
                    self.detailStaleDataDisplayed = self.detailSnapshot != nil
                    self.detailDiagnostics = self.detailStaleDataDisplayed
                        ? [
                            diagnostic,
                            .staleCachedData(source: .current, rawCause: diagnostic.rawCause, occurredAt: recordedAt)
                        ]
                        : [diagnostic]
                    self.detailStatus = "Codex 雷达详情读取失败：\(error.localizedDescription)"
                    self.isDetailRefreshing = false
                    self.detailRefreshTask = nil
                }
            }
        }
    }

    private func scheduleNextDetailRefreshTimer(from date: Date = Date()) {
        detailTimer?.invalidate()
        let delay = CodexRadarDetailRefreshSchedule.delayUntilNextSlot(
            from: date,
            calendar: detailRefreshCalendar
        )
        detailTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshScheduledDetailIfNeeded()
                self.scheduleNextDetailRefreshTimer()
            }
        }
    }

    private nonisolated static func readFeedIfAvailable(
        _ url: URL?,
        feedReader: any CodexRadarFeedReading
    ) async -> CodexRadarFeedRefreshResult {
        guard let url else { return CodexRadarFeedRefreshResult(items: [], diagnostic: nil) }
        do {
            let items = try await feedReader.readFeed(from: url)
            return CodexRadarFeedRefreshResult(items: items, diagnostic: nil)
        } catch {
            return CodexRadarFeedRefreshResult(
                items: nil,
                diagnostic: CodexRadarDiagnostic.classify(source: .rss, error: error)
            )
        }
    }
}

private struct CodexRadarFeedRefreshResult: Sendable {
    let items: [CodexRadarFeedItem]?
    let diagnostic: CodexRadarDiagnostic?
}
