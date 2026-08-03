import XCTest
@testable import CodexTokenBar

@MainActor
final class TaskCompletionMonitorTests: XCTestCase {
    func testTimedOutPollDoesNotPermanentlyBlockFuturePolls() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskPollTimeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let loader = TimeoutThenFreshTaskCompletionPollLoader()
        let monitor = TaskCompletionMonitor(
            defaults: isolatedDefaults(),
            pollLoader: loader,
            pollInterval: 0.02,
            pollTimeout: 0.05
        )

        monitor.start(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
        await waitUntil("fresh poll after timeout", timeout: 1) {
            await loader.requestCount() >= 2 && monitor.unreadThreadCount == 1
        }

        let requestCount = await loader.requestCount()
        XCTAssertGreaterThanOrEqual(requestCount, 2)
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        monitor.start(dataSource: nil)
    }

    func testSameIdentityPathRebindCancelsOldPollAndStartsOneNewPathPoll() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskPathRebind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldHome = parent.appendingPathComponent("old-home", isDirectory: true)
        let newHome = parent.appendingPathComponent("new-home", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        let sourceAtOldPath = CodexDataSource(codexHome: oldHome, origin: .userSelected)
        let loader = SuspendedTaskCompletionPollLoader()
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults(), pollLoader: loader)

