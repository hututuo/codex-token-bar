import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

@MainActor
final class DashboardContentLifetimeTests: XCTestCase {
    private final class Counts {
        var mounted = 0
        var dismantled = 0
        weak var probe: LifetimeProbe?
    }

    private final class LifetimeProbe: ObservableObject {}

    private struct ContentWithState: View {
        @StateObject private var probe = LifetimeProbe()
        let counts: Counts
        var body: some View {
            Content(counts: counts)
                .onAppear { counts.probe = probe }
        }
    }

    private struct Content: NSViewRepresentable {
        let counts: Counts
        func makeCoordinator() -> Counts { counts }
        func makeNSView(context: Context) -> NSView {
            counts.mounted += 1
            return NSView()
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
        static func dismantleNSView(_ nsView: NSView, coordinator: Counts) {
            coordinator.dismantled += 1
        }
    }

    func testHiddenWindowUnloadsContentAndReopeningRebuildsIt() async throws {
        NSApplication.shared.unhide(nil)
        let counts = Counts()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardContentLifetime { Content(counts: counts) })
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counts.mounted, 1)

        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertEqual(counts.dismantled, 1, "A hidden hosting tree must release its heavy content")

        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counts.mounted, 2, "The persistent shell must observe reopen and recreate content")
        XCTAssertEqual(counts.dismantled, 1)
    }

    func testQuickReopenCancelsPendingUnload() async throws {
        NSApplication.shared.unhide(nil)
        let counts = Counts()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardContentLifetime { Content(counts: counts) })
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        StartupPresentation.showExistingDashboardWindow(window)
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(counts.mounted, 1)
        XCTAssertEqual(counts.dismantled, 0, "An obsolete hidden-window task cannot unload visible content")
    }

    func testNativeCloseReleasesViewOwnedStateWhileWindowShellSurvives() async throws {
        NSApplication.shared.unhide(nil)
        let counts = Counts()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DashboardContentLifetime { ContentWithState(counts: counts) })
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(counts.probe)
        window.close()
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertNil(counts.probe, "A dismantled view must release its state objects, not just its native child")
        XCTAssertTrue(window.contentView === host, "The scene shell survives for normal reopening")
        // Exercise the production reopen operation. A native key/occlusion
        // change is not guaranteed for a previously closed window.
        NSApplication.shared.activate(ignoringOtherApps: true)
        StartupPresentation.showExistingDashboardWindow(window)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(counts.probe)
        XCTAssertEqual(counts.mounted, 2)
    }
}
