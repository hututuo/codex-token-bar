import Combine
import Foundation

enum AutoResumeTaskCreationResult: Equatable {
    case created(String)
    case existing(String)
}

@MainActor
final class AutoResumeManagedTask: ObservableObject, Identifiable {
    let id: String
    let createdAt: Date
    @Published var updatedAt: Date
    let controller: AutoResumeController
    fileprivate var subscriptions: Set<AnyCancellable> = []

    init(
        id: String,
        createdAt: Date,
        updatedAt: Date,
        controller: AutoResumeController
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.controller = controller
    }

    var configuration: AutoResumeConfiguration { controller.configuration }
    var runtimeState: AutoResumeRuntimeState { controller.runtimeState }
    var isRunning: Bool { controller.isRunning }
}

@MainActor
final class AutoResumeTaskManager: ObservableObject {
    nonisolated static let collectionStorageKey = "CodexTokenBar.autoResume.tasks.v2"

    @Published private(set) var tasks: [AutoResumeManagedTask] = []
    @Published var selectedTaskID: String?
    @Published private(set) var availableThreads: [AutoResumeThreadDescriptor] = []
    @Published private(set) var isRefreshingThreads = false
    @Published private(set) var catalogError: String?

    private let quotaStore: AccountQuotaStore
    private let appServer: any CodexAutoResumeAppServerServing
    private let defaults: UserDefaults
    private let dataSourceProvider: @MainActor () -> CodexDataSource?
    private let quotaBackgroundActivityChanged: @MainActor (Bool) -> Void
    private let notifier: any AutoResumeNotifying
    private let codexBinaryProvider: @Sendable () throws -> String
    private let executionGate = AutoResumeLocalExecutionGate()
    private var cancellables: Set<AnyCancellable> = []
    private var schedulerTimer: Timer?
    private var capacityCursor = 0
    private var started = false

    init(
        quotaStore: AccountQuotaStore,
        appServer: any CodexAutoResumeAppServerServing = CodexAppServerClient(),
        defaults: UserDefaults = .standard,
        dataSourceProvider: @escaping @MainActor () -> CodexDataSource? = {
            CodexDataSourceResolver().resolve()
        },
        quotaBackgroundActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        notifier: any AutoResumeNotifying = SystemAutoResumeNotifier(),
        codexBinaryProvider: @escaping @Sendable () throws -> String = {
            try CodexBinaryLocator.findExecutable()
        }
    ) {
        self.quotaStore = quotaStore
        self.appServer = appServer
        self.defaults = defaults
        self.dataSourceProvider = dataSourceProvider
        self.quotaBackgroundActivityChanged = quotaBackgroundActivityChanged
        self.notifier = notifier
        self.codexBinaryProvider = codexBinaryProvider

        let loaded = Self.loadCollection(defaults: defaults)
        let collection: AutoResumeTaskCollection
        let migratedRuntime: AutoResumeRuntimeState?
        if let loaded {
            collection = loaded.normalized
            migratedRuntime = nil
        } else if let legacy = AutoResumeStorage.loadConfiguration(defaults: defaults),
                  legacy.target != nil {
            let task = AutoResumeTaskDefinition(configuration: legacy)
            collection = AutoResumeTaskCollection(
                selectedTaskID: task.id,
                tasks: [task]
            )
            migratedRuntime = AutoResumeStorage.loadRuntimeState(defaults: defaults)
        } else {
            collection = .empty
            migratedRuntime = nil
        }

        selectedTaskID = collection.selectedTaskID
        tasks = collection.tasks.enumerated().map { index, definition in
            makeHandle(
                definition: definition,
                initialRuntimeState: index == 0 ? migratedRuntime : nil
            )
        }
        attachAllHandles()
        persistCollection()
        updateQuotaBackgroundActivity()
    }

    isolated deinit {
        schedulerTimer?.invalidate()
    }

    var selectedTask: AutoResumeManagedTask? {
        guard let selectedTaskID else { return nil }
        return task(id: selectedTaskID)
    }

    var hasProtectedTasks: Bool {
        tasks.contains { $0.configuration.enabled }
    }

    var protectedThreadIDs: Set<String> {
        Set(tasks.compactMap {
            guard $0.configuration.enabled else { return nil }
            return $0.configuration.target?.id
        })
    }

    func acquireSessionManagementExecution(ownerID: String) -> Bool {
        executionGate.acquire(ownerID: ownerID)
    }

    func releaseSessionManagementExecution(ownerID: String) {
        executionGate.release(ownerID: ownerID)
    }

    var runningTask: AutoResumeManagedTask? {
        tasks.first(where: \.isRunning)
    }

    func task(id: String) -> AutoResumeManagedTask? {
        tasks.first { $0.id == id }
    }

