import Sparkle
import SwiftUI

@main
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
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
