import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class AutoResumeControllerTests: XCTestCase {
    func testManualRunBypassesLocalCooldownAndDailyLimitButStillUsesSharedCoordination() async throws {
        let suiteName = "AutoResumeControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let target = AutoResumeThreadDescriptor(
            id: "manual-bypass-thread",
            title: "Manual bypass",
            cwd: codexHome.path,
            updatedAt: nil
        )
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = false
        configuration.target = target
        configuration.cooldownMinutes = 24 * 60
        configuration.maxRunsPerDay = 1
        let now = Date()
        var runtime = AutoResumeRuntimeState.default
        runtime.lastRunAt = now
        runtime.runHistory = [now]
        runtime.schedulePendingFreshness = AutoResumePendingFreshness(
            threadID: target.id,
            armedAt: now.addingTimeInterval(-60),
            baseline: AutoResumeThreadFreshness(
                updatedAt: now.addingTimeInterval(-60),
                lastTurnID: "old-turn"
            )
        )
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: "CodexTokenBar.autoResume.configuration.v1"
        )
        defaults.set(
            try JSONEncoder().encode(runtime),
            forKey: "CodexTokenBar.autoResume.runtimeState.v1"
        )

        let appServer = RecordingAutoResumeAppServer()
        let notifier = RecordingAutoResumeNotifier()
        let quotaStore = AccountQuotaStore(
            quotaReader: EmptyAutoResumeQuotaReader(),
            userDefaults: defaults,
            observesUserDefaults: false
        )
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let sharedCoordinator = AutoResumeSharedCoordinator(
            codexHome: codexHome,
            ownerID: "other-runtime"
        )
        XCTAssertEqual(try sharedCoordinator.claimTrigger(
            key: "interval:other-thread:already-counted",
            threadID: "other-thread",
            minimumInterval: 0,
            dailyLimit: AutoResumeSharedDailyLimit(
                dayStart: Calendar.current.startOfDay(for: now),
                maxRunsPerDay: 1
            ),
            now: now.addingTimeInterval(-60)
        ), .claimed)
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-controller-tests",
            dataSourceProvider: { source },
            notifier: notifier,
            codexBinaryProvider: { "/fake/codex" }
        )

        controller.runNow()
        await waitUntil("manual auto-resume result") {
            controller.runtimeState.status == .succeeded
        }

        XCTAssertEqual(appServer.resumeCount, 1)
        XCTAssertEqual(appServer.lastTargetID, target.id)
        XCTAssertEqual(appServer.lastPrompt, "继续")
        XCTAssertTrue(appServer.lastClientMessageID?.hasPrefix("manual:\(target.id):") == true)
        XCTAssertNil(appServer.lastExpectedFreshness, "Run Now must bypass pending freshness checks")
        XCTAssertFalse(appServer.lastHadStartAuthorization, "Run Now must bypass generation guards")
        XCTAssertEqual(controller.runtimeState.status, .succeeded)
        XCTAssertEqual(controller.runtimeState.runHistory.count, 1, "manual must not consume an automatic daily run")
        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertEqual(notifier.notifications.first?.title, "Codex 自动续跑完成")

        let coordinationRoot = codexHome
            .appendingPathComponent(".codex-token-bar-auto-resume", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: coordinationRoot.appendingPathComponent("trigger-ledger.json").path
        ))
        let manualLedger = try JSONDecoder().decode(
            AutoResumeTriggerLedgerFile.self,
            from: Data(contentsOf: coordinationRoot.appendingPathComponent("trigger-ledger.json"))
        )
        XCTAssertEqual(manualLedger.entries.count, 2, "Run Now must bypass the shared daily limit")
    }

    func testAutomaticScheduleTreatsManualThreadProgressAsSatisfiedWithoutCountingRun() async throws {
        let suiteName = "AutoResumeControllerProgressTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeControllerProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let target = AutoResumeThreadDescriptor(
            id: "automatic-progress-thread",
            title: "Automatic progress",
            cwd: codexHome.path,
            updatedAt: nil
        )
        let now = Date()
        let baseline = AutoResumeThreadFreshness(
            updatedAt: now.addingTimeInterval(-20 * 60),
            lastTurnID: "old-turn"
        )
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        configuration.scheduleMode = .interval
        configuration.intervalMinutes = 15
        var runtime = AutoResumeRuntimeState.default
        runtime.enabledAt = now.addingTimeInterval(-16 * 60)
        runtime.schedulePendingFreshness = AutoResumePendingFreshness(
            threadID: target.id,
            armedAt: now.addingTimeInterval(-16 * 60),
            baseline: baseline
        )
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: "CodexTokenBar.autoResume.configuration.v1"
        )
        defaults.set(
            try JSONEncoder().encode(runtime),
            forKey: "CodexTokenBar.autoResume.runtimeState.v1"
        )

        let appServer = RecordingAutoResumeAppServer(progressedWhenExpectedFreshness: true)
        let quotaStore = AccountQuotaStore(
            quotaReader: EmptyAutoResumeQuotaReader(),
            userDefaults: defaults,
            observesUserDefaults: false
        )
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-progress-tests",
            dataSourceProvider: { source },
            notifier: RecordingAutoResumeNotifier(),
            codexBinaryProvider: { "/fake/codex" }
        )

        controller.start()
        await waitUntil("automatic progress satisfaction") {
            appServer.resumeCount == 1 && !controller.isRunning
        }

        XCTAssertEqual(appServer.lastExpectedFreshness, baseline)
        XCTAssertTrue(controller.runtimeState.runHistory.isEmpty)
        XCTAssertNil(controller.runtimeState.lastRunAt)
        XCTAssertEqual(controller.runtimeState.lastTriggerKind, .interval)

        let ledgerURL = codexHome
            .appendingPathComponent(".codex-token-bar-auto-resume", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("trigger-ledger.json")
        let ledger = try JSONDecoder().decode(
            AutoResumeTriggerLedgerFile.self,
            from: Data(contentsOf: ledgerURL)
        )
        XCTAssertEqual(ledger.entries.values.first?.outcome, "satisfied")
        XCTAssertTrue(ledger.entries.values.first?.message?.contains("已有新进展") == true)
    }

    func testSharedDailyLimitDoesNotClaimClearPendingOrIncreaseLocalRuns() async throws {
        let suiteName = "AutoResumeControllerDailyLimitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeControllerDailyLimitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let target = AutoResumeThreadDescriptor(
            id: "daily-limit-target",
            title: "Daily limit target",
            cwd: codexHome.path,
            updatedAt: nil
        )
        let now = Date()
        let pending = AutoResumePendingFreshness(
            threadID: target.id,
            armedAt: now.addingTimeInterval(-16 * 60),
            baseline: AutoResumeThreadFreshness(
                updatedAt: now.addingTimeInterval(-16 * 60),
                lastTurnID: "old-turn"
            )
        )
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        configuration.scheduleMode = .interval
        configuration.intervalMinutes = 15
        configuration.maxRunsPerDay = 1
        var runtime = AutoResumeRuntimeState.default
        runtime.enabledAt = now.addingTimeInterval(-16 * 60)
        runtime.schedulePendingFreshness = pending
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: "CodexTokenBar.autoResume.configuration.v1"
        )
        defaults.set(
            try JSONEncoder().encode(runtime),
            forKey: "CodexTokenBar.autoResume.runtimeState.v1"
        )

        let coordinator = AutoResumeSharedCoordinator(codexHome: codexHome, ownerID: "tauri")
        XCTAssertEqual(try coordinator.claimTrigger(
            key: "interval:other-thread:today",
            threadID: "other-thread",
            minimumInterval: 0,
            dailyLimit: AutoResumeSharedDailyLimit(
                dayStart: Calendar.current.startOfDay(for: now),
                maxRunsPerDay: 1
            ),
            now: now.addingTimeInterval(-60)
        ), .claimed)

        let appServer = RecordingAutoResumeAppServer()
        let quotaStore = AccountQuotaStore(
            quotaReader: EmptyAutoResumeQuotaReader(),
            userDefaults: defaults,
            observesUserDefaults: false
        )
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-daily-limit-tests",
            dataSourceProvider: { source },
            notifier: RecordingAutoResumeNotifier(),
            codexBinaryProvider: { "/fake/codex" }
        )

        controller.start()
        await waitUntil("shared daily limit") {
            controller.runtimeState.sharedDailyLimitUntil != nil && !controller.isRunning
        }

        XCTAssertEqual(appServer.resumeCount, 0)
        XCTAssertTrue(controller.runtimeState.runHistory.isEmpty)
        XCTAssertNil(controller.runtimeState.lastRunAt)
        XCTAssertEqual(controller.runtimeState.schedulePendingFreshness, pending)
        XCTAssertTrue(controller.runtimeState.statusMessage.contains("明天自动恢复"))

        let ledgerURL = codexHome
            .appendingPathComponent(".codex-token-bar-auto-resume", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("trigger-ledger.json")
        let ledger = try JSONDecoder().decode(
            AutoResumeTriggerLedgerFile.self,
            from: Data(contentsOf: ledgerURL)
        )
        XCTAssertEqual(ledger.entries.count, 1, "daily-limit rejection must not write a claim")
    }

    func testInvalidatedAutomaticStartCompletesLedgerAsSkippedWithoutCountingRun() async throws {
        let suiteName = "AutoResumeControllerGenerationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeControllerGenerationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let target = AutoResumeThreadDescriptor(
            id: "generation-target",
            title: "Generation target",
            cwd: codexHome.path,
            updatedAt: nil
        )
        let now = Date()
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        configuration.scheduleMode = .interval
        configuration.intervalMinutes = 15
        var runtime = AutoResumeRuntimeState.default
        runtime.enabledAt = now.addingTimeInterval(-16 * 60)
        runtime.schedulePendingFreshness = AutoResumePendingFreshness(
            threadID: target.id,
            armedAt: now.addingTimeInterval(-16 * 60),
            baseline: AutoResumeThreadFreshness(
                updatedAt: now.addingTimeInterval(-16 * 60),
                lastTurnID: "old-turn"
            )
        )
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: "CodexTokenBar.autoResume.configuration.v1"
        )
        defaults.set(
            try JSONEncoder().encode(runtime),
            forKey: "CodexTokenBar.autoResume.runtimeState.v1"
        )

        let appServer = RecordingAutoResumeAppServer(invalidatedWhenAuthorized: true)
        let quotaStore = AccountQuotaStore(
            quotaReader: EmptyAutoResumeQuotaReader(),
            userDefaults: defaults,
            observesUserDefaults: false
        )
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-generation-tests",
            dataSourceProvider: { source },
            notifier: RecordingAutoResumeNotifier(),
            codexBinaryProvider: { "/fake/codex" }
        )

        controller.start()
        await waitUntil("generation invalidation") {
            appServer.resumeCount == 1 && !controller.isRunning
        }

        XCTAssertTrue(appServer.lastHadStartAuthorization)
        XCTAssertTrue(controller.runtimeState.runHistory.isEmpty)
        XCTAssertNil(controller.runtimeState.lastRunAt)

        let ledgerURL = codexHome
            .appendingPathComponent(".codex-token-bar-auto-resume", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("trigger-ledger.json")
        let ledger = try JSONDecoder().decode(
            AutoResumeTriggerLedgerFile.self,
            from: Data(contentsOf: ledgerURL)
        )
        XCTAssertEqual(ledger.entries.values.first?.outcome, "skipped")
    }

    func testCapacityFailureSendsExactlyOneContinueForTheObservedTurn() async throws {
        let suiteName = "AutoResumeControllerCapacityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeControllerCapacityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let target = AutoResumeThreadDescriptor(
            id: "capacity-target",
            title: "Capacity target",
            cwd: codexHome.path,
            updatedAt: nil
        )
        let now = Date()
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        configuration.capacityRecoveryEnabled = true
        configuration.quotaRecoveryEnabled = false
        configuration.scheduleMode = .off
        configuration.prompt = "执行另一条定时指令"
        configuration.cooldownMinutes = 1
        var runtime = AutoResumeRuntimeState.default
        runtime.enabledAt = now.addingTimeInterval(-60)
        runtime.capacityMonitorArmedAt = now.addingTimeInterval(-60)
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: "CodexTokenBar.autoResume.configuration.v1"
        )
        defaults.set(
            try JSONEncoder().encode(runtime),
            forKey: "CodexTokenBar.autoResume.runtimeState.v1"
        )

        let observation = AutoResumeLatestTurnObservation(
            turnID: "failed-capacity-turn",
            status: "failed",
            completedAt: now.addingTimeInterval(-5),
            errorMessage: "Selected model is at capacity. Please try a different model.",
            codexErrorCode: "serverOverloaded",
            clientUserMessageID: "desktop-user-message"
        )
        let appServer = RecordingAutoResumeAppServer(latestTurnObservation: observation)
        let quotaStore = AccountQuotaStore(
            quotaReader: EmptyAutoResumeQuotaReader(),
            userDefaults: defaults,
            observesUserDefaults: false
        )
        let source = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-capacity-tests",
            dataSourceProvider: { source },
            notifier: RecordingAutoResumeNotifier(),
            codexBinaryProvider: { "/fake/codex" }
        )

        controller.start()
        await waitUntil("capacity auto-resume") {
            appServer.resumeCount == 1 && !controller.isRunning
        }

        XCTAssertEqual(appServer.lastPrompt, "继续")
        XCTAssertEqual(
            appServer.lastClientMessageID,
            "capacity:\(target.id):failed-capacity-turn"
        )
        XCTAssertEqual(appServer.lastExpectedFreshness, observation.freshness)
        XCTAssertTrue(appServer.lastHadStartAuthorization)
        XCTAssertEqual(controller.runtimeState.lastTriggerKind, .capacityRecovery)
        XCTAssertEqual(controller.runtimeState.lastCapacityObservedTurnID, observation.turnID)

        controller.setNotifyOnResult(false)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(appServer.resumeCount, 1, "the same failed turn must never send twice")
    }

    func testCapacityRecoveryDoesNotLoopWhenItsOwnContinueAlsoOverloads() async throws {
        let suiteName = "AutoResumeControllerCapacityLoopTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeControllerCapacityLoopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let target = AutoResumeThreadDescriptor(
            id: "capacity-loop-target",
            title: "Capacity loop target",
            cwd: codexHome.path,
            updatedAt: nil
        )
        let now = Date()
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        configuration.capacityRecoveryEnabled = true
        configuration.quotaRecoveryEnabled = false
        var runtime = AutoResumeRuntimeState.default
        runtime.enabledAt = now.addingTimeInterval(-60)
        runtime.capacityMonitorArmedAt = now.addingTimeInterval(-60)
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: "CodexTokenBar.autoResume.configuration.v1"
        )
        defaults.set(
            try JSONEncoder().encode(runtime),
            forKey: "CodexTokenBar.autoResume.runtimeState.v1"
        )
        let ownFailure = AutoResumeLatestTurnObservation(
            turnID: "own-failed-turn",
            status: "failed",
            completedAt: now.addingTimeInterval(-5),
            errorMessage: "Selected model is at capacity. Please try a different model.",
            codexErrorCode: "serverOverloaded",
            clientUserMessageID: "capacity:\(target.id):original-failed-turn"
        )
        let appServer = RecordingAutoResumeAppServer(latestTurnObservation: ownFailure)
        let quotaStore = AccountQuotaStore(
            quotaReader: EmptyAutoResumeQuotaReader(),
            userDefaults: defaults,
            observesUserDefaults: false
        )
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-capacity-loop-tests",
            dataSourceProvider: {
                CodexDataSource(codexHome: codexHome, origin: .userSelected)
            },
            notifier: RecordingAutoResumeNotifier(),
            codexBinaryProvider: { "/fake/codex" }
        )

        controller.start()
        await waitUntil("own capacity failure observation") {
            controller.runtimeState.lastCapacityObservedTurnID == ownFailure.turnID
        }

        XCTAssertEqual(appServer.resumeCount, 0)
        XCTAssertTrue(controller.runtimeState.statusMessage.contains("本次不再重试"))
    }

    func testCapacityFailureBlockedByCooldownRemainsPendingAndUnconsumed() async throws {
        let suiteName = "AutoResumeControllerCapacityCooldownTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoResumeControllerCapacityCooldownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let target = AutoResumeThreadDescriptor(
            id: "capacity-cooldown-target",
            title: "Capacity cooldown target",
            cwd: codexHome.path,
            updatedAt: nil
        )
        let now = Date()
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        configuration.capacityRecoveryEnabled = true
        configuration.quotaRecoveryEnabled = false
        configuration.cooldownMinutes = 1
        var runtime = AutoResumeRuntimeState.default
        runtime.enabledAt = now.addingTimeInterval(-60)
        runtime.capacityMonitorArmedAt = now.addingTimeInterval(-60)
        runtime.lastRunAt = now
        defaults.set(
            try JSONEncoder().encode(configuration),
            forKey: "CodexTokenBar.autoResume.configuration.v1"
        )
        defaults.set(
            try JSONEncoder().encode(runtime),
            forKey: "CodexTokenBar.autoResume.runtimeState.v1"
        )
        let observation = AutoResumeLatestTurnObservation(
            turnID: "cooldown-capacity-turn",
            status: "failed",
            completedAt: now.addingTimeInterval(-5),
            errorMessage: "Selected model is at capacity. Please try a different model.",
            codexErrorCode: "serverOverloaded",
            clientUserMessageID: "desktop-user-message"
        )
        let appServer = RecordingAutoResumeAppServer(latestTurnObservation: observation)
        let quotaStore = AccountQuotaStore(
            quotaReader: EmptyAutoResumeQuotaReader(),
            userDefaults: defaults,
            observesUserDefaults: false
        )
        let controller = AutoResumeController(
            quotaStore: quotaStore,
            appServer: appServer,
            defaults: defaults,
            ownerID: "swift-capacity-cooldown-tests",
            dataSourceProvider: {
                CodexDataSource(codexHome: codexHome, origin: .userSelected)
            },
            notifier: RecordingAutoResumeNotifier(),
            codexBinaryProvider: { "/fake/codex" }
        )

        controller.start()
        await waitUntil("capacity cooldown deferral") {
            controller.runtimeState.capacityPendingFreshness?.baseline?.lastTurnID
                == observation.turnID
                && controller.runtimeState.statusMessage.contains("冷却中")
        }

        XCTAssertEqual(appServer.resumeCount, 0)
        XCTAssertNil(controller.runtimeState.lastCapacityObservedTurnID)
        let persisted = try JSONDecoder().decode(
            AutoResumeRuntimeState.self,
            from: try XCTUnwrap(defaults.data(
                forKey: "CodexTokenBar.autoResume.runtimeState.v1"
            ))
        )
        XCTAssertEqual(
            persisted.capacityPendingFreshness?.baseline?.lastTurnID,
            observation.turnID
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

@MainActor
private final class RecordingAutoResumeNotifier: AutoResumeNotifying {
    struct Notification: Equatable {
        let title: String
        let body: String
    }

    private(set) var notifications: [Notification] = []

    func post(title: String, body: String) {
        notifications.append(Notification(title: title, body: body))
    }
}

private struct EmptyAutoResumeQuotaReader: QuotaReading {
    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        .success(.empty)
    }
}

