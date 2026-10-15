import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

final class LedgerGenerationPublicationTests: XCTestCase {
    private enum InjectedFailure: Error {
        case secondBatch
        case incrementalAppend
    }

    private struct PublishedSnapshot {
        let state: CodexUsageHistoryIndex.AttributionState
        let eventCount: Int
        let eventTokens: Int
        let attributionTokens: Int
        let certificate: UsageIndexCoverageCertificate?
    }

    func testFailedLaterProductionBatchPreservesPublishedRowsGenerationEpochAndQuery() throws {
        try withFixture { fixture in
            let baseline = try fixture.writeRollout(id: "019eaaaa-bbbb-4ccc-8ddd-000000000000", tokens: 100)
            _ = try synchronize([baseline], in: fixture, parser: productionParser(fixture.analyzer))
            let before = try snapshot(fixture)
            XCTAssertEqual(before.eventCount, 1)
            XCTAssertEqual(before.eventTokens, 100)
            XCTAssertEqual(before.attributionTokens, 100)

            let additions = try stagedRollouts(in: fixture)
            fixture.index.coldBuildHeavyFileThreshold = 1
            let parser: CodexUsageHistoryIndex.SessionParser = { file, sessionID, request, insertFingerprint, emit in
                if file == additions.second {
                    throw InjectedFailure.secondBatch
                }
                return try fixture.analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: sessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }

            XCTAssertThrowsError(try synchronize(
                [baseline, additions.first, additions.second],
                in: fixture,
                parser: parser
            ))

            let after = try snapshot(fixture)
            XCTAssertEqual(after.eventCount, 1, "the failed second batch must not publish the first batch's event")
            XCTAssertEqual(after.eventTokens, 100)
            XCTAssertEqual(after.certificate, before.certificate)
            XCTAssertEqual(after.state.generation, before.state.generation)
            XCTAssertEqual(after.state.provenanceEpoch, before.state.provenanceEpoch)
            XCTAssertFalse(after.state.currentScanUnsafeCauseDetected)
            XCTAssertEqual(
                try attributionTotal(fixture.home, state: before.state),
                100,
                "a query using the previously published generation must still return its baseline"
            )
        }
    }

    func testConcurrentReaderSeesBaselineDuringRetryAndSuccessfulRetryPublishesAllEvents() throws {
        try withFixture { fixture in
            let baseline = try fixture.writeRollout(id: "019eaaaa-bbbb-4ccc-8ddd-000000000000", tokens: 100)
            _ = try synchronize([baseline], in: fixture, parser: productionParser(fixture.analyzer))
            let before = try snapshot(fixture)
            let additions = try stagedRollouts(in: fixture)
            fixture.index.coldBuildHeavyFileThreshold = 1

            let failingParser: CodexUsageHistoryIndex.SessionParser = { file, sessionID, request, insertFingerprint, emit in
                if file == additions.second {
                    throw InjectedFailure.secondBatch
                }
                return try fixture.analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: sessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }
            XCTAssertThrowsError(try synchronize(
                [baseline, additions.first, additions.second],
                in: fixture,
                parser: failingParser
            ))
            let afterFailure = try snapshot(fixture)
            XCTAssertEqual(afterFailure.eventCount, 1)
            XCTAssertEqual(afterFailure.eventTokens, 100)
            XCTAssertEqual(afterFailure.state.generation, before.state.generation)
            XCTAssertEqual(afterFailure.state.provenanceEpoch, before.state.provenanceEpoch)

            // Retry the failed synchronization. The first source is imported
            // into the still-open publication transaction before the second
            // parser runs; an independent read must continue to see the old
            // committed generation at that point.
            let observation = ConcurrentReadObservation()
            let retryParser: CodexUsageHistoryIndex.SessionParser = { file, sessionID, request, insertFingerprint, emit in
                if file == additions.second {
                    let visible = try self.attributionTotal(fixture.home, state: before.state)
                    observation.record(visible)
                }
                return try fixture.analyzer.parseSessionIntoHistoryIndex(
                    file: file,
                    sessionID: sessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: emit
                )
            }

            let retry = try synchronize(
                [baseline, additions.first, additions.second],
                in: fixture,
                parser: retryParser
            )
            XCTAssertEqual(observation.value, 100)
            XCTAssertEqual(retry.changedFiles, 2)

            let published = try snapshot(fixture)
            XCTAssertEqual(published.eventCount, 3)
            XCTAssertEqual(published.eventTokens, 600)
            XCTAssertEqual(published.attributionTokens, 600)
            XCTAssertEqual(published.state.provenanceEpoch, before.state.provenanceEpoch)
            XCTAssertGreaterThan(published.state.generation, before.state.generation)
            XCTAssertEqual(published.certificate?.generation, published.state.generation)
            XCTAssertNotEqual(published.certificate?.scanID, before.certificate?.scanID)
        }
    }

