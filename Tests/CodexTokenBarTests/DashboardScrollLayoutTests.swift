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

@MainActor
private final class DynamicScrollContent: ObservableObject {
    @Published var height: CGFloat = 900
}

private struct DynamicScrollFixture: View {
    @ObservedObject var content: DynamicScrollContent
    let scale: CGFloat
    var body: some View {
        ScrollView {
            InterfaceScaledContainer(scale: scale, visualWidth: 800) {
                Color.clear.frame(height: content.height)
            }
        }
    }
}

final class DashboardScrollLayoutTests: XCTestCase {
    @MainActor
    func testContentGrowthAndShrinkUpdateScrollExtentAtDefaultAndCustomScales() throws {
        for scale: CGFloat in [1, 0.9, 1.3] {
            let content = DynamicScrollContent()
            let host = NSHostingView(rootView: DynamicScrollFixture(content: content, scale: scale))
            let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 800, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            func settle() {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
            }
            func findScroll(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap(findScroll).first
            }
            settle()
            let scroll = try XCTUnwrap(findScroll(host))
            let document = try XCTUnwrap(scroll.documentView)
            for height: CGFloat in [900, 1600, 700] {
                content.height = height
                settle()
                XCTAssertEqual(document.frame.height, height * scale, accuracy: 2,
                    "Scroll extent must follow dynamic content at scale \(scale)")
                XCTAssertLessThanOrEqual(document.frame.width, 801)
            }
        }
    }

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
