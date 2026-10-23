import SwiftUI
import Charts

struct ActivityRateUnitControl: View {
    @AppStorage(ActivityRateUnit.preferenceKey) private var unitRaw = ActivityRateUnit.tokens.rawValue
    @AppStorage(ActivityRateUnit.exchangeRateKey) private var exchangeRate = ActivityRateUnit.defaultExchangeRate
    @State private var showsExchangeRate = false
    private var unit: ActivityRateUnit { ActivityRateUnit(rawValue: unitRaw) ?? .tokens }
    var body: some View {
        Menu {
            Picker("速率单位", selection: $unitRaw) {
                ForEach(ActivityRateUnit.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Divider()
            Button("设置人民币换算汇率…") { showsExchangeRate = true }
        } label: {
            HStack(spacing: 3) { Text(unit.rawValue); Image(systemName: "chevron.down").font(.system(size: 8)) }
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11, weight: .medium))
            .accessibilityLabel("速率单位：" + unit.rawValue)
            .popover(isPresented: $showsExchangeRate) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("人民币换算汇率").font(.headline)
                    HStack {
                        Text("1 USD =")
                        TextField("汇率", value: $exchangeRate, format: .number.precision(.fractionLength(1...4)))
                            .textFieldStyle(.roundedBorder).frame(width: 85)
                        Text("CN 元")
                    }
                    Text("手动换算参数 · 用于估算输出价值").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }
    }
}

struct LiveActivityRateDetail: View {
    @ObservedObject var monitor: LiveRateMonitor
    @AppStorage(ActivityRateUnit.preferenceKey) private var unitRaw = ActivityRateUnit.tokens.rawValue
    @AppStorage(ActivityRateUnit.exchangeRateKey) private var exchangeRate = ActivityRateUnit.defaultExchangeRate
    private var unit: ActivityRateUnit { ActivityRateUnit(rawValue: unitRaw) ?? .tokens }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("全会话活动速率").font(.system(size: 13, weight: .semibold))
                Spacer()
                ActivityRateUnitControl()
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(unit.text(unit.value(total: monitor.totalSnapshot.rollingTokensPerSecond,
                    rates: monitor.totalSnapshot.modelRates, exchangeRate: exchangeRate)))
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit == .yuan ? "估算 CN 元/s" : "tok/s").font(.caption).foregroundStyle(.secondary)
            }
            ActivityRateHistoryChart(history: monitor.activityRateHistory, unit: unit, exchangeRate: exchangeRate)
            if unit == .yuan {
                Text("输出单价折算 · 1 USD = \(ActivityRateUnit.safeExchangeRate(exchangeRate), specifier: "%.2f") 元")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.bottom, 10)
    }
}

private struct ActivityRateChartNode: Identifiable {
    var at: Date
    var value: Double
    var segment: Int
    var id: Date { at }
}

private struct ActivityRateHistoryChart: View {
    @ObservedObject var history: LiveActivityRateHistory
    let unit: ActivityRateUnit
    let exchangeRate: Double
    var body: some View {
        ActivityRateHistoryPlot(points: history.points, unit: unit, exchangeRate: exchangeRate, windowEnd: floor(Date().timeIntervalSince1970 / 5) * 5).equatable()
    }
}

private struct ActivityRateHistoryPlot: View, Equatable {
    let points: [ActivityRateHistoryPoint]
    let unit: ActivityRateUnit
    let exchangeRate: Double
    let windowEnd: TimeInterval
    @State private var selectedDate: Date?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.unit == rhs.unit && lhs.exchangeRate == rhs.exchangeRate && lhs.windowEnd == rhs.windowEnd
    }
    private var nodes: [ActivityRateChartNode] {
        var result: [ActivityRateChartNode] = [], previous: Double?, segment = 0
        for point in points where point.start >= windowEnd - 1800 && point.start <= windowEnd {
            guard let value = unit.value(total: point.total, rates: point.modelRates, exchangeRate: exchangeRate) else {
                previous = nil; segment += 1; continue
            }
            if let previous, point.start - previous > 5.1 { segment += 1 }
            result.append(.init(at: Date(timeIntervalSince1970: point.start + 2.5), value: value, segment: segment))
            previous = point.start
        }
        return result
    }
    var body: some View {
        let values = nodes
        let now = Date(timeIntervalSince1970: windowEnd)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("近30分钟 · 5秒均值").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let selectedDate, let point = values.min(by: { abs($0.at.timeIntervalSince(selectedDate)) < abs($1.at.timeIntervalSince(selectedDate)) }) {
                    Text(point.at, format: .dateTime.hour().minute().second())
                    Text(unit.text(point.value)).monospacedDigit()
                }
            }.font(.system(size: 10))
            Chart(values) { point in
                LineMark(x: .value("时间", point.at), y: .value(unit.rawValue, point.value), series: .value("采集段", point.segment))
                    .foregroundStyle(AppTheme.accentBlue).lineStyle(.init(lineWidth: 1.8))
            }
            .chartXScale(domain: now.addingTimeInterval(-1800)...now)
            .chartYScale(domain: 0...max(unit == .tokens ? 1 : 0.0001, (values.map(\.value).max() ?? 0) * 1.12))
            .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 10)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.12)); AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.white.opacity(0.8)) } }
            .chartYAxis { AxisMarks(position: .leading) { mark in
                AxisGridLine().foregroundStyle(.white.opacity(0.12))
                AxisValueLabel { if let value = mark.as(Double.self) { Text(unit.text(value)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)) } }
            } }
            .chartXSelection(value: $selectedDate)
            .frame(height: 160)
            if values.isEmpty {
                Text(points.isEmpty ? "等待采集 · 启动前的时间留空" : unit == .yuan ? "部分模型缺少单价，未做金额换算" : "近30分钟暂无采集")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
