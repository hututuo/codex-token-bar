import CryptoKit
import Foundation

/// A sparse, model-specific trend point backed by one or more completed body samples.
/// `bucketStart` is a UTC Unix timestamp aligned to the read window's bucket width.
struct BodySpeedTrendPoint: Codable, Equatable, Identifiable, Sendable {
    var bucketStart: Int64
    var model: String
    var outputTokens: Int64
    var durationSeconds: Double
    var sampleCount: Int64
    var tokensPerSecond: Double

    var bucketEnd: Int64? = nil
    var lowerQuartile: Double? = nil
    var median: Double? = nil
    var upperQuartile: Double? = nil
    var bucketCount: Int64? = nil
    var isPartial: Bool? = nil

    var id: String { "\(model):\(bucketStart)" }
    var isDistribution: Bool {
        guard let end = bucketEnd, end > bucketStart,
              let lower = lowerQuartile, let median, let upper = upperQuartile,
              lower.isFinite, median.isFinite, upper.isFinite,
              lower > 0, lower <= median, median <= upper,
              let count = bucketCount, count >= 3, sampleCount >= 6 else { return false }
        return true
    }
}

/// Durable numeric storage for completed response-body samples and their five-minute trend.
/// The caller owns the cache path; this store never scans rollout files or stores response text.
final class BodySpeedTrendStore {
    private static let schemaVersion = "1"
    private static let bucketSeconds: Int64 = 300
    private static let dedupRetentionSeconds = 30.0 * 86_400.0
    private static let aggregateRetentionSeconds = 90.0 * 86_400.0
    private static let maxBackfillSeconds = 30.0 * 86_400.0

    private let database: BodySpeedDatabase
    private let lock = NSLock()

    init(url: URL, sharedURL: URL? = nil) throws {
        let database = try BodySpeedDatabase(logicalURL: url, sharedURL: sharedURL)
        self.database = database
        try database.transaction { connection in
            try Self.createSchema(connection)
        }
        if sharedURL != nil {
            try database.validateNamespace(requireAll: true)
            try BodySpeedMigration.migrate(logicalURL: url, database: database)
        }
    }

    /// Persist eligible history rows and update the weighted five-minute trend.
    /// Repeated IDs are idempotent; changed numeric/model/quality fields replace their old
    /// aggregate contribution in the same transaction.
    @discardableResult
    func ingest(
        samples: [ObservedSpeedSample],
        now: Double,
        retentionDays: Int = 30
    ) throws -> Int {
        guard Self.safeNow(now) else { return 0 }
        let retention = Self.normalizedRetentionDays(retentionDays)
        lock.lock()
        defer { lock.unlock() }
        return try database.transaction { connection in
            try Self.ingest(samples, now: now, retentionDays: retention, connection: connection)
        }
    }

    /// Read retained completed-body history in chronological order for UI bootstrap.
    func loadSamples(now: Double, retentionDays: Int = 30) throws -> [ObservedSpeedSample] {
        guard Self.safeNow(now) else { return [] }
        let retention = Self.normalizedRetentionDays(retentionDays)
        let cutoff = now - Double(retention) * 86_400
        lock.lock()
        defer { lock.unlock() }
        return try database.readRows(
            """
            SELECT payload_json
            FROM speed_samples
            WHERE ended_at >= ? AND ended_at <= ?
            ORDER BY ended_at ASC, id ASC
            """,
            bindings: [.double(cutoff), .double(now)]
        ) { row in
            guard let json = row.text(0), let data = json.data(using: .utf8) else {
                throw Self.storageError("Invalid completed body payload")
            }
            return try JSONDecoder().decode(ObservedSpeedSample.self, from: data)
        }
    }

