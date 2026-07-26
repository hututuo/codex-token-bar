import Foundation

@MainActor
final class CodexInstanceStore: ObservableObject {
    @Published private(set) var snapshot: CodexInstanceRegistrySnapshot?
    @Published private(set) var statuses: [String: CodexInstanceRuntimeStatus] = [:]
    @Published private(set) var transactions: [CodexInstanceSyncTransactionSummary] = []
    @Published private(set) var preview: CodexInstanceSyncPreview?
    @Published private(set) var busyAction: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private let engine: CodexInstanceEngine?
    private let initializationError: Error?

    init(defaultCodexHome: URL?) {
        do {
            engine = try CodexInstanceEngine(defaultCodexHome: defaultCodexHome)
            initializationError = nil
        } catch {
            engine = nil
            initializationError = error
        }
    }

    func refresh() {
        guard busyAction == nil else { return }
        busyAction = "loading"
        errorMessage = nil
        Task {
            defer { busyAction = nil }
            do {
                let engine = try requireEngine()
                let result = try await Task.detached(priority: .utility) {
                    let snapshot = try engine.listInstances()
                    let transactions = try engine.listSyncTransactions()
                    let statuses = Dictionary(uniqueKeysWithValues: snapshot.instances.map { instance in
                        let status: CodexInstanceRuntimeStatus
                        do {
                            status = try engine.runtimeStatus(id: instance.id)
                        } catch {
                            status = CodexInstanceRuntimeStatus(
                                id: instance.id,
                                running: true,
                                controlled: false,
                                pid: nil,
                                message: "状态无法可靠确认，已按运行中锁定危险操作：\(error.localizedDescription)"
                            )
                        }
                        return (instance.id, status)
                    })
                    return (snapshot, transactions, statuses)
                }.value
                snapshot = result.0
                transactions = result.1
                statuses = result.2
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func create(_ request: CodexInstanceCreateRequest, onSuccess: @escaping () -> Void = {}) {
        perform("create", onSuccess: onSuccess) { engine in
            try await Task.detached(priority: .utility) {
                try engine.createInstance(request)
            }.value
        }
    }

    func importExisting(
        _ request: CodexInstanceImportRequest,
        onSuccess: @escaping () -> Void = {}
    ) {
        perform("import", onSuccess: onSuccess) { engine in
            try await Task.detached(priority: .utility) {
                try engine.importInstance(request)
            }.value
        }
    }

    func update(_ request: CodexInstanceUpdateRequest, onSuccess: @escaping () -> Void = {}) {
        perform("update", onSuccess: onSuccess) { engine in
            try await Task.detached(priority: .utility) {
                try engine.updateInstance(request)
            }.value
        }
    }

    func delete(id: String) {
        perform("delete") { engine in
            try await Task.detached(priority: .utility) {
                try engine.deleteInstance(id: id)
            }.value
        }
    }

    func launch(id: String) {
        perform("launch") { engine in
            try await Task.detached(priority: .utility) {
                try await engine.launchInstance(id: id)
            }.value
        }
    }

    func focus(id: String) {
        perform("focus") { engine in
            try await Task.detached(priority: .utility) {
                try engine.focusInstance(id: id)
            }.value
        }
    }

    func stop(id: String) {
        perform("stop") { engine in
            try await Task.detached(priority: .utility) {
                try await engine.stopInstance(id: id)
            }.value
        }
    }

    func previewSync(instanceIDs: [String]) {
        guard busyAction == nil else { return }
        busyAction = "preview"
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busyAction = nil }
            do {
                let engine = try requireEngine()
                let result = try await Task.detached(priority: .utility) {
                    try engine.previewSync(instanceIDs: instanceIDs)
                }.value
                preview = result
                statusMessage = "预览完成：\(result.operations.count) 项可安全同步，\(result.conflicts.count) 个分歧将保留。"
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func sync(instanceIDs: [String]) {
        perform("sync") { engine in
            try await Task.detached(priority: .utility) {
                try engine.syncInstances(instanceIDs: instanceIDs)
            }.value
        }
    }

    func rollback(transactionID: String) {
        perform("rollback") { engine in
            try await Task.detached(priority: .utility) {
                try engine.rollbackSync(transactionID: transactionID)
            }.value
        }
    }

    func clearPreview() {
        preview = nil
    }

    private func perform(
        _ action: String,
        onSuccess: @escaping () -> Void = {},
        operation: @escaping (CodexInstanceEngine) async throws -> CodexInstanceActionResult
    ) {
        guard busyAction == nil else { return }
        busyAction = action
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busyAction = nil }
            do {
                let result = try await operation(try requireEngine())
                statusMessage = result.message
                preview = nil
                onSuccess()
                try await refreshAfterMutation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func perform(
        _ action: String,
        operation: @escaping (CodexInstanceEngine) async throws -> CodexInstanceSyncResult
    ) {
        guard busyAction == nil else { return }
        busyAction = action
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busyAction = nil }
            do {
                let result = try await operation(try requireEngine())
                statusMessage = result.message
                preview = nil
                try await refreshAfterMutation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshAfterMutation() async throws {
        let engine = try requireEngine()
        let result = try await Task.detached(priority: .utility) {
            let snapshot = try engine.listInstances()
            let transactions = try engine.listSyncTransactions()
            let statuses = Dictionary(uniqueKeysWithValues: snapshot.instances.map { instance in
                let status: CodexInstanceRuntimeStatus
                do {
                    status = try engine.runtimeStatus(id: instance.id)
                } catch {
                    status = CodexInstanceRuntimeStatus(
                        id: instance.id,
                        running: true,
                        controlled: false,
                        pid: nil,
                        message: "状态无法可靠确认，已按运行中锁定危险操作：\(error.localizedDescription)"
                    )
                }
                return (instance.id, status)
            })
            return (snapshot, transactions, statuses)
        }.value
        snapshot = result.0
        transactions = result.1
        statuses = result.2
    }

    private func requireEngine() throws -> CodexInstanceEngine {
        if let engine { return engine }
        throw initializationError ?? NSError(
            domain: "CodexTokenBar.CodexInstances",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Codex 实例管理器初始化失败"]
        )
    }
}
