import Combine
import Foundation
import SwiftUI

/// Constructing this object never opens a ledger or starts a business owner.
/// The first window can render before the asynchronous startup gate runs.
@MainActor
final class ApplicationStartupCoordinator: ObservableObject {
    enum Phase: Equatable { case waiting, preparing, ready, readyWithPendingRecovery(String), failed(String) }
    typealias Prepare = @Sendable (@escaping @Sendable (BusinessDatabaseMigration.Progress) -> Void) async throws -> Void
    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var progress = BusinessDatabaseMigration.Progress(stage: .preparing)
    @Published private(set) var runtime: CodexReadyApplicationRuntime?
    private let prepare: Prepare
    private let activate: @MainActor () -> CodexReadyApplicationRuntime?
    private let productionLifecycle: Bool
    private var job: Task<Void, Never>?
    private var progressAt = Date.distantPast
    private var hasActivated = false
    private let retryDelay: @Sendable (Int) -> TimeInterval?
    private var retryAttempt = 0
    private var retryTimer: Task<Void, Never>?
    static private(set) var blocksBusinessServices = false

    init(prepare: @escaping Prepare = { callback in
        do {
            try await BusinessDatabaseMigration.startProduction(onProgress: callback)
        } catch {
            if BusinessSQLiteRoutes.hasPublishedAdmission {
                await SharedAccountUsageSafetyDatabase.prepareProductionConnection()
            }
            throw error
        }
        await SharedAccountUsageSafetyDatabase.prepareProductionConnection()
    }, activate: @escaping @MainActor () -> CodexReadyApplicationRuntime? = { CodexReadyApplicationRuntime() },
         productionLifecycle: Bool = true,
         retryDelay: @escaping @Sendable (Int) -> TimeInterval? = LocalRecoveryRetryPolicy.delay) {
        self.prepare = prepare; self.activate = activate; self.productionLifecycle = productionLifecycle
        self.retryDelay = retryDelay
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
                self.activateOnce()
                if self.productionLifecycle { Self.blocksBusinessServices = false }
                self.phase = .ready
                DiagnosticRuntime.record(.startup, .ready)
                self.retryTimer?.cancel(); self.retryTimer = nil; self.retryAttempt = 0
            } catch let deferred as PublishedBusinessAdmission.Deferred where BusinessSQLiteRoutes.hasPublishedAdmission {
                // The backend installed per-owner capabilities before returning
                // this state. Do not grant an unfinished owner writer access.
                if self.productionLifecycle { Self.blocksBusinessServices = false }
                self.activateOnce()
                self.phase = .readyWithPendingRecovery(deferred.localizedDescription)
                DiagnosticRuntime.record(.startup, .waiting)
                self.scheduleRetry(for: deferred)
            } catch {
                self.phase = .failed(error.localizedDescription)
                DiagnosticRuntime.record(.startup, .failed, ["code":Int64((error as NSError).code)])
                self.scheduleRetry(for: error)
            }
        }
    }

    func retry() {
        guard job == nil else { return }
        switch phase { case .failed, .readyWithPendingRecovery: break; default: return }
        retryTimer?.cancel(); retryTimer = nil; retryAttempt = 0
        phase = .waiting; start()
    }

    private func scheduleRetry(for error: Error) {
        guard LocalRecoveryRetryPolicy.canRetry(error), retryTimer == nil,
              let delay = retryDelay(retryAttempt), delay.isFinite, delay >= 0, delay <= 3600 else { return }
        retryAttempt += 1
        retryTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.job == nil else { return }
            self.retryTimer = nil
            switch self.phase { case .failed, .readyWithPendingRecovery: break; default: return }
            self.phase = .waiting; self.start()
        }
    }

    var recoveryNotice: String? {
        switch phase {
        case .readyWithPendingRecovery(let message): return "旧账可读，部分恢复尚未完成。\(message)"
        case .preparing where hasActivated: return "旧账继续显示，正在重试本地恢复。"
        case .failed(let message) where hasActivated: return "恢复未完成，已保留上次显示的统计。\(message)"
        default: return nil
        }
    }

    private func activateOnce() {
        guard !hasActivated else { return }
        runtime = activate(); hasActivated = true
    }

    private func receive(_ value: BusinessDatabaseMigration.Progress) {
        guard phase == .preparing else { return }
        let now = Date()
        guard value.stage != progress.stage || value.completed == value.total
                || now.timeIntervalSince(progressAt) >= 0.15 else { return }
        progressAt = now; progress = value
        DiagnosticRuntime.record(.uiProgress, .progress, ["completed":Int64(value.completed), "total":Int64(value.total)])
    }
}

struct PublishedRecoveryNotice: View {
    @ObservedObject var startup: ApplicationStartupCoordinator
    var body: some View {
        if let notice = startup.recoveryNotice {
            HStack(spacing: 12) {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("重试恢复") { startup.retry() }.disabled(startup.phase == .preparing)
                DiagnosticsExportButton()
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color.orange.opacity(0.10))
        }
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
            DiagnosticsExportButton()
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
