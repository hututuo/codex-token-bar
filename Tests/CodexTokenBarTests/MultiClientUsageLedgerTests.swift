import XCTest
import CryptoKit
@testable import CodexTokenBar

final class MultiClientUsageLedgerTests: XCTestCase {
    func testRegisteredClaudeAccountBackfillsOnceDeduplicatesCopiesAndResumesPartialTail() async throws {
        let fm = FileManager.default
        let accounts = root.appendingPathComponent(".local/share/claude-adapter/accounts")
        let old = root.appendingPathComponent(".claude/projects/p/original.jsonl")
        let account = accounts.appendingPathComponent("\(String(repeating: "a", count: 32))/code/projects/p/copied.jsonl")
        for path in [old, account] { try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true) }
        func line(_ session: String, _ id: String) -> String {
            "{\"type\":\"assistant\",\"entrypoint\":\"claude-desktop-3p\",\"sessionId\":\"\(session)\",\"timestamp\":\"2026-11-26T10:00:00Z\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":3,\"cache_read_input_tokens\":20,\"cache_creation_input_tokens\":7,\"output_tokens\":5}}}\n"
        }
        try Data(line("original", "shared").utf8).write(to: old)
        let database = root.appendingPathComponent("account-backfill.sqlite")
        let scanner = MultiClientUsageScanner(databaseURL: database, home: root, environment: [:])
        var preference = MultiClientUsagePreference.defaults.first { $0.client == .claudeDesktop }!
        preference.enabled = true
        let baseline = try await scanner.scan([preference])
        XCTAssertEqual(baseline.summaries.first?.requests, 1)
        let tail = line("isolated", "appended")
        try Data((line("copied-session", "shared") + line("isolated", "new") + tail.dropLast(5)).utf8).write(to: account)
        let registry: [String: Any] = ["version": 1, "accounts": [["id": "existing"], ["id": String(repeating: "a", count: 32)]]]
        try JSONSerialization.data(withJSONObject: registry).write(to: accounts.appendingPathComponent("registry.json"))
        let backfilled = try await scanner.scan([preference])
        XCTAssertEqual(backfilled.summaries.first?.requests, 2)
        XCTAssertEqual(backfilled.summaries.first?.inputTokens, 60)
        XCTAssertEqual(backfilled.summaries.first?.cacheReadTokens, 40)
        XCTAssertEqual(backfilled.summaries.first?.cacheWriteTokens, 14)
        let repeated = try await scanner.scan([preference])
        XCTAssertEqual(repeated.summaries, backfilled.summaries)
        let file = try FileHandle(forWritingTo: account)
        try file.seekToEnd(); try file.write(contentsOf: Data(tail.suffix(5).utf8)); try file.close()
        let appended = try await scanner.scan([preference])
        XCTAssertEqual(appended.summaries.first?.requests, 3)
        XCTAssertEqual(appended.summaries.first?.inputTokens, 90)