        monitor.start(dataSource: sourceAtOldPath)
        await waitUntil("old-path task poll") {
            await loader.hasPendingRequest(at: oldHome)
        }
        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["trusted-thread"]))
        let identityGeneration = monitor.sourceIdentityGeneration
        let oldBindingGeneration = monitor.sourceBindingGeneration

        try FileManager.default.moveItem(at: oldHome, to: newHome)
        let sourceAtNewPath = CodexDataSource(codexHome: newHome, origin: .userSelected)
        XCTAssertEqual(sourceAtNewPath.stableIdentityKey, sourceAtOldPath.stableIdentityKey)
        monitor.start(dataSource: sourceAtNewPath)

        XCTAssertEqual(monitor.sourceIdentityGeneration, identityGeneration)
        XCTAssertEqual(monitor.sourceBindingGeneration, oldBindingGeneration + 1)
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        await waitUntil("new-path task poll") {
            await loader.hasPendingRequest(at: newHome)
        }

        await loader.completeRequest(
            at: oldHome,
            output: TaskCompletionPollOutput(
                result: nil,
                runningThreadResult: RunningThreadScanResult(
                    states: [:],
                    summary: RunningThreadSummary(
                        main: 99,
                        subagents: 0,
                        updatedAt: Date(),
                        freshness: .fresh
                    )
                ),
                unreadThreadRead: .available(["old-path-thread"])
            )
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.runningThreadSummary, .loading)

        await loader.completeRequest(
            at: newHome,
            output: TaskCompletionPollOutput(
                result: nil,
                runningThreadResult: RunningThreadScanResult(
                    states: [:],
                    summary: RunningThreadSummary(
                        main: 1,
                        subagents: 2,
                        updatedAt: Date(),
                        freshness: .fresh
                    )
                ),
                unreadThreadRead: .available(["trusted-thread", "new-path-thread"])
            )
        )
        await waitUntil("new-path task completion") {
            monitor.unreadThreadCount == 2
        }
        XCTAssertEqual(monitor.runningThreadSummary.total, 3)

        let requestCount = await loader.requestCount()
        monitor.start(dataSource: sourceAtNewPath)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(monitor.sourceBindingGeneration, oldBindingGeneration + 1)
        let samePathRequestCount = await loader.requestCount()
        XCTAssertEqual(samePathRequestCount, requestCount)
    }

    func testNativeUnreadMarkAllReadClearsCurrentThreadsAndKeepsNewThreadActive() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())

        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["thread-a"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)

        monitor.markAllRead()
        XCTAssertEqual(monitor.unreadThreadCount, 0)

        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["thread-a", "thread-b"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)
    }

    func testCompletionEventsNeverCreateUnreadStateWithoutSidebarMarker() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let first = TaskCompletionEvent(
            id: "event-1",
            threadID: "thread-a",
            title: "First",
            body: "Done"
        )
        let second = TaskCompletionEvent(
            id: "event-2",
            threadID: "thread-b",
            title: "Second",
            body: "Done"
        )

        monitor.applyForTesting(
            result: scanResult(events: [first]),
            unreadThreadRead: .unavailable
        )
        XCTAssertEqual(monitor.unreadThreadCount, 0)

        monitor.markAllRead()
        XCTAssertEqual(monitor.unreadThreadCount, 0)

        monitor.applyForTesting(
            result: scanResult(events: [first, second]),
            unreadThreadRead: .unavailable
        )
        XCTAssertEqual(monitor.unreadThreadCount, 0)
    }

    func testOfficialReadFailureRetainsLastTrustedUnreadValueWithoutFallback() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["official-thread"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")

        let fallbackEvents = [
            TaskCompletionEvent(id: "fallback-1", threadID: "fallback-thread-1", title: "Fallback 1", body: "Done"),
            TaskCompletionEvent(id: "fallback-2", threadID: "fallback-thread-2", title: "Fallback 2", body: "Done")
        ]
        monitor.applyForTesting(
            result: scanResult(events: fallbackEvents),
            unreadThreadRead: .unavailable
        )

        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")
        XCTAssertEqual(monitor.detailText, "Codex 有 1 个未读会话")
    }

    func testOfficialAuthorityRecoveryReplacesRetainedValue() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let fallback = TaskCompletionEvent(
            id: "fallback-event",
            threadID: "fallback-thread",
            title: "Fallback",
            body: "Done"
        )
        monitor.applyForTesting(
            result: scanResult(events: [fallback]),
            unreadThreadRead: .unavailable
        )
        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["official-thread"]))

        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")
        XCTAssertEqual(monitor.detailText, "Codex 有 1 个未读会话")

        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["official-thread"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")
    }

    func testSharedUnreadCorrectnessSequence() throws {
        let sequence = try unreadCorrectnessSequence()
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let sessionsRoot = try makeScannerSessionsRoot(named: "SharedUnreadSequence")
        defer { try? FileManager.default.removeItem(at: sessionsRoot) }
        let sessionFile = sessionsRoot.appendingPathComponent("sequence.jsonl")
        let threadID = try XCTUnwrap(sequence.steps.first?.nativeThreadIDs.first)
        try writeScannerSessionMeta(threadID: threadID, to: sessionFile)
        var states: [String: TaskCompletionFileState] = [:]
        let baseCompletedAt = 1_782_306_000.0

        for step in sequence.steps {
            for completion in step.appendCompletions {
                try appendScannerCompletion(
                    completion,
                    completedAt: baseCompletedAt + completion.completedAtOffsetSeconds,
                    to: sessionFile
                )
            }
            let scan = TaskCompletionScanner.scan(
                sessionsRoot: sessionsRoot,
                previousStates: states,
                seedMode: false,
                seedCutoff: .distantPast
            )
            states = scan.states
            XCTAssertEqual(
                scan.events.map(\.id),
                step.appendCompletions.map(\.expectedCanonicalID),
                step.name
            )
            monitor.applyForTesting(
                result: scan,
                unreadThreadRead: .available(Set(step.nativeThreadIDs))
            )
            if step.action == "markAllRead" {
                monitor.markAllRead()
            }

            XCTAssertEqual(monitor.unreadThreadCount, step.expectedCount, step.name)
            if let expectedLatestTitle = step.expectedLatestTitle {
                XCTAssertEqual(monitor.lastCompletedTitle, expectedLatestTitle, step.name)
            }
        }
    }

    func testLegacyPersistedScannerEventIDSuppressesCanonicalEventAfterUpgrade() throws {
        let defaults = isolatedDefaults()
        let sessionsRoot = try makeScannerSessionsRoot(named: "LegacyUnreadEventID")
        defer { try? FileManager.default.removeItem(at: sessionsRoot) }
        let sessionFile = sessionsRoot.appendingPathComponent("legacy.jsonl")
        let threadID = "019eaaaa-0000-0000-0000-0000000000cc"
        let turnID = "turn-legacy"
        let completedAt = 1_782_306_004.0
        let completion = UnreadCorrectnessCompletion(
            expectedCanonicalID: "\(threadID):\(turnID)",
            threadID: threadID,
            turnID: turnID,
            completedAtOffsetSeconds: 4,
            title: "Legacy completion"
        )
        try writeScannerSessionMeta(threadID: threadID, to: sessionFile)
        try appendScannerCompletion(completion, completedAt: completedAt, to: sessionFile)
        defaults.set(
            ["\(threadID)-\(turnID)-\(Int(completedAt))"],
            forKey: "TaskCompletionMonitor.completedEventIDs.v1"
        )

        let scan = TaskCompletionScanner.scan(
            sessionsRoot: sessionsRoot,
            previousStates: [:],
            seedMode: false,
            seedCutoff: .distantPast
        )
        XCTAssertEqual(scan.events.map(\.id), [completion.expectedCanonicalID])

        let monitor = TaskCompletionMonitor(defaults: defaults)
        monitor.applyForTesting(result: scan, unreadThreadRead: .unavailable)
        XCTAssertEqual(monitor.unreadThreadCount, 0)
        XCTAssertTrue(monitor.lastCompletedTitle.isEmpty)
    }

    func testLiveLoaderSkipsFallbackScannerAcrossRepeatedOfficialAvailability() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskCompletionLiveMerge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let threadID = "019eaaaa-0000-0000-0000-0000000000bb"
        let unreadState: [String: Any] = [
            "electron-persisted-atom-state": [
                "unread-thread-ids-by-host-v1": ["local": [threadID]],
                "flat-project-sidebar-preferences-v1": [
                    "initialized": true,
                    "mode": "project"
                ]
            ],
            "sidebar-project-thread-orders": [
                "local-project": [
                    "sortKey": "updated_at",
                    "threadIds": [threadID]
                ]
            ],
            "pinned-thread-ids": [],
            "projectless-thread-ids": []
        ]
        try JSONSerialization.data(withJSONObject: unreadState).write(
            to: codexHome.appendingPathComponent(".codex-global-state.json")
        )
        let session = sessions.appendingPathComponent("live.jsonl")
        let lines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\",\"cwd\":\"/tmp\",\"thread_source\":\"user\",\"source\":\"desktop\"}}",
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-06-24T13:00:00.000Z\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-live\",\"completed_at\":1782306000}}"
        ]
        try lines.joined(separator: "\n").appending("\n").write(
            to: session,
            atomically: true,
            encoding: .utf8
        )
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)

        let scanner = RecordingTaskCompletionScanner(
            result: TaskCompletionScanResult(states: [:], events: [], fileCount: 0)
        )
        let loader = LiveTaskCompletionPollLoader(scanner: scanner)
        let request = TaskCompletionPollRequest(
            dataSource: source,
            previousStates: [:],
            seedMode: false,
            seedCutoff: Date(timeIntervalSince1970: 0)
        )
        let firstOutput = await loader.load(request: request)
        let secondOutput = await loader.load(request: request)

        guard case let .available(threadIDs) = firstOutput.unreadThreadRead else {
            return XCTFail("Expected official unread state")
        }
        XCTAssertEqual(threadIDs, [threadID])
        guard case .available = secondOutput.unreadThreadRead else {
            return XCTFail("Expected repeated official unread state")
        }
        XCTAssertNil(firstOutput.result)
        XCTAssertNil(secondOutput.result)
        let scannerCallCount = await scanner.callCount()
        XCTAssertEqual(scannerCallCount, 0)
    }

    func testLiveLoaderNeverScansCompletionHistoryForUnreadFallback() async {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskCompletionPollPlan-\(UUID().uuidString)", isDirectory: true)
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let fallbackResult = TaskCompletionScanResult(states: [:], events: [], fileCount: 7)
        let unreadReader = SequencedCodexUnreadThreadReader(results: [
            .available([]),
            .available(["official-thread"]),
            .unavailable
        ])
        let scanner = RecordingTaskCompletionScanner(result: fallbackResult)
        let loader = LiveTaskCompletionPollLoader(unreadReader: unreadReader, scanner: scanner)
        let request = TaskCompletionPollRequest(
            dataSource: source,
            previousStates: [:],
            seedMode: true,
            seedCutoff: Date(timeIntervalSince1970: 100),
            suppressedOfficialThreadIDs: ["suppressed-thread"]
        )

        let emptyOfficial = await loader.load(request: request)
        let scannerCallsAfterOfficialEmpty = await scanner.callCount()
        let populatedOfficial = await loader.load(request: request)
        let unavailable = await loader.load(request: request)

        guard case let .available(emptyIDs) = emptyOfficial.unreadThreadRead else {
            return XCTFail("Expected empty official state to remain available")
        }
        XCTAssertTrue(emptyIDs.isEmpty)
        XCTAssertEqual(scannerCallsAfterOfficialEmpty, 0)
        XCTAssertNil(emptyOfficial.result)
        XCTAssertNil(populatedOfficial.result)
        XCTAssertNil(unavailable.result)
        let scannerCallCount = await scanner.callCount()
        XCTAssertEqual(scannerCallCount, 0)
    }

    func testLiveLoaderAndMonitorIgnoreCompletionAfterNativeAcknowledgement() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskCompletionReactivation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let sessionFile = sessionsRoot.appendingPathComponent("reactivation.jsonl")
        let threadID = "019eaaaa-0000-0000-0000-0000000000ee"
        try writeScannerSessionMeta(threadID: threadID, to: sessionFile)
        try writeOfficialUnreadThreadIDs([threadID], codexHome: codexHome)
        try appendScannerCompletion(
            UnreadCorrectnessCompletion(
                expectedCanonicalID: "\(threadID):pre-read-turn",
                threadID: threadID,
                turnID: "pre-read-turn",
                completedAtOffsetSeconds: 0,
                title: "Pre-read completion"
            ),
            completedAt: 109,
            to: sessionFile
        )

        let clock = MutableTaskCompletionClock(now: Date(timeIntervalSince1970: 100))
        let scanner = CountingForwardingTaskCompletionScanner()
        let loader = LiveTaskCompletionPollLoader(scanner: scanner)
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults(), now: { clock.now })

        let initialOutput = await loader.load(
            request: monitor.pollRequestForTesting(dataSource: source)
        )
        monitor.applyForTesting(output: initialOutput)
        XCTAssertEqual(monitor.unreadThreadCount, 1)

        clock.now = Date(timeIntervalSince1970: 110)
        monitor.markAllRead()
        XCTAssertEqual(monitor.unreadThreadCount, 0)
        let suppressedRequest = monitor.pollRequestForTesting(dataSource: source)
        XCTAssertEqual(suppressedRequest.suppressedOfficialThreadIDs, [threadID])
        XCTAssertTrue(suppressedRequest.seedMode)
        XCTAssertEqual(suppressedRequest.seedCutoff, Date(timeIntervalSince1970: 110))

        try appendScannerCompletion(
            UnreadCorrectnessCompletion(
                expectedCanonicalID: "\(threadID):reactivated-turn",
                threadID: threadID,
                turnID: "reactivated-turn",
                completedAtOffsetSeconds: 0,
                title: "Reactivated completion"
            ),
            completedAt: 111,
            to: sessionFile
        )
        let reactivationOutput = await loader.load(request: suppressedRequest)
        XCTAssertNil(reactivationOutput.result)
        monitor.applyForTesting(output: reactivationOutput)
        XCTAssertEqual(monitor.unreadThreadCount, 0)

        let normalRequest = monitor.pollRequestForTesting(dataSource: source)
        XCTAssertEqual(normalRequest.suppressedOfficialThreadIDs, [threadID])
        let normalOutput = await loader.load(request: normalRequest)
        XCTAssertNil(normalOutput.result)
        monitor.applyForTesting(output: normalOutput)
        let scannerCallCount = await scanner.callCount()
        XCTAssertEqual(scannerCallCount, 0)
    }

    func testAvailableToUnavailableDoesNotSeedCompletionFallback() throws {
        let codexHome = try makeScannerSessionsRoot(named: "FallbackSeedHome")
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let sessionFile = sessionsRoot.appendingPathComponent("transition.jsonl")
        let threadID = "019eaaaa-0000-0000-0000-0000000000dd"
        try writeScannerSessionMeta(threadID: threadID, to: sessionFile)
        try appendScannerCompletion(
            UnreadCorrectnessCompletion(
                expectedCanonicalID: "\(threadID):old-turn",
                threadID: threadID,
                turnID: "old-turn",
                completedAtOffsetSeconds: 0,
                title: "Old completion"
            ),
            completedAt: 199,
            to: sessionFile
        )

        try appendScannerCompletion(
            UnreadCorrectnessCompletion(
                expectedCanonicalID: "\(threadID):new-turn",
                threadID: threadID,
                turnID: "new-turn",
                completedAtOffsetSeconds: 0,
                title: "New completion"
            ),
            completedAt: 201,
            to: sessionFile
        )

        let clock = MutableTaskCompletionClock(now: Date(timeIntervalSince1970: 200))
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults(), now: { clock.now })
        let officialReadRequest = monitor.pollRequestForTesting(dataSource: source)
        clock.now = Date(timeIntervalSince1970: 250)
        monitor.applyForTesting(
            result: nil,
            unreadThreadRead: .available([]),
            officialReadBoundary: officialReadRequest.pollStartedAt
        )

        monitor.applyForTesting(result: nil, unreadThreadRead: .unavailable)
        XCTAssertEqual(monitor.unreadThreadCount, 0)
        let continuedRequest = monitor.pollRequestForTesting(dataSource: source)
        XCTAssertTrue(continuedRequest.seedMode)
        XCTAssertTrue(continuedRequest.previousStates.isEmpty)

        clock.now = Date(timeIntervalSince1970: 300)
        monitor.applyForTesting(result: nil, unreadThreadRead: .available(["official-thread"]))
        XCTAssertEqual(monitor.unreadThreadCount, 1)
        XCTAssertEqual(monitor.statusText, "有未读会话")
        let recoveredRequest = monitor.pollRequestForTesting(dataSource: source)
        XCTAssertTrue(recoveredRequest.seedMode)
        XCTAssertTrue(recoveredRequest.previousStates.isEmpty)
    }

    private func scanResult(events: [TaskCompletionEvent]) -> TaskCompletionScanResult {
        TaskCompletionScanResult(states: [:], events: events, fileCount: 1)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TaskCompletionMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func unreadCorrectnessSequence() throws -> UnreadCorrectnessSequence {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repositoryRoot
            .appendingPathComponent("TestFixtures", isDirectory: true)
            .appendingPathComponent("unread-correctness-sequence.json")
        return try JSONDecoder().decode(UnreadCorrectnessSequence.self, from: Data(contentsOf: fixture))
    }

    private func makeScannerSessionsRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeScannerSessionMeta(threadID: String, to file: URL) throws {
        try appendJSONLine([
            "type": "session_meta",
            "payload": [
                "id": threadID,
                "cwd": "/tmp/unread-sequence",
                "thread_source": "user",
                "source": "desktop"
            ]
        ], to: file)
    }

    private func appendScannerCompletion(
        _ completion: UnreadCorrectnessCompletion,
        completedAt: TimeInterval,
        to file: URL
    ) throws {
        try appendJSONLine([
            "type": "event_msg",
            "payload": [
                "type": "task_started",
                "turn_id": completion.turnID,
                "started_at": completedAt - 1
            ]
        ], to: file)
        try appendJSONLine([
            "type": "event_msg",
            "payload": ["type": "user_message", "message": completion.title]
        ], to: file)
        try appendJSONLine([
            "type": "event_msg",
            "payload": [
                "type": "task_complete",
                "turn_id": completion.turnID,
                "completed_at": completedAt,
                "duration_ms": 1_000
            ]
        ], to: file)
    }

    private func appendJSONLine(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let handle: FileHandle
        if FileManager.default.fileExists(atPath: file.path) {
            handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
        } else {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
        }
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([10]))
    }

    private func writeOfficialUnreadThreadIDs(_ threadIDs: [String], codexHome: URL) throws {
        let unreadState: [String: Any] = [
            "electron-persisted-atom-state": [
                "unread-thread-ids-by-host-v1": ["local": threadIDs],
                "flat-project-sidebar-preferences-v1": [
                    "initialized": true,
                    "mode": "project"
                ]
            ],
            "sidebar-project-thread-orders": [
                "local-project": [
                    "sortKey": "updated_at",
                    "threadIds": threadIDs
                ]
            ],
            "pinned-thread-ids": [],
            "projectless-thread-ids": []
        ]
        try JSONSerialization.data(withJSONObject: unreadState).write(
            to: codexHome.appendingPathComponent(".codex-global-state.json")
        )
    }

    func testRunningThreadFailureRetainsLastGoodCountsAsStale() {
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults())
        let fresh = RunningThreadScanResult(
            states: [:],
            summary: RunningThreadSummary(
                main: 2,
                subagents: 3,
                updatedAt: Date(timeIntervalSince1970: 100),
                freshness: .fresh
            )
        )

        monitor.applyForTesting(
            result: nil,
            unreadThreadRead: .available([]),
            runningThreadResult: fresh
        )
        XCTAssertEqual(monitor.runningThreadSummary.total, 5)
        XCTAssertEqual(monitor.runningThreadSummary.freshness, .fresh)

        monitor.applyForTesting(
            result: nil,
            unreadThreadRead: .available([]),
            runningThreadResult: nil
        )
        XCTAssertEqual(monitor.runningThreadSummary.total, 5)
        XCTAssertEqual(monitor.runningThreadSummary.main, 2)
        XCTAssertEqual(monitor.runningThreadSummary.subagents, 3)
        XCTAssertEqual(monitor.runningThreadSummary.freshness, .stale)
    }

    func testSourceSwitchClearsRunningThreadCountsBeforeNewSourceLoads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunningThreadSourceSwitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstHome = root.appendingPathComponent("first", isDirectory: true)
        let secondHome = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)
        let loader = SuspendedTaskCompletionPollLoader()
        let monitor = TaskCompletionMonitor(defaults: isolatedDefaults(), pollLoader: loader)

        monitor.start(dataSource: CodexDataSource(codexHome: firstHome, origin: .userSelected))
        monitor.applyForTesting(
            result: nil,
            unreadThreadRead: .available([]),
            runningThreadResult: RunningThreadScanResult(
                states: [:],
                summary: RunningThreadSummary(
                    main: 1,
                    subagents: 4,
                    updatedAt: Date(),
                    freshness: .fresh
                )
            )
        )
        XCTAssertEqual(monitor.runningThreadSummary.total, 5)

        monitor.start(dataSource: CodexDataSource(codexHome: secondHome, origin: .userSelected))
        XCTAssertEqual(monitor.runningThreadSummary, .loading)
        XCTAssertTrue(
            monitor.pollRequestForTesting(
                dataSource: CodexDataSource(codexHome: secondHome, origin: .userSelected)
            ).previousRunningThreadStates.isEmpty
        )
        monitor.start(dataSource: nil)
        XCTAssertEqual(monitor.runningThreadSummary, .unavailable)
    }

    func testLiveLoaderRunsRunningScannerWhenOfficialUnreadIsAvailable() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunningThreadOfficialUnread-\(UUID().uuidString)", isDirectory: true)
        let source = CodexDataSource(codexHome: home, origin: .userSelected)
        let completionScanner = RecordingTaskCompletionScanner(
            result: TaskCompletionScanResult(states: [:], events: [], fileCount: 0)
        )
        let expected = RunningThreadScanResult(
            states: [:],
            summary: RunningThreadSummary(
                main: 1,
                subagents: 2,
                updatedAt: Date(timeIntervalSince1970: 200),
                freshness: .fresh
            )
        )
        let runningScanner = RecordingRunningThreadScanner(result: expected)
        let loader = LiveTaskCompletionPollLoader(
            unreadReader: SequencedCodexUnreadThreadReader(results: [.available([])]),
            scanner: completionScanner,
            runningThreadScanner: runningScanner
        )
        let output = await loader.load(
            request: TaskCompletionPollRequest(
                dataSource: source,
                previousStates: [:],
                seedMode: false,
                seedCutoff: .distantPast
            )
        )

        XCTAssertNil(output.result)
        XCTAssertEqual(output.runningThreadResult, expected)
        let completionCallCount = await completionScanner.callCount()
        let runningCallCount = await runningScanner.callCount()
        XCTAssertEqual(completionCallCount, 0)
        XCTAssertEqual(runningCallCount, 1)
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private struct UnreadCorrectnessSequence: Decodable {
    let steps: [UnreadCorrectnessStep]
}

