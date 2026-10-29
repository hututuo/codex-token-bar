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
    func testDayActivityKeepsEarlierMinutesWhileDefaultRemainsHalfHour() {
        let rows = [point(10_000), point(96_400), point(97_000), point(97_060), point(100_001)]
        let day = ActivitySpeedChartProjection.points(rows, now: Date(timeIntervalSince1970: 100_000), windowSeconds: 86400)
        XCTAssertEqual(day.map(\.bucketStart), [96_400, 97_000, 97_060])
        XCTAssertEqual(day.map(\.segment), [0, 1, 1])
        XCTAssertTrue(ActivitySpeedChartProjection.points(rows, now: Date(timeIntervalSince1970: 100_000)).isEmpty)
    }
    func testThirtySecondDetailUsesItsOwnGapBoundary() {
        let rows = [point(14_000), point(14_030), point(14_090)]
        let detail = ActivitySpeedChartProjection.points(rows, now: Date(timeIntervalSince1970: 100_000), windowSeconds: 86400, bucketSeconds: 30)
        XCTAssertEqual(detail.map(\.segment), [0, 0, 1])
    }
    func testInvalidAggregatesDoNotDistortScaleAndValidZeroStillPlots() {
        let rows = [point(9_700, rate: .nan), point(9_800, seconds: 0), point(9_900, rate: 0)]
        XCTAssertEqual(ActivitySpeedChartProjection.points(rows, now: Date(timeIntervalSince1970: 10_000)).map(\.rate), [0])
        XCTAssertTrue(ActivitySpeedChartProjection.points(rows, now: Date(timeIntervalSince1970: .nan)).isEmpty)
    }
}