private final class RecordingAutoResumeAppServer: CodexAutoResumeAppServerServing, @unchecked Sendable {
    private let lock = NSLock()
    private let progressedWhenExpectedFreshness: Bool
    private let invalidatedWhenAuthorized: Bool
    private let latestTurnObservation: AutoResumeLatestTurnObservation?
    private var recordedResumeCount = 0
    private var recordedTargetID: String?
    private var recordedPrompt: String?
    private var recordedClientMessageID: String?
    private var recordedExpectedFreshness: AutoResumeThreadFreshness?
    private var recordedHadStartAuthorization = false

    init(
        progressedWhenExpectedFreshness: Bool = false,
        invalidatedWhenAuthorized: Bool = false,
        latestTurnObservation: AutoResumeLatestTurnObservation? = nil
    ) {
        self.progressedWhenExpectedFreshness = progressedWhenExpectedFreshness
        self.invalidatedWhenAuthorized = invalidatedWhenAuthorized
        self.latestTurnObservation = latestTurnObservation
    }

    var resumeCount: Int { lock.withLock { recordedResumeCount } }
    var lastTargetID: String? { lock.withLock { recordedTargetID } }
    var lastPrompt: String? { lock.withLock { recordedPrompt } }
    var lastClientMessageID: String? { lock.withLock { recordedClientMessageID } }
    var lastExpectedFreshness: AutoResumeThreadFreshness? {
        lock.withLock { recordedExpectedFreshness }
    }
    var lastHadStartAuthorization: Bool { lock.withLock { recordedHadStartAuthorization } }

