import Foundation
import os
import Testing
@testable import AgentSpeedCore

@MainActor
@Suite("Live monitor", .serialized)
struct LiveMonitorTests {
    static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func observationMergeKeepsEarliestAndUnknownResolution() {
        let earliest = SourceReadObservation(
            observedAtMs: 1_000,
            observedTickMs: 100,
            sourceMode: "log",
            sourceResolutionMs: nil
        )
        let later = SourceReadObservation(
            observedAtMs: 2_000,
            observedTickMs: 200,
            sourceMode: "poll",
            sourceResolutionMs: 1_000
        )

        let merged = earliest.merged(with: later)
        #expect(merged.observedAtMs == earliest.observedAtMs)
        #expect(merged.observedTickMs == earliest.observedTickMs)
        #expect(merged.sourceMode == "mixed")
        #expect(merged.sourceResolutionMs == nil)
    }

    @Test func timerTickDoesNotReissueAnObservation() {
        let store = SpeedStore()
        let observation = SourceReadObservation(
            observedAtMs: 1_000,
            observedTickMs: 100,
            sourceMode: "log",
            sourceResolutionMs: 0
        )
        var delivered: [SourceReadObservation?] = []
        let listener = store.addLiveListener { snapshot in delivered.append(snapshot.readObservation) }

        var observedSnapshot = SpeedSnapshot.empty
        observedSnapshot.readObservation = observation
        store.publishLive(observedSnapshot)

        var timerSnapshot = observedSnapshot
        timerSnapshot.timestamp = Date()
        timerSnapshot.readObservation = nil
        store.publishLive(timerSnapshot)
        store.removeLiveListener(listener)

        #expect(delivered.count == 2)
        #expect(delivered[0] == observation)
        #expect(delivered[1] == nil)
        #expect(store.liveSnapshot.readObservation == nil)
    }

    @Test func mailboxKeepsTheEarliestObservationWhenItCoalescesSnapshots() async throws {
        let received = Received()
        let mailbox = SnapshotMailbox { snapshot, _ in received.snapshots.append(snapshot) }
        let earliest = SourceReadObservation(
            observedAtMs: 1_000,
            observedTickMs: 100,
            sourceMode: "log",
            sourceResolutionMs: 0
        )
        let later = SourceReadObservation(
            observedAtMs: 2_000,
            observedTickMs: 200,
            sourceMode: "poll",
            sourceResolutionMs: 1_000
        )
        var first = SpeedSnapshot.empty
        first.readObservation = earliest
        var second = SpeedSnapshot.empty
        second.readObservation = later

        mailbox.post(first)
        mailbox.post(second)
        mailbox.post(.empty) // A timer snapshot must not erase the still-unbuilt observation.
        #expect(await Self.waitUntil { !received.snapshots.isEmpty })
        mailbox.close()

        let merged = try #require(received.snapshots.first?.readObservation)
        #expect(merged.observedAtMs == earliest.observedAtMs)
        #expect(merged.observedTickMs == earliest.observedTickMs)
        #expect(merged.sourceMode == "mixed")
        #expect(merged.sourceResolutionMs == 1_000)
    }

    @Test func reportsNoSourcesWhenRootsAreMissing() async throws {
        let directory = try TempDirectory()
        let store = SpeedStore()
        let monitor = LiveMonitor(store: store, configuration: MonitorConfiguration(
            codexRoot: directory.file("missing-codex"),
            claudeRoot: directory.file("missing-claude"),
            dshRoot: directory.file("missing-dsh"),
            opencodeRoot: directory.file("missing-opencode"),
            geminiRoot: directory.file("missing-gemini"),
            ompRoot: directory.file("missing-omp"),
            antigravityRoot: directory.file("missing-antigravity"),
            workbuddyRoot: directory.file("missing-workbuddy"),
            workbuddyAiRoot: directory.file("missing-workbuddy-ai"),
            zcodeRoot: directory.file("missing-zcode"),
            kimiRoot: directory.file("missing-kimi"),
            grokBuildRoot: directory.file("missing-grok-build")
        ))
        monitor.start()
        defer { monitor.stop() }
        #expect(await Self.waitUntil { store.snapshot.state == .noSources })
        #expect(store.snapshot.sources.map(\.kind) == SourceKind.allCases)
        #expect(store.snapshot.sources.allSatisfy { !$0.available && $0.enabled })
    }

