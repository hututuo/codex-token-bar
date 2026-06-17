import Foundation

final class CodexUsageAnalyzer {
    private struct SessionCacheKey: Equatable {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    private final class SessionEventCache: @unchecked Sendable {
        private static let persistentCacheVersion = 4

        private struct PersistentCache: Codable {
            let version: Int
            let entries: [PersistentEntry]
        }

        private struct PersistentEntry: Codable {
            let path: String
            let size: UInt64
            let modifiedAt: TimeInterval
            let events: [PersistentEvent]
        }

        private struct PersistentEvent: Codable {
            let timestamp: TimeInterval
            let sessionID: String
            let tokens: Int
            let inputTokens: Int
            let cachedInputTokens: Int
            let outputTokens: Int
            let reasoningOutputTokens: Int
            let userPrompt: String
            let assistantResponse: String
        }

        private let lock = NSLock()
        private var storage: [String: (key: SessionCacheKey, events: [TokenEvent])] = [:]
        private var didLoadPersistentCache = false
        private var isDirty = false

        func events(for path: String, key: SessionCacheKey) -> [TokenEvent]? {
            loadPersistentCacheIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            guard storage[path]?.key == key else { return nil }
            return storage[path]?.events
        }

        func store(_ events: [TokenEvent], for path: String, key: SessionCacheKey) {
            loadPersistentCacheIfNeeded()
            lock.lock()
            storage[path] = (key, events)
            isDirty = true
            lock.unlock()
        }

        func flushPersistentCache() {
            lock.lock()
            if CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled {
                isDirty = false
                lock.unlock()
                return
            }
            guard isDirty else {
                lock.unlock()
                return
            }
            let entries = storage.map { path, value in
                PersistentEntry(
                    path: path,
                    size: value.key.size,
                    modifiedAt: value.key.modifiedAt,
                    events: value.events.map { event in
                        PersistentEvent(
                            timestamp: event.timestamp.timeIntervalSince1970,
                            sessionID: event.sessionID,
                            tokens: event.tokens,
                            inputTokens: event.inputTokens,
                            cachedInputTokens: event.cachedInputTokens,
                            outputTokens: event.outputTokens,
                            reasoningOutputTokens: event.reasoningOutputTokens,
                            userPrompt: event.userPrompt,
                            assistantResponse: event.assistantResponse
                        )
                    }
                )
            }
            isDirty = false
            lock.unlock()

            guard let cacheURL = Self.cacheURL else { return }
            do {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let cache = PersistentCache(version: Self.persistentCacheVersion, entries: entries)
                let data = try JSONEncoder().encode(cache)
                try data.write(to: cacheURL, options: [.atomic])
            } catch {
                // The in-memory cache is still valid; a disk-cache miss should never block the dashboard.
            }
        }

        private func loadPersistentCacheIfNeeded() {
            lock.lock()
            if didLoadPersistentCache {
                lock.unlock()
                return
            }
            defer {
                didLoadPersistentCache = true
                lock.unlock()
            }

            guard !CodexUsageAnalyzer.isPersistentSessionEventCacheDisabled else {
                return
            }

            guard let cacheURL = Self.readableCacheURL,
                  let data = try? Data(contentsOf: cacheURL),
                  let cache = try? JSONDecoder().decode(PersistentCache.self, from: data),
                  cache.version == Self.persistentCacheVersion else {
                return
            }

            var loaded: [String: (key: SessionCacheKey, events: [TokenEvent])] = [:]
            for entry in cache.entries {
                let key = SessionCacheKey(path: entry.path, size: entry.size, modifiedAt: entry.modifiedAt)
                loaded[entry.path] = (
                    key,
                    entry.events.map { event in
                        TokenEvent(
                            timestamp: Date(timeIntervalSince1970: event.timestamp),
                            sessionID: event.sessionID,
                            tokens: event.tokens,
                            inputTokens: event.inputTokens,
                            cachedInputTokens: event.cachedInputTokens,
                            outputTokens: event.outputTokens,
                            reasoningOutputTokens: event.reasoningOutputTokens,
                            userPrompt: event.userPrompt,
                            assistantResponse: event.assistantResponse
                        )
                    }
                )
            }

            for (path, value) in loaded where storage[path] == nil {
                storage[path] = value
            }
        }

