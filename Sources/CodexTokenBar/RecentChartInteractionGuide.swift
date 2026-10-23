import SwiftUI

/// A small, isolated animation: no data reads, sampling, or dashboard timer.
struct RecentChartInteractionGuide: View {
    @State private var expanded = true
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "cursorarrow.motionlines.click")
                    Text("图表怎么用").fontWeight(.semibold)
                    Spacer()
                    Text(expanded ? "收起演示" : "展开演示").font(.system(size: 11))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold))
                }.font(.system(size: 14)).foregroundStyle(AppTheme.accentBlue).contentShape(Rectangle())
            }.buttonStyle(ChartGuidePressStyle()).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                HStack(spacing: 20) {
                    Group {
                        if !AnimationActivity.runs(visible: visible, reducedMotion: reduceMotion, lowPower: lowPower) { RecentChartGuideDemo(step: .result) }
                        else {
                            PhaseAnimator(RecentChartGuideStep.allCases) { step in
                                RecentChartGuideDemo(step: step)
                            } animation: { step in .easeInOut(duration: step.duration) }
                        }
                    }.frame(width: 220, height: 108).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("移上去预览：鼠标移到图上，查看当前点的时间和用量。")
                            .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        Text("点选计算：点一下定起点，移动选择区间，再点一下定终点，弹出用量与反推额度；再点可重选。")
                            .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(AppTheme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(AnimationVisibilityProbe { if visible != $0 { visible = $0 } })
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .padding(12)
            .background(AppTheme.accentBlue.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.accentBlue.opacity(0.2), lineWidth: 1))
    }
}

/// Clicks have stationary press/release steps, so feedback finishes before the
/// cursor moves on. These steps do not add a timer or any data work.
enum RecentChartGuideStep: Int, CaseIterable {
    case preview, hoverStart, pressStart, releaseStart, moveRange, hoverEnd, pressEnd, releaseEnd, result, restart
    var x: CGFloat {
        switch self {
        case .preview: 35
        case .hoverStart, .pressStart, .releaseStart: 65
        case .moveRange: 125
        case .hoverEnd, .pressEnd, .releaseEnd, .result: 187
        case .restart: 35
        }
    }
    var press: CGFloat { self == .pressStart || self == .pressEnd ? 1 : 0 }
    var hasStart: Bool { (Self.pressStart.rawValue...Self.result.rawValue).contains(rawValue) }
    var hasEnd: Bool { (Self.pressEnd.rawValue...Self.result.rawValue).contains(rawValue) }
    var duration: Double {
        switch self {
        case .pressStart, .pressEnd: 0.14
        case .releaseStart, .releaseEnd: 0.32
        case .preview: 0.8
        case .result: 1.3
        default: 1.4
        }
    }
    var value: String {
        switch self {
        case .preview: "单点 3.2万 Token"
        case .hoverStart: "单点 4.1万 Token"
        case .pressStart, .releaseStart: "起点 12:05"
        case .moveRange: "区间 8.4万 Token"
        case .hoverEnd, .pressEnd, .releaseEnd, .result: "区间 12.6万 Token"
        case .restart: "重新选择"
        }
    }
    var caption: String {
        switch self {
        case .pressStart, .releaseStart: "点击起点"
        case .pressEnd, .releaseEnd: "点击终点 · 弹出数据"
        case .result: "选区已确定"
        default: "左右移动查看"
        }
    }
}

