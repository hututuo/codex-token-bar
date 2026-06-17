import Foundation

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

    func normalizedForDisplay(_ quota: AccountQuotaSnapshot) async -> AccountQuotaSnapshot {
        guard quota.isAvailable else { return quota }
        let database = database
        return (try? await Task.detached(priority: .utility) {
            try database.normalizedSnapshot(quota)
        }.value) ?? quota
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

    func normalized(after previous: QuotaHistoryRow?) -> QuotaHistoryRow {
        guard let previous else { return self }
        return QuotaHistoryRow(
            createdAt: createdAt,
            accountKey: accountKey,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            fiveHourUsedPercent: QuotaMonotonicNormalizer.normalizedUsedPercent(
                currentUsedPercent: fiveHourUsedPercent,
                currentResetsAt: fiveHourResetsAt,
                previousUsedPercent: previous.fiveHourUsedPercent,
                previousResetsAt: previous.fiveHourResetsAt
            ),
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayUsedPercent: QuotaMonotonicNormalizer.normalizedUsedPercent(
                currentUsedPercent: sevenDayUsedPercent,
                currentResetsAt: sevenDayResetsAt,
                previousUsedPercent: previous.sevenDayUsedPercent,
                previousResetsAt: previous.sevenDayResetsAt
            ),
            sevenDayResetsAt: sevenDayResetsAt,
            status: status
        )
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
        let row = Self.row(from: quota, createdAt: now)

        try withDatabase { database in
            try ensureSchema(database)
            let latest = try latestTrustedRow(database: database, accountKey: row.accountKey)
            let normalizedRow = row.normalized(after: latest)
            if let latest,
               !shouldInsert(normalizedRow, after: latest, now: now) {
                return
            }
            try insert(normalizedRow, database: database)
            try prune(database: database, now: now)
        }
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) throws -> AccountQuotaSnapshot {
        let row = Self.row(from: quota, createdAt: Date())
        return try withDatabase { database in
            try ensureSchema(database)
            let latest = try latestTrustedRow(database: database, accountKey: row.accountKey)
            let normalizedRow = row.normalized(after: latest)
            return Self.snapshot(from: normalizedRow, base: quota)
        }
    }

    func loadSnapshot() throws -> QuotaHistorySnapshot {
        try withDatabase { database in
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
        let sorted = sanitizedRows(rows.sorted { $0.createdAt < $1.createdAt })
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

    private static func sanitizedRows(_ rows: [QuotaHistoryRow]) -> [QuotaHistoryRow] {
        var lastByAccount: [String: QuotaHistoryRow] = [:]
        return rows.map { row in
            let normalized = row.normalized(after: lastByAccount[row.accountKey])
            lastByAccount[row.accountKey] = normalized
            return normalized
        }
    }

    private static func row(from quota: AccountQuotaSnapshot, createdAt: Date) -> QuotaHistoryRow {
        QuotaHistoryRow(
            createdAt: createdAt,
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
    }

    private static func snapshot(from row: QuotaHistoryRow, base quota: AccountQuotaSnapshot) -> AccountQuotaSnapshot {
        var adjusted = quota
        adjusted.fiveHour = window(label: "5h", usedPercent: row.fiveHourUsedPercent, resetsAt: row.fiveHourResetsAt)
        adjusted.sevenDay = window(label: "7d", usedPercent: row.sevenDayUsedPercent, resetsAt: row.sevenDayResetsAt)
        return adjusted
    }

    private static func window(label: String, usedPercent: Int?, resetsAt: Date?) -> AccountQuotaWindow? {
        guard let usedPercent else { return nil }
        return AccountQuotaWindow(label: label, usedPercent: usedPercent, resetsAt: resetsAt)
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

    private func ensureSchema(_ database: SQLiteDatabaseConnection) throws {
        try database.execute(
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
            """
        )
        try ensureColumn("five_hour_resets_at", definition: "REAL", database: database)
        try ensureColumn("seven_day_resets_at", definition: "REAL", database: database)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_created_at ON quota_snapshots(created_at);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_account_created ON quota_snapshots(account_key, created_at);")
    }

    private func insert(_ row: QuotaHistoryRow, database: SQLiteDatabaseConnection) throws {
        let sql = """
        INSERT INTO quota_snapshots (
            created_at, account_key, plan_type, limit_name, account_name,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try database.execute(sql, bindings: [
            .date(row.createdAt),
            .text(row.accountKey),
            .optionalText(row.planType),
            .optionalText(row.limitName),
            .optionalText(row.accountName),
            .optionalInt(row.fiveHourUsedPercent),
            .optionalDate(row.fiveHourResetsAt),
            .optionalInt(row.sevenDayUsedPercent),
            .optionalDate(row.sevenDayResetsAt),
            .text(row.status)
        ])
    }

    private func latestTrustedRow(database: SQLiteDatabaseConnection, accountKey: String) throws -> QuotaHistoryRow? {
        let rawRows = try rows(
            database: database,
            sql: """
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE account_key = ?
            ORDER BY created_at DESC;
            """,
            bindings: [.text(accountKey)]
        )
        return Self.sanitizedRows(Array(rawRows.reversed())).last
    }

    private func recentRows(database: SQLiteDatabaseConnection) throws -> [QuotaHistoryRow] {
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
            bindings: [.text(accountKey), .double(cutoff)]
        )
    }

    private func latestAccountKey(database: SQLiteDatabaseConnection) throws -> String? {
        let sql = "SELECT account_key FROM quota_snapshots ORDER BY created_at DESC LIMIT 1;"
        return try database.readRows(sql) { statement in
            statement.text(0)
        }
        .compactMap { $0 }
        .first
    }

    private func rows(database: SQLiteDatabaseConnection, sql: String, bindings: [SQLiteBinding]) throws -> [QuotaHistoryRow] {
        try database.readRows(sql, bindings: bindings) { statement in
            QuotaHistoryRow(
                createdAt: statement.date(0) ?? Date(timeIntervalSince1970: 0),
                accountKey: statement.text(1) ?? "default",
                planType: statement.text(2),
                limitName: statement.text(3),
                accountName: statement.text(4),
                fiveHourUsedPercent: statement.int(5),
                fiveHourResetsAt: statement.date(6),
                sevenDayUsedPercent: statement.int(7),
                sevenDayResetsAt: statement.date(8),
                status: statement.text(9) ?? ""
            )
        }
    }

    private func prune(database: SQLiteDatabaseConnection, now: Date) throws {
        let cutoff = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60)).timeIntervalSince1970
        let sql = "DELETE FROM quota_snapshots WHERE created_at < ?;"
        try database.execute(sql, bindings: [.double(cutoff)])
    }

    private func withDatabase<T>(_ work: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        guard let url = Self.databaseURL else {
            throw NSError(domain: "CodexTokenBar", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Unable to locate Application Support"])
        }
        let driver = SQLiteDatabaseDriver(
            url: url,
            readOnly: false,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: true,
            fileManager: fileManager
        )
        return try driver.transaction(work)
    }

    private func ensureColumn(_ name: String, definition: String, database: SQLiteDatabaseConnection) throws {
        let columns = try database.readRows("PRAGMA table_info(quota_snapshots);") { statement in
            statement.text(1) ?? ""
        }
        guard !columns.contains(name) else { return }
        try database.execute("ALTER TABLE quota_snapshots ADD COLUMN \(name) \(definition);")
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
