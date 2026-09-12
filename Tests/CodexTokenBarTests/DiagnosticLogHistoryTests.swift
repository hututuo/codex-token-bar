import XCTest
@testable import CodexTokenBar

final class DiagnosticLogHistoryTests: XCTestCase {
    @MainActor
    func testRecoveryKeepsOriginalCauseAndTimes() {
        let journal = DiagnosticLogHistory()
        let first = Date(timeIntervalSince1970: 100)
        journal.record(summary: "额度读取失败", logs: "HTTP 503 original cause", source: "quota", at: first)
        journal.record(summary: "额度读取失败", logs: "HTTP 503 original cause", source: "quota", at: first.addingTimeInterval(60))
        XCTAssertEqual(journal.current["quota"]?.count, 2)
        journal.record(summary: "额度读取", logs: "", source: "quota", at: first.addingTimeInterval(90))
        XCTAssertTrue(journal.current.isEmpty)
        XCTAssertEqual(journal.history.first?.firstAt, first)
        XCTAssertEqual(journal.history.first?.endedAt, first.addingTimeInterval(90))
        XCTAssertEqual(journal.history.first?.detail, "HTTP 503 original cause")
        XCTAssertEqual(journal.history.first?.recovered, true)
        XCTAssertTrue(journal.report.contains("【当前问题】"))
        XCTAssertTrue(journal.report.contains("【历史记录】"))
    }

    @MainActor
    func testChangedErrorIsNotRecoveryAndHistoryIsBounded() {
        let journal = DiagnosticLogHistory()
        for index in 0..<110 {
            journal.record(summary: "读取失败", logs: "error \(index)", source: "usage", at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(journal.history.count, 100)
        XCTAssertEqual(journal.history.first?.recovered, false)
        XCTAssertEqual(journal.current["usage"]?.detail, "error 109")
    }
}
