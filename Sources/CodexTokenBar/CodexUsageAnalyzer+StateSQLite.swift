import Foundation

extension CodexUsageAnalyzer {
    struct StateRefreshSnapshot {
        let metadata: (plugins: [PluginUsage], reasoning: String)
        let officialSummary: OfficialThreadSummary?
        let threadInfo: [String: ThreadInfo]
    }

    /// One precise refresh opens `state_5.sqlite` once and derives every
    /// read-only thread projection from the same row set.  This prevents the
    /// metadata, official-count and detail paths from observing three
    /// different WAL moments or paying three open/prepare cycles.
    func loadStateRefreshSnapshot() -> StateRefreshSnapshot {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db),
              let rows = try? sqliteRows(
                db: db,
                sql: """
                SELECT
                    id,
                    title,
                    first_user_message,
                    preview,
                    reasoning_effort,
                    COALESCE(updated_at_ms, updated_at)
                FROM threads
                ORDER BY COALESCE(updated_at_ms, updated_at) DESC;
                """
              ) else {
            return StateRefreshSnapshot(
                metadata: ([], "未知"),
                officialSummary: nil,
                threadInfo: [:]
            )
        }

        var pluginCounts: [String: Int] = [:]
        var reasoningCounts: [String: Int] = [:]
        var info: [String: ThreadInfo] = [:]
        for (index, row) in rows.enumerated() {
            if index < 500 {
                let text = [row[safe: 1], row[safe: 2], row[safe: 3]]
                    .compactMap { $0 }
                    .joined(separator: " ")
                collectPluginMentions(from: text, into: &pluginCounts)
                collectReasoningEffort(row[safe: 4], into: &reasoningCounts)
            }
            guard let id = row[safe: 0], !id.isEmpty else { continue }
            let title = firstNonEmpty([
                row[safe: 1],
                row[safe: 2],
                row[safe: 3],
            ]) ?? "Untitled"
            info[id] = ThreadInfo(
                title: title,
                updatedAt: parseThreadTimestamp(row[safe: 5])
            )
        }
        let pluginItems: [PluginUsage] = pluginCounts.map { entry in
            PluginUsage(name: entry.key, runs: entry.value)
        }
        let sortedPlugins = pluginItems.sorted { lhs, rhs in
            if lhs.runs == rhs.runs {
                return lhs.name < rhs.name
            }
            return lhs.runs > rhs.runs
        }
        let plugins = Array(sortedPlugins.prefix(8))
        let reasoning = reasoningCounts.max(by: { $0.value < $1.value })
            .map { "\($0.key) · \($0.value)" } ?? "未知"
        return StateRefreshSnapshot(
            metadata: (plugins, reasoning),
            officialSummary: OfficialThreadSummary(
                totalTokens: 0,
                peakThreadTokens: 0,
                totalThreads: rows.count
            ),
            threadInfo: info
        )
    }

    func loadFromStateSQLite(
        includeTimeSeries: Bool = true,
        usagePrecision: DashboardUsagePrecision = .metadataOnly
    ) throws -> DashboardSnapshot {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db) else {
            throw NSError(domain: "CodexTokenBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(dataSource.displayPath)/state_5.sqlite not found"])
        }

        let summaryRows = try sqliteRows(
            db: db,
            sql: """
            SELECT COUNT(*) AS total_threads
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

        let daily: [DayUsage] = []
        let recentBins: [BinUsage] = []
        let hourlyUsage: [BinUsage] = []

        var pluginCounts: [String: Int] = [:]
        var reasoningCounts: [String: Int] = [:]
        for row in titleRows {
            let text = [row[safe: 0], row[safe: 1], row[safe: 2]]
                .compactMap { $0 }
                .joined(separator: " ")
            collectPluginMentions(from: text, into: &pluginCounts)
            collectReasoningEffort(row[safe: 3], into: &reasoningCounts)
        }

        let totalTokens = 0
        let totalThreads = Int(summaryRows.first?[safe: 0] ?? "0") ?? 0
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
            peakThreadTokens: 0,
            currentStreakDays: 0,
            longestStreakDays: longestStreakDays(from: daily),
            totalCalls: recentBins.reduce(0) { $0 + $1.calls },
            totalThreads: totalThreads,
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
            usagePrecision: usagePrecision,
            generatedAt: Date(),
            lastCheckedAt: Date(),
            // state_5.sqlite is only a metadata fallback here. It does not
            // prove that token data changed, so do not manufacture a data
            // timestamp from the check time.
            dataUpdatedAt: nil,
            homeIdentity: dataSource.stableIdentityKey,
            coverageKind: .summary,
            observedThrough: Date()
        )
    }

    func loadOfficialThreadSummary() -> OfficialThreadSummary? {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db),
              let row = try? sqliteRows(
                db: db,
                sql: """
                SELECT COUNT(*) AS total_threads
                FROM threads;
                """
              ).first else {
            return nil
        }

        return OfficialThreadSummary(
            totalTokens: 0,
            peakThreadTokens: 0,
            totalThreads: Int(row[safe: 0] ?? "0") ?? 0
        )
    }

    private func sqliteRows(db: String, sql: String) throws -> [[String]] {
        try SQLiteReadRecovery.run {
            let driver = SQLiteDatabaseDriver(
                url: URL(fileURLWithPath: db),
                readOnly: true,
                createsFileIfMissing: false,
                busyTimeoutMilliseconds: 3_000,
                enableWAL: false,
                consistency: .externallyOwnedWAL
            )
            return try driver.readRows(sql) { statement in
                (0..<statement.columnCount).map { column in
                    statement.text(column) ?? ""
                }
            }
        }
    }

    func loadThreadMetadata() -> (plugins: [PluginUsage], reasoning: String) {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db),
              let rows = try? sqliteRows(
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

    func loadThreadInfo() -> [String: ThreadInfo] {
        let db = dataSource.stateDatabase.path
        guard fileManager.fileExists(atPath: db),
              let rows = try? sqliteRows(
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

    private func parseThreadTimestamp(_ value: String?) -> Date? {
        guard let raw = value, let number = Double(raw) else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
}