        private static var cacheURL: URL? {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("CodexTokenBar", isDirectory: true)
                .appendingPathComponent("session-token-events-v4.json")
        }

        private static var legacyCacheURL: URL? {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("CodexTokenBar", isDirectory: true)
                .appendingPathComponent("session-token-events-v3.json")
        }

        private static var readableCacheURL: URL? {
            guard let cacheURL else { return legacyCacheURL }
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                return cacheURL
            }
            return legacyCacheURL ?? cacheURL
        }
    }

    private static let sessionEventCache = SessionEventCache()
    private static var isPersistentSessionEventCacheDisabled: Bool {
        ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE"] == "1"
    }

    private struct OfficialThreadSummary {
        let totalTokens: Int
        let peakThreadTokens: Int
        let totalThreads: Int
    }

    private struct ThreadInfo {
        let title: String
        let updatedAt: Date?
    }

    private struct ParsedTokenUsage {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
        let totalTokens: Int
    }

    private struct ParsedTokenUsageLine {
        let timestamp: Date
        let total: ParsedTokenUsage?
        let last: ParsedTokenUsage?
    }

    private struct TokenCacheAccumulator {
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var reasoningOutputTokens = 0
        var totalTokens = 0
        var calls = 0

        mutating func add(_ event: TokenEvent) {
            inputTokens += event.inputTokens
            cachedInputTokens += min(event.cachedInputTokens, event.inputTokens)
            outputTokens += event.outputTokens
            reasoningOutputTokens += event.reasoningOutputTokens
            totalTokens += event.tokens
            calls += 1
        }

