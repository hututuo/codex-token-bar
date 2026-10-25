import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Price table sync")
struct PriceTableSyncTests {
    static let raw = PriceTableSync.urls[0]
    static let mirror = PriceTableSync.urls[1]
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-22T12:00Z, a fixed clock for future-date validation.
    static let noon = Date(timeIntervalSince1970: 1_792_670_400)

    /// Keeps synthetic metadata independent of the bundled table's version and dates.
    static func table(version: Int, schema: Int = 1, updated: String = "2026-10-22") throws -> Data {
        var table = try PriceTableTests.bundledJSON()
        table["schema"] = schema
        table["version"] = version
        table["updated"] = updated
        var models = try #require(table["models"] as? [[String: Any]])
        for index in models.indices {
            if let checked = models[index]["checked"] as? String, checked > updated {
                models[index]["checked"] = updated
            }
        }
        table["models"] = models
        return try JSONSerialization.data(withJSONObject: table)
    }

    struct Harness {
        let directory: TempDirectory
        let transport = ScriptedTransport()
        let clock = TestClock(PriceTableSyncTests.noon)
        var store: PriceTableStore { PriceTableStore(appDataDirectory: directory.url) }
        var sync: PriceTableSync {
            PriceTableSync(store: store, transport: transport, userAgent: "AgentSpeed/9.9.9 (macOS)", timeZone: PriceTableSyncTests.utc,
                           now: clock.function)
        }

        init() throws {
            directory = try TempDirectory()
        }
    }

