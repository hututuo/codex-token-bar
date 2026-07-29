import Combine
import Foundation

enum AutoResumeStorage {
    static let configurationKey = "CodexTokenBar.autoResume.configuration.v1"
    static let runtimeStateKey = "CodexTokenBar.autoResume.runtimeState.v1"

    static func loadConfiguration(
        defaults: UserDefaults,
        key: String = configurationKey
    ) -> AutoResumeConfiguration? {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AutoResumeConfiguration.self, from: data) else {
            return nil
        }
        return value.normalized
    }

    static func loadRuntimeState(
        defaults: UserDefaults,
        key: String = runtimeStateKey
    ) -> AutoResumeRuntimeState? {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AutoResumeRuntimeState.self, from: data) else {
            return nil
        }
        return value
    }

    static func save<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        guard defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class AutoResumeLocalExecutionGate {
    private var ownerID: String?

    func acquire(ownerID: String) -> Bool {
        guard self.ownerID == nil else { return false }
        self.ownerID = ownerID
        return true
    }

    func release(ownerID: String) {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
    }
}

private enum AutoResumeWorkerOutcome: Sendable {
    case succeeded(AutoResumeRunResult)
    case satisfied(String)
    case dailyLimit(AutoResumeSharedDailyLimit)
    case failed(
        message: String,
        requiresHuman: Bool,
        quotaLimited: Bool,
        claimedTrigger: Bool
    )
    case deferred(String)
    case skipped(String)

    var claimedTrigger: Bool {
        switch self {
        case .succeeded: return true
        case .satisfied, .dailyLimit, .deferred: return false
        case .failed(_, _, _, let claimedTrigger): return claimedTrigger
        case .skipped: return false
        }
    }

    var completesCapacityObservation: Bool {
        switch self {
        case .succeeded, .satisfied:
            return true
        case .failed(_, _, _, let claimedTrigger):
            return claimedTrigger
        case .skipped(let message):
            return message.contains("本次触发已由")
        case .dailyLimit, .deferred:
            return false
        }
    }
}

private enum AutoResumePendingSlot: String, Sendable {
    case schedule
    case quota
}

private struct AutoResumePendingCapture: Sendable {
    let slot: AutoResumePendingSlot
    let threadID: String
    let armedAt: Date

    var key: String {
        "\(slot.rawValue):\(threadID):\(armedAt.timeIntervalSinceReferenceDate)"
    }
}

@MainActor
final class AutoResumeController: ObservableObject {
    @Published private(set) var configuration: AutoResumeConfiguration
    @Published private(set) var runtimeState: AutoResumeRuntimeState
    @Published private(set) var availableThreads: [AutoResumeThreadDescriptor] = []
    @Published private(set) var isRefreshingThreads = false
    @Published private(set) var isRunning = false

    private let quotaStore: AccountQuotaStore
    private let appServer: any CodexAutoResumeAppServerServing
    private let defaults: UserDefaults
    private let ownerID: String
    private let dataSourceProvider: @MainActor () -> CodexDataSource?
    private let quotaBackgroundActivityChanged: @MainActor (Bool) -> Void
    private let codexBinaryProvider: @Sendable () throws -> String
    private let notifier: any AutoResumeNotifying
    private let startGuard: AutoResumeStartGuard
    private let configurationStorageKey: String
    private let runtimeStateStorageKey: String
    private let externallyManaged: Bool
    private let localExecutionGate: AutoResumeLocalExecutionGate?
    private var cancellables: Set<AnyCancellable> = []
    private var schedulerTimer: Timer?
    private var executionTask: Task<Void, Never>?
    private var workerTask: Task<AutoResumeWorkerOutcome, Never>?
    private var capacityCheckTask: Task<Void, Never>?
    private var capacityCheckToken: UUID?
    private var capacityMonitorHasLiveBaseline = false
    private var pendingFreshnessCaptureKeys: Set<String> = []
    private var started = false

    init(
        quotaStore: AccountQuotaStore,
        appServer: any CodexAutoResumeAppServerServing = CodexAppServerClient(),
        defaults: UserDefaults = .standard,
        ownerID: String = "swift-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
        dataSourceProvider: @escaping @MainActor () -> CodexDataSource? = {
            CodexDataSourceResolver().resolve()
        },
        quotaBackgroundActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        notifier: any AutoResumeNotifying = SystemAutoResumeNotifier(),
        codexBinaryProvider: @escaping @Sendable () throws -> String = {
            try CodexBinaryLocator.findExecutable()
        },
        configurationStorageKey: String = AutoResumeStorage.configurationKey,
        runtimeStateStorageKey: String = AutoResumeStorage.runtimeStateKey,
        initialConfiguration: AutoResumeConfiguration? = nil,
        initialRuntimeState: AutoResumeRuntimeState? = nil,
        externallyManaged: Bool = false,
        localExecutionGate: AutoResumeLocalExecutionGate? = nil
    ) {
        self.quotaStore = quotaStore
        self.appServer = appServer
        self.defaults = defaults
        self.ownerID = ownerID
        self.dataSourceProvider = dataSourceProvider
        self.quotaBackgroundActivityChanged = quotaBackgroundActivityChanged
        self.notifier = notifier
        self.codexBinaryProvider = codexBinaryProvider
        self.configurationStorageKey = configurationStorageKey
        self.runtimeStateStorageKey = runtimeStateStorageKey
        self.externallyManaged = externallyManaged
        self.localExecutionGate = localExecutionGate
        let loadedConfiguration = AutoResumeStorage.loadConfiguration(
            defaults: defaults,
            key: configurationStorageKey
        ) ?? initialConfiguration ?? .default
        configuration = loadedConfiguration
        runtimeState = AutoResumeStorage.loadRuntimeState(
            defaults: defaults,
            key: runtimeStateStorageKey
        ) ?? initialRuntimeState ?? .default
        startGuard = AutoResumeStartGuard(configuration: loadedConfiguration)
    }

