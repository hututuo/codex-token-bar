import SwiftUI

/// Shares the existing monitor's publication cadence; no view-owned timer.
struct CacheUsageAdviceView: View {
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var retention: CacheRetentionStore
    var onOpenSuggestions: () -> Void
    @AppStorage("cacheHitAdviceEnabled") private var enabled = true
    @AppStorage("cacheHitAdviceDismissed") private var dismissedID = ""

    var body: some View {
        let advice = monitor.totalSnapshot.cacheAdvice
        let warning = advice?.shouldRemind(enabled: enabled, dismissedID: dismissedID) == true
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: warning ? "exclamationmark.circle" : "square.stack.3d.up")
                    .foregroundStyle(warning ? .orange : .secondary)
                Text("最近请求缓存命中率").fontWeight(.medium)
                Spacer(minLength: 4)
                Text(advice.flatMap { $0.hasValidHitRate ? String(format: "%.1f%%", $0.hitRate * 100) : nil } ?? "等待缓存数据")
                    .monospacedDigit()
                Toggle("低命中提醒", isOn: $enabled).toggleStyle(.checkbox)
            }
            if let advice, warning {
                HStack(alignment: .top) {
                    VStack(alignment: .leading,spacing: 5) {
                        Text("本次缓存命中偏低（\(advice.hitRate*100,specifier: "%.1f")%） · \(advice.displayTitle)\(advice.affectedThreads > 1 ? " 等 \(advice.affectedThreads) 个会话" : "")")
                            .help("会话 ID：\(advice.threadID)")
                        Text(CacheRetentionCopy.recommendation(retention.adviceAnalysis)).fontWeight(.semibold)
                        Text(advice.idleGapSeconds.map { "本轮实际间隔：\(CacheRetentionCopy.minutes($0*1_000_000))" } ?? "本轮实际间隔：暂未取得")
                        Text("等待较久、切换模型或上下文变化都可能影响缓存。")
                        Button(action: onOpenSuggestions) {
                            Label("查看续问建议",systemImage: "chart.xyaxis.line").fontWeight(.semibold)
                        }.buttonStyle(.borderedProminent).tint(.teal).controlSize(.small)
                    }
                    Spacer(minLength: 4)
                    Button { dismissedID = advice.presentationID } label: {
                        Label("关闭提醒", systemImage: "xmark").fontWeight(.semibold)
                    }.buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("关闭本次缓存提醒")
                }.foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10))
        .padding(8)
        .background(warning ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .help("请求用量写入后更新。输入至少 2 万 Token、单次请求命中低于 30% 时立即提醒；随实时监控运行。")
    }
}
