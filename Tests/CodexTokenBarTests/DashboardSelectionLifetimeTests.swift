import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

@MainActor
final class DashboardSelectionLifetimeTests: XCTestCase {
    private final class Payload: ObservableObject {}
    private final class CapturedMenu {
        var binding: Binding<String>?
        weak var payload: Payload?
    }
    private struct Capture: NSViewRepresentable {
        let binding: Binding<String>
        let menu: CapturedMenu
        func makeNSView(context: Context) -> NSView {
            menu.binding = binding
            return NSView()
        }
        func updateNSView(_ view: NSView, context: Context) { menu.binding = binding }
    }
    private struct Page: View {
        @StateObject private var payload = Payload()
        @AppStorage private var selection: String
        let menu: CapturedMenu

        init(menu: CapturedMenu, defaults: UserDefaults) {
            self.menu = menu
            _selection = AppStorage(wrappedValue: "removed-client", "selection", store: defaults)
        }
        var body: some View {
            let effective = selection == "removed-client" ? "dashboard" : selection
            let binding = DashboardSelectionBinding.displayed(effective, storage: $selection)
            Picker("Client", selection: binding) {
                Text("Follow").tag("dashboard")
                Text("Antigravity").tag("antigravity")
            }
            .background(Capture(binding: binding, menu: menu))
            .onAppear { menu.payload = payload }
        }
    }

    func testRetainedMenuBindingDoesNotRetainClosedPageAndStillSavesSelection() async throws {
        let suite = "DashboardSelectionLifetime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = CapturedMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardContentLifetime {
            Page(menu: menu, defaults: defaults)
        })
        defer { window.close() }
        NSApplication.shared.unhide(nil)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(menu.payload)
        XCTAssertEqual(menu.binding?.wrappedValue, "dashboard")
        XCTAssertNil(defaults.string(forKey: "selection"), "Displaying a fallback must not overwrite the saved preference")

        window.close()
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertNotNil(menu.binding, "Model the native focus proxy retaining its menu binding")
        XCTAssertNil(menu.payload, "That proxy must not keep the page's state and source snapshots")
        menu.binding?.wrappedValue = "antigravity"
        XCTAssertEqual(defaults.string(forKey: "selection"), "antigravity")

        StartupPresentation.showExistingDashboardWindow(window)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(menu.payload)
        XCTAssertEqual(menu.binding?.wrappedValue, "antigravity")
    }

    func testNativeTrackingTeardownDropsCapturedContentEvenIfNativeViewsSurvive() {
        let hover = HoverTrackingArea.TrackingView()
        let outside = RecentChartOutsideClickMonitor.MonitoringView()
        weak var released: Payload?
        autoreleasepool {
            let payload = Payload()
            released = payload
            hover.onMove = { _ in withExtendedLifetime(payload) {} }
            hover.onClick = { _ in withExtendedLifetime(payload) {} }
            hover.onExit = { withExtendedLifetime(payload) {} }
            outside.onOutsideClick = { withExtendedLifetime(payload) {} }
        }
        XCTAssertNotNil(released)
        HoverTrackingArea.dismantleNSView(hover, coordinator: ())
        RecentChartOutsideClickMonitor.dismantleNSView(outside, coordinator: ())
        XCTAssertNil(released)
        XCTAssertNil(hover.onMove)
        XCTAssertNil(hover.onClick)
        XCTAssertNil(hover.onExit)
        XCTAssertNil(outside.onOutsideClick)
    }

    func testDismantledAccessibilityButtonsReleaseTheirActions() {
        let button = NSButton()
        let other = NSButton()
        weak var released: Payload?
        let activity = ActivityModeAccessibilityButtonRepresentation.Coordinator(action: {})
        let chart = RecentChartAccessibilityButtonRepresentation.Coordinator(action: {})
        autoreleasepool {
            let payload = Payload()
            released = payload
            activity.action = { withExtendedLifetime(payload) {} }
            chart.action = { withExtendedLifetime(payload) {} }
        }
        XCTAssertNotNil(released)
        ActivityModeAccessibilityButtonRepresentation.dismantleNSView(button, coordinator: activity)
        RecentChartAccessibilityButtonRepresentation.dismantleNSView(other, coordinator: chart)
        XCTAssertNil(released)
        activity.performAction()
        chart.performAction()
        XCTAssertNil(button.target)
        XCTAssertNil(other.target)
    }
}
