import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class CompactRunningTaskLayoutTests: XCTestCase {
    @MainActor
    func testCompactTaskHierarchyKeepsTenChildrenReadableWithinOnePanel() throws {
        let children = (0..<10).map { index in RunningThreadMember(threadID: "child-\(index)",
            title: "James · windows_model_scroll_inventory_\(index)", model: "gpt-6-luna", reasoningEffort: "max") }
        let main = RunningThreadMember(threadID: "main", title: "修复模型费用与运行任务菜单，保留历史账目和任务归属",
            model: "gpt-6-astra", reasoningEffort: "max", client: "codex")
        let view = SidebarRunningTaskGroup(group: .init(mainThread: main, subagents: children), showClient: true)
            .frame(width: 380).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 340, "Ten children must not become ten tall cards")
        XCTAssertGreaterThan(host.fittingSize.height, 260)
        let row = NSHostingView(rootView: SidebarRunningChildRow(member: children[0]).frame(width: 360))
        XCTAssertEqual(row.fittingSize.height, 26, accuracy: 0.5)
        XCTAssertTrue(SidebarTaskPresentation.detail(children[0], child: true).contains("windows_model_scroll_inventory"))
        XCTAssertTrue(SidebarTaskPresentation.detail(children[0]).contains("Luna6"))
        XCTAssertFalse(SidebarTaskPresentation.detail(children[0]).contains("gpt-6-luna"))
        if let output = ProcessInfo.processInfo.environment["CODEX_CYCLE_LAYOUT_OUTPUT"] {
            let renderer = ImageRenderer(content: view.padding(12).background(Color.black))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("compact-running-task-hierarchy.png"))
        }
    }
}
