import XCTest
@testable import CodexTokenBar

final class DiagnosticErrorDetailsTests: XCTestCase {
    func testCredentialsInRenderedFieldsAndUnderlyingCausesAreRedacted() {
        for field in [NSLocalizedDescriptionKey, NSLocalizedFailureReasonErrorKey, NSFilePathErrorKey] {
            let cause = NSError(domain: "Fixture", code: 13, userInfo: [field: "Bearer synthetic-private-value"])
            let outer = NSError(domain: "Scan", code: 5, userInfo: [NSUnderlyingErrorKey: cause])
            let text = DiagnosticErrorDetails.text(outer)
            XCTAssertFalse(text.contains("synthetic-private-value"), field)
            XCTAssertTrue(text.contains("Fixture / 13"))
            XCTAssertTrue(text.contains("Scan / 5"))
        }
    }

    func testKnownCredentialAssignmentsAndURLUserInfoAreRedacted() {
        for payload in [
            "https://fixture-user:synthetic-private-value@example.invalid/retry",
            "https://example.invalid/retry?access_token=synthetic-private-value&attempt=2",
            #"{"api_key":"synthetic-private-value","code":13}"#,
            "refresh_token = 'synthetic-private-value'",
            "password=synthetic-private-value",
            "Authorization: Basic synthetic-private-value",
            "Cookie: session=synthetic-private-value; another=synthetic-second-value"
        ] {
            let error = NSError(domain: "Fixture", code: 13, userInfo: [NSLocalizedDescriptionKey: payload])
            let text = DiagnosticErrorDetails.text(error)
            XCTAssertFalse(text.contains("synthetic-private-value"), payload)
            XCTAssertFalse(text.contains("synthetic-second-value"), payload)
            XCTAssertTrue(text.contains("[redacted]"))
        }
    }

    func testOrdinaryPathsCodesAndTokenCountsRemainUseful() {
        let error = NSError(domain: "SQLite", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "database is locked; tokens_used=123; totalTokens=456",
            NSFilePathErrorKey: "/tmp/token-cache/ledger.sqlite",
            NSLocalizedFailureReasonErrorKey: "writer still active"
        ])
        let text = DiagnosticErrorDetails.text(error)
        XCTAssertTrue(text.contains("SQLite / 5"))
        XCTAssertTrue(text.contains("tokens_used=123; totalTokens=456"))
        XCTAssertTrue(text.contains("/tmp/token-cache/ledger.sqlite"))
        XCTAssertTrue(text.contains("writer still active"))
    }

    func testRedactionRunsBeforeOutputTruncation() {
        let text = DiagnosticErrorDetails.text(NSError(domain: "Fixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Bearer " + String(repeating: "Z", count: 20_000)
        ]))
        XCTAssertFalse(text.contains("ZZZZ"))
        XCTAssertLessThanOrEqual(text.count, 8192)
    }
}
