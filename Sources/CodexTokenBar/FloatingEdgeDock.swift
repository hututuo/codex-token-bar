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
            let length = frame.height
            return NSRect(x: edge == .left ? frame.minX : frame.maxX - 12,
                          y: frame.midY - length / 2, width: 12, height: length)
        case .top, .bottom:
            let length = min(frame.width, max(40, min(92, frame.width * 0.45)))
            return NSRect(x: frame.midX - length / 2,
                          y: edge == .top ? frame.maxY - 12 : frame.minY,
                          width: length, height: 12)
        }
    }

    static func resolve(frame: NSRect, workArea: NSRect, threshold: CGFloat = 48) -> Self? {
        guard frame.width > 6, frame.height > 6,
              frame.width <= workArea.width, frame.height <= workArea.height,
              [frame.minX, frame.minY, frame.width, frame.height,
               workArea.minX, workArea.minY, workArea.width, workArea.height].allSatisfy(\.isFinite)
        else { return nil }
        let distances: [(FloatingDockEdge, CGFloat)] = [
            (.left, frame.minX - workArea.minX),
            (.right, workArea.maxX - frame.maxX),
            (.top, workArea.maxY - frame.maxY),
            (.bottom, frame.minY - workArea.minY),
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
    let surfaceSize: NSSize
    let detailsAbove: Bool
    var cardCornerRadius: CGFloat = 14
    var shellPadding: CGFloat = 0
    let quota: AccountQuotaSnapshot
    let quotaColorStyle: FloatingQuotaColorStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let contentScale = max(0.8, (surfaceSize.width - 10) / surfaceSize.width)
        let baseHeight = surfaceSize.height + 2 * shellPadding
        let contentInsetY = (baseHeight - surfaceSize.height * contentScale) / 2
        let travel = CGSize(
            width: collapsed ? (anchor?.edge == .left ? -size.width : anchor?.edge == .right ? size.width : 0) : 0,
            height: collapsed ? (anchor?.edge == .top ? -size.height : anchor?.edge == .bottom ? size.height : 0) : 0
        )
        return ZStack(alignment: .topLeading) {
            if let anchor {
                FloatingDockShellShape(edge: anchor.edge,
                    radiusX: collapsed ? 3 : cardCornerRadius * contentScale + (surfaceSize.width * (1 - contentScale) / 2),
                    radiusY: collapsed ? 3 : cardCornerRadius * contentScale + contentInsetY)
                    .fill(.black)
                    .frame(width: shellSize.width, height: shellSize.height)
                    .offset(shellOffset)
                    .transition(.scale(scale: 0.025, anchor: attachmentPoint(anchor.edge)))
                    .allowsHitTesting(false)
            }
            content
                .frame(width: size.width, height: surfaceSize.height + (size.height - baseHeight) / (anchor == nil ? 1 : contentScale), alignment: .topLeading)
                .scaleEffect(anchor == nil ? 1 : contentScale,
                             anchor: .top)
                .offset(y: anchor == nil ? shellPadding : contentInsetY)
                .offset(travel)
                .opacity(collapsed ? 0 : 1)
                .allowsHitTesting(!collapsed)
                .accessibilityHidden(collapsed)
            if anchor != nil {
                Button { presentation.onReveal?() } label: {
                    FloatingEdgeQuotaStrip(snapshot: quota, vertical: anchor?.edge == .left || anchor?.edge == .right, colorStyle: quotaColorStyle)
                        .frame(width: lip.width, height: lip.height)
                }
                .buttonStyle(.plain)
                .offset(x: compact ? 0 : lip.minX - full.minX, y: compact ? 0 : full.maxY - lip.maxY)
                .opacity(collapsed ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: collapsed)
                .allowsHitTesting(collapsed)
                .accessibilityHidden(!collapsed)
                .accessibilityLabel("展开边缘悬浮窗")
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
    }

    private func attachmentPoint(_ edge: FloatingDockEdge) -> UnitPoint {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }


}

/// Elliptical outer corners share the inner card's corner centers even when
/// horizontal and vertical shell padding differ.
struct FloatingDockShellShape: Shape {
    let edge: FloatingDockEdge
    let radiusX: CGFloat
    let radiusY: CGFloat

    func path(in rect: CGRect) -> Path {
        let rx = min(radiusX, rect.width / 2)
        let ry = min(radiusY, rect.height / 2)
        guard rx > 0, ry > 0 else { return Path(rect) }
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: edge == .left || edge == .top ? 0 : rx,
            bottomLeadingRadius: edge == .left || edge == .bottom ? 0 : rx,
            bottomTrailingRadius: edge == .right || edge == .bottom ? 0 : rx,
            topTrailingRadius: edge == .right || edge == .top ? 0 : rx,
            style: .continuous
        )
        return shape.path(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height * rx / ry))
            .applying(CGAffineTransform(scaleX: 1, y: ry / rx))
    }
}

/// Attached directly to the native content view; SwiftUI layout updates cannot
/// replace its tracking area or leave it behind the hosted content.
final class FloatingEdgeTrackingView: NSView {
    var hover: (Bool) -> Void
    private var area: NSTrackingArea?
    init(frame: NSRect, hover: @escaping (Bool) -> Void) {
        self.hover = hover
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }
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


/// Same available windows and pace/fixed/gradient colors as the expanded strip.
private struct FloatingEdgeQuotaStrip: View {
    let snapshot: AccountQuotaSnapshot
    let vertical: Bool
    let colorStyle: FloatingQuotaColorStyle

    var body: some View {
        let windows = floatingQuotaWindows(snapshot)
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(windows, id: \.label) { window in
                GeometryReader { proxy in
                    let fraction = min(1, max(0, Double(window.remainingPercent) / 100))
                    ZStack(alignment: vertical ? .bottom : .leading) {
                        Color.white.opacity(0.16)
                        Rectangle()
                            .fill(colorStyle.fillStyle(remainingPercent: Double(window.remainingPercent),
                                expectedRemainingPercent: window.expectedRemainingPercentByEvenPace.map(Double.init)))
                            .frame(width: vertical ? proxy.size.width : proxy.size.width * fraction,
                                   height: vertical ? proxy.size.height * fraction : proxy.size.height)
                        Text("\(window.compactDisplayLabel) \(window.remainingPercent)%\(snapshot.staleDataDisplayed ? "旧" : "")")
                            .font(.system(size: 8, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(width: vertical ? proxy.size.height : proxy.size.width,
                                   height: vertical ? proxy.size.width : proxy.size.height)
                            .rotationEffect(.degrees(vertical ? -90 : 0))
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .accessibilityLabel("\(window.displayLabel)额度，剩余 \(window.remainingPercent)%\(snapshot.staleDataDisplayed ? "，旧数据" : "")")
            }
            if windows.isEmpty { Color.white.opacity(0.12).accessibilityLabel("额度待读取") }
        }
        .padding(2)
        .background(.black)
    }
}
