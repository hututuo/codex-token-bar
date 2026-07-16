import SwiftUI

enum DashboardMarkAllReadTone: Equatable {
    case active
    case idle
}

enum DashboardHeaderAction: Equatable {
    case markAllRead
    case refresh
    case changeDirectory
    case providerRepair
    case threadDelete
}

enum DashboardHeaderPresentationMode: Equatable {
    case dashboard
    case export

    var showsActions: Bool { self == .dashboard }

    func actions(unreadCount: Int) -> [DashboardHeaderAction] {
        guard showsActions else { return [] }
        return [.markAllRead, .refresh, .changeDirectory, .providerRepair, .threadDelete]
    }
}

struct DashboardMarkAllReadController: Equatable {
    private(set) var isBusy = false

    @discardableResult
    mutating func trigger(_ action: () -> Void) -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        action()
        return true
    }

    mutating func complete() {
        isBusy = false
    }
}

struct DashboardMarkAllReadPresentation: Equatable {
    let unreadCount: Int
    let isBusy: Bool

    var tone: DashboardMarkAllReadTone { unreadCount > 0 ? .active : .idle }
    var isEnabled: Bool { !isBusy }
    var accessibilityLabel: String { "全部已读" }
    var accessibilityValue: String {
        unreadCount > 0 ? "\(unreadCount) 个未读会话" : "当前没有未读会话，可重新建立已读基线"
    }
    var accessibilityHint: String {
        isBusy ? "正在更新已读基线" : "将当前会话状态标记为已读"
    }
}

enum DashboardHeaderContextLayout {
    static let contextRowCount = 2
    static let dataSourceWidth: CGFloat = 280
    static let badgeHorizontalPadding: CGFloat = 7
    static let iconWidth: CGFloat = 14
    static let badgeSpacing: CGFloat = 5
}

struct DashboardHeaderFreshnessPresentation: Equatable {
    let text: String
    let needsAttention: Bool

    init(status: String, isRefreshing: Bool, generatedAt: Date) {
        if isRefreshing {
            text = "正在同步"
            needsAttention = false
            return
        }

        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("失败") || trimmed.contains("陈旧") {
            text = trimmed
            needsAttention = true
            return
        }

        text = "更新于 \(DateFormatter.statusString(from: generatedAt))"
        needsAttention = false
    }
}

struct InitialLoadingOverlay: View {
    let status: String

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .opacity(0.82)
                .ignoresSafeArea()

            Color.black
                .opacity(0.06)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .progressViewStyle(.circular)

                VStack(spacing: 4) {
                    Text("正在加载本地统计")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 320)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
    }
}

struct HeaderView: View {
    let snapshot: DashboardSnapshot
    let quotaSnapshot: AccountQuotaSnapshot
    let status: String
    let dataSourceLabel: String
    let dataSourceOrigin: String
    let isRefreshing: Bool
    let unreadThreadCount: Int
    let presentationMode: DashboardHeaderPresentationMode
    let onRefresh: () -> Void
    let onMarkAllRead: () -> Void
    let onChangeDirectory: () -> Void
    let onOpenProviderSync: () -> Void
    let onOpenSettings: () -> Void
    let threadDeleteStatus: CodexThreadDeleteBridgeStatus
    let onThreadDeleteConnectionAction: () -> Void
    @Binding var showingInterfaceScaleMenu: Bool
    @Binding var interfaceScaleAutoEnabled: Bool
    @Binding var interfaceScaleManualMultiplier: Double
    @Binding var showingResetCreditDetails: Bool

    @AppStorage("customAccountDisplayName") private var customAccountDisplayName = ""
    @State private var isEditingDisplayName = false
    @State private var displayNameDraft = ""
    @State private var markAllReadController = DashboardMarkAllReadController()
    @FocusState private var displayNameFieldFocused: Bool

    private var accountDisplayName: String {
        let trimmed = customAccountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? quotaSnapshot.accountDisplayName : trimmed
    }

