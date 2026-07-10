import Foundation

protocol ProviderSyncRunning: Sendable {
    func scan(codexHome: URL, includeArchivedSessions: Bool) async throws -> ProviderSyncSnapshot
    func sync(
        codexHome: URL,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?,
        dryRunOnly: Bool
    ) async throws -> ProviderSyncSnapshot
    func verify(
        codexHome: URL,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?
    ) async throws -> ProviderSyncSnapshot
    func rollbackLatest(codexHome: URL) async throws -> ProviderSyncSnapshot
    func rollback(codexHome: URL, backupPath: String) async throws -> ProviderSyncSnapshot
}

struct LiveProviderSyncRunner: ProviderSyncRunning {
    func scan(codexHome: URL, includeArchivedSessions: Bool) async throws -> ProviderSyncSnapshot {
        try await Task.detached(priority: .utility) {
            try ProviderSyncEngine().scan(codexHome: codexHome, includeArchivedSessions: includeArchivedSessions)
        }.value
    }

    func sync(
        codexHome: URL,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?,
        dryRunOnly: Bool
    ) async throws -> ProviderSyncSnapshot {
        try await Task.detached(priority: .utility) {
            try ProviderSyncEngine().sync(
                codexHome: codexHome,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: targetProviderOverride,
                dryRunOnly: dryRunOnly
            )
        }.value
    }

    func verify(
        codexHome: URL,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?
    ) async throws -> ProviderSyncSnapshot {
        try await Task.detached(priority: .utility) {
            try ProviderSyncEngine().verify(
                codexHome: codexHome,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: targetProviderOverride
            )
        }.value
    }

    func rollbackLatest(codexHome: URL) async throws -> ProviderSyncSnapshot {
        try await Task.detached(priority: .utility) {
            try ProviderSyncEngine().rollbackLatest(codexHome: codexHome)
        }.value
    }

    func rollback(codexHome: URL, backupPath: String) async throws -> ProviderSyncSnapshot {
        try await Task.detached(priority: .utility) {
            try ProviderSyncEngine().rollback(codexHome: codexHome, backupPath: backupPath)
        }.value
    }
}

@MainActor
final class ProviderSyncStore: ObservableObject {
    @Published private(set) var snapshot = ProviderSyncSnapshot()
    @Published private(set) var currentDataSource: CodexDataSource?
    @Published var includeArchivedSessions = true
    @Published var dryRunOnly = false
    @Published var manualProvider = ""
    @Published private(set) var hasScanned = false
    @Published private(set) var hasBackedUp = false
    @Published private(set) var hasRepaired = false
    @Published private(set) var hasVerified = false

    private let runner: any ProviderSyncRunning
    private var task: Task<Void, Never>?
    private var operationGeneration = 0
    private var activeOperationKind: OperationKind?
    private var hasBoundDataSource = false

    init(runner: any ProviderSyncRunning = LiveProviderSyncRunner()) {
        self.runner = runner
    }

    var canScanOrVerify: Bool {
        !snapshot.isWorking
    }

    var canCreateBackup: Bool {
        !snapshot.isWorking
    }

    var canSync: Bool {
        !snapshot.isWorking && (dryRunOnly || !snapshot.codexRunning)
    }

    var canRollback: Bool {
        !snapshot.isWorking && !snapshot.codexRunning
    }

    @discardableResult
    func setDataSource(_ dataSource: CodexDataSource?) -> Bool {
        let previousIdentity = currentDataSource?.stableIdentityKey
        let nextIdentity = dataSource?.stableIdentityKey
        let previousPath = currentDataSource?.codexHome.standardizedFileURL.path
        let nextPath = dataSource?.codexHome.standardizedFileURL.path
        hasBoundDataSource = true
        currentDataSource = dataSource
        guard previousIdentity != nextIdentity || previousPath != nextPath else { return false }

        if previousIdentity == nextIdentity {
            snapshot.codexHome = dataSource?.displayPath ?? "未选择 Codex Home"
            return true
        }

        operationGeneration += 1
        task?.cancel()
        task = nil
        activeOperationKind = nil
        snapshot = ProviderSyncSnapshot(
            codexHome: dataSource?.displayPath ?? "未选择 Codex Home",
            status: dataSource == nil ? "没有可用的 Codex Home" : "等待扫描当前 Codex Home"
        )
        hasScanned = false
        hasBackedUp = false
        hasRepaired = false
        hasVerified = false
        return true
    }

