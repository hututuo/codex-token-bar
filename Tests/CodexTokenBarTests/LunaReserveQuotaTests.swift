import Foundation
import XCTest
@testable import CodexTokenBar

final class LunaReserveQuotaTests: XCTestCase {
    private let reset: TimeInterval = 1_800_000_000

    private func reserveCard() -> [String: Any] {
        [
            "limitName": "gpt-reserve",
            "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": reset],
            "secondary": ["usedPercent": 60, "windowDurationMins": 10_080, "resetsAt": reset + 86_400]
        ]
    }

    func testReserveIsSeparateWhetherOrdinaryQuotaIsAvailableOrExhausted() {
        for ordinaryUsed in [20, 100] {
            let snapshot = AccountQuotaReader.parse([
                "rateLimitsByLimitId": [
                    "codex": [
                        "primary": ["usedPercent": ordinaryUsed, "windowDurationMins": 300],
                        "secondary": ["usedPercent": ordinaryUsed, "windowDurationMins": 10_080]
                    ],
                    "base_model_inference": reserveCard()
                ]
            ], accountName: nil)

            XCTAssertEqual(snapshot.selectedLimitID, "codex")
            XCTAssertEqual(snapshot.fiveHour?.usedPercent, ordinaryUsed)
            XCTAssertEqual(snapshot.sevenDay?.usedPercent, ordinaryUsed)
            XCTAssertEqual(snapshot.reserveWindows.map(\.label), ["Reserve 5h", "Reserve 7d"])
            XCTAssertEqual(snapshot.reserveWindows.map(\.remainingPercent), [75, 40])
            XCTAssertEqual(snapshot.reserveWindows.map { $0.resetsAt?.timeIntervalSince1970 }, [reset, reset + 86_400])
            XCTAssertFalse(snapshot.reserveHasUnavailableWindow)
        }
    }

    func testReserveOnlyResponseDoesNotBecomeOrdinaryQuotaOrHistoryIdentity() {
        let snapshot = AccountQuotaReader.parse([
            "rateLimitsByLimitId": ["base_model_inference": reserveCard()]
        ], accountName: nil)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.sevenDay)
        XCTAssertNil(snapshot.selectedLimitID)
        XCTAssertEqual(snapshot.resolvedFiveHourAvailability, .unavailable)
        XCTAssertEqual(snapshot.resolvedSevenDayAvailability, .unavailable)
        XCTAssertEqual(snapshot.reserveWindows.count, 2)
        XCTAssertTrue(snapshot.isAvailable)
    }

    func testReserveOnlyMapPreservesLegacyOrdinaryFallback() {
        let snapshot = AccountQuotaReader.parse([
            "rateLimitsByLimitId": ["base_model_inference": reserveCard()],
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 42, "windowDurationMins": 300]]
        ], accountName: nil)
        XCTAssertEqual(snapshot.selectedLimitID, "codex")
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.reserveWindows.count, 2)
    }

    func testReserveIdentifiersAndDisplayLabels() {
        for id in ["base_model_inference", " GPT-RESERVE "] {
            var card = reserveCard()
            card.removeValue(forKey: "limitName")
            let snapshot = AccountQuotaReader.parse(["rateLimitsByLimitId": [id: card]], accountName: nil)
            XCTAssertEqual(snapshot.reserveWindows.count, 2)
            XCTAssertNil(snapshot.selectedLimitID)
            XCTAssertEqual(snapshot.reserveWindows.map(\.displayLabel), ["Luna 储备 · 5小时", "Luna 储备 · 7天"])
            XCTAssertEqual(snapshot.reserveWindows.map(\.compactDisplayLabel), ["储备5h", "储备7d"])
        }
        let byName = AccountQuotaReader.parse(["rateLimitsByLimitId": ["other-id": reserveCard()]], accountName: nil)
        XCTAssertEqual(byName.reserveWindows.count, 2)
        XCTAssertNil(byName.selectedLimitID)
    }

    func testWeeklyReserveInPrimaryDoesNotFabricateFiveHourWindow() {
        let snapshot = AccountQuotaReader.parse([
            "rateLimitsByLimitId": ["base_model_inference": [
                "primary": ["usedPercent": 100, "windowDurationMins": 10_080]
            ]]
        ], accountName: nil)
        XCTAssertEqual(snapshot.reserveWindows.map(\.label), ["Reserve 7d"])
        XCTAssertEqual(snapshot.reserveWindows.first?.remainingPercent, 0)
        XCTAssertFalse(snapshot.reserveHasUnavailableWindow)
    }

    func testMalformedReserveIsUnknownInsteadOfAZeroOrFullMeasurement() {
        var card = reserveCard()
        card["primary"] = ["usedPercent": "broken", "windowDurationMins": 300]
        let snapshot = AccountQuotaReader.parse(["rateLimitsByLimitId": ["base_model_inference": card]], accountName: nil)
        XCTAssertEqual(snapshot.reserveWindows.map(\.label), ["Reserve 7d"])
        XCTAssertEqual(snapshot.reserveWindows.first?.remainingPercent, 40)
        XCTAssertTrue(snapshot.reserveHasUnavailableWindow)
    }

    func testAbsentReserveDoesNotCreatePlaceholderWindows() {
        let snapshot = AccountQuotaReader.parse([
            "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]]
        ], accountName: nil)
        XCTAssertTrue(snapshot.reserveWindows.isEmpty)
        XCTAssertFalse(snapshot.reserveHasUnavailableWindow)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 80)
    }
}
