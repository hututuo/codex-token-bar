import Foundation

struct TaskCompletionPollRequest: Sendable {
    let dataSource: CodexDataSource
    let previousStates: [String: TaskCompletionFileState]
    let previousRunningThreadStates: [String: RunningThreadFileState]
    let seedMode: Bool
    let seedCutoff: Date
    let suppressedOfficialThreadIDs: Set<String>
    let pollStartedAt: Date

    init(
        dataSource: CodexDataSource,
        previousStates: [String: TaskCompletionFileState],
        previousRunningThreadStates: [String: RunningThreadFileState] = [:],
        seedMode: Bool,
        seedCutoff: Date,
        suppressedOfficialThreadIDs: Set<String> = [],
        pollStartedAt: Date = Date()
    ) {
        self.dataSource = dataSource
        self.previousStates = previousStates
        self.previousRunningThreadStates = previousRunningThreadStates
        self.seedMode = seedMode
        self.seedCutoff = seedCutoff
        self.suppressedOfficialThreadIDs = suppressedOfficialThreadIDs
        self.pollStartedAt = pollStartedAt
    }
}

struct TaskCompletionPollOutput: Sendable {
    let result: TaskCompletionScanResult?
    let runningThreadResult: RunningThreadScanResult?
    let unreadThreadRead: CodexUnreadThreadReadResult
    let officialReadBoundary: Date?

    init(
        result: TaskCompletionScanResult?,
        runningThreadResult: RunningThreadScanResult? = nil,
        unreadThreadRead: CodexUnreadThreadReadResult,
        officialReadBoundary: Date? = nil
    ) {
        self.result = result
        self.runningThreadResult = runningThreadResult
        self.unreadThreadRead = unreadThreadRead
        self.officialReadBoundary = officialReadBoundary
    }
}

protocol TaskCompletionPollLoading: Sendable {
    func load(request: TaskCompletionPollRequest) async -> TaskCompletionPollOutput
}

protocol CodexUnreadThreadReading: Sendable {
    func readUnreadThreadIDs(codexHome: URL) async -> CodexUnreadThreadReadResult
}

struct UnavailableCodexUnreadThreadReader: CodexUnreadThreadReading {
    func readUnreadThreadIDs(codexHome: URL) async -> CodexUnreadThreadReadResult {
        .unavailable
    }
}

protocol TaskCompletionScanning: Sendable {
    func scan(request: TaskCompletionPollRequest) async -> TaskCompletionScanResult
}

protocol RunningThreadScanning: Sendable {
    func scan(request: TaskCompletionPollRequest) async -> RunningThreadScanResult?
}

struct LiveCodexUnreadThreadReader: CodexUnreadThreadReading {
    func readUnreadThreadIDs(codexHome: URL) async -> CodexUnreadThreadReadResult {
        await Task.detached(priority: .utility) {
            CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)
        }.value
    }
}

struct LiveCodexSidebarUnreadThreadReader: CodexUnreadThreadReading {
    let bridge: CodexThreadDeleteBridgeService

    func readUnreadThreadIDs(codexHome: URL) async -> CodexUnreadThreadReadResult {
        guard let threadIDs = await bridge.sidebarUnreadThreadIDsSnapshot() else {
            return .unavailable
        }
        return .available(
            CodexUnreadThreadReader.filterLiveSidebarThreadIDs(
                threadIDs,
                codexHome: codexHome
            )
        )
    }
}

struct LiveTaskCompletionScanner: TaskCompletionScanning {
    func scan(request: TaskCompletionPollRequest) async -> TaskCompletionScanResult {
        await Task.detached(priority: .utility) {
            TaskCompletionScanner.scan(
                sessionsRoot: request.dataSource.sessionsRoot,
                previousStates: request.previousStates,
                seedMode: request.seedMode,
                seedCutoff: request.seedCutoff
            )
        }.value
    }
}

