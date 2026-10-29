import SwiftUI

struct ActivitySpeedDisplayPicker: View {
    @AppStorage(ActivitySpeedDisplayMode.key) private var raw = ActivitySpeedDisplayMode.bar.rawValue
    var body: some View {
        Picker("速度显示", selection: $raw) {
            ForEach(ActivitySpeedDisplayMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }.pickerStyle(.segmented)
            .help("只切换显示；排行榜始终使用 Agent Speed 标准，不会因此开启上报。")
            .onChange(of: raw) { MultiClientUsageStore.shared.syncLocalRuntime() }
    }
}

/// The two menu sizes share one raw-point chart; no database/history query.
struct ActivitySpeedSummaryView: View {
    let allowed: Set<String>
    var compact = false
    @ObservedObject private var history = ActivitySpeedHistoryController.shared
    @ObservedObject private var palette = SpeedDisplayPreferences.shared
    @AppStorage(ActivitySpeedDisplayMode.key) private var modeRaw = ActivitySpeedDisplayMode.bar.rawValue
    @AppStorage(ActivityRateUnit.preferenceKey) private var unitRaw = ActivityRateUnit.tokens.rawValue
    @AppStorage(ActivityRateUnit.exchangeRateKey) private var exchangeRate = ActivityRateUnit.defaultExchangeRate
    @State private var selectedClient: String?
    private var unit: ActivityRateUnit { ActivityRateUnit(rawValue: unitRaw) ?? .tokens }
    private var mode: ActivitySpeedDisplayMode { .normalized(modeRaw) }
    private func title(_ client: String) -> String { SpeedColorOverrides.clientTitle("client:" + client) }
    private func value(_ point: ActivityLivePoint) -> Double? { unit.value(total: point.rate, rates: point.rates, exchangeRate: exchangeRate) }
    var body: some View {
        let now = Date().timeIntervalSince1970
        let rows = history.rows(allowed: allowed, mode: mode, now: now)
        let selection = rows.contains { $0.client == selectedClient } ? selectedClient : nil
        let visible = rows.filter { selection == nil || $0.client == selection }
        let ceiling = max(unit == .tokens ? 10 : 0.0001, (visible.flatMap { $0.points.compactMap(value) }.max() ?? 0)*1.12)
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 6) {
                Text(compact ? "速度" : "活动速率").font(.system(size: compact ? 10 : 13, weight: .semibold))
                Text("近3分钟").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !compact {
                    Text(mode.title).font(.system(size: 10)).foregroundStyle(.secondary)
                    ActivityRateUnitControl()
                }
            }
            if !rows.isEmpty {
                HStack(spacing: 8) {
                    if rows.count > 1 { clientButton("全部", client: nil, selection: selection) }
                    ForEach(rows) { row in clientButton(title(row.client), client: row.client, selection: selection) }
                }
            }
            Canvas { context, size in
                let left: CGFloat = compact ? 2 : 35, right = size.width - 4
                let top: CGFloat = 8, bottom = size.height - 16
                func position(_ point: ActivityLiveConnections.Point) -> CGPoint {
                    CGPoint(x: left + (point.x - (now-180))/180*(right-left), y: bottom - point.y/ceiling*(bottom-top))
                }
                for fraction in [0.0, 0.5, 1.0] {
                    let y = bottom - fraction*(bottom-top)
                    var grid = Path(); grid.move(to:.init(x:left,y:y)); grid.addLine(to:.init(x:right,y:y))
                    context.stroke(grid, with:.color(.secondary.opacity(0.18)), style:.init(lineWidth:0.5, dash:fraction == 0 ? [] : [1,3]))
                    if !compact {
                        context.draw(Text(unit.text(ceiling*fraction)).font(.system(size:9)).foregroundStyle(.secondary), at:.init(x:left-5,y:y), anchor:.trailing)
                    }
                }
                var clipped = context
                clipped.clip(to:Path(CGRect(x:left,y:top-3,width:max(0,right-left),height:max(0,bottom-top+6))))
                for row in visible {
                    let color = ModelUsagePresentation.color(for:"client:"+row.client)
                    let points = row.points.map { ActivityLiveConnections.Point(x:$0.time, y:value($0) ?? .nan) }
                    for run in ActivityLiveConnections.runs(points) {
                        guard let first = run.first else { continue }
                        var path = Path(); path.move(to:position(first))
                        for segment in ActivityLiveConnections.segments(run) {
                            path.addCurve(to:position(segment.end), control1:position(segment.first), control2:position(segment.second))
                        }
                        clipped.stroke(path, with:.color(color), style:.init(lineWidth:compact ? 1.3 : 1.6,lineCap:.round,lineJoin:.round))
                    }
                    if let point = points.last, point.y.isFinite {
                        let pos = position(point), radius: CGFloat = compact ? 1.5 : 2.5
                        clipped.fill(Path(ellipseIn:CGRect(x:pos.x-radius,y:pos.y-radius,width:radius*2,height:radius*2)),with:.color(color))
                    }
                }
                if rows.isEmpty { context.draw(Text("等待速度读数").font(.system(size:compact ? 9 : 11)).foregroundStyle(.secondary), at:.init(x:(left+right)/2,y:(top+bottom)/2)) }
                context.draw(Text("3分钟前").font(.system(size:9)).foregroundStyle(.secondary), at:.init(x:left,y:size.height-3),anchor:.bottomLeading)
                context.draw(Text("现在").font(.system(size:9)).foregroundStyle(.secondary), at:.init(x:right,y:size.height-3),anchor:.bottomTrailing)
            }
            .frame(height:compact ? 84 : 176)
            .overlay {
                if !compact { ActivitySpeedInspectionOverlay(rows: visible, now: now, unit: unit, exchangeRate: exchangeRate) }
            }
            .accessibilityLabel("最近3分钟活动速率，原始读数连线")
            if !compact { Text("原始速度读数 · 移到曲线上查看").font(.system(size:10)).foregroundStyle(.secondary) }
        }
    }
    private func clientButton(_ text: String, client: String?, selection: String?) -> some View {
        Button { selectedClient = client } label: {
            Text(text).font(.system(size:compact ? 9 : 11, weight:selection == client || client != nil && selection == nil ? .semibold : .regular))
                .foregroundStyle(client.map { ModelUsagePresentation.color(for:"client:"+$0) } ?? .primary)
        }.buttonStyle(.plain)
    }
}

