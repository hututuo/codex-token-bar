import AppKit
import SwiftUI

private enum TokenDisplayLayout {
    static let metricOutset: CGFloat = 9
}

enum TokenDisplayLockState {
    case unlocked
    case locked

    var systemImage: String {
        switch self {
        case .unlocked:
            return "lock.open"
        case .locked:
            return "lock.fill"
        }
    }

    var helpText: String {
        switch self {
        case .unlocked:
            return "锁定悬浮窗到当前窗口位置"
        case .locked:
            return "解除悬浮窗锁定"
        }
    }
}

private struct TokenDisplayScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var tokenDisplayScale: CGFloat {
        get { self[TokenDisplayScaleKey.self] }
        set { self[TokenDisplayScaleKey.self] = newValue }
    }
}

extension CGFloat {
    func scaled(by scale: CGFloat) -> CGFloat {
        self * Swift.max(scale, 0.1)
    }
}

extension BinaryInteger {
    func scaled(by scale: CGFloat) -> CGFloat {
        CGFloat(self) * Swift.max(scale, 0.1)
    }
}

enum TokenDisplayMode: String, CaseIterable, Identifiable {
    case off
    case floating
    case statusBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "关闭"
        case .floating:
            return "悬浮窗"
        case .statusBar:
            return "状态栏"
        }
    }

    var controlLabel: String {
        label
    }

    var systemImage: String {
        switch self {
        case .off:
            return "slash.circle"
        case .floating:
            return "rectangle.on.rectangle"
        case .statusBar:
            return "menubar.rectangle"
        }
    }
}

struct TokenDisplaySnapshot {
    let title: String
    let status: String
    let rate: Double
    let consumedTokens: Int
    let todayTokens: Int
    let todayRequests: Int
    let quota: AccountQuotaSnapshot
    let updatedAt: Date

    @MainActor
    static func make(store: CodexUsageStore, monitor: LiveRateMonitor, quota: AccountQuotaStore) -> TokenDisplaySnapshot {
        let calendar = Calendar.current
        let today = Date()
        let todayUsage = store.snapshot.dailyUsage.first { calendar.isDate($0.date, inSameDayAs: today) }

        return TokenDisplaySnapshot(
            title: "全会话实时",
            status: monitor.totalSnapshot.status,
            rate: monitor.totalSnapshot.rollingTokensPerSecond,
            consumedTokens: store.snapshot.stats.totalTokens,
            todayTokens: todayUsage?.tokens ?? 0,
            todayRequests: todayUsage?.calls ?? 0,
            quota: quota.snapshot,
            updatedAt: max(store.snapshot.generatedAt, max(monitor.totalSnapshot.updatedAt, quota.snapshot.updatedAt ?? .distantPast))
        )
    }

    var statusBarTitle: String {
        if rate >= 100 {
            return "\(Int(rate.rounded()))/s"
        }
        if rate < 10 {
            return String(format: "%.1f/s", rate)
        }
        return "\(Int(rate.rounded()))/s"
    }

    var compactUsageStatus: String {
        guard quota.isAvailable else {
            if quota.status.contains("失败") {
                return "读取失败"
            }
            return "读取中"
        }

        if let pace = quota.sevenDayPaceStatus {
            return "\(pace.compactTitle)(\(pace.compactDetail))\(quota.compactResetCreditCountSuffix)"
        }

        if let sevenDay = quota.sevenDay {
            return "7d剩\(sevenDay.remainingPercent)%\(quota.compactResetCreditCountSuffix)"
        }
        if let fiveHour = quota.fiveHour {
            return "5h剩\(fiveHour.remainingPercent)%\(quota.compactResetCreditCountSuffix)"
        }
        return "额度已读\(quota.compactResetCreditCountSuffix)"
    }
}

