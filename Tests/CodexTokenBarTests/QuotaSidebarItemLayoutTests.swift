import AppKit
import XCTest
@testable import CodexTokenBar

final class QuotaSidebarItemLayoutTests: XCTestCase {
    func testMigrationSplitsOldBlocksAndPreservesClientOrderAndVisibility() {
        let value = QuotaSidebarItemLayout.migrate(
            moduleOrder: [.tasks, .overview, .speeds, .modeltrace, .radar, .credits, .clientUsage],
            hiddenModules: [.overview, .speeds, .clientUsage],
            quotaWindowOrder: ["claudeCode:7d", "codex:7d", "claudeCode:5h"])
        XCTAssertEqual(Array(value.order.prefix(6)), ["tasks", "quota:claudeCode", "quota:codex", "models", "speed", "tps"])
        for item in [QuotaSidebarItem.speed, .tps, .quota("codex"), .quota("claudeCode"), .models, .clientUsage] {
            XCTAssertFalse(value.isVisible(item))
        }
        XCTAssertTrue(value.isVisible(.tasks))
    }

    func testReorderAndVisibilityHaveOneProjectionForBothLevels() {
        let quotas = ClientQuotaProjection.previewItems(includeClaude: true)
        var value = QuotaSidebarItemLayout()
        value.move(.quota("claudeCode"), relativeTo: .speed, after: false)
        var items = value.arranged(availableQuotaClients: ["codex", "claudeCode"]).filter(value.isVisible)
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items: items, quotas: quotas), ["claudeCode:5h", "claudeCode:7d", "speed", "codex:7d", "models"])
        value.hidden.insert(QuotaSidebarItem.quota("claudeCode").id)
        items = value.arranged(availableQuotaClients: ["codex", "claudeCode"]).filter(value.isVisible)
        XCTAssertFalse(items.contains(.quota("claudeCode")))
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items: items, quotas: quotas), ["speed", "codex:7d", "models"])
        value.hidden.insert(QuotaSidebarItem.tps.id)
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items: items.filter(value.isVisible), quotas: quotas), ["speed", "codex:7d", "models"])
    }

    func testTemporaryMissingClientDoesNotEraseItsPlacementOrHiddenChoice() throws {
        var value = QuotaSidebarItemLayout()
        value.move(.quota("claudeCode"), relativeTo: .speed, after: false)
        value.hidden.insert("quota:claudeCode")
        XCTAssertFalse(value.arranged(availableQuotaClients: ["codex"]).contains(.quota("claudeCode")))
        let restored = try XCTUnwrap(QuotaSidebarItemLayout.decode(try JSONEncoder().encode(value)))
        XCTAssertEqual(restored, value)
        XCTAssertEqual(restored.arranged(availableQuotaClients: ["codex", "claudeCode"]).firstIndex(of: .quota("claudeCode")), 1)
        XCTAssertFalse(restored.isVisible(.quota("claudeCode")))
    }

    func testNewQuotaClientAppendsOnceAndInvalidOrFutureVersionDoesNotDecode() throws {
        let value = QuotaSidebarItemLayout()
        let items = value.arranged(availableQuotaClients: ["codex", "gemini", "gemini"])
        XCTAssertEqual(items.filter { $0 == .quota("gemini") }.count, 1)
        XCTAssertEqual(items[try XCTUnwrap(items.firstIndex(of: .models)) - 1], .quota("gemini"))
        XCTAssertNil(QuotaSidebarItem(id: "quota:../account"))
        XCTAssertNil(QuotaSidebarItem(id: "quota:"))
        XCTAssertNil(QuotaSidebarItemLayout.decode(Data(#"{"version":2,"order":[],"hidden":[]}"#.utf8)))
    }

    func testWindowOrderAndSingleWindowRingRemainStableAfterGroupMoves() {
        let fixtures = ClientQuotaProjection.previewItems(includeClaude: true)
        let windows = QuotaSidebarContentOrder.quotaWindows(Array(fixtures.reversed()), client: "claudeCode")
        XCTAssertEqual(windows.map(\.window), ["5h", "7d"])
        XCTAssertEqual(ClientQuotaRingGroup.make(windows).first?.left.window, "5h")
        XCTAssertEqual(ClientQuotaRingGroup.make(windows).first?.right?.window, "7d")
        XCTAssertNil(ClientQuotaRingGroup.make(fixtures.filter { $0.client == "codex" }).first?.right)
    }

    @MainActor func testControllerMigratesWithoutOverwritingOldPreferencesAndRestoresEdits() throws {
        let suite = "LinkedSidebar-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldOrder = ["tasks", "overview", "speeds"]
        let oldHidden = ["radar"]
        var oldQuota = ClientQuotaSelection()
        oldQuota.order = ["claudeCode:7d", "codex:7d"]
        oldQuota.colors = ["codex:7d": "#123456"]
        defaults.set(oldOrder, forKey: "quotaSidebarModuleOrder")
        defaults.set(oldHidden, forKey: "quotaSidebarHiddenModules")
        defaults.set(oldQuota.encoded, forKey: ClientQuotaSelection.key)
        let controller = QuotaSidebarController(settings: defaults)
        XCTAssertNotNil(defaults.data(forKey: QuotaSidebarItemLayout.key))
        XCTAssertEqual(Array(controller.sidebarLayout.order.prefix(3)), ["tasks", "quota:claudeCode", "quota:codex"])
        controller.moveSidebarItem(.quota("codex"), relativeTo: .tasks, after: false)
        controller.setSidebarItemVisible(.speed, visible: false)
        XCTAssertTrue(controller.sidebarLayout.isVisible(.tps), "Live speed and body TPS are independently visible")
        let restored = QuotaSidebarController(settings: defaults)
        XCTAssertEqual(restored.sidebarLayout, controller.sidebarLayout)
        XCTAssertEqual(defaults.stringArray(forKey: "quotaSidebarModuleOrder"), oldOrder)
        XCTAssertEqual(defaults.stringArray(forKey: "quotaSidebarHiddenModules"), oldHidden)
        XCTAssertEqual(defaults.string(forKey: ClientQuotaSelection.key), oldQuota.encoded)
        restored.resetSidebarItemOrder()
        XCTAssertFalse(restored.sidebarLayout.isVisible(.speed))
    }

    @MainActor func testReusableDragHandleAcceptsFirstMouseInNonactivatingPanel() {
        XCTAssertTrue(FloatingStructureDragSourceView().acceptsFirstMouse(for: nil))
    }
}
