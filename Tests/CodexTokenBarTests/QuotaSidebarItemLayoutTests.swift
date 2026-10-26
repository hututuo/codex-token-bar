import AppKit
import XCTest
@testable import CodexTokenBar

final class QuotaSidebarItemLayoutTests: XCTestCase {
    func testSettingsCompareLayoutShowsBothLevelsAndMirrorsWithoutLeavingTheScreen() throws {
        for area in [CGRect(x: 0, y: 23, width: 1440, height: 877), CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            for edge in [QuotaSidebarEdge.left, .right] {
                let normal = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true)
                let editing = QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: true, compactHeight: 366, settingsPreview: true)
                let compact = try XCTUnwrap(editing.compactPreview)
                for rect in [compact, editing.rail, editing.detail] { XCTAssertTrue(area.contains(rect)) }
                XCTAssertEqual(compact.width, 16)
                XCTAssertEqual(abs(normal.rail.minX - editing.rail.minX), 24)
                XCTAssertEqual(edge == .left ? compact.maxX + 8 : editing.rail.maxX + 8, edge == .left ? editing.rail.minX : compact.minX)
                XCTAssertTrue(editing.contains(CGPoint(x: compact.midX, y: compact.midY), detailVisible: true))
                XCTAssertNil(normal.compactPreview)
                XCTAssertNil(QuotaSidebarFrames.make(usableFrame: area, edge: edge, expanded: false, settingsPreview: true).compactPreview)
            }
        }
        let tiny = CGRect(x: 0, y: 0, width: 90, height: 180)
        let narrow = QuotaSidebarFrames.make(usableFrame: tiny, edge: .left, expanded: true, settingsPreview: true)
        XCTAssertNil(narrow.compactPreview)
        XCTAssertTrue(tiny.contains(narrow.rail))
    }
    func testLegacyHiddenItemCanEnableOneLevelWithoutEnablingTheOther() throws {
        let raw = Data(##"{"version":1,"order":["quota:codex"],"hidden":["quota:codex","clientUsage"]}"##.utf8)
        var value = try XCTUnwrap(QuotaSidebarItemLayout.decode(raw))
        XCTAssertFalse(value.isVisible(.quota("codex"), in: .compact))
        XCTAssertFalse(value.isVisible(.quota("codex"), in: .expanded))
        value.setVisible(.quota("codex"), in: .compact, visible: true)
        XCTAssertTrue(value.isVisible(.quota("codex"), in: .compact))
        XCTAssertFalse(value.isVisible(.quota("codex"), in: .expanded))
        value.setVisible(.quota("codex"), in: .expanded, visible: true)
        value.setVisible(.quota("codex"), in: .compact, visible: false)
        XCTAssertFalse(value.isVisible(.quota("codex"), in: .compact))
        XCTAssertTrue(value.isVisible(.quota("codex"), in: .expanded))
        value.setVisible(.clientUsage, in: .expanded, visible: true)
        XCTAssertFalse(value.isVisible(.clientUsage, in: .compact), "No invented first-level representation")
        XCTAssertTrue(value.isVisible(.clientUsage, in: .expanded))
        let restored = try XCTUnwrap(QuotaSidebarItemLayout.decode(JSONEncoder().encode(value)))
        XCTAssertEqual(restored, value)
        value.move(.quota("codex"), relativeTo: .tasks, after: true)
        XCTAssertEqual(value.hiddenCompact, restored.hiddenCompact)
        XCTAssertEqual(value.hiddenExpanded, restored.hiddenExpanded)
    }
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
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items: items, quotas: quotas), ["modeltrace", "claudeCode:5h", "claudeCode:7d", "speed", "tps", "codex:7d", "models", "tasks", "radar", "credits"])
        value.hidden.insert(QuotaSidebarItem.quota("claudeCode").id)
        items = value.arranged(availableQuotaClients: ["codex", "claudeCode"]).filter(value.isVisible)
        XCTAssertFalse(items.contains(.quota("claudeCode")))
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items: items, quotas: quotas), ["modeltrace", "speed", "tps", "codex:7d", "models", "tasks", "radar", "credits"])
        value.hidden.insert(QuotaSidebarItem.tps.id)
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items: items.filter(value.isVisible), quotas: quotas), ["modeltrace", "speed", "codex:7d", "models", "tasks", "radar", "credits"])
    }

    func testCompactDotsUseSameOrderAndOnlySixPointsOfHeight() {
        let items: [QuotaSidebarItem] = [.modeltrace, .speed, .tps]
        XCTAssertTrue(items.allSatisfy(\.hasCompactRepresentation))
        XCTAssertEqual(items.filter(\.usesCompactDot), [.modeltrace, .tps])
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items: items, quotas: []), ["modeltrace", "speed", "tps"])
        XCTAssertEqual(ClientRailLayout.fixed(trackCount: 3, dotCount: 2, availableHeight: 900).height, 112)
        var layout = QuotaSidebarItemLayout()
        layout.setVisible(.tps, in: .compact, visible: false)
        XCTAssertFalse(layout.isVisible(.tps, in: .compact))
        XCTAssertTrue(layout.isVisible(.tps, in: .expanded))
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
        let oldQuotaRaw = oldQuota.encoded
        defaults.set(oldQuotaRaw, forKey: ClientQuotaSelection.key)
        let controller = QuotaSidebarController(settings: defaults)
        XCTAssertNotNil(defaults.data(forKey: QuotaSidebarItemLayout.key))
        XCTAssertEqual(Array(controller.sidebarLayout.order.prefix(3)), ["tasks", "quota:claudeCode", "quota:codex"])
        controller.moveSidebarItem(.quota("codex"), relativeTo: .tasks, after: false)
        controller.setSidebarItemVisible(.speed, visible: false)
        controller.setSidebarItemVisible(.speed, in: .compact, visible: true)
        XCTAssertTrue(controller.sidebarLayout.isVisible(.speed, in: .compact))
        XCTAssertFalse(controller.sidebarLayout.isVisible(.speed, in: .expanded))
        XCTAssertTrue(controller.sidebarLayout.isVisible(.tps), "Live speed and body TPS are independently visible")
        let restored = QuotaSidebarController(settings: defaults)
        XCTAssertEqual(restored.sidebarLayout, controller.sidebarLayout)
        XCTAssertEqual(defaults.stringArray(forKey: "quotaSidebarModuleOrder"), oldOrder)
        XCTAssertEqual(defaults.stringArray(forKey: "quotaSidebarHiddenModules"), oldHidden)
        XCTAssertEqual(defaults.string(forKey: ClientQuotaSelection.key), oldQuotaRaw)
        restored.resetSidebarItemOrder()
        XCTAssertTrue(restored.sidebarLayout.isVisible(.speed, in: .compact))
        XCTAssertFalse(restored.sidebarLayout.isVisible(.speed, in: .expanded))
    }

    @MainActor func testReusableDragHandleAcceptsFirstMouseInNonactivatingPanel() {
        XCTAssertTrue(FloatingStructureDragSourceView().acceptsFirstMouse(for: nil))
    }
}