    func start() {
        guard !started else { return }
        started = true
        tasks.forEach { $0.controller.start() }

        quotaStore.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                Task { @MainActor in
                    self?.tasks.forEach { $0.controller.observeManagedQuota(snapshot) }
                }
            }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateTick()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        schedulerTimer = timer
        evaluateTick()
    }

    @discardableResult
    func createTask(target: AutoResumeThreadDescriptor) -> AutoResumeTaskCreationResult {
        if let existing = tasks.first(where: { $0.configuration.target?.id == target.id }) {
            selectedTaskID = existing.id
            persistCollection()
            return .existing(existing.id)
        }

        var configuration = AutoResumeConfiguration.default
        configuration.target = target
        configuration.enabled = false
        let definition = AutoResumeTaskDefinition(configuration: configuration)
        let handle = makeHandle(definition: definition, initialRuntimeState: nil)
        attach(handle)
        tasks.append(handle)
        selectedTaskID = handle.id
        persistCollection()
        updateQuotaBackgroundActivity()
        if started {
            handle.controller.start()
        }
        objectWillChange.send()
        return .created(handle.id)
    }

    func selectTask(id: String?) {
        selectedTaskID = id.flatMap { task(id: $0) == nil ? nil : $0 }
        persistCollection()
    }

    @discardableResult
    func deleteTask(id: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              !tasks[index].isRunning else {
            return false
        }
        let removed = tasks.remove(at: index)
        removed.controller.stopCurrentRun()
        defaults.removeObject(forKey: Self.configurationKey(taskID: id))
        defaults.removeObject(forKey: Self.runtimeStateKey(taskID: id))
        if selectedTaskID == id {
            selectedTaskID = tasks.indices.contains(index)
                ? tasks[index].id
                : tasks.last?.id
        }
        capacityCursor = tasks.isEmpty ? 0 : min(capacityCursor, tasks.count - 1)
        persistCollection()
        updateQuotaBackgroundActivity()
        objectWillChange.send()
        return true
    }

    func refreshThreads() {
        guard !isRefreshingThreads else { return }
        isRefreshingThreads = true
        catalogError = nil
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
            } catch {
                guard let self else { return }
                self.isRefreshingThreads = false
                self.catalogError = "会话读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func evaluateTick() {
        tasks.forEach { $0.controller.evaluateManagedTick(includeCapacity: false) }
        guard runningTask == nil,
              !tasks.isEmpty,
              !tasks.contains(where: { $0.controller.isCapacityCheckInFlight }) else {
            return
        }

        let capacityTasks = tasks.filter {
            $0.configuration.enabled
                && $0.configuration.capacityRecoveryEnabled
                && $0.configuration.target != nil
        }
        guard !capacityTasks.isEmpty else { return }
        capacityCursor %= capacityTasks.count
        let task = capacityTasks[capacityCursor]
        capacityCursor = (capacityCursor + 1) % capacityTasks.count
        task.controller.evaluateManagedTick(includeCapacity: true)
    }

    private func makeHandle(
        definition: AutoResumeTaskDefinition,
        initialRuntimeState: AutoResumeRuntimeState?
    ) -> AutoResumeManagedTask {
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-task-\(definition.id)-\(ProcessInfo.processInfo.processIdentifier)",
            dataSourceProvider: dataSourceProvider,
            quotaBackgroundActivityChanged: { _ in },
            notifier: notifier,
            codexBinaryProvider: codexBinaryProvider,
            configurationStorageKey: Self.configurationKey(taskID: definition.id),
            runtimeStateStorageKey: Self.runtimeStateKey(taskID: definition.id),
            initialConfiguration: definition.configuration,
            initialRuntimeState: initialRuntimeState,
            externallyManaged: true,
            localExecutionGate: executionGate
        )
        return AutoResumeManagedTask(
            id: definition.id,
            createdAt: definition.createdAt,
            updatedAt: definition.updatedAt,
            controller: controller
        )
    }

    private func attachAllHandles() {
        tasks.forEach(attach)
    }

    private func attach(_ handle: AutoResumeManagedTask) {
        handle.controller.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &handle.subscriptions)
        handle.controller.$configuration
            .dropFirst()
            .sink { [weak self, weak handle] _ in
                guard let self, let handle else { return }
                handle.updatedAt = Date()
                self.persistCollection()
                self.updateQuotaBackgroundActivity()
            }
            .store(in: &handle.subscriptions)
    }

    private func updateQuotaBackgroundActivity() {
        quotaBackgroundActivityChanged(
            tasks.contains {
                $0.configuration.enabled && $0.configuration.quotaRecoveryEnabled
            }
        )
    }

    private func persistCollection() {
        let collection = AutoResumeTaskCollection(
            selectedTaskID: selectedTaskID,
            tasks: tasks.map {
                AutoResumeTaskDefinition(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    configuration: $0.configuration
                )
            }
        ).normalized
        selectedTaskID = collection.selectedTaskID
        AutoResumeStorage.save(
            collection,
            key: Self.collectionStorageKey,
            defaults: defaults
        )
    }

    private static func loadCollection(defaults: UserDefaults) -> AutoResumeTaskCollection? {
        guard let data = defaults.data(forKey: collectionStorageKey) else { return nil }
        return try? JSONDecoder().decode(AutoResumeTaskCollection.self, from: data)
    }

    private static func configurationKey(taskID: String) -> String {
        "CodexTokenBar.autoResume.task.\(safeKey(taskID)).configuration.v2"
    }

    private static func runtimeStateKey(taskID: String) -> String {
        "CodexTokenBar.autoResume.task.\(safeKey(taskID)).runtimeState.v2"
    }

    private static func safeKey(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }
}
