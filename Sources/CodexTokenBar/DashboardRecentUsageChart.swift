import SwiftUI

/// The chart can inspect another client without changing the page's cost table,
/// heatmap, or ranking. An unavailable saved choice follows the page again.
enum RecentChartClientScope {
    static let key = "recentChartClientScope.v1"
    static let followDashboard = "dashboard"
    static func resolved(_ selection: String, page: Set<String>, available: [String]) -> Set<String> {
        guard selection != followDashboard,
              selection == "all" || selection == "codex" || available.contains(selection) else { return page }
        return ClientDisplayScope.clients(selection, available: available)
    }
}

struct RecentChartClientSelector: View {
    @Binding var selection: String
    let clients: [String]
    let pageTitle: String
    var body: some View {
        Picker("图表客户端", selection: $selection) {
            Text("跟随主页 · " + pageTitle).tag(RecentChartClientScope.followDashboard)
            Text("汇总").tag("all")
            Text("Codex").tag("codex")
            ForEach(clients.filter { $0 != "codex" && $0 != "all" }, id: \.self) { client in
                Text(ClientDisplayScope.title(client)).tag(client)
            }
        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 180)
            .accessibilityLabel("图表客户端").accessibilityIdentifier("recent-chart-client")
    }
}

struct DashboardRecentUsageChart: View {
    let codex: DashboardSnapshot
    let page: DashboardSnapshot
    let pageClients: Set<String>
    let quota: AccountQuotaSnapshot
    let quotaHistory: QuotaHistorySnapshot
    let attribution: QuotaSelectionAttributionContext?
    @ObservedObject private var clients = MultiClientUsageStore.shared
    @State private var projection = ClientDashboardProjectionCache()
    @AppStorage(RecentChartClientScope.key) private var selection = RecentChartClientScope.followDashboard

    var body: some View {
        let available = clients.displayClientIDs
        let allowed = RecentChartClientScope.resolved(selection, page: pageClients, available: available)
        let includesCodex = allowed.contains("codex")
        let codexOnly = allowed == ["codex"]
        let externalCosts = clients.trendBuckets.filter { allowed.contains($0.client.rawValue) }
        let display = allowed == pageClients ? page : projection.value(codex: codex, clients: clients, allowed: allowed)
        let effectiveSelection = (["dashboard", "all", "codex"] + available).contains(selection) ? selection : RecentChartClientScope.followDashboard
        VStack(alignment: .leading, spacing: 8) {
            RecentUsageChart(
                bins: display.recentBins, hourlyBins: display.hourlyUsage,
                cacheRecentBins: display.cacheUsage.recentBins, cacheHourlyBins: display.cacheUsage.hourly,
                attributionEvents: includesCodex ? codex.cacheUsage.attributionEvents : [],
                attributionEventsComplete: includesCodex && codex.cacheUsage.attributionEventsComplete,
                quotaRecentBins: includesCodex ? quotaHistory.recentBins : [],
                quotaHourlyBins: includesCodex ? quotaHistory.hourlyBins : [],
                currentFiveHourQuotaPresent: includesCodex && quota.fiveHour != nil,
                currentSevenDayQuotaPresent: includesCodex && quota.sevenDay != nil,
                sharedAccountAttributionContext: includesCodex ? attribution : nil,
                pricingAvailable: includesCodex || externalCosts.contains { $0.apiCostMicroUSD != nil },
                quotaCostSource: !codexOnly && includesCodex ? .init(
                    bins: codex.recentBins, hourlyBins: codex.hourlyUsage,
                    cacheRecentBins: codex.cacheUsage.recentBins, cacheHourlyBins: codex.cacheUsage.hourly,
                    attributionEvents: codex.cacheUsage.attributionEvents,
                    settledThrough: codex.settledThrough ?? codex.preciseTimeSeriesGeneratedAt) : nil,
                settledThrough: codex.settledThrough ?? codex.preciseTimeSeriesGeneratedAt,
                unreportedCompactionDates: includesCodex ? codex.cacheUsage.unreportedCompactionDates : [],
                clientSelector: RecentChartClientSelector(selection: Binding(get: { effectiveSelection }, set: { selection = $0 }), clients: available,
                    pageTitle: ClientDisplayScope.title(pageClients.count == 1 ? pageClients.first! : "all")),
                externalCostBuckets: codexOnly ? nil : externalCosts,
                includesCodexCost: includesCodex
            )
            // A prepared result/selection from another source must not survive
            // a client switch, even when both clients have identical timestamps.
            .id(allowed.sorted().joined(separator: ",") + "|" + (codex.homeIdentity ?? ""))
            if !codexOnly && includesCodex {
                Text("Token、调用与金额汇总所选客户端，命中率按输入加权；额度和额度反推仅对应 Codex 账户。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: 980, alignment: .leading)
    }
}
