import Foundation

struct ClientQuotaHistorySample: Equatable, Sendable {
    let windowID: String
    let observedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

/// Adapts a client's independent pool to the existing two-window chart contract.
struct ClientQuotaHistory: Identifiable, Equatable, Sendable {
    let client: String
    let source: String
    let pool: String
    let samples: [ClientQuotaHistorySample]
    var id: String { client + ":" + source + ":" + pool }
    var title: String {
        let name = ClientDisplayScope.title(client)
        return pool.isEmpty ? name : name + " · " + (pool == "gemini" ? "Gemini" : "第三方模型")
    }

    func buckets(interval: TimeInterval, now: Date = Date()) -> [QuotaHistoryRecentBucket] {
        guard interval.isFinite, interval > 0 else { return [] }
        let end = floor(now.timeIntervalSince1970 / interval) * interval
        let start = end - 30 * 24 * 60 * 60 + interval
        let five = samples.filter { Self.period($0.windowID) == "5h" }
        let seven = samples.filter { Self.period($0.windowID) == "7d" }
        var fiveIndex = 0, sevenIndex = 0
        func value(_ rows: [ClientQuotaHistorySample], _ index: inout Int, from start: Date, through boundary: Date) -> (Double?, [QuotaHistoryObservation]) {
            let first = index
            while index < rows.count && rows[index].observedAt <= boundary { index += 1 }
            let observations = rows[first..<index].filter { $0.observedAt >= start }.map {
                QuotaHistoryObservation(observedAt: $0.observedAt, remainingPercent: 100 - $0.usedPercent, resetsAt: $0.resetsAt)
            }
            guard index > 0 else { return (nil, observations) }
            let latest = rows[index - 1]
            // Carry a recent observation only within its known reset boundary.
            // Reopening an old disk cache never creates a new observation.
            let fresh = boundary.timeIntervalSince(latest.observedAt) <= 20 * 60
            let beforeReset = latest.resetsAt.map { boundary < $0 } ?? true
            return (fresh && beforeReset ? 100 - latest.usedPercent : observations.last?.remainingPercent, observations)
        }
        return (0..<Int(30 * 24 * 60 * 60 / interval)).map { offset in
            let date = Date(timeIntervalSince1970: start + Double(offset) * interval)
            let boundary = min(date.addingTimeInterval(interval - 0.000_001), now)
            let f = value(five, &fiveIndex, from: date, through: boundary)
            let s = value(seven, &sevenIndex, from: date, through: boundary)
            return QuotaHistoryRecentBucket(start: date, fiveHourRemainingPercent: f.0, sevenDayRemainingPercent: s.0,
                fiveHourObservations: f.1, sevenDayObservations: s.1)
        }
    }

    static func period(_ windowID: String) -> String? {
        switch windowID {
        case "5h", "gemini-5h", "3p-5h": "5h"
        case "7d", "gemini-weekly", "3p-weekly": "7d"
        default: nil
        }
    }

