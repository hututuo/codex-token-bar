import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

@MainActor
private final class ScrollRowObservation {
    var constructed: Set<Int> = []
}

private struct ObservedScrollRow: View {
    let index: Int
    let observation: ScrollRowObservation
    var body: some View {
        observation.constructed.insert(index)
        return Text("Synthetic dashboard section \(index)")
            .frame(height: 100)
    }
}

final class DashboardScrollLayoutTests: XCTestCase {
    @MainActor
    func testDefaultScaleDoesNotLayOutTheEntireLazyDashboardBeforeScrolling() throws {
        let observation = ScrollRowObservation()
        let host = NSHostingView(rootView: ScrollView {
            InterfaceScaledContainer(scale: 1, visualWidth: 800) {
                LazyVStack {
                    ForEach(0..<200, id: \.self) { index in
                        ObservedScrollRow(index: index, observation: observation)
                    }
                }
            }
        })
        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
        settle()
        let initial = observation.constructed.count
        XCTAssertLessThan(initial, 60, "The viewport must not eagerly build all 200 off-screen sections")
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }
        let scroll = try XCTUnwrap(findScroll(host))
        scroll.contentView.scroll(to: .init(x: 0, y: 4_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        XCTAssertGreaterThan(observation.constructed.count, initial)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 3_000)
        print("DASHBOARD_SCROLL_LAZY initial=\(initial) after=\(observation.constructed.count)")
    }
}