struct TokenDisplayCard: View {
    let snapshot: TokenDisplaySnapshot
    let radarSnapshot: CodexRadarSnapshot?
    let visibility: FloatingPanelContentVisibility
    let onClose: (() -> Void)?
    var lockState: TokenDisplayLockState? = nil
    var lockTargetDescription: String? = nil
    var onToggleLock: (() -> Void)? = nil
    @Environment(\.tokenDisplayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let rowSpacing = FloatingTokenPanelMetrics.rowSpacing.scaled(by: displayScale)
            let rateRowHeight = FloatingTokenPanelMetrics.rateRowHeight.scaled(by: displayScale)
            let usageStatusRowHeight = FloatingTokenPanelMetrics.usageStatusRowHeight.scaled(by: displayScale)
            let metricRowHeight = FloatingTokenPanelMetrics.metricRowHeight.scaled(by: displayScale)
            let quotaRowHeight = FloatingTokenPanelMetrics.quotaRowHeight.scaled(by: displayScale)
            let radarRowHeight = FloatingTokenPanelMetrics.radarRowHeight.scaled(by: displayScale)
            let topSafetyInset = visibility.needsSingleElementTopInset ? FloatingTokenPanelMetrics.singleElementTopInset.scaled(by: displayScale) : 0

            VStack(alignment: .center, spacing: rowSpacing) {
                if visibility.showRateAndBar {
                    rateRow
                        .frame(height: rateRowHeight, alignment: .center)
                }

                if visibility.showsStandaloneUsageStatus {
                    TokenDisplayUsageStatusLine(text: snapshot.compactUsageStatus)
                        .frame(height: usageStatusRowHeight, alignment: .center)
                }

                if visibility.showMetrics {
                    metricRow
                        .frame(height: metricRowHeight, alignment: .center)
                }

                if visibility.showQuota {
                    TokenQuotaMiniStrip(snapshot: snapshot.quota)
                        .frame(height: quotaRowHeight, alignment: .center)
                }

                if visibility.showRadar {
                    TokenDisplayRadarStrip(snapshot: radarSnapshot)
                        .frame(height: radarRowHeight, alignment: .center)
                }
            }
            .frame(width: proxy.size.width, height: max(0, proxy.size.height - topSafetyInset), alignment: .center)
            .padding(.top, topSafetyInset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .topLeading) {
                cardLockButton
            }
            .overlay(alignment: .topTrailing) {
                cardCloseButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex Token Bar 悬浮窗")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if visibility.showRateAndBar {
            parts.append(String(format: "实时速率 %.1f token 每秒", snapshot.rate))
        }
        if visibility.showMetrics {
            parts.append("累计 \(snapshot.consumedTokens.abbreviatedTokens) token")
            parts.append("今天 \(snapshot.todayTokens.abbreviatedTokens) token")
            parts.append("今天 \(snapshot.todayRequests) 次请求")
        }
        if visibility.showUsageStatus {
            parts.append(snapshot.compactUsageStatus)
        }
        if visibility.showQuota, let fiveHour = snapshot.quota.fiveHour {
            parts.append("5 小时额度剩余 \(fiveHour.remainingPercent)%，\(fiveHour.accessibleResetText) 重置")
        }
        if visibility.showQuota, let sevenDay = snapshot.quota.sevenDay {
            parts.append("7 天额度剩余 \(sevenDay.remainingPercent)%，\(sevenDay.accessibleResetText) 重置")
        }
        if visibility.showRadar {
            if let radarSnapshot {
                parts.append("雷达建议 \(radarSnapshot.recommendedAction)")
                parts.append(radarSnapshot.modelIQ.latest.scoreDisplayText)
            } else {
                parts.append("雷达等待读取")
            }
        }
        return parts.isEmpty ? "未显示内容" : parts.joined(separator: "；")
    }

    private var rateRow: some View {
        HStack(alignment: .center, spacing: 8.scaled(by: displayScale)) {
            HStack(alignment: .lastTextBaseline, spacing: 4.scaled(by: displayScale)) {
                Text(String(format: "%.1f", snapshot.rate))
                    .font(.system(size: 20.scaled(by: displayScale), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 64.scaled(by: displayScale), alignment: .leading)
                    .offset(x: 3.scaled(by: displayScale), y: 1.5.scaled(by: displayScale))
                Text("tok/s")
                    .font(.system(size: 8.6.scaled(by: displayScale), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(y: 2.scaled(by: displayScale))
            }
            .frame(height: FloatingTokenPanelMetrics.rateRowHeight.scaled(by: displayScale), alignment: .center)

            TokenDisplayRateBar(
                rate: snapshot.rate,
                usageStatus: visibility.embedsUsageStatusInRateRow ? snapshot.compactUsageStatus : nil
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var cardLockButton: some View {
        if let lockState, let onToggleLock {
            Button(action: onToggleLock) {
                Image(systemName: lockState.systemImage)
                    .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .frame(width: 26.scaled(by: displayScale), height: 22.scaled(by: displayScale), alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(cardLockHelpText)
            .padding(.leading, 1.scaled(by: displayScale))
            .padding(.top, 1.scaled(by: displayScale))
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var cardCloseButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.78))
                    .frame(width: 22.scaled(by: displayScale), height: 20.scaled(by: displayScale), alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 1.scaled(by: displayScale))
            .padding(.top, 1.scaled(by: displayScale))
            .zIndex(10)
        }
    }

    private var cardLockHelpText: String {
        guard lockState == .locked else {
            return TokenDisplayLockState.unlocked.helpText
        }
        if let lockTargetDescription, !lockTargetDescription.isEmpty {
            return "已锁定到 \(lockTargetDescription)"
        }
        return TokenDisplayLockState.locked.helpText
    }

    private var metricRow: some View {
        HStack(spacing: 6.scaled(by: displayScale)) {
            TokenDisplayMetric(label: "总", value: snapshot.consumedTokens.abbreviatedTokens)
                .offset(x: -TokenDisplayLayout.metricOutset.scaled(by: displayScale))
            TokenDisplayMetric(label: "今", value: snapshot.todayTokens.abbreviatedTokens)
            TokenDisplayMetric(label: "次", value: "\(snapshot.todayRequests)")
                .offset(x: TokenDisplayLayout.metricOutset.scaled(by: displayScale))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
