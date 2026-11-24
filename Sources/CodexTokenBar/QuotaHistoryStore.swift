import Foundation

enum QuotaHistoryProjection: Int, Comparable, Sendable {
    case sidebar, dashboard

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

protocol QuotaHistoryLoading: Sendable {
    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot
    func loadSnapshot(for quota: AccountQuotaSnapshot, projection: QuotaHistoryProjection) async throws -> QuotaHistorySnapshot
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot, projection: QuotaHistoryProjection?) async throws -> QuotaHistorySnapshot
    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot
    func resetStabilityTracking()
    func checkMaintenance()
}

extension QuotaHistoryLoading {
    func loadSnapshot(for quota: AccountQuotaSnapshot, projection: QuotaHistoryProjection) async throws -> QuotaHistorySnapshot {
        try await loadSnapshot(for: quota)
    }
    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot, projection: QuotaHistoryProjection?) async throws -> QuotaHistorySnapshot {
        let loaded = try await recordAndLoadSnapshot(quota)
        return projection == nil ? .empty : loaded
    }
    func resetStabilityTracking() {}
    func checkMaintenance() {}
}

actor LiveQuotaHistoryClient: QuotaHistoryLoading {
    private let database: QuotaHistoryDatabase

    init(database: QuotaHistoryDatabase = QuotaHistoryDatabase()) {
        self.database = database
    }

    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        try await loadSnapshot(for: quota, projection: .dashboard)
    }

    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        try await recordAndLoadSnapshot(quota, projection: .dashboard)
    }

    func loadSnapshot(for quota: AccountQuotaSnapshot, projection: QuotaHistoryProjection) async throws -> QuotaHistorySnapshot {
        try Task.checkCancellation()
        return try autoreleasepool { try database.loadSnapshot(for: quota, projection: projection) }
    }

    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot, projection: QuotaHistoryProjection?) async throws -> QuotaHistorySnapshot {
        try autoreleasepool { _ = try database.record(quota) }
        guard let projection, !Task.isCancelled else { return .empty }
        return try await loadSnapshot(for: quota, projection: projection)
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot {
        try autoreleasepool { try database.normalizedSnapshot(quota) }
    }

    nonisolated func resetStabilityTracking() {
        database.resetStabilityTracking()
    }

    nonisolated func checkMaintenance() {
        Task(priority: .utility) { await migrate() }
    }

    private func migrate() {
        try? database.migrate()
    }
}

enum QuotaCycleProjectionConsistency {
    static func needsRebuild(_ history: QuotaHistorySnapshot, quota: AccountQuotaSnapshot,
                             expectedStart: Date? = nil) -> Bool {
        guard let identity = quota.historyIdentity, let observedAt = quota.updatedAt,
              quota.sevenDay != nil, history.latest != nil else { return false }
        guard history.cycleIdentity == identity,
              history.projectionVersion == QuotaActualCycleProjector.projectionVersion,
              let current = history.actualCycles.first, current.isCurrent,
              current.lastObservedAt >= observedAt.addingTimeInterval(-0.000_001) else { return true }
        if let expectedStart, current.certainStart < expectedStart,
           !history.cycleDiagnostics.contains(where: { $0.kind == .withdrawn && $0.after.at == expectedStart }) {
            return true
        }
        return false
    }
}

@MainActor
final class QuotaHistoryStore: ObservableObject {
    @Published private(set) var snapshot: QuotaHistorySnapshot = .empty

    private let historyClient: any QuotaHistoryLoading
    private let backgroundProjection: QuotaHistoryProjection?
    private var projectionConsumers: [UUID: QuotaHistoryProjection] = [:]
    private var operationTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var currentQuota: AccountQuotaSnapshot?
    private var diagnosticIdentity: QuotaHistoryIdentity?
    private var diagnosticObservedThrough: Date?
    private var expectedCycleStart: Date?
    private var healingKey: String?

