import Foundation
import Testing
@testable import AgentSpeedCore

@MainActor
@Suite("Subset monitor", .serialized)
struct SubsetMonitorTests {
    @Test func publishesRequestedSubsetsAndKeepsThemAcrossRestarts() async throws {
        let (directory, configuration) = try SessionTests.makeFixtureRoots()
        let store = SpeedStore()
        let monitor = LiveMonitor(store: store, configuration: configuration)
        monitor.start()
        defer {
            monitor.stop()
            withExtendedLifetime(directory) {}
        }

        #expect(await LiveMonitorTests.waitUntil { store.snapshot.state == .running })
        #expect(store.snapshot.subsetPeaks.isEmpty)
        #expect(store.snapshot.dayStart == Calendar.current.startOfDay(for: store.snapshot.timestamp))

        let codex = SourceSet(.codex)
        let claude = SourceSet([.claudeCode, .claudeDesktop])
        monitor.setSubsets([codex, claude])
        #expect(monitor.subsets == [codex, claude])
        #expect(await LiveMonitorTests.waitUntil { Set(store.snapshot.subsetPeaks.keys) == [codex, claude] })

        var reduced = configuration
        reduced.enabledSources.remove(.gemini)
        monitor.update(configuration: reduced)
        #expect(await LiveMonitorTests.waitUntil {
            store.snapshot.state == .running
                && store.snapshot.sources.first { $0.kind == .gemini }?.enabled == false
                && Set(store.snapshot.subsetPeaks.keys) == [codex, claude]
        })
        let gemini = OrbSubset.reading(store.snapshot, sources: SourceSet(.gemini))
        #expect(gemini.state == .allDisabled)

        monitor.setSubsets([])
        #expect(await LiveMonitorTests.waitUntil { store.snapshot.subsetPeaks.isEmpty })
    }
}