    @Test func seedsThenStreamsLiveCompletions() async throws {
        let (directory, configuration) = try SessionTests.makeFixtureRoots()
        let store = SpeedStore()
        var completions: [ResponseSummary] = []
        store.addEventListener { event in
            if case .responseCompleted(let summary) = event { completions.append(summary) }
        }
        let monitor = LiveMonitor(store: store, configuration: configuration)
        monitor.start()
        defer { monitor.stop() }

        #expect(await Self.waitUntil { store.snapshot.state == .running })
        let snapshot = store.snapshot
        #expect(snapshot.sources.count == SourceKind.allCases.count)
        #expect(snapshot.sources.first { $0.kind == .codex }?.available == true)
        #expect(snapshot.sources.first { $0.kind == .deepseek }?.available == true)
        #expect(snapshot.warnings.contains(.malformedLines(2)))
        #expect(snapshot.history.count == 300)
        #expect(completions.isEmpty, "seeded responses never produce live events")

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let relative = "claude/projects/-Users-dev-projects-orbit/s-desk.jsonl"
        try directory.append(relative, [
            #"{"type":"user","entrypoint":"claude-desktop","cwd":"/w/orbit","message":{"role":"user","content":"go"},"timestamp":"\#(formatter.string(from: now.addingTimeInterval(-2)))"}"#,
            #"{"type":"assistant","entrypoint":"claude-desktop","cwd":"/w/orbit","message":{"id":"msg_live","model":"m","stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":200}},"timestamp":"\#(formatter.string(from: now))"}"#,
        ].joined(separator: "\n") + "\n")

        #expect(await Self.waitUntil { !completions.isEmpty })
        #expect(completions.first?.source == .claudeDesktop)
        #expect(completions.first?.outputTokens == 200)
        #expect(await Self.waitUntil { store.snapshot.live.output > 0 })
        #expect(store.snapshot.agents.contains { $0.id.hasSuffix("s-desk.jsonl") })
    }

    @Test func streamsAntigravityCompletionsFromTheWAL() async throws {
        let directory = try TempDirectory()
        let store = directory.file("antigravity-cli")
        let folder = store.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Clock.milliseconds(Date())
        let writer = try ConversationWriter(path: folder.appendingPathComponent("6f0e0d0c-0b0a-4908-8706-050403020100.db").path,
                                            trajectory: AntigravityBlobEncoder.trajectory(created: now - 60_000, uris: ["file:///w/comet"]))
        defer { try? writer.close() }
        try writer.step(0, type: AntigravityStep.userInput, status: 3, AntigravityBlobEncoder.step(created: now - 5000, completed: now - 4990))
        let speeds = SpeedStore()
        var completions: [ResponseSummary] = []
        speeds.addEventListener { event in
            if case .responseCompleted(let summary) = event { completions.append(summary) }
        }
        let monitor = LiveMonitor(store: speeds, configuration: MonitorConfiguration(enabledSources: [.antigravity], antigravityRoot: store))
        monitor.start()
        defer { monitor.stop() }
        #expect(await Self.waitUntil { speeds.snapshot.state == .running })
        #expect(speeds.snapshot.agents.first?.phase == .generating, "a user input starts the model call")

        try writer.step(1, type: AntigravityStep.plannerResponse, status: 3,
                        AntigravityTests.plannerDone(now - 4900, Clock.milliseconds(Date()), output: 250, id: "live-ag-1"))
        #expect(await Self.waitUntil { !completions.isEmpty })
        #expect(completions.first?.source == .antigravity && completions.first?.project == "comet")
        #expect(completions.first?.outputTokens == 250)
        #expect(speeds.snapshot.sources.first { $0.kind == .antigravity }?.today.output == 250)
    }

