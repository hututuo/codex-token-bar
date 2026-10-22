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
                        if !AnimationActivity.runs(visible: visible, reducedMotion: reduceMotion, lowPower: lowPower) { RecentChartGuideDemo(phase: 5, animatesPress: false) }
                        else {
                            PhaseAnimator([0, 1, 2, 3, 4, 5, 6]) { phase in
                                RecentChartGuideDemo(phase: phase)
                            } animation: { phase in .easeInOut(duration: phase == 2 || phase == 5 ? 1 : 1.6) }
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

private struct RecentChartGuideDemo: View {
    let phase: Int
    var animatesPress = true
    private let positions: [CGFloat] = [35, 65, 65, 125, 187, 187, 45]
    private let values = ["单点 3.2万 Token", "单点 4.1万 Token", "起点 12:05", "区间 8.4万 Token", "区间 12.6万 Token", "区间 12.6万 Token", "重新选择"]
    var body: some View {
        GeometryReader { proxy in
            let x = positions[phase]
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(AppTheme.insetBackground)
                Path { p in
                    p.move(to: CGPoint(x: 14, y: 88)); p.addLine(to: CGPoint(x: 207, y: 88))
                    p.move(to: CGPoint(x: 14, y: 56)); p.addLine(to: CGPoint(x: 207, y: 56))
                }.stroke(AppTheme.border, lineWidth: 1)
                if (2...5).contains(phase) {
                    Rectangle().fill(AppTheme.accentBlue.opacity(0.14))
                        .frame(width: max(1, x - 65), height: 51).offset(x: 65, y: 37)
                }
                Path { p in p.addLines(RecentChartGuideGeometry.curve) }
                    .stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                RecentChartGuideMarker(x: x, pressed: animatesPress && (phase == 2 || phase == 5))
                Text(values[phase]).transaction { $0.animation = nil }.font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: min(proxy.size.width - 68, max(68, x)), y: 19)
                Text("演示 · " + (phase == 2 ? "点击起点" : phase == 5 ? "点击终点 · 弹出数据" : "左右移动查看"))
                    .transaction { $0.animation = nil }
                    .font(.system(size: 9)).foregroundStyle(.secondary).position(x: 110, y: 100)
            }
        }
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
    let pressed: Bool
    nonisolated var animatableData: CGFloat { get { x } set { x = newValue } }
    var body: some View {
        Canvas { context, _ in
            let point = RecentChartGuideGeometry.point(at: x)
            var line = Path(); line.move(to: CGPoint(x: point.x, y: 35)); line.addLine(to: CGPoint(x: point.x, y: 88))
            context.stroke(line, with: .color(AppTheme.accentBlue.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if pressed {
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)), with: .color(AppTheme.accentBlue), lineWidth: 2)
            }
            var arrow = Path(); arrow.addLines([.zero, CGPoint(x: 0, y: 21), CGPoint(x: 6, y: 16), CGPoint(x: 10, y: 24), CGPoint(x: 14, y: 22), CGPoint(x: 10, y: 14), CGPoint(x: 18, y: 13)]); arrow.closeSubpath()
            let scale: CGFloat = pressed ? 0.78 : 1
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
