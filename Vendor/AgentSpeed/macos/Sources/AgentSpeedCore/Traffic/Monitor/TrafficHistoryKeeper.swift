import Foundation
import os

/// Stored traffic days (METRICS 10.9): loads them once, upserts today's totals every 60 s, at the day change, on
/// flush and at stop, and merges today's unsaved part into what it publishes. The database is opened per write, so
/// "Clear history" deleting the file needs no coordination beyond `clear()`.
struct TrafficHistoryKeeper {
    static let writeIntervalMs: Int64 = 60_000
    static let publishIntervalMs: Int64 = 10_000
    private static let log = Logger(subsystem: "app.agentspeed", category: "traffic")

    let storePath: String
    private(set) var stored: [String: [TrafficDay]] = [:]
    private(set) var since: String?
    private var lastWriteMs: Int64?
    private var lastPublishMs: Int64?
    private var lastPublished: ([TrafficDay], String?)?

    init(storePath: String) {
        self.storePath = storePath
    }

    mutating func load() {
        let loaded = HistoryDatabase.storedTraffic(at: storePath)
        stored = Dictionary(grouping: loaded.days, by: \.day)
        since = loaded.since
    }

    func storedRows(of day: String) -> [TrafficDay] { stored[day] ?? [] }

    func isWriteDue(nowMs: Int64) -> Bool {
        lastWriteMs.map { nowMs - $0 >= Self.writeIntervalMs } ?? true
    }

    /// The first write happens a full interval after launch or a clear.
    mutating func deferWrites(nowMs: Int64) {
        lastWriteMs = nowMs
    }

    /// Upserts `rows` (one or more whole days); on failure they stay in memory and the next write retries.
    mutating func write(_ rows: [TrafficDay], nowMs: Int64) {
        lastWriteMs = nowMs
        guard !rows.isEmpty else { return }
        do {
            try HistoryDatabase.saveTraffic(rows, at: storePath)
            for (day, dayRows) in Dictionary(grouping: rows, by: \.day) { stored[day] = dayRows }
            if let first = rows.map(\.day).min(), since.map({ first < $0 }) ?? true { since = first }
        } catch {
            Self.log.error("Traffic rows could not be saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// "Clear history": nothing stored any more; the next write recreates today's rows.
    mutating func clear(nowMs: Int64) {
        stored = [:]
        since = nil
        lastWriteMs = nowMs
        lastPublished = nil
    }

    /// Stored days with `today`'s rows replaced by the in-memory ones, oldest first; nil when not due (every 10 s,
    /// or `force`) or unchanged.
    mutating func daysToPublish(today: String, rows: [TrafficDay], nowMs: Int64, force: Bool) -> ([TrafficDay], String?)? {
        guard force || lastPublishMs.map({ nowMs - $0 >= Self.publishIntervalMs }) ?? true else { return nil }
        lastPublishMs = nowMs
        var merged = stored
        if !rows.isEmpty { merged[today] = rows }
        let days = merged.keys.sorted().flatMap { day in Self.ordered(merged[day] ?? []) }
        let first = since ?? (rows.isEmpty ? nil : today)
        let result = (days, first)
        if let lastPublished, lastPublished.0 == result.0, lastPublished.1 == result.1 { return nil }
        lastPublished = result
        return result
    }

    /// `machine` first, then sources in their declared order.
    private static func ordered(_ rows: [TrafficDay]) -> [TrafficDay] {
        rows.sorted { rank($0.key) < rank($1.key) }
    }

    private static func rank(_ key: String) -> Int {
        if key == TrafficDay.machineKey { return -1 }
        return SourceKind.allCases.firstIndex { $0.rawValue == key } ?? SourceKind.allCases.count
    }
}