private struct UnreadCorrectnessStep: Decodable {
    let name: String
    let nativeThreadIDs: [String]
    let appendCompletions: [UnreadCorrectnessCompletion]
    let action: String
    let expectedCount: Int
    let expectedLatestTitle: String?
}

private struct UnreadCorrectnessCompletion: Decodable {
    let expectedCanonicalID: String
    let threadID: String
    let turnID: String
    let completedAtOffsetSeconds: TimeInterval
    let title: String
}

private actor SuspendedTaskCompletionPollLoader: TaskCompletionPollLoading {
    private var continuations: [String: CheckedContinuation<TaskCompletionPollOutput, Never>] = [:]
    private var count = 0

    func load(request: TaskCompletionPollRequest) async -> TaskCompletionPollOutput {
        count += 1
        return await withCheckedContinuation { continuation in
            continuations[request.dataSource.codexHome.path] = continuation
        }
    }

    func hasPendingRequest(at codexHome: URL) -> Bool {
        continuations[codexHome.path] != nil
    }

    func completeRequest(at codexHome: URL, output: TaskCompletionPollOutput) {
        continuations.removeValue(forKey: codexHome.path)?.resume(returning: output)
    }

    func requestCount() -> Int {
        count
    }
}

private actor TimeoutThenFreshTaskCompletionPollLoader: TaskCompletionPollLoading {
    private var count = 0

    func load(request: TaskCompletionPollRequest) async -> TaskCompletionPollOutput {
        count += 1
        let requestNumber = count
        if requestNumber == 1 {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                // The monitor deadline should cancel this stale request.
            }
            return TaskCompletionPollOutput(
                result: nil,
                unreadThreadRead: .available(["stale-thread-a", "stale-thread-b"])
            )
        }
        return TaskCompletionPollOutput(
            result: nil,
            unreadThreadRead: .available(["fresh-thread"])
        )
    }

    func requestCount() -> Int {
        count
    }
}

