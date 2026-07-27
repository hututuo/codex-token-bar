import Foundation
import XCTest
@testable import CodexTokenBar

final class AutoResumePolicyTests: XCTestCase {
    private let target = AutoResumeThreadDescriptor(
        id: "thread-policy-tests",
        title: "Policy tests",
        cwd: "/tmp/policy-tests",
        updatedAt: nil
    )

    func testDefaultsKeepAutomaticRunsOffButQuotaRecoveryReadyForOptIn() {
        let configuration = AutoResumeConfiguration.default

        XCTAssertFalse(configuration.enabled)
        XCTAssertFalse(configuration.capacityRecoveryEnabled)
        XCTAssertTrue(configuration.quotaRecoveryEnabled)
        XCTAssertEqual(configuration.quotaWindow, .lowestRemaining)
        XCTAssertEqual(configuration.prompt, "继续")
        XCTAssertEqual(configuration.maxRunsPerDay, 6)
        XCTAssertEqual(configuration.cooldownMinutes, 30)
        XCTAssertTrue(configuration.notifyOnResult)
        XCTAssertEqual(AutoResumeConfiguration.allowedIntervalMinutes, [15, 30, 60, 120, 360, 720])
    }

    func testConfigurationNormalizationMatchesCrossRuntimeVisibleBounds() {
        var configuration = AutoResumeConfiguration.default
        configuration.intervalMinutes = 240
        configuration.cooldownMinutes = 0
        configuration.maxRunsPerDay = 99

        let normalized = configuration.normalized

        XCTAssertEqual(normalized.intervalMinutes, 60)
        XCTAssertEqual(normalized.cooldownMinutes, 1)
        XCTAssertEqual(normalized.maxRunsPerDay, 24)
    }

    func testIntervalFiresOnlyAfterItsAnchorAndAdvancesAfterAcceptance() throws {
        var configuration = enabledConfiguration()
        configuration.scheduleMode = .interval
        configuration.intervalMinutes = 60

        let anchor = date(2026, 7, 16, 10, 0)
        var state = AutoResumeRuntimeState.default
        state.enabledAt = anchor

        XCTAssertNil(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: anchor.addingTimeInterval(59 * 60),
            calendar: utcCalendar
        ))

