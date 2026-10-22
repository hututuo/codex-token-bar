import Charts
import SwiftUI

struct BodySpeedTrendView: View {
    @ObservedObject var monitor: LiveRateMonitor
    var compact = false
    @Environment(\.colorScheme) private var inheritedScheme
    @State private var consumer = UUID()
    @State private var selectedTime: Date?
    private var ink: Color { compact ? .white : .primary }
    private var models: [String] { Set(monitor.speedTrendPoints.map(\.model)).sorted() }
    private var caption: String {
        monitor.speedTrendDays == 1 ? "每5分钟平均 TPS" : monitor.speedTrendDays == 7 ? "30分钟汇总 · 底层5分钟" : "2小时汇总 · 底层5分钟"
    }
    private func color(_ model: String, models: [String]) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        return colors[(models.firstIndex(of: model) ?? 0) % colors.count]
    }
    private struct Entry: Identifiable {
        let point: BodySpeedTrendPoint
        let segment: String
        var id: String { point.id }
    }
    private var entries: [Entry] {
        let width: Int64 = monitor.speedTrendDays == 1 ? 300 : monitor.speedTrendDays == 7 ? 1800 : 7200
        var result: [Entry] = []
        for (model, points) in Dictionary(grouping: monitor.speedTrendPoints, by: \.model).sorted(by: { $0.key < $1.key }) {
            var previous: Int64?, segment = 0
            for point in points.sorted(by: { $0.bucketStart < $1.bucketStart }) {
                if let previous, point.bucketStart - previous > width { segment += 1 }
                result.append(Entry(point: point, segment: "\(model)/\(segment)")); previous = point.bucketStart
            }
        }
        return result
    }
    private var rangePicker: some View {
        HStack(spacing: 3) {
            ForEach([1, 7, 30], id: \.self) { days in
                Button { monitor.setSpeedTrendDays(days) } label: {
                    Text(days == 1 ? "24小时" : "\(days)天")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(monitor.speedTrendDays == days ? Color.white : ink.opacity(0.8))
                        .background(RoundedRectangle(cornerRadius: 5).fill(monitor.speedTrendDays == days ? Color.blue : ink.opacity(0.07)))
                }.buttonStyle(.plain)
                    .accessibilityLabel("速度趋势范围 " + (days == 1 ? "24小时" : "\(days)天"))
                    .accessibilityValue(monitor.speedTrendDays == days ? "已选择" : "未选择")
            }
        }.frame(width: compact ? 160 : 180)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let activeModels = models
            HStack(spacing: 8) {
                Text("速度变化").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink).fixedSize()
                if !compact { Text(caption).font(.system(size: 10)).foregroundStyle(ink.opacity(0.65)).lineLimit(1) }
                Spacer(minLength: 4)
                rangePicker
            }
            if compact { Text(caption).font(.system(size: 10)).foregroundStyle(ink.opacity(0.65)) }
            let now = Date()
            Chart(entries) { entry in
                LineMark(x: .value("时间", Date(timeIntervalSince1970: Double(entry.point.bucketStart))), y: .value("TPS", entry.point.tokensPerSecond), series: .value("连续区间", entry.segment))
                    .foregroundStyle(color(entry.point.model, models: activeModels)).lineStyle(StrokeStyle(lineWidth: 1.6))
                PointMark(x: .value("时间", Date(timeIntervalSince1970: Double(entry.point.bucketStart))), y: .value("TPS", entry.point.tokensPerSecond))
                    .foregroundStyle(color(entry.point.model, models: activeModels)).symbolSize(compact ? 9 : 12)
                    .accessibilityLabel(entry.point.model)
                    .accessibilityValue("\(entry.point.tokensPerSecond, specifier: "%.1f") TPS，\(entry.point.sampleCount)段正文")
            }
            .chartXSelection(value: $selectedTime)
            .chartXScale(domain: now.addingTimeInterval(-Double(monitor.speedTrendDays * 86400))...now)
            .chartYScale(domain: 0...max(10, (monitor.speedTrendPoints.map(\.tokensPerSecond).max() ?? 10) * 1.15))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: compact ? 3 : 5)) { _ in
                    AxisGridLine().foregroundStyle(ink.opacity(0.10))
                    AxisValueLabel(format: monitor.speedTrendDays == 1 ? Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits) : Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits))
                        .font(.system(size: 9)).foregroundStyle(ink.opacity(0.7))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(ink.opacity(0.12))
                    AxisValueLabel().font(.system(size: 9)).foregroundStyle(ink.opacity(0.7))
                }
            }
            .chartLegend(.hidden)
            .frame(height: compact ? 125 : 175)
            .overlay { if entries.isEmpty { Text("等待合格正文采样 · 无数据时留空").font(.caption).foregroundStyle(ink.opacity(0.7)) } }
            HStack(spacing: 12) {
                ForEach(activeModels, id: \.self) { model in
                    HStack(spacing: 4) {
                        Circle().fill(color(model, models: activeModels)).frame(width: 6, height: 6)
                        Text(model.replacingOccurrences(of: "gpt-", with: "")).font(.system(size: 10)).foregroundStyle(ink.opacity(0.85))
                    }
                }
            }
            if let selectedTime, let point = monitor.speedTrendPoints.min(by: { abs(Double($0.bucketStart) - selectedTime.timeIntervalSince1970) < abs(Double($1.bucketStart) - selectedTime.timeIntervalSince1970) }) {
                Text("\(Date(timeIntervalSince1970: Double(point.bucketStart)).formatted(.dateTime.month().day().hour().minute())) · \(point.model) · \(point.tokensPerSecond, specifier: "%.1f") TPS · \(point.sampleCount)段 · \(point.outputTokens) token / \(point.durationSeconds, specifier: "%.2f")秒")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(ink.opacity(0.85)).lineLimit(2)
            } else { Text("点击图中查看采样数与精确数值").font(.system(size: 10)).foregroundStyle(ink.opacity(0.65)) }
            if let error = monitor.speedTrendError { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
        .environment(\.colorScheme, compact ? .dark : inheritedScheme)
        .onAppear { monitor.showSpeedTrend(true, consumer: consumer) }
        .onDisappear { monitor.showSpeedTrend(false, consumer: consumer) }
    }
}
