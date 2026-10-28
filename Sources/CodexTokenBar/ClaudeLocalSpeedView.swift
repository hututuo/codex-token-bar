import SwiftUI
import Charts

struct ActivitySpeedDisplayPicker: View {
    @AppStorage(ActivitySpeedDisplayMode.key) private var raw = ActivitySpeedDisplayMode.bar.rawValue
    var body: some View {
        Picker("速度显示", selection: $raw) {
            ForEach(ActivitySpeedDisplayMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }.pickerStyle(.segmented)
            .help("只切换显示；排行榜始终使用 Agent Speed 标准，不会因此开启上报。")
            .onChange(of: raw) {
                MultiClientUsageStore.shared.syncLocalRuntime()
                ActivitySpeedHistoryController.shared.refresh()
            }
    }
}

/// One activity panel for all selected sources. No Claude body/API TPS route.
struct ActivitySpeedSummaryView: View {
    let allowed: Set<String>
    var codexRates: [ModelRateContribution] = []
    var codexAvailable = false
    @ObservedObject private var local = ClaudeLocalRuntime.shared
    @ObservedObject private var upstream = AgentSpeedDisplayRuntime.shared
    @ObservedObject private var history = ActivitySpeedHistoryController.shared
    @AppStorage(ActivitySpeedDisplayMode.key) private var raw = ActivitySpeedDisplayMode.bar.rawValue
    private var mode: ActivitySpeedDisplayMode { .normalized(raw) }
    private var rates: [ModelRateContribution] {
        ClientLocalRuntimePresentation.rates(codex: codexRates, claude: local.projection(allowed: allowed).modelRates,
            allowed: allowed, mode: mode, upstreamCodex: AgentSpeedDisplayRuntime.modelRates(snapshot: upstream.snapshot, source: .codex, now: Date()), others: upstream.externalModelRates(allowed: allowed))
    }
    private var hasCoverage: Bool {
        let codex = allowed.contains("codex") && (mode == .bar ? codexAvailable : upstream.snapshot.sources.contains { $0.kind == .codex && $0.available })
        return codex || local.projection(allowed: allowed).sourceAvailable || upstream.hasCoverage(allowed: allowed)
    }
    private var rows: [ActivitySpeedSeries] {
        history.series.filter { allowed.contains($0.dimensions.client) && $0.dimensions.displayMode == mode.rawValue && !$0.oneMinuteTrend.isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("聚合活动速度").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(hasCoverage ? "\(LiveRateSnapshot.rateDisplayText(rates.reduce(0) { $0 + $1.tokensPerSecond })) t/s" : "—")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            ActivitySpeedDisplayPicker().frame(maxWidth: 280)
            if rates.isEmpty && rows.isEmpty {
                Text("等待本地活动记录").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(Set(rows.map { $0.dimensions.client })).sorted(), id: \.self) { client in
                ClientActivityTrendView(client: clientTitle(client), rows: rows.filter { $0.dimensions.client == client })
            }
            Text(history.issue ?? "近半小时 · 每分钟加权速度 · 空缺表示无活动采样")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.task {
            history.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { history.refresh() }
            }
        }
    }
    private func clientTitle(_ value: String) -> String {
        switch value { case "claudeCode": "Claude CLI"; case "claudeDesktop": "Claude Desktop"; default: value.capitalized }
    }
}

/// Client boundaries are explicit; a model with the same name in two clients
/// never becomes a single line or shares the other client's activity interval.
private struct ClientActivityTrendView: View {
    let client: String
    let rows: [ActivitySpeedSeries]
    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 6) {
            Text(client).font(.system(size: 12, weight: .semibold))
            Chart {
                ForEach(rows) { row in
                    ForEach(ActivitySpeedChartProjection.points(row.oneMinuteTrend, now: now)) { point in
                        LineMark(x: .value("时间", Date(timeIntervalSince1970: Double(point.bucketStart))),
                            y: .value("活动速度", point.rate),
                            series: .value("连续段", row.id + ":" + String(point.segment)))
                            .foregroundStyle(ModelUsagePresentation.color(for: row.dimensions.model))
                        PointMark(x: .value("时间", Date(timeIntervalSince1970: Double(point.bucketStart))),
                            y: .value("活动速度", point.rate))
                            .symbolSize(12)
                            .foregroundStyle(ModelUsagePresentation.color(for: row.dimensions.model))
                    }
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-1800)...now)
            .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 5)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute())
            } }
            .chartPlotStyle { plot in plot.clipped() }
            .frame(height: 140)
            HStack(spacing: 12) {
                ForEach(rows) { row in
                    Label(ModelUsagePresentation.label(for: row.dimensions.model), systemImage: "circle.fill")
                        .foregroundStyle(ModelUsagePresentation.color(for: row.dimensions.model))
                        .font(.system(size: 10)).lineLimit(1)
                }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(client + "近半小时活动速度，每分钟一个点")
    }
}