        let first = try XCTUnwrap(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: anchor.addingTimeInterval(60 * 60),
            calendar: utcCalendar
        ))
        XCTAssertEqual(first.kind, .interval)
        XCTAssertTrue(first.key.hasPrefix("interval:\(target.id):60:"))

        AutoResumePolicy.markTriggerAccepted(first, state: &state)
        XCTAssertEqual(state.lastIntervalFireAt, first.firedAt)
        XCTAssertNil(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: anchor.addingTimeInterval(119 * 60),
            calendar: utcCalendar
        ))
        XCTAssertNotNil(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: anchor.addingTimeInterval(120 * 60),
            calendar: utcCalendar
        ))
    }

    func testDailyFiresAtConfiguredTimeOnlyOncePerCalendarDay() throws {
        var configuration = enabledConfiguration()
        configuration.scheduleMode = .daily
        configuration.dailyHour = 9
        configuration.dailyMinute = 30
        var state = AutoResumeRuntimeState.default

        XCTAssertNil(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: date(2026, 7, 16, 9, 29),
            calendar: utcCalendar
        ))

        let first = try XCTUnwrap(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: date(2026, 7, 16, 9, 30),
            calendar: utcCalendar
        ))
        XCTAssertEqual(first.kind, .daily)
        XCTAssertEqual(first.key, "daily:\(target.id):2026-07-16:0930")

        AutoResumePolicy.markTriggerAccepted(first, state: &state)
        XCTAssertNil(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: date(2026, 7, 16, 23, 59),
            calendar: utcCalendar
        ))

        let nextDay = try XCTUnwrap(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: date(2026, 7, 17, 9, 30),
            calendar: utcCalendar
        ))
        XCTAssertEqual(nextDay.key, "daily:\(target.id):2026-07-17:0930")
    }

    func testDailyDoesNotBackfireImmediatelyWhenEnabledAfterTodaysTime() {
        var configuration = enabledConfiguration()
        configuration.scheduleMode = .daily
        configuration.dailyHour = 9
        configuration.dailyMinute = 30
        var state = AutoResumeRuntimeState.default
        state.enabledAt = date(2026, 7, 16, 10, 0)

        XCTAssertNil(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: date(2026, 7, 16, 10, 1),
            calendar: utcCalendar
        ))
        XCTAssertNotNil(AutoResumePolicy.scheduledTrigger(
            configuration: configuration,
            state: state,
            now: date(2026, 7, 17, 9, 30),
            calendar: utcCalendar
        ))
    }

    func testOlderPersistedConfigurationAndRuntimeDecodeWithNewSafeDefaults() throws {
        let configurationData = try JSONSerialization.data(withJSONObject: [
            "enabled": false,
            "prompt": "继续执行",
            "maxRunsPerDay": 3,
        ])
        let configuration = try JSONDecoder().decode(
            AutoResumeConfiguration.self,
            from: configurationData
        )
        XCTAssertEqual(configuration.prompt, "继续执行")
        XCTAssertEqual(configuration.maxRunsPerDay, 3)
        XCTAssertTrue(configuration.quotaRecoveryEnabled)
        XCTAssertFalse(configuration.capacityRecoveryEnabled)
        XCTAssertEqual(configuration.quotaWindow, .lowestRemaining)
        XCTAssertTrue(configuration.notifyOnResult)

        let runtimeData = try JSONSerialization.data(withJSONObject: [
            "status": "waiting",
            "statusMessage": "旧状态",
            "quotaArmed": true,
        ])
        let runtime = try JSONDecoder().decode(AutoResumeRuntimeState.self, from: runtimeData)
        XCTAssertEqual(runtime.status, .waiting)
        XCTAssertEqual(runtime.statusMessage, "旧状态")
        XCTAssertTrue(runtime.quotaArmed)
        XCTAssertFalse(runtime.quotaRecoveryRequiresTransition)
        XCTAssertNil(runtime.lastQuotaObservedAt)
        XCTAssertNil(runtime.capacityMonitorArmedAt)
        XCTAssertNil(runtime.lastCapacityMonitorObservationKey)
        XCTAssertNil(runtime.lastCapacityObservedTurnID)
        XCTAssertNil(runtime.capacityPendingFreshness)
    }

    func testFirstLowQuotaSampleOnlyEstablishesBaselineAndSecondLowSampleArms() {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .fiveHour
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let reset = date(2026, 7, 16, 15, 0)

        let baselineTrigger = AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 96, fiveHourReset: reset),
            now: date(2026, 7, 16, 10, 0)
        )
        XCTAssertNil(baselineTrigger)
        XCTAssertFalse(state.quotaArmed)
        XCTAssertNil(state.quotaArmedCycleID)
        XCTAssertEqual(state.lastQuotaRemainingPercent, 4)
        XCTAssertEqual(state.lastQuotaCycleID, "5h:\(Int(reset.timeIntervalSince1970))")

        let armedTrigger = AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 97, fiveHourReset: reset),
            now: date(2026, 7, 16, 10, 1)
        )
        XCTAssertNil(armedTrigger)
        XCTAssertTrue(state.quotaArmed)
        XCTAssertEqual(state.quotaArmedCycleID, "5h:\(Int(reset.timeIntervalSince1970))")
    }

    func testQuotaRecoveryFiresOnlyAfterBaselineThenArmingThenHighWatermark() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .fiveHour
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let reset = date(2026, 7, 16, 15, 0)

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 96, fiveHourReset: reset),
            now: date(2026, 7, 16, 10, 0)
        ))
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 97, fiveHourReset: reset),
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertTrue(state.quotaArmed)

        let recovered = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 80, fiveHourReset: reset),
            now: date(2026, 7, 16, 10, 5)
        ))
        XCTAssertEqual(recovered.kind, .quotaRecovery)
        XCTAssertEqual(
            recovered.key,
            "quota:\(target.id):5h:\(Int(reset.timeIntervalSince1970))"
        )
        XCTAssertFalse(state.quotaArmed)
        XCTAssertNil(state.quotaArmedCycleID)
    }

    func testQuotaRecoveryWithoutResetUsesArmedObservationAsRepeatBoundary() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .fiveHour
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let baselineAt = date(2026, 7, 16, 10, 0)
        let armedAt = date(2026, 7, 16, 10, 1)
        let recoveredAt = date(2026, 7, 16, 10, 5)

        func snapshot(usedPercent: Int, updatedAt: Date) -> AccountQuotaSnapshot {
            AccountQuotaSnapshot(
                fiveHour: AccountQuotaWindow(
                    label: "5h",
                    usedPercent: usedPercent,
                    resetsAt: nil
                ),
                sevenDay: nil,
                planType: "pro",
                limitName: "codex",
                accountName: "tests",
                status: "额度已读取",
                updatedAt: updatedAt
            )
        }

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: snapshot(usedPercent: 96, updatedAt: baselineAt),
            now: baselineAt
        ))
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: snapshot(usedPercent: 97, updatedAt: armedAt),
            now: armedAt
        ))
        let recovered = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: snapshot(usedPercent: 80, updatedAt: recoveredAt),
            now: recoveredAt
        ))

        XCTAssertEqual(recovered.key, "quota:\(target.id):5h:unknown")
        XCTAssertEqual(recovered.repeatAfter, armedAt)
        XCTAssertFalse(state.quotaArmed)
    }

    func testQuotaCycleChangeStaysArmedWhileLowAndFiresOnlyAfterRecovery() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .fiveHour
        var state = AutoResumeRuntimeState.default
        let firstReset = date(2026, 7, 16, 15, 0)
        let nextReset = date(2026, 7, 16, 20, 0)

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 96, fiveHourReset: firstReset),
            now: date(2026, 7, 16, 10, 0)
        ))
        XCTAssertFalse(state.quotaArmed)
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 97, fiveHourReset: firstReset),
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertTrue(state.quotaArmed)

        let stillLowAfterReset = AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 97, fiveHourReset: nextReset),
            now: date(2026, 7, 16, 10, 5)
        )
        XCTAssertNil(stillLowAfterReset)
        XCTAssertTrue(state.quotaArmed)

        let resetTrigger = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(fiveHourUsed: 80, fiveHourReset: nextReset),
            now: date(2026, 7, 16, 10, 6)
        ))
        XCTAssertEqual(resetTrigger.kind, .quotaRecovery)
        XCTAssertTrue(resetTrigger.key.hasSuffix(":5h:\(Int(nextReset.timeIntervalSince1970))"))
        XCTAssertFalse(state.quotaArmed)
    }

    func testLowestRemainingRecoveryKeepsTheWindowThatWasActuallyArmedInTriggerKey() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .lowestRemaining
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let fiveHourReset = date(2026, 7, 16, 15, 0)
        let sevenDayReset = date(2026, 7, 23, 10, 0)

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 96,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 40,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 0)
        ))
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 97,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 40,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertTrue(state.quotaArmed)

        let recovered = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 70,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 75,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 5)
        ))

        XCTAssertEqual(recovered.kind, .quotaRecovery)
        XCTAssertTrue(recovered.key.contains(":5h:"))
        XCTAssertFalse(recovered.key.contains(":lowestRemaining:"))
        XCTAssertFalse(recovered.key.contains(":7d:"))
    }

    func testLowestRemainingUsesFiveHourKeyWhenSevenDayArmedBeforeBothWindowsRecover() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .lowestRemaining
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let fiveHourReset = date(2026, 7, 16, 15, 0)
        let sevenDayReset = date(2026, 7, 23, 10, 0)

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 50,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 96,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 0)
        ))
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 50,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 97,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertEqual(state.quotaArmedWindowLabel, "7d")

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 97,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 97,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 2)
        ))
        XCTAssertEqual(Set(state.quotaLowObservedWindowLabels), Set(["5h", "7d"]))

        let recovered = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 70,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 70,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 3)
        ))
        XCTAssertEqual(
            recovered.key,
            "quota:\(target.id):5h:\(Int(fiveHourReset.timeIntervalSince1970))"
        )
    }

    func testLowestRemainingWaitsUntilEveryMeasuredWindowHasRecovered() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .lowestRemaining
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let fiveHourReset = date(2026, 7, 16, 15, 0)
        let sevenDayReset = date(2026, 7, 23, 10, 0)

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 97,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 96,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 0)
        ))
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 97,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 96,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertTrue(state.quotaArmed)

        let onlyFiveHourRecovered = AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 70,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 96,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 5)
        )
        XCTAssertNil(onlyFiveHourRecovered)
        XCTAssertTrue(state.quotaArmed)

        let bothRecovered = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 70,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 75,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 6)
        ))
        XCTAssertEqual(bothRecovered.kind, .quotaRecovery)
        XCTAssertFalse(state.quotaArmed)
    }

    func testLowestRemainingIgnoresANeverLowWindowStuckBelowTheRecoveryThreshold() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .lowestRemaining
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let fiveHourReset = date(2026, 7, 16, 15, 0)
        let sevenDayReset = date(2026, 7, 23, 10, 0)

        // 7d 长期 10% 剩余：高于武装阈值(5)从未低位，但一直低于恢复阈值(20)。
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 20,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 90,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 0)
        ))
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 96,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 90,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertTrue(state.quotaArmed)
        XCTAssertEqual(state.quotaLowObservedWindowLabels, ["5h"])

        // 决策口径：只有曾进入低位的窗口需要达到恢复阈值；从未低位的 7d
        // 不得阻塞 5h 重置后的触发（旧实现在此永不触发，可阻塞数天）。
        let nextReset = date(2026, 7, 16, 20, 0)
        let recovered = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 0,
                fiveHourReset: nextReset,
                sevenDayUsed: 90,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 5)
        ))
        XCTAssertEqual(recovered.kind, .quotaRecovery)
        XCTAssertTrue(recovered.key.contains(":5h:"))
        XCTAssertFalse(state.quotaArmed)
        XCTAssertTrue(state.quotaLowObservedWindowLabels.isEmpty)
    }

    func testLowestRemainingStillWaitsForAWindowThatDippedLowEvenAfterItClimbsAboveArm() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .lowestRemaining
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let fiveHourReset = date(2026, 7, 16, 15, 0)
        let sevenDayReset = date(2026, 7, 23, 10, 0)

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 20,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 50,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 0)
        ))
        // 两个窗口同时进入低位：7d 的低位历史必须被记住。
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 97,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 96,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertTrue(state.quotaArmed)
        XCTAssertEqual(Set(state.quotaLowObservedWindowLabels), Set(["5h", "7d"]))

        // 5h 已重置、7d 爬回 10%（高于武装阈值但仍低于恢复阈值）：曾低位的
        // 7d 仍须达到恢复阈值，不得因"当前不算低位"而放行。
        let nextReset = date(2026, 7, 16, 20, 0)
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 0,
                fiveHourReset: nextReset,
                sevenDayUsed: 90,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 5)
        ))
        XCTAssertTrue(state.quotaArmed)

        let recovered = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: quotaSnapshot(
                fiveHourUsed: 0,
                fiveHourReset: nextReset,
                sevenDayUsed: 75,
                sevenDayReset: sevenDayReset
            ),
            now: date(2026, 7, 16, 10, 6)
        ))
        XCTAssertEqual(recovered.kind, .quotaRecovery)
        XCTAssertTrue(recovered.key.contains(":5h:"))
        XCTAssertFalse(state.quotaArmed)
    }

    func testQuotaLimitArmIgnoresStaleHighAndRequiresFreshRecoveryTransition() throws {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .fiveHour
        configuration.quotaArmAtOrBelowPercent = 5
        configuration.quotaResumeAtOrAbovePercent = 20
        var state = AutoResumeRuntimeState.default
        let reset = date(2026, 7, 16, 15, 0)
        let baselineAt = date(2026, 7, 16, 10, 0)
        var baseline = quotaSnapshot(fiveHourUsed: 20, fiveHourReset: reset)
        baseline.updatedAt = baselineAt

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: baseline,
            now: baselineAt
        ))
        let failureAt = baselineAt.addingTimeInterval(30)
        AutoResumePolicy.armAfterQuotaLimit(
            configuration: configuration,
            state: &state,
            now: failureAt
        )
        XCTAssertTrue(state.quotaArmed)
        XCTAssertTrue(state.quotaRecoveryRequiresTransition)
        XCTAssertEqual(state.quotaRecoveryArmObservationAt, failureAt)

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: baseline,
            now: baselineAt.addingTimeInterval(1)
        ))
        XCTAssertTrue(state.quotaArmed)

        var freshButStillHigh = quotaSnapshot(fiveHourUsed: 19, fiveHourReset: reset)
        freshButStillHigh.updatedAt = baselineAt.addingTimeInterval(60)
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: freshButStillHigh,
            now: baselineAt.addingTimeInterval(60)
        ))
        XCTAssertTrue(state.quotaArmed)

        var confirmedLow = quotaSnapshot(fiveHourUsed: 97, fiveHourReset: reset)
        confirmedLow.updatedAt = baselineAt.addingTimeInterval(120)
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: confirmedLow,
            now: baselineAt.addingTimeInterval(120)
        ))
        XCTAssertTrue(state.quotaRecoveryObservedLow)

        var recovered = quotaSnapshot(fiveHourUsed: 70, fiveHourReset: reset)
        recovered.updatedAt = baselineAt.addingTimeInterval(180)
        let trigger = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: recovered,
            now: baselineAt.addingTimeInterval(180)
        ))
        XCTAssertEqual(trigger.key, "quota:\(target.id):5h:\(Int(reset.timeIntervalSince1970))")
    }

    func testDisabledOrQuotaOffObservationsNeverEstablishBaselineOrArm() {
        let reset = date(2026, 7, 16, 15, 0)
        let low = quotaSnapshot(fiveHourUsed: 99, fiveHourReset: reset)
        var configuration = AutoResumeConfiguration.default
        configuration.target = target
        var state = AutoResumeRuntimeState.default

        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: low,
            now: date(2026, 7, 16, 10, 0)
        ))
        XCTAssertFalse(state.quotaArmed)
        XCTAssertNil(state.lastQuotaCycleID)

        configuration.enabled = true
        configuration.quotaRecoveryEnabled = false
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: low,
            now: date(2026, 7, 16, 10, 1)
        ))
        XCTAssertFalse(state.quotaArmed)
        XCTAssertNil(state.lastQuotaCycleID)
    }

    func testStaleQuotaSnapshotIsIgnoredWithoutChangingArmedState() {
        var configuration = enabledConfiguration()
        configuration.quotaWindow = .fiveHour
        var state = AutoResumeRuntimeState.default
        state.quotaArmed = true
        state.quotaArmedCycleID = "existing-cycle"
        state.lastQuotaRemainingPercent = 4
        state.lastQuotaCycleID = "existing-cycle"
        var stale = quotaSnapshot(
            fiveHourUsed: 0,
            fiveHourReset: date(2026, 7, 16, 20, 0)
        )
        stale.diagnostics = [
            .staleCachedData(source: .accountQuota, rawCause: "offline")
        ]

        let trigger = AutoResumePolicy.observeQuota(
            configuration: configuration,
            state: &state,
            snapshot: stale,
            now: date(2026, 7, 16, 10, 0)
        )

        XCTAssertNil(trigger)
        XCTAssertTrue(state.quotaArmed)
        XCTAssertEqual(state.quotaArmedCycleID, "existing-cycle")
        XCTAssertEqual(state.lastQuotaRemainingPercent, 4)
        XCTAssertEqual(state.lastQuotaCycleID, "existing-cycle")
    }

    func testSafetyPolicyEnforcesCooldownThenDailyRunLimit() {
        var configuration = enabledConfiguration()
        configuration.cooldownMinutes = 30
        configuration.maxRunsPerDay = 2
        let now = date(2026, 7, 16, 12, 0)

        var coolingState = AutoResumeRuntimeState.default
        coolingState.lastRunAt = now.addingTimeInterval(-29 * 60)
        XCTAssertEqual(
            AutoResumePolicy.safetyBlock(
                configuration: configuration,
                state: coolingState,
                now: now,
                calendar: utcCalendar
            ),
            .cooldown(until: now.addingTimeInterval(60))
        )

        var limitedState = AutoResumeRuntimeState.default
        limitedState.lastRunAt = now.addingTimeInterval(-31 * 60)
        limitedState.runHistory = [
            date(2026, 7, 16, 8, 0),
            date(2026, 7, 16, 10, 0),
            date(2026, 7, 15, 23, 59),
        ]
        XCTAssertEqual(
            AutoResumePolicy.safetyBlock(
                configuration: configuration,
                state: limitedState,
                now: now,
                calendar: utcCalendar
            ),
            .dailyLimit
        )

        limitedState.runHistory.removeFirst()
        XCTAssertNil(AutoResumePolicy.safetyBlock(
            configuration: configuration,
            state: limitedState,
            now: now,
            calendar: utcCalendar
        ))

        limitedState.runHistory = []
        limitedState.sharedDailyLimitUntil = date(2026, 7, 17, 0, 0)
        XCTAssertEqual(AutoResumePolicy.safetyBlock(
            configuration: configuration,
            state: limitedState,
            now: now,
            calendar: utcCalendar
        ), .dailyLimit)
        XCTAssertNil(AutoResumePolicy.safetyBlock(
            configuration: configuration,
            state: limitedState,
            now: date(2026, 7, 17, 0, 0),
            calendar: utcCalendar
        ))
    }

    func testThreadFreshnessUsesLastTurnBeforeUpdatedTimestamp() {
        let baseline = AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 100),
            lastTurnID: "turn-1"
        )

        XCTAssertFalse(AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 200),
            lastTurnID: "turn-1"
        ).hasProgressed(since: baseline))
        XCTAssertTrue(AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 200),
            lastTurnID: "turn-2"
        ).hasProgressed(since: baseline))
        XCTAssertTrue(AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 200),
            lastTurnID: nil
        ).hasProgressed(since: AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 100),
            lastTurnID: nil
        )))
    }

    func testCapacityRecoveryOnlyAcceptsFreshExternalServerOverload() throws {
        var configuration = enabledConfiguration()
        configuration.capacityRecoveryEnabled = true
        let now = date(2026, 7, 16, 10, 0)
        var state = AutoResumeRuntimeState.default
        state.capacityMonitorArmedAt = now.addingTimeInterval(-60)
        let overload = AutoResumeLatestTurnObservation(
            turnID: "capacity-turn",
            status: "failed",
            completedAt: now.addingTimeInterval(-10),
            errorMessage: "Selected model is at capacity. Please try a different model.",
            codexErrorCode: "serverOverloaded",
            clientUserMessageID: "desktop-user-message"
        )

        let trigger = try XCTUnwrap(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: state,
            observation: overload,
            now: now
        ))
        XCTAssertEqual(trigger.kind, .capacityRecovery)
        XCTAssertEqual(trigger.key, "capacity:\(target.id):capacity-turn")

        state.lastCapacityObservedTurnID = overload.turnID
        XCTAssertNil(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: state,
            observation: overload,
            now: now
        ))
    }

    func testCapacityRecoveryRejectsQuotaContextInterruptedAndItsOwnRetry() {
        var configuration = enabledConfiguration()
        configuration.capacityRecoveryEnabled = true
        let now = date(2026, 7, 16, 10, 0)
        var state = AutoResumeRuntimeState.default
        state.capacityMonitorArmedAt = now.addingTimeInterval(-60)

        for (status, code, clientID) in [
            ("failed", "usageLimitExceeded", "desktop-user-message"),
            ("failed", "contextWindowExceeded", "desktop-user-message"),
            ("interrupted", "serverOverloaded", "desktop-user-message"),
            ("failed", "serverOverloaded", "capacity:\(target.id):old-turn"),
        ] {
            let observation = AutoResumeLatestTurnObservation(
                turnID: UUID().uuidString,
                status: status,
                completedAt: now.addingTimeInterval(-5),
                errorMessage: "error",
                codexErrorCode: code,
                clientUserMessageID: clientID
            )
            XCTAssertNil(AutoResumePolicy.capacityRecoveryTrigger(
                configuration: configuration,
                state: state,
                observation: observation,
                now: now
            ))
        }
    }

    func testCapacityRecoveryTextFallbackIsStrictAndRecent() {
        var configuration = enabledConfiguration()
        configuration.capacityRecoveryEnabled = true
        let now = date(2026, 7, 16, 10, 0)
        var state = AutoResumeRuntimeState.default
        state.capacityMonitorArmedAt = now.addingTimeInterval(-60)

        let fallback = AutoResumeLatestTurnObservation(
            turnID: "fallback-turn",
            status: "failed",
            completedAt: now.addingTimeInterval(-5),
            errorMessage: "Selected model is at capacity. Please try a different model.",
            codexErrorCode: nil,
            clientUserMessageID: "desktop-user-message"
        )
        XCTAssertNotNil(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: state,
            observation: fallback,
            now: now
        ))

        let generic429 = AutoResumeLatestTurnObservation(
            turnID: "429-turn",
            status: "failed",
            completedAt: now.addingTimeInterval(-5),
            errorMessage: "429 Too Many Requests",
            codexErrorCode: nil,
            clientUserMessageID: "desktop-user-message"
        )
        XCTAssertNil(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: state,
            observation: generic429,
            now: now
        ))

        let old = AutoResumeLatestTurnObservation(
            turnID: "old-turn",
            status: "failed",
            completedAt: now.addingTimeInterval(-10 * 60),
            errorMessage: fallback.errorMessage,
            codexErrorCode: "server_overloaded",
            clientUserMessageID: "desktop-user-message"
        )
        XCTAssertNil(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: state,
            observation: old,
            now: now
        ))
    }

    func testCapacityRecoveryWithoutTimestampsRequiresAnObservedStateTransition() {
        var configuration = enabledConfiguration()
        configuration.capacityRecoveryEnabled = true
        let now = date(2026, 7, 16, 10, 0)
        var state = AutoResumeRuntimeState.default
        state.capacityMonitorArmedAt = now.addingTimeInterval(-60)
        let observation = AutoResumeLatestTurnObservation(
            turnID: "timestamp-less-turn",
            status: "failed",
            completedAt: nil,
            errorMessage: "Selected model is at capacity. Please try a different model.",
            codexErrorCode: "server_overloaded",
            clientUserMessageID: "desktop-user-message"
        )

        XCTAssertNil(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: state,
            observation: observation,
            now: now
        ))

        state.lastCapacityMonitorObservationKey = "timestamp-less-turn|inprogress|none"
        XCTAssertNotNil(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: configuration,
            state: state,
            observation: observation,
            now: now
        ))
    }

    func testTriggerKeysMatchTheCrossRuntimeContract() throws {
        // 与 Tauri 端 cross_runtime_trigger_keys_match_the_swift_contract 互为
        // 镜像：同一触发两端必须产出逐字节相同的 key，共享 ledger 的精确匹配
        // 去重才能生效。任何一端改动 key 格式都必须同步另一端与两份测试。
        let contractTarget = AutoResumeThreadDescriptor(
            id: "thread-1",
            title: "contract",
            cwd: "/tmp/contract",
            updatedAt: nil
        )

        var dailyConfiguration = AutoResumeConfiguration.default
        dailyConfiguration.enabled = true
        dailyConfiguration.target = contractTarget
        dailyConfiguration.scheduleMode = .daily
        dailyConfiguration.dailyHour = 9
        dailyConfiguration.dailyMinute = 5
        let daily = try XCTUnwrap(AutoResumePolicy.scheduledTrigger(
            configuration: dailyConfiguration,
            state: .default,
            now: date(2026, 7, 27, 9, 5),
            calendar: utcCalendar
        ))
        XCTAssertEqual(daily.key, "daily:thread-1:2026-07-27:0905")

        var intervalConfiguration = AutoResumeConfiguration.default
        intervalConfiguration.enabled = true
        intervalConfiguration.target = contractTarget
        intervalConfiguration.scheduleMode = .interval
        intervalConfiguration.intervalMinutes = 30
        var intervalState = AutoResumeRuntimeState.default
        intervalState.lastIntervalFireAt = Date(timeIntervalSince1970: 1_753_600_000 - 1_800)
        let interval = try XCTUnwrap(AutoResumePolicy.scheduledTrigger(
            configuration: intervalConfiguration,
            state: intervalState,
            now: Date(timeIntervalSince1970: 1_753_600_000),
            calendar: utcCalendar
        ))
        XCTAssertEqual(interval.key, "interval:thread-1:30:974222")

        var quotaConfiguration = AutoResumeConfiguration.default
        quotaConfiguration.enabled = true
        quotaConfiguration.target = contractTarget
        quotaConfiguration.quotaWindow = .fiveHour
        quotaConfiguration.quotaArmAtOrBelowPercent = 5
        quotaConfiguration.quotaResumeAtOrAbovePercent = 20
        var quotaState = AutoResumeRuntimeState.default
        let reset = Date(timeIntervalSince1970: 1_753_602_000)
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: quotaConfiguration,
            state: &quotaState,
            snapshot: quotaSnapshot(fiveHourUsed: 96, fiveHourReset: reset),
            now: date(2026, 7, 27, 10, 0)
        ))
        XCTAssertNil(AutoResumePolicy.observeQuota(
            configuration: quotaConfiguration,
            state: &quotaState,
            snapshot: quotaSnapshot(fiveHourUsed: 97, fiveHourReset: reset),
            now: date(2026, 7, 27, 10, 1)
        ))
        let quota = try XCTUnwrap(AutoResumePolicy.observeQuota(
            configuration: quotaConfiguration,
            state: &quotaState,
            snapshot: quotaSnapshot(fiveHourUsed: 80, fiveHourReset: reset),
            now: date(2026, 7, 27, 10, 5)
        ))
        XCTAssertEqual(quota.key, "quota:thread-1:5h:1753602000")

        var capacityConfiguration = AutoResumeConfiguration.default
        capacityConfiguration.enabled = true
        capacityConfiguration.target = contractTarget
        capacityConfiguration.capacityRecoveryEnabled = true
        let capacityNow = date(2026, 7, 27, 10, 0)
        var capacityState = AutoResumeRuntimeState.default
        capacityState.capacityMonitorArmedAt = capacityNow.addingTimeInterval(-60)
        let capacity = try XCTUnwrap(AutoResumePolicy.capacityRecoveryTrigger(
            configuration: capacityConfiguration,
            state: capacityState,
            observation: AutoResumeLatestTurnObservation(
                turnID: "turn-9",
                status: "failed",
                completedAt: capacityNow.addingTimeInterval(-10),
                errorMessage: "Selected model is at capacity. Please try a different model.",
                codexErrorCode: "serverOverloaded",
                clientUserMessageID: "desktop-user-message"
            ),
            now: capacityNow
        ))
        XCTAssertEqual(capacity.key, "capacity:thread-1:turn-9")
    }

    private func enabledConfiguration() -> AutoResumeConfiguration {
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = target
        return configuration
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        utcCalendar.date(from: DateComponents(
            timeZone: utcCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func quotaSnapshot(
        fiveHourUsed: Int,
        fiveHourReset: Date,
        sevenDayUsed: Int = 50,
        sevenDayReset: Date? = nil
    ) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(
                label: "5h",
                usedPercent: fiveHourUsed,
                resetsAt: fiveHourReset
            ),
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: sevenDayUsed,
                resetsAt: sevenDayReset ?? fiveHourReset.addingTimeInterval(7 * 24 * 60 * 60)
            ),
            planType: "pro",
            limitName: "codex",
            accountName: "tests",
            status: "额度已读取",
            updatedAt: date(2026, 7, 16, 10, 0)
        )
    }
}
