import XCTest
@testable import CodexTokenBar

final class RateAccumulatorTests: XCTestCase {
    func testDeltaAccumulatorCountsOnlyNewTokens() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)
        let estimator: (String) -> Int = { $0.count }

        accumulator.add(
            delta: "hello",
            category: .visibleText,
            key: "thread:item",
            at: 10,
            windowSeconds: 2.5,
            estimator: estimator
        )
        accumulator.add(
            delta: " world",
            category: .visibleText,
            key: "thread:item",
            at: 11,
            windowSeconds: 2.5,
            estimator: estimator
        )

        XCTAssertEqual(accumulator.breakdown.visibleText, 11)
        XCTAssertEqual(accumulator.outputTokens, 11)
        XCTAssertEqual(accumulator.outputCharacters, 11)
        XCTAssertEqual(accumulator.averageRate, 11, accuracy: 0.001)
        XCTAssertEqual(accumulator.rollingRate(now: 11, windowSeconds: 2.5, minimumSpan: 0.4), 11, accuracy: 0.001)
    }

    func testResettingAccumulatorClearsPreviousItemWhenKeyChanges() {
        var accumulator = RateAccumulator(resetsOnNewItem: true)
        let estimator: (String) -> Int = { $0.count }

        accumulator.add(
            delta: "first",
            category: .visibleText,
            key: "item-1",
            at: 1,
            windowSeconds: 2.5,
            estimator: estimator
        )
        accumulator.add(
            delta: "next",
            category: .toolArguments,
            key: "item-2",
            at: 2,
            windowSeconds: 2.5,
            estimator: estimator
        )

        XCTAssertEqual(accumulator.breakdown.visibleText, 0)
        XCTAssertEqual(accumulator.breakdown.toolArguments, 4)
        XCTAssertEqual(accumulator.outputTokens, 4)
        XCTAssertEqual(accumulator.outputCharacters, 4)
    }

    func testDistributedCompletionPayloadAddsBreakdownWithoutCurrentSecondSpike() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        accumulator.addDistributed(
            tokens: 110,
            category: .visibleText,
            key: "message",
            startTimestamp: nil,
            endingAt: 20,
            windowSeconds: 2.5
        )

        XCTAssertEqual(accumulator.breakdown.visibleText, 110)
        XCTAssertEqual(accumulator.outputTokens, 110)
        XCTAssertGreaterThan(accumulator.rollingRate(now: 20.5, windowSeconds: 2.5, minimumSpan: 0.4), 0)
        XCTAssertLessThan(accumulator.rollingRate(now: 20.5, windowSeconds: 2.5, minimumSpan: 0.4), 110)
    }

    func testToolOutputPayloadDoesNotDriveLiveRollingRate() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        accumulator.addDistributed(
            tokens: 2_200,
            category: .toolOutput,
            key: "tool-output",
            startTimestamp: 10,
            endingAt: 20,
            windowSeconds: 2.5
        )

        XCTAssertEqual(accumulator.breakdown.toolOutput, 2_200)
        XCTAssertEqual(accumulator.outputTokens, 2_200)
        XCTAssertEqual(accumulator.rollingRate(now: 20.5, windowSeconds: 2.5, minimumSpan: 0.4), 0, accuracy: 0.001)
    }

    func testToolInputPayloadDrivesLiveRollingRate() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        accumulator.addDistributed(
            tokens: 800,
            category: .toolArguments,
            key: "tool-input",
            startTimestamp: 10,
            endingAt: 20,
            windowSeconds: 2.5
        )

        XCTAssertEqual(accumulator.breakdown.toolArguments, 800)
        XCTAssertEqual(accumulator.outputTokens, 800)
        XCTAssertGreaterThan(accumulator.rollingRate(now: 20.5, windowSeconds: 2.5, minimumSpan: 0.4), 0)
    }

    func testToolInputDeltaUsesConservativeLiveRateInsteadOfInstantSpike() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        accumulator.add(
            delta: String(repeating: "x", count: 160),
            category: .toolArguments,
            key: "tool-input",
            at: 20,
            windowSeconds: 2.5,
            estimator: { $0.count }
        )

        XCTAssertEqual(accumulator.breakdown.toolArguments, 160)
        XCTAssertEqual(accumulator.outputTokens, 160)
        XCTAssertGreaterThan(accumulator.rollingRate(now: 20, windowSeconds: 2.5, minimumSpan: 0.4), 0)
        XCTAssertLessThan(accumulator.rollingRate(now: 20, windowSeconds: 2.5, minimumSpan: 0.4), 90)
    }

    func testParallelToolInputDisplayRateIsCappedForOneSession() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        for index in 0..<8 {
            accumulator.add(
                delta: String(repeating: "x", count: 180),
                category: .toolArguments,
                key: "tool-input-\(index)",
                at: 20,
                windowSeconds: 2.5,
                estimator: { $0.count }
            )
        }

        XCTAssertEqual(accumulator.breakdown.toolArguments, 1_440)
        XCTAssertEqual(accumulator.outputTokens, 1_440)
        XCTAssertLessThanOrEqual(accumulator.rollingRate(now: 20, windowSeconds: 2.5, minimumSpan: 0.4), 80)
    }

    func testDenseVisibleTextDisplayRateIsCappedForOneSession() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        for index in 0..<120 {
            accumulator.add(
                delta: "中",
                category: .visibleText,
                key: "message",
                at: 20 + Double(index) * 0.001,
                windowSeconds: 2.5,
                estimator: { $0.count }
            )
        }

        XCTAssertEqual(accumulator.breakdown.visibleText, 120)
        XCTAssertEqual(accumulator.outputTokens, 120)
        XCTAssertLessThanOrEqual(accumulator.rollingRate(now: 20.2, windowSeconds: 2.5, minimumSpan: 0.4), 80)
    }

    func testReasoningPayloadDoesNotDriveLiveRollingRate() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        accumulator.addDistributed(
            tokens: 600,
            category: .reasoning,
            key: "reasoning",
            startTimestamp: 10,
            endingAt: 20,
            windowSeconds: 2.5
        )

        XCTAssertEqual(accumulator.breakdown.reasoning, 600)
        XCTAssertEqual(accumulator.outputTokens, 600)
        XCTAssertEqual(accumulator.rollingRate(now: 20.5, windowSeconds: 2.5, minimumSpan: 0.4), 0, accuracy: 0.001)
    }

    func testDuplicateVisibleCompletionFromAgentAndMessageCountsOnce() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)
        let text = "可以，先按这个修。"

        accumulator.addDistributed(
            text: text,
            category: .visibleText,
            key: "thread:agent-message:visibleText",
            startTimestamp: nil,
            endingAt: 20,
            windowSeconds: 2.5,
            estimator: { $0.count }
        )
        accumulator.addDistributed(
            text: text,
            category: .visibleText,
            key: "thread:response-item:visibleText",
            startTimestamp: nil,
            endingAt: 20.2,
            windowSeconds: 2.5,
            estimator: { $0.count }
        )

        XCTAssertEqual(accumulator.breakdown.visibleText, text.count)
        XCTAssertEqual(accumulator.outputTokens, text.count)
        XCTAssertEqual(accumulator.outputCharacters, text.count)
    }

    func testExactModelOutputOverridesModelGeneratedEstimateWhenLarger() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        accumulator.add(
            tokens: 12,
            category: .visibleText,
            key: "item",
            at: 1,
            windowSeconds: 2.5
        )
        accumulator.addExactModelOutput(20)

        XCTAssertEqual(accumulator.breakdown.modelGeneratedEstimate, 12)
        XCTAssertEqual(accumulator.breakdown.modelGenerated, 20)
        XCTAssertEqual(accumulator.outputTokens, 20)
    }

    func testPruneDropsExpiredPrefixAndKeepsRecentDeltas() {
        var accumulator = RateAccumulator(resetsOnNewItem: false)

        accumulator.add(tokens: 10, category: .visibleText, key: "first", at: 0, windowSeconds: 10)
        accumulator.add(tokens: 20, category: .visibleText, key: "second", at: 2, windowSeconds: 10)
        accumulator.add(tokens: 30, category: .visibleText, key: "third", at: 4, windowSeconds: 10)

        accumulator.prune(now: 5, windowSeconds: 2.5)

        XCTAssertEqual(accumulator.rollingRate(now: 5, windowSeconds: 2.5, minimumSpan: 0.4), 30, accuracy: 0.001)

        accumulator.prune(now: 10, windowSeconds: 2.5)

        XCTAssertEqual(accumulator.rollingRate(now: 10, windowSeconds: 2.5, minimumSpan: 0.4), 0, accuracy: 0.001)
    }
}
