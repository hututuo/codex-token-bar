import XCTest
import SwiftUI
@testable import CodexTokenBar

final class QuotaSidebarSummaryTests: XCTestCase {
    func testResetLabelsUseLocalCalendarAnd24HourMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let reset = ISO8601DateFormatter().date(from: "2026-09-25T16:07:00Z")!
        XCTAssertEqual(QuotaSidebarResetTimePresentation.make(reset, calendar: calendar),
                       .init(date: "9/26", time: "00:07"))
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        XCTAssertEqual(QuotaSidebarResetTimePresentation.make(reset, calendar: calendar),
                       .init(date: "9/25", time: "09:07"))
        XCTAssertNil(QuotaSidebarResetTimePresentation.make(nil))
    }

    func testRecommendationPagesIncludeTailAndWrapWithoutDuplicatingRanks() {
        for count in 0...8 {
            let pages = QuotaSidebarRecommendationPaging.pageCount(count)
            let ranks = (0..<pages).flatMap { Array(QuotaSidebarRecommendationPaging.range(page: $0, count: count)) }
            XCTAssertEqual(ranks, Array(0..<count))
            XCTAssertEqual(QuotaSidebarRecommendationPaging.next(page: max(0, pages - 1), count: count), 0)
        }
        XCTAssertEqual(QuotaSidebarRecommendationPaging.range(page: 2, count: 8), 6..<8)
        XCTAssertEqual(QuotaSidebarRecommendationPaging.range(page: 3, count: 8), 0..<3)
        XCTAssertEqual(QuotaSidebarRecommendationPaging.range(page: 2, count: 2), 0..<2)
        XCTAssertEqual(QuotaSidebarRecommendationPaging.range(page: 0, count: 0), 0..<0)
        XCTAssertEqual(QuotaSidebarRecommendationPaging.interval, .seconds(4))
    }

    @MainActor
    func testResetLabelFitsInsideNativeRing() throws {
        let label = SidebarQuotaRingLabel(label: "7d", reset: .init(date: "12/31", time: "23:59"))
        let renderer = ImageRenderer(content: label.foregroundStyle(.white).fixedSize())
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertLessThanOrEqual(image.size.width, 34)
        XCTAssertLessThanOrEqual(image.size.height, 36)
        if let directory = ProcessInfo.processInfo.environment["CODEX_SIDEBAR_SUMMARY_PREVIEW_OUTPUT"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let preview = ImageRenderer(content: HStack(spacing: 14) {
                ForEach(["5h", "7d"], id: \.self) { text in
                    ZStack {
                        Circle().stroke(text == "5h" ? Color.green : Color.purple, lineWidth: 3)
                        SidebarQuotaRingLabel(label: text, reset: .init(date: "12/31", time: "23:59"))
                    }.frame(width: 46, height: 46)
                }
            }.foregroundStyle(.white).padding(16).background(Color(red: 0.035, green: 0.045, blue: 0.038)))
            preview.scale = 3
            let cgImage = try XCTUnwrap(preview.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("native-reset-rings.png"))
        }
    }
}
