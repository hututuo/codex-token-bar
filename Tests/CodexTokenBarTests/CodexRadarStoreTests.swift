import XCTest
@testable import CodexTokenBar

@MainActor
final class CodexRadarStoreTests: XCTestCase {
    func testInitialRadarFailureExposesDiagnosticWithoutStaleSnapshot() async throws {
        let reader = RadarReaderStub(actions: [
            .failure(URLError(.notConnectedToInternet))
        ])
        let store = CodexRadarStore(reader: reader, feedReader: FeedReaderStub(actions: []))

        store.refresh()

        await waitUntil("initial radar failure") {
            !store.isRefreshing && !store.diagnostics.isEmpty
        }
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.staleDataDisplayed)
        XCTAssertFalse(store.feedStaleDataDisplayed)
        XCTAssertEqual(store.diagnostics.map(\.category), [.networkFetch])
        XCTAssertNotNil(store.lastFailureAt)
        XCTAssertNil(store.lastSuccessfulRefreshAt)
    }

    func testRootFailureAfterSuccessPreservesSnapshotAndMarksStale() async throws {
        let snapshot = try Self.makeSnapshot()
        let feedItem = Self.makeFeedItem(guid: "rss-1")
        let reader = RadarReaderStub(actions: [
            .success(snapshot),
            .failure(CodexRadarReaderError.httpStatus(500))
        ])
        let feedReader = FeedReaderStub(actions: [
            .success([feedItem])
        ])
        let store = CodexRadarStore(reader: reader, feedReader: feedReader)

        store.refresh()
        await waitUntil("first radar success") {
            store.snapshot != nil && !store.isRefreshing
        }
        store.refresh()
        await waitUntil("stale radar failure") {
            store.staleDataDisplayed && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.feedItems, [feedItem])
        XCTAssertEqual(store.diagnostics.map(\.category), [.httpServer, .staleCachedData])
        XCTAssertFalse(store.feedStaleDataDisplayed)
        XCTAssertNotNil(store.lastSuccessfulRefreshAt)
        XCTAssertNotNil(store.lastFailureAt)
    }

    func testRSSFailureAfterRootSuccessPreservesPriorFeedAndReportsPartialFailure() async throws {
        let snapshot = try Self.makeSnapshot()
        let feedItem = Self.makeFeedItem(guid: "rss-1")
        let reader = RadarReaderStub(actions: [
            .success(snapshot),
            .success(snapshot)
        ])
        let feedReader = FeedReaderStub(actions: [
            .success([feedItem]),
            .failure(CodexRadarFeedParserError.invalidXML)
        ])
        let store = CodexRadarStore(reader: reader, feedReader: feedReader)

        store.refresh()
        await waitUntil("radar success with feed") {
            store.feedItems == [feedItem] && !store.isRefreshing
        }
        store.refresh()
        await waitUntil("rss failure diagnostic") {
            store.feedStaleDataDisplayed && !store.isRefreshing
        }

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.feedItems, [feedItem])
        XCTAssertFalse(store.staleDataDisplayed)
        XCTAssertEqual(store.diagnostics.map(\.category), [.rssFailure])
        XCTAssertEqual(store.diagnostics.first?.underlyingCategory, .parseFailure)
        XCTAssertNotNil(store.lastSuccessfulRefreshAt)
        XCTAssertNotNil(store.lastFailureAt)
    }

    func testFullSuccessClearsPriorRadarDiagnosticsAndStaleFlags() async throws {
        let snapshot = try Self.makeSnapshot()
        let oldFeed = Self.makeFeedItem(guid: "rss-old")
        let newFeed = Self.makeFeedItem(guid: "rss-new")
        let reader = RadarReaderStub(actions: [
            .success(snapshot),
            .success(snapshot),
            .success(snapshot)
        ])
        let feedReader = FeedReaderStub(actions: [
            .success([oldFeed]),
            .failure(CodexRadarReaderError.httpStatus(503)),
            .success([newFeed])
        ])
        let store = CodexRadarStore(reader: reader, feedReader: feedReader)

        store.refresh()
        await waitUntil("initial success") {
            store.feedItems == [oldFeed] && !store.isRefreshing
        }
        store.refresh()
        await waitUntil("partial failure") {
            !store.diagnostics.isEmpty && !store.isRefreshing
        }
        store.refresh()
        await waitUntil("full success clears diagnostics") {
            store.diagnostics.isEmpty && store.feedItems == [newFeed] && !store.isRefreshing
        }

        XCTAssertFalse(store.staleDataDisplayed)
        XCTAssertFalse(store.feedStaleDataDisplayed)
        XCTAssertEqual(store.feedItems, [newFeed])
    }

    func testRadarDiagnosticClassifiesTimeoutHTTPParseAndEmptyPayload() {
        XCTAssertEqual(
            CodexRadarDiagnostic.classify(source: .current, error: URLError(.timedOut)).category,
            .timeout
        )
        XCTAssertEqual(
            CodexRadarDiagnostic.classify(source: .current, error: CodexRadarReaderError.httpStatus(429)).category,
            .httpRateLimited
        )
        XCTAssertEqual(
            CodexRadarDiagnostic.classify(source: .current, error: CodexRadarReaderError.invalidResponse).category,
            .parseFailure
        )
        XCTAssertEqual(
            CodexRadarDiagnostic.classify(source: .current, error: CodexRadarReaderError.emptyPayload).category,
            .emptyRadar
        )
    }

    func testStopPreventsInFlightRefreshFromPublishingSnapshot() async throws {
        let snapshot = try Self.makeSnapshot()
        let reader = DelayedRadarReader()
        let store = CodexRadarStore(reader: reader, feedReader: FeedReaderStub(actions: []))

        store.refresh()
        await waitUntil("radar request pending") {
            let hasPendingRequest = await reader.hasPendingRequest()
            return store.isRefreshing && hasPendingRequest
        }
        store.stop()
        await reader.finish(with: snapshot)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(store.diagnostics.isEmpty)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 1,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private static func makeSnapshot() throws -> CodexRadarSnapshot {
        try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(CodexRadarModelsTests.sampleJSON.utf8))
    }

    private static func makeFeedItem(guid: String) -> CodexRadarFeedItem {
        CodexRadarFeedItem(
            title: "Radar item \(guid)",
            link: "https://codexradar.com/\(guid)",
            guid: guid,
            pubDate: "Wed, 17 Jun 2026 21:25:51 GMT",
            description: "Codex Radar feed item"
        )
    }
}

