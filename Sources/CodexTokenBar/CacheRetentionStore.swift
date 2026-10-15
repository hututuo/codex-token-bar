import Foundation
import SwiftUI

/// One shared presentation owner; homepage, chart and advice read this store.
@MainActor
final class CacheRetentionStore: ObservableObject {
    @Published private(set) var snapshot = CacheRetentionSnapshot()
    @Published private(set) var adviceAnalysis = CacheRetentionAnalysis.calculate([])
    @Published private(set) var status = "正在准备本机续问建议"
    @Published private(set) var isUpdating = false
    @Published private(set) var scope = CacheRetentionScope()
    @Published private(set) var chart = CacheRetentionChartData(points: [])
    @Published var isChartPresented = false
    private var source: CodexDataSource?
    private var engine: CacheRetentionEngine?
    private var work: Task<Void, Never>?
    private var analysisWork: Task<Void, Never>?
    private var generation = UUID()
    private var backgroundGeneration = UUID()
    private let engineFactory: @Sendable (CodexDataSource) throws -> CacheRetentionEngine

    init(engineFactory: @escaping @Sendable (CodexDataSource) throws -> CacheRetentionEngine = { try CacheRetentionEngine(source: $0) }) {
        self.engineFactory = engineFactory
    }
    private var dirty = false

    func bind(_ source: CodexDataSource?) {
        guard self.source != source else { return }
        generation = UUID(); backgroundGeneration = UUID(); work?.cancel(); analysisWork?.cancel()
        self.source = source; engine = nil; dirty = false; isUpdating = false
        snapshot = .init(); adviceAnalysis = .calculate([]); chart = .init(points: [])
        status = source == nil ? "请先选择 Codex 数据目录" : "正在准备本机续问建议"
    }

    func cancelBackgroundWork() {
        backgroundGeneration = UUID(); work?.cancel(); isUpdating = false; dirty = false
    }

    func refresh() {
        guard let source else { return }
        if isUpdating { dirty = true; return }
        isUpdating = true; dirty = false; backgroundGeneration = UUID()
        let token = backgroundGeneration
        work = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let worker: CacheRetentionEngine
                if let current = engine { worker = current }
                else {
                    let factory = engineFactory
                    worker = try await Task.detached(priority: .utility) { try factory(source) }.value
                    guard token == backgroundGeneration, !Task.isCancelled else { return }
                    engine = worker
                }
                if snapshot.updatedAt == nil {
                    let restored = try await worker.snapshot(scope: scope)
                    guard token == backgroundGeneration, !Task.isCancelled else { return }
                    publish(restored)
                }
                var failures = 0
                repeat {
                    dirty = false
                    failures = try await worker.synchronize { [weak self] done, count in
                        Task { @MainActor [weak self] in
                            guard let self, self.backgroundGeneration == token, self.isUpdating else { return }
                            self.status = "正在更新续问建议 · \(done) / \(count) 个来源"
                        }
                    }
                    guard token == backgroundGeneration, !Task.isCancelled else { return }
                    let currentScope = scope
                    let result = try await worker.snapshot(scope: currentScope)
                    let all = currentScope == CacheRetentionScope() ? result : try await worker.snapshot(scope: .init())
                    guard token == backgroundGeneration, !Task.isCancelled else { return }
                    adviceAnalysis = all.analysis
                    if currentScope == scope { publish(result) } else { analyzeScope() }
                    status = failures == 0 ? "本机历史已更新" : "已更新可读取历史 · \(failures) 个来源稍后重试"
                } while dirty
                isUpdating = false
            } catch is CancellationError {
                if token == backgroundGeneration { isUpdating = false }
            } catch {
                guard token == backgroundGeneration else { return }
                isUpdating = false
                status = "续问建议暂未更新：\(error.localizedDescription)"
            }
        }
    }

    func select(range: CacheRetentionScope.Range? = nil, model: String?? = nil) {
        if let range { scope.range = range }
        if let model { scope.model = model }
        analyzeScope()
    }

    private func analyzeScope() {
        analysisWork?.cancel()
        let token = generation; let selected = scope
        snapshot = .init(models: snapshot.models, scope: selected); chart = .init(points: [])
        guard let engine else { return }
        analysisWork = Task { [weak self] in
            do {
                let result = try await engine.snapshot(scope: selected)
                guard let self, !Task.isCancelled, self.generation == token, self.scope == selected else { return }
                self.publish(result)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.scope == selected else { return }
                self.status = "续问建议暂未更新：\(error.localizedDescription)"
            }
        }
    }

    private func publish(_ result: CacheRetentionSnapshot) {
        snapshot = result
        chart = result.chartData
        if result.scope == CacheRetentionScope() { adviceAnalysis = result.analysis }
    }
}
