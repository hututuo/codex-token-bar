import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexRadarCompatibilityTests: XCTestCase {
    func testCountdownStaysInsideItsOpenSection() {
        let later = #"<section data-speed-window="closed"><time data-window-closes-at="2030-01-01T00:00:00Z"></time></section>"#
        XCTAssertNil(CodexRadarWindowCountdownParser.deadline(in: #"<section data-speed-window="open">No clock</section>"# + later))
        XCTAssertEqual(CodexRadarWindowCountdownParser.deadline(in: #"<section data-speed-window="open"><time data-window-closes-at="2029-01-01T00:00:00Z"></time></section>"# + later), "2029-01-01T00:00:00Z")
    }

    func testNestedSummaryWrappersRemainBounded() throws {
        let window: [String: Any] = ["window": ["open": true, "action": "use_window"]]
        let data = try JSONSerialization.data(withJSONObject: ["data": ["PAY-LOAD": window]])
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)
        XCTAssertEqual(snapshot.window.action, "use_window")
        var deeplyWrapped = window
        for _ in 0..<6 { deeplyWrapped = ["data": deeplyWrapped] }
        XCTAssertThrowsError(try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: JSONSerialization.data(withJSONObject: deeplyWrapped)))
    }

    func testFeedRejectsBrokenAndNonRSSDocumentsButAllowsAnEmptyFeed() throws {
        for xml in ["<rss><channel><item><title>truncated", "<rss><channel></rss>", "<html><body>maintenance</body></html>", "<rss/>"] {
            XCTAssertThrowsError(try CodexRadarFeedParser.parse(Data(xml.utf8)), xml)
        }
        XCTAssertEqual(try CodexRadarFeedParser.parse(Data("<?xml version=\"1.0\"?><rss><channel/></rss>".utf8)), [])
    }

    func testValidJSONDeadlineSkipsSupplementalHTMLAndClosedWindowsStayHidden() async throws {
        let counter = RadarCompatibilityRequestCounter()
        for open in [true, false] {
            let body = try JSONSerialization.data(withJSONObject: ["window": ["open": open, "action": "use_window", "countdown_deadline": "2030-01-01T00:00:00Z"]])
            let reader = LiveCodexRadarReader(transport: { request in
                (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, announcementTransport: { request in
                await counter.record()
                return (Data("<html>No announcement</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let snapshot = try await reader.readRadar()
            XCTAssertEqual(snapshot.window.countdownDeadline, "2030-01-01T00:00:00Z")
            if !open { XCTAssertNil(CodexRadarPresentationText.countdownDeadline(snapshot: snapshot)) }
        }
        let requests = await counter.count
        XCTAssertEqual(requests, 0)
    }

    @MainActor
    func testBrokenRSSPreservesCachedHistoryAndValidEmptyFeedClearsIt() async throws {
        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: Data(#"{"window":{"action":"wait"}}"#.utf8))
        let valid = "<rss><channel><item><title>Saved</title><link>https://example.invalid/item</link><guid>saved</guid><pubDate>Tue, 13 Oct 2026 00:00:00 GMT</pubDate><description>Saved reminder</description></item></channel></rss>"
        let store = CodexRadarStore(
            reader: RadarCompatibilityStaticReader(snapshot: snapshot),
            feedReader: RadarCompatibilitySequenceFeedReader([valid, "<rss><channel><item>", "<html><body>maintenance</body></html>", "<rss><channel/></rss>"]),
            crowdReader: RadarCompatibilityUnavailableCrowdReader()
        )
        for step in 0..<4 {
            store.refresh()
            for _ in 0..<100 {
                if !store.isRefreshing { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(store.isRefreshing)
            XCTAssertEqual(store.feedItems.map(\.guid), step == 3 ? [] : ["saved"])
            XCTAssertEqual(store.feedStaleDataDisplayed, step == 1 || step == 2)
            XCTAssertEqual(store.diagnostics.map(\.category), step == 1 || step == 2 ? [.rssFailure] : [])
        }
    }
}

private actor RadarCompatibilityRequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct RadarCompatibilityStaticReader: CodexRadarReading {
    let snapshot: CodexRadarSnapshot
    func readRadar() async throws -> CodexRadarSnapshot { snapshot }
}

private actor RadarCompatibilitySequenceFeedReader: CodexRadarFeedReading {
    private var documents: [String]
    init(_ documents: [String]) { self.documents = documents }
    func readFeed(from url: URL) async throws -> [CodexRadarFeedItem] {
        try CodexRadarFeedParser.parse(Data(documents.removeFirst().utf8))
    }
}

private struct RadarCompatibilityUnavailableCrowdReader: CodexCrowdRadarReading {
    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot { throw CodexRadarReaderError.emptyPayload }
}
