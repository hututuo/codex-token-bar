import XCTest
@testable import CodexTokenBar

final class MultiClientCacheRankingTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-cache-ranking-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func event(
        _ id: String,
        client: UsageClient = .claudeCode,
        session: String,
        model: String,
        timestamp: TimeInterval,
        input: Int64,
        output: Int64 = 10,
        cacheRead: Int64?,
        cacheWrite: Int64? = 0
    ) -> ClientUsageEvent {
        ClientUsageEvent(
            client: client,
            eventID: id,
            sessionID: session,
            model: model,
            timestamp: Date(timeIntervalSince1970: timestamp),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
    }

    func testProjectionRanksRequestsAndComputesWeightedSessionTotals() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        _ = try ledger.ingest([
            event("zero", session: "weighted", model: "claude-opus-5", timestamp: 10, input: 30_000, cacheRead: 0, cacheWrite: 2_000),
            event("low", session: "weighted", model: "claude-sonnet-5", timestamp: 20, input: 100_000, cacheRead: 20_000, cacheWrite: 10_000),
            event("high", session: "weighted", model: "claude-opus-5", timestamp: 30, input: 100_000, cacheRead: 80_000),
            event("unknown", session: "unknown-cache", model: "claude-haiku-5", timestamp: 70, input: 150_000, cacheRead: nil, cacheWrite: nil),
            event("known-zero", session: "unknown-cache", model: "claude-sonnet-5", timestamp: 50, input: 30_000, cacheRead: 0),
            event("low-boundary", session: "boundary", model: "claude-opus-5", timestamp: 40, input: 20_000, cacheRead: 5_999),
            event("not-low-boundary", session: "boundary", model: "claude-opus-5", timestamp: 60, input: 20_000, cacheRead: 6_000),
            event("under-minimum", session: "small", model: "claude-opus-5", timestamp: 80, input: 999, cacheRead: 0),
            event("other-client", client: .gemini, session: "other", model: "gemini-3", timestamp: 90, input: 300_000, cacheRead: 0)
        ])

        let projection = try ledger.cacheRankingProjection(clients: [.claudeCode], order: .lowestHit, requestLimit: 4)

        XCTAssertEqual(projection.requests.map(\.eventID), ["known-zero", "zero", "low", "low-boundary"])
        XCTAssertEqual(projection.matchingRequestCount, 7)
        XCTAssertEqual(projection.requestLimit, 4)
        XCTAssertTrue(projection.hasMoreRequests)
        XCTAssertFalse(projection.sessions.contains { $0.sessionID == "small" })
        XCTAssertTrue(projection.requests.allSatisfy(\.isRankable))
        XCTAssertTrue(projection.requests[0].isZeroHit)
        XCTAssertTrue(projection.requests[0].isLowHit)
        XCTAssertTrue(projection.requests[1].isLowHit)
        XCTAssertTrue(projection.requests[2].isLowHit)
        let low = try XCTUnwrap(projection.requests.first { $0.eventID == "low" })
        XCTAssertEqual(low.cacheHitRate ?? -1, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(low.cacheWriteTokens ?? -1, 10_000)
        XCTAssertEqual(low.uncachedInputTokens ?? -1, 80_000)

        let weighted = try XCTUnwrap(projection.sessions.first { $0.sessionID == "weighted" })
        XCTAssertEqual(weighted.inputTokens, 230_000)
        XCTAssertEqual(weighted.cacheReadTokens ?? -1, 100_000)
        XCTAssertEqual(weighted.cacheHitRate ?? -1, 100_000.0 / 230_000.0, accuracy: 0.000_001)
        XCTAssertEqual(weighted.cacheWriteTokens ?? -1, 12_000)
        XCTAssertEqual(weighted.requests, 3)
        XCTAssertEqual(weighted.firstSeen, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(weighted.lastSeen, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(weighted.modelIDs, ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(weighted.lowHitRequests, 2)
        XCTAssertEqual(weighted.zeroHitRequests, 1)
    }

    func testUnknownCacheReadRemainsNilAndDoesNotBecomeZeroHit() throws {
        let root = try temporaryDirectory()
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        _ = try ledger.ingest([
            event("known", session: "s", model: "claude-sonnet-5", timestamp: 10, input: 30_000, cacheRead: 0),
            event("unknown", session: "s", model: "claude-opus-5", timestamp: 20, input: 100_000, cacheRead: nil, cacheWrite: nil)
        ])

        let projection = try ledger.cacheRankingProjection(clients: [.claudeCode], order: .latest)
        let unknown = try XCTUnwrap(projection.requests.first { $0.eventID == "unknown" })
        XCTAssertNil(unknown.cacheReadTokens)
        XCTAssertNil(unknown.cacheHitRate)
        XCTAssertFalse(unknown.isRankable)
        XCTAssertFalse(unknown.isZeroHit)
        XCTAssertFalse(unknown.isLowHit)

        let session = try XCTUnwrap(projection.sessions.first)
        XCTAssertNil(session.cacheReadTokens)
        XCTAssertNil(session.cacheHitRate)
        XCTAssertEqual(session.unknownCacheReadRequests, 1)
        XCTAssertEqual(session.unknownCacheWriteRequests, 1)
        XCTAssertEqual(session.zeroHitRequests, 1, "known zero remains countable beside an unknown request")
        XCTAssertEqual(session.lowHitRequests, 1)
    }

    func testReadOnlyProjectionDoesNotChangeLedgerVersionOrRevisionHistory() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        _ = try ledger.ingest([event("one", session: "s", model: "claude-opus-5", timestamp: 10, input: 2_000, cacheRead: 100)])
        let beforeRevisionCount = try XCTUnwrap(ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first)
        let beforeVersion = try XCTUnwrap(ledger.database.readRows("PRAGMA user_version") { $0.int(0) }.first)

        let projection = try MultiClientUsageLedger.readOnlyCacheRankingProjection(url: url, clients: [.claudeCode])

        XCTAssertEqual(projection.requests.count, 1)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first, beforeRevisionCount)
        XCTAssertEqual(try ledger.database.readRows("PRAGMA user_version") { $0.int(0) }.first, beforeVersion)
    }

    @MainActor
    func testStoreReturnsEmptyForMissingLedgerWithoutCreatingIt() async throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("missing.sqlite")
        let suiteName = "multi-cache-ranking-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: url)

        let projection = try await store.cacheRankingProjection(clients: Set([.claudeCode]))

        XCTAssertEqual(projection.requests, [])
        XCTAssertEqual(projection.sessions, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
