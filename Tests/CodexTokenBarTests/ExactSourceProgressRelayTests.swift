import XCTest
@testable import CodexTokenBar

final class ExactSourceProgressRelayTests: XCTestCase {
    func testByteNotificationsAreBoundedAndNeverCompleteOrRewindFileWork() {
        var now = 0.0
        var values: [PreciseIndexProgress] = []
        let relay = ExactSourceProgressRelay({ values.append($0) }, clock: { now })
        relay.report(.init(phase: .backfillingModel, message: "历史补全", completed: 4, total: 4124))
        now = 0.25
        relay.sourceBytes(100, total: 1000)
        now = 0.35; relay.sourceBytes(200, total: 1000)
        XCTAssertEqual(values.count, 2)
        now = 0.5; relay.sourceBytes(400, total: 1000)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.last?.completed, 4)
        XCTAssertEqual(values.last?.total, 4124)
        XCTAssertTrue(values.last?.message.contains("已读取") == true)
        relay.report(.init(phase: .backfillingModel, message: "历史补全", completed: 5, total: 4124))
        XCTAssertEqual(values.count, 3, "Fast file counters are coalesced before reaching the UI")
        now = 0.75; relay.sourceBytes(1000, total: 1000)
        XCTAssertEqual(values.last?.completed, 5, "Reading all bytes does not complete another file")
        XCTAssertEqual(values.last?.phase, .backfillingModel)
        relay.report(.init(phase: .publishing, message: "提交中", completed: 4124, total: 4124))
        let publishedCount = values.count
        now = 1; relay.sourceBytes(1000, total: 1000)
        XCTAssertEqual(values.count, publishedCount, "Late byte callbacks cannot restore the old phase")
        XCTAssertEqual(values.last?.fraction, 0.99)
    }
}
