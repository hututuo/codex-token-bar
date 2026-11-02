import AppKit
import Sparkle
import XCTest
@testable import CodexTokenBar

@MainActor
final class ApplicationRecoveryOperationGateTests: XCTestCase {
    private actor Attempts {
        enum Interrupted: Error { case fixture }
        private(set) var count = 0
        func run() throws { count += 1; throw Interrupted.fixture }
    }

    func testManualRequestBlocksRetryBeforeSessionObservation() {
        let gate = ApplicationRecoveryOperationGate()
        XCTAssertTrue(gate.beginUpdateRequest())
        XCTAssertFalse(gate.beginMigration())
        XCTAssertFalse(gate.beginUpdateRequest())
        gate.observeUpdateSession(true)
        XCTAssertFalse(gate.beginMigration())
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: false)
        XCTAssertTrue(gate.beginMigration())
        XCTAssertFalse(gate.beginUpdateRequest())
        gate.finishMigration()
        XCTAssertTrue(gate.beginUpdateRequest())
    }

    func testAutomaticSessionBlocksRetryAndCancellationRestoresIt() {
        let gate = ApplicationRecoveryOperationGate()
        gate.observeUpdateSession(true)
        XCTAssertFalse(gate.canBeginMigration)
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: true)
        XCTAssertTrue(gate.canBeginMigration)
        XCTAssertTrue(gate.canRequestUpdate)
    }

    func testInstallerOwnershipOutlivesSuccessfulSessionCompletion() {
        let gate = ApplicationRecoveryOperationGate()
        XCTAssertTrue(gate.beginUpdateRequest())
        gate.observeUpdateSession(true)
        gate.installationWillBegin()
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: false)
        XCTAssertFalse(gate.canBeginMigration)
        XCTAssertFalse(gate.canRequestUpdate)
        gate.finishMigration()
        XCTAssertFalse(gate.canBeginMigration, "An unrelated completion cannot release installer ownership")
        gate.updateCycleFinished(failed: true)
        XCTAssertTrue(gate.canBeginMigration, "A failed/cancelled installer permits recovery again")
    }

    func testRefusedCheckDoesNotLeaveAnUnfinishablePendingRequest() {
        let gate = ApplicationRecoveryOperationGate()
        XCTAssertTrue(gate.beginUpdateRequest())
        gate.updateRequestDidNotStart()
        XCTAssertTrue(gate.canBeginMigration)
    }

    func testInstallerFocusRequiresOwnedObservedAndLiveInteractiveSession() {
        let gate = ApplicationRecoveryOperationGate()
        var focused = 0
        func focus(_ live: Bool = true, _ interactive: Bool = true) -> Bool {
            gate.focusInstallationSession(updaterSessionInProgress: live,
                canCheckForUpdates: interactive) { focused += 1 }
        }
        XCTAssertFalse(focus(), "An idle updater cannot start an installer through the focus action")
        gate.observeUpdateSession(true)
        XCTAssertFalse(focus(), "An automatic check has not handed ownership to an installer")
        gate.installationWillBegin()
        XCTAssertFalse(focus(false, true), "A stale observed session cannot revive an ended live session")
        XCTAssertFalse(focus(true, false), "Sparkle must permit interaction with the existing session")
        gate.observeUpdateSession(false)
        XCTAssertFalse(focus(), "A stale presentation cannot outlive the session observation")
        XCTAssertEqual(focused, 0)

        let migrating = ApplicationRecoveryOperationGate()
        XCTAssertTrue(migrating.beginMigration())
        migrating.observeUpdateSession(true)
        migrating.installationWillBegin()
        XCTAssertFalse(migrating.focusInstallationSession(updaterSessionInProgress: true,
            canCheckForUpdates: true) { XCTFail("A conflicting callback cannot bypass migration ownership") })
    }

    func testInstallerFocusCannotStartAnotherCheckOrReleaseMigrationOwnership() {
        let gate = ApplicationRecoveryOperationGate()
        XCTAssertTrue(gate.beginUpdateRequest())
        gate.observeUpdateSession(true)
        gate.installationWillBegin()
        var focused = 0
        // Recreating a presentation after closing a window uses the same
        // gate. The only permitted operation is presenting that same session.
        for _ in 0..<2 {
            XCTAssertTrue(gate.focusInstallationSession(updaterSessionInProgress: true,
                canCheckForUpdates: true) {
                focused += 1
                XCTAssertFalse(gate.beginMigration())
                XCTAssertFalse(gate.beginUpdateRequest())
            })
        }
        XCTAssertEqual(focused, 2)
        XCTAssertFalse(gate.updateRequestPending)
        XCTAssertTrue(gate.updateSessionInProgress)
        XCTAssertTrue(gate.installationInProgress)
        XCTAssertFalse(gate.canBeginMigration)
    }

    func testInstallerCompletionOrderingNeverAdmitsEarlyMigration() {
        for failed in [false, true] {
            for sessionEndsFirst in [false, true] {
                let gate = ApplicationRecoveryOperationGate()
                gate.observeUpdateSession(true)
                gate.installationWillBegin()
                if sessionEndsFirst { gate.observeUpdateSession(false) }
                else { gate.updateCycleFinished(failed: failed) }
                XCTAssertFalse(gate.canBeginMigration, "The other half of completion still owns recovery")
                if sessionEndsFirst { gate.updateCycleFinished(failed: failed) }
                else { gate.observeUpdateSession(false) }
                XCTAssertFalse(gate.focusInstallationSession(updaterSessionInProgress: false,
                    canCheckForUpdates: true) { XCTFail("An ended session cannot be focused") })
                XCTAssertEqual(gate.canBeginMigration, failed)
                XCTAssertEqual(gate.canRequestUpdate, failed)
                XCTAssertEqual(gate.installationInProgress, !failed,
                    "Successful installer handoff remains owned until this process exits")
            }
        }
    }

    func testPinnedSparkleDriverRefocusesDeferredTerminationAfterWindowClose() throws {
        // Exercise the real pinned standard user driver, not a fake updater
        // or a real installation. Its documented 'application not terminated'
        // callback stores a retry handler and closes its prior status window.
        let application = NSApplication.shared
        let identifier = "TokenBar.UpdaterContinuation.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let bundleURL = root.appendingPathComponent("Fixture.bundle")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        let info: [String: String] = ["CFBundleIdentifier": identifier, "CFBundleName": "Isolated updater fixture",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let previousWindows = Set(application.windows.map(ObjectIdentifier.init))
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        defer { driver.dismissUpdateInstallation() }
        let focus = try XCTUnwrap(driver.showUpdateInFocus)
        let gate = ApplicationRecoveryOperationGate()
        gate.observeUpdateSession(true)
        gate.installationWillBegin()
        var terminationRequests = 0
        driver.showInstallingUpdate(withApplicationTerminated: false) { terminationRequests += 1 }

        func findRetryButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.accessibilityIdentifier() == "SUStatusInstallAndRelaunch" { return button }
            return view.subviews.lazy.compactMap(findRetryButton).first
        }
        func continuationWindow() -> NSWindow? {
            application.windows.first { window in
                !previousWindows.contains(ObjectIdentifier(window))
                    && window.contentView.flatMap(findRetryButton) != nil
            }
        }
        XCTAssertTrue(gate.focusInstallationSession(updaterSessionInProgress: true,
            canCheckForUpdates: true, focus: focus))
        let firstWindow = try XCTUnwrap(continuationWindow())
        XCTAssertTrue(firstWindow.isVisible)
        let firstButton = try XCTUnwrap(firstWindow.contentView.flatMap(findRetryButton))
        firstButton.performClick(nil)
        XCTAssertEqual(terminationRequests, 1)
        XCTAssertFalse(gate.canBeginMigration)
        XCTAssertFalse(gate.canRequestUpdate)

        // The controlled handler deliberately leaves the host running, as a
        // delayed/refused quit does. Closing and reopening must retain it.
        firstWindow.close()
        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertTrue(gate.focusInstallationSession(updaterSessionInProgress: true,
            canCheckForUpdates: true, focus: focus))
        let reopened = try XCTUnwrap(continuationWindow())
        XCTAssertTrue(reopened.isVisible)
        try XCTUnwrap(reopened.contentView.flatMap(findRetryButton)).performClick(nil)
        XCTAssertEqual(terminationRequests, 2)
        XCTAssertTrue(gate.installationInProgress)
        XCTAssertFalse(gate.canBeginMigration)

        // Match pinned Sparkle's actual error-completion order. A successful
        // handoff is covered separately and never clears installer ownership.
        gate.observeUpdateSession(false)
        XCTAssertFalse(gate.canBeginMigration)
        gate.updateCycleFinished(failed: true)
        driver.dismissUpdateInstallation()
        XCTAssertTrue(gate.canBeginMigration)
        XCTAssertFalse(gate.focusInstallationSession(updaterSessionInProgress: false,
            canCheckForUpdates: true, focus: focus))
    }

    func testInitialBusyUpdateResumesRequestedPreparationAfterCancellation() async {
        let gate = ApplicationRecoveryOperationGate()
        gate.observeUpdateSession(true)
        let attempts = Attempts()
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { XCTFail("Failed preparation activated business owners"); return nil },
            productionLifecycle: false, operationGate: gate)
        startup.start()
        XCTAssertEqual(startup.phase, .waiting)
        XCTAssertTrue(startup.waitingForSoftwareUpdate)
        let waitingCount = await attempts.count
        XCTAssertEqual(waitingCount, 0)
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: true)
        for _ in 0..<200 {
            if case .failed = startup.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed = startup.phase else { return XCTFail("Initial preparation never resumed") }
        XCTAssertFalse(startup.waitingForSoftwareUpdate)
        let finalCount = await attempts.count
        XCTAssertEqual(finalCount, 1)
    }

    func testObservingAnUpdateDoesNotStartAnUnrequestedCoordinator() async {
        let gate = ApplicationRecoveryOperationGate()
        let attempts = Attempts()
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { nil }, productionLifecycle: false, operationGate: gate)
        gate.observeUpdateSession(true)
        gate.observeUpdateSession(false)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(startup.phase, .waiting)
        let count = await attempts.count
        XCTAssertEqual(count, 0)
    }

    func testRetryCannotEscapeUpdateOwnershipThroughCoordinator() async {
        let gate = ApplicationRecoveryOperationGate()
        let attempts = Attempts()
        let startup = ApplicationStartupCoordinator(prepare: { _ in try await attempts.run() },
            activate: { XCTFail("Failed preparation activated business owners"); return nil },
            productionLifecycle: false, operationGate: gate)
        startup.start()
        for _ in 0..<200 {
            if case .failed = startup.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed = startup.phase else { return XCTFail("Fixture preparation did not fail") }
        XCTAssertFalse(gate.migrationInProgress)
        XCTAssertTrue(gate.beginUpdateRequest())
        startup.retry()
        guard case .failed = startup.phase else { return XCTFail("Blocked retry did not retain the failed screen") }
        let blockedCount = await attempts.count
        XCTAssertEqual(blockedCount, 1, "A pending update must not start a second database operation")
        XCTAssertFalse(gate.migrationInProgress)
        gate.observeUpdateSession(true)
        startup.retry()
        guard case .failed = startup.phase else { return XCTFail("Active update session admitted migration") }
        gate.observeUpdateSession(false)
        gate.updateCycleFinished(failed: true)
        startup.retry()
        XCTAssertEqual(startup.phase, .preparing)
        XCTAssertTrue(gate.migrationInProgress)
        for _ in 0..<200 {
            if case .failed = startup.phase { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(gate.migrationInProgress)
        let resumedCount = await attempts.count
        XCTAssertEqual(resumedCount, 2)
    }
}
