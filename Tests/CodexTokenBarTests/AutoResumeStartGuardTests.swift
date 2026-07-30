import XCTest
@testable import CodexTokenBar

final class AutoResumeStartGuardTests: XCTestCase {
    func testScheduleAuthorizationInvalidatesAcrossSourceMasterAndTargetGenerations() throws {
        var configuration = enabledConfiguration()
        configuration.scheduleMode = .interval
        let gate = AutoResumeStartGuard(configuration: configuration)
        let original = try XCTUnwrap(gate.authorization(
            for: .interval,
            targetID: "thread-1"
        ))
        XCTAssertTrue(original.isValid)
        XCTAssertNil(gate.authorization(for: .manual, targetID: "thread-1"))

        configuration.scheduleMode = .daily
        gate.update(configuration: configuration)
        XCTAssertFalse(original.isValid)

        configuration.scheduleMode = .interval
        gate.update(configuration: configuration)
        XCTAssertFalse(original.isValid, "switching back must not revive an old trigger")
        let afterSourceSwitch = try XCTUnwrap(gate.authorization(
            for: .interval,
            targetID: "thread-1"
        ))

        configuration.target = AutoResumeThreadDescriptor(
            id: "thread-2",
            title: "Other",
            cwd: "/tmp/other",
            updatedAt: nil
        )
        gate.update(configuration: configuration)
        XCTAssertFalse(afterSourceSwitch.isValid)

        configuration.target = AutoResumeThreadDescriptor(
            id: "thread-1",
            title: "Target",
            cwd: "/tmp/project",
            updatedAt: nil
        )
        gate.update(configuration: configuration)
        let beforeDisable = try XCTUnwrap(gate.authorization(
            for: .interval,
            targetID: "thread-1"
        ))
        configuration.enabled = false
        gate.update(configuration: configuration)
        XCTAssertFalse(beforeDisable.isValid)
    }

    func testQuotaAuthorizationIgnoresScheduleButTracksItsOwnPolicy() throws {
        var configuration = enabledConfiguration()
        configuration.scheduleMode = .interval
        let gate = AutoResumeStartGuard(configuration: configuration)
        let quota = try XCTUnwrap(gate.authorization(
            for: .quotaRecovery,
            targetID: "thread-1"
        ))

        configuration.scheduleMode = .daily
        configuration.dailyHour = 22
        gate.update(configuration: configuration)
        XCTAssertTrue(quota.isValid)

        configuration.quotaWindow = .fiveHour
        configuration.quotaArmAtOrBelowPercent = 3
        configuration.quotaResumeAtOrAbovePercent = 30
        gate.update(configuration: configuration)
        XCTAssertFalse(quota.isValid)

        let updatedQuota = try XCTUnwrap(gate.authorization(
            for: .quotaRecovery,
            targetID: "thread-1"
        ))

        configuration.quotaRecoveryEnabled = false
        gate.update(configuration: configuration)
        XCTAssertFalse(updatedQuota.isValid)
        configuration.quotaRecoveryEnabled = true
        gate.update(configuration: configuration)
        XCTAssertFalse(quota.isValid, "switching quota back on must not revive an old trigger")
    }

    func testSafetyLimitChangesInvalidateEveryAutomaticSource() throws {
        var configuration = enabledConfiguration()
        configuration.scheduleMode = .interval
        configuration.capacityRecoveryEnabled = true
        let gate = AutoResumeStartGuard(configuration: configuration)
        let scheduleBeforeLimit = try XCTUnwrap(gate.authorization(
            for: .interval,
            targetID: "thread-1"
        ))
        let quotaBeforeLimit = try XCTUnwrap(gate.authorization(
            for: .quotaRecovery,
            targetID: "thread-1"
        ))
        let capacityBeforeLimit = try XCTUnwrap(gate.authorization(
            for: .capacityRecovery,
            targetID: "thread-1"
        ))

        configuration.maxRunsPerDay -= 1
        gate.update(configuration: configuration)
        XCTAssertFalse(scheduleBeforeLimit.isValid)
        XCTAssertFalse(quotaBeforeLimit.isValid)
        XCTAssertFalse(capacityBeforeLimit.isValid)

        let scheduleBeforeCooldown = try XCTUnwrap(gate.authorization(
            for: .interval,
            targetID: "thread-1"
        ))
        let quotaBeforeCooldown = try XCTUnwrap(gate.authorization(
            for: .quotaRecovery,
            targetID: "thread-1"
        ))
        let capacityBeforeCooldown = try XCTUnwrap(gate.authorization(
            for: .capacityRecovery,
            targetID: "thread-1"
        ))
        configuration.cooldownMinutes += 1
        gate.update(configuration: configuration)
        XCTAssertFalse(scheduleBeforeCooldown.isValid)
        XCTAssertFalse(quotaBeforeCooldown.isValid)
        XCTAssertFalse(capacityBeforeCooldown.isValid)
    }

    func testCapacityAuthorizationTracksMasterTargetToggleAndPrompt() throws {
        var configuration = enabledConfiguration()
        configuration.capacityRecoveryEnabled = true
        let gate = AutoResumeStartGuard(configuration: configuration)
        let original = try XCTUnwrap(gate.authorization(
            for: .capacityRecovery,
            targetID: "thread-1"
        ))
        XCTAssertTrue(original.isValid)

        configuration.prompt = "继续执行"
        gate.update(configuration: configuration)
        XCTAssertFalse(original.isValid)

        let afterPrompt = try XCTUnwrap(gate.authorization(
            for: .capacityRecovery,
            targetID: "thread-1"
        ))
        configuration.capacityRecoveryEnabled = false
        gate.update(configuration: configuration)
        XCTAssertFalse(afterPrompt.isValid)
        XCTAssertNil(gate.authorization(for: .capacityRecovery, targetID: "thread-1"))
    }

    func testAutoApprovalChangeInvalidatesEveryAutomaticSource() throws {
        var configuration = enabledConfiguration()
        configuration.scheduleMode = .interval
        configuration.capacityRecoveryEnabled = true
        let gate = AutoResumeStartGuard(configuration: configuration)
        let schedule = try XCTUnwrap(gate.authorization(
            for: .interval,
            targetID: "thread-1"
        ))
        let quota = try XCTUnwrap(gate.authorization(
            for: .quotaRecovery,
            targetID: "thread-1"
        ))
        let capacity = try XCTUnwrap(gate.authorization(
            for: .capacityRecovery,
            targetID: "thread-1"
        ))

        configuration.autoApprovalEnabled = true
        gate.update(configuration: configuration)

        XCTAssertFalse(schedule.isValid)
        XCTAssertFalse(quota.isValid)
        XCTAssertFalse(capacity.isValid)
    }

    private func enabledConfiguration() -> AutoResumeConfiguration {
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = AutoResumeThreadDescriptor(
            id: "thread-1",
            title: "Target",
            cwd: "/tmp/project",
            updatedAt: nil
        )
        return configuration
    }
}
