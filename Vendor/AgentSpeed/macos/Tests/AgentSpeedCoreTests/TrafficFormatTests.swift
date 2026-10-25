import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Traffic formatting")
struct TrafficFormatTests {
    @Test func everyFixtureCase() throws {
        let rows = try #require(try Fixtures.json("traffic-cases.json")["format"] as? [[String: Any]])
        #expect(rows.count >= 20)
        for row in rows {
            let value = try #require(row.double("value"))
            let text = try #require(row.string("text"))
            let got = switch row.string("kind") {
            case "total": TrafficFormat.total(value)
            case "bits": TrafficFormat.rate(value, bits: true)
            default: TrafficFormat.rate(value)
            }
            #expect(got == text.replacingOccurrences(of: " ", with: "\u{00A0}"), "\(row)")
        }
    }

    @Test func partsSplitNumberAndUnit() {
        #expect(TrafficFormat.rateParts(12_400_000) == .init(number: "12.4", unit: "MB/s"))
        #expect(TrafficFormat.totalParts(512) == .init(number: "512", unit: "B"))
        #expect(TrafficFormat.rateParts(.nan) == .init(number: "0", unit: "B/s"))
        #expect(TrafficFormat.rateParts(-5) == .init(number: "0", unit: "B/s"))
    }
}
