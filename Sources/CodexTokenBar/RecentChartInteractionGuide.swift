import SwiftUI

/// A small, isolated animation: no data reads, sampling, or dashboard timer.
struct RecentChartInteractionGuide: View {
    @State private var expanded = true
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
            }.buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                HStack(spacing: 20) {
                    Group {
                        if reduceMotion { RecentChartGuideDemo(phase: 5) }
                        else {
                            PhaseAnimator([0, 1, 2, 3, 4, 5, 6]) { phase in
                                RecentChartGuideDemo(phase: phase)
                            } animation: { phase in .easeInOut(duration: phase == 2 || phase == 5 ? 1 : 1.6) }
                        }
                    }.frame(width: 220, height: 108).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("移动鼠标，跟着看时间和用量").font(.system(size: 13, weight: .semibold))
                        Text("① 点一下定起点　② 移动看区间　③ 再点一下固定终点")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Text("固定后弹出区间数据；第三次点击重新选。下图可直接操作。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("左侧为演示数据").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(12)
            .background(AppTheme.accentBlue.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.accentBlue.opacity(0.2), lineWidth: 1))
    }
}

private struct RecentChartGuideDemo: View {
    let phase: Int
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
                Path { p in
                    p.move(to: CGPoint(x: 14, y: 80))
                    p.addLines([CGPoint(x: 35, y: 67), CGPoint(x: 65, y: 74), CGPoint(x: 95, y: 49), CGPoint(x: 125, y: 61), CGPoint(x: 155, y: 44), CGPoint(x: 187, y: 53), CGPoint(x: 207, y: 39)])
                }.stroke(AppTheme.accentBlue, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 54)) }
                    .stroke(AppTheme.accentBlue.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 1, height: 54).position(x: x, y: 62)
                if phase == 2 || phase == 5 {
                    Circle().stroke(AppTheme.accentBlue.opacity(0.7), lineWidth: 2)
                        .frame(width: 20, height: 20).position(x: x, y: 69).transition(.identity)
                }
                Image(systemName: "cursorarrow").font(.system(size: 19)).foregroundStyle(.primary)
                    .position(x: x + 5, y: 75)
                Text(values[phase]).transaction { $0.animation = nil }.font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: min(proxy.size.width - 68, max(68, x)), y: 19)
                Text(phase == 2 ? "点击起点" : phase == 5 ? "点击终点 · 弹出数据" : "左右移动查看")
                    .transaction { $0.animation = nil }
                    .font(.system(size: 9)).foregroundStyle(.secondary).position(x: 110, y: 100)
            }
        }
    }
}
