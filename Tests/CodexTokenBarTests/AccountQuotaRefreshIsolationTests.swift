import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class AccountQuotaRefreshIsolationTests: XCTestCase {
    func testFoundationTimerSchedulerRegistersQuotaClockInCommonRunLoopMode() {
        var registeredModes: [RunLoop.Mode] = []
        let scheduler = FoundationAccountQuotaTimerScheduler { timer, mode in
            registeredModes.append(mode)
            timer.invalidate()
        }

        let token = scheduler.scheduleRepeatingTimer(interval: 60) {}

        XCTAssertEqual(registeredModes, [.common])
        token.invalidate()
    }

    func testPersistentBackoffStartsFastAndRemainsAtOneMinuteForever() {
        var backoff = PersistentRefreshBackoff()
        let delays = (0..<10).map { _ in
            backoff.recordFailure(maximumDelay: 60)
        }

        XCTAssertEqual(delays, [1, 2, 5, 10, 30, 60, 60, 60, 60, 60])

        backoff.recordSuccess()
        XCTAssertEqual(backoff.recordFailure(maximumDelay: 60), 1)
    }

    func testResetCreditStaleStateDoesNotHideHealthyMainQuota() {
        var snapshot = Self.quotaSnapshot(usedPercent: 34)
        snapshot.diagnostics = [
            .staleCachedData(source: .resetCredit, rawCause: "offline", occurredAt: Date())
        ]

        XCTAssertFalse(snapshot.staleDataDisplayed)
        XCTAssertTrue(snapshot.resetCreditStaleDataDisplayed)

        let items = StatusBarQuotaPresentation.items(for: snapshot)
        XCTAssertEqual(items.map(\.window?.remainingPercent), [66, 56])
    }

    func testQuotaAndResetCreditFailuresAndSuccessesOnlyMutateTheirOwnChannel() async {
        let quotaReader = IsolationQuotaReader(results: [
            .failure(IsolationQuotaError()),
            .success(Self.quotaSnapshot(usedPercent: 34)),
            .failure(IsolationQuotaError()),
        ])
        let resetFailure = Self.resetFailure()
        let resetReader = IsolationResetReader(results: [
            .failure(resetFailure),
            .failure(resetFailure),
            .success(Self.resetSnapshot(count: 2)),
        ])
        let store = AccountQuotaStore(
            quotaReader: quotaReader,
            resetCreditReader: resetReader,
            observesUserDefaults: false
        )

        store.refresh()
        await waitUntil("both channels fail independently") {
            store.snapshot.status.hasPrefix("额度读取失败")
                && store.snapshot.resetCreditStatus.hasPrefix("重置卡读取失败")
        }
        XCTAssertTrue(store.snapshot.diagnostics.contains { $0.source == .accountQuota })
        XCTAssertTrue(store.snapshot.diagnostics.contains { $0.source == .resetCredit })

        store.refresh()
        await waitUntil("quota recovers while reset remains failed") {
            store.snapshot.fiveHour?.usedPercent == 34
                && store.snapshot.status == "额度已更新"
                && store.snapshot.resetCreditStatus.hasPrefix("重置卡读取失败")
        }
        XCTAssertFalse(store.snapshot.diagnostics.contains { $0.source == .accountQuota })
        XCTAssertTrue(store.snapshot.diagnostics.contains { $0.source == .resetCredit })

        store.refresh()
        await waitUntil("reset recovers while quota remains failed") {
            store.snapshot.status.hasPrefix("额度读取失败")
                && store.snapshot.resetCreditsAvailableCount == 2
                && store.snapshot.resetCreditStatus == "重置卡已更新"
        }
        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 34)
        XCTAssertTrue(store.snapshot.diagnostics.contains { $0.source == .accountQuota })
        XCTAssertFalse(store.snapshot.diagnostics.contains { $0.source == .resetCredit })
    }

    func testQuotaFailureDoesNotClearResetCreditResultWhenQuotaHasNeverSucceeded() async {
        let quotaReader = IsolationQuotaReader(results: [.failure(IsolationQuotaError())])
        let resetReader = IsolationResetReader(results: [.success(Self.resetSnapshot(count: 1))])
        let store = AccountQuotaStore(
            quotaReader: quotaReader,
            resetCreditReader: resetReader,
            observesUserDefaults: false
        )

        store.refresh()
        await waitUntil("reset succeeds alongside quota failure") {
            store.snapshot.status.hasPrefix("额度读取失败")
                && store.snapshot.resetCreditsAvailableCount == 1
        }

        XCTAssertEqual(store.snapshot.compactResetCreditSummary, "1 张重置卡")
        XCTAssertTrue(store.snapshot.diagnostics.contains { $0.source == .accountQuota })
        XCTAssertFalse(store.snapshot.diagnostics.contains { $0.source == .resetCredit })
    }

    func testStartedStoreRetriesForeverWithCappedSequenceAndStopCancelsPendingRetry() async {
        let quotaReader = AlwaysFailingIsolationQuotaReader()
        let retryScheduler = ControlledIsolationRetryScheduler()
        let timerScheduler = IsolationTimerScheduler()
        let store = AccountQuotaStore(
            quotaReader: quotaReader,
            timerScheduler: timerScheduler,
            retryScheduler: retryScheduler,
            observesUserDefaults: false
        )

        store.start()
        let expectedDelays: [TimeInterval] = [1, 2, 5, 10, 30, 60, 60]
        for index in expectedDelays.indices {
            await waitUntil("retry delay \(index)") {
                await retryScheduler.delays() == Array(expectedDelays.prefix(index + 1))
            }
            if index < expectedDelays.count - 1 {
                await retryScheduler.resumeNext()
            }
        }

        XCTAssertEqual(timerScheduler.scheduledIntervals, [60])
        let readCountBeforeStop = await quotaReader.readCount()
        store.stop()
        await retryScheduler.resumeNext()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let readCountAfterStop = await quotaReader.readCount()
        XCTAssertEqual(readCountAfterStop, readCountBeforeStop)
    }

    func testAutomaticRefreshIntervalIsAlwaysClampedToOneMinute() {
        let timerScheduler = IsolationTimerScheduler()
        let store = AccountQuotaStore(
            quotaReader: IsolationQuotaReader(results: []),
            automaticRefreshInterval: 600,
            timerScheduler: timerScheduler,
            observesUserDefaults: false
        )

        XCTAssertEqual(store.automaticRefreshInterval, 60)
        store.start()
        XCTAssertEqual(timerScheduler.scheduledIntervals, [60])
        store.setAutomaticRefreshInterval(300)
        XCTAssertEqual(store.automaticRefreshInterval, 60)
        XCTAssertEqual(timerScheduler.scheduledIntervals, [60])
        store.stop()
    }

    private static func quotaSnapshot(usedPercent: Int) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(
                label: "5h",
                usedPercent: usedPercent,
                resetsAt: Date().addingTimeInterval(3_600)
            ),
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: usedPercent + 10,
                resetsAt: Date().addingTimeInterval(86_400)
            ),
            planType: "pro",
            limitName: "codex",
            status: "额度已更新",
            updatedAt: Date()
        )
    }

    private static func resetSnapshot(count: Int) -> AccountQuotaResetCreditSnapshot {
        AccountQuotaResetCreditSnapshot(
            availableCount: count,
            credits: [],
            status: "重置卡已更新",
            updatedAt: Date()
        )
    }

    private static func resetFailure() -> AccountQuotaDiagnostic {
        .resetCreditFailure(
            underlying: AccountQuotaDiagnostic(
                source: .resetCredit,
                category: .networkSendFetch,
                severity: .warning,
                message: "模拟重置卡网络失败",
                rawCause: "offline",
                retryable: true,
                occurredAt: Date()
            )
        )
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private struct IsolationQuotaError: LocalizedError {
    var errorDescription: String? { "模拟额度网络失败" }
}

private actor IsolationQuotaReader: QuotaReading {
    private var results: [Result<AccountQuotaSnapshot, Error>]

    init(results: [Result<AccountQuotaSnapshot, Error>]) {
        self.results = results
    }

    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        guard !results.isEmpty else { return .failure(IsolationQuotaError()) }
        return results.removeFirst()
    }
}

