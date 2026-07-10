import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class AccountQuotaStoreTests: XCTestCase {
    func testRefreshFailurePreservesLastSuccessfulQuotaSnapshot() async {
        let successfulSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_800)),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 17, resetsAt: Date(timeIntervalSince1970: 10_800)),
            planType: "pro",
            limitName: "PRO",
            accountName: "测试用户",
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let reader = SequentialQuotaReader(results: [
            .success(successfulSnapshot),
            .failure(QuotaTestError())
        ])
        let store = AccountQuotaStore(quotaReader: reader)

        store.refresh()
        await waitUntil("first quota refresh") {
            store.snapshot.status == "额度已读取"
        }

        XCTAssertEqual(store.snapshot.fiveHour, successfulSnapshot.fiveHour)
        XCTAssertEqual(store.snapshot.sevenDay, successfulSnapshot.sevenDay)

        store.refresh()
        await waitUntil("failed quota refresh") {
            store.snapshot.status.hasPrefix("额度读取失败")
        }

        XCTAssertEqual(store.snapshot.fiveHour, successfulSnapshot.fiveHour)
        XCTAssertEqual(store.snapshot.sevenDay, successfulSnapshot.sevenDay)
        XCTAssertEqual(store.snapshot.accountName, "测试用户")
        XCTAssertTrue(store.snapshot.staleDataDisplayed)
        XCTAssertTrue(store.snapshot.diagnostics.contains { $0.category == .staleCachedData })
        XCTAssertTrue(store.snapshot.diagnostics.contains { $0.category == .unknown })
    }

    func testSuccessfulQuotaWithResetCreditFailurePublishesDiagnosticWithoutClearingQuota() async {
        var snapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 18, resetsAt: Date(timeIntervalSince1970: 1_800)),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 28, resetsAt: Date(timeIntervalSince1970: 10_800)),
            planType: "pro",
            limitName: "codex",
            accountName: "测试用户",
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        snapshot.diagnostics = [
            AccountQuotaDiagnostic.resetCreditFailure(
                underlying: AccountQuotaDiagnostic(
                    source: .resetCredit,
                    category: .authMissing,
                    severity: .warning,
                    message: "未找到登录 token",
                    rawCause: "auth.json missing",
                    retryable: true,
                    occurredAt: Date(timeIntervalSince1970: 1_000)
                ),
                occurredAt: Date(timeIntervalSince1970: 1_001)
            )
        ]
        let reader = SequentialQuotaReader(results: [.success(snapshot)])
        let store = AccountQuotaStore(quotaReader: reader)

        store.refresh()
        await waitUntil("quota refresh with reset-credit diagnostic") {
            store.snapshot.diagnostics.contains { $0.category == .resetCreditFailure }
        }

        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 18)
        XCTAssertEqual(store.snapshot.sevenDay?.usedPercent, 28)
        XCTAssertEqual(store.snapshot.diagnostics.first?.underlyingCategory, .authMissing)
    }

    func testRefreshClampsQuotaRegressionWithinSameResetWindow() async {
        let reset = Date().addingTimeInterval(60 * 60)
        let firstSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 80, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 90, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "测试用户",
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let regressedSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 70, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 88, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "测试用户",
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: 1_100)
        )
        let reader = SequentialQuotaReader(results: [
            .success(firstSnapshot),
            .success(regressedSnapshot)
        ])
        let store = AccountQuotaStore(quotaReader: reader)

        store.refresh()
        await waitUntil("first quota refresh") {
            store.snapshot.fiveHour?.usedPercent == 80
        }

        store.refresh()
        await waitUntil("second quota refresh") {
            store.snapshot.updatedAt == regressedSnapshot.updatedAt
        }

        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 80)
        XCTAssertEqual(store.snapshot.sevenDay?.usedPercent, 90)
    }

    func testAutomaticRefreshSkipsSoonAfterSuccessfulManualRefresh() async {
        let reset = Date().addingTimeInterval(60 * 60)
        let firstSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 40, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "测试用户",
            status: "额度已读取",
            updatedAt: Date()
        )
        let reader = SequentialQuotaReader(results: [
            .success(firstSnapshot),
            .failure(QuotaTestError())
        ])
        let store = AccountQuotaStore(quotaReader: reader)

        store.refresh(force: true)
        await waitUntil("manual quota refresh") {
            store.snapshot.fiveHour?.usedPercent == 20
        }

        store.refresh(force: false)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let readCount = await reader.currentReadCount()
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 20)
        XCTAssertEqual(store.snapshot.status, "额度已读取")
    }

    func testRefreshPassesCurrentCodexHomeToQuotaReader() async throws {
        let codexHome = try makeTemporaryDirectory(named: "QuotaSourceHome")
        let dataSource = CodexDataSource(codexHome: codexHome, origin: .userSelected)
        let snapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_800)),
            sevenDay: nil,
            planType: "pro",
            limitName: "codex",
            accountName: "测试用户",
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let reader = SequentialQuotaReader(results: [.success(snapshot)])
        let store = AccountQuotaStore(quotaReader: reader)

        store.setDataSource(dataSource)
        store.refresh()
        await waitUntil("quota refresh with source") {
            store.snapshot.status == "额度已读取"
        }

        let sources = await reader.requestedSources()
        XCTAssertEqual(sources, [dataSource])
    }

    func testExplicitNilSourceDoesNotReusePreviousCodexHome() async throws {
        let sourceA = CodexDataSource(codexHome: try makeTemporaryDirectory(named: "QuotaPreviousSource"), origin: .userSelected)
        let reader = SequentialQuotaReader(results: [
            .success(quotaSnapshot(usedPercent: 11, accountName: "old")),
            .success(quotaSnapshot(usedPercent: 33, accountName: "default"))
        ])
        let store = AccountQuotaStore(quotaReader: reader)

        store.setDataSource(sourceA)
        store.refresh()
        await waitUntil("old source quota refresh") {
            store.snapshot.fiveHour?.usedPercent == 11
        }

        store.setDataSource(nil)
        store.refresh()
        await waitUntil("default source quota refresh") {
            store.snapshot.fiveHour?.usedPercent == 33
        }

        let sources = await reader.requestedSources()
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0], sourceA)
        XCTAssertNil(sources[1])
    }

    func testSourceBFailureDoesNotRelabelSourceAQuotaAsStale() async throws {
        let sourceA = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "QuotaSourceAForFailure"),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "QuotaSourceBForFailure"),
            origin: .userSelected
        )
        let reader = SequentialQuotaReader(results: [
            .success(quotaSnapshot(usedPercent: 42, accountName: "source-a-account")),
            .failure(QuotaTestError())
        ])
        let store = AccountQuotaStore(quotaReader: reader, observesUserDefaults: false)

        store.setDataSource(sourceA)
        store.refresh()
        await waitUntil("source A quota") {
            store.snapshot.accountName == "source-a-account"
        }

        store.setDataSource(sourceB)

        XCTAssertEqual(store.currentDataSourceIdentity, sourceB.stableIdentityKey)
        XCTAssertFalse(store.snapshot.isAvailable)
        XCTAssertNotEqual(store.snapshot.accountName, "source-a-account")

        store.refresh()
        await waitUntil("source B quota failure") {
            store.snapshot.status.hasPrefix("额度读取失败")
        }

        XCTAssertFalse(store.snapshot.isAvailable)
        XCTAssertNotEqual(store.snapshot.accountName, "source-a-account")
        XCTAssertFalse(store.snapshot.staleDataDisplayed)
        XCTAssertFalse(store.snapshot.diagnostics.contains { $0.category == .staleCachedData })
    }

    func testAutomaticNilFailureDoesNotRetainPreviousExplicitSourceQuota() async throws {
        let sourceA = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "QuotaExplicitToAutomatic"),
            origin: .userSelected
        )
        let reader = SequentialQuotaReader(results: [
            .success(quotaSnapshot(usedPercent: 31, accountName: "explicit-account")),
            .failure(QuotaTestError())
        ])
        let store = AccountQuotaStore(quotaReader: reader, observesUserDefaults: false)

        store.setDataSource(sourceA)
        store.refresh()
        await waitUntil("explicit source quota") {
            store.snapshot.accountName == "explicit-account"
        }

        store.setDataSource(nil)
        XCTAssertNil(store.currentDataSourceIdentity)
        XCTAssertFalse(store.snapshot.isAvailable)

        store.refresh()
        await waitUntil("automatic quota failure") {
            store.snapshot.status.hasPrefix("额度读取失败")
        }

        XCTAssertFalse(store.snapshot.isAvailable)
        XCTAssertNotEqual(store.snapshot.accountName, "explicit-account")
        XCTAssertFalse(store.snapshot.staleDataDisplayed)
    }

    func testInFlightQuotaRefreshFromOldSourceDoesNotOverwriteNewSourceSnapshot() async throws {
        let sourceA = CodexDataSource(codexHome: try makeTemporaryDirectory(named: "QuotaOldSource"), origin: .userSelected)
        let sourceB = CodexDataSource(codexHome: try makeTemporaryDirectory(named: "QuotaNewSource"), origin: .userSelected)
        let reader = SuspendedQuotaReader()
        let store = AccountQuotaStore(quotaReader: reader)

        store.setDataSource(sourceA)
        store.refresh()
        await waitUntil("old quota request") {
            await reader.hasPendingRequest(for: sourceA)
        }

        store.setDataSource(sourceB)
        store.refresh()
        await waitUntil("new quota request") {
            await reader.hasPendingRequest(for: sourceB)
        }

        await reader.completeRequest(
            for: sourceB,
            with: quotaSnapshot(usedPercent: 22, accountName: "new")
        )
        await waitUntil("new quota snapshot published") {
            store.snapshot.fiveHour?.usedPercent == 22
        }

        await reader.completeRequest(
            for: sourceA,
            with: quotaSnapshot(usedPercent: 77, accountName: "old")
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 22)
        XCTAssertEqual(store.snapshot.accountName, "new")
    }

    func testInFlightSameIdentityPathRebindRejectsOldQuotaAndRestartsNewPathRead() async throws {
        let parent = try makeTemporaryDirectory(named: "QuotaPathRebind")
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldHome = parent.appendingPathComponent("old-home", isDirectory: true)
        let newHome = parent.appendingPathComponent("new-home", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        let sourceAtOldPath = CodexDataSource(codexHome: oldHome, origin: .userSelected)
        let reader = SuspendedQuotaReader()
        let store = AccountQuotaStore(quotaReader: reader, observesUserDefaults: false)

        store.setDataSource(sourceAtOldPath)
        store.refresh()
        await waitUntil("trusted old-path quota request") {
            await reader.hasPendingRequest(for: sourceAtOldPath)
        }
        await reader.completeRequest(
            for: sourceAtOldPath,
            with: quotaSnapshot(usedPercent: 42, accountName: "trusted")
        )
        await waitUntil("trusted old-path quota") {
            store.snapshot.fiveHour?.usedPercent == 42
        }

        store.refresh()
        await waitUntil("delayed old-path quota request") {
            await reader.hasPendingRequest(for: sourceAtOldPath)
        }
        let identityGeneration = store.sourceIdentityGeneration
        let oldBindingGeneration = store.sourceBindingGeneration
        try FileManager.default.moveItem(at: oldHome, to: newHome)
        let sourceAtNewPath = CodexDataSource(codexHome: newHome, origin: .userSelected)
        XCTAssertEqual(sourceAtNewPath.stableIdentityKey, sourceAtOldPath.stableIdentityKey)

        XCTAssertTrue(store.setDataSource(sourceAtNewPath))
        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(store.sourceIdentityGeneration, identityGeneration)
        XCTAssertEqual(store.sourceBindingGeneration, oldBindingGeneration + 1)
        store.refresh()
        await waitUntil("new-path quota request") {
            await reader.hasPendingRequest(for: sourceAtNewPath)
        }

        await reader.completeRequest(
            for: sourceAtOldPath,
            with: quotaSnapshot(usedPercent: 99, accountName: "old-path")
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotEqual(store.snapshot.accountName, "old-path")

        await reader.completeRequest(
            for: sourceAtNewPath,
            with: quotaSnapshot(usedPercent: 55, accountName: "new-path")
        )
        await waitUntil("new-path quota completion") {
            store.snapshot.accountName == "new-path"
        }
        XCTAssertFalse(store.setDataSource(sourceAtNewPath))
        XCTAssertEqual(store.sourceBindingGeneration, oldBindingGeneration + 1)
    }

    func testSameIdentityPathRebindFailurePreservesQuotaAndHistoryIdentity() async throws {
        let parent = try makeTemporaryDirectory(named: "QuotaHistoryPathRebind")
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldHome = parent.appendingPathComponent("old-home", isDirectory: true)
        let newHome = parent.appendingPathComponent("new-home", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
        let sourceAtOldPath = CodexDataSource(codexHome: oldHome, origin: .userSelected)
        let historyIdentity = try XCTUnwrap(QuotaHistoryIdentity(
            homeIdentity: sourceAtOldPath.stableIdentityKey,
            stableAccountKey: "stable-account",
            planType: "pro",
            limitID: "codex"
        ))
        let trustedHistory = QuotaHistorySnapshot(
            daily: [],
            recentBins: [],
            hourlyBins: [],
            latest: Date(timeIntervalSince1970: 1_500)
        )
        let historyClient = RecordingQuotaHistoryClient(snapshot: trustedHistory)
        let historyStore = QuotaHistoryStore(historyClient: historyClient)
        let reader = SuspendedQuotaReader()
        let store = AccountQuotaStore(quotaReader: reader, observesUserDefaults: false)
        store.setHistoryStore(historyStore)

        var trustedQuota = quotaSnapshot(usedPercent: 42, accountName: "trusted")
        trustedQuota.historyIdentity = historyIdentity
        store.setDataSource(sourceAtOldPath)
        store.refresh()
        await waitUntil("trusted quota request") {
            await reader.hasPendingRequest(for: sourceAtOldPath)
        }
        await reader.completeRequest(for: sourceAtOldPath, with: trustedQuota)
        await waitUntil("trusted quota and history") {
            store.snapshot.accountName == "trusted" && historyStore.snapshot == trustedHistory
        }

        store.refresh()
        await waitUntil("delayed old-path quota") {
            await reader.hasPendingRequest(for: sourceAtOldPath)
        }
        try FileManager.default.moveItem(at: oldHome, to: newHome)
        let sourceAtNewPath = CodexDataSource(codexHome: newHome, origin: .userSelected)
        XCTAssertEqual(sourceAtNewPath.stableIdentityKey, sourceAtOldPath.stableIdentityKey)

        XCTAssertTrue(store.setDataSource(sourceAtNewPath))
        store.refresh()
        await waitUntil("new-path quota request") {
            await reader.hasPendingRequest(for: sourceAtNewPath)
        }

        var oldCompletion = quotaSnapshot(usedPercent: 99, accountName: "old-completion")
        oldCompletion.historyIdentity = historyIdentity
        await reader.completeRequest(for: sourceAtOldPath, with: oldCompletion)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotEqual(store.snapshot.accountName, "old-completion")

        await reader.failRequest(for: sourceAtNewPath, error: QuotaTestError())
        await waitUntil("new-path quota failure") {
            store.snapshot.status.hasPrefix("额度读取失败")
        }

        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(store.snapshot.accountName, "trusted")
        XCTAssertTrue(store.snapshot.staleDataDisplayed)
        XCTAssertEqual(historyStore.snapshot, trustedHistory)

        historyStore.reload()
        await waitUntil("retained history identity reload") {
            await historyClient.loadCount() == 1
        }
        let reloadedIdentities = await historyClient.loadedIdentities()
        XCTAssertEqual(reloadedIdentities, [historyIdentity])
        XCTAssertEqual(historyStore.snapshot, trustedHistory)
    }

    func testInFlightQuotaRefreshFromOldSourceDoesNotOverwriteExplicitNilSourceSnapshot() async throws {
        let sourceA = CodexDataSource(codexHome: try makeTemporaryDirectory(named: "QuotaOldToNilSource"), origin: .userSelected)
        let reader = SuspendedQuotaReader()
        let store = AccountQuotaStore(quotaReader: reader)

        store.setDataSource(sourceA)
        store.refresh()
        await waitUntil("old quota request") {
            await reader.hasPendingRequest(for: sourceA)
        }

        store.setDataSource(nil)
        store.refresh()
        await waitUntil("nil quota request") {
            await reader.hasPendingNilRequest()
        }

        await reader.completeNilRequest(with: quotaSnapshot(usedPercent: 44, accountName: "default"))
        await waitUntil("nil source quota snapshot published") {
            store.snapshot.fiveHour?.usedPercent == 44
        }

        await reader.completeRequest(
            for: sourceA,
            with: quotaSnapshot(usedPercent: 88, accountName: "old")
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.snapshot.fiveHour?.usedPercent, 44)
        XCTAssertEqual(store.snapshot.accountName, "default")
    }

    func testAutomaticRefreshReusesTrackedSourceWhenNoExplicitSourceChange() async throws {
        let source = CodexDataSource(codexHome: try makeTemporaryDirectory(named: "QuotaTrackedSource"), origin: .userSelected)
        let firstSnapshot = AccountQuotaSnapshot(
            status: "首轮额度暂无数据",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let reader = SequentialQuotaReader(results: [
            .success(firstSnapshot),
            .success(quotaSnapshot(usedPercent: 55, accountName: "tracked"))
        ])
        let store = AccountQuotaStore(quotaReader: reader)

        store.setDataSource(source)
        store.refresh(force: true)
        await waitUntil("first unavailable quota snapshot publication") {
            store.snapshot == firstSnapshot
        }

        store.refresh(force: false)
        await waitUntil("automatic quota refresh") {
            store.snapshot.fiveHour?.usedPercent == 55
        }

        let sources = await reader.requestedSources()
        XCTAssertEqual(sources, [source, source])
    }

    func testStartUsesDefaultAutomaticRefreshInterval() async {
        let reader = SequentialQuotaReader(results: [.success(quotaSnapshot(usedPercent: 10, accountName: "default"))])
        let timerScheduler = ManualQuotaTimerScheduler()
        let store = AccountQuotaStore(
            quotaReader: reader,
            timerScheduler: timerScheduler,
            observesUserDefaults: false
        )

        store.start()

        XCTAssertEqual(store.automaticRefreshInterval, 60)
        XCTAssertEqual(timerScheduler.scheduledIntervals, [60])
    }

    func testUpdatingAutomaticRefreshIntervalReschedulesTimerWithoutImmediateQuotaRequest() async {
        let reader = SequentialQuotaReader(results: [.success(quotaSnapshot(usedPercent: 10, accountName: "default"))])
        let timerScheduler = ManualQuotaTimerScheduler()
        let store = AccountQuotaStore(
            quotaReader: reader,
            timerScheduler: timerScheduler,
            observesUserDefaults: false
        )
        store.start()
        await waitUntil("initial quota request") {
            await reader.currentReadCount() == 1
        }

        store.setAutomaticRefreshInterval(300)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.automaticRefreshInterval, 300)
        XCTAssertEqual(timerScheduler.scheduledIntervals, [60, 300])
        XCTAssertTrue(timerScheduler.tokens.first?.isInvalidated == true)
        let readCount = await reader.currentReadCount()
        XCTAssertEqual(readCount, 1)
    }

    func testSettingSameAutomaticRefreshIntervalDoesNotRescheduleTimer() {
        let reader = SequentialQuotaReader(results: [])
        let timerScheduler = ManualQuotaTimerScheduler()
        let store = AccountQuotaStore(
            quotaReader: reader,
            timerScheduler: timerScheduler,
            observesUserDefaults: false
        )

        store.start()
        store.setAutomaticRefreshInterval(60)

        XCTAssertEqual(timerScheduler.scheduledIntervals, [60])
    }

    func testAutomaticTimerDoesNotStartConcurrentQuotaRefreshForSameSource() async {
        let reader = SuspendedQuotaReader()
        let timerScheduler = ManualQuotaTimerScheduler()
        let store = AccountQuotaStore(
            quotaReader: reader,
            timerScheduler: timerScheduler,
            observesUserDefaults: false
        )

        store.start()
        await waitUntil("initial quota request") {
            await reader.pendingRequestCount() == 1
        }

        timerScheduler.fireLatest()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let readCount = await reader.currentReadCount()
        XCTAssertEqual(readCount, 1)
    }

    func testInitialAutomaticRefreshIntervalUsesPersistedCadence() {
        let suiteName = "AccountQuotaStoreTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(AccountQuotaRefreshCadence.fiveMinutes.rawValue, forKey: AccountQuotaRefreshCadence.storageKey)

        let store = AccountQuotaStore(
            quotaReader: SequentialQuotaReader(results: []),
            userDefaults: userDefaults,
            observesUserDefaults: false
        )

        XCTAssertEqual(store.automaticRefreshInterval, 300)
    }

    func testPersistedCadenceChangeReschedulesRunningTimerWithoutImmediateQuotaRequest() async {
        let suiteName = "AccountQuotaStoreTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let reader = SequentialQuotaReader(results: [.success(quotaSnapshot(usedPercent: 10, accountName: "default"))])
        let timerScheduler = ManualQuotaTimerScheduler()
        let store = AccountQuotaStore(
            quotaReader: reader,
            timerScheduler: timerScheduler,
            userDefaults: userDefaults
        )
        store.start()
        await waitUntil("initial quota request") {
            await reader.currentReadCount() == 1
        }

        userDefaults.set(AccountQuotaRefreshCadence.fiveMinutes.rawValue, forKey: AccountQuotaRefreshCadence.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: userDefaults)
        await waitUntil("persisted cadence reschedule") {
            timerScheduler.scheduledIntervals == [60, 300]
        }

        let readCount = await reader.currentReadCount()
        XCTAssertEqual(readCount, 1)
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

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func quotaSnapshot(usedPercent: Int, accountName: String) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: usedPercent, resetsAt: Date(timeIntervalSince1970: 1_800)),
            sevenDay: nil,
            planType: "pro",
            limitName: "codex",
            accountName: accountName,
            status: "额度已读取",
            updatedAt: Date(timeIntervalSince1970: TimeInterval(usedPercent))
        )
    }
}

