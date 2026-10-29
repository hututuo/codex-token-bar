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
                ActivitySpeedHistoryController.shared.refreshDayTrend(force: true)
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
    private let mode = ActivitySpeedDisplayMode.agentSpeed
    private var rates: [ModelRateContribution] {
        ClientLocalRuntimePresentation.rates(codex: [], claude: local.projection(allowed: allowed).modelRates,
            allowed: allowed, mode: mode, upstreamCodex: AgentSpeedDisplayRuntime.modelRates(snapshot: upstream.snapshot, source: .codex, now: Date()), others: upstream.externalModelRates(allowed: allowed))
    }
    private var hasCoverage: Bool {
        let codex = allowed.contains("codex") && upstream.snapshot.sources.contains { $0.kind == .codex && $0.available }
        return codex || local.projection(allowed: allowed).sourceAvailable || upstream.hasCoverage(allowed: allowed)
    }
    @State private var trendConsumer = UUID()
    @State private var windowSeconds = 43200
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ActivityRateUnit.preferenceKey) private var unitRaw = ActivityRateUnit.tokens.rawValue
    @AppStorage(ActivityRateUnit.exchangeRateKey) private var exchangeRate = ActivityRateUnit.defaultExchangeRate
    private var unit: ActivityRateUnit { ActivityRateUnit(rawValue: unitRaw) ?? .tokens }
    private var rows: [ActivitySpeedSeries] {
        history.daySeries.filter { allowed.contains($0.dimensions.client) && $0.dimensions.displayMode == mode.rawValue && !$0.halfMinuteTrend.isEmpty }
    }
    private var visibleClients: [String] {
        var clients = Set(rows.map { $0.dimensions.client })
        if allowed.contains("codex") { clients.insert("codex") }
        for client in allowed where client != "codex" {
            let localEnabled = local.projection(allowed: [client]).enabled
            let otherEnabled = upstream.snapshot.sources.contains { $0.enabled && ActivitySourceConfiguration.client(for: $0.kind) == client }
            if localEnabled || otherEnabled { clients.insert(client) }
        }
        return clients.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("活动速率 · Agent Speed").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(hasCoverage ? unit.text(unit.value(total: rates.reduce(0) { $0 + $1.tokensPerSecond }, rates: rates, exchangeRate: exchangeRate)) + " " + unit.rawValue : "—")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            HStack {
                Text("Agent Speed 本地活动速率").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ActivityRateUnitControl()
            }
            Picker("活动速率范围", selection: $windowSeconds) {
                Text("12小时").tag(43200)
                Text("24小时").tag(86400)
            }.pickerStyle(.segmented).frame(maxWidth: 205)
            if rates.isEmpty && rows.isEmpty {
                Text("等待本地活动记录").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(visibleClients, id: \.self) { client in
                ClientActivityTrendView(client: clientTitle(client), rows: rows.filter { $0.dimensions.client == client },
                    now: history.dayAsOf, windowSeconds: windowSeconds, unit: unit, exchangeRate: exchangeRate).equatable()
            }
            Text(history.dayIssue ?? "每30秒平均速率 · 无活动采样的时段留空")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onAppear { history.showDayTrend(true, consumer: trendConsumer) }
        .onDisappear { history.showDayTrend(false, consumer: trendConsumer) }
        .onChange(of: scenePhase) { _, value in history.showDayTrend(value == .active, consumer: trendConsumer) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled && scenePhase == .active { history.refreshDayTrend() }
            }
        }
    }

    private func clientTitle(_ value: String) -> String {
        switch value { case "claudeCode": "Claude CLI"; case "claudeDesktop": "Claude Desktop"; default: value.capitalized }
    }
}

/// Client boundaries are explicit; a model with the same name in two clients
/// never becomes a single line or shares the other client's activity interval.
struct ClientActivityTrendView: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.client == rhs.client && lhs.rows == rhs.rows && lhs.now == rhs.now && lhs.windowSeconds == rhs.windowSeconds && lhs.unit == rhs.unit && lhs.exchangeRate == rhs.exchangeRate
    }
    @ObservedObject private var palette = SpeedDisplayPreferences.shared
    let client: String
    let rows: [ActivitySpeedSeries]
    let now: Date
    let windowSeconds: Int
    let unit: ActivityRateUnit
    let exchangeRate: Double
    @State private var selectedTime: Date?
    private struct Entry: Identifiable {
        let row: ActivitySpeedSeries
        let point: ActivitySpeedChartProjection.Point
        let value: Double
        var id: String { row.id + ":" + String(point.bucketStart) }
    }
    private var entries: [Entry] {
        rows.flatMap { row -> [Entry] in
            guard let factor = unit.value(total: 1, rates: [.init(model: row.dimensions.model, tokensPerSecond: 1)], exchangeRate: exchangeRate) else { return [] }
            return ActivitySpeedChartProjection.points(row.halfMinuteTrend, now: now, windowSeconds: Double(windowSeconds), bucketSeconds: 30)
                .map { Entry(row: row, point: $0, value: $0.rate * factor) }
        }
    }
    var body: some View {
        let values = entries
        VStack(alignment: .leading, spacing: 6) {
            Text(client).font(.system(size: 12, weight: .semibold))
            Chart {
                ForEach(values) { entry in
                    LineMark(x: .value("时间", Date(timeIntervalSince1970: Double(entry.point.bucketStart))),
                        y: .value(unit.rawValue, entry.value),
                        series: .value("连续段", entry.row.id + ":" + String(entry.point.segment)))
                        .foregroundStyle(ModelUsagePresentation.color(for: entry.row.dimensions.model))
                        .lineStyle(.init(lineWidth: 1.4))
                    PointMark(x: .value("时间", Date(timeIntervalSince1970: Double(entry.point.bucketStart))), y: .value(unit.rawValue, entry.value))
                        .symbolSize(5).foregroundStyle(ModelUsagePresentation.color(for: entry.row.dimensions.model))
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-Double(windowSeconds))...now)
            .chartYScale(domain: 0...max(unit == .tokens ? 1 : 0.0001, (values.map(\.value).max() ?? 0) * 1.12))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute())
            } }
            .chartXSelection(value: $selectedTime)
            .chartPlotStyle { plot in plot.clipped() }
            .frame(height: 165)
            HStack(spacing: 12) {
                ForEach(Array(Set(values.map { $0.row.dimensions.model })).sorted(), id: \.self) { model in
                    Label(ModelUsagePresentation.label(for: model), systemImage: "circle.fill")
                        .foregroundStyle(ModelUsagePresentation.color(for: model)).font(.system(size: 10)).lineLimit(1)
                }
            }
            if let selectedTime {
                let selected = values.filter { Double($0.point.bucketStart) <= selectedTime.timeIntervalSince1970 && selectedTime.timeIntervalSince1970 < Double($0.point.bucketStart + 60) }
                if selected.isEmpty { Text("该时段没有活动采样").font(.caption2).foregroundStyle(.secondary) }
                ForEach(selected) { entry in
                    Text("\(Date(timeIntervalSince1970: Double(entry.point.bucketStart)).formatted(.dateTime.month().day().hour().minute().second())) · \(ModelUsagePresentation.label(for: entry.row.dimensions.model)) · \(unit.text(entry.value)) \(unit.rawValue)")
                        .font(.system(size: 10)).monospacedDigit()
                }
            }
            if values.isEmpty { Text(unit == .yuan ? "暂无可换算的活动速率采样" : "暂无活动速率采样").font(.caption2).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(client + (windowSeconds == 86400 ? "全天活动速率" : "近12小时活动速率") + "，每30秒一个点")
    }
}