private actor AlwaysFailingIsolationQuotaReader: QuotaReading {
    private var count = 0

    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        count += 1
        return .failure(IsolationQuotaError())
    }

    func readCount() -> Int { count }
}

private actor IsolationResetReader: AccountQuotaResetCreditReading {
    private var results: [Result<AccountQuotaResetCreditSnapshot, AccountQuotaDiagnostic>]

    init(results: [Result<AccountQuotaResetCreditSnapshot, AccountQuotaDiagnostic>]) {
        self.results = results
    }

    func readResetCredits(
        dataSource: CodexDataSource?
    ) async -> Result<AccountQuotaResetCreditSnapshot, AccountQuotaDiagnostic> {
        guard !results.isEmpty else {
            return .failure(
                .resetCreditFailure(
                    underlying: AccountQuotaDiagnostic(
                        source: .resetCredit,
                        category: .unknown,
                        severity: .warning,
                        message: "没有测试结果",
                        retryable: true
                    )
                )
            )
        }
        return results.removeFirst()
    }
}

private actor ControlledIsolationRetryScheduler: AccountQuotaRetryScheduling {
    private var recordedDelays: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func wait(for delay: TimeInterval) async throws {
        recordedDelays.append(delay)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func delays() -> [TimeInterval] { recordedDelays }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

@MainActor
private final class IsolationTimerScheduler: AccountQuotaTimerScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []

    func scheduleRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> any AccountQuotaTimerToken {
        scheduledIntervals.append(interval)
        return IsolationTimerToken()
    }
}

@MainActor
private final class IsolationTimerToken: AccountQuotaTimerToken {
    func invalidate() {}
}
