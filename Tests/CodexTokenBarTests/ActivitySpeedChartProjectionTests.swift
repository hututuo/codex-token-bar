import XCTest
@testable import CodexTokenBar

final class ActivitySpeedChartProjectionTests: XCTestCase {
    private func point(_ time: Int64, rate: Double = 50, seconds: Double = 10) -> ActivitySpeedTrendPoint {
        .init(bucketStart: time, value: .init(weightedOutput: rate * seconds, coveredSeconds: seconds))
    }
    func testOlderLookbackAndFutureBucketsNeverLeaveTheVisibleHalfHour() {
        let points = ActivitySpeedChartProjection.points([point(7_900), point(8_200), point(8_260), point(10_000), point(10_300)], now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(points.map(\.bucketStart), [8_200, 8_260, 10_000])
        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }
    func testCrossingExpiryBoundaryUsesIndependentStableArraysWithoutAnyOldIndexes() {
        let source = [point(8_200), point(8_260), point(8_320)]
        let before = ActivitySpeedChartProjection.points(source, now: Date(timeIntervalSince1970: 10_000))
        let after = ActivitySpeedChartProjection.points(source, now: Date(timeIntervalSince1970: 10_000.001))
        XCTAssertEqual(before.count, 3)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(before.map(\.bucketStart), [8_200, 8_260, 8_320])
        XCTAssertEqual(after.map(\.bucketStart), [8_260, 8_320])
        XCTAssertEqual(after.map(\.segment), [0, 0])
    }
    func testInvalidAggregatesDoNotDistortScaleAndValidZeroStillPlots() {
        let rows = [point(9_700, rate: .nan), point(9_800, seconds: 0), point(9_900, rate: 0)]
        XCTAssertEqual(ActivitySpeedChartProjection.points(rows, now: Date(timeIntervalSince1970: 10_000)).map(\.rate), [0])
        XCTAssertTrue(ActivitySpeedChartProjection.points(rows, now: Date(timeIntervalSince1970: .nan)).isEmpty)
    }
}
