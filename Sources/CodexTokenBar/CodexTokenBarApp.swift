import Sparkle
import SwiftUI

@main
@MainActor
enum CodexTokenBarEntry {
    static func main() {
        if CommandLine.arguments.contains("--verify-bundled-resources") {
            do {
                try AppResources.verifyPackagedResources()
                print("PASS packaged resources")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Packaged resource verification failed: \(error)\n".utf8))
                exit(1)
            }
        }
        CodexTokenBarApp.main()
    }
}

struct CodexTokenBarApp: App {
    @NSApplicationDelegateAdaptor(CodexTokenBarApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var startup = ApplicationStartupCoordinator()

    init() {
        TokenRateScaleSettings.initializeForV092()
        StartupPresentation.configureInitialActivationPolicy()
    }

    var body: some Scene {
        Window("Codex Token Bar", id: "dashboard") {
            Group {
                if let runtime = startup.runtime {
                    ReadyDashboardView(runtime: runtime)
                } else {
                    ApplicationStartupView(startup: startup)
                }
            }.frame(minWidth: 1080, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 1000)
        .commands {
            DashboardWindowCommands()
            CommandGroup(after: .appInfo) {
                if let runtime = startup.runtime { ReadyApplicationMenu(runtime: runtime) }
            }
        }
    }
}

/// Software repair remains available even when business initialization fails.
/// Lazy creation preserves normal launch policy and prevents two Sparkle owners.
@MainActor
final class ApplicationSoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = ApplicationSoftwareUpdater()
    @Published private(set) var canCheckForUpdates = false
    private var ownedController: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private let operationGate = ApplicationRecoveryOperationGate.shared

    var controller: SPUStandardUpdaterController {
        if let ownedController { return ownedController }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        ownedController = controller
        // The pinned Sparkle API requires all updater access on the main
        // thread. Observe before starting it, including automatic sessions.
        observations = [
            controller.updater.observe(\.sessionInProgress, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.operationGate.observeUpdateSession(updater.sessionInProgress) }
            },
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
        ]
        controller.startUpdater()
        return controller
    }

    private override init() {
        super.init()
        _ = controller
    }

    func checkForRecoveryUpdates() {
        let updater = controller.updater
        guard updater.canCheckForUpdates, operationGate.beginUpdateRequest() else { return }
        updater.checkForUpdates()
        // Focusing an existing update window does not emit a new KVO change.
        // A refused/no-op check must not leave a permanent pending latch.
        if updater.sessionInProgress { operationGate.observeUpdateSession(true) }
        else { operationGate.updateRequestDidNotStart() }
    }

    var canContinueRecoveryInstallation: Bool {
        guard let controller = ownedController,
              controller.userDriver.showUpdateInFocus != nil else { return false }
        return operationGate.canFocusInstallationSession(
            updaterSessionInProgress: controller.updater.sessionInProgress,
            canCheckForUpdates: controller.updater.canCheckForUpdates)
    }

