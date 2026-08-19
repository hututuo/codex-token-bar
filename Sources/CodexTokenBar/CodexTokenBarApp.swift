import Sparkle
import SwiftUI

@main
struct CodexTokenBarApp: App {
    @NSApplicationDelegateAdaptor(CodexTokenBarApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var loginItemStore = LoginItemStore()
    @StateObject private var updateSettingsStore: AppUpdateSettingsStore
    @StateObject private var floatingPanel: FloatingTokenPanelController
    @StateObject private var statusBarPanel: StatusBarTokenController
    @StateObject private var dashboardRuntime: DashboardRuntime
    @StateObject private var threadDeleteBridge: CodexThreadDeleteBridgeController
    @StateObject private var autoResumeController: AutoResumeTaskManager
    private let updaterController: SPUStandardUpdaterController

    init() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
            }
        )
        self.updaterController = updaterController
        _updateSettingsStore = StateObject(wrappedValue: AppUpdateSettingsStore(updater: updaterController.updater))
        _floatingPanel = StateObject(wrappedValue: floatingPanel)
        _statusBarPanel = StateObject(wrappedValue: statusBarPanel)
        _threadDeleteBridge = StateObject(wrappedValue: threadDeleteBridge)
        _dashboardRuntime = StateObject(wrappedValue: dashboardRuntime)
        _autoResumeController = StateObject(wrappedValue: autoResumeController)
        StartupPresentation.configureInitialActivationPolicy()
        Task { @MainActor in
            threadDeleteBridge.start()
            autoResumeController.start()
        }
    }

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            DashboardView(
                loginItemStore: loginItemStore,
                updateSettingsStore: updateSettingsStore,
                threadDeleteBridge: threadDeleteBridge,
                autoResumeController: autoResumeController,
                runtime: dashboardRuntime
            )
                .frame(minWidth: 1080, minHeight: 760)
                .task {
                    loginItemStore.start()
                    updateSettingsStore.refresh()
#if DEBUG
                    if UserDefaults.standard.bool(forKey: "debugCheckForUpdatesOnLaunch") {
                        UserDefaults.standard.set(false, forKey: "debugCheckForUpdatesOnLaunch")
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        updaterController.updater.checkForUpdates()
                    }
#endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 1000)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(updater: updaterController.updater)

                Divider()

                Toggle(
                    updateSettingsStore.menuTitle,
                    isOn: Binding(
                        get: { updateSettingsStore.automaticChecksEnabled },
                        set: { updateSettingsStore.setAutomaticChecksEnabled($0) }
                    )
                )

                Toggle(
                    loginItemStore.menuTitle,
                    isOn: Binding(
                        get: { loginItemStore.isOn },
                        set: { loginItemStore.setEnabled($0) }
                    )
                )

                Menu("界面大小") {
                    InterfaceScaleMenuContent()
                }

                if loginItemStore.needsSystemApproval {
                    Button("打开登录项设置") {
                        loginItemStore.openLoginItemsSettings()
                    }
                }

                if let message = loginItemStore.errorMessage {
                    Text("自启设置失败：\(message)")
                }

                Divider()

                Button(threadDeleteBridge.status.connectionActionTitle) {
                    threadDeleteBridge.performConnectionAction()
                }
                .disabled(threadDeleteBridge.status.isBusy)

                Text(threadDeleteBridge.status.message)

                Divider()
            }
        }

    }
}
