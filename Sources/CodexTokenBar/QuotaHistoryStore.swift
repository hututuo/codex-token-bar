import Foundation

protocol QuotaHistoryLoading: Sendable {
    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot
    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot
    func resetStabilityTracking()
    func checkMaintenance()
}

extension QuotaHistoryLoading {
    func resetStabilityTracking() {}
    func checkMaintenance() {}
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

    func resetStabilityTracking() {
        database.resetStabilityTracking()
    }

    func checkMaintenance() {
        let database = database
        Task.detached(priority: .utility) {
            try? database.migrate()
        }
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
        historyClient.resetStabilityTracking()
        historyClient.checkMaintenance()
        clearIdentity()
    }

    func resetStabilityTracking() {
        historyClient.resetStabilityTracking()
    }

    func checkMaintenance() {
        historyClient.checkMaintenance()
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
    fileprivate static let legacyFiveHourMaxResetSpan: TimeInterval = 6 * 60 * 60

    let databaseID: Int64?
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
    let fiveHourCycleGeneration: Int?
    let fiveHourResetAnchor: Bool
    let sevenDayCycleGeneration: Int?
    let sevenDayResetAnchor: Bool

    init(
        createdAt: Date,
        accountKey: String,
        source: String?,
        planType: String?,
        limitName: String?,
        accountName: String?,
        fiveHourUsedPercent: Int?,
        fiveHourResetsAt: Date?,
        sevenDayUsedPercent: Int?,
        sevenDayResetsAt: Date?,
        status: String,
        identityVersion: Int?,
        homeIdentity: String?,
        stableAccountKey: String?,
        identityPlanType: String?,
        identityLimitID: String?,
        databaseID: Int64? = nil,
        fiveHourCycleGeneration: Int? = nil,
        fiveHourResetAnchor: Bool = false,
        sevenDayCycleGeneration: Int? = nil,
        sevenDayResetAnchor: Bool = false
    ) {
        self.databaseID = databaseID
        self.createdAt = createdAt
        self.accountKey = accountKey
        self.source = source
        self.planType = planType
        self.limitName = limitName
        self.accountName = accountName
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayUsedPercent = sevenDayUsedPercent
        self.sevenDayResetsAt = sevenDayResetsAt
        self.status = status
        self.identityVersion = identityVersion
        self.homeIdentity = homeIdentity
        self.stableAccountKey = stableAccountKey
        self.identityPlanType = identityPlanType
        self.identityLimitID = identityLimitID
        self.fiveHourCycleGeneration = fiveHourCycleGeneration
        self.fiveHourResetAnchor = fiveHourResetAnchor
        self.sevenDayCycleGeneration = sevenDayCycleGeneration
        self.sevenDayResetAnchor = sevenDayResetAnchor
    }

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
                previousResetsAt: previous.fiveHourResetsAt,
                currentCycleID: fiveHourCycleID,
                previousCycleID: previous.fiveHourCycleID
            ),
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayUsedPercent: QuotaMonotonicNormalizer.normalizedUsedPercent(
                currentUsedPercent: sevenDayUsedPercent,
                currentResetsAt: sevenDayResetsAt,
                previousUsedPercent: previous.sevenDayUsedPercent,
                previousResetsAt: previous.sevenDayResetsAt,
                currentCycleID: sevenDayCycleID,
                previousCycleID: previous.sevenDayCycleID
            ),
            sevenDayResetsAt: sevenDayResetsAt,
            status: status,
            identityVersion: identityVersion,
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            identityPlanType: identityPlanType,
            identityLimitID: identityLimitID,
            databaseID: databaseID,
            fiveHourCycleGeneration: fiveHourCycleGeneration,
            fiveHourResetAnchor: fiveHourResetAnchor,
            sevenDayCycleGeneration: sevenDayCycleGeneration,
            sevenDayResetAnchor: sevenDayResetAnchor
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
            identityLimitID: identityLimitID,
            databaseID: databaseID,
            fiveHourCycleGeneration: fiveHourCycleGeneration,
            fiveHourResetAnchor: fiveHourResetAnchor,
            sevenDayCycleGeneration: sevenDayCycleGeneration,
            sevenDayResetAnchor: sevenDayResetAnchor
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
            identityLimitID: identityLimitID,
            databaseID: databaseID,
            fiveHourCycleGeneration: nil,
            fiveHourResetAnchor: false,
            sevenDayCycleGeneration: fiveHourCycleGeneration,
            sevenDayResetAnchor: fiveHourResetAnchor
        )
    }

    func isSameFiveHourCycle(as other: QuotaHistoryRow) -> Bool {
        Self.isSameObservedCycle(
            lhs: self,
            rhs: other,
            used: \.fiveHourUsedPercent,
            reset: \.fiveHourResetsAt,
            generation: \.fiveHourCycleGeneration
        )
    }

    func isSameSevenDayCycle(as other: QuotaHistoryRow) -> Bool {
        Self.isSameObservedCycle(
            lhs: self,
            rhs: other,
            used: \.sevenDayUsedPercent,
            reset: \.sevenDayResetsAt,
            generation: \.sevenDayCycleGeneration
        )
    }

    func replacingCycleMetadata(
        fiveHourGeneration: Int?,
        fiveHourAnchor: Bool,
        sevenDayGeneration: Int?,
        sevenDayAnchor: Bool
    ) -> QuotaHistoryRow {
        QuotaHistoryRow(
            createdAt: createdAt,
            accountKey: accountKey,
            source: source,
            planType: planType,
            limitName: limitName,
            accountName: accountName,
            fiveHourUsedPercent: fiveHourUsedPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayUsedPercent: sevenDayUsedPercent,
            sevenDayResetsAt: sevenDayResetsAt,
            status: status,
            identityVersion: identityVersion,
            homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey,
            identityPlanType: identityPlanType,
            identityLimitID: identityLimitID,
            databaseID: databaseID,
            fiveHourCycleGeneration: fiveHourGeneration,
            fiveHourResetAnchor: fiveHourAnchor,
            sevenDayCycleGeneration: sevenDayGeneration,
            sevenDayResetAnchor: sevenDayAnchor
        )
    }

    var fiveHourCycleID: String? {
        cycleID(kind: .fiveHour, generation: fiveHourCycleGeneration)
    }

    var sevenDayCycleID: String? {
        cycleID(kind: .sevenDay, generation: sevenDayCycleGeneration)
    }

    private func cycleID(kind: QuotaHistoryWindowKind, generation: Int?) -> String? {
        guard let generation else { return nil }
        // Identity and window are already carried by the containing quota
        // value. Keep the token deliberately opaque and cheap to produce for
        // thousands of chart observations; consumers only compare equality.
        return "g\(generation)"
    }

    private static func isSameObservedCycle(
        lhs: QuotaHistoryRow,
        rhs: QuotaHistoryRow,
        used: KeyPath<QuotaHistoryRow, Int?>,
        reset: KeyPath<QuotaHistoryRow, Date?>,
        generation: KeyPath<QuotaHistoryRow, Int?>
    ) -> Bool {
        if let left = lhs[keyPath: generation], let right = rhs[keyPath: generation] {
            return left == right
        }
        let newer = lhs.createdAt >= rhs.createdAt ? lhs : rhs
        let older = lhs.createdAt >= rhs.createdAt ? rhs : lhs
        return !QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: newer[keyPath: used],
            currentResetsAt: newer[keyPath: reset],
            acceptedResetsAt: older[keyPath: reset]
        )
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
    let cycleGeneration: Int?
}

