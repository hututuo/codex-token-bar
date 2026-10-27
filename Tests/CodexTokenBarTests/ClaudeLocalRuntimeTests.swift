import AgentSpeedCore
import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
private final class FakeClaudeLocalMonitor: ClaudeLocalRuntimeMonitoring {
    private(set) var configuration: MonitorConfiguration
    private(set) var isRunning = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var updates = 0

    init(configuration: MonitorConfiguration) {
        self.configuration = configuration
    }

    func start() {
        guard !isRunning else { return }
        starts += 1
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        stops += 1
        isRunning = false
    }

    func update(configuration: MonitorConfiguration) {
        guard self.configuration != configuration else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        self.configuration = configuration
        updates += 1
        if wasRunning { start() }
    }
}

@MainActor
final class ClaudeLocalRuntimeTests: XCTestCase {
    func testProjectionKeepsOnlyFreshActiveClaudeAgentsAndGroupsSubagentsByOpaqueParentID() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mainID = "/private/session-project/main.jsonl"
        let main = agent(
            id: mainID,
            source: .claudeCode,
            project: "private-project-name",
            model: "claude-sonnet-4",
            phase: .generating,
            isSubagent: false,
            outputRate: 2,
            lastActivity: now.addingTimeInterval(-10),
            cwdPath: "/private/session-project"
        )
        let subagent = agent(
            id: "/private/session-project/subagents/worker.jsonl",
            source: .claudeCode,
            project: "private-project-name",
            model: "claude-haiku-4",
            phase: .tools,
            isSubagent: true,
            outputRate: 0.5,
            lastActivity: now.addingTimeInterval(-4),
            parentId: mainID,
            cwdPath: "/private/session-project"
        )
        let staleDesktop = agent(
            id: "/private/desktop/stale.jsonl",
            source: .claudeDesktop,
            project: "private-desktop-project",
            model: "claude-opus-4",
            phase: .generating,
            isSubagent: false,
            outputRate: 99,
            lastActivity: now.addingTimeInterval(-301)
        )
        let idleDesktop = agent(
            id: "/private/desktop/idle.jsonl",
            source: .claudeDesktop,
            project: "private-desktop-project",
            model: "claude-opus-4",
            phase: .idle,
            isSubagent: false,
            outputRate: 99,
            lastActivity: now
        )
        let unrelatedCodex = agent(
            id: "/private/codex/session.jsonl",
            source: .codex,
            project: "unrelated-project",
            model: "gpt-6.1-sol",
            phase: .generating,
            isSubagent: false,
            outputRate: 500,
            lastActivity: now
        )

        let projected = ClaudeLocalRuntime.project(
            from: coreSnapshot(
                timestamp: now,
                sources: [
                    source(.claudeCode, available: true, output: 60),
                    source(.claudeDesktop, available: true, output: 500),
                    source(.codex, available: true, output: 1_000)
                ],
                agents: [main, subagent, staleDesktop, idleDesktop, unrelatedCodex]
            ),
            allowedSources: [.claudeCode]
        )

