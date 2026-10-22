import Charts
import SwiftUI

struct BodySpeedTrendView: View {
    @ObservedObject var monitor: LiveRateMonitor
    var compact = false
    @Environment(\.colorScheme) private var inheritedScheme
    @State private var consumer = UUID()
    @State private var selectedTime: Date?
    @State private var selectedModel: String?
    private var ink: Color { compact ? .white : .primary }
    private var rangePoints: [BodySpeedTrendPoint] {
        let cutoff = Date().timeIntervalSince1970 - Double(monitor.speedTrendWindowSeconds)
        return monitor.speedTrendPoints.filter { Double($0.bucketStart) >= cutoff && Double($0.bucketStart) <= Date().timeIntervalSince1970 }
    }
    private var models: [String] { Set(rangePoints.map(\.model)).sorted() }
    private var preferredModel: String? {
        monitor.modelSpeeds15m.sorted { $0.sampleCount > $1.sampleCount }.first { models.contains($0.model) }?.model ?? models.first
    }
    private var focusModel: String? { selectedModel == "*" ? nil : selectedModel.flatMap { models.contains($0) ? $0 : nil } ?? preferredModel }
    private var visiblePoints: [BodySpeedTrendPoint] { rangePoints.filter { focusModel == nil || $0.model == focusModel } }
    private var yBounds: ClosedRange<Double> {
        let values = visiblePoints.map(\.tokensPerSecond), low = values.min() ?? 0, high = values.max() ?? 10
        let padding = max(5, (high - low) * 0.2)
        return max(0, low - padding)...max(10, high + padding)
    }
    private var caption: String {
        monitor.speedTrendDays == 1 ? "每点为5分钟均速 · TPS" : monitor.speedTrendDays == 7 ? "30分钟汇总 · 底层5分钟" : "2小时汇总 · 底层5分钟"
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
        for (model, points) in Dictionary(grouping: visiblePoints, by: \.model).sorted(by: { $0.key < $1.key }) {
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
            ForEach([86400, 604800, 2592000], id: \.self) { seconds in
                Button { monitor.setSpeedTrendWindow(seconds); selectedTime = nil } label: {
                    Text(seconds == 86400 ? "24小时" : seconds == 604800 ? "7天" : "30天")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(monitor.speedTrendWindowSeconds == seconds ? Color.white : ink.opacity(0.8))
                        .background(RoundedRectangle(cornerRadius: 5).fill(monitor.speedTrendWindowSeconds == seconds ? Color.blue : ink.opacity(0.07)))
                }.buttonStyle(.plain)
                    .accessibilityLabel("速度趋势范围 " + (seconds == 86400 ? "24小时" : seconds == 604800 ? "7天" : "30天"))
                    .accessibilityValue(monitor.speedTrendWindowSeconds == seconds ? "已选择" : "未选择")
            }
        }.frame(width: compact ? 170 : 205)
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
            HStack(spacing: 5) {
                Button("全部") { selectedModel = "*"; selectedTime = nil }.buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(focusModel == nil ? ink : ink.opacity(0.55))
                ForEach(activeModels, id: \.self) { model in
                    Button { selectedModel = model; selectedTime = nil } label: {
                        HStack(spacing: 4) {
                            Circle().fill(color(model, models: activeModels)).frame(width: 6, height: 6)
                            Text(model.replacingOccurrences(of: "gpt-", with: "")).lineLimit(1).font(.system(size: 10))
                        }.padding(.horizontal, 7).padding(.vertical, 4)
                            .foregroundStyle(focusModel == model ? ink : ink.opacity(0.55))
                            .background(RoundedRectangle(cornerRadius: 5).fill(focusModel == model ? ink.opacity(0.12) : .clear))
                    }.buttonStyle(.plain)
                }
            }
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
            .chartXScale(domain: now.addingTimeInterval(-Double(monitor.speedTrendWindowSeconds))...now)
            .chartYScale(domain: yBounds)
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
            if focusModel != nil, let first = visiblePoints.min(by: { $0.bucketStart < $1.bucketStart }), let last = visiblePoints.max(by: { $0.bucketStart < $1.bucketStart }) {
                HStack {
                    Text("最近 \(last.tokensPerSecond, specifier: "%.1f") TPS").fontWeight(.semibold)
                    Spacer()
                    if first.bucketStart != last.bucketStart && first.tokensPerSecond > 0 {
                        let change = (last.tokensPerSecond / first.tokensPerSecond - 1) * 100
                        Text("首尾 \(change >= 0 ? "+" : "")\(change, specifier: "%.1f")%")
                            .foregroundStyle(change >= 0 ? Color.green : Color.orange)
                    }
                }.font(.system(size: 11)).monospacedDigit().foregroundStyle(ink)
            }
            if let selectedTime, let point = visiblePoints.min(by: { abs(Double($0.bucketStart) - selectedTime.timeIntervalSince1970) < abs(Double($1.bucketStart) - selectedTime.timeIntervalSince1970) }) {
                Text("\(Date(timeIntervalSince1970: Double(point.bucketStart)).formatted(.dateTime.month().day().hour().minute())) · \(point.model) · \(point.tokensPerSecond, specifier: "%.1f") TPS · \(point.sampleCount)段 · \(point.outputTokens) token / \(point.durationSeconds, specifier: "%.2f")秒")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(ink.opacity(0.85)).lineLimit(2)
            } else { Text("点击图中查看采样数与精确数值").font(.system(size: 10)).foregroundStyle(ink.opacity(0.65)) }
            if let error = monitor.speedTrendError { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
        .environment(\.colorScheme, compact ? .dark : inheritedScheme)
        .onChange(of: models, initial: true) { _, values in
            if selectedModel != "*", selectedModel == nil || !values.contains(selectedModel ?? "") { selectedModel = preferredModel }
        }
        .onAppear { monitor.showSpeedTrend(true, consumer: consumer) }
        .onDisappear { monitor.showSpeedTrend(false, consumer: consumer) }
    }
}
