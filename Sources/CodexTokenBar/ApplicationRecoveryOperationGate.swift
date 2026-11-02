import Combine
import Foundation

/// Main-actor ownership for the two actions offered before business owners exist.
/// Sparkle callbacks update this gate for automatic as well as manual checks.
@MainActor
final class ApplicationRecoveryOperationGate: ObservableObject {
    static let shared = ApplicationRecoveryOperationGate()

    @Published private(set) var migrationInProgress = false
    @Published private(set) var updateRequestPending = false
    @Published private(set) var updateSessionInProgress = false
    @Published private(set) var installationInProgress = false

    var canBeginMigration: Bool {
        !migrationInProgress && !updateRequestPending && !updateSessionInProgress && !installationInProgress
    }

    var canRequestUpdate: Bool {
        !migrationInProgress && !updateRequestPending && !installationInProgress
    }

    @discardableResult func beginMigration() -> Bool {
        guard canBeginMigration else { return false }
        migrationInProgress = true
        return true
    }

    func finishMigration() { migrationInProgress = false }

    @discardableResult func beginUpdateRequest() -> Bool {
        guard canRequestUpdate else { return false }
        // Close the interval before Sparkle changes its observable session flag.
        updateRequestPending = true
        return true
    }

    func observeUpdateSession(_ active: Bool) {
        updateSessionInProgress = active
        updateRequestPending = false
    }

    func updateRequestDidNotStart() { updateRequestPending = false }

    func installationWillBegin() { installationInProgress = true }

    func updateCycleFinished(failed: Bool) {
        updateRequestPending = false
        // sessionInProgress is observed independently. Sparkle can end its
        // session while its separate installer still owns installation.
        if failed { installationInProgress = false }
    }
}
