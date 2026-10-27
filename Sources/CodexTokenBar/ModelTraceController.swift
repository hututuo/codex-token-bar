import CryptoKit
import Combine
import Foundation

struct ModelTraceAutoSettings: Codable, Equatable, Sendable {
    var enabled = false
    var intervalHours = 24
    var nextRunAt: Int?
    var scopeKey: String?
}

private final class ModelTraceJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var run: ModelTrace.Run
    let store: ModelTraceHistoryStore
    let scope: String
    init(run: ModelTrace.Run, store: ModelTraceHistoryStore, scope: String) { self.run = run; self.store = store; self.scope = scope }
    func update(_ body: (inout ModelTrace.Run) -> Void) throws -> ModelTrace.Run {
        lock.lock(); defer { lock.unlock() }; body(&run); try store.save(run, scope: scope); return run
    }
    func snapshot() -> ModelTrace.Run { lock.lock(); defer { lock.unlock() }; return run }
}

@MainActor
final class ModelTraceController: ObservableObject {
    static let shared = ModelTraceController()
    @Published private(set) var runs: [ModelTrace.Run] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var settings = ModelTraceAutoSettings()
    private var scopeKey = ""
    private var source: CodexDataSource?
    private var cancel: ModelTraceCancellation?
    private var timer: Timer?
    private var sourceSubscription: AnyCancellable?
    private var loading = false
    private var checkingAuto = false
    @Published private(set) var settingsSaving = false
    private let store: ModelTraceHistoryStore
    init(store: ModelTraceHistoryStore? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.store = store ?? ModelTraceHistoryStore(url: base.appendingPathComponent("CodexTokenBar/modeltrace/modeltrace.sqlite"))
    }
    nonisolated static func scope(source: CodexDataSource) throws -> String {
        let account = try CurrentCodexCredentialReader.currentCredential(home: source.codexHome).id
        let input = "modeltrace-v1\0\(source.codexHome.path)\0\(source.stableIdentityKey)\0\(account)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func start(sourceStore: CodexUsageStore) {
        bind(source: sourceStore.currentDataSource)
        sourceSubscription = sourceStore.$dataSourceBindingKey.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak sourceStore] _ in
                self?.bind(source: sourceStore?.currentDataSource)
            }
    }
    func bind(source: CodexDataSource?) {
        guard self.source != source || timer == nil else { return }
        cancel?.cancel(); self.source = source; runs = []; scopeKey = ""
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.autoTick() } }
        }
        refresh()
    }
    func refresh() {
        guard let source, !loading else { return }
        loading = true
        let store = store
        Task {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    let scope = try Self.scope(source: source)
                    return (scope, try store.history(scope: scope), try store.autoSettings())
                }.value
                guard self.source == source else { loading = false; refresh(); return }
                scopeKey = loaded.0; runs = loaded.1; settings = loaded.2; error = nil
                if !busy {
                    for index in runs.indices where runs[index].status == "running" {
                        runs[index].status = "interrupted"; runs[index].completedAt = Int(Date().timeIntervalSince1970); runs[index].message = "上次检测已中断，未自动重试"
                        let run = runs[index], scope = scopeKey
                        Task.detached(priority: .utility) { try? store.save(run, scope: scope) }
                    }
                }
                loading = false
                autoTick()
            } catch { self.error = error.localizedDescription; loading = false }
        }
    }
    func start(model: String = ModelTrace.defaultModel) {
        guard !busy, ModelTrace.models.contains(model), let source else { return }
        busy = true; error = nil
        let token = ModelTraceCancellation(); cancel = token
        let store = store
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<(String, ModelTrace.Run), Error> in
                do {
                    let scope = try Self.scope(source: source)
                    let state = ModelTraceJobState(run: ModelTrace.Run(model: model), store: store, scope: scope)
                    _ = try state.update { _ in }
                    do {
                        let attribution = try ModelTraceProbe().run(source: source, model: model, cancel: token, validate: {
                            guard CodexHomeIdentity.read(at: source.codexHome) == source.homeIdentity,
                                  try Self.scope(source: source) == scope else { throw ModelTrace.fail("账号或数据源已改变，检测已停止") }
                        }, progress: { attempt, sample in
                            let run = try state.update { run in
                                run.attempts = max(run.attempts, attempt)
                                if let sample { run.samples.append(sample); run.validSamples = run.samples.count }
                            }
                            Task { @MainActor in
                                guard self.source == source else { return }
                                self.scopeKey = scope; self.publish(run)
                            }
                        })
                        _ = try state.update { run in run.attribution = attribution; run.status = "completed"; run.message = ModelTrace.message(model: model, attribution: attribution); run.completedAt = Int(Date().timeIntervalSince1970) }
                    } catch {
                        _ = try state.update { run in run.status = token.isCancelled ? "cancelled" : "failed"; run.message = error.localizedDescription; run.completedAt = Int(Date().timeIntervalSince1970) }
                    }
                    return .success((scope, state.snapshot()))
                } catch { return .failure(error) }
            }.value
            busy = false; cancel = nil
            switch result {
            case .success(let (scope, run)):
                if self.source == source { scopeKey = scope; publish(run) }
                if settings.enabled, settings.scopeKey == scope { saveAuto(enabled: true, hours: settings.intervalHours) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    func stop() { cancel?.cancel() }
    func saveAuto(enabled: Bool, hours: Int) {
        guard (1...168).contains(hours), !settingsSaving else { return }
        settingsSaving = true
        let next = ModelTraceAutoSettings(enabled: enabled, intervalHours: hours, nextRunAt: enabled ? Int(Date().timeIntervalSince1970) + hours * 3600 : nil, scopeKey: scopeKey.isEmpty ? nil : scopeKey)
        let store = store
        Task {
            do { try await Task.detached(priority: .utility) { try store.saveAutoSettings(next) }.value; settings = next; error = nil }
            catch { self.error = error.localizedDescription }
            settingsSaving = false
        }
    }
    private func autoTick() {
        guard settings.enabled, !busy, !loading, !settingsSaving, !checkingAuto,
              let source, !scopeKey.isEmpty, (1...168).contains(settings.intervalHours) else { return }
        checkingAuto = true
        Task {
            let current = try? await Task.detached(priority: .utility) { try Self.scope(source: source) }.value
            checkingAuto = false
            guard self.source == source, !busy, settings.enabled, !settingsSaving else { return }
            guard let current else { return }
            if current != scopeKey { refresh(); return }
            if settings.scopeKey != scopeKey || settings.nextRunAt == nil { saveAuto(enabled: true, hours: settings.intervalHours); return }
            if let next = settings.nextRunAt, next <= Int(Date().timeIntervalSince1970) {
                // One due run only; missed intervals are never replayed in a burst.
                start()
            }
        }
    }
    private func publish(_ run: ModelTrace.Run) {
        runs.removeAll { $0.id == run.id }; runs.insert(run, at: 0); runs = Array(runs.prefix(100))
    }
}

extension ModelTraceHistoryStore {
    private func settingsDB() throws -> SQLiteDatabaseDriver {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = SQLiteDatabaseDriver(url: url)
        try db.execute("CREATE TABLE IF NOT EXISTS modeltrace_settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL)")
        return db
    }
    func autoSettings() throws -> ModelTraceAutoSettings {
        try settingsDB().readRows("SELECT payload FROM modeltrace_settings WHERE id=1") { statement in
            try JSONDecoder().decode(ModelTraceAutoSettings.self, from: Data((statement.text(0) ?? "").utf8))
        }.first ?? ModelTraceAutoSettings()
    }
    func saveAutoSettings(_ settings: ModelTraceAutoSettings) throws {
        let payload = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try settingsDB().execute("INSERT INTO modeltrace_settings(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", bindings: [.text(payload)])
    }
}
