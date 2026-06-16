import AppKit
import SwiftUI

struct AccountQuotaStrip: View {
    let snapshot: AccountQuotaSnapshot
    @State private var showingResetCreditDetails = false

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

private struct AccountQuotaResetCreditButton: View {
    let snapshot: AccountQuotaSnapshot
    @Binding var isPresented: Bool
    @State private var localClickMonitor: Any?
    @State private var globalClickMonitor: Any?
    @State private var keyDownMonitor: Any?

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
        .overlay(alignment: .topTrailing) {
            if isPresented {
                resetCreditCallout
                    .offset(y: 34)
                    .zIndex(40)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
            }
        }
        .zIndex(isPresented ? 40 : 0)
        .onChange(of: isPresented) { _, presented in
            presented ? installDismissMonitors() : removeDismissMonitors()
        }
        .onDisappear {
            removeDismissMonitors()
        }
    }

    private var resetCreditCallout: some View {
        VStack(alignment: .trailing, spacing: 0) {
            AccountQuotaResetCreditDetailView(
                snapshot: snapshot,
                onClose: { isPresented = false }
            )
            .frame(width: 414)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.calloutBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.borderStrong.opacity(0.46), lineWidth: 1)
            )
            .shadow(color: AppTheme.shadow.opacity(0.42), radius: 7, x: 0, y: 4)
        }
    }

    private func installDismissMonitors() {
        guard localClickMonitor == nil, globalClickMonitor == nil, keyDownMonitor == nil else { return }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                isPresented = false
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                isPresented = false
            }
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    isPresented = false
                }
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }
}

private struct AccountQuotaResetCreditDetailView: View {
    let snapshot: AccountQuotaSnapshot
    let onClose: () -> Void

    private var visibleCredits: [AccountQuotaResetCredit] {
        snapshot.resetCredits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.accentBlue.opacity(0.13))
                    Image(systemName: "bolt.clock.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.accentBlue)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text("重置卡")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(snapshot.resetCreditDetailSummary)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(AppTheme.calloutOptionBackground)
            )

            if visibleCredits.isEmpty {
                Text(snapshot.availableResetCreditCount > 0 ? "已读到可用数量，但暂时没有单卡明细。" : "还没有读取到重置卡。")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 7) {
                        ForEach(Array(visibleCredits.enumerated()), id: \.element.id) { index, credit in
                            AccountQuotaResetCreditRow(index: index + 1, credit: credit)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .background(AppTheme.calloutBackground)
    }
}

private struct AccountQuotaResetCreditRow: View {
    let index: Int
    let credit: AccountQuotaResetCredit

    private var statusColor: Color {
        credit.isAvailable ? AppTheme.accentBlue : .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("#\(index)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.accentBlue)
                .monospacedDigit()
                .frame(width: 28, height: 24)
                .background(AppTheme.accentBlue.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(credit.title?.isEmpty == false ? credit.title! : "Rate limit reset")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(credit.statusText)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                HStack(spacing: 12) {
                    ResetCreditDetailPill(label: "到期", value: credit.detailedExpiryText, emphasized: credit.isAvailable)
                    ResetCreditDetailPill(label: "发放", value: credit.detailedGrantedText, emphasized: false)
                }

                if let redeemedText = credit.detailedRedeemedText {
                    Text("已使用 \(redeemedText)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if credit.redeemStartedAt != nil {
                    Text("已开始兑换，等待确认")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let description = credit.descriptionText, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let profileUserID = credit.profileUserID, !profileUserID.isEmpty {
                        Text(profileUserID)
                            .lineLimit(1)
                    }
                    Text("ID \(credit.id.suffix(8))")
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.82))
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

private struct ResetCreditDetailPill: View {
    let label: String
    let value: String
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .monospacedDigit()
        }
        .font(.system(size: 10.5, weight: emphasized ? .bold : .semibold))
        .lineLimit(1)
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