private struct QuotaHistoryWindowObservation {
    let rowIndex: Int
    let createdAt: Date
    let usedPercent: Int
    let resetsAt: Date?
}

final class QuotaHistoryDatabase: @unchecked Sendable {
    private static let initialHistoryWindowDays = 60
    private static let maintenancePolicyVersion = 2
    private let fileManager: FileManager
    private let databaseURL: URL?
    private let peerDatabaseURL: URL?
    private let recentInterval: TimeInterval = 5 * 60
    private let maxCarryGap: TimeInterval = 90 * 60
    private let legacyClaimRefreshInterval: TimeInterval = 60 * 60
    private let stabilityLock = NSLock()
    private var stabilityCandidates: [StabilityKey: QuotaResetStabilityCandidate] = [:]

    private struct StabilityKey: Hashable {
        let identity: QuotaHistoryIdentity
        let window: QuotaHistoryWindowKind
        let generation: Int
    }

    init(
        databaseURL: URL? = nil,
        peerDatabaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL
        // Custom database URLs are used by tests and migrations. Do not silently
        // read the user's live Tauri database in those isolated instances.
        let configuredPeerURL = peerDatabaseURL ?? (databaseURL == nil ? Self.defaultPeerDatabaseURL : nil)
        self.peerDatabaseURL = configuredPeerURL.map { SQLitePeerDatabasePath.mainURL(for: $0) }
        self.fileManager = fileManager
    }

    func resetStabilityTracking() {
        stabilityLock.lock()
        stabilityCandidates.removeAll(keepingCapacity: true)
        stabilityLock.unlock()
    }

    func migrate() throws {
        var deletedRows = 0
        try withDatabase { database in
            try ensureSchema(database)
            deletedRows = try performMaintenanceIfNeeded(database: database, now: Date())
        }
        reclaimDatabaseIfNeeded(deletedRows: deletedRows)
    }

    @discardableResult
    func record(_ quota: AccountQuotaSnapshot, createdAt: Date = Date()) throws -> Bool {
        let now = createdAt
        guard quota.isAvailable, let rawRow = Self.row(from: quota, createdAt: now),
              let identity = stableIdentity(from: rawRow) else {
            return false
        }
        let peerRows = loadPeerRows(for: rawRow, cutoff: nil)

        var deletedRows = 0
        let recorded = try withDatabase { database in
            try ensureSchema(database)
            let localRows = try matchingRows(database: database, row: rawRow, cutoff: nil, now: now)
            let history = Self.canonicalizedCycleRows(mergedRows(localRows + peerRows))
            let latest = Self.sanitizedRows(history).last
            var normalizedRow = Self.annotatedCurrentRow(rawRow, after: history)
                .normalized(after: latest)
            let stableAnchors = updateStabilityCandidates(
                for: normalizedRow,
                identity: identity,
                history: history
            )
            normalizedRow = normalizedRow.replacingCycleMetadata(
                fiveHourGeneration: normalizedRow.fiveHourCycleGeneration,
                fiveHourAnchor: normalizedRow.fiveHourResetAnchor || stableAnchors.fiveHour,
                sevenDayGeneration: normalizedRow.sevenDayCycleGeneration,
                sevenDayAnchor: normalizedRow.sevenDayResetAnchor || stableAnchors.sevenDay
            )
            let cycleBoundaryChanged = latest.map {
                normalizedRow.fiveHourCycleGeneration != $0.fiveHourCycleGeneration
                    || normalizedRow.sevenDayCycleGeneration != $0.sevenDayCycleGeneration
            } ?? true
            if let latest,
               !stableAnchors.fiveHour,
               !stableAnchors.sevenDay,
               !cycleBoundaryChanged,
               !shouldInsert(normalizedRow, after: latest) {
                deletedRows = try performMaintenanceIfNeeded(database: database, now: now)
                return true
            }
            try insert(normalizedRow, database: database)
            deletedRows = try performMaintenanceIfNeeded(database: database, now: now)
            return true
        }
        reclaimDatabaseIfNeeded(deletedRows: deletedRows)
        return recorded
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) throws -> AccountQuotaSnapshot {
        let now = Date()
        guard let row = Self.row(from: quota, createdAt: now) else { return quota }
        let peerRows = loadPeerRows(for: row, cutoff: nil)
        return try withDatabase { database in
            try ensureSchema(database)
            let localRows = try matchingRows(
                database: database,
                row: row,
                cutoff: nil,
                now: now
            )
            let history = Self.sanitizedRows(
                Self.canonicalizedCycleRows(mergedRows(localRows + peerRows))
            )
            let annotatedRow = Self.annotatedCurrentRow(row, after: history)
            let normalizedRow = annotatedRow.normalized(after: history.last)
            return Self.snapshot(from: normalizedRow, base: quota)
        }
    }