    @Test func aNewerTableIsStoredAndDelivered() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.raw, body: try Self.table(version: 2), etag: "\"v2\"")
        let result = await harness.sync.run(currentVersion: 1)
        #expect(result.outcome == .updated(version: 2))
        #expect(result.table?.version == 2)
        #expect(harness.transport.requestedURLs == [Self.raw.absoluteString])
        let request = try #require(harness.transport.requests.first)
        #expect(request.accept == "application/json")
        #expect(request.userAgent == "AgentSpeed/9.9.9 (macOS)")
        #expect(request.ifNoneMatch == nil)
        #expect(request.maxBytes == PriceTable.maxBytes)
        #expect(request.allowedHosts == ["raw.githubusercontent.com", "cdn.jsdelivr.net"])
        #expect(harness.store.loadTable()?.version == 2)
        let state = harness.store.loadState()
        #expect(state.version == 2)
        #expect(state.etag == "\"v2\"")
        #expect(state.url == Self.raw.absoluteString)
        #expect(state.lastSuccessMs == 1_792_670_400_000)
        #expect(state.failures == 0)
    }

    @Test func theMirrorIsTriedWhenGitHubFails() async throws {
        for answer in [ScriptedTransport.Answer.failure(.transport("URLError -1009")),
                       .response(HTTPFetchResponse(status: 404)),
                       .response(HTTPFetchResponse(status: 200, body: Data("not json".utf8)))] {
            let harness = try Harness()
            harness.transport.script(Self.raw, answer)
            harness.transport.reply(Self.mirror, body: try Self.table(version: 3))
            let result = await harness.sync.run(currentVersion: 1)
            #expect(result.outcome == .updated(version: 3))
            #expect(harness.transport.requestedURLs == [Self.raw.absoluteString, Self.mirror.absoluteString])
            #expect(harness.store.loadState().url == Self.mirror.absoluteString)
        }
    }

    @Test func aStoredETagTurnsTheNextDayIntoA304() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.raw, body: try Self.table(version: 2), etag: "\"v2\"")
        _ = await harness.sync.run(currentVersion: 1)
        harness.clock.advance(PriceTableSync.interval)
        harness.transport.reply(Self.raw, status: 304)
        let result = await harness.sync.run(currentVersion: 2)
        #expect(result.outcome == .upToDate)
        #expect(harness.transport.requests.last?.ifNoneMatch == "\"v2\"")
        #expect(harness.store.loadState().lastSuccessMs == 1_792_756_800_000)
        #expect(harness.store.loadTable()?.version == 2)
    }

    @Test func anETagIsNotSentWhenItsTableIsNewerThanOurs() async throws {
        let harness = try Harness()
        try harness.store.save(state: PriceSyncState(version: 5, url: Self.raw.absoluteString, etag: "\"v5\""))
        harness.transport.reply(Self.raw, body: try Self.table(version: 5))
        let result = await harness.sync.run(currentVersion: 1)
        #expect(harness.transport.requests.first?.ifNoneMatch == nil)
        #expect(result.outcome == .updated(version: 5))
    }

    @Test func equalOrLowerVersionsChangeNothing() async throws {
        for version in [1, 2] {
            let harness = try Harness()
            harness.transport.reply(Self.raw, body: try Self.table(version: version))
            let result = await harness.sync.run(currentVersion: 2)
            #expect(result.outcome == .upToDate)
            #expect(result.table == nil)
            #expect(harness.store.loadTable() == nil, "nothing is stored, never a downgrade")
            #expect(harness.transport.requestedURLs == [Self.raw.absoluteString])
        }
    }

    @Test func aNewerSchemaIsNotAnError() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.raw, body: try Self.table(version: 9, schema: 2))
        harness.transport.reply(Self.mirror, body: try Self.table(version: 9, schema: 2))
        let result = await harness.sync.run(currentVersion: 1)
        #expect(result.outcome == .newerSchema)
        #expect(harness.store.loadState().failures == 0)
        #expect(harness.store.loadTable() == nil)
    }

    @Test func aLaggingMirrorStillServesTheCurrentSchema() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.raw, body: try Self.table(version: 9, schema: 2))
        harness.transport.reply(Self.mirror, body: try Self.table(version: 4))
        #expect(await harness.sync.run(currentVersion: 1).outcome == .updated(version: 4))
    }

    @Test func tablesDatedMoreThanTwoDaysAheadAreRejected() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.raw, body: try Self.table(version: 2, updated: "2026-10-25"))
        harness.transport.reply(Self.mirror, body: try Self.table(version: 2, updated: "2026-10-24"))
        let result = await harness.sync.run(currentVersion: 1)
        #expect(result.outcome == .updated(version: 2), "two days ahead is still fine")
        #expect(harness.transport.requestedURLs.count == 2)

        let late = try Harness()
        late.transport.reply(Self.raw, body: try Self.table(version: 2, updated: "2026-10-25"))
        late.transport.reply(Self.mirror, body: try Self.table(version: 2, updated: "2026-10-25"))
        guard case .failed = await late.sync.run(currentVersion: 1).outcome else {
            Issue.record("a table from the future was accepted")
            return
        }
    }

    @Test func oversizedAndInvalidDownloadsFailTheRound() async throws {
        let harness = try Harness()
        harness.transport.reply(Self.raw, body: Data(count: PriceTable.maxBytes + 1))
        var broken = try #require(try JSONSerialization.jsonObject(with: Self.table(version: 2)) as? [String: Any])
        var models = try #require(broken["models"] as? [[String: Any]])
        let index = try #require(models.firstIndex { $0["prices"] != nil })
        var prices = try #require(models[index]["prices"] as? [String: Any])
        prices["input"] = NSDecimalNumber(string: "4.0000001")
        models[index]["prices"] = prices
        broken["models"] = models
        harness.transport.reply(Self.mirror, body: try JSONSerialization.data(withJSONObject: broken))
        let result = await harness.sync.run(currentVersion: 1)
        guard case .failed(let reason) = result.outcome else {
            Issue.record("expected a failure, got \(result.outcome)")
            return
        }
        #expect(reason == "invalid table")
        let state = harness.store.loadState()
        #expect(state.failures == 1)
        #expect(state.lastError == "invalid table")
        #expect(state.lastSuccessMs == nil)
        #expect(harness.store.loadTable() == nil)
    }

    @Test func theStoredCopyIsValidatedAgain() throws {
        let directory = try TempDirectory()
        let store = PriceTableStore(appDataDirectory: directory.url)
        #expect(store.loadTable() == nil)
        try store.save(tableData: Data("{\"schema\": 1}".utf8))
        #expect(store.loadTable() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.tableURL.path), "an invalid copy is deleted")
        try store.save(tableData: try Self.table(version: 7))
        #expect(store.loadTable()?.version == 7)
        #expect(store.tableURL.path.hasSuffix("/prices/prices.json"))
        #expect(store.stateURL.path.hasSuffix("/prices/sync.json"))
    }

    @Test func scheduleFollowsLaunchDailyAndRetryRules() {
        let launch = Self.noon
        let now = launch.addingTimeInterval(10)
        func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        #expect(PriceTableSync.nextAttempt(launchedAt: launch, state: PriceSyncState(), now: now) == launch.addingTimeInterval(60))
        let synced = PriceSyncState(lastSuccessMs: ms(launch.addingTimeInterval(-3600)), lastAttemptMs: ms(launch.addingTimeInterval(-3600)))
        #expect(PriceTableSync.nextAttempt(launchedAt: launch, state: synced, now: now) == launch.addingTimeInterval(23 * 3600))
        let old = PriceSyncState(lastSuccessMs: ms(launch.addingTimeInterval(-3 * 86400)))
        #expect(PriceTableSync.nextAttempt(launchedAt: launch, state: old, now: now) == launch.addingTimeInterval(60))
        let failedOnce = PriceSyncState(lastAttemptMs: ms(now), failures: 1)
        #expect(PriceTableSync.nextAttempt(launchedAt: launch, state: failedOnce, now: now) == now.addingTimeInterval(3600))
        let failedTwice = PriceSyncState(lastAttemptMs: ms(now), failures: 2)
        #expect(PriceTableSync.nextAttempt(launchedAt: launch, state: failedTwice, now: now) == now.addingTimeInterval(86400))
        let future = PriceSyncState(lastSuccessMs: ms(now.addingTimeInterval(10 * 86400)))
        #expect(PriceTableSync.nextAttempt(launchedAt: launch, state: future, now: now) == now.addingTimeInterval(86400),
                "a stamp in the future counts as now")
    }

    @Test func aFailedRoundThenASuccessResetsTheRetryCount() async throws {
        let harness = try Harness()
        _ = await harness.sync.run(currentVersion: 1)
        #expect(harness.store.loadState().failures == 1)
        _ = await harness.sync.run(currentVersion: 1)
        #expect(harness.store.loadState().failures == 2)
        harness.transport.reply(Self.raw, body: try Self.table(version: 1))
        #expect(await harness.sync.run(currentVersion: 1).outcome == .upToDate)
        #expect(harness.store.loadState().failures == 0)
        #expect(harness.store.loadState().lastError == nil)
    }

    @Test func syncStateDecodesWithoutTheRetryCount() throws {
        let json = #"{"version":3,"updated":"2026-10-21","url":"u","etag":"e","lastSuccessMs":1,"lastAttemptMs":2,"lastError":null}"#
        let state = try JSONDecoder().decode(PriceSyncState.self, from: Data(json.utf8))
        #expect(state == PriceSyncState(version: 3, updated: "2026-10-21", url: "u", etag: "e", lastSuccessMs: 1, lastAttemptMs: 2))
    }
}
