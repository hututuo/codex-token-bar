import Charts
import SwiftUI

struct BodySpeedTrendView: View {
    @ObservedObject var monitor: LiveRateMonitor
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("速度变化").font(.system(size: 12, weight: .semibold))
                Text(monitor.speedTrendDays == 1 ? "每5分钟平均 TPS" : monitor.speedTrendDays == 7 ? "30分钟汇总 · 底层5分钟" : "2小时汇总 · 底层5分钟")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Picker("速度趋势范围", selection: Binding(get: { monitor.speedTrendDays }, set: { monitor.setSpeedTrendDays($0) })) {
                    Text("24小时").tag(1); Text("7天").tag(7); Text("30天").tag(30)
                }.pickerStyle(.segmented).frame(width: 180)
            }
            let now = Date()
            Chart(entries) { entry in
                LineMark(x: .value("时间", Date(timeIntervalSince1970: Double(entry.point.bucketStart))), y: .value("TPS", entry.point.tokensPerSecond), series: .value("连续区间", entry.segment))
                    .foregroundStyle(by: .value("模型", entry.point.model)).lineStyle(StrokeStyle(lineWidth: 1.8))
                PointMark(x: .value("时间", Date(timeIntervalSince1970: Double(entry.point.bucketStart))), y: .value("TPS", entry.point.tokensPerSecond))
                    .foregroundStyle(by: .value("模型", entry.point.model)).symbolSize(12)
                    .accessibilityLabel(entry.point.model)
                    .accessibilityValue("\(entry.point.tokensPerSecond, specifier: "%.1f") TPS，\(entry.point.sampleCount)段正文")
            }
            .chartXScale(domain: now.addingTimeInterval(-Double(monitor.speedTrendDays * 86400))...now)
            .chartYScale(domain: 0...max(10, (monitor.speedTrendPoints.map(\.tokensPerSecond).max() ?? 10) * 1.15))
            .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
            .frame(height: 175)
            .overlay { if entries.isEmpty { Text("等待合格正文采样 · 无数据时留空").font(.caption).foregroundStyle(.secondary) } }
            if let error = monitor.speedTrendError { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
        .onAppear { monitor.showSpeedTrend(true) }
        .onDisappear { monitor.showSpeedTrend(false) }
    }
}
