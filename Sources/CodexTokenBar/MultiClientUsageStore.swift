import AppKit
import Combine
import CryptoKit
import Foundation

struct MultiClientUsagePreference: Codable, Equatable, Identifiable, Sendable {
    var id: String { client.rawValue }
    var client: UsageClient
    var enabled = false
    var showQuota = false
    var showSidebar = false
    var showMenuBar = false
    var color: String
    var order: Int
    var style = "compact"
    var path = ""

    static var defaults: [Self] {
        UsageClient.allCases.enumerated().map { index, client in
            Self(client: client, color: ClientBrand.hex(client.rawValue), order: index)
        }
    }
    static func normalized(_ values: [Self]) -> [Self] {
        var result: [Self] = defaults.map { fallback in
            var value = values.first { $0.client == fallback.client } ?? fallback
            if value.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { value.color = fallback.color }
            if !["compact", "detailed"].contains(value.style) { value.style = "compact" }
            value.path = String(value.path.prefix(4096))
            return value
        }
        result.sort { lhs, rhs in
            if lhs.order == rhs.order { return lhs.client.rawValue < rhs.client.rawValue }
            return lhs.order < rhs.order
        }
        for index in result.indices { result[index].order = index }
        return result
    }
}

extension UsageClient {
    var displayName: String {
        switch self {
        case .claudeCode: "Claude CLI"
        case .claudeDesktop: "Claude Desktop"
        case .deepseek: "DeepSeek / DSH"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        }
    }
}

struct MultiClientScanResult: Sendable {
    let summaries: [ClientUsageSummary]
    let diagnostics: [String]
    var todaySummaries: [ClientUsageSummary] = []
    var sevenDaySummaries: [ClientUsageSummary] = []
    var trendBuckets: [ClientTrendBucket] = []
    var dailyBuckets: [ClientTrendBucket] = []
}

