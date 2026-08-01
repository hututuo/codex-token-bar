import Foundation

final class CodexUsageAnalyzer: @unchecked Sendable {
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

    /// Clears a durable exact-index attribution safety marker only after the
    /// caller has committed the corresponding synthetic cutover. Epoch and
    /// generation matching make stale acknowledgements harmless.
    @discardableResult
    func acknowledgeAttributionSafety(
        provenanceEpoch: String,
        throughGeneration: Int64
    ) throws -> Bool {
        let historyIndex = try CodexUsageHistoryIndex(codexHome: dataSource.codexHome)
        return try historyIndex.acknowledgeAttributionSafety(
            provenanceEpoch: provenanceEpoch,
            throughGeneration: throughGeneration
        )
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
        } catch let error as CodexUsageHistoryIndexError {
            trace?.end("precise-index-failed", metadata: ["error": error.localizedDescription])
            throw error
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

    struct CompactUsageSummary: Equatable {
        let totalTokens: Int
        let todayTokens: Int
        let todayCalls: Int
        let generatedAt: Date
    }

    // 紧凑 surface 的轻量刷新：同步索引（增量）后只跑三条 SUM SQL，
    // 不重放历史事件、不构建时间序列/排行/摘录，也不写 snapshot 缓存。
    // 无 token JSONL 文件时返回 nil，调用方回退全量路径。
    func loadCompactSummary() throws -> CompactUsageSummary? {
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.compactSummary", metadata: [
            "source": dataSource.displayPath
        ])
        do {
            let summary = try CodexUsageHistoryIndex.withExclusiveAccess(
                codexHome: dataSource.codexHome
            ) { () -> CompactUsageSummary? in
                let sessionFiles = try usageJSONLFiles()
                guard !sessionFiles.isEmpty else { return nil }
                let historyIndex = try CodexUsageHistoryIndex(codexHome: dataSource.codexHome)
                _ = try historyIndex.synchronize(
                    files: sessionFiles,
                    sessionID: sessionID(from:)
                ) { [self] file, sessionID, request, insertFingerprint, emit in
                    try parseSessionIntoHistoryIndex(
                        file: file,
                        sessionID: sessionID,
                        request: request,
                        insertFingerprint: insertFingerprint,
                        emit: emit
                    )
                }
                let totals = try historyIndex.compactTotals(
                    todayStart: calendar.startOfDay(for: Date())
                )
                return CompactUsageSummary(
                    totalTokens: totals.totalTokens,
                    todayTokens: totals.todayTokens,
                    todayCalls: totals.todayCalls,
                    generatedAt: Date()
                )
            }
            trace?.end(summary == nil ? "no-token-jsonl-files" : "ok", metadata: [
                "tokens": summary.map { String($0.totalTokens) } ?? "-"
            ])
            return summary
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
        let historyIndex = try CodexUsageHistoryIndex(codexHome: dataSource.codexHome)
        let attributionState = try historyIndex.attributionState()
        let signature = sessionTreeSignature(
            for: sessionFiles,
            attributionProvenanceEpoch: attributionState.provenanceEpoch,
            attributionGeneration: attributionState.generation
        )
        return Self.sessionEventCache.snapshot(for: dataSource.codexHome.path, signature: signature)
    }

    private func loadFromTokenCountJSONL() throws -> DashboardSnapshot {
        // Keep discovery, generation synchronization, event aggregation, excerpt lookup, and
        // snapshot publication in one per-index scope. Releasing between synchronize and the
        // reads would let another refresh delete or replace the generation being aggregated.
        try CodexUsageHistoryIndex.withExclusiveAccess(codexHome: dataSource.codexHome) {
            try loadFromTokenCountJSONLExclusively()
        }
    }

