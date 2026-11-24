import SwiftUI

/// Same source choices as the recent chart, with independent saved selection.
struct DashboardTokenActivity: View {
    let codex: DashboardSnapshot
    let page: DashboardSnapshot
    let pageClients: Set<String>
    let quotaHistory: QuotaHistorySnapshot
    @Binding var selectedMode: ActivityMode
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @State private var projection = ClientDashboardProjectionCache()
    @AppStorage("heatmapClientScope.v1") private var selection = "dashboard"
    @AppStorage("heatmapQuotaSource.v1") private var quotaSelection = "codex"
    @AppStorage("heatmapQuotaPeriod.v1") private var period = "7d"
    @AppStorage(SharedAccountUsageAttributionSettings.priceModelKey) private var priceRaw = OfficialAPIPriceModel.gpt56Sol.rawValue
    @State private var prepared: [HeatmapDayUsage] = []
    @State private var preparedKey = ""
    @State private var preparedInput: HeatmapPreparationInput?

    var body: some View {
        let available = clients.displayClientIDs
        let allowed = RecentChartClientScope.resolved(selection, page: pageClients, available: available)
        let display = allowed == pageClients ? page : projection.value(codex: codex, clients: clients, allowed: allowed)
        let source = ClientQuotaChartSource.resolve(quotaSelection, clients: allowed, histories: clients.quotaHistories)
        let quotaDays = source?.client == "codex" ? quotaHistory.daily : source?.history(in: clients.quotaHistories)?.daily ?? []
        let effectiveSelection = (["dashboard", "all", "codex"] + available).contains(selection) ? selection : "dashboard"
        let key = allowed.sorted().joined(separator: ",") + "|" + (codex.homeIdentity ?? "")
            + "|\(codex.generatedAt.timeIntervalSince1970)|\(codex.exactGeneration ?? 0)"
            + "|\(clients.updatedAt?.timeIntervalSince1970 ?? 0)|\(priceRaw)|\(TimeZone.current.identifier)"
            + "|\(clients.usageChartRevision)"
        let external = clients.dailyBuckets
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("热力图客户端", selection: DashboardSelectionBinding.displayed(effectiveSelection, storage: $selection)) {
                    Text("跟随主页 · " + ClientDisplayScope.title(pageClients.count == 1 ? pageClients.first! : "all")).tag("dashboard")
                    Text("汇总").tag("all")
                    Text("Codex").tag("codex")
                    ForEach(available.filter { $0 != "codex" }, id: \.self) { Text(ClientDisplayScope.title($0)).tag($0) }
                }.pickerStyle(.menu).fixedSize().accessibilityIdentifier("heatmap-client")
                Spacer()
            }
            if selectedMode == .quotaRemaining {
                HStack {
                    if let source {
                        Picker("额度来源", selection: DashboardSelectionBinding.displayed(source.id, storage: $quotaSelection)) {
                            ForEach(ClientQuotaChartSource.options(clients: allowed, histories: clients.quotaHistories)) { Text($0.title).tag($0.id) }
                        }.pickerStyle(.menu).fixedSize().accessibilityIdentifier("heatmap-quota-source")
                        Spacer()
                        Picker("周期", selection: $period) {
                            Text("5小时").tag("5h")
                            Text("7天").tag("7d")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
                    } else {
                        Text("所选客户端尚无本地额度来源").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ActivitySection(dailyUsage: display.dailyUsage, cacheDaily: display.cacheUsage.daily,
                dailyModelBreakdowns: display.cacheUsage.dailyModelBreakdowns, quotaDaily: quotaDays,
                selectedMode: $selectedMode, recordedDaily: preparedKey == key ? prepared : [],
                quotaPeriod: HeatmapQuotaPeriod(rawValue: period) ?? .sevenDay)
            if selectedMode == .quotaRemaining, let source {
                Text(source.title + " · 日内有效采样的剩余额度均值；空白表示没有观测。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: 980, alignment: .leading)
        .task(id: key) {
            let model = OfficialAPIPriceModel.storedValue(for: priceRaw)
            let input = HeatmapPreparationInput(codex: codex, external: external, allowed: allowed, model: model)
            // A successful source check advances updatedAt even when the daily
            // facts are identical. Reuse prices and the prepared day arrays.
            if input == preparedInput {
                preparedKey = key
                return
            }
            let worker = Task.detached(priority: .utility) { [codex, external, allowed, model] in
                HeatmapDayUsage.project(codex: codex, external: external, allowed: allowed, priceModel: model)
            }
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            prepared = value
            preparedInput = input
            preparedKey = key
        }
    }
}

private struct HeatmapPreparationInput: Equatable {
    let home: String?
    let days: [DayUsage]
    let cache: [TokenCacheBucket]
    let models: [ModelTokenBucket]
    let external: [ClientTrendBucket]
    let allowed: Set<String>
    let model: OfficialAPIPriceModel
    let timezone: String

    init(codex: DashboardSnapshot, external: [ClientTrendBucket], allowed: Set<String>, model: OfficialAPIPriceModel) {
        let includesCodex = allowed.contains("codex")
        home = includesCodex ? codex.homeIdentity : nil
        days = includesCodex ? codex.dailyUsage : []
        cache = includesCodex ? codex.cacheUsage.daily : []
        models = includesCodex ? codex.cacheUsage.dailyModelBreakdowns : []
        self.external = external.filter { allowed.contains($0.client.rawValue) }
        self.allowed = allowed
        self.model = model
        timezone = TimeZone.current.identifier
    }
}
