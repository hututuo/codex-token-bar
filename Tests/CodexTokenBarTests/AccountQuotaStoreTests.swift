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

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private actor SequentialQuotaReader: QuotaReading {
    private var results: [Result<AccountQuotaSnapshot, Error>]

    init(results: [Result<AccountQuotaSnapshot, Error>]) {
        self.results = results
    }

    func readQuota() async -> Result<AccountQuotaSnapshot, Error> {
        guard !results.isEmpty else {
            return .failure(QuotaTestError())
        }
        return results.removeFirst()
    }
}

private struct QuotaTestError: LocalizedError {
    var errorDescription: String? {
        "模拟网络失败"
    }
}
