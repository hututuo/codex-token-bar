import SwiftUI

struct ActivitySection: View {
    let dailyUsage: [DayUsage]
    let cacheDaily: [TokenCacheBucket]
    let quotaDaily: [QuotaHistoryDailyBucket]
    @Binding var selectedMode: ActivityMode

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Token 活动")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                ActivityModeSelector(selectedMode: $selectedMode)
            }

            TokenHeatmap(dailyUsage: dailyUsage, cacheDaily: cacheDaily, quotaDaily: quotaDaily, mode: selectedMode)
        }
        .frame(maxWidth: 980)
    }
}

struct ActivityModeSelector: View {
    @Binding var selectedMode: ActivityMode

    private let regularModes: [ActivityMode] = [.daily, .weekly, .cumulative]
    private let specialModes: [ActivityMode] = [.cacheHitRate, .quotaRemaining]

    var body: some View {
        HStack(spacing: 4) {
            Text("模式")
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            HStack(spacing: 2) {
                ForEach(regularModes) { mode in
                    modeButton(mode, width: 42)
                }

                HStack(spacing: 2) {
                    ForEach(specialModes) { mode in
                        modeButton(mode, width: 42, groupedSpecial: true)
                    }
                }
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.accentBlue.opacity(0.26), lineWidth: 1)
                )
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.raisedBackground)
            )
        }
    }

    private func modeButton(_ mode: ActivityMode, width: CGFloat, groupedSpecial: Bool = false) -> some View {
        Button {
            selectedMode = mode
        } label: {
            Text(mode.rawValue)
                .font(.system(size: groupedSpecial ? 12 : 13, weight: selectedMode == mode ? .semibold : .medium))
                .foregroundStyle(labelColor(for: mode))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: width, height: 25)
                .background(background(for: mode))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Token 活动模式 \(mode.rawValue)")
        .accessibilityValue(selectedMode == mode ? "已选择" : "未选择")
        .accessibilityHint("切换 Token 活动显示模式")
    }

    private func labelColor(for mode: ActivityMode) -> Color {
        return .primary
    }

    @ViewBuilder
    private func background(for mode: ActivityMode) -> some View {
        if selectedMode == mode {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.accentBlue.opacity(mode.isSpecial ? 0.13 : 0.18))
        } else {
            Color.clear
        }
    }
}
