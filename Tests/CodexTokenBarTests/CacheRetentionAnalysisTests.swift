import XCTest
@testable import CodexTokenBar

final class CacheRetentionAnalysisTests: XCTestCase {
    private let minute: Int64 = 60_000_000

    func testComparableEarlyFitsChooseLargerDeclineAcrossSmallSampleChanges() {
        let cohorts = [
            [(1778,1417),(583,429),(163,115),(263,158),(321,48)],
            [(1787,1426),(585,431),(165,117),(260,158),(327,50)]
        ]
        for cohort in cohorts {
            let points = cohort.enumerated().flatMap { group, block in
                (0..<block.0).map { index in
                    makePoint(index: "synthetic-\(group)-\(index)",
                        gap: Int64([1,5,10,20,100][group]) * minute,
                        cached: index < block.1 ? 1_000 : 0)
                }
            }
            let result = CacheRetentionAnalysis.calculate(points)
            XCTAssertEqual(result.earlierDecline?.microseconds, Double(15 * minute))
            let scaled = points.map { point in
                makePoint(index: point.id, gap: point.gapMicroseconds * 2, cached: point.cached)
            }
            XCTAssertEqual(CacheRetentionAnalysis.calculate(scaled).earlierDecline?.microseconds, Double(30 * minute))
        }
    }

    func testPublishedSyntheticVectorAndModelScopes() {
        let points = syntheticPoints()
        let all = CacheRetentionAnalysis.calculate(points)
        XCTAssertEqual(all.count, 160)
        XCTAssertEqual(all.highCount, 120)
        XCTAssertEqual(all.p95Microseconds, 114 * minute)
        XCTAssertEqual(all.p95CoverageCount, 114)
        XCTAssertEqual(all.p95State, .ready)
        XCTAssertEqual(all.dropMicroseconds, Double(120 * minute) + Double(minute) / 2)
        XCTAssertEqual(all.dropLeftMicroseconds, 120 * minute)
        XCTAssertEqual(all.dropRightMicroseconds, 121 * minute)
        XCTAssertEqual(all.dropState, .ready)
        XCTAssertEqual(all.bestSegments, 2)
        XCTAssertEqual(all.segments.map(\.count), [120, 40])
        XCTAssertEqual(all.segments.map(\.highCount), [120, 0])
        XCTAssertEqual(all.searchMode, "exact")

        let modelA = CacheRetentionAnalysis.calculate(points.filter { $0.model == "synthetic-A" })
        XCTAssertEqual(modelA.p95Microseconds, 113 * minute)
        XCTAssertEqual(modelA.p95State, .smallSample)
        XCTAssertEqual(modelA.dropLeftMicroseconds, 119 * minute)
        XCTAssertEqual(modelA.dropRightMicroseconds, 121 * minute)
        XCTAssertEqual(modelA.dropMicroseconds, Double(120 * minute))

        let modelB = CacheRetentionAnalysis.calculate(points.filter { $0.model == "synthetic-B" })
        XCTAssertEqual(modelB.p95Microseconds, 114 * minute)
        XCTAssertEqual(modelB.p95State, .smallSample)
        XCTAssertEqual(modelB.dropLeftMicroseconds, 120 * minute)
        XCTAssertEqual(modelB.dropRightMicroseconds, 122 * minute)
        XCTAssertEqual(modelB.dropMicroseconds, Double(121 * minute))
    }

    func testScalingAllGapsScalesBothEstimates() {
        let doubled = syntheticPoints().map { point in
            makePoint(
                index: point.id,
                gap: point.gapMicroseconds * 2,
                startedAt: point.startedAtMicroseconds,
                model: point.model,
                cached: point.cached
            )
        }

        let result = CacheRetentionAnalysis.calculate(doubled)
        XCTAssertEqual(result.p95Microseconds, 228 * minute)
        XCTAssertEqual(result.dropLeftMicroseconds, 240 * minute)
        XCTAssertEqual(result.dropRightMicroseconds, 242 * minute)
        XCTAssertEqual(result.dropMicroseconds, Double(241 * minute))
    }

    func testNearestRankThresholdsAndEmptyInput() {
        let empty = CacheRetentionAnalysis.calculate([])
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.highCount, 0)
        XCTAssertNil(empty.p95Microseconds)
        XCTAssertNil(empty.dropMicroseconds)
        XCTAssertEqual(empty.p95State, .insufficient)
        XCTAssertEqual(empty.dropState, .insufficient)