        var breakdown: TokenCacheBreakdown {
            TokenCacheBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                totalTokens: totalTokens,
                calls: calls
            )
        }
    }

    private let fileManager = FileManager.default
    private let calendar = Calendar.current
    private let dataSource: CodexDataSource
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(dataSource: CodexDataSource) {
        self.dataSource = dataSource
    }

    func load() throws -> DashboardSnapshot {
        if let preciseSnapshot = try? loadFromTokenCountJSONL() {
            return preciseSnapshot
        }
        return try loadFromStateSQLite()
    }

    func loadFastSnapshot() throws -> DashboardSnapshot {
        try loadFromStateSQLite(includeTimeSeries: false)
    }

    private func loadFromTokenCountJSONL() throws -> DashboardSnapshot {
        let sessionsRoot = dataSource.sessionsRoot
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            throw NSError(domain: "CodexTokenBar", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(dataSource.displayPath)/sessions not found"])
        }

        var events: [TokenEvent] = []
        var sessionIDsWithEvents = Set<String>()
        let metadata = loadThreadMetadata()

        for file in jsonlFiles(under: sessionsRoot) {
            let sessionID = sessionID(from: file)
            let sessionEvents = parseSession(file: file, sessionID: sessionID)
            if !sessionEvents.isEmpty {
                sessionIDsWithEvents.insert(sessionID)
                events.append(contentsOf: sessionEvents)
            }
        }
        Self.sessionEventCache.flushPersistentCache()

        guard !events.isEmpty else {
            throw NSError(domain: "CodexTokenBar", code: 6, userInfo: [NSLocalizedDescriptionKey: "No token_count events found in \(dataSource.displayPath)/sessions"])
        }

        let daily = dailyUsage(from: events)
        let recentBins = recentBins(from: events)
        let hourlyUsage = hourlyUsage(from: events)
        let officialSummary = loadOfficialThreadSummary()
        let cacheUsage = cacheUsage(from: events, recentBins: recentBins, threadInfo: loadThreadInfo())
        let totalTokens = events.reduce(0) { $0 + $1.tokens }
        let peakThreadTokens = peakSessionTokens(from: events)
        let stats = DashboardStats(
            totalTokens: totalTokens,
            peakDayTokens: daily.map(\.tokens).max() ?? 0,
            peakThreadTokens: peakThreadTokens,
            currentStreakDays: currentStreakDays(from: daily),
            longestStreakDays: longestStreakDays(from: daily),
            totalCalls: events.count,
            totalThreads: officialSummary?.totalThreads ?? sessionIDsWithEvents.count,
            fastModePercent: 0,
            mostUsedReasoning: metadata.reasoning,
            skillsExplored: metadata.plugins.filter { $0.name.hasPrefix("$") }.count,
            totalSkillsUsed: metadata.plugins.count
        )

        return DashboardSnapshot(
            stats: stats,
            dailyUsage: daily,
            recentBins: recentBins,
            hourlyUsage: hourlyUsage,
            pluginUsage: metadata.plugins,
            cacheUsage: cacheUsage,
            generatedAt: Date()
        )
    }

    private func loadFromStateSQLite(includeTimeSeries: Bool = true) throws -> DashboardSnapshot {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db) else {
            throw NSError(domain: "CodexTokenBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(dataSource.displayPath)/state_5.sqlite not found"])
        }

        let dayRows = includeTimeSeries
            ? try sqliteRows(
                db: db,
                sql: """
                SELECT strftime('%Y-%m-%d', COALESCE(updated_at_ms, updated_at)/1000, 'unixepoch', 'localtime') AS day,
                       SUM(tokens_used) AS tokens,
                       COUNT(*) AS threads
                FROM threads
                GROUP BY day
                ORDER BY day;
                """
            )
            : []

        let binRows = includeTimeSeries
            ? try sqliteRows(
                db: db,
                sql: """
                SELECT CAST((COALESCE(updated_at_ms, updated_at)/1000) / 300 AS INTEGER) * 300 AS bin_epoch,
                       SUM(tokens_used) AS tokens,
                       COUNT(*) AS threads
                FROM threads
                WHERE COALESCE(updated_at_ms, updated_at)/1000 >= strftime('%s','now','-24 hours')
                GROUP BY bin_epoch
                ORDER BY bin_epoch;
                """
            )
            : []

        let hourlyRows = includeTimeSeries
            ? try sqliteRows(
                db: db,
                sql: """
                SELECT CAST((COALESCE(updated_at_ms, updated_at)/1000) / 3600 AS INTEGER) * 3600 AS hour_epoch,
                       SUM(tokens_used) AS tokens,
                       COUNT(*) AS threads
                FROM threads
                WHERE COALESCE(updated_at_ms, updated_at)/1000 >= strftime('%s','now','-30 days')
                GROUP BY hour_epoch
                ORDER BY hour_epoch;
                """
            )
            : []

        let summaryRows = try sqliteRows(
            db: db,
            sql: """
            SELECT SUM(tokens_used) AS total_tokens,
                   MAX(tokens_used) AS peak_thread_tokens,
                   COUNT(*) AS total_threads
            FROM threads;
            """
        )

        let titleRows = try sqliteRows(
            db: db,
            sql: """
            SELECT substr(title, 1, 240), substr(first_user_message, 1, 360), substr(preview, 1, 360), reasoning_effort
            FROM threads
            ORDER BY COALESCE(updated_at_ms, updated_at) DESC
            LIMIT 400;
            """
        )

        let today = calendar.startOfDay(for: Date())
        guard let startDay = calendar.date(byAdding: .day, value: -364, to: today) else {
            throw NSError(domain: "CodexTokenBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to calculate date range"])
        }

        var dailyMap: [Date: (tokens: Int, calls: Int)] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for row in dayRows {
            guard let dayText = row[safe: 0],
                  let date = dayFormatter.date(from: dayText) else { continue }
            dailyMap[calendar.startOfDay(for: date)] = (
                Int(row[safe: 1] ?? "0") ?? 0,
                Int(row[safe: 2] ?? "0") ?? 0
            )
        }

        let daily = (0..<365).compactMap { offset -> DayUsage? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            let usage = dailyMap[calendar.startOfDay(for: date)] ?? (0, 0)
            return DayUsage(date: date, tokens: usage.tokens, calls: usage.calls)
        }

        let now = Date()
        guard let recentStart = calendar.date(byAdding: .hour, value: -24, to: now) else {
            throw NSError(domain: "CodexTokenBar", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to calculate recent range"])
        }
        let interval: TimeInterval = 5 * 60
        var binMap: [Int: (tokens: Int, calls: Int)] = [:]
        for row in binRows {
            guard let epoch = Int(row[safe: 0] ?? "") else { continue }
            binMap[epoch] = (
                Int(row[safe: 1] ?? "0") ?? 0,
                Int(row[safe: 2] ?? "0") ?? 0
            )
        }

        let recentBins = (0..<288).map { index -> BinUsage in
            let date = recentStart.addingTimeInterval(Double(index) * interval)
            let epoch = Int(floor(date.timeIntervalSince1970 / interval) * interval)
            let usage = binMap[epoch] ?? (0, 0)
            return BinUsage(start: date, tokens: usage.tokens, calls: usage.calls)
        }

        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let hourlyStart = calendar.date(byAdding: .hour, value: -719, to: currentHour) ?? currentHour
        var hourlyMap: [Int: (tokens: Int, calls: Int)] = [:]
        for row in hourlyRows {
            guard let epoch = Int(row[safe: 0] ?? "") else { continue }
            hourlyMap[epoch] = (
                Int(row[safe: 1] ?? "0") ?? 0,
                Int(row[safe: 2] ?? "0") ?? 0
            )
        }
        let hourlyUsage = (0..<720).map { index -> BinUsage in
            let date = hourlyStart.addingTimeInterval(Double(index) * 3600)
            let epoch = Int(floor(date.timeIntervalSince1970 / 3600) * 3600)
            let usage = hourlyMap[epoch] ?? (0, 0)
            return BinUsage(start: date, tokens: usage.tokens, calls: usage.calls)
        }

        var pluginCounts: [String: Int] = [:]
        var reasoningCounts: [String: Int] = [:]
        for row in titleRows {
            let text = [row[safe: 0], row[safe: 1], row[safe: 2]]
                .compactMap { $0 }
                .joined(separator: " ")
            collectPluginMentions(from: text, into: &pluginCounts)
            collectReasoningEffort(row[safe: 3], into: &reasoningCounts)
        }

        let totalTokens = Int(summaryRows.first?[safe: 0] ?? "0") ?? 0
        let totalThreads = Int(summaryRows.first?[safe: 2] ?? "0") ?? 0
        let peakDay = daily.map(\.tokens).max() ?? 0
        let pluginItems: [PluginUsage] = pluginCounts.map { key, value in
            PluginUsage(name: key, runs: value)
        }
        let sortedPlugins = pluginItems.sorted { lhs, rhs in
            lhs.runs == rhs.runs ? lhs.name < rhs.name : lhs.runs > rhs.runs
        }
        let plugins = sortedPlugins.prefix(8)

        let stats = DashboardStats(
            totalTokens: totalTokens,
            peakDayTokens: peakDay,
            peakThreadTokens: Int(summaryRows.first?[safe: 1] ?? "0") ?? 0,
            currentStreakDays: currentStreakDays(from: daily),
            longestStreakDays: longestStreakDays(from: daily),
            totalCalls: recentBins.reduce(0) { $0 + $1.calls },
            totalThreads: totalThreads,
            fastModePercent: 0,
            mostUsedReasoning: reasoningCounts.max(by: { $0.value < $1.value }).map { "\($0.key) · \($0.value)" } ?? "未知",
            skillsExplored: pluginCounts.keys.filter { $0.hasPrefix("$") }.count,
            totalSkillsUsed: pluginCounts.count
        )

        return DashboardSnapshot(
            stats: stats,
            dailyUsage: daily,
            recentBins: recentBins,
            hourlyUsage: hourlyUsage,
            pluginUsage: Array(plugins),
            cacheUsage: .empty,
            generatedAt: Date()
        )
    }

    private func loadOfficialThreadSummary() -> OfficialThreadSummary? {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db),
              let row = try? sqliteRows(
                db: db,
                sql: """
                SELECT SUM(tokens_used) AS total_tokens,
                       MAX(tokens_used) AS peak_thread_tokens,
                       COUNT(*) AS total_threads
                FROM threads;
                """
              ).first else {
            return nil
        }

        return OfficialThreadSummary(
            totalTokens: Int(row[safe: 0] ?? "0") ?? 0,
            peakThreadTokens: Int(row[safe: 1] ?? "0") ?? 0,
            totalThreads: Int(row[safe: 2] ?? "0") ?? 0
        )
    }

    private func sqliteRows(db: String, sql: String) throws -> [[String]] {
        let driver = SQLiteDatabaseDriver(
            url: URL(fileURLWithPath: db),
            readOnly: true,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: false
        )
        return try driver.readRows(sql) { statement in
            (0..<statement.columnCount).map { column in
                statement.text(column) ?? ""
            }
        }
    }

    private func loadThreadMetadata() -> (plugins: [PluginUsage], reasoning: String) {
        let db = dataSource.stateDatabase.path
        guard let rows = try? sqliteRows(
            db: db,
            sql: """
            SELECT substr(title, 1, 240), substr(first_user_message, 1, 360), substr(preview, 1, 360), reasoning_effort
            FROM threads
            ORDER BY COALESCE(updated_at_ms, updated_at) DESC
            LIMIT 500;
            """
        ) else {
            return ([], "未知")
        }

        var pluginCounts: [String: Int] = [:]
        var reasoningCounts: [String: Int] = [:]
        for row in rows {
            let text = [row[safe: 0], row[safe: 1], row[safe: 2]]
                .compactMap { $0 }
                .joined(separator: " ")
            collectPluginMentions(from: text, into: &pluginCounts)
            collectReasoningEffort(row[safe: 3], into: &reasoningCounts)
        }

        let pluginItems = pluginCounts.map { key, value in
            PluginUsage(name: key, runs: value)
        }
        let plugins = pluginItems
            .sorted { lhs, rhs in lhs.runs == rhs.runs ? lhs.name < rhs.name : lhs.runs > rhs.runs }
            .prefix(8)
        let reasoning = reasoningCounts.max(by: { $0.value < $1.value }).map { "\($0.key) · \($0.value)" } ?? "未知"
        return (Array(plugins), reasoning)
    }

    private func loadThreadInfo() -> [String: ThreadInfo] {
        let db = dataSource.stateDatabase.path
        guard let rows = try? sqliteRows(
            db: db,
            sql: """
            SELECT id, title, first_user_message, preview, COALESCE(updated_at_ms, updated_at)
            FROM threads;
            """
        ) else {
            return [:]
        }

        var info: [String: ThreadInfo] = [:]
        for row in rows {
            guard let id = row[safe: 0], !id.isEmpty else { continue }
            let title = firstNonEmpty([
                row[safe: 1],
                row[safe: 2],
                row[safe: 3]
            ]) ?? "Untitled"
            let updatedAt = parseThreadTimestamp(row[safe: 4])
            info[id] = ThreadInfo(title: title, updatedAt: updatedAt)
        }
        return info
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func jsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private func sessionID(from file: URL) -> String {
        file.deletingPathExtension().lastPathComponent.split(separator: "-").suffix(5).joined(separator: "-")
    }

    private func parseSession(file: URL, sessionID: String) -> [TokenEvent] {
        let cacheKey = sessionCacheKey(for: file)
        if let cacheKey {
            if let events = Self.sessionEventCache.events(for: file.path, key: cacheKey) {
                return events
            }
        }

        var events: [TokenEvent] = []
        var previousTotal: Int?
        var currentUserPrompt = ""
        var assistantFragments: [String] = []
        let forkReplayCutoff = forkedSessionReplayCutoff(for: file)
        streamSessionLines(from: file) { lineString in
            if let message = extractPayloadMessage(from: lineString, expectedType: "user_message") {
                currentUserPrompt = message
                assistantFragments.removeAll(keepingCapacity: true)
                return
            }

            if let message = extractPayloadMessage(from: lineString, expectedType: "agent_message") {
                assistantFragments.append(message)
                return
            }

            guard let usageLine = parseTokenUsageLine(lineString) else {
                return
            }

            if let forkReplayCutoff, usageLine.timestamp <= forkReplayCutoff {
                return
            }

            let totalTokens = usageLine.total?.totalTokens
            let lastTokens = usageLine.last?.totalTokens
            let delta: Int

            if let totalTokens {
                if let previousTotal, totalTokens >= previousTotal {
                    delta = totalTokens - previousTotal
                } else {
                    delta = lastTokens ?? totalTokens
                }
                previousTotal = totalTokens
            } else {
                delta = lastTokens ?? 0
            }

            guard delta > 0 else { return }

            events.append(TokenEvent(
                timestamp: usageLine.timestamp,
                sessionID: sessionID,
                tokens: delta,
                inputTokens: usageLine.last?.inputTokens ?? 0,
                cachedInputTokens: usageLine.last?.cachedInputTokens ?? 0,
                outputTokens: usageLine.last?.outputTokens ?? 0,
                reasoningOutputTokens: usageLine.last?.reasoningOutputTokens ?? 0,
                userPrompt: excerpt(currentUserPrompt, limit: 180),
                assistantResponse: excerpt(assistantFragments.joined(separator: " "), limit: 220)
            ))
            assistantFragments.removeAll(keepingCapacity: true)
        }

        if let cacheKey {
            Self.sessionEventCache.store(events, for: file.path, key: cacheKey)
        }

        return events
    }

    private func forkedSessionReplayCutoff(for file: URL) -> Date? {
        guard let firstLine = readFirstLinePrefix(from: file),
              firstLine.contains("\"type\":\"session_meta\""),
              firstLine.contains("\"forked_from_id\":\""),
              let timestampString = extractString(after: "\"timestamp\":\"", in: firstLine),
              let timestamp = parseDate(timestampString) else {
            return nil
        }
        return timestamp.addingTimeInterval(30)
    }

    private func extractPayloadMessage(from line: String, expectedType: String) -> String? {
        guard line.contains(#""payload""#),
              line.contains(#""type":"\#(expectedType)""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == expectedType,
              let message = payload["message"] as? String else {
            return nil
        }
        let normalized = normalizeExcerptText(message)
        return normalized.isEmpty ? nil : normalized
    }

    private func parseTokenUsageLine(_ line: String) -> ParsedTokenUsageLine? {
        guard line.contains(#""token_count""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let timestampString = object["timestamp"] as? String,
              let timestamp = parseDate(timestampString),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else {
            return nil
        }

        let total = parseTokenUsage(info["total_token_usage"] as? [String: Any])
        let last = parseTokenUsage(info["last_token_usage"] as? [String: Any])
        guard total != nil || last != nil else { return nil }
        return ParsedTokenUsageLine(timestamp: timestamp, total: total, last: last)
    }

    private func parseTokenUsage(_ raw: [String: Any]?) -> ParsedTokenUsage? {
        guard let raw,
              let totalTokens = intValue(raw["total_tokens"]) else {
            return nil
        }

        return ParsedTokenUsage(
            inputTokens: intValue(raw["input_tokens"]) ?? 0,
            cachedInputTokens: intValue(raw["cached_input_tokens"]) ?? 0,
            outputTokens: intValue(raw["output_tokens"]) ?? 0,
            reasoningOutputTokens: intValue(raw["reasoning_output_tokens"]) ?? 0,
            totalTokens: totalTokens
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private func normalizeExcerptText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func excerpt(_ value: String, limit: Int) -> String {
        let normalized = normalizeExcerptText(value)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "..."
    }

    private func sessionCacheKey(for file: URL) -> SessionCacheKey? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else { return nil }
        let size = attributes[.size] as? UInt64 ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return SessionCacheKey(path: file.path, size: size, modifiedAt: modifiedAt)
    }

    private func extractString(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let rest = text[markerRange.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func readFirstLinePrefix(from file: URL, maxBytes: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        let newline = UInt8(ascii: "\n")
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: min(16_384, maxBytes - data.count))
            if chunk.isEmpty { break }
            if let newlineIndex = chunk.firstIndex(of: newline) {
                data.append(chunk[..<newlineIndex])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func streamSessionLines(from file: URL, handleLine: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        var pending = Data()
        let newline = Data([0x0A])
        let tokenNeedle = Data(#""token_count""#.utf8)
        let userMessageNeedle = Data(#""type":"user_message""#.utf8)
        let agentMessageNeedle = Data(#""type":"agent_message""#.utf8)

        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            pending.append(data)

            var searchStart = pending.startIndex
            while let newlineRange = pending[searchStart...].range(of: newline) {
                let lineRange = searchStart..<newlineRange.lowerBound
                let lineData = pending[lineRange]
                if lineData.range(of: tokenNeedle) != nil
                    || lineData.range(of: userMessageNeedle) != nil
                    || lineData.range(of: agentMessageNeedle) != nil {
                    handleLine(String(decoding: lineData, as: UTF8.self))
                }
                searchStart = newlineRange.upperBound
            }

            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
            }
        }

        if !pending.isEmpty,
           pending.range(of: tokenNeedle) != nil
            || pending.range(of: userMessageNeedle) != nil
            || pending.range(of: agentMessageNeedle) != nil {
            handleLine(String(decoding: pending, as: UTF8.self))
        }
    }

    private func collectPluginMentions(from text: String, into counts: inout [String: Int]) {
        let candidates = ["@documents", "@spreadsheets", "@presentations", "@browser", "@chrome", "$paper-spine", "$paper-spine-translate-en", "$nature-reader", "$nature-figure"]
        for candidate in candidates where text.contains(candidate) {
            counts[candidate, default: 0] += 1
        }
    }

    private func collectReasoningEffort(_ value: String?, into counts: inout [String: Int]) {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high":
            counts["高", default: 0] += 1
        case "medium":
            counts["中", default: 0] += 1
        case "low":
            counts["低", default: 0] += 1
        default:
            return
        }
    }

    private func dailyUsage(from events: [TokenEvent]) -> [DayUsage] {
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -364, to: today) else { return [] }

        var grouped: [Date: (tokens: Int, calls: Int)] = [:]
        for event in events where event.timestamp >= start {
            let day = calendar.startOfDay(for: event.timestamp)
            let current = grouped[day] ?? (0, 0)
            grouped[day] = (current.tokens + event.tokens, current.calls + 1)
        }

        return (0..<365).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let usage = grouped[date] ?? (0, 0)
            return DayUsage(date: date, tokens: usage.tokens, calls: usage.calls)
        }
    }

    private func recentBins(from events: [TokenEvent]) -> [BinUsage] {
        let end = Date()
        guard let start = calendar.date(byAdding: .hour, value: -24, to: end) else { return [] }
        let interval: TimeInterval = 5 * 60
        var grouped: [Date: (tokens: Int, calls: Int)] = [:]

        for event in events where event.timestamp >= start && event.timestamp <= end {
            let offset = floor(event.timestamp.timeIntervalSince(start) / interval)
            let bin = start.addingTimeInterval(offset * interval)
            let current = grouped[bin] ?? (0, 0)
            grouped[bin] = (current.tokens + event.tokens, current.calls + 1)
        }

        return (0..<288).map { index in
            let bin = start.addingTimeInterval(Double(index) * interval)
            let usage = grouped[bin] ?? (0, 0)
            return BinUsage(start: bin, tokens: usage.tokens, calls: usage.calls)
        }
    }

    private func hourlyUsage(from events: [TokenEvent]) -> [BinUsage] {
        let now = Date()
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        guard let start = calendar.date(byAdding: .hour, value: -719, to: currentHour) else { return [] }
        var grouped: [Date: (tokens: Int, calls: Int)] = [:]

        for event in events where event.timestamp >= start && event.timestamp <= now {
            guard let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start else { continue }
            let current = grouped[hour] ?? (0, 0)
            grouped[hour] = (current.tokens + event.tokens, current.calls + 1)
        }

        return (0..<720).compactMap { index -> BinUsage? in
            guard let hour = calendar.date(byAdding: .hour, value: index, to: start) else { return nil }
            let usage = grouped[hour] ?? (0, 0)
            return BinUsage(start: hour, tokens: usage.tokens, calls: usage.calls)
        }
    }

    private func cacheUsage(from events: [TokenEvent], recentBins: [BinUsage], threadInfo: [String: ThreadInfo]) -> TokenCacheUsage {
        var total = TokenCacheAccumulator()
        var daily: [Date: TokenCacheAccumulator] = [:]
        var hourly: [Date: TokenCacheAccumulator] = [:]
        var recent: [Date: TokenCacheAccumulator] = [:]
        var sessions: [String: TokenCacheAccumulator] = [:]
        var sessionLastUpdated: [String: Date] = [:]
        let recentInterval: TimeInterval = 5 * 60
        let recentStart = recentBins.first?.start
        let recentEnd = recentBins.last?.start.addingTimeInterval(recentInterval)

        for event in events {
            total.add(event)

            let day = calendar.startOfDay(for: event.timestamp)
            daily[day, default: TokenCacheAccumulator()].add(event)

            if let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start {
                hourly[hour, default: TokenCacheAccumulator()].add(event)
            }

            if let recentStart, let recentEnd,
               event.timestamp >= recentStart,
               event.timestamp <= recentEnd {
                let offset = floor(event.timestamp.timeIntervalSince(recentStart) / recentInterval)
                let bin = recentStart.addingTimeInterval(offset * recentInterval)
                recent[bin, default: TokenCacheAccumulator()].add(event)
            }

            sessions[event.sessionID, default: TokenCacheAccumulator()].add(event)
            if let current = sessionLastUpdated[event.sessionID] {
                sessionLastUpdated[event.sessionID] = max(current, event.timestamp)
            } else {
                sessionLastUpdated[event.sessionID] = event.timestamp
            }
        }

        let dailyBuckets = daily
            .map { date, accumulator in
                TokenCacheBucket(start: date, breakdown: accumulator.breakdown)
            }
            .sorted { $0.start < $1.start }

        let hourlyBuckets = hourly
            .map { date, accumulator in
                TokenCacheBucket(start: date, breakdown: accumulator.breakdown)
            }
            .sorted { $0.start < $1.start }

        let recentBuckets = recentBins.map { bin in
            TokenCacheBucket(start: bin.start, breakdown: (recent[bin.start] ?? TokenCacheAccumulator()).breakdown)
        }

        let sessionItems = sessions.map { sessionID, accumulator in
            let info = threadInfo[sessionID]
            return SessionCacheUsage(
                id: sessionID,
                title: info?.title ?? sessionID,
                lastUpdated: info?.updatedAt ?? sessionLastUpdated[sessionID],
                breakdown: accumulator.breakdown
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.lastUpdated, rhs.lastUpdated) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.breakdown.totalTokens > rhs.breakdown.totalTokens
            }
        }

        let orderedEvents = events.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }
        var turnIndexBySession: [String: Int] = [:]
        let turnItems = orderedEvents.map { index, event in
            let turnIndex = (turnIndexBySession[event.sessionID] ?? 0) + 1
            turnIndexBySession[event.sessionID] = turnIndex
            let info = threadInfo[event.sessionID]
            let breakdown = TokenCacheBreakdown(
                inputTokens: event.inputTokens,
                cachedInputTokens: min(event.cachedInputTokens, event.inputTokens),
                outputTokens: event.outputTokens,
                reasoningOutputTokens: event.reasoningOutputTokens,
                totalTokens: event.tokens,
                calls: 1
            )
            return TurnCacheUsage(
                id: "\(event.sessionID)-\(Int(event.timestamp.timeIntervalSince1970))-\(index)",
                sessionID: event.sessionID,
                sessionTitle: info?.title ?? event.sessionID,
                timestamp: event.timestamp,
                turnIndexInSession: turnIndex,
                userPrompt: event.userPrompt,
                assistantResponse: event.assistantResponse,
                breakdown: breakdown
            )
        }
        .sorted { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }

        return TokenCacheUsage(
            total: total.breakdown,
            daily: dailyBuckets,
            hourly: hourlyBuckets,
            recentBins: recentBuckets,
            sessions: sessionItems,
            turns: turnItems
        )
    }

    private func currentStreakDays(from daily: [DayUsage]) -> Int {
        var streak = 0
        for day in daily.reversed() {
            if day.tokens > 0 {
                streak += 1
            } else if streak > 0 {
                break
            }
        }
        return streak
    }

    private func longestStreakDays(from daily: [DayUsage]) -> Int {
        var best = 0
        var current = 0
        for day in daily {
            if day.tokens > 0 {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    private func peakSessionTokens(from events: [TokenEvent]) -> Int {
        var totals: [String: Int] = [:]
        for event in events {
            totals[event.sessionID, default: 0] += event.tokens
        }

        return totals.values.max() ?? 0
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return plainDateFormatter.date(from: value)
    }

    private func parseThreadTimestamp(_ value: String?) -> Date? {
        guard let raw = value, let number = Double(raw) else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
}
