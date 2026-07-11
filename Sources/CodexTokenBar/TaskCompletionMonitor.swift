import Foundation

struct TaskCompletionPollRequest: Sendable {
    let dataSource: CodexDataSource
    let previousStates: [String: TaskCompletionFileState]
    let seedMode: Bool
    let seedCutoff: Date
}

struct TaskCompletionPollOutput: Sendable {
    let result: TaskCompletionScanResult?
    let unreadThreadRead: CodexUnreadThreadReadResult
}

protocol TaskCompletionPollLoading: Sendable {
    func load(request: TaskCompletionPollRequest) async -> TaskCompletionPollOutput
}

protocol CodexUnreadThreadReading: Sendable {
    func readUnreadThreadIDs(codexHome: URL) async -> CodexUnreadThreadReadResult
}

protocol TaskCompletionScanning: Sendable {
    func scan(request: TaskCompletionPollRequest) async -> TaskCompletionScanResult
}

struct LiveCodexUnreadThreadReader: CodexUnreadThreadReading {
    func readUnreadThreadIDs(codexHome: URL) async -> CodexUnreadThreadReadResult {
        await Task.detached(priority: .utility) {
            CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)
        }.value
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

struct LiveTaskCompletionPollLoader: TaskCompletionPollLoading {
    private let unreadReader: any CodexUnreadThreadReading
    private let scanner: any TaskCompletionScanning

    init(
        unreadReader: any CodexUnreadThreadReading = LiveCodexUnreadThreadReader(),
        scanner: any TaskCompletionScanning = LiveTaskCompletionScanner()
    ) {
        self.unreadReader = unreadReader
        self.scanner = scanner
    }

