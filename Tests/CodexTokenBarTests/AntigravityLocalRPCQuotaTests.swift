import Foundation
import XCTest
@testable import CodexTokenBar

final class AntigravityLocalRPCQuotaTests: XCTestCase {
    func testAutomaticVisibilityRequiresRecentQuotaAndRespectsManualChoices() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for client in ["claudeCode", "claudeDesktop", "antigravity"] {
            for (age, expected) in [(0.0, true), (259_200, true), (259_201, false), (-60, true), (-61, false)] {
                let reading = ClientQuotaReading(client: client, state: "stale", source: "fixture", windows: [], notice: "",
                    capturedAt: now.addingTimeInterval(-age))
                XCTAssertEqual(ClientQuotaPresentation.shouldAutomaticallyShow(reading, now: now), expected, "\(client) age \(age)")
            }
        }
        for state in ["api", "invalid", "unavailable", "notConnected", "missing"] {
            let reading = ClientQuotaReading(client: "claudeCode", state: state, source: "fixture", windows: [], notice: "", capturedAt: now)
            XCTAssertFalse(ClientQuotaPresentation.shouldAutomaticallyShow(reading, now: now))
        }
        let reading = ClientQuotaReading(client: "claudeCode", state: "available", source: "fixture",
            windows: [.init(label: "5h", usedPercent: 90.8865, resetsAt: nil)], notice: "", capturedAt: now)
        let item = try XCTUnwrap(ClientQuotaProjection.items(codex: .empty, localReadings: [reading], now: now).first { $0.client == "claudeCode" })
        var selection = ClientQuotaSelection()
        XCTAssertTrue(selection.includes(item), "First valid recent observation appears without transcript opt-in")
        selection.hidden.insert(item.id)
        XCTAssertFalse(selection.includes(item), "Automatic detection must not undo a manual hide")
        let api = ClientQuotaReading(client: "claudeCode", state: "api", source: "fixture", windows: [], notice: "")
        let apiItem = try XCTUnwrap(ClientQuotaProjection.items(codex: .empty, localReadings: [api], now: now).first { $0.client == "claudeCode" })
        XCTAssertFalse(selection.includes(apiItem))
        selection.enabled.insert(apiItem.id)
        XCTAssertTrue(selection.includes(apiItem), "Explicit display choice remains possible")
        XCTAssertTrue(ClientQuotaProjection.items(codex: .empty, localReadings: []).allSatisfy { !ClientQuotaSelection().includes($0) })
    }

    func testQuotaTextPreservesTwoFractionalDigitsWithoutPaddingIntegers() {
        for (number, expected) in [(9.1135, "9.11"), (12.5, "12.5"), (0.1, "0.1"), (100.0, "100"), (0.0, "0")] {
            let item = ClientQuotaItem(id: "fixture", client: "antigravity", window: "Gemini", remaining: number,
                resetsAt: nil, source: "fixture", status: "")
            XCTAssertEqual(item.compactValue, expected)
            XCTAssertEqual(item.value, expected + "%")
            XCTAssertEqual(item.accessibleValue, expected + "%")
        }
    }

    func testSharedRPCFixturesKeepExplicitFractionsResetsAndPrivacy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/antigravity-quota-summary.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for row in try XCTUnwrap(fixture["cases"] as? [[String: Any]]) {
            let reading = AntigravityLocalRPCQuota.decode(try JSONSerialization.data(withJSONObject: row["data"]!),
                now: Date(timeIntervalSince1970: try XCTUnwrap(row["now"] as? Double)))
            XCTAssertEqual(reading.state, row["expectedState"] as? String, row["name"] as? String ?? "")
            XCTAssertEqual(reading.windows.map { $0.id ?? "" }, row["ids"] as? [String])
            let used = try XCTUnwrap(row["used"] as? [Double])
            XCTAssertEqual(reading.windows.count, used.count)
            for (window, value) in zip(reading.windows, used) { XCTAssertEqual(window.usedPercent, value, accuracy: 0.000001) }
            XCTAssertFalse(String(describing: reading).contains("DO-NOT-PROJECT"))
        }
        XCTAssertEqual(AntigravityLocalRPCQuota.decode(Data(repeating: 32, count: 524_289), now: Date()).state, "unavailable")
    }

    func testDiscoveryRequiresInstalledProcessOwnedLoopbackPortAndCSRF() throws {
        let path = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
        let args = path + " --standalone --https_server_port 0 --csrf_token 00000000-0000-0000-0000-000000000001"
        let log = "I server.go] Language server listening on random port at 53100 for HTTPS (gRPC)"
        let listeners = "p42\nn127.0.0.1:53100\n"
        XCTAssertEqual(AntigravityLocalRPCQuota.runningServers("42 \(path)\n43 /tmp/language_server", home: URL(fileURLWithPath: "/fixture")).count, 1)
        let endpoint = try XCTUnwrap(AntigravityLocalRPCQuota.endpoint(pid: 42, executable: path, commandLine: args, listeners: listeners, logPrefix: log))
        XCTAssertEqual(endpoint.port, 53100)
        for badListeners in ["p42\nn*:53100", "p41\nn127.0.0.1:53100"] {
            XCTAssertNil(AntigravityLocalRPCQuota.endpoint(pid: 42, executable: path, commandLine: args, listeners: badListeners, logPrefix: log))
        }
        XCTAssertNil(AntigravityLocalRPCQuota.endpoint(pid: 42, executable: path, commandLine: args, listeners: listeners, logPrefix: "no current port"))
        XCTAssertNil(AntigravityLocalRPCQuota.endpoint(pid: 42, executable: path, commandLine: args.replacingOccurrences(of: "--standalone", with: "--other"), listeners: listeners, logPrefix: log))
        let request = try XCTUnwrap(AntigravityLocalRPCQuota.request(endpoint))
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/RetrieveUserQuotaSummary") == true)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["forceRefresh"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
}
