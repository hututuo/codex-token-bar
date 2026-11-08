import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

private struct DiscoveryBoundsKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

final class MultiClientDiscoveryLayoutTests: XCTestCase {
    @MainActor
    func testEveryDiscoveryUsesTheCardWidthAndWrapsAtNarrowWidths() throws {
        let clients: [UsageClient] = [.deepseek, .gemini, .antigravity]
        let detections: [DetectedUsageClient] = clients.map {
            .init(client: $0, evidence: "synthetic local discovery")
        }
        var enabled: [UsageClient] = [], dismissed: [UsageClient] = []
        for width: CGFloat in [360, 872, 1404] {
            var heights: [CGFloat] = []
            for rows in [Array(detections.prefix(1)), detections] {
                var bounds = CGRect.zero
                let view = MultiClientDiscoveryRows(detections: rows,
                    enable: { enabled.append($0) }, acknowledge: { dismissed.append($0) })
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: DiscoveryBoundsKey.self, value: geometry.frame(in: .named("fixture")))
                    })
                    .onPreferenceChange(DiscoveryBoundsKey.self) { bounds = $0 }
                    .frame(width: width, height: 440, alignment: .top)
                    .coordinateSpace(name: "fixture")
                    .background(AppTheme.pageBackground)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 440),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(bounds.width, min(980, width), accuracy: 1)
                XCTAssertEqual(bounds.midX, width / 2, accuracy: 1)
                XCTAssertGreaterThan(bounds.height, 20)
                XCTAssertLessThan(bounds.height, 440, "Every discovery must remain inside the visible fixture")
                heights.append(bounds.height)
                if let folder = ProcessInfo.processInfo.environment["TOKENBAR_DISCOVERY_RENDER_DIR"] {
                    let root = URL(fileURLWithPath: folder)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appendingPathComponent("discovery-\(Int(width))-\(rows.count).png"))
                }
            }
            XCTAssertGreaterThanOrEqual(heights[1], heights[0] * 3,
                "All three pending discoveries must be rendered at once")
        }
        XCTAssertTrue(enabled.isEmpty)
        XCTAssertTrue(dismissed.isEmpty, "Rendering must not enable or acknowledge a client")
    }
}