    func loadSnapshot(for quota: AccountQuotaSnapshot, now: Date = Date()) throws -> QuotaHistorySnapshot {
        guard let row = Self.row(from: quota, createdAt: now) else { return .empty }
        // Read two months up front so the existing 30-day chart has a warm
        // buffer for range expansion. A future dynamic loader can widen this
        // same cutoff without changing the persisted history schema.
        let cutoff = now.addingTimeInterval(
            -TimeInterval(Self.initialHistoryWindowDays * 24 * 60 * 60)
        )
        let localRows = try withDatabase { database in
            try ensureSchema(database)
            return try matchingRows(
                database: database,
                row: row,
                cutoff: cutoff,
                now: now
            )
        }
        let peerRows = loadPeerRows(
            for: row,
            cutoff: cutoff
        )
        return Self.makeSnapshot(
            rows: mergedRows(localRows + peerRows),
            recentInterval: recentInterval,
            maxCarryGap: maxCarryGap,
            now: now
        )
    }

    func recordedFiveHourUsedPercents(
        for quota: AccountQuotaSnapshot,
        now: Date = Date(),
        age: TimeInterval = 31 * 24 * 60 * 60
    ) throws -> [Int] {
        guard let row = Self.row(from: quota, createdAt: now) else { return [] }
        let localRows = try withDatabase { database in
            try ensureSchema(database)
            return try matchingRows(
                database: database,
                row: row,
                cutoff: now.addingTimeInterval(-age),
                now: now
            )
        }
        let peerRows = loadPeerRows(for: row, cutoff: now.addingTimeInterval(-age))
        return mergedRows(localRows + peerRows).compactMap(\.fiveHourUsedPercent)
    }

    private func shouldInsert(_ row: QuotaHistoryRow, after latest: QuotaHistoryRow) -> Bool {
        if row.accountKey != latest.accountKey { return true }
        if row.fiveHourUsedPercent != latest.fiveHourUsedPercent { return true }
        if row.sevenDayUsedPercent != latest.sevenDayUsedPercent { return true }
        if !QuotaHistoryCyclePolicy.isResetJitter(row.fiveHourResetsAt, latest.fiveHourResetsAt) { return true }
        if !QuotaHistoryCyclePolicy.isResetJitter(row.sevenDayResetsAt, latest.sevenDayResetsAt) { return true }
        if row.planType != latest.planType || row.limitName != latest.limitName || row.accountName != latest.accountName { return true }
        return false
    }

    private static func annotatedCurrentRow(
        _ row: QuotaHistoryRow,
        after history: [QuotaHistoryRow]
    ) -> QuotaHistoryRow {
        canonicalizedCycleRows(history + [row]).last(where: {
            $0.databaseID == row.databaseID
                && $0.createdAt == row.createdAt
                && $0.source == row.source
        }) ?? row
    }

    /// Replays the strict boundary rule over one stable-identity timeline. A
    /// persisted non-boundary anchor advances the accepted reset timestamp
    /// without incrementing the generation.
    private static func canonicalizedCycleRows(_ rows: [QuotaHistoryRow]) -> [QuotaHistoryRow] {
        var ordered = rows.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return ($0.databaseID ?? Int64.max) < ($1.databaseID ?? Int64.max)
        }
        // Preserve the newest native Swift generation as the absolute offset.
        // The loaded chart window is bounded, so replaying from zero alone
        // would rename every surviving cycle whenever an old boundary rolled
        // out of that window.
        let fiveGenerationTarget = ordered.enumerated().reversed().first(where: { entry in
            entry.element.source?.caseInsensitiveCompare("swift") == .orderedSame
                && entry.element.fiveHourCycleGeneration != nil
        }).flatMap { entry in
            entry.element.fiveHourCycleGeneration.map { (entry.offset, $0) }
        }
        let sevenGenerationTarget = ordered.enumerated().reversed().first(where: { entry in
            entry.element.source?.caseInsensitiveCompare("swift") == .orderedSame
                && entry.element.sevenDayCycleGeneration != nil
        }).flatMap { entry in
            entry.element.sevenDayCycleGeneration.map { (entry.offset, $0) }
        }
        var fiveGeneration = 0
        var sevenGeneration = 0
        var fiveAcceptedReset: Date?
        var sevenAcceptedReset: Date?
        var hasFive = false
        var hasSeven = false

