import XCTest
@testable import CodexTokenBar

final class OfflineClientQuotaTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/local-quota-caches.json"))) as? [String: Any])
    }

    func testSharedHTTPFixturesValidateIntegrityAgeEncodingAndRealZero() throws {
        let cases = try XCTUnwrap(try fixture()["claude"] as? [[String: Any]])
        for row in cases {
            let name = try XCTUnwrap(row["name"] as? String)
            let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(row["entryBase64"] as? String)))
            let now = Date(timeIntervalSince1970: try XCTUnwrap(row["now"] as? Double))
            let reading = ClaudeDesktopHTTPCache.decode(bytes, now: now)
            XCTAssertEqual(reading?.state, row["expectedState"] as? String, name)
            XCTAssertEqual(reading?.fiveHour?.usedPercent, row["five"] as? Double, name)
            XCTAssertEqual(reading?.sevenDay?.usedPercent, row["seven"] as? Double, name)
            if reading?.state == "available" {
                XCTAssertEqual(reading?.source, "local-desktop-http-cache")
                XCTAssertNotNil((reading?.fiveHour ?? reading?.sevenDay)?.resetsAt, name)
            }
            var corrupt = bytes; corrupt.removeLast()
            XCTAssertNil(ClaudeDesktopHTTPCache.decode(corrupt, now: now), name)
        }
    }

    func testSharedAntigravityFixturesKeepModelPoolsAndAccountBoundary() throws {
        for row in try XCTUnwrap(try fixture()["antigravityTools"] as? [[String: Any]]) {
            let reading = AntigravityLocalQuota.decodeTools(try JSONSerialization.data(withJSONObject: row["data"]!),
                selectedID: try XCTUnwrap(row["selectedID"] as? String), now: Date(timeIntervalSince1970: try XCTUnwrap(row["now"] as? Double)))
            XCTAssertEqual(reading.state, row["expectedState"] as? String, row["name"] as? String ?? "")
            XCTAssertEqual(reading.windows.map(\.usedPercent), row["used"] as? [Double])
            XCTAssertFalse(String(describing: reading).contains("DO-NOT-PROJECT"))
        }
        for row in try XCTUnwrap(try fixture()["antigravityState"] as? [[String: Any]]) {
            let reading = AntigravityLocalQuota.decodeState(Data(try XCTUnwrap(row["data"] as? String).utf8),
                now: Date(timeIntervalSince1970: try XCTUnwrap(row["now"] as? Double)))
            XCTAssertEqual(reading.state, row["expectedState"] as? String)
            XCTAssertEqual(reading.windows.map(\.usedPercent), row["used"] as? [Double])
            XCTAssertNil(reading.capturedAt, "DB mtime is not a quota sample timestamp")
            XCTAssertTrue(ClientQuotaProjection.items(codex: .empty, localReadings: [reading])
                .filter { $0.client == "antigravity" }.allSatisfy { $0.remaining == nil })
        }
    }

    func testNewerObservationNeverBorrowsAnotherAccountsMissingWindow() {
        let old = ClaudeLocalQuota(state: "available", capturedAt: Date(timeIntervalSince1970: 100),
            fiveHour: .init(usedPercent: 70, resetsAt: nil), sevenDay: nil)
        let new = ClaudeLocalQuota(state: "available", capturedAt: Date(timeIntervalSince1970: 200),
            fiveHour: nil, sevenDay: .init(usedPercent: 30, resetsAt: Date(timeIntervalSince1970: 500)), source: "local-desktop-http-cache")
        let selected = ClaudeLocalQuota.desktopObservation(history: old, cache: new)
        XCTAssertNil(selected.fiveHour); XCTAssertEqual(selected.sevenDay?.usedPercent, 30)
        let reading = ClaudeCapturedQuotaProvider(snapshot: selected, client: .claudeDesktop).reading()
        XCTAssertEqual(reading.windows.first?.resetsAt, Date(timeIntervalSince1970: 500))
        XCTAssertFalse(reading.notice.contains("重置时间未知"))
        let invalid = ClaudeLocalQuota(state: "invalid", capturedAt: Date(timeIntervalSince1970: 300), fiveHour: nil, sevenDay: nil, source: new.source)
        XCTAssertEqual(ClaudeLocalQuota.desktopObservation(history: old, cache: invalid).state, "invalid")
    }

    func testReaderUsesOnlySelectedToolsAccountWithoutWritingOrFollowingSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("accounts"), withIntermediateDirectories: true)
        let row = try XCTUnwrap(try fixture()["antigravityTools"] as? [[String: Any]]).first!
        let bytes = try JSONSerialization.data(withJSONObject: row["data"]!)
        let file = directory.appendingPathComponent("accounts/selected-fixture.json")
        try bytes.write(to: file)
        let index = directory.appendingPathComponent("accounts.json")
        try Data("{\"current_account_id\":\"selected-fixture\",\"accounts\":[{\"id\":\"selected-fixture\"}]}".utf8).write(to: index)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AntigravityLocalQuota.readTools(directory: directory, now: now).state, "available")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let target = directory.appendingPathComponent("unselected.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertEqual(AntigravityLocalQuota.readTools(directory: directory, now: now).state, "unavailable")
        try Data("{\"current_account_id\":\"../unselected\",\"accounts\":[{\"id\":\"../unselected\"}]}".utf8).write(to: index)
        XCTAssertEqual(AntigravityLocalQuota.readTools(directory: directory, now: now).state, "unavailable")
    }

    func testAntigravityProjectionReachesAllSurfacesAndStaleCacheIsNotCurrent() {
        let reading = ClientQuotaReading(client: "antigravity", state: "available", source: "local-antigravity-tools",
            windows: [.init(label: "Argon 4", usedPercent: 30, resetsAt: nil, id: "gemini-4-argon"),
                      .init(label: "Opus 5.5", usedPercent: 100, resetsAt: nil, id: "claude-opus-5-5")], notice: "离线缓存")
        let items = ClientQuotaProjection.items(codex: .empty, localReadings: [reading]).filter { $0.client == "antigravity" }
        XCTAssertEqual(items.map(\.remaining), [70, 0]); XCTAssertEqual(items.map(\.id), ["antigravity:gemini-4-argon", "antigravity:claude-opus-5-5"])
        XCTAssertTrue(items.allSatisfy(ClientQuotaSelection().includes))
        let stale = ClientQuotaReading(client: reading.client, state: "stale", source: reading.source, windows: reading.windows, notice: "历史缓存")
        let old = ClientQuotaProjection.items(codex: .empty, localReadings: [stale]).filter { $0.client == "antigravity" }
        XCTAssertEqual(old.count, 1); XCTAssertNil(old.first?.remaining); XCTAssertEqual(old.first?.status, "额度采样已过期")
    }

    func testDesktopCLIAndInstalledAntigravityKeepIndependentVisibleQuotaStates() throws {
        let desktop = ClaudeCapturedQuotaProvider(snapshot: .init(state: "available", capturedAt: Date(),
            fiveHour: .init(usedPercent: 13, resetsAt: nil), sevenDay: nil), client: .claudeDesktop).reading()
        let cli = ClaudeCapturedQuotaProvider(snapshot: .init(state: "api", capturedAt: nil, fiveHour: nil, sevenDay: nil)).reading()
        let ag = AntigravityLocalQuota.empty()
        let items = ClientQuotaProjection.items(codex: .empty, localReadings: [desktop, cli, ag]).filter { $0.client != "codex" }
        XCTAssertEqual(items.map(\.id), ["claudeDesktop:5h", "claudeCode:api", "antigravity:status"])
        XCTAssertEqual(items.map(\.remaining), [87, nil, nil])
        XCTAssertEqual(items.map(\.compactValue), ["87", "API", "待"])
        XCTAssertEqual(items.last?.accessibleValue, "额度未接入")
        XCTAssertTrue(ClientQuotaPresentation.isPresent(cli))
        XCTAssertFalse(ClientQuotaPresentation.isPresent(ag))
        XCTAssertTrue(ClientQuotaPresentation.isPresent(ag, detected: true))
        XCTAssertFalse(ClientQuotaPresentation.isPresent(UnavailableClientQuotaProvider(client: .gemini).reading(), detected: true))
        let stale = ClaudeCapturedQuotaProvider(snapshot: .init(state: "stale", capturedAt: Date(), fiveHour: nil, sevenDay: nil)).reading()
        let cached = try XCTUnwrap(ClientQuotaProjection.items(codex: .empty, localReadings: [stale]).last)
        XCTAssertEqual(stale.state, "stale")
        XCTAssertEqual(cached.compactValue, "旧")
        XCTAssertNil(cached.remaining)
    }
}
