import XCTest
@testable import CodexTokenBar

final class ActivitySpeedStoreTests: XCTestCase {
    private let now = 1_800.0

    func testMinuteTrendSplitsIntervalsWithoutMixingClientsOrInventingIdle() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await store.addBatch(samples: [
            makeSample(id: "cross-minute", startedAt: 1750, endedAt: 1810, rate: 40, covered: 60),
            makeSample(id: "weighted", startedAt: 1810, endedAt: 1820, rate: 80, covered: 10),
            makeSample(id: "claude", startedAt: 1810, endedAt: 1820, rate: 200, covered: 10, client: "claudeCode")
        ], now: 2000)
        let result = try await store.query(now: 2000, filter: .init(client: "codex"), trendPointLimit: 1)
        let points = try XCTUnwrap(result.series.first).oneMinuteTrend
        XCTAssertEqual(points.map(\.bucketStart), [1740, 1800])
        XCTAssertEqual(points[0].value.outputRate, 40, accuracy: 0.001)
        XCTAssertEqual(points[1].value.outputRate, 60, accuracy: 0.001)
        XCTAssertEqual(points.reduce(0) { $0 + $1.value.weightedOutput }, 3200, accuracy: 0.001)
        XCTAssertEqual(result.series.count, 1)
    }

    func testDayHalfMinuteHistoryWeightsAcrossBoundariesClipsBoundsAndKeepsGaps() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let historyNow = 100_143.5
        let from = historyNow - 86_400
        let samples = [
            // Crosses the day boundary and three half-minute buckets; only the 80s inside count.
            makeSample(id: "window-edge", startedAt: from - 20, endedAt: from + 80, rate: 10),
            makeSample(id: "outside-day", startedAt: from - 100, endedAt: from - 90, rate: 99),
            makeSample(id: "old-day-point", startedAt: historyNow - 5_000, endedAt: historyNow - 4_990, rate: 6),
            makeSample(id: "slow-crossing", startedAt: 100_010, endedAt: 100_070, rate: 10),
            makeSample(id: "fast-crossing", startedAt: 100_030, endedAt: 100_070, rate: 20),
            // Stored with a later write horizon so the query proves it clips at now.
            makeSample(id: "future-end", startedAt: historyNow - 20, endedAt: historyNow + 20, rate: 4)
        ]
        _ = try await store.addBatch(samples: samples, now: historyNow + 20)

        let result = try await store.activityHistory(now: historyNow, windowSeconds: 86_400)
        let series = try XCTUnwrap(result.series.first)
        let points = Dictionary(uniqueKeysWithValues: series.halfMinuteTrend.map { ($0.bucketStart, $0.value) })
        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(points.count, 9)
        XCTAssertNil(series.rolling5m)
        XCTAssertTrue(series.fiveMinuteTrend.isEmpty)
        XCTAssertTrue(series.thirtyMinuteTrend.isEmpty)
        XCTAssertTrue(series.oneMinuteTrend.isEmpty)

        let edgeFirst = try XCTUnwrap(points[Int64(floor(from / 30) * 30)])
        let edgeMiddle = try XCTUnwrap(points[Int64(floor((from + 30) / 30) * 30)])
        let edgeLast = try XCTUnwrap(points[Int64(floor((from + 60) / 30) * 30)])
        XCTAssertEqual(edgeFirst.outputRate, 10, accuracy: 0.0001)
        XCTAssertEqual(edgeFirst.coveredSeconds, 26.5, accuracy: 0.0001)
        XCTAssertEqual(edgeFirst.weightedOutput, 265, accuracy: 0.0001)
        XCTAssertEqual(edgeMiddle.coveredSeconds, 30, accuracy: 0.0001)
        XCTAssertEqual(edgeMiddle.weightedOutput, 300, accuracy: 0.0001)
        XCTAssertEqual(edgeLast.outputRate, 10, accuracy: 0.0001)
        XCTAssertEqual(edgeLast.coveredSeconds, 23.5, accuracy: 0.0001)
        XCTAssertEqual(edgeLast.weightedOutput, 235, accuracy: 0.0001)

        let firstWeighted = try XCTUnwrap(points[99_990])
        let secondWeighted = try XCTUnwrap(points[100_020])
        let thirdWeighted = try XCTUnwrap(points[100_050])
        XCTAssertEqual(firstWeighted.outputRate, 10, accuracy: 0.0001)
        XCTAssertEqual(firstWeighted.coveredSeconds, 10, accuracy: 0.0001)
        XCTAssertEqual(secondWeighted.weightedOutput, 700, accuracy: 0.0001)
        XCTAssertEqual(secondWeighted.coveredSeconds, 50, accuracy: 0.0001)
        XCTAssertEqual(secondWeighted.outputRate, 14, accuracy: 0.0001)
        XCTAssertEqual(thirdWeighted.weightedOutput, 600, accuracy: 0.0001)
        XCTAssertEqual(thirdWeighted.coveredSeconds, 40, accuracy: 0.0001)
        XCTAssertEqual(thirdWeighted.outputRate, 15, accuracy: 0.0001)

        let clippedNow = try XCTUnwrap(points[100_140])
        XCTAssertEqual(clippedNow.weightedOutput, 14, accuracy: 0.0001)
        XCTAssertEqual(clippedNow.coveredSeconds, 3.5, accuracy: 0.0001)
        XCTAssertEqual(clippedNow.outputRate, 4, accuracy: 0.0001)
        XCTAssertTrue(points.keys.contains(Int64(floor((historyNow - 5_000) / 30) * 30)))
        XCTAssertFalse(points.values.contains { $0.outputRate == 99 })

        let thirtyMinute = try await store.activityHistory(now: historyNow, windowSeconds: 1_800)
        XCTAssertLessThanOrEqual(thirtyMinute.series.first?.halfMinuteTrend.count ?? 0, 61)
        XCTAssertFalse(thirtyMinute.series.first?.halfMinuteTrend.contains {
            $0.bucketStart == Int64(floor((historyNow - 5_000) / 30) * 30)
        } ?? false)
        let legacy = try await store.query(now: historyNow)
        let legacyMinutePoints = try XCTUnwrap(legacy.series.first?.oneMinuteTrend)
        XCTAssertLessThanOrEqual(legacyMinutePoints.count, 31)
        XCTAssertTrue(legacyMinutePoints.contains { $0.bucketStart == 100_140 })
        XCTAssertFalse(legacyMinutePoints.contains {
            $0.bucketStart == Int64(floor((historyNow - 5_000) / 60) * 60)
        })
    }

    func testActivityHistoryKeepsSourceModeClientEstimatorAndModelSeparate() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let base = makeSample(id: "base", startedAt: 110, endedAt: 112, rate: 10,
                              sourceIdentity: "source-a")
        let samples = [
            base,
            makeSample(id: "source", startedAt: 110, endedAt: 112, rate: 20, sourceIdentity: "source-b"),
            makeSample(id: "mode", startedAt: 110, endedAt: 112, rate: 30,
                       sourceIdentity: "source-a", displayMode: "agentSpeed"),
            makeSample(id: "estimator", startedAt: 110, endedAt: 112, rate: 40,
                       sourceIdentity: "source-a", estimator: "statusline"),
            makeSample(id: "estimator-version", startedAt: 110, endedAt: 112, rate: 45,
                       sourceIdentity: "source-a", estimatorVersion: "2"),
            makeSample(id: "client", startedAt: 110, endedAt: 112, rate: 50,
                       sourceIdentity: "source-a", client: "claude"),
            makeSample(id: "model", startedAt: 110, endedAt: 112, rate: 60,
                       sourceIdentity: "source-a", model: "model-b")
        ]
        _ = try await store.addBatch(samples: samples, now: 120)

        let all = try await store.activityHistory(now: 120, windowSeconds: 86_400)
        XCTAssertEqual(all.series.count, 7)
        XCTAssertTrue(all.series.allSatisfy { $0.rolling5m == nil && $0.oneMinuteTrend.isEmpty && $0.halfMinuteTrend.count == 1 })
        let filtered = try await store.activityHistory(
            now: 120,
            filter: ActivitySpeedFilter(sourceIdentity: "source-a", displayMode: "tokens",
                                        estimatorID: "agent-speed", client: "codex", model: "model-a"),
            windowSeconds: 86_400
        )
        XCTAssertEqual(filtered.series.count, 1)
        XCTAssertEqual(filtered.series.first?.dimensions.sourceIdentity, "source-a")
        XCTAssertEqual(
            try XCTUnwrap(filtered.series.first?.halfMinuteTrend.first).value.outputRate,
            10,
            accuracy: 0.0001
        )
    }

    func testActivityHistoryAcceptsOnlySupportedWindows() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await store.activityHistory(now: now, windowSeconds: 3_600)
            XCTFail("Unsupported activity history windows should be rejected")
        } catch ActivitySpeedStoreError.invalidWindow { }
    }

    func testActivityHistoryCanReturnExactly2881HalfMinuteBuckets() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let historyNow = 100_000.5
        let from = historyNow - 86_400
        let firstBucket = Int64(floor(from / 30) * 30)
        let samples = (0..<2_881).map { index -> ActivitySpeedSample in
            let bucket = Double(firstBucket + Int64(index) * 30)
            let startedAt = index == 0 ? from + 0.1 : bucket + 1
            return makeSample(
                id: "half-minute-\(index)", startedAt: startedAt, endedAt: startedAt + 0.2,
                rate: 6
            )
        }
        let inserted = try await store.addBatch(samples: samples, now: historyNow)
        XCTAssertEqual(inserted, 2_881)

        let result = try await store.activityHistory(now: historyNow, windowSeconds: 86_400)
        let series = try XCTUnwrap(result.series.first)
        XCTAssertEqual(series.halfMinuteTrend.count, 2_881)
        XCTAssertEqual(series.halfMinuteTrend.first?.bucketStart, firstBucket)
        XCTAssertEqual(series.halfMinuteTrend.last?.bucketStart, Int64(floor(historyNow / 30) * 30))
    }

    func testActivityHistoryEnforces64SeriesLimit() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let samples = (0..<65).map { index in
            makeSample(id: "series-\(index)", startedAt: 100, endedAt: 101, rate: 1,
                       model: "model-\(index)")
        }
        _ = try await store.addBatch(samples: samples, now: 110)
        do {
            _ = try await store.activityHistory(now: 110, windowSeconds: 86_400)
            XCTFail("Activity history must stop at the 64-series limit")
        } catch ActivitySpeedStoreError.tooManySeries { }
    }

    func testActivityHistoryDoesNotWriteOrPruneSharedTables() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = SQLiteDatabaseDriver(url: url)
        let expired = makeSample(id: "expired-detail", startedAt: 10, endedAt: 11, rate: 3, covered: 1)
        let dimensions: [SQLiteBinding] = [
            .text(expired.sourceIdentity), .text(expired.displayMode), .text(expired.estimatorID),
            .text(expired.estimatorVersion), .text(expired.metricKind), .text(expired.client),
            .text(expired.model)
        ]
        try database.execute(
            "INSERT INTO activity_speed_samples(source_identity,id,display_mode,estimator_id,estimator_version,metric_kind,client,model,started_at,ended_at,output_rate,covered_seconds,weighted_output) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            bindings: [.text(expired.sourceIdentity), .text(expired.id), .text(expired.displayMode),
                .text(expired.estimatorID), .text(expired.estimatorVersion), .text(expired.metricKind),
                .text(expired.client), .text(expired.model), .double(expired.startedAt),
                .double(expired.endedAt), .double(expired.outputRate), .double(expired.coveredSeconds),
                .double(3)]
        )
        try database.execute(
            "INSERT INTO activity_speed_sample_ids(source_identity,id,ended_at) VALUES(?,?,?)",
            bindings: [.text(expired.sourceIdentity), .text(expired.id), .double(expired.endedAt)]
        )
        try database.execute(
            "INSERT INTO activity_speed_buckets_5m(source_identity,display_mode,estimator_id,estimator_version,metric_kind,client,model,bucket_start,weighted_output,covered_seconds,sample_count) VALUES(?,?,?,?,?,?,?,0,3,1,1)",
            bindings: dimensions
        )

        let result = try await store.activityHistory(now: 5_000_000, windowSeconds: 86_400)
        XCTAssertTrue(result.series.isEmpty)
        for table in ["activity_speed_samples", "activity_speed_sample_ids", "activity_speed_buckets_5m"] {
            let count = try database.readRows("SELECT COUNT(*) FROM \(table)") { $0.int(0) ?? 0 }.first
            XCTAssertEqual(count, 1, "Activity history must not prune \(table)")
        }
    }

    func testDuplicateReplayAddsOneRawAndBucketContribution() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sample = makeSample(id: "one", startedAt: 1_700, endedAt: 1_720, rate: 10, covered: 20)

        let firstInsert = try await store.add(sample: sample, now: now)
        let replayInsert = try await store.add(sample: sample, now: now)
        XCTAssertTrue(firstInsert)
        XCTAssertFalse(replayInsert)
        let result = try await store.query(now: now)
        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(try XCTUnwrap(result.series[0].rolling5m).weightedOutput, 200, accuracy: 0.0001)

        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        let rawCount = try database.readRows("SELECT COUNT(*) FROM activity_speed_samples") { $0.int(0) ?? 0 }.first
        let bucketCount = try database.readRows("SELECT SUM(sample_count) FROM activity_speed_buckets_5m") { $0.int(0) ?? 0 }.first
        XCTAssertEqual(rawCount, 1)
        XCTAssertEqual(bucketCount, 1)
    }

    func testBatchIsAtomicAndReplaySafe() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let valid = makeSample(id: "batch-valid", startedAt: 1_700, endedAt: 1_701, rate: 4, covered: 1)
        let invalid = makeSample(id: "batch-invalid", startedAt: 1_700, endedAt: 1_701, rate: .nan, covered: 1)
        do {
            _ = try await store.addBatch(samples: [valid, invalid], now: now)
            XCTFail("A batch containing an invalid sample must be rejected")
        } catch ActivitySpeedStoreError.invalidSample { }

        let hugeRate = Double.greatestFiniteMagnitude / 1.5
        let overflowA = makeSample(id: "overflow-a", startedAt: 1_700, endedAt: 1_701, rate: hugeRate, covered: 1)
        let overflowB = makeSample(id: "overflow-b", startedAt: 1_700, endedAt: 1_701, rate: hugeRate, covered: 1)
        do {
            _ = try await store.addBatch(samples: [overflowA, overflowB], now: now)
            XCTFail("A later bucket overflow must roll back earlier batch writes")
        } catch ActivitySpeedStoreError.invalidSample { }

        let insertedCount = try await store.addBatch(samples: [valid, valid], now: now)
        let replayCount = try await store.addBatch(samples: [valid], now: now)
        XCTAssertEqual(insertedCount, 1)
        XCTAssertEqual(replayCount, 0)

        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        let rawCount = try database.readRows("SELECT COUNT(*) FROM activity_speed_samples") { $0.int(0) ?? 0 }.first
        let bucketCount = try database.readRows("SELECT SUM(sample_count) FROM activity_speed_buckets_5m") { $0.int(0) ?? 0 }.first
        XCTAssertEqual(rawCount, 1)
        XCTAssertEqual(bucketCount, 1)
    }

    func testDimensionsRemainSeparateAndMethodClientFiltersApply() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let samples = [
            makeSample(id: "codex", startedAt: 1_700, endedAt: 1_710, rate: 10, client: "codex"),
            makeSample(id: "claude", startedAt: 1_700, endedAt: 1_710, rate: 20, client: "claude", estimator: "statusline"),
            makeSample(id: "other-model", startedAt: 1_700, endedAt: 1_710, rate: 30, client: "claude", estimator: "statusline", model: "model-b")
        ]
        for sample in samples {
            let inserted = try await store.add(sample: sample, now: now)
            XCTAssertTrue(inserted)
        }

        let all = try await store.query(now: now)
        XCTAssertEqual(all.series.count, 3)
        let filtered = try await store.query(
            now: now,
            filter: ActivitySpeedFilter(displayMode: "tokens", estimatorID: "statusline", client: "claude", model: "model-a")
        )
        XCTAssertEqual(filtered.series.count, 1)
        XCTAssertEqual(try XCTUnwrap(filtered.series[0].rolling5m).outputRate, 20, accuracy: 0.0001)
    }

    func testSourceIdentitySeparatesDuplicateIDsAndFiltersQueries() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sourceA = makeSample(
            id: "same-id", startedAt: 1_700, endedAt: 1_710, rate: 10, sourceIdentity: "sha256-root-a"
        )
        let sourceB = makeSample(
            id: "same-id", startedAt: 1_700, endedAt: 1_710, rate: 20, sourceIdentity: "sha256-root-b"
        )
        let insertedA = try await store.add(sample: sourceA, now: now)
        let insertedB = try await store.add(sample: sourceB, now: now)
        XCTAssertTrue(insertedA)
        XCTAssertTrue(insertedB)

        let all = try await store.query(now: now)
        XCTAssertEqual(all.series.count, 2)
        XCTAssertEqual(Set(all.series.map(\.dimensions.sourceIdentity)), ["sha256-root-a", "sha256-root-b"])
        let onlyB = try await store.query(
            now: now, filter: ActivitySpeedFilter(sourceIdentity: "sha256-root-b")
        )
        XCTAssertEqual(onlyB.series.count, 1)
        XCTAssertEqual(try XCTUnwrap(onlyB.series.first?.rolling5m).outputRate, 20, accuracy: 0.0001)
    }

    func testV1MigrationCopiesLegacyRowsAndRetainsOriginalTables() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "activity-speed-v1-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("multi-client-usage.sqlite")
        let seed = SQLiteDatabaseDriver(url: url)
        let v1DDL = [
            "PRAGMA user_version=17",
            "CREATE TABLE client_usage_events(event_id TEXT PRIMARY KEY)",
            "INSERT INTO client_usage_events(event_id) VALUES('kept')",
            "CREATE TABLE activity_speed_meta(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL) WITHOUT ROWID",
            "INSERT INTO activity_speed_meta(key,value) VALUES('schema_version','1')",
            "CREATE TABLE activity_speed_samples(id TEXT PRIMARY KEY NOT NULL,display_mode TEXT NOT NULL,estimator_id TEXT NOT NULL,estimator_version TEXT NOT NULL,metric_kind TEXT NOT NULL,client TEXT NOT NULL,model TEXT NOT NULL,started_at REAL NOT NULL,ended_at REAL NOT NULL,output_rate REAL NOT NULL CHECK(output_rate>=0),covered_seconds REAL NOT NULL CHECK(covered_seconds>0),weighted_output REAL NOT NULL CHECK(weighted_output>=0),CHECK(ended_at>started_at)) WITHOUT ROWID",
            "CREATE INDEX activity_speed_samples_time ON activity_speed_samples(ended_at,started_at)",
            "CREATE INDEX activity_speed_samples_scope_time ON activity_speed_samples(display_mode,estimator_id,estimator_version,metric_kind,client,model,ended_at)",
            "INSERT INTO activity_speed_samples VALUES('same-id','tokens','agent-speed','1','output','codex','model-a',1700,1710,10,10,100)",
            "CREATE TABLE activity_speed_sample_ids(id TEXT PRIMARY KEY NOT NULL,ended_at REAL NOT NULL) WITHOUT ROWID",
            "CREATE INDEX activity_speed_sample_ids_time ON activity_speed_sample_ids(ended_at)",
            "INSERT INTO activity_speed_sample_ids VALUES('same-id',1710)",
            "CREATE TABLE activity_speed_buckets_5m(display_mode TEXT NOT NULL,estimator_id TEXT NOT NULL,estimator_version TEXT NOT NULL,metric_kind TEXT NOT NULL,client TEXT NOT NULL,model TEXT NOT NULL,bucket_start INTEGER NOT NULL,weighted_output REAL NOT NULL CHECK(weighted_output>=0),covered_seconds REAL NOT NULL CHECK(covered_seconds>0),sample_count INTEGER NOT NULL CHECK(sample_count>0),PRIMARY KEY(display_mode,estimator_id,estimator_version,metric_kind,client,model,bucket_start)) WITHOUT ROWID",
            "CREATE INDEX activity_speed_buckets_time ON activity_speed_buckets_5m(bucket_start)",
            "INSERT INTO activity_speed_buckets_5m VALUES('tokens','agent-speed','1','output','codex','model-a',1500,100,10,1)"
        ]
        for statement in v1DDL { try seed.execute(statement) }

        let store = try ActivitySpeedStore(url: url)
        let verify = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        let version = try verify.readRows("SELECT value FROM activity_speed_meta WHERE key='schema_version'") { $0.text(0) }.first
        let preserved = try verify.readRows("SELECT COUNT(*) FROM activity_speed_samples_v1_legacy") { $0.int(0) ?? 0 }.first
        let preservedIds = try verify.readRows("SELECT COUNT(*) FROM activity_speed_sample_ids_v1_legacy") { $0.int(0) ?? 0 }.first
        let preservedBuckets = try verify.readRows("SELECT COUNT(*) FROM activity_speed_buckets_5m_v1_legacy") { $0.int(0) ?? 0 }.first
        let copied = try verify.readRows("SELECT source_identity FROM activity_speed_samples WHERE id='same-id'") { $0.text(0) }.first
        let userVersion = try verify.readRows("PRAGMA user_version") { $0.int(0) ?? 0 }.first
        let ledger = try verify.readRows("SELECT event_id FROM client_usage_events") { $0.text(0) }.compactMap { $0 }
        let samplePlan = try verify.readRows(
            "EXPLAIN QUERY PLAN SELECT * FROM activity_speed_samples WHERE ended_at>? AND started_at<?",
            bindings: [.double(1_600), .double(1_800)]
        ) { $0.text(3) }.compactMap { $0 }.joined(separator: " ")
        let bucketPlan = try verify.readRows(
            "EXPLAIN QUERY PLAN SELECT * FROM activity_speed_buckets_5m WHERE bucket_start>=? AND bucket_start<=?",
            bindings: [.int64(1_200), .int64(1_800)]
        ) { $0.text(3) }.compactMap { $0 }.joined(separator: " ")
        XCTAssertEqual(version, "2")
        XCTAssertEqual(preserved, 1)
        XCTAssertEqual(preservedIds, 1)
        XCTAssertEqual(preservedBuckets, 1)
        XCTAssertEqual(copied, ActivitySpeedSample.unscopedSourceIdentity)
        XCTAssertEqual(userVersion, 17)
        XCTAssertEqual(ledger, ["kept"])
        XCTAssertTrue(samplePlan.contains("activity_speed_samples_v2_time"), samplePlan)
        XCTAssertTrue(bucketPlan.contains("activity_speed_buckets_v2_time"), bucketPlan)

        let sourceB = makeSample(
            id: "same-id", startedAt: 1_700, endedAt: 1_710, rate: 20, sourceIdentity: "sha256-root-b"
        )
        let insertedSourceB = try await store.add(sample: sourceB, now: now)
        XCTAssertTrue(insertedSourceB)
        let all = try await store.query(now: now)
        XCTAssertEqual(all.series.count, 2)
        let legacy = try await store.query(
            now: now, filter: ActivitySpeedFilter(sourceIdentity: ActivitySpeedSample.unscopedSourceIdentity)
        )
        XCTAssertEqual(try XCTUnwrap(legacy.series.first?.rolling5m).outputRate, 10, accuracy: 0.0001)
        XCTAssertEqual(legacy.series.first?.fiveMinuteTrend.count, 1)
        let duplicateLegacy = try await store.add(
            sample: makeSample(id: "same-id", startedAt: 1_700, endedAt: 1_710, rate: 10), now: now
        )
        XCTAssertFalse(duplicateLegacy)
        let newSource = try await store.query(
            now: now, filter: ActivitySpeedFilter(sourceIdentity: "sha256-root-b")
        )
        XCTAssertEqual(try XCTUnwrap(newSource.series.first?.rolling5m).outputRate, 20, accuracy: 0.0001)
    }

    func testWindowRatesUseCoveredTimeWeightsAndPreserveObservedZero() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let slowInserted = try await store.add(
            sample: makeSample(id: "slow", startedAt: 1_500, endedAt: 1_560, rate: 10, covered: 60), now: now
        )
        XCTAssertTrue(slowInserted)
        let fastInserted = try await store.add(
            sample: makeSample(id: "fast", startedAt: 1_620, endedAt: 1_800, rate: 20, covered: 180), now: now
        )
        XCTAssertTrue(fastInserted)
        let weightedResult = try await store.query(now: now)
        let weighted = try XCTUnwrap(weightedResult.series.first?.rolling5m)
        XCTAssertEqual(weighted.weightedOutput, 4_200, accuracy: 0.0001)
        XCTAssertEqual(weighted.coveredSeconds, 240, accuracy: 0.0001)
        XCTAssertEqual(weighted.outputRate, 17.5, accuracy: 0.0001)

        let zeroInserted = try await store.add(
            sample: makeSample(id: "observed-zero", startedAt: 1_790, endedAt: 1_800, rate: 0, covered: 10), now: now
        )
        XCTAssertTrue(zeroInserted)
        let zeroResult = try await store.query(now: now, filter: ActivitySpeedFilter(model: "model-a"))
        let zero = try XCTUnwrap(zeroResult.series.first?.rolling5m)
        XCTAssertEqual(zero.outputRate, 16.8, accuracy: 0.0001)
        let empty = try await store.query(now: now, filter: ActivitySpeedFilter(client: "missing"))
        XCTAssertTrue(empty.series.isEmpty)
    }

    func testTrendSinceLimitsBucketScanAndRejectsInvalidBounds() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let trendNow = 100_000.0
        let oldInserted = try await store.add(sample: makeSample(
            id: "old-trend", startedAt: 96_990, endedAt: 97_000, rate: 2
        ), now: trendNow)
        let recentInserted = try await store.add(sample: makeSample(
            id: "recent-trend", startedAt: 99_980, endedAt: 99_990, rate: 4
        ), now: trendNow)
        XCTAssertTrue(oldInserted)
        XCTAssertTrue(recentInserted)

        let allHistory = try await store.query(now: trendNow)
        XCTAssertEqual(allHistory.series.first?.fiveMinuteTrend.count, 2)
        XCTAssertEqual(allHistory.series.first?.thirtyMinuteTrend.count, 2)

        let trendSince = trendNow - 1_800
        let limited = try await store.query(
            now: trendNow, filter: ActivitySpeedFilter(trendSince: trendSince), trendPointLimit: 8
        )
        let series = try XCTUnwrap(limited.series.first)
        let earliest = Int64(floor(trendSince / 300)) * 300
        XCTAssertEqual(series.fiveMinuteTrend.count, 1)
        XCTAssertEqual(series.thirtyMinuteTrend.count, 1)
        XCTAssertTrue(series.fiveMinuteTrend.allSatisfy { $0.bucketStart >= earliest })
        XCTAssertTrue(series.thirtyMinuteTrend.allSatisfy { $0.bucketStart >= earliest })

        for invalidSince in [-1.0, .nan, trendNow + 1] {
            do {
                _ = try await store.query(
                    now: trendNow, filter: ActivitySpeedFilter(trendSince: invalidSince)
                )
                XCTFail("Invalid trend bounds should be rejected")
            } catch ActivitySpeedStoreError.invalidFilter { }
        }
    }

    func testRawSevenDayAndRollupThirtyDayRetention() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let base = 40 * 86_400.0
        let olderThanRaw = makeSample(id: "ten-days", startedAt: base - 10 * 86_400 - 10,
                                      endedAt: base - 10 * 86_400, rate: 5, covered: 10)
        let nearRollupEdge = makeSample(id: "twenty-nine-days", startedAt: base - 29 * 86_400 - 10,
                                        endedAt: base - 29 * 86_400, rate: 7, covered: 10)
        let oldDetailInserted = try await store.add(sample: olderThanRaw, now: base)
        let oldRollupInserted = try await store.add(sample: nearRollupEdge, now: base)
        XCTAssertTrue(oldDetailInserted)
        XCTAssertTrue(oldRollupInserted)
        let expiredInserted = try await store.add(
            sample: makeSample(id: "expired", startedAt: base - 31 * 86_400 - 10,
                               endedAt: base - 31 * 86_400, rate: 7, covered: 10), now: base
        )
        XCTAssertFalse(expiredInserted)

        let database = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        let raw = try database.readRows("SELECT COUNT(*) FROM activity_speed_samples") { $0.int(0) ?? 0 }.first
        let rollups = try database.readRows("SELECT COUNT(*) FROM activity_speed_buckets_5m") { $0.int(0) ?? 0 }.first
        XCTAssertEqual(raw, 0)
        XCTAssertEqual(rollups, 2)

        // Replaying a sample after its details expire remains a no-op while its rollup is retained.
        let replayAfterDetailExpiry = try await store.add(sample: olderThanRaw, now: base)
        XCTAssertFalse(replayAfterDetailExpiry)
        _ = try await store.query(now: base + 8 * 86_400)
        let afterSevenDays = try database.readRows("SELECT COUNT(*) FROM activity_speed_samples") { $0.int(0) ?? 0 }.first
        let afterThirtyDays = try database.readRows("SELECT COUNT(*) FROM activity_speed_buckets_5m") { $0.int(0) ?? 0 }.first
        XCTAssertEqual(afterSevenDays, 0)
        XCTAssertEqual(afterThirtyDays, 1)
        _ = try await store.query(now: base + 40 * 86_400)
        let expiredRollups = try database.readRows("SELECT COUNT(*) FROM activity_speed_buckets_5m") { $0.int(0) ?? 0 }.first
        XCTAssertEqual(expiredRollups, 0)
    }

    func testInvalidRatesAndCoverageAreRejectedAndUnknownIsNotZero() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for rate in [-1.0, .infinity, .nan] {
            do {
                _ = try await store.add(sample: makeSample(id: "bad-\(rate)", startedAt: 1_700,
                    endedAt: 1_710, rate: rate, covered: 10), now: now)
                XCTFail("Invalid output rate should be rejected")
            } catch ActivitySpeedStoreError.invalidSample { }
        }
        do {
            _ = try await store.add(sample: makeSample(id: "bad-coverage", startedAt: 1_700,
                endedAt: 1_710, rate: 1, covered: 11), now: now)
            XCTFail("Coverage longer than the interval should be rejected")
        } catch ActivitySpeedStoreError.invalidSample { }
        let result = try await store.query(now: now)
        XCTAssertTrue(result.series.isEmpty)
    }

    func testInputSpanAndQuerySeriesHaveHardLimits() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await store.add(
                sample: makeSample(id: "overlong", startedAt: 100, endedAt: 3_701, rate: 1), now: 4_000
            )
            XCTFail("Samples longer than one hour should be rejected")
        } catch ActivitySpeedStoreError.invalidSample { }

        let bounded = makeSample(id: "batch-limit", startedAt: 1_700, endedAt: 1_710, rate: 1)
        do {
            _ = try await store.addBatch(samples: Array(repeating: bounded, count: 4_097), now: now)
            XCTFail("Batches larger than the hard sample limit should be rejected")
        } catch ActivitySpeedStoreError.tooManySamples { }

        for index in 0..<65 {
            let inserted = try await store.add(sample: makeSample(
                id: "bounded-\(index)", startedAt: 1_700, endedAt: 1_710, rate: 1,
                model: "model-\(index)"
            ), now: now)
            XCTAssertTrue(inserted)
        }
        do {
            _ = try await store.query(now: now)
            XCTFail("Queries must stop at the bounded series limit")
        } catch ActivitySpeedStoreError.tooManySeries { }
    }

    func testSharedSchemaPreservesUserVersionAndClientUsageLedger() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "activity-speed-shared-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("multi-client-usage.sqlite")
        let seed = SQLiteDatabaseDriver(url: url)
        try seed.execute("PRAGMA user_version=17")
        try seed.execute("CREATE TABLE client_usage_events(event_id TEXT PRIMARY KEY)")
        try seed.execute("INSERT INTO client_usage_events(event_id) VALUES('kept')")

        let store = try ActivitySpeedStore(url: url)
        let inserted = try await store.add(
            sample: makeSample(id: "new-speed", startedAt: 1_700, endedAt: 1_710, rate: 3), now: now
        )
        XCTAssertTrue(inserted)
        let verify = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
        let userVersion = try verify.readRows("PRAGMA user_version") { $0.int(0) ?? 0 }.first
        let ledgerRows = try verify.readRows("SELECT event_id FROM client_usage_events") { $0.text(0) }.compactMap { $0 }
        XCTAssertEqual(userVersion, 17)
        XCTAssertEqual(ledgerRows, ["kept"])
    }

    private func makeStore() throws -> (ActivitySpeedStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("activity-speed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try ActivitySpeedStore(url: folder.appendingPathComponent("multi-client-usage.sqlite")),
                folder.appendingPathComponent("multi-client-usage.sqlite"))
    }

    private func makeSample(
        id: String,
        startedAt: Double,
        endedAt: Double,
        rate: Double,
        covered: Double? = nil,
        client: String = "codex",
        displayMode: String = "tokens",
        estimator: String = "agent-speed",
        estimatorVersion: String = "1",
        model: String = "model-a",
        sourceIdentity: String = ActivitySpeedSample.unscopedSourceIdentity
    ) -> ActivitySpeedSample {
        ActivitySpeedSample(
            id: id, displayMode: displayMode, estimatorID: estimator, estimatorVersion: estimatorVersion,
            metricKind: "output", client: client, model: model,
            startedAt: startedAt, endedAt: endedAt, outputRate: rate,
            coveredSeconds: covered ?? endedAt - startedAt,
            sourceIdentity: sourceIdentity
        )
    }
}
