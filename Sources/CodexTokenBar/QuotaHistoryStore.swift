import Foundation

protocol QuotaHistoryLoading: Sendable {
    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot
    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot
}

struct LiveQuotaHistoryClient: QuotaHistoryLoading {
    private let database: QuotaHistoryDatabase

    init(database: QuotaHistoryDatabase = QuotaHistoryDatabase()) {
        self.database = database
    }

    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        let database = database
        return try await Task.detached(priority: .utility) {
            try database.loadSnapshot(for: quota)
        }.value
    }

    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        let database = database
        return try await Task.detached(priority: .utility) {
            _ = try database.record(quota)
            return try database.loadSnapshot(for: quota)
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
    private var currentQuota: AccountQuotaSnapshot?

    init(historyClient: any QuotaHistoryLoading = LiveQuotaHistoryClient()) {
        self.historyClient = historyClient
    }

    deinit {
        operationTask?.cancel()
    }

    func start() {
        clearIdentity()
    }

    func reload() {
        guard let quota = currentQuota, quota.historyIdentity != nil else {
            clearIdentity()
            return
        }
        operationTask?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        let trace = RefreshPerformanceProbe.begin("quotaHistory.reload")
        let historyClient = historyClient
        operationTask = Task {
            trace?.mark("database.loadSnapshot.begin")
            do {
                let loaded = try await historyClient.loadSnapshot(for: quota)
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
        guard quota.isAvailable, let identity = quota.historyIdentity else {
            clearIdentity()
            return
        }
        if currentQuota?.historyIdentity != identity {
            clearIdentity()
        }
        currentQuota = quota
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
        guard quota.isAvailable, let identity = quota.historyIdentity else {
            clearIdentity()
            return quota
        }
        if currentQuota?.historyIdentity != identity {
            clearIdentity()
        }
        currentQuota = quota
        let trace = RefreshPerformanceProbe.begin("quotaHistory.normalizedForDisplay")
        trace?.mark("database.normalizedSnapshot.begin")
        let normalized = (try? await historyClient.normalizedSnapshot(quota)) ?? quota
        trace?.mark("database.normalizedSnapshot.end")
        trace?.end("ok")
        return normalized
    }

    func clearIdentity() {
        operationTask?.cancel()
        operationTask = nil
        operationGeneration += 1
        currentQuota = nil
        snapshot = .empty
    }

    private func isCurrentOperation(generation: Int) -> Bool {
        operationGeneration == generation
    }
}

private struct QuotaHistoryRow {
    fileprivate static let resetGraceInterval: TimeInterval = 2 * 60
    fileprivate static let legacyFiveHourMaxResetSpan: TimeInterval = 6 * 60 * 60

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
    let identityVersion: Int?
    let homeIdentity: String?
    let stableAccountKey: String?
    let identityPlanType: String?
    let identityLimitID: String?

    var historyMatchKey: String {
        let fallbackAccountName = accountKey
            .split(separator: "|", omittingEmptySubsequences: false)
            .first
            .map(String.init)
        let account = Self.nonempty(accountName) ?? Self.nonempty(fallbackAccountName) ?? "default"
        let plan = Self.canonicalPlanType(planType)
        let limit = Self.canonicalLimitName(limitName)
        return [account, plan, limit]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

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
            status: status,
            identityVersion: identityVersion,
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            identityPlanType: identityPlanType,
            identityLimitID: identityLimitID
        )
    }

    func replacing(
        fiveHourUsedPercent: Int? = nil,
        fiveHourResetsAt: Date? = nil,
        sevenDayUsedPercent: Int? = nil,
        sevenDayResetsAt: Date? = nil
    ) -> QuotaHistoryRow {
        QuotaHistoryRow(
            createdAt: createdAt,
            accountKey: accountKey,
            source: source,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            fiveHourUsedPercent: fiveHourUsedPercent ?? self.fiveHourUsedPercent,
            fiveHourResetsAt: fiveHourResetsAt ?? self.fiveHourResetsAt,
            sevenDayUsedPercent: sevenDayUsedPercent ?? self.sevenDayUsedPercent,
            sevenDayResetsAt: sevenDayResetsAt ?? self.sevenDayResetsAt,
            status: status,
            identityVersion: identityVersion,
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            identityPlanType: identityPlanType,
            identityLimitID: identityLimitID
        )
    }

    func reclassifyingLegacySevenDayOnlyWindow() -> QuotaHistoryRow {
        let looksLikeSevenDay = sevenDayUsedPercent == nil
            && sevenDayResetsAt == nil
            && fiveHourUsedPercent != nil
            && fiveHourResetsAt.map {
                $0.timeIntervalSince(createdAt) > Self.legacyFiveHourMaxResetSpan
            } == true
        guard looksLikeSevenDay else { return self }
        return QuotaHistoryRow(
            createdAt: createdAt,
            accountKey: accountKey,
            source: source,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            fiveHourUsedPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayUsedPercent: fiveHourUsedPercent,
            sevenDayResetsAt: fiveHourResetsAt,
            status: status,
            identityVersion: identityVersion,
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            identityPlanType: identityPlanType,
            identityLimitID: identityLimitID
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

    private static func canonicalPlanType(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        let normalized = value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "plus", "chatgptplus":
            return "Plus"
        case "pro", "chatgptpro":
            return "Pro"
        case "team", "teams", "business":
            return "Team"
        case "enterprise":
            return "Enterprise"
        case "free":
            return "Free"
        case "unknown", "null", "none", "unread":
            return nil
        default:
            if value.contains("待读取") || value.contains("未知") {
                return nil
            }
            return value
        }
    }

    private static func canonicalLimitName(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return "codex" }
        return value.caseInsensitiveCompare("codex") == .orderedSame ? "codex" : value
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct QuotaHistorySpikeEntry {
    let index: Int
    let usedPercent: Int
    let resetsAt: Date?
}

private struct QuotaHistoryWindowObservation {
    let rowIndex: Int
    let createdAt: Date
    let usedPercent: Int
    let resetsAt: Date?
}

final class QuotaHistoryDatabase: @unchecked Sendable {
    private let fileManager: FileManager
    private let databaseURL: URL?
    private let heartbeatInterval: TimeInterval = 60 * 60
    private let retentionDays = 45
    private let recentInterval: TimeInterval = 5 * 60
    private let maxCarryGap: TimeInterval = 90 * 60
    private let legacyBridgeMaxAge: TimeInterval = 45 * 24 * 60 * 60
    private let legacyBridgeMaxRows = 512

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    func migrate() throws {
        try withDatabase { database in
            try ensureSchema(database)
        }
    }

    @discardableResult
    func record(_ quota: AccountQuotaSnapshot, createdAt: Date = Date()) throws -> Bool {
        let now = createdAt
        guard quota.isAvailable, let row = Self.row(from: quota, createdAt: now) else {
            return false
        }

        return try withDatabase { database in
            try ensureSchema(database)
            let latest = try latestTrustedRow(database: database, row: row, now: now)
            let normalizedRow = row.normalized(after: latest)
            if let latest,
               !shouldInsert(normalizedRow, after: latest, now: now) {
                return true
            }
            try insert(normalizedRow, database: database)
            try prune(database: database, now: now)
            return true
        }
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) throws -> AccountQuotaSnapshot {
        let now = Date()
        guard let row = Self.row(from: quota, createdAt: now) else { return quota }
        return try withDatabase { database in
            try ensureSchema(database)
            let latest = try latestTrustedRow(database: database, row: row, now: now)
            let normalizedRow = row.normalized(after: latest)
            return Self.snapshot(from: normalizedRow, base: quota)
        }
    }

    func loadSnapshot(for quota: AccountQuotaSnapshot, now: Date = Date()) throws -> QuotaHistorySnapshot {
        guard let row = Self.row(from: quota, createdAt: now) else { return .empty }
        return try withDatabase { database in
            try ensureSchema(database)
            let rows = try matchingRows(
                database: database,
                row: row,
                cutoff: now.addingTimeInterval(-31 * 24 * 60 * 60),
                now: now
            )
            return Self.makeSnapshot(rows: rows, recentInterval: recentInterval, maxCarryGap: maxCarryGap, now: now)
        }
    }

    func recordedFiveHourUsedPercents(
        for quota: AccountQuotaSnapshot,
        now: Date = Date(),
        age: TimeInterval = 31 * 24 * 60 * 60
    ) throws -> [Int] {
        guard let row = Self.row(from: quota, createdAt: now) else { return [] }
        return try withDatabase { database in
            try ensureSchema(database)
            return try matchingRows(
                database: database,
                row: row,
                cutoff: now.addingTimeInterval(-age),
                now: now
            ).compactMap(\.fiveHourUsedPercent)
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
        guard let recentStart = calendar.date(byAdding: .day, value: -30, to: now) else {
            return .empty
        }

        let intervalCount = 30 * 24 * 12
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
        let reclassified = rows.map { $0.reclassifyingLegacySevenDayOnlyWindow() }
        let withoutFullRemainingJumps = suppressRecoveredFullRemainingJumps(reclassified)
        return suppressRecoveredFullUsageSpikes(withoutFullRemainingJumps).map { row in
            let key = row.historyMatchKey
            let normalized = row.normalized(after: lastByAccount[key])
            lastByAccount[key] = normalized
            return normalized
        }
    }

    private static func suppressRecoveredFullRemainingJumps(_ rows: [QuotaHistoryRow]) -> [QuotaHistoryRow] {
        var adjusted = rows
        suppressRecoveredFullRemainingJumps(
            in: &adjusted,
            usedPercent: \.fiveHourUsedPercent,
            resetDate: \.fiveHourResetsAt,
            replacing: { row, used, reset in
                row.replacing(fiveHourUsedPercent: used, fiveHourResetsAt: reset)
            }
        )
        suppressRecoveredFullRemainingJumps(
            in: &adjusted,
            usedPercent: \.sevenDayUsedPercent,
            resetDate: \.sevenDayResetsAt,
            replacing: { row, used, reset in
                row.replacing(sevenDayUsedPercent: used, sevenDayResetsAt: reset)
            }
        )
        return adjusted
    }

    private static func suppressRecoveredFullRemainingJumps(
        in rows: inout [QuotaHistoryRow],
        usedPercent: KeyPath<QuotaHistoryRow, Int?>,
        resetDate: KeyPath<QuotaHistoryRow, Date?>,
        replacing: (QuotaHistoryRow, Int, Date?) -> QuotaHistoryRow
    ) {
        let maxGlitchDuration: TimeInterval = 30 * 60
        var groups: [String: [QuotaHistoryWindowObservation]] = [:]
        for (rowIndex, row) in rows.enumerated() {
            guard let used = row[keyPath: usedPercent] else { continue }
            let clampedUsed = max(0, min(100, used))
            groups[row.historyMatchKey, default: []].append(
                QuotaHistoryWindowObservation(
                    rowIndex: rowIndex,
                    createdAt: row.createdAt,
                    usedPercent: clampedUsed,
                    resetsAt: row[keyPath: resetDate]
                )
            )
        }

        for observations in groups.values {
            var position = 1
            while position + 1 < observations.count {
                let previous = observations[position - 1]
                let current = observations[position]
                guard current.usedPercent <= previous.usedPercent - 20 else {
                    position += 1
                    continue
                }

                var recoveryPosition: Int?
                var candidatePosition = position + 1
                while candidatePosition < observations.count {
                    let candidate = observations[candidatePosition]
                    if candidate.createdAt.timeIntervalSince(current.createdAt) > maxGlitchDuration {
                        break
                    }
                    if sameReset(previous.resetsAt, candidate.resetsAt),
                       candidate.usedPercent >= previous.usedPercent - 5 {
                        recoveryPosition = candidatePosition
                        break
                    }
                    candidatePosition += 1
                }
                guard let recoveryPosition, let stableReset = previous.resetsAt else {
                    position += 1
                    continue
                }

                let recoveredFloor = min(previous.usedPercent, observations[recoveryPosition].usedPercent)
                for observation in observations[position..<recoveryPosition]
                where observation.usedPercent <= recoveredFloor - 20
                    && stableReset > observation.createdAt {
                    rows[observation.rowIndex] = replacing(
                        rows[observation.rowIndex],
                        previous.usedPercent,
                        previous.resetsAt
                    )
                }
                position = recoveryPosition
            }
        }
    }

    private static func sameReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= QuotaHistoryRow.resetGraceInterval
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
            groups[row.historyMatchKey, default: []].append(
                QuotaHistorySpikeEntry(
                    index: index,
                    usedPercent: max(0, min(100, used)),
                    resetsAt: row[keyPath: resetDate]
                )
            )
        }

        for entries in groups.values {
            for cycleEntries in resetClusters(entries) {
                let ordered = cycleEntries.sorted { $0.index < $1.index }
                for position in ordered.indices {
                    let entry = ordered[position]
                    let previous = position > ordered.startIndex
                        ? ordered[ordered.index(before: position)].usedPercent
                        : nil
                    let nextIndex = ordered.index(after: position)
                    let next = nextIndex < ordered.endIndex ? ordered[nextIndex].usedPercent : nil
                    guard let replacement = recoveredFullUsageReplacement(
                        current: entry.usedPercent,
                        previous: previous,
                        next: next
                    ) else { continue }
                    rows[entry.index] = replacing(rows[entry.index], replacement)
                }
            }
        }
    }

    private static func resetClusters(_ entries: [QuotaHistorySpikeEntry]) -> [[QuotaHistorySpikeEntry]] {
        var clusters: [[QuotaHistorySpikeEntry]] = []
        let missingReset = entries.filter { $0.resetsAt == nil }
        if !missingReset.isEmpty {
            clusters.append(missingReset)
        }

        let sorted = entries
            .compactMap { entry -> (QuotaHistorySpikeEntry, Date)? in
                guard let reset = entry.resetsAt else { return nil }
                return (entry, reset)
            }
            .sorted { $0.1 < $1.1 }

        var current: [QuotaHistorySpikeEntry] = []
        var clusterStart: Date?
        for (entry, reset) in sorted {
            if let start = clusterStart,
               reset.timeIntervalSince(start) > QuotaHistoryRow.resetGraceInterval {
                clusters.append(current)
                current = []
                clusterStart = reset
            } else if clusterStart == nil {
                clusterStart = reset
            }
            current.append(entry)
        }
        if !current.isEmpty {
            clusters.append(current)
        }
        return clusters
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

    private static func row(from quota: AccountQuotaSnapshot, createdAt: Date) -> QuotaHistoryRow? {
        guard let identity = quota.historyIdentity else { return nil }
        let accountName = nonemptyText(quota.accountName)
        return QuotaHistoryRow(
            createdAt: createdAt,
            accountKey: Self.accountKey(accountName: accountName, identity: identity),
            source: "swift",
            planType: identity.planType,
            limitName: identity.limitID,
            accountName: accountName,
            fiveHourUsedPercent: quota.fiveHour?.usedPercent,
            fiveHourResetsAt: quota.fiveHour?.resetsAt,
            sevenDayUsedPercent: quota.sevenDay?.usedPercent,
            sevenDayResetsAt: quota.sevenDay?.resetsAt,
            status: quota.status,
            identityVersion: identity.version,
            homeIdentity: identity.homeIdentity,
            stableAccountKey: identity.stableAccountKey,
            identityPlanType: identity.planType,
            identityLimitID: identity.limitID
        )
    }

    private static func snapshot(from row: QuotaHistoryRow, base quota: AccountQuotaSnapshot) -> AccountQuotaSnapshot {
        var adjusted = quota
        if quota.resolvedFiveHourAvailability == .measured {
            adjusted.fiveHour = window(label: "5h", usedPercent: row.fiveHourUsedPercent, resetsAt: row.fiveHourResetsAt)
        } else {
            adjusted.fiveHour = nil
        }
        if quota.resolvedSevenDayAvailability == .measured {
            adjusted.sevenDay = window(label: "7d", usedPercent: row.sevenDayUsedPercent, resetsAt: row.sevenDayResetsAt)
        } else {
            adjusted.sevenDay = nil
        }
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
            let firstUnreadRowIndex = rowIndex

            while rowIndex < rows.count, rows[rowIndex].createdAt <= sampleDate {
                latestRow = rows[rowIndex]
                rowIndex += 1
            }
            let nextRow = rows[safe: rowIndex]
            let observations = rows[firstUnreadRowIndex..<rowIndex].filter { row in
                row.createdAt >= binStart && row.createdAt <= sampleDate
            }

            return QuotaHistoryRecentBucket(
                start: binStart,
                fiveHourRemainingPercent: quotaRemaining(
                    from: latestRow,
                    to: nextRow,
                    previousBoundary: binStart,
                    at: sampleDate,
                    maxCarryGap: maxCarryGap,
                    remaining: \.fiveHourRemainingPercent,
                    resetsAt: \.fiveHourResetsAt,
                    sameCycle: { $0.isSameFiveHourCycle(as: $1) }
                ),
                sevenDayRemainingPercent: quotaRemaining(
                    from: latestRow,
                    to: nextRow,
                    previousBoundary: binStart,
                    at: sampleDate,
                    maxCarryGap: maxCarryGap,
                    remaining: \.sevenDayRemainingPercent,
                    resetsAt: \.sevenDayResetsAt,
                    sameCycle: { $0.isSameSevenDayCycle(as: $1) }
                ),
                fiveHourObservations: observations.compactMap { row in
                    quotaObservation(
                        from: row,
                        remaining: \.fiveHourRemainingPercent,
                        resetsAt: \.fiveHourResetsAt
                    )
                },
                sevenDayObservations: observations.compactMap { row in
                    quotaObservation(
                        from: row,
                        remaining: \.sevenDayRemainingPercent,
                        resetsAt: \.sevenDayResetsAt
                    )
                }
            )
        }
    }

    private static func quotaObservation(
        from row: QuotaHistoryRow,
        remaining: KeyPath<QuotaHistoryRow, Double?>,
        resetsAt: KeyPath<QuotaHistoryRow, Date?>
    ) -> QuotaHistoryObservation? {
        guard let remainingPercent = row[keyPath: remaining] else { return nil }
        return QuotaHistoryObservation(
            observedAt: row.createdAt,
            remainingPercent: remainingPercent,
            resetsAt: row[keyPath: resetsAt]
        )
    }

    private static func quotaRemaining(
        from row: QuotaHistoryRow?,
        to nextRow: QuotaHistoryRow?,
        previousBoundary: Date,
        at date: Date,
        maxCarryGap: TimeInterval,
        remaining: KeyPath<QuotaHistoryRow, Double?>,
        resetsAt: KeyPath<QuotaHistoryRow, Date?>,
        sameCycle: (QuotaHistoryRow, QuotaHistoryRow) -> Bool
    ) -> Double? {
        guard let row, let value = row[keyPath: remaining] else { return nil }

        if let resetDate = row[keyPath: resetsAt], resetDate > row.createdAt {
            if previousBoundary < resetDate, date >= resetDate {
                return 100
            }
            if date >= resetDate {
                return nil
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

    private struct LegacyBridge {
        let accountName: String
        let planType: String
        let limitID: String
        let kind: String
        let isFakePro: Bool
    }

    private struct LegacyBridgeClaim {
        let state: String
        let version: Int?
        let home: String?
        let account: String?
        let plan: String?
        let limit: String?
        let lastSeenAt: Date?

        func belongs(to identity: QuotaHistoryIdentity) -> Bool {
            version == identity.version
                && home == identity.homeIdentity
                && account == identity.stableAccountKey
                && plan == identity.planType
                && limit == identity.limitID
        }
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
                status TEXT NOT NULL,
                identity_version INTEGER,
                home_identity TEXT,
                stable_account_key TEXT,
                identity_plan_type TEXT,
                identity_limit_id TEXT
            );
            """
        )
        try ensureColumn("source", definition: "TEXT", database: database)
        try ensureColumn("five_hour_resets_at", definition: "REAL", database: database)
        try ensureColumn("seven_day_resets_at", definition: "REAL", database: database)
        try ensureColumn("identity_version", definition: "INTEGER", database: database)
        try ensureColumn("home_identity", definition: "TEXT", database: database)
        try ensureColumn("stable_account_key", definition: "TEXT", database: database)
        try ensureColumn("identity_plan_type", definition: "TEXT", database: database)
        try ensureColumn("identity_limit_id", definition: "TEXT", database: database)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_created_at ON quota_snapshots(created_at);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_quota_snapshots_account_created ON quota_snapshots(account_key, created_at);")
        try database.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_quota_snapshots_stable_identity_created
            ON quota_snapshots(
                identity_version, home_identity, stable_account_key,
                identity_plan_type, identity_limit_id, created_at
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS quota_history_legacy_claims (
                legacy_account_name TEXT NOT NULL,
                legacy_plan_type TEXT NOT NULL,
                legacy_limit_id TEXT NOT NULL,
                bridge_kind TEXT NOT NULL,
                owner_identity_version INTEGER NOT NULL,
                owner_home_identity TEXT NOT NULL,
                owner_stable_account_key TEXT NOT NULL,
                owner_plan_type TEXT NOT NULL,
                owner_limit_id TEXT NOT NULL,
                state TEXT NOT NULL,
                claimed_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                PRIMARY KEY (legacy_account_name, legacy_plan_type, legacy_limit_id)
            );
            """
        )
    }

    private func insert(_ row: QuotaHistoryRow, database: SQLiteDatabaseConnection) throws {
        let sql = """
        INSERT INTO quota_snapshots (
            created_at, account_key, source, plan_type, limit_name, account_name,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status,
            identity_version, home_identity, stable_account_key,
            identity_plan_type, identity_limit_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            .text(row.status),
            row.identityVersion.map(SQLiteBinding.int) ?? .null,
            .optionalText(row.homeIdentity),
            .optionalText(row.stableAccountKey),
            .optionalText(row.identityPlanType),
            .optionalText(row.identityLimitID)
        ])
    }

    private func latestTrustedRow(
        database: SQLiteDatabaseConnection,
        row: QuotaHistoryRow,
        now: Date
    ) throws -> QuotaHistoryRow? {
        let rawRows = try matchingRows(database: database, row: row, cutoff: nil, now: now)
        return Self.sanitizedRows(rawRows).last
    }

    private func matchingRows(
        database: SQLiteDatabaseConnection,
        row: QuotaHistoryRow,
        cutoff: Date?,
        now: Date
    ) throws -> [QuotaHistoryRow] {
        guard let identity = stableIdentity(from: row) else { return [] }
        var matched = try stableRows(database: database, identity: identity, cutoff: cutoff)
        guard !matched.isEmpty else { return matched }

        let legacyCutoff = max(cutoff ?? .distantPast, now.addingTimeInterval(-legacyBridgeMaxAge))
        for bridge in legacyBridges(row: row, identity: identity) {
            let legacyRows = try legacyRows(
                database: database,
                bridge: bridge,
                cutoff: legacyCutoff
            )
            guard !legacyRows.isEmpty else { continue }
            let knownAmbiguous = try legacyBridgeHasOtherStableIdentity(
                database: database,
                bridge: bridge,
                identity: identity
            )
            if try claimLegacyBridge(
                database: database,
                bridge: bridge,
                identity: identity,
                knownAmbiguous: knownAmbiguous,
                now: now
            ) {
                matched.append(contentsOf: legacyRows)
            }
        }
        return matched.sorted { $0.createdAt < $1.createdAt }
    }

    private func stableRows(
        database: SQLiteDatabaseConnection,
        identity: QuotaHistoryIdentity,
        cutoff: Date?
    ) throws -> [QuotaHistoryRow] {
        var sql = """
        SELECT created_at, account_key, plan_type, limit_name, account_name,
               source, five_hour_used_percent, five_hour_resets_at,
               seven_day_used_percent, seven_day_resets_at, status,
               identity_version, home_identity, stable_account_key,
               identity_plan_type, identity_limit_id
        FROM quota_snapshots
        WHERE identity_version = ?
          AND home_identity = ?
          AND stable_account_key = ?
          AND identity_plan_type = ?
          AND identity_limit_id = ?
        """
        var bindings: [SQLiteBinding] = [
            .int(identity.version),
            .text(identity.homeIdentity),
            .text(identity.stableAccountKey),
            .text(identity.planType),
            .text(identity.limitID)
        ]
        if let cutoff {
            sql += " AND created_at >= ?"
            bindings.append(.date(cutoff))
        }
        sql += " ORDER BY created_at ASC;"
        return try rows(database: database, sql: sql, bindings: bindings)
    }

    private func legacyBridges(
        row: QuotaHistoryRow,
        identity: QuotaHistoryIdentity
    ) -> [LegacyBridge] {
        guard let accountName = Self.nonemptyText(row.accountName) else { return [] }
        var bridges = [LegacyBridge(
            accountName: accountName,
            planType: identity.planType,
            limitID: identity.limitID,
            kind: "exact-plan",
            isFakePro: false
        )]
        if identity.planType.caseInsensitiveCompare("Pro") != .orderedSame,
           identity.limitID.caseInsensitiveCompare("codex") == .orderedSame {
            bridges.append(LegacyBridge(
                accountName: accountName,
                planType: "Pro",
                limitID: identity.limitID,
                kind: "swift-fake-pro",
                isFakePro: true
            ))
        }
        return bridges
    }

    private func legacyRows(
        database: SQLiteDatabaseConnection,
        bridge: LegacyBridge,
        cutoff: Date
    ) throws -> [QuotaHistoryRow] {
        try rows(
            database: database,
            sql: """
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   source, five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
            FROM quota_snapshots
            WHERE identity_version IS NULL
              AND account_name = ?
              AND lower(coalesce(plan_type, '')) = lower(?)
              AND (
                lower(coalesce(limit_name, '')) = lower(?)
                OR (? = 'codex' AND coalesce(limit_name, '') = '')
              )
              AND created_at >= ?
              AND (
                source IS NULL
                OR trim(source) = ''
                OR lower(trim(source)) IN ('swift', 'tauri')
              )
              AND (
                ? = 0
                OR source IS NULL
                OR trim(source) = ''
                OR lower(trim(source)) = 'swift'
              )
            ORDER BY created_at DESC
            LIMIT \(legacyBridgeMaxRows);
            """,
            bindings: [
                .text(bridge.accountName),
                .text(bridge.planType),
                .text(bridge.limitID),
                .text(bridge.limitID),
                .date(cutoff),
                .int(bridge.isFakePro ? 1 : 0)
            ]
        )
    }

    private func legacyBridgeHasOtherStableIdentity(
        database: SQLiteDatabaseConnection,
        bridge: LegacyBridge,
        identity: QuotaHistoryIdentity
    ) throws -> Bool {
        let sharedProAlias = bridge.planType.caseInsensitiveCompare("Pro") == .orderedSame
            && bridge.limitID.caseInsensitiveCompare("codex") == .orderedSame
        let counts = try database.readRows(
            """
            SELECT count(*)
            FROM (
                SELECT DISTINCT identity_version, home_identity, stable_account_key,
                                identity_plan_type, identity_limit_id
                FROM quota_snapshots
                WHERE identity_version = ?
                  AND account_name = ?
                  AND identity_limit_id = ?
                  AND (? = 1 OR identity_plan_type = ?)
                  AND NOT (
                    home_identity = ?
                    AND stable_account_key = ?
                    AND identity_plan_type = ?
                    AND identity_limit_id = ?
                  )
            );
            """,
            bindings: [
                .int(identity.version),
                .text(bridge.accountName),
                .text(bridge.limitID),
                .int(sharedProAlias ? 1 : 0),
                .text(bridge.planType),
                .text(identity.homeIdentity),
                .text(identity.stableAccountKey),
                .text(identity.planType),
                .text(identity.limitID)
            ]
        ) { statement in
            statement.int(0) ?? 0
        }
        return (counts.first ?? 0) > 0
    }

    private func claimLegacyBridge(
        database: SQLiteDatabaseConnection,
        bridge: LegacyBridge,
        identity: QuotaHistoryIdentity,
        knownAmbiguous: Bool,
        now: Date
    ) throws -> Bool {
        let desiredState = knownAmbiguous ? "ambiguous" : "claimed"
        if let existing = try legacyBridgeClaim(database: database, bridge: bridge) {
            let remainsClaimed = desiredState == "claimed"
                && existing.state == "claimed"
                && existing.belongs(to: identity)
            let resultingState = remainsClaimed ? "claimed" : "ambiguous"
            let heartbeatDue = existing.lastSeenAt.map {
                now.timeIntervalSince($0) >= heartbeatInterval
            } ?? true
            if existing.state == resultingState, !heartbeatDue {
                return remainsClaimed
            }
        }

        try database.execute(
            """
            INSERT INTO quota_history_legacy_claims (
                legacy_account_name, legacy_plan_type, legacy_limit_id, bridge_kind,
                owner_identity_version, owner_home_identity, owner_stable_account_key,
                owner_plan_type, owner_limit_id, state, claimed_at, last_seen_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(legacy_account_name, legacy_plan_type, legacy_limit_id)
            DO UPDATE SET
                state = CASE
                    WHEN excluded.state = 'claimed'
                     AND quota_history_legacy_claims.state = 'claimed'
                     AND quota_history_legacy_claims.owner_identity_version = excluded.owner_identity_version
                     AND quota_history_legacy_claims.owner_home_identity = excluded.owner_home_identity
                     AND quota_history_legacy_claims.owner_stable_account_key = excluded.owner_stable_account_key
                     AND quota_history_legacy_claims.owner_plan_type = excluded.owner_plan_type
                     AND quota_history_legacy_claims.owner_limit_id = excluded.owner_limit_id
                    THEN 'claimed'
                    ELSE 'ambiguous'
                END,
                last_seen_at = excluded.last_seen_at;
            """,
            bindings: [
                .text(bridge.accountName),
                .text(bridge.planType),
                .text(bridge.limitID),
                .text(bridge.kind),
                .int(identity.version),
                .text(identity.homeIdentity),
                .text(identity.stableAccountKey),
                .text(identity.planType),
                .text(identity.limitID),
                .text(knownAmbiguous ? "ambiguous" : "claimed"),
                .date(now),
                .date(now)
            ]
        )

        guard let claim = try legacyBridgeClaim(database: database, bridge: bridge) else {
            return false
        }
        return claim.state == "claimed" && claim.belongs(to: identity)
    }

    private func legacyBridgeClaim(
        database: SQLiteDatabaseConnection,
        bridge: LegacyBridge
    ) throws -> LegacyBridgeClaim? {
        try database.readRows(
            """
            SELECT state, owner_identity_version, owner_home_identity,
                   owner_stable_account_key, owner_plan_type, owner_limit_id,
                   last_seen_at
            FROM quota_history_legacy_claims
            WHERE legacy_account_name = ?
              AND legacy_plan_type = ?
              AND legacy_limit_id = ?;
            """,
            bindings: [
                .text(bridge.accountName),
                .text(bridge.planType),
                .text(bridge.limitID)
            ]
        ) { statement in
            LegacyBridgeClaim(
                state: statement.text(0) ?? "",
                version: statement.int(1),
                home: statement.text(2),
                account: statement.text(3),
                plan: statement.text(4),
                limit: statement.text(5),
                lastSeenAt: statement.date(6)
            )
        }.first
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
                status: statement.text(10) ?? "",
                identityVersion: statement.int(11),
                homeIdentity: statement.text(12),
                stableAccountKey: statement.text(13),
                identityPlanType: statement.text(14),
                identityLimitID: statement.text(15)
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

    private func stableIdentity(from row: QuotaHistoryRow) -> QuotaHistoryIdentity? {
        guard let version = row.identityVersion else { return nil }
        return QuotaHistoryIdentity(
            version: version,
            homeIdentity: row.homeIdentity,
            stableAccountKey: row.stableAccountKey,
            planType: row.identityPlanType,
            limitID: row.identityLimitID
        )
    }

    private static func accountKey(accountName: String?, identity: QuotaHistoryIdentity) -> String {
        [accountName ?? "default", identity.planType, identity.limitID]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    private static func nonemptyText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
