import SwiftUI

struct CacheRetentionDashboardIntegration: ViewModifier {
    @ObservedObject var retention: CacheRetentionStore
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                CacheRetentionDetailView(store: retention,onClose: { isPresented = false })
            }
    }
}

struct CacheRetentionChartData: Sendable {
    struct Cell: Hashable, Sendable { let gap: Int64; let hit: Int }
    var points: [CacheRetentionPoint]
    var cells: [Cell: Int] = [:]
    var maximum = 1
    var endMinutes: Double = 4320
    init(points: [CacheRetentionPoint]) {
        self.points = points
        for point in points { cells[Self.cell(point), default: 0] += 1 }
        maximum = cells.values.max() ?? 1
        endMinutes = max(4320, ceil(Double(points.map(\.gapMicroseconds).max() ?? 0) / 60_000_000 / 60) * 60)
    }
    static func cell(_ point: CacheRetentionPoint) -> Cell {
        .init(gap: point.gapMicroseconds / 10_000_000, hit: min(19, Int(point.hitRate * 20)))
    }
    func color(_ count: Int) -> Color {
        let value = maximum > 1 ? log(Double(max(1, count))) / log(Double(maximum)) : 0
        return Color(red: 0.58 - 0.55 * value, green: 0.76 - 0.53 * value, blue: 0.76 - 0.47 * value)
    }
}

struct CacheRetentionAxis {
    let boundaries: [Double]
    let positions: [Double]
    init(end: Double, focus: Bool) {
        boundaries = focus ? [0,5,30,180,720,end] : [0,60,180,720,end]
        positions = focus ? [0,0.40,0.63,0.80,0.91,1] : [0,0.32,0.60,0.85,1]
    }
    func position(_ value: Double) -> Double {
        for i in 1..<boundaries.count where value <= boundaries[i] {
            return positions[i-1] + (value-boundaries[i-1])/(boundaries[i]-boundaries[i-1])*(positions[i]-positions[i-1])
        }
        return 1
    }
}

struct CacheRetentionChartView: View {
    let data: CacheRetentionChartData
    let analysis: CacheRetentionAnalysis
    @Binding var focus: Bool
    @State private var hovered: CacheRetentionPoint?
    private let recommended = Color(red: 0.47, green: 0.36, blue: 0.64)
    private let risk = Color(red: 0.75, green: 0.40, blue: 0.22)