struct RecentChartGuideDemo: View {
    let step: RecentChartGuideStep
    var body: some View {
        GeometryReader { proxy in
            let x = step.x
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(AppTheme.insetBackground)
                Path { p in
                    p.move(to: CGPoint(x: 14, y: 88)); p.addLine(to: CGPoint(x: 207, y: 88))
                    p.move(to: CGPoint(x: 14, y: 56)); p.addLine(to: CGPoint(x: 207, y: 56))
                }.stroke(AppTheme.border, lineWidth: 1)
                if step.hasStart {
                    Rectangle().fill(AppTheme.accentBlue.opacity(0.14))
                        .frame(width: max(1, x - 65), height: 51).offset(x: 65, y: 37)
                }
                Path { p in p.addLines(RecentChartGuideGeometry.curve) }
                    .stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                if step.hasStart { selectedPoint(at: 65) }
                if step.hasEnd { selectedPoint(at: 187) }
                RecentChartGuideMarker(x: x, press: step.press)
                Text(step.value).transaction { $0.animation = nil }.font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: min(proxy.size.width - 68, max(68, x)), y: 19)
                Text("演示 · " + step.caption)
                    .transaction { $0.animation = nil }
                    .font(.system(size: 9)).foregroundStyle(.secondary).position(x: 110, y: 100)
            }
        }
    }
    private func selectedPoint(at x: CGFloat) -> some View {
        Circle().fill(AppTheme.insetBackground)
            .overlay(Circle().stroke(AppTheme.accentBlue, lineWidth: 1.5))
            .frame(width: 6, height: 6).position(RecentChartGuideGeometry.point(at: x))
            .transaction { $0.animation = nil }
    }
}

enum RecentChartGuideGeometry {
    static let curve: [CGPoint] = [CGPoint(x: 14, y: 80), CGPoint(x: 35, y: 67), CGPoint(x: 65, y: 74), CGPoint(x: 95, y: 49), CGPoint(x: 125, y: 61), CGPoint(x: 155, y: 44), CGPoint(x: 187, y: 53), CGPoint(x: 207, y: 39)]
    static func point(at x: CGFloat) -> CGPoint {
        let clamped = min(curve.last!.x, max(curve.first!.x, x))
        for pair in zip(curve, curve.dropFirst()) where clamped <= pair.1.x {
            let fraction = (clamped - pair.0.x) / (pair.1.x - pair.0.x)
            return CGPoint(x: clamped, y: pair.0.y + fraction * (pair.1.y - pair.0.y))
        }
        return curve.last!
    }
}

/// One animated x drives both drawings in the same Canvas. The cursor's tip
/// follows the actual polyline, including vertices between animation phases.
private struct RecentChartGuideMarker: View, Animatable {
    nonisolated var x: CGFloat
    nonisolated var press: CGFloat
    // Include the press in interpolation: start/end clicks keep x unchanged.
    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(x, press) }
        set { x = newValue.first; press = newValue.second }
    }
    var body: some View {
        Canvas { context, _ in
            let point = RecentChartGuideGeometry.point(at: x)
            var line = Path(); line.move(to: CGPoint(x: point.x, y: 35)); line.addLine(to: CGPoint(x: point.x, y: 88))
            context.stroke(line, with: .color(AppTheme.accentBlue.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let depth = min(1, max(0, press))
            if depth > 0 {
                let radius = 9 + (1 - depth) * 5
                let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                   width: radius * 2, height: radius * 2))
                context.fill(circle, with: .color(AppTheme.accentBlue.opacity(Double(depth) * 0.12)))
                context.stroke(circle, with: .color(AppTheme.accentBlue.opacity(Double(depth))), lineWidth: 2)
            }
            var arrow = Path(); arrow.addLines([.zero, CGPoint(x: 0, y: 21), CGPoint(x: 6, y: 16), CGPoint(x: 10, y: 24), CGPoint(x: 14, y: 22), CGPoint(x: 10, y: 14), CGPoint(x: 18, y: 13)]); arrow.closeSubpath()
            let scale: CGFloat = 1 - depth * 0.22
            arrow = arrow.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: point.x, y: point.y)))
            context.fill(arrow, with: .color(AppTheme.textPrimary))
            context.stroke(arrow, with: .color(AppTheme.insetBackground), lineWidth: 0.7)
        }.allowsHitTesting(false)
    }
}

private struct ChartGuidePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
