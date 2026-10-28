import Combine
import CoreFoundation
import CryptoKit
import Foundation

struct ClaudeAPISpeedSample: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let session: String
    let model: String
    let endedAt: Date
    let outputTokens: Int
    let duration: Double
    var method: String? = "statusline-response-api-v2"
    var tps: Double { Double(outputTokens) / duration }
    var qualified: Bool { method == "statusline-response-api-v2" && duration > 0.4 && tps.isFinite && (2...500).contains(tps) }
}

struct ClaudeStatuslineMetrics: Equatable, Sendable {
    let session: String
    let model: String
    let capturedAt: Date
    let output: Int
    let apiMilliseconds: Double
    let contextUsed: Int?
    let contextSize: Int?
    var usageKey: String = ""

    static func decode(_ data: Data, now: Date) -> Self? {
        guard data.count <= 65_536, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema_version"] as? Int == 1,
              let time = root["captured_at_epoch"] as? Double, time.isFinite,
              time <= now.timeIntervalSince1970 + 1, now.timeIntervalSince1970 - time <= 600,
              let session = root["session_id"] as? String, !session.isEmpty, session.utf8.count <= 256,
              let model = (root["model"] as? [String: Any])?["id"] as? String, !model.isEmpty, model.utf8.count <= 256,
              let context = root["context_window"] as? [String: Any],
              let current = context["current_usage"] as? [String: Any],
              let output = count(current["output_tokens"]),
              let duration = count((root["cost"] as? [String: Any])?["total_api_duration_ms"]) else { return nil }
        let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        let values = keys.compactMap { count(current[$0]) }
        let sum = values.reduce(Int64(0)) { min(Int64(Int.max), $0 + Int64($1)) }
        return .init(session: session, model: model, capturedAt: Date(timeIntervalSince1970: time), output: output,
            apiMilliseconds: Double(duration), contextUsed: values.isEmpty ? nil : Int(sum), contextSize: count(context["context_window_size"]),
            usageKey: keys.map { count(current[$0]).map(String.init) ?? "unknown" }.joined(separator: ":"))
    }
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1e12,
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
    func sample(after old: Self) -> ClaudeAPISpeedSample? {
        guard session == old.session, model == old.model, capturedAt > old.capturedAt,
              !usageKey.isEmpty, usageKey != old.usageKey, output > 0, apiMilliseconds > old.apiMilliseconds else { return nil }
        let elapsed = (apiMilliseconds - old.apiMilliseconds) / 1000
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        let opaqueSession = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "statusline-response-api-v2|\(opaqueSession)|\(model)|\(apiMilliseconds)|\(usageKey)"
        let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(id: id, session: opaqueSession, model: model, endedAt: capturedAt, outputTokens: output, duration: elapsed)
    }
}

struct ClaudeAPISpeedWindow: Equatable, Sendable, Identifiable {
    var id: String { model }
    let model: String
    let five: Double?
    let fifteen: Double?
    let thirty: Double?
    let latest: Double?
}
struct ClaudeAPISpeedBucket: Equatable, Sendable, Identifiable {
    var id: String { model + String(start) }
    let model: String
    let start: Int
    let tps: Double
}