private actor SequentialQuotaReader: QuotaReading {
    private var results: [Result<AccountQuotaSnapshot, Error>]
    private(set) var readCount = 0
    private var sources: [CodexDataSource?] = []

    init(results: [Result<AccountQuotaSnapshot, Error>]) {
        self.results = results
    }

    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        readCount += 1
        sources.append(dataSource)
        guard !results.isEmpty else {
            return .failure(QuotaTestError())
        }
        return results.removeFirst()
    }

    func currentReadCount() -> Int {
        readCount
    }

    func requestedSources() -> [CodexDataSource?] {
        sources
    }
}

private struct QuotaTestError: LocalizedError {
    var errorDescription: String? {
        "模拟网络失败"
    }
}

private actor SuspendedQuotaReader: QuotaReading {
    private var continuations: [String: CheckedContinuation<Result<AccountQuotaSnapshot, Error>, Never>] = [:]
    private var readCount = 0

    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        readCount += 1
        let key = dataSource?.codexHome.path ?? "nil"
        return await withCheckedContinuation { continuation in
            continuations[key] = continuation
        }
    }

    func hasPendingRequest(for dataSource: CodexDataSource) -> Bool {
        continuations[dataSource.codexHome.path] != nil
    }

    func hasPendingNilRequest() -> Bool {
        continuations["nil"] != nil
    }

    func pendingRequestCount() -> Int {
        continuations.count
    }

    func currentReadCount() -> Int {
        readCount
    }

    func completeRequest(for dataSource: CodexDataSource, with snapshot: AccountQuotaSnapshot) {
        continuations.removeValue(forKey: dataSource.codexHome.path)?.resume(returning: .success(snapshot))
    }

    func failRequest(for dataSource: CodexDataSource, error: Error) {
        continuations.removeValue(forKey: dataSource.codexHome.path)?.resume(returning: .failure(error))
    }

    func completeNilRequest(with snapshot: AccountQuotaSnapshot) {
        continuations.removeValue(forKey: "nil")?.resume(returning: .success(snapshot))
    }
}