    isolated deinit {
        schedulerTimer?.invalidate()
        executionTask?.cancel()
        workerTask?.cancel()
        capacityCheckTask?.cancel()
        capacityCheckToken = nil
        localExecutionGate?.release(ownerID: ownerID)
    }

    func start() {
        guard !started else { return }
        started = true
        if configuration.enabled, runtimeState.enabledAt == nil {
            runtimeState.enabledAt = Date()
        }
        if configuration.enabled,
           configuration.capacityRecoveryEnabled,
           runtimeState.capacityMonitorArmedAt == nil {
            runtimeState.capacityMonitorArmedAt = Date()
        }
        refreshWaitingStatus()
        persistRuntimeState()
        updateQuotaBackgroundActivity()

        guard !externallyManaged else {
            synchronizePendingFreshness()
            persistRuntimeState()
            return
        }

        quotaStore.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                Task { @MainActor in
                    self?.handleQuotaSnapshot(snapshot)
                }
            }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateCapacityRecovery()
                self?.evaluateSchedule()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        schedulerTimer = timer
        synchronizePendingFreshness()
        evaluateCapacityRecovery()
        evaluateSchedule()
    }

    func setEnabled(_ enabled: Bool) {
        guard configuration.enabled != enabled else { return }
        var next = configuration
        next.enabled = enabled
        applyConfiguration(next)
        if !enabled {
            stopCurrentRun()
        }
    }

    func setPrompt(_ prompt: String) {
        var next = configuration
        next.prompt = prompt
        applyConfiguration(next)
    }

    func setScheduleMode(_ mode: AutoResumeScheduleMode) {
        var next = configuration
        next.scheduleMode = mode
        applyConfiguration(next, resetsScheduleAnchor: true)
    }

    func setIntervalMinutes(_ minutes: Int) {
        var next = configuration
        next.intervalMinutes = minutes
        applyConfiguration(next, resetsScheduleAnchor: true)
    }

    func setDailyTime(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        var next = configuration
        next.dailyHour = components.hour ?? next.dailyHour
        next.dailyMinute = components.minute ?? next.dailyMinute
        applyConfiguration(next, resetsScheduleAnchor: true)
    }

    func setQuotaRecoveryEnabled(_ enabled: Bool) {
        var next = configuration
        next.quotaRecoveryEnabled = enabled
        applyConfiguration(next, resetsQuotaArming: true)
    }

    func setCapacityRecoveryEnabled(_ enabled: Bool) {
        setFailureRecoveryReason(.serverOverloaded, enabled: enabled)
    }

    func setFailureRecoveryReason(_ reason: AutoResumeFailureReason, enabled: Bool) {
        var next = configuration
        var selected = next.selectedFailureReasons
        if enabled {
            selected.insert(reason)
        } else {
            selected.remove(reason)
        }
        next.failureRecoveryPolicyVersion = 2
        next.failureRecoveryReasons = AutoResumeFailureReason.allCases.filter(selected.contains)
        next.capacityRecoveryEnabled = !next.failureRecoveryReasons.isEmpty
        applyConfiguration(next, resetsCapacityMonitoring: true)
    }

    func setAllFailureRecoveryReasons(_ enabled: Bool) {
        var next = configuration
        next.failureRecoveryPolicyVersion = 2
        next.failureRecoveryReasons = enabled ? AutoResumeFailureReason.allCases : []
        next.capacityRecoveryEnabled = enabled
        applyConfiguration(next, resetsCapacityMonitoring: true)
    }

    func setAllRecoveryConditions(_ enabled: Bool) {
        var next = configuration
        next.failureRecoveryPolicyVersion = 2
        next.failureRecoveryReasons = enabled ? AutoResumeFailureReason.allCases : []
        next.capacityRecoveryEnabled = enabled
        next.quotaRecoveryEnabled = enabled
        applyConfiguration(
            next,
            resetsQuotaArming: true,
            resetsCapacityMonitoring: true
        )
    }

    func setQuotaWindow(_ window: AutoResumeQuotaWindow) {
        var next = configuration
        next.quotaWindow = window
        applyConfiguration(next, resetsQuotaArming: true)
    }

    func setQuotaArmPercent(_ percent: Int) {
        var next = configuration
        next.quotaArmAtOrBelowPercent = percent
        applyConfiguration(next, resetsQuotaArming: true)
    }

    func setQuotaResumePercent(_ percent: Int) {
        var next = configuration
        next.quotaResumeAtOrAbovePercent = percent
        applyConfiguration(next, resetsQuotaArming: true)
    }

    func setCooldownMinutes(_ minutes: Int) {
        var next = configuration
        next.cooldownMinutes = minutes
        applyConfiguration(next)
    }

    func setMaxRunsPerDay(_ count: Int) {
        var next = configuration
        next.maxRunsPerDay = count
        applyConfiguration(next)
    }

    func setNotifyOnResult(_ enabled: Bool) {
        var next = configuration
        next.notifyOnResult = enabled
        applyConfiguration(next)
    }

    func selectThread(id: String?) {
        var next = configuration
        if let id {
            next.target = availableThreads.first { $0.id == id }
                ?? (configuration.target?.id == id ? configuration.target : nil)
        } else {
            next.target = nil
        }
        applyConfiguration(
            next,
            resetsScheduleAnchor: true,
            resetsQuotaArming: true,
            resetsCapacityMonitoring: true
        )
    }

    func setTarget(_ target: AutoResumeThreadDescriptor?) {
        var next = configuration
        next.target = target
        applyConfiguration(
            next,
            resetsScheduleAnchor: true,
            resetsQuotaArming: true,
            resetsCapacityMonitoring: true
        )
    }

    func evaluateManagedTick(includeCapacity: Bool) {
        guard externallyManaged else { return }
        if includeCapacity {
            evaluateCapacityRecovery()
        }
        evaluateSchedule()
    }

    func observeManagedQuota(_ snapshot: AccountQuotaSnapshot) {
        guard externallyManaged else { return }
        handleQuotaSnapshot(snapshot)
    }

    var isCapacityCheckInFlight: Bool {
        capacityCheckTask != nil
    }

    func refreshThreads() {
        guard !isRefreshingThreads else { return }
        isRefreshingThreads = true
        runtimeState.status = .refreshingThreads
        runtimeState.statusMessage = "正在刷新 Codex 任务列表"
        persistRuntimeState()

        let appServer = self.appServer
        let dataSource = dataSourceProvider()
        let codexBinaryProvider = self.codexBinaryProvider
        Task { [weak self] in
            do {
                let threads = try await Task.detached(priority: .utility) {
                    let codexPath = try codexBinaryProvider()
                    return try await appServer.listThreads(
                        codexPath: codexPath,
                        dataSource: dataSource
                    )
                }.value
                guard let self else { return }
                self.availableThreads = threads
                self.isRefreshingThreads = false
                self.refreshWaitingStatus()
                self.persistRuntimeState()
            } catch {
                guard let self else { return }
                self.isRefreshingThreads = false
                self.runtimeState.status = .failed
                self.runtimeState.statusMessage = "任务列表刷新失败：\(error.localizedDescription)"
                self.runtimeState.lastError = error.localizedDescription
                self.persistRuntimeState()
            }
        }
    }

    func runNow() {
        guard let target = configuration.target else {
            runtimeState.status = .failed
            runtimeState.statusMessage = "请先选择目标任务"
            persistRuntimeState()
            return
        }
        let trigger = AutoResumeTrigger(
            kind: .manual,
            key: "manual:\(target.id):\(UUID().uuidString)",
            firedAt: Date()
        )
        beginExecution(trigger: trigger, requiresAutomationEnabled: false)
    }

    func stopCurrentRun() {
        executionTask?.cancel()
        workerTask?.cancel()
        capacityCheckTask?.cancel()
        executionTask = nil
        workerTask = nil
        capacityCheckTask = nil
        capacityCheckToken = nil
        isRunning = false
        localExecutionGate?.release(ownerID: ownerID)
        runtimeState.status = .stopped
        runtimeState.statusMessage = "自动续跑已停止"
        synchronizePendingFreshness()
        persistRuntimeState()
    }

    var selectedThreadID: String? { configuration.target?.id }

    var nextScheduledAt: Date? {
        AutoResumePolicy.nextScheduledDate(
            configuration: configuration,
            state: runtimeState,
            now: Date()
        )
    }

    var runsToday: Int {
        runtimeState.runHistory.filter { Calendar.current.isDateInToday($0) }.count
    }

    private func applyConfiguration(
        _ value: AutoResumeConfiguration,
        resetsScheduleAnchor: Bool = false,
        resetsQuotaArming: Bool = false,
        resetsCapacityMonitoring: Bool = false
    ) {
        let old = configuration
        configuration = value.normalized
        startGuard.update(configuration: configuration)
        if old.maxRunsPerDay != configuration.maxRunsPerDay {
            runtimeState.sharedDailyLimitUntil = nil
        }
        let shouldRefreshQuota = configuration.enabled
            && configuration.quotaRecoveryEnabled
            && (!old.enabled || !old.quotaRecoveryEnabled || resetsQuotaArming)
        if !old.enabled, configuration.enabled {
            runtimeState.enabledAt = Date()
            resetQuotaBaseline()
            runtimeState.schedulePendingFreshness = nil
            resetCapacityMonitoring()
        }
        if resetsScheduleAnchor {
            runtimeState.enabledAt = Date()
            runtimeState.lastIntervalFireAt = nil
            runtimeState.lastDailyTriggerKey = nil
            runtimeState.schedulePendingFreshness = nil
        }
        if resetsQuotaArming {
            resetQuotaBaseline()
        }
        if resetsCapacityMonitoring {
            capacityCheckTask?.cancel()
            capacityCheckTask = nil
            capacityCheckToken = nil
            resetCapacityMonitoring()
        }
        if configuration.enabled, configuration.capacityRecoveryEnabled {
            if runtimeState.capacityMonitorArmedAt == nil {
                runtimeState.capacityMonitorArmedAt = Date()
            }
        } else {
            runtimeState.capacityMonitorArmedAt = nil
            runtimeState.capacityPendingFreshness = nil
        }
        AutoResumeStorage.save(
            configuration,
            key: configurationStorageKey,
            defaults: defaults
        )
        updateQuotaBackgroundActivity()
        if shouldRefreshQuota {
            quotaStore.refresh(force: true)
        }
        synchronizePendingFreshness()
        refreshWaitingStatus()
        persistRuntimeState()
        evaluateCapacityRecovery()
        evaluateSchedule()
    }

    private func updateQuotaBackgroundActivity() {
        quotaBackgroundActivityChanged(
            configuration.enabled && configuration.quotaRecoveryEnabled
        )
    }

    private func evaluateCapacityRecovery(now: Date = Date()) {
        guard started,
              configuration.enabled,
              configuration.capacityRecoveryEnabled,
              !isRunning,
              capacityCheckTask == nil,
              let target = configuration.target,
              let dataSource = dataSourceProvider() else {
            return
        }

        let targetID = target.id
        let appServer = self.appServer
        let codexBinaryProvider = self.codexBinaryProvider
        let checkToken = UUID()
        capacityCheckToken = checkToken
        capacityCheckTask = Task { [weak self] in
            do {
                let observation = try await Task.detached(priority: .utility) {
                    let codexPath = try codexBinaryProvider()
                    return try await appServer.readLatestTurnObservation(
                        codexPath: codexPath,
                        dataSource: dataSource,
                        threadID: targetID
                    )
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.capacityCheckToken == checkToken else {
                    return
                }
                self.capacityCheckTask = nil
                self.capacityCheckToken = nil
                self.handleCapacityObservation(
                    observation,
                    targetID: targetID,
                    now: now
                )
            } catch is CancellationError {
                guard let self, self.capacityCheckToken == checkToken else { return }
                self.capacityCheckTask = nil
                self.capacityCheckToken = nil
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.capacityCheckToken == checkToken else {
                    return
                }
                self.capacityCheckTask = nil
                self.capacityCheckToken = nil
                guard self.configuration.enabled,
                      self.configuration.capacityRecoveryEnabled,
                      self.configuration.target?.id == targetID else {
                    return
                }
                self.runtimeState.status = .waiting
                self.runtimeState.statusMessage = "失败中断监控检查失败，15 秒后重试"
                self.runtimeState.lastError = error.localizedDescription
                self.persistRuntimeState()
            }
        }
    }

    private func handleCapacityObservation(
        _ observation: AutoResumeLatestTurnObservation?,
        targetID: String,
        now: Date
    ) {
        guard configuration.enabled,
              configuration.capacityRecoveryEnabled,
              configuration.target?.id == targetID,
              !isRunning else {
            return
        }

        let recoveredFromMonitorError = runtimeState.statusMessage
            == "失败中断监控检查失败，15 秒后重试"
        if recoveredFromMonitorError {
            runtimeState.lastError = nil
            refreshWaitingStatus()
        }
        guard let observation else {
            if recoveredFromMonitorError { persistRuntimeState() }
            return
        }
        let previousMonitorKey = runtimeState.lastCapacityMonitorObservationKey
        let monitorKeyChanged = previousMonitorKey != observation.monitorKey
        let pendingMatchesObservation = runtimeState.capacityPendingFreshness?.threadID == targetID
            && runtimeState.capacityPendingFreshness?.baseline?.lastTurnID == observation.turnID
        if observation.startedAt == nil,
           observation.completedAt == nil,
           !capacityMonitorHasLiveBaseline,
           !pendingMatchesObservation {
            capacityMonitorHasLiveBaseline = true
            runtimeState.lastCapacityMonitorObservationKey = observation.monitorKey
            persistRuntimeState()
            return
        }
        capacityMonitorHasLiveBaseline = true
        let alreadyObserved = runtimeState.lastCapacityObservedTurnID == observation.turnID
        if observation.isGeneratedByAutomaticRecovery,
           let failureReason = observation.failureReason {
            if !alreadyObserved {
                runtimeState.lastCapacityMonitorObservationKey = observation.monitorKey
                runtimeState.lastCapacityObservedTurnID = observation.turnID
                runtimeState.capacityPendingFreshness = nil
                runtimeState.status = .waiting
                runtimeState.statusMessage =
                    "自动续跑的后续轮仍因“\(failureReason.label)”结束，本次不再重试"
                runtimeState.lastError = observation.errorMessage
                persistRuntimeState()
            } else if recoveredFromMonitorError {
                persistRuntimeState()
            }
            return
        }

        if alreadyObserved {
            if monitorKeyChanged || recoveredFromMonitorError {
                runtimeState.lastCapacityMonitorObservationKey = observation.monitorKey
                persistRuntimeState()
            }
            return
        }
        guard let trigger = AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: runtimeState,
            observation: observation,
            now: now
        ) else {
            if monitorKeyChanged || recoveredFromMonitorError {
                runtimeState.lastCapacityMonitorObservationKey = observation.monitorKey
                if let reason = observation.failureReason,
                   configuration.selectedFailureReasons.contains(reason),
                   observation.clientUserMessageID == nil {
                    runtimeState.status = .waiting
                    runtimeState.statusMessage =
                        "检测到“\(reason.label)”，但无法确认原用户消息，已安全停下"
                }
                persistRuntimeState()
            }
            return
        }

        runtimeState.lastCapacityMonitorObservationKey = observation.monitorKey
        runtimeState.capacityPendingFreshness = AutoResumePendingFreshness(
            threadID: targetID,
            armedAt: now,
            baseline: observation.freshness
        )
        runtimeState.status = .waiting
        let reasonLabel = observation.failureReason?.label ?? "所选失败"
        runtimeState.statusMessage = "检测到“\(reasonLabel)”，准备续跑一次"
        runtimeState.lastError = observation.errorMessage
        persistRuntimeState()
        beginExecution(trigger: trigger, requiresAutomationEnabled: true)
    }

    private func evaluateSchedule(now: Date = Date()) {
        synchronizePendingFreshness(now: now)
        guard started, !isRunning,
              let trigger = AutoResumePolicy.scheduledTrigger(
                configuration: configuration,
                state: runtimeState,
                now: now
              ) else {
            return
        }
        beginExecution(trigger: trigger, requiresAutomationEnabled: true)
    }

    private func handleQuotaSnapshot(_ snapshot: AccountQuotaSnapshot, now: Date = Date()) {
        var nextState = runtimeState
        guard let trigger = AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &nextState,
            snapshot: snapshot,
            now: now
        ) else {
            if nextState != runtimeState {
                runtimeState = nextState
                synchronizePendingFreshness(now: now)
                refreshWaitingStatus()
                persistRuntimeState()
            }
            return
        }

        if AutoResumePolicy.safetyBlock(
            configuration: configuration,
            state: nextState,
            now: now
        ) != nil {
            nextState.quotaArmed = true
            nextState.quotaArmedCycleID = nextState.lastQuotaCycleID
            nextState.quotaArmedWindowLabel = nextState.lastQuotaWindowLabel
            nextState.quotaRecoveryRequiresTransition = false
            nextState.quotaRecoveryObservedLow = true
            nextState.quotaRecoveryArmObservationAt =
                trigger.repeatAfter ?? nextState.lastQuotaObservedAt
            runtimeState = nextState
            synchronizePendingFreshness(now: now)
            refreshWaitingStatus()
            persistRuntimeState()
            return
        }

        runtimeState = nextState
        persistRuntimeState()
        beginExecution(trigger: trigger, requiresAutomationEnabled: true)
    }

    private func beginExecution(
        trigger: AutoResumeTrigger,
        requiresAutomationEnabled: Bool
    ) {
        guard !isRunning, executionTask == nil else { return }
        guard let target = configuration.target else {
            runtimeState.status = .failed
            runtimeState.statusMessage = "请先选择目标任务"
            persistRuntimeState()
            return
        }
        if requiresAutomationEnabled, !configuration.enabled {
            return
        }
        if let localExecutionGate,
           !localExecutionGate.acquire(ownerID: ownerID) {
            runtimeState.status = .waiting
            runtimeState.statusMessage = "另一条监控任务正在续跑，本任务稍后重试"
            persistRuntimeState()
            return
        }
        var keepsLocalExecutionGate = false
        defer {
            if !keepsLocalExecutionGate {
                localExecutionGate?.release(ownerID: ownerID)
            }
        }
        let expectedFreshness: AutoResumeThreadFreshness?
        if trigger.kind == .manual {
            expectedFreshness = nil
        } else {
            let pending: AutoResumePendingFreshness?
            switch trigger.kind {
            case .interval, .daily:
                pending = runtimeState.schedulePendingFreshness
            case .quotaRecovery:
                pending = runtimeState.quotaPendingFreshness
            case .capacityRecovery:
                pending = runtimeState.capacityPendingFreshness
            case .manual:
                pending = nil
            }
            guard let pending,
                  pending.threadID == target.id,
                  let baseline = pending.baseline else {
                if trigger.kind == .quotaRecovery {
                    rearmQuotaAfterDeferredTrigger()
                }
                synchronizePendingFreshness(now: trigger.firedAt)
                runtimeState.status = .waiting
                runtimeState.statusMessage = "正在建立目标任务的防重复基线"
                persistRuntimeState()
                return
            }
            expectedFreshness = baseline
        }
        if trigger.kind != .manual,
           let block = AutoResumePolicy.safetyBlock(
            configuration: configuration,
            state: runtimeState,
            now: trigger.firedAt
        ) {
            switch block {
            case .cooldown(let until):
                runtimeState.status = .waiting
                runtimeState.statusMessage = "冷却中，最早 \(until.formatted(date: .omitted, time: .shortened)) 续跑"
            case .dailyLimit:
                runtimeState.status = .waiting
                runtimeState.statusMessage = "今天已达到最多 \(configuration.maxRunsPerDay) 次"
            }
            persistRuntimeState()
            return
        }

        guard let dataSource = dataSourceProvider() else {
            runtimeState.status = .failed
            runtimeState.statusMessage = "找不到 Codex Home，无法创建跨进程续跑锁"
            persistRuntimeState()
            return
        }
        let startAuthorization: AutoResumeStartAuthorization?
        if trigger.kind == .manual {
            startAuthorization = nil
        } else {
            guard let authorization = startGuard.authorization(
                for: trigger.kind,
                targetID: target.id
            ) else {
                runtimeState.status = .waiting
                runtimeState.statusMessage = "自动续跑设置已变化，旧触发已作废"
                persistRuntimeState()
                return
            }
            startAuthorization = authorization
        }

        var state = runtimeState
        AutoResumePolicy.markTriggerAccepted(trigger, state: &state)
        state.status = .running
        state.statusMessage = "\(trigger.kind.label)：正在恢复 \(target.displayTitle)"
        state.lastError = nil
        runtimeState = state
        isRunning = true
        keepsLocalExecutionGate = true
        persistRuntimeState()

        let appServer = self.appServer
        let prompt = trigger.kind == .capacityRecovery
            ? AutoResumeConfiguration.defaultPrompt
            : configuration.prompt
        let sharedCooldown = trigger.kind == .manual
            ? TimeInterval.zero
            : TimeInterval(configuration.cooldownMinutes * 60)
        let codexBinaryProvider = self.codexBinaryProvider
        let ownerID = self.ownerID
        let sharedDailyLimit = trigger.kind == .manual
            ? nil
            : AutoResumeSharedDailyLimit(
                dayStart: Calendar.current.startOfDay(for: trigger.firedAt),
                maxRunsPerDay: configuration.maxRunsPerDay
            )
        let worker = Task.detached(priority: .utility) { () -> AutoResumeWorkerOutcome in
            let coordinator = AutoResumeSharedCoordinator(
                codexHome: dataSource.codexHome,
                ownerID: ownerID
            )
            do {
                if let startAuthorization, !startAuthorization.isValid {
                    return .skipped("自动续跑设置已变化，旧触发已作废")
                }
                guard let lease = try coordinator.acquireThreadLease(threadID: target.id) else {
                    return .skipped("另一个端正在续跑此任务")
                }
                defer { lease.release() }

                let claim = try coordinator.claimTriggerResolved(
                    key: trigger.key,
                    threadID: target.id,
                    minimumInterval: sharedCooldown,
                    dailyLimit: sharedDailyLimit,
                    repeatAfter: trigger.repeatAfter,
                    now: trigger.firedAt
                )
                switch claim.result {
                case .claimed:
                    break
                case .duplicate:
                    return .skipped("本次触发已由 Swift 或 Tauri 处理")
                case .cooldown:
                    return .deferred("另一个端的续跑仍在冷却")
                case .dailyLimit:
                    guard let sharedDailyLimit else {
                        return .failed(
                            message: "共享每日上限参数缺失",
                            requiresHuman: false,
                            quotaLimited: false,
                            claimedTrigger: false
                        )
                    }
                    return .dailyLimit(sharedDailyLimit)
                }
                guard let resolvedTriggerKey = claim.triggerKey else {
                    return .failed(
                        message: "共享触发记录未返回本次唯一标识",
                        requiresHuman: false,
                        quotaLimited: false,
                        claimedTrigger: false
                    )
                }

                do {
                    let codexPath = try codexBinaryProvider()
                    let result = try await appServer.resumeThread(
                        codexPath: codexPath,
                        dataSource: dataSource,
                        target: target,
                        prompt: prompt,
                        clientMessageID: resolvedTriggerKey,
                        expectedFreshness: expectedFreshness,
                        startAuthorization: startAuthorization
                    )
                    try? coordinator.completeTrigger(
                        key: resolvedTriggerKey,
                        outcome: "succeeded",
                        message: result.message
                    )
                    return .succeeded(result)
                } catch CodexAutoResumeAppServerError.threadProgressed {
                    let message = "目标任务已有新进展，本次续跑已视为完成"
                    try? coordinator.completeTrigger(
                        key: resolvedTriggerKey,
                        outcome: "satisfied",
                        message: message
                    )
                    return .satisfied(message)
                } catch AutoResumeStartGuardError.invalidated {
                    let message = "自动续跑设置已变化，旧触发已作废"
                    try? coordinator.completeTrigger(
                        key: resolvedTriggerKey,
                        outcome: "skipped",
                        message: message
                    )
                    return .skipped(message)
                } catch {
                    let requiresHuman: Bool
                    let quotaLimited: Bool
                    if let appServerError = error as? CodexAutoResumeAppServerError,
                       case .requiresHuman = appServerError {
                        requiresHuman = true
                    } else {
                        requiresHuman = false
                    }
                    if let appServerError = error as? CodexAutoResumeAppServerError,
                       case .quotaLimited = appServerError {
                        quotaLimited = true
                    } else {
                        quotaLimited = false
                    }
                    try? coordinator.completeTrigger(
                        key: resolvedTriggerKey,
                        outcome: requiresHuman
                            ? "requiresHuman"
                            : (quotaLimited ? "waitingQuota" : "failed"),
                        message: error.localizedDescription
                    )
                    return .failed(
                        message: error.localizedDescription,
                        requiresHuman: requiresHuman,
                        quotaLimited: quotaLimited,
                        claimedTrigger: true
                    )
                }
            } catch {
                return .failed(
                    message: error.localizedDescription,
                    requiresHuman: false,
                    quotaLimited: false,
                    claimedTrigger: false
                )
            }
        }
        workerTask = worker
        executionTask = Task { [weak self] in
            let outcome = await worker.value
            guard !Task.isCancelled, let self else { return }
            self.finishExecution(outcome, trigger: trigger)
        }
    }

    private func finishExecution(
        _ outcome: AutoResumeWorkerOutcome,
        trigger: AutoResumeTrigger,
        now: Date = Date()
    ) {
        let capacityTurnID = trigger.kind == .capacityRecovery
            ? runtimeState.capacityPendingFreshness?.baseline?.lastTurnID
            : nil
        executionTask = nil
        workerTask = nil
        isRunning = false
        localExecutionGate?.release(ownerID: ownerID)
        runtimeState.pruneRunHistory(now: now, calendar: .current)
        if outcome.claimedTrigger {
            runtimeState.lastRunAt = now
            if trigger.kind != .manual {
                runtimeState.runHistory.append(now)
            }
        }

        switch outcome {
        case .succeeded(let result):
            runtimeState.status = .succeeded
            runtimeState.statusMessage = "续跑成功 · turn \(String(result.turnID.prefix(8))) · \(result.status)"
            runtimeState.lastSuccessAt = now
            runtimeState.lastError = nil
        case .satisfied(let message):
            runtimeState.status = .waiting
            runtimeState.statusMessage = message
            runtimeState.lastError = nil
        case .dailyLimit(let rejectedLimit):
            if trigger.kind == .quotaRecovery {
                rearmQuotaAfterDeferredTrigger(repeatAfter: trigger.repeatAfter)
            }
            if configuration.maxRunsPerDay == rejectedLimit.maxRunsPerDay {
                runtimeState.sharedDailyLimitUntil = Calendar.current.date(
                    byAdding: .day,
                    value: 1,
                    to: rejectedLimit.dayStart
                )
                runtimeState.status = .waiting
                runtimeState.statusMessage = "今天已达到共享最多 \(configuration.maxRunsPerDay) 次，明天自动恢复"
            } else {
                runtimeState.sharedDailyLimitUntil = nil
                runtimeState.status = .waiting
                runtimeState.statusMessage = "每日上限已更新，等待重新检查"
            }
            runtimeState.lastError = nil
        case .failed(let message, let requiresHuman, let quotaLimited, _):
            if quotaLimited, configuration.enabled, configuration.quotaRecoveryEnabled {
                AutoResumePolicy.armAfterQuotaLimit(
                    configuration: configuration,
                    state: &runtimeState,
                    now: now
                )
                runtimeState.status = .waiting
                runtimeState.statusMessage = "额度暂不可用，等待新的额度样本确认恢复"
            } else {
                runtimeState.status = requiresHuman ? .requiresHuman : .failed
                runtimeState.statusMessage = requiresHuman
                    ? "需要人工处理，自动续跑已停止：\(message)"
                    : "续跑失败：\(message)"
            }
            runtimeState.lastError = message
        case .deferred(let message):
            if trigger.kind == .quotaRecovery {
                rearmQuotaAfterDeferredTrigger(repeatAfter: trigger.repeatAfter)
            }
            runtimeState.status = .waiting
            runtimeState.statusMessage = message
        case .skipped(let message):
            runtimeState.status = .waiting
            runtimeState.statusMessage = message
        }
        settlePendingFreshnessAfterExecution(outcome, trigger: trigger)
        if trigger.kind == .capacityRecovery,
           outcome.completesCapacityObservation {
            runtimeState.lastCapacityObservedTurnID = capacityTurnID
            runtimeState.capacityPendingFreshness = nil
        }
        runtimeState.lastTriggerKey = trigger.key
        runtimeState.lastTriggerKind = trigger.kind
        synchronizePendingFreshness(now: now)
        postResultNotificationIfNeeded(outcome)
        persistRuntimeState()
    }

    private func refreshWaitingStatus() {
        guard !isRunning, !isRefreshingThreads else { return }
        if !configuration.enabled {
            runtimeState.status = .idle
            runtimeState.statusMessage = configuration.target == nil
                ? "自动续跑未启用 · 尚未选择目标任务"
                : "自动续跑未启用"
            return
        }
        guard configuration.target != nil else {
            runtimeState.status = .waiting
            runtimeState.statusMessage = "自动续跑已启用，请选择目标任务"
            return
        }
        let hasTrigger = configuration.scheduleMode != .off
            || configuration.quotaRecoveryEnabled
            || configuration.capacityRecoveryEnabled
        guard hasTrigger else {
            runtimeState.status = .waiting
            runtimeState.statusMessage = "已启用，但尚未选择自动触发方式"
            return
        }
        runtimeState.status = .waiting
        let scheduleBaselinePending = configuration.scheduleMode != .off
            && runtimeState.schedulePendingFreshness?.baseline == nil
        let quotaBaselinePending = runtimeState.quotaArmed
            && runtimeState.quotaPendingFreshness?.baseline == nil
        if let sharedDailyLimitUntil = runtimeState.sharedDailyLimitUntil,
           Date() < sharedDailyLimitUntil {
            runtimeState.statusMessage = "今天已达到共享最多 \(configuration.maxRunsPerDay) 次，明天自动恢复"
        } else if scheduleBaselinePending || quotaBaselinePending {
            runtimeState.statusMessage = "正在建立目标任务的防重复基线"
        } else if runtimeState.quotaArmed {
            let remaining = runtimeState.lastQuotaRemainingPercent.map { "（当前 \($0)%）" } ?? ""
            runtimeState.statusMessage = "额度续跑已武装\(remaining)，等待恢复"
        } else if let next = nextScheduledAt {
            runtimeState.statusMessage = "等待下次续跑：\(next.formatted(date: .abbreviated, time: .shortened))"
        } else if configuration.capacityRecoveryEnabled {
            let reasonCount = configuration.failureRecoveryReasons.count
            runtimeState.statusMessage = configuration.quotaRecoveryEnabled
                ? "已监控 \(reasonCount) 类失败中断，同时观察额度恢复"
                : "已监控 \(reasonCount) 类失败中断，每 15 秒检查目标任务"
        } else {
            runtimeState.statusMessage = "正在等待额度进入低位"
        }
    }

    private func resetQuotaBaseline() {
        runtimeState.quotaArmed = false
        runtimeState.quotaArmedCycleID = nil
        runtimeState.quotaArmedWindowLabel = nil
        runtimeState.quotaRecoveryRequiresTransition = false
        runtimeState.quotaRecoveryObservedLow = false
        runtimeState.quotaRecoveryArmObservationAt = nil
        runtimeState.quotaLowObservedWindowLabels = []
        runtimeState.lastQuotaRemainingPercent = nil
        runtimeState.lastQuotaCycleID = nil
        runtimeState.lastQuotaWindowLabel = nil
        runtimeState.lastQuotaObservedAt = nil
        runtimeState.quotaPendingFreshness = nil
    }

    private func resetCapacityMonitoring() {
        capacityMonitorHasLiveBaseline = false
        runtimeState.capacityMonitorArmedAt = nil
        runtimeState.lastCapacityMonitorObservationKey = nil
        runtimeState.lastCapacityObservedTurnID = nil
        runtimeState.capacityPendingFreshness = nil
    }

    private func rearmQuotaAfterDeferredTrigger(repeatAfter: Date? = nil) {
        runtimeState.quotaArmed = true
        runtimeState.quotaArmedCycleID = runtimeState.lastQuotaCycleID
        runtimeState.quotaArmedWindowLabel = runtimeState.lastQuotaWindowLabel
        runtimeState.quotaRecoveryRequiresTransition = false
        runtimeState.quotaRecoveryObservedLow = true
        runtimeState.quotaRecoveryArmObservationAt =
            repeatAfter ?? runtimeState.lastQuotaObservedAt
    }

    private func settlePendingFreshnessAfterExecution(
        _ outcome: AutoResumeWorkerOutcome,
        trigger: AutoResumeTrigger
    ) {
        switch outcome {
        case .succeeded:
            runtimeState.schedulePendingFreshness = nil
            runtimeState.quotaPendingFreshness = nil
            runtimeState.capacityPendingFreshness = nil
            runtimeState.quotaArmed = false
            runtimeState.quotaArmedCycleID = nil
            runtimeState.quotaArmedWindowLabel = nil
            runtimeState.quotaRecoveryRequiresTransition = false
            runtimeState.quotaRecoveryObservedLow = false
            runtimeState.quotaRecoveryArmObservationAt = nil
            runtimeState.quotaLowObservedWindowLabels = []
        case .satisfied:
            switch trigger.kind {
            case .interval, .daily:
                runtimeState.schedulePendingFreshness = nil
            case .quotaRecovery:
                runtimeState.quotaPendingFreshness = nil
                runtimeState.quotaArmed = false
                runtimeState.quotaLowObservedWindowLabels = []
            case .capacityRecovery:
                runtimeState.capacityPendingFreshness = nil
            case .manual:
                break
            }
        case .dailyLimit:
            break
        case .failed(_, _, _, let claimedTrigger):
            guard claimedTrigger else { return }
            runtimeState.schedulePendingFreshness = nil
            runtimeState.quotaPendingFreshness = nil
        case .deferred, .skipped:
            break
        }
    }

    private func synchronizePendingFreshness(now: Date = Date()) {
        guard configuration.enabled, let target = configuration.target else {
            let changed = runtimeState.schedulePendingFreshness != nil
                || runtimeState.quotaPendingFreshness != nil
                || runtimeState.capacityPendingFreshness != nil
            runtimeState.schedulePendingFreshness = nil
            runtimeState.quotaPendingFreshness = nil
            runtimeState.capacityPendingFreshness = nil
            if changed { persistRuntimeState() }
            return
        }
        guard !isRunning else { return }

        var changed = false
        if configuration.scheduleMode == .off {
            if runtimeState.schedulePendingFreshness != nil {
                runtimeState.schedulePendingFreshness = nil
                changed = true
            }
        } else if runtimeState.schedulePendingFreshness?.threadID != target.id {
            runtimeState.schedulePendingFreshness = AutoResumePendingFreshness(
                threadID: target.id,
                armedAt: now,
                baseline: nil
            )
            changed = true
        }

        if !configuration.quotaRecoveryEnabled || !runtimeState.quotaArmed {
            if runtimeState.quotaPendingFreshness != nil {
                runtimeState.quotaPendingFreshness = nil
                changed = true
            }
        } else if runtimeState.quotaPendingFreshness?.threadID != target.id {
            runtimeState.quotaPendingFreshness = AutoResumePendingFreshness(
                threadID: target.id,
                armedAt: now,
                baseline: nil
            )
            changed = true
        }

        var captures: [AutoResumePendingCapture] = []
        if let pending = runtimeState.schedulePendingFreshness,
           pending.baseline == nil {
            captures.append(AutoResumePendingCapture(
                slot: .schedule,
                threadID: pending.threadID,
                armedAt: pending.armedAt
            ))
        }
        if let pending = runtimeState.quotaPendingFreshness,
           pending.baseline == nil {
            captures.append(AutoResumePendingCapture(
                slot: .quota,
                threadID: pending.threadID,
                armedAt: pending.armedAt
            ))
        }
        captures.removeAll { pendingFreshnessCaptureKeys.contains($0.key) }
        pendingFreshnessCaptureKeys.formUnion(captures.map(\.key))
        if changed { persistRuntimeState() }
        guard !captures.isEmpty else { return }

        let appServer = self.appServer
        let dataSource = dataSourceProvider()
        let codexBinaryProvider = self.codexBinaryProvider
        Task { [weak self] in
            do {
                let freshness = try await Task.detached(priority: .utility) {
                    let codexPath = try codexBinaryProvider()
                    return try await appServer.readThreadFreshness(
                        codexPath: codexPath,
                        dataSource: dataSource,
                        threadID: target.id
                    )
                }.value
                guard let self else { return }
                self.applyCapturedFreshness(freshness, captures: captures)
            } catch {
                guard let self else { return }
                self.pendingFreshnessCaptureKeys.subtract(captures.map(\.key))
            }
        }
    }

    private func applyCapturedFreshness(
        _ freshness: AutoResumeThreadFreshness,
        captures: [AutoResumePendingCapture]
    ) {
        pendingFreshnessCaptureKeys.subtract(captures.map(\.key))
        var changed = false
        for capture in captures {
            switch capture.slot {
            case .schedule:
                guard var pending = runtimeState.schedulePendingFreshness,
                      pending.threadID == capture.threadID,
                      pending.armedAt == capture.armedAt else {
                    continue
                }
                pending.baseline = freshness
                runtimeState.schedulePendingFreshness = pending
                changed = true
            case .quota:
                guard var pending = runtimeState.quotaPendingFreshness,
                      pending.threadID == capture.threadID,
                      pending.armedAt == capture.armedAt else {
                    continue
                }
                pending.baseline = freshness
                runtimeState.quotaPendingFreshness = pending
                changed = true
            }
        }
        if changed {
            refreshWaitingStatus()
            persistRuntimeState()
            if captures.contains(where: { $0.slot == .quota }), runtimeState.quotaArmed {
                handleQuotaSnapshot(quotaStore.snapshot)
            }
            evaluateSchedule()
        }
    }

    private func postResultNotificationIfNeeded(_ outcome: AutoResumeWorkerOutcome) {
        guard configuration.notifyOnResult, outcome.claimedTrigger else { return }
        switch outcome {
        case .succeeded:
            notifier.post(
                title: "Codex 自动续跑完成",
                body: runtimeState.statusMessage
            )
        case .failed:
            notifier.post(
                title: "Codex 自动续跑需要留意",
                body: runtimeState.statusMessage
            )
        case .satisfied, .dailyLimit, .deferred, .skipped:
            break
        }
    }

    private func persistRuntimeState() {
        AutoResumeStorage.save(
            runtimeState,
            key: runtimeStateStorageKey,
            defaults: defaults
        )
    }
}
