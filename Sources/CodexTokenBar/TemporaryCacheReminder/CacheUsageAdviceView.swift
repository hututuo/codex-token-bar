import SwiftUI

/// Uses the existing live publication cadence; no historical scan or side-store.
struct CacheUsageAdviceView: View {
    @ObservedObject var monitor: LiveRateMonitor
    @AppStorage("cacheHitAdviceEnabled") private var enabled = true
    @AppStorage("cacheHitAdviceDismissed") private var dismissedID = ""

    var body: some View {
        if CacheMissReminderFeature.isEnabled {
            let advice = monitor.totalSnapshot.cacheAdvice
            let warning = advice?.shouldRemind(enabled: enabled, dismissedID: dismissedID) == true
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Toggle("低命中提醒", isOn: $enabled).toggleStyle(.checkbox)
                    Spacer(minLength: 4)
                    if let advice, advice.hasValidHitRate {
                        Text("最近请求 \(advice.hitRate * 100, specifier: "%.1f")%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let advice, warning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("缓存命中偏低 · \(advice.hitRate * 100, specifier: "%.1f")%")
                                .fontWeight(.semibold)
                            Text(advice.displayTitle).lineLimit(2).help(advice.displayTitle)
                            Text("本次请求复用较少，切换模型、思考强度或上下文变化都可能影响缓存。")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { dismissedID = advice.presentationID } label: {
                            Label("关闭提醒", systemImage: "xmark")
                        }.buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel("关闭本次缓存提醒")
                    }
                }
            }
            .font(.system(size: 10))
            .padding(8)
            .background(warning ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8))
            .help("输入至少 2 万 Token、单次请求缓存命中低于 30% 时提醒；新上下文首次请求不提醒。")
        }
    }
}
