import SwiftUI

/// Demand-driven numeric read; closed/occluded sidebars do no work. This owns no
/// log scanner, network client, schema, timer publisher, or animation timeline.
struct QuotaSidebarBodySpeedReadings: View {
    @ObservedObject var monitor: LiveRateMonitor
    var latest: [ModelSpeedSummary] = []
    var active = true
    let onOpen: () -> Void
    @State private var exposed = false
    @State private var loadedSource: String?
    @State private var snapshot: SidebarBodyMedian?
    @State private var error: String?
    private var source: String? { monitor.sidebarBodyMedianSource }
    private var request: String? { active && exposed ? source : nil }

    private var displayedSnapshot: SidebarBodyMedian? {
        #if DEBUG
        // Layout tests supply a projection without launching a real collector or
        // depending on the test runner window's macOS occlusion state.
        if let fixture = monitor.sidebarMedianFixture { return fixture }
        #endif
        return loadedSource == source ? snapshot : nil
    }
    var body: some View {
        SidebarBodyMedianContent(snapshot: displayedSnapshot, latest: latest,
            error: loadedSource == source ? error : nil, onOpen: onOpen).equatable()
            .background(AnimationVisibilityProbe { exposed = $0 })
            .task(id: request) {
                guard let request else { return }
                while !Task.isCancelled {
                    do {
                        let value = try await monitor.readSidebarBodyMedian()
                        guard !Task.isCancelled, source == request else { return }
                        loadedSource = request
                        if snapshot != value { snapshot = value }
                        error = nil
                    } catch {
                        guard !Task.isCancelled, source == request else { return }
                        loadedSource = request; snapshot = nil; self.error = "读取失败"
                    }
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
    }
}

struct SidebarBodyMedianContent: View, Equatable {
    let snapshot: SidebarBodyMedian?
    var latest: [ModelSpeedSummary] = []
    let error: String?
    let onOpen: () -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { a.snapshot == b.snapshot && a.latest == b.latest && a.error == b.error }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 4) {
                HStack {
                    Text("正文 TPS").font(.system(size: 9, weight: .semibold))
                    Spacer(minLength: 2)
                    Text("近3小时").font(.system(size: 7)).foregroundStyle(.white.opacity(0.75))
                }.frame(width: 74)
                if let error { Text(error).font(.system(size: 9)).foregroundStyle(.orange) }
                if !latest.isEmpty {
                    ForEach(latest) { reading in
                        let series = snapshot?.series.first { $0.model == reading.model }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 3) {
                                Circle().fill(ModelUsagePresentation.color(for: reading.model)).frame(width: 4, height: 4)
                                Text(reading.model.replacingOccurrences(of: "gpt-", with: ""))
                                    .font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                                Spacer(minLength: 1)
                                Text(reading.tokensPerSecond, format: .number.precision(.fractionLength(1)))
                                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().fixedSize()
                            }
                            if let series { SidebarBodyMedianBars(series: series).frame(height: 32) }
                            else { Text("趋势待采样").font(.system(size: 7)).foregroundStyle(.secondary).frame(height: 32) }
                            Text(series?.current.map { "中位 \(String(format: "%.1f", $0.median))" } ?? "中位 —").font(.system(size: 7)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.75)).frame(maxWidth: .infinity)
                        }.frame(width: 74).padding(.vertical, 2)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: QuotaSidebarContentMeasurementKey.self,
                                    value: QuotaSidebarContentMeasurement(speedRowHeight: proxy.size.height + 6))
                            })
                            .help("\(reading.model) · 最新 \(String(format: "%.1f", reading.tokensPerSecond)) TPS。" + (series.map { Self.description($0, end: snapshot?.end ?? 0) } ?? "趋势待采样"))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(reading.model) · 最新 \(String(format: "%.1f", reading.tokensPerSecond)) TPS。" + (series.map { Self.description($0, end: snapshot?.end ?? 0) } ?? "趋势待采样"))
                    }
                } else { Text("等待采样").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)) }
            }.foregroundStyle(.white).frame(maxWidth: .infinity)
                .padding(.horizontal, 5).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(SidebarPulseButtonStyle())
            .help("最近3小时，每半小时一个中位数；当前未满区间不计。点击查看测速记录")
    }

    static func interval(_ end: Int64) -> String {
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return Date(timeIntervalSince1970: Double(end - 1800)).formatted(style) + "–" + Date(timeIntervalSince1970: Double(end)).formatted(style)
    }
    static func description(_ series: SidebarBodyMedian.Series, end: Int64) -> String {
        let readings = series.slots.enumerated().map { i, point in
            let time = interval(end - Int64(5 - i) * 1800)
            guard let point else { return "\(time) 采样不足" }
            return "\(time) 中位数 \(String(format: "%.1f", point.median)) TPS，中间50% \(String(format: "%.1f", point.lower))–\(String(format: "%.1f", point.upper)) TPS，\(point.bucketCount)桶、\(point.sampleCount)段正文"
        }.joined(separator: "；")
        return series.model + " · " + readings + "。色柱表示中间50%的分布，横线表示中位数；各模型纵轴独立，缺样本留空。"
    }
}

private struct SidebarBodyMedianBars: View {
    let series: SidebarBodyMedian.Series
    var body: some View {
        Canvas { context, size in
            let bounds = series.bounds
            let color = ModelUsagePresentation.color(for: series.model)
            let step = size.width / 6
            let bottom = size.height - 3
            func y(_ value: Double) -> CGFloat {
                bottom - (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * (bottom - 3)
            }
            context.fill(Path(CGRect(x: 0, y: bottom, width: size.width, height: 1)), with: .color(.white.opacity(0.055)))
            for (index, point) in series.slots.enumerated() {
                let left = CGFloat(index) * step + 1
                let width = step - 2
                guard let point else {
                    context.fill(Path(CGRect(x: left + width / 2 - 1.5, y: bottom, width: 3, height: 1)), with: .color(.white.opacity(0.3)))
                    continue
                }
                // Match option 1: floating P25–P75 column with a median tick.
                // Not a zero-baseline bar, confidence interval, or connected line.
                context.fill(Path(CGRect(x: left, y: y(point.upper), width: width,
                    height: max(1, y(point.lower) - y(point.upper)))), with: .color(color.opacity(0.25)))
                var tick = Path()
                tick.move(to: CGPoint(x: left, y: y(point.median)))
                tick.addLine(to: CGPoint(x: left + width, y: y(point.median)))
                context.stroke(tick, with: .color(color), lineWidth: 2)
            }
        }.accessibilityHidden(true)
    }
}
