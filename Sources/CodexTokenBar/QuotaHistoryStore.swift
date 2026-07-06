import Foundation

protocol QuotaHistoryLoading: Sendable {
    func loadSnapshot() async throws -> QuotaHistorySnapshot
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot
    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot
}

struct LiveQuotaHistoryClient: QuotaHistoryLoading {
    private let database: QuotaHistoryDatabase

    init(database: QuotaHistoryDatabase = QuotaHistoryDatabase()) {
        self.database = database
    }

    func loadSnapshot() async throws -> QuotaHistorySnapshot {
        let database = database
        return try await Task.detached(priority: .utility) {
            try database.loadSnapshot()
        }.value
    }

    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        let database = database
        return try await Task.detached(priority: .utility) {
            try database.record(quota)
            return try database.loadSnapshot()
        }.value
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot {
        let database = database
        return try await Task.detached(priority: .utility) {
            try database.normalizedSnapshot(quota)
        }.value
    }
}

@MainActor
final class QuotaHistoryStore: ObservableObject {
    @Published private(set) var snapshot: QuotaHistorySnapshot = .empty

    private let historyClient: any QuotaHistoryLoading
    private var operationTask: Task<Void, Never>?
    private var operationGeneration = 0

    init(historyClient: any QuotaHistoryLoading = LiveQuotaHistoryClient()) {
        self.historyClient = historyClient
    }

    deinit {
        operationTask?.cancel()
    }

    func start() {
        reload()
    }

    func reload() {
        operationTask?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        let trace = RefreshPerformanceProbe.begin("quotaHistory.reload")
        let historyClient = historyClient
        operationTask = Task {
            trace?.mark("database.loadSnapshot.begin")
            do {
                let loaded = try await historyClient.loadSnapshot()
                trace?.mark("database.loadSnapshot.end", metadata: [
                    "daily": String(loaded.daily.count),
                    "recent": String(loaded.recentBins.count),
                    "hourly": String(loaded.hourlyBins.count)
                ])
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-after-load")
                    return
                }
                snapshot = loaded
                trace?.end("ok")
            } catch {
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-failed", metadata: ["error": error.localizedDescription])
                    return
                }
                trace?.end("failed", metadata: ["error": error.localizedDescription])
            }
        }
    }

    func record(_ quota: AccountQuotaSnapshot) {
        guard quota.isAvailable else { return }
        operationTask?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        let trace = RefreshPerformanceProbe.begin("quotaHistory.record", metadata: [
            "fiveHour": quota.fiveHour.map { String(format: "%.2f", $0.remainingPercent) } ?? "nil",
            "sevenDay": quota.sevenDay.map { String(format: "%.2f", $0.remainingPercent) } ?? "nil"
        ])
        let historyClient = historyClient
        operationTask = Task {
            do {
                trace?.mark("database.recordAndLoadSnapshot.begin")
                let loaded = try await historyClient.recordAndLoadSnapshot(quota)
                trace?.mark("database.recordAndLoadSnapshot.end", metadata: [
                    "daily": String(loaded.daily.count),
                    "recent": String(loaded.recentBins.count),
                    "hourly": String(loaded.hourlyBins.count)
                ])
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-after-record")
                    return
                }
                snapshot = loaded
                trace?.end("ok")
            } catch {
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-record-failed", metadata: ["error": error.localizedDescription])
                    return
                }
                trace?.end("failed", metadata: ["error": error.localizedDescription])
                // Quota history is helpful context, not the source of truth for quota display.
            }
        }
    }

    func normalizedForDisplay(_ quota: AccountQuotaSnapshot) async -> AccountQuotaSnapshot {
        guard quota.isAvailable else { return quota }
        let trace = RefreshPerformanceProbe.begin("quotaHistory.normalizedForDisplay")
        trace?.mark("database.normalizedSnapshot.begin")
        let normalized = (try? await historyClient.normalizedSnapshot(quota)) ?? quota
        trace?.mark("database.normalizedSnapshot.end")
        trace?.end("ok")
        return normalized
    }

    private func isCurrentOperation(generation: Int) -> Bool {
        operationGeneration == generation
    }
}

private struct QuotaHistoryRow {
    fileprivate static let resetGraceInterval: TimeInterval = 2 * 60

    let createdAt: Date
    let accountKey: String
    let source: String?
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
            source: source,
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

    func replacing(fiveHourUsedPercent: Int? = nil, sevenDayUsedPercent: Int? = nil) -> QuotaHistoryRow {
        QuotaHistoryRow(
            createdAt: createdAt,
            accountKey: accountKey,
            source: source,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            fiveHourUsedPercent: fiveHourUsedPercent ?? self.fiveHourUsedPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayUsedPercent: sevenDayUsedPercent ?? self.sevenDayUsedPercent,
            sevenDayResetsAt: sevenDayResetsAt,
            status: status
        )
    }

