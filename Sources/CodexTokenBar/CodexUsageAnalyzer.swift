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
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.load", metadata: [
            "source": dataSource.displayPath
        ])
        do {
            let preciseSnapshot = try loadFromTokenCountJSONL()
            trace?.end("precise", metadata: [
                "tokens": String(preciseSnapshot.stats.totalTokens),
                "calls": String(preciseSnapshot.stats.totalCalls)
            ])
            return preciseSnapshot
        } catch let error as CodexUsageDiscoveryError {
            trace?.end("discovery-failed", metadata: ["error": error.localizedDescription])
            throw error
        } catch {
            trace?.mark("precise.failed.fallbackStateSQLite", metadata: [
                "error": error.localizedDescription
            ])
        }
        let snapshot = try loadFromStateSQLite()
        trace?.end("stateSQLite", metadata: [
            "tokens": String(snapshot.stats.totalTokens),
            "threads": String(snapshot.stats.totalThreads)
        ])
        return snapshot
    }

    func loadFastSnapshot() throws -> DashboardSnapshot {
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.loadFastSnapshot", metadata: [
            "source": dataSource.displayPath
        ])
        do {
            if let cachedPreciseSnapshot = try cachedPreciseSnapshot() {
                trace?.end("precise-cache", metadata: [
                    "tokens": String(cachedPreciseSnapshot.stats.totalTokens),
                    "threads": String(cachedPreciseSnapshot.stats.totalThreads)
                ])
                return cachedPreciseSnapshot
            }
            let snapshot = try loadFromStateSQLite(includeTimeSeries: false)
            trace?.end("ok", metadata: [
                "tokens": String(snapshot.stats.totalTokens),
                "threads": String(snapshot.stats.totalThreads)
            ])
            return snapshot
        } catch {
            trace?.end("failed", metadata: ["error": error.localizedDescription])
            throw error
        }
    }

    private func cachedPreciseSnapshot() throws -> DashboardSnapshot? {
        let sessionFiles = try usageJSONLFiles()
        guard !sessionFiles.isEmpty else {
            return nil
        }
        let signature = sessionTreeSignature(for: sessionFiles)
        return Self.sessionEventCache.snapshot(for: dataSource.codexHome.path, signature: signature)
    }

    private func loadFromTokenCountJSONL() throws -> DashboardSnapshot {
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.preciseJSONL", metadata: [
            "sessionsRoot": dataSource.sessionsRoot.path
        ])
        trace?.mark("jsonlFiles.begin")
        let sessionFiles = try usageJSONLFiles()
        trace?.mark("jsonlFiles.end", metadata: ["count": String(sessionFiles.count)])
        guard !sessionFiles.isEmpty else {
            trace?.end("missing-token-jsonl-files")
            throw NSError(domain: "CodexTokenBar", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(dataSource.displayPath) has no token JSONL files"])
        }
        trace?.mark("signature.begin")
        let signature = sessionTreeSignature(for: sessionFiles)
        trace?.mark("signature.end", metadata: [
            "files": String(signature.files.count),
            "hasStateDB": signature.stateDatabase == nil ? "0" : "1"
        ])
        if let cached = Self.sessionEventCache.snapshot(for: dataSource.codexHome.path, signature: signature) {
            trace?.end("snapshot-cache-hit", metadata: [
                "tokens": String(cached.stats.totalTokens),
                "calls": String(cached.stats.totalCalls)
            ])
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
        trace?.mark("snapshot-cache-miss")
        trace?.mark("retainOnly.begin")
        Self.sessionEventCache.retainOnly(paths: Set(sessionFiles.map { $0.resolvingSymlinksInPath().path }))
        trace?.mark("retainOnly.end")

        var events: [TokenEvent] = []
        var sessionIDsWithEvents = Set<String>()
        trace?.mark("threadMetadata.begin")
        let metadata = loadThreadMetadata()
        trace?.mark("threadMetadata.end", metadata: ["plugins": String(metadata.plugins.count)])

        trace?.mark("parseSessions.begin")
        for file in sessionFiles {
            let sessionID = sessionID(from: file)
            let sessionEvents = parseSession(file: file, sessionID: sessionID)
            if !sessionEvents.isEmpty {
                sessionIDsWithEvents.insert(sessionID)
                events.append(contentsOf: sessionEvents)
            }
        }
        trace?.mark("parseSessions.end", metadata: [
            "events": String(events.count),
            "sessionsWithEvents": String(sessionIDsWithEvents.count)
        ])
        trace?.mark("flushCache.begin")
        Self.sessionEventCache.flushPersistentCache()
        trace?.mark("flushCache.end")

        guard !events.isEmpty else {
            trace?.end("no-token-events")
            throw NSError(domain: "CodexTokenBar", code: 6, userInfo: [NSLocalizedDescriptionKey: "No token_count events found in \(dataSource.displayPath)/sessions"])
        }

        trace?.mark("dailyUsage.begin")
        let daily = dailyUsage(from: events)
        trace?.mark("dailyUsage.end", metadata: ["count": String(daily.count)])
        trace?.mark("recentBins.begin")
        let recentBins = recentBins(from: events)
        trace?.mark("recentBins.end", metadata: ["count": String(recentBins.count)])
        trace?.mark("hourlyUsage.begin")
        let hourlyUsage = hourlyUsage(from: events)
        trace?.mark("hourlyUsage.end", metadata: ["count": String(hourlyUsage.count)])
        trace?.mark("officialSummary.begin")
        let officialSummary = loadOfficialThreadSummary()
        trace?.mark("officialSummary.end", metadata: [
            "hasSummary": officialSummary == nil ? "0" : "1"
        ])
        trace?.mark("threadInfo.begin")
        let threadInfo = loadThreadInfo()
        trace?.mark("threadInfo.end", metadata: ["count": String(threadInfo.count)])
        trace?.mark("cacheUsage.begin")
        let cacheUsage = cacheUsage(from: events, recentBins: recentBins, threadInfo: threadInfo)
        trace?.mark("cacheUsage.end", metadata: [
            "sessions": String(cacheUsage.sessions.count),
            "turns": String(cacheUsage.turns.count)
        ])
        let totalTokens = events.reduce(0) { $0 + $1.tokens }
        trace?.mark("stats.begin")
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
        trace?.mark("stats.end", metadata: [
            "tokens": String(totalTokens),
            "peakThread": String(peakThreadTokens)
        ])

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
        trace?.mark("storeSnapshot.begin")
        Self.sessionEventCache.storeSnapshot(snapshot, for: dataSource.codexHome.path, signature: signature)
        trace?.mark("storeSnapshot.end")
        trace?.mark("flushCacheAfterSnapshot.begin")
        Self.sessionEventCache.flushPersistentCache()
        trace?.mark("flushCacheAfterSnapshot.end")
        trace?.end("ok", metadata: [
            "tokens": String(totalTokens),
            "calls": String(events.count)
        ])
        return snapshot
    }
}