    var body: some View {
        GeometryReader { geometry in
            let axis = CacheRetentionAxis(end: data.endMinutes, focus: focus)
            let plot = CGRect(x: 48, y: 48, width: max(1, geometry.size.width-75), height: max(1, geometry.size.height-101))
            Canvas { context, _ in
                func x(_ minutes: Double) -> CGFloat { plot.minX + axis.position(minutes) * plot.width }
                func y(_ ratio: Double) -> CGFloat { plot.maxY-ratio*plot.height }
                func text(_ label: String, _ at: CGPoint, _ color: Color = .secondary, _ size: CGFloat = 10, _ anchor: UnitPoint = .center) {
                    context.draw(Text(label).font(.system(size: size)).foregroundColor(color), at: at, anchor: anchor)
                }
                for rate in [0,20,40,60,80,100] {
                    let yy = y(Double(rate)/100)
                    var line = Path(); line.move(to: .init(x: plot.minX, y: yy)); line.addLine(to: .init(x: plot.maxX, y: yy))
                    context.stroke(line, with: .color(.secondary.opacity(0.16)), lineWidth: 0.6)
                    text("\(rate)%", .init(x: plot.minX-8,y: yy), .secondary, 10, .trailing)
                }
                // Fixed data-space cells supply color counts only. Every sample
                // uses the same glyph in every axis segment; no stretched tiles.
                for point in data.points {
                    let center = CGPoint(x: x(Double(point.gapMicroseconds)/60_000_000),y: y(point.hitRate))
                    let circle = Path(ellipseIn: CGRect(x: center.x-1.7,y: center.y-1.7,width: 3.4,height: 3.4))
                    context.fill(circle, with: .color(data.color(data.cells[CacheRetentionChartData.cell(point)] ?? 1)))
                    context.stroke(circle,with: .color(.white.opacity(0.22)),lineWidth: 0.2)
                }
                let ticks: [Double] = focus ? [0,1,2,3,4,5,15,30,60,180,720,data.endMinutes] : [0,15,30,60,120,180,360,720,data.endMinutes]
                for tick in ticks {
                    text(tick >= 1440 ? String(format: "%.1f天",tick/1440) : String(format: "%.0f",tick), .init(x: x(tick),y: plot.maxY+17))
                }
                for (i, value) in axis.boundaries.enumerated().dropFirst().dropLast() {
                    text("//",.init(x: plot.minX+axis.positions[i]*plot.width,y: plot.maxY-2), .secondary, 15)
                    _ = value
                }
                func marker(_ microseconds: Double, color: Color, label: String, height: CGFloat) {
                    let xx = x(microseconds/60_000_000)
                    var line = Path(); line.move(to: .init(x: xx,y: plot.minY)); line.addLine(to: .init(x: xx,y: plot.maxY))
                    context.stroke(line,with: .color(color),style: .init(lineWidth: 1.7,dash: [5,4]))
                    text(label,.init(x: min(plot.maxX-110,max(plot.minX+110,xx)),y: height),color,10)
                }
                if let earlier = analysis.earlierDecline { marker(earlier.microseconds,color: recommended,label: CacheRetentionCopy.recommendation(analysis),height: 12) }
                if let drop = analysis.dropMicroseconds { marker(drop,color: risk,label: CacheRetentionCopy.risk(analysis),height: 31) }
                text(focus ? "间隔（分钟） · 前 5 分钟展开，// 处改变比例；右侧保留全部长尾" : "间隔（分钟） · // 处改变横轴比例",.init(x: plot.midX,y: plot.maxY+43),.secondary,10)
            }
            .onContinuousHover { phase in
                switch phase {
                case .ended: hovered = nil
                case .active(let location):
                    guard plot.contains(location) else { hovered = nil; return }
                    var best: CacheRetentionPoint?; var distance = 64.0
                    for point in data.points {
                        let dx = plot.minX+axis.position(Double(point.gapMicroseconds)/60_000_000)*plot.width-location.x
                        let dy = plot.maxY-point.hitRate*plot.height-location.y
                        let value = dx*dx+dy*dy
                        if value < distance { best = point; distance = value }
                    }
                    hovered = best
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let hovered {
                    Text("\(hovered.model) · 间隔 \(CacheRetentionCopy.minutes(Double(hovered.gapMicroseconds))) · 命中 \(hovered.hitRate*100,specifier: "%.1f")% · \(hovered.cached) / \(hovered.input) 输入 Token · 此网格 \(data.cells[CacheRetentionChartData.cell(hovered)] ?? 1) 轮")
                        .font(.system(size: 10)).padding(7).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 6)).padding(.leading,48)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("缓存续问密度图，\(data.points.count)轮。\(CacheRetentionCopy.recommendation(analysis))。\(CacheRetentionCopy.risk(analysis))。")
        }
    }
}

struct CacheRetentionSummaryView: View {
    @ObservedObject var store: CacheRetentionStore
    var onOpen: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 23)).foregroundStyle(.teal)
            VStack(alignment: .leading,spacing: 4) {
                Text("缓存续问参考").font(.system(size: 14,weight: .semibold))
                Text(store.snapshot.updatedAt == nil || (store.isUpdating && store.adviceAnalysis.count == 0) ? "正在读取历史并计算建议…" : CacheRetentionCopy.recommendation(store.adviceAnalysis)).font(.system(size: 12))
                Text(store.isUpdating ? store.status : "\(store.adviceAnalysis.count) 轮有效续问 · 完全在本机计算")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onOpen) { Label("查看间隔图表",systemImage: "chart.xyaxis.line").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent).tint(.teal)
        }
        .padding(14).frame(maxWidth: 980,alignment: .leading)
        .background(AppTheme.panelBackground,in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.border,lineWidth: 1))
    }
}

