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
    private var claudeDiscoveryCursor: String?
    private var aggregateCache: (
        minute: Int64, timezone: String, includesCharts: Bool, projection: MultiClientUsageLedger.ScanProjection
    )?
    private var scanNotices: [String] = []
    private var importedQuotaHistorySource: String?
    private var deepSeekContexts: [String: (identity: String, session: String)] = [:]
    init(databaseURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.databaseURL = databaseURL; self.home = home; self.environment = environment
    }
    private func open() throws -> MultiClientUsageLedger {
        if let ledger { return ledger }
        let opened = try MultiClientUsageLedger(url: databaseURL); ledger = opened; return opened
    }
    func scan(_ preferences: [MultiClientUsagePreference], includesCharts: Bool = true) throws -> MultiClientScanResult {
        try autoreleasepool { try scanSynchronously(preferences, includesCharts: includesCharts) }
    }

    private func scanSynchronously(_ preferences: [MultiClientUsagePreference], includesCharts: Bool) throws -> MultiClientScanResult {
        let enabled = preferences.filter(\.enabled)
        guard !enabled.isEmpty || FileManager.default.fileExists(atPath: databaseURL.path) else {
            return MultiClientScanResult(summaries: [], diagnostics: [])
        }
        let ledger = try open()
        var diagnostics: [String] = []
        scanNotices = []
        let claudeCheckpointOwners = try ledger.claudeCheckpointOwners()
        var claudeClassificationBytesRemaining = 64 * 1_024 * 1_024
        var entries: [(UsageClient, URL)] = []
        let sharesClaudeDiscovery = enabled.contains { $0.client == .claudeCode && $0.path.isEmpty }
            && enabled.contains { $0.client == .claudeDesktop && $0.path.isEmpty }
        var claudeDiscovery: MultiClientUsageDiscovery.ClaudePairResult?
        for preference in enabled {
            let files: [URL]
            if preference.client == .antigravity {
                let discovery = AntigravityUsageSource.discover(home: home, path: preference.path)
                files = discovery.files
                if discovery.truncated { diagnostics.append("Antigravity：发现达到读取上限，请缩小目录范围；当前不是完整历史") }
            } else if preference.path.isEmpty {
                let discovery: MultiClientUsageDiscovery.Result
                if sharesClaudeDiscovery, preference.client == .claudeCode || preference.client == .claudeDesktop {
                    let paired: MultiClientUsageDiscovery.ClaudePairResult
                    if let cached = claudeDiscovery {
                        paired = cached
                    } else {
                        let discovered = MultiClientUsageDiscovery.discoverClaudePair(
                            home: home,
                            environment: environment,
                            claudeCheckpointOwners: claudeCheckpointOwners,
                            resumeAfterSourceKey: claudeDiscoveryCursor
                        )
                        claudeDiscovery = discovered
                        claudeDiscoveryCursor = discovered.nextClaudeSourceKey
                        paired = discovered
                    }
                    discovery = preference.client == .claudeCode ? paired.code : paired.desktop
                } else {
                    discovery = MultiClientUsageDiscovery.discover(
                        client: preference.client,
                        home: home,
                        environment: environment,
                        claudeCheckpointOwners: claudeCheckpointOwners,
                        resumeAfterClaudeSourceKey: preference.client == .claudeCode || preference.client == .claudeDesktop
                            ? claudeDiscoveryCursor
                            : nil
                    )
                    if preference.client == .claudeCode || preference.client == .claudeDesktop {
                        claudeDiscoveryCursor = discovery.nextClaudeSourceKey
                    }
                }
                files = discovery.files
                if discovery.claudeOwnershipConflict {
                    scanNotices.append("Claude：部分日志已有另一客户端账本归属，保留旧账并跳过自动重分类")
                }
                if discovery.truncated { diagnostics.append("\(preference.client.displayName)：自动发现未完整完成，部分目录或记录未读取；当前不是完整历史") }
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
            // Only the connection is shared. Each file still commits its
            // checkpoint and events together in its own transaction.
            try ledger.database.withOperationConnection {
                for step in 0..<count {
                    if Task.isCancelled { break }
                    let (client, url) = entries[(start + step) % entries.count]
                    do {
                        try autoreleasepool {
                            try ingestFile(
                                url,
                                client: client,
                                ledger: ledger,
                                claudeClassificationBytesRemaining: &claudeClassificationBytesRemaining
                            )
                        }
                    }
                    catch { diagnostics.append("\(client.displayName)：部分日志读取失败，已保留旧账（\(error.localizedDescription)）") }
                }
            }
            cursor = (start + count) % entries.count
            if count < entries.count { diagnostics.append("本轮检查 \(count)/\(entries.count) 个文件，后续自动继续；已入账数据保留") }
        }
        let projection = try usageProjection(ledger, includesCharts: includesCharts)
        return MultiClientScanResult(summaries: projection?.summaries ?? [],
            diagnostics: Array((diagnostics + scanNotices).prefix(12)),
            todaySummaries: projection?.todaySummaries ?? [],
            sevenDaySummaries: projection?.sevenDaySummaries ?? [],
            trendBuckets: projection?.trend ?? [], dailyBuckets: projection?.daily ?? [])
    }

    private func usageProjection(_ ledger: MultiClientUsageLedger, includesCharts: Bool) throws -> MultiClientUsageLedger.ScanProjection? {
        if !includesCharts, aggregateCache?.includesCharts == true { discardUsageCharts() }
        let now = Date(), minute = Int64(now.timeIntervalSince1970 / 60)
        let timezone = TimeZone.current.identifier + ":" + String(TimeZone.current.secondsFromGMT(for: now))
        let unchangedRevision = aggregateCache.flatMap {
            $0.minute == minute && $0.timezone == timezone && $0.includesCharts == includesCharts
                ? $0.projection.revision : nil
        }
        if let projection = try ledger.scanProjection(
            now: now, unchangedRevision: unchangedRevision, includesCharts: includesCharts
        ) {
            aggregateCache = (minute, timezone, includesCharts, projection)
        }
        return aggregateCache?.projection
    }

    func loadUsageCharts() throws -> (trend: [ClientTrendBucket], daily: [ClientTrendBucket]) {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return ([], []) }
        let projection = try autoreleasepool { try usageProjection(open(), includesCharts: true) }
        return (projection?.trend ?? [], projection?.daily ?? [])
    }

    func discardUsageCharts() {
        aggregateCache?.projection.trend = []
        aggregateCache?.projection.daily = []
        aggregateCache?.includesCharts = false
        ledger?.discardDailyProjection()
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

    func recordQuotaHistory(_ readings: [ClientQuotaReading]) throws {
        let hasObservation = readings.contains { reading in
            reading.capturedAt != nil && ["available", "stale", "cached"].contains(reading.state)
                && reading.windows.contains { ClientQuotaHistory.pool(client: reading.client, windowID: $0.id ?? $0.label) != nil }
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) || hasObservation else { return }
        let ledger = try open()
        let desktopSource = readings.first { $0.client == "claudeDesktop" }?.source ?? ""
        if importedQuotaHistorySource != desktopSource {
            try ledger.recordQuotaHistory(ClaudeLocalQuota.desktopHistoryReadings(home: home))
            importedQuotaHistorySource = desktopSource
        }
        try ledger.recordQuotaHistory(readings)
    }

    func loadQuotaHistory(_ readings: [ClientQuotaReading], projection: QuotaHistoryProjection) throws -> [ClientQuotaHistory] {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        return try autoreleasepool { try open().quotaHistory(readings: readings, projection: projection) }
    }

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

    private func ingestFile(
        _ url: URL,
        client: UsageClient,
        ledger: MultiClientUsageLedger,
        claudeClassificationBytesRemaining: inout Int
    ) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { return }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        var modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var identity = String(describing: attrs[.systemFileNumber] ?? "")
        let key = MultiClientUsageLedger.sourceKey(for: url)
        let isClaudeJSONL = (client == .claudeCode || client == .claudeDesktop)
            && url.pathExtension.lowercased() == "jsonl"
        var claudeSourceObservation: SourceFileObservation?
        if isClaudeJSONL {
            // Reuse one classification only when the checkpoint proves it was
            // written under the current contract and the physical source is unchanged.
            let observed = try SourceFileObservation.read(at: url)
            claudeSourceObservation = observed
            let oppositeClient: UsageClient = client == .claudeCode ? .claudeDesktop : .claudeCode
            if try ledger.checkpoint(client: oppositeClient, sourceKey: key) != nil {
                scanNotices.append("Claude：该日志已有另一客户端账本归属，保留旧账并跳过自动重分类")
                return
            }
        }
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
        if let claudeSourceObservation {
            identity += "|physical-v1:\(claudeSourceObservation.physicalStamp)"
        }
        identity = MultiClientUsageParsers.checkpointIdentity(identity, client: client, isDatabase: isDatabase)
        if let saved,
           saved.size == size,
           saved.modified == modified,
           saved.identity == identity,
           saved.offset >= size,
           (!isClaudeJSONL || saved.identity.hasPrefix(MultiClientUsageParsers.claudeEntrypointCheckpointPrefix)) {
            return
        }
        if isClaudeJSONL {
            guard let observed = claudeSourceObservation else { throw CocoaError(.fileReadUnknown) }
            let classification = try ClaudeTranscriptClassification.classify(
                url: url,
                byteLimit: claudeClassificationBytesRemaining
            )
            claudeClassificationBytesRemaining = max(0, claudeClassificationBytesRemaining - classification.bytesRead)
            // A transcript tail is committed only by LF. Until that arrives,
            // classification is intentionally inconclusive and should behave
            // like the JSONL reader below: wait without publishing a notice or
            // advancing the checkpoint. A full classifier window with bytes
            // still present beyond the parser limit, however, is an oversized
            // record and must use the established read-limit diagnostic.
            if case .incomplete(.partialRecord) = classification.evidence {
                if saved != nil {
                    scanNotices.append("Claude：日志分类未完成，保留旧账且不推进断点")
                }
                return
            }
            if case .incomplete(.byteLimit) = classification.evidence,
               classification.bytesRead >= MultiClientUsageParsers.maximumInputBytes,
               size > Int64(classification.bytesRead) {
                guard observed.matches(try SourceFileObservation.read(at: url)) else {
                    throw POSIXError(.ESTALE)
                }
                throw ScanError.oversized
            }
            guard let classifiedClient = classification.client else {
                scanNotices.append("Claude：日志分类未完成，保留旧账且不推进断点")
                return
            }
            guard classifiedClient == client else {
                scanNotices.append("Claude：日志归属与当前客户端不符，保留旧账且不推进断点")
                return
            }
            guard observed.matches(try SourceFileObservation.read(at: url)) else { throw POSIXError(.ESTALE) }
            claudeSourceObservation = observed
        }
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
            let start: Int64 = saved.flatMap { checkpoint -> Int64? in
                guard MultiClientUsageParsers.checkpointBaseIdentity(checkpoint.identity)
                    == MultiClientUsageParsers.checkpointBaseIdentity(identity),
                    checkpoint.offset <= size else { return nil }
                if checkpoint.size == size {
                    guard checkpoint.modified == modified else { return nil }
                    return checkpoint.identity == identity ? checkpoint.offset : 0
                }
                return checkpoint.offset
            } ?? 0
            try handle.seek(toOffset: UInt64(start))
            let readWindow = 4 * 1024 * 1024
            let isClaude = client == .claudeCode || client == .claudeDesktop
            let recordLimit = isClaude ? MultiClientUsageParsers.maximumInputBytes : readWindow
            let before: SourceFileObservation?
            if isClaude && size - start >= Int64(readWindow) {
                before = try SourceFileObservation.readPhysical(handle: handle)
            } else {
                before = nil
            }
            var bytes = try handle.readShared(upToCount: readWindow)
            var extendedObservation: SourceFileObservation?
            // Preserve ordinary batch paging. Only a first record without LF
            // needs continuation, and it must fit the existing parser limit.
            if isClaude, bytes.count == readWindow, !bytes.contains(10) {
                guard let before else { throw POSIXError(.ESTALE) }
                extendedObservation = before
                while bytes.count < recordLimit {
                    try Task.checkCancellation()
                    let next = try handle.readShared(upToCount: min(readWindow, recordLimit - bytes.count))
                    if next.isEmpty { break }
                    if let newline = next.firstIndex(of: 10) {
                        bytes.append(next.prefix(through: newline))
                        break // A large record's successor belongs to the next scan.
                    }
                    bytes.append(next)
                }
                guard before.matches(try SourceFileObservation.readPhysical(handle: handle)),
                      before.matches(try SourceFileObservation.read(at: url))
                else { throw POSIXError(.ESTALE) }
            }
            guard let newline = bytes.lastIndex(of: 10) else {
                if bytes.count >= recordLimit { throw ScanError.oversized }
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
            if let before = extendedObservation {
                guard before.matches(try SourceFileObservation.readPhysical(handle: handle)),
                      before.matches(try SourceFileObservation.read(at: url))
                else { throw POSIXError(.ESTALE) }
            }
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
        if let claudeSourceObservation {
            checkpointIdentity += "|physical-v1:\(claudeSourceObservation.physicalStamp)"
        }
        if let claudeSourceObservation,
           !claudeSourceObservation.matches(try SourceFileObservation.read(at: url)) {
            throw POSIXError(.ESTALE)
        }
        _ = try ledger.ingest(events, client: client, sourceKey: key,
                              checkpoint: MultiClientFileCheckpoint(offset: offset, size: size, modified: checkpointModified,
                                  identity: MultiClientUsageParsers.checkpointIdentity(checkpointIdentity, client: client, isDatabase: isDatabase)))
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
            applicationSupport: ApplicationStorageLocation.applicationSupport,
            bundleIdentifier: Bundle.main.bundleIdentifier)
    }
    @Published private(set) var preferences: [MultiClientUsagePreference]
    @Published private(set) var detections: [DetectedUsageClient] = []
    private(set) var trendBuckets: [ClientTrendBucket] = []
    private(set) var dailyBuckets: [ClientTrendBucket] = []
    @Published private(set) var usageChartRevision = 0
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
    @Published private(set) var quotaHistories: [ClientQuotaHistory] = []
    @Published private(set) var quotaHistoryIssue: String?
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
    private var usageChartConsumers: Set<UUID> = []
    private var usageChartLoadTask: Task<Void, Never>?
    private var quotaProbeInFlight = false
    private var lastQuotaProbeUptime: TimeInterval?
    private var quotaHistoryConsumers: [UUID: QuotaHistoryProjection] = [:]
    private var quotaHistoryReadings: [ClientQuotaReading] = []
    private var quotaHistoryTask: Task<Void, Never>?
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
        // transcript ingestion and speed monitoring. Claude reads files; the active
        // Antigravity Hub may use its authorized loopback status query.
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
        // Reconcile newly registered local accounts on the existing refresh
        // cadence; unchanged monitor configurations do not restart the core.
        syncLocalRuntime()
        refreshing = true
        let preferences = preferences, generation = generation
        refreshTask = Task { [weak self, scanner] in
            var includesCharts = false
            do {
                let detected = await Task.detached(priority: .utility) { UsageClientDetection.detect() }.value
                guard let self else { return }
                self.detections = detected
                includesCharts = !self.usageChartConsumers.isEmpty
                let result = try await scanner.scan(preferences, includesCharts: includesCharts)
                if self.generation == generation {
                    self.summaries = result.summaries
                    self.todaySummaries = result.todaySummaries
                    self.sevenDaySummaries = result.sevenDaySummaries
                    self.diagnostics = result.diagnostics
                    self.detections = detected
                    if includesCharts, !self.usageChartConsumers.isEmpty {
                        self.usageChartLoadTask?.cancel()
                        self.usageChartLoadTask = nil
                        self.publishUsageCharts(trend: result.trendBuckets, daily: result.dailyBuckets)
                    }
                    self.updatedAt = Date(); self.syncMenuItems()
                }
                if includesCharts, self.usageChartConsumers.isEmpty {
                    await scanner.discardUsageCharts()
                }
            } catch { self?.diagnostics = [error.localizedDescription] }
            guard let self else { return }
            self.refreshing = false
            if self.generation != generation { self.refresh() }
            else if !includesCharts { self.loadUsageChartsForDashboard() }
        }
    }

    func setUsageChartDemand(_ active: Bool, consumer: UUID) {
        let hadDemand = !usageChartConsumers.isEmpty
        if active { usageChartConsumers.insert(consumer) }
        else { usageChartConsumers.remove(consumer) }
        if !usageChartConsumers.isEmpty {
            if !hadDemand { loadUsageChartsForDashboard() }
        } else if hadDemand {
            usageChartLoadTask?.cancel()
            usageChartLoadTask = nil
            publishUsageCharts(trend: [], daily: [])
            Task { [weak self, scanner] in
                guard self?.usageChartConsumers.isEmpty != false else { return }
                await scanner.discardUsageCharts()
            }
        }
    }

    private func loadUsageChartsForDashboard() {
        guard !usageChartConsumers.isEmpty, !refreshing, usageChartLoadTask == nil else { return }
        usageChartLoadTask = Task(priority: .utility) { [weak self, scanner] in
            do {
                let charts = try await scanner.loadUsageCharts()
                guard let self else { return }
                guard !self.usageChartConsumers.isEmpty else {
                    await scanner.discardUsageCharts()
                    return
                }
                guard !Task.isCancelled else { return }
                self.usageChartLoadTask = nil
                self.publishUsageCharts(trend: charts.trend, daily: charts.daily)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.usageChartLoadTask = nil
                self.diagnostics = [error.localizedDescription]
            }
        }
    }

    private func publishUsageCharts(trend: [ClientTrendBucket], daily: [ClientTrendBucket]) {
        guard trend != trendBuckets || daily != dailyBuckets else { return }
        trendBuckets = trend
        dailyBuckets = daily
        usageChartRevision &+= 1
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
            let readings = [ClaudeCapturedQuotaProvider(snapshot: reading).reading(),
                ClaudeCapturedQuotaProvider(snapshot: desktop, client: .claudeDesktop).reading(), antigravity]
            if self.quotaHistoryReadings.map(\.source) != readings.map(\.source) {
                self.quotaHistoryTask?.cancel()
                if !self.quotaHistories.isEmpty { self.quotaHistories = [] }
            }
            self.quotaHistoryReadings = readings
            if self.claudeQuota != reading || self.claudeDesktopQuota != desktop || self.antigravityQuota != antigravity {
                self.claudeQuota = reading
                self.claudeDesktopQuota = desktop
                self.antigravityQuota = antigravity
                self.syncMenuItems()
            }
            do {
                try await self.scanner.recordQuotaHistory(readings)
                if self.quotaHistoryIssue != nil { self.quotaHistoryIssue = nil }
                self.reloadQuotaHistory()
            } catch {
                self.reportQuotaHistoryError(error)
            }
            self.quotaProbeInFlight = false
        }
    }

    func setQuotaHistoryDemand(_ demand: QuotaHistoryProjection?, consumer: UUID) {
        let previous = quotaHistoryConsumers.values.max()
        quotaHistoryConsumers[consumer] = demand
        let projection = quotaHistoryConsumers.values.max()
        guard previous != projection else { return }
        if projection == nil || previous == .dashboard {
            quotaHistoryTask?.cancel()
            if !quotaHistories.isEmpty { quotaHistories = [] }
        }
        reloadQuotaHistory()
    }

    private func reloadQuotaHistory() {
        guard let projection = quotaHistoryConsumers.values.max(), !quotaHistoryReadings.isEmpty else { return }
        let readings = quotaHistoryReadings
        quotaHistoryTask?.cancel()
        quotaHistoryTask = Task(priority: .utility) { [weak self, scanner] in
            do {
                let loaded = try await scanner.loadQuotaHistory(readings, projection: projection)
                guard let self, !Task.isCancelled else { return }
                if self.quotaHistories != loaded { self.quotaHistories = loaded }
                if self.quotaHistoryIssue != nil { self.quotaHistoryIssue = nil }
            } catch {
                guard !Task.isCancelled else { return }
                self?.reportQuotaHistoryError(error)
            }
        }
    }

    private func reportQuotaHistoryError(_ error: Error) {
        let issue = "额度历史暂不可用，已保留当前读数和原记录（\(error.localizedDescription)）"
        if quotaHistoryIssue != issue { quotaHistoryIssue = issue }
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
                quotaText = "Claude " + ClientQuotaPresentation.percentNumber(100 - window.usedPercent) + "%"
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