    func retentionDays() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let values = try database.readRows(
            "SELECT value FROM speed_trend_meta WHERE key = 'body_retention_days'"
        ) { $0.text(0) }
        guard let value = values.compactMap({ $0 }).first,
              let days = Int(value), [15, 30].contains(days) else {
            throw Self.storageError("Invalid completed body retention preference")
        }
        return days
    }

    private struct LegacyJSONReceipt: Codable {
        let source: String
        let backup: String
        let digest: String
    }

    /// Public 0.9.7 used JSON before the intermediate SQLite store existed.
    /// Import once per source, in the same transaction as its receipt. Keep the
    /// complete original and a verified backup, including retired stream rows.
    func importLegacyJSON(now: Double, retentionDays: Int) throws {
        guard Self.safeNow(now) else { throw Self.storageError("Invalid body history migration time") }
        let name = database.logicalURL.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("body-speed-") else { return }
        let source = database.logicalURL.deletingLastPathComponent()
            .appendingPathComponent("observed-speed-" + name.dropFirst("body-speed-".count) + ".json")
        let backups = (database.sharedURL ?? database.logicalURL).deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        let marker = "public_097_json_import_v1"
        let receipt = try database.readRows("SELECT value FROM speed_trend_meta WHERE key=?", bindings: [.text(marker)]) { $0.text(0) }.first ?? nil
        if let receipt {
            let saved = try JSONDecoder().decode(LegacyJSONReceipt.self, from: Data(receipt.utf8))
            guard saved.source == source.path, saved.digest.count == 64,
                  saved.digest.allSatisfy({ $0.isHexDigit }),
                  saved.backup == backups.appendingPathComponent("observed-speed-\(saved.digest).json").path,
                  Self.legacyDigest(try Data(contentsOf: URL(fileURLWithPath: saved.backup))) == saved.digest else {
                throw Self.storageError("Legacy JSON body history backup verification failed")
            }
            return
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: source.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= 64 * 1_048_576 else {
            throw Self.storageError("Invalid legacy JSON body history file")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1_048_576 + 1) ?? Data()
        guard data.count <= 64 * 1_048_576 else { throw Self.storageError("Legacy JSON body history is too large") }
        let samples = try JSONDecoder().decode([ObservedSpeedSample].self, from: data)
        // A once-only receipt must not fence out samples merely because the
        // local clock is behind their timestamp. Leave the source retryable.
        guard !samples.contains(where: { $0.isBody && $0.endedAt > now }) else {
            throw Self.storageError("Legacy body history contains future timestamps; import deferred")
        }
        let digest = Self.legacyDigest(data)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backups.appendingPathComponent("observed-speed-\(digest).json")
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        guard try Data(contentsOf: backup) == data else { throw Self.storageError("Legacy JSON body history backup mismatch") }
        let encodedReceipt = String(decoding: try JSONEncoder().encode(LegacyJSONReceipt(source: source.path, backup: backup.path, digest: digest)), as: UTF8.self)
        try database.transaction { connection in
            // Recheck under the writer lock; a second process may have imported.
            if !(try connection.readRows("SELECT value FROM speed_trend_meta WHERE key=?", bindings: [.text(marker)]) { $0.text(0) }).isEmpty { return }
            let existing = Set(try connection.readRows("SELECT id FROM speed_sample_ids UNION SELECT id FROM speed_samples") { $0.text(0) ?? "" })
            let aggregateRows = try connection.readRows("SELECT 1 FROM speed_5m LIMIT 1") { $0.int(0) }
            let hasHistory = !existing.isEmpty || !aggregateRows.isEmpty
            // A more recent SQLite record wins over an older JSON revision.
            _ = try Self.ingest(samples.filter { $0.isBody && !existing.contains($0.id) }, now: now,
                                retentionDays: try self.retentionDaysForImport(connection, fallback: retentionDays, hasHistory: hasHistory), connection: connection)
            try connection.execute("INSERT INTO speed_trend_meta(key,value) VALUES(?,?)", bindings: [.text(marker), .text(encodedReceipt)])
        }
    }

    private func retentionDaysForImport(_ connection: BodySpeedDatabaseConnection, fallback: Int, hasHistory: Bool) throws -> Int {
        guard hasHistory else { return Self.normalizedRetentionDays(fallback) }
        let raw = try connection.readRows("SELECT value FROM speed_trend_meta WHERE key='body_retention_days'") { $0.text(0) }.first ?? nil
        guard let raw, let days = Int(raw), [15, 30].contains(days) else { throw Self.storageError("Invalid body retention preference") }
        return days
    }

    private static func legacyDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Read sparse points for 1, 7, or 30 days. Five-minute stored totals are grouped by
    /// their sums, so each returned rate remains tokens divided by measured duration.
    func read(now: Double, days: Int) throws -> [BodySpeedTrendPoint] {
        guard Self.safeNow(now), [1, 7, 30].contains(days) else { return [] }
        let resolution: Int64 = days == 1 ? 300 : (days == 7 ? 1_800 : 7_200)
        let cutoff = now - Double(days) * 86_400
        let firstStoredBucket = Int64(floor(cutoff / 300)) * 300
        let lastStoredBucket = Int64(floor(now / 300)) * 300
        let maxPoints = Int64(days * 86_400) / resolution
        lock.lock()
        defer { lock.unlock() }
        return try database.readRows(
            """
            WITH grouped AS (
                SELECT (bucket_start / ?) * ? AS bucket_start,
                       model,
                       SUM(output_tokens) AS output_tokens,
                       SUM(duration_seconds) AS duration_seconds,
                       SUM(sample_count) AS sample_count
                FROM speed_5m
                WHERE bucket_start >= ? AND bucket_start <= ?
                GROUP BY (bucket_start / ?) * ?, model
            ), ranked AS (
                SELECT bucket_start, model, output_tokens, duration_seconds, sample_count,
                       ROW_NUMBER() OVER (PARTITION BY model ORDER BY bucket_start DESC) AS point_rank
                FROM grouped
            )
            SELECT bucket_start, model, output_tokens, duration_seconds, sample_count
            FROM ranked
            WHERE point_rank <= ?
            ORDER BY bucket_start ASC, model ASC
            """,
            bindings: [
                .int64(resolution), .int64(resolution),
                .int64(firstStoredBucket), .int64(lastStoredBucket),
                .int64(resolution), .int64(resolution), .int64(maxPoints)
            ]
        ) { row in
            guard let bucketStart = row.int64(0), let model = row.text(1),
                  let outputTokens = row.int64(2), let duration = row.double(3),
                  let count = row.int64(4), duration.isFinite, duration > 0,
                  outputTokens > 0, count > 0 else {
                throw Self.storageError("Invalid completed body aggregate")
            }
            let rate = Double(outputTokens) / duration
            guard rate.isFinite, rate > 0 else {
                throw Self.storageError("Invalid completed body aggregate rate")
            }
            return BodySpeedTrendPoint(
                bucketStart: bucketStart,
                model: model,
                outputTokens: outputTokens,
                durationSeconds: duration,
                sampleCount: count,
                tokensPerSecond: rate
            )
        }
    }

    /// Distribution of completed five-minute bucket rates, not individual response samples.
    /// Numeric history remains unchanged; preparation runs on the existing persistence actor.
    func readDistribution(now: Double, days: Int) throws -> [BodySpeedTrendPoint] {
        guard Self.safeNow(now), [1, 7, 30].contains(days) else { return [] }
        let width: Int64 = days == 1 ? 1_800 : days == 7 ? 7_200 : 21_600
        let first = Int64(ceil((now - Double(days) * 86_400) / 300)) * 300
        let completedThrough = Int64(floor(now / 300)) * 300
        lock.lock()
        defer { lock.unlock() }
        let raw: [BodySpeedTrendPoint] = try database.readRows(
            "SELECT bucket_start, model, output_tokens, duration_seconds, sample_count FROM speed_5m " +
            "WHERE bucket_start >= ? AND bucket_start < ? ORDER BY bucket_start, model",
            bindings: [.int64(first), .int64(completedThrough)]
        ) { row in
            guard let start = row.int64(0), let model = row.text(1), let tokens = row.int64(2),
                  let seconds = row.double(3), let count = row.int64(4),
                  seconds.isFinite, seconds > 0, tokens > 0, count > 0,
                  (Double(tokens) / seconds).isFinite else {
                throw Self.storageError("Invalid completed body distribution bucket")
            }
            return .init(bucketStart: start, model: model, outputTokens: tokens,
                         durationSeconds: seconds, sampleCount: count, tokensPerSecond: Double(tokens) / seconds)
        }
        return try Self.distributions(raw, width: width, completedThrough: completedThrough)
    }

    static func distributions(_ points: [BodySpeedTrendPoint], width: Int64,
                              completedThrough: Int64) throws -> [BodySpeedTrendPoint] {
        struct Key: Hashable { let model: String; let start: Int64 }
        guard width > 0 else { return [] }
        let grouped = Dictionary(grouping: points) { Key(model: $0.model, start: $0.bucketStart / width * width) }
        return try grouped.compactMap { key, rows -> BodySpeedTrendPoint? in
            guard rows.count >= 3 else { return nil }
            var tokens: Int64 = 0, count: Int64 = 0, seconds = 0.0
            for row in rows {
                let (newTokens, tokenOverflow) = tokens.addingReportingOverflow(row.outputTokens)
                let (newCount, countOverflow) = count.addingReportingOverflow(row.sampleCount)
                guard !tokenOverflow, !countOverflow, row.tokensPerSecond.isFinite,
                      row.tokensPerSecond > 0, row.durationSeconds.isFinite, row.durationSeconds > 0 else {
                    throw storageError("Invalid completed body distribution totals")
                }
                tokens = newTokens; count = newCount; seconds += row.durationSeconds
            }
            guard count >= 6 else { return nil }
            guard seconds.isFinite, seconds > 0, (Double(tokens) / seconds).isFinite else {
                throw storageError("Invalid completed body distribution duration")
            }
            let rates = rows.map(\.tokensPerSecond).sorted()
            func quantile(_ p: Double) -> Double {
                let position = Double(rates.count - 1) * p
                let lower = Int(floor(position)), upper = Int(ceil(position))
                return rates[lower] + (rates[upper] - rates[lower]) * (position - Double(lower))
            }
            return .init(bucketStart: key.start, model: key.model, outputTokens: tokens,
                         durationSeconds: seconds, sampleCount: count, tokensPerSecond: Double(tokens) / seconds,
                         bucketEnd: min(key.start + width, completedThrough), lowerQuartile: quantile(0.25),
                         median: quantile(0.5), upperQuartile: quantile(0.75), bucketCount: Int64(rows.count),
                         isPartial: key.start + width > completedThrough)
        }.sorted { $0.bucketStart == $1.bucketStart ? $0.model < $1.model : $0.bucketStart < $1.bucketStart }
    }

    private static func createSchema(_ connection: BodySpeedDatabaseConnection) throws {
        try connection.execute(
            "CREATE TABLE IF NOT EXISTS speed_trend_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID"
        )
        let versions = try connection.readRows(
            "SELECT value FROM speed_trend_meta WHERE key = 'schema_version'"
        ) { $0.text(0) }
        if let version = versions.first, version != schemaVersion {
            throw storageError("Unsupported body speed trend schema version")
        }
        try connection.execute(
            "INSERT OR IGNORE INTO speed_trend_meta(key, value) VALUES('schema_version', '\(schemaVersion)')"
        )
        try connection.execute(
            "INSERT OR IGNORE INTO speed_trend_meta(key, value) VALUES('body_retention_days', '30')"
        )
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS speed_samples (
                id TEXT PRIMARY KEY NOT NULL,
                ended_at REAL NOT NULL,
                model TEXT NOT NULL,
                included INTEGER NOT NULL,
                payload_json TEXT NOT NULL
            ) WITHOUT ROWID
            """
        )
        try connection.execute("CREATE INDEX IF NOT EXISTS speed_samples_ended_model ON speed_samples(ended_at, model)")
        try connection.execute("CREATE INDEX IF NOT EXISTS speed_samples_model_ended ON speed_samples(model, ended_at)")
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS speed_sample_ids (
                id TEXT PRIMARY KEY NOT NULL,
                ended_at REAL NOT NULL,
                bucket_start INTEGER NOT NULL,
                model TEXT NOT NULL,
                output_tokens INTEGER NOT NULL,
                duration_seconds REAL NOT NULL,
                trend_eligible INTEGER NOT NULL
            ) WITHOUT ROWID
            """
        )
        try connection.execute("CREATE INDEX IF NOT EXISTS speed_sample_ids_ended ON speed_sample_ids(ended_at)")
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS speed_5m (
                bucket_start INTEGER NOT NULL,
                model TEXT NOT NULL,
                output_tokens INTEGER NOT NULL,
                duration_seconds REAL NOT NULL,
                sample_count INTEGER NOT NULL,
                PRIMARY KEY(bucket_start, model)
            ) WITHOUT ROWID
            """
        )
        if connection.isShared {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS speed_migration_receipts (
                    source_identity TEXT PRIMARY KEY NOT NULL,
                    source_digest TEXT NOT NULL,
                    rows_digest TEXT NOT NULL,
                    meta_count INTEGER NOT NULL,
                    sample_count INTEGER NOT NULL,
                    id_count INTEGER NOT NULL,
                    aggregate_count INTEGER NOT NULL,
                    backup_path TEXT NOT NULL,
                    completed_at REAL NOT NULL
                ) WITHOUT ROWID
                """
            )
        }
    }

    private static func ingest(
        _ samples: [ObservedSpeedSample],
        now: Double,
        retentionDays: Int,
        connection: BodySpeedDatabaseConnection
    ) throws -> Int {
        let rawCutoff = now - Double(retentionDays) * 86_400
        let idCutoff = now - dedupRetentionSeconds
        let trendCutoff = now - maxBackfillSeconds
        var changedIDs = Set<String>()

        try connection.execute(
            "INSERT INTO speed_trend_meta(key, value) VALUES('body_retention_days', ?) " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text(String(retentionDays))]
        )

        let rawUpsert = try connection.prepare(
            """
            INSERT INTO speed_samples(id, ended_at, model, included, payload_json)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                ended_at = excluded.ended_at,
                model = excluded.model,
                included = excluded.included,
                payload_json = excluded.payload_json
            WHERE speed_samples.ended_at != excluded.ended_at
               OR speed_samples.model != excluded.model
               OR speed_samples.included != excluded.included
               OR speed_samples.payload_json != excluded.payload_json
            """
        )
        let insertID = try connection.prepare(
            """
            INSERT INTO speed_sample_ids(id, ended_at, bucket_start, model, output_tokens, duration_seconds, trend_eligible)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """
        )
        let insertAggregate = try connection.prepare(
            """
            INSERT INTO speed_5m(bucket_start, model, output_tokens, duration_seconds, sample_count)
            VALUES(?, ?, ?, ?, 1)
            ON CONFLICT(bucket_start, model) DO UPDATE SET
                output_tokens = output_tokens + excluded.output_tokens,
                duration_seconds = duration_seconds + excluded.duration_seconds,
                sample_count = sample_count + 1
            WHERE output_tokens <= 9223372036854775807 - excluded.output_tokens
              AND sample_count < 9223372036854775807
              AND duration_seconds <= 1.7976931348623157e308 - excluded.duration_seconds
            """
        )
        let updateID = try connection.prepare(
            """
            UPDATE speed_sample_ids
            SET ended_at = ?, bucket_start = ?, model = ?, output_tokens = ?, duration_seconds = ?, trend_eligible = ?
            WHERE id = ?
            """
        )
        let subtractAggregate = try connection.prepare(
            """
            UPDATE speed_5m
            SET output_tokens = output_tokens - ?, duration_seconds = duration_seconds - ?, sample_count = sample_count - 1
            WHERE bucket_start = ? AND model = ? AND output_tokens >= ? AND sample_count > 0
            """
        )
        let removeEmptyAggregate = try connection.prepare(
            "DELETE FROM speed_5m WHERE bucket_start = ? AND model = ? AND sample_count <= 0"
        )

        for sample in samples where isValidRawBodySample(sample) {
            guard sample.endedAt <= now else { continue }
            let model = sample.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "unknown" : sample.model
            let rawAge = now - sample.endedAt
            if rawAge <= Double(retentionDays) * 86_400 {
                let payload = try encode(sample)
                if try rawUpsert.execute([
                    .text(sample.id), .double(sample.endedAt), .text(model),
                    .int(sample.bodyQuality.included ? 1 : 0), .text(payload)
                ]) > 0 {
                    changedIDs.insert(sample.id)
                }
            }

            guard sample.endedAt >= trendCutoff else { continue }
            let bucketValue = floor(sample.endedAt / Double(bucketSeconds)) * Double(bucketSeconds)
            guard bucketValue.isFinite,
                  bucketValue >= Double(Int64.min), bucketValue < Double(Int64.max) else { continue }
            let bucket = Int64(bucketValue)
            let trendEligible = sample.hasKnownModel && sample.bodyQuality.included
            let trendModel = trendEligible ? sample.model : model
            let tokens = Int64(sample.outputTokens)
            let duration = sample.durationSeconds

            let inserted = try insertID.execute([
                .text(sample.id), .double(sample.endedAt), .int64(bucket), .text(trendModel),
                .int64(tokens), .double(duration), .int(trendEligible ? 1 : 0)
            ]) > 0
            if inserted {
                if trendEligible {
                    try addAggregate(
                        statement: insertAggregate, bucket: bucket, model: trendModel,
                        tokens: tokens, duration: duration
                    )
                }
                changedIDs.insert(sample.id)
                continue
            }

            let oldRows = try connection.readRows(
                """
                SELECT ended_at, bucket_start, model, output_tokens, duration_seconds, trend_eligible
                FROM speed_sample_ids WHERE id = ?
                """,
                bindings: [.text(sample.id)]
            ) { row in
                (
                    row.double(0) ?? 0,
                    row.int64(1) ?? 0,
                    row.text(2) ?? "",
                    row.int64(3) ?? 0,
                    row.double(4) ?? 0,
                    row.int(5) == 1
                )
            }
            guard let old = oldRows.first else { continue }
            let same = old.0 == sample.endedAt && old.1 == bucket && old.2 == trendModel
                && old.3 == tokens && old.4 == duration && old.5 == trendEligible
            guard !same else { continue }

            if old.5 {
                guard try subtractAggregate.execute([
                    .int64(old.3), .double(old.4), .int64(old.1), .text(old.2), .int64(old.3)
                ]) > 0 else {
                    throw Self.storageError("Missing completed body aggregate during correction")
                }
                try removeEmptyAggregate.execute([.int64(old.1), .text(old.2)])
            }
            try updateID.execute([
                .double(sample.endedAt), .int64(bucket), .text(trendModel), .int64(tokens),
                .double(duration), .int(trendEligible ? 1 : 0), .text(sample.id)
            ])
            if trendEligible {
                try addAggregate(
                    statement: insertAggregate, bucket: bucket, model: trendModel,
                    tokens: tokens, duration: duration
                )
            }
            changedIDs.insert(sample.id)
        }

        try connection.execute("DELETE FROM speed_samples WHERE ended_at < ?", bindings: [.double(rawCutoff)])
        try connection.execute("DELETE FROM speed_sample_ids WHERE ended_at < ?", bindings: [.double(idCutoff)])
        try connection.execute(
            "DELETE FROM speed_5m WHERE bucket_start < ?",
            bindings: [.int64(Int64(floor((now - aggregateRetentionSeconds) / 300)) * 300)]
        )
        return changedIDs.count
    }

    private static func addAggregate(
        statement: SQLitePreparedStatement,
        bucket: Int64,
        model: String,
        tokens: Int64,
        duration: Double
    ) throws {
        guard try statement.execute([.int64(bucket), .text(model), .int64(tokens), .double(duration)]) > 0 else {
            throw storageError("Completed body aggregate exceeded numeric storage limits")
        }
    }

    private static func encode(_ sample: ObservedSpeedSample) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sample)
        guard let json = String(data: data, encoding: .utf8) else {
            throw storageError("Unable to encode completed body payload")
        }
        return json
    }

    private static func isValidRawBodySample(_ sample: ObservedSpeedSample) -> Bool {
        guard sample.isBody,
              !sample.id.isEmpty, sample.id.utf8.count <= 2_048,
              !sample.threadID.isEmpty, sample.threadID.utf8.count <= 512,
              !sample.turnID.isEmpty, sample.turnID.utf8.count <= 512,
              !sample.itemID.isEmpty, sample.itemID.utf8.count <= 512,
              sample.model.utf8.count <= 256,
              (sample.networkWarning?.utf8.count ?? 0) <= 512,
              sample.source.utf8.count <= 128,
              ["low", "medium", "high"].contains(sample.confidence),
              (sample.bodyPhase?.utf8.count ?? 0) <= 64,
              (sample.qualityReason?.utf8.count ?? 0) <= 256,
              sample.startedAt.isFinite, sample.endedAt.isFinite,
              sample.durationSeconds.isFinite, sample.tokensPerSecond.isFinite,
              sample.startedAt >= 0, sample.endedAt >= sample.startedAt,
              sample.durationSeconds >= 0, sample.outputTokens >= 0,
              sample.tokensPerSecond >= 0 else { return false }
        return true
    }

    private static func normalizedRetentionDays(_ days: Int) -> Int {
        [15, 30].contains(days) ? days : 30
    }

    private static func safeNow(_ now: Double) -> Bool {
        now.isFinite && now >= 0 && now < Double(Int64.max) - aggregateRetentionSeconds
    }

    private static func storageError(_ message: String) -> SQLiteDatabaseError {
        SQLiteDatabaseError(
            operation: "Read body speed trend",
            code: 20,
            message: message,
            path: nil
        )
    }
}