    func load(request: TaskCompletionPollRequest) async -> TaskCompletionPollOutput {
        let unreadThreadRead = await unreadReader.readUnreadThreadIDs(
            codexHome: request.dataSource.codexHome
        )
        switch unreadThreadRead {
        case .available:
            return TaskCompletionPollOutput(result: nil, unreadThreadRead: unreadThreadRead)
        case .unavailable:
            let result = await scanner.scan(request: request)
            return TaskCompletionPollOutput(result: result, unreadThreadRead: unreadThreadRead)
        }
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

    private let pollInterval: TimeInterval = 2.0
    private let liveSeedWindow: TimeInterval = 30.0
    private let defaults: UserDefaults
    private let pollLoader: any TaskCompletionPollLoading
    private let now: () -> Date
    private var dataSource: CodexDataSource?
    private var fileStates: [String: TaskCompletionFileState] = [:]
    private var completedEventIDs: Set<String> = []
    private var completedEventIDOrder: [String] = []
    private var completedTaskThreadIDs: [String: String] = [:]
    private var officialUnreadThreadIDs: Set<String> = []
    private var unreadThreadState = CodexUnreadThreadState()
    private var readBaseline = TaskCompletionReadBaseline()
    private var hasCodexUnreadState = false
    private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private(set) var sourceIdentityGeneration = 0
    private(set) var sourceBindingGeneration = 0
    private var seeded = false
    private var fallbackSeedCutoff: Date

    init(
        defaults: UserDefaults = .standard,
        pollLoader: any TaskCompletionPollLoading = LiveTaskCompletionPollLoader(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.pollLoader = pollLoader
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

    func start(dataSource: CodexDataSource?) {
        let oldSourceIdentity = self.dataSource?.stableIdentityKey
        let newSourceIdentity = dataSource?.stableIdentityKey
        let oldPath = self.dataSource?.codexHome.standardizedFileURL.path
        let newPath = dataSource?.codexHome.standardizedFileURL.path
        let identityChanged = oldSourceIdentity != newSourceIdentity
        let bindingChanged = oldPath != newPath
        guard identityChanged || bindingChanged else { return }

        self.dataSource = dataSource
        sourceBindingGeneration += 1
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil

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

        updateStatusText()
        configureTimer()
    }

    func refreshUnreadThreadStatus() {
        guard dataSource != nil else { return }
        if let codexHome = dataSource?.codexHome {
            applyCodexUnreadRead(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome))
        }

        if hasCodexUnreadState {
            prepareFallbackForOfficialAvailability()
        } else {
            completedTaskThreadIDs.removeAll()
        }
        applyReadBaselineToFallbackEvents()
        refreshActiveOfficialUnreadState()
        recomputeUnreadThreadCount()
        updateStatusText(fileCount: fileStates.count)
    }

    func markAllRead() {
        readBaseline.markAllRead(
            unreadThreadIDs: unreadThreadState.threadIDs,
            completedEventIDs: Set(completedTaskThreadIDs.keys)
        )
        persistReadBaseline()
        unreadThreadState = CodexUnreadThreadState()
        completedTaskThreadIDs.removeAll()
        recomputeUnreadThreadCount()
        updateStatusText(fileCount: fileStates.isEmpty ? nil : fileStates.count)
    }

    func applyForTesting(result: TaskCompletionScanResult?, unreadThreadRead: CodexUnreadThreadReadResult) {
        apply(result, unreadThreadRead: unreadThreadRead)
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil

        guard dataSource != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    private func poll() {
        guard pollTask == nil, let dataSource else {
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
                guard !Task.isCancelled,
                      self.pollGeneration == generation,
                      self.sourceIdentityGeneration == identityGeneration,
                      self.sourceBindingGeneration == bindingGeneration else { return }
                self.pollTask = nil
                self.apply(output.result, unreadThreadRead: output.unreadThreadRead)
            }
        }
    }

    private func makePollRequest(dataSource: CodexDataSource) -> TaskCompletionPollRequest {
        TaskCompletionPollRequest(
            dataSource: dataSource,
            previousStates: fileStates,
            seedMode: !seeded,
            seedCutoff: fallbackSeedCutoff
        )
    }

    func pollRequestForTesting(dataSource: CodexDataSource) -> TaskCompletionPollRequest {
        makePollRequest(dataSource: dataSource)
    }

    private func apply(_ result: TaskCompletionScanResult?, unreadThreadRead: CodexUnreadThreadReadResult) {
        applyCodexUnreadRead(unreadThreadRead)

        if hasCodexUnreadState, result == nil {
            prepareFallbackForOfficialAvailability()
        }

        if hasCodexUnreadState {
            completedTaskThreadIDs = completedTaskThreadIDs.filter { _, threadID in
                officialUnreadThreadIDs.contains(threadID)
            }
        }

        guard let result else {
            applyReadBaselineToFallbackEvents()
            refreshActiveOfficialUnreadState()
            recomputeUnreadThreadCount()
            updateStatusText(fileCount: fileStates.isEmpty ? nil : fileStates.count)
            return
        }

        fileStates = result.states
        seeded = true

        if result.fileCount == 0 {
            setStatusText("未发现会话日志", detail: "等待 Codex 写入 sessions")
        } else if result.events.isEmpty {
            updateStatusText(fileCount: result.fileCount)
        }

        var didAddUnread = false
        for event in result.events {
            guard rememberCompletedEvent(event) else { continue }
            guard !hasCodexUnreadState || officialUnreadThreadIDs.contains(event.threadID) else { continue }
            setLastCompletedTitle(event.title)
            completedTaskThreadIDs[event.id] = event.threadID
            didAddUnread = true
        }

        applyReadBaselineToFallbackEvents()
        refreshActiveOfficialUnreadState()
        recomputeUnreadThreadCount()
        if didAddUnread, !hasCodexUnreadState, unreadThreadCount > 0 {
            statusText = "有任务完成"
            detailText = lastCompletedTitle
        } else {
            updateStatusText(fileCount: result.fileCount)
        }
    }

    private func recomputeUnreadThreadCount() {
        if hasCodexUnreadState {
            setUnreadThreadCount(unreadThreadState.threadIDs.count)
        } else {
            setUnreadThreadCount(Set(completedTaskThreadIDs.values).count)
        }
    }

    private func applyCodexUnreadRead(_ result: CodexUnreadThreadReadResult) {
        switch result {
        case let .available(threadIDs):
            officialUnreadThreadIDs = threadIDs
            hasCodexUnreadState = true
            refreshActiveOfficialUnreadState()
        case .unavailable:
            officialUnreadThreadIDs.removeAll()
            unreadThreadState = CodexUnreadThreadState()
            hasCodexUnreadState = false
        }
    }

    private func prepareFallbackForOfficialAvailability() {
        fileStates.removeAll()
        seeded = false
        fallbackSeedCutoff = now()
        completedTaskThreadIDs.removeAll()
    }

    private func refreshActiveOfficialUnreadState() {
        guard hasCodexUnreadState else { return }
        let completionThreadIDs = Set(completedTaskThreadIDs.values)
        unreadThreadState = CodexUnreadThreadState(
            threadIDs: readBaseline.activeUnreadThreadIDs(
                from: officialUnreadThreadIDs,
                reactivatedBy: completionThreadIDs
            )
        )
        persistReadBaseline()
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
