import SwiftUI

struct SidebarTrendView: View {
    let data: SidebarTrendData
    private var bins: [BinUsage] { data.bins }
    @State private var selected: Int?
    private let blue = Color(red: 0.47, green: 0.72, blue: 1)
    private let purple = Color(red: 0.71, green: 0.67, blue: 1)
    private let green = Color(red: 0.71, green: 0.94, blue: 0.46)

    var body: some View {
        let values = data.alignedQuota
        let five = values.map { $0?.fiveHourRemainingPercent }
        let seven = values.map { $0?.sevenDayRemainingPercent }
        let hasFive = five.contains { $0?.isFinite == true }
        let hasSeven = seven.contains { $0?.isFinite == true }
        let index = min(selected ?? max(0, bins.count - 1), max(0, bins.count - 1))
        let maximum = Double(max(1, bins.map(\.tokens).max() ?? 1))
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("最近 24 小时").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(data.quotaTitle.map { "Token / " + $0 + " 剩余额度" } ?? "Token · 点击查看").font(.system(size: 9)).foregroundStyle(.gray)
            }
            if bins.isEmpty {
                Text("趋势待读取").font(.system(size: 10)).foregroundStyle(.gray)
            } else {
                GeometryReader { geometry in
                    ZStack {
                        line(bins.map { Double($0.tokens) }, maximum: maximum, size: geometry.size).stroke(blue, lineWidth: 1.3)
                        line(five, maximum: 100, size: geometry.size).stroke(green, lineWidth: 1.3)
                        line(seven, maximum: 100, size: geometry.size).stroke(purple, lineWidth: 1.3)
                        isolated(five, size: geometry.size).fill(green)
                        isolated(seven, size: geometry.size).fill(purple)
                        if selected != nil {
                            Path { path in
                                let x = geometry.size.width * Double(index) / Double(max(1, bins.count - 1))
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                            }.stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { event in
                        selected = max(0, min(bins.count - 1, Int((event.location.x / max(1, geometry.size.width) * Double(bins.count - 1)).rounded())))
                    })
                }.frame(height: 80)
                HStack(spacing: 8) {
                    Text(bins[index].start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))).foregroundStyle(.gray)
                    Text("\(bins[index].tokens.abbreviatedTokens) Token / 5分").foregroundStyle(blue)
                    if hasFive {
                        Text("5h \(percent(values[index]?.fiveHourRemainingPercent))").foregroundStyle(green)
                    }
                    if hasSeven { Text("7d \(percent(values[index]?.sevenDayRemainingPercent))").foregroundStyle(purple) }
                }.font(.system(size: 9)).monospacedDigit()
                if let title = data.quotaTitle, !hasFive && !hasSeven {
                    Text(title + " 额度暂无历史采样").font(.system(size: 9)).foregroundStyle(.gray)
                }
            }
        }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return ClientQuotaPresentation.percentNumber(min(100, max(0, value))) + "%"
    }
    private func isolated(_ values: [Double?], size: CGSize) -> Path {
        Path { path in
            for index in SidebarTrendData.isolatedIndices(values) {
                guard let value = values[index] else { continue }
                let x = size.width * Double(index) / Double(max(1, values.count - 1))
                let y = size.height * (1 - min(1, max(0, value / 100)))
                path.addEllipse(in: CGRect(x: x - 1.8, y: y - 1.8, width: 3.6, height: 3.6))
            }
        }
    }
    private func line(_ values: [Double?], maximum: Double, size: CGSize) -> Path {
        Path { path in
            var connected = false
            for (index, value) in values.enumerated() {
                guard let value, value.isFinite else { connected = false; continue }
                let point = CGPoint(x: size.width * Double(index) / Double(max(1, values.count - 1)),
                                    y: size.height * (1 - min(1, max(0, value / maximum))))
                if connected { path.addLine(to: point) } else { path.move(to: point) }
                connected = true
            }
        }
    }
}
