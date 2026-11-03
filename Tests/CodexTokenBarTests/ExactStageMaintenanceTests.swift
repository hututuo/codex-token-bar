import Foundation
import XCTest
@testable import CodexTokenBar

final class ExactStageMaintenanceTests: XCTestCase {
    func testFirstScheduledTickRunsOffMainActor() async {
        let fired = expectation(description: "actual maintenance timer callback")
        let maintenance = await MainActor.run {
            let maintenance = ExactStageMaintenance(firstTickDelayForTesting: 0.01) {
                XCTAssertFalse(Thread.isMainThread)
                fired.fulfill()
            }
            maintenance.start()
            return maintenance
        }

        await fulfillment(of: [fired], timeout: 5)
        withExtendedLifetime(maintenance) {}
    }

    func testRepeatedStartKeepsOneScheduledCallback() async {
        let fired = expectation(description: "one maintenance timer callback")
        fired.assertForOverFulfill = true
        let maintenance = await MainActor.run {
            let maintenance = ExactStageMaintenance(firstTickDelayForTesting: 0.01) {
                XCTAssertFalse(Thread.isMainThread)
                fired.fulfill()
            }
            maintenance.start()
            maintenance.start()
            return maintenance
        }

        await fulfillment(of: [fired], timeout: 5)
        try? await Task.sleep(for: .milliseconds(100))
        withExtendedLifetime(maintenance) {}
    }
}