        for count in [19, 20, 99, 100] {
            let result = CacheRetentionAnalysis.calculate((0..<count).map { index in
                makePoint(index: "high-\(index)", gap: Int64(index), cached: 1_000)
            })
            XCTAssertEqual(result.highCount, count)
            if count < 20 {
                XCTAssertNil(result.p95Microseconds)
                XCTAssertEqual(result.p95State, .insufficient)
            } else {
                let rank = (95 * count + 99) / 100
                XCTAssertEqual(result.p95Microseconds, Int64(rank - 1))
                XCTAssertEqual(result.p95CoverageCount, rank)
                XCTAssertEqual(result.p95State, count < 100 ? .smallSample : .ready)
            }
        }
    }

    func testNearestRankCountsTiedValuesAtTheCutoff() {
        let points = (0..<20).map { index in
            makePoint(
                index: "tie-\(index)",
                gap: index < 12 ? 10 : 20,
                cached: 1_000
            )
        }

        let result = CacheRetentionAnalysis.calculate(points)
        XCTAssertEqual(result.p95Microseconds, 20)
        XCTAssertEqual(result.p95CoverageCount, 20)
        XCTAssertEqual(result.p95State, .smallSample)
    }

    func testEqualGapValuesAreOneIndivisibleTieGroup() {
        let points = (0..<40).map { index in
            makePoint(index: "same-gap-\(index)", gap: 7, cached: index < 20 ? 1_000 : 0)
        }

        let result = CacheRetentionAnalysis.calculate(points)
        XCTAssertEqual(result.searchMode, "exact")
        XCTAssertNil(result.bestSegments)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.dropMicroseconds)
        XCTAssertEqual(result.dropState, .insufficient)
    }

    func testAllHighAndAllLowHaveNoDetectedDrop() {
        for cached in [Int64(1_000), Int64(0)] {
            let points = (1...160).map { index in
                makePoint(index: "uniform-\(index)", gap: Int64(index), cached: cached)
            }
            let result = CacheRetentionAnalysis.calculate(points)
            XCTAssertNil(result.dropMicroseconds)
            XCTAssertEqual(result.dropState, .notDetected)
            XCTAssertEqual(result.bestSegments, 1)
        }
    }

    func testLargeScopeClearsBothEstimates() {
        let points = (0...100_000).map { index in
            makePoint(index: "large-\(index)", gap: Int64(index), cached: 1_000)
        }

        let result = CacheRetentionAnalysis.calculate(points)
        XCTAssertEqual(result.count, 100_001)
        XCTAssertEqual(result.highCount, 100_001)
        XCTAssertNil(result.p95Microseconds)
        XCTAssertNil(result.dropMicroseconds)
        XCTAssertEqual(result.p95State, .rangeTooLarge)
        XCTAssertEqual(result.dropState, .rangeTooLarge)
        XCTAssertEqual(result.searchMode, "not_run")
    }

    func testBoundedCandidateGridActivatesAbove512DistinctCuts() {
        let points = (1...514).flatMap { index in
            (0..<20).map { replicate in
                makePoint(
                    index: "grid-\(index)-\(replicate)",
                    gap: Int64(index),
                    cached: index <= 400 ? 1_000 : 0
                )
            }
        }

        let result = CacheRetentionAnalysis.calculate(points)
        XCTAssertEqual(result.searchMode, "bounded_candidate_grid")
        XCTAssertEqual(result.bestSegments, 2)
        XCTAssertEqual(result.dropLeftMicroseconds, 400)
        XCTAssertEqual(result.dropRightMicroseconds, 401)
        XCTAssertEqual(result.dropMicroseconds, 400.5)
    }

    func testMidpointAvoidsSignedInt64AdditionOverflow() {
        let points = (0..<40).map { index in
            makePoint(
                index: "overflow-\(index)",
                gap: index < 20 ? Int64.min : Int64.max,
                cached: index < 20 ? 1_000 : 0
            )
        }

        let result = CacheRetentionAnalysis.calculate(points)
        XCTAssertEqual(result.dropLeftMicroseconds, Int64.min)
        XCTAssertEqual(result.dropRightMicroseconds, Int64.max)
        XCTAssertTrue(result.dropMicroseconds?.isFinite == true)
        XCTAssertEqual(result.dropMicroseconds, -0.5)
    }

    private func syntheticPoints() -> [CacheRetentionPoint] {
        (1...160).map { index in
            let percent = index <= 120
                ? 80 + (index * 7 % 20)
                : 5 + (index * 11 % 65)
            return makePoint(
                index: "synthetic-\(index)",
                gap: Int64(index) * minute,
                model: index.isMultiple(of: 2) ? "synthetic-B" : "synthetic-A",
                cached: Int64(percent * 10)
            )
        }
    }

    private func makePoint(
        index: String,
        gap: Int64,
        startedAt: Int64 = 0,
        model: String = "synthetic-A",
        cached: Int64
    ) -> CacheRetentionPoint {
        CacheRetentionPoint(
            id: index,
            sourceKey: "source",
            sessionKey: "session",
            model: model,
            gapMicroseconds: gap,
            startedAtMicroseconds: startedAt,
            previousInput: 1_000,
            previousCached: 900,
            input: 1_000,
            cached: cached
        )
    }
}
