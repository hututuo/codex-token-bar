import Combine
import Foundation
import SwiftUI

/// Constructing this object never opens a ledger or starts a business owner.
/// The first window can render before the asynchronous startup gate runs.
@MainActor
final class ApplicationStartupCoordinator: ObservableObject {
    enum Phase: Equatable { case waiting, preparing, ready, failed(String) }
    typealias Prepare = @Sendable (@escaping @Sendable (BusinessDatabaseMigration.Progress) -> Void) async throws -> Void
    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var progress = BusinessDatabaseMigration.Progress(stage: .preparing)
    @Published private(set) var runtime: CodexReadyApplicationRuntime?
    private let prepare: Prepare
    private let activate: @MainActor () -> CodexReadyApplicationRuntime?
    private let productionLifecycle: Bool
    private var job: Task<Void, Never>?
    private var progressAt = Date.distantPast
    static private(set) var blocksBusinessServices = false

    init(prepare: @escaping Prepare = { callback in
        try await BusinessDatabaseMigration.startProduction(onProgress: callback)
    }, activate: @escaping @MainActor () -> CodexReadyApplicationRuntime? = { CodexReadyApplicationRuntime() },
         productionLifecycle: Bool = true) {
        self.prepare = prepare; self.activate = activate; self.productionLifecycle = productionLifecycle
        if productionLifecycle { Self.blocksBusinessServices = true }
    }

    func start() {
        guard phase == .waiting, job == nil else { return }
        phase = .preparing
        job = Task { [weak self] in
            guard let self else { return }
            defer { self.job = nil }
            do {
                try await self.prepare { [weak self] progress in
                    Task { @MainActor in self?.receive(progress) }
                }
                // Routes and the lifetime writer lock are installed first.
                self.runtime = self.activate()
                if self.productionLifecycle { Self.blocksBusinessServices = false }
                self.phase = .ready
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        guard case .failed = phase, job == nil else { return }
        phase = .waiting; start()
    }

    private func receive(_ value: BusinessDatabaseMigration.Progress) {
        guard phase == .preparing else { return }
        let now = Date()
        guard value.stage != progress.stage || value.completed == value.total
                || now.timeIntervalSince(progressAt) >= 0.15 else { return }
        progressAt = now; progress = value
    }
}

struct ApplicationStartupView: View {
    @ObservedObject var startup: ApplicationStartupCoordinator
    @Environment(\.openWindow) private var openWindow
    private var title: String {
        switch startup.progress.stage {
        case .preparing: "正在打开本地账本"
        case .importing: "正在备份并归并旧账本"
        case .verifying: "正在核对历史记录"
        case .activating: "正在完成账本升级"
        case .ready: "正在打开主页"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Codex Token Bar", systemImage: "chart.bar.xaxis").font(.title2.bold())
            if case let .failed(message) = startup.phase {
                Label("账本准备未完成", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).textSelection(.enabled)
                Text("旧账本和备份已保留，尚未启动业务写入。可以重试，或退出后检查。")
                    .foregroundStyle(.secondary)
                HStack { Button("重试") { startup.retry() }; Button("退出") { NSApp.terminate(nil) } }
            } else {
                Text(title).font(.headline)
                if startup.progress.total > 0 {
                    ProgressView(value: Double(startup.progress.completed), total: Double(startup.progress.total))
                    Text("\(startup.progress.completed) / \(startup.progress.total) 个索引")
                        .monospacedDigit().foregroundStyle(.secondary)
                } else { ProgressView().controlSize(.small) }
                Text("首次升级可能需要几分钟。迁移在后台执行，完成校验后自动进入主页；原始账本和备份都会保留。")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(30).frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            DashboardReopenCoordinator.shared.install {
                StartupPresentation.showDashboardWindow { openWindow(id: "dashboard") }
            }
            StartupPresentation.hideDashboardIfNeeded()
            startup.start()
        }
    }
}
