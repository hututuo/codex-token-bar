import AppKit
import Sparkle
import SwiftUI

struct DashboardMenuBarExtra: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var loginItemStore: LoginItemStore
    @ObservedObject var updateSettingsStore: AppUpdateSettingsStore
    let updater: SPUUpdater

    var body: some View {
        Button("打开主界面") {
            StartupPresentation.showDashboardWindow {
                openWindow(id: "dashboard")
            }
        }

        Divider()

        CheckForUpdatesMenuItem(updater: updater)

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

        Divider()

        Button("退出") {
            NSApp.terminate(nil)
        }
    }
}