    func scan(dataSource: CodexDataSource?) {
        let includeArchivedSessions = includeArchivedSessions
        run(dataSource: dataSource, operationKind: .scan) { runner, source in
            try await runner.scan(codexHome: source.codexHome, includeArchivedSessions: includeArchivedSessions)
        }
    }

    func sync(dataSource: CodexDataSource?) {
        let includeArchivedSessions = includeArchivedSessions
        let dryRunOnly = dryRunOnly
        let targetProvider = effectiveTargetProvider()
        run(dataSource: dataSource, operationKind: dryRunOnly ? .backup : .sync) { runner, source in
            try await runner.sync(
                codexHome: source.codexHome,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: targetProvider,
                dryRunOnly: dryRunOnly
            )
        }
    }

    func backup(dataSource: CodexDataSource?) {
        let includeArchivedSessions = includeArchivedSessions
        let targetProvider = effectiveTargetProvider()
        run(dataSource: dataSource, operationKind: .backup) { runner, source in
            try await runner.sync(
                codexHome: source.codexHome,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: targetProvider,
                dryRunOnly: true
            )
        }
    }

    func verify(dataSource: CodexDataSource?) {
        let includeArchivedSessions = includeArchivedSessions
        let targetProvider = effectiveTargetProvider()
        run(dataSource: dataSource, operationKind: .verify) { runner, source in
            try await runner.verify(
                codexHome: source.codexHome,
                includeArchivedSessions: includeArchivedSessions,
                targetProviderOverride: targetProvider
            )
        }
    }

    func rollbackLatest(dataSource: CodexDataSource?) {
        run(dataSource: dataSource, operationKind: .rollback) { runner, source in
            try await runner.rollbackLatest(codexHome: source.codexHome)
        }
    }

    func rollback(dataSource: CodexDataSource?, backup: ProviderSyncBackupRecord) {
        run(dataSource: dataSource, operationKind: .rollback) { runner, source in
            try await runner.rollback(codexHome: source.codexHome, backupPath: backup.path)
        }
    }

    private func effectiveTargetProvider() -> String? {
        let trimmed = manualProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum OperationKind {
        case scan
        case backup
        case sync
        case verify
        case rollback

        var isDestructive: Bool {
            switch self {
            case .scan, .verify:
                false
            case .backup, .sync, .rollback:
                true
            }
        }
    }

    private func run(
        dataSource: CodexDataSource?,
        operationKind: OperationKind,
        operation: @escaping @Sendable (any ProviderSyncRunning, CodexDataSource) async throws -> ProviderSyncSnapshot
    ) {
        let dataSource = hasBoundDataSource ? currentDataSource : dataSource
        if let activeOperationKind,
           activeOperationKind.isDestructive || operationKind.isDestructive {
            var blocked = snapshot
            blocked.isWorking = true
            blocked.status = "已有修复操作进行中，请等待完成"
            snapshot = blocked
            return
        }

        task?.cancel()
        guard let dataSource else {
            operationGeneration += 1
            activeOperationKind = nil
            snapshot.status = "没有可用的 Codex Home"
            return
        }

        var working = snapshot
        working.codexHome = dataSource.displayPath
        working.isWorking = true
        working.status = "处理中..."
        snapshot = working

        operationGeneration += 1
        let generation = operationGeneration
        activeOperationKind = operationKind
        let runner = runner
        task = Task {
            let result: Result<ProviderSyncSnapshot, Error>
            do {
                result = .success(try await operation(runner, dataSource))
            } catch {
                result = .failure(error)
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard isCurrentOperation(generation: generation) else { return }
                switch result {
                case .success(var next):
                    if hasBoundDataSource {
                        next.codexHome = currentDataSource?.displayPath ?? "未选择 Codex Home"
                    }
                    snapshot = next
                    activeOperationKind = nil
                    markCompleted(operationKind)
                case .failure(let error):
                    var failed = snapshot
                    failed.isWorking = false
                    if let mutationError = error as? ProviderSyncMutationError,
                       case .codexRunning = mutationError {
                        failed.codexRunning = true
                    }
                    failed.status = error.localizedDescription
                    snapshot = failed
                    activeOperationKind = nil
                }
            }
        }
    }

    private func isCurrentOperation(generation: Int) -> Bool {
        operationGeneration == generation
    }

    private func markCompleted(_ operationKind: OperationKind) {
        switch operationKind {
        case .scan:
            hasScanned = true
        case .backup:
            hasScanned = true
            hasBackedUp = true
        case .sync:
            hasScanned = true
            hasBackedUp = true
            hasRepaired = true
        case .verify:
            hasScanned = true
            hasVerified = true
        case .rollback:
            hasScanned = true
        }
    }
}
