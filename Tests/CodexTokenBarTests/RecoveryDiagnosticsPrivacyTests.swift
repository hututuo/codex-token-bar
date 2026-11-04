import Foundation
import XCTest
@testable import CodexTokenBar

final class RecoveryDiagnosticsPrivacyTests: XCTestCase {
    func testRecoveryLogAllowsOnlyFixedMetadataFields() throws {
        let sentinel = "SYNTHETIC-PRIVATE-PATH-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(sentinel)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try XCTUnwrap(RecoveryDiagnostics(root: root))
        log.record(.importing, completed: 2, total: 7, retryCount: 1, code: 13)
        log.record(.failure, completed: 2, total: 7, retryCount: 2, code: 5)
        log.close()

        let bytes = try Data(contentsOf: log.fileURL)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(sentinel))
        let rows = try bytes.split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, 3)
        let header = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(header.keys), Set(["format", "attempt"]))
        XCTAssertEqual(header["format"] as? String, RecoveryDiagnostics.format)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(header["attempt"] as? String)))
        let eventFields = Set(["phase", "at", "completed", "total", "retryCount", "code"])
        for event in rows.dropFirst() {
            XCTAssertEqual(Set(event.keys), eventFields)
            XCTAssertEqual(event["completed"] as? Int, 2)
            XCTAssertEqual(event["total"] as? Int, 7)
        }
        let latestBytes = try Data(contentsOf: root.appendingPathComponent("latest-failure.json"))
        XCTAssertFalse(String(decoding: latestBytes, as: UTF8.self).contains(sentinel))
        let latest = try XCTUnwrap(JSONSerialization.jsonObject(with: latestBytes) as? [String: Any])
        XCTAssertEqual(Set(latest.keys), Set(["format", "event"]))
        let failure = try XCTUnwrap(latest["event"] as? [String: Any])
        XCTAssertEqual(Set(failure.keys), eventFields)
        XCTAssertEqual(failure["phase"] as? String, "failure")
        XCTAssertEqual(failure["code"] as? Int, 5)
    }
}
