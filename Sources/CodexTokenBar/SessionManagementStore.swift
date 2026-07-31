import Foundation

enum SessionManagementSelectionPolicy {
    static func canSelect(_ thread: SessionManagementThread) -> Bool {
        !thread.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SessionManagementBatchDeletionFailure: Equatable, Sendable {
    let threadID: String
    let title: String
    let reason: String
    let recoveryPackageURL: URL?
}

struct SessionManagementBatchDeletionResult: Equatable, Sendable {
    let succeededThreadIDs: [String]
    let failures: [SessionManagementBatchDeletionFailure]
    let recoveryPackageURLs: [String: URL]
    let affectedCount: Int
    let indirectDescendantCount: Int
}

enum SessionManagementBatchDeletion {
    static func run(
        confirmation: SessionManagementDeletionConfirmation,
        service: any SessionManagementServicing,
        dataSource: CodexDataSource
    ) async -> SessionManagementBatchDeletionResult {
        let confirmedImpact = confirmation.impact
        let requestedIDs = Set(confirmedImpact.requested.map(\.id))
        guard !requestedIDs.isEmpty else {
            return SessionManagementBatchDeletionResult(
                succeededThreadIDs: [],
                failures: [],
                recoveryPackageURLs: [:],
                affectedCount: 0,
                indirectDescendantCount: 0
            )
        }
        guard dataSource.homeIdentity == confirmation.codexHomeIdentity,
              Set(confirmation.rolloutSnapshotsByThreadID.keys)
                == Set(confirmedImpact.affected.map(\.id)),
              confirmation.rolloutSnapshotsByThreadID.allSatisfy({
                  $0.key == $0.value.threadID
              }) else {
            return failedResult(
                requested: confirmedImpact.requested,
                reason: "删除未开始：确认时 Codex Home 或 rollout 物理快照不完整。",
                recoveryPackageURLs: [:],
                impact: confirmedImpact
            )
        }
        var recoveryPackageURLs: [String: URL] = [:]
        var recoveryPackages: [String: SessionManagementRecoveryPackageResult] = [:]
        let initialCatalog: SessionManagementCatalog
        do {
            initialCatalog = try await service.loadCatalog(dataSource: dataSource)
        } catch {
            return failedResult(
                requested: confirmedImpact.requested,
                reason: "删除未开始：无法重新读取官方会话目录：\(error.localizedDescription)",
                recoveryPackageURLs: recoveryPackageURLs
            )
        }
        guard initialCatalog.deletionVerificationComplete else {
            return failedResult(
                requested: confirmedImpact.requested,
                reason: "删除未开始：当前官方与本地会话目录读取不完整，不能验证完整递归影响范围。",
                recoveryPackageURLs: recoveryPackageURLs
            )
        }
        let initialImpact = SessionManagementPresentation.deletionImpact(
            threads: initialCatalog.threads,
            selectedThreadIDs: requestedIDs
        )
        guard scopeMatches(initialImpact, confirmedImpact) else {
            return failedResult(
                requested: confirmedImpact.requested,
                reason: "删除未开始：当前删除根或递归影响范围与确认画面不一致，请重新核对。",
                recoveryPackageURLs: recoveryPackageURLs,
                impact: initialImpact
            )
        }
        if let reason = unsafeReason(impact: initialImpact) {
            return failedResult(
                requested: initialImpact.requested,
                reason: "删除未开始：\(reason)",
                recoveryPackageURLs: recoveryPackageURLs,
                impact: initialImpact
            )
        }

        // Codex official delete recursively removes spawned descendants.
        // Package and verify every affected rollout before the first root
        // deletion so a root can never erase an unprotected child.
        for thread in initialImpact.affected {
            do {
                try Task.checkCancellation()
                let package = try await service.createRecoveryPackage(
                    thread: thread,
                    dataSource: dataSource,
                    expectedSnapshot:
                        confirmation.rolloutSnapshotsByThreadID[thread.id]
                )
                recoveryPackages[thread.id] = package
                recoveryPackageURLs[thread.id] = package.packageURL
            } catch let error as SessionManagementPublishedRecoveryPackageError {
                recoveryPackages[thread.id] = error.result
                recoveryPackageURLs[thread.id] = error.result.packageURL
                return failedResult(
                    requested: initialImpact.requested,
                    reason:
                        "删除未开始：受影响会话 \(thread.displayTitle) 的恢复包虽已发布，但最终复核失败：\(error.detail)",
                    recoveryPackageURLs: recoveryPackageURLs,
                    impact: initialImpact
                )
            } catch {
                return failedResult(
                    requested: initialImpact.requested,
                    reason:
                        "删除未开始：受影响会话 \(thread.displayTitle) 的恢复包创建或校验失败：\(error.localizedDescription)",
                    recoveryPackageURLs: recoveryPackageURLs,
                    impact: initialImpact
                )
            }
        }

        let refreshedCatalog: SessionManagementCatalog
        do {
            refreshedCatalog = try await service.loadCatalog(dataSource: dataSource)
        } catch {
            return failedResult(
                requested: initialImpact.requested,
                reason: "删除未开始：恢复包完成后的目录复核失败：\(error.localizedDescription)",
                recoveryPackageURLs: recoveryPackageURLs,
                impact: initialImpact
            )
        }
        guard refreshedCatalog.deletionVerificationComplete else {
            return failedResult(
                requested: initialImpact.requested,
                reason: "删除未开始：恢复包完成后的官方与本地目录读取不完整，不能再次验证递归影响范围。",
                recoveryPackageURLs: recoveryPackageURLs,
                impact: initialImpact
            )
        }
        let refreshedImpact = SessionManagementPresentation.deletionImpact(
            threads: refreshedCatalog.threads,
            selectedThreadIDs: requestedIDs
        )
        guard scopeMatches(refreshedImpact, confirmedImpact),
              unsafeReason(impact: refreshedImpact) == nil else {
            return failedResult(
                requested: initialImpact.requested,
                reason: "删除未开始：准备期间 spawned 后代范围或安全状态发生变化，请刷新后重试。",
                recoveryPackageURLs: recoveryPackageURLs,
                impact: refreshedImpact
            )
        }

        var firstFailureReason: String?
        var completedRootIDs: [String] = []
        for (rootIndex, root) in confirmedImpact.effectiveRoots.enumerated() {
            do {
                try Task.checkCancellation()
                _ = try await service.delete(
                    rootID: root.id,
                    expectation: SessionManagementDeletionExpectation(
                        confirmation: confirmation,
                        pendingRootIndex: rootIndex,
                        requiresRecoveryEvidence: true
                    ),
                    recoveryPackages: recoveryPackages,
                    dataSource: dataSource
                )
                completedRootIDs.append(root.id)
            } catch {
                firstFailureReason =
                    "删除根 \(root.displayTitle) 未获得确定成功回执，后续根未再执行：\(error.localizedDescription)"
                break
            }
        }
        let finalCatalog: SessionManagementCatalog
        do {
            finalCatalog = try await service.loadCatalog(dataSource: dataSource)
        } catch {
            return failedResult(
                requested: confirmedImpact.requested,
                reason: firstFailureReason
                    ?? "删除命令结束后无法完整重读官方目录，结果保持待确认：\(error.localizedDescription)",
                recoveryPackageURLs: recoveryPackageURLs,
                impact: confirmedImpact
            )
        }
        guard finalCatalog.deletionVerificationComplete else {
            return failedResult(
                requested: confirmedImpact.requested,
                reason: firstFailureReason
                    ?? "删除命令结束后的目录读取并不完整，不能把部分目录缺失视为删除成功。",
                recoveryPackageURLs: recoveryPackageURLs,
                impact: confirmedImpact
            )
        }

        let finalIDs = Set(finalCatalog.threads.map(\.id))
        let completedRootSet = Set(completedRootIDs)
        var provenRootIDs = Set<String>()
        var unverifiedCompletedRootReasons: [String: String] = [:]
        for rootID in completedRootIDs {
            let closureIDs = Set(confirmedImpact.affected.compactMap {
                confirmedImpact.coveringRootIDByThreadID[$0.id] == rootID
                    ? $0.id
                    : nil
            })
            if let remainingID = closureIDs.intersection(finalIDs).sorted().first {
                unverifiedCompletedRootReasons[rootID] =
                    "官方命令返回成功，但严格目录复核仍发现冻结闭包会话 \(remainingID)。"
                continue
            }
            if let dangling = descendantsStillReferencing(
                affectedIDs: closureIDs,
                threads: finalCatalog.threads
            ).first {
                unverifiedCompletedRootReasons[rootID] =
                    "官方命令返回成功，但严格目录复核仍发现会话 \(dangling.id) 指向该冻结闭包。"
                continue
            }
            provenRootIDs.insert(rootID)
        }

        let succeeded = confirmedImpact.requested.compactMap { thread -> String? in
            guard let rootID =
                    confirmedImpact.coveringRootIDByThreadID[thread.id],
                  provenRootIDs.contains(rootID) else {
                return nil
            }
            return thread.id
        }
        let succeededSet = Set(succeeded)
        let failures = confirmedImpact.requested.compactMap {
            thread -> SessionManagementBatchDeletionFailure? in
            guard !succeededSet.contains(thread.id) else { return nil }
            let rootID =
                confirmedImpact.coveringRootIDByThreadID[thread.id] ?? thread.id
            let reason: String
            if completedRootSet.contains(rootID) {
                reason = unverifiedCompletedRootReasons[rootID]
                    ?? "官方命令返回成功，但无法严格证明该冻结闭包已经完整消失。"
            } else {
                reason = firstFailureReason
                    ?? "该删除根未执行，或没有获得确定成功回执。"
            }
            return SessionManagementBatchDeletionFailure(
                threadID: thread.id,
                title: thread.displayTitle,
                reason: reason,
                recoveryPackageURL: recoveryPackageURLs[thread.id]
            )
        }
        return SessionManagementBatchDeletionResult(
            succeededThreadIDs: succeeded,
            failures: failures,
            recoveryPackageURLs: recoveryPackageURLs,
            affectedCount: confirmedImpact.affected.count,
            indirectDescendantCount: confirmedImpact.indirectDescendants.count
        )
    }

    private static func scopeMatches(
        _ current: SessionManagementDeletionImpact,
        _ confirmed: SessionManagementDeletionImpact
    ) -> Bool {
        Set(current.requested.map(\.id)) == Set(confirmed.requested.map(\.id))
            && current.effectiveRoots.map(\.id)
                == confirmed.effectiveRoots.map(\.id)
            && Set(current.affected.map(\.id))
                == Set(confirmed.affected.map(\.id))
            && current.coveringRootIDByThreadID
                == confirmed.coveringRootIDByThreadID
    }

    private static func descendantsStillReferencing(
        affectedIDs: Set<String>,
        threads: [SessionManagementThread]
    ) -> [SessionManagementThread] {
        var closure = affectedIDs
        var found: [SessionManagementThread] = []
        var changed = true
        while changed {
            changed = false
            for thread in threads where !closure.contains(thread.id) {
                guard let parent = thread.parentThreadID,
                      closure.contains(parent) else { continue }
                closure.insert(thread.id)
                found.append(thread)
                changed = true
            }
        }
        return found
    }

    private static func unsafeReason(
        impact: SessionManagementDeletionImpact
    ) -> String? {
        if let blocked = impact.affected.first(where: {
            !$0.status.permitsMutation || !$0.rolloutIdentityVerified || !$0.canDelete
        }) {
            return "受影响会话 \(blocked.displayTitle) 正在运行、加载、受保护或身份无法验证。"
        }
        return nil
    }

    private static func failedResult(
        requested: [SessionManagementThread],
        reason: String,
        recoveryPackageURLs: [String: URL],
        impact: SessionManagementDeletionImpact = .empty
    ) -> SessionManagementBatchDeletionResult {
        SessionManagementBatchDeletionResult(
            succeededThreadIDs: [],
            failures: requested.map {
                SessionManagementBatchDeletionFailure(
                    threadID: $0.id,
                    title: $0.displayTitle,
                    reason: reason,
                    recoveryPackageURL: recoveryPackageURLs[$0.id]
                )
            },
            recoveryPackageURLs: recoveryPackageURLs,
            affectedCount: impact.affected.count,
            indirectDescendantCount: impact.indirectDescendants.count
        )
    }
}

@MainActor
final class SessionManagementStore: ObservableObject {
    @Published private(set) var catalog: SessionManagementCatalog
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isLoadingContext = false
    @Published private(set) var isPreparingDeletionConfirmation = false
    @Published private(set) var isPerformingMutation = false
    @Published private(set) var contextMessages: [SessionManagementContextMessage] = []
    @Published private(set) var contextWarnings: [String] = []
    @Published private(set) var contextHasMoreBefore = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var operationSummary: String?
    @Published private(set) var operationSummaryHasFailures = false
    @Published private(set) var lastRecoveryPackageURL: URL?
    @Published var selectedCollection: SessionManagementCollection = .all {
        didSet { visibleLimit = SessionManagementPresentation.visiblePageSize }
    }
    @Published var selectedProjectID: String? {
        didSet { visibleLimit = SessionManagementPresentation.visiblePageSize }
    }
    @Published var query = "" {
        didSet { resultFilterDidChange() }
    }
    @Published var sort: SessionManagementSort = .recent {
        didSet { visibleLimit = SessionManagementPresentation.visiblePageSize }
    }
    @Published var inactivityFilter: SessionManagementInactivityFilter = .any {
        didSet { resultFilterDidChange() }
    }
    @Published var customInactiveDaysText = "14" {
        didSet { resultFilterDidChange() }
    }
    @Published var minimumBytes: Int64? = SessionManagementPresentation.largeThreadThreshold {
        didSet { resultFilterDidChange() }
    }
    @Published private(set) var visibleLimit = SessionManagementPresentation.visiblePageSize
    @Published var selectedThreadID: String?
    @Published var checkedThreadIDs = Set<String>()

    let dataSource: CodexDataSource?
    private let service: any SessionManagementServicing
    private let autoResumeManager: AutoResumeTaskManager?
    private let mutationOwnerID =
        "session-management-\(UUID().uuidString.lowercased())-\(ProcessInfo.processInfo.processIdentifier)"
    private var contextBeforeOffset: Int64?
    private var contextIdentity: SessionManagementFileIdentity?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var contextTask: Task<Void, Never>?
    private var contextGeneration = 0

    init(
        dataSource: CodexDataSource?,
        service: any SessionManagementServicing = FoundationSessionManagementBackend(),
        autoResumeManager: AutoResumeTaskManager? = nil
    ) {
        self.dataSource = dataSource
        self.service = service
        self.autoResumeManager = autoResumeManager
        catalog = .empty(codexHome: dataSource?.displayPath ?? "")
    }

    deinit {
        refreshTask?.cancel()
        contextTask?.cancel()
    }

    var projects: [SessionManagementProject] {
        SessionManagementPresentation.projects(from: catalog.threads)
    }

    var matchingThreads: [SessionManagementThread] {
        var rows = SessionManagementPresentation.filteredThreads(
            in: catalog,
            collection: selectedCollection,
            projectID: selectedProjectID,
            query: query,
            sort: sort,
            inactivityFilter: inactivityFilter,
            customInactiveDays: customInactiveDays
        )
        if selectedCollection == .large {
            if let minimumBytes {
                rows = rows.filter { ($0.fileBytes ?? -1) >= minimumBytes }
            }
        }
        return rows
    }

    var customInactiveDays: Int? {
        let trimmed = customInactiveDaysText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    var isCustomInactiveDaysValid: Bool {
        !inactivityFilter.requiresCustomDays || customInactiveDays != nil
    }

    var visibleThreads: [SessionManagementThread] {
        SessionManagementPresentation.visibleThreads(
            matchingThreads,
            limit: visibleLimit,
            selectedThreadID: selectedThreadID
        )
    }

    var hiddenThreadCount: Int {
        max(0, matchingThreads.count - min(visibleLimit, matchingThreads.count))
    }

    var selectedThread: SessionManagementThread? {
        guard let selectedThreadID else { return nil }
        return catalog.threads.first { $0.id == selectedThreadID }
    }

    var checkedThreads: [SessionManagementThread] {
        catalog.threads.filter { checkedThreadIDs.contains($0.id) }
    }

    var checkedOutsideCurrentResultsCount: Int {
        let matchingIDs = Set(matchingThreads.map(\.id))
        return checkedThreadIDs.filter { !matchingIDs.contains($0) }.count
    }

    var checkedBytes: Int64? {
        let rows = checkedThreads
        guard rows.allSatisfy({ $0.fileBytes != nil }) else { return nil }
        return rows.reduce(0) { $0 + max(0, $1.fileBytes ?? 0) }
    }

    var deletionImpact: SessionManagementDeletionImpact {
        let selectedIDs = Set(
            (checkedThreads.isEmpty
                ? selectedThread.map { [$0] } ?? []
                : checkedThreads)
                .map(\.id)
        )
        return SessionManagementPresentation.deletionImpact(
            threads: catalog.threads,
            selectedThreadIDs: selectedIDs
        )
    }

    var deletionBlockedAffectedThreads: [SessionManagementThread] {
        let protected = autoResumeManager?.protectedThreadIDs ?? []
        return deletionImpact.affected.filter {
            !$0.status.permitsMutation
                || !$0.rolloutIdentityVerified
                || !$0.canDelete
                || protected.contains($0.id)
        }
    }

    @discardableResult
    func refresh(
        preservingError: Bool = false
    ) -> Task<Void, Never>? {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let dataSource else {
            isLoadingCatalog = false
            errorMessage = "没有可用的 Codex 数据目录"
            return nil
        }
        isLoadingCatalog = true
        if !preservingError {
            errorMessage = nil
        }
        statusMessage = "正在读取会话目录…"
        let task = Task { [weak self, service] in
            do {
                let catalog = try await service.loadCatalog(dataSource: dataSource)
                try Task.checkCancellation()
                guard let self, self.refreshGeneration == generation else { return }
                self.catalog = catalog
                self.checkedThreadIDs.formIntersection(catalog.threads.map(\.id))
                if let selectedThreadID = self.selectedThreadID,
                   !catalog.threads.contains(where: { $0.id == selectedThreadID }) {
                    self.selectedThreadID = nil
                    self.clearContext()
                }
                self.statusMessage = "已读取 \(catalog.threads.count) 个会话"
                self.isLoadingCatalog = false
                self.selectFirstVisibleIfNeeded()
            } catch is CancellationError {
                guard let self, self.refreshGeneration == generation else { return }
                self.isLoadingCatalog = false
            } catch {
                guard let self, self.refreshGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
                self.statusMessage = "会话目录读取失败"
                self.isLoadingCatalog = false
            }
        }
        refreshTask = task
        return task
    }

    func selectCollection(_ collection: SessionManagementCollection) {
        selectedCollection = collection
        selectedProjectID = nil
        if collection == .large {
            sort = .size
        }
        selectFirstVisibleIfNeeded()
    }

    func selectProject(_ projectID: String) {
        selectedCollection = .all
        selectedProjectID = projectID
        selectFirstVisibleIfNeeded()
    }

    @discardableResult
    func selectThread(_ threadID: String) -> Task<Void, Never>? {
        guard selectedThreadID != threadID else { return nil }
        selectedThreadID = threadID
        clearContext()
        return loadInitialContext()
    }

    func toggleChecked(_ threadID: String) {
        if checkedThreadIDs.contains(threadID) {
            checkedThreadIDs.remove(threadID)
        } else {
            checkedThreadIDs.insert(threadID)
        }
    }

    func clearChecked() {
        checkedThreadIDs.removeAll()
    }

    func toggleAllVisibleChecked() {
        let selectable = visibleThreads.filter(SessionManagementSelectionPolicy.canSelect)
        let allSelected = !selectable.isEmpty
            && selectable.allSatisfy { checkedThreadIDs.contains($0.id) }
        if allSelected {
            checkedThreadIDs.subtract(selectable.map(\.id))
        } else {
            checkedThreadIDs.formUnion(selectable.map(\.id))
        }
    }

    func showMore() {
        visibleLimit = min(
            matchingThreads.count,
            visibleLimit + SessionManagementPresentation.visiblePageSize
        )
    }

    func collapseVisible() {
        visibleLimit = SessionManagementPresentation.visiblePageSize
    }

    @discardableResult
    func loadInitialContext() -> Task<Void, Never>? {
        guard let thread = selectedThread else { return nil }
        return loadContext(thread: thread, beforeOffset: nil, prepend: false)
    }

    @discardableResult
    func loadOlderContext() -> Task<Void, Never>? {
        guard contextHasMoreBefore,
              let thread = selectedThread,
              let contextBeforeOffset else { return nil }
        return loadContext(
            thread: thread,
            beforeOffset: contextBeforeOffset,
            prepend: true
        )
    }

    func archiveSelected() {
        guard let thread = selectedThread else { return }
        performMutation(actionLabel: "官方归档") { service, dataSource in
            try await service.archive(threadID: thread.id, dataSource: dataSource)
        }
    }

    func unarchiveSelected() {
        guard let thread = selectedThread else { return }
        performMutation(actionLabel: "恢复官方归档") { service, dataSource in
            try await service.unarchive(threadID: thread.id, dataSource: dataSource)
        }
    }

    func prepareDeletionConfirmation()
        async -> SessionManagementDeletionConfirmation? {
        guard !isPreparingDeletionConfirmation,
              !isPerformingMutation,
              let dataSource else {
            return nil
        }
        let impact = deletionImpact
        let selectedIDs = Set(impact.requested.map(\.id))
        guard !selectedIDs.isEmpty else { return nil }
        isPreparingDeletionConfirmation = true
        errorMessage = nil
        statusMessage = "正在冻结 Codex Home 与完整 rollout 内容快照…"
        defer { isPreparingDeletionConfirmation = false }
        do {
            let confirmation = try await service.prepareDeletionConfirmation(
                selectedThreadIDs: selectedIDs,
                dataSource: dataSource
            )
            statusMessage =
                "已冻结 \(confirmation.impact.affected.count) 个会话的确认快照"
            return confirmation
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "删除确认快照建立失败"
            return nil
        }
    }

    func deleteConfirmed(
        confirmation: SessionManagementDeletionConfirmation
    ) {
        let confirmedImpact = confirmation.impact
        guard !confirmedImpact.requested.isEmpty,
              !isPerformingMutation,
              let dataSource else { return }
        guard autoResumeManager?.acquireSessionManagementExecution(
            ownerID: mutationOwnerID
        ) ?? true else {
            errorMessage = "自动续跑正在执行；为避免续跑与删除竞争，本次删除已暂停。"
            return
        }
        isPerformingMutation = true
        errorMessage = nil
        operationSummary = nil
        operationSummaryHasFailures = false
        statusMessage = "正在为完整影响范围创建恢复包并永久删除…"

        let executionManager = autoResumeManager
        let ownerID = mutationOwnerID
        Task { [weak self, service, executionManager] in
            defer {
                executionManager?.releaseSessionManagementExecution(ownerID: ownerID)
            }
            let result = await SessionManagementBatchDeletion.run(
                confirmation: confirmation,
                service: service,
                dataSource: dataSource
            )
            guard let self else { return }

            let succeeded = result.succeededThreadIDs.count
            let failed = result.failures.count
            if let latestPackage = result.recoveryPackageURLs
                .sorted(by: { $0.key < $1.key })
                .last?.value {
                self.lastRecoveryPackageURL = latestPackage
            }
            self.checkedThreadIDs.subtract(result.succeededThreadIDs)
            self.operationSummaryHasFailures = failed > 0
            let recoveryNote: String
            if let package = result.recoveryPackageURLs
                .sorted(by: { $0.key < $1.key })
                .first?.value {
                recoveryNote =
                    "\n已完整校验 \(result.recoveryPackageURLs.count) 个恢复包；目录：\(package.deletingLastPathComponent().path)"
            } else {
                recoveryNote = ""
            }
            if failed == 0 {
                self.operationSummary =
                    "已永久删除 \(succeeded) 个所选会话；官方实际影响 \(result.affectedCount) 个，其中 \(result.indirectDescendantCount) 个是 spawned 后代。\(recoveryNote)"
            } else {
                let details = result.failures.prefix(3).map {
                    "\($0.title)：\($0.reason)"
                }.joined(separator: "\n")
                let remaining = failed > 3 ? "\n另有 \(failed - 3) 项失败。" : ""
                self.operationSummary =
                    "已删除 \(succeeded) 个，\(failed) 个未删除。\n\(details)\(remaining)\(recoveryNote)"
            }
            self.statusMessage = failed == 0
                ? "永久删除完成"
                : "批量删除部分完成"
            self.isPerformingMutation = false
            self.refresh()
        }
    }

    func createRecoveryPackage() {
        guard let thread = selectedThread,
              let dataSource else { return }
        guard autoResumeManager?.acquireSessionManagementExecution(
            ownerID: mutationOwnerID
        ) ?? true else {
            errorMessage = "自动续跑正在执行；为避免正文变化，本次恢复包创建已暂停。"
            return
        }
        isPerformingMutation = true
        errorMessage = nil
        operationSummary = nil
        operationSummaryHasFailures = false
        statusMessage = "正在创建并回读校验深度压缩恢复包…"
        let executionManager = autoResumeManager
        let ownerID = mutationOwnerID
        Task { [weak self, service, executionManager] in
            defer {
                executionManager?.releaseSessionManagementExecution(ownerID: ownerID)
            }
            do {
                let result = try await service.createRecoveryPackage(
                    thread: thread,
                    dataSource: dataSource
                )
                guard let self else { return }
                self.lastRecoveryPackageURL = result.packageURL
                self.statusMessage = "恢复包已创建并校验：\(result.packageURL.lastPathComponent)"
                self.isPerformingMutation = false
            } catch let error as SessionManagementPublishedRecoveryPackageError {
                self?.lastRecoveryPackageURL = error.result.packageURL
                self?.errorMessage = error.localizedDescription
                self?.statusMessage = "恢复包已发布，但最终复核失败"
                self?.isPerformingMutation = false
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.statusMessage = "恢复包创建失败"
                self?.isPerformingMutation = false
            }
        }
    }

    private func loadContext(
        thread: SessionManagementThread,
        beforeOffset: Int64?,
        prepend: Bool
    ) -> Task<Void, Never>? {
        contextTask?.cancel()
        contextGeneration &+= 1
        let generation = contextGeneration
        guard let dataSource else {
            isLoadingContext = false
            return nil
        }
        isLoadingContext = true
        let task = Task { [weak self, service] in
            do {
                let page = try await service.loadContextPage(
                    thread: thread,
                    dataSource: dataSource,
                    beforeOffset: beforeOffset,
                    pageSize: 30
                )
                try Task.checkCancellation()
                guard let self,
                      self.contextGeneration == generation,
                      self.selectedThreadID == thread.id else { return }
                if prepend, let identity = self.contextIdentity, identity != page.fileIdentity {
                    self.contextMessages = page.messages
                    self.contextWarnings = page.warnings
                        + ["正文文件在分页期间发生变化，已从当前页重新建立视图。"]
                } else if prepend {
                    self.contextMessages = page.messages + self.contextMessages
                    self.contextWarnings.append(contentsOf: page.warnings)
                } else {
                    self.contextMessages = page.messages
                    self.contextWarnings = page.warnings
                }
                self.contextIdentity = page.fileIdentity
                self.contextBeforeOffset = page.nextBeforeOffset
                self.contextHasMoreBefore = page.hasMoreBefore
                self.isLoadingContext = false
            } catch is CancellationError {
                guard let self,
                      self.contextGeneration == generation,
                      self.selectedThreadID == thread.id else { return }
                self.isLoadingContext = false
            } catch {
                guard let self,
                      self.contextGeneration == generation,
                      self.selectedThreadID == thread.id else { return }
                self.contextWarnings = [error.localizedDescription]
                self.isLoadingContext = false
            }
        }
        contextTask = task
        return task
    }

    private func performMutation(
        actionLabel: String,
        operation: @escaping @Sendable (
            any SessionManagementServicing,
            CodexDataSource
        ) async throws -> Void
    ) {
        guard !isPerformingMutation,
              let dataSource else { return }
        guard autoResumeManager?.acquireSessionManagementExecution(
            ownerID: mutationOwnerID
        ) ?? true else {
            errorMessage = "自动续跑正在执行；为避免写操作竞争，本次\(actionLabel)已暂停。"
            return
        }
        isPerformingMutation = true
        errorMessage = nil
        operationSummary = nil
        operationSummaryHasFailures = false
        statusMessage = "正在\(actionLabel)…"
        let executionManager = autoResumeManager
        let ownerID = mutationOwnerID
        Task { [weak self, service, executionManager] in
            defer {
                executionManager?.releaseSessionManagementExecution(ownerID: ownerID)
            }
            do {
                try await operation(service, dataSource)
                guard let self else { return }
                self.statusMessage = "\(actionLabel)完成，正在刷新目录…"
                self.isPerformingMutation = false
                self.checkedThreadIDs.removeAll()
                self.refresh()
            } catch {
                self?.errorMessage =
                    "没有获得确定的\(actionLabel)回执，结果待确认；已立即重新读取官方目录。\(error.localizedDescription)"
                self?.statusMessage = "\(actionLabel)结果待确认"
                self?.isPerformingMutation = false
                self?.refresh(preservingError: true)
            }
        }
    }

    private func selectFirstVisibleIfNeeded() {
        if let selectedThreadID,
           visibleThreads.contains(where: { $0.id == selectedThreadID }) {
            return
        }
        if let first = visibleThreads.first {
            selectThread(first.id)
        } else {
            selectedThreadID = nil
            clearContext()
        }
    }

    private func resultFilterDidChange() {
        visibleLimit = SessionManagementPresentation.visiblePageSize
        selectFirstVisibleIfNeeded()
    }

    private func clearContext() {
        contextTask?.cancel()
        contextGeneration &+= 1
        contextMessages = []
        contextWarnings = []
        contextHasMoreBefore = false
        contextBeforeOffset = nil
        contextIdentity = nil
        isLoadingContext = false
    }
}
