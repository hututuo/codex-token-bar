import Foundation
import XCTest
@testable import CodexTokenBar

final class CompactionUsageAccountingTests: XCTestCase {
    private func record(_ id: String = "resp_compact", known: Bool = true, offset: UInt64 = 20) -> CodexCompactionAccounting.Record {
        .init(responseID:id,timestamp:100,components:known ? .init(input:326340,cached:323968,output:7768,reasoning:0) : nil,
              cacheWriteInputTokens:known ? 0:nil,reportedTotal:known ? 334108:nil,ordinal:20,offset:offset,
              model:"gpt-6.1-sol",prompt:1,assistant:2)
    }
    func testCompactionCountsSingleRequestNotTurnOrThreadCumulative() throws {
        var state=CodexCompactionAccounting()
        XCTAssertNil(state.remember(record()))
        let found=try XCTUnwrap(state.compact(record(offset:30)))
        XCTAssertEqual(found.components?.total,334108)
        XCTAssertEqual(found.offset,30)
        state.markEmitted(found)
        XCTAssertNil(state.compact(record(offset:40)))
    }
    func testLegacyMirrorAfterCompactionDoesNotCountTwice() throws {
        var state=CodexCompactionAccounting()
        _=state.remember(record())
        state.markEmitted(try XCTUnwrap(state.compact(record())))
        XCTAssertTrue(state.observeLegacy(last:record().components,counted:true))
        XCTAssertFalse(state.observeLegacy(last:record().components,counted:true))
    }
    func testLegacyMirrorBeforeMarkerKeepsOriginalLegacyIdentity() {
        var state=CodexCompactionAccounting()
        _=state.remember(record())
        XCTAssertFalse(state.observeLegacy(last:record().components,counted:true))
        XCTAssertNil(state.compact(record()))
    }
    func testNearestResponseOnlyPreventsCoincidentalEqualCountsBeingSuppressed() throws {
        var state=CodexCompactionAccounting()
        _=state.remember(record())
        state.markEmitted(try XCTUnwrap(state.compact(record())))
        _=state.remember(record("independent_request"))
        XCTAssertFalse(state.observeLegacy(last:record().components,counted:true))
    }
    func testUnknownUsageIsNotMeasuredZeroAndLateIDPreservesMarker() throws {
        var state=CodexCompactionAccounting()
        let missing=try XCTUnwrap(state.compact(record(known:false,offset:99)))
        XCTAssertNil(missing.components)
        state.markEmitted(missing)
        let later=try XCTUnwrap(state.remember(record(offset:200)))
        XCTAssertEqual(later.offset,99)
        XCTAssertTrue(later.unknownEmitted)
        XCTAssertEqual(later.components?.total,334108)
        state.markEmitted(later)
        XCTAssertNil(state.remember(record(offset:210)))
    }
    func testAppendCheckpointPreservesMirrorAndPendingSeedAnchor() throws {
        var state=CodexCompactionAccounting()
        _=state.remember(record())
        state.markEmitted(try XCTUnwrap(state.compact(record())))
        var restored=try JSONDecoder().decode(CodexCompactionAccounting.self,from:JSONEncoder().encode(state))
        XCTAssertTrue(restored.anchorNextEmptyLegacy)
        XCTAssertTrue(restored.observeLegacy(last:record().components,counted:true))
    }
    func testOldAccountingCheckpointStillDecodesWithoutCompactionState() throws {
        let state=try UsageAccountingState.decode("{\"unreflected\":{\"input\":0,\"cached\":0,\"output\":0,\"reasoning\":0},\"canStartFromZero\":true,\"counterReset\":false}")
        XCTAssertNil(state.compaction)
    }
    func testTrackerMemoryIsBounded() throws {
        var state=CodexCompactionAccounting()
        for i in 0..<10000 { _=state.remember(record("resp_\(i)")) }
        XCTAssertEqual(state.recent.count,128)
        XCTAssertLessThan(try JSONEncoder().encode(state).count,100000)
    }
    func testModernNegativeZeroValidationDoesNotNormalizeItIntoMeasuredUsage() {
        let line=#"{"type":"token_usage_record","payload":{"usage":{"input_tokens":-0,"output_tokens":1}}}"#
        XCTAssertEqual(TokenUsageLexicalValidation.negativeZeroFields(in:line)["usage"],["input_tokens"])
    }
}
