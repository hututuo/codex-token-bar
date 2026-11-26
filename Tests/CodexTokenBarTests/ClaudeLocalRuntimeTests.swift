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
    func testLocalAgentNamesReachTheExistingTaskGroups() {
        let now = Date()
        var main = agent(id: "main", source: .claudeCode, project: "fixture", model: "claude-sonnet", phase: .idle, isSubagent: false, outputRate: 0, lastActivity: now)
        main.displayTitle = "整理主任务"
        var child = agent(id: "child", source: .claudeCode, project: "fixture", model: "claude-opus", phase: .tools, isSubagent: true, outputRate: 0, lastActivity: now, parentId: "main")
        child.displayTitle = "检查迁移测试"
        let projected = ClaudeLocalRuntime.project(from: coreSnapshot(timestamp: now, sources: [source(.claudeCode, available: true)], agents: [main, child]), allowedSources: [.claudeCode])
        XCTAssertEqual(projected.running.subagents, 1)
        XCTAssertEqual(projected.running.groups.first?.mainThread.title, "整理主任务")
        XCTAssertEqual(projected.running.groups.first?.subagents.first?.title, "检查迁移测试")
    }

    func testBarSmoothingDoesNotChangeRawMetricAndExplicitStopClearsIt() {
        var store: SpeedStore?
        let runtime = ClaudeLocalRuntime { suppliedStore, configuration in
            store = suppliedStore
            return FakeClaudeLocalMonitor(configuration: configuration)
        }
        runtime.configure(preferences: claudePreferences(codeEnabled: true, desktopEnabled: false, sharedPath: "/tmp/claude-smoothing-fixture"))
        let now = Date()
        var active = agent(id: "main", source: .claudeCode, project: "fixture", model: "claude-sonnet", phase: .generating, isSubagent: false, outputRate: 100, lastActivity: now)
        store?.publishLive(coreSnapshot(timestamp: now, sources: [source(.claudeCode, available: true, output: 100)], agents: [active]))
        XCTAssertEqual(runtime.displayModelRates(allowed: ["claudeCode"], mode: .bar).reduce(0) { $0 + $1.tokensPerSecond }, 28, accuracy: 1e-8)
        XCTAssertEqual(runtime.displayModelRates(allowed: ["claudeCode"], mode: .agentSpeed).reduce(0) { $0 + $1.tokensPerSecond }, 100, accuracy: 1e-8)
        var finished = active
        finished.phase = .idle
        finished.lastActivity = now.addingTimeInterval(0.1)
        store?.publishLive(coreSnapshot(timestamp: now.addingTimeInterval(0.1), sources: [source(.claudeCode, available: true, output: 0)], agents: [finished]))
        XCTAssertGreaterThan(runtime.displayModelRates(allowed: ["claudeCode"], mode: .bar).reduce(0) { $0 + $1.tokensPerSecond }, 0)
        XCTAssertTrue(runtime.displayModelRates(allowed: ["claudeCode"], mode: .agentSpeed).isEmpty)
        active.localDisplayStopped = true
        store?.publishLive(coreSnapshot(timestamp: now.addingTimeInterval(0.2), sources: [source(.claudeCode, available: true, output: 100)], agents: [active]))
        XCTAssertTrue(runtime.displayModelRates(allowed: ["claudeCode"], mode: .bar).isEmpty)
        XCTAssertEqual(runtime.snapshot.running.main, 0)
        runtime.stop()
        XCTAssertTrue(runtime.displayModelRates(allowed: ["claudeCode"], mode: .bar).isEmpty)
    }

    func testStandaloneClaudeMainTaskKeepsItsTitleWithoutAnySubagents() {
        let now = Date()
        var main = agent(id: "standalone", source: .claudeCode, project: "fixture", model: "claude-sonnet", phase: .generating, isSubagent: false, outputRate: 10, lastActivity: now)
        main.displayTitle = "检查项目构建"
        let projected = ClaudeLocalRuntime.project(from: coreSnapshot(timestamp: now, sources: [source(.claudeCode, available: true)], agents: [main]), allowedSources: [.claudeCode])
        XCTAssertEqual(projected.running.main, 1)
        XCTAssertEqual(projected.running.groups.first?.mainThread.title, "检查项目构建")
        XCTAssertEqual(projected.running.groups.first?.subagents.count, 0)
    }

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
        XCTAssertTrue(projected.running.groups[0].mainThread.title?.hasPrefix("任务 · ") == true)
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

    func testAutomaticAccountsShareOneMonitorAndExplicitSelectionsStayExclusive() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-live-roots-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let accounts = home.appendingPathComponent(".local/share/claude-adapter/accounts")
        let id = String(repeating: "a", count: 32)
        let accountProjects = accounts.appendingPathComponent("\(id)/code/projects")
        try fm.createDirectory(at: accountProjects, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "accounts": [["id": "existing"], ["id": id]]])
            .write(to: accounts.appendingPathComponent("registry.json"))
        // These files are deliberately not part of automatic transcript selection.
        try Data("credential-canary".utf8).write(to: accounts.appendingPathComponent("\(id)/code/.credentials.json"))
        let explicit = home.appendingPathComponent("desktop-projects")
        var makeCount = 0
        var monitor: FakeClaudeLocalMonitor?
        let runtime = ClaudeLocalRuntime(home: home, environment: [:]) { _, configuration in
            makeCount += 1
            let fake = FakeClaudeLocalMonitor(configuration: configuration)
            monitor = fake
            return fake
        }
        var prefs = claudePreferences(codeEnabled: true, desktopEnabled: true, sharedPath: "")
        runtime.configure(preferences: prefs)
        let expected = Set([home.appendingPathComponent(".claude/projects"),
                            home.appendingPathComponent(".claude-official-guarded/projects"), accountProjects]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        XCTAssertEqual(Set(monitor!.configuration.claudeRootsBySource[.claudeCode]!.map(\.path)), expected)
        XCTAssertEqual(Set(monitor!.configuration.claudeRootsBySource[.claudeDesktop]!.map(\.path)), expected)
        XCTAssertEqual(runtime.displaySourceIdentity(client: "claudeCode"), runtime.displaySourceIdentity(client: "claudeDesktop"))
        let codeIdentity = runtime.displaySourceIdentity(client: "claudeCode")
        prefs[prefs.firstIndex { $0.client == .claudeDesktop }!].path = explicit.path
        runtime.configure(preferences: prefs)
        XCTAssertEqual(Set(monitor!.configuration.claudeRootsBySource[.claudeCode]!.map(\.path)), expected)
        XCTAssertEqual(monitor!.configuration.claudeRootsBySource[.claudeDesktop]!.map(\.path), [explicit.resolvingSymlinksInPath().path])
        XCTAssertEqual(runtime.displaySourceIdentity(client: "claudeCode"), codeIdentity)
        XCTAssertNotEqual(codeIdentity, runtime.displaySourceIdentity(client: "claudeDesktop"))
        XCTAssertNil(runtime.snapshot.configurationIssue)
        prefs[prefs.firstIndex { $0.client == .claudeCode }!].path = accountProjects.path
        runtime.configure(preferences: prefs)
        XCTAssertEqual(monitor!.configuration.claudeRootsBySource[.claudeCode]!.map(\.path), [accountProjects.resolvingSymlinksInPath().path])
        prefs[prefs.firstIndex { $0.client == .claudeDesktop }!].enabled = false
        runtime.configure(preferences: prefs)
        XCTAssertEqual(monitor!.configuration.enabledSources, [.claudeCode])
        XCTAssertNil(monitor!.configuration.claudeRootsBySource[.claudeDesktop])
        let explicitCodeIdentity = runtime.displaySourceIdentity(client: "claudeCode")
        XCTAssertEqual(runtime.displaySourceIdentity(client: "claudeDesktop"), "unavailable")
        runtime.configure(preferences: prefs, monitoringEnabled: false)
        XCTAssertFalse(monitor!.isRunning)
        XCTAssertEqual(runtime.displaySourceIdentity(client: "claudeCode"), "unavailable")
        runtime.configure(preferences: prefs)
        XCTAssertTrue(monitor!.isRunning)
        XCTAssertEqual(runtime.displaySourceIdentity(client: "claudeCode"), explicitCodeIdentity)
        XCTAssertEqual(runtime.displaySourceIdentity(client: "claudeDesktop"), "unavailable")
        XCTAssertEqual(makeCount, 1, "accounts and configuration updates reuse one monitor")
    }

    func testAutomaticAccountAliasesAreDeduplicatedAndDoNotChangeSingleRootIdentity() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("claude-live-alias-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let projects = home.appendingPathComponent(".claude/projects")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        let alias = home.appendingPathComponent("selected")
        try fm.createSymbolicLink(at: alias, withDestinationURL: home.appendingPathComponent(".claude"))
        var monitor: FakeClaudeLocalMonitor?
        let runtime = ClaudeLocalRuntime(home: home, environment: ["CLAUDE_CONFIG_DIR": alias.path]) { _, configuration in
            let fake = FakeClaudeLocalMonitor(configuration: configuration); monitor = fake; return fake
        }
        var prefs = claudePreferences(codeEnabled: true, desktopEnabled: false, sharedPath: "")
        runtime.configure(preferences: prefs)
        XCTAssertEqual(monitor!.configuration.claudeRootsBySource[.claudeCode]!.map(\.path), [projects.resolvingSymlinksInPath().path])
        let identity = runtime.displaySourceIdentity(client: "claudeCode")
        prefs[prefs.firstIndex { $0.client == .claudeCode }!].path = projects.path + "/./"
        runtime.configure(preferences: prefs)
        XCTAssertEqual(runtime.displaySourceIdentity(client: "claudeCode"), identity)
        XCTAssertEqual(monitor!.updates, 1)
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
            warnings: [],
            // Fixtures supply event-model metadata explicitly. Production gets it from LiveWindow.
            liveModels: agents.map { .init(source: $0.source, model: $0.model, rate: $0.live) }
        )
    }
}