private actor RecordingTaskCompletionScanner: TaskCompletionScanning {
    private let result: TaskCompletionScanResult
    private var requests: [TaskCompletionPollRequest] = []

    init(result: TaskCompletionScanResult) {
        self.result = result
    }

    func scan(request: TaskCompletionPollRequest) -> TaskCompletionScanResult {
        requests.append(request)
        return result
    }

    func callCount() -> Int {
        requests.count
    }
}

private actor RecordingRunningThreadScanner: RunningThreadScanning {
    private let result: RunningThreadScanResult?
    private var count = 0

    init(result: RunningThreadScanResult?) {
        self.result = result
    }

    func scan(request: TaskCompletionPollRequest) -> RunningThreadScanResult? {
        count += 1
        return result
    }

    func callCount() -> Int {
        count
    }
}

private actor CountingForwardingTaskCompletionScanner: TaskCompletionScanning {
    private var count = 0

    func scan(request: TaskCompletionPollRequest) async -> TaskCompletionScanResult {
        count += 1
        return await LiveTaskCompletionScanner().scan(request: request)
    }

    func callCount() -> Int {
        count
    }
}

private actor SequencedCodexUnreadThreadReader: CodexUnreadThreadReading {
    private var results: [CodexUnreadThreadReadResult]

    init(results: [CodexUnreadThreadReadResult]) {
        self.results = results
    }

    func readUnreadThreadIDs(codexHome: URL) -> CodexUnreadThreadReadResult {
        guard !results.isEmpty else { return .unavailable }
        return results.removeFirst()
    }
}

@MainActor
private final class MutableTaskCompletionClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
