import XCTest
@testable import CodexTokenBar

@MainActor
final class QuotaCycleUsageCoverageTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture")
    private var identity: QuotaHistoryIdentity {
        // These fixed fixture values satisfy the failable identity validator.
        QuotaHistoryIdentity(homeIdentity: home.path, stableAccountKey: "a", planType: "Plus", limitID: "codex")!
    }
    private func d(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }
    private func breakdown(_ tokens: Int, cached: Int = 0, output: Int = 0) -> TokenCacheBreakdown {
        .init(inputTokens: tokens, cachedInputTokens: cached, outputTokens: output,
              reasoningOutputTokens: 0, totalTokens: tokens + output, calls: 1)
    }
    private func event(_ at: Double, _ tokens: Int, model: String? = "gpt-5.6-sol") -> TokenCacheAttributionEvent {
        .init(id: "fixture:\(at):\(model ?? "unknown")", start: d(at), model: model, breakdown: breakdown(tokens))
    }
    private func cycle(start: QuotaCycleBoundary? = nil, end: QuotaCycleBoundary? = nil,
                       observed: Date? = nil, current: Bool = true) -> QuotaActualCycle {
        .init(id: "cycle", start: start, end: end, scheduledResetAt: d(10000),
              firstObservedAt: d(0), lastObservedAt: observed ?? d(900), endedEarly: false,
              resetChangePending: false, isCurrent: current)
    }
    private func snapshot(coverage: Date, generation: Int64 = 1, epoch: String = "epoch",
                          observed: Date? = nil, headlineGeneration: Int64? = nil,
                          snapshotHome: URL? = nil, hasHomeIdentity: Bool = true,
                          coverageKind: DashboardSnapshotCoverageKind = .full) -> DashboardSnapshot {
        DashboardSnapshot(stats: DashboardSnapshot.empty.stats,
            dailyUsage: [], recentBins: [], hourlyUsage: [], pluginUsage: [],
            cacheUsage: TokenCacheUsage(total: .empty, daily: [], hourly: [], recentBins: [], sessions: [], turns: [],
                attributionEventsComplete: true, attributionModelBucketsComplete: true,
                attributionProvenanceEpoch: epoch, attributionGeneration: generation),
            preciseTimeSeriesGeneratedAt: coverage, generatedAt: coverage,
            homeIdentity: hasHomeIdentity ? CodexDataSource(codexHome: snapshotHome ?? home, origin: .defaultHome).usageIdentityKey : nil,
            coverageKind: coverageKind,
            observedThrough: observed ?? coverage, settledThrough: coverage,
            exactGeneration: headlineGeneration ?? generation)
    }
    private func request(_ cycle: QuotaActualCycle, _ snapshot: DashboardSnapshot) throws -> QuotaCycleUsageRequest {
        try XCTUnwrap(QuotaCycleUsageRequest.make(cycle: cycle, identity: identity, home: home, snapshot: snapshot))
    }
    private func items(_ rows: [ModelTokenBreakdown]) -> [FloatingTodayModelUsageItem] {
        FloatingTodayModelUsagePresentation.items(from: rows, fallbackModel: .gpt56Sol)
    }

    func testCoverageAdvancesOnlyToLatestQuotaObservation() throws {
        let current = cycle(observed: d(600))
        let events = [event(0, 100), event(300, 200), event(600, 400)]
        let earlier = try request(current, snapshot(coverage: d(300)))
        let later = try request(current, snapshot(coverage: d(900)))
        XCTAssertEqual(earlier.end, d(300))
        XCTAssertEqual(later.end, d(600))
        XCTAssertEqual(later.outerEnd, d(600))
        XCTAssertEqual(QuotaCycleUsage(events: events, cycle: current, coverageEnd: earlier.coverage).total.totalTokens, 100)
        XCTAssertEqual(QuotaCycleUsage(events: events, cycle: current, coverageEnd: later.coverage).total.totalTokens, 300)
    }

    func testEmptyConfirmedInteriorRetainsPendingModelPriceAndRequest() throws {
        let current = try XCTUnwrap(QuotaActualCycleProjector.project([
            .init(at: d(0), usedPercent: 50, resetsAt: d(10000)),
            .init(at: d(300), usedPercent: 0, resetsAt: d(20000)),
            .init(at: d(600), usedPercent: 0, resetsAt: d(20000))
        ], now: d(900)).first)
        XCTAssertTrue(current.resetChangePending)
        let key = try request(current, snapshot(coverage: d(900)))
        XCTAssertEqual(key.start, key.end)
        let usage = QuotaCycleUsage(events: [event(0, 100), event(300, 200)], cycle: current, coverageEnd: key.coverage)
        XCTAssertEqual(usage.total, .empty)
        XCTAssertEqual(usage.unassignedTokens, 300)
        XCTAssertEqual(usage.unassignedRows.first?.breakdown, usage.unassignedTotal)
        XCTAssertGreaterThan(try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: items(usage.unassignedRows))), 0)
    }

    func testMinuteSlicesPartitionEveryModelAndCacheFieldWithoutTokenSubtraction() throws {
        let minutes = (0..<5).map { index in
            TokenCacheBucket(start: d(Double(index * 60)),
                             breakdown: breakdown((index + 1) * 100, cached: (index + 1) * 20, output: index + 1))
        }
        let known = TokenCacheAttributionEvent(id: "priced", start: d(0), model: "gpt-5.6-sol",
            breakdown: minutes.map(\.breakdown).combined, minuteBuckets: minutes)
        let unknown = TokenCacheAttributionEvent(id: "unknown", start: d(0), model: "future-unpriced",
            breakdown: minutes.map(\.breakdown).combined, minuteBuckets: minutes)
        let current = cycle(start: .init(earliest: d(0), latest: d(120)), observed: d(300))
        let usage = QuotaCycleUsage(events: [known, unknown], cycle: current, coverageEnd: d(300))
        let expectedPending = Array(minutes.prefix(2)).map(\.breakdown).combined
        let expectedConfirmed = Array(minutes.dropFirst(2)).map(\.breakdown).combined
        XCTAssertEqual(usage.total, [expectedConfirmed, expectedConfirmed].combined)
        XCTAssertEqual(usage.unassignedTotal, [expectedPending, expectedPending].combined)
        XCTAssertEqual([usage.total, usage.unassignedTotal].combined, [known.breakdown, unknown.breakdown].combined)
        XCTAssertNil(items(usage.unassignedRows).first(where: { $0.id == "future-unpriced" })?.costUSD)
        let wholeKnownCost = try XCTUnwrap(items(ModelUsagePresentation.rows(from: [known])).first?.costUSD)
        let confirmedKnownCost = try XCTUnwrap(items(usage.rows).first(where: { $0.id == "gpt-5.6-sol" })?.costUSD)
        let pendingKnownCost = try XCTUnwrap(items(usage.unassignedRows).first(where: { $0.id == "gpt-5.6-sol" })?.costUSD)
        XCTAssertEqual(confirmedKnownCost + pendingKnownCost, wholeKnownCost, accuracy: 0.000001)
    }

    func testInvalidMinuteDetailKeepsWholeModelBreakdownPending() {
        let coarse = event(0, 1500)
        let invalid = TokenCacheAttributionEvent(id: coarse.id, start: coarse.start, model: coarse.model,
            breakdown: coarse.breakdown, minuteBuckets: [.init(start: d(0), breakdown: breakdown(100))])
        let current = cycle(start: .init(earliest: d(0), latest: d(120)), observed: d(300))
        let usage = QuotaCycleUsage(events: [invalid], cycle: current, coverageEnd: d(300))
        XCTAssertEqual(usage.total, .empty)
        XCTAssertEqual(usage.unassignedTotal, coarse.breakdown)
        XCTAssertEqual(usage.unassignedRows.first?.model, coarse.model)
    }

    func testAdjacentCyclesSharePendingSliceReferencesAndConfirmedInteriorsReconcile() {
        let minutes = (0..<5).map { TokenCacheBucket(start: d(Double($0 * 60)), breakdown: breakdown(($0 + 1) * 100)) }
        let event = TokenCacheAttributionEvent(id: "shared", start: d(0), model: "gpt-5.6-sol",
            breakdown: minutes.map(\.breakdown).combined, minuteBuckets: minutes)
        let boundary = QuotaCycleBoundary(earliest: d(120), latest: d(180))
        let previous = QuotaCycleUsage(events: [event], cycle: cycle(end: boundary, current: false), coverageEnd: d(300))
        let current = QuotaCycleUsage(events: [event], cycle: cycle(start: boundary), coverageEnd: d(300))
        XCTAssertEqual(previous.unassignedSliceIDs, current.unassignedSliceIDs)
        XCTAssertEqual(previous.unassignedTokens, 300)
        XCTAssertEqual(current.unassignedTokens, 300)
        XCTAssertEqual([previous.total, current.total, current.unassignedTotal].combined, event.breakdown)
    }

    func testWideUncertainEdgesSelectFourMinuteBucketsAndExcludeKnownOutsideMinutes() throws {
        let selected = cycle(start: .init(earliest: d(31), latest: d(361)),
                             end: .init(earliest: d(691), latest: d(1021)), current: false)
        let key = try request(selected, snapshot(coverage: d(1200)))
        XCTAssertEqual(key.minuteBoundaries, [d(31), d(361), d(691), d(1021)])
        let events = (0..<4).map { index in
            let minutes = (0..<5).map { minute in
                TokenCacheBucket(start: d(Double(index * 300 + minute * 60)), breakdown: breakdown(100))
            }
            return TokenCacheAttributionEvent(id: "wide:\(index)", start: d(Double(index * 300)),
                model: "gpt-5.6-sol", breakdown: minutes.map(\.breakdown).combined, minuteBuckets: minutes)
        }
        let usage = QuotaCycleUsage(events: events, cycle: selected, coverageEnd: key.coverage)
        XCTAssertEqual(usage.total.totalTokens, 400)
        XCTAssertEqual(usage.unassignedTokens, 1400)
        XCTAssertEqual([usage.total, usage.unassignedTotal].combined.totalTokens, 1800)
        XCTAssertFalse(usage.unassignedSliceIDs.contains("wide:3:minute:\(Int64(d(1080).timeIntervalSince1970))"))
    }

    func testPendingModelRowsRetainHistoricalPriceDates() throws {
        let before = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T23:55:00Z"))
        let after = before.addingTimeInterval(300)
        let events = [before, after].enumerated().map { index, at in
            TokenCacheAttributionEvent(id: "dated:\(index)", start: at, model: "gpt-5.6-sol", breakdown: breakdown(1_000_000))
        }
        let current = cycle(start: .init(earliest: before, latest: after.addingTimeInterval(300)),
                            observed: after.addingTimeInterval(300))
        let usage = QuotaCycleUsage(events: events, cycle: current, coverageEnd: after.addingTimeInterval(300))
        XCTAssertEqual(usage.unassignedRows.first?.pricePeriods?.count, 2)
        XCTAssertEqual(try XCTUnwrap(FloatingTodayModelUsagePresentation.knownCostUSD(in: items(usage.unassignedRows))), 9, accuracy: 0.0001)
    }

    func testCacheIdentityIncludesVersionHomeEpochGenerationAndAllBounds() throws {
        let current = cycle()
        let key = try request(current, snapshot(coverage: d(900)))
        let newerGeneration = try request(current, snapshot(coverage: d(900), generation: 2))
        let otherEpoch = try request(current, snapshot(coverage: d(900), epoch: "other"))
        let advancedCoverage = try request(current, snapshot(coverage: d(1200)))
        let shiftedStart = try request(cycle(start: .exact(d(300))), snapshot(coverage: d(900)))
        let shiftedOuter = try request(cycle(start: .init(earliest: d(-60), latest: d(0))), snapshot(coverage: d(900)))
        let shortenedEnd = try request(cycle(end: .exact(d(600)), current: false), snapshot(coverage: d(900)))
        let oldVersion = QuotaCycleUsageRequest(identity: key.identity, home: key.home, cycleID: key.cycleID,
            start: key.start, end: key.end, outerStart: key.outerStart, outerEnd: key.outerEnd, coverage: key.coverage,
            epoch: key.epoch, generation: key.generation, projectionVersion: key.projectionVersion - 1, isCurrent: true)
        let otherIdentity = try XCTUnwrap(QuotaHistoryIdentity(homeIdentity: home.path, stableAccountKey: "b", planType: "Plus", limitID: "codex"))
        let identityKey = try XCTUnwrap(QuotaCycleUsageRequest.make(cycle: current, identity: otherIdentity, home: home,
            snapshot: snapshot(coverage: d(900))))
        let otherHome = URL(fileURLWithPath: "/other-home")
        let otherHomeIdentity = try XCTUnwrap(QuotaHistoryIdentity(homeIdentity: otherHome.path,
            stableAccountKey: "a", planType: "Plus", limitID: "codex"))
        let homeKey = try XCTUnwrap(QuotaCycleUsageRequest.make(cycle: current,
            identity: otherHomeIdentity,
            home: otherHome, snapshot: snapshot(coverage: d(900), snapshotHome: otherHome)))
        XCTAssertEqual(Set([key, newerGeneration, otherEpoch, advancedCoverage, shiftedStart, shiftedOuter,
                            shortenedEnd, oldVersion, identityKey, homeKey]).count, 10)
        XCTAssertFalse(key.canDisplay(oldVersion))
        XCTAssertFalse(oldVersion.canDisplay(key))
        XCTAssertFalse(identityKey.canDisplay(key))
        XCTAssertFalse(homeKey.canDisplay(key))
        XCTAssertFalse(otherEpoch.canDisplay(key))
        XCTAssertFalse(shiftedStart.canDisplay(key))
        XCTAssertFalse(shiftedOuter.canDisplay(key))
        XCTAssertFalse(shortenedEnd.canDisplay(key))
        XCTAssertTrue(newerGeneration.canDisplay(key))
        XCTAssertFalse(key.canDisplay(newerGeneration))
    }

    func testCompactHeadlineCannotPromoteRetainedPreciseCoverageOrFreshness() throws {
        let previous = snapshot(coverage: d(300))
        let summary = CodexUsageAnalyzer.CompactUsageSummary(totalTokens: 40000, todayTokens: 40000, todayCalls: 10,
            generatedAt: d(1200), observedThrough: d(900), settledThrough: d(600), exactGeneration: 2)
        let compact = CodexUsageStore.applyingCompactSummary(summary, to: previous)
        let key = try request(cycle(), compact)
        XCTAssertEqual(key.generation, 1)
        XCTAssertEqual(key.coverage, d(300))
        XCTAssertEqual(key.end, d(300))
        XCTAssertEqual(key.outerEnd, d(300))
        XCTAssertFalse(key.isCurrentResult(for: compact, preciseFresh: true))
        XCTAssertTrue(QuotaCycleUsageRequest.preciseCoverageIsBehind(compact))
        let sameGenerationAhead = snapshot(coverage: d(300), observed: d(900))
        XCTAssertFalse(try request(cycle(), sameGenerationAhead).isCurrentResult(for: sameGenerationAhead, preciseFresh: true))
        XCTAssertTrue(try request(cycle(), previous).isCurrentResult(for: previous, preciseFresh: true))
    }

    func testFullAndNumericSnapshotsRemainCurrentWithinLatestEligibleBoundary() throws {
        for kind in [DashboardSnapshotCoverageKind.full, .settled] {
            let precise = snapshot(coverage: d(300), observed: d(400), coverageKind: kind)
            XCTAssertEqual(precise.settledThrough, d(300))
            XCTAssertEqual(precise.observedThrough, d(400))
            XCTAssertFalse(QuotaCycleUsageRequest.preciseCoverageIsBehind(precise))
            XCTAssertTrue(try request(cycle(), precise).isCurrentResult(for: precise, preciseFresh: true))
        }
        let generationMismatch = snapshot(coverage: d(300), observed: d(400), headlineGeneration: 2)
        XCTAssertTrue(QuotaCycleUsageRequest.preciseCoverageIsBehind(generationMismatch))
        XCTAssertFalse(try request(cycle(), generationMismatch).isCurrentResult(for: generationMismatch, preciseFresh: true))
    }

    func testCompactObservationBecomesStaleOnlyAfterNextBucketSettles() throws {
        let precise = snapshot(coverage: d(300), observed: d(400))
        let settling = CodexUsageStore.applyingCompactSummary(
            .init(totalTokens: 100, todayTokens: 100, todayCalls: 1, generatedAt: d(1200),
                  observedThrough: d(614), settledThrough: d(300), exactGeneration: 1), to: precise)
        let settled = CodexUsageStore.applyingCompactSummary(
            .init(totalTokens: 200, todayTokens: 200, todayCalls: 2, generatedAt: d(1200),
                  observedThrough: d(615), settledThrough: d(600), exactGeneration: 1), to: precise)
        XCTAssertFalse(QuotaCycleUsageRequest.preciseCoverageIsBehind(settling))
        XCTAssertTrue(try request(cycle(), settling).isCurrentResult(for: settling, preciseFresh: true))
        XCTAssertTrue(QuotaCycleUsageRequest.preciseCoverageIsBehind(settled))
        let key = try request(cycle(), settled)
        XCTAssertFalse(key.isCurrentResult(for: settled, preciseFresh: true))
        XCTAssertEqual(key.coverage, d(300))
        XCTAssertEqual(key.outerEnd, d(300))
    }

    func testRequestUsesProductionUsageHomeIdentityAndAcceptsExplicitLegacyNil() throws {
        let source = CodexDataSource(codexHome: home, origin: .defaultHome)
        let precise = snapshot(coverage: d(900))
        XCTAssertEqual(precise.homeIdentity, source.usageIdentityKey)
        XCTAssertNotNil(QuotaCycleUsageRequest.make(cycle: cycle(), identity: identity,
            home: source.codexHome, snapshot: precise))
        XCTAssertNotNil(QuotaCycleUsageRequest.make(cycle: cycle(), identity: identity,
            home: source.codexHome, snapshot: snapshot(coverage: d(900), hasHomeIdentity: false)))
        let anotherHome = URL(fileURLWithPath: "/another-home")
        XCTAssertNil(QuotaCycleUsageRequest.make(cycle: cycle(), identity: identity,
            home: source.codexHome, snapshot: snapshot(coverage: d(900), snapshotHome: anotherHome)))
    }

    func testOpeningDashboardCatchesUpGenerationEvenWithinCoveredWallClockBucket() async throws {
        let now = Date()
        let coverage = UsageRefreshCadencePolicy.latestEligibleBoundary(now: now)
        let initial = snapshot(coverage: coverage)
        let final = snapshot(coverage: coverage, generation: 2)
        let loader = QuotaCycleCoverageLoader(initial: initial, final: final,
            summary: .init(totalTokens: 40, todayTokens: 40, todayCalls: 1,
                generatedAt: now, observedThrough: coverage, settledThrough: coverage, exactGeneration: 2))
        let source = CodexDataSource(codexHome: home, origin: .defaultHome)
        let defaultsName = "QuotaCycleCoverageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = CodexUsageStore(resolver: QuotaCycleCoverageResolver(source: source), snapshotLoader: loader,
            autoStart: false, continuityDefaults: defaults)
        store.setBackgroundActivityEnabled(true)
        defer { store.setBackgroundActivityEnabled(false) }
        await waitUntil { store.snapshot.cacheUsage.attributionGeneration == 1 && !store.isRefreshing }
        store.setOnlyCompactSurfaceVisible(true)
        store.refreshLightSummary()
        await waitUntil { store.snapshot.exactGeneration == 2 && !store.isRefreshing }
        XCTAssertEqual(store.snapshot.preciseTimeSeriesGeneratedAt, coverage)
        XCTAssertEqual(store.snapshot.cacheUsage.attributionGeneration, 1)
        XCTAssertFalse(store.preciseTimeSeriesFresh)
        store.setOnlyCompactSurfaceVisible(false)
        store.setUsageRefreshCadence(UsageRefreshCadenceSettings(), mainDashboardVisible: true)
        await waitUntil { store.snapshot.cacheUsage.attributionGeneration == 2 && !store.isRefreshing }
        XCTAssertTrue(store.preciseTimeSeriesFresh)
        let counts = await loader.counts()
        XCTAssertEqual(counts.precise, 2)
        XCTAssertEqual(counts.compact, 1)
        let visibleCycle = QuotaActualCycle(id: "current-wall-clock", start: nil, end: nil,
            scheduledResetAt: coverage.addingTimeInterval(10000),
            firstObservedAt: coverage.addingTimeInterval(-900), lastObservedAt: coverage,
            endedEarly: false, resetChangePending: false, isCurrent: true)
        let key = try request(visibleCycle, store.snapshot)
        XCTAssertTrue(key.isCurrentResult(for: store.snapshot, preciseFresh: store.preciseTimeSeriesFresh))
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            // A yield-count is not a timeout: unrelated GUI tests can exhaust
            // the loop before the detached loader gets scheduled.
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for quota-cycle coverage refresh")
    }
}

private final class QuotaCycleCoverageResolver: CodexDataSourceResolving {
    let source: CodexDataSource
    init(source: CodexDataSource) { self.source = source }
    func resolve() -> CodexDataSource? { source }
    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource? { source }
}

private actor QuotaCycleCoverageLoader: DashboardSnapshotLoading {
    let initial: DashboardSnapshot
    let final: DashboardSnapshot
    let summary: CodexUsageAnalyzer.CompactUsageSummary
    private var precise = 0
    private var compact = 0
    init(initial: DashboardSnapshot, final: DashboardSnapshot, summary: CodexUsageAnalyzer.CompactUsageSummary) {
        self.initial = initial; self.final = final; self.summary = summary
    }
    func loadFastSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot { initial }
    func loadSnapshot(dataSource: CodexDataSource) async throws -> DashboardSnapshot {
        precise += 1
        return precise == 1 ? initial : final
    }
    func loadCompactSummary(dataSource: CodexDataSource) async throws -> CodexUsageAnalyzer.CompactUsageSummary? {
        compact += 1
        return summary
    }
    func counts() -> (precise: Int, compact: Int) { (precise, compact) }
}
