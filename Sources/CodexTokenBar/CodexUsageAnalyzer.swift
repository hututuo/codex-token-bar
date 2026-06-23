import Foundation

final class CodexUsageAnalyzer {
    let fileManager = FileManager.default
    let calendar = Calendar.current
    let dataSource: CodexDataSource
    let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    let plainDateFormatter: ISO8601DateFormatter = {
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

        let sessionFiles = jsonlFiles(under: sessionsRoot)
        let signature = sessionTreeSignature(for: sessionFiles)
        if let cached = Self.sessionEventCache.snapshot(for: dataSource.codexHome.path, signature: signature) {
            return DashboardSnapshot(
                stats: cached.stats,
                dailyUsage: cached.dailyUsage,
                recentBins: cached.recentBins,
                hourlyUsage: cached.hourlyUsage,
                pluginUsage: cached.pluginUsage,
                cacheUsage: cached.cacheUsage,
                generatedAt: Date()
            )
        }

        var events: [TokenEvent] = []
        var sessionIDsWithEvents = Set<String>()
        let metadata = loadThreadMetadata()

        for file in sessionFiles {
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
            mostUsedReasoning: metadata.reasoning,
            skillsExplored: metadata.plugins.filter { $0.name.hasPrefix("$") }.count,
            totalSkillsUsed: metadata.plugins.count
        )

        let snapshot = DashboardSnapshot(
            stats: stats,
            dailyUsage: daily,
            recentBins: recentBins,
            hourlyUsage: hourlyUsage,
            pluginUsage: metadata.plugins,
            cacheUsage: cacheUsage,
            generatedAt: Date()
        )
        Self.sessionEventCache.recordSnapshotBuildForTesting()
        Self.sessionEventCache.storeSnapshot(snapshot, for: dataSource.codexHome.path, signature: signature)
        Self.sessionEventCache.flushPersistentCache()
        return snapshot
    }
}
