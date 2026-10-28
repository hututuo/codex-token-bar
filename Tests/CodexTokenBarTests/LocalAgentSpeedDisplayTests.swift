import AgentSpeedCore
import Foundation
import Testing
@testable import CodexTokenBar

@Suite("Local speed display isolation")
@MainActor
struct LocalAgentSpeedDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func agent(_ id: String, _ source: SourceKind, _ model: String, _ speed: Double, age: Double = 0, phase: AgentPhase = .generating) -> AgentStatus {
        .init(id: id, source: source, project: "", model: model, phase: phase, isSubagent: false,
              live: .init(output: speed, total: speed), recentSpeed: speed, lastActivity: now.addingTimeInterval(-age))
    }
    private func snapshot(_ agents: [AgentStatus]) -> SpeedSnapshot {
        var value = SpeedSnapshot.empty; value.state = .running; value.timestamp = now; value.agents = agents
        value.live = .init(output: 777, total: 999)
        return value
    }
    @Test func combinesClientsWithoutChangingUpstreamMetric() {
        let raw = snapshot([agent("a", .codex, "gpt-6-astra", 40), agent("b", .claudeCode, "claude-opus-5", 60), agent("c", .deepseek, "deepseek-v4-flash", 100)])
        let reading = LocalAgentSpeedReading.project(raw, now: now)
        #expect(reading.total == 200)
        #expect(reading.clientRates.map(\.model) == ["client:claudeCode", "client:codex", "client:deepseek"])
        #expect(reading.clientRates.reduce(0) { $0 + $1.tokensPerSecond } == reading.total)
        #expect(raw.live.output == 777)
    }
    @Test func oneStopOrStaleAgentDoesNotStopOthersAndResumeIsFresh() {
        var stopped = agent("stopped", .codex, "gpt-6-astra", 80); stopped.localDisplayStopped = true
        let reading = LocalAgentSpeedReading.project(snapshot([stopped, agent("old", .deepseek, "deepseek-v4-flash", 90, age: 20), agent("idle", .claudeCode, "claude-opus-5", 60, phase: .idle), agent("live", .claudeCode, "claude-opus-5", 45)]), now: now)
        #expect(reading.total == 45)
        #expect(LocalAgentSpeedReading.project(snapshot([agent("resumed", .deepseek, "deepseek-v4-flash", 50)]), now: now).total == 50)
    }
    @Test func lostCollectorAndUnavailableSourcesClearDisplay() {
        let raw = snapshot([agent("a", .codex, "gpt-6-astra", 50)])
        #expect(LocalAgentSpeedReading.project(raw, now: now.addingTimeInterval(3.1)).total == 0)
        #expect(!LocalAgentSpeedReading.project(.empty, now: now).available)
    }
    @Test func feedbackFailureStopsOnlyMatchingSessionUntilNewProgress() {
        let raw = snapshot([agent("rollout-session-a.jsonl", .codex, "gpt-6-astra", 40), agent("other", .claudeCode, "claude-opus-5", 60)])
        #expect(LocalAgentSpeedReading.project(raw, now: now, stoppedThreads: ["session-a": now.timeIntervalSince1970]).total == 60)
        #expect(LocalAgentSpeedReading.project(raw, now: now, stoppedThreads: ["session-a": now.timeIntervalSince1970 - 1]).total == 100)
    }
    @Test func invalidNumbersNeverEnterColorShares() {
        #expect(LocalAgentSpeedReading.project(snapshot([agent("a", .codex, "x", .infinity), agent("b", .deepseek, "y", -.infinity)]), now: now).total == 0)
    }
    @Test func oneReaderIsLeasedAndStopsOnlyAfterLastConsumer() {
        final class Fake: AgentSpeedReportingMonitor { var starts = 0; var stops = 0; func start() { starts += 1 }; func stop() { stops += 1 } }
        let fake = Fake(); let hub = SharedAgentSpeedCollection(makeMonitor: { _ in fake })
        let local = hub.lease(for: SpeedStore()), report = hub.lease(for: SpeedStore())
        local.start(); report.start(); #expect(fake.starts == 1)
        local.stop(); #expect(fake.stops == 0)
        report.stop(); #expect(fake.stops == 1)
    }
    @Test func automaticLeaseReleaseStopsUnownedReader() async {
        final class Fake: AgentSpeedReportingMonitor { var stops = 0; func start() {}; func stop() { stops += 1 } }
        let fake = Fake(); let hub = SharedAgentSpeedCollection(makeMonitor: { _ in fake })
        var lease: (any AgentSpeedReportingMonitor)? = hub.lease(for: SpeedStore())
        lease?.start(); lease = nil
        for _ in 0..<10 where fake.stops == 0 { await Task.yield() }
        #expect(fake.stops == 1)
    }
    @Test func preferencesPersistWithoutOptingIntoReports() {
        let name = "test.speed-display." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let prefs = SpeedDisplayPreferences(defaults: defaults)
        #expect(prefs.mode == .activity); #expect(prefs.grouping == .model)
        prefs.setMode(.agentSpeed); prefs.setGrouping(.client)
        let reloaded = SpeedDisplayPreferences(defaults: defaults)
        #expect(reloaded.mode == .agentSpeed); #expect(reloaded.grouping == .client)
        #expect(!defaults.bool(forKey: AgentSpeedReportingController.enabledKey))
        #expect(SpeedColorOverrides.valid("#D4512c")); #expect(!SpeedColorOverrides.valid("red"))
    }
    @Test func mergedDisplayKeepsResponseModelsAndStopsWithoutChangingReportCounters() {
        var raw = snapshot([agent("active", .codex, "gpt-6.1-sol", 60)])
        raw.sources = [.init(kind: .codex, enabled: true, rootPath: "", available: true, sessionCount: 1,
            live: .init(output: 60, total: 60), today: .zero, activeAgents: 1)]
        raw.liveModels = [.init(source: .codex, model: "gpt-6-luna", rate: .init(output: 40, total: 40)),
                          .init(source: .codex, model: "gpt-6.1-sol", rate: .init(output: 20, total: 20))]
        let active = LocalAgentSpeedReading.project(raw, now: now)
        #expect(active.total == 60)
        #expect(active.modelRates.count == 2)
        raw.agents[0].localDisplayStopped = true
        #expect(LocalAgentSpeedReading.project(raw, now: now).total == 0)
        #expect(raw.sources[0].live.output == 60)
        #expect(raw.liveModels.count == 2)
    }
    @Test func legacyAlgorithmPreferenceMigratesToOneSharedSetting() {
        let name = "test.speed-merge." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("agentSpeed", forKey: "speedDisplay.mode.v1")
        let prefs = SpeedDisplayPreferences(defaults: defaults)
        #expect(prefs.mode == .agentSpeed)
        #expect(defaults.string(forKey: ActivitySpeedDisplayMode.key) == "agentSpeed")
        prefs.setMode(.activity)
        #expect(defaults.string(forKey: ActivitySpeedDisplayMode.key) == "bar")
        #expect(!defaults.bool(forKey: AgentSpeedReportingController.enabledKey))
    }

}
