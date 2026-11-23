import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

@MainActor
final class SidebarDeferredContentTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var active = false
        @Published var value = 1
        var mounts = 0
        var dismantles = 0
        var latest = 0
        var height: CGFloat = -1
        weak var lifetime: Lifetime?
    }
    private final class Lifetime: ObservableObject {}
    private struct Probe: NSViewRepresentable {
        let state: State
        let value: Int
        func makeCoordinator() -> State { state }
        func makeNSView(context: Context) -> NSView { state.mounts += 1; return NSView() }
        func updateNSView(_ view: NSView, context: Context) { state.latest = value }
        static func dismantleNSView(_ view: NSView, coordinator: State) { coordinator.dismantles += 1 }
    }
    private struct Content: View {
        @StateObject private var lifetime = Lifetime()
        let state: State
        let value: Int
        var body: some View {
            Probe(state: state, value: value).frame(width: 88, height: 92)
                .onAppear { state.lifetime = lifetime }
        }
    }
    private struct Height: PreferenceKey {
        static let defaultValue: CGFloat = -1
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
    private struct Harness: View {
        @ObservedObject var state: State
        var body: some View {
            SidebarDeferredContent(active: state.active) {
                Content(state: state, value: state.value)
            }
            .background(GeometryReader { proxy in Color.clear.preference(key: Height.self, value: proxy.size.height) })
            .onPreferenceChange(Height.self) { state.height = $0 }
            .frame(width: 88).fixedSize(horizontal: false, vertical: true)
        }
    }

    func testCollapsedChartReleasesStateKeepsGeometryAndReopensWithLatestData() async throws {
        let state = State()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 88, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Harness(state: state))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(state.mounts, 0, "An unopened hidden chart must not subscribe or allocate its content")
        state.active = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.mounts, 1)
        XCTAssertNotNil(state.lifetime)
        XCTAssertEqual(state.height, 92, accuracy: 0.5)
        state.active = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.dismantles, 1)
        XCTAssertNil(state.lifetime, "Removing only the native Canvas is insufficient; its SwiftUI state must release")
        XCTAssertEqual(state.height, 92, accuracy: 0.5, "Other ring/morph anchors must keep their measured positions")
        state.value = 42
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.latest, 1, "Hidden updates must not reach the dismantled content")
        state.active = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.mounts, 2)
        XCTAssertEqual(state.latest, 42)
        XCTAssertNotNil(state.lifetime)
        XCTAssertEqual(state.height, 92, accuracy: 0.5)
    }
}
