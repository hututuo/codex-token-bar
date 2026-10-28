import Charts
import SwiftUI

struct BodySpeedResetMarker: Equatable, Identifiable, Sendable {
    var observedAt: Date
    var previousAt: Date
    var id: Date { observedAt }

    static func from(_ history: QuotaHistorySnapshot) -> [Self] {
        guard !history.isStale else { return [] }
        // Accepted cycles exclude withdrawn cuts; the first unknown start is not a reset.
        return history.actualCycles.compactMap { cycle in
            guard let start = cycle.start?.latest else { return nil }
            let event = history.cycleDiagnostics.first { $0.kind == .confirmed && $0.after.at == start }
            return .init(observedAt: start, previousAt: event?.before.at ?? cycle.start!.earliest)
        }.sorted { $0.observedAt < $1.observedAt }
    }
}

struct BodySpeedTrendView: View {
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject private var palette = SpeedDisplayPreferences.shared
    var compact = false
    var resetMarkers: [BodySpeedResetMarker] = []
    @State private var consumer = UUID()

    var body: some View {
        BodySpeedTrendContent(input: .init(points: monitor.speedTrendPoints,
            days: monitor.speedTrendDays, windowSeconds: monitor.speedTrendWindowSeconds,
            preferredModels: monitor.modelSpeeds15m.sorted { $0.sampleCount > $1.sampleCount }.map(\.model),
            minute: Int64(Date().timeIntervalSince1970 / 60), error: monitor.speedTrendError,
            resetMarkers: resetMarkers, palette: palette.colors), compact: compact, source: ObjectIdentifier(monitor),
            selectWindow: { monitor.setSpeedTrendWindow($0) })
            .equatable()
            .onAppear { monitor.showSpeedTrend(true, consumer: consumer) }
            .onDisappear { monitor.showSpeedTrend(false, consumer: consumer) }
    }
}

struct BodySpeedTrendInput: Equatable, Sendable {
    var points: [BodySpeedTrendPoint]
    var days: Int
    var windowSeconds: Int
    var preferredModels: [String]
    var minute: Int64
    var error: String?
    var resetMarkers: [BodySpeedResetMarker] = []
    var palette: [String: String] = [:]
    var now: Date { Date(timeIntervalSince1970: Double(minute * 60)) }
}

/// Bounded display projection. Distribution preparation happens on the persistence actor,
/// never on hover/scroll, and no line interpolates across an empty interval.
struct BodySpeedTrendProjection {
    let models: [String]
    let preferredModel: String?
    let focusModel: String?
    let visiblePoints: [BodySpeedTrendPoint]
    let yBounds: ClosedRange<Double>
    let first: BodySpeedTrendPoint?
    let last: BodySpeedTrendPoint?
    let resets: [BodySpeedResetMarker]

    init(input: BodySpeedTrendInput, selectedModel: String?) {
        let now = input.now.timeIntervalSince1970
        let start = now - Double(input.windowSeconds)
        let points = input.points.filter {
            $0.isDistribution && Double($0.bucketEnd!) > start && Double($0.bucketStart) < now
        }.sorted { $0.bucketStart == $1.bucketStart ? $0.model < $1.model : $0.bucketStart < $1.bucketStart }
        models = Set(points.map(\.model)).sorted()
        let modelSet = Set(models)
        preferredModel = input.preferredModels.first { modelSet.contains($0) } ?? models.first
        let focus = selectedModel == "*" ? nil : selectedModel.flatMap { modelSet.contains($0) ? $0 : nil } ?? preferredModel
        focusModel = focus
        visiblePoints = points.filter { focus == nil || $0.model == focus }
        let low = visiblePoints.compactMap(\.lowerQuartile).min() ?? 0
        let high = visiblePoints.compactMap(\.upperQuartile).max() ?? 10
        let padding = max(3, (high - low) * 0.15)
        yBounds = max(0, low - padding)...max(10, high + padding)
        first = visiblePoints.first
        last = visiblePoints.last
        resets = input.resetMarkers.filter {
            $0.observedAt.timeIntervalSince1970 >= start && $0.observedAt.timeIntervalSince1970 <= now
        }
    }

