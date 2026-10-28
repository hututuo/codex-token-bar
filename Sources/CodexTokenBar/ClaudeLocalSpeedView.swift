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
        history.series.filter { allowed.contains($0.dimensions.client) && $0.dimensions.displayMode == mode.rawValue && $0.rolling30m != nil }
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
            if !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow { Text("模型 / 客户端"); Text("5分钟"); Text("15分钟"); Text("30分钟") }.foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GridRow {
                            Text(ModelUsagePresentation.label(for: row.dimensions.model) + " · " + clientTitle(row.dimensions.client))
                                .foregroundStyle(ModelUsagePresentation.color(for: row.dimensions.model)).lineLimit(1)
                            Text(display(row.rolling5m)); Text(display(row.rolling15m)); Text(display(row.rolling30m))
                        }
                    }
                }.font(.system(size: 10)).monospacedDigit()
                let chartNow = Date()
                Chart {
                    ForEach(rows) { row in
                        ForEach(ActivitySpeedChartProjection.points(row.fiveMinuteTrend, now: chartNow)) { point in
                            LineMark(x: .value("时间", Date(timeIntervalSince1970: Double(point.bucketStart))),
                                y: .value("活动速度", point.rate),
                                series: .value("连续段", row.id + ":" + String(point.segment)))
                                .foregroundStyle(ModelUsagePresentation.color(for: row.dimensions.model))
                            PointMark(x: .value("时间", Date(timeIntervalSince1970: Double(point.bucketStart))),
                                y: .value("活动速度", point.rate))
                                .foregroundStyle(ModelUsagePresentation.color(for: row.dimensions.model))
                        }
                    }
                }
                .chartXScale(domain: chartNow.addingTimeInterval(-1800)...chartNow)
                .chartPlotStyle { plot in plot.clipped() }
                .frame(height: 105)
            }
            Text(history.issue ?? "活动估算 · 每5分钟汇总 · Codex 正文测速另计")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.task {
            history.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { history.refresh() }
            }
        }
    }
    private func display(_ aggregate: ActivitySpeedAggregate?) -> String {
        aggregate.map { LiveRateSnapshot.rateDisplayText($0.outputRate) } ?? "—"
    }
    private func clientTitle(_ value: String) -> String {
        switch value { case "claudeCode": "Claude CLI"; case "claudeDesktop": "Claude Desktop"; default: value.capitalized }
    }
}