    init(historyClient: any QuotaHistoryLoading = LiveQuotaHistoryClient(),
         backgroundProjection: QuotaHistoryProjection? = .dashboard) {
        self.historyClient = historyClient
        self.backgroundProjection = backgroundProjection
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

    private var projection: QuotaHistoryProjection? {
        projectionConsumers.values.max() ?? backgroundProjection
    }

    func setProjectionDemand(_ demand: QuotaHistoryProjection?, consumer: UUID) {
        let previous = projection
        projectionConsumers[consumer] = demand
        guard projection != previous else { return }
        if projection == nil || previous == .dashboard {
            operationTask?.cancel()
            operationGeneration += 1
            if snapshot != .empty { snapshot = .empty }
        }
        if projection != nil { reload() }
    }

    func reload() {
        guard let projection else { return }
        guard let quota = currentQuota, quota.historyIdentity != nil else {
            clearIdentity()
            return
        }
        operationTask?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        let trace = RefreshPerformanceProbe.begin("quotaHistory.reload")
        let historyClient = historyClient
        let pendingRecord = recordingTask
        operationTask = Task(priority: .utility) {
            await pendingRecord?.value
            guard !Task.isCancelled else {
                trace?.end("cancelled-before-load")
                return
            }
            trace?.mark("database.loadSnapshot.begin")
            do {
                let loaded = try await historyClient.loadSnapshot(for: quota, projection: projection)
                trace?.mark("database.loadSnapshot.end", metadata: [
                    "daily": String(loaded.daily.count),
                    "recent": String(loaded.recentBins.count),
                    "hourly": String(loaded.hourlyBins.count)
                ])
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-after-load")
                    return
                }
                applyProjection(loaded)
                trace?.end("ok")
            } catch {
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-failed", metadata: ["error": error.localizedDescription])
                    return
                }
                recordHistoryFailure(error)
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
        if let previous = currentQuota, previous.historyIdentity == identity,
           let before = previous.sevenDay?.usedPercent, let after = quota.sevenDay?.usedPercent,
           let at = quota.updatedAt, previous.updatedAt.map({ at > $0 }) == true,
           before - after >= QuotaActualCycleProjector.minimumDrop {
            expectedCycleStart = at
        }
        currentQuota = quota
        operationTask?.cancel()
        operationGeneration += 1
        let generation = operationGeneration
        let projection = projection
        let trace = RefreshPerformanceProbe.begin("quotaHistory.record", metadata: [
            "fiveHour": quota.fiveHour.map { String(format: "%.2f", $0.remainingPercent) } ?? "nil",
            "sevenDay": quota.sevenDay.map { String(format: "%.2f", $0.remainingPercent) } ?? "nil"
        ])
        let historyClient = historyClient
        let pendingRecord = recordingTask
        let task = Task(priority: .utility) {
            // Opening or closing a chart can cancel projection work, but a
            // captured observation still commits before the next read or write.
            await pendingRecord?.value
            do {
                trace?.mark("database.recordAndLoadSnapshot.begin")
                let loaded = try await historyClient.recordAndLoadSnapshot(quota, projection: projection)
                trace?.mark("database.recordAndLoadSnapshot.end", metadata: [
                    "daily": String(loaded.daily.count),
                    "recent": String(loaded.recentBins.count),
                    "hourly": String(loaded.hourlyBins.count)
                ])
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-after-record")
                    return
                }
                if projection != nil { applyProjection(loaded) }
                trace?.end("ok")
            } catch {
                guard !Task.isCancelled, isCurrentOperation(generation: generation) else {
                    trace?.end("stale-record-failed", metadata: ["error": error.localizedDescription])
                    return
                }
                recordHistoryFailure(error)
                trace?.end("failed", metadata: ["error": error.localizedDescription])
                // Quota history is helpful context, not the source of truth for quota display.
            }
        }
        recordingTask = task
        operationTask = task
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
        diagnosticIdentity = nil
        diagnosticObservedThrough = nil
        expectedCycleStart = nil
        healingKey = nil
    }

    private func applyProjection(_ loaded: QuotaHistorySnapshot) {
        if diagnosticIdentity != loaded.cycleIdentity, let identity = loaded.cycleIdentity {
            diagnosticIdentity = identity
            DiagnosticLogHistory.shared.record(summary: "周期投影重算", logs:
                "version=\(loaded.projectionVersion) cycles=\(loaded.actualCycles.count) observedThrough=\(loaded.latest?.ISO8601Format() ?? "none") raw history retained",
                source: "quota-cycle-projection")
        } else if let previous = diagnosticObservedThrough {
            let changes = loaded.cycleDiagnostics.filter { $0.at > previous }
            if !changes.isEmpty {
                DiagnosticLogHistory.shared.record(summary: "周期判定节点", logs:
                    changes.suffix(10).map(\.detail).joined(separator: "\n"), source: "quota-cycle-projection")
            }
        }
        diagnosticObservedThrough = loaded.latest
        var published = loaded
        if let expected = currentQuota?.updatedAt,
           loaded.latest.map({ $0 < expected.addingTimeInterval(-0.000_001) }) ?? true {
            published.isStale = true
        }
        let mismatch = currentQuota.map {
            QuotaCycleProjectionConsistency.needsRebuild(loaded, quota: $0, expectedStart: expectedCycleStart)
        } ?? false
        if mismatch { published.isStale = true }
        snapshot = published
        if mismatch, let quota = currentQuota {
            let key = "\(String(describing: quota.historyIdentity))|\(expectedCycleStart?.timeIntervalSince1970 ?? 0)|\(QuotaActualCycleProjector.projectionVersion)"
            if healingKey != key {
                healingKey = key
                DiagnosticLogHistory.shared.record(summary: "本期周期自动重算", logs: "local projection only; raw records retained", source: "quota-cycle-projection")
                reload()
            }
        }
        if !published.isStale {
            healingKey = nil
            DiagnosticLogHistory.shared.record(summary: "额度历史更新", logs: "", source: "quota-cycle-history")
        }
    }

    private func recordHistoryFailure(_ error: Error) {
        snapshot.isStale = true
        DiagnosticLogHistory.shared.record(summary: "额度历史更新失败", logs: DiagnosticErrorDetails.text(error), source: "quota-cycle-history")
    }

    private func isCurrentOperation(generation: Int) -> Bool {
        operationGeneration == generation
    }
}

private struct QuotaHistoryRow {
    // In-memory projection only; never persisted or exposed on the wire.
    var fiveRejected = false
    var sevenRejected = false
    var fiveBridgeEnd: Date?
    var sevenBridgeEnd: Date?
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

    func projecting(fiveUsed: Int?, fiveReset: Date?, sevenUsed: Int?, sevenReset: Date?) -> QuotaHistoryRow {
        QuotaHistoryRow(
            createdAt: createdAt, accountKey: accountKey, source: source,
            planType: planType, limitName: limitName, accountName: accountName,
            fiveHourUsedPercent: fiveUsed, fiveHourResetsAt: fiveReset,
            sevenDayUsedPercent: sevenUsed, sevenDayResetsAt: sevenReset,
            status: status, identityVersion: identityVersion, homeIdentity: homeIdentity,
            stableAccountKey: stableAccountKey, identityPlanType: identityPlanType,
            identityLimitID: identityLimitID, databaseID: databaseID,
            fiveHourCycleGeneration: fiveHourCycleGeneration, fiveHourResetAnchor: fiveHourResetAnchor,
            sevenDayCycleGeneration: sevenDayCycleGeneration, sevenDayResetAnchor: sevenDayResetAnchor
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
            generation: \.fiveHourCycleGeneration,
            window: .fiveHour
        )
    }