struct CacheRetentionDetailView: View {
    @ObservedObject var store: CacheRetentionStore
    var onClose: () -> Void
    @State private var focus = true
    private var preparing: Bool { store.snapshot.updatedAt == nil || (store.isUpdating && store.snapshot.points.isEmpty) }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                VStack(alignment: .leading,spacing: 5) {
                    Text("续问间隔与缓存命中").font(.system(size: 20,weight: .semibold))
                    Text(preparing ? "正在读取本机历史，完成后显示有效续问轮数" : "\(store.snapshot.points.count) 轮有效续问 · \(Set(store.snapshot.points.map(\.sessionKey)).count) 个主会话 · 全部本地记录 · 已排除子 Agent")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isUpdating { ProgressView().controlSize(.small) }
                Button("刷新") { store.refresh() }.disabled(store.isUpdating)
                Button("完成",action: onClose).keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 16) {
                Picker("范围",selection: Binding(get: {store.scope.range},set: {store.select(range: $0)})) {
                    ForEach(CacheRetentionScope.Range.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 205)
                Picker("模型",selection: Binding(get: {store.scope.model ?? ""},set: {store.select(model: .some($0.isEmpty ? nil : $0))})) {
                    Text("全部模型").tag("")
                    ForEach(store.snapshot.models,id: \.self) { Text($0).tag($0) }
                }.frame(width: 255)
                Spacer()
                Toggle("展开前 5 分钟",isOn: $focus).toggleStyle(.checkbox)
            }.font(.system(size: 11))
            HStack(alignment: .top,spacing: 12) {
                explanation(title: "建议续问线",text: preparing ? "正在寻找较早的下降…" : CacheRetentionCopy.recommendation(store.snapshot.analysis),detail: preparing ? "读取完成后自动显示，无需重新打开图表。" : store.snapshot.analysis.earlierDecline == nil ? "风险线之前还没有清楚的更早分界，暂不补画。" : "风险线之前最明显的下降；尽量在这之前续问。它仍是历史参考。",color: .purple)
                explanation(title: "低命中风险线",text: preparing ? "正在寻找风险分界…" : CacheRetentionCopy.risk(store.snapshot.analysis),detail: preparing ? "根据本机历史计算，请稍候。" : store.snapshot.analysis.dropMicroseconds == nil ? "历史数据还没有清楚的下降分界，暂不提供最晚参考。" : "尽量别拖到这条线以后；切换模型或改动上下文也会影响缓存。",color: .orange)
            }
            if store.snapshot.analysis.p95State == .rangeTooLarge {
                ContentUnavailableView("范围内轮次太多",systemImage: "line.3.horizontal.decrease.circle",description: Text("请选择更短日期范围；不会抽样后冒充全部历史。"))
            } else if store.chart.points.isEmpty {
                ContentUnavailableView(preparing ? "正在读取真实历史" : "这个范围还没有足够的完整续问",systemImage: "chart.xyaxis.line",description: Text(store.status))
            } else {
                CacheRetentionChartView(data: store.chart,analysis: store.snapshot.analysis,focus: $focus).frame(minHeight: 330)
                HStack(spacing: 8) {
                    Text("稀疏").foregroundStyle(.secondary)
                    LinearGradient(colors: [store.chart.color(1),store.chart.color(max(1,store.chart.maximum/10)),store.chart.color(store.chart.maximum)],startPoint: .leading,endPoint: .trailing).frame(width: 110,height: 8).clipShape(Capsule())
                    Text("密集 · 按 10 秒 × 5 个百分点计数，最高 \(store.chart.maximum) 轮").foregroundStyle(.secondary)
                    Spacer()
                    Text("点色越深，同区间轮次越多").foregroundStyle(.secondary)
                }.font(.system(size: 10))
            }
            Text("历史补充：" + CacheRetentionCopy.coverage(store.snapshot.analysis)).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(store.status).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("横轴按段改变比例。线条描述当前筛选的历史分布，实际命中还受模型和上下文变化影响。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth: 850,idealWidth: 1060,minHeight: 650).background(AppTheme.pageBackground)
    }
    private func explanation(title: String,text: String,detail: String,color: Color) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            Label(title,systemImage: "line.diagonal").font(.system(size: 11,weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 13,weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity,alignment: .leading).padding(12).background(color.opacity(0.065),in: RoundedRectangle(cornerRadius: 10))
    }
}