/// Hover state is isolated from the canvas, so moving the pointer does not
/// regenerate all paths or publish a new speed/history value.
private struct ActivitySpeedInspectionOverlay: View {
    let rows: [ActivityLiveSeries]
    let now: Double
    let unit: ActivityRateUnit
    let exchangeRate: Double
    @State private var selectedTime: Double?
    var body: some View {
        GeometryReader { proxy in
            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let time = now-180+(point.x-35)/max(1,proxy.size.width-39)*180
                        let next = point.x >= 35 && point.x <= proxy.size.width-4 ? time.rounded() : nil
                        if selectedTime != next { selectedTime = next }
                    case .ended: selectedTime = nil
                    }
                }
                .overlay(alignment:.topLeading) {
                    if let selectedTime {
                        VStack(alignment:.leading,spacing:3) {
                            ForEach(rows) { row in
                                if let point = row.points.min(by:{ abs($0.time-selectedTime)<abs($1.time-selectedTime) }), abs(point.time-selectedTime)<=2 {
                                    Text(SpeedColorOverrides.clientTitle("client:"+row.client)+" · "+unit.text(unit.value(total:point.rate,rates:point.rates,exchangeRate:exchangeRate))+" "+unit.rawValue)
                                        .font(.system(size:10)).monospacedDigit()
                                }
                            }
                        }.padding(5).background(AppTheme.solidControlBackground,in:RoundedRectangle(cornerRadius:5))
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
