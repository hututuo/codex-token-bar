import XCTest
@testable import CodexTokenBar

final class QuotaSidebarModuleOrderTests: XCTestCase {
    @MainActor func testNewUsageModuleDefaultsHiddenAndPersistsExplicitChoice() throws {
        let name = "SidebarUsageModule-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["radar"], forKey: "quotaSidebarHiddenModules")
        defaults.set(["tasks", "overview"], forKey: "quotaSidebarModuleOrder")
        let first = QuotaSidebarController(settings: defaults)
        XCTAssertFalse(first.isModuleVisible(.clientUsage))
        XCTAssertFalse(first.isModuleVisible(.radar))
        XCTAssertEqual(Array(first.moduleOrder.prefix(2)), [.tasks, .overview])
        first.setModuleVisible(.clientUsage, visible: true)
        first.moveModule(.clientUsage, by: -1)
        let restored = QuotaSidebarController(settings: defaults)
        XCTAssertTrue(restored.isModuleVisible(.clientUsage))
        XCTAssertEqual(restored.moduleOrder, first.moduleOrder)
        restored.setModuleVisible(.clientUsage, visible: false)
        XCTAssertFalse(QuotaSidebarController(settings: defaults).isModuleVisible(.clientUsage))
    }

    func testOrderMigrationKeepsUniqueKnownModulesAndAppendsNewOnes() {
        XCTAssertEqual(QuotaSidebarDetail.normalizedModuleOrder([]), [.modeltrace, .speeds, .overview, .tasks, .radar, .credits, .clientUsage])
        XCTAssertEqual(QuotaSidebarDetail.normalizedModuleOrder(["radar", "settings", "missing", "radar", "tasks"]), [.radar, .tasks, .modeltrace, .speeds, .overview, .credits, .clientUsage])
    }

    @MainActor
    func testReorderingPersistsIndependentlyOfHiddenModulesAndSettingsRemainsReachable() throws {
        let suite = "SidebarOrder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = QuotaSidebarController(settings: defaults)
        XCTAssertEqual(controller.moduleOrder.first, .modeltrace)
        controller.setModuleVisible(.modeltrace, visible: false)
        controller.moveModule(.modeltrace, by: 1)
        XCTAssertEqual(Array(controller.moduleOrder.prefix(2)), [.speeds, .modeltrace])
        var restored = QuotaSidebarController(settings: defaults)
        XCTAssertEqual(restored.moduleOrder, controller.moduleOrder)
        XCTAssertFalse(restored.isModuleVisible(.modeltrace))
        controller.setModuleVisible(.modeltrace, visible: true)
        XCTAssertEqual(Array(controller.moduleOrder.prefix(2)), [.speeds, .modeltrace])
        controller.moveModule(.speeds, by: -1)
        XCTAssertEqual(Array(controller.moduleOrder.prefix(2)), [.speeds, .modeltrace])
        for module in QuotaSidebarDetail.defaultModuleOrder { controller.setModuleVisible(module, visible: false) }
        controller.setModuleVisible(.settings, visible: false)
        restored = QuotaSidebarController(settings: defaults)
        XCTAssertTrue(QuotaSidebarDetail.defaultModuleOrder.allSatisfy { !restored.isModuleVisible($0) })
        XCTAssertTrue(restored.isModuleVisible(.settings))
        restored.select(.settings)
        XCTAssertEqual(restored.interaction.detail, .settings)
        controller.resetModuleOrder()
        restored = QuotaSidebarController(settings: defaults)
        XCTAssertEqual(restored.moduleOrder, QuotaSidebarDetail.defaultModuleOrder)
        XCTAssertTrue(QuotaSidebarDetail.defaultModuleOrder.allSatisfy { !restored.isModuleVisible($0) })
    }
}
