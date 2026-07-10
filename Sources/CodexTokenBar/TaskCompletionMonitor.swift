import Foundation

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
    private var dataSource: CodexDataSource?
    private var fileStates: [String: TaskCompletionFileState] = [:]
    private var completedEventIDs: Set<String> = []
    private var completedEventIDOrder: [String] = []
    private var completedTaskThreadIDs: [String: String] = [:]
    private var unreadThreadState = CodexUnreadThreadState()
    private var readBaseline = TaskCompletionReadBaseline()
    private var hasCodexUnreadState = false
    private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var seeded = false
    private var monitorStartedAt = Date()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPersistedCompletedEventIDs()
        updateStatusText()
    }

    var currentDataSourceIdentity: String? {
        dataSource?.stableIdentityKey
    }

    func start(dataSource: CodexDataSource?) {
        let oldSourceIdentity = self.dataSource?.stableIdentityKey
        let newSourceIdentity = dataSource?.stableIdentityKey
        let newPath = dataSource?.codexHome.path
        self.dataSource = dataSource

        if oldSourceIdentity != newSourceIdentity {
            pollGeneration += 1
            pollTask?.cancel()
            pollTask = nil
            fileStates.removeAll()
            seeded = false
            monitorStartedAt = Date()
            loadPersistedCompletedEventIDs()
            readBaseline = TaskCompletionReadBaselineStore.load(codexHomePath: newPath, defaults: defaults)
            completedTaskThreadIDs.removeAll()
            unreadThreadState = CodexUnreadThreadState()
            hasCodexUnreadState = false
            setUnreadThreadCount(0)
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
            completedTaskThreadIDs = completedTaskThreadIDs.filter { _, threadID in
                unreadThreadState.threadIDs.contains(threadID)
            }
        } else {
            completedTaskThreadIDs.removeAll()
        }
        applyReadBaselineToFallbackEvents()
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
        let root = dataSource.sessionsRoot
        let previousStates = fileStates
        let seedMode = !seeded
        let seedCutoff = monitorStartedAt.addingTimeInterval(-liveSeedWindow)
        let codexHome = dataSource.codexHome

        pollTask = Task { [weak self] in
            let unreadThreadRead = await Task.detached(priority: .utility) {
                CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)
            }.value
            let result: TaskCompletionScanResult?
            if case .available = unreadThreadRead {
                result = nil
            } else {
                result = await Task.detached(priority: .utility) {
                    TaskCompletionScanner.scan(
                        sessionsRoot: root,
                        previousStates: previousStates,
                        seedMode: seedMode,
                        seedCutoff: seedCutoff
                    )
                }.value
            }

            await MainActor.run {
                guard let self else { return }
                guard self.pollGeneration == generation else { return }
                self.pollTask = nil
                self.apply(result, unreadThreadRead: unreadThreadRead)
            }
        }
    }

    private func apply(_ result: TaskCompletionScanResult?, unreadThreadRead: CodexUnreadThreadReadResult) {
        applyCodexUnreadRead(unreadThreadRead)

        if hasCodexUnreadState {
            completedTaskThreadIDs = completedTaskThreadIDs.filter { _, threadID in
                unreadThreadState.threadIDs.contains(threadID)
            }
        }

        guard let result else {
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
            guard rememberCompletedEventID(event.id) else { continue }
            setLastCompletedTitle(event.title)
            completedTaskThreadIDs[event.id] = event.threadID
            didAddUnread = true
        }

        applyReadBaselineToFallbackEvents()
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
        guard case let .available(threadIDs) = result else { return }
        unreadThreadState = CodexUnreadThreadState(threadIDs: readBaseline.activeUnreadThreadIDs(from: threadIDs))
        hasCodexUnreadState = true
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

    private func rememberCompletedEventID(_ id: String) -> Bool {
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
