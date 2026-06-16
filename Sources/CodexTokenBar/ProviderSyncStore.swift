import Foundation

@MainActor
final class ProviderSyncStore: ObservableObject {
    @Published private(set) var snapshot = ProviderSyncSnapshot()
    @Published var includeArchivedSessions = true
    @Published var dryRunOnly = false
    @Published var manualProvider = ""
    @Published private(set) var hasScanned = false
    @Published private(set) var hasBackedUp = false
    @Published private(set) var hasRepaired = false
    @Published private(set) var hasVerified = false

    private var task: Task<Void, Never>?

    func scan(dataSource: CodexDataSource?) {
        run(dataSource: dataSource, operationKind: .scan) { engine, source in
            try engine.scan(codexHome: source.codexHome, includeArchivedSessions: self.includeArchivedSessions)
        }
    }

    func sync(dataSource: CodexDataSource?) {
        run(dataSource: dataSource, operationKind: self.dryRunOnly ? .backup : .sync) { engine, source in
            let targetProvider = self.effectiveTargetProvider()
            return try engine.sync(
                codexHome: source.codexHome,
                includeArchivedSessions: self.includeArchivedSessions,
                targetProviderOverride: targetProvider,
                dryRunOnly: self.dryRunOnly
            )
        }
    }

    func backup(dataSource: CodexDataSource?) {
        run(dataSource: dataSource, operationKind: .backup) { engine, source in
            let targetProvider = self.effectiveTargetProvider()
            return try engine.sync(
                codexHome: source.codexHome,
                includeArchivedSessions: self.includeArchivedSessions,
                targetProviderOverride: targetProvider,
                dryRunOnly: true
            )
        }
    }

    func verify(dataSource: CodexDataSource?) {
        run(dataSource: dataSource, operationKind: .verify) { engine, source in
            let targetProvider = self.effectiveTargetProvider()
            return try engine.verify(
                codexHome: source.codexHome,
                includeArchivedSessions: self.includeArchivedSessions,
                targetProviderOverride: targetProvider
            )
        }
    }

    func rollbackLatest(dataSource: CodexDataSource?) {
        run(dataSource: dataSource, operationKind: .rollback) { engine, source in
            try engine.rollbackLatest(codexHome: source.codexHome)
        }
    }

    func rollback(dataSource: CodexDataSource?, backup: ProviderSyncBackupRecord) {
        run(dataSource: dataSource, operationKind: .rollback) { engine, source in
            try engine.rollback(codexHome: source.codexHome, backupPath: backup.path)
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
    }

    private func run(
        dataSource: CodexDataSource?,
        operationKind: OperationKind,
        operation: @escaping (ProviderSyncEngine, CodexDataSource) throws -> ProviderSyncSnapshot
    ) {
        task?.cancel()
        guard let dataSource else {
            snapshot.status = "没有可用的 Codex Home"
            return
        }

        var working = snapshot
        working.codexHome = dataSource.displayPath
        working.isWorking = true
        working.status = "处理中..."
        snapshot = working

        task = Task {
            let result = await Task.detached(priority: .utility) {
                do {
                    return Result<ProviderSyncSnapshot, Error>.success(try operation(ProviderSyncEngine(), dataSource))
                } catch {
                    return Result<ProviderSyncSnapshot, Error>.failure(error)
                }
            }.value

            await MainActor.run {
                switch result {
                case .success(let next):
                    snapshot = next
                    markCompleted(operationKind)
                case .failure(let error):
                    var failed = snapshot
                    failed.isWorking = false
                    failed.status = error.localizedDescription
                    snapshot = failed
                }
            }
        }
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
