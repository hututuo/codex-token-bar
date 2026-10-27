import Foundation
import os

/// `<app data>/prices/sync.json` (NETWORK 3). `version`, `updated`, `url` and `etag` describe the last valid table
/// downloaded (whether or not it became current); `failures` counts consecutive failed rounds for the retry rule.
public struct PriceSyncState: Codable, Equatable, Sendable {
    public var version: Int?
    public var updated: String?
    public var url: String?
    public var etag: String?
    public var lastSuccessMs: Int64?
    public var lastAttemptMs: Int64?
    public var lastError: String?
    public var failures: Int

    public init(
        version: Int? = nil, updated: String? = nil, url: String? = nil, etag: String? = nil, lastSuccessMs: Int64? = nil,
        lastAttemptMs: Int64? = nil, lastError: String? = nil, failures: Int = 0
    ) {
        self.version = version
        self.updated = updated
        self.url = url
        self.etag = etag
        self.lastSuccessMs = lastSuccessMs
        self.lastAttemptMs = lastAttemptMs
        self.lastError = lastError
        self.failures = failures
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        updated = try container.decodeIfPresent(String.self, forKey: .updated)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastSuccessMs = try container.decodeIfPresent(Int64.self, forKey: .lastSuccessMs)
        lastAttemptMs = try container.decodeIfPresent(Int64.self, forKey: .lastAttemptMs)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        failures = try container.decodeIfPresent(Int.self, forKey: .failures) ?? 0
    }
}

/// What one sync round (or a manual check) found.
public enum PriceSyncOutcome: Equatable, Sendable {
    case upToDate
    case updated(version: Int)
    /// Only tables of a newer schema were offered: this build needs an update to use them.
    case newerSchema
    case failed(reason: String)
}

public struct PriceSyncResult: Sendable {
    public var outcome: PriceSyncOutcome
    /// The table that became current; deliver it to `PriceBook.add`.
    public var table: PriceTable?
    public var state: PriceSyncState
}

/// The synced price table on disk: `<app data>/prices/prices.json` and `sync.json`, written atomically.
public struct PriceTableStore: Sendable {
    static let logger = Logger(subsystem: "io.github.zoefix.agentspeed", category: "prices")

    public let directory: URL

    /// `appDataDirectory` is `~/Library/Application Support/AgentSpeed`.
    public init(appDataDirectory: URL) {
        directory = appDataDirectory.appendingPathComponent("prices", isDirectory: true)
    }

    public var tableURL: URL { directory.appendingPathComponent("prices.json") }
    public var stateURL: URL { directory.appendingPathComponent("sync.json") }

    /// The stored table, validated again; an invalid copy is deleted (logged) so the bundled table is used.
    public func loadTable() -> PriceTable? {
        guard let data = try? Data(contentsOf: tableURL) else { return nil }
        switch PriceTable.load(data) {
        case .success(let table):
            return table
        case .failure(let error):
            Self.logger.error("Stored price table is invalid (\(Self.describe(error), privacy: .public)); deleted")
            try? FileManager.default.removeItem(at: tableURL)
            return nil
        }
    }

    public func loadState() -> PriceSyncState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PriceSyncState.self, from: data) else { return PriceSyncState() }
        return state
    }

    public func save(tableData data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: tableURL, options: .atomic)
    }

    public func save(state: PriceSyncState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    static func describe(_ error: PriceTableError) -> String {
        switch error {
        case .tooLarge: "too large"
        case .notJSON: "not a JSON object"
        case .unsupportedSchema(let schema): "schema \(schema.map(String.init) ?? "missing")"
        case .invalid(let errors): "\(errors.count) validation errors, first: \(errors.first ?? "")"
        }
    }
}

/// The daily price-table sync of NETWORK 3: GitHub raw first, the jsDelivr mirror second, every download validated
/// like `spec/tools/prices.py`, never a downgrade.
public struct PriceTableSync: Sendable {
    public static let urls = [
        URL(string: "https://raw.githubusercontent.com/zoefix/agent-speed/main/spec/assets/prices.json")!,
        URL(string: "https://cdn.jsdelivr.net/gh/zoefix/agent-speed@main/spec/assets/prices.json")!,
    ]
    public static let allowedHosts: Set<String> = ["raw.githubusercontent.com", "cdn.jsdelivr.net"]
    /// Where Settings' `prices.viewSource` link points.
    public static let sourcePage = URL(string: "https://github.com/zoefix/agent-speed/blob/main/spec/assets/prices.json")!

    public static let launchDelay: TimeInterval = 60
    public static let interval: TimeInterval = 24 * 3600
    public static let retryDelay: TimeInterval = 3600
    /// The schedule is re-checked at least this often (and on wake).
    public static let checkInterval: TimeInterval = 3600
    /// A table's `updated` may be at most this many days after the local date.
    public static let maxUpdatedAheadDays = 2

    let store: PriceTableStore
    let transport: any HTTPTransport
    let userAgent: String
    let timeZone: TimeZone
    let now: @Sendable () -> Date