    func testFailedIncrementalAppendRollsBackEventAndPublicationMetadata() throws {
        try withFixture { fixture in
            let file = try fixture.writeRollout(id: "019eaaaa-bbbb-4ccc-8ddd-000000000010", tokens: 100)
            _ = try synchronize([file], in: fixture, parser: productionParser(fixture.analyzer))
            let before = try snapshot(fixture)
            let originalSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            ).uint64Value
            try fixture.appendRolloutLine(to: file, tokens: 150, lastTokens: 50)

            var emittedAppendedEvent = false
            let failingParser: CodexUsageHistoryIndex.SessionParser = { parsedFile, sessionID, request, insertFingerprint, emit in
                try fixture.analyzer.parseSessionIntoHistoryIndex(
                    file: parsedFile,
                    sessionID: sessionID,
                    request: request,
                    insertFingerprint: insertFingerprint,
                    emit: { event in
                        try emit(event)
                        if event.sourceOffset >= originalSize {
                            emittedAppendedEvent = true
                            throw InjectedFailure.incrementalAppend
                        }
                    }
                )
            }

            XCTAssertThrowsError(try synchronize([file], in: fixture, parser: failingParser))
            XCTAssertTrue(emittedAppendedEvent, "the failure must occur after the incremental parser emitted its appended event")

            let after = try snapshot(fixture)
            XCTAssertEqual(after.eventCount, 1)
            XCTAssertEqual(after.eventTokens, 100)
            XCTAssertEqual(after.certificate, before.certificate)
            XCTAssertEqual(after.state.generation, before.state.generation)
            XCTAssertEqual(after.state.provenanceEpoch, before.state.provenanceEpoch)
            XCTAssertEqual(try attributionTotal(fixture.home, state: before.state), 100)
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LedgerGenerationPublication-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let keys = [
            "CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE",
            "CODEX_TOKEN_BAR_USAGE_CACHE_DIR",
            "CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR",
        ]
        let previous = keys.map { key in
            getenv(key).map { String(cString: $0) }
        }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        unsetenv(keys[0])
        setenv(keys[1], cache.path, 1)
        setenv(keys[2], cache.path, 1)

        let analyzer = CodexUsageAnalyzer(
            dataSource: CodexDataSource(codexHome: home, origin: .userSelected)
        )
        let index = try CodexUsageHistoryIndex(codexHome: home)
        try body(Fixture(home: home, sessions: sessions, analyzer: analyzer, index: index))
    }

    private func synchronize(
        _ files: [URL],
        in fixture: Fixture,
        parser: @escaping CodexUsageHistoryIndex.SessionParser
    ) throws -> CodexUsageHistoryIndex.SynchronizationResult {
        try fixture.index.synchronize(
            files: files,
            sessionID: fixture.analyzer.sessionID(from:),
            parser: parser
        )
    }

    private func productionParser(
        _ analyzer: CodexUsageAnalyzer
    ) -> CodexUsageHistoryIndex.SessionParser {
        { file, sessionID, request, insertFingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(
                file: file,
                sessionID: sessionID,
                request: request,
                insertFingerprint: insertFingerprint,
                emit: emit
            )
        }
    }

    private func stagedRollouts(in fixture: Fixture) throws -> (first: URL, second: URL) {
        let first = try fixture.writeRollout(id: "019eaaaa-bbbb-4ccc-8ddd-000000000001", tokens: 200)
        let second = try fixture.writeRollout(id: "019eaaaa-bbbb-4ccc-8ddd-000000000002", tokens: 300)
        XCTAssertLessThan(first.path, second.path, "batch order should be deterministic")
        return (first, second)
    }

    private func snapshot(_ fixture: Fixture) throws -> PublishedSnapshot {
        let state = try fixture.index.attributionState()
        var eventCount = 0
        var eventTokens = 0
        try fixture.index.forEachStoredEvent { stored in
            eventCount += 1
            eventTokens += stored.event.tokens
        }
        return PublishedSnapshot(
            state: state,
            eventCount: eventCount,
            eventTokens: eventTokens,
            attributionTokens: try attributionTotal(fixture.home, state: state),
            certificate: try fixture.index.coverageCertificate()
        )
    }

    private func attributionTotal(
        _ codexHome: URL,
        state: CodexUsageHistoryIndex.AttributionState
    ) throws -> Int {
        let start = Date(timeIntervalSince1970: 1_700_000_100 - 600)
        let end = Date(timeIntervalSince1970: 1_700_000_100 + 600)
        return try CodexUsageHistoryIndex.quotaCycleSourceBuckets(
            codexHome: codexHome,
            provenanceEpoch: state.provenanceEpoch,
            generation: state.generation,
            from: start,
            before: end,
            minuteBucketStarts: []
        ).reduce(0) { $0 + $1.breakdown.totalTokens }
    }
}

private struct Fixture {
    let home: URL
    let sessions: URL
    let analyzer: CodexUsageAnalyzer
    let index: CodexUsageHistoryIndex

    func writeRollout(id: String, tokens: Int) throws -> URL {
        let file = sessions.appendingPathComponent(
            "rollout-2026-01-01T00-00-00-\(id).jsonl"
        )
        try tokenCountLine(timestamp: Date(timeIntervalSince1970: 1_700_000_100), tokens: tokens, lastTokens: tokens)
            .write(to: file)
        return file
    }

    func appendRolloutLine(to file: URL, tokens: Int, lastTokens: Int) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: tokenCountLine(
            timestamp: Date(timeIntervalSince1970: 1_700_000_160),
            tokens: tokens,
            lastTokens: lastTokens
        ))
        try handle.close()
    }

    private func tokenCountLine(timestamp: Date, tokens: Int, lastTokens: Int) throws -> Data {
        func usage(_ value: Int) -> [String: Int] {
            [
                "input_tokens": value,
                "cached_input_tokens": 0,
                "output_tokens": 0,
                "reasoning_output_tokens": 0,
                "total_tokens": value,
            ]
        }
        let object: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": usage(tokens),
                    "last_token_usage": usage(lastTokens),
                ],
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        return data
    }
}

private final class ConcurrentReadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int?

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: Int) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