    static func pool(client: String, windowID: String) -> String? {
        guard period(windowID) != nil else { return nil }
        if client == "antigravity" {
            if windowID.hasPrefix("gemini-") { return "gemini" }
            if windowID.hasPrefix("3p-") { return "3p" }
            return nil
        }
        return ["claudeCode", "claudeDesktop"].contains(client) && ["5h", "7d"].contains(windowID) ? "" : nil
    }
}

struct ClientQuotaChartSource: Identifiable, Equatable {
    let client: String
    var pool = ""
    var historySource: String? = nil
    var id: String { (pool.isEmpty ? client : client + ":" + pool) + (historySource.map { "@" + $0 } ?? "") }
    var title: String {
        ClientDisplayScope.title(client) + (pool.isEmpty ? "" : " · " + (pool == "gemini" ? "Gemini" : "第三方模型"))
            + (historySource == nil ? "" : " · 历史采样")
    }
    static func options(clients: Set<String>, histories: [ClientQuotaHistory] = []) -> [Self] {
        let base = [Self(client: "codex"), Self(client: "claudeCode"), Self(client: "claudeDesktop"),
         Self(client: "antigravity", pool: "gemini"), Self(client: "antigravity", pool: "3p")].filter { clients.contains($0.client) }
        let earlier = base.flatMap { source in
            histories.filter { $0.client == source.client && $0.pool == source.pool }.dropFirst().map {
                Self(client: $0.client, pool: $0.pool, historySource: $0.source)
            }
        }
        return base + earlier
    }
    static func resolve(_ selection: String, clients: Set<String>, histories: [ClientQuotaHistory] = []) -> Self? {
        let choices = options(clients: clients, histories: histories)
        return choices.first { $0.id == selection } ?? choices.first
    }
    func history(in histories: [ClientQuotaHistory]) -> ClientQuotaHistory? {
        histories.first { $0.client == client && $0.pool == pool && (historySource == nil || $0.source == historySource) }
    }
}

extension MultiClientUsageLedger {
    /// Optional additive table in the existing v2 ledger. Older apps can still open
    /// the file and preserve this table. Codex's account/cycle database is untouched.
    func recordQuotaHistory(_ readings: [ClientQuotaReading], now: Date = Date()) throws {
        try database.transaction { connection in
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS client_quota_observations (
                    client TEXT NOT NULL, source TEXT NOT NULL, window_id TEXT NOT NULL,
                    observed_at REAL NOT NULL, used_percent REAL NOT NULL CHECK(used_percent>=0 AND used_percent<=100),
                    resets_at REAL, PRIMARY KEY(client,source,window_id,observed_at)
                ) WITHOUT ROWID
                """)
            try connection.execute("CREATE INDEX IF NOT EXISTS client_quota_observations_client_time ON client_quota_observations(client,observed_at)")
            try connection.execute("CREATE INDEX IF NOT EXISTS client_quota_observations_source_time ON client_quota_observations(client,source,observed_at)")
            for reading in readings {
                guard ["available", "stale", "cached"].contains(reading.state), reading.source != "unsupported",
                      let captured = reading.capturedAt, captured.timeIntervalSince1970 > 0,
                      captured <= now, captured >= now.addingTimeInterval(-30 * 24 * 60 * 60) else { continue }
                for window in reading.windows {
                    let id = window.id ?? window.label
                    guard ClientQuotaHistory.pool(client: reading.client, windowID: id) != nil,
                          window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                          window.resetsAt.map({ $0 > captured }) ?? true else { continue }
                    let bindings: [SQLiteBinding] = [.text(reading.client), .text(reading.source), .text(id)]
                    let previous = try connection.readRows("""
                        SELECT observed_at,used_percent,resets_at FROM client_quota_observations
                        WHERE client=? AND source=? AND window_id=? ORDER BY observed_at DESC LIMIT 1
                        """, bindings: bindings) { ($0.date(0)!, $0.double(1)!, $0.date(2)) }.first
                    if let previous, previous.1 == window.usedPercent, previous.2 == window.resetsAt,
                       previous.0 <= captured,
                       floor(previous.0.timeIntervalSince1970 / 300) == floor(captured.timeIntervalSince1970 / 300) { continue }
                    try connection.execute("""
                        INSERT INTO client_quota_observations(client,source,window_id,observed_at,used_percent,resets_at)
                        VALUES(?,?,?,?,?,?) ON CONFLICT(client,source,window_id,observed_at)
                        DO UPDATE SET used_percent=excluded.used_percent,resets_at=excluded.resets_at
                        """, bindings: bindings + [.date(captured), .double(window.usedPercent), .optionalDate(window.resetsAt)])
                }
            }
        }
    }

    func quotaHistory(readings: [ClientQuotaReading], now: Date = Date()) throws -> [ClientQuotaHistory] {
        let exists = try database.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='client_quota_observations'") { $0.int(0) }.first == 1
        guard exists else { return [] }
        var histories: [ClientQuotaHistory] = []
        for reading in readings {
            let rows = try database.readRows("""
                SELECT source,window_id,observed_at,used_percent,resets_at FROM client_quota_observations
                WHERE client=? AND observed_at>=? AND observed_at<=? ORDER BY observed_at DESC LIMIT 100001
                """, bindings: [.text(reading.client), .date(now.addingTimeInterval(-30 * 24 * 60 * 60)), .date(now)]) {
                    ($0.text(0)!, ClientQuotaHistorySample(windowID: $0.text(1)!, observedAt: $0.date(2)!, usedPercent: $0.double(3)!, resetsAt: $0.date(4)))
                }
            guard rows.count <= 100_000 else { throw ClientQuotaHistoryError.tooManySamples }
            let sources = [reading.source] + Set(rows.map(\.0)).subtracting([reading.source]).sorted()
            for source in sources {
                let current = rows.filter { $0.0 == source }.map(\.1).reversed()
                let pools = Dictionary(grouping: current) { ClientQuotaHistory.pool(client: reading.client, windowID: $0.windowID) ?? "" }
                for pool in pools.keys.sorted() {
                    histories.append(ClientQuotaHistory(client: reading.client, source: source, pool: pool, samples: pools[pool] ?? []))
                }
            }
        }
        return histories
    }
}

private enum ClientQuotaHistoryError: LocalizedError {
    case tooManySamples
    var errorDescription: String? { "本地额度采样超过读取上限，历史曲线暂不可用；原记录已保留。" }
}

extension ClaudeLocalQuota {
    /// Recover observations the client already recorded, limited to the latest
    /// organization in the file. This never assigns the file's mtime to a sample.
    static func desktopHistoryReadings(home: URL, now: Date = Date()) -> [ClientQuotaReading] {
        let url = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = LocalQuotaCacheFile.read(url, limit: desktopHistoryMaximumBytes),
              decodeDesktopHistory(data, now: now).state != "invalid",
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["samples"] as? [Any], values.count <= 50_000 else { return [] }
        let rows = values.compactMap { $0 as? [String: Any] }
        let latest = rows.enumerated().max { lhs, rhs in
            let before = lhs.element["t"] as? Double ?? -1, after = rhs.element["t"] as? Double ?? -1
            return before == after ? lhs.offset < rhs.offset : before < after
        }?.element
        guard let latest else { return [] }
        return rows.compactMap { row in
            guard row["org"] as? String == latest["org"] as? String,
                  let time = row["t"] as? Double, time / 1000 >= now.timeIntervalSince1970 - 30 * 24 * 60 * 60,
                  let sample = try? JSONSerialization.data(withJSONObject: ["version": root["version"]!, "samples": [row]]) else { return nil }
            let snapshot = decodeDesktopHistory(sample, now: now)
            guard snapshot.state == "available" else { return nil }
            return ClaudeCapturedQuotaProvider(snapshot: snapshot, client: .claudeDesktop).reading()
        }
    }
}
