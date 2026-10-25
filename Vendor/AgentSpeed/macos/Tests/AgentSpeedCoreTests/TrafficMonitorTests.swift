import Darwin
import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Traffic monitor")
struct TrafficMonitorTests {
    @Test func cadenceFollowsAgentProcessesActivityAndDemand() {
        let now: Int64 = 1_000_000
        func desired(_ agents: Bool, active: Int64?, demand: Bool = false, forced: Int? = nil) -> Int? {
            TrafficCadence.desiredInterval(hasAgentProcess: agents, lastActiveWallMs: active, nowWallMs: now,
                                           detailDemand: demand, forced: forced)
        }
        #expect(desired(false, active: now) == nil, "no agent process: standby")
        #expect(desired(true, active: now - 59_999) == 1)
        #expect(desired(true, active: now - 60_000) == 5, "idle for 60 s")
        #expect(desired(true, active: nil) == 5)
        #expect(desired(true, active: nil, demand: true) == 1, "a visible surface shows per-source traffic")
        #expect(desired(false, active: nil, forced: 1) == 1)
        #expect(desired(true, active: now, forced: 0) == nil)
        #expect(TrafficCadence.shouldApply(desired: 5, current: nil, lastChangeMs: now, nowMs: now, forced: false))
        #expect(!TrafficCadence.shouldApply(desired: 5, current: 1, lastChangeMs: now - 29_999, nowMs: now, forced: false))
        #expect(TrafficCadence.shouldApply(desired: 5, current: 1, lastChangeMs: now - 30_000, nowMs: now, forced: false))
        #expect(!TrafficCadence.shouldApply(desired: 1, current: 1, lastChangeMs: nil, nowMs: now, forced: false))
    }

    @Test func agentStatusMapsToATrafficAgent() {
        let status = AgentStatus(
            id: "/Users/dev/.claude/projects/p/s.jsonl", source: .claudeCode, project: "p", model: nil, phase: .tools,
            isSubagent: false, live: .zero, recentSpeed: nil, lastActivity: Date(timeIntervalSince1970: 1000),
            parentId: nil, cwdPath: "/Users/dev/p")
        let agent = TrafficAgent(status)
        #expect(agent.transcript == status.id && agent.cwdPath == "/Users/dev/p")
        #expect(agent.activity == .live(working: true, lastLineMs: 1_000_000))
        let opencode = TrafficAgent(AgentStatus(
            id: "opencode:ses_1", source: .opencode, project: "p", model: nil, phase: .idle, isSubagent: false, live: .zero,
            recentSpeed: nil, lastActivity: Date(timeIntervalSince1970: 0)))
        #expect(opencode.transcript == nil && opencode.activity == .live(working: false, lastLineMs: nil))
        #expect(TrafficCadence.lastActive([agent, opencode], nowWallMs: 5000) == 5000)
    }

    @Test func historyKeeperWritesMergesAndClears() throws {
        let directory = try TempDirectory()
        var keeper = TrafficHistoryKeeper(storePath: directory.file("history.sqlite").path)
        keeper.load()
        #expect(keeper.since == nil)
        #expect(keeper.isWriteDue(nowMs: 0))
        let yesterday = [TrafficDay(day: "2026-10-21", key: "machine", rx: 10, tx: 1, sampledMs: 1000)]
        keeper.write(yesterday, nowMs: 0)
        #expect(!keeper.isWriteDue(nowMs: 59_999) && keeper.isWriteDue(nowMs: 60_000))
        let today = [TrafficDay(day: "2026-10-22", key: "codex", rx: 5, tx: 5, rxTools: 2, txTools: 2, sampledMs: 900),
                     TrafficDay(day: "2026-10-22", key: "machine", rx: 20, tx: 2, sampledMs: 1000)]
        let published = keeper.daysToPublish(today: "2026-10-22", rows: today, nowMs: 0, force: true) ?? ([], nil)
        #expect(published.0.map(\.key) == ["machine", "machine", "codex"], "machine first within a day, oldest day first")
        #expect(published.1 == "2026-10-21")
        #expect(keeper.daysToPublish(today: "2026-10-22", rows: today, nowMs: 5000, force: false) == nil, "at most every 10 s")
        #expect(keeper.daysToPublish(today: "2026-10-22", rows: today, nowMs: 10_000, force: false) == nil, "unchanged")

        var reloaded = TrafficHistoryKeeper(storePath: keeper.storePath)
        reloaded.load()
        #expect(reloaded.storedRows(of: "2026-10-21") == yesterday)

        HistoryDatabase.delete(at: keeper.storePath)
        keeper.clear(nowMs: 100_000)
        #expect(keeper.since == nil && keeper.storedRows(of: "2026-10-21").isEmpty)
        keeper.write(today, nowMs: 160_000)
        var recreated = TrafficHistoryKeeper(storePath: keeper.storePath)
        recreated.load()
        #expect(recreated.since == "2026-10-22", "the next write recreates today's rows in a new file")
        #expect(Set(recreated.storedRows(of: "2026-10-22")) == Set(today))
    }

    @Test func restoredTotalsCountAsUnassigned() {
        let rows = [TrafficDay(day: "d", key: "machine", rx: 100, tx: 10, sampledMs: 5000),
                    TrafficDay(day: "d", key: "claudeCode", rx: 7, tx: 3, rxTools: 2, txTools: 1, sampledMs: 4000)]
        let totals = TrafficDayTotals(restoring: rows)
        #expect(totals.machine == TrafficBytes(rx: 100, tx: 10) && totals.machineSampledMs == 5000)
        #expect(totals.processSampledMs == 4000)
        #expect(totals.sources[.claudeCode]?.unassigned == TrafficBytes(rx: 9, tx: 4))
        #expect(totals.rows(day: "d") == rows)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func monitorPublishesWritesAndLeavesNoChild() async throws {
        let directory = try TempDirectory()
        let url = directory.file("history.sqlite")
        let store = TrafficStore()
        let monitor = TrafficMonitor(store: store, storeURL: url)
        monitor.start(enabled: true)
        for _ in 0..<60 where store.snapshot.machineLive == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(store.snapshot.enabled)
        #expect(store.snapshot.machineLive != nil, "two machine samples within a few seconds")
        #expect(store.snapshot.machineHistory.count == 300)
        #expect(store.snapshot.dayStart == Calendar.current.startOfDay(for: Date()))
        let nettop = monitor.diagnostics()?.nettopPid
        monitor.flush()
        let stored = HistoryDatabase.storedTraffic(at: url.path)
        #expect(stored.days.contains { $0.isMachine }, "flush writes today's rows")
        #expect(stored.since != nil)

        monitor.setEnabled(false)
        for _ in 0..<20 where store.snapshot.enabled { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(store.snapshot == .off)
        if let nettop { #expect(kill(nettop, 0) == -1, "off stops nettop at once") }

        monitor.setEnabled(true)
        monitor.clearHistory()
        HistoryDatabase.delete(at: url.path)
        for _ in 0..<40 where !store.snapshot.enabled { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let running = monitor.diagnostics()?.nettopPid
        monitor.stop()
        #expect(!monitor.isRunning)
        let afterClear = HistoryDatabase.storedTraffic(at: url.path)
        #expect(afterClear.days.contains { $0.isMachine }, "stop recreates today's rows in the new file")
        #expect(afterClear.days.allSatisfy { $0.sampledMs < 10_000 }, "today restarted at the clear")
        if let running { #expect(kill(running, 0) == -1 && errno == ESRCH, "stop kills and reaps nettop") }
    }
}
