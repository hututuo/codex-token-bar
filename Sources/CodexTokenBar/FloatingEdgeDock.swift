import AppKit
import SwiftUI

// Geometry is in AppKit screen points (bottom-left origin). The visible work
// area keeps the reveal handle clear of the menu bar and Dock on every display.
enum FloatingDockEdge: String, CaseIterable, Sendable {
    case left, right, top, bottom
}

struct FloatingEdgeDockAnchor: Equatable {
    let edge: FloatingDockEdge
    let expandedFrame: NSRect

    var collapsedFrame: NSRect {
        let frame = expandedFrame
        switch edge {
        case .left, .right:
            let length = min(frame.height, max(28, min(72, frame.height * 0.6)))
            return NSRect(x: edge == .left ? frame.minX : frame.maxX - 6,
                          y: frame.midY - length / 2, width: 6, height: length)
        case .top, .bottom:
            let length = min(frame.width, max(40, min(92, frame.width * 0.45)))
            return NSRect(x: frame.midX - length / 2,
                          y: edge == .top ? frame.maxY - 6 : frame.minY,
                          width: length, height: 6)
        }
    }

    static func resolve(frame: NSRect, workArea: NSRect, threshold: CGFloat = 14) -> Self? {
        guard frame.width > 6, frame.height > 6,
              frame.width <= workArea.width, frame.height <= workArea.height,
              [frame.minX, frame.minY, frame.width, frame.height,
               workArea.minX, workArea.minY, workArea.width, workArea.height].allSatisfy(\.isFinite)
        else { return nil }
        let distances: [(FloatingDockEdge, CGFloat)] = [
            (.left, abs(frame.minX - workArea.minX)),
            (.right, abs(frame.maxX - workArea.maxX)),
            (.top, abs(frame.maxY - workArea.maxY)),
            (.bottom, abs(frame.minY - workArea.minY)),
        ]
        guard let (edge, distance) = distances.min(by: { $0.1 < $1.1 }), distance <= threshold,
              frame.intersects(workArea) else { return nil }
        var snapped = frame
        snapped.origin.x = min(max(frame.minX, workArea.minX), workArea.maxX - frame.width)
        snapped.origin.y = min(max(frame.minY, workArea.minY), workArea.maxY - frame.height)
        switch edge {
        case .left: snapped.origin.x = workArea.minX
        case .right: snapped.origin.x = workArea.maxX - frame.width
        case .top: snapped.origin.y = workArea.maxY - frame.height
        case .bottom: snapped.origin.y = workArea.minY
        }
        return Self(edge: edge, expandedFrame: snapped)
    }
}

@MainActor
final class FloatingEdgeDockPresentation: ObservableObject {
    @Published var anchor: FloatingEdgeDockAnchor?
    @Published var collapsed = false
    @Published var compactWindow = false
    var onHover: ((Bool) -> Void)?
    var onReveal: (() -> Void)?
}

struct FloatingEdgeDockModifier: ViewModifier {
    @ObservedObject var presentation: FloatingEdgeDockPresentation
    let size: NSSize

    func body(content: Content) -> some View {
        let anchor = presentation.anchor
        let compact = anchor != nil && presentation.compactWindow
        let collapsed = anchor != nil && presentation.collapsed
        let lip = anchor?.collapsedFrame ?? .zero
        let full = anchor?.expandedFrame ?? NSRect(origin: .zero, size: size)
        let viewport = compact ? lip.size : size
        let shellSize = collapsed ? lip.size : size
        let shellOffset = collapsed && !compact
            ? CGSize(width: lip.minX - full.minX, height: full.maxY - lip.maxY) : .zero
        let travel = CGSize(
            width: collapsed ? (anchor?.edge == .left ? -size.width : anchor?.edge == .right ? size.width : 0) : 0,
            height: collapsed ? (anchor?.edge == .top ? -size.height : anchor?.edge == .bottom ? size.height : 0) : 0
        )
        return ZStack(alignment: .topLeading) {
            if let anchor {
                dockShape(edge: anchor.edge, radius: collapsed ? 3 : 22)
                    .fill(.black)
                    .frame(width: shellSize.width, height: shellSize.height)
                    .offset(shellOffset)
                    .transition(.scale(scale: 0.025, anchor: attachmentPoint(anchor.edge)))
                    .allowsHitTesting(false)
            }
            content
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: anchor == nil ? 1 : collapsed ? 0.84 : max(0.8, (size.width - 10) / size.width),
                             y: anchor == nil ? 1 : collapsed ? 0.84 : max(0.8, (size.height - 10) / size.height))
                .offset(travel)
                .opacity(collapsed ? 0 : 1)
                .allowsHitTesting(!collapsed)
                .accessibilityHidden(collapsed)
            if compact {
                Button { presentation.onReveal?() } label: {
                    Color.clear.frame(width: viewport.width, height: viewport.height)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开边缘悬浮窗")
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        .background(FloatingEdgeHoverView { presentation.onHover?($0) })
    }

    private func attachmentPoint(_ edge: FloatingDockEdge) -> UnitPoint {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func dockShape(edge: FloatingDockEdge, radius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .left || edge == .top ? 0 : radius,
            bottomLeadingRadius: edge == .left || edge == .bottom ? 0 : radius,
            bottomTrailingRadius: edge == .right || edge == .bottom ? 0 : radius,
            topTrailingRadius: edge == .right || edge == .top ? 0 : radius,
            style: .continuous
        )
    }
}

private struct FloatingEdgeHoverView: NSViewRepresentable {
    let hover: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(hover: hover) }
    func updateNSView(_ view: TrackingView, context: Context) { view.hover = hover }

    final class TrackingView: NSView {
        var hover: (Bool) -> Void
        private var area: NSTrackingArea?
        init(hover: @escaping (Bool) -> Void) { self.hover = hover; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(next)
            area = next
        }
        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }
    }
}