struct LiveRunningThreadScanner: RunningThreadScanning {
    func scan(request: TaskCompletionPollRequest) async -> RunningThreadScanResult? {
        let task = Task.detached(priority: .utility) {
            RunningThreadScanner.scan(
                dataSource: request.dataSource,
                previousStates: request.previousRunningThreadStates,
                now: request.pollStartedAt
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct LiveTaskCompletionPollLoader: TaskCompletionPollLoading {
    private let unreadReader: any CodexUnreadThreadReading
    private let scanner: any TaskCompletionScanning
    private let runningThreadScanner: any RunningThreadScanning

    init(
        unreadReader: any CodexUnreadThreadReading = UnavailableCodexUnreadThreadReader(),
        scanner: any TaskCompletionScanning = LiveTaskCompletionScanner(),
        runningThreadScanner: any RunningThreadScanning = LiveRunningThreadScanner()
    ) {
        self.unreadReader = unreadReader
        self.scanner = scanner
        self.runningThreadScanner = runningThreadScanner
    }

    func load(request: TaskCompletionPollRequest) async -> TaskCompletionPollOutput {
        async let unreadThreadReadTask = unreadReader.readUnreadThreadIDs(
            codexHome: request.dataSource.codexHome
        )
        async let runningThreadResultTask = runningThreadScanner.scan(request: request)
        let unreadThreadRead = await unreadThreadReadTask
        let runningThreadResult = await runningThreadResultTask
        // Codex Desktop's unread atom is the only source of truth for this
        // indicator.  A completed turn, an active rollout, or a stale local
        // scanner event is not equivalent to a sidebar unread marker.  Keep
        // the scanner dependency for source compatibility with older test and
        // composition code, but never use it to manufacture an unread state.
        _ = scanner
        return TaskCompletionPollOutput(
            result: nil,
            runningThreadResult: runningThreadResult,
            unreadThreadRead: unreadThreadRead,
            officialReadBoundary: request.pollStartedAt
        )
    }
}

@MainActor
final class TaskCompletionMonitor: ObservableObject {
    private static let completedEventIDsKey = "TaskCompletionMonitor.completedEventIDs.v1"
    private static let maxPersistedCompletedEventIDs = 2_000

    @Published private(set) var statusText = "未读监听准备中"
    @Published private(set) var detailText = "Codex 有未读会话时在悬浮窗显示小红点"
    @Published private(set) var lastCompletedTitle = ""
    @Published private(set) var unreadThreadCount = 0
    @Published private(set) var unreadThreadCountAvailable = false
    @Published private(set) var runningThreadSummary = RunningThreadSummary.unavailable

    private let pollInterval: TimeInterval
    private let pollTimeout: TimeInterval
    private let liveSeedWindow: TimeInterval = 30.0
    private let defaults: UserDefaults
    private let pollLoader: any TaskCompletionPollLoading
    private let now: () -> Date
    private var dataSource: CodexDataSource?
    private var fileStates: [String: TaskCompletionFileState] = [:]
    private var runningThreadStates: [String: RunningThreadFileState] = [:]
    private var completedEventIDs: Set<String> = []
    private var completedEventIDOrder: [String] = []
    private var completedTaskThreadIDs: [String: String] = [:]
    private var officialUnreadThreadIDs: Set<String> = []
    private var unreadThreadState = CodexUnreadThreadState()
    private var readBaseline = TaskCompletionReadBaseline()
    private var hasCodexUnreadState = false
    private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private var pollTimeoutTask: Task<Void, Never>?
    private var pollGeneration = 0
    private(set) var isActive = true
    private(set) var sourceIdentityGeneration = 0
    private(set) var sourceBindingGeneration = 0
    private var seeded = false
    private var fallbackSeedCutoff: Date

    init(
        defaults: UserDefaults = .standard,
        pollLoader: any TaskCompletionPollLoading = LiveTaskCompletionPollLoader(),
        pollInterval: TimeInterval = 2.0,
        pollTimeout: TimeInterval = 30.0,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.pollLoader = pollLoader
        self.pollInterval = pollInterval.isFinite && pollInterval > 0 ? pollInterval : 2.0
        self.pollTimeout = pollTimeout.isFinite && pollTimeout > 0 ? pollTimeout : 30.0
        self.now = now
        fallbackSeedCutoff = now().addingTimeInterval(-liveSeedWindow)
        loadPersistedCompletedEventIDs()
        updateStatusText()
    }

    var currentDataSourceIdentity: String? {
        dataSource?.stableIdentityKey
    }

    var currentDataSourcePath: String? {
        dataSource?.codexHome.standardizedFileURL.path
    }

    var statusBarUnreadThreadCount: Int? {
        unreadThreadCountAvailable ? unreadThreadCount : nil
    }

    /// Enables or suspends background polling without discarding the last
    /// trusted values published to the UI.  Re-activation starts a fresh poll
    /// for the currently bound source.
    func setActive(_ active: Bool) {
        if active {
            guard !isActive else { return }
            isActive = true
            configureTimer()
            return
        }

        isActive = false
        cancelScheduledWork()
    }

    func stop() {
        setActive(false)
    }

    func start(dataSource: CodexDataSource?) {
        let wasInactive = !isActive
        isActive = true
        let bindingChanged = bind(dataSource: dataSource)
        if wasInactive, !bindingChanged {
            configureTimer()
        }
    }

    /// Rebinds the source without implicitly acquiring a polling lease. This
    /// is used by runtime source transitions while every surface is closed;
    /// a path change must not resurrect a stopped 2-second timer.
    @discardableResult
    func bind(dataSource: CodexDataSource?) -> Bool {
        let oldSourceIdentity = self.dataSource?.stableIdentityKey
        let newSourceIdentity = dataSource?.stableIdentityKey
        let oldPath = self.dataSource?.codexHome.standardizedFileURL.path
        let newPath = dataSource?.codexHome.standardizedFileURL.path
        let identityChanged = oldSourceIdentity != newSourceIdentity
        let bindingChanged = oldPath != newPath
        guard identityChanged || bindingChanged else { return false }

        self.dataSource = dataSource
        sourceBindingGeneration += 1
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        pollTimeoutTask?.cancel()
        pollTimeoutTask = nil

        if identityChanged {
            sourceIdentityGeneration += 1
            fileStates.removeAll()
            seeded = false
            fallbackSeedCutoff = now().addingTimeInterval(-liveSeedWindow)
            loadPersistedCompletedEventIDs()
            readBaseline = TaskCompletionReadBaselineStore.load(codexHomePath: newPath, defaults: defaults)
            completedTaskThreadIDs.removeAll()
            officialUnreadThreadIDs.removeAll()
            unreadThreadState = CodexUnreadThreadState()
            hasCodexUnreadState = false
            setUnreadThreadCount(0)
            unreadThreadCountAvailable = false
        } else if let oldPath, let newPath {
            var reboundStates: [String: TaskCompletionFileState] = [:]
            for (path, state) in fileStates {
                let reboundPath: String
                if path == oldPath || path.hasPrefix(oldPath + "/") {
                    reboundPath = newPath + String(path.dropFirst(oldPath.count))
                } else {
                    reboundPath = path
                }
                reboundStates[reboundPath] = state
            }
            fileStates = reboundStates
        }
        runningThreadStates.removeAll()
        runningThreadSummary = dataSource == nil ? .unavailable : .loading

        updateStatusText()
        configureTimer()
        return true
    }

    func markAllRead() {
        // Token Bar cannot mutate Codex Desktop's in-memory sidebar state.
        // Keeping a local acknowledgement baseline here made the indicator
        // disagree with the left list, so the compatibility entry point is a
        // deliberate no-op.  Users must mark the conversation read in Codex;
        // the next CDP snapshot will mirror that state.
        updateStatusText(fileCount: fileStates.isEmpty ? nil : fileStates.count)
    }

    func applyForTesting(
        result: TaskCompletionScanResult?,
        unreadThreadRead: CodexUnreadThreadReadResult,
        officialReadBoundary: Date? = nil,
        runningThreadResult: RunningThreadScanResult? = nil
    ) {
        apply(
            result,
            runningThreadResult: runningThreadResult,
            unreadThreadRead: unreadThreadRead,
            officialReadBoundary: officialReadBoundary
        )
    }

    func applyForTesting(output: TaskCompletionPollOutput) {
        apply(
            output.result,
            runningThreadResult: output.runningThreadResult,
            unreadThreadRead: output.unreadThreadRead,
            officialReadBoundary: output.officialReadBoundary
        )
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil

        guard isActive, dataSource != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    private func poll() {
        guard isActive, pollTask == nil, let dataSource else {
            return
        }

        pollGeneration += 1
        let generation = pollGeneration
        let identityGeneration = sourceIdentityGeneration
        let bindingGeneration = sourceBindingGeneration
        let request = makePollRequest(dataSource: dataSource)
        let pollLoader = pollLoader

        pollTask = Task { [weak self] in
            let output = await pollLoader.load(request: request)

            await MainActor.run {
                guard let self else { return }
                guard self.isActive,
                      !Task.isCancelled,
                      self.pollGeneration == generation,
                      self.sourceIdentityGeneration == identityGeneration,
                      self.sourceBindingGeneration == bindingGeneration else { return }
                self.pollTimeoutTask?.cancel()
                self.pollTimeoutTask = nil
                self.pollTask = nil
                self.apply(
                    output.result,
                    runningThreadResult: output.runningThreadResult,
                    unreadThreadRead: output.unreadThreadRead,
                    officialReadBoundary: output.officialReadBoundary ?? request.pollStartedAt
                )
            }
        }
        let maximumSleepSeconds = TimeInterval(UInt64.max) / 1_000_000_000
        let timeoutNanoseconds = UInt64(min(pollTimeout, maximumSleepSeconds) * 1_000_000_000)
        pollTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.isActive,
                  self.pollGeneration == generation,
                  self.sourceIdentityGeneration == identityGeneration,
                  self.sourceBindingGeneration == bindingGeneration else { return }
            self.pollGeneration += 1
            self.pollTask?.cancel()
            self.pollTask = nil
            self.pollTimeoutTask = nil
            self.markRunningThreadSummaryStale()
        }
    }

    private func cancelScheduledWork() {
        timer?.invalidate()
        timer = nil
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        pollTimeoutTask?.cancel()
        pollTimeoutTask = nil
    }

    private func makePollRequest(dataSource: CodexDataSource) -> TaskCompletionPollRequest {
        return TaskCompletionPollRequest(
            dataSource: dataSource,
            previousStates: fileStates,
            previousRunningThreadStates: runningThreadStates,
            seedMode: !seeded,
            seedCutoff: fallbackSeedCutoff,
            suppressedOfficialThreadIDs: suppressedOfficialThreadIDs,
            pollStartedAt: now()
        )
    }

    func pollRequestForTesting(dataSource: CodexDataSource) -> TaskCompletionPollRequest {
        makePollRequest(dataSource: dataSource)
    }

    private func apply(
        _ result: TaskCompletionScanResult?,
        runningThreadResult: RunningThreadScanResult?,
        unreadThreadRead: CodexUnreadThreadReadResult,
        officialReadBoundary: Date?
    ) {
        // `result` and `officialReadBoundary` are retained in the poll
        // protocol for compatibility, but completion events are deliberately
        // ignored.  Only the desktop sidebar unread atom may change this
        // indicator.
        _ = result
        _ = officialReadBoundary
        applyRunningThreadResult(runningThreadResult)
        applyCodexUnreadRead(unreadThreadRead)
        refreshActiveOfficialUnreadState()
        recomputeUnreadThreadCount()
        updateStatusText(fileCount: fileStates.isEmpty ? nil : fileStates.count)
    }

    private func applyRunningThreadResult(_ result: RunningThreadScanResult?) {
        guard let result else {
            markRunningThreadSummaryStale()
            return
        }
        runningThreadStates = result.states
        let businessStateChanged = runningThreadSummary.main != result.summary.main
            || runningThreadSummary.subagents != result.summary.subagents
            || runningThreadSummary.freshness != result.summary.freshness
        guard businessStateChanged else { return }
        runningThreadSummary = result.summary
    }

    private func markRunningThreadSummaryStale() {
        let next = runningThreadSummary.markedStale()
        if runningThreadSummary != next {
            runningThreadSummary = next
        }
    }

    private func recomputeUnreadThreadCount() {
        if hasCodexUnreadState {
            setUnreadThreadCount(unreadThreadState.threadIDs.count)
        } else {
            setUnreadThreadCount(0)
        }
    }

    private func applyCodexUnreadRead(_ result: CodexUnreadThreadReadResult) {
        switch result {
        case let .available(threadIDs):
            officialUnreadThreadIDs = threadIDs
            hasCodexUnreadState = true
            unreadThreadCountAvailable = true
            refreshActiveOfficialUnreadState()
        case .unavailable:
            // A CDP snapshot is the only accepted source.  If it disappears,
            // hide the previous value immediately; retaining it would keep a
            // stale atom/DOM observation flashing after the user read the row.
            officialUnreadThreadIDs.removeAll()
            unreadThreadState = CodexUnreadThreadState()
            hasCodexUnreadState = false
            unreadThreadCountAvailable = false
        }
    }

    private func prepareFallbackForOfficialAvailability(boundary: Date) {
        resetFallbackReactivationTracking(boundary: boundary)
        completedTaskThreadIDs.removeAll()
    }

    private func resetFallbackReactivationTracking(boundary: Date) {
        fileStates.removeAll()
        seeded = false
        fallbackSeedCutoff = boundary
    }

    private var suppressedOfficialThreadIDs: Set<String> {
        []
    }

    private func refreshActiveOfficialUnreadState() {
        guard hasCodexUnreadState else { return }
        // Pure mirror: no local baseline, completion scanner or acknowledgement
        // can add/remove an ID from the official sidebar snapshot.
        unreadThreadState = CodexUnreadThreadState(threadIDs: officialUnreadThreadIDs)
    }

    private func applyReadBaselineToFallbackEvents() {
        completedTaskThreadIDs = readBaseline.activeCompletedTaskThreadIDs(from: completedTaskThreadIDs)
    }

    private func persistReadBaseline() {
        TaskCompletionReadBaselineStore.save(readBaseline, codexHomePath: dataSource?.codexHome.path, defaults: defaults)
    }

    private func updateStatusText(fileCount: Int? = nil) {
        if unreadThreadCount > 0 {
            if hasCodexUnreadState {
                setStatusText("有未读会话", detail: "Codex 有 \(unreadThreadCount) 个未读会话")
            } else {
                setStatusText(
                    "有任务完成",
                    detail: lastCompletedTitle.isEmpty ? "等待 Codex 未读状态同步" : lastCompletedTitle
                )
            }
            return
        }

        if dataSource == nil {
            setStatusText("未找到 Codex 目录", detail: "选择目录后开始监听")
            return
        }

        if let fileCount {
            setStatusText("未读监听中", detail: "已跟踪 \(fileCount) 个会话文件")
        } else {
            setStatusText("未读监听中", detail: "Codex 有未读会话时会亮点")
        }
    }

    private func setStatusText(_ status: String, detail: String) {
        if statusText != status {
            statusText = status
        }
        if detailText != detail {
            detailText = detail
        }
    }

    private func setLastCompletedTitle(_ title: String) {
        guard lastCompletedTitle != title else { return }
        lastCompletedTitle = title
    }

    private func setUnreadThreadCount(_ count: Int) {
        guard unreadThreadCount != count else { return }
        unreadThreadCount = count
    }

    private func loadPersistedCompletedEventIDs() {
        let storedIDs = defaults.stringArray(forKey: Self.completedEventIDsKey) ?? []
        var ordered: [String] = []
        var seen = Set<String>()
        for id in storedIDs where !id.isEmpty && seen.insert(id).inserted {
            ordered.append(id)
        }
        if ordered.count > Self.maxPersistedCompletedEventIDs {
            ordered = Array(ordered.suffix(Self.maxPersistedCompletedEventIDs))
            defaults.set(ordered, forKey: Self.completedEventIDsKey)
        }
        completedEventIDOrder = ordered
        completedEventIDs = Set(ordered)
    }

    private func rememberCompletedEvent(_ event: TaskCompletionEvent) -> Bool {
        guard !completedEventIDs.contains(event.id) else {
            return false
        }
        if !completedEventIDs.isDisjoint(with: event.legacyIDs) {
            _ = persistCompletedEventID(event.id)
            return false
        }
        return persistCompletedEventID(event.id)
    }

    private func persistCompletedEventID(_ id: String) -> Bool {
        guard !id.isEmpty, completedEventIDs.insert(id).inserted else {
            return false
        }

        completedEventIDOrder.append(id)
        if completedEventIDOrder.count > Self.maxPersistedCompletedEventIDs {
            let overflow = completedEventIDOrder.count - Self.maxPersistedCompletedEventIDs
            let removed = completedEventIDOrder.prefix(overflow)
            completedEventIDs.subtract(removed)
            completedEventIDOrder.removeFirst(overflow)
        }
        defaults.set(completedEventIDOrder, forKey: Self.completedEventIDsKey)
        return true
    }
}