    func selected(at date: Date) -> [BodySpeedTrendPoint] {
        let time = date.timeIntervalSince1970
        return visiblePoints.filter { Double($0.bucketStart) <= time && time < Double($0.bucketEnd!) }
    }
}

struct BodySpeedTrendContent: View, Equatable {
    let input: BodySpeedTrendInput
    let compact: Bool
    let source: ObjectIdentifier
    let selectWindow: (Int) -> Void
    @Environment(\.colorScheme) private var inheritedScheme
    @State private var selectedTime: Date?
    @State private var selectedModel: String?
    private var ink: Color { compact ? .white : .primary }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.compact == rhs.compact && lhs.source == rhs.source
    }
    private var caption: String {
        let width = input.days == 1 ? "30分钟" : input.days == 7 ? "2小时" : "6小时"
        return "\(width)分布 · P25–P75 / 中位数 · TPS"
    }
    private var rangePicker: some View {
        HStack(spacing: 3) {
            ForEach([86400, 604800, 2592000], id: \.self) { seconds in
                Button { selectWindow(seconds); selectedTime = nil } label: {
                    Text(seconds == 86400 ? "24小时" : seconds == 604800 ? "7天" : "30天")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(input.windowSeconds == seconds ? Color.white : ink.opacity(0.8))
                        .background(RoundedRectangle(cornerRadius: 5).fill(input.windowSeconds == seconds ? Color.blue : ink.opacity(0.07)))
                }.buttonStyle(.plain)
                    .accessibilityLabel("速度分布范围 " + (seconds == 86400 ? "24小时" : seconds == 604800 ? "7天" : "30天"))
                    .accessibilityValue(input.windowSeconds == seconds ? "已选择" : "未选择")
            }
        }.frame(width: compact ? 170 : 205)
    }
    var body: some View {
        let projection = BodySpeedTrendProjection(input: input, selectedModel: selectedModel)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("速度分布").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink).fixedSize()
                if !compact { Text(caption).font(.system(size: 10)).foregroundStyle(ink.opacity(0.75)).lineLimit(1) }
                Spacer(minLength: 4)
                rangePicker
            }
            if compact { Text(caption).font(.system(size: 10)).foregroundStyle(ink.opacity(0.75)) }
            HStack(spacing: 5) {
                Button("全部") { selectedModel = "*"; selectedTime = nil }.buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(projection.focusModel == nil ? ink : ink.opacity(0.55))
                ForEach(projection.models, id: \.self) { model in
                    Button { selectedModel = model; selectedTime = nil } label: {
                        HStack(spacing: 4) {
                            Circle().fill(ModelUsagePresentation.color(for: model)).frame(width: 6, height: 6)
                            Text(model.replacingOccurrences(of: "gpt-", with: "")).lineLimit(1).font(.system(size: 10))
                        }.padding(.horizontal, 7).padding(.vertical, 4)
                            .foregroundStyle(projection.focusModel == model ? ink : ink.opacity(0.55))
                            .background(RoundedRectangle(cornerRadius: 5).fill(projection.focusModel == model ? ink.opacity(0.12) : .clear))
                    }.buttonStyle(.plain)
                }
            }
            Chart {
                ForEach(projection.resets) { reset in
                    RectangleMark(xStart: .value("上次额度记录", max(reset.previousAt, input.now.addingTimeInterval(-Double(input.windowSeconds)))),
                        xEnd: .value("额度回升观测", reset.observedAt), yStart: .value("下界", projection.yBounds.lowerBound),
                        yEnd: .value("上界", projection.yBounds.upperBound))
                        .foregroundStyle(Color.cyan.opacity(0.07))
                    RuleMark(x: .value("额度回升观测", reset.observedAt))
                        .foregroundStyle(Color.cyan.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            if reset.id == projection.resets.last?.id {
                                Text("额度回升 \(reset.observedAt.formatted(.dateTime.hour().minute()))")
                                    .font(.system(size: 8)).foregroundStyle(ink.opacity(0.85))
                            }
                        }
                }
                ForEach(projection.visiblePoints) { point in
                    RectangleMark(xStart: .value("区间开始", Date(timeIntervalSince1970: Double(point.bucketStart))),
                        xEnd: .value("区间结束", Date(timeIntervalSince1970: Double(point.bucketEnd!))),
                        yStart: .value("P25", point.lowerQuartile!), yEnd: .value("P75", point.upperQuartile!))
                        .foregroundStyle(ModelUsagePresentation.color(for: point.model).opacity(compact ? 0.30 : 0.23))
                    RuleMark(xStart: .value("区间开始", Date(timeIntervalSince1970: Double(point.bucketStart))),
                        xEnd: .value("区间结束", Date(timeIntervalSince1970: Double(point.bucketEnd!))),
                        y: .value("中位数 TPS", point.median!))
                        .foregroundStyle(ModelUsagePresentation.color(for: point.model))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: point.isPartial == true ? [3, 2] : []))
                        .accessibilityLabel(point.model + " 正文速度分布")
                        .accessibilityValue("中位数 \(point.median!, specifier: "%.1f") TPS，P25 \(point.lowerQuartile!, specifier: "%.1f")，P75 \(point.upperQuartile!, specifier: "%.1f")，\(point.sampleCount)段正文")
                }
            }
            .chartXSelection(value: $selectedTime)
            .chartXScale(domain: input.now.addingTimeInterval(-Double(input.windowSeconds))...input.now)
            .chartYScale(domain: projection.yBounds)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: compact ? 3 : 5)) { _ in
                    AxisValueLabel(format: input.days == 1 ? Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits) : Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits))
                        .font(.system(size: 9)).foregroundStyle(ink.opacity(0.7))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(ink.opacity(0.06))
                    AxisValueLabel().font(.system(size: 9)).foregroundStyle(ink.opacity(0.7))
                }
            }
            .chartLegend(.hidden)
            .frame(height: compact ? 140 : 185)
            .overlay { if projection.visiblePoints.isEmpty { Text("等待分布采样 · 每区间至少3个五分钟桶、6段正文").font(.caption).foregroundStyle(ink.opacity(0.75)) } }
            if projection.focusModel != nil, let last = projection.last {
                Text("最近区间中位数 \(last.median!, specifier: "%.1f") TPS\(last.isPartial == true ? " · 区间未满" : "")")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(ink)
            }
            if let selectedTime {
                let selected = projection.selected(at: selectedTime)
                if selected.isEmpty {
                    Text("该时段没有足够分布采样").font(.system(size: 10)).foregroundStyle(ink.opacity(0.75))
                } else {
                    ForEach(selected) { point in
                        Text("\(Date(timeIntervalSince1970: Double(point.bucketStart)).formatted(.dateTime.month().day().hour().minute())) · \(point.model) · 中位数 \(point.median!, specifier: "%.1f") TPS · P25–P75 \(point.lowerQuartile!, specifier: "%.1f")–\(point.upperQuartile!, specifier: "%.1f") · \(point.bucketCount!)桶 / \(point.sampleCount)段 · 加权均速 \(point.tokensPerSecond, specifier: "%.1f") TPS")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(ink.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("色带为五分钟均速的中间50%，横线为中位数；点击查看数值。空档留空。")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.75))
            }
            if !projection.resets.isEmpty {
                Text("蓝线为额度回升首次观测，阴影为可定位区间；不是服务器精确重置时刻。")
                    .font(.system(size: 9)).foregroundStyle(ink.opacity(0.7))
            }
            if let error = input.error { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
        .environment(\.colorScheme, compact ? .dark : inheritedScheme)
        .onChange(of: projection.models, initial: true) { _, values in
            if selectedModel != "*", selectedModel == nil || !values.contains(selectedModel ?? "") { selectedModel = projection.preferredModel }
        }
    }
}
