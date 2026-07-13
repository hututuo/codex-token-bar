import AppKit
import SwiftUI

enum AccountQuotaStripLayout {
    static let controlWidth: CGFloat = 980
    static let horizontalPadding: CGFloat = 12
    static let accountLabelWidth: CGFloat = 84
    static let resetCreditWidth: CGFloat = 154
    static let itemSpacing: CGFloat = 8
    static let accountIconAndSpacingWidth: CGFloat = 16
    static let noResetSpacerMinimumWidth = resetCreditWidth
    static let combinedQuotaSegmentsWidth = controlWidth
        - horizontalPadding * 2
        - accountLabelWidth
        - resetCreditWidth
        - AccountQuotaPaceInsightLayout.controlWidth
        - itemSpacing * 3

    static func trailingEdge(hasResetCredit: Bool) -> CGFloat {
        horizontalPadding
            + accountLabelWidth
            + combinedQuotaSegmentsWidth
            + (hasResetCredit ? resetCreditWidth : noResetSpacerMinimumWidth)
            + AccountQuotaPaceInsightLayout.controlWidth
            + itemSpacing * 3
    }
}

enum AccountQuotaSegmentLayout {
    static let interSegmentSpacing: CGFloat = 6
    static let topRowSpacing: CGFloat = 5
    static let progressBarHeight: CGFloat = 20
    static let progressHorizontalPadding: CGFloat = 8
    static let progressTextSpacing: CGFloat = 4
    static let controlHeight: CGFloat = 35
    static let twoSegmentWidth = (AccountQuotaStripLayout.combinedQuotaSegmentsWidth - interSegmentSpacing) / 2
    static let singleSegmentWidth = AccountQuotaStripLayout.combinedQuotaSegmentsWidth
    static let progressBarWidth = twoSegmentWidth
}

enum AccountQuotaPaceInsightLayout {
    static let controlWidth: CGFloat = 348
    static let horizontalPadding: CGFloat = 9
    static let iconWidth: CGFloat = 18
    static let itemSpacing: CGFloat = 7
    static let cadenceWidth = AccountQuotaRefreshCadenceMenuLayout.controlWidth
    static let textWidth = controlWidth
        - horizontalPadding * 2
        - iconWidth
        - cadenceWidth
        - itemSpacing * 2
}

struct AccountQuotaRefreshCadencePicker: View {
    @AppStorage(AccountQuotaRefreshCadence.storageKey) private var selectionRaw: String = AccountQuotaRefreshCadence.defaultRawValue

    private var selection: Binding<String> {
        Binding(
            get: { AccountQuotaRefreshCadence.value(for: selectionRaw).rawValue },
            set: { selectionRaw = AccountQuotaRefreshCadence.value(for: $0).rawValue }
        )
    }

    var body: some View {
        AccountQuotaRefreshCadenceMenu(selectionRaw: selection)
    }
}

struct AccountQuotaRefreshCadenceMenuPresentation: Equatable {
    let visibleLabel: String
    let accessibilityLabel = "额度刷新"
    let accessibilityValue: String
    let disclosureSystemImage = "chevron.down"

    init(selectionRaw: String) {
        let cadence = AccountQuotaRefreshCadence.value(for: selectionRaw)
        visibleLabel = "额度刷新 \(cadence.label)"
        accessibilityValue = cadence.label
    }
}

enum AccountQuotaRefreshCadenceMenuLayout {
    static let controlWidth: CGFloat = 132
    static let controlHeight: CGFloat = 28
    static let horizontalPadding: CGFloat = 6
    static let iconWidth: CGFloat = 12
    static let disclosureWidth: CGFloat = 8
    static let spacing: CGFloat = 4
}

struct AccountQuotaRefreshCadenceMenu: View {
    @Binding var selectionRaw: String

    private var presentation: AccountQuotaRefreshCadenceMenuPresentation {
        AccountQuotaRefreshCadenceMenuPresentation(selectionRaw: selectionRaw)
    }

