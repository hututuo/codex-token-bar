import AppKit
import SwiftUI

struct AccountQuotaStrip: View {
    let snapshot: AccountQuotaSnapshot
    @Binding var showingResetCreditDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        snapshot.displayName,
                        systemImage: snapshot.isAvailable ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.0percent"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(snapshot.isAvailable ? .primary : .secondary)
                    .lineLimit(1)

                    Text(snapshot.isAvailable ? "本地账户额度" : snapshot.status)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 104, alignment: .leading)

                HStack(spacing: 8) {
                    if let fiveHour = snapshot.fiveHour {
                        AccountQuotaSegment(window: fiveHour, accent: AppTheme.accentCyan)
                    }
                    if let sevenDay = snapshot.sevenDay {
                        AccountQuotaSegment(window: sevenDay, accent: AppTheme.accentBlue)
                    }
                    if !snapshot.isAvailable {
                        Text(snapshot.status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if shouldShowResetCredits {
                    AccountQuotaResetCreditButton(
                        snapshot: snapshot,
                        isPresented: $showingResetCreditDetails
                    )
                }

                AccountQuotaPaceInsight(snapshot: snapshot)
                    .padding(.leading, 10)
            }

            if shouldShowRetryHint {
                Text("可能由于网络等原因读取失败，点击“立即刷新”进行重试。")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
                    .lineLimit(1)
                    .padding(.leading, 122)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, shouldShowRetryHint ? 6 : 7)
        .frame(maxWidth: 980, minHeight: shouldShowRetryHint ? 66 : 54)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
        .help(helpText)
        .zIndex(showingResetCreditDetails ? 10_000 : 0)
    }

    private var shouldShowRetryHint: Bool {
        !snapshot.isAvailable && snapshot.status.contains("失败")
    }

    private var shouldShowResetCredits: Bool {
        snapshot.availableResetCreditCount > 0 || !snapshot.resetCredits.isEmpty
    }

    private var helpText: String {
        guard snapshot.isAvailable else { return snapshot.status }
        return [snapshot.fiveHour, snapshot.sevenDay].compactMap { window -> String? in
            guard let window else { return nil }
            return "\(window.label)：已用 \(window.usedPercent)%，剩余 \(window.remainingPercent)%，\(window.accessibleResetText) 重置"
        }.joined(separator: "；")
    }
}

struct AccountQuotaResetCreditButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct AccountQuotaResetCreditButton: View {
    let snapshot: AccountQuotaSnapshot
    @Binding var isPresented: Bool

    private var summaryText: String {
        snapshot.compactResetCreditSummary ?? "无可用重置"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bolt.clock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.accentBlue)
                Text(summaryText)
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isPresented ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.80))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(width: 138, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.calloutBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isPresented ? AppTheme.accentBlue.opacity(0.42) : AppTheme.borderStrong.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("查看每张重置机会的到期时间")
        .anchorPreference(key: AccountQuotaResetCreditButtonBoundsKey.self, value: .bounds) { anchor in
            anchor
        }
        .zIndex(isPresented ? 10_001 : 0)
    }
}

struct AccountQuotaResetCreditDetailView: View {
    let snapshot: AccountQuotaSnapshot
    let onClose: () -> Void

    private var visibleCredits: [AccountQuotaResetCredit] {
        snapshot.resetCredits
    }

