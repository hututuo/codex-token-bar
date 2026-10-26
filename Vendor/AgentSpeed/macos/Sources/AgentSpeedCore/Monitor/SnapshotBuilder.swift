import Foundation

/// Facts about the roots and files that the engine does not know.
struct SnapshotContext: Sendable {
    struct SourceInfo: Sendable {
        var enabled: Bool
        var rootPath: String
        var available: Bool
        var sessionCount: Int
        var configuredModes: ExecutionModes = .empty
    }

    var sources: [SourceKind: SourceInfo]
    var warnings: [MonitorWarning]
    var todayStartMs: Int64

    init(sources: [SourceKind: SourceInfo], warnings: [MonitorWarning] = [], todayStartMs: Int64) {
        self.sources = sources
        self.warnings = warnings
        self.todayStartMs = todayStartMs
    }

    init(session: TranscriptSession, todayStartMs: Int64) {
        let counts = session.sessionCounts(todayStartMs: todayStartMs)
        var sources: [SourceKind: SourceInfo] = [:]
        for kind in SourceKind.allCases {
            let enabled = session.enabledSources.contains(kind)
            if let family = TranscriptFamily(kind) {
                let root = session.root(for: family)
                sources[kind] = SourceInfo(enabled: enabled, rootPath: root.path, available: root.detected, sessionCount: counts[kind] ?? 0)
            } else if kind == .opencode {
                let location = session.opencodeLocation
                sources[kind] = SourceInfo(enabled: enabled, rootPath: location.path, available: location.available, sessionCount: counts[kind] ?? 0)
            } else if kind == .zcode {
                let location = session.zcodeLocation
                sources[kind] = SourceInfo(enabled: enabled, rootPath: location.path, available: location.available, sessionCount: counts[kind] ?? 0)
            } else {
                sources[kind] = SourceInfo(enabled: enabled, rootPath: "", available: false, sessionCount: 0)
            }
        }
        if let info = sources[.codex] {
            sources[.codex]?.configuredModes = ConfiguredModes.codex(sessionsRoot: info.rootPath)
        }
        self.sources = sources
        var warnings: [MonitorWarning] = []
        if session.partialHistory { warnings.append(.partialHistory) }
        for source in session.unsupportedSources { warnings.append(.unsupportedFormat(source)) }
        if session.unreadableFileCount > 0 { warnings.append(.unreadableFiles(session.unreadableFileCount)) }
        let malformed = session.malformedLines
        if malformed > 0 { warnings.append(.malformedLines(malformed)) }
        self.warnings = warnings
        self.todayStartMs = todayStartMs
    }

    /// Warnings that depend on the engine's view of today.
    func warnings(for output: EngineOutput) -> [MonitorWarning] {
        output.unfinalizedToday > 0 ? warnings + [.unfinalizedUsage(output.unfinalizedToday)] : warnings
    }
}

/// Maps engine output onto the public `SpeedSnapshot`.
enum SnapshotBuilder {
    static func running(
        _ output: EngineOutput,
        context: SnapshotContext,
        readObservation: SourceReadObservation? = nil
    ) -> SpeedSnapshot {
        let agents = output.agents.map { row in
            var status = AgentStatus(
                id: row.agent.id,
                source: row.agent.source,
                project: row.agent.project,
                model: row.agent.model,
                phase: row.phase,
                isSubagent: row.agent.isSubagent,
                live: row.live,
                recentSpeed: row.recentSpeed,
                lastActivity: date(row.agent.lastLineMs ?? 0),
                parentId: row.parentId,
                liveCost: row.liveCost,
                cwdPath: row.agent.cwdPath,
                modes: row.agent.modes
            )
            status.localDisplayStopped = row.agent.localDisplayStopped
            return status
        }
        let sources = SourceKind.allCases.map { kind in
            let info = context.sources[kind]
            return SourceStatus(
                kind: kind,
                enabled: info?.enabled ?? false,
                rootPath: info?.rootPath ?? "",
                available: info?.available ?? false,
                sessionCount: info?.sessionCount ?? 0,
                live: output.sourceLive[kind] ?? .zero,
                today: output.todayBySource[kind] ?? TokenTotals(),
                activeAgents: agents.filter { $0.source == kind && $0.phase == .generating }.count,
                liveEstimated: output.sourceLiveEstimated[kind] ?? .zero,
                liveCost: output.sourceLiveCost[kind] ?? .zero,
                todayCost: output.todayCostBySource[kind] ?? .zero,
                unpricedModels: unpricedModels(output.todayCostByModel[kind]),
                configuredModes: info?.configuredModes ?? .empty
            )
        }
        return SpeedSnapshot(
            timestamp: date(output.nowMs),
            state: .running,
            live: output.live,
            liveEstimatedShare: output.liveEstimatedShare,
            peakToday: output.peakToday,
            peakTodayAt: output.peakTodayAtMs.map(date),
            averageToday: output.averageToday,
            today: output.today,
            sources: sources,
            agents: agents,
            generatingCount: agents.filter { $0.phase == .generating }.count,
            toolsCount: agents.filter { $0.phase == .tools }.count,
            history: output.history,
            lastResponse: output.lastResponse,
            warnings: context.warnings(for: output),
            subsetPeaks: output.subsetPeaks,
            dayStart: date(output.todayStartMs),
            liveCost: output.liveCost,
            todayCost: output.todayCost,
            report: output.report,
            readObservation: readObservation
        )
    }

    /// Models with unpriced responses, most first, then by name.
    static func unpricedModels(_ models: [String: CostTally]?) -> [String] {
        (models ?? [:])
            .filter { $0.value.unpricedRequests > 0 && !$0.key.isEmpty }
            .sorted { $0.value.unpricedRequests != $1.value.unpricedRequests ? $0.value.unpricedRequests > $1.value.unpricedRequests : $0.key < $1.key }
            .map(\.key)
    }

    /// A snapshot without data, for `.starting` and `.noSources`.
    static func placeholder(state: MonitorState, context: SnapshotContext, now: Date) -> SpeedSnapshot {
        var snapshot = SpeedSnapshot.empty
        snapshot.timestamp = now
        snapshot.state = state
        snapshot.sources = SourceKind.allCases.map { kind in
            let info = context.sources[kind]
            return SourceStatus(
                kind: kind,
                enabled: info?.enabled ?? false,
                rootPath: info?.rootPath ?? "",
                available: info?.available ?? false,
                sessionCount: 0,
                live: .zero,
                today: TokenTotals(),
                activeAgents: 0,
                configuredModes: info?.configuredModes ?? .empty
            )
        }
        snapshot.warnings = context.warnings
        snapshot.dayStart = date(context.todayStartMs)
        return snapshot
    }

    private static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