    func isSameSevenDayCycle(as other: QuotaHistoryRow) -> Bool {
        Self.isSameObservedCycle(
            lhs: self,
            rhs: other,
            used: \.sevenDayUsedPercent,
            reset: \.sevenDayResetsAt,
            generation: \.sevenDayCycleGeneration,
            window: .sevenDay
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
        generation: KeyPath<QuotaHistoryRow, Int?>,
        window: QuotaHistoryWindowKind
    ) -> Bool {
        if let left = lhs[keyPath: generation], let right = rhs[keyPath: generation] {
            return left == right
        }
        let newer = lhs.createdAt >= rhs.createdAt ? lhs : rhs
        let older = lhs.createdAt >= rhs.createdAt ? rhs : lhs
        return !QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: newer[keyPath: used],
            currentResetsAt: newer[keyPath: reset],
            acceptedResetsAt: older[keyPath: reset],
            window: window
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

final class QuotaHistoryDatabase: @unchecked Sendable {
    static let peerReadBusyTimeoutMilliseconds: Int32 = 250
    private static let maintenancePolicyVersion = 3
    private let fileManager: FileManager
    private let databaseURL: URL?
    private let peerDatabaseURL: URL?
    private let recentInterval: TimeInterval = 5 * 60
    private let maxCarryGap: TimeInterval = 90 * 60
    private let legacyClaimRefreshInterval: TimeInterval = 60 * 60
    private let filterAnomalies: @Sendable () -> Bool
    private let consumption: @Sendable (URL, Date, Date) -> QuotaCycleConsumption
    init(
        databaseURL: URL? = nil,
        peerDatabaseURL: URL? = nil,
        fileManager: FileManager = .default,
        filterAnomalies: (@Sendable () -> Bool)? = nil,
        consumption: (@Sendable (URL, Date, Date) -> QuotaCycleConsumption)? = nil
    ) {
        self.databaseURL = databaseURL
        if let consumption {
            self.consumption = consumption
        } else if databaseURL == nil {
            self.consumption = { home, start, end in
                CodexUsageHistoryIndex.quotaCycleConsumption(codexHome: home, after: start, through: end)
            }
        } else {
            self.consumption = { _, _, _ in .unknown }
        }
        if let filterAnomalies {
            self.filterAnomalies = filterAnomalies
        } else if databaseURL == nil {
            self.filterAnomalies = { QuotaHistoryFilterSettings.isEnabled() }
        } else {
            self.filterAnomalies = { true }
        }
        // Custom database URLs are used by tests and migrations. Do not silently
        // read the user's live Tauri database in those isolated instances.
        let configuredPeerURL = peerDatabaseURL ?? (databaseURL == nil ? Self.defaultPeerDatabaseURL : nil)
        self.peerDatabaseURL = configuredPeerURL.map { SQLitePeerDatabasePath.mainURL(for: $0) }
        self.fileManager = fileManager
    }

    // Protection state is replayed from retained observations across restarts.
    func resetStabilityTracking() {}

    func migrate() throws {
        var deletedRows = 0
        try withDatabase { database in
            try ensureSchema(database)
            deletedRows = try performMaintenanceIfNeeded(database: database, now: Date())
        }
        reclaimDatabaseIfNeeded(deletedRows: deletedRows)
    }

    @discardableResult
    func record(_ quota: AccountQuotaSnapshot, createdAt: Date? = nil) throws -> Bool {
        guard let now = createdAt ?? quota.updatedAt,
              now.timeIntervalSince1970.isFinite else { return false }
        guard quota.isAvailable, let rawRow = Self.row(from: quota, createdAt: now),
              let identity = stableIdentity(from: rawRow) else {
            return false
        }
        let peerRows = loadPeerRows(for: rawRow, cutoff: nil)

        var deletedRows = 0
        let recorded = try withDatabase { database in
            try ensureSchema(database)
            let sequential: SequentialRecord
            if peerRows.isEmpty, try legacyBridges(row: rawRow, identity: identity).allSatisfy({
                try legacyRows(database: database, bridge: $0, cutoff: .distantPast, limitOne: true).isEmpty
            }) {
                sequential = try planSequentialRecord(rawRow, identity: identity, database: database)
            } else {
                sequential = .needsMerge
            }
            let planned: QuotaHistoryRow
            switch sequential {
            case .unchanged: return false
            case .append(let row): planned = row
            case .needsMerge:
                let localRows = try matchingRows(database: database, row: rawRow, cutoff: nil, now: now)
                let history = mergedRows(localRows + peerRows)
                guard history.last.map({ now.timeIntervalSince($0.createdAt) > QuotaHistoryCyclePolicy.timestampComparisonTolerance }) ?? true else { return false }
                planned = Self.annotatedCurrentRow(rawRow, after: history)
            }
            // Persist distinct successful observations together with their
            // freshness timestamp. Cached/older responses cannot become fresh
            // confirmation evidence after a restart or normal-value dedup.
            try insert(planned, database: database)
            deletedRows = try performMaintenanceIfNeeded(database: database, now: now)
            return true
        }
        reclaimDatabaseIfNeeded(deletedRows: deletedRows)
        return recorded
    }

    private enum SequentialRecord {
        case unchanged, needsMerge
        case append(QuotaHistoryRow)
    }

    private func planSequentialRecord(
        _ row: QuotaHistoryRow, identity: QuotaHistoryIdentity, database: SQLiteDatabaseConnection
    ) throws -> SequentialRecord {
        let (sql, bindings) = stableTimelineQuery(columns: """
            created_at, five_hour_used_percent, five_hour_resets_at, seven_day_used_percent,
            source, five_hour_cycle_generation, seven_day_cycle_generation
            """, identity: identity, cutoff: nil)
        var replay = CycleAssignment()
        var latest: Date?
        var duplicateTime = false
        var fiveOffset = 0, sevenOffset = 0
        try database.forEachRow(sql, bindings: bindings) { observation in
            guard !duplicateTime else { return }
            let at = observation.date(0) ?? Date(timeIntervalSince1970: 0)
            if let latest, at.timeIntervalSince1970 <= latest.timeIntervalSince1970 {
                duplicateTime = true
                return
            }
            latest = at
            let cycles = replay.advance(fiveUsed: observation.int(1), fiveReset: observation.date(2),
                sevenUsed: observation.int(3))
            guard observation.text(4)?.caseInsensitiveCompare("swift") == .orderedSame else { return }
            // The newest retained native generation anchors each window.
            // Peer, legacy, and duplicate timestamps use the general merge path.
            if let persisted = observation.int(5) {
                fiveOffset = cycles.five.map { persisted - $0 } ?? 0
            }
            if let persisted = observation.int(6) {
                sevenOffset = cycles.seven.map { persisted - $0 } ?? 0
            }
        }
        if duplicateTime { return .needsMerge }
        if let latest, row.createdAt.timeIntervalSince(latest) <= QuotaHistoryCyclePolicy.timestampComparisonTolerance {
            return .unchanged
        }
        return .append(replay.assign(row, fiveOffset: fiveOffset, sevenOffset: sevenOffset))
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) throws -> AccountQuotaSnapshot {
        let now = quota.updatedAt ?? Date()
        guard let row = Self.row(from: quota, createdAt: now) else { return quota }
        let peerRows = loadPeerRows(for: row, cutoff: nil)
        let localRows = try matchingHistoryRows(row: row, cutoff: nil, now: now)
        let history = Self.sanitizedRows(mergedRows(localRows + peerRows), now: now, filterAnomalies: filterAnomalies())
        let annotatedRow = Self.annotatedCurrentRow(row, after: history)
        return Self.snapshot(from: annotatedRow, base: quota)
    }

    func loadSnapshot(
        for quota: AccountQuotaSnapshot, now: Date = Date(), projection: QuotaHistoryProjection = .dashboard
    ) throws -> QuotaHistorySnapshot {
        guard let row = Self.row(from: quota, createdAt: now) else { return .empty }
        // Replay the retained identity timeline before selecting visible
        // ranges; the accepted baseline can predate any chart cutoff.
        let cutoff: Date? = nil
        let localRows = try matchingHistoryRows(row: row, cutoff: cutoff, now: now)
        let peerRows = loadPeerRows(
            for: row,
            cutoff: cutoff
        )
        return Self.makeSnapshot(
            rows: mergedRows(localRows + peerRows),
            recentInterval: recentInterval,
            maxCarryGap: maxCarryGap,
            now: now,
            projection: projection,
            filterAnomalies: filterAnomalies(),
            consumption: consumption
        )
    }

    func recordedFiveHourUsedPercents(
        for quota: AccountQuotaSnapshot,
        now: Date = Date(),
        age: TimeInterval = 31 * 24 * 60 * 60
    ) throws -> [Int] {
        guard let row = Self.row(from: quota, createdAt: now) else { return [] }
        let localRows = try matchingHistoryRows(row: row, cutoff: now.addingTimeInterval(-age), now: now)
        let peerRows = loadPeerRows(for: row, cutoff: now.addingTimeInterval(-age))
        return mergedRows(localRows + peerRows).compactMap(\.fiveHourUsedPercent)
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
        var ordered = rows
        ordered.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return ($0.databaseID ?? Int64.max) < ($1.databaseID ?? Int64.max)
        }
        applyCycleMetadata(to: &ordered, preserveLatestTarget: true)
        return ordered
    }

    /// Rows are already in chronological order. Projection groups have one
    /// observation per timestamp, so their sample indices stay aligned.
    private static func applyCycleMetadata(to ordered: inout [QuotaHistoryRow], preserveLatestTarget: Bool) {
        // Raw writes preserve the latest native generation. Read projections
        // start from the earliest retained native generation instead: using a
        // later target would retain the offset introduced by a rejected reset.
        // Both retain a durable offset when older history is no longer present.
        func nativeTarget(_ generation: KeyPath<QuotaHistoryRow, Int?>) -> (Int, Int)? {
            let matches: (QuotaHistoryRow) -> Bool = {
                $0[keyPath: generation] != nil && $0.source?.caseInsensitiveCompare("swift") == .orderedSame
            }
            let index = preserveLatestTarget ? ordered.lastIndex(where: matches) : ordered.firstIndex(where: matches)
            guard let index, let persisted = ordered[index][keyPath: generation] else { return nil }
            return (index, persisted)
        }
        let fiveGenerationTarget = nativeTarget(\.fiveHourCycleGeneration)
        let sevenGenerationTarget = nativeTarget(\.sevenDayCycleGeneration)
        var replay = CycleAssignment()
        for index in ordered.indices {
            ordered[index] = replay.assign(ordered[index])
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
    }

    /// Both persisted raw observations and protected chart projections use
    /// the same boundary decisions, with their own retained generation offsets.
    private struct CycleAssignment {
        private var fiveGeneration: Int?
        private var sevenGeneration: Int?
        private var fiveAcceptedReset: Date?
        private var sevenPreviousUsed: Int?

        mutating func advance(fiveUsed: Int?, fiveReset: Date?, sevenUsed: Int?)
            -> (five: Int?, fiveAnchor: Bool, seven: Int?, sevenAnchor: Bool) {
            var five: Int?, seven: Int?
            var fiveAnchor = false, sevenAnchor = false
            if let fiveUsed, (0...100).contains(fiveUsed) {
                fiveAnchor = fiveGeneration == nil || QuotaHistoryCyclePolicy.startsNewCycle(
                    currentUsedPercent: fiveUsed, currentResetsAt: fiveReset,
                    acceptedResetsAt: fiveAcceptedReset, window: .fiveHour
                )
                if fiveAnchor { fiveGeneration = (fiveGeneration ?? -1) + 1 }
                if fiveAnchor || fiveAcceptedReset == nil {
                    fiveAcceptedReset = fiveReset ?? fiveAcceptedReset
                }
                five = fiveGeneration
            }
            if let sevenUsed, (0...100).contains(sevenUsed) {
                sevenAnchor = sevenPreviousUsed.map { $0 - sevenUsed >= QuotaActualCycleProjector.minimumDrop } ?? true
                if sevenAnchor { sevenGeneration = (sevenGeneration ?? -1) + 1 }
                sevenPreviousUsed = sevenUsed
                seven = sevenGeneration
            }
            return (five, fiveAnchor, seven, sevenAnchor)
        }

        mutating func assign(_ row: QuotaHistoryRow, fiveOffset: Int = 0, sevenOffset: Int = 0) -> QuotaHistoryRow {
            let cycles = advance(fiveUsed: row.fiveHourUsedPercent, fiveReset: row.fiveHourResetsAt,
                sevenUsed: row.sevenDayUsedPercent)
            return row.replacingCycleMetadata(fiveHourGeneration: cycles.five.map { $0 + fiveOffset },
                fiveHourAnchor: cycles.fiveAnchor, sevenDayGeneration: cycles.seven.map { $0 + sevenOffset },
                sevenDayAnchor: cycles.sevenAnchor)
        }
    }

    private static func makeSnapshot(
        rows: [QuotaHistoryRow], recentInterval: TimeInterval, maxCarryGap: TimeInterval,
        now: Date = Date(), projection: QuotaHistoryProjection = .dashboard, filterAnomalies: Bool = true,
        consumption: (URL, Date, Date) -> QuotaCycleConsumption = { _, _, _ in .unknown }
    ) -> QuotaHistorySnapshot {
        let calendar = Calendar.current
        guard let recentStart = calendar.date(byAdding: .day, value: -30, to: now) else {
            return .empty
        }

        let intervalCount = 30 * 24 * 12
        let upperBound = now.addingTimeInterval(0.000_001)
        let raw = rows.allSatisfy { $0.createdAt <= upperBound } ? rows : rows.filter { $0.createdAt <= upperBound }
        var evidence: [String: QuotaCycleConsumption] = [:]
        func lookup(_ home: URL, _ start: Date, _ end: Date) -> QuotaCycleConsumption {
            let key = "\(home.path)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
            if let cached = evidence[key] { return cached }
            let value = consumption(home, start, end)
            evidence[key] = value
            return value
        }
        let sorted = sanitizedRows(raw, now: now, filterAnomalies: filterAnomalies, consumption: lookup)
        let visibleCount = projection == .dashboard ? intervalCount : 288
        let recentBins = makeCarriedBins(
            rows: sorted,
            start: recentStart.addingTimeInterval(Double(intervalCount - visibleCount) * recentInterval),
            count: visibleCount,
            interval: recentInterval,
            maxCarryGap: maxCarryGap,
            now: now
        )

        var hourlyBins: [QuotaHistoryRecentBucket] = []
        var daily: [QuotaHistoryDailyBucket] = []
        if projection == .dashboard {
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let hourlyCount = 365 * 24
            let hourlyStart = calendar.date(byAdding: .hour, value: -(hourlyCount - 1), to: currentHour) ?? currentHour
            hourlyBins = makeCarriedBins(
                rows: sorted, start: hourlyStart, count: hourlyCount, interval: 60 * 60,
                maxCarryGap: maxCarryGap, now: now
            )
            let startDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -364, to: now) ?? now)
            var grouped: [Date: DailyQuotaTotals] = [:]
            for row in sorted where row.createdAt >= startDay {
                grouped[calendar.startOfDay(for: row.createdAt), default: DailyQuotaTotals()].add(row)
            }
            daily = (0..<365).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
                return (grouped[date] ?? DailyQuotaTotals()).bucket(at: date)
            }
        }

        let identity = sorted.last(where: { $0.identityVersion != nil }).flatMap { row in
            QuotaHistoryIdentity(version: row.identityVersion ?? 0, homeIdentity: row.homeIdentity,
                stableAccountKey: row.stableAccountKey, planType: row.identityPlanType,
                limitID: row.identityLimitID)
        }
        let observations = raw.compactMap { row -> QuotaCycleObservation? in
            guard let used = row.sevenDayUsedPercent else { return nil }
            return QuotaCycleObservation(at: row.createdAt, usedPercent: used, resetsAt: row.sevenDayResetsAt ?? .distantPast)
        }
        let cycles = QuotaActualCycleProjector.projectWithDiagnostics(observations, now: now) { start, end in
            guard let home = identity?.homeIdentity else { return .unknown }
            return lookup(URL(fileURLWithPath: home), start, end)
        }
        return QuotaHistorySnapshot(daily: daily, recentBins: recentBins, hourlyBins: hourlyBins,
            latest: sorted.last?.createdAt,
            actualCycles: cycles.cycles, cycleIdentity: identity, cycleDiagnostics: cycles.diagnostics)
    }

