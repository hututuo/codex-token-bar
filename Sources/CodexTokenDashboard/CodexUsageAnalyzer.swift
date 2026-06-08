import Foundation

final class CodexUsageAnalyzer {
    private struct SessionCacheKey: Equatable {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    private final class SessionEventCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: (key: SessionCacheKey, events: [TokenEvent])] = [:]

        func events(for path: String, key: SessionCacheKey) -> [TokenEvent]? {
            lock.lock()
            defer { lock.unlock() }
            guard storage[path]?.key == key else { return nil }
            return storage[path]?.events
        }

        func store(_ events: [TokenEvent], for path: String, key: SessionCacheKey) {
            lock.lock()
            storage[path] = (key, events)
            lock.unlock()
        }
    }

    private static let sessionEventCache = SessionEventCache()

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

    private func loadFromTokenCountJSONL() throws -> DashboardSnapshot {
        let sessionsRoot = dataSource.sessionsRoot
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            throw NSError(domain: "CodexTokenDashboard", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(dataSource.displayPath)/sessions not found"])
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

        guard !events.isEmpty else {
            throw NSError(domain: "CodexTokenDashboard", code: 6, userInfo: [NSLocalizedDescriptionKey: "No token_count events found in \(dataSource.displayPath)/sessions"])
        }

        let daily = dailyUsage(from: events)
        let recentBins = recentBins(from: events)
        let stats = DashboardStats(
            totalTokens: events.reduce(0) { $0 + $1.tokens },
            peakDayTokens: daily.map(\.tokens).max() ?? 0,
            longestTaskSeconds: longestSessionSeconds(from: events),
            currentStreakDays: currentStreakDays(from: daily),
            longestStreakDays: longestStreakDays(from: daily),
            totalCalls: events.count,
            totalThreads: sessionIDsWithEvents.count,
            fastModePercent: 14,
            mostUsedReasoning: metadata.reasoning,
            skillsExplored: metadata.plugins.filter { $0.name.hasPrefix("$") }.count,
            totalSkillsUsed: metadata.plugins.count
        )

        return DashboardSnapshot(
            stats: stats,
            dailyUsage: daily,
            recentBins: recentBins,
            pluginUsage: metadata.plugins,
            generatedAt: Date()
        )
    }

    private func loadFromStateSQLite() throws -> DashboardSnapshot {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db) else {
            throw NSError(domain: "CodexTokenDashboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(dataSource.displayPath)/state_5.sqlite not found"])
        }

        let dayRows = try sqliteRows(
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

        let binRows = try sqliteRows(
            db: db,
            sql: """
            SELECT CAST((COALESCE(updated_at_ms, updated_at)/1000) / 1800 AS INTEGER) * 1800 AS bin_epoch,
                   SUM(tokens_used) AS tokens,
                   COUNT(*) AS threads
            FROM threads
            WHERE COALESCE(updated_at_ms, updated_at)/1000 >= strftime('%s','now','-24 hours')
            GROUP BY bin_epoch
            ORDER BY bin_epoch;
            """
        )

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
            throw NSError(domain: "CodexTokenDashboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to calculate date range"])
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
            throw NSError(domain: "CodexTokenDashboard", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to calculate recent range"])
        }
        let interval: TimeInterval = 30 * 60
        var binMap: [Int: (tokens: Int, calls: Int)] = [:]
        for row in binRows {
            guard let epoch = Int(row[safe: 0] ?? "") else { continue }
            binMap[epoch] = (
                Int(row[safe: 1] ?? "0") ?? 0,
                Int(row[safe: 2] ?? "0") ?? 0
            )
        }

        let recentBins = (0..<48).map { index -> BinUsage in
            let date = recentStart.addingTimeInterval(Double(index) * interval)
            let epoch = Int(floor(date.timeIntervalSince1970 / interval) * interval)
            let usage = binMap[epoch] ?? (0, 0)
            return BinUsage(start: date, tokens: usage.tokens, calls: usage.calls)
        }

        var pluginCounts: [String: Int] = [:]
        var reasoningCounts: [String: Int] = [:]
        for row in titleRows {
            let text = row.joined(separator: " ")
            collectPluginMentions(from: text, into: &pluginCounts)
            collectReasoning(from: text, into: &reasoningCounts)
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
            longestTaskSeconds: longestTaskSeconds(from: daily),
            currentStreakDays: currentStreakDays(from: daily),
            longestStreakDays: longestStreakDays(from: daily),
            totalCalls: recentBins.reduce(0) { $0 + $1.calls },
            totalThreads: totalThreads,
            fastModePercent: 14,
            mostUsedReasoning: reasoningCounts.max(by: { $0.value < $1.value }).map { "\($0.key) · \($0.value)" } ?? "未知",
            skillsExplored: pluginCounts.keys.filter { $0.hasPrefix("$") }.count,
            totalSkillsUsed: pluginCounts.count
        )

        return DashboardSnapshot(
            stats: stats,
            dailyUsage: daily,
            recentBins: recentBins,
            pluginUsage: Array(plugins),
            generatedAt: Date()
        )
    }

    private func sqliteRows(db: String, sql: String) throws -> [[String]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "\t", db, sql]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
            throw NSError(domain: "CodexTokenDashboard", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
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
            let text = row.joined(separator: " ")
            collectPluginMentions(from: text, into: &pluginCounts)
            collectReasoning(from: text, into: &reasoningCounts)
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
        streamTokenCountLines(from: file) { lineString in
            guard lineString.contains("\"total_token_usage\""),
                  let timestampString = extractString(after: "\"timestamp\":\"", in: lineString),
                  let timestamp = parseDate(timestampString) else {
                return
            }

            let totalTokens = extractInt(after: "\"total_token_usage\":", marker: "\"total_tokens\":", in: lineString)
            let lastTokens = extractInt(after: "\"last_token_usage\":", marker: "\"total_tokens\":", in: lineString)
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
                timestamp: timestamp,
                sessionID: sessionID,
                tokens: delta,
                inputTokens: extractInt(after: "\"last_token_usage\":", marker: "\"input_tokens\":", in: lineString) ?? 0,
                cachedInputTokens: extractInt(after: "\"last_token_usage\":", marker: "\"cached_input_tokens\":", in: lineString) ?? 0,
                outputTokens: extractInt(after: "\"last_token_usage\":", marker: "\"output_tokens\":", in: lineString) ?? 0,
                reasoningOutputTokens: extractInt(after: "\"last_token_usage\":", marker: "\"reasoning_output_tokens\":", in: lineString) ?? 0
            ))
        }

        if let cacheKey {
            Self.sessionEventCache.store(events, for: file.path, key: cacheKey)
        }

        return events
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

    private func extractInt(after scopeMarker: String, marker: String, in text: String) -> Int? {
        guard let scopeRange = text.range(of: scopeMarker) else { return nil }
        let scoped = text[scopeRange.upperBound...]
        guard let markerRange = scoped.range(of: marker) else { return nil }
        var digits = ""
        for character in scoped[markerRange.upperBound...] {
            if character.isNumber {
                digits.append(character)
            } else {
                break
            }
        }
        return Int(digits)
    }

    private func streamTokenCountLines(from file: URL, handleLine: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        var pending = Data()
        let newline = Data([0x0A])
        let tokenNeedle = Data(#""token_count""#.utf8)

        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            pending.append(data)

            var searchStart = pending.startIndex
            while let newlineRange = pending[searchStart...].range(of: newline) {
                let lineRange = searchStart..<newlineRange.lowerBound
                if pending[lineRange].range(of: tokenNeedle) != nil {
                    let lineData = pending[lineRange]
                    handleLine(String(decoding: lineData, as: UTF8.self))
                }
                searchStart = newlineRange.upperBound
            }

            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
            }
        }

        if !pending.isEmpty, pending.range(of: tokenNeedle) != nil {
            handleLine(String(decoding: pending, as: UTF8.self))
        }
    }

    private func collectPluginMentions(from text: String, into counts: inout [String: Int]) {
        let candidates = ["@documents", "@spreadsheets", "@presentations", "@browser", "@chrome", "$paper-spine", "$paper-spine-translate-en", "$nature-reader", "$nature-figure"]
        for candidate in candidates where text.contains(candidate) {
            counts[candidate, default: 0] += 1
        }
    }

    private func collectReasoning(from text: String, into counts: inout [String: Int]) {
        if text.contains("reasoning_effort") || text.contains("effort") {
            if text.contains("high") {
                counts["高", default: 0] += 1
            } else if text.contains("medium") {
                counts["中", default: 0] += 1
            } else if text.contains("low") {
                counts["低", default: 0] += 1
            }
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
        let interval: TimeInterval = 30 * 60
        var grouped: [Date: (tokens: Int, calls: Int)] = [:]

        for event in events where event.timestamp >= start && event.timestamp <= end {
            let offset = floor(event.timestamp.timeIntervalSince(start) / interval)
            let bin = start.addingTimeInterval(offset * interval)
            let current = grouped[bin] ?? (0, 0)
            grouped[bin] = (current.tokens + event.tokens, current.calls + 1)
        }

        return (0..<48).map { index in
            let bin = start.addingTimeInterval(Double(index) * interval)
            let usage = grouped[bin] ?? (0, 0)
            return BinUsage(start: bin, tokens: usage.tokens, calls: usage.calls)
        }
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

    private func longestTaskSeconds(from daily: [DayUsage]) -> Int {
        let maxCalls = daily.map(\.calls).max() ?? 0
        return max(0, maxCalls * 42)
    }

    private func longestSessionSeconds(from events: [TokenEvent]) -> Int {
        var ranges: [String: (first: Date, last: Date)] = [:]
        for event in events {
            if let current = ranges[event.sessionID] {
                ranges[event.sessionID] = (
                    min(current.first, event.timestamp),
                    max(current.last, event.timestamp)
                )
            } else {
                ranges[event.sessionID] = (event.timestamp, event.timestamp)
            }
        }

        return ranges.values
            .map { max(0, Int($0.last.timeIntervalSince($0.first))) }
            .max() ?? 0
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return plainDateFormatter.date(from: value)
    }
}
