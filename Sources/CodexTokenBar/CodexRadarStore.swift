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
        return try CodexRadarFeedParser.parse(data)
    }
}

enum CodexRadarReaderError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Codex Radar 返回了无效响应"
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

    private let reader: any CodexRadarReading
    private let feedReader: any CodexRadarFeedReading
    private let refreshInterval: TimeInterval
    private var timer: Timer?

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
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        status = snapshot == nil ? "正在读取 Codex 雷达..." : "正在更新 Codex 雷达..."

        let reader = reader
        let feedReader = feedReader
        Task.detached(priority: .utility) {
            do {
                let snapshot = try await reader.readRadar()
                let feedURL = URL(string: snapshot.links.rss)
                let feedItems = await Self.readFeedIfAvailable(feedURL, feedReader: feedReader)
                await MainActor.run {
                    self.snapshot = snapshot
                    self.feedItems = feedItems
                    self.status = "Codex 雷达 · 更新于 \(DateFormatter.statusString(from: Date()))"
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    self.status = "Codex 雷达读取失败：\(error.localizedDescription)"
                    self.isRefreshing = false
                }
            }
        }
    }

    private nonisolated static func readFeedIfAvailable(
        _ url: URL?,
        feedReader: any CodexRadarFeedReading
    ) async -> [CodexRadarFeedItem] {
        guard let url else { return [] }
        return (try? await feedReader.readFeed(from: url)) ?? []
    }
}