        XCTAssertTrue(projected.enabled)
        XCTAssertTrue(projected.sourceAvailable)
        XCTAssertEqual(projected.sourceTotals.keys.sorted(), ["claudeCode"])
        XCTAssertEqual(projected.today.output, 60)
        XCTAssertEqual(projected.modelRates, [
            .init(model: "claude-haiku-4", tokensPerSecond: 0.5),
            .init(model: "claude-sonnet-4", tokensPerSecond: 2),
            .init(model: "unknown", tokensPerSecond: 57.5)
        ])
        XCTAssertEqual(projected.modelRates.reduce(0) { $0 + $1.tokensPerSecond }, projected.live.output)
        XCTAssertEqual(projected.running.main, 1)
        XCTAssertEqual(projected.running.subagents, 1)
        XCTAssertEqual(projected.running.groups.count, 1)
        XCTAssertEqual(projected.running.groups[0].subagents.count, 1)
        XCTAssertEqual(projected.running.freshness, .fresh)
        XCTAssertEqual(projected.running.groups[0].mainThread.title, "Claude session")
        XCTAssertTrue(projected.running.groups[0].mainThread.threadID.hasPrefix("claude:"))
        XCTAssertTrue(projected.running.groups[0].subagents[0].threadID.hasPrefix("claude:"))
        XCTAssertFalse(projected.running.groups[0].mainThread.threadID.contains("private"))
        XCTAssertFalse(projected.running.groups[0].subagents[0].threadID.contains("private"))
        XCTAssertFalse(projected.running.groups[0].mainThread.title?.contains("private") ?? false)
    }

    func testClientProjectionDropsIdleGhostsAndFiltersResponseRowsBySource() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let activeCode = agent(
            id: "/private/code/active.jsonl",
            source: .claudeCode,
            project: "code-project",
            model: "claude-sonnet-4",
            phase: .generating,
            isSubagent: false,
            outputRate: 12,
            lastActivity: now
        )
        let activeDesktop = agent(
            id: "/private/desktop/active.jsonl",
            source: .claudeDesktop,
            project: "desktop-project",
            model: "claude-haiku-4",
            phase: .tools,
            isSubagent: false,
            outputRate: 4,
            lastActivity: now
        )
        let rows = [responseRow(id: "code-row", sourceID: "claudeCode", endedAt: now),
                    responseRow(id: "desktop-row", sourceID: "claudeDesktop", endedAt: now)]

        let codeOnly = ClaudeLocalRuntime.project(
            from: coreSnapshot(
                timestamp: now,
                sources: [source(.claudeCode, available: true, output: 12), source(.claudeDesktop, available: true, output: 4)],
                agents: [activeCode, activeDesktop]
            ),
            allowedSources: [.claudeCode],
            rows: rows
        )
        let desktopOnly = ClaudeLocalRuntime.project(
            from: coreSnapshot(
                timestamp: now,
                sources: [source(.claudeCode, available: true, output: 12), source(.claudeDesktop, available: true, output: 4)],
                agents: [activeCode, activeDesktop]
            ),
            allowedSources: [.claudeDesktop],
            rows: rows
        )
        let noneAllowed = ClaudeLocalRuntime.project(
            from: coreSnapshot(timestamp: now, sources: [source(.claudeCode, available: true)], agents: [activeCode]),
            allowedSources: [],
            rows: rows
        )

        XCTAssertEqual(codeOnly.modelRates.map(\.model), ["claude-sonnet-4"])
        XCTAssertEqual(codeOnly.rows.map(\.sourceID), ["claudeCode"])
        XCTAssertEqual(desktopOnly.modelRates.map(\.model), ["claude-haiku-4"])
        XCTAssertEqual(desktopOnly.rows.map(\.sourceID), ["claudeDesktop"])
        XCTAssertFalse(noneAllowed.enabled)
        XCTAssertFalse(noneAllowed.sourceAvailable)
        XCTAssertTrue(noneAllowed.modelRates.isEmpty)
        XCTAssertTrue(noneAllowed.rows.isEmpty)
    }

    func testResponseRowsAreTaggedAsAgentSpeedResponseIntervalsAndBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = (0...ClaudeLocalRuntime.responseRowLimit).map { index in
            responseRow(id: "row-\(index)", sourceID: "claudeCode", endedAt: now.addingTimeInterval(TimeInterval(index)))
        }
        let projected = ClaudeLocalRuntime.project(
            from: coreSnapshot(timestamp: now, sources: [source(.claudeCode, available: true)], agents: []),
            allowedSources: [.claudeCode],
            rows: rows
        )

        XCTAssertEqual(projected.rows.count, ClaudeLocalRuntime.responseRowLimit)
        XCTAssertEqual(projected.rows.first?.id, "row-1")
        let sample = try! XCTUnwrap(projected.rows.first)
        XCTAssertEqual(sample.sourceID, "claudeCode")
        XCTAssertEqual(sample.method, .agentSpeedResponseInterval)
        XCTAssertEqual(sample.responseIntervalOutputTokensPerSecond, 10)
    }

    func testConfigureStartsOnceForRepeatedPreferencesAndMonitoringOffClearsLocalState() {
        let prefs = claudePreferences(codeEnabled: true, desktopEnabled: true, sharedPath: "/tmp/claude-local-runtime-fixture")
        var fakeMonitor: FakeClaudeLocalMonitor?
        var store: SpeedStore?
        let runtime = ClaudeLocalRuntime { suppliedStore, configuration in
            store = suppliedStore
            let fake = FakeClaudeLocalMonitor(configuration: configuration)
            fakeMonitor = fake
            return fake
        }

        runtime.configure(preferences: prefs)
        runtime.configure(preferences: prefs)
        XCTAssertEqual(fakeMonitor?.starts, 1)
        XCTAssertEqual(fakeMonitor?.stops, 0)
        XCTAssertEqual(fakeMonitor?.updates, 1)
        XCTAssertEqual(fakeMonitor?.configuration.enabledSources, [.claudeCode, .claudeDesktop])

        store?.publishLive(coreSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [source(.claudeCode, available: true)],
            agents: [],
            state: .running
        ), events: [.responseCompleted(ResponseSummary(
            source: .claudeCode,
            project: "private-project-name",
            model: "claude-sonnet-4",
            outputTokens: 200,
            totalTokens: 250,
            duration: 10,
            speed: 20,
            endedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))])
        XCTAssertEqual(runtime.snapshot.rows.count, 1)

        runtime.configure(preferences: prefs, monitoringEnabled: false)
        XCTAssertEqual(fakeMonitor?.stops, 1)
        XCTAssertFalse(runtime.snapshot.enabled)
        XCTAssertTrue(runtime.snapshot.rows.isEmpty)
        XCTAssertEqual(runtime.projection(allowed: ["claudeCode"]).running.freshness, .unavailable)

        runtime.configure(preferences: prefs, monitoringEnabled: true)
        XCTAssertEqual(fakeMonitor?.starts, 2)
        XCTAssertEqual(fakeMonitor?.stops, 1)
        XCTAssertTrue(runtime.snapshot.rows.isEmpty)
    }

    func testEstimatedShareReusesUpstreamSourceFactsWithoutCrossClientLeakage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var code = source(.claudeCode, available: true, output: 60)
        code.live = .init(output: 60, total: 100)
        code.liveEstimated = .init(output: 15, total: 30)
        var desktop = source(.claudeDesktop, available: true, output: 100)
        desktop.live = .init(output: 100, total: 160)
        desktop.liveEstimated = .init(output: 100, total: 160)
        let core = coreSnapshot(timestamp: now, sources: [code, desktop], agents: [])
        XCTAssertEqual(ClaudeLocalRuntime.project(from: core, allowedSources: [.claudeCode]).estimatedShare, 0.25)
        XCTAssertEqual(ClaudeLocalRuntime.project(from: core, allowedSources: [.claudeCode, .claudeDesktop]).estimatedShare, 115.0 / 160)
        code.live = .zero
        let idle = coreSnapshot(timestamp: now, sources: [code], agents: [])
        XCTAssertEqual(ClaudeLocalRuntime.project(from: idle, allowedSources: [.claudeCode]).estimatedShare, 0)
    }

    private func claudePreferences(codeEnabled: Bool, desktopEnabled: Bool, sharedPath: String) -> [MultiClientUsagePreference] {
        var values = MultiClientUsagePreference.defaults
        for index in values.indices {
            switch values[index].client {
            case .claudeCode:
                values[index].enabled = codeEnabled
                values[index].path = sharedPath
            case .claudeDesktop:
                values[index].enabled = desktopEnabled
                values[index].path = sharedPath
            default:
                break
            }
        }
        return values
    }

    private func source(_ kind: SourceKind, available: Bool, output: Double = 0) -> SourceStatus {
        SourceStatus(
            kind: kind,
            enabled: true,
            rootPath: "/private/project-name/path-that-must-not-be-projected",
            available: available,
            sessionCount: 1,
            live: Rate(output: output, total: output),
            today: TokenTotals(requests: 1, input: 10, cachedInput: 5, cacheWriteInput: 2, output: Int(output), reasoning: 0),
            activeAgents: 1
        )
    }

    private func agent(
        id: String,
        source: SourceKind,
        project: String,
        model: String,
        phase: AgentPhase,
        isSubagent: Bool,
        outputRate: Double,
        lastActivity: Date,
        parentId: String? = nil,
        cwdPath: String? = nil
    ) -> AgentStatus {
        AgentStatus(
            id: id,
            source: source,
            project: project,
            model: model,
            phase: phase,
            isSubagent: isSubagent,
            live: Rate(output: outputRate, total: outputRate),
            recentSpeed: outputRate,
            lastActivity: lastActivity,
            parentId: parentId,
            cwdPath: cwdPath
        )
    }

    private func responseRow(id: String, sourceID: String, endedAt: Date) -> ClaudeLocalResponseSpeedSample {
        ClaudeLocalResponseSpeedSample(
            id: id,
            sourceID: sourceID,
            model: "claude-sonnet-4",
            outputTokens: 100,
            duration: 10,
            endedAt: endedAt,
            method: .agentSpeedResponseInterval
        )
    }

    private func coreSnapshot(
        timestamp: Date,
        sources: [SourceStatus],
        agents: [AgentStatus],
        state: MonitorState = .running
    ) -> SpeedSnapshot {
        SpeedSnapshot(
            timestamp: timestamp,
            state: state,
            live: .zero,
            liveEstimatedShare: 0,
            peakToday: .zero,
            peakTodayAt: nil,
            averageToday: nil,
            today: .zero,
            sources: sources,
            agents: agents,
            generatingCount: agents.filter { $0.phase == .generating }.count,
            toolsCount: agents.filter { $0.phase == .tools }.count,
            history: [],
            lastResponse: nil,
            warnings: []
        )
    }
}
