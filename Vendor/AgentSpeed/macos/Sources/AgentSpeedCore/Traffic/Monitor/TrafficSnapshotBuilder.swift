import Foundation

/// Builds the published `TrafficSnapshot` from the engine (METRICS 10.7, 10.8).
enum TrafficSnapshotBuilder {
    static func snapshot(engine: TrafficEngine, wallMs: Int64, state: ProcessTrafficState) -> TrafficSnapshot {
        let today = engine.today()
        var sources: [SourceKind: SourceTraffic] = [:]
        var sourceHistory: [SourceKind: [TrafficPoint]] = [:]
        if state.isAvailable {
            for source in SourceKind.allCases {
                let series = engine.sourceSeries[source]
                let traffic = today.sources[source]
                let live = series?.withTools
                guard traffic != nil || (live?.sum ?? 0) > 0 else { continue }
                sources[source] = SourceTraffic(
                    source: source, today: traffic?.split ?? .zero, unassigned: traffic?.unassigned ?? .zero,
                    liveWithTools: live, liveOwn: series?.ownOnly)
                sourceHistory[source] = engine.sourceBuckets[source]?.points(nowMs: wallMs) ?? TrafficBuckets().points(nowMs: wallMs)
            }
        }
        var agents: [String: AgentTraffic] = [:]
        if state.isAvailable {
            for (root, split) in today.agents {
                let series = engine.agentSeries[root]
                agents[root] = AgentTraffic(agentId: root, today: split, liveWithTools: series?.withTools, liveOwn: series?.ownOnly)
            }
        }
        return TrafficSnapshot(
            timestamp: Date(timeIntervalSince1970: TimeInterval(wallMs) / 1000),
            enabled: true,
            machineLive: engine.machineRate,
            machineToday: today.machine,
            machineSampledMs: today.machineSampledMs,
            machineHistory: engine.machineBuckets.points(nowMs: wallMs),
            sourceHistory: sourceHistory,
            processState: state,
            processSampledMs: today.processSampledMs,
            sources: sources,
            agents: agents,
            dayStart: engine.ledger.dayStart(forMs: wallMs),
            reportTotals: engine.reportTotals,
            machineAvailable: engine.machineInterfaceCount > 0
        )
    }
}
