import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Antigravity store locations")
struct TranscriptLocationsTests {
    @Test func defaultsAndExplicitParentsResolveAllStores() {
        let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
        let expected = [".gemini/antigravity-cli", ".gemini/antigravity", ".gemini/antigravity-ide", ".gemini/antigravity-acp",
            "Library/Application Support/orca/antigravity-chat/antigravity-acp",
            "Library/Application Support/orca/antigravity-chat/antigravity-cli",
            "Library/Application Support/orca/antigravity-chat/antigravity"]
        #expect(TranscriptLocations.defaultAntigravityStores(homeDirectory: home).map(\.path) ==
            expected.map { home.appendingPathComponent($0).path })
        #expect(MonitorConfiguration().resolvedRoots(for: .antigravity) ==
            LiveMonitor.defaultAntigravityStores.map { $0.appendingPathComponent("conversations").path })
        for parent in [home.appendingPathComponent(".gemini"), home.appendingPathComponent("Library/Application Support/orca/antigravity-chat")] {
            let selected = MonitorConfiguration(antigravityRoot: parent).resolvedRoots(for: .antigravity)
            #expect(selected.count == 5)
            #expect(selected.contains(parent.appendingPathComponent("antigravity-acp/conversations").path))
            #expect(selected.allSatisfy { $0.hasPrefix(parent.path + "/") })
            for store in ["antigravity-cli", "antigravity", "antigravity-ide", "antigravity-acp"] {
                let root = parent.appendingPathComponent(store)
                #expect(MonitorConfiguration(antigravityRoot: root).resolvedRoots(for: .antigravity) ==
                    [root.appendingPathComponent("conversations").path])
            }
        }
    }

    @Test func standaloneAndOrcaAreWatchedAndDeduplicateConversationSteps() throws {
        let directory = try TempDirectory()
        let home = directory.file("home"), id = "11111111-2222-4333-8444-555555555555"
        let standalone = home.appendingPathComponent(".gemini/antigravity/conversations")
        let orca = home.appendingPathComponent("Library/Application Support/orca/antigravity-chat/antigravity-acp/conversations")
        for folder in [standalone, orca] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let t0 = Clock.milliseconds(Date()) - 10_000
        let file = standalone.appendingPathComponent(id + ".db")
        let writer = try ConversationWriter(path: file.path, trajectory: AntigravityBlobEncoder.trajectory(created: t0))
        try writer.step(1, type: AntigravityStep.plannerResponse, status: 3,
            AntigravityBlobEncoder.step(created: t0 + 100, finished: t0 + 900,
                usage: AntigravityBlobEncoder.usage(input: 100, output: 20)))
        try writer.close()
        let copy = orca.appendingPathComponent(id + ".db")
        try FileManager.default.copyItem(at: file, to: copy)
        var config = MonitorConfiguration(enabledSources: [.antigravity])
        config.automaticRoots = [.antigravity: TranscriptLocations.defaultAntigravityStores(homeDirectory: home)]
        let session = TranscriptSession(configuration: config)
        let summary = session.seed(todayStartMs: t0 - 1000)
        #expect(summary.filesDiscovered == 2 && summary.filesRead == 2)
        #expect(session.responses.map(\.key) == ["antigravity:\(id):1"])
        func canonicalPath(_ url: URL) throws -> String {
            let pointer = try #require(realpath(url.path, nil))
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let canonical = try [standalone, orca].map(canonicalPath)
        #expect(Set(session.watchedPaths) == Set(canonical))

        // A new completed step arriving through the Orca WAL reaches the live
        // session and completion events; the copied step is not counted again.
        let resumed = try ConversationWriter(reopening: copy.path)
        try resumed.step(2, type: AntigravityStep.plannerResponse, status: 3,
            AntigravityBlobEncoder.step(created: t0 + 1100, finished: t0 + 1900,
                usage: AntigravityBlobEncoder.usage(input: 200, output: 30)))
        // A just-seeded SQLite source is throttled for 500ms. Deliver the WAL
        // notification immediately, then let the normal dirty read drain it.
        session.handleChanges(atCanonicalPaths: [try canonicalPath(copy) + "-wal"])
        Thread.sleep(forTimeInterval: 0.55)
        session.readDirtyDatabases()
        #expect(Set(session.responses.map(\.key)) == ["antigravity:\(id):1", "antigravity:\(id):2"])
        #expect(session.responses.reduce(0) { $0 + $1.usage.output } == 50)
        let (_, events) = session.advance(nowMs: t0 + 10_000, todayStartMs: t0 - 1000, emitsEvents: true)
        #expect(events.count == 1, "only the new Orca step generates a live completion")
        try resumed.close()
    }
}