    private static func sanitizedRows(_ rows: [QuotaHistoryRow], now: Date, filterAnomalies: Bool = true, consumption: (URL, Date, Date) -> QuotaCycleConsumption = { _, _, _ in .unknown }) -> [QuotaHistoryRow] {
        guard let first = rows.first else { return [] }
        if let account = first.stableAccountKey {
            let home = first.homeIdentity ?? ""
            let plan = first.identityPlanType ?? ""
            let limit = first.identityLimitID ?? ""
            var previous: Date?
            let oneOrderedScope = rows.allSatisfy { row in
                guard row.stableAccountKey == account, (row.homeIdentity ?? "") == home,
                      (row.identityPlanType ?? "") == plan, (row.identityLimitID ?? "") == limit,
                      previous.map({ row.createdAt.timeIntervalSince($0) > 0.000_001 }) ?? true else { return false }
                previous = row.createdAt
                return true
            }
            if oneOrderedScope {
                return projectOrderedTimeline(rows, now: now, filterAnomalies: filterAnomalies, consumption: consumption)
            }
        }

        var groups: [[String]: [QuotaHistoryRow]] = [:]
        var legacyScopes: [String: Set<[String]>] = [:]
        if rows.contains(where: { $0.stableAccountKey == nil }) {
            for row in rows {
                if let account = row.stableAccountKey {
                    legacyScopes[row.historyMatchKey, default: []].insert(
                        [row.homeIdentity ?? "", account, row.identityPlanType ?? "", row.identityLimitID ?? ""]
                    )
                }
            }
        }
        for row in rows.sorted(by: { $0.createdAt < $1.createdAt }) {
            let scope: [String]
            if let account = row.stableAccountKey {
                scope = [row.homeIdentity ?? "", account, row.identityPlanType ?? "", row.identityLimitID ?? ""]
            } else {
                let key = row.historyMatchKey
                if let candidates = legacyScopes[key], candidates.count == 1, let single = candidates.first {
                    scope = single
                } else {
                    scope = [key]
                }
            }
            if let last = groups[scope]?.last, !(row.createdAt.timeIntervalSince(last.createdAt) > 0.000_001) { continue }
            groups[scope, default: []].append(row)
        }
        return groups.values.flatMap {
            projectOrderedTimeline($0, now: now, filterAnomalies: filterAnomalies, consumption: consumption)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private static func projectOrderedTimeline(
        _ rows: [QuotaHistoryRow], now: Date, filterAnomalies: Bool, consumption: (URL, Date, Date) -> QuotaCycleConsumption
    ) -> [QuotaHistoryRow] {
        var timeline = rows.map { $0.reclassifyingLegacySevenDayOnlyWindow() }
        let projection: QuotaHistoryProtection.Projection
        if filterAnomalies {
            let samples = timeline.map { row in
                QuotaHistoryProtection.Sample(at: row.createdAt.timeIntervalSince1970,
                    fiveUsed: row.fiveHourUsedPercent, fiveReset: row.fiveHourResetsAt?.timeIntervalSince1970,
                    sevenUsed: row.sevenDayUsedPercent, sevenReset: row.sevenDayResetsAt?.timeIntervalSince1970)
            }
            let plan = timeline.first(where: { $0.identityPlanType != nil })?.identityPlanType ?? timeline.first?.planType
            let home = timeline.first?.homeIdentity.map { URL(fileURLWithPath: $0) }
            projection = QuotaHistoryProtection.project(samples, plan: plan, now: now.timeIntervalSince1970) { start, end in
                guard let home else { return .unknown }
                return consumption(home, start, end)
            }
        } else {
            projection = QuotaHistoryProtection.Projection()
        }

        for index in timeline.indices {
            let row = timeline[index]
            timeline[index] = row.projecting(
                fiveUsed: projection.fiveRejected.contains(index) ? nil : QuotaHistoryProtection.valid(row.fiveHourUsedPercent),
                fiveReset: row.fiveHourResetsAt,
                sevenUsed: projection.sevenRejected.contains(index) ? nil : QuotaHistoryProtection.valid(row.sevenDayUsedPercent),
                sevenReset: row.sevenDayResetsAt)
        }
        // Keep the protection sample indices and recompute cycles from the
        // surviving values. Rejected observations cannot add an anchor.
        applyCycleMetadata(to: &timeline, preserveLatestTarget: false)
        for index in timeline.indices {
            let fiveBridgeEnd = projection.fiveBridges[index].map { timeline[$0].createdAt }
            let sevenBridgeEnd = projection.sevenBridges[index].map { timeline[$0].createdAt }
            timeline[index].fiveRejected = projection.fiveRejected.contains(index)
            timeline[index].sevenRejected = projection.sevenRejected.contains(index)
            timeline[index].fiveBridgeEnd = fiveBridgeEnd
            timeline[index].sevenBridgeEnd = sevenBridgeEnd
        }
        return timeline
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
        var fiveIndex = 0
        var sevenIndex = 0
        var latestFive: QuotaHistoryRow?
        var latestSeven: QuotaHistoryRow?

        func advanceWindow(
            index: inout Int, latest: inout QuotaHistoryRow?,
            rejected: KeyPath<QuotaHistoryRow, Bool>, through upperBound: Date
        ) -> QuotaHistoryRow? {
            while index < rows.count {
                let row = rows[index]
                if !row[keyPath: rejected] {
                    if !(row.createdAt <= upperBound) { return row }
                    latest = row
                }
                index += 1
            }
            return nil
        }

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
                rowIndex += 1
            }
            let nextFive = advanceWindow(index: &fiveIndex, latest: &latestFive,
                rejected: \.fiveRejected, through: inclusiveUpperBound)
            let nextSeven = advanceWindow(index: &sevenIndex, latest: &latestSeven,
                rejected: \.sevenRejected, through: inclusiveUpperBound)
            let observations = rows[firstUnreadRowIndex..<rowIndex].drop { $0.createdAt < binStart }

            return QuotaHistoryRecentBucket(
                start: binStart,
                fiveHourRemainingPercent: quotaRemaining(
                    from: latestFive,
                    to: nextFive,
                    previousBoundary: binStart,
                    at: sampleDate,
                    maxCarryGap: maxCarryGap,
                    remaining: \.fiveHourRemainingPercent,
                    resetsAt: \.fiveHourResetsAt,
                    bridgeEnd: \.fiveBridgeEnd,
                    sameCycle: { $0.isSameFiveHourCycle(as: $1) }
                ),
                sevenDayRemainingPercent: quotaRemaining(
                    from: latestSeven,
                    to: nextSeven,
                    previousBoundary: binStart,
                    at: sampleDate,
                    maxCarryGap: maxCarryGap,
                    remaining: \.sevenDayRemainingPercent,
                    resetsAt: \.sevenDayResetsAt,
                    bridgeEnd: \.sevenBridgeEnd,
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
        bridgeEnd: KeyPath<QuotaHistoryRow, Date?>,
        sameCycle: (QuotaHistoryRow, QuotaHistoryRow) -> Bool
    ) -> Double? {
        guard let row, let value = row[keyPath: remaining] else { return nil }

        if let nextRow, row[keyPath: bridgeEnd] == nextRow.createdAt,
           let endValue = nextRow[keyPath: remaining], date > row.createdAt, date < nextRow.createdAt {
            let fraction = date.timeIntervalSince(row.createdAt) / nextRow.createdAt.timeIntervalSince(row.createdAt)
            return value + (endValue - value) * fraction
        }
        if let resetDate = row[keyPath: resetsAt], resetDate > row.createdAt {
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

    private struct DailyQuotaTotals {
        var first: Date?
        var last: Date?
        var count = 0
        var fiveCount = 0
        var sevenCount = 0
        var fiveTotal = 0.0
        var sevenTotal = 0.0

        mutating func add(_ row: QuotaHistoryRow) {
            first = first ?? row.createdAt
            last = row.createdAt
            count += 1
            if let value = row.fiveHourRemainingPercent {
                fiveTotal += value; fiveCount += 1
            }
            if let value = row.sevenDayRemainingPercent {
                sevenTotal += value; sevenCount += 1
            }
        }

        func bucket(at date: Date) -> QuotaHistoryDailyBucket {
            QuotaHistoryDailyBucket(
                date: date,
                fiveHourRemainingPercent: fiveCount > 0 ? fiveTotal / Double(fiveCount) : nil,
                sevenDayRemainingPercent: sevenCount > 0 ? sevenTotal / Double(sevenCount) : nil,
                sampleCount: count, fiveHourSampleCount: fiveCount, sevenDaySampleCount: sevenCount,
                firstObservedAt: first, lastObservedAt: last
            )
        }
    }

    private struct MergeKey: Hashable {
        let scope: String
        let account: String
        let plan: String
        let limit: String
        let createdAt: UInt64
    }

    /// Merge the two independently written histories by quota identity and
    /// observation. The runtime source is metadata, not a second quota: Swift
    /// and Tauri can record the same percentage at the same instant, and that
    /// cross-platform duplicate should be removed before sanitizing and
    /// interpolating the series. Genuinely different observations remain
    /// ordered by timestamp.
    private func mergedRows(_ rows: [QuotaHistoryRow]) -> [QuotaHistoryRow] {
        // The local timeline is ordered and usually has distinct times.
        // There is nothing to merge unless some observation time repeats or
        // a peer timeline needs to be placed into chronological order.
        var previousTime = -Double.infinity
        let strictlyOrdered = rows.allSatisfy { row in
            let time = row.createdAt.timeIntervalSince1970
            guard time > previousTime else { return false }
            previousTime = time
            return true
        }
        if strictlyOrdered { return rows }

        var unique: [MergeKey: QuotaHistoryRow] = [:]
        for row in rows {
            let identity = stableIdentity(from: row)
            let hasStableIdentity = identity != nil
            let key = MergeKey(
                scope: mergeScope(for: row, identity: identity),
                // Stable identity is authoritative even if one runtime has a
                // missing or differently formatted display name. Legacy rows
                // still require the account/plan/limit fallback to stay safe.
                account: hasStableIdentity ? "" : row.historyMatchKey,
                plan: hasStableIdentity ? "" : canonicalMergeValue(row.planType),
                limit: hasStableIdentity ? "" : canonicalMergeValue(row.limitName),
                createdAt: row.createdAt.timeIntervalSince1970.bitPattern
            )
            guard let previous = unique[key] else {
                unique[key] = row
                continue
            }

            // Match the peer reader's deterministic source precedence. Two
            // conflicting rows with one observation time are one observation,
            // never two votes toward confirming a lower value.
            func rank(_ row: QuotaHistoryRow) -> Int {
                switch canonicalSource(row.source) {
                case "tauri": 2
                case "swift": 1
                default: 0
                }
            }
            let currentKey = [row.fiveHourUsedPercent.map(String.init) ?? "", row.sevenDayUsedPercent.map(String.init) ?? "", row.status].joined(separator: "|")
            let previousKey = [previous.fiveHourUsedPercent.map(String.init) ?? "", previous.sevenDayUsedPercent.map(String.init) ?? "", previous.status].joined(separator: "|")
            if rank(row) > rank(previous) || (rank(row) == rank(previous) && currentKey > previousKey) {
                unique[key] = row
            }
        }
        return unique.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return canonicalSource($0.source) < canonicalSource($1.source)
        }
    }

    private func mergeScope(for row: QuotaHistoryRow, identity: QuotaHistoryIdentity?) -> String {
        if let identity {
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
                busyTimeoutMilliseconds: Self.peerReadBusyTimeoutMilliseconds,
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

    private func cycleColumnProjection(
        _ database: DatabaseAccessing,
        includeCycleMetadata: Bool
    ) throws -> String {
        if includeCycleMetadata {
            return "id, five_hour_cycle_generation, five_hour_reset_anchor, seven_day_cycle_generation, seven_day_reset_anchor"
        }
        let columns = Set(try database.readRows("PRAGMA table_info(quota_snapshots);") {
            ($0.text(1) ?? "").lowercased()
        })
        // Preserve each readable legacy value even if another cycle column
        // is missing. Keep the historical NULL row-id slot for this fallback.
        let fields = [
            ("five_hour_cycle_generation", "NULL"), ("five_hour_reset_anchor", "0"),
            ("seven_day_cycle_generation", "NULL"), ("seven_day_reset_anchor", "0")
        ]
        return (["NULL"] + fields.map { name, fallback in
            columns.contains(name) ? SQLiteStoreNamespace.quote(name) : fallback
        }).joined(separator: ", ")
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

        // Policy 3 replays raw observations. Equal lower samples are evidence;
        // neither reset-only deletion nor historical anchor rewriting is safe.
        let deleted = 0
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
        return Self.sanitizedRows(rawRows, now: now, filterAnomalies: filterAnomalies()).last
    }

    private func matchingHistoryRows(row: QuotaHistoryRow, cutoff: Date?, now: Date) throws -> [QuotaHistoryRow] {
        guard let url = databaseURL ?? Self.defaultDatabaseURL else { throw BusinessStoreError.invalidStore }
        if BusinessSQLiteRoutes.hasPublishedAdmission, BusinessSQLiteRoutes.store(for: url) == nil {
            throw PublishedBusinessAdmission.Deferred(message: "该额度来源没有已核实的已发布分区，旧材料已保留")
        }
        if let owner = BusinessSQLiteRoutes.store(for: url),
           BusinessSQLiteRoutes.isRegistered(owner) || BusinessSQLiteRoutes.writesArePaused(for: owner) {
            let reader = SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false,
                busyTimeoutMilliseconds: 3_000, enableWAL: false, fileManager: fileManager)
            return try reader.withConnection { db in try db.readTransaction { tx in
                guard try peerSupportsStableIdentitySchema(tx) else { throw BusinessStoreError.unsupportedSchema("quota stable identity") }
                return try matchingRows(database: tx, row: row, cutoff: cutoff, now: now,
                    allowClaimWrites: false, includeCycleMetadata: peerSupportsCycleSchema(tx))
            } }
        }
        return try withDatabase { db in
            try ensureSchema(db)
            return try matchingRows(database: db, row: row, cutoff: cutoff, now: now)
        }
    }

    private func matchingRows(
        database: SQLiteDatabaseConnection,
        row: QuotaHistoryRow,
        cutoff: Date?,
        now: Date,
        allowClaimWrites: Bool = true,
        includeCycleMetadata: Bool = true
    ) throws -> [QuotaHistoryRow] {
        guard let identity = stableIdentity(from: row) else { return [] }
        var matched = try stableRows(database: database, identity: identity, cutoff: cutoff, includeCycleMetadata: includeCycleMetadata)
        let legacyCutoff = cutoff ?? .distantPast
        var appendedLegacyRows = false
        for bridge in legacyBridges(row: row, identity: identity) {
            let legacyRows = try legacyRows(
                database: database,
                bridge: bridge,
                cutoff: legacyCutoff,
                includeCycleMetadata: includeCycleMetadata
            )
            guard !legacyRows.isEmpty else { continue }
            let knownAmbiguous = try legacyBridgeHasOtherStableIdentity(
                database: database,
                bridge: bridge,
                identity: identity
            )
            let claimed: Bool
            if allowClaimWrites {
                claimed = try claimLegacyBridge(database: database, bridge: bridge, identity: identity,
                    knownAmbiguous: knownAmbiguous, now: now)
            } else {
                let hasClaims = try database.readRows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='quota_history_legacy_claims'",map:{$0.int(0)}).first == 1
                let existing = hasClaims ? try legacyBridgeClaim(database: database, bridge: bridge) : nil
                claimed = !knownAmbiguous && existing?.state == "claimed" && existing?.belongs(to: identity) == true
            }
            if claimed {
                matched.append(contentsOf: legacyRows)
                appendedLegacyRows = true
            }
        }
        if appendedLegacyRows { matched.sort { $0.createdAt < $1.createdAt } }
        return matched
    }

    private func stableRows(
        database: DatabaseAccessing,
        identity: QuotaHistoryIdentity,
        cutoff: Date?,
        includeCycleMetadata: Bool = true
    ) throws -> [QuotaHistoryRow] {
        let cycleColumns = try cycleColumnProjection(database, includeCycleMetadata: includeCycleMetadata)
        let (sql, bindings) = stableTimelineQuery(columns: """
            created_at, account_key, plan_type, limit_name, account_name,
            source, five_hour_used_percent, five_hour_resets_at,
            seven_day_used_percent, seven_day_resets_at, status,
            identity_version, home_identity, stable_account_key,
            identity_plan_type, identity_limit_id, \(cycleColumns)
            """, identity: identity, cutoff: cutoff)
        return try rows(database: database, sql: sql, bindings: bindings)
    }

    private func stableTimelineQuery(columns: String, identity: QuotaHistoryIdentity, cutoff: Date?)
        -> (String, [SQLiteBinding]) {
        var sql = """
        SELECT \(columns)
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
        return (sql, bindings)
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
        cutoff: Date,
        includeCycleMetadata: Bool = true,
        limitOne: Bool = false
    ) throws -> [QuotaHistoryRow] {
        let cycleColumns = try cycleColumnProjection(database, includeCycleMetadata: includeCycleMetadata)
        return try rows(
            database: database,
            sql: """
            SELECT created_at, account_key, plan_type, limit_name, account_name,
                   source, five_hour_used_percent, five_hour_resets_at,
                   seven_day_used_percent, seven_day_resets_at, status,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id,
                   \(cycleColumns)
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
            ORDER BY created_at DESC \(limitOne ? "LIMIT 1" : "");
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
        if let store = BusinessSQLiteRoutes.store(for: url) {
            _ = try? BusinessDatabaseMaintenance.run(container: store.containerURL)
            return
        }
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
        ApplicationStorageLocation.directory(.applicationSupportDirectory)?
            .appendingPathComponent("CodexTokenBar", isDirectory: true)
            .appendingPathComponent("quota-history.sqlite")
    }

    private static var defaultPeerDatabaseURL: URL? {
        ApplicationStorageLocation.directory(.applicationSupportDirectory)?
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