    var body: some View {
        Menu {
            ForEach(AccountQuotaRefreshCadence.allCases) { cadence in
                Button {
                    selectionRaw = cadence.rawValue
                } label: {
                    if cadence.rawValue == AccountQuotaRefreshCadence.value(for: selectionRaw).rawValue {
                        Label(cadence.label, systemImage: "checkmark")
                    } else {
                        Text(cadence.label)
                    }
                }
            }
        } label: {
            HStack(spacing: AccountQuotaRefreshCadenceMenuLayout.spacing) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: AccountQuotaRefreshCadenceMenuLayout.iconWidth)
                Text(presentation.visibleLabel)
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: presentation.disclosureSystemImage)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: AccountQuotaRefreshCadenceMenuLayout.disclosureWidth)
            }
            .padding(.horizontal, AccountQuotaRefreshCadenceMenuLayout.horizontalPadding)
            .frame(
                width: AccountQuotaRefreshCadenceMenuLayout.controlWidth,
                height: AccountQuotaRefreshCadenceMenuLayout.controlHeight
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(
            width: AccountQuotaRefreshCadenceMenuLayout.controlWidth,
            height: AccountQuotaRefreshCadenceMenuLayout.controlHeight
        )
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.insetBackground.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border.opacity(0.55), lineWidth: 1)
        )
        .help("设置额度自动刷新频率")
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }
}

struct AccountQuotaStrip: View {
    let snapshot: AccountQuotaSnapshot
    @Binding var showingResetCreditDetails: Bool