private enum RadarReaderAction: Sendable {
    case success(CodexRadarSnapshot)
    case failure(any Error & Sendable)
}

private actor RadarReaderStub: CodexRadarReading {
    private var actions: [RadarReaderAction]

    init(actions: [RadarReaderAction]) {
        self.actions = actions
    }

    func readRadar() async throws -> CodexRadarSnapshot {
        guard !actions.isEmpty else {
            throw CodexRadarReaderError.invalidResponse
        }
        let action = actions.removeFirst()
        switch action {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}

private enum FeedReaderAction: Sendable {
    case success([CodexRadarFeedItem])
    case failure(any Error & Sendable)
}

private actor FeedReaderStub: CodexRadarFeedReading {
    private var actions: [FeedReaderAction]

    init(actions: [FeedReaderAction]) {
        self.actions = actions
    }

    func readFeed(from url: URL) async throws -> [CodexRadarFeedItem] {
        guard !actions.isEmpty else {
            return []
        }
        let action = actions.removeFirst()
        switch action {
        case .success(let items):
            return items
        case .failure(let error):
            throw error
        }
    }
}

private actor DelayedRadarReader: CodexRadarReading {
    private var continuation: CheckedContinuation<CodexRadarSnapshot, Error>?

    func readRadar() async throws -> CodexRadarSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingRequest() -> Bool {
        continuation != nil
    }

    func finish(with snapshot: CodexRadarSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
