import Foundation

protocol CodexRadarReading: Sendable {
    func readRadar() async throws -> CodexRadarSnapshot
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
    @Published private(set) var snapshot: CodexRadarSnapshot?
    @Published private(set) var feedItems: [CodexRadarFeedItem] = []
    @Published private(set) var status = "Codex 雷达待读取"
    @Published private(set) var isRefreshing = false
    @Published private(set) var diagnostics: [CodexRadarDiagnostic] = []
    @Published private(set) var lastSuccessfulRefreshAt: Date?
    @Published private(set) var lastFailureAt: Date?
    @Published private(set) var staleDataDisplayed = false
    @Published private(set) var feedStaleDataDisplayed = false

    private let reader: any CodexRadarReading
    private let feedReader: any CodexRadarFeedReading
    private let refreshInterval: TimeInterval
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(
        reader: any CodexRadarReading = LiveCodexRadarReader(),
        feedReader: any CodexRadarFeedReading = LiveCodexRadarFeedReader(),
        refreshInterval: TimeInterval = 600
    ) {
        self.reader = reader
        self.feedReader = feedReader
        self.refreshInterval = refreshInterval
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
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