    func listThreads(
        codexPath: String,
        dataSource: CodexDataSource?
    ) async throws -> [AutoResumeThreadDescriptor] {
        []
    }

    func readThreadFreshness(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws -> AutoResumeThreadFreshness {
        AutoResumeThreadFreshness(updatedAt: Date(), lastTurnID: "fresh-turn")
    }

    func readLatestTurnObservation(
        codexPath: String,
        dataSource: CodexDataSource?,
        threadID: String
    ) async throws -> AutoResumeLatestTurnObservation? {
        latestTurnObservation
    }

    func resumeThread(
        codexPath: String,
        dataSource: CodexDataSource?,
        target: AutoResumeThreadDescriptor,
        prompt: String,
        clientMessageID: String,
        expectedFreshness: AutoResumeThreadFreshness?,
        startAuthorization: AutoResumeStartAuthorization?
    ) async throws -> AutoResumeRunResult {
        lock.withLock {
            recordedResumeCount += 1
            recordedTargetID = target.id
            recordedPrompt = prompt
            recordedClientMessageID = clientMessageID
            recordedExpectedFreshness = expectedFreshness
            recordedHadStartAuthorization = startAuthorization != nil
        }
        if progressedWhenExpectedFreshness, expectedFreshness != nil {
            throw CodexAutoResumeAppServerError.threadProgressed
        }
        if invalidatedWhenAuthorized, startAuthorization != nil {
            throw AutoResumeStartGuardError.invalidated
        }
        return AutoResumeRunResult(
            threadID: target.id,
            turnID: "manual-test-turn",
            status: "completed",
            message: "done"
        )
    }
}