        // A user-selected path remains exclusive, even when accounts are registered.
        preference.path = old.path
        let explicitScanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("explicit.sqlite"), home: root, environment: [:])
        let explicit = try await explicitScanner.scan([preference])
        XCTAssertEqual(explicit.summaries.first?.requests, 1)
        try fm.removeItem(at: account)
        preference.path = ""
        let retained = try await scanner.scan([preference])
        XCTAssertEqual(retained.summaries.first?.requests, 3)
    }

    func testScanProjectionMatchesIndependentReadsAfterResponseMovesAcrossDays() throws {
        let url = root.appendingPathComponent("scan-projection.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let now = today.addingTimeInterval(3600)
        let week = Date(timeIntervalSince1970: floor((now.timeIntervalSince1970 - 7 * 86400) / 300) * 300)
        let response = String(repeating: "a", count: 64)
        let original = ClientUsageEvent(client: .claudeDesktop,
            eventID: "v1:" + String(repeating: "b", count: 64) + ":id:" + response,
            sessionID: "original", model: "claude-opus-5-5", timestamp: today.addingTimeInterval(-1),
            inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 30)
        var copy = original
        copy.eventID = "v1:" + String(repeating: "c", count: 64) + ":id:" + response
        copy.sessionID = "copied"
        copy.timestamp = today.addingTimeInterval(-2)
        copy.cacheWrite5mTokens = 10; copy.cacheWrite1hTokens = 20
        let futureUnknown = ClientUsageEvent(client: .antigravity, eventID: "unknown", sessionID: "s", model: "unknown",
            timestamp: now.addingTimeInterval(1), inputTokens: 200, outputTokens: 5)
        let oldPriced = ClientUsageEvent(client: .antigravity, eventID: "older", sessionID: "s", model: "gemini-3-flash-a",
            timestamp: now.addingTimeInterval(-45 * 86400), inputTokens: 200, outputTokens: 80,
            cacheReadTokens: 0, cacheWriteTokens: 0)
        _ = try ledger.ingest([original, copy, futureUnknown, oldPriced])

        func check(_ projection: MultiClientUsageLedger.ScanProjection) throws {
            let independent = try MultiClientUsageLedger(url: url, readOnly: true)
            XCTAssertEqual(projection.summaries, try independent.summaries())
            XCTAssertEqual(projection.todaySummaries, try independent.summaries(since: today))
            XCTAssertEqual(projection.sevenDaySummaries, try independent.summaries(since: week))
            XCTAssertEqual(projection.trend, try independent.trendBuckets(now: now))
            XCTAssertEqual(projection.daily, try independent.dailyBuckets(now: now))
            XCTAssertEqual(projection.summaries.reduce(0) { $0 + $1.requests }, 3)
            XCTAssertEqual(projection.summaries.reduce(0) { $0 + $1.unpricedRequests }, 1)
            XCTAssertEqual(projection.trend.count, 1)
            XCTAssertEqual(projection.daily.count, 2)
        }

        let headless = try XCTUnwrap(ledger.scanProjection(now: now, unchangedRevision: nil, includesCharts: false))
        XCTAssertTrue(headless.trend.isEmpty && headless.daily.isEmpty)
        let first = try XCTUnwrap(ledger.scanProjection(now: now, unchangedRevision: nil))
        try check(first)
        XCTAssertEqual(headless.summaries, first.summaries)
        XCTAssertEqual(headless.todaySummaries, first.todaySummaries)
        XCTAssertEqual(headless.sevenDaySummaries, first.sevenDaySummaries)
        XCTAssertNil(try ledger.scanProjection(now: now, unchangedRevision: first.revision))
        copy.timestamp = today
        copy.outputTokens += 50
        _ = try ledger.ingest([copy])
        let updated = try XCTUnwrap(ledger.scanProjection(now: now, unchangedRevision: first.revision))
        try check(updated)
        XCTAssertEqual(updated.daily.first { $0.client == .claudeDesktop }?.startUnix, Int64(today.timeIntervalSince1970))
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first, 5)
        XCTAssertTrue(try ledger.database.readRows("SELECT name FROM main.sqlite_schema WHERE name='effective_client_usage_events'") {
            $0.text(0)
        }.isEmpty)
    }

    @MainActor
    func testUsageChartsReloadFromLedgerAfterLastDashboardCloses() async throws {
        let suite = "MultiClientUsageChartDemand.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("chart-demand.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        var event = ClientUsageEvent(client: .claudeCode, eventID: "old", sessionID: "s",
            model: "claude-opus-5", timestamp: Date().addingTimeInterval(-30),
            inputTokens: 100, outputTokens: 10, cacheReadTokens: 50, cacheWriteTokens: 0)
        try ledger.ingest([event])
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: url)
        let primary = UUID(), secondary = UUID()

        func waitFor(_ label: String, _ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !ready(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(ready(), label)
        }

        store.refresh()
        try await waitFor("background summaries") { !store.refreshing && store.summaries.count == 1 }
        XCTAssertTrue(store.trendBuckets.isEmpty && store.dailyBuckets.isEmpty)
        let summaryTimestamp = store.updatedAt
        store.setUsageChartDemand(true, consumer: primary)
        try await waitFor("charts appear directly from the ledger") {
            store.trendBuckets.count == 1 && store.dailyBuckets.count == 1
        }
        XCTAssertEqual(store.updatedAt, summaryTimestamp)
        store.setUsageChartDemand(true, consumer: secondary)
        store.setUsageChartDemand(false, consumer: primary)
        XCTAssertFalse(store.dailyBuckets.isEmpty)
        store.setUsageChartDemand(false, consumer: secondary)
        XCTAssertTrue(store.trendBuckets.isEmpty && store.dailyBuckets.isEmpty)

        event.eventID = "new"
        event.outputTokens = 25
        try ledger.ingest([event])
        store.refresh()
        try await waitFor("new background totals") {
            !store.refreshing && store.summaries.first?.outputTokens == 35
        }
        XCTAssertTrue(store.trendBuckets.isEmpty && store.dailyBuckets.isEmpty)
        store.setUsageChartDemand(true, consumer: primary)
        try await waitFor("reopening restores both current charts") {
            store.trendBuckets.first?.outputTokens == 35 && store.dailyBuckets.first?.outputTokens == 35
        }
        store.setUsageChartDemand(false, consumer: primary)
    }

    func testDailyProjectionScaleKeepsTotalsAcrossCachedAndIncrementalReads() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("daily-scale.sqlite"))
        let now = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(3600)
        let events = (0..<3650).map { index in
            ClientUsageEvent(client: .claudeCode, eventID: "scale-\(index)", sessionID: "s", model: "claude-opus-5",
                timestamp: Calendar.current.date(byAdding: .day, value: -(index / 10), to: now)!,
                inputTokens: 1000, outputTokens: 100, cacheReadTokens: 900, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest(events)
        let start = Date()
        let first = try ledger.dailyBuckets(now: now)
        let firstMS = Date().timeIntervalSince(start) * 1000
        let cachedStart = Date()
        let cached = try ledger.dailyBuckets(now: now)
        let cachedMS = Date().timeIntervalSince(cachedStart) * 1000
        XCTAssertEqual(first, cached)
        XCTAssertEqual(first.reduce(0) { $0 + $1.requests }, events.count)
        XCTAssertEqual(first.reduce(0) { $0 + Int($1.tokens) }, events.count * 1100)
        var changed = events[0]; changed.outputTokens += 100
        _ = try ledger.ingest([changed])
        let incrementalStart = Date()
        let updated = try ledger.dailyBuckets(now: now)
        let incrementalMS = Date().timeIntervalSince(incrementalStart) * 1000
        XCTAssertEqual(updated.reduce(0) { $0 + $1.requests }, events.count)
        XCTAssertEqual(updated.reduce(0) { $0 + Int($1.tokens) }, events.count * 1100 + 100)
        XCTAssertEqual(Array(first.dropLast()), Array(updated.dropLast()))
        print("HEATMAP_DAILY_PERF rows=\(events.count) days=\(first.count) first_ms=\(firstMS) cached_ms=\(cachedMS) incremental_ms=\(incrementalMS)")
    }
    func testDailyPricesMatchRequestsAndMovedRevisionInvalidatesPriorDay() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("daily-prices.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = now.addingTimeInterval(-86400 * 3)
        var event = ClientUsageEvent(client: .claudeCode, eventID: "moved", sessionID: "s", model: "claude-opus-5",
            timestamp: previous, inputTokens: 100_000, outputTokens: 100, cacheReadTokens: 1000, cacheWriteTokens: 10_000)
        _ = try ledger.ingest([event])
        let before = try ledger.dailyBuckets(now: now)
        XCTAssertEqual(before.reduce(0) { $0 + $1.requests }, 1)
        XCTAssertEqual(try ledger.dailyBuckets(now: now.addingTimeInterval(60)), before)
        event.timestamp = now
        _ = try ledger.ingest([event])
        let after = try ledger.dailyBuckets(now: now.addingTimeInterval(120))
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].startUnix, Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970))
        XCTAssertEqual(after[0].apiCostMicroUSD, try ledger.trendBuckets(now: now.addingTimeInterval(120)).first?.apiCostMicroUSD)
        XCTAssertEqual(after[0].cacheReadComplete, true)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 2)
    }
    func testTrendModelsAndPricesStaySeparateWithinOneClientAndBucket() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("model-trend.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let models = ["claude-opus-5", "claude-sonnet-5", "unknown"]
        _ = try ledger.ingest(models.enumerated().map { index, model in
            ClientUsageEvent(client: .claudeCode, eventID: "m\(index)", sessionID: "s", model: model,
                timestamp: now, inputTokens: 100_000, outputTokens: 100,
                cacheReadTokens: index == 2 ? nil : 1000, cacheWriteTokens: 10_000)
        })
        let before = try ledger.database.readRows("SELECT payload FROM client_usage_events ORDER BY event_id") { $0.text(0) }
        let rows = try ledger.trendBuckets(now: now), summaries = try ledger.summaries()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.compactMap(\.model)), Set(models))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.requests }, 3)
        for row in rows {
            let summary = try XCTUnwrap(summaries.first { $0.model == row.model })
            XCTAssertEqual(row.inputTokens, summary.inputTokens)
            XCTAssertEqual(row.unpricedRequests, summary.unpricedRequests)
            XCTAssertEqual(row.apiCostMicroUSD.map { Double($0) / 1_000_000 }, summary.apiCostUSD)
            XCTAssertEqual(row.cacheReadComplete, row.model != "unknown")
        }
        XCTAssertEqual(before, try ledger.database.readRows("SELECT payload FROM client_usage_events ORDER BY event_id") { $0.text(0) })
    }
    func testConfirmedAntigravityAliasesAndLegacyOpusArePricedWithoutChangingRawRecords() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("confirmed-routes.sqlite"))
        for model in ["gemini-3-flash-a", "gemini-3-flash-preview", "gemini-3.8-flash-n", "gemini-3.8-flash", "claude-opus-5"] {
            _ = try ledger.ingest([.init(client: .antigravity, eventID: model, sessionID: "s", model: model,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: 100_000, outputTokens: 10_000,
                cacheReadTokens: 20_000, cacheWriteTokens: 30_000)])
        }
        let before = try ledger.database.readRows("SELECT payload FROM client_usage_events ORDER BY event_id") { $0.text(0) }
        let rows = try ledger.summaries()
        let cost = Dictionary(uniqueKeysWithValues: rows.map { ($0.model, $0.apiCostUSD) })
        XCTAssertEqual(rows.count, 5); XCTAssertEqual(rows.reduce(0) { $0 + $1.unpricedRequests }, 0)
        XCTAssertEqual(cost["gemini-3-flash-a"], cost["gemini-3-flash-preview"])
        XCTAssertEqual(cost["gemini-3.8-flash-n"], cost["gemini-3.8-flash"])
        XCTAssertGreaterThan(try XCTUnwrap(rows.first { $0.model == "claude-opus-5" }?.apiCostUSD), 0)
        XCTAssertEqual(before, try ledger.database.readRows("SELECT payload FROM client_usage_events ORDER BY event_id") { $0.text(0) })
        XCTAssertEqual(rows.reduce(0) { $0 + $1.inputTokens }, 500_000)
    }
    func testClaudeCacheLifetimeEnrichmentPricesSameRequestWithoutChangingOldUsage() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("ttl.sqlite"))
        let original = ClientUsageEvent(client: .claudeDesktop, eventID: "same-request", sessionID: "s", model: "claude-opus-5-5", timestamp: Date(timeIntervalSince1970: 1_793_000_000), inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 30)
        XCTAssertEqual(try ledger.ingest([original]), 1)
        XCTAssertEqual(try ledger.summaries().first?.unpricedRequests, 0)
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, 0.000554)
        var enriched = original
        enriched.cacheWrite5mTokens = 10; enriched.cacheWrite1hTokens = 20
        XCTAssertEqual(try ledger.ingest([enriched]), 1)
        let summary = try XCTUnwrap(try ledger.summaries().first)
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.inputTokens, 100); XCTAssertEqual(summary.outputTokens, 10)
        XCTAssertEqual(summary.cacheWriteTokens, 30)
        XCTAssertEqual(try XCTUnwrap(summary.apiCostUSD), 0.000614, accuracy: 1e-10)
        XCTAssertEqual(summary.unpricedRequests, 0)
        XCTAssertEqual(try ledger.ingest([original]), 0, "An older reader cannot clear a proved lifetime split")
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, summary.apiCostUSD)
    }

    func testIncompleteOrContradictoryCacheLifetimeUsesStandardFiveMinutePriceWithoutLosingUsage() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("ttl-invalid.sqlite"))
        for (index, split) in [(Int64(10), Int64(10)), (Int64(-1), Int64(31))].enumerated() {
            var row = ClientUsageEvent(client: .claudeDesktop, eventID: "bad-\(index)", sessionID: "s", model: "claude-opus-5-5", timestamp: Date(), inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 30)
            row.cacheWrite5mTokens = split.0; row.cacheWrite1hTokens = split.1
            _ = try ledger.ingest([row])
        }
        let summary = try XCTUnwrap(try ledger.summaries().first)
        XCTAssertEqual(summary.apiCostUSD, 0.001108); XCTAssertEqual(summary.unpricedRequests, 0)
        XCTAssertEqual(summary.inputTokens, 200); XCTAssertEqual(summary.requests, 2)
    }

    func testMalformedLowerWriteCannotBorrowOldTotalToInventACoherentSplit() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("ttl-merge-invalid.sqlite"))
        let original = ClientUsageEvent(client: .claudeDesktop, eventID: "same", sessionID: "s", model: "claude-opus-5-5", timestamp: Date(), inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 30)
        var incoming = original
        incoming.cacheWriteTokens = 20; incoming.cacheWrite5mTokens = 10; incoming.cacheWrite1hTokens = 20
        XCTAssertNil(original.mergingUpdate(incoming).cacheWriteLifetimeSplit)
        _ = try ledger.ingest([original]); _ = try ledger.ingest([incoming])
        let row = try XCTUnwrap(try ledger.summaries().first)
        XCTAssertEqual(row.cacheWriteTokens, 30); XCTAssertEqual(row.requests, 1)
        XCTAssertEqual(row.unpricedRequests, 0); XCTAssertEqual(row.apiCostUSD, 0.000554)
    }

    func testOldAndMalformedOptionalTTLMetadataDecodeWithoutDiscardingCounts() throws {
        let original = ClientUsageEvent(client: .claudeDesktop, eventID: "old", sessionID: "s", model: "claude-opus-5-5", timestamp: Date(), inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 30)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        payload.removeValue(forKey: "cacheWrite5mTokens"); payload.removeValue(forKey: "cacheWrite1hTokens")
        let old = try decoder.decode(ClientUsageEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(old, original)
        payload["cacheWrite5mTokens"] = "malformed"; payload["cacheWrite1hTokens"] = 30
        let malformed = try decoder.decode(ClientUsageEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(malformed.eventID, original.eventID)
        XCTAssertEqual(malformed.inputTokens, 100); XCTAssertNil(malformed.cacheWriteLifetimeSplit)
    }

    func testBadOptionalPricingPayloadDoesNotBlockKnownNumericUsage() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("ttl-payloads.sqlite"))
        for id in ["blob", "invalid", "oversized", "valid"] {
            _ = try ledger.ingest([ClientUsageEvent(client: .claudeDesktop, eventID: id, sessionID: "s", model: "claude-opus-5-5", timestamp: Date(), inputTokens: 100, outputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 30, cacheWrite5mTokens: 10, cacheWrite1hTokens: 20)])
        }
        try ledger.database.execute("UPDATE client_usage_events SET payload=CAST('bad' AS BLOB) WHERE event_id='blob'")
        try ledger.database.execute("UPDATE client_usage_events SET payload='not-json' WHERE event_id='invalid'")
        try ledger.database.execute("UPDATE client_usage_events SET payload=? WHERE event_id='oversized'", bindings: [.text(String(repeating: "x", count: 70_000))])
        let summary = try XCTUnwrap(try ledger.summaries().first)
        XCTAssertEqual(summary.requests, 4); XCTAssertEqual(summary.inputTokens, 400)
        XCTAssertEqual(summary.outputTokens, 40); XCTAssertEqual(summary.unpricedRequests, 0)
        XCTAssertEqual(try XCTUnwrap(summary.apiCostUSD), 0.002276, accuracy: 1e-10)
    }

    func testLegacyClaudeCheckpointEnrichesOnceAndDeletedSourceKeepsOldAccountedUsage() async throws {
        let file = root.appendingPathComponent("session.jsonl")
        let bytes = Data("{\"type\":\"assistant\",\"sessionId\":\"s\",\"timestamp\":\"2026-11-03T10:00:00Z\",\"message\":{\"id\":\"ttl-old\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":50,\"output_tokens\":10,\"cache_read_input_tokens\":20,\"cache_creation_input_tokens\":30,\"cache_creation\":{\"ephemeral_5m_input_tokens\":10,\"ephemeral_1h_input_tokens\":20}}}}\n".utf8)
        try bytes.write(to: file)
        let database = root.appendingPathComponent("ttl-checkpoint.sqlite")
        let ledger = try MultiClientUsageLedger(url: database)
        var old = try XCTUnwrap(try MultiClientUsageParsers.parse(data: bytes, client: .claudeCode, sessionHint: "session").first)
        old.cacheWrite5mTokens = nil; old.cacheWrite1hTokens = nil
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let width = min(4096, bytes.count)
        let digest = SHA256.hash(data: bytes.prefix(width)).map { String(format: "%02x", $0) }.joined()
        let key = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let rawIdentity = String(describing: attributes[.systemFileNumber] ?? "") + ":\(width):" + digest
        _ = try ledger.ingest([old], client: .claudeCode, sourceKey: key, checkpoint: .init(offset: Int64(bytes.count), size: Int64(bytes.count), modified: (attributes[.modificationDate] as! Date).timeIntervalSince1970, identity: rawIdentity))
        XCTAssertEqual(try ledger.summaries().first?.unpricedRequests, 0)
        var preference = MultiClientUsagePreference.defaults.first { $0.client == .claudeCode }!
        preference.enabled = true; preference.path = file.path
        let scanner = MultiClientUsageScanner(databaseURL: database, home: root, environment: [:])
        let first = try await scanner.scan([preference])
        XCTAssertEqual(first.summaries.first?.apiCostUSD, 0.000614)
        XCTAssertEqual(first.summaries.first?.requests, 1)
        XCTAssertTrue(try ledger.checkpoint(client: .claudeCode, sourceKey: key)?.identity.hasPrefix("claude-entrypoint-v3|claude-cache-lifetimes-v1|") == true)
        func revision() throws -> Int64 { try ledger.database.readRows("SELECT MAX(revision) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first ?? 0 }
        let enrichedRevision = try revision()
        _ = try await scanner.scan([preference])
        XCTAssertEqual(try revision(), enrichedRevision)
        try FileManager.default.removeItem(at: file)
        let deleted = try await scanner.scan([preference])
        XCTAssertEqual(deleted.summaries.first?.apiCostUSD, 0.000614)
        XCTAssertEqual(deleted.summaries.first?.inputTokens, 100)
        XCTAssertEqual(deleted.summaries.first?.requests, 1)
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-client-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func event(_ output: Int64 = 20, client: UsageClient = .claudeCode) -> ClientUsageEvent {
        ClientUsageEvent(client: client, eventID: "s:msg1", sessionID: "s", model: "test-model", timestamp: Date(timeIntervalSince1970: 1800000000), inputTokens: 100, outputTokens: output, cacheReadTokens: 60, cacheWriteTokens: 10, reasoningTokens: nil)
    }
    func testReplayUpdatesAndOtherClientAreIndependentWithoutCodexMutation() throws {
        let codex = root.appendingPathComponent("codex-token-index.sqlite")
        let sentinel = Data("existing Codex raw accounting".utf8); try sentinel.write(to: codex)
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("multi-client-usage.sqlite"))
        XCTAssertEqual(try ledger.ingest([event()]), 1)
        XCTAssertEqual(try ledger.ingest([event()]), 0)
        XCTAssertEqual(try ledger.ingest([event(40)]), 1)
        XCTAssertEqual(try ledger.ingest([event(10)]), 0, "copied/rotated earlier streaming records cannot reduce final counts")
        XCTAssertEqual(try ledger.ingest([event(5, client: .deepseek)]), 1)
        let summaries = try ledger.summaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first { $0.client == .claudeCode }?.outputTokens, 40)
        XCTAssertEqual(summaries.first { $0.client == .claudeCode }?.requests, 1)
        XCTAssertNil(summaries.first?.reasoningTokens)
        XCTAssertEqual(try Data(contentsOf: codex), sentinel)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 3)
    }

    func testReplayRepairsModelAndSessionColumnDriftWithoutChangingPayload() throws {
        var expected = event()
        expected.model = "claude-opus-5"
        let variants = [
            (name: "model", sessionID: expected.sessionID, model: "unknown"),
            (name: "session", sessionID: "legacy-owner", model: expected.model),
            (name: "both", sessionID: "legacy-owner", model: "unknown")
        ]
        for variant in variants {
            let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("column-drift-\(variant.name).sqlite"))
            XCTAssertEqual(try ledger.ingest([expected]), 1)
            let payload = try XCTUnwrap(ledger.database.readRows("SELECT payload FROM client_usage_events") { $0.text(0) }.first!)
            let revisions = try XCTUnwrap(ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!)
            try ledger.database.execute("UPDATE client_usage_events SET session_id=?,model=?",
                                        bindings: [.text(variant.sessionID), .text(variant.model)])
            XCTAssertEqual(try ledger.database.readRows("SELECT payload FROM client_usage_events") { $0.text(0) }.first!, payload)

            XCTAssertEqual(try ledger.ingest([expected]), 1, variant.name)

            XCTAssertEqual(try ledger.database.readRows("SELECT session_id FROM client_usage_events") { $0.text(0) }.first!, expected.sessionID, variant.name)
            XCTAssertEqual(try ledger.database.readRows("SELECT model FROM client_usage_events") { $0.text(0) }.first!, expected.model, variant.name)
            XCTAssertEqual(try ledger.database.readRows("SELECT payload FROM client_usage_events") { $0.text(0) }.first!, payload, variant.name)
            XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, revisions + 1, variant.name)
            XCTAssertEqual(try ledger.ingest([expected]), 0, variant.name)
            XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, revisions + 1, variant.name)
        }
    }

    func testNullableEventAndCheckpointColumnsRemainWritable() throws {
        let url = root.appendingPathComponent("additive-columns.sqlite")
        let original = try MultiClientUsageLedger(url: url)
        let initialCheckpoint = MultiClientFileCheckpoint(offset: 100, size: 100, modified: 10, identity: "inode")
        XCTAssertEqual(try original.ingest([event()], client: .claudeCode, sourceKey: "existing", checkpoint: initialCheckpoint), 1)
        try original.database.execute("""
        ALTER TABLE client_usage_events ADD COLUMN future_event TEXT;
        ALTER TABLE client_file_checkpoints ADD COLUMN future_checkpoint TEXT;
        UPDATE client_usage_events SET future_event='event-extension';
        UPDATE client_file_checkpoints SET future_checkpoint='checkpoint-extension';
        """)

        let ledger = try MultiClientUsageLedger(url: url)
        let updatedCheckpoint = MultiClientFileCheckpoint(offset: 200, size: 250, modified: 11, identity: "updated-inode")
        XCTAssertEqual(try ledger.ingest([event(40)], client: .claudeCode, sourceKey: "existing", checkpoint: updatedCheckpoint), 1)
        var added = event(30)
        added.eventID = "s:msg2"
        let addedCheckpoint = MultiClientFileCheckpoint(offset: 300, size: 350, modified: 12, identity: "new-inode")
        XCTAssertEqual(try ledger.ingest([added], client: .claudeCode, sourceKey: "added", checkpoint: addedCheckpoint), 1)

        XCTAssertEqual(try ledger.summaries().first?.outputTokens, 70)
        XCTAssertEqual(try ledger.summaries().first?.requests, 2)
        XCTAssertEqual(try ledger.database.readRows("SELECT future_event FROM client_usage_events WHERE event_id='s:msg1'") { $0.text(0) }.first!, "event-extension")
        XCTAssertNil(try ledger.database.readRows("SELECT future_event FROM client_usage_events WHERE event_id='s:msg2'") { $0.text(0) }.first!)
        XCTAssertEqual(try ledger.database.readRows("SELECT future_checkpoint FROM client_file_checkpoints WHERE source_key='existing'") { $0.text(0) }.first!, "checkpoint-extension")
        XCTAssertNil(try ledger.database.readRows("SELECT future_checkpoint FROM client_file_checkpoints WHERE source_key='added'") { $0.text(0) }.first!)
        for (key, expected) in [("existing", updatedCheckpoint), ("added", addedCheckpoint)] {
            let actual = try XCTUnwrap(ledger.checkpoint(client: .claudeCode, sourceKey: key))
            XCTAssertEqual(actual.offset, expected.offset)
            XCTAssertEqual(actual.size, expected.size)
            XCTAssertEqual(actual.modified, expected.modified)
            XCTAssertEqual(actual.identity, expected.identity)
        }
        XCTAssertEqual(try ledger.database.readRows("PRAGMA user_version") { $0.int(0) }.first!, MultiClientUsageLedger.schemaVersion)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 3)
    }

    func testCheckpointAndEventsRollbackTogether() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let checkpoint = MultiClientFileCheckpoint(offset: 100, size: 100, modified: 10, identity: "inode")
        _ = try ledger.ingest([event()], client: .claudeCode, sourceKey: "file", checkpoint: checkpoint)
        var invalid = event(30); invalid.inputTokens = -1
        XCTAssertThrowsError(try ledger.ingest([invalid], client: .claudeCode, sourceKey: "file", checkpoint: .init(offset: 200, size: 200, modified: 11, identity: "inode")))
        XCTAssertEqual(try ledger.checkpoint(client: .claudeCode, sourceKey: "file")?.offset, 100)
        XCTAssertEqual(try ledger.summaries().first?.outputTokens, 20)
    }

    func testCheckpointTransactionRejectsOppositeClaudeOwnerBeforeWriting() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("claude-owner-fence.sqlite"))
        let original = MultiClientFileCheckpoint(offset: 100, size: 100, modified: 10, identity: "legacy")
        XCTAssertEqual(try ledger.ingest([event()], client: .claudeCode, sourceKey: "source", checkpoint: original), 1)

        XCTAssertThrowsError(try ledger.ingest(
            [event(30, client: .claudeDesktop)],
            client: .claudeDesktop,
            sourceKey: "source",
            checkpoint: .init(offset: 200, size: 200, modified: 11, identity: "reclassified")
        )) { error in
            guard let ledgerError = error as? MultiClientUsageLedger.LedgerError,
                  case .claudeCheckpointConflict(.claudeCode) = ledgerError else {
                return XCTFail("Expected the transaction-time Claude owner fence, got \(error)")
            }
        }
        XCTAssertEqual(try ledger.checkpoint(client: .claudeCode, sourceKey: "source")?.identity, "legacy")
        XCTAssertNil(try ledger.checkpoint(client: .claudeDesktop, sourceKey: "source"))
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int(0) }.first, 1)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first, 1)
    }

    func testRowwiseEncodingRollsBackLateDatabaseFailureAndKeepsOriginalRevisions() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("rowwise.sqlite"))
        let initial = MultiClientFileCheckpoint(offset: 100, size: 100, modified: 10, identity: "inode")
        let advanced = MultiClientFileCheckpoint(offset: 200, size: 200, modified: 11, identity: "inode")
        XCTAssertEqual(try ledger.ingest([event()], client: .claudeCode, sourceKey: "file", checkpoint: initial), 1)
        func rows(_ sql: String) throws -> [String] {
            try ledger.database.readRows(sql) { $0.text(0) ?? "" }
        }
        let eventsSQL = "SELECT event_id || ':' || payload FROM client_usage_events ORDER BY client,event_id"
        let revisionsSQL = "SELECT CAST(revision AS TEXT) || ':' || event_id || ':' || payload FROM client_usage_revisions ORDER BY revision"
        let sequenceSQL = "SELECT name || ':' || CAST(seq AS TEXT) FROM sqlite_sequence ORDER BY name"
        let beforeEvents = try rows(eventsSQL), beforeRevisions = try rows(revisionsSQL), beforeSequence = try rows(sequenceSQL)
        var update = event(40)
        update.inputTokens = 50 // Revision keeps the incoming observation; projection keeps the prior maximum.
        var inserted = event(30); inserted.eventID = "s:new"
        var failure = event(60); failure.eventID = "s:failure"
        let batch = [update, inserted, failure]
        try ledger.database.execute("""
        CREATE TRIGGER fail_late_revision BEFORE INSERT ON client_usage_revisions
        WHEN NEW.event_id='s:failure' BEGIN SELECT RAISE(ABORT, 'injected late revision failure'); END
        """)
        XCTAssertThrowsError(try ledger.ingest(batch, client: .claudeCode, sourceKey: "file", checkpoint: advanced))
        XCTAssertEqual(try rows(eventsSQL), beforeEvents)
        XCTAssertEqual(try rows(revisionsSQL), beforeRevisions)
        XCTAssertEqual(try rows(sequenceSQL), beforeSequence)
        XCTAssertEqual(try ledger.checkpoint(client: .claudeCode, sourceKey: "file")?.offset, initial.offset)

        try ledger.database.execute("DROP TRIGGER fail_late_revision")
        XCTAssertEqual(try ledger.ingest(batch, client: .claudeCode, sourceKey: "file", checkpoint: advanced), 3)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let originalPayload = String(decoding: try encoder.encode(update), as: UTF8.self)
        let revisions = try ledger.database.readRows(
            "SELECT payload FROM client_usage_revisions WHERE event_id=? ORDER BY revision DESC",
            bindings: [.text(update.eventID)]) { $0.text(0) ?? "" }
        XCTAssertEqual(revisions.first, originalPayload)
        XCTAssertEqual(try ledger.database.readRows("SELECT input_tokens FROM client_usage_events WHERE event_id=?",
            bindings: [.text(update.eventID)]) { $0.int64(0) }.first!, 100)
        XCTAssertEqual(try ledger.checkpoint(client: .claudeCode, sourceKey: "file")?.offset, advanced.offset)
        XCTAssertEqual(try ledger.ingest(batch, client: .claudeCode, sourceKey: "file", checkpoint: advanced), 0)
        XCTAssertEqual(try rows(revisionsSQL).count, 4)
    }

    func testBackupIncludesCommittedWALAndFutureSchemaIsNotDowngraded() throws {
        let url = root.appendingPathComponent("usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        _ = try ledger.ingest([event()])
        let backup = try ledger.backup()
        let copy = SQLiteDatabaseDriver(url: backup, readOnly: true)
        XCTAssertEqual(try copy.readRows("SELECT SUM(output_tokens) FROM client_usage_events") { $0.int64(0) }.first!, 20)
        try ledger.database.execute("PRAGMA user_version=99")
        XCTAssertThrowsError(try MultiClientUsageLedger(url: url))
        XCTAssertEqual(try ledger.database.readRows("PRAGMA user_version") { $0.int(0) }.first!, 99)
    }

    func testLongLivedLedgerWriterRechecksSchemaInsideWriteTransaction() throws {
        let url = root.appendingPathComponent("stale-writer.sqlite")
        let ledger = try MultiClientUsageLedger(url: url)
        XCTAssertEqual(try ledger.ingest([event()]), 1)
        let peer = SQLiteDatabaseDriver(url: url, bypassBusinessRoutes: true)
        try peer.execute("PRAGMA user_version=99")

        var later = event(30)
        later.eventID = "s:later"
        let checkpoint = MultiClientFileCheckpoint(offset: 200, size: 200, modified: 11, identity: "inode")
        XCTAssertThrowsError(try ledger.ingest([later], client: .claudeCode, sourceKey: "file", checkpoint: checkpoint)) { error in
            guard let ledgerError = error as? MultiClientUsageLedger.LedgerError,
                  case .newerSchema(let version) = ledgerError else {
                return XCTFail("Expected the transaction-time future-schema refusal, got \(error)")
            }
            XCTAssertEqual(version, 99)
        }
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int(0) }.first!, 1)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 1)
        XCTAssertTrue(try ledger.database.readRows("SELECT 1 FROM client_file_checkpoints") { $0.int(0) }.isEmpty)
        XCTAssertEqual(try peer.readRows("PRAGMA user_version") { $0.int(0) }.first!, 99)

        try peer.execute("PRAGMA user_version=1")
        later.eventID = "s:older-schema"
        XCTAssertThrowsError(try ledger.ingest([later])) { error in
            guard let ledgerError = error as? MultiClientUsageLedger.LedgerError,
                  case .incompatibleSchema = ledgerError else {
                return XCTFail("Expected the transaction-time incompatible-schema refusal, got \(error)")
            }
        }
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int(0) }.first!, 1)
        XCTAssertEqual(try ledger.database.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 1)
    }

    func testRefusingFutureDeleteModeDatabasePreservesEveryByteAndCreatesNoSidecars() throws {
        let url = root.appendingPathComponent("future.sqlite")
        let original = SQLiteDatabaseDriver(url: url)
        try original.execute("CREATE TABLE future_proof(id INTEGER PRIMARY KEY, payload BLOB)")
        try original.execute("INSERT INTO future_proof VALUES(42, X'001122334455')")
        try original.execute("PRAGMA user_version=99")
        XCTAssertEqual(try original.readRows("PRAGMA journal_mode") { $0.text(0) }.first!, "delete")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try MultiClientUsageLedger(url: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }
        XCTAssertEqual(try original.readRows("SELECT id FROM future_proof") { $0.int(0) }.first!, 42)
    }

    func testReadOnlyCacheRankingRejectsFutureSchemaWithoutChangingExistingLedger() throws {
        let url = root.appendingPathComponent("future-rankings.sqlite")
        let sourceURL = root.appendingPathComponent("future-rankings-source.sqlite")
        let ledger = try MultiClientUsageLedger(url: sourceURL)
        var rankedEvent = event()
        rankedEvent.inputTokens = 2_000
        _ = try ledger.ingest([rankedEvent], client: .claudeCode, sourceKey: "fixture",
                              checkpoint: .init(offset: 100, size: 100, modified: 10, identity: "fixture"))
        let source = SQLiteDatabaseDriver(url: sourceURL)
        try source.execute("PRAGMA user_version=99")
        let original = try prepareDeleteModeFixture(driver: source, url: url)
        let before = try Data(contentsOf: url)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

        XCTAssertThrowsError(try MultiClientUsageLedger.readOnlyCacheRankingProjection(url: url, clients: [.claudeCode])) { error in
            guard let ledgerError = error as? MultiClientUsageLedger.LedgerError,
                  case .newerSchema(let version) = ledgerError else {
                return XCTFail("Expected the future-schema admission error, got \(error)")
            }
            XCTAssertEqual(version, 99)
        }

        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), filesBefore)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix), "Refusal left \(suffix)")
        }
        XCTAssertEqual(try original.readRows("PRAGMA user_version") { $0.int(0) }.first!, 99)
        XCTAssertEqual(try original.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 1)
        XCTAssertEqual(try original.readRows("SELECT offset FROM client_file_checkpoints") { $0.int64(0) }.first!, 100)
    }

    func testReadOnlyCacheRankingReadsCurrentSchemaWithoutChangingExistingLedger() throws {
        let url = root.appendingPathComponent("current-rankings.sqlite")
        let sourceURL = root.appendingPathComponent("current-rankings-source.sqlite")
        let ledger = try MultiClientUsageLedger(url: sourceURL)
        var rankedEvent = event()
        rankedEvent.inputTokens = 2_000
        _ = try ledger.ingest([rankedEvent])
        let expected = try ledger.cacheRankingProjection(clients: [.claudeCode])
        let original = try prepareDeleteModeFixture(driver: SQLiteDatabaseDriver(url: sourceURL), url: url)
        let before = try Data(contentsOf: url)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

        let actual = try MultiClientUsageLedger.readOnlyCacheRankingProjection(url: url, clients: [.claudeCode])

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.matchingRequestCount, 1)
        XCTAssertEqual(actual.requests.first?.eventID, rankedEvent.eventID)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), filesBefore)
        XCTAssertEqual(try original.readRows("PRAGMA user_version") { $0.int(0) }.first!, MultiClientUsageLedger.schemaVersion)
        XCTAssertEqual(try original.readRows("SELECT COUNT(*) FROM client_usage_revisions") { $0.int(0) }.first!, 1)
    }

    func testCurrentVersionWithUnrelatedSchemaIsRejectedBeforeAnyWrite() throws {
        let url = root.appendingPathComponent("wrong-shape.sqlite")
        let source = SQLiteDatabaseDriver(url: root.appendingPathComponent("wrong-shape-source.sqlite"))
        try source.execute("CREATE TABLE unrelated(id INTEGER PRIMARY KEY); INSERT INTO unrelated VALUES(42); PRAGMA user_version=2")
        let original = try prepareDeleteModeFixture(driver: source, url: url)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try MultiClientUsageLedger(url: url))
        XCTAssertThrowsError(try MultiClientUsageLedger.readOnlyCacheRankingProjection(url: url, clients: [.claudeCode])) { error in
            guard let ledgerError = error as? MultiClientUsageLedger.LedgerError,
                  case .incompatibleSchema = ledgerError else {
                return XCTFail("Expected the schema admission error, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertEqual(try original.readRows("SELECT id FROM unrelated") { $0.int(0)! }, [42])
    }

    func testNegativeSchemaVersionIsRejectedWithoutChangingDatabaseFiles() throws {
        let directory = root.appendingPathComponent("negative-version", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.sqlite")
        let original = SQLiteDatabaseDriver(url: url)
        try original.execute("CREATE TABLE unrelated(id INTEGER PRIMARY KEY); INSERT INTO unrelated VALUES(42); PRAGMA user_version=-1")

        try assertSchemaRefusalPreservesFiles(at: url, version: -1)

        XCTAssertEqual(try original.readRows("SELECT id FROM unrelated") { $0.int(0)! }, [42])
    }

    func testIncompleteTablesAndCollidingViewsAreRejectedAtEverySupportedVersion() throws {
        let objects: [(name: String, columns: [String])] = [
            ("client_usage_events", ["client", "event_id", "session_id", "model", "timestamp", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "payload"]),
            ("client_usage_revisions", ["revision", "client", "event_id", "captured_at", "payload"]),
            ("client_file_checkpoints", ["client", "source_key", "offset", "size", "modified", "identity"]),
            ("multi_usage_metadata", ["key", "value"])
        ]
        for version in [0, 1, MultiClientUsageLedger.schemaVersion] {
            for object in objects {
                for kind in ["table", "view"] {
                    let directory = root.appendingPathComponent("refuse-v\(version)-\(object.name)-\(kind)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("usage.sqlite")
                    let sourceURL = directory.appendingPathComponent("source.sqlite")
                    let ledger = try MultiClientUsageLedger(url: sourceURL)
                    try ledger.database.execute("DROP TABLE IF EXISTS \(object.name)")
                    if kind == "table" {
                        let columns = object.name == "client_usage_events" ? "client TEXT,model TEXT,timestamp REAL" : "\(object.columns[0]) TEXT"
                        try ledger.database.execute("CREATE TABLE \(object.name)(\(columns))")
                    } else {
                        // A view with all required names must still be refused as a non-table.
                        let columns = object.columns.map { "NULL AS \($0)" }.joined(separator: ",")
                        try ledger.database.execute("CREATE VIEW \(object.name) AS SELECT \(columns)")
                    }
                    let source = SQLiteDatabaseDriver(url: sourceURL)
                    try source.execute("PRAGMA user_version=\(version)")
                    _ = try prepareDeleteModeFixture(driver: source, url: url)

                    try assertSchemaRefusalPreservesFiles(at: url, version: version)
                }
            }
        }
    }

    func testExistingTablesMustKeepLedgerIdentityConstraints() throws {
        let malformed: [(table: String, ddl: String)] = [
            ("client_usage_events", """
             CREATE TABLE client_usage_events (
                 client TEXT NOT NULL, event_id TEXT NOT NULL, session_id TEXT NOT NULL,
                 model TEXT NOT NULL, timestamp REAL NOT NULL, input_tokens INTEGER NOT NULL,
                 output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                 reasoning_tokens INTEGER, payload TEXT NOT NULL)
             ; CREATE UNIQUE INDEX event_identity_nocase
                 ON client_usage_events(client,event_id COLLATE NOCASE)
             """),
            ("client_file_checkpoints", """
             CREATE TABLE client_file_checkpoints (
                 client TEXT NOT NULL, source_key TEXT NOT NULL, offset INTEGER NOT NULL,
                 size INTEGER NOT NULL, modified REAL NOT NULL, identity TEXT NOT NULL)
             """),
            ("client_usage_revisions", """
             CREATE TABLE client_usage_revisions (
                 revision INTEGER, client TEXT NOT NULL, event_id TEXT NOT NULL,
                 captured_at REAL NOT NULL, payload TEXT NOT NULL)
             """),
            ("client_usage_revisions", """
             CREATE TABLE client_usage_revisions (
                 revision INTEGER, client TEXT NOT NULL, event_id TEXT NOT NULL,
                 captured_at REAL NOT NULL, payload TEXT NOT NULL,
                 PRIMARY KEY(revision, client))
             """),
            ("client_usage_revisions", """
             CREATE TABLE client_usage_revisions (
                 revision INTEGER PRIMARY KEY DESC, client TEXT NOT NULL,
                 event_id TEXT NOT NULL, captured_at REAL NOT NULL, payload TEXT NOT NULL)
             """),
            ("multi_usage_metadata", "CREATE TABLE multi_usage_metadata (key TEXT, value TEXT NOT NULL)")
        ]

        for version in [1, MultiClientUsageLedger.schemaVersion] {
            for invalid in malformed {
                let directory = root.appendingPathComponent(
                    "missing-key-v\(version)-\(invalid.table)", isDirectory: true
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let sourceURL = directory.appendingPathComponent("source.sqlite")
                _ = try MultiClientUsageLedger(url: sourceURL)
                let source = SQLiteDatabaseDriver(url: sourceURL)
                try source.execute("DROP TABLE \(invalid.table); \(invalid.ddl); PRAGMA user_version=\(version)")
                let targetURL = directory.appendingPathComponent("usage.sqlite")
                _ = try prepareDeleteModeFixture(driver: source, url: targetURL)

                try assertSchemaRefusalPreservesFiles(at: targetURL, version: version)
            }
        }
    }

    func testEquivalentUniqueIndexesRemainSupportedForLedgerKeys() throws {
        let sourceURL = root.appendingPathComponent("unique-index-source.sqlite")
        _ = try MultiClientUsageLedger(url: sourceURL)
        let source = SQLiteDatabaseDriver(url: sourceURL)
        try source.execute("""
            DROP TABLE client_usage_events;
            CREATE TABLE client_usage_events (
                client TEXT NOT NULL, event_id TEXT NOT NULL, session_id TEXT NOT NULL,
                model TEXT NOT NULL, timestamp REAL NOT NULL, input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                reasoning_tokens INTEGER, payload TEXT NOT NULL);
            CREATE UNIQUE INDEX event_identity ON client_usage_events(event_id,client);
            DROP TABLE client_file_checkpoints;
            CREATE TABLE client_file_checkpoints (
                client TEXT NOT NULL, source_key TEXT NOT NULL, offset INTEGER NOT NULL,
                size INTEGER NOT NULL, modified REAL NOT NULL, identity TEXT NOT NULL);
            CREATE UNIQUE INDEX checkpoint_identity ON client_file_checkpoints(source_key,client);
            DROP TABLE multi_usage_metadata;
            CREATE TABLE multi_usage_metadata (key TEXT NOT NULL, value TEXT NOT NULL);
            CREATE UNIQUE INDEX metadata_identity ON multi_usage_metadata(key);
            """)
        let url = root.appendingPathComponent("unique-index.sqlite")
        _ = try prepareDeleteModeFixture(driver: source, url: url)

        let ledger = try MultiClientUsageLedger(url: url)
        let checkpoint = MultiClientFileCheckpoint(offset: 100, size: 100, modified: 10, identity: "fixture")
        XCTAssertEqual(try ledger.ingest([event()], client: .claudeCode, sourceKey: "fixture", checkpoint: checkpoint), 1)
        let eventCount = try ledger.database.readRows(
            "SELECT COUNT(*) FROM client_usage_events WHERE client=?",
            bindings: [.text(UsageClient.claudeCode.rawValue)]
        ) { $0.int(0) ?? 0 }.first ?? 0
        XCTAssertEqual(eventCount, 1)
        let saved = try XCTUnwrap(ledger.checkpoint(client: .claudeCode, sourceKey: "fixture"))
        XCTAssertEqual(saved.offset, checkpoint.offset)
        XCTAssertEqual(saved.size, checkpoint.size)
        XCTAssertEqual(saved.modified, checkpoint.modified)
        XCTAssertEqual(saved.identity, checkpoint.identity)
    }

    func testWALSchemaRefusalPreservesMainAndWALContents() throws {
        let url = root.appendingPathComponent("wal-schema-refusal.sqlite")
        _ = try MultiClientUsageLedger(url: url)
        let writer = SQLiteDatabaseDriver(url: url, enableWAL: false)

        try writer.withConnection { connection in
            try connection.execute("""
                DROP TABLE client_usage_events;
                CREATE TABLE client_usage_events (
                    client TEXT NOT NULL, event_id TEXT NOT NULL, session_id TEXT NOT NULL,
                    model TEXT NOT NULL, timestamp REAL NOT NULL, input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER,
                    cache_write_tokens INTEGER, reasoning_tokens INTEGER, payload TEXT NOT NULL);
                PRAGMA user_version=\(MultiClientUsageLedger.schemaVersion);
                """)
            XCTAssertEqual(try connection.readRows("PRAGMA journal_mode") { $0.text(0) }.first!, "wal")

            let walURL = URL(fileURLWithPath: url.path + "-wal")
            XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
            let databaseBytes = try Data(contentsOf: url)
            let walBytes = try Data(contentsOf: walURL)
            XCTAssertThrowsError(try MultiClientUsageLedger(url: url)) { error in
                guard let ledgerError = error as? MultiClientUsageLedger.LedgerError,
                      case .incompatibleSchema = ledgerError else {
                    return XCTFail("Expected schema admission refusal, got \(error)")
                }
            }

            XCTAssertEqual(try Data(contentsOf: url), databaseBytes)
            XCTAssertEqual(try Data(contentsOf: walURL), walBytes)
            XCTAssertEqual(try connection.readRows("PRAGMA user_version") { $0.int(0) }.first!,
                           MultiClientUsageLedger.schemaVersion)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true).path
            ))
        }
    }

    func testUnversionedUnrelatedDatabaseIsBackedUpBeforeUpgrade() throws {
        let url = root.appendingPathComponent("unversioned-unrelated.sqlite")
        let original = SQLiteDatabaseDriver(url: url)
        try original.execute("CREATE TABLE unrelated(id INTEGER PRIMARY KEY,payload TEXT NOT NULL); INSERT INTO unrelated VALUES(42,'preserved'); PRAGMA user_version=0")

        let ledger = try MultiClientUsageLedger(url: url)

        XCTAssertEqual(try ledger.database.readRows("PRAGMA user_version") { $0.int(0) }.first!, MultiClientUsageLedger.schemaVersion)
        XCTAssertEqual(try ledger.database.readRows("SELECT payload FROM unrelated WHERE id=42") { $0.text(0) }.first!, "preserved")
        XCTAssertEqual(try ledger.ingest([event()]), 1)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("backups", isDirectory: true), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = SQLiteDatabaseDriver(url: try XCTUnwrap(backups.first), readOnly: true, createsFileIfMissing: false)
        XCTAssertEqual(try backup.readRows("PRAGMA user_version") { $0.int(0) }.first!, 0)
        XCTAssertEqual(try backup.readRows("SELECT payload FROM unrelated WHERE id=42") { $0.text(0) }.first!, "preserved")
        XCTAssertTrue(try backup.readRows("SELECT name FROM sqlite_master WHERE name='client_usage_events'") { $0.text(0) }.isEmpty)
    }

    private func prepareDeleteModeFixture(driver: SQLiteDatabaseDriver, url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> SQLiteDatabaseDriver {
        // A WAL-to-DELETE conversion can leave an orphan -shm on macOS. Retain
        // that source intact and test a fresh SQLite-created DELETE snapshot.
        XCTAssertNotEqual(driver.url.standardizedFileURL, url.standardizedFileURL, "Fixture snapshot must use a new path", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Fixture snapshot target must not exist", file: file, line: line)
        try driver.execute("VACUUM INTO ?", bindings: [.text(url.path)])
        let fixture = SQLiteDatabaseDriver(url: url, createsFileIfMissing: false, enableWAL: false)
        let checkpoint = try fixture.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
        let busy = try XCTUnwrap(checkpoint.first ?? nil, "Fixture checkpoint returned no busy status", file: file, line: line)
        XCTAssertEqual(busy, 0, "Fixture checkpoint must finish before the baseline snapshot", file: file, line: line)
        let modes = try fixture.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
        let mode = try XCTUnwrap(modes.first ?? nil, "Fixture journal mode returned no result", file: file, line: line)
        XCTAssertEqual(mode, "delete", "Fixture must enter DELETE mode before the baseline snapshot", file: file, line: line)
        let header = try Data(contentsOf: url)
        XCTAssertEqual(Array(header.dropFirst(18).prefix(2)), [1, 1], "Fixture header bytes 18/19 must both be 1", file: file, line: line)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix), "Fixture setup left \(suffix) before the baseline snapshot", file: file, line: line)
        }
        return fixture
    }

    private func assertSchemaRefusalPreservesFiles(at url: URL, version: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent("existing.sqlite")
        let backupBytes = Data("preexisting backup must remain unchanged".utf8)
        try backupBytes.write(to: backup)
        let bytes = try Data(contentsOf: url)
        let paths = try fm.subpathsOfDirectory(atPath: directory.path).sorted()
        let original = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        let attempts: [() throws -> Void] = [
            { _ = try MultiClientUsageLedger(url: url) },
            { _ = try MultiClientUsageLedger(url: url, readOnly: true) },
            { _ = try MultiClientUsageLedger.readOnlyCacheRankingProjection(url: url, clients: [.claudeCode]) }
        ]
        for attempt in attempts {
            XCTAssertThrowsError(try attempt(), url.deletingLastPathComponent().lastPathComponent, file: file, line: line) { error in
                guard let ledgerError = error as? MultiClientUsageLedger.LedgerError,
                      case .incompatibleSchema = ledgerError else {
                    return XCTFail("Expected schema admission refusal, got \(error)", file: file, line: line)
                }
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes, file: file, line: line)
            XCTAssertEqual(try original.readRows("PRAGMA user_version") { $0.int(0) }.first!, version, file: file, line: line)
            XCTAssertEqual(try fm.subpathsOfDirectory(atPath: directory.path).sorted(), paths, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: backup), backupBytes, file: file, line: line)
            for suffix in ["-wal", "-shm", "-journal"] {
                XCTAssertFalse(fm.fileExists(atPath: url.path + suffix), "Refusal left \(suffix)", file: file, line: line)
            }
        }
    }

    func testTrendBucketsUseFiveMinuteUTCWindowsAndConserveRawEvents() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let now: Int64 = 1_800_000_600
        let cutoff = now - 30 * 24 * 60 * 60
        func sample(_ id: String, _ timestamp: Int64, _ input: Int64, _ output: Int64,
                    client: UsageClient = .claudeCode, cacheRead: Int64? = nil,
                    cacheWrite: Int64? = nil, reasoning: Int64? = nil) -> ClientUsageEvent {
            ClientUsageEvent(client: client, eventID: id, sessionID: id, model: "fixture",
                timestamp: Date(timeIntervalSince1970: Double(timestamp)), inputTokens: input,
                outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                reasoningTokens: reasoning)
        }
        _ = try ledger.ingest([
            sample("before-cutoff", cutoff - 1, 100, 100),
            sample("at-cutoff", cutoff, 10, 1, cacheWrite: 2),
            sample("same-bucket", cutoff + 299, 3, 4, cacheRead: 5, reasoning: 7),
            sample("next-bucket", cutoff + 300, 2, 3),
            sample("last-client", now - 1, 8, 9, client: .deepseek, cacheRead: 10,
                   cacheWrite: 11, reasoning: 12),
            sample("at-upper-bound", now, 100, 100),
            sample("after-upper-bound", now + 1, 100, 100)
        ])

        let buckets = try ledger.trendBuckets(now: Date(timeIntervalSince1970: Double(now)))
        XCTAssertEqual(buckets.count, 4)
        XCTAssertTrue(buckets.allSatisfy { $0.startUnix % 300 == 0 })
        XCTAssertEqual(buckets.reduce(Int64(0)) { $0 + $1.inputTokens + $1.outputTokens }, 240)

        let first = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == cutoff })
        XCTAssertEqual(first.inputTokens, 13)
        XCTAssertEqual(first.outputTokens, 5)
        XCTAssertEqual(first.cacheReadTokens, 5)
        XCTAssertEqual(first.cacheWriteTokens, 2)
        XCTAssertEqual(first.reasoningTokens, 7)
        XCTAssertEqual(first.requests, 2)

        let next = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == cutoff + 300 })
        XCTAssertNil(next.cacheReadTokens)
        XCTAssertNil(next.cacheWriteTokens)
        XCTAssertNil(next.reasoningTokens)
        XCTAssertEqual(next.requests, 1)

        let latest = try XCTUnwrap(buckets.first { $0.client == .deepseek })
        XCTAssertEqual(latest.startUnix, now - 300)
        let upper = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == now })
        XCTAssertEqual(upper.requests, 1)
    }
    func testDailyBucketsUseLocalCalendarDaysAndConserveRawEvents() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_800_000_600)
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -364, to: today)!
        let nextDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: firstDay)!)
        func sample(_ id: String, _ timestamp: Date, _ input: Int64, _ output: Int64,
                    client: UsageClient = .claudeCode, cacheRead: Int64? = nil,
                    cacheWrite: Int64? = nil, reasoning: Int64? = nil) -> ClientUsageEvent {
            ClientUsageEvent(client: client, eventID: id, sessionID: id, model: "fixture",
                timestamp: timestamp, inputTokens: input, outputTokens: output,
                cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, reasoningTokens: reasoning)
        }
        _ = try ledger.ingest([
            sample("before-window", firstDay.addingTimeInterval(-1), 100, 100),
            sample("at-window", firstDay, 10, 1, cacheWrite: 2),
            sample("same-day", firstDay.addingTimeInterval(299), 3, 4, cacheRead: 5, reasoning: 7),
            sample("next-day", nextDay, 2, 3),
            sample("last-client", now.addingTimeInterval(-1), 8, 9, client: .deepseek,
                   cacheRead: 10, cacheWrite: 11, reasoning: 12),
            sample("at-upper-bound", now, 100, 100),
            sample("after-upper-bound", now.addingTimeInterval(1), 100, 100)
        ])

        let buckets = try ledger.dailyBuckets(now: now)
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(buckets.reduce(Int64(0)) { $0 + $1.inputTokens + $1.outputTokens }, 240)
        XCTAssertTrue(buckets.allSatisfy {
            let start = Date(timeIntervalSince1970: Double($0.startUnix))
            return calendar.startOfDay(for: start).timeIntervalSince1970 == Double($0.startUnix)
        })

        let first = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == Int64(firstDay.timeIntervalSince1970) })
        XCTAssertEqual(first.inputTokens, 13)
        XCTAssertEqual(first.outputTokens, 5)
        XCTAssertEqual(first.cacheReadTokens, 5)
        XCTAssertEqual(first.cacheWriteTokens, 2)
        XCTAssertEqual(first.reasoningTokens, 7)
        XCTAssertEqual(first.requests, 2)

        let next = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == Int64(nextDay.timeIntervalSince1970) })
        XCTAssertEqual(next.requests, 1)
        XCTAssertNil(next.cacheReadTokens)
        XCTAssertNil(next.cacheWriteTokens)
        XCTAssertNil(next.reasoningTokens)
        let current = try XCTUnwrap(buckets.first { $0.client == .claudeCode && $0.startUnix == Int64(today.timeIntervalSince1970) })
        XCTAssertEqual(current.requests, 1)
        let otherClient = try XCTUnwrap(buckets.first { $0.client == .deepseek && $0.startUnix == Int64(today.timeIntervalSince1970) })
        XCTAssertEqual(otherClient.requests, 1)
    }
    func testSummariesPriceEachKnownRequestAndKeepUnpricedRowsVisible() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        func pricedEvent(_ id: String, client: UsageClient = .claudeCode, model: String,
                         input: Int64, output: Int64, cacheRead: Int64? = 0,
                         cacheWrite: Int64? = 0) -> ClientUsageEvent {
            ClientUsageEvent(client: client, eventID: id, sessionID: id, model: model,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: input,
                outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite)
        }
        _ = try ledger.ingest([
            pricedEvent("standard", model: "gpt-6.1-sol", input: 100, output: 10),
            pricedEvent("unknown-cache-read", model: "gpt-6.1-sol", input: 100, output: 10,
                        cacheRead: nil),
            pricedEvent("small-a", client: .claudeDesktop, model: "gpt-6.1-sol", input: 140_000, output: 0),
            pricedEvent("small-b", client: .claudeDesktop, model: "gpt-6.1-sol", input: 140_000, output: 0),
            pricedEvent("long", client: .deepseek, model: "gpt-6.1-sol", input: 280_000, output: 0),
            pricedEvent("unknown-model", model: "unlisted-provider-model", input: 100, output: 10),
            pricedEvent("unknown-write-lifetime", model: "claude-opus-5-5", input: 100, output: 0, cacheWrite: 1),
            pricedEvent("time-dependent-price", client: .deepseek, model: "deepseek-reasoner", input: 100, output: 10),
            pricedEvent("namespace-alias", client: .opencode, model: "openai/gpt-5.5-2026-04-23", input: 100, output: 10),
            pricedEvent("explicit-fast", client: .gemini, model: "gpt-6.1-sol-fast", input: 100, output: 10),
            pricedEvent("half-up", client: .claudeDesktop, model: "gpt-5.5", input: 1, output: 0, cacheRead: 1),
            pricedEvent("free", client: .opencode, model: "glm-4.7-flash", input: 0, output: 0,
                        cacheRead: nil, cacheWrite: nil)
        ])

        let summaries = try ledger.summaries()
        let standard = try XCTUnwrap(summaries.first { $0.client == .claudeCode && $0.model == "gpt-6.1-sol" })
        XCTAssertEqual(try XCTUnwrap(standard.apiCostUSD), 0.0003, accuracy: 0.000000001)
        XCTAssertEqual(standard.unpricedRequests, 1)
        XCTAssertFalse(standard.cacheReadComplete)

        let twoSmall = try XCTUnwrap(summaries.first { $0.client == .claudeDesktop && $0.model == "gpt-6.1-sol" })
        XCTAssertEqual(try XCTUnwrap(twoSmall.apiCostUSD), 0.56, accuracy: 0.000000001,
                       "Two 140k requests each use the base tier even though their combined input exceeds the threshold")
        XCTAssertEqual(twoSmall.unpricedRequests, 0)
        XCTAssertTrue(twoSmall.cacheReadComplete)
        let long = try XCTUnwrap(summaries.first { $0.client == .deepseek && $0.model == "gpt-6.1-sol" })
        XCTAssertEqual(try XCTUnwrap(long.apiCostUSD), 1.12, accuracy: 0.000000001)

        let unknown = try XCTUnwrap(summaries.first { $0.model == "unlisted-provider-model" })
        XCTAssertNil(unknown.apiCostUSD)
        XCTAssertEqual(unknown.unpricedRequests, 1)
        let lifetime = try XCTUnwrap(summaries.first { $0.model == "claude-opus-5-5" })
        XCTAssertEqual(lifetime.apiCostUSD, 0.000401)
        XCTAssertEqual(lifetime.unpricedRequests, 0)
        let timeDependent = try XCTUnwrap(summaries.first { $0.model == "deepseek-reasoner" })
        XCTAssertEqual(try XCTUnwrap(timeDependent.apiCostUSD), 0.000017, accuracy: 0.000000001)
        XCTAssertEqual(timeDependent.unpricedRequests, 0)
        let alias = try XCTUnwrap(summaries.first { $0.model == "openai/gpt-5.5-2026-04-23" })
        XCTAssertEqual(alias.apiCostUSD, 0.0008)
        let fast = try XCTUnwrap(summaries.first { $0.model == "gpt-6.1-sol-fast" })
        XCTAssertEqual(fast.apiCostUSD, 0.0006)
        let halfUp = try XCTUnwrap(summaries.first { $0.client == .claudeDesktop && $0.model == "gpt-5.5" })
        XCTAssertEqual(halfUp.apiCostUSD, 0.000001)
        let free = try XCTUnwrap(summaries.first { $0.model == "glm-4.7-flash" })
        XCTAssertEqual(free.apiCostUSD, 0)
        XCTAssertEqual(free.unpricedRequests, 0)
    }

    func testSharedPriceBookUsesEventTimeForDeepSeekPeakHolidayAndHistoricalRates() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("timed-prices.sqlite"))
        let cases: [(String, String, Double)] = [
            ("peak", "2026-10-30T01:00:00Z", 1.4412),
            ("before-boundary", "2026-10-30T03:59:59Z", 1.4412),
            ("offpeak", "2026-10-30T04:00:00Z", 0.7206),
            ("second-peak", "2026-10-30T06:00:00Z", 1.4412),
            ("second-end", "2026-10-30T10:00:00Z", 0.7206),
            ("weekend", "2026-10-31T02:00:00Z", 0.7206),
            ("holiday", "2026-10-01T02:00:00Z", 0.7206),
            ("historical", "2026-08-10T02:00:00Z", 0.39256),
            ("older-peak", "2026-08-17T02:00:00Z", 1.6748)
        ]
        let formatter = ISO8601DateFormatter()
        for (id, time, _) in cases {
            _ = try ledger.ingest([ClientUsageEvent(client: .deepseek, eventID: id, sessionID: id,
                model: "\(id)/deepseek-v4-flash", timestamp: try XCTUnwrap(formatter.date(from: time)),
                inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 200_000,
                cacheWriteTokens: nil)])
        }
        let summaries = try ledger.summaries()
        for (id, _, expected) in cases {
            let row = try XCTUnwrap(summaries.first { $0.model == "\(id)/deepseek-v4-flash" })
            XCTAssertEqual(try XCTUnwrap(row.apiCostUSD), expected, accuracy: 0.000000001, id)
            XCTAssertEqual(row.unpricedRequests, 0, id)
        }
    }

    func testFable52StandardFastAndCacheLifetimesKeepFable51Rates() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("fable52-prices.sqlite"))
        let cases = [("claude-fable-5-2", 12.24), ("anthropic.claude-fable-5-2", 12.24),
                     ("claude-fable-5-2-fast", 24.48), ("claude-fable-5-1", 15.30)]
        for (model, _) in cases {
            _ = try ledger.ingest([ClientUsageEvent(client: .claudeDesktop, eventID: model, sessionID: "fixture", model: model,
                timestamp: Date(timeIntervalSince1970: 1_794_312_000), inputTokens: 1_000_000, outputTokens: 100_000,
                cacheReadTokens: 200_000, cacheWriteTokens: 300_000, cacheWrite5mTokens: 100_000, cacheWrite1hTokens: 200_000)])
        }
        let rows = try ledger.summaries()
        for (model, amount) in cases {
            let row = try XCTUnwrap(rows.first { $0.model == model })
            XCTAssertEqual(try XCTUnwrap(row.apiCostUSD), amount, accuracy: 0.000001, model)
            XCTAssertEqual(row.unpricedRequests, 0)
        }
    }

    func testPriceAggregateCacheInvalidatesWhenLedgerRevisionChanges() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        func request(_ id: String) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: 100,
                outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest([request("first")])
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, 0.0003)
        _ = try ledger.ingest([request("second")])
        XCTAssertEqual(try ledger.summaries().first?.apiCostUSD, 0.0006)
        XCTAssertEqual(try ledger.summaries().first?.requests, 2)
    }

    func testSinceSummariesIncludeExactCutoffAndPriceEachPeriodIndependently() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todayStart = Calendar.current.startOfDay(for: now)
        let sevenDayStart = Date(timeIntervalSince1970:
            floor((now.timeIntervalSince1970 - 7 * 24 * 60 * 60) / 300) * 300)
        func request(_ id: String, at timestamp: Date) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: timestamp, inputTokens: 100, outputTokens: 10,
                cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest([
            request("before-seven-days", at: sevenDayStart.addingTimeInterval(-1)),
            request("at-seven-day-cutoff", at: sevenDayStart),
            request("before-today", at: todayStart.addingTimeInterval(-1)),
            request("at-today-cutoff", at: todayStart),
            request("current", at: now)
        ])

        let allTime = try XCTUnwrap(ledger.summaries().first)
        let sevenDays = try XCTUnwrap(ledger.summaries(since: sevenDayStart).first)
        let today = try XCTUnwrap(ledger.summaries(since: todayStart).first)
        XCTAssertEqual(allTime.requests, 5)
        XCTAssertEqual(allTime.apiCostUSD, 0.0015)
        XCTAssertEqual(sevenDays.requests, 4, "The exact lower boundary is included")
        XCTAssertEqual(sevenDays.apiCostUSD, 0.0012)
        XCTAssertEqual(today.requests, 2, "Local midnight is included and the prior second is excluded")
        XCTAssertEqual(today.apiCostUSD, 0.0006)
        XCTAssertTrue(today.cacheReadComplete)
        XCTAssertEqual(today.unpricedRequests, 0)
    }

    func testSinceSummaryCacheSeparatesCutoffsAndInvalidatesOnRevision() throws {
        let ledger = try MultiClientUsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        func request(_ id: String, at offset: TimeInterval) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: anchor.addingTimeInterval(offset), inputTokens: 100, outputTokens: 10,
                cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try ledger.ingest([request("old", at: -1_000), request("new", at: -500)])
        let broadCutoff = anchor.addingTimeInterval(-1_000)
        let narrowCutoff = anchor.addingTimeInterval(-500)
        XCTAssertEqual(try ledger.summaries(since: broadCutoff).first?.requests, 2)
        XCTAssertEqual(try ledger.summaries(since: narrowCutoff).first?.requests, 1)
        XCTAssertEqual(try ledger.summaries(since: broadCutoff).first?.apiCostUSD, 0.0006)

        _ = try ledger.ingest([request("newer", at: -250)])
        XCTAssertEqual(try ledger.summaries(since: broadCutoff).first?.requests, 3)
        XCTAssertEqual(try ledger.summaries(since: narrowCutoff).first?.requests, 2)
        XCTAssertEqual(try ledger.summaries(since: narrowCutoff).first?.apiCostUSD, 0.0006)
    }

    func testScannerReturnsAllTimeTodayAndSevenDayModelSummaries() async throws {
        let database = root.appendingPathComponent("usage.sqlite")
        let ledger = try MultiClientUsageLedger(url: database)
        _ = try ledger.ingest([
            ClientUsageEvent(client: .claudeCode, eventID: "now", sessionID: "now", model: "gpt-6.1-sol",
                timestamp: Date(), inputTokens: 100, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)
        ])
        let scanner = MultiClientUsageScanner(databaseURL: database, home: root, environment: [:])
        let result = try await scanner.scan([])
        XCTAssertEqual(result.summaries.first?.requests, 1)
        XCTAssertEqual(result.todaySummaries.first?.requests, 1)
        XCTAssertEqual(result.sevenDaySummaries.first?.requests, 1)
        XCTAssertEqual(result.todaySummaries.first?.apiCostUSD, 0.0003)
        XCTAssertEqual(result.sevenDaySummaries.first?.apiCostUSD, 0.0003)
    }

    func testPricingRowsAndSummaryStayOnOneSQLiteReadSnapshot() throws {
        let url = root.appendingPathComponent("usage.sqlite")
        let reader = try MultiClientUsageLedger(url: url)
        let writer = try MultiClientUsageLedger(url: url)
        func pricedEvent(_ id: String) -> ClientUsageEvent {
            ClientUsageEvent(client: .claudeCode, eventID: id, sessionID: id, model: "gpt-6.1-sol",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), inputTokens: 100,
                outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)
        }
        _ = try writer.ingest([pricedEvent("first")])

        try reader.database.withConnection { connection in
            try connection.readTransaction { snapshot in
                let revisionBefore = try snapshot.readRows("SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first!
                let countBefore = try snapshot.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int(0) ?? 0 }.first!
                _ = try writer.ingest([pricedEvent("second")])
                let revisionAfter = try snapshot.readRows("SELECT COALESCE(MAX(revision),0) FROM client_usage_revisions") { $0.int64(0) ?? 0 }.first!
                let countAfter = try snapshot.readRows("SELECT COUNT(*) FROM client_usage_events") { $0.int(0) ?? 0 }.first!
                XCTAssertEqual(revisionAfter, revisionBefore)
                XCTAssertEqual(countAfter, countBefore)
            }
        }

        let summaries = try reader.summaries()
        XCTAssertEqual(summaries.first?.requests, 2)
        XCTAssertEqual(summaries.first?.apiCostUSD, 0.0006)
    }
    func testDeletionKeepsLedgerAndPartialTailIsNotSkipped() async throws {
        let path = root.appendingPathComponent("session.jsonl")
        let line = "{\"type\":\"assistant\",\"sessionId\":\"s\",\"timestamp\":\"2026-10-25T03:00:00Z\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}}"
        try Data(line.dropLast(4).utf8).write(to: path)
        var preference = MultiClientUsagePreference.defaults[0]; preference.enabled = true; preference.path = path.path
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("usage.sqlite"), home: root, environment: [:])
        let partial = try await scanner.scan([preference]); XCTAssertTrue(partial.summaries.isEmpty)
        try Data((line + "\n").utf8).write(to: path)
        let complete = try await scanner.scan([preference]); XCTAssertEqual(complete.summaries.first?.outputTokens, 20)
        try FileManager.default.removeItem(at: path)
        let deleted = try await scanner.scan([preference]); XCTAssertEqual(deleted.summaries.first?.outputTokens, 20)
    }
    func testPrefixRewriteInGrowingFileIsRescannedAndAppendDoesNotDoubleCount() async throws {
        let path = root.appendingPathComponent("session.jsonl")
        func line(_ id: String, _ output: Int) -> String {
            "{\"type\":\"assistant\",\"sessionId\":\"s\",\"timestamp\":\"2026-10-25T03:00:00Z\",\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":\(output)}}}\n"
        }
        var preference = MultiClientUsagePreference.defaults[0]; preference.enabled = true; preference.path = path.path
        let scanner = MultiClientUsageScanner(databaseURL: root.appendingPathComponent("usage.sqlite"), home: root, environment: [:])
        try Data(line("m1", 20).utf8).write(to: path)
        _ = try await scanner.scan([preference])
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line("m2", 30).utf8)); try handle.close()
        let appended = try await scanner.scan([preference])
        XCTAssertEqual(appended.summaries.first?.outputTokens, 50)
        let rewrite = try FileHandle(forWritingTo: path)
        try rewrite.write(contentsOf: Data((line("m1", 40) + line("m2", 30) + line("m3", 50)).utf8)); try rewrite.close()
        let rewritten = try await scanner.scan([preference])
        XCTAssertEqual(rewritten.summaries.first?.outputTokens, 120)
        XCTAssertEqual(rewritten.summaries.first?.requests, 3)
    }
    @MainActor func testPreferencesArePersistentAndDefaultsDoNotChangeCodexDisplay() {
        let name = "multi-client-prefs-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"))
        XCTAssertFalse(store.preferences.contains { $0.enabled || $0.showMenuBar || $0.showSidebar })
        var value = store.preferences[0]; value.color = "#123456"; value.showSidebar = true
        store.update(value)
        let next = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"))
        XCTAssertEqual(next.preferences[0].color, "#123456"); XCTAssertTrue(next.preferences[0].showSidebar)
        XCTAssertNil(defaults.object(forKey: "quotaSidebarEnabled"))
    }
}