    private func loadFromTokenCountJSONLExclusively() throws -> DashboardSnapshot {
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
        let preciseCoverageAt = Date()
        let historyIndex: CodexUsageHistoryIndex
        let initialAttributionState: CodexUsageHistoryIndex.AttributionState
        do {
            historyIndex = try CodexUsageHistoryIndex(codexHome: dataSource.codexHome)
            initialAttributionState = try historyIndex.attributionState()
        } catch {
            throw CodexUsageHistoryIndexError(operation: "读取归因代次", underlying: error)
        }
        trace?.mark("signature.begin")
        let signature = sessionTreeSignature(
            for: sessionFiles,
            attributionProvenanceEpoch: initialAttributionState.provenanceEpoch,
            attributionGeneration: initialAttributionState.generation
        )
        trace?.mark("signature.end", metadata: [
            "files": String(signature.files.count),
            "hasStateDB": signature.stateDatabase == nil ? "0" : "1",
            "attributionGeneration": String(signature.attributionGeneration)
        ])
        if !initialAttributionState.currentScanUnsafeCauseDetected,
           let cached = Self.sessionEventCache.snapshot(for: dataSource.codexHome.path, signature: signature),
           cached.cacheUsage.attributionEventsComplete {
            trace?.end("snapshot-cache-hit", metadata: [
                "tokens": String(cached.stats.totalTokens),
                "calls": String(cached.stats.totalCalls)
            ])
            let stableCacheUsage = TokenCacheUsage(
                total: cached.cacheUsage.total,
                modelBreakdowns: cached.cacheUsage.modelBreakdowns,
                daily: cached.cacheUsage.daily,
                hourly: cached.cacheUsage.hourly,
                recentBins: cached.cacheUsage.recentBins,
                sessions: cached.cacheUsage.sessions,
                turns: cached.cacheUsage.turns,
                attributionEvents: cached.cacheUsage.attributionEvents,
                attributionEventsComplete: true,
                attributionProvenanceEpoch: cached.cacheUsage.attributionProvenanceEpoch,
                attributionGeneration: initialAttributionState.generation,
                attributionUnsafeSinceGeneration:
                    initialAttributionState.unsafeSinceGeneration,
                attributionCurrentScanUnsafeCauseDetected:
                    initialAttributionState.currentScanUnsafeCauseDetected,
                // Unsafe provenance is durable index state, not a one-refresh
                // pulse. Keep emitting it on cache hits until the segment
                // cutover has been durably acknowledged.
                attributionSourceMutationDetected:
                    initialAttributionState.requiresSyntheticCutover
            )
            return DashboardSnapshot(
                stats: cached.stats,
                dailyUsage: cached.dailyUsage,
                recentBins: cached.recentBins,
                hourlyUsage: cached.hourlyUsage,
                pluginUsage: cached.pluginUsage,
                cacheUsage: stableCacheUsage,
                preciseTimeSeriesGeneratedAt: preciseCoverageAt,
                generatedAt: Date()
            )
        }
        trace?.mark("snapshot-cache-miss")

        let aggregationNow = preciseCoverageAt
        var aggregation = UsageAggregationBuilder(calendar: calendar, now: aggregationNow)
        trace?.mark("threadMetadata.begin")
        let metadata = loadThreadMetadata()
        trace?.mark("threadMetadata.end", metadata: ["plugins": String(metadata.plugins.count)])

        trace?.mark("parseSessions.begin")
        let synchronization: CodexUsageHistoryIndex.SynchronizationResult
        let durableAttributionEvents: [TokenCacheAttributionEvent]
        do {
            synchronization = try historyIndex.synchronize(
                files: sessionFiles,
                sessionID: sessionID(from:)
            ) { [self] file, sessionID, request, insertFingerprint, emit in
                try parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: sessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }
            trace?.mark("historyIndex.synchronized", metadata: [
                "changedFiles": String(synchronization.changedFiles),
                "unchangedFiles": String(synchronization.unchangedFiles),
                "indexedEvents": String(synchronization.indexedEvents),
                "incrementalFiles": String(synchronization.incrementallyParsedFiles)
            ])
            for _ in 0..<(synchronization.changedFiles - synchronization.incrementallyParsedFiles) {
                Self.sessionEventCache.recordFullSessionParseForTesting()
            }
            for _ in 0..<synchronization.incrementallyParsedFiles {
                Self.sessionEventCache.recordIncrementalSessionParseForTesting()
            }

            if let attributionStart = aggregation.attributionCoverageStart,
               let attributionEnd = aggregation.attributionCoverageEnd {
                durableAttributionEvents = try historyIndex.attributionSourceBuckets(
                    provenanceEpoch: synchronization.provenanceEpoch,
                    from: attributionStart,
                    before: attributionEnd
                )
            } else {
                durableAttributionEvents = []
            }

            var currentSessionID: String?
            var turnIndexInSession = 0
            try historyIndex.forEachStoredEvent { stored in
                if currentSessionID == stored.event.sessionID {
                    turnIndexInSession += 1
                } else {
                    currentSessionID = stored.event.sessionID
                    turnIndexInSession = 1
                }
                aggregation.consume(
                    stored.event,
                    stableID: stored.stableID,
                    attributionSourceID: String(stored.sourceID),
                    turnIndexInSession: turnIndexInSession
                )
            }
        } catch {
            throw CodexUsageHistoryIndexError(operation: "同步或查询", underlying: error)
        }
        trace?.mark("parseSessions.end", metadata: [
            "events": String(aggregation.totalEventCount),
            "sessionsWithEvents": String(aggregation.totalSessionCount)
        ])
        guard aggregation.totalEventCount > 0 else {
            trace?.end("no-token-events")
            throw NSError(domain: "CodexTokenBar", code: 6, userInfo: [NSLocalizedDescriptionKey: "No token_count events found in \(dataSource.displayPath)/sessions"])
        }

        trace?.mark("dailyUsage.begin")
        let daily = aggregation.dailyUsage()
        trace?.mark("dailyUsage.end", metadata: ["count": String(daily.count)])
        trace?.mark("recentBins.begin")
        let recentBins = aggregation.recentBins()
        trace?.mark("recentBins.end", metadata: ["count": String(recentBins.count)])
        trace?.mark("hourlyUsage.begin")
        let hourlyUsage = aggregation.hourlyUsage()
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
        let cacheUsage = hydratingTurnExcerpts(
            in: aggregation.cacheUsage(
                recentBins: recentBins,
                threadInfo: threadInfo,
                attributionProvenanceEpoch: synchronization.provenanceEpoch,
                attributionGeneration: synchronization.attributionGeneration,
                attributionUnsafeSinceGeneration:
                    synchronization.attributionUnsafeSinceGeneration,
                attributionCurrentScanUnsafeCauseDetected:
                    synchronization.rewrittenFiles > 0
                        || synchronization.lineageAmbiguityDetected,
                attributionSourceMutationDetected:
                    synchronization.attributionSourceMutationDetected,
                durableAttributionEvents: durableAttributionEvents
            ),
            from: historyIndex
        )
        trace?.mark("cacheUsage.end", metadata: [
            "sessions": String(cacheUsage.sessions.count),
            "turns": String(cacheUsage.turns.count)
        ])
        let totalTokens = aggregation.totalTokens
        trace?.mark("stats.begin")
        let peakThreadTokens = aggregation.peakSessionTokens
        let stats = DashboardStats(
            totalTokens: totalTokens,
            peakDayTokens: daily.map(\.tokens).max() ?? 0,
            peakThreadTokens: peakThreadTokens,
            currentStreakDays: currentStreakDays(
                from: daily,
                now: aggregationNow,
                calendar: calendar
            ),
            longestStreakDays: longestStreakDays(from: daily),
            totalCalls: aggregation.totalCalls,
            totalThreads: officialSummary?.totalThreads ?? aggregation.totalSessionCount,
            mostUsedReasoning: metadata.reasoning,
            skillsExplored: metadata.plugins.filter { $0.name.hasPrefix("$") }.count,
            totalSkillsUsed: metadata.plugins.count,
            totalInputTokens: cacheUsage.total.inputTokens,
            totalCachedInputTokens: cacheUsage.total.cachedInputTokens,
            totalOutputTokens: cacheUsage.total.outputTokens,
            firstUsageAt: aggregation.firstEventAt
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
            preciseTimeSeriesGeneratedAt: preciseCoverageAt,
            generatedAt: Date()
        )
        Self.sessionEventCache.recordSnapshotBuildForTesting()
        trace?.mark("storeSnapshot.begin")
        let synchronizedSignature = signature.withAttributionState(
            provenanceEpoch: synchronization.provenanceEpoch,
            generation: synchronization.attributionGeneration
        )
        Self.sessionEventCache.storeSnapshot(
            snapshot,
            for: dataSource.codexHome.path,
            signature: synchronizedSignature
        )
        trace?.mark("storeSnapshot.end")
        trace?.end("ok", metadata: [
            "tokens": String(totalTokens),
            "calls": String(aggregation.totalCalls)
        ])
        return snapshot
    }
}