    public init(
        store: PriceTableStore,
        transport: any HTTPTransport,
        userAgent: String,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.transport = transport
        self.userAgent = userAgent
        self.timeZone = timeZone
        self.now = now
    }

    /// The next automatic round: 60 s after launch, then 24 h after the last success; a failed round retries once
    /// after 1 h and then follows the daily rhythm. Stamps in the future (clock moved back) count as now.
    public static func nextAttempt(launchedAt: Date, state: PriceSyncState, now: Date) -> Date {
        let earliest = launchedAt.addingTimeInterval(launchDelay)
        func clamped(_ ms: Int64) -> Date { min(Date(timeIntervalSince1970: TimeInterval(ms) / 1000), now) }
        if state.failures > 0, let attempt = state.lastAttemptMs {
            let delay = state.failures == 1 ? retryDelay : interval
            return max(earliest, clamped(attempt).addingTimeInterval(delay))
        }
        if let success = state.lastSuccessMs { return max(earliest, clamped(success).addingTimeInterval(interval)) }
        return earliest
    }

    /// One round: tries each URL until one answers with a usable table (or `304`). `currentVersion` is the higher
    /// of the bundled and the stored table.
    public func run(currentVersion: Int) async -> PriceSyncResult {
        var state = store.loadState()
        let started = now()
        let startedMs = Self.milliseconds(started)
        state.lastAttemptMs = startedMs
        var failure = "no response"
        var sawNewerSchema = false
        for url in Self.urls {
            let host = url.host() ?? "?"
            // A 304 means "the table behind this ETag", which is only worth knowing when it is not newer than ours.
            let etag = state.url == url.absoluteString && (state.version.map { $0 <= currentVersion } ?? false) ? state.etag : nil
            let request = HTTPFetchRequest(
                url: url, accept: "application/json", ifNoneMatch: etag, userAgent: userAgent,
                maxBytes: PriceTable.maxBytes, allowedHosts: Self.allowedHosts
            )
            let response: HTTPFetchResponse
            do {
                response = try await transport.get(request)
            } catch {
                failure = (error as? HTTPFetchError)?.reason ?? "transport error"
                PriceTableStore.logger.notice("Price table \(host, privacy: .public): \(failure, privacy: .public)")
                continue
            }
            if response.status == 304 {
                PriceTableStore.logger.notice("Price table \(host, privacy: .public): 304, unchanged")
                return finish(&state, outcome: .upToDate, table: nil)
            }
            guard (200..<300).contains(response.status) else {
                failure = "HTTP \(response.status)"
                PriceTableStore.logger.notice("Price table \(host, privacy: .public): HTTP \(response.status)")
                continue
            }
            let table: PriceTable
            switch PriceTable.load(response.body) {
            case .success(let loaded):
                table = loaded
            case .failure(let error):
                if error.isNewerSchema {
                    sawNewerSchema = true
                } else {
                    failure = "invalid table"
                }
                PriceTableStore.logger.notice(
                    "Price table \(host, privacy: .public): \(response.body.count) bytes rejected (\(PriceTableStore.describe(error), privacy: .public))")
                continue
            }
            guard isAcceptableUpdated(table.updated, at: started) else {
                failure = "table dated in the future"
                PriceTableStore.logger.notice("Price table \(host, privacy: .public): updated \(table.updated, privacy: .public) is in the future")
                continue
            }
            state.version = table.version
            state.updated = table.updated
            state.url = url.absoluteString
            state.etag = response.etag
            guard table.version > currentVersion else {
                PriceTableStore.logger.notice(
                    "Price table \(host, privacy: .public): v\(table.version) (\(response.body.count) bytes), current is v\(currentVersion)")
                return finish(&state, outcome: .upToDate, table: nil)
            }
            do {
                try store.save(tableData: response.body)
            } catch {
                failure = "could not save"
                PriceTableStore.logger.error("Price table v\(table.version) could not be saved")
                state.version = nil
                state.etag = nil
                continue
            }
            PriceTableStore.logger.notice(
                "Price table \(host, privacy: .public): updated to v\(table.version) (\(response.body.count) bytes)")
            return finish(&state, outcome: .updated(version: table.version), table: table)
        }
        if sawNewerSchema {
            PriceTableStore.logger.notice("Price table: only a newer schema is offered; this build needs an update")
            return finish(&state, outcome: .newerSchema, table: nil)
        }
        state.failures += 1
        state.lastError = failure
        try? store.save(state: state)
        return PriceSyncResult(outcome: .failed(reason: failure), table: nil, state: state)
    }

    private func finish(_ state: inout PriceSyncState, outcome: PriceSyncOutcome, table: PriceTable?) -> PriceSyncResult {
        state.lastSuccessMs = state.lastAttemptMs
        state.failures = 0
        state.lastError = nil
        try? store.save(state: state)
        return PriceSyncResult(outcome: outcome, table: table, state: state)
    }

    /// Check 5: `updated` is at most two days after the local date.
    func isAcceptableUpdated(_ updated: String, at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let limit = calendar.date(byAdding: .day, value: Self.maxUpdatedAheadDays, to: date) else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: limit)
        let text = String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return updated <= text
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
