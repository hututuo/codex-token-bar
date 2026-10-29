import XCTest
@testable import CodexTokenBar

final class ActivityLiveHistoryTests: XCTestCase {
    private func rates(_ value: Double) -> [ModelRateContribution] { [.init(model:"gpt-6-luna",tokensPerSecond:value)] }
    func testFirstPositiveReceiptAndSubsecondPointsArePreserved() {
        var history = ActivityLiveHistory()
        XCTAssertFalse(history.record(client:"claudeCode",mode:.agentSpeed,rates:[],at:10,available:true))
        XCTAssertTrue(history.snapshot(allowed:["claudeCode"],mode:.bar,now:10).isEmpty)
        history.record(client:"codex",mode:.bar,rates:rates(40),at:10,available:true)
        history.record(client:"codex",mode:.bar,rates:rates(80),at:10.2,available:true)
        history.record(client:"codex",mode:.bar,rates:[],at:10.4,available:true)
        XCTAssertFalse(history.record(client:"codex",mode:.bar,rates:rates(99),at:10.4,available:true))
        let points = history.snapshot(allowed:["codex"],mode:.bar,now:11).first!.points
        XCTAssertEqual(points.map(\.time),[10,10.2,10.4])
        XCTAssertEqual(points.map(\.rate),[40,80,0])
        XCTAssertTrue(history.snapshot(allowed:["codex"],mode:.bar,now:191).isEmpty)
    }
    func testModesClientResetAndUnavailableReadRemainIndependent() {
        var history = ActivityLiveHistory()
        history.record(client:"codex",mode:.bar,rates:rates(40),at:10,available:true)
        history.record(client:"codex",mode:.agentSpeed,rates:rates(90),at:10,available:true)
        history.record(client:"claudeCode",mode:.agentSpeed,rates:rates(30),at:10,available:true)
        XCTAssertFalse(history.record(client:"claudeCode",mode:.agentSpeed,rates:rates(100),at:11,available:false))
        XCTAssertEqual(history.snapshot(allowed:["codex","claudeCode"],mode:.bar,now:12).map { $0.points.last!.rate },[30,40])
        XCTAssertEqual(history.snapshot(allowed:["codex"],mode:.agentSpeed,now:12).first?.points.first?.rate,90)
        history.reset(client:"codex")
        XCTAssertEqual(history.snapshot(allowed:["codex","claudeCode"],mode:.bar,now:12).map(\.client),["claudeCode"])
    }
    func testMemoryIsBoundedWithoutAveraging() {
        var history = ActivityLiveHistory()
        for i in 0..<5000 { history.record(client:"codex",mode:.bar,rates:rates(Double(i)),at:Double(i)/100,available:true) }
        let points = history.snapshot(allowed:["codex"],mode:.bar,now:50).first!.points
        XCTAssertEqual(points.count,ActivityLiveHistory.pointLimit)
        XCTAssertEqual(points.last?.rate,4999)
    }
    func testCurvePreservesEveryPointAndHasNoInventedExtremaOrGapBridge() {
        let input = [ActivityLiveConnections.Point(x:0,y:10),.init(x:1,y:120),.init(x:2,y:30),.init(x:2.5,y:60),.init(x:7,y:100),.init(x:8,y:90)]
        let runs = ActivityLiveConnections.runs(input)
        XCTAssertEqual(runs.map(\.count),[4,2])
        for run in runs {
            let segments = ActivityLiveConnections.segments(run)
            XCTAssertEqual(segments.first?.start,run.first)
            XCTAssertEqual(segments.map(\.end),Array(run.dropFirst()))
            for segment in segments {
                for control in [segment.first,segment.second] {
                    XCTAssertGreaterThanOrEqual(control.y,min(segment.start.y,segment.end.y))
                    XCTAssertLessThanOrEqual(control.y,max(segment.start.y,segment.end.y))
                }
            }
        }
        XCTAssertEqual(ActivityLiveConnections.runs([.init(x:0,y:1),.init(x:1,y:.nan),.init(x:2,y:3)]).count,2)
    }
    @MainActor func testHomepageOldModelsAreGrayAndSavedOverridesWin() {
        let suite = "ActivityLiveHistoryTests."+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); SpeedColorOverrides.shared.replace(UserDefaults.standard.dictionary(forKey:SpeedDisplayPreferences.colorsKey) as? [String:String] ?? [:]) }
        let preferences = SpeedDisplayPreferences(defaults:defaults)
        SpeedColorOverrides.shared.replace([:])
        XCTAssertEqual(ModelUsagePresentation.dashboardColorHex(for:"gpt-5.6-luna",latest:false),"#87919e")
        XCTAssertEqual(ModelUsagePresentation.dashboardColorHex(for:"claude-sonnet-4-6",latest:false),"#87919e")
        XCTAssertEqual(ModelUsagePresentation.dashboardColorHex(for:"gpt-6-astra",latest:true),ModelUsagePresentation.colorHex(for:"gpt-6-astra"))
        preferences.setColor("#123456",for:"gpt-5.6-luna")
        XCTAssertEqual(ModelUsagePresentation.dashboardColorHex(for:"codex|gpt-5.6-luna",latest:false),"#123456")
        XCTAssertEqual(SpeedDisplayPreferences(defaults:defaults).colors["gpt-5.6-luna"],"#123456")
        preferences.setColor(nil,for:"gpt-5.6-luna")
        XCTAssertEqual(ModelUsagePresentation.dashboardColorHex(for:"gpt-5.6-luna",latest:false),"#87919e")
    }
}