private actor RecordingQuotaHistoryClient: QuotaHistoryLoading {
    private let snapshot: QuotaHistorySnapshot
    private var loadIdentities: [QuotaHistoryIdentity] = []

    init(snapshot: QuotaHistorySnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot(for quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        if let identity = quota.historyIdentity {
            loadIdentities.append(identity)
        }
        return snapshot
    }

    func recordAndLoadSnapshot(_ quota: AccountQuotaSnapshot) async throws -> QuotaHistorySnapshot {
        snapshot
    }

    func normalizedSnapshot(_ quota: AccountQuotaSnapshot) async throws -> AccountQuotaSnapshot {
        quota
    }

    func loadCount() -> Int {
        loadIdentities.count
    }

    func loadedIdentities() -> [QuotaHistoryIdentity] {
        loadIdentities
    }
}

@MainActor
private final class ManualQuotaTimerScheduler: AccountQuotaTimerScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private(set) var tokens: [ManualQuotaTimerToken] = []

    func scheduleRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> any AccountQuotaTimerToken {
        let token = ManualQuotaTimerToken(handler: handler)
        scheduledIntervals.append(interval)
        tokens.append(token)
        return token
    }

    func fireLatest() {
        tokens.last?.fire()
    }
}

@MainActor
private final class ManualQuotaTimerToken: AccountQuotaTimerToken {
    private let handler: @MainActor @Sendable () -> Void
    private(set) var isInvalidated = false

    init(handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    func invalidate() {
        isInvalidated = true
    }

    func fire() {
        guard !isInvalidated else { return }
        handler()
    }
}
