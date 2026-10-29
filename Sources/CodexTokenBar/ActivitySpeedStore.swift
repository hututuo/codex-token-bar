import Foundation

struct ActivitySpeedSample: Equatable, Sendable {
    static let unscopedSourceIdentity = "legacy/unscoped"

    let id, sourceIdentity, displayMode, estimatorID, estimatorVersion: String
    let metricKind, client, model: String
    let startedAt, endedAt, outputRate, coveredSeconds: Double

    init(
        id: String,
        displayMode: String,
        estimatorID: String,
        estimatorVersion: String,
        metricKind: String,
        client: String,
        model: String,
        startedAt: Double,
        endedAt: Double,
        outputRate: Double,
        coveredSeconds: Double,
        sourceIdentity: String = ActivitySpeedSample.unscopedSourceIdentity
    ) {
        self.id = id; self.sourceIdentity = sourceIdentity; self.displayMode = displayMode
        self.estimatorID = estimatorID; self.estimatorVersion = estimatorVersion
        self.metricKind = metricKind; self.client = client; self.model = model
        self.startedAt = startedAt; self.endedAt = endedAt
        self.outputRate = outputRate; self.coveredSeconds = coveredSeconds
    }
}

struct ActivitySpeedFilter: Sendable {
    var sourceIdentity: String? = nil, displayMode: String? = nil
    var estimatorID: String? = nil, estimatorVersion: String? = nil
    var metricKind: String? = nil, client: String? = nil, model: String? = nil
    var trendSince: Double? = nil
}

struct ActivitySpeedDimensions: Equatable, Hashable, Sendable {
    let sourceIdentity, displayMode, estimatorID, estimatorVersion, metricKind, client, model: String
}

struct ActivitySpeedAggregate: Equatable, Sendable {
    /// Sum of output rate multiplied by covered seconds (output-token equivalent).
    let weightedOutput, coveredSeconds: Double
    var outputRate: Double { weightedOutput / coveredSeconds }
}

struct ActivitySpeedTrendPoint: Equatable, Identifiable, Sendable {
    let bucketStart: Int64, value: ActivitySpeedAggregate
    var id: Int64 { bucketStart }
}

struct ActivitySpeedSeries: Equatable, Identifiable, Sendable {
    let dimensions: ActivitySpeedDimensions
    var id: String {
        [dimensions.sourceIdentity, dimensions.displayMode, dimensions.estimatorID, dimensions.estimatorVersion,
         dimensions.metricKind, dimensions.client, dimensions.model].joined(separator: "\u{1f}")
    }
    var rolling5m, rolling15m, rolling30m: ActivitySpeedAggregate?
    var fiveMinuteTrend: [ActivitySpeedTrendPoint] = [], thirtyMinuteTrend: [ActivitySpeedTrendPoint] = []
    var oneMinuteTrend: [ActivitySpeedTrendPoint] = []
    var halfMinuteTrend: [ActivitySpeedTrendPoint] = []
}

struct ActivitySpeedQueryResult: Equatable, Sendable {
    let series: [ActivitySpeedSeries]
}