    private var presentation: AccountQuotaStripPresentation {
        AccountQuotaStripPresentation(snapshot: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: AccountQuotaStripLayout.itemSpacing) {
                AccountQuotaAccountLabel(
                    presentation: presentation.accountLabel,
                    isAvailable: snapshot.isAvailable
                )

                HStack(spacing: AccountQuotaSegmentLayout.interSegmentSpacing) {
                    if let fiveHour = snapshot.fiveHour {
                        AccountQuotaSegment(
                            window: fiveHour,
                            accent: AppTheme.quotaRemainingColor(percent: Double(fiveHour.remainingPercent))
                        )
                    }
                    if let sevenDay = snapshot.sevenDay {
                        AccountQuotaSegment(
                            window: sevenDay,
                            accent: AppTheme.quotaRemainingColor(percent: Double(sevenDay.remainingPercent))
                        )
                    }
                }
                .frame(width: AccountQuotaStripLayout.combinedQuotaSegmentsWidth, alignment: .leading)

                if shouldShowResetCredits {
                    AccountQuotaResetCreditButton(
                        snapshot: snapshot,
                        isPresented: $showingResetCreditDetails
                    )
                } else {
                    Spacer(minLength: AccountQuotaStripLayout.noResetSpacerMinimumWidth)
                }

                AccountQuotaPaceInsight(snapshot: snapshot)
            }

            if shouldShowRetryHint {
                Text("可能由于网络等原因读取失败，点击“立即刷新”进行重试。")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
                    .lineLimit(1)
                    .padding(.leading, 122)
            }
        }
        .padding(.horizontal, AccountQuotaStripLayout.horizontalPadding)
        .padding(.vertical, shouldShowRetryHint ? 6 : 7)
        .frame(maxWidth: AccountQuotaStripLayout.controlWidth, minHeight: shouldShowRetryHint ? 66 : 54)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("账户额度")
        .accessibilityValue(helpText)
        .zIndex(showingResetCreditDetails ? 10_000 : 0)
    }

    private var shouldShowRetryHint: Bool {
        !snapshot.isAvailable && snapshot.status.contains("失败")
    }

    private var shouldShowResetCredits: Bool {
        snapshot.isAvailable || snapshot.status.contains("失败") || snapshot.resetCreditsAvailableCount != nil || !snapshot.resetCredits.isEmpty
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

struct AccountQuotaStripPresentation: Equatable {
    let accountLabel: AccountQuotaAccountLabelPresentation
    let isAvailable: Bool

    init(snapshot: AccountQuotaSnapshot) {
        accountLabel = AccountQuotaAccountLabelPresentation(snapshot: snapshot)
        isAvailable = snapshot.isAvailable
    }

    var visibleCompactStatusTexts: [String] {
        isAvailable ? [] : [accountLabel.subtitle]
    }
}

struct AccountQuotaAccountLabelPresentation: Equatable {
    let title: String
    let subtitle: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let help: String

    init(snapshot: AccountQuotaSnapshot) {
        let limitTitle = Self.meaningful(snapshot.limitName)
        let planTitle = Self.meaningful(snapshot.planType)?.uppercased()
        let semanticTitle = limitTitle ?? planTitle ?? "账户额度"
        title = Self.firstFittingTitle([limitTitle, planTitle, "账户额度"])
        subtitle = snapshot.isAvailable ? "本地账户额度" : Self.compactStatus(snapshot.status)
        accessibilityLabel = semanticTitle
        accessibilityValue = snapshot.status
        help = "\(semanticTitle) · \(snapshot.status)"
    }

    var visibleTextFitsBudget: Bool {
        Self.titleFits(title) && Self.subtitleFits(subtitle)
    }

    private static func firstFittingTitle(_ candidates: [String?]) -> String {
        candidates
            .compactMap { $0 }
            .first(where: titleFits) ?? "账户额度"
    }

    private static func meaningful(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func compactStatus(_ status: String) -> String {
        if status.contains("失败") { return "读取失败" }
        if status.contains("未读取") { return "额度未读取" }
        if status.contains("不可用") { return "额度不可用" }
        return "额度未读取"
    }

    private static func titleFits(_ text: String) -> Bool {
        measuredWidth(text, font: .systemFont(ofSize: 10, weight: .semibold))
            + AccountQuotaStripLayout.accountIconAndSpacingWidth
            <= AccountQuotaStripLayout.accountLabelWidth
    }

    private static func subtitleFits(_ text: String) -> Bool {
        measuredWidth(text, font: .systemFont(ofSize: 8, weight: .medium))
            <= AccountQuotaStripLayout.accountLabelWidth
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

enum AccountQuotaAccountAccessibilityRepresentation {
    static func makeElement(
        presentation: AccountQuotaAccountLabelPresentation
    ) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.group)
        element.setAccessibilityLabel(presentation.accessibilityLabel)
        element.setAccessibilityValue(presentation.accessibilityValue)
        element.setAccessibilityHelp(presentation.help)
        return element
    }
}

struct AccountQuotaAccountLabel: View {
    let presentation: AccountQuotaAccountLabelPresentation
    let isAvailable: Bool

    init(presentation: AccountQuotaAccountLabelPresentation, isAvailable: Bool) {
        self.presentation = presentation
        self.isAvailable = isAvailable
    }

    init(snapshot: AccountQuotaSnapshot) {
        presentation = AccountQuotaAccountLabelPresentation(snapshot: snapshot)
        isAvailable = snapshot.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(
                presentation.title,
                systemImage: isAvailable ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.0percent"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isAvailable ? .primary : .secondary)
            .fixedSize(horizontal: true, vertical: false)

            Text(presentation.subtitle)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: AccountQuotaStripLayout.accountLabelWidth, alignment: .leading)
        .help(presentation.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }
}

private struct AccountQuotaResetCreditButton: View {
    let snapshot: AccountQuotaSnapshot
    @Binding var isPresented: Bool

    private var summaryText: String {
        snapshot.compactResetCreditSummary ?? "重置卡"
    }

    private var nearestText: String? {
        snapshot.resetCreditNearestLineText
    }

    private var helpText: String {
        if let nearestText {
            return "\(summaryText)，\(nearestText)。点击查看每张重置机会。"
        }
        return "\(summaryText)。点击查看每张重置机会。"
    }

    private var accessibilityValue: String {
        if let nearestText {
            return "\(summaryText)，\(nearestText)"
        }
        return summaryText
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "bolt.clock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.accentBlue)

                VStack(alignment: .leading, spacing: 1) {
                    Text(summaryText)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let nearestText {
                        Text(nearestText)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isPresented ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.80))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: AccountQuotaStripLayout.resetCreditWidth, alignment: .leading)
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
        .help(helpText)
        .accessibilityLabel("重置卡")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("查看每张重置机会的剩余时间和到期信息")
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
        snapshot.sortedResetCreditsForDisplay
    }

    var body: some View {
        SettingsCalloutContainer(
            title: "重置卡详情",
            subtitle: snapshot.resetCreditDetailSubtitle,
            systemImage: "bolt.clock.fill",
            imageResourceName: "ResetCreditIcon",
            closeAction: onClose
        ) {
            if visibleCredits.isEmpty {
                Text(snapshot.availableResetCreditCount > 0 ? "已读到可用数量，但暂时没有单卡明细。" : "暂时没有读到重置卡明细。可能是网络抖动，点击主页面“立即刷新”重试。")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 7) {
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
    @State private var isExpanded = false

    private var statusColor: Color {
        credit.isAvailable ? AppTheme.accentBlue : .secondary
    }

    private var remainingProgress: CGFloat {
        CGFloat(credit.remainingProgress(relativeTo: Date()) ?? (credit.isAvailable ? 1 : 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    AccountQuotaResetCreditAvatarView(credit: credit)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(credit.compactRemainingTimeText)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(credit.isAvailable ? .primary : .secondary)
                                .monospacedDigit()
                                .lineLimit(1)

                            Text("第 \(index) 张")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(AppTheme.raisedBackground)
                                Capsule()
                                    .fill(statusColor.opacity(credit.isAvailable ? 0.76 : 0.34))
                                    .frame(width: max(0, proxy.size.width * remainingProgress))
                            }
                        }
                        .frame(height: 7)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.82))
                        .frame(width: 18, height: 18)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                SettingsCalloutSection {
                    SettingsCalloutRow(title: "原因", value: credit.descriptionSummaryText, systemImage: "text.alignleft")
                    SettingsCalloutRow(title: "关联用户", value: credit.profileUserText, systemImage: "person.crop.circle", isEmphasized: credit.profileUserText != "未提供关联用户")
                    SettingsCalloutRow(title: "到期时间", value: credit.detailedExpiryText, systemImage: "calendar", isEmphasized: credit.isAvailable)
                    SettingsCalloutRow(title: "剩余时间", value: credit.remainingTimeText, systemImage: "hourglass", isEmphasized: credit.isAvailable)
                    SettingsCalloutRow(title: "卡片编号", value: credit.cardIdentifierText, systemImage: "number", isLast: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.calloutOptionBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(AppTheme.border.opacity(0.65), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(index) 张重置卡")
        .accessibilityValue("\(credit.remainingTimeText)，\(credit.profileUserText)")
        .accessibilityHint(isExpanded ? "点击收起详情" : "点击展开详情")
    }
}

private struct AccountQuotaResetCreditAvatarView: View {
    let credit: AccountQuotaResetCredit

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.accentBlue.opacity(0.12))

            if let url = credit.profileImageDisplayURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallback
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(AppTheme.borderStrong.opacity(0.52), lineWidth: 1)
        )
        .accessibilityLabel("关联用户头像")
    }

    private var fallback: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(AppTheme.accentBlue.opacity(0.72))
    }
}

struct AccountQuotaSegment: View {
    let window: AccountQuotaWindow
    let accent: Color

    private var presentation: AccountQuotaSegmentPresentation {
        AccountQuotaSegmentPresentation(window: window)
    }

    private var remainingFraction: CGFloat {
        CGFloat(Double(window.remainingPercent) / 100.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: AccountQuotaSegmentLayout.topRowSpacing) {
                Text(presentation.title)
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize(horizontal: true, vertical: false)
                Text(presentation.resetText)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }

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

                    HStack(spacing: AccountQuotaSegmentLayout.progressTextSpacing) {
                        Text(presentation.remainingText)
                            .fontWeight(.semibold)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        Text(presentation.usedText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, AccountQuotaSegmentLayout.progressHorizontalPadding)
                }
            }
            .frame(height: AccountQuotaSegmentLayout.progressBarHeight)
        }
        .frame(maxWidth: .infinity, minHeight: AccountQuotaSegmentLayout.controlHeight, maxHeight: AccountQuotaSegmentLayout.controlHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.displayLabel)额度")
        .accessibilityValue("剩余 \(window.remainingPercent)%，已用 \(window.usedPercent)%，\(window.accessibleResetText) 重置")
    }
}