    @Test func streamsOpencodeCompletionsFromTheDatabase() async throws {
        let db = try OpencodeTests.LiveDatabase()
        let now = Clock.milliseconds(Date())
        try db.addSession("ses_live", at: now - 60_000)
        let store = SpeedStore()
        var completions: [ResponseSummary] = []
        store.addEventListener { event in
            if case .responseCompleted(let summary) = event { completions.append(summary) }
        }
        let monitor = LiveMonitor(store: store, configuration: MonitorConfiguration(
            enabledSources: [.opencode], opencodeRoot: db.directory.url))
        monitor.start()
        defer { monitor.stop() }
        #expect(await Self.waitUntil { store.snapshot.state == .running })
        #expect(store.snapshot.sources.first { $0.kind == .opencode }?.available == true)

        try db.upsertRow("a_live", session: "ses_live", seq: 1, type: "assistant", created: now - 2000, updated: now,
                         data: OpencodeTests.LiveDatabase.assistant(created: now - 2000, streamed: now - 10, output: 300))
        #expect(await Self.waitUntil { !completions.isEmpty })
        #expect(completions.map(\.source) == [.opencode])
        #expect(completions.first?.outputTokens == 300)
        #expect(completions.first?.project == "atlas")
        #expect(await Self.waitUntil { store.snapshot.agents.contains { $0.id == "opencode:ses_live" } })
        #expect(store.snapshot.sources.first { $0.kind == .opencode }?.sessionCount == 1)
    }

    @MainActor
    final class Received {
        var snapshots: [SpeedSnapshot] = []
        var completions: [ResponseSummary] = []
    }

    @Test func aSlowWholeFileReadDoesNotPausePublishing() async throws {
        let directory = try TempDirectory()
        try FileManager.default.createDirectory(at: directory.file("codex/sessions"), withIntermediateDirectories: true)
        let received = Received()
        let mailbox = SnapshotMailbox { snapshot, events in
            received.snapshots.append(snapshot)
            for case .responseCompleted(let summary) in events { received.completions.append(summary) }
        }
        let gate = DispatchSemaphore(value: 0)
        let reading = OSAllocatedUnfairLock(initialState: false)
        let core = MonitorCore(
            configuration: MonitorConfiguration(enabledSources: [.codex], codexRoot: directory.file("codex/sessions")),
            mailbox: mailbox,
            wholeFileReadHook: { _ in
                reading.withLock { $0 = true }
                _ = gate.wait(timeout: .now() + 10)
            }
        )
        core.start()
        defer {
            gate.signal()
            mailbox.close()
            core.stop()
        }
        #expect(await Self.waitUntil { received.snapshots.last?.state == .running })

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        try directory.write("codex/sessions/rollout-z.jsonl.zst", bytes: ZstdFrames.raw([
            #"{"timestamp":"\#(formatter.string(from: now.addingTimeInterval(-3)))","type":"session_meta","payload":{"id":"t-z","cwd":"/w/zip"}}"#,
            #"{"timestamp":"\#(formatter.string(from: now.addingTimeInterval(-2)))","type":"event_msg","payload":{"type":"user_message","message":"x"}}"#,
            #"{"timestamp":"\#(formatter.string(from: now))","type":"token_usage_record","payload":{"response_id":"z-live","usage":{"input_tokens":5,"output_tokens":42}}}"#,
        ].joined(separator: "\n") + "\n"))
        // FSEvents or, at the latest, the 10-second rediscovery starts the read.
        #expect(await Self.waitUntil(timeout: 15) { reading.withLock { $0 } })
        let published = received.snapshots.count
        try await Task.sleep(for: .milliseconds(1600))
        #expect(received.snapshots.count >= published + 2, "snapshots keep coming while the read is blocked")
        #expect(received.completions.isEmpty)

        gate.signal()
        #expect(await Self.waitUntil { !received.completions.isEmpty })
        #expect(received.completions.map(\.outputTokens) == [42])
    }

    @Test func restartsOnlyWhenRootsOrSourcesChange() throws {
        let store = SpeedStore()
        let monitor = LiveMonitor(store: store)
        var configuration = monitor.configuration
        configuration.codexRoot = LiveMonitor.defaultCodexRoot
        #expect(!configuration.requiresRescan(comparedTo: monitor.configuration))
        configuration.dshRoot = LiveMonitor.defaultDshRoot
        #expect(!configuration.requiresRescan(comparedTo: monitor.configuration))
        configuration.dshRoot = URL(fileURLWithPath: "/elsewhere/sessions", isDirectory: true)
        #expect(configuration.requiresRescan(comparedTo: monitor.configuration))
        configuration.dshRoot = nil
        configuration.enabledSources = [.codex]
        #expect(configuration.requiresRescan(comparedTo: monitor.configuration))
    }
}
