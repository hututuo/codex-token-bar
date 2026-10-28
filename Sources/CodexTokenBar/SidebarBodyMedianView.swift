import SwiftUI

/// Demand-driven numeric read; closed/occluded sidebars do no work. This owns no
/// log scanner, network client, schema, timer publisher, or animation timeline.
struct QuotaSidebarBodySpeedReadings: View {
    @ObservedObject var monitor: LiveRateMonitor
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
        SidebarBodyMedianContent(snapshot: displayedSnapshot,
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
    let error: String?
    let onOpen: () -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { a.snapshot == b.snapshot && a.error == b.error }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                Text("正文 TPS").font(.system(size: 9, weight: .semibold))
                Text("中位数 · 近3小时").font(.system(size: 8)).foregroundStyle(.white.opacity(0.75))
                if let error { Text(error).font(.system(size: 9)).foregroundStyle(.orange) }
                else if let snapshot, !snapshot.series.isEmpty {
                    ForEach(snapshot.series) { series in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 3) {
                                Circle().fill(ModelUsagePresentation.color(for: series.model)).frame(width: 4, height: 4)
                                Text(series.model.replacingOccurrences(of: "gpt-", with: ""))
                                    .font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(series.current.map { String(format: "%.1f", $0.median) } ?? "—")
                                    .font(.system(size: 18, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                Text("中位").font(.system(size: 7)).foregroundStyle(.white.opacity(0.75))
                            }
                            SidebarBodyMedianLine(series: series).frame(height: 32)
                            Text(Self.interval(snapshot.end)).font(.system(size: 7)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.75)).frame(maxWidth: .infinity)
                        }.frame(width: 66).padding(.vertical, 2)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: QuotaSidebarContentMeasurementKey.self,
                                    value: QuotaSidebarContentMeasurement(speedRowHeight: proxy.size.height + 6))
                            })
                            .help(Self.description(series, end: snapshot.end))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.description(series, end: snapshot.end))
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
            return "\(time) 中位数 \(String(format: "%.1f", point.median)) TPS，\(point.bucketCount)桶、\(point.sampleCount)段正文"
        }.joined(separator: "；")
        return series.model + " · " + readings + "。各模型纵轴独立；缺样本不连线。"
    }
}

private struct SidebarBodyMedianLine: View {
    let series: SidebarBodyMedian.Series
    var body: some View {
        Canvas { context, size in
            let bounds = series.bounds
            let color = ModelUsagePresentation.color(for: series.model)
            var path = Path(), previous = false
            for (index, point) in series.slots.enumerated() {
                let x = 2 + (CGFloat(index) + 0.5) / 6 * (size.width - 4)
                guard let point else {
                    previous = false
                    let gap = Path(CGRect(x: x - 1.5, y: size.height - 2, width: 3, height: 1))
                    context.fill(gap, with: .color(.white.opacity(0.3)))
                    continue
                }
                let y = size.height - 3 - (point.median - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * (size.height - 6)
                let position = CGPoint(x: x, y: y)
                if previous { path.addLine(to: position) } else { path.move(to: position) }
                previous = true
                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(color))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}
