import XCTest
@testable import CodexTokenBar

final class UsageLedgerReconcilerTests: XCTestCase {
    typealias Reconciler = UsageLedgerReconciler
    private func event(_ id: String, _ tokens: Int64, at: Int64 = 1000, identity: String? = nil,
                       trusted: Bool = true, fresh: Bool = false, source: String = "child") -> Reconciler.Observation {
        .init(id: id, source: source, timestampMillis: at,
              components: .init(input: tokens, cached: 0, output: 0, reasoning: 0),
              identity: identity, timestampTrusted: trusted, confirmedNew: fresh)
    }
    private func total(_ result: Reconciler.Result) -> Int64 {
        (result.retained + result.inserted).reduce(0) { $0 + $1.components.input + $1.components.output }
    }

    func testRewriteRetainsMissingHistoryMatchesOverlapAndAddsOnlyProvenNewUsage() throws {
        let old = [event("A", 80, identity: "request-a"), event("B", 20, identity: "request-b")]
        let result = try Reconciler.reconcile(history: old, incoming: [
            event("observed-b", 20, at: 1, identity: "request-b", trusted: false),
            event("C", 5, at: 2000, identity: "request-c", fresh: true)])
        XCTAssertEqual(total(result), 105)
        XCTAssertEqual(result.retained, old)
        XCTAssertEqual(result.matches, [.init(historicalID: "B", observationID: "observed-b")])
        XCTAssertTrue(result.unresolved.isEmpty)
        let reopened = try Reconciler.reconcile(history: result.retained + result.inserted,
                                                incoming: [event("C-again", 5, at: 1, identity: "request-c", trusted: false)])
        XCTAssertEqual(total(reopened), 105)
        let appended = try Reconciler.reconcile(history: reopened.retained,
                                                incoming: [event("D", 7, at: 3000, identity: "request-d", fresh: true)])
        XCTAssertEqual(total(appended), 112)
    }

    func testEqualNumbersWithDifferentRequestIDsAreNotDeduplicated() throws {
        let result = try Reconciler.reconcile(history: [event("A", 20, identity: "a")],
                                              incoming: [event("B", 20, identity: "b", fresh: true)])
        XCTAssertEqual(total(result), 40)
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testRewrittenTimestampWithoutIdentityCannotInventAMatchOrNewConsumption() throws {
        let result = try Reconciler.reconcile(history: [event("A", 80)],
                                              incoming: [event("maybe-a", 80, at: 1, trusted: false), event("unknown", 5, trusted: false)])
        XCTAssertEqual(total(result), 80)
        XCTAssertEqual(result.unresolved.count, 2)
    }

    func testRepeatedProvenRequestWithinBatchIsOneInsertion() throws {
        let result = try Reconciler.reconcile(history: [], incoming: [
            event("A", 20, identity: "request", fresh: true), event("alias", 20, identity: "request", fresh: true)])
        XCTAssertEqual(total(result), 20)
        XCTAssertEqual(result.matches.count, 1)
    }

    func testConflictingComponentsPreserveOriginalEvidenceUntilExplicitCorrection() throws {
        let result = try Reconciler.reconcile(history: [event("A", 80, identity: "request")],
                                              incoming: [event("changed-a", 70, identity: "request", fresh: true)])
        XCTAssertEqual(total(result), 80)
        XCTAssertEqual(result.unresolved.count, 1)
    }

    func testSourcesCannotBeMergedAcrossTasksOrAccounts() {
        XCTAssertThrowsError(try Reconciler.reconcile(history: [event("A", 80)],
                                                     incoming: [event("B", 5, fresh: true, source: "another-child")]))
    }
    func testEqualTrustedTimestampAndComponentsAloneCannotMergeRequests() throws {
        let result = try Reconciler.reconcile(history: [event("A", 20)],
                                              incoming: [event("B", 20, fresh: true), event("unknown", 20)])
        XCTAssertEqual(total(result), 40)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.unresolved.map(\.id), ["unknown"])
    }

    func testReusedLedgerIDAndEmptyIdentityAreRejected() {
        XCTAssertThrowsError(try Reconciler.reconcile(history: [event("A", 80)],
                                                     incoming: [event("A", 5, fresh: true)]))
        XCTAssertThrowsError(try Reconciler.reconcile(history: [],
                                                     incoming: [event("B", 5, identity: "", fresh: true)]))
    }

}
