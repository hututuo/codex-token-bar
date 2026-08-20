import Foundation
import Sparkle

@MainActor
final class AppUpdateSettingsStore: ObservableObject {
    @Published private(set) var automaticChecksEnabled = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        refresh()
    }

    var menuTitle: String {
        "自动检查更新"
    }

    var statusText: String {
        automaticChecksEnabled ? "已开启" : "未开启"
    }

    func refresh() {
        automaticChecksEnabled = updater.automaticallyChecksForUpdates
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
