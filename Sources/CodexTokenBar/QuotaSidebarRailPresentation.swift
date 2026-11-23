import SwiftUI

/// Values for one render, shared by layout, modules and morph endpoints.
/// No cross-refresh cache: quota status and user selections remain current.
struct QuotaSidebarRailPresentation {
    let allowedClients: Set<String>
    let supportsCodex: Bool
    let quotaSelection: ClientQuotaSelection
    let sidebarItems: [QuotaSidebarItem]
    let compactItems: [QuotaSidebarItem]
    let expandedItems: [QuotaSidebarItem]
    let quotaItems: [ClientQuotaItem]
    let recentBodySpeeds: [ModelSpeedSummary]
    let liveRateSnapshot: LiveModelRateSnapshot
    let runningSummary: RunningThreadSummary
    let selectedModelRows: [ModelTokenBreakdown]
    let fullScale: Double

    var barRates: [ModelRateContribution] { liveRateSnapshot.colorRates }
    var rateFraction: CGFloat {
        CGFloat(QuotaSidebarRatePresentation.fraction(rate: liveRateSnapshot.total,
            fullScale: fullScale, available: liveRateSnapshot.available))
    }
    var rateText: String {
        guard liveRateSnapshot.enabled else { return "已关闭" }
        guard liveRateSnapshot.available else { return "待读取" }
        return liveRateSnapshot.valueText + " tok/s"
    }
    var runningText: String {
        switch runningSummary.freshness {
        case .fresh: "\(runningSummary.main) 主 · \(runningSummary.subagents) 子"
        case .stale: "\(runningSummary.total) 运行 · 上次数据"
        case .loading: "读取任务中"
        case .unavailable: "任务未知"
        }
    }
    func railLayout(_ height: CGFloat) -> ClientRailLayout {
        ClientQuotaPodLayout.railLayout(items: compactItems, quotas: quotaItems, availableHeight: Double(height))
    }
}

/// Drop a hidden chart's observers and Canvas, retaining only its last measured
/// height so the surrounding native morph endpoints do not move on collapse.
struct SidebarDeferredContent<Content: View>: View {
    let active: Bool
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        Group {
            if active {
                content().background(GeometryReader { proxy in
                    Color.clear.preference(key: SidebarDeferredHeight.self, value: proxy.size.height)
                })
            } else {
                Color.clear.frame(height: height)
            }
        }
        .onPreferenceChange(SidebarDeferredHeight.self) { value in
            if active, let value, value.isFinite, value >= 0 { height = value }
        }
    }
}

private struct SidebarDeferredHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}
