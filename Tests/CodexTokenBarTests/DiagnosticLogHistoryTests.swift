import XCTest
@testable import CodexTokenBar

final class DiagnosticLogHistoryTests: XCTestCase {
    func testUnderlyingFileErrorIncludesDomainCodeAndPath() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSFilePathErrorKey: "/codex/sessions/blocked.jsonl"])
        let error = NSError(domain: "Scan", code: 1, userInfo: [NSUnderlyingErrorKey: underlying, "access_token": "must-not-log"])
        let text = DiagnosticErrorDetails.text(error)
        XCTAssertTrue(text.contains("NSPOSIXErrorDomain / 13"))
        XCTAssertTrue(text.contains("blocked.jsonl"))
        XCTAssertFalse(text.contains("must-not-log"))
    }

    @MainActor
    func testSourceSwitchKeepsOriginalFailureContext() {
        let journal = DiagnosticLogHistory()
        journal.sourceContext = "/old"
        journal.record(summary: "读取失败", logs: "same error", source: "usage")
        journal.sourceContext = "/new"
        journal.record(summary: "读取失败", logs: "same error", source: "usage")
        XCTAssertEqual(journal.history.first?.sourceContext, "/old")
        XCTAssertEqual(journal.current["usage"]?.sourceContext, "/new")
        XCTAssertTrue(journal.environmentText.contains("build"))
    }

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
