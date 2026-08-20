import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class AutoResumeTaskManagerTests: XCTestCase {
    func testLegacySingleTaskMigratesIntoPersistentTaskCollection() throws {
        let suiteName = "AutoResumeTaskManagerMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let target = AutoResumeThreadDescriptor(
            id: "legacy-thread",
            title: "Legacy thread",
            cwd: "/tmp/legacy-project",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        var runtime = AutoResumeRuntimeState.default
        runtime.status = .waiting
        runtime.statusMessage = "legacy waiting"
        AutoResumeStorage.save(
            configuration,
            key: AutoResumeStorage.configurationKey,
            defaults: defaults
        )
        AutoResumeStorage.save(
            runtime,
            key: AutoResumeStorage.runtimeStateKey,
            defaults: defaults
        )

        let manager = makeManager(defaults: defaults)

        XCTAssertEqual(manager.tasks.count, 1)
        XCTAssertEqual(manager.selectedTaskID, manager.tasks[0].id)
        XCTAssertEqual(manager.tasks[0].configuration.target, target)
        XCTAssertTrue(manager.tasks[0].configuration.enabled)
        XCTAssertEqual(manager.tasks[0].runtimeState.status, .waiting)
        XCTAssertEqual(manager.tasks[0].runtimeState.statusMessage, "legacy waiting")

        let persisted = try XCTUnwrap(
            defaults.data(forKey: AutoResumeTaskManager.collectionStorageKey)
        )
        let collection = try JSONDecoder().decode(
            AutoResumeTaskCollection.self,
            from: persisted
        )
        XCTAssertEqual(collection.schemaVersion, 2)
        XCTAssertEqual(collection.tasks.count, 1)
        XCTAssertEqual(collection.tasks[0].configuration.target?.id, target.id)
    }

    func testTaskCreationDeduplicatesThreadsAndDeletionKeepsSelectionValid() throws {
        let suiteName = "AutoResumeTaskManagerCRUDTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = makeManager(defaults: defaults)
        let first = AutoResumeThreadDescriptor(
            id: "thread-a",
            title: "A",
            cwd: "/tmp/project",
            updatedAt: nil
        )
        let second = AutoResumeThreadDescriptor(
            id: "thread-b",
            title: "B",
            cwd: "/tmp/project",
            updatedAt: nil
        )

        let firstResult = manager.createTask(target: first)
        guard case .created(let firstID) = firstResult else {
            return XCTFail("first thread should create a task")
        }
        XCTAssertEqual(manager.tasks.count, 1)
        XCTAssertFalse(manager.tasks[0].configuration.enabled)

        XCTAssertEqual(manager.createTask(target: first), .existing(firstID))
        XCTAssertEqual(manager.tasks.count, 1)

        guard case .created(let secondID) = manager.createTask(target: second) else {
            return XCTFail("second thread should create another task")
        }
        XCTAssertEqual(manager.tasks.count, 2)
        XCTAssertEqual(manager.selectedTaskID, secondID)

        manager.selectTask(id: firstID)
        XCTAssertTrue(manager.deleteTask(id: firstID))
        XCTAssertEqual(manager.tasks.map(\.id), [secondID])
        XCTAssertEqual(manager.selectedTaskID, secondID)
        XCTAssertFalse(manager.deleteTask(id: "missing"))
    }

    func testSchedulerTimerFollowsEnabledTaskPresence() throws {
        let suiteName = "AutoResumeTaskManagerSchedulerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = makeManager(defaults: defaults)
        XCTAssertFalse(schedulerTimerIsInstalled(in: manager))

        manager.start()
        XCTAssertFalse(schedulerTimerIsInstalled(in: manager))

        let target = AutoResumeThreadDescriptor(
            id: "scheduler-thread",
            title: "Scheduler",
            cwd: "/tmp/project",
            updatedAt: nil
        )
        guard case .created(let taskID) = manager.createTask(target: target),
              let task = manager.task(id: taskID) else {
            return XCTFail("scheduler task should be created")
        }
        XCTAssertFalse(schedulerTimerIsInstalled(in: manager))

        task.controller.setEnabled(true)
        XCTAssertTrue(schedulerTimerIsInstalled(in: manager))

        task.controller.setEnabled(false)
        XCTAssertFalse(schedulerTimerIsInstalled(in: manager))
    }

    func testAutoResumeNeedsRunningStateCoversAutomaticTriggersOnly() throws {
        let suiteName = "AutoResumeTaskManagerRunningLeaseTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = makeManager(defaults: defaults)
        XCTAssertFalse(manager.autoResumeNeedsRunningState)

        let target = AutoResumeThreadDescriptor(
            id: "running-state-thread",
            title: "Running state",
            cwd: "/tmp/project",
            updatedAt: nil
        )
        guard case .created(let taskID) = manager.createTask(target: target),
              let task = manager.task(id: taskID) else {
            return XCTFail("running-state task should be created")
        }
        XCTAssertFalse(manager.autoResumeNeedsRunningState)

        task.controller.setEnabled(true)
        XCTAssertTrue(manager.autoResumeNeedsRunningState)

        task.controller.setQuotaRecoveryEnabled(false)
        XCTAssertFalse(manager.autoResumeNeedsRunningState)

        task.controller.setScheduleMode(.interval)
        XCTAssertTrue(manager.autoResumeNeedsRunningState)

        task.controller.setScheduleMode(.off)
        task.controller.setCapacityRecoveryEnabled(true)
        XCTAssertTrue(manager.autoResumeNeedsRunningState)

        task.controller.setCapacityRecoveryEnabled(false)
        XCTAssertFalse(manager.autoResumeNeedsRunningState)

        task.controller.setEnabled(false)
        XCTAssertFalse(manager.autoResumeNeedsRunningState)
    }

    func testCorruptProtectedTaskWithoutAnyTriggerFailsClosed() {
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = AutoResumeThreadDescriptor(
            id: "thread-no-trigger",
            title: "No trigger",
            cwd: "/tmp/project",
            updatedAt: nil
        )
        configuration.scheduleMode = .off
        configuration.capacityRecoveryEnabled = false
        configuration.quotaRecoveryEnabled = false

        let normalized = AutoResumeTaskDefinition(
            id: "task-no-trigger",
            configuration: configuration
        ).normalized

        XCTAssertFalse(normalized.configuration.enabled)
        XCTAssertFalse(normalized.configuration.hasAutomaticTrigger)
    }

    private func makeManager(defaults: UserDefaults) -> AutoResumeTaskManager {
        AutoResumeTaskManager(
            quotaStore: AccountQuotaStore(
                quotaReader: AutoResumeTaskManagerQuotaReader(),
                userDefaults: defaults,
                observesUserDefaults: false
            ),
            defaults: defaults,
            dataSourceProvider: { nil },
            notifier: AutoResumeTaskManagerNotifier(),
            codexBinaryProvider: { "/fake/codex" }
        )
    }

    private func schedulerTimerIsInstalled(in manager: AutoResumeTaskManager) -> Bool {
        guard let timer = Mirror(reflecting: manager).children
            .first(where: { $0.label == "schedulerTimer" }) else {
            return false
        }
        return Mirror(reflecting: timer.value).children.first != nil
    }
}

private struct AutoResumeTaskManagerQuotaReader: QuotaReading {
    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        .success(.empty)
    }
}

@MainActor
private struct AutoResumeTaskManagerNotifier: AutoResumeNotifying {
    func post(title: String, body: String) {}
}
