import Sparkle
import SwiftUI

struct CheckForUpdatesMenuItem: View {
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var body: some View {
        Button("检查更新…") {
            DiagnosticRuntime.record(.updater, .checking)
            updater.checkForUpdates()
        }
    }
}
