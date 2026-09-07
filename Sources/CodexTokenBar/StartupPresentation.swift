import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class DashboardReopenCoordinator {
    static let shared = DashboardReopenCoordinator()

    private var reopenAction: (() -> Void)?
    private var initialWindowRequested = false

    func ensureInitialWindow(_ action: () -> Void) {
        guard !initialWindowRequested else { return }
        initialWindowRequested = true
        action()
    }

    func install(_ action: @escaping () -> Void) {
        reopenAction = action
    }

    @discardableResult
    func handleApplicationReopen(hasVisibleWindows: Bool) -> Bool {
        // A floating panel counts as visible too; Dock activation always targets the dashboard.
        guard let reopenAction else {
            return false
        }
        reopenAction()
        return true
    }
}

@MainActor
final class CodexTokenBarApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        DashboardReopenCoordinator.shared.handleApplicationReopen(
            hasVisibleWindows: flag
        )
    }
}

@MainActor
final class DashboardStartupVisibility {
    private var pendingInitialHide = true

    func consumeInitialHide(shouldHide: Bool) -> Bool {
        guard pendingInitialHide else { return false }
        pendingInitialHide = false
        return shouldHide
    }

    private(set) var explicitlyOpened = false

    func requestOpen() {
        explicitlyOpened = true
        pendingInitialHide = false
    }
}

enum StartupPresentation {
    @MainActor private static let visibility = DashboardStartupVisibility()
    private static let setupGuideCompletedKey = "setupGuideCompletedV01"
    private static let loginLaunchWindowSeconds: TimeInterval = 180

    @MainActor
    static func configureInitialActivationPolicy() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    @MainActor
    static func hideDashboardIfNeeded() {
        guard visibility.consumeInitialHide(shouldHide: shouldHideDashboardAtStartup()) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !visibility.explicitlyOpened else { return }
            dashboardWindows().forEach { $0.orderOut(nil) }
        }
    }

    @MainActor
    static func showDashboardWindow(openWindow: () -> Void) {
        visibility.requestOpen()
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        let windows = dashboardWindows()
        if let window = windows.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow()
        }
    }

    private static func shouldHideDashboardAtStartup() -> Bool {
        UserDefaults.standard.bool(forKey: setupGuideCompletedKey)
            && SMAppService.mainApp.status == .enabled
            && isNearConsoleLogin()
    }

    private static func isNearConsoleLogin() -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
            let loginDate = attributes[.modificationDate] as? Date
        else {
            return false
        }

        let elapsed = Date().timeIntervalSince(loginDate)
        return elapsed >= 0 && elapsed <= loginLaunchWindowSeconds
    }

    @MainActor
    private static func dashboardWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            !(window is NSPanel)
                && window.contentViewController != nil
        }
    }
}

/// Lives in the scene graph even when no dashboard window has been created.
struct DashboardWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = registerWindowActions()
        CommandGroup(after: .newItem) {
            Button("打开主界面") {
                StartupPresentation.showDashboardWindow {
                    openWindow(id: "dashboard")
                }
            }
        }
    }

    private func registerWindowActions() {
        let action = openWindow
        DispatchQueue.main.async {
            DashboardReopenCoordinator.shared.install {
                StartupPresentation.showDashboardWindow {
                    action(id: "dashboard")
                }
            }
            DashboardReopenCoordinator.shared.ensureInitialWindow {
                action(id: "dashboard")
            }
        }
    }
}