    func isSameFiveHourCycle(as other: QuotaHistoryRow) -> Bool {
        Self.isSameObservedCycle(lhs: fiveHourResetsAt, rhs: other.fiveHourResetsAt)
    }

    func isSameSevenDayCycle(as other: QuotaHistoryRow) -> Bool {
        Self.isSameObservedCycle(lhs: sevenDayResetsAt, rhs: other.sevenDayResetsAt)
    }

    private static func isSameObservedCycle(lhs: Date?, rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) <= resetGraceInterval
        case (nil, nil):
            return true
        case (_?, nil), (nil, _?):
            return false
        }
    }
}

private struct QuotaHistorySpikeEntry {
    let index: Int
    let usedPercent: Int
}

final class QuotaHistoryDatabase: @unchecked Sendable {
    private let fileManager: FileManager
    private let databaseURL: URL?
    private let heartbeatInterval: TimeInterval = 60 * 60
    private let retentionDays = 45
    private let recentInterval: TimeInterval = 5 * 60
    private let maxCarryGap: TimeInterval = 90 * 60

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    func record(_ quota: AccountQuotaSnapshot, createdAt: Date = Date()) throws {
        let now = createdAt
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

    func loadSnapshot(now: Date = Date()) throws -> QuotaHistorySnapshot {
        try withDatabase { database in
            try ensureSchema(database)
            let rows = try recentRows(database: database, now: now)
            return Self.makeSnapshot(rows: rows, recentInterval: recentInterval, maxCarryGap: maxCarryGap, now: now)
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

    private static func makeSnapshot(rows: [QuotaHistoryRow], recentInterval: TimeInterval, maxCarryGap: TimeInterval, now: Date = Date()) -> QuotaHistorySnapshot {
        let calendar = Calendar.current
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
            maxCarryGap: maxCarryGap,
            now: now
        )

        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let hourlyCount = 365 * 24
        let hourlyStart = calendar.date(byAdding: .hour, value: -(hourlyCount - 1), to: currentHour) ?? currentHour
        let hourlyBins = makeCarriedBins(
            rows: sorted,
            start: hourlyStart,
            count: hourlyCount,
            interval: 60 * 60,
            maxCarryGap: maxCarryGap,
            now: now
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
        return suppressRecoveredFullUsageSpikes(rows).map { row in
            let normalized = row.normalized(after: lastByAccount[row.accountKey])
            lastByAccount[row.accountKey] = normalized
            return normalized
        }
    }

    private static func suppressRecoveredFullUsageSpikes(_ rows: [QuotaHistoryRow]) -> [QuotaHistoryRow] {
        var adjusted = rows
        suppressRecoveredFullUsageSpikes(
            in: &adjusted,
            usedPercent: \.fiveHourUsedPercent,
            resetDate: \.fiveHourResetsAt,
            replacing: { row, value in row.replacing(fiveHourUsedPercent: value) }
        )
        suppressRecoveredFullUsageSpikes(
            in: &adjusted,
            usedPercent: \.sevenDayUsedPercent,
            resetDate: \.sevenDayResetsAt,
            replacing: { row, value in row.replacing(sevenDayUsedPercent: value) }
        )
        return adjusted
    }

    private static func suppressRecoveredFullUsageSpikes(
        in rows: inout [QuotaHistoryRow],
        usedPercent: KeyPath<QuotaHistoryRow, Int?>,
        resetDate: KeyPath<QuotaHistoryRow, Date?>,
        replacing: (QuotaHistoryRow, Int) -> QuotaHistoryRow
    ) {
        var groups: [String: [QuotaHistorySpikeEntry]] = [:]
        for (index, row) in rows.enumerated() {
            guard let used = row[keyPath: usedPercent] else { continue }
            let key = "\(row.accountKey)|\(resetBucket(row[keyPath: resetDate]))"
            groups[key, default: []].append(QuotaHistorySpikeEntry(index: index, usedPercent: used))
        }

        for entries in groups.values {
            for position in entries.indices {
                let entry = entries[position]
                let previous = position > entries.startIndex ? entries[entries.index(before: position)].usedPercent : nil
                let nextIndex = entries.index(after: position)
                let next = nextIndex < entries.endIndex ? entries[nextIndex].usedPercent : nil
                guard let replacement = recoveredFullUsageReplacement(
                    current: entry.usedPercent,
                    previous: previous,
                    next: next
                ) else { continue }
                rows[entry.index] = replacing(rows[entry.index], replacement)
            }
        }
    }

    private static func resetBucket(_ date: Date?) -> String {
        guard let date else { return "none" }
        return String(Int((date.timeIntervalSince1970 / QuotaHistoryRow.resetGraceInterval).rounded()))
    }

    private static func recoveredFullUsageReplacement(current: Int, previous: Int?, next: Int?) -> Int? {
        if let next, current - next >= 20 {
            if let previous {
                if current < 95, current - previous < 20 {
                    return nil
                }
                if previous < 95 {
                    return previous
                }
            }
            return next
        }
        if let previous, previous <= 5, current >= 95 {
            return previous
        }
        return nil
    }

    private static func row(from quota: AccountQuotaSnapshot, createdAt: Date) -> QuotaHistoryRow {
        let canonical = canonicalCodexIdentity(for: quota)
        return QuotaHistoryRow(
            createdAt: createdAt,
            accountKey: Self.accountKey(for: quota, canonical: canonical),
            source: "swift",
            planType: canonical?.planType ?? quota.planType,
            limitName: canonical?.limitName ?? quota.limitName,
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
        maxCarryGap: TimeInterval,
        now: Date
    ) -> [QuotaHistoryRecentBucket] {
        var rowIndex = 0
        var latestRow: QuotaHistoryRow?

        return (0..<count).map { index -> QuotaHistoryRecentBucket in
            let binStart = start.addingTimeInterval(Double(index) * interval)
            let end = binStart.addingTimeInterval(interval)
            let sampleDate = min(end, now)

            while rowIndex < rows.count, rows[rowIndex].createdAt <= sampleDate {
                latestRow = rows[rowIndex]
                rowIndex += 1
            }
            let nextRow = rows[safe: rowIndex]

            return QuotaHistoryRecentBucket(
                start: binStart,
                fiveHourRemainingPercent: quotaRemaining(
                    from: latestRow,
                    to: nextRow,
                    at: sampleDate,
                    maxCarryGap: maxCarryGap,
                    remaining: \.fiveHourRemainingPercent,
                    resetsAt: \.fiveHourResetsAt,
                    sameCycle: { $0.isSameFiveHourCycle(as: $1) }
                ),
                sevenDayRemainingPercent: quotaRemaining(
                    from: latestRow,
                    to: nextRow,
                    at: sampleDate,
                    maxCarryGap: maxCarryGap,
                    remaining: \.sevenDayRemainingPercent,
                    resetsAt: \.sevenDayResetsAt,
                    sameCycle: { $0.isSameSevenDayCycle(as: $1) }
                )
            )
        }
    }

    private static func quotaRemaining(
        from row: QuotaHistoryRow?,
        to nextRow: QuotaHistoryRow?,
        at date: Date,
        maxCarryGap: TimeInterval,
        remaining: KeyPath<QuotaHistoryRow, Double?>,
        resetsAt: KeyPath<QuotaHistoryRow, Date?>,
        sameCycle: (QuotaHistoryRow, QuotaHistoryRow) -> Bool
    ) -> Double? {
        guard let row, let value = row[keyPath: remaining] else { return nil }

        if let resetDate = row[keyPath: resetsAt] {
            if date >= resetDate {
                return 100
            }
            if let interpolated = interpolatedQuotaRemaining(
                from: row,
                to: nextRow,
                at: date,
                startValue: value,
                remaining: remaining,
                sameCycle: sameCycle
            ) {
                return interpolated
            }
            return value
        }

        if let interpolated = interpolatedQuotaRemaining(
            from: row,
            to: nextRow,
            at: date,
            startValue: value,
            remaining: remaining,
            sameCycle: sameCycle
        ) {
            return interpolated
        }
        guard date.timeIntervalSince(row.createdAt) <= maxCarryGap else {
            return nil
        }
        return value
    }

    private static func interpolatedQuotaRemaining(
        from row: QuotaHistoryRow,
        to nextRow: QuotaHistoryRow?,
        at date: Date,
        startValue: Double,
        remaining: KeyPath<QuotaHistoryRow, Double?>,
        sameCycle: (QuotaHistoryRow, QuotaHistoryRow) -> Bool
    ) -> Double? {
        guard let nextRow,
              sameCycle(row, nextRow),
              let endValue = nextRow[keyPath: remaining],
              endValue < startValue,
              date > row.createdAt,
              date < nextRow.createdAt else { return nil }

        let duration = nextRow.createdAt.timeIntervalSince(row.createdAt)
        guard duration > 0 else { return nil }
        let progress = max(0, min(1, date.timeIntervalSince(row.createdAt) / duration))
        return startValue + (endValue - startValue) * progress
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
                source TEXT,
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
        try ensureColumn("source", definition: "TEXT", database: database)
        try ensureColumn("five_hour_resets_at", definition: "REAL", database: database)
        try ensureColumn("seven_day_resets_at", definition: "REAL", database: database)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_created_at ON quota_snapshots(created_at);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_account_created ON quota_snapshots(account_key, created_at);")
    }

    private func insert(_ row: QuotaHistoryRow, database: SQLiteDatabaseConnection) throws {
        let sql = """
        INSERT INTO quota_snapshots (
            created_at, account_key, source, plan_type, limit_name, account_name,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try database.execute(sql, bindings: [
            .date(row.createdAt),
            .text(row.accountKey),
            .optionalText(row.source),
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
                   source, five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE account_key = ?
            ORDER BY created_at DESC;
            """,
            bindings: [.text(accountKey)]
        )
        return Self.sanitizedRows(Array(rawRows.reversed())).last
    }

    private func recentRows(database: SQLiteDatabaseConnection, now: Date = Date()) throws -> [QuotaHistoryRow] {
        guard let latest = try latestHistoryRow(database: database) else { return [] }
        let cutoff = now.addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970
        guard let accountName = Self.normalizedIdentityText(latest.accountName),
              let planType = Self.normalizedIdentityText(latest.planType) else {
            return try rows(
                database: database,
                sql: """
                SELECT created_at, account_key, plan_type, limit_name, account_name,
                       source, five_hour_used_percent, five_hour_resets_at,
                       seven_day_used_percent, seven_day_resets_at, status
                FROM quota_snapshots
                WHERE account_key = ? AND created_at >= ?
                ORDER BY created_at ASC;
                """,
                bindings: [.text(latest.accountKey), .double(cutoff)]
            )
        }
        let limitName = Self.normalizedLimitName(latest.limitName)
        return try rows(
            database: database,
            sql: """
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   source, five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            WHERE created_at >= ?
              AND (
                account_key = ?
                OR (
                  lower(trim(account_name)) = ?
                  AND lower(trim(plan_type)) = ?
                  AND (
                    lower(trim(COALESCE(limit_name, ''))) = ?
                    OR (
                      lower(trim(COALESCE(limit_name, ''))) IN ('', 'codex')
                      AND ? IN ('', 'codex')
                    )
                  )
                )
              )
            ORDER BY created_at ASC;
            """,
            bindings: [
                .double(cutoff),
                .text(latest.accountKey),
                .text(accountName),
                .text(planType),
                .text(limitName),
                .text(limitName)
            ]
        )
    }

    private func latestHistoryRow(database: SQLiteDatabaseConnection) throws -> QuotaHistoryRow? {
        try rows(
            database: database,
            sql: """
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   source, five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status
            FROM quota_snapshots
            ORDER BY created_at DESC
            LIMIT 1;
            """
        )
        .first
    }

    private func rows(database: SQLiteDatabaseConnection, sql: String, bindings: [SQLiteBinding] = []) throws -> [QuotaHistoryRow] {
        try database.readRows(sql, bindings: bindings) { statement in
            QuotaHistoryRow(
                createdAt: statement.date(0) ?? Date(timeIntervalSince1970: 0),
                accountKey: statement.text(1) ?? "default",
                source: statement.text(5),
                planType: statement.text(2),
                limitName: statement.text(3),
                accountName: statement.text(4),
                fiveHourUsedPercent: statement.int(6),
                fiveHourResetsAt: statement.date(7),
                sevenDayUsedPercent: statement.int(8),
                sevenDayResetsAt: statement.date(9),
                status: statement.text(10) ?? ""
            )
        }
    }

    private func prune(database: SQLiteDatabaseConnection, now: Date) throws {
        let cutoff = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60)).timeIntervalSince1970
        let sql = "DELETE FROM quota_snapshots WHERE created_at < ?;"
        try database.execute(sql, bindings: [.double(cutoff)])
    }

    private func withDatabase<T>(_ work: (SQLiteDatabaseConnection) throws -> T) throws -> T {
        guard let url = databaseURL ?? Self.defaultDatabaseURL else {
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

    private static var defaultDatabaseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexTokenBar", isDirectory: true)
            .appendingPathComponent("quota-history.sqlite")
    }

    private static func accountKey(for quota: AccountQuotaSnapshot, canonical: (planType: String, limitName: String)? = nil) -> String {
        let parts = [quota.accountName, canonical?.planType ?? quota.planType, canonical?.limitName ?? quota.limitName]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        return parts.isEmpty ? "default" : parts.joined(separator: "|")
    }

    private static func canonicalCodexIdentity(for quota: AccountQuotaSnapshot) -> (planType: String, limitName: String)? {
        let limitName = normalizedLimitName(quota.limitName)
        guard limitName.isEmpty || limitName == "codex" else { return nil }
        guard normalizedIdentityText(quota.planType) != nil else { return nil }
        return ("Pro", "codex")
    }

    private static func normalizedIdentityText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func normalizedLimitName(_ value: String?) -> String {
        normalizedIdentityText(value) ?? ""
    }
}
