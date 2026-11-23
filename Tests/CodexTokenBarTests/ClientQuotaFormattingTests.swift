import Foundation
import XCTest
@testable import CodexTokenBar

final class ClientQuotaFormattingTests: XCTestCase {
    func testQuotaFastFormattingPreservesExistingDecimalsAndRoundingBoundaries() {
        func reference(_ value: Double) -> String {
            let rounded = (value * 100).rounded(.toNearestOrAwayFromZero) / 100
            return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
                .replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
        }
        var values = stride(from: 0.0, through: 100.0, by: 0.1).map { $0 }
        for boundary in [0.005, 0.995, 8.305, 83.125, 99.995] {
            values += [boundary.nextDown, boundary, boundary.nextUp]
        }
        values += [-0.0, -1.235, 101.125]
        for value in values {
            XCTAssertEqual(ClientQuotaPresentation.percentNumber(value), reference(value), "percentage \(value)")
        }
        XCTAssertEqual(ClientQuotaPresentation.percentNumber(83.125), "83.13")
        XCTAssertEqual(ClientQuotaPresentation.percentNumber(83.1), "83.1")
        XCTAssertEqual(ClientQuotaPresentation.percentNumber(.nan), "—")
        XCTAssertEqual(ClientQuotaPresentation.percentNumber(.infinity), "—")
    }
}