/// App-owned SQLite, seven-day retention. This database never opens the Codex
/// ledger or any Claude database and contains no transcript content.
actor ClaudeLocalSpeedLedger {
    let url: URL
    private var db: SQLiteDatabaseDriver?
    init(url: URL) { self.url = url }
    func records(adding sample: ClaudeAPISpeedSample? = nil, now: Date = Date()) throws -> [ClaudeAPISpeedSample] {
        if db == nil {
            let value = SQLiteDatabaseDriver(url: url)
            try value.execute("CREATE TABLE IF NOT EXISTS api_speed(id TEXT PRIMARY KEY, ended REAL NOT NULL, payload TEXT NOT NULL, model TEXT NOT NULL, tokens INTEGER NOT NULL, duration REAL NOT NULL)")
            try value.execute("CREATE INDEX IF NOT EXISTS api_speed_by_time ON api_speed(ended)")
            try value.execute("CREATE INDEX IF NOT EXISTS api_speed_by_model ON api_speed(model,ended)")
            // Preserve older samples for inspection, but never average the old
            // output-delta interpretation together with corrected response samples.
            let columns = try value.readRows("PRAGMA table_info(api_speed)") { $0.text(1) ?? "" }
            if !columns.contains("method") {
                try value.execute("ALTER TABLE api_speed ADD COLUMN method TEXT NOT NULL DEFAULT 'legacy-output-delta-v1'")
            }
            db = value
        }
        guard let db else { return [] }
        if let sample, let json = String(data: try JSONEncoder().encode(sample), encoding: .utf8) {
            try db.execute("INSERT OR IGNORE INTO api_speed(id,ended,payload,model,tokens,duration,method) VALUES(?1,?2,?3,?4,?5,?6,?7)", bindings: [.text(sample.id), .double(sample.endedAt.timeIntervalSince1970), .text(json), .text(sample.model), .int64(Int64(sample.outputTokens)), .double(sample.duration), .text(sample.method ?? "legacy-output-delta-v1")])
        }
        try db.execute("DELETE FROM api_speed WHERE ended < ?1", bindings: [.double(now.addingTimeInterval(-7 * 86400).timeIntervalSince1970)])
        return try db.readRows("SELECT payload FROM api_speed WHERE ended >= ?1 ORDER BY ended DESC LIMIT 1000", bindings: [.double(now.addingTimeInterval(-1800).timeIntervalSince1970)]) { row -> ClaudeAPISpeedSample? in
            guard let json = row.text(0)?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ClaudeAPISpeedSample.self, from: json)
        }.compactMap { $0 }
    }
    func aggregates(now: Date) throws -> ([ClaudeAPISpeedWindow], [ClaudeAPISpeedBucket]) {
        guard let db else { return ([], []) }
        let epoch = now.timeIntervalSince1970
        let valid = "method = 'statusline-response-api-v2' AND duration > 0.4 AND tokens / duration BETWEEN 2 AND 500"
        let windows = try db.readRows("""
            SELECT model,
            SUM(CASE WHEN ended>=?1 THEN tokens ELSE 0 END)*1.0 / NULLIF(SUM(CASE WHEN ended>=?1 THEN duration ELSE 0 END),0),
            SUM(CASE WHEN ended>=?2 THEN tokens ELSE 0 END)*1.0 / NULLIF(SUM(CASE WHEN ended>=?2 THEN duration ELSE 0 END),0),
            SUM(tokens)*1.0 / SUM(duration),
            (SELECT tokens*1.0/duration FROM api_speed b WHERE b.model=a.model AND b.ended>=?3 AND \(valid) ORDER BY ended DESC LIMIT 1)
            FROM api_speed a WHERE ended>=?3 AND \(valid) GROUP BY model ORDER BY model
            """, bindings: [.double(epoch-300), .double(epoch-900), .double(epoch-1800)]) { row in
                ClaudeAPISpeedWindow(model: row.text(0) ?? "unknown", five: row.double(1), fifteen: row.double(2), thirty: row.double(3), latest: row.double(4))
            }
        let buckets = try db.readRows("""
            SELECT model,CAST(ended/300 AS INTEGER)*300,SUM(tokens)*1.0/SUM(duration)
            FROM api_speed WHERE ended>=?1 AND \(valid) GROUP BY model,CAST(ended/300 AS INTEGER) ORDER BY model,2
            """, bindings: [.double(epoch-1800)]) { row in
                ClaudeAPISpeedBucket(model: row.text(0) ?? "unknown", start: row.int(1) ?? 0, tps: row.double(2) ?? 0)
            }
        return (windows, buckets)
    }

}

@MainActor final class ClaudeStatuslineStore: ObservableObject {
    static let shared = ClaudeStatuslineStore()
    static var cacheURL: URL { MultiClientUsageStore.defaultDatabaseURL.deletingLastPathComponent().appendingPathComponent("claude-local-statusline/latest.json") }
    @Published private(set) var metrics: ClaudeStatuslineMetrics?
    @Published private(set) var samples: [ClaudeAPISpeedSample] = []
    @Published private(set) var windows: [ClaudeAPISpeedWindow] = []
    @Published private(set) var buckets: [ClaudeAPISpeedBucket] = []
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var baselines: [String: ClaudeStatuslineMetrics] = [:]
    private let ledger = ClaudeLocalSpeedLedger(url: MultiClientUsageStore.defaultDatabaseURL.deletingLastPathComponent().appendingPathComponent("claude-local-speed.sqlite"))

    func setEnabled(_ enabled: Bool) {
        if !enabled { task?.cancel(); task = nil; baselines.removeAll(); metrics = nil; samples = []; windows = []; buckets = []; return }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func loadHistory() async {
        do {
            let now = Date(), rows = try await ledger.records(now: Date())
            let result = try await ledger.aggregates(now: now)
            guard !Task.isCancelled else { return }
            samples = rows; windows = result.0; buckets = result.1
        } catch { self.error = "本地测速索引暂不可用" }
    }
    private let files = ClaudeStatuslineFiles()
    private func poll() async {
        let now = Date()
        let recent = samples.filter { $0.endedAt >= now.addingTimeInterval(-1800) }
        if samples != recent { samples = recent }
        let readings = await files.read(directory: Self.cacheURL.deletingLastPathComponent(), now: now)
        let reading = readings.max { $0.capturedAt < $1.capturedAt }
        guard !Task.isCancelled else { return }
        if metrics != reading { metrics = reading }
        // Statusline context polling only. Legacy API-speed records remain on
        // disk for migration; this path never opens or writes the old speed DB.

    }
}

private actor ClaudeStatuslineFiles {
    private var cache: [URL: (Date, ClaudeStatuslineMetrics?)] = [:]
    func read(directory: URL, now: Date) -> [ClaudeStatuslineMetrics] {
        guard let info = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]), info.isSymbolicLink != true,
              let paths = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { cache.removeAll(); return [] }
        let files = paths.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }.prefix(64)
        var result: [ClaudeStatuslineMetrics] = []
        for path in files {
            guard let info = try? path.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, let date = info.contentModificationDate,
                  let size = info.fileSize, size <= 65_536 else { continue }
            let value: ClaudeStatuslineMetrics?
            if let prior = cache[path], prior.0 == date { value = prior.1 }
            else {
                value = (try? Data(contentsOf: path)).flatMap { ClaudeStatuslineMetrics.decode($0, now: now) }
                cache[path] = (date, value)
            }
            if let value, now.timeIntervalSince(value.capturedAt) <= 600 { result.append(value) }
        }
        cache = cache.filter { files.contains($0.key) }
        return result
    }
}
