import XCTest
@testable import CodexTokenBar

final class QuotaSidebarModuleOrderTests: XCTestCase {
    func testOrderMigrationKeepsUniqueKnownModulesAndAppendsNewOnes() {
        XCTAssertEqual(QuotaSidebarDetail.normalizedModuleOrder([]), [.modeltrace, .speeds, .overview, .tasks, .radar, .credits])
        XCTAssertEqual(QuotaSidebarDetail.normalizedModuleOrder(["radar", "settings", "missing", "radar", "tasks"]), [.radar, .tasks, .modeltrace, .speeds, .overview, .credits])
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