actor MultiClientUsageScanner {
    private let databaseURL: URL
    private let home: URL
    private let environment: [String: String]
    private var ledger: MultiClientUsageLedger?
    private var cursor = 0
    private var aggregateCache: (revision: Int64, minute: Int64, timezone: String,
        summaries: [ClientUsageSummary], todaySummaries: [ClientUsageSummary],
        sevenDaySummaries: [ClientUsageSummary], trend: [ClientTrendBucket], daily: [ClientTrendBucket])?
    private var scanNotices: [String] = []
    private var deepSeekContexts: [String: (identity: String, session: String)] = [:]
    init(databaseURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.databaseURL = databaseURL; self.home = home; self.environment = environment
    }
    private func open() throws -> MultiClientUsageLedger {
        if let ledger { return ledger }
        let opened = try MultiClientUsageLedger(url: databaseURL); ledger = opened; return opened
    }
    func scan(_ preferences: [MultiClientUsagePreference]) throws -> MultiClientScanResult {
        let enabled = preferences.filter(\.enabled)
        guard !enabled.isEmpty || FileManager.default.fileExists(atPath: databaseURL.path) else {
            return MultiClientScanResult(summaries: [], diagnostics: [])
        }
        let ledger = try open()
        var diagnostics: [String] = []
        scanNotices = []
        var entries: [(UsageClient, URL)] = []
        for preference in enabled {
            let files: [URL]
            if preference.client == .antigravity {
                let discovery = AntigravityUsageSource.discover(home: home, path: preference.path)
                files = discovery.files
                if discovery.truncated { diagnostics.append("Antigravity：发现达到读取上限，请缩小目录范围；当前不是完整历史") }
            } else if preference.path.isEmpty {
                let discovery = MultiClientUsageDiscovery.discover(client: preference.client, home: home, environment: environment)
                files = discovery.files
                if discovery.truncated { diagnostics.append("\(preference.client.displayName)：自动发现达到安全上限，请分目录读取；当前不是完整历史") }
            } else {
                let discovery = Self.files(at: URL(fileURLWithPath: (preference.path as NSString).expandingTildeInPath))
                files = discovery.files
                if discovery.truncated { diagnostics.append("\(preference.client.displayName)：自选目录达到扫描上限，请缩小目录范围；当前不是完整历史") }
            }
            if files.isEmpty { diagnostics.append("\(preference.client.displayName)：未发现本地用量日志") }
            entries.append(contentsOf: files.map { (preference.client, $0) })
        }
        // Rotate a bounded batch: large initial histories do not monopolize an actor or starve later files.
        if !entries.isEmpty {
            let start = cursor % entries.count
            let count = min(200, entries.count)
            for step in 0..<count {
                if Task.isCancelled { break }
                let (client, url) = entries[(start + step) % entries.count]
                do { try ingestFile(url, client: client, ledger: ledger) }
                catch { diagnostics.append("\(client.displayName)：部分日志读取失败，已保留旧账（\(error.localizedDescription)）") }
            }
            cursor = (start + count) % entries.count
            if count < entries.count { diagnostics.append("本轮检查 \(count)/\(entries.count) 个文件，后续自动继续；已入账数据保留") }
        }
        let now = Date(), minute = Int64(now.timeIntervalSince1970 / 60)
        let todayStart = Calendar.current.startOfDay(for: now)
        let sevenDayStartUnix = floor((now.timeIntervalSince1970 - 7 * 24 * 60 * 60) / 300) * 300
        let sevenDayStart = Date(timeIntervalSince1970: sevenDayStartUnix)
        let revision = try ledger.database.readRows("SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first ?? 0
        let timezone = TimeZone.current.identifier + ":" + String(TimeZone.current.secondsFromGMT(for: now))
        if aggregateCache?.revision != revision || aggregateCache?.minute != minute || aggregateCache?.timezone != timezone {
            aggregateCache = (revision, minute, timezone, try ledger.summaries(),
                try ledger.summaries(since: todayStart), try ledger.summaries(since: sevenDayStart),
                try ledger.trendBuckets(now: now), try ledger.dailyBuckets(now: now))
        }
        return MultiClientScanResult(summaries: aggregateCache?.summaries ?? [],
            diagnostics: Array((diagnostics + scanNotices).prefix(12)),
            todaySummaries: aggregateCache?.todaySummaries ?? [],
            sevenDaySummaries: aggregateCache?.sevenDaySummaries ?? [],
            trendBuckets: aggregateCache?.trend ?? [], dailyBuckets: aggregateCache?.daily ?? [])
    }

    private func deepSeekSession(_ url: URL, identity: String) throws -> String {
        if let cached = deepSeekContexts[url.path], cached.identity == identity { return cached.session }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.readShared(upToCount: 4 * 1024 * 1024)
        let decoded = url.pathExtension.lowercased() == "zstd" ? try MultiClientCompressedUsageReader.decode(bytes).data : bytes
        let fallback = url.lastPathComponent.hasPrefix("session.v") ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent
        let session = MultiClientUsageParsers.deepSeekHeaderSession(data: decoded) ?? fallback
        if deepSeekContexts.count >= 1024 { deepSeekContexts.removeAll(keepingCapacity: true) }
        deepSeekContexts[url.path] = (identity, session)
        return session
    }

    func backup() throws -> URL { try open().backup() }

    /// Reads cached cache-ranking projections on demand without scanning source logs. If the
    /// ledger has not been opened by a normal scan, it is queried with SQLite read-only flags.
    func cacheRankingProjection(
        clients: Set<UsageClient>? = nil,
        since: Date? = nil,
        order: ClientCacheRankingOrder = .lowestHit,
        requestLimit: Int = 500
    ) throws -> ClientCacheRankingProjection {
        if let ledger {
            return try ledger.cacheRankingProjection(clients: clients, since: since, order: order, requestLimit: requestLimit)
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return .empty }
        return try MultiClientUsageLedger.readOnlyCacheRankingProjection(
            url: databaseURL,
            clients: clients,
            since: since,
            order: order,
            requestLimit: requestLimit
        )
    }

    static func files(at url: URL) -> (files: [URL], truncated: Bool) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return ([], false) }
        if !isDirectory.boolValue { return ([url], false) }
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return ([], false) }
        var result: [URL] = []
        var visited = 0
        var truncated = false
        for case let file as URL in enumerator {
            visited += 1
            if visited > 200_000 { truncated = true; break }
            if enumerator.level > 8 { enumerator.skipDescendants(); truncated = true; continue }
            let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties?.isRegularFile == true, properties?.isSymbolicLink != true,
                  ["json", "jsonl", "zstd", "db", "sqlite"].contains(file.pathExtension.lowercased()) else { continue }
            result.append(file)
            if result.count >= 20_000 { truncated = true; break }
        }
        return (result.sorted { $0.path < $1.path }, truncated)
    }

    private func ingestFile(_ url: URL, client: UsageClient, ledger: MultiClientUsageLedger) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { return }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        var modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var identity = String(describing: attrs[.systemFileNumber] ?? "")
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let saved = try ledger.checkpoint(client: client, sourceKey: key)
        let isDatabase = ["db", "sqlite"].contains(url.pathExtension.lowercased())
        if isDatabase, let wal = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal") {
            modified = max(modified, (wal[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            if client == .antigravity {
                identity += ":wal:\(wal[.systemFileNumber] ?? ""):\(wal[.size] ?? ""):\((wal[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
        }
        // Hash a fixed prefix already covered by the checkpoint. Appending to a short
        // file must not change the comparison width; a rewritten prefix resets the scan.
        if !isDatabase {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let width = min(4096, max(0, saved?.offset ?? 0))
            let prefix = try handle.readShared(upToCount: Int(width), probe: true)
            let digest = SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
            identity += ":" + String(width) + ":" + digest
        }
        identity = MultiClientUsageParsers.checkpointIdentity(identity, client: client)
        if let saved, saved.size == size, saved.modified == modified, saved.identity == identity, saved.offset >= size { return }
        let sessionHint = client == .deepseek ? try deepSeekSession(url, identity: identity) : url.deletingPathExtension().lastPathComponent
        let events: [ClientUsageEvent]
        let offset: Int64
        var checkpointIdentity = identity
        var checkpointModified = modified
        if isDatabase && client == .antigravity {
            guard AntigravityUsageSource.isConversation(url) else { return }
            let read = try AntigravityUsageSource.read(url)
            events = read.events
            offset = size
            if read.malformedRows > 0 { scanNotices.append("Antigravity：部分记录字段无效，已保留可识别用量和旧账") }
        } else if isDatabase {
            guard client == .opencode else { return }
            let prefix = identity + "|"
            let continuation = saved.flatMap { saved -> OpenCodeDatabaseCursor? in
                guard saved.offset == -1, saved.identity.hasPrefix(prefix),
                      let data = Data(base64Encoded: String(saved.identity.dropFirst(prefix.count))) else { return nil }
                return try? JSONDecoder().decode(OpenCodeDatabaseCursor.self, from: data)
            }
            // Keep the first page's modification time until completion. If the database
            // changes behind the cursor while paging, the next pass will replay it.
            if continuation != nil, let saved { checkpointModified = saved.modified }
            let page = try MultiClientUsageParsers.readOpenCodeDatabase(url: url, after: continuation, limit: 500)
            events = page.events
            if page.isComplete { offset = size }
            else if let cursor = page.nextCursor {
                offset = -1
                checkpointIdentity = prefix + (try JSONEncoder().encode(cursor)).base64EncodedString()
                scanNotices.append("OpenCode：历史分页读取中，已完成的请求已保留；每轮继续 500 条")
            } else { throw ScanError.oversized }
            if page.skippedMalformedRows + page.skippedOversizedRows > 0 {
                scanNotices.append("OpenCode：部分消息缺少有效字段或超过单条上限，未计入 Token")
            }
        } else if client == .deepseek && url.pathExtension.lowercased() == "zstd" {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let start = saved.flatMap { $0.identity == identity && $0.offset <= size && ($0.size != size || $0.modified == modified) ? $0.offset : nil } ?? 0
            try handle.seek(toOffset: UInt64(start))
            let bytes = try handle.readShared(upToCount: 4 * 1024 * 1024)
            let batch = try MultiClientCompressedUsageReader.decode(bytes)
            guard batch.consumed > 0 else {
                if bytes.count >= 4 * 1024 * 1024 { throw ScanError.oversized }
                return
            }
            events = try MultiClientUsageParsers.parse(data: batch.data, client: client, sessionHint: sessionHint)
            offset = start + Int64(batch.consumed)
            try handle.seek(toOffset: 0)
            let width = min(4096, offset)
            let prefix = try handle.readShared(upToCount: Int(width), probe: true)
            checkpointIdentity = String(describing: attrs[.systemFileNumber] ?? "") + ":" + String(width) + ":" + SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
        } else if url.pathExtension.lowercased() == "jsonl" {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let start = saved.flatMap { $0.identity == identity && $0.offset <= size && ($0.size != size || $0.modified == modified) ? $0.offset : nil } ?? 0
            try handle.seek(toOffset: UInt64(start))
            let bytes = try handle.readShared(upToCount: 4 * 1024 * 1024)
            guard let newline = bytes.lastIndex(of: 10) else {
                if bytes.count >= 4 * 1024 * 1024 { throw ScanError.oversized }
                return // Hold a partial trailing line; do not publish a checkpoint beyond it.
            }
            let complete = bytes.prefix(through: newline)
            events = try MultiClientUsageParsers.parse(data: Data(complete), client: client, sessionHint: sessionHint)
            offset = start + Int64(complete.count)
            try handle.seek(toOffset: 0)
            let width = min(4096, offset)
            let prefix = try handle.readShared(upToCount: Int(width), probe: true)
            let digest = SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
            checkpointIdentity = String(describing: attrs[.systemFileNumber] ?? "") + ":" + String(width) + ":" + digest
        } else {
            guard size <= 16 * 1024 * 1024 else { throw ScanError.oversized }
            events = try MultiClientUsageParsers.parse(data: FileHandle.readSourceDocument(at: url, maximumBytes: 16 * 1024 * 1024), client: client, sessionHint: sessionHint)
            offset = size
            let prefix = try FileHandle(forReadingFrom: url)
            defer { try? prefix.close() }
            let width = min(4096, size)
            let bytes = try prefix.readShared(upToCount: Int(width), probe: true)
            checkpointIdentity = String(describing: attrs[.systemFileNumber] ?? "") + ":" + String(width) + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        _ = try ledger.ingest(events, client: client, sourceKey: key,
                              checkpoint: MultiClientFileCheckpoint(offset: offset, size: size, modified: checkpointModified,
                                  identity: MultiClientUsageParsers.checkpointIdentity(checkpointIdentity, client: client)))
    }
    enum ScanError: LocalizedError {
        case oversized
        var errorDescription: String? { "单条或单文件超过读取上限，未跳过其断点" }
    }
}

@MainActor
final class MultiClientUsageStore: ObservableObject {
    static let shared = MultiClientUsageStore()
    static let preferencesKey = "multiClientUsage.preferences.v1"
    static var defaultDatabaseURL: URL {
        ClientUsageDataLocation.databaseURL(
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            bundleIdentifier: Bundle.main.bundleIdentifier)
    }
    @Published private(set) var preferences: [MultiClientUsagePreference]
    @Published private(set) var detections: [DetectedUsageClient] = []
    @Published private(set) var trendBuckets: [ClientTrendBucket] = []
    @Published private(set) var dailyBuckets: [ClientTrendBucket] = []
    @Published private(set) var acknowledgedClients: Set<String> = []
    @Published private(set) var summaries: [ClientUsageSummary] = []
    @Published private(set) var todaySummaries: [ClientUsageSummary] = []
    @Published private(set) var sevenDaySummaries: [ClientUsageSummary] = []
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var refreshing = false
    @Published private(set) var updatedAt: Date?
    @Published private(set) var claudeQuota = ClaudeLocalQuota.missing
    @Published private(set) var claudeDesktopQuota = ClaudeLocalQuota.missing
    @Published private(set) var antigravityQuota = AntigravityLocalQuota.empty()
    private let defaults: UserDefaults
    private let scanner: MultiClientUsageScanner
    private let quotaReader: @Sendable () -> ClaudeLocalQuota
    private let desktopQuotaReader: @Sendable () -> ClaudeLocalQuota
    private let antigravityQuotaReader: @Sendable () -> ClientQuotaReading
    private var loop: Task<Void, Never>?
    private var isStarted = false
    private var quotaTimer: (any AccountQuotaTimerToken)?
    private var quotaTimerInterval: TimeInterval?
    private let quotaTimerScheduler: any AccountQuotaTimerScheduling
    private let quotaProbeUptime: @Sendable () -> TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var quotaProbeInFlight = false
    private var lastQuotaProbeUptime: TimeInterval?
    private var menuItem: NSStatusItem?
    private var monitoringUpdates: AnyCancellable?

    init(defaults: UserDefaults = .standard, databaseURL: URL = MultiClientUsageStore.defaultDatabaseURL,
         quotaReader: @escaping @Sendable () -> ClaudeLocalQuota = { ClaudeLocalQuota.read() },
         desktopQuotaReader: @escaping @Sendable () -> ClaudeLocalQuota = { ClaudeLocalQuota.readDesktop() },
         antigravityQuotaReader: @escaping @Sendable () -> ClientQuotaReading = { AntigravityLocalQuota.read() },
         quotaTimerScheduler: any AccountQuotaTimerScheduling = FoundationAccountQuotaTimerScheduler(),
         quotaProbeUptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.quotaReader = quotaReader
        self.desktopQuotaReader = desktopQuotaReader
        self.antigravityQuotaReader = antigravityQuotaReader
        self.quotaTimerScheduler = quotaTimerScheduler
        self.quotaProbeUptime = quotaProbeUptime
        let decoded = defaults.data(forKey: Self.preferencesKey).flatMap { try? JSONDecoder().decode([MultiClientUsagePreference].self, from: $0) } ?? []
        preferences = MultiClientUsagePreference.normalized(decoded)
        scanner = MultiClientUsageScanner(databaseURL: databaseURL)
        acknowledgedClients = Set(defaults.stringArray(forKey: "multiClient.discoveryAcknowledged.v1") ?? [])
    }
    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitoringUpdates = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.syncLocalRuntime()
                self?.configureLocalQuotaTimer()
            }
        // Local providers share the main page's quota cadence, independently of
        // transcript ingestion and speed monitoring. No provider is invoked remotely.
        refreshLocalQuotaCaches(force: true)
        configureLocalQuotaTimer()
        syncLocalRuntime()
        refresh()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    func stop() {
        isStarted = false
        loop?.cancel(); loop = nil
        quotaTimer?.invalidate(); quotaTimer = nil; quotaTimerInterval = nil
        monitoringUpdates?.cancel(); monitoringUpdates = nil
    }
    private func configureLocalQuotaTimer() {
        guard isStarted else { return }
        let interval = AccountQuotaRefreshCadence.storedValue(in: defaults).seconds
        guard quotaTimerInterval != interval else { return }
        quotaTimer?.invalidate()
        quotaTimerInterval = interval
        quotaTimer = quotaTimerScheduler.scheduleRepeatingTimer(interval: interval) { [weak self] in
            guard let self, self.isStarted, self.quotaTimerInterval == interval else { return }
            self.refreshLocalQuotaCaches(automatic: true)
        }
    }
    func update(_ value: MultiClientUsagePreference) {
        var next = preferences
        let prior = next.first { $0.client == value.client }
        if let index = next.firstIndex(where: { $0.client == value.client }) { next[index] = value }
        preferences = MultiClientUsagePreference.normalized(next)
        persist()
        if prior?.enabled != value.enabled || prior?.path != value.path { syncLocalRuntime(); refresh() }
    }
    func move(_ client: UsageClient, by offset: Int) {
        guard let index = preferences.firstIndex(where: { $0.client == client }), preferences.indices.contains(index + offset) else { return }
        preferences.swapAt(index, index + offset)
        for index in preferences.indices { preferences[index].order = index }
        persist()
    }
    private func persist() {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
        generation += 1; syncMenuItems()
    }
    func syncLocalRuntime(monitoringEnabled: Bool? = nil) {
        let enabled = monitoringEnabled ?? (defaults.object(forKey: "liveRateMonitoringEnabled") == nil || defaults.bool(forKey: "liveRateMonitoringEnabled"))
        AgentSpeedReportingController.shared.configureLocalPreferences(preferences)
        AgentSpeedDisplayRuntime.shared.configure(monitoringEnabled: enabled, codexEnabled: enabled, preferences: preferences)
        ClaudeLocalRuntime.shared.configure(preferences: preferences, monitoringEnabled: enabled)
        ClaudeStatuslineStore.shared.setEnabled(enabled && preferences.contains { $0.enabled && $0.client == .claudeCode })
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let preferences = preferences, generation = generation
        refreshTask = Task { [weak self, scanner] in
            do {
                let detected = await Task.detached(priority: .utility) { UsageClientDetection.detect() }.value
                self?.detections = detected
                let result = try await scanner.scan(preferences)
                guard let self else { return }
                if self.generation == generation {
                    self.summaries = result.summaries
                    self.todaySummaries = result.todaySummaries
                    self.sevenDaySummaries = result.sevenDaySummaries
                    self.diagnostics = result.diagnostics
                    self.detections = detected; self.trendBuckets = result.trendBuckets; self.dailyBuckets = result.dailyBuckets
                    self.updatedAt = Date(); self.syncMenuItems()
                }
            } catch { self?.diagnostics = [error.localizedDescription] }
            self?.refreshing = false
            if self?.generation != generation { self?.refresh() }
        }
    }
    func refreshLocalQuotaCaches(force: Bool = false, automatic: Bool = false) {
        let uptime = quotaProbeUptime()
        let interval = AccountQuotaRefreshCadence.storedValue(in: defaults).seconds
        let reuseInterval = automatic ? AccountQuotaAutomaticRefreshPolicy.successCooldown(for: interval) : interval
        guard force || (lastQuotaProbeUptime.map({ uptime - $0 >= reuseInterval }) ?? true) else { return }
        guard !quotaProbeInFlight else { return }
        quotaProbeInFlight = true
        lastQuotaProbeUptime = uptime
        let reader = quotaReader
        let desktopReader = desktopQuotaReader
        let antigravityReader = antigravityQuotaReader
        Task { [weak self] in
            let (reading, desktop, antigravity) = await Task.detached(priority: .utility) { (reader(), desktopReader(), antigravityReader()) }.value
            guard let self else { return }
            if self.claudeQuota != reading || self.claudeDesktopQuota != desktop || self.antigravityQuota != antigravity {
                self.claudeQuota = reading
                self.claudeDesktopQuota = desktop
                self.antigravityQuota = antigravity
                self.syncMenuItems()
            }
            self.quotaProbeInFlight = false
        }
    }
    private func hasLocalQuota(_ client: UsageClient) -> Bool {
        let value = quotaReading(client)
        return ClientQuotaPresentation.isPresent(value, detected: detections.contains { $0.client == client })
    }
    var localQuotaReadings: [ClientQuotaReading] {
        availablePreferences.map { quotaReading($0.client) }.filter { $0.source != "unsupported" }
    }
    var displayClientIDs: [String] {
        preferences.filter { value in
            value.enabled || summaries.contains { $0.client == value.client }
                || hasLocalQuota(value.client)
        }.map { $0.client.rawValue }
    }
    var availablePreferences: [MultiClientUsagePreference] {
        preferences.filter { value in
            value.enabled || !value.path.isEmpty || detections.contains { $0.client == value.client }
                || summaries.contains { $0.client == value.client }
                || hasLocalQuota(value.client)
        }
    }
    var newDetections: [DetectedUsageClient] {
        detections.filter { detected in !acknowledgedClients.contains(detected.client.rawValue) && !preferences.contains { $0.client == detected.client && $0.enabled } }
    }
    func acknowledge(_ client: UsageClient) {
        acknowledgedClients.insert(client.rawValue)
        defaults.set(Array(acknowledgedClients).sorted(), forKey: "multiClient.discoveryAcknowledged.v1")
    }
    func enable(_ client: UsageClient) {
        guard var value = preferences.first(where: { $0.client == client }) else { return }
        value.enabled = true; value.showSidebar = true; value.showQuota = quotaReading(client).source != "unsupported"
        acknowledge(client); update(value)
    }
    func quotaReading(_ client: UsageClient) -> ClientQuotaReading {
        switch client {
        case .claudeCode: ClaudeCapturedQuotaProvider(snapshot: claudeQuota).reading()
        case .claudeDesktop: ClaudeCapturedQuotaProvider(snapshot: claudeDesktopQuota, client: .claudeDesktop).reading()
        case .antigravity: antigravityQuota
        default: UnavailableClientQuotaProvider(client: client).reading()
        }
    }
    func backup() async throws -> URL { try await scanner.backup() }
    func cacheRankingProjection(
        clients: Set<UsageClient>? = nil,
        since: Date? = nil,
        order: ClientCacheRankingOrder = .lowestHit,
        requestLimit: Int = 500
    ) async throws -> ClientCacheRankingProjection {
        try await scanner.cacheRankingProjection(clients: clients, since: since, order: order, requestLimit: requestLimit)
    }
    func total(_ client: UsageClient) -> Int64 {
        summaries.filter { $0.client == client }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }
    func refreshPresentation() { syncMenuItems() }
    private func syncMenuItems() {
        let visible = preferences.filter(\.showMenuBar)
        let showClaudeQuota = defaults.bool(forKey: "multiClient.claudeQuotaMenuBar")
        guard !visible.isEmpty || showClaudeQuota else {
            if let menuItem { NSStatusBar.system.removeStatusItem(menuItem); self.menuItem = nil }
            return
        }
        let item = menuItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuItem = item
        let title = NSMutableAttributedString(string: "")
        for preference in visible {
            if title.length > 0 { title.append(NSAttributedString(string: "  ·  ")) }
            let amount = summaries.contains { $0.client == preference.client } ? Self.compact(total(preference.client)) : "—"
            let text = preference.style == "compact" ? "\(preference.client.displayName.prefix(3)) \(amount)" : "\(preference.client.displayName) \(amount) Token"
            title.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor(clientHex: preference.color)]))
        }
        if showClaudeQuota {
            let quotaText: String
            if claudeQuota.state == "available", let window = claudeQuota.fiveHour ?? claudeQuota.sevenDay {
                quotaText = "Claude " + String(Int((100 - window.usedPercent).rounded())) + "%"
            } else { quotaText = "Claude —" }
            let quotaTitle = NSAttributedString(string: quotaText, attributes: [.foregroundColor: NSColor(clientHex: defaults.string(forKey: "multiClient.claudeQuotaColor") ?? "#d87757")])
            if defaults.bool(forKey: "multiClient.claudeQuotaFirst") {
                if title.length > 0 { title.insert(NSAttributedString(string: "  ·  "), at: 0) }
                title.insert(quotaTitle, at: 0)
            } else {
                if title.length > 0 { title.append(NSAttributedString(string: "  ·  ")) }
                title.append(quotaTitle)
            }
        }
        item.button?.attributedTitle = title
        item.button?.toolTip = "本地已记录输入+输出 Token；不代表订阅剩余额度"
    }
    static func compact(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

extension NSColor {
    convenience init(clientHex: String) {
        let value = UInt32(clientHex.dropFirst(), radix: 16) ?? 0x888888
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

// Keep persisted v1 preferences readable when adding optional display capabilities.
extension MultiClientUsagePreference {
    enum CodingKeys: String, CodingKey { case client, enabled, showSidebar, showMenuBar, showQuota, color, order, style, path }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedClient = try c.decode(UsageClient.self, forKey: .client)
        client = decodedClient
        let fallback = Self.defaults.first { $0.client == decodedClient }!
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        showSidebar = try c.decodeIfPresent(Bool.self, forKey: .showSidebar) ?? false
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? false
        showQuota = try c.decodeIfPresent(Bool.self, forKey: .showQuota) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? fallback.color
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? fallback.order
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "compact"
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}