    func continueRecoveryInstallation() {
        guard let controller = ownedController,
              let focus = controller.userDriver.showUpdateInFocus else { return }
        // Do not call checkForUpdates here. A delayed/refused termination can
        // close Sparkle's status window while its existing session still owns
        // installation. The pinned standard driver reopens its saved retry UI.
        operationGate.focusInstallationSession(
            updaterSessionInProgress: controller.updater.sessionInProgress,
            canCheckForUpdates: controller.updater.canCheckForUpdates,
            focus: focus)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !operationGate.migrationInProgress else {
            throw NSError(domain: "CodexTokenBar.Recovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "账本准备正在进行，请完成后再检查软件更新。"])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        operationGate.installationWillBegin()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        operationGate.updateCycleFinished(failed: error != nil)
    }
}

/// All business owners are built once, only after the background gate succeeds.
@MainActor
final class CodexReadyApplicationRuntime {
    let loginItemStore = LoginItemStore()
    let updateSettingsStore: AppUpdateSettingsStore
    let floatingPanel: FloatingTokenPanelController
    let statusBarPanel: StatusBarTokenController
    let dashboardRuntime: DashboardRuntime
    let threadDeleteBridge: CodexThreadDeleteBridgeController
    let autoResumeController: AutoResumeTaskManager
    let updaterController: SPUStandardUpdaterController

    init() {
        let updaterController = ApplicationSoftwareUpdater.shared.controller
        ActivitySpeedHistoryController.shared.start()
        let floatingPanel = FloatingTokenPanelController()
        let statusBarPanel = StatusBarTokenController()
        let threadDeleteBridge = CodexThreadDeleteBridgeController()
        let dashboardRuntime = DashboardRuntime(
            unreadThreadReader: LiveCodexSidebarUnreadThreadReader(
                bridge: threadDeleteBridge.service
            ),
            floatingPanel: floatingPanel,
            statusBarPanel: statusBarPanel
        )
        let autoResumeController = AutoResumeTaskManager(
            quotaStore: dashboardRuntime.quotaStore,
            dataSourceProvider: { [weak dashboardRuntime] in
                dashboardRuntime?.usageStore.currentDataSource
                    ?? CodexDataSourceResolver().resolve()
            },
            quotaBackgroundActivityChanged: { [weak dashboardRuntime] enabled in
                dashboardRuntime?.setAutoResumeQuotaBackgroundEnabled(enabled)
            },
            runningStateBackgroundActivityChanged: { [weak dashboardRuntime] enabled in
                dashboardRuntime?.setAutoResumeRunningStateBackgroundEnabled(enabled)
            }
        )
        self.updaterController = updaterController
        self.updateSettingsStore = AppUpdateSettingsStore(updater: updaterController.updater)
        self.floatingPanel = floatingPanel
        self.statusBarPanel = statusBarPanel
        self.threadDeleteBridge = threadDeleteBridge
        self.dashboardRuntime = dashboardRuntime
        self.autoResumeController = autoResumeController
        Task { @MainActor in
            threadDeleteBridge.start()
            autoResumeController.start()
            MultiClientUsageStore.shared.start()
            ModelTraceController.shared.start(sourceStore: dashboardRuntime.usageStore)
            AgentSpeedReportingController.shared.start()
        }
    }

}

private struct ReadyDashboardView: View {
    let runtime: CodexReadyApplicationRuntime
    var body: some View {
        DashboardView(loginItemStore: runtime.loginItemStore,
            updateSettingsStore: runtime.updateSettingsStore,
            threadDeleteBridge: runtime.threadDeleteBridge,
            autoResumeController: runtime.autoResumeController,
            runtime: runtime.dashboardRuntime)
        .overlay(alignment: .topTrailing) { AgentSpeedReportingInvitation() }
        .task {
            runtime.loginItemStore.start()
            runtime.updateSettingsStore.refresh()
#if DEBUG
            if UserDefaults.standard.bool(forKey: "debugCheckForUpdatesOnLaunch") {
                UserDefaults.standard.set(false, forKey: "debugCheckForUpdatesOnLaunch")
                try? await Task.sleep(nanoseconds: 900_000_000)
                runtime.updaterController.updater.checkForUpdates()
            }
#endif
        }
    }
}

private struct ReadyApplicationMenu: View {
    let runtime: CodexReadyApplicationRuntime
    @ObservedObject private var login: LoginItemStore
    @ObservedObject private var updates: AppUpdateSettingsStore
    @ObservedObject private var bridge: CodexThreadDeleteBridgeController
    init(runtime: CodexReadyApplicationRuntime) {
        self.runtime = runtime
        _login = ObservedObject(wrappedValue: runtime.loginItemStore)
        _updates = ObservedObject(wrappedValue: runtime.updateSettingsStore)
        _bridge = ObservedObject(wrappedValue: runtime.threadDeleteBridge)
    }
    var body: some View {
        CheckForUpdatesMenuItem(updater: runtime.updaterController.updater)
#if DEBUG
        if ClientPreviewMode.simulated {
            Button("诊断侧栏动效（5次）") { runtime.dashboardRuntime.replaySidebarForDiagnostics() }
            Button("诊断侧栏快速反向（5次）") { runtime.dashboardRuntime.replaySidebarForDiagnostics(rapid: true) }
        }
#endif
        Divider()
        Toggle(updates.menuTitle, isOn: Binding(get: { updates.automaticChecksEnabled },
            set: { updates.setAutomaticChecksEnabled($0) }))
        Toggle(login.menuTitle, isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }))
        Menu("界面大小") { InterfaceScaleMenuContent() }
        if login.needsSystemApproval { Button("打开登录项设置") { login.openLoginItemsSettings() } }
        if let message = login.errorMessage { Text("自启设置失败：\(message)") }
        Divider()
        Button(bridge.status.connectionActionTitle) { bridge.performConnectionAction() }
            .disabled(bridge.status.isBusy)
        Text(bridge.status.message)
        Divider()
    }
}
