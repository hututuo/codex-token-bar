import SwiftUI

/// Shares the existing monitor's publication cadence; no view-owned timer.
struct CacheUsageAdviceView: View {
    @ObservedObject var monitor: LiveRateMonitor
    @AppStorage("cacheHitAdviceEnabled") private var enabled = true
    @State private var dismissed = false

    var body: some View {
        let advice = monitor.totalSnapshot.cacheAdvice
        let warning = enabled && advice?.low == true && !dismissed
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: warning ? "exclamationmark.circle" : "square.stack.3d.up")
                    .foregroundStyle(warning ? .orange : .secondary)
                Text("最近请求缓存命中率").fontWeight(.medium)
                Spacer(minLength: 4)
                Text(advice.map { String(format: "%.1f%%", $0.hitRate * 100) } ?? "等待缓存数据")
                    .monospacedDigit()
                Toggle("低命中提醒", isOn: $enabled).toggleStyle(.checkbox)
            }
            if let advice, warning {
                HStack(alignment: .top) {
                    Text("本次请求缓存命中偏低 · 会话 \(String(advice.threadID.prefix(8)))\(advice.affectedThreads > 1 ? " 等 \(advice.affectedThreads) 个会话" : "")\n可检查是否切换了模型或上下文；这不代表缓存服务故障。")
                    Spacer(minLength: 4)
                    Button("收起") { dismissed = true }.buttonStyle(.plain)
                }.foregroundStyle(.orange)
            }
        }
        .onChange(of: advice?.low) { _, low in if low != true { dismissed = false } }
        .font(.system(size: 10))
        .padding(8)
        .background(warning ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .help("请求用量写入后更新。输入至少 2 万 Token、单次请求命中低于 30% 时立即提醒；随实时监控运行。")
    }
}