        for index in ordered.indices {
            let row = ordered[index]
            var fiveAnchor = false
            var sevenAnchor = false
            var fiveValueGeneration: Int?
            var sevenValueGeneration: Int?

            if row.fiveHourUsedPercent != nil || row.fiveHourResetsAt != nil {
                if !hasFive {
                    hasFive = true
                    fiveAnchor = true
                } else if QuotaHistoryCyclePolicy.startsNewCycle(
                    currentUsedPercent: row.fiveHourUsedPercent,
                    currentResetsAt: row.fiveHourResetsAt,
                    acceptedResetsAt: fiveAcceptedReset
                ) {
                    fiveGeneration += 1
                    fiveAnchor = true
                } else if row.fiveHourResetAnchor {
                    fiveAnchor = true
                }
                fiveValueGeneration = fiveGeneration
                if fiveAnchor, let reset = row.fiveHourResetsAt {
                    fiveAcceptedReset = reset
                } else if fiveAcceptedReset == nil {
                    fiveAcceptedReset = row.fiveHourResetsAt
                }
            }

            if row.sevenDayUsedPercent != nil || row.sevenDayResetsAt != nil {
                if !hasSeven {
                    hasSeven = true
                    sevenAnchor = true
                } else if QuotaHistoryCyclePolicy.startsNewCycle(
                    currentUsedPercent: row.sevenDayUsedPercent,
                    currentResetsAt: row.sevenDayResetsAt,
                    acceptedResetsAt: sevenAcceptedReset
                ) {
                    sevenGeneration += 1
                    sevenAnchor = true
                } else if row.sevenDayResetAnchor {
                    sevenAnchor = true
                }
                sevenValueGeneration = sevenGeneration
                if sevenAnchor, let reset = row.sevenDayResetsAt {
                    sevenAcceptedReset = reset
                } else if sevenAcceptedReset == nil {
                    sevenAcceptedReset = row.sevenDayResetsAt
                }
            }

            ordered[index] = row.replacingCycleMetadata(
                fiveHourGeneration: fiveValueGeneration,
                fiveHourAnchor: fiveAnchor,
                sevenDayGeneration: sevenValueGeneration,
                sevenDayAnchor: sevenAnchor
            )
        }
        if let (targetIndex, persisted) = fiveGenerationTarget,
           let relative = ordered[targetIndex].fiveHourCycleGeneration {
            let offset = persisted - relative
            for index in ordered.indices {
                let row = ordered[index]
                ordered[index] = row.replacingCycleMetadata(
                    fiveHourGeneration: row.fiveHourCycleGeneration.map { $0 + offset },
                    fiveHourAnchor: row.fiveHourResetAnchor,
                    sevenDayGeneration: row.sevenDayCycleGeneration,
                    sevenDayAnchor: row.sevenDayResetAnchor
                )
            }
        }
        if let (targetIndex, persisted) = sevenGenerationTarget,
           let relative = ordered[targetIndex].sevenDayCycleGeneration {
            let offset = persisted - relative
            for index in ordered.indices {
                let row = ordered[index]
                ordered[index] = row.replacingCycleMetadata(
                    fiveHourGeneration: row.fiveHourCycleGeneration,
                    fiveHourAnchor: row.fiveHourResetAnchor,
                    sevenDayGeneration: row.sevenDayCycleGeneration.map { $0 + offset },
                    sevenDayAnchor: row.sevenDayResetAnchor
                )
            }
        }
        return ordered
    }

    private func updateStabilityCandidates(
        for row: QuotaHistoryRow,
        identity: QuotaHistoryIdentity,
        history: [QuotaHistoryRow]
    ) -> (fiveHour: Bool, sevenDay: Bool) {
        let fiveAnchor = history.last(where: { $0.fiveHourResetAnchor && $0.fiveHourResetsAt != nil })
        let sevenAnchor = history.last(where: { $0.sevenDayResetAnchor && $0.sevenDayResetsAt != nil })
        return (
            stabilityAnchorDecision(
                identity: identity,
                window: .fiveHour,
                generation: row.fiveHourCycleGeneration,
                currentUsedPercent: row.fiveHourUsedPercent,
                currentResetsAt: row.fiveHourResetsAt,
                currentIsBoundaryAnchor: row.fiveHourResetAnchor,
                acceptedResetsAt: fiveAnchor?.fiveHourResetsAt,
                observedAt: row.createdAt
            ),
            stabilityAnchorDecision(
                identity: identity,
                window: .sevenDay,
                generation: row.sevenDayCycleGeneration,
                currentUsedPercent: row.sevenDayUsedPercent,
                currentResetsAt: row.sevenDayResetsAt,
                currentIsBoundaryAnchor: row.sevenDayResetAnchor,
                acceptedResetsAt: sevenAnchor?.sevenDayResetsAt,
                observedAt: row.createdAt
            )
        )
    }

    private func stabilityAnchorDecision(
        identity: QuotaHistoryIdentity,
        window: QuotaHistoryWindowKind,
        generation: Int?,
        currentUsedPercent: Int?,
        currentResetsAt: Date?,
        currentIsBoundaryAnchor: Bool,
        acceptedResetsAt: Date?,
        observedAt: Date
    ) -> Bool {
        guard currentUsedPercent != nil,
              let generation,
              let currentResetsAt else { return false }
        let key = StabilityKey(identity: identity, window: window, generation: generation)
        stabilityLock.lock()
        defer { stabilityLock.unlock() }
        stabilityCandidates = stabilityCandidates.filter {
            !($0.key.identity == identity && $0.key.window == window && $0.key.generation != generation)
        }
        if currentIsBoundaryAnchor {
            stabilityCandidates.removeValue(forKey: key)
            return false
        }
        guard let acceptedResetsAt,
              !QuotaHistoryCyclePolicy.isResetJitter(currentResetsAt, acceptedResetsAt) else {
            stabilityCandidates.removeValue(forKey: key)
            return false
        }
        guard var candidate = stabilityCandidates[key] else {
            stabilityCandidates[key] = QuotaResetStabilityCandidate(
                observedAt: observedAt,
                resetsAt: currentResetsAt
            )
            return false
        }
        let stable = candidate.observe(observedAt: observedAt, resetsAt: currentResetsAt)
        if stable {
            stabilityCandidates.removeValue(forKey: key)
        } else {
            stabilityCandidates[key] = candidate
        }
        return stable
    }

    private static func makeSnapshot(rows: [QuotaHistoryRow], recentInterval: TimeInterval, maxCarryGap: TimeInterval, now: Date = Date()) -> QuotaHistorySnapshot {
        let calendar = Calendar.current
        guard let recentStart = calendar.date(byAdding: .day, value: -30, to: now) else {
            return .empty
        }

        let intervalCount = 30 * 24 * 12
        let sorted = sanitizedRows(canonicalizedCycleRows(rows))
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
        QuotaHistoryCyclePolicy.isResetJitter(lhs, rhs)
    }

    private static func suppressRecoveredFullUsageSpikes(_ rows: [QuotaHistoryRow]) -> [QuotaHistoryRow] {
        var adjusted = rows
        suppressRecoveredFullUsageSpikes(
            in: &adjusted,
            usedPercent: \.fiveHourUsedPercent,
            resetDate: \.fiveHourResetsAt,
            cycleGeneration: \.fiveHourCycleGeneration,
            replacing: { row, value in row.replacing(fiveHourUsedPercent: value) }
        )
        suppressRecoveredFullUsageSpikes(
            in: &adjusted,
            usedPercent: \.sevenDayUsedPercent,
            resetDate: \.sevenDayResetsAt,
            cycleGeneration: \.sevenDayCycleGeneration,
            replacing: { row, value in row.replacing(sevenDayUsedPercent: value) }
        )
        return adjusted
    }

    private static func suppressRecoveredFullUsageSpikes(
        in rows: inout [QuotaHistoryRow],
        usedPercent: KeyPath<QuotaHistoryRow, Int?>,
        resetDate: KeyPath<QuotaHistoryRow, Date?>,
        cycleGeneration: KeyPath<QuotaHistoryRow, Int?>,
        replacing: (QuotaHistoryRow, Int) -> QuotaHistoryRow
    ) {
        var groups: [String: [QuotaHistorySpikeEntry]] = [:]
        for (index, row) in rows.enumerated() {
            guard let used = row[keyPath: usedPercent] else { continue }
            groups[row.historyMatchKey, default: []].append(
                QuotaHistorySpikeEntry(
                    index: index,
                    usedPercent: max(0, min(100, used)),
                    resetsAt: row[keyPath: resetDate],
                    cycleGeneration: row[keyPath: cycleGeneration]
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
        let ordered = entries.sorted { $0.index < $1.index }
        let generated = Dictionary(grouping: ordered.compactMap { entry in
            entry.cycleGeneration.map { ($0, entry) }
        }, by: \.0)
            .values
            .map { $0.map(\.1) }
        let legacy = ordered.filter { $0.cycleGeneration == nil }
        guard !legacy.isEmpty else { return generated }

        var legacyClusters: [[QuotaHistorySpikeEntry]] = []
        var current: [QuotaHistorySpikeEntry] = []
        var acceptedReset: Date?
        for entry in legacy {
            if !current.isEmpty,
               QuotaHistoryCyclePolicy.startsNewCycle(
                currentUsedPercent: entry.usedPercent,
                currentResetsAt: entry.resetsAt,
                acceptedResetsAt: acceptedReset
               ) {
                legacyClusters.append(current)
                current = []
                acceptedReset = nil
            }
            current.append(entry)
            if acceptedReset == nil { acceptedReset = entry.resetsAt }
        }
        if !current.isEmpty { legacyClusters.append(current) }
        return generated + legacyClusters
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
            adjusted.fiveHour = window(
                label: "5h",
                usedPercent: row.fiveHourUsedPercent,
                resetsAt: row.fiveHourResetsAt,
                cycleID: row.fiveHourCycleID
            )
        } else {
            adjusted.fiveHour = nil
        }
        if quota.resolvedSevenDayAvailability == .measured {
            adjusted.sevenDay = window(
                label: "7d",
                usedPercent: row.sevenDayUsedPercent,
                resetsAt: row.sevenDayResetsAt,
                cycleID: row.sevenDayCycleID
            )
        } else {
            adjusted.sevenDay = nil
        }
        return adjusted
    }

    private static func window(
        label: String,
        usedPercent: Int?,
        resetsAt: Date?,
        cycleID: String?
    ) -> AccountQuotaWindow? {
        guard let usedPercent else { return nil }
        return AccountQuotaWindow(
            label: label,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            cycleID: cycleID
        )
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
            // Calendar subtraction followed by floating-point interval
            // addition can leave the final bin a fraction of a millisecond
            // before `now`. Snap that numerical residue back to `now` so an
            // observation recorded exactly at the load boundary is retained.
            let boundaryTolerance: TimeInterval = 0.000_001
            let sampleDate = now.timeIntervalSince(end) <= boundaryTolerance ? now : end
            // SQLite REAL timestamps can round one ULP above the originating
            // Date when converted back. One microsecond covers that numerical
            // residue without changing the chart's meaningful bucket timing.
            let inclusiveUpperBound = sampleDate.addingTimeInterval(boundaryTolerance)
            let firstUnreadRowIndex = rowIndex

            while rowIndex < rows.count, rows[rowIndex].createdAt <= inclusiveUpperBound {
                latestRow = rows[rowIndex]
                rowIndex += 1
            }
            let nextRow = rows[safe: rowIndex]
            let observations = rows[firstUnreadRowIndex..<rowIndex].filter { row in
                row.createdAt >= binStart && row.createdAt <= inclusiveUpperBound
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
                        resetsAt: \.fiveHourResetsAt,
                        cycleID: \.fiveHourCycleID
                    )
                },
                sevenDayObservations: observations.compactMap { row in
                    quotaObservation(
                        from: row,
                        remaining: \.sevenDayRemainingPercent,
                        resetsAt: \.sevenDayResetsAt,
                        cycleID: \.sevenDayCycleID
                    )
                }
            )
        }
    }

    private static func quotaObservation(
        from row: QuotaHistoryRow,
        remaining: KeyPath<QuotaHistoryRow, Double?>,
        resetsAt: KeyPath<QuotaHistoryRow, Date?>,
        cycleID: KeyPath<QuotaHistoryRow, String?>
    ) -> QuotaHistoryObservation? {
        guard let remainingPercent = row[keyPath: remaining] else { return nil }
        return QuotaHistoryObservation(
            observedAt: row.createdAt,
            remainingPercent: remainingPercent,
            resetsAt: row[keyPath: resetsAt],
            cycleID: row[keyPath: cycleID]
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

    private struct MergeKey: Hashable {
        let scope: String
        let account: String
        let plan: String
        let limit: String
        let createdAt: UInt64
        let fiveHourUsedPercent: Int?
        let fiveHourResetsAt: UInt64?
        let sevenDayUsedPercent: Int?
        let sevenDayResetsAt: UInt64?
    }

    /// Merge the two independently written histories by quota identity and
    /// observation. The runtime source is metadata, not a second quota: Swift
    /// and Tauri can record the same percentage at the same instant, and that
    /// cross-platform duplicate should be removed before sanitizing and
    /// interpolating the series. Genuinely different observations remain
    /// ordered by timestamp.
    private func mergedRows(_ rows: [QuotaHistoryRow]) -> [QuotaHistoryRow] {
        var unique: [MergeKey: QuotaHistoryRow] = [:]
        for row in rows {
            let hasStableIdentity = stableIdentity(from: row) != nil
            let key = MergeKey(
                scope: mergeScope(for: row),
                // Stable identity is authoritative even if one runtime has a
                // missing or differently formatted display name. Legacy rows
                // still require the account/plan/limit fallback to stay safe.
                account: hasStableIdentity ? "" : row.historyMatchKey,
                plan: hasStableIdentity ? "" : canonicalMergeValue(row.planType),
                limit: hasStableIdentity ? "" : canonicalMergeValue(row.limitName),
                createdAt: row.createdAt.timeIntervalSince1970.bitPattern,
                fiveHourUsedPercent: row.fiveHourUsedPercent,
                fiveHourResetsAt: row.fiveHourResetsAt?.timeIntervalSince1970.bitPattern,
                sevenDayUsedPercent: row.sevenDayUsedPercent,
                sevenDayResetsAt: row.sevenDayResetsAt?.timeIntervalSince1970.bitPattern
            )
            guard let previous = unique[key] else {
                unique[key] = row
                continue
            }

            // Prefer the row with useful descriptive metadata when duplicate
            // snapshots disagree only in status or an optional display field.
            if previous.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !row.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unique[key] = row
            }
        }
        return unique.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return canonicalSource($0.source) < canonicalSource($1.source)
        }
    }

    private func mergeScope(for row: QuotaHistoryRow) -> String {
        if let identity = stableIdentity(from: row) {
            return [
                "stable",
                String(identity.version),
                identity.homeIdentity,
                identity.stableAccountKey,
                identity.planType,
                identity.limitID
            ].joined(separator: "|")
        }
        return "legacy|\(row.historyMatchKey)"
    }

    private func canonicalMergeValue(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func canonicalSource(_ value: String?) -> String {
        canonicalMergeValue(value)
    }

    /// Read only the stable-identity rows from the peer runtime. In particular,
    /// do not call `ensureSchema`, legacy bridge claims, or any write-capable
    /// transaction against the peer database.
    private func loadPeerRows(for row: QuotaHistoryRow, cutoff: Date?) -> [QuotaHistoryRow] {
        guard let configuredPeerURL = peerDatabaseURL,
              let configuredMainURL = databaseURL ?? Self.defaultDatabaseURL,
              let identity = stableIdentity(from: row) else {
            return []
        }
        // Re-apply the peer family rule at the read boundary so a future
        // candidate resolver cannot hand SQLite a WAL/SHM path as `main`.
        let peerURL = SQLitePeerDatabasePath.mainURL(for: configuredPeerURL)
        let mainURL = SQLitePeerDatabasePath.mainURL(for: configuredMainURL)
        guard peerURL.standardizedFileURL.path != mainURL.standardizedFileURL.path,
              fileManager.fileExists(atPath: peerURL.path) else {
            return []
        }

        do {
            // This is a fixed, append-only peer WAL. Let SQLite provide its
            // normal read snapshot while sidecars exist. If a completed
            // checkpoint has already removed both sidecars, the peer reader
            // may use an immutable main-file snapshot after rechecking the
            // main identity and WAL family before and after the read.
            let driver = SQLitePeerDatabaseReader(
                url: peerURL,
                busyTimeoutMilliseconds: 250,
                fileManager: fileManager
            )
            guard try peerSupportsStableIdentitySchema(driver) else { return [] }
            return try stableRows(
                database: driver,
                identity: identity,
                cutoff: cutoff,
                includeCycleMetadata: try peerSupportsCycleSchema(driver)
            )
        } catch {
            // Peer history is an optional supplement. Missing, locked, corrupt,
            // or partially migrated peer state must never hide the main history.
            return []
        }
    }

    private func peerSupportsStableIdentitySchema(_ database: DatabaseAccessing) throws -> Bool {
        let columns = try database.readRows("PRAGMA table_info(quota_snapshots);") { statement in
            statement.text(1) ?? ""
        }
        let required = Set([
            "created_at", "account_key", "source", "plan_type", "limit_name", "account_name",
            "five_hour_used_percent", "five_hour_resets_at", "seven_day_used_percent",
            "seven_day_resets_at", "status", "identity_version", "home_identity",
            "stable_account_key", "identity_plan_type", "identity_limit_id"
        ])
        return required.isSubset(of: Set(columns))
    }

    private func peerSupportsCycleSchema(_ database: DatabaseAccessing) throws -> Bool {
        let columns = try database.readRows("PRAGMA table_info(quota_snapshots);") { statement in
            statement.text(1) ?? ""
        }
        let required = Set([
            "five_hour_cycle_generation", "five_hour_reset_anchor",
            "seven_day_cycle_generation", "seven_day_reset_anchor"
        ])
        return required.isSubset(of: Set(columns))
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
                identity_limit_id TEXT,
                five_hour_cycle_generation INTEGER,
                five_hour_reset_anchor INTEGER NOT NULL DEFAULT 0,
                seven_day_cycle_generation INTEGER,
                seven_day_reset_anchor INTEGER NOT NULL DEFAULT 0
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
        try ensureColumn("five_hour_cycle_generation", definition: "INTEGER", database: database)
        try ensureColumn("five_hour_reset_anchor", definition: "INTEGER NOT NULL DEFAULT 0", database: database)
        try ensureColumn("seven_day_cycle_generation", definition: "INTEGER", database: database)
        try ensureColumn("seven_day_reset_anchor", definition: "INTEGER NOT NULL DEFAULT 0", database: database)
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
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS quota_history_maintenance (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
    }

    @discardableResult
    private func performMaintenanceIfNeeded(
        database: SQLiteDatabaseConnection,
        now: Date
    ) throws -> Int {
        let metadata = try database.readRows(
            "SELECT key, value FROM quota_history_maintenance WHERE key IN ('policy_version', 'last_compacted_at');"
        ) { statement in
            (statement.text(0) ?? "", statement.text(1) ?? "")
        }
        let values = Dictionary(uniqueKeysWithValues: metadata)
        let policyVersion = Int(values["policy_version"] ?? "")
        let lastCompactedAt = Double(values["last_compacted_at"] ?? "").map {
            Date(timeIntervalSince1970: $0)
        }
        let policyChanged = policyVersion != Self.maintenancePolicyVersion
        let due = lastCompactedAt.map {
            now.timeIntervalSince($0) >= QuotaHistoryCyclePolicy.maintenanceInterval
        } ?? true
        guard policyChanged || due else { return 0 }

        let deleted = try compactStableIdentityHistory(database: database)
        try database.execute(
            """
            INSERT INTO quota_history_maintenance(key, value)
            VALUES ('policy_version', ?), ('last_compacted_at', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            bindings: [
                .text(String(Self.maintenancePolicyVersion)),
                .text(String(now.timeIntervalSince1970))
            ]
        )
        return deleted
    }

    private func compactStableIdentityHistory(
        database: SQLiteDatabaseConnection
    ) throws -> Int {
        let identities = try database.readRows(
            """
            SELECT DISTINCT identity_version, home_identity, stable_account_key,
                            identity_plan_type, identity_limit_id
            FROM quota_snapshots
            WHERE identity_version IS NOT NULL
              AND trim(coalesce(home_identity, '')) <> ''
              AND trim(coalesce(stable_account_key, '')) <> ''
              AND trim(coalesce(identity_plan_type, '')) <> ''
              AND trim(coalesce(identity_limit_id, '')) <> '';
            """
        ) { statement in
            QuotaHistoryIdentity(
                version: statement.int(0) ?? 0,
                homeIdentity: statement.text(1),
                stableAccountKey: statement.text(2),
                planType: statement.text(3),
                limitID: statement.text(4)
            )
        }.compactMap { $0 }

        var deleted = 0
        for identity in identities {
            let rawRows = try stableRows(database: database, identity: identity, cutoff: nil)
            let rows = Self.rowsWithHistoricalStableAnchors(rawRows)
            for row in rows {
                guard let id = row.databaseID else { continue }
                try database.execute(
                    """
                    UPDATE quota_snapshots
                    SET five_hour_cycle_generation = ?, five_hour_reset_anchor = ?,
                        seven_day_cycle_generation = ?, seven_day_reset_anchor = ?
                    WHERE id = ?;
                    """,
                    bindings: [
                        .optionalInt(row.fiveHourCycleGeneration),
                        .int(row.fiveHourResetAnchor ? 1 : 0),
                        .optionalInt(row.sevenDayCycleGeneration),
                        .int(row.sevenDayResetAnchor ? 1 : 0),
                        .int64(id)
                    ]
                )
            }

            let deletionIDs = Self.redundantResetOnlyRowIDs(rows)
            for id in deletionIDs {
                deleted += try database.executeChangedRows(
                    "DELETE FROM quota_snapshots WHERE id = ?;",
                    bindings: [.int64(id)]
                )
            }
        }
        return deleted
    }

    private static func rowsWithHistoricalStableAnchors(
        _ input: [QuotaHistoryRow]
    ) -> [QuotaHistoryRow] {
        var rows = canonicalizedCycleRows(input)
        let five = historicalStableAnchorIndices(
            rows,
            used: \.fiveHourUsedPercent,
            reset: \.fiveHourResetsAt,
            generation: \.fiveHourCycleGeneration,
            anchor: \.fiveHourResetAnchor
        )
        let seven = historicalStableAnchorIndices(
            rows,
            used: \.sevenDayUsedPercent,
            reset: \.sevenDayResetsAt,
            generation: \.sevenDayCycleGeneration,
            anchor: \.sevenDayResetAnchor
        )
        for index in rows.indices where five.contains(index) || seven.contains(index) {
            let row = rows[index]
            rows[index] = row.replacingCycleMetadata(
                fiveHourGeneration: row.fiveHourCycleGeneration,
                fiveHourAnchor: row.fiveHourResetAnchor || five.contains(index),
                sevenDayGeneration: row.sevenDayCycleGeneration,
                sevenDayAnchor: row.sevenDayResetAnchor || seven.contains(index)
            )
        }
        return canonicalizedCycleRows(rows)
    }

    private static func historicalStableAnchorIndices(
        _ rows: [QuotaHistoryRow],
        used: KeyPath<QuotaHistoryRow, Int?>,
        reset: KeyPath<QuotaHistoryRow, Date?>,
        generation: KeyPath<QuotaHistoryRow, Int?>,
        anchor: KeyPath<QuotaHistoryRow, Bool>
    ) -> Set<Int> {
        var acceptedReset: Date?
        var activeGeneration: Int?
        var candidate: QuotaResetStabilityCandidate?
        var anchors = Set<Int>()

        for index in rows.indices {
            let row = rows[index]
            guard row[keyPath: used] != nil,
                  let currentReset = row[keyPath: reset],
                  let currentGeneration = row[keyPath: generation] else { continue }
            if activeGeneration != currentGeneration {
                activeGeneration = currentGeneration
                acceptedReset = nil
                candidate = nil
            }
            if row[keyPath: anchor] || acceptedReset == nil {
                acceptedReset = currentReset
                candidate = nil
                continue
            }
            guard let baselineReset = acceptedReset,
                  !QuotaHistoryCyclePolicy.isResetJitter(currentReset, baselineReset) else {
                candidate = nil
                continue
            }
            if candidate == nil {
                candidate = QuotaResetStabilityCandidate(
                    observedAt: row.createdAt,
                    resetsAt: currentReset
                )
                continue
            }
            if candidate?.observe(observedAt: row.createdAt, resetsAt: currentReset) == true {
                anchors.insert(index)
                acceptedReset = currentReset
                candidate = nil
            }
        }
        return anchors
    }

    private static func redundantResetOnlyRowIDs(_ rows: [QuotaHistoryRow]) -> [Int64] {
        guard rows.count > 1 else { return [] }
        var nextFiveAnchor: [Int?] = Array(repeating: nil, count: rows.count)
        var nextSevenAnchor: [Int?] = Array(repeating: nil, count: rows.count)
        var fiveByGeneration: [Int: Int] = [:]
        var sevenByGeneration: [Int: Int] = [:]
        for index in rows.indices.reversed() {
            let row = rows[index]
            if let generation = row.fiveHourCycleGeneration {
                nextFiveAnchor[index] = fiveByGeneration[generation]
                if row.fiveHourResetAnchor { fiveByGeneration[generation] = index }
            }
            if let generation = row.sevenDayCycleGeneration {
                nextSevenAnchor[index] = sevenByGeneration[generation]
                if row.sevenDayResetAnchor { sevenByGeneration[generation] = index }
            }
        }

        var retained = rows[0]
        var deletions: [Int64] = []
        for index in rows.indices.dropFirst() {
            let row = rows[index]
            guard let id = row.databaseID,
                  !row.fiveHourResetAnchor,
                  !row.sevenDayResetAnchor,
                  sameNonResetPayload(row, retained),
                  resetChangeIsCompacted(
                    previous: retained.fiveHourResetsAt,
                    current: row.fiveHourResetsAt,
                    hasLaterStableAnchor: nextFiveAnchor[index] != nil
                  ),
                  resetChangeIsCompacted(
                    previous: retained.sevenDayResetsAt,
                    current: row.sevenDayResetsAt,
                    hasLaterStableAnchor: nextSevenAnchor[index] != nil
                  ) else {
                retained = row
                continue
            }
            deletions.append(id)
        }
        return deletions
    }

    private static func sameNonResetPayload(
        _ lhs: QuotaHistoryRow,
        _ rhs: QuotaHistoryRow
    ) -> Bool {
        lhs.accountKey == rhs.accountKey
            && lhs.source == rhs.source
            && lhs.planType == rhs.planType
            && lhs.limitName == rhs.limitName
            && lhs.accountName == rhs.accountName
            && lhs.fiveHourUsedPercent == rhs.fiveHourUsedPercent
            && lhs.sevenDayUsedPercent == rhs.sevenDayUsedPercent
            && lhs.status == rhs.status
            && lhs.identityVersion == rhs.identityVersion
            && lhs.homeIdentity == rhs.homeIdentity
            && lhs.stableAccountKey == rhs.stableAccountKey
            && lhs.identityPlanType == rhs.identityPlanType
            && lhs.identityLimitID == rhs.identityLimitID
    }

    private static func resetChangeIsCompacted(
        previous: Date?,
        current: Date?,
        hasLaterStableAnchor: Bool
    ) -> Bool {
        if QuotaHistoryCyclePolicy.isResetJitter(previous, current) { return true }
        return hasLaterStableAnchor
    }

    private func insert(_ row: QuotaHistoryRow, database: SQLiteDatabaseConnection) throws {
        let sql = """
        INSERT INTO quota_snapshots (
            created_at, account_key, source, plan_type, limit_name, account_name,
            five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status,
            identity_version, home_identity, stable_account_key,
            identity_plan_type, identity_limit_id,
            five_hour_cycle_generation, five_hour_reset_anchor,
            seven_day_cycle_generation, seven_day_reset_anchor
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            .optionalText(row.identityLimitID),
            .optionalInt(row.fiveHourCycleGeneration),
            .int(row.fiveHourResetAnchor ? 1 : 0),
            .optionalInt(row.sevenDayCycleGeneration),
            .int(row.sevenDayResetAnchor ? 1 : 0)
        ])
    }

    private func latestTrustedRow(
        database: SQLiteDatabaseConnection,
        row: QuotaHistoryRow,
        now: Date,
        additionalRows: [QuotaHistoryRow] = []
    ) throws -> QuotaHistoryRow? {
        var rawRows = try matchingRows(database: database, row: row, cutoff: nil, now: now)
        if !additionalRows.isEmpty {
            rawRows = mergedRows(rawRows + additionalRows)
        }
        return Self.sanitizedRows(Self.canonicalizedCycleRows(rawRows)).last
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

        let legacyCutoff = cutoff ?? .distantPast
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
        database: DatabaseAccessing,
        identity: QuotaHistoryIdentity,
        cutoff: Date?,
        includeCycleMetadata: Bool = true
    ) throws -> [QuotaHistoryRow] {
        let cycleColumns = includeCycleMetadata
            ? "id, five_hour_cycle_generation, five_hour_reset_anchor, seven_day_cycle_generation, seven_day_reset_anchor"
            : "NULL, NULL, 0, NULL, 0"
        var sql = """
        SELECT created_at, account_key, plan_type, limit_name, account_name,
               source, five_hour_used_percent, five_hour_resets_at,
               seven_day_used_percent, seven_day_resets_at, status,
               identity_version, home_identity, stable_account_key,
               identity_plan_type, identity_limit_id,
               \(cycleColumns)
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
                   identity_plan_type, identity_limit_id,
                   id, five_hour_cycle_generation, five_hour_reset_anchor,
                   seven_day_cycle_generation, seven_day_reset_anchor
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
            ORDER BY created_at DESC;
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
                now.timeIntervalSince($0) >= legacyClaimRefreshInterval
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

    private func rows(database: DatabaseAccessing, sql: String, bindings: [SQLiteBinding] = []) throws -> [QuotaHistoryRow] {
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
                identityLimitID: statement.text(15),
                databaseID: statement.int64(16),
                fiveHourCycleGeneration: statement.int(17),
                fiveHourResetAnchor: (statement.int(18) ?? 0) != 0,
                sevenDayCycleGeneration: statement.int(19),
                sevenDayResetAnchor: (statement.int(20) ?? 0) != 0
            )
        }
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

    private func reclaimDatabaseIfNeeded(deletedRows: Int) {
        guard deletedRows > 0,
              let url = databaseURL ?? Self.defaultDatabaseURL else { return }
        let driver = SQLiteDatabaseDriver(
            url: url,
            readOnly: false,
            busyTimeoutMilliseconds: 3_000,
            enableWAL: true,
            fileManager: fileManager
        )
        do {
            let pageCount = try driver.readRows("PRAGMA page_count;") { $0.int64(0) ?? 0 }.first ?? 0
            let freePages = try driver.readRows("PRAGMA freelist_count;") { $0.int64(0) ?? 0 }.first ?? 0
            let pageSize = try driver.readRows("PRAGMA page_size;") { $0.int64(0) ?? 0 }.first ?? 0
            let freeBytes = freePages * pageSize
            let freeRatio = pageCount > 0 ? Double(freePages) / Double(pageCount) : 0
            guard freeBytes >= 1_048_576 || freeRatio >= 0.20 else { return }
            try driver.execute("PRAGMA wal_checkpoint(TRUNCATE);")
            try driver.execute("VACUUM;")
        } catch {
            // Page reclamation is best-effort. Row compaction has already
            // committed and a later daily pass can retry without data loss.
        }
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

    private static var defaultPeerDatabaseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexTokenBarTauri", isDirectory: true)
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
