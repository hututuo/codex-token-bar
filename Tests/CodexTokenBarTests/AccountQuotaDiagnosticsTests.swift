import Foundation
import XCTest
@testable import CodexTokenBar

final class AccountQuotaDiagnosticsTests: XCTestCase {
    func testQuotaDiagnosticClassifierMapsReaderErrors() {
        let cases: [(Error, AccountQuotaDiagnosticCategory)] = [
            (AccountQuotaReaderError.codexBinaryNotFound, .appServerUnavailable),
            (AccountQuotaReaderError.timeout, .timeout),
            (AccountQuotaReaderError.emptyResponse, .timeout),
            (AccountQuotaReaderError.invalidResponse, .parseFailure),
            (AccountQuotaReaderError.emptyRateLimits, .emptyQuota),
            (AccountQuotaReaderError.timeoutWithOutput("WARN plugin manifest noise"), .timeout),
            (AccountQuotaReaderError.serverError("stderr: failed to launch app-server"), .appServerUnavailable),
            (QuotaDiagnosticTestError(), .unknown)
        ]

        for (error, expectedCategory) in cases {
            let diagnostic = AccountQuotaDiagnostic.classify(
                source: .accountQuota,
                error: error,
                occurredAt: Date(timeIntervalSince1970: 1_000)
            )
            XCTAssertEqual(diagnostic.category, expectedCategory)
            XCTAssertEqual(diagnostic.source, .accountQuota)
            XCTAssertFalse(diagnostic.message.isEmpty)
            XCTAssertNotNil(diagnostic.rawCause)
        }
    }

    func testQuotaTimeoutWithNoisyStderrPreservesRawCauseWithoutChangingCategory() {
        let error = AccountQuotaReaderError.timeout(stderrText: "  WARN failed to refresh available models\n")
        let diagnostic = AccountQuotaDiagnostic.classify(
            source: .accountQuota,
            error: error,
            occurredAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(diagnostic.category, .timeout)
        XCTAssertEqual(diagnostic.rawCause, "WARN failed to refresh available models")
        XCTAssertTrue(diagnostic.retryable)
    }

    func testHTTPStatusClassifierUsesSharedQuotaCategories() {
        XCTAssertEqual(AccountQuotaDiagnostic.category(forHTTPStatus: 401), .httpAuth)
        XCTAssertEqual(AccountQuotaDiagnostic.category(forHTTPStatus: 403), .httpAuth)
        XCTAssertEqual(AccountQuotaDiagnostic.category(forHTTPStatus: 429), .httpRateLimited)
        XCTAssertEqual(AccountQuotaDiagnostic.category(forHTTPStatus: 500), .httpServer)
        XCTAssertEqual(AccountQuotaDiagnostic.category(forHTTPStatus: 418), .httpOther)
    }

    func testResetCreditFailureWrapsUnderlyingCause() {
        let underlying = AccountQuotaDiagnostic.classify(
            source: .resetCredit,
            error: URLError(.notConnectedToInternet),
            occurredAt: Date(timeIntervalSince1970: 1_000)
        )

        let diagnostic = AccountQuotaDiagnostic.resetCreditFailure(
            underlying: underlying,
            occurredAt: Date(timeIntervalSince1970: 1_001)
        )

        XCTAssertEqual(diagnostic.source, .resetCredit)
        XCTAssertEqual(diagnostic.category, .resetCreditFailure)
        XCTAssertEqual(diagnostic.underlyingCategory, .networkSendFetch)
        XCTAssertEqual(diagnostic.rawCause, underlying.rawCause)
        XCTAssertTrue(diagnostic.retryable)
    }

    func testResetCreditAuthMissingFailureIsNotRetryable() {
        let underlying = AccountQuotaDiagnostic(
            source: .resetCredit,
            category: .authMissing,
            severity: .warning,
            message: "未找到登录 token",
            rawCause: "auth.json missing",
            retryable: true,
            occurredAt: Date(timeIntervalSince1970: 1_000)
        )

        let diagnostic = AccountQuotaDiagnostic.resetCreditFailure(
            underlying: underlying,
            occurredAt: Date(timeIntervalSince1970: 1_001)
        )

        XCTAssertEqual(diagnostic.category, .resetCreditFailure)
        XCTAssertEqual(diagnostic.underlyingCategory, .authMissing)
        XCTAssertFalse(diagnostic.retryable)
    }
}

private struct QuotaDiagnosticTestError: LocalizedError {
    var errorDescription: String? {
        "无法解释的额度错误"
    }
}
