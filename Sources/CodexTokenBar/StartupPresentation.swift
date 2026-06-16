import AppKit
import Foundation
import ServiceManagement

enum StartupPresentation {
    private static let setupGuideCompletedKey = "setupGuideCompletedV01"
    private static let loginLaunchWindowSeconds: TimeInterval = 180

    @MainActor
    static func configureInitialActivationPolicy() {
        guard shouldHideDashboardAtStartup() else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor
    static func hideDashboardIfNeeded() {
        guard shouldHideDashboardAtStartup() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            dashboardWindows().forEach { $0.orderOut(nil) }
        }
    }

    @MainActor
    static func showDashboardWindow(openWindow: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let windows = dashboardWindows()
        if let window = windows.first {
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