    private var markAllReadPresentation: DashboardMarkAllReadPresentation {
        DashboardMarkAllReadPresentation(unreadCount: unreadThreadCount, isBusy: markAllReadController.isBusy)
    }

    private var actions: [DashboardHeaderAction] {
        presentationMode.actions(unreadCount: unreadThreadCount)
    }

    private var headerPlanLabel: String {
        let plan = quotaSnapshot.planType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plan.isEmpty ? "套餐待读取" : plan.uppercased()
    }

    private var headerPrecisionLabel: String {
        snapshot.hasPreciseTokenUsage ? "精确统计" : "元数据"
    }

    private var freshnessPresentation: DashboardHeaderFreshnessPresentation {
        DashboardHeaderFreshnessPresentation(
            status: status,
            isRefreshing: isRefreshing,
            generatedAt: snapshot.generatedAt
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 72, height: 72)
                Text("CX")
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 9) {
                if isEditingDisplayName {
                    TextField("昵称", text: $displayNameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .regular))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(width: 300)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(AppTheme.raisedBackground, in: Capsule())
                        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
                        .focused($displayNameFieldFocused)
                        .onSubmit(saveDisplayNameDraft)
                        .onChange(of: displayNameFieldFocused) { _, isFocused in
                            if !isFocused {
                                saveDisplayNameDraft()
                            }
                        }
                        .onAppear {
                            displayNameDraft = accountDisplayName
                            displayNameFieldFocused = true
                        }
                } else if presentationMode.showsActions {
                    Button {
                        displayNameDraft = accountDisplayName
                        isEditingDisplayName = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0)
                            Text(accountDisplayName)
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.75))
                        }
                        .frame(maxWidth: 360)
                    }
                    .buttonStyle(.plain)
                    .help("点击修改顶部昵称；留空会恢复本地账户名")
                } else {
                    Text(accountDisplayName)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: 360)
                }

                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        if presentationMode.showsActions {
                            InterfaceScaleMenuButton(
                                isPresented: $showingInterfaceScaleMenu,
                                autoEnabled: $interfaceScaleAutoEnabled,
                                manualMultiplier: $interfaceScaleManualMultiplier
                            )
                            DashboardHeaderRailDivider()
                        }

                        HStack(spacing: 7) {
                            Circle()
                                .fill(AppTheme.accentBlue)
                                .frame(width: 7, height: 7)
                            Text("Swift 原生版")
                                .foregroundStyle(AppTheme.accentBlue)
                            Text(headerPlanLabel)
                                .foregroundStyle(.primary)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)

                        DashboardHeaderRailDivider()
                        DataSourceBadge(path: dataSourceLabel, origin: dataSourceOrigin)

                        DashboardHeaderRailDivider()
                        HStack(spacing: 7) {
                            Text(headerPrecisionLabel)
                                .foregroundStyle(snapshot.hasPreciseTokenUsage ? AppTheme.accentGreen : .secondary)
                            Text(freshnessPresentation.text)
                                .foregroundStyle(freshnessPresentation.needsAttention ? AppTheme.accentRed : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.solidControlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, alignment: .center)

                    if presentationMode.showsActions {
                        HStack(spacing: 4) {
                            HStack(spacing: 2) {
                                if actions.contains(.markAllRead) {
                                    Button(action: markAllRead) {
                                        DashboardHeaderCommandLabel(
                                            title: "全部已读",
                                            systemImage: "checkmark.circle",
                                            color: markAllReadPresentation.tone == .active
                                                ? AppTheme.accentBlue
                                                : .secondary,
                                            highlighted: markAllReadPresentation.tone == .active
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!markAllReadPresentation.isEnabled)
                                    .accessibilityLabel(markAllReadPresentation.accessibilityLabel)
                                    .accessibilityValue(markAllReadPresentation.accessibilityValue)
                                    .accessibilityHint(markAllReadPresentation.accessibilityHint)
                                }

                                if actions.contains(.refresh) {
                                    Button(action: onRefresh) {
                                        DashboardHeaderCommandLabel(
                                            title: isRefreshing ? "刷新中" : "立即刷新",
                                            systemImage: "arrow.clockwise",
                                            color: AppTheme.accentBlue
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isRefreshing)
                                    .accessibilityLabel(isRefreshing ? "刷新中" : "立即刷新")
                                }
                            }

                            DashboardHeaderRailDivider(height: 20)

                            HStack(spacing: 2) {
                                if actions.contains(.changeDirectory) {
                                    Button(action: onChangeDirectory) {
                                        DashboardHeaderCommandLabel(
                                            title: "更改目录",
                                            systemImage: "folder",
                                            color: .primary
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("更改目录")
                                }

                                if actions.contains(.providerRepair) {
                                    Button(action: onOpenProviderSync) {
                                        DashboardHeaderCommandLabel(
                                            title: "会话消失修复",
                                            systemImage: "wrench.and.screwdriver",
                                            color: .primary
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("会话消失修复")
                                }
                            }

                            DashboardHeaderRailDivider(height: 20)

                            if actions.contains(.threadDelete) {
                                Button(action: onThreadDeleteConnectionAction) {
                                    DashboardHeaderCommandLabel(
                                        title: threadDeleteStatus.dashboardActionTitle,
                                        systemImage: threadDeleteStatus.connected ? "link.circle.fill" : "link.badge.plus",
                                        color: threadDeleteStatus.connected
                                            ? AppTheme.accentGreen
                                            : AppTheme.accentBlue,
                                        highlighted: threadDeleteStatus.connected
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(threadDeleteStatus.message)
                                .accessibilityLabel(threadDeleteStatus.dashboardActionTitle)
                                .accessibilityValue(threadDeleteStatus.message)
                                .accessibilityHint(
                                    threadDeleteStatus.connected
                                        ? "重新连接 Codex 侧栏删除按钮"
                                        : "启用 Codex 侧栏删除按钮"
                                )
                            }

                            DashboardHeaderRailDivider(height: 20)

                            Button(action: onOpenSettings) {
                                DashboardHeaderCommandLabel(
                                    title: "设置",
                                    systemImage: "gearshape",
                                    color: AppTheme.accentBlue
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("总体设置")
                        }
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppTheme.solidControlBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .font(.system(size: 14))
                .frame(maxWidth: 980)

                AccountQuotaStrip(
                    snapshot: quotaSnapshot,
                    showingResetCreditDetails: $showingResetCreditDetails
                )
            }
        }
        .zIndex(showingResetCreditDetails ? 10_000 : 0)
        .onReceive(NotificationCenter.default.publisher(for: .dashboardBlankAreaClicked)) { _ in
            if isEditingDisplayName {
                saveDisplayNameDraft()
            }
            showingResetCreditDetails = false
            showingInterfaceScaleMenu = false
        }
    }

    private func saveDisplayNameDraft() {
        customAccountDisplayName = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingDisplayName = false
    }

    private func markAllRead() {
        guard markAllReadController.trigger(onMarkAllRead) else { return }
        DispatchQueue.main.async {
            markAllReadController.complete()
        }
    }
}

struct DataSourceBadge: View {
    let path: String
    let origin: String

    var body: some View {
        Label {
            HStack(spacing: 5) {
                Text(origin)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(path)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: "externaldrive")
                .foregroundStyle(AppTheme.accentCyan)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, DashboardHeaderContextLayout.badgeHorizontalPadding)
        .frame(width: DashboardHeaderContextLayout.dataSourceWidth)
        .help(path)
        .accessibilityLabel("数据源 \(origin) \(path)")
    }
}

private struct DashboardHeaderRailDivider: View {
    var height: CGFloat = 18

    var body: some View {
        Rectangle()
            .fill(AppTheme.borderStrong)
            .frame(width: 1, height: height)
            .padding(.horizontal, 4)
    }
}

private struct DashboardHeaderCommandLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var highlighted = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlighted ? AppTheme.selectedControlBackground : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

struct StatStripStatusLinePresentation: Equatable {
    let text: String
    let showsProgress: Bool

    init?(
        hasPreciseTokenUsage: Bool,
        isPreparingUsageCache: Bool,
        cacheStatus: String
    ) {
        let trimmedStatus = cacheStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedStatus.hasPrefix("读取失败") || trimmedStatus.contains("用量已陈旧") {
            text = trimmedStatus
            showsProgress = false
            return
        }

        if isPreparingUsageCache {
            let statusText = trimmedStatus.isEmpty ? "后台准备中" : trimmedStatus
            text = "正在初始化本地统计缓存 · \(statusText)"
            showsProgress = true
            return
        }

        guard !hasPreciseTokenUsage else { return nil }
        text = "仅显示会话元数据，精确 token 仍在读取，请稍后。"
        showsProgress = false
    }
}

struct StatStrip: View {
    let snapshot: DashboardSnapshot
    var planLabel = ""
    var isPreparingUsageCache = false
    var cacheStatus = ""

    @AppStorage("recentChartQuotaEstimateModel") private var quotaEstimateModelRaw = OfficialAPIPriceModel.gpt55.rawValue

    private var stats: DashboardStats {
        snapshot.stats
    }

    private var isMetadataOnly: Bool {
        !snapshot.hasPreciseTokenUsage
    }

    private func tokenValue(_ value: String) -> String {
        isMetadataOnly ? "待读取" : value
    }

    private var statusLine: StatStripStatusLinePresentation? {
        StatStripStatusLinePresentation(
            hasPreciseTokenUsage: snapshot.hasPreciseTokenUsage,
            isPreparingUsageCache: isPreparingUsageCache,
            cacheStatus: cacheStatus
        )
    }

    private var savingsPresentation: SubscriptionSavingsPresentation {
        let priceModel = OfficialAPIPriceModel(rawValue: quotaEstimateModelRaw) ?? .gpt55
        let estimate = snapshot.hasPreciseTokenUsage
            ? SubscriptionSavingsEstimator.estimate(
                breakdown: stats.lifetimeTokenBreakdown,
                firstUsageAt: stats.firstUsageAt,
                planLabel: planLabel,
                priceModel: priceModel
            )
            : nil
        return SubscriptionSavingsPresentation(estimate: estimate)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                StatCell(value: tokenValue(stats.totalTokens.abbreviatedTokens), label: "累计 Token 数")
                Divider().frame(height: 40)
                StatCell(
                    value: savingsPresentation.valueText,
                    label: savingsPresentation.labelText,
                    help: savingsPresentation.helpText
                )
                Divider().frame(height: 40)
                StatCell(value: tokenValue(stats.peakDayTokens.abbreviatedTokens), label: "峰值 Token 数")
                Divider().frame(height: 40)
                StatCell(value: tokenValue(stats.peakThreadTokens.abbreviatedTokens), label: "单会话最大 Token")
                Divider().frame(height: 40)
                StatCell(value: tokenValue("\(stats.currentStreakDays) 天"), label: "当前连续天数")
                Divider().frame(height: 40)
                StatCell(value: tokenValue("\(stats.longestStreakDays) 天"), label: "最长连续天数")
            }

            if let statusLine {
                HStack(spacing: 5) {
                    if statusLine.showsProgress {
                        ProgressView()
                            .controlSize(.mini)
                            .progressViewStyle(.circular)
                    }
                    Text(statusLine.text)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(height: 70)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .frame(maxWidth: 980)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatCell: View {
    let value: String
    let label: String
    var help: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
        .help(help ?? "")
    }
}
