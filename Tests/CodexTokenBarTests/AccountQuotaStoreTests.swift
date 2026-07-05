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

        store.refresh(dataSource: dataSource)
        await waitUntil("quota refresh with source") {
            store.snapshot.status == "额度已读取"
        }

        let sources = await reader.requestedSources()
        XCTAssertEqual(sources, [dataSource])
    }

    func testInFlightQuotaRefreshFromOldSourceDoesNotOverwriteNewSourceSnapshot() async throws {
        let sourceA = CodexDataSource(codexHome: try makeTemporaryDirectory(named: "QuotaOldSource"), origin: .userSelected)
        let sourceB = CodexDataSource(codexHome: try makeTemporaryDirectory(named: "QuotaNewSource"), origin: .userSelected)
        let reader = SuspendedQuotaReader()
        let store = AccountQuotaStore(quotaReader: reader)

        store.refresh(dataSource: sourceA)
        await waitUntil("old quota request") {
            await reader.hasPendingRequest(for: sourceA)
        }

        store.refresh(dataSource: sourceB)
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

    func readQuota(dataSource: CodexDataSource?) async -> Result<AccountQuotaSnapshot, Error> {
        let key = dataSource?.codexHome.path ?? "nil"
        return await withCheckedContinuation { continuation in
            continuations[key] = continuation
        }
    }

    func hasPendingRequest(for dataSource: CodexDataSource) -> Bool {
        continuations[dataSource.codexHome.path] != nil
    }

    func completeRequest(for dataSource: CodexDataSource, with snapshot: AccountQuotaSnapshot) {
        continuations.removeValue(forKey: dataSource.codexHome.path)?.resume(returning: .success(snapshot))
    }
}
