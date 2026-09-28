import Foundation
import XCTest
@testable import CodexTokenBar

final class DirectQuotaHTTPReaderTests: XCTestCase {
    func testRemovalFailurePreservesManifestAndCredential() throws {
        enum Failure: Error { case delete, commit, restore }
        var hasCredential = true
        var listed = true
        XCTAssertThrowsError(try QuotaAccountRegistry.finishRemoval(
            delete: { throw Failure.delete },
            commit: { listed = false },
            restore: { XCTFail("No rollback is needed when deletion fails") }))
        XCTAssertTrue(hasCredential)
        XCTAssertTrue(listed)
        XCTAssertThrowsError(try QuotaAccountRegistry.finishRemoval(
            delete: { hasCredential = false },
            commit: { throw Failure.commit },
            restore: { hasCredential = true }))
        XCTAssertTrue(hasCredential)
        XCTAssertTrue(listed)
        try QuotaAccountRegistry.finishRemoval(
            delete: { hasCredential = false },
            commit: { listed = false },
            restore: { XCTFail("Successful removal must not restore a credential") })
        XCTAssertFalse(hasCredential)
        XCTAssertFalse(listed)
        XCTAssertThrowsError(try QuotaAccountRegistry.finishRemoval(
            delete: {}, commit: { throw Failure.commit }, restore: { throw Failure.restore })) { error in
            guard case DirectQuotaError.removalRecovery = error else {
                return XCTFail("Restoration failure must be surfaced explicitly")
            }
        }
    }

    private func auth(account: String = "account-1", user: String = "user-1", signature: String = "one", explicit: String? = nil) throws -> Data {
        let claims: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": user], "https://api.openai.com/profile": ["email": "same@example.invalid"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "e30.\(payload).\(signature)", "account_id": explicit ?? account]])
    }
    func testTokenRotationKeepsStableIdentityAcrossClients() throws {
        let a = try QuotaAccountCredential.parse(auth())
        let b = try QuotaAccountCredential.parse(auth(signature: "two"))
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, "a6903db6ef51e158e82e0d8cac1984e301afbb9746a826285f4d0d3f4d15c313")
        XCTAssertNotEqual(a.accessToken, b.accessToken)
        XCTAssertEqual(a.label, "same@example.invalid")
    }
    func testSameEmailDifferentAccountOrUserDoesNotMerge() throws {
        let a = try QuotaAccountCredential.parse(auth())
        XCTAssertNotEqual(a.id, try QuotaAccountCredential.parse(auth(account: "account-2")).id)
        XCTAssertNotEqual(a.id, try QuotaAccountCredential.parse(auth(user: "user-2")).id)
    }
    func testConflictingAccountAndMissingStableUserAreRejected() throws {
        XCTAssertThrowsError(try QuotaAccountCredential.parse(auth(explicit: "other")))
        XCTAssertThrowsError(try QuotaAccountCredential.parse(auth(user: "")))
    }
    func testFreshestCredentialNeverBorrowsAnotherAccount() throws {
        var older = try QuotaAccountCredential.parse(auth())
        var newer = older
        func token(_ expiry: Int) -> String {
            "e30." + Data("{\"exp\":\(expiry)}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".synthetic"
        }
        older.accessToken = token(100)
        newer.accessToken = token(200)
        let other = try QuotaAccountCredential.parse(auth(account: "other"))
        XCTAssertEqual(QuotaAccountCredential.freshest([older, newer, other], accountID: older.id)?.accessToken, newer.accessToken)
        XCTAssertNil(QuotaAccountCredential.freshest([other], accountID: older.id))
    }

    func testAPIKeyAndControlCharactersAreRejected() throws {
        for access in ["sk-synthetic-not-a-real-key", "abc\r\nX-Test: value", "abc\u{0}def"] {
            let data = try JSONSerialization.data(withJSONObject: ["access_token": access, "account_id": "account-1"])
            XCTAssertThrowsError(try QuotaAccountCredential.parse(data))
        }
    }
    func testCPAFlatAndCodexNestedUseSameIdentity() throws {
        let nested = try auth()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: nested) as? [String: Any])
        let flat = try JSONSerialization.data(withJSONObject: root["tokens"]!)
        XCTAssertEqual(try QuotaAccountCredential.parse(flat).id, try QuotaAccountCredential.parse(nested).id)
    }
    func testRequestIsReadOnlyOfficialAndNeverOptsIntoReserve() throws {
        let credential = try QuotaAccountCredential.parse(auth())
        for reset in [false, true] {
            let request = DirectQuotaHTTPReader.request(credential: credential, resetCredits: reset)
            XCTAssertEqual(request.url?.host, "chatgpt.com")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Chatgpt-Account-Id"), "account-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + credential.accessToken)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-openai-codex-luna-reserve"))
            XCTAssertNil(request.httpBody)
        }
    }
    func testWHAMOnePercentAndRelativeReset() {
        let wire: [String: Any] = ["plan_type": "pro", "rate_limit": ["allowed": true, "primary_window": ["used_percent": 1, "limit_window_seconds": 18000, "reset_after_seconds": 60], "secondary_window": ["used_percent": 40, "limit_window_seconds": 604800, "reset_at": 1_800_086_400]]]
        let snapshot = AccountQuotaReader.parse(DirectQuotaHTTPReader.normalize(wire, now: Date(timeIntervalSince1970: 1_800_000_000)), accountName: nil)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 1)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt?.timeIntervalSince1970, 1_800_000_060)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 40)
    }
    func testMissingWindowsStayUnknownAndReserveStaysSeparate() {
        let wire: [String: Any] = ["rate_limit": ["allowed": false], "additional_rate_limits": [["metered_feature": "base_model_inference", "limit_name": "gpt-reserve", "rate_limit": ["primary_window": ["used_percent": 25, "limit_window_seconds": 18000]]]]]
        let snapshot = AccountQuotaReader.parse(DirectQuotaHTTPReader.normalize(wire), accountName: nil)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.sevenDay)
        XCTAssertEqual(snapshot.reserveWindows.first?.remainingPercent, 75)
    }
}
