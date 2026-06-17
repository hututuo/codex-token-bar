import Sparkle
import SwiftUI

@main
struct CodexTokenBarApp: App {
    @StateObject private var loginItemStore = LoginItemStore()
    @StateObject private var updateSettingsStore: AppUpdateSettingsStore
    @StateObject private var floatingPanel = FloatingTokenPanelController()
    @StateObject private var statusBarPanel = StatusBarTokenController()
    private let updaterController: SPUStandardUpdaterController

    init() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController
        _updateSettingsStore = StateObject(wrappedValue: AppUpdateSettingsStore(updater: updaterController.updater))
        StartupPresentation.configureInitialActivationPolicy()
    }

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            DashboardView(
                loginItemStore: loginItemStore,
                updateSettingsStore: updateSettingsStore,
                floatingPanel: floatingPanel,
                statusBarPanel: statusBarPanel
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
            }
        }

        MenuBarExtra("Codex Token Bar", systemImage: "bolt.circle.fill") {
            DashboardMenuBarExtra(
                loginItemStore: loginItemStore,
                updateSettingsStore: updateSettingsStore,
                updater: updaterController.updater
            )
        }
        .menuBarExtraStyle(.menu)
    }
}
