import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

@MainActor
final class DashboardContentLifetimeTests: XCTestCase {
    private final class Counts {
        var mounted = 0
        var dismantled = 0
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
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(counts.mounted, 1)
        XCTAssertEqual(counts.dismantled, 0, "An obsolete hidden-window task cannot unload visible content")
    }
}