/// Local numeric speed history in the caller-selected shared usage database.
/// Raw samples live for seven days; five-minute aggregates and replay IDs live for 30.
actor ActivitySpeedStore {
    private static let schemaVersion = "2"
    private static let bucketSeconds: Int64 = 300
    private static let minuteSeconds: Int64 = 60
    private static let halfMinuteSeconds: Int64 = 30
    private static let rawRetention: Double = 7 * 86_400, rollupRetention: Double = 30 * 86_400
    private static let maxSampleSpan: Double = 3_600
    private static let maxTextLength = 256
    private static let maxSeries = 64
    private static let maxTrendPointLimit = 512
    private static let maxBatchSize = 4_096

    private let database: SQLiteDatabaseDriver

    private static func migrateV1(connection: SQLiteDatabaseConnection, schema: String) throws {
        let tables = ["activity_speed_samples", "activity_speed_sample_ids", "activity_speed_buckets_5m"]
        for table in tables { try connection.execute("ALTER TABLE \(table) RENAME TO \(table)_v1_legacy") }
        try connection.execute(schema)
        let copies = [
            ("activity_speed_sample_ids", "id, ended_at"),
            ("activity_speed_samples", "id, display_mode, estimator_id, estimator_version, metric_kind, client, model, started_at, ended_at, output_rate, covered_seconds, weighted_output"),
            ("activity_speed_buckets_5m", "display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start, weighted_output, covered_seconds, sample_count")
        ]
        for (table, columns) in copies {
            try connection.execute(
                "INSERT INTO \(table)(source_identity, \(columns)) SELECT ?, \(columns) FROM \(table)_v1_legacy",
                bindings: [.text(ActivitySpeedSample.unscopedSourceIdentity)]
            )
        }
        guard try connection.executeChangedRows("UPDATE activity_speed_meta SET value='2' WHERE key='schema_version' AND value='1'") == 1 else {
            throw ActivitySpeedStoreError.unsupportedSchema
        }
    }

    init(url: URL) throws {
        database = SQLiteDatabaseDriver(url: url, enableWAL: true)
        guard let schemaURL = AppResources.url(forResource: "activity-speed-schema", withExtension: "sql"),
              let schema = try? String(contentsOf: schemaURL, encoding: .utf8) else {
            throw ActivitySpeedStoreError.schemaUnavailable
        }
        try database.transaction { connection in
            let metadata = try connection.readRows(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='activity_speed_meta'"
            ) { $0.int(0) ?? 0 }
            if metadata.isEmpty {
                try connection.execute(schema)
            } else {
                let versions = try connection.readRows(
                    "SELECT value FROM activity_speed_meta WHERE key='schema_version'"
                ) { $0.text(0) }
                switch versions.first {
                case "1": try Self.migrateV1(connection: connection, schema: schema)
                case Self.schemaVersion: try connection.execute(schema)
                default: throw ActivitySpeedStoreError.unsupportedSchema
                }
            }
            let migratedVersion = try connection.readRows(
                "SELECT value FROM activity_speed_meta WHERE key='schema_version'"
            ) { $0.text(0) }
            guard migratedVersion.first == Self.schemaVersion else {
                throw ActivitySpeedStoreError.unsupportedSchema
            }
        }
    }

    /// Adds a sample once, updating its retained raw row and five-minute rollups atomically.
    /// Returns false for a duplicate ID or a sample already outside the 30-day horizon.
    @discardableResult
    func add(sample: ActivitySpeedSample, now: Double) throws -> Bool {
        try addBatch(samples: [sample], now: now) == 1
    }

    /// Inserts a bounded batch with one prune pass and one transaction. Any invalid sample
    /// or numeric overflow rolls back every sample in the batch.
    @discardableResult
    func addBatch(samples: [ActivitySpeedSample], now: Double) throws -> Int {
        guard now.isFinite, now >= 0, now < Double(Int64.max) - Self.rollupRetention else {
            throw ActivitySpeedStoreError.invalidNow
        }
        guard samples.count <= Self.maxBatchSize else { throw ActivitySpeedStoreError.tooManySamples }
        guard !samples.isEmpty else { return 0 }
        for sample in samples { try Self.validate(sample, now: now) }
        let rawCutoff = now - Self.rawRetention
        let rollupCutoff = now - Self.rollupRetention

        return try database.transaction { connection in
            try Self.prune(now: now, connection: connection)
            var inserted = 0
            for sample in samples where sample.endedAt >= rollupCutoff {
                if try Self.insert(
                    sample: sample, rawCutoff: rawCutoff, rollupCutoff: rollupCutoff,
                    connection: connection
                ) {
                    inserted += 1
                }
            }
            return inserted
        }
    }

    private static func insert(
        sample: ActivitySpeedSample,
        rawCutoff: Double,
        rollupCutoff: Double,
        connection: SQLiteDatabaseConnection
    ) throws -> Bool {
        let inserted = try connection.executeChangedRows(
            "INSERT OR IGNORE INTO activity_speed_sample_ids(source_identity, id, ended_at) VALUES(?, ?, ?)",
            bindings: [.text(sample.sourceIdentity), .text(sample.id), .double(sample.endedAt)]
        )
        guard inserted == 1 else { return false }

        let dimensions = dimensionBindings(sample)
        if sample.endedAt >= rawCutoff {
            try connection.execute(
                """
                INSERT INTO activity_speed_samples(
                    source_identity, id, display_mode, estimator_id, estimator_version, metric_kind,
                    client, model, started_at, ended_at, output_rate, covered_seconds, weighted_output
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [.text(sample.sourceIdentity), .text(sample.id)] + dimensions.dropFirst() + [
                    .double(sample.startedAt), .double(sample.endedAt), .double(sample.outputRate),
                    .double(sample.coveredSeconds), .double(sample.outputRate * sample.coveredSeconds)
                ]
            )
        }

        var cursor = max(sample.startedAt, rollupCutoff)
        while cursor < sample.endedAt {
            let bucket = bucketStart(cursor)
            let stop = min(sample.endedAt, Double(bucket + bucketSeconds))
            let fraction = (stop - cursor) / (sample.endedAt - sample.startedAt)
            let weighted = sample.outputRate * sample.coveredSeconds * fraction
            let covered = sample.coveredSeconds * fraction
            guard weighted.isFinite, covered.isFinite, covered > 0 else {
                throw ActivitySpeedStoreError.invalidSample
            }
            let existing = try connection.readRows(
                """
                SELECT weighted_output, covered_seconds FROM activity_speed_buckets_5m
                WHERE source_identity=? AND display_mode=? AND estimator_id=? AND estimator_version=? AND metric_kind=?
                  AND client=? AND model=? AND bucket_start=?
                """,
                bindings: dimensions + [.int64(bucket)]
            ) { row -> (Double, Double) in
                guard let weighted = row.double(0), let seconds = row.double(1) else {
                    throw ActivitySpeedStoreError.invalidStoredAggregate
                }
                return (weighted, seconds)
            }.first ?? (0, 0)
            guard (existing.0 + weighted).isFinite, (existing.1 + covered).isFinite else {
                throw ActivitySpeedStoreError.invalidSample
            }
            try connection.execute(
                """
                INSERT INTO activity_speed_buckets_5m(
                    source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model,
                    bucket_start, weighted_output, covered_seconds, sample_count
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start)
                DO UPDATE SET weighted_output=weighted_output+excluded.weighted_output,
                              covered_seconds=covered_seconds+excluded.covered_seconds,
                              sample_count=sample_count+1
                """,
                bindings: dimensions + [.int64(bucket), .double(weighted), .double(covered)]
            )
            cursor = stop
        }
        return true
    }

    /// Reads 5/15/30-minute weighted averages plus sparse 5- and 30-minute trend buckets.
    /// At most 64 dimension series and 512 points per trend are returned.
    func query(
        now: Double,
        filter: ActivitySpeedFilter = ActivitySpeedFilter(),
        trendPointLimit: Int = 288
    ) throws -> ActivitySpeedQueryResult {
        guard now.isFinite, now >= 0, now < Double(Int64.max) - Self.rollupRetention else {
            throw ActivitySpeedStoreError.invalidNow
        }
        if let trendSince = filter.trendSince,
           !trendSince.isFinite || trendSince < 0 || trendSince > now {
            throw ActivitySpeedStoreError.invalidFilter
        }
        let pointLimit = max(1, min(trendPointLimit, Self.maxTrendPointLimit))
        try database.transaction { connection in try Self.prune(now: now, connection: connection) }
        var values: [ActivitySpeedDimensions: ActivitySpeedSeries] = [:]
        for minutes in [5, 15, 30] {
            let window = Double(minutes * 60)
            let aggregates = try readRolling(now: now, window: window, filter: filter)
            for (dimensions, aggregate) in aggregates {
                var series = values[dimensions] ?? ActivitySpeedSeries(dimensions: dimensions)
                switch minutes {
                case 5: series.rolling5m = aggregate
                case 15: series.rolling15m = aggregate
                default: series.rolling30m = aggregate
                }
                values[dimensions] = series
            }
        }
        let five = try readTrend(now: now, minutes: 5, filter: filter, pointLimit: pointLimit)
        let thirty = try readTrend(now: now, minutes: 30, filter: filter, pointLimit: pointLimit)
        for (dimensions, points) in five {
            var series = values[dimensions] ?? ActivitySpeedSeries(dimensions: dimensions)
            series.fiveMinuteTrend = points
            values[dimensions] = series
        }
        for (dimensions, points) in thirty {
            var series = values[dimensions] ?? ActivitySpeedSeries(dimensions: dimensions)
            series.thirtyMinuteTrend = points
            values[dimensions] = series
        }
        for (dimensions, points) in try readSampleTrend(
            now: now, filter: filter, windowSeconds: 1_800, bucketSeconds: Int(Self.minuteSeconds)
        ) {
            var series = values[dimensions] ?? ActivitySpeedSeries(dimensions: dimensions)
            series.oneMinuteTrend = points
            values[dimensions] = series
        }
        guard values.count <= Self.maxSeries else { throw ActivitySpeedStoreError.tooManySeries }
        return ActivitySpeedQueryResult(series: values.values.sorted { $0.id < $1.id })
    }

    /// Reads only retained raw samples and returns sparse, measured 30-second points.
    /// Supported windows are 30 minutes and 24 hours; this method does not read rollups
    /// or mutate retention state.
    func activityHistory(
        now: Double,
        filter: ActivitySpeedFilter = ActivitySpeedFilter(),
        windowSeconds: Int
    ) throws -> ActivitySpeedQueryResult {
        guard now.isFinite, now >= 0, now < Double(Int64.max) - Self.rollupRetention else {
            throw ActivitySpeedStoreError.invalidNow
        }
        guard windowSeconds == 1_800 || windowSeconds == 86_400 else {
            throw ActivitySpeedStoreError.invalidWindow
        }
        if let trendSince = filter.trendSince,
           !trendSince.isFinite || trendSince < 0 || trendSince > now {
            throw ActivitySpeedStoreError.invalidFilter
        }

        let points = try readSampleTrend(
            now: now, filter: filter, windowSeconds: windowSeconds,
            bucketSeconds: Int(Self.halfMinuteSeconds)
        )
        let series = points.map { dimensions, points in
            var value = ActivitySpeedSeries(dimensions: dimensions)
            value.halfMinuteTrend = points
            return value
        }
        return ActivitySpeedQueryResult(series: series.sorted { $0.id < $1.id })
    }

    private func readRolling(
        now: Double,
        window: Double,
        filter: ActivitySpeedFilter
    ) throws -> [ActivitySpeedDimensions: ActivitySpeedAggregate] {
        let from = now - window
        let (predicate, filterBindings) = Self.filterSQL(filter)
        let rows = try database.readRows(
            """
            SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model,
                   SUM(weighted_output * ((MIN(ended_at, ?) - MAX(started_at, ?)) / (ended_at - started_at))),
                   SUM(covered_seconds * ((MIN(ended_at, ?) - MAX(started_at, ?)) / (ended_at - started_at)))
            FROM activity_speed_samples
            WHERE ended_at > ? AND started_at < ? \(predicate)
            GROUP BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model
            HAVING SUM(covered_seconds * ((MIN(ended_at, ?) - MAX(started_at, ?)) / (ended_at - started_at))) > 0
            ORDER BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model
            LIMIT ?
            """,
            bindings: [.double(now), .double(from), .double(now), .double(from), .double(from), .double(now)]
                + filterBindings + [.double(now), .double(from), .int(Self.maxSeries + 1)]
        ) { row in
            let dimensions = try Self.dimensions(row)
            guard let weighted = row.double(7), let covered = row.double(8),
                  weighted.isFinite, weighted >= 0, covered.isFinite, covered > 0 else {
                throw ActivitySpeedStoreError.invalidStoredAggregate
            }
            return (dimensions, ActivitySpeedAggregate(weightedOutput: weighted, coveredSeconds: covered))
        }
        guard rows.count <= Self.maxSeries else { throw ActivitySpeedStoreError.tooManySeries }
        return Dictionary(rows, uniquingKeysWith: { _, later in later })
    }

    /// Splits only each overlapping retained sample at its minute boundaries.
    /// The recursive expansion is proportional to the covered sample intervals, not
    /// the full window multiplied by the number of samples. Gaps stay absent.
    private func readSampleTrend(
        now: Double,
        filter: ActivitySpeedFilter,
        windowSeconds: Int,
        bucketSeconds: Int
    ) throws -> [ActivitySpeedDimensions: [ActivitySpeedTrendPoint]] {
        let from = max(0, now - Double(windowSeconds))
        let pointLimit = windowSeconds / bucketSeconds + 1
        let (predicate, filterBindings) = Self.filterSQL(filter)
        let rows = try database.readRows("""
            WITH RECURSIVE bounds(from_time, now_time) AS (SELECT ?, ?),
            bucket_samples(
                source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model,
                started_at, ended_at, weighted_output, covered_seconds, clipped_start, clipped_end, bucket_start
            ) AS (
                SELECT samples.source_identity, samples.display_mode, samples.estimator_id, samples.estimator_version,
                       samples.metric_kind, samples.client, samples.model, samples.started_at, samples.ended_at,
                       samples.weighted_output, samples.covered_seconds,
                       MAX(samples.started_at, bounds.from_time), MIN(samples.ended_at, bounds.now_time),
                       CAST(MAX(samples.started_at, bounds.from_time) / \(bucketSeconds) AS INTEGER) * \(bucketSeconds)
                FROM activity_speed_samples AS samples CROSS JOIN bounds
                WHERE samples.ended_at > bounds.from_time AND samples.started_at < bounds.now_time \(predicate)
                UNION ALL
                SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model,
                       started_at, ended_at, weighted_output, covered_seconds, clipped_start, clipped_end,
                       bucket_start + \(bucketSeconds)
                FROM bucket_samples
                WHERE bucket_start + \(bucketSeconds) < clipped_end
            )
            SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model,
                   bucket_start,
                   SUM(weighted_output * ((MIN(clipped_end, bucket_start + \(bucketSeconds)) - MAX(clipped_start, bucket_start)) / (ended_at - started_at))),
                   SUM(covered_seconds * ((MIN(clipped_end, bucket_start + \(bucketSeconds)) - MAX(clipped_start, bucket_start)) / (ended_at - started_at)))
            FROM bucket_samples
            GROUP BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start
            HAVING SUM(covered_seconds * ((MIN(clipped_end, bucket_start + \(bucketSeconds)) - MAX(clipped_start, bucket_start)) / (ended_at - started_at))) > 0
            ORDER BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start
            LIMIT ?
            """, bindings: [.double(from), .double(now)] + filterBindings
                + [.int(Self.maxSeries * pointLimit + 1)]) { row in
            let dimensions = try Self.dimensions(row)
            guard let bucket = row.int64(7), let weighted = row.double(8), let covered = row.double(9),
                  weighted.isFinite, weighted >= 0, covered.isFinite, covered > 0 else {
                throw ActivitySpeedStoreError.invalidStoredAggregate
            }
            return (dimensions, ActivitySpeedTrendPoint(bucketStart: bucket,
                value: ActivitySpeedAggregate(weightedOutput: weighted, coveredSeconds: covered)))
        }
        guard rows.count <= Self.maxSeries * pointLimit else { throw ActivitySpeedStoreError.tooManySeries }
        var result: [ActivitySpeedDimensions: [ActivitySpeedTrendPoint]] = [:]
        for (dimensions, point) in rows { result[dimensions, default: []].append(point) }
        guard result.count <= Self.maxSeries,
              result.values.allSatisfy({ $0.count <= pointLimit }) else {
            throw ActivitySpeedStoreError.tooManySeries
        }
        return result
    }

    private func readTrend(
        now: Double,
        minutes: Int,
        filter: ActivitySpeedFilter,
        pointLimit: Int
    ) throws -> [ActivitySpeedDimensions: [ActivitySpeedTrendPoint]] {
        let retentionCutoff = Self.bucketStart(now - Self.rollupRetention)
        let cutoff = filter.trendSince.map { max(retentionCutoff, Self.bucketStart($0)) } ?? retentionCutoff
        let lastBucket = Self.bucketStart(now)
        let (predicate, filterBindings) = Self.filterSQL(filter)
        let groupedBucket = minutes == 5 ? "bucket_start" : "(bucket_start / 1800) * 1800"
        let rows = try database.readRows(
            """
            WITH grouped AS (
                SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model,
                       \(groupedBucket) AS bucket_start, SUM(weighted_output) AS weighted_output,
                       SUM(covered_seconds) AS covered_seconds FROM activity_speed_buckets_5m
                WHERE bucket_start >= ? AND bucket_start <= ? \(predicate)
                GROUP BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, \(groupedBucket)
            ), ranked AS (
                SELECT *, ROW_NUMBER() OVER (PARTITION BY source_identity, display_mode, estimator_id,
                    estimator_version, metric_kind, client, model ORDER BY bucket_start DESC) AS point_rank FROM grouped
            )
            SELECT source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model,
                   bucket_start, weighted_output, covered_seconds FROM ranked WHERE point_rank <= ?
            ORDER BY source_identity, display_mode, estimator_id, estimator_version, metric_kind, client, model, bucket_start LIMIT ?
            """,
            bindings: [.int64(cutoff), .int64(lastBucket)] + filterBindings
                + [.int(pointLimit), .int(Self.maxSeries * pointLimit + 1)]
        ) { row in
            let dimensions = try Self.dimensions(row)
            guard let bucket = row.int64(7), let weighted = row.double(8), let covered = row.double(9),
                  weighted.isFinite, weighted >= 0, covered.isFinite, covered > 0 else {
                throw ActivitySpeedStoreError.invalidStoredAggregate
            }
            return (dimensions, ActivitySpeedTrendPoint(
                bucketStart: bucket,
                value: ActivitySpeedAggregate(weightedOutput: weighted, coveredSeconds: covered)
            ))
        }
        guard rows.count <= Self.maxSeries * pointLimit else { throw ActivitySpeedStoreError.tooManySeries }
        var result: [ActivitySpeedDimensions: [ActivitySpeedTrendPoint]] = [:]
        for (dimensions, point) in rows { result[dimensions, default: []].append(point) }
        guard result.count <= Self.maxSeries else { throw ActivitySpeedStoreError.tooManySeries }
        return result
    }

    private static func validate(_ sample: ActivitySpeedSample, now: Double) throws {
        guard now.isFinite, now >= 0, now < Double(Int64.max) - rollupRetention else {
            throw ActivitySpeedStoreError.invalidNow
        }
        let labels = [sample.sourceIdentity, sample.id, sample.displayMode, sample.estimatorID, sample.estimatorVersion,
                      sample.metricKind, sample.client, sample.model]
        let span = sample.endedAt - sample.startedAt
        let weighted = sample.outputRate * sample.coveredSeconds
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maxTextLength }),
              sample.startedAt.isFinite, sample.endedAt.isFinite,
              sample.startedAt >= 0, sample.endedAt <= now, sample.endedAt < Double(Int64.max),
              span.isFinite, span > 0, span <= maxSampleSpan,
              sample.outputRate.isFinite, sample.outputRate >= 0,
              sample.coveredSeconds.isFinite, sample.coveredSeconds > 0,
              sample.coveredSeconds <= span, weighted.isFinite, weighted >= 0 else {
            throw ActivitySpeedStoreError.invalidSample
        }
    }

    private static func prune(now: Double, connection: SQLiteDatabaseConnection) throws {
        try connection.execute(
            "DELETE FROM activity_speed_samples WHERE ended_at < ?",
            bindings: [.double(now - rawRetention)]
        )
        try connection.execute(
            "DELETE FROM activity_speed_sample_ids WHERE ended_at < ?",
            bindings: [.double(now - rollupRetention)]
        )
        try connection.execute(
            "DELETE FROM activity_speed_buckets_5m WHERE bucket_start < ?",
            bindings: [.int64(bucketStart(now - rollupRetention))]
        )
    }

    private static func bucketStart(_ timestamp: Double) -> Int64 {
        Int64(floor(timestamp / Double(bucketSeconds))) * bucketSeconds
    }

    private static func dimensionBindings(_ sample: ActivitySpeedSample) -> [SQLiteBinding] {
        [.text(sample.sourceIdentity), .text(sample.displayMode), .text(sample.estimatorID), .text(sample.estimatorVersion),
         .text(sample.metricKind), .text(sample.client), .text(sample.model)]
    }

    private static func dimensions(_ row: SQLiteStatement) throws -> ActivitySpeedDimensions {
        guard let sourceIdentity = row.text(0), let displayMode = row.text(1), let estimatorID = row.text(2),
              let estimatorVersion = row.text(3), let metricKind = row.text(4),
              let client = row.text(5), let model = row.text(6) else {
            throw ActivitySpeedStoreError.invalidStoredAggregate
        }
        return ActivitySpeedDimensions(sourceIdentity: sourceIdentity, displayMode: displayMode, estimatorID: estimatorID,
                                       estimatorVersion: estimatorVersion, metricKind: metricKind,
                                       client: client, model: model)
    }

    private static func filterSQL(_ filter: ActivitySpeedFilter) -> (String, [SQLiteBinding]) {
        let pairs: [(String, String?)] = [
            ("source_identity", filter.sourceIdentity), ("display_mode", filter.displayMode),
            ("estimator_id", filter.estimatorID),
            ("estimator_version", filter.estimatorVersion), ("metric_kind", filter.metricKind),
            ("client", filter.client), ("model", filter.model)
        ]
        let selected = pairs.compactMap { column, value -> (String, String)? in
            value.map { (column, $0) }
        }
        guard !selected.isEmpty else { return ("", []) }
        return (" AND " + selected.map { "\($0.0)=?" }.joined(separator: " AND "),
                selected.map { .text($0.1) })
    }
}

enum ActivitySpeedStoreError: LocalizedError {
    case invalidNow, invalidFilter, invalidWindow, invalidSample, invalidStoredAggregate, schemaUnavailable, unsupportedSchema, tooManySeries, tooManySamples

    var errorDescription: String? { switch self {
        case .invalidNow: "Activity speed query or write time is invalid"
        case .invalidFilter: "Activity speed trend start is invalid"
        case .invalidWindow: "Activity speed history window is unsupported"
        case .invalidSample: "Activity speed sample is invalid"
        case .invalidStoredAggregate: "Activity speed database contains invalid aggregate data"
        case .schemaUnavailable: "Activity speed schema resource is unavailable"
        case .unsupportedSchema: "Activity speed database schema is not supported"
        case .tooManySeries: "Activity speed query exceeds the bounded series limit"
        case .tooManySamples: "Activity speed batch exceeds the bounded sample limit"
    } }
}
