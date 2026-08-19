import Foundation

enum CodexUsagePreciseDataUnavailableReason: Equatable {
    case noTokenJSONLFiles
    case noTokenEvents
}

struct CodexUsagePreciseDataUnavailableError: LocalizedError {
    let reason: CodexUsagePreciseDataUnavailableReason
    let path: String

    var errorDescription: String? {
        switch reason {
        case .noTokenJSONLFiles:
            return "未发现 token JSONL 文件：\(path)"
        case .noTokenEvents:
            return "token JSONL 中没有可用 token_count 事件：\(path)"
        }
    }
}

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
        try load(onNumericPhase: nil, onProgress: nil)
    }

    func load(
        onNumericPhase: (@Sendable (DashboardSnapshot) -> Void)?
    ) throws -> DashboardSnapshot {
        try load(onNumericPhase: onNumericPhase, onProgress: nil)
    }

    func load(
        onNumericPhase: (@Sendable (DashboardSnapshot) -> Void)?,
        onProgress: (@Sendable (PreciseIndexProgress) -> Void)?
    ) throws -> DashboardSnapshot {
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.load", metadata: [
            "source": dataSource.displayPath
        ])
        do {
            let preciseSnapshot = try loadFromTokenCountJSONL(
                onNumericPhase: onNumericPhase,
                onProgress: onProgress
            )
            trace?.end("precise", metadata: [
                "tokens": String(preciseSnapshot.stats.totalTokens),
                "calls": String(preciseSnapshot.stats.totalCalls)
            ])
            return preciseSnapshot
        } catch let error as CodexUsagePreciseDataUnavailableError {
            // A Home with no token JSONL (or only replay/no-op records) is the
            // one intentional fallback boundary.  Do not broaden this catch:
            // index ownership, migration, SQLite, and parser failures must
            // remain visible to the store's last-good/transient recovery path.
            trace?.mark("precise.unavailable.fallbackStateSQLite", metadata: [
                "reason": String(describing: error.reason)
            ])
        } catch let error as CodexUsageHistoryIndexError {
            trace?.end("precise-index-failed", metadata: ["error": error.localizedDescription])
            throw error
        } catch let error as CodexUsageDiscoveryError {
            trace?.end("discovery-failed", metadata: ["error": error.localizedDescription])
            throw error
        } catch {
            // An unexpected precise-path failure is not evidence that the
            // selected Home lacks token history.  Preserve the error as an
            // index failure so CodexUsageStore retains last-good data and can
            // schedule its bounded transient retry when appropriate.
            let wrapped = CodexUsageHistoryIndexError(
                operation: "读取精确索引",
                underlying: error
            )
            trace?.end("precise-index-failed", metadata: [
                "error": wrapped.localizedDescription
            ])
            throw wrapped
        }
        let snapshot = try loadFromStateSQLite()
        trace?.end("stateSQLite", metadata: [
            "tokens": String(snapshot.stats.totalTokens),
            "threads": String(snapshot.stats.totalThreads)
        ])
        return snapshot
    }

    func loadFastSnapshot() throws -> DashboardSnapshot {
        try loadFastSnapshotResult().snapshot
    }

    func loadFastSnapshotResult() throws -> DashboardFastSnapshotResult {
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.loadFastSnapshot", metadata: [
            "source": dataSource.displayPath
        ])
        do {
            if let cachedPreciseSnapshot = try cachedPreciseSnapshot() {
                trace?.end("precise-cache", metadata: [
                    "tokens": String(cachedPreciseSnapshot.snapshot.stats.totalTokens),
                    "threads": String(cachedPreciseSnapshot.snapshot.stats.totalThreads),
                    "freshness": String(describing: cachedPreciseSnapshot.freshness)
                ])
                return cachedPreciseSnapshot
            }
            let snapshot = try loadFromStateSQLite(includeTimeSeries: false)
            trace?.end("ok", metadata: [
                "tokens": String(snapshot.stats.totalTokens),
                "threads": String(snapshot.stats.totalThreads)
            ])
            return DashboardFastSnapshotResult(
                snapshot: snapshot,
                freshness: .unavailable
            )
        } catch {
            trace?.end("failed", metadata: ["error": error.localizedDescription])
            throw error
        }
    }

    struct CompactUsageSummary: Equatable {
        let totalTokens: Int
        let todayTokens: Int
        let todayCalls: Int
        let todayModelBreakdowns: [ModelTokenBreakdown]
        let generatedAt: Date
        let homeIdentity: String?
        let coverageKind: DashboardSnapshotCoverageKind
        let observedThrough: Date?
        let settledThrough: Date?
        let exactGeneration: Int64?

        init(
            totalTokens: Int,
            todayTokens: Int,
            todayCalls: Int,
            todayModelBreakdowns: [ModelTokenBreakdown] = [],
            generatedAt: Date,
            homeIdentity: String? = nil,
            coverageKind: DashboardSnapshotCoverageKind = .summary,
            observedThrough: Date? = nil,
            settledThrough: Date? = nil,
            exactGeneration: Int64? = nil
        ) {
            self.totalTokens = totalTokens
            self.todayTokens = todayTokens
            self.todayCalls = todayCalls
            self.todayModelBreakdowns = todayModelBreakdowns
            self.generatedAt = generatedAt
            self.homeIdentity = homeIdentity
            self.coverageKind = coverageKind
            self.observedThrough = observedThrough
            self.settledThrough = settledThrough
            self.exactGeneration = exactGeneration
        }
    }

    // 紧凑 surface 的轻量刷新：同步索引（增量）后只跑轻量聚合 SQL，
    // 不重放历史事件、不构建时间序列/排行/摘录，也不写 snapshot 缓存。
    // 无 token JSONL 文件时返回 nil，调用方回退全量路径。
    func loadCompactSummary() throws -> CompactUsageSummary? {
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.compactSummary", metadata: [
            "source": dataSource.displayPath
        ])
        do {
            let sessionFiles = try usageJSONLFiles()
            guard !sessionFiles.isEmpty else {
                trace?.end("no-token-jsonl-files")
                return nil
            }
            let historyIndex = try CodexUsageHistoryIndex(codexHome: dataSource.codexHome)
            let synchronization = try historyIndex.synchronize(
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
            let now = Date()
            let todayStart = calendar.startOfDay(for: now)
            guard let tomorrowStart = calendar.date(
                byAdding: .day,
                value: 1,
                to: todayStart
            ) else {
                throw CodexUsageDiscoveryError.traversalFailed(
                    path: dataSource.displayPath,
                    reason: "无法计算下一自然日边界"
                )
            }
            let totals = try historyIndex.compactTotals(
                todayStart: todayStart,
                before: tomorrowStart
            )
            let normalizedTodayModelBreakdowns = ModelUsagePresentation.rows(
                from: totals.todayModelBreakdowns,
                at: Date()
            )
            let summaryGeneratedAt = Date()
            let summary = CompactUsageSummary(
                totalTokens: totals.totalTokens,
                todayTokens: totals.todayTokens,
                todayCalls: totals.todayCalls,
                todayModelBreakdowns: normalizedTodayModelBreakdowns,
                generatedAt: summaryGeneratedAt,
                homeIdentity: dataSource.stableIdentityKey,
                coverageKind: .summary,
                observedThrough: summaryGeneratedAt,
                exactGeneration: synchronization.attributionGeneration
            )
            trace?.end("ok", metadata: [
                "tokens": String(summary.totalTokens)
            ])
            return summary
        } catch {
            trace?.end("failed", metadata: ["error": error.localizedDescription])
            throw error
        }
    }

    private func cachedPreciseSnapshot() throws -> DashboardFastSnapshotResult? {
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
        if let inMemory = Self.sessionEventCache.snapshot(
            for: dataSource.codexHome.path,
            signature: signature
        ) {
            return DashboardFastSnapshotResult(
                snapshot: inMemory,
                freshness: .current
            )
        }
        guard let persistent = Self.sessionEventCache.persistentExactSnapshot(
            for: dataSource.codexHome.path,
            homeIdentityKey: dataSource.stableIdentityKey,
            signature: signature,
            attributionState: attributionState
        ) else {
            return nil
        }
        return DashboardFastSnapshotResult(
            snapshot: persistent.snapshot,
            freshness: persistent.freshness
        )
    }

    private func loadFromTokenCountJSONL(
        onNumericPhase: (@Sendable (DashboardSnapshot) -> Void)? = nil,
        onProgress: (@Sendable (PreciseIndexProgress) -> Void)? = nil
    ) throws -> DashboardSnapshot {
        // Discovery and pure in-memory derivation do not need the index write
        // gate. `CodexUsageHistoryIndex.synchronize` owns the short writer
        // section, while its read methods use WAL snapshots. Excerpt hydration
        // remains outside both boundaries.
        let prepared: PreparedPreciseLoad
        do {
            prepared = try loadFromTokenCountJSONLExclusively(onProgress: onProgress)
        } catch let error as CodexUsagePreciseDataUnavailableError {
            throw error
        } catch let error as CodexUsageHistoryIndexError {
            throw error
        } catch let error as CodexUsageDiscoveryError {
            throw error
        } catch {
            // The exclusive gate itself can fail before an index object exists
            // (most notably cross-process owner contention).  Classify that
            // boundary exactly like errors raised inside the index so callers
            // never silently fall back to the metadata-only state database.
            throw CodexUsageHistoryIndexError(
                operation: "获取精确索引所有权",
                underlying: error
            )
        }
        switch prepared {
        case let .complete(snapshot):
            return snapshot
        case let .numeric(phase):
            // The numeric file is already atomically replaced before this
            // callback. Publishing outside the exact-index gate lets a new
            // append refresh acquire the gate immediately.
            onNumericPhase?(phase.snapshot)
            guard !Task.isCancelled else { return phase.snapshot }

            let detailTrace = RefreshPerformanceProbe.begin(
                "usageAnalyzer.hydrateTurnExcerpts",
                metadata: [
                    "generation": String(phase.signature.attributionGeneration),
                    "turns": String(phase.cacheUsage.turns.count)
                ]
            )
            Self.runDetailHydrationHookForTesting(root: dataSource.codexHome.path)
            guard !Task.isCancelled else {
                detailTrace?.end("cancelled-before-hydration")
                return phase.snapshot
            }
            let hydratedCacheUsage = hydratingTurnExcerpts(
                in: phase.cacheUsage,
                from: phase.historyIndex
            )
            guard !Task.isCancelled else {
                detailTrace?.end("cancelled-after-hydration")
                return phase.snapshot
            }

            let finalSnapshot = DashboardSnapshot(
                stats: phase.snapshot.stats,
                dailyUsage: phase.snapshot.dailyUsage,
                recentBins: phase.snapshot.recentBins,
                hourlyUsage: phase.snapshot.hourlyUsage,
                pluginUsage: phase.snapshot.pluginUsage,
                cacheUsage: hydratedCacheUsage,
                coverageKind: .full,
                homeIdentity: dataSource.stableIdentityKey,
                observedThrough: phase.snapshot.observedThrough,
                settledThrough: phase.snapshot.settledThrough,
                exactGeneration: phase.snapshot.exactGeneration,
                preciseTimeSeriesGeneratedAt: phase.preciseCoverageAt,
                generatedAt: Date()
            )

            // A concurrent numeric owner may have advanced the source tree or
            // generation while this detail phase was reading excerpts. Only a
            // still-exact completion can become the in-memory detail receipt or
            // replace the durable numeric last-good file.
            let stored = (try? {
                let currentState = try phase.historyIndex.attributionState()
                guard currentState.provenanceEpoch
                        == phase.signature.attributionProvenanceEpoch,
                      currentState.generation
                        == phase.signature.attributionGeneration else {
                    return false
                }
                Self.sessionEventCache.recordSnapshotBuildForTesting()
                Self.sessionEventCache.storeSnapshot(
                    finalSnapshot,
                    for: dataSource.codexHome.path,
                    homeIdentityKey: dataSource.stableIdentityKey,
                    signature: phase.signature
                )
                return true
            }()) ?? false
            guard stored else {
                detailTrace?.end("superseded")
                return phase.snapshot
            }
            detailTrace?.end("complete", metadata: [
                "sessions": String(hydratedCacheUsage.sessions.count),
                "turns": String(hydratedCacheUsage.turns.count)
            ])
            return finalSnapshot
        }
    }

    private struct PreparedNumericPhase {
        let snapshot: DashboardSnapshot
        let cacheUsage: TokenCacheUsage
        let historyIndex: CodexUsageHistoryIndex
        let signature: SessionTreeSignature
        let preciseCoverageAt: Date
    }

    private enum PreparedPreciseLoad {
        case complete(DashboardSnapshot)
        case numeric(PreparedNumericPhase)
    }

    private func loadFromTokenCountJSONLExclusively(
        onProgress: (@Sendable (PreciseIndexProgress) -> Void)? = nil
    ) throws -> PreparedPreciseLoad {
        let trace = RefreshPerformanceProbe.begin("usageAnalyzer.preciseJSONL", metadata: [
            "sessionsRoot": dataSource.sessionsRoot.path
        ])
        trace?.mark("jsonlFiles.begin")
        let sessionFiles = try usageJSONLFiles()
        trace?.mark("jsonlFiles.end", metadata: ["count": String(sessionFiles.count)])
        onProgress?(PreciseIndexProgress(
            phase: .preparing,
            message: "已发现 \(sessionFiles.count) 个会话文件，准备建立精确索引",
            completed: 0,
            total: sessionFiles.count
        ))
        guard !sessionFiles.isEmpty else {
            trace?.end("missing-token-jsonl-files")
            throw CodexUsagePreciseDataUnavailableError(
                reason: .noTokenJSONLFiles,
                path: dataSource.displayPath
            )
        }
        let preciseCoverageAt = Date()
        let historyIndex: CodexUsageHistoryIndex
        let initialAttributionState: CodexUsageHistoryIndex.AttributionState
        do {
            historyIndex = try CodexUsageHistoryIndex(
                codexHome: dataSource.codexHome,
                onProgress: onProgress
            )
            initialAttributionState = try historyIndex.attributionState()
        } catch {
            throw CodexUsageHistoryIndexError(operation: "打开或升级精确索引", underlying: error)
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
                dailyModelBreakdowns: cached.cacheUsage.dailyModelBreakdowns,
                daily: cached.cacheUsage.daily,
                hourly: cached.cacheUsage.hourly,
                recentBins: cached.cacheUsage.recentBins,
                sessions: cached.cacheUsage.sessions,
                turns: cached.cacheUsage.turns,
                attributionEvents: cached.cacheUsage.attributionEvents,
                attributionEventsComplete: true,
                attributionModelBucketsComplete: true,
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
            return .complete(DashboardSnapshot(
                stats: cached.stats,
                dailyUsage: cached.dailyUsage,
                recentBins: cached.recentBins,
                hourlyUsage: cached.hourlyUsage,
                pluginUsage: cached.pluginUsage,
                cacheUsage: stableCacheUsage,
                homeIdentity: dataSource.stableIdentityKey,
                coverageKind: .full,
                observedThrough: preciseCoverageAt,
                settledThrough: cached.settledThrough
                    ?? cached.preciseTimeSeriesGeneratedAt,
                exactGeneration: initialAttributionState.generation,
                preciseTimeSeriesGeneratedAt: preciseCoverageAt,
                generatedAt: Date()
            ))
        }
        trace?.mark("snapshot-cache-miss")

        let settledThrough = UsageRefreshCadencePolicy.latestEligibleBoundary(
            now: preciseCoverageAt
        )
        // Builder bins are keyed by their start. Anchor just inside the last
        // closed bucket so the still-open bucket is left for the next aggregate
        // cycle while summary totals can still reflect the latest exact index.
        let aggregationNow = settledThrough.addingTimeInterval(-0.001)
        var aggregation = UsageAggregationBuilder(calendar: calendar, now: aggregationNow)
        trace?.mark("threadMetadata.begin")
        let stateRefresh = loadStateRefreshSnapshot()
        let metadata = stateRefresh.metadata
        trace?.mark("threadMetadata.end", metadata: ["plugins": String(metadata.plugins.count)])

        trace?.mark("parseSessions.begin")
        let synchronization: CodexUsageHistoryIndex.SynchronizationResult
        let durableAttributionEvents: [TokenCacheAttributionEvent]
        let firstAggregatedEventAt: Date?
        let exactSessionCount: Int
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
            } onProgress: { completed, total, phase in
                let message: String
                switch phase {
                case .scanning:
                    message = "正在扫描精确历史 \(completed)/\(total)"
                case .backfillingModel:
                    message = "正在补齐历史模型 \(completed)/\(total)；首次升级可能需要几分钟，原始数据不会丢失"
                case .publishing:
                    message = "正在提交索引升级结果"
                default:
                    message = "正在升级精确索引"
                }
                onProgress?(PreciseIndexProgress(
                    phase: phase,
                    message: message,
                    completed: completed,
                    total: total
                ))
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

            let aggregateReadStart = aggregation.aggregateReadStart
                ?? aggregationNow
            try historyIndex.forEachAggregatedUsageRow(from: aggregateReadStart) { row in
                aggregation.consumeAggregate(row)
            }
            try historyIndex.forEachAggregatedSessionRow { row in
                aggregation.consumeSessionAggregate(row)
            }
            for turn in try historyIndex.boundedTurnCandidates() {
                aggregation.considerTurnCandidate(turn)
            }
            exactSessionCount = try historyIndex.aggregatedSessionCount()
            firstAggregatedEventAt = try historyIndex.firstAggregatedEventAt()
        } catch {
            throw CodexUsageHistoryIndexError(operation: "同步或查询", underlying: error)
        }
        trace?.mark("parseSessions.end", metadata: [
            "events": String(aggregation.totalEventCount),
            "sessionsWithEvents": String(aggregation.totalSessionCount)
        ])
        guard aggregation.totalEventCount > 0 else {
            trace?.end("no-token-events")
            throw CodexUsagePreciseDataUnavailableError(
                reason: .noTokenEvents,
                path: "\(dataSource.displayPath)/sessions"
            )
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
        let officialSummary = stateRefresh.officialSummary
        trace?.mark("officialSummary.end", metadata: [
            "hasSummary": officialSummary == nil ? "0" : "1"
        ])
        trace?.mark("threadInfo.begin")
        let threadInfo = stateRefresh.threadInfo
        trace?.mark("threadInfo.end", metadata: ["count": String(threadInfo.count)])
        trace?.mark("cacheUsage.begin")
        let attributionCurrentScanUnsafeCauseDetected =
            synchronization.rewrittenFiles > 0
                || synchronization.lineageAmbiguityDetected
        let aggregatedCacheUsage = aggregation.cacheUsage(
            recentBins: recentBins,
            threadInfo: threadInfo,
            attributionProvenanceEpoch: synchronization.provenanceEpoch,
            attributionGeneration: synchronization.attributionGeneration,
            attributionUnsafeSinceGeneration:
                synchronization.attributionUnsafeSinceGeneration,
            attributionCurrentScanUnsafeCauseDetected:
                attributionCurrentScanUnsafeCauseDetected,
            attributionSourceMutationDetected:
                synchronization.attributionSourceMutationDetected,
            durableAttributionEvents: durableAttributionEvents
        )
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
            totalThreads: officialSummary?.totalThreads ?? exactSessionCount,
            mostUsedReasoning: metadata.reasoning,
            skillsExplored: metadata.plugins.filter { $0.name.hasPrefix("$") }.count,
            totalSkillsUsed: metadata.plugins.count,
            totalInputTokens: aggregatedCacheUsage.total.inputTokens,
            totalCachedInputTokens: aggregatedCacheUsage.total.cachedInputTokens,
            totalOutputTokens: aggregatedCacheUsage.total.outputTokens,
            firstUsageAt: firstAggregatedEventAt ?? aggregation.firstEventAt
        )
        trace?.mark("stats.end", metadata: [
            "tokens": String(totalTokens),
            "peakThread": String(peakThreadTokens)
        ])

        // Publish only the numeric projection at this boundary. It becomes the
        // durable numeric last-good value, but never the in-memory completion
        // receipt used to skip detail hydration.
        let numericCacheUsage = TokenCacheUsage(
            total: aggregatedCacheUsage.total,
            modelBreakdowns: aggregatedCacheUsage.modelBreakdowns,
            dailyModelBreakdowns: aggregatedCacheUsage.dailyModelBreakdowns,
            daily: aggregatedCacheUsage.daily,
            hourly: aggregatedCacheUsage.hourly,
            recentBins: aggregatedCacheUsage.recentBins,
            sessions: [],
            turns: [],
            // `aggregatedCacheUsage` has already read exact 5-minute
            // source/model buckets from the index. Keep that compact exact
            // projection available even when turn excerpts are superseded.
            attributionEvents: aggregatedCacheUsage.attributionEvents,
            attributionEventsComplete: false,
            attributionModelBucketsComplete:
                aggregatedCacheUsage.attributionModelBucketsComplete
                && !aggregatedCacheUsage.attributionCurrentScanUnsafeCauseDetected,
            attributionProvenanceEpoch:
                aggregatedCacheUsage.attributionProvenanceEpoch,
            attributionGeneration: aggregatedCacheUsage.attributionGeneration,
            attributionUnsafeSinceGeneration:
                aggregatedCacheUsage.attributionUnsafeSinceGeneration,
            attributionCurrentScanUnsafeCauseDetected:
                aggregatedCacheUsage.attributionCurrentScanUnsafeCauseDetected,
            attributionSourceMutationDetected:
                aggregatedCacheUsage.attributionSourceMutationDetected
        )
        let numericSnapshot = DashboardSnapshot(
            stats: stats,
            dailyUsage: daily,
            recentBins: recentBins,
            hourlyUsage: hourlyUsage,
            pluginUsage: metadata.plugins,
            cacheUsage: numericCacheUsage,
            usagePrecision: .precise,
            homeIdentity: dataSource.stableIdentityKey,
            coverageKind: .settled,
            observedThrough: preciseCoverageAt,
            settledThrough: settledThrough,
            exactGeneration: synchronization.attributionGeneration,
            // Numeric time-series coverage is complete at this boundary.
            // Event-level attribution/detail readiness remains represented by
            // `attributionEventsComplete` and is intentionally independent.
            preciseTimeSeriesGeneratedAt: settledThrough,
            generatedAt: Date()
        )
        let synchronizedSignature = signature.withAttributionState(
            provenanceEpoch: synchronization.provenanceEpoch,
            generation: synchronization.attributionGeneration
        )
        try historyIndex.markDashboardAggregatePublished(
            exactGeneration: synchronization.attributionGeneration,
            settledThrough: settledThrough
        )
        trace?.mark("numericPhase.persist.begin")
        Self.sessionEventCache.storeNumericSnapshot(
            numericSnapshot,
            for: dataSource.codexHome.path,
            homeIdentityKey: dataSource.stableIdentityKey,
            signature: synchronizedSignature
        )
        trace?.mark("numericPhase.persist.end", metadata: [
            "tokens": String(numericSnapshot.stats.totalTokens),
            "calls": String(numericSnapshot.stats.totalCalls)
        ])
        trace?.end("numeric-ready", metadata: [
            "tokens": String(totalTokens),
            "calls": String(aggregation.totalCalls)
        ])
        return .numeric(PreparedNumericPhase(
            snapshot: numericSnapshot,
            cacheUsage: aggregatedCacheUsage,
            historyIndex: historyIndex,
            signature: synchronizedSignature,
            preciseCoverageAt: settledThrough
        ))
    }
}