    var body: some View {
        SettingsCalloutContainer(
            title: "重置卡详情",
            subtitle: "共 \(visibleCredits.count) 张明细 · 可用 \(snapshot.availableResetCreditCount) 张",
            systemImage: "bolt.clock.fill",
            closeAction: onClose
        ) {
            if visibleCredits.isEmpty {
                Text(snapshot.availableResetCreditCount > 0 ? "已读到可用数量，但暂时没有单卡明细。" : "还没有读取到重置卡。")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(visibleCredits.enumerated()), id: \.element.id) { index, credit in
                            AccountQuotaResetCreditRow(index: index + 1, credit: credit)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 520)

                Text("只读取本机 Codex 登录态，不会消耗重置卡。")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct AccountQuotaResetCreditRow: View {
    let index: Int
    let credit: AccountQuotaResetCredit

    private var statusColor: Color {
        credit.isAvailable ? AppTheme.accentBlue : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(index)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.accentBlue)
                    .monospacedDigit()
                    .frame(width: 30, height: 22)
                    .background(AppTheme.accentBlue.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(credit.titleText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(credit.statusText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            SettingsCalloutSection {
                SettingsCalloutRow(title: "状态", value: credit.detailedStatusText, systemImage: "circle.fill", isEmphasized: credit.isAvailable)
                SettingsCalloutRow(title: "类型", value: credit.detailedResetTypeText, systemImage: "bolt.horizontal")
                SettingsCalloutRow(title: "标题", value: credit.titleText, systemImage: "tag")
                SettingsCalloutRow(title: "获得原因", value: credit.descriptionSummaryText, systemImage: "text.alignleft")
                SettingsCalloutRow(title: "关联用户", value: credit.profileUserText, systemImage: "person.crop.circle", isEmphasized: credit.profileUserText != "未提供关联用户")
                SettingsCalloutRow(title: "头像链接", value: credit.profileImageSummaryText, systemImage: "photo")
                SettingsCalloutRow(title: "发放时间", value: credit.detailedGrantedText, systemImage: "gift")
                SettingsCalloutRow(title: "到期时间", value: credit.detailedExpiryText, systemImage: "calendar", isEmphasized: credit.isAvailable)
                SettingsCalloutRow(title: "剩余时间", value: credit.remainingTimeText, systemImage: "hourglass", isEmphasized: credit.isAvailable)
                SettingsCalloutRow(title: "兑换状态", value: credit.redeemStateText, systemImage: "arrow.triangle.2.circlepath")
                SettingsCalloutRow(title: "开始兑换", value: credit.detailedRedeemStartedText, systemImage: "clock.arrow.circlepath")
                SettingsCalloutRow(title: "使用完成", value: credit.detailedRedeemedText ?? "未使用", systemImage: "checkmark.circle")
                SettingsCalloutRow(title: "卡片编号", value: credit.cardIdentifierText, systemImage: "number", isLast: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(AppTheme.border.opacity(0.65), lineWidth: 1)
        )
    }
}

struct AccountQuotaSegment: View {
    let window: AccountQuotaWindow
    let accent: Color

    private var remainingFraction: CGFloat {
        CGFloat(Double(window.remainingPercent) / 100.0)
    }

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text(window.displayLabel)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text("重置 \(window.detailedResetText)")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 72, alignment: .leading)

            GeometryReader { proxy in
                let clampedFraction = min(max(remainingFraction, 0), 1)
                let fillWidth = proxy.size.width * clampedFraction

                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.raisedBackground)
                        if fillWidth > 0 {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [accent.opacity(0.92), accent.opacity(0.55)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: min(proxy.size.width, max(proxy.size.height, fillWidth)), height: proxy.size.height)
                        }
                    }
                    .clipShape(Capsule())

                    HStack(spacing: 4) {
                        Text("剩 \(window.remainingPercent)%")
                            .fontWeight(.semibold)
                        Text("已用 \(window.usedPercent)%")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
                }
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity)
    }
}
struct AccountQuotaPaceInsight: View {
    let snapshot: AccountQuotaSnapshot

    private var insight: AccountQuotaPaceStatus? {
        snapshot.sevenDayPaceStatus
    }

    private var accent: Color {
        guard let insight else { return .secondary }
        switch insight.severity {
        case .urgent:
            return AppTheme.accentOrange
        case .fast:
            return AppTheme.accentCyan
        case .slightlyFast:
            return Color.orange
        case .steady, .roomy:
            return AppTheme.accentBlue
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: insight?.iconName ?? "clock.badge.questionmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(insight?.title ?? "等待额度")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(insight == nil ? .secondary : .primary)
                    .lineLimit(1)
                Text(insight?.detail ?? "读取后计算均速")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 232, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.raisedBackground)
        )
    }
}
