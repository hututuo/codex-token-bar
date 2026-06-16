import Foundation
import SQLite3

@MainActor
final class QuotaHistoryStore: ObservableObject {
    @Published private(set) var snapshot: QuotaHistorySnapshot = .empty

    private let database = QuotaHistoryDatabase()

    func start() {
        reload()
    }

    func reload() {
        Task.detached(priority: .utility) {
            let loaded = (try? self.database.loadSnapshot()) ?? .empty
            await MainActor.run {
                self.snapshot = loaded
            }
        }
    }

    func record(_ quota: AccountQuotaSnapshot) {
        guard quota.isAvailable else { return }
        Task.detached(priority: .utility) {
            do {
                try self.database.record(quota)
                let loaded = try self.database.loadSnapshot()
                await MainActor.run {
                    self.snapshot = loaded
                }
            } catch {
                // Quota history is helpful context, not the source of truth for quota display.
            }
        }
    }
}

private struct QuotaHistoryRow {
    let createdAt: Date
    let accountKey: String
    let planType: String?
    let limitName: String?
    let accountName: String?
    let fiveHourUsedPercent: Int?
    let fiveHourResetsAt: Date?
    let sevenDayUsedPercent: Int?
    let sevenDayResetsAt: Date?
    let status: String

    var fiveHourRemainingPercent: Double? {
        fiveHourUsedPercent.map { Double(max(0, min(100, 100 - $0))) }
    }

    var sevenDayRemainingPercent: Double? {
        sevenDayUsedPercent.map { Double(max(0, min(100, 100 - $0))) }
    }
}

