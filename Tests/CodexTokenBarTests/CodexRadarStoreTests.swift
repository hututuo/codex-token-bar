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

    func testPublicRefreshDoesNotCallFullDetailReader() async throws {
        let snapshot = try Self.makeSnapshot()
        let detailReader = DetailRadarReaderStub(actions: [.success(snapshot)])
        let store = CodexRadarStore(
            reader: RadarReaderStub(actions: [.success(snapshot)]),
            feedReader: FeedReaderStub(actions: []),
            detailReader: detailReader
        )

        store.refresh()
        await waitUntil("public radar refresh") {
            store.snapshot != nil && !store.isRefreshing
        }

        let detailCallCount = await detailReader.callCountValue()
        XCTAssertEqual(detailCallCount, 0)
        XCTAssertNil(store.detailSnapshot)
    }

    func testScheduledDetailRefreshRunsOnceWhenLatestSlotWasMissed() async throws {
        let snapshot = try Self.makeSnapshot()
        let defaults = try Self.makeDefaults()
        let calendar = Self.detailCalendar
        let now = try Self.detailDate("2026-07-07 09:00")
        let previousSlot = try Self.detailDate("2026-07-06 18:00")
        defaults.set(previousSlot.timeIntervalSince1970, forKey: CodexRadarStore.detailRefreshDefaultsKey)

        let detailReader = DetailRadarReaderStub(actions: [.success(snapshot)])
        let store = CodexRadarStore(
            reader: RadarReaderStub(actions: []),
            feedReader: FeedReaderStub(actions: []),
            detailReader: detailReader,
            detailRefreshDefaults: defaults,
            detailRefreshCalendar: calendar
        )

        store.refreshScheduledDetailIfNeeded(now: now)
        await waitUntil("scheduled detail refresh") {
            store.detailSnapshot != nil && !store.isDetailRefreshing
        }

        let detailCallCount = await detailReader.callCountValue()
        XCTAssertEqual(detailCallCount, 1)
        XCTAssertEqual(store.detailSnapshot, snapshot)
        XCTAssertEqual(defaults.double(forKey: CodexRadarStore.detailRefreshDefaultsKey), now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(CodexRadarDetailRefreshSchedule.shouldRefresh(
            now: now,
            lastSuccessfulRefreshAt: store.lastSuccessfulDetailRefreshAt,
            calendar: calendar
        ))
    }

    func testScheduledDetailFailureRecordsAttemptAndDoesNotRetrySameSlot() async throws {
        let defaults = try Self.makeDefaults()
        let calendar = Self.detailCalendar
        let now = try Self.detailDate("2026-07-07 09:00")
        let previousSlot = try Self.detailDate("2026-07-06 18:00")
        let latestSlot = try Self.detailDate("2026-07-07 08:00")
        defaults.set(previousSlot.timeIntervalSince1970, forKey: CodexRadarStore.detailRefreshDefaultsKey)

        let detailReader = DetailRadarReaderStub(actions: [
            .failure(CodexRadarReaderError.httpStatus(503)),
            .success(try Self.makeSnapshot())
        ])
        let store = CodexRadarStore(
            reader: RadarReaderStub(actions: []),
            feedReader: FeedReaderStub(actions: []),
            detailReader: detailReader,
            detailRefreshDefaults: defaults,
            detailRefreshCalendar: calendar
        )

        store.refreshScheduledDetailIfNeeded(now: now)
        await waitUntil("scheduled detail failure") {
            !store.isDetailRefreshing && !store.detailDiagnostics.isEmpty
        }
        store.refreshScheduledDetailIfNeeded(now: now)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let detailCallCount = await detailReader.callCountValue()
        XCTAssertEqual(detailCallCount, 1)
        XCTAssertEqual(store.lastAttemptedDetailSlotAt, latestSlot)
        XCTAssertEqual(defaults.double(forKey: CodexRadarStore.detailAttemptDefaultsKey), latestSlot.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(store.detailSnapshot)
    }

    func testScheduledDetailCanAttemptAgainForNextSlotAfterFailure() async throws {
        let snapshot = try Self.makeSnapshot()
        let defaults = try Self.makeDefaults()
        let calendar = Self.detailCalendar
        let morningCheck = try Self.detailDate("2026-07-07 09:00")
        let eveningCheck = try Self.detailDate("2026-07-07 19:00")
        let previousSlot = try Self.detailDate("2026-07-06 18:00")
        defaults.set(previousSlot.timeIntervalSince1970, forKey: CodexRadarStore.detailRefreshDefaultsKey)

        let detailReader = DetailRadarReaderStub(actions: [
            .failure(CodexRadarReaderError.httpStatus(503)),
            .success(snapshot)
        ])
        let store = CodexRadarStore(
            reader: RadarReaderStub(actions: []),
            feedReader: FeedReaderStub(actions: []),
            detailReader: detailReader,
            detailRefreshDefaults: defaults,
            detailRefreshCalendar: calendar
        )

        store.refreshScheduledDetailIfNeeded(now: morningCheck)
        await waitUntil("first scheduled detail failure") {
            !store.isDetailRefreshing && !store.detailDiagnostics.isEmpty
        }
        store.refreshScheduledDetailIfNeeded(now: eveningCheck)
        await waitUntil("next slot scheduled detail success") {
            store.detailSnapshot != nil && !store.isDetailRefreshing
        }

        let detailCallCount = await detailReader.callCountValue()
        XCTAssertEqual(detailCallCount, 2)
        XCTAssertEqual(store.detailSnapshot, snapshot)
        XCTAssertEqual(store.lastAttemptedDetailSlotAt, try Self.detailDate("2026-07-07 18:00"))
    }

    func testManualDetailRefreshCanRetryAfterScheduledFailure() async throws {
        let snapshot = try Self.makeSnapshot()
        let defaults = try Self.makeDefaults()
        let calendar = Self.detailCalendar
        let now = try Self.detailDate("2026-07-07 09:00")
        let previousSlot = try Self.detailDate("2026-07-06 18:00")
        defaults.set(previousSlot.timeIntervalSince1970, forKey: CodexRadarStore.detailRefreshDefaultsKey)

        let detailReader = DetailRadarReaderStub(actions: [
            .failure(CodexRadarReaderError.httpStatus(503)),
            .success(snapshot)
        ])
        let store = CodexRadarStore(
            reader: RadarReaderStub(actions: []),
            feedReader: FeedReaderStub(actions: []),
            detailReader: detailReader,
            detailRefreshDefaults: defaults,
            detailRefreshCalendar: calendar
        )

        store.refreshScheduledDetailIfNeeded(now: now)
        await waitUntil("scheduled detail failure") {
            !store.isDetailRefreshing && !store.detailDiagnostics.isEmpty
        }
        store.refreshDetail()
        await waitUntil("manual detail retry success") {
            store.detailSnapshot != nil && !store.isDetailRefreshing
        }

        let detailCallCount = await detailReader.callCountValue()
        XCTAssertEqual(detailCallCount, 2)
        XCTAssertEqual(store.detailSnapshot, snapshot)
        XCTAssertNotNil(store.lastSuccessfulDetailRefreshAt)
    }

    func testStopPreventsInFlightScheduledDetailRefreshFromPublishingSnapshot() async throws {
        let snapshot = try Self.makeSnapshot()
        let defaults = try Self.makeDefaults()
        let calendar = Self.detailCalendar
        let now = try Self.detailDate("2026-07-07 09:00")
        let previousSlot = try Self.detailDate("2026-07-06 18:00")
        defaults.set(previousSlot.timeIntervalSince1970, forKey: CodexRadarStore.detailRefreshDefaultsKey)

        let detailReader = DelayedDetailRadarReader()
        let store = CodexRadarStore(
            reader: RadarReaderStub(actions: []),
            feedReader: FeedReaderStub(actions: []),
            detailReader: detailReader,
            detailRefreshDefaults: defaults,
            detailRefreshCalendar: calendar
        )

        store.refreshScheduledDetailIfNeeded(now: now)
        await waitUntil("scheduled detail request pending") {
            let hasPendingRequest = await detailReader.hasPendingRequest()
            return store.isDetailRefreshing && hasPendingRequest
        }
        store.stop()
        await detailReader.finish(with: snapshot)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(store.detailSnapshot)
        XCTAssertFalse(store.isDetailRefreshing)
    }

    func testScheduledDetailRefreshSkipsWhenLatestSlotAlreadySucceeded() async throws {
        let snapshot = try Self.makeSnapshot()
        let defaults = try Self.makeDefaults()
        let calendar = Self.detailCalendar
        let now = try Self.detailDate("2026-07-07 09:00")
        let latestSlot = try Self.detailDate("2026-07-07 08:00")
        defaults.set(latestSlot.timeIntervalSince1970, forKey: CodexRadarStore.detailRefreshDefaultsKey)

        let detailReader = DetailRadarReaderStub(actions: [.success(snapshot)])
        let store = CodexRadarStore(
            reader: RadarReaderStub(actions: []),
            feedReader: FeedReaderStub(actions: []),
            detailReader: detailReader,
            detailRefreshDefaults: defaults,
            detailRefreshCalendar: calendar
        )

        store.refreshScheduledDetailIfNeeded(now: now)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let detailCallCount = await detailReader.callCountValue()
        XCTAssertEqual(detailCallCount, 0)
        XCTAssertNil(store.detailSnapshot)
        XCTAssertFalse(store.isDetailRefreshing)
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

    private static func makeDefaults() throws -> UserDefaults {
        let suiteName = "CodexRadarStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static var detailCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func detailDate(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = detailCalendar
        formatter.timeZone = detailCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
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

private actor DetailRadarReaderStub: CodexRadarDetailReading {
    private var actions: [RadarReaderAction]
    private(set) var callCount = 0

    init(actions: [RadarReaderAction]) {
        self.actions = actions
    }

    func readRadarDetail() async throws -> CodexRadarSnapshot {
        callCount += 1
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

    func callCountValue() -> Int {
        callCount
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

private actor DelayedDetailRadarReader: CodexRadarDetailReading {
    private var continuation: CheckedContinuation<CodexRadarSnapshot, Error>?

    func readRadarDetail() async throws -> CodexRadarSnapshot {
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
