import Foundation
import Sparkle
import TokenBarDiagnosticsCore

/// Observe Sparkle without changing its update, signature or installation policy.
/// Never serialize URLRequest, URL, error text, headers, or appcast release notes.
@MainActor final class UpdaterDiagnostics: NSObject, @preconcurrency SPUUpdaterDelegate {
    static let shared = UpdaterDiagnostics()
    private var attempt = UUID().uuidString
    private func record(_ phase:DiagnosticPhase, item:SUAppcastItem?=nil, code:Int?=nil) {
        DiagnosticRuntime.journal.record(.updater,phase,metrics:code.map{["code":Int64($0)]} ?? [:],attempt:attempt,
            targetVersion:item?.displayVersionString,targetBuild:item?.versionString)
    }
    func updater(_ updater:SPUUpdater, didFindValidUpdate item:SUAppcastItem) { attempt=UUID().uuidString;record(.available,item:item) }
    func updater(_ updater:SPUUpdater, willDownloadUpdate item:SUAppcastItem, with request:NSMutableURLRequest) { record(.downloading,item:item) }
    func updater(_ updater:SPUUpdater, didDownloadUpdate item:SUAppcastItem) { record(.downloaded,item:item) }
    func updater(_ updater:SPUUpdater, failedToDownloadUpdate item:SUAppcastItem, error:Error) { record(.failed,item:item,code:(error as NSError).code) }
    func userDidCancelDownload(_ updater:SPUUpdater) { record(.cancelled) }
    func updater(_ updater:SPUUpdater, willExtractUpdate item:SUAppcastItem) { record(.verifying,item:item) }
    func updater(_ updater:SPUUpdater, didExtractUpdate item:SUAppcastItem) { record(.completed,item:item) }
    func updater(_ updater:SPUUpdater, willInstallUpdate item:SUAppcastItem) {
        record(.replacing,item:item)
        // A small independent receipt survives the app replacement. It does
        // not mark success; the new app confirms after a successful refresh.
        DiagnosticInstallations.prepare(configuration:.production,attempt:attempt,targetVersion:item.displayVersionString,
            targetBuild:item.versionString,sourceBuild:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "")
    }
    func updaterWillRelaunchApplication(_ updater:SPUUpdater) { record(.launched);_ = DiagnosticRuntime.journal.flush(timeout:0.5) }
    func updater(_ updater:SPUUpdater, didAbortWithError error:Error) { record(.failed,code:(error as NSError).code) }
    func updater(_ updater:SPUUpdater, didFinishUpdateCycleFor updateCheck:SPUUpdateCheck, error:Error?) {
        record(error == nil ? .completed : .failed,code:error.map{($0 as NSError).code})
    }
}