private final class QuotaHistoryDatabase: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let heartbeatInterval: TimeInterval = 60 * 60
    private let retentionDays = 45
    private let recentInterval: TimeInterval = 5 * 60
    private let maxCarryGap: TimeInterval = 90 * 60

    func record(_ quota: AccountQuotaSnapshot) throws {
        let now = Date()
        let row = QuotaHistoryRow(
            createdAt: now,
            accountKey: Self.accountKey(for: quota),
            planType: quota.planType,
            limitName: quota.limitName,
            accountName: quota.accountName,
            fiveHourUsedPercent: quota.fiveHour?.usedPercent,
            fiveHourResetsAt: quota.fiveHour?.resetsAt,
            sevenDayUsedPercent: quota.sevenDay?.usedPercent,
            sevenDayResetsAt: quota.sevenDay?.resetsAt,
            status: quota.status
        )

        try withDatabase(flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { database in
            try ensureSchema(database)
            if let latest = try latestRow(database: database, accountKey: row.accountKey),
               !shouldInsert(row, after: latest, now: now) {
                return
            }
            try insert(row, database: database)
            try prune(database: database, now: now)
        }
    }

    func loadSnapshot() throws -> QuotaHistorySnapshot {
        try withDatabase(flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { database in
            try ensureSchema(database)
            let rows = try recentRows(database: database)
            return Self.makeSnapshot(rows: rows, recentInterval: recentInterval, maxCarryGap: maxCarryGap)
        }
    }

    private func shouldInsert(_ row: QuotaHistoryRow, after latest: QuotaHistoryRow, now: Date) -> Bool {
        if row.accountKey != latest.accountKey { return true }
        if row.fiveHourUsedPercent != latest.fiveHourUsedPercent { return true }
        if row.sevenDayUsedPercent != latest.sevenDayUsedPercent { return true }
        if row.fiveHourResetsAt != latest.fiveHourResetsAt { return true }
        if row.sevenDayResetsAt != latest.sevenDayResetsAt { return true }
        if row.planType != latest.planType || row.limitName != latest.limitName || row.accountName != latest.accountName { return true }
        return now.timeIntervalSince(latest.createdAt) >= heartbeatInterval
    }

    private static func makeSnapshot(rows: [QuotaHistoryRow], recentInterval: TimeInterval, maxCarryGap: TimeInterval) -> QuotaHistorySnapshot {
        let calendar = Calendar.current
        let now = Date()
        guard let recentStart = calendar.date(byAdding: .hour, value: -24, to: now) else {
            return .empty
        }

        let intervalCount = 288
        let sorted = rows.sorted { $0.createdAt < $1.createdAt }
        let recentBins = makeCarriedBins(
            rows: sorted,
            start: recentStart,
            count: intervalCount,
            interval: recentInterval,
            maxCarryGap: maxCarryGap
        )

        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let hourlyStart = calendar.date(byAdding: .hour, value: -719, to: currentHour) ?? currentHour
        let hourlyBins = makeCarriedBins(
            rows: sorted,
            start: hourlyStart,
            count: 720,
            interval: 60 * 60,
            maxCarryGap: maxCarryGap
        )

        let startDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -29, to: now) ?? now)
        var grouped: [Date: [QuotaHistoryRow]] = [:]
        for row in sorted where row.createdAt >= startDay {
            grouped[calendar.startOfDay(for: row.createdAt), default: []].append(row)
        }
        let daily = (0..<30).compactMap { offset -> QuotaHistoryDailyBucket? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            let dayRows = grouped[date] ?? []
            let fiveValues = dayRows.compactMap(\.fiveHourRemainingPercent)
            let sevenValues = dayRows.compactMap(\.sevenDayRemainingPercent)
            return QuotaHistoryDailyBucket(
                date: date,
                fiveHourRemainingPercent: Self.average(fiveValues),
                sevenDayRemainingPercent: Self.average(sevenValues),
                sampleCount: dayRows.count
            )
        }

        return QuotaHistorySnapshot(daily: daily, recentBins: recentBins, hourlyBins: hourlyBins, latest: sorted.last?.createdAt)
    }

    private static func makeCarriedBins(
        rows: [QuotaHistoryRow],
        start: Date,
        count: Int,
        interval: TimeInterval,
        maxCarryGap: TimeInterval
    ) -> [QuotaHistoryRecentBucket] {
        var rowIndex = 0
        var latestRow: QuotaHistoryRow?

        return (0..<count).map { index -> QuotaHistoryRecentBucket in
            let binStart = start.addingTimeInterval(Double(index) * interval)
            let end = binStart.addingTimeInterval(interval)

            while rowIndex < rows.count, rows[rowIndex].createdAt <= end {
                latestRow = rows[rowIndex]
                rowIndex += 1
            }

            return QuotaHistoryRecentBucket(
                start: binStart,
                fiveHourRemainingPercent: quotaRemaining(
                    from: latestRow,
                    at: end,
                    maxCarryGap: maxCarryGap,
                    remaining: \.fiveHourRemainingPercent,
                    resetsAt: \.fiveHourResetsAt
                ),
                sevenDayRemainingPercent: quotaRemaining(
                    from: latestRow,
                    at: end,
                    maxCarryGap: maxCarryGap,
                    remaining: \.sevenDayRemainingPercent,
                    resetsAt: \.sevenDayResetsAt
                )
            )
        }
    }

    private static func quotaRemaining(
        from row: QuotaHistoryRow?,
        at date: Date,
        maxCarryGap: TimeInterval,
        remaining: KeyPath<QuotaHistoryRow, Double?>,
        resetsAt: KeyPath<QuotaHistoryRow, Date?>
    ) -> Double? {
        guard let row, let value = row[keyPath: remaining] else { return nil }

        if let resetDate = row[keyPath: resetsAt] {
            if date >= resetDate {
                return 100
            }
            return value
        }

        guard date.timeIntervalSince(row.createdAt) <= maxCarryGap else {
            return nil
        }
        return value
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func ensureSchema(_ database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS quota_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                account_key TEXT NOT NULL,
                plan_type TEXT,
                limit_name TEXT,
                account_name TEXT,
                five_hour_used_percent INTEGER,
                five_hour_resets_at REAL,
                seven_day_used_percent INTEGER,
                seven_day_resets_at REAL,
                status TEXT NOT NULL
            );
            """,
            database: database
        )
        try ensureColumn("five_hour_resets_at", definition: "REAL", database: database)
        try ensureColumn("seven_day_resets_at", definition: "REAL", database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_created_at ON quota_snapshots(created_at);", database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_account_created ON quota_snapshots(account_key, created_at);", database: database)
    }

    private func insert(_ row: QuotaHistoryRow, database: OpaquePointer) throws {
        let sql = """
        INSERT INTO quota_snapshots (
            created_at, account_key, plan_type, limit_name, account_name,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }

        bindDouble(row.createdAt.timeIntervalSince1970, statement: statement, index: 1)
        bindText(row.accountKey, statement: statement, index: 2)
        bindText(row.planType, statement: statement, index: 3)
        bindText(row.limitName, statement: statement, index: 4)
        bindText(row.accountName, statement: statement, index: 5)
        bindInt(row.fiveHourUsedPercent, statement: statement, index: 6)
        bindDate(row.fiveHourResetsAt, statement: statement, index: 7)
        bindInt(row.sevenDayUsedPercent, statement: statement, index: 8)
        bindDate(row.sevenDayResetsAt, statement: statement, index: 9)
        bindText(row.status, statement: statement, index: 10)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(database)
        }
    }

    private func latestRow(database: OpaquePointer, accountKey: String) throws -> QuotaHistoryRow? {
        try rows(
            database: database,
            sql: """
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE account_key = ?
            ORDER BY created_at DESC
            LIMIT 1;
            """,
            bindings: [accountKey]
        ).first
    }

    private func recentRows(database: OpaquePointer) throws -> [QuotaHistoryRow] {
        guard let accountKey = try latestAccountKey(database: database) else { return [] }
        let cutoff = Date().addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970
        return try rows(
            database: database,
            sql: """
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE account_key = ? AND created_at >= ?
            ORDER BY created_at ASC;
            """,
            bindings: [accountKey, String(cutoff)]
        )
    }

    private func latestAccountKey(database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT account_key FROM quota_snapshots ORDER BY created_at DESC LIMIT 1;"
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func rows(database: OpaquePointer, sql: String, bindings: [String]) throws -> [QuotaHistoryRow] {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
        }

        var result: [QuotaHistoryRow] = []
        while true {
            let stepStatus = sqlite3_step(statement)
            if stepStatus == SQLITE_ROW {
                result.append(QuotaHistoryRow(
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    accountKey: text(statement, 1) ?? "default",
                    planType: text(statement, 2),
                    limitName: text(statement, 3),
                    accountName: text(statement, 4),
                    fiveHourUsedPercent: nullableInt(statement, 5),
                    fiveHourResetsAt: nullableDate(statement, 6),
                    sevenDayUsedPercent: nullableInt(statement, 7),
                    sevenDayResetsAt: nullableDate(statement, 8),
                    status: text(statement, 9) ?? ""
                ))
            } else if stepStatus == SQLITE_DONE {
                break
            } else {
                throw sqliteError(database)
            }
        }
        return result
    }

    private func prune(database: OpaquePointer, now: Date) throws {
        let cutoff = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60)).timeIntervalSince1970
        var statement: OpaquePointer?
        let sql = "DELETE FROM quota_snapshots WHERE created_at < ?;"
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(database)
        }
    }

    private func withDatabase<T>(flags: Int32, _ work: (OpaquePointer) throws -> T) throws -> T {
        guard let url = Self.databaseURL else {
            throw NSError(domain: "CodexTokenBar", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Unable to locate Application Support"])
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open quota history database"
            if let database {
                sqlite3_close(database)
            }
            throw NSError(domain: "CodexTokenBar", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        return try work(database)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw NSError(domain: "CodexTokenBar", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func ensureColumn(_ name: String, definition: String, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, "PRAGMA table_info(quota_snapshots);", -1, &statement, nil)
        guard prepareStatus == SQLITE_OK else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == name {
                return
            }
        }

        try execute("ALTER TABLE quota_snapshots ADD COLUMN \(name) \(definition);", database: database)
    }

    private func sqliteError(_ database: OpaquePointer) -> NSError {
        NSError(domain: "CodexTokenBar", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }

    private func bindText(_ value: String?, statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindInt(_ value: Int?, statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func bindDate(_ value: Date?, statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func bindDouble(_ value: Double, statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_double(statement, index, value)
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    private func nullableInt(_ statement: OpaquePointer?, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    private func nullableDate(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static var databaseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexTokenBar", isDirectory: true)
            .appendingPathComponent("quota-history.sqlite")
    }

    private static func accountKey(for quota: AccountQuotaSnapshot) -> String {
        let parts = [quota.accountName, quota.planType, quota.limitName]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        return parts.isEmpty ? "default" : parts.joined(separator: "|")
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
