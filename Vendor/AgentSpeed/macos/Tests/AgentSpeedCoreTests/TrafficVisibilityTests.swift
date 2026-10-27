import Foundation
import Testing
@testable import AgentSpeedCore

/// METRICS 10.5, DESIGN 10: a disabled source is still measured and stored, but no view shows its traffic.
@Suite("Traffic of disabled sources")
struct TrafficVisibilityTests {
    static let point = TrafficPoint(time: Date(timeIntervalSince1970: 0), rate: TrafficRate(rx: 10, tx: 1))

    static let snapshot = TrafficSnapshot(
        timestamp: Date(timeIntervalSince1970: 100),
        enabled: true,
        machineLive: TrafficRate(rx: 9_000, tx: 900),
        machineToday: TrafficBytes(rx: 90_000, tx: 9_000),
        sourceHistory: [.codex: [point], .claudeCode: [point]],
        processState: .running(interval: 1),
        sources: [
            .codex: SourceTraffic(source: .codex, today: TrafficSplit(own: TrafficBytes(rx: 1_000, tx: 100)),
                                  liveWithTools: TrafficRate(rx: 100, tx: 10), liveOwn: TrafficRate(rx: 100, tx: 10)),
            .claudeCode: SourceTraffic(source: .claudeCode, today: TrafficSplit(own: TrafficBytes(rx: 2_000, tx: 200)),
                                       liveWithTools: TrafficRate(rx: 200, tx: 20), liveOwn: TrafficRate(rx: 200, tx: 20)),
        ],
        agents: ["a": AgentTraffic(agentId: "a", today: TrafficSplit(own: TrafficBytes(rx: 5, tx: 5)))]
    )

    @Test func disabledSourcesLeaveEverySumButTheMachineIsUnchanged() {
        let visible = TrafficVisibility.snapshot(Self.snapshot, enabled: SourceSet(.codex))
        #expect(Array(visible.sources.keys) == [.codex])
        #expect(Array(visible.sourceHistory.keys) == [.codex])
        #expect(visible.live(of: nil, includeTools: true) == TrafficRate(rx: 100, tx: 10))
        #expect(visible.today(of: nil, includeTools: true) == TrafficBytes(rx: 1_000, tx: 100))
        #expect(visible.machineLive == Self.snapshot.machineLive && visible.machineToday == Self.snapshot.machineToday)
        #expect(visible.processState == Self.snapshot.processState && visible.agents == Self.snapshot.agents)
    }

    @Test func everySourceEnabledKeepsTheSnapshot() {
        #expect(TrafficVisibility.snapshot(Self.snapshot, enabled: .everything) == Self.snapshot)
    }

    @Test func onlyDisabledSourcesRunningShowsAMeasuredZero() {
        let visible = TrafficVisibility.snapshot(Self.snapshot, enabled: SourceSet(.gemini))
        #expect(visible.sources.isEmpty)
        // Per-process data is available, so the agents' rate is a real 0 rather than unknown.
        #expect(visible.live(of: nil, includeTools: true) == .zero)
    }

    @Test func storedDaysKeepTheMachineRowsAndEnabledSources() {
        let days = [
            TrafficDay(day: "2026-10-21", key: TrafficDay.machineKey, rx: 9, tx: 1, sampledMs: 1_000),
            TrafficDay(day: "2026-10-21", key: SourceKind.codex.rawValue, rx: 5, tx: 1, sampledMs: 1_000),
            TrafficDay(day: "2026-10-21", key: SourceKind.claudeCode.rawValue, rx: 3, tx: 1, sampledMs: 1_000),
        ]
        let visible = TrafficVisibility.days(days, enabled: SourceSet(.claudeCode))
        #expect(visible.map(\.key) == [TrafficDay.machineKey, SourceKind.claudeCode.rawValue])
        #expect(TrafficVisibility.days(days, enabled: .everything) == days)
    }
}