struct AccountQuotaSegmentPresentation: Equatable {
    let title: String
    let resetText: String
    let remainingText: String
    let usedText: String

    init(window: AccountQuotaWindow) {
        title = window.displayLabel
        resetText = "重置 \(window.detailedResetText)"
        remainingText = "剩 \(window.remainingPercent)%"
        usedText = "已用 \(window.usedPercent)%"
    }

    var allVisibleText: [String] {
        [title, resetText, remainingText, usedText]
    }
}

struct AccountQuotaPaceInsight: View {
    let snapshot: AccountQuotaSnapshot

    private var insight: AccountQuotaPaceStatus? {
        snapshot.sevenDayPaceStatus
    }

    private var accent: Color {
        guard let insight else { return .secondary }
        return AppTheme.accentColor(for: AppTheme.quotaPaceRole(insight.title))
    }

    var body: some View {
        HStack(spacing: AccountQuotaPaceInsightLayout.itemSpacing) {
            Image(systemName: insight?.iconName ?? "clock.badge.questionmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: AccountQuotaPaceInsightLayout.iconWidth)

            VStack(alignment: .leading, spacing: 1) {
                Text(insight?.title ?? "等待额度")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(insight == nil ? .secondary : .primary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(insight?.detail ?? "读取后计算均速")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: AccountQuotaPaceInsightLayout.textWidth, alignment: .leading)

            AccountQuotaRefreshCadencePicker()
        }
        .padding(.horizontal, AccountQuotaPaceInsightLayout.horizontalPadding)
        .padding(.vertical, 7)
        .frame(width: AccountQuotaPaceInsightLayout.controlWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.raisedBackground)
        )
    }
}
