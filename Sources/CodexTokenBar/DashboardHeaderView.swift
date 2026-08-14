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
    case sessionManagement
    case sessionEnhancements
    case autoResume
}

enum DashboardHeaderPresentationMode: Equatable {
    case dashboard
    case export

    var showsActions: Bool { self == .dashboard }

    func actions(unreadCount: Int) -> [DashboardHeaderAction] {
        guard showsActions else { return [] }
        return [
            .refresh,
            .changeDirectory,
            .providerRepair,
            .sessionManagement,
            .sessionEnhancements,
            .autoResume,
        ]
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
    let runningThreadSummary: RunningThreadSummary
    let presentationMode: DashboardHeaderPresentationMode
    let onRefresh: () -> Void
    let onMarkAllRead: () -> Void
    let onChangeDirectory: () -> Void
    let onOpenProviderSync: () -> Void
    let onOpenSessionManagement: () -> Void
    let onOpenSettings: () -> Void
    let onOpenSessionEnhancements: () -> Void
    let onOpenAutoResume: () -> Void
    let threadDeleteStatus: CodexThreadDeleteBridgeStatus
    let autoResumeEnabled: Bool
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
        switch snapshot.usagePrecision {
        case .precise:
            return "精确统计"
        case .metadataOnly:
            return "元数据"
        }
    }

    private var headerPrecisionColor: Color {
        switch snapshot.usagePrecision {
        case .precise:
            return AppTheme.accentGreen
        case .metadataOnly:
            return .secondary
        }
    }

    private var freshnessPresentation: DashboardHeaderFreshnessPresentation {
        DashboardHeaderFreshnessPresentation(
            status: status,
            isRefreshing: isRefreshing,
            generatedAt: snapshot.generatedAt
        )
    }

    private var runningThreadPresentation: RunningThreadPresentation {
        RunningThreadPresentation(summary: runningThreadSummary)
    }

    private var runningThreadIndicatorColor: Color {
        switch runningThreadSummary.freshness {
        case .fresh:
            return runningThreadSummary.total > 0 ? AppTheme.accentGreen : .secondary
        case .stale:
            return .orange
        case .loading, .unavailable:
            return .secondary
        }
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
                        HStack(spacing: 6) {
                            Circle()
                                .fill(runningThreadIndicatorColor)
                                .frame(width: 6, height: 6)
                            Text(runningThreadPresentation.displayText)
                                .foregroundStyle(
                                    runningThreadSummary.freshness == .stale
                                        ? Color.orange
                                        : Color.primary
                                )
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .help(runningThreadPresentation.accessibilityText)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("运行线程")
                        .accessibilityValue(runningThreadPresentation.accessibilityText)

                        DashboardHeaderRailDivider()
                        HStack(spacing: 7) {
                            Text(headerPrecisionLabel)
                                .foregroundStyle(headerPrecisionColor)
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

                            HStack(spacing: 2) {
                                if actions.contains(.sessionManagement) {
                                    Button(action: onOpenSessionManagement) {
                                        DashboardHeaderCommandLabel(
                                            title: "会话管理",
                                            systemImage: "rectangle.stack.badge.gearshape",
                                            color: AppTheme.accentBlue
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help("按项目浏览上下文，管理官方归档、恢复包和容量清理")
                                    .accessibilityLabel("会话管理")
                                }

                                if actions.contains(.sessionEnhancements) {
                                    Button(action: onOpenSessionEnhancements) {
                                        DashboardHeaderCommandLabel(
                                            title: threadDeleteStatus.dashboardActionTitle,
                                            systemImage: threadDeleteStatus.connected ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack",
                                            color: threadDeleteStatus.connected
                                                ? AppTheme.accentGreen
                                                : AppTheme.accentBlue,
                                            highlighted: threadDeleteStatus.connected
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help("管理 Codex 会话删除、导出、移动、输入和阅读增强。\n\(threadDeleteStatus.message)")
                                    .accessibilityLabel("会话增强")
                                    .accessibilityValue(threadDeleteStatus.message)
                                    .accessibilityHint("打开会话增强设置")
                                }

                                if actions.contains(.autoResume) {
                                    Button(action: onOpenAutoResume) {
                                        DashboardHeaderCommandLabel(
                                            title: "自动续跑",
                                            systemImage: autoResumeEnabled ? "play.circle.fill" : "play.circle",
                                            color: autoResumeEnabled
                                                ? AppTheme.accentGreen
                                                : AppTheme.accentBlue,
                                            highlighted: autoResumeEnabled
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help(autoResumeEnabled ? "自动续跑已开启，点击管理" : "管理失败中断、定时和额度恢复续跑")
                                    .accessibilityLabel("自动续跑")
                                    .accessibilityValue(autoResumeEnabled ? "已开启" : "已关闭")
                                    .accessibilityHint("打开自动续跑设置")
                                }
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
        if trimmedStatus.hasPrefix("读取失败")
            || trimmedStatus.contains("用量已陈旧") {
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
    var quotaSnapshot: AccountQuotaSnapshot? = nil
    var todayModelBreakdowns: [ModelTokenBreakdown] = []
    var showsModelCostRow = true
    var planLabel = ""
    var isPreparingUsageCache = false
    var cacheStatus = ""

    @AppStorage(SharedAccountUsageAttributionSettings.priceModelKey) private var quotaEstimateModelRaw = OfficialAPIPriceModel.gpt56Sol.rawValue
    @AppStorage(DashboardSavingsScope.storageKey) private var savingsScopeRaw = DashboardSavingsScope.defaultScope.rawValue
    @State private var modelCostScope: DashboardModelCostScope = .today

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

    private var savingsScope: DashboardSavingsScope {
        DashboardSavingsScope.storedValue(for: savingsScopeRaw)
    }

    private var lifetimeSavingsPresentation: SubscriptionSavingsPresentation {
        let priceModel = OfficialAPIPriceModel.storedValue(for: quotaEstimateModelRaw)
        let estimate = snapshot.hasPreciseTokenUsage
            ? SubscriptionSavingsEstimator.estimate(
                breakdown: stats.lifetimeTokenBreakdown,
                modelBreakdowns: snapshot.cacheUsage.modelBreakdowns,
                firstUsageAt: stats.firstUsageAt,
                planLabel: planLabel,
                priceModel: priceModel
            )
            : nil
        return SubscriptionSavingsPresentation(estimate: estimate)
    }

    private var sevenDaySavingsPresentation: SevenDayAPIValuePresentation {
        let estimate: SevenDayAPIValueEstimate
        if snapshot.hasPreciseTokenUsage {
            estimate = SubscriptionSavingsEstimator.sevenDayAPIValue(
                cacheUsage: snapshot.cacheUsage,
                quotaSnapshot: quotaSnapshot,
                fallbackModel: OfficialAPIPriceModel.storedValue(for: quotaEstimateModelRaw),
                now: snapshot.generatedAt
            )
        } else {
            estimate = .waiting(reason: "精确 token 仍在读取，暂不显示本 7d 金额。")
        }
        return SevenDayAPIValuePresentation(estimate: estimate)
    }

    private var activeSavingsValueText: String {
        switch savingsScope {
        case .sevenDay: return sevenDaySavingsPresentation.valueText
        case .lifetime: return lifetimeSavingsPresentation.valueText
        }
    }

    private var activeSavingsLabelText: String {
        switch savingsScope {
        case .sevenDay: return sevenDaySavingsPresentation.labelText
        case .lifetime: return lifetimeSavingsPresentation.labelText
        }
    }

    private var activeSavingsHelpText: String {
        switch savingsScope {
        case .sevenDay: return sevenDaySavingsPresentation.helpText
        case .lifetime: return lifetimeSavingsPresentation.helpText
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                StatCell(value: tokenValue(stats.totalTokens.abbreviatedTokens), label: "累计 Token 数")
                Divider().frame(height: 40)
                DashboardSavingsStatCell(
                    value: activeSavingsValueText,
                    label: activeSavingsLabelText,
                    help: activeSavingsHelpText,
                    scopeRaw: $savingsScopeRaw
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

            if showsModelCostRow {
                DashboardModelCostRow(
                    scope: $modelCostScope,
                    todayRows: todayModelBreakdowns,
                    lifetimeRows: snapshot.cacheUsage.modelBreakdowns,
                    todayTokens: snapshot.dailyUsage.last(where: { Calendar.current.isDateInToday($0.date) })?.tokens ?? 0,
                    lifetimeTokens: snapshot.stats.totalTokens,
                    fallbackModel: OfficialAPIPriceModel.storedValue(for: quotaEstimateModelRaw),
                    dataAvailable: snapshot.hasPreciseTokenUsage
                )
            }
        }
        // Keep the original overview row clear of the rounded card edge even
        // when the model-cost section makes the card choose its intrinsic height.
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .frame(minHeight: showsModelCostRow ? nil : 70)
        .frame(maxWidth: 980)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum DashboardModelCostScope: String, CaseIterable, Identifiable {
    case today = "今日"
    case lifetime = "累计"

    var id: String { rawValue }
}

struct DashboardModelCostRow: View {
    @Binding var scope: DashboardModelCostScope
    let todayRows: [ModelTokenBreakdown]
    let lifetimeRows: [ModelTokenBreakdown]
    let todayTokens: Int
    let lifetimeTokens: Int
    let fallbackModel: OfficialAPIPriceModel
    let dataAvailable: Bool

    private var sourceRows: [ModelTokenBreakdown] {
        scope == .today ? todayRows : lifetimeRows
    }

    private var items: [FloatingTodayModelUsageItem] {
        guard dataAvailable, hasModelDetail else { return [] }
        return FloatingTodayModelUsagePresentation.items(
            from: sourceRows,
            fallbackModel: fallbackModel
        )
    }

    private var totalCost: Double {
        items.compactMap(\.costUSD).reduce(0, +)
    }

    private var primaryItems: [FloatingTodayModelUsageItem] {
        FloatingTodayModelUsagePresentation.dashboardPrimaryItems(from: items)
    }

    private var secondaryItems: [FloatingTodayModelUsageItem] {
        FloatingTodayModelUsagePresentation.dashboardSecondaryItems(from: items)
    }

    private var expectedTokens: Int {
        scope == .today ? todayTokens : lifetimeTokens
    }

    private var hasModelDetail: Bool {
        expectedTokens == 0 || !sourceRows.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                Picker("模型费用范围", selection: $scope) {
                    ForEach(DashboardModelCostScope.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 86)

                Text("各模型 API 等值费用")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 4)

                if dataAvailable, hasModelDetail, !items.isEmpty {
                    Text("合计 \(totalCost.quotaEstimatorMoneyText)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                        .monospacedDigit()
                        .fixedSize()
                }
            }

            if !dataAvailable {
                Text("待读取")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !hasModelDetail {
                Text(scope == .today ? "今日模型明细待读取" : "逐模型历史待读取")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if items.isEmpty {
                Text(scope == .today ? "今日暂无模型用量" : "暂无逐模型历史")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Text("主力")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .frame(width: 28, alignment: .leading)

                    HStack(spacing: 7) {
                        ForEach(primaryItems) { item in
                            DashboardPrimaryModelCostCard(item: item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !secondaryItems.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Text("其他")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .frame(width: 28, alignment: .leading)

                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(minimum: 108), spacing: 6),
                                count: 4
                            ),
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(secondaryItems) { item in
                                DashboardSecondaryModelCostChip(item: item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(scope.rawValue)各模型 API 等值费用")
    }
}

private struct DashboardPrimaryModelCostCard: View {
    let item: FloatingTodayModelUsageItem

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(item.color)
                .frame(width: 7, height: 7)

            Text(item.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 2)

            Text(item.valueText(for: .cost))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()

            Text(item.valueText(for: .share))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(item.color.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(item.color.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct DashboardSecondaryModelCostChip: View {
    let item: FloatingTodayModelUsageItem

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                modelIndicator
                modelLabel
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                costText
                    .fixedSize(horizontal: true, vertical: false)
                shareText
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    modelIndicator
                    modelLabel
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    costText
                        .fixedSize(horizontal: true, vertical: false)
                    shareText
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppTheme.panelBackground.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.label)，费用 \(item.valueText(for: .cost))，占比 \(item.valueText(for: .share))"
        )
    }

    private var modelIndicator: some View {
        Circle()
            .fill(item.color)
            .frame(width: 6, height: 6)
    }

    private var modelLabel: some View {
        Text(item.label)
            .foregroundStyle(.secondary)
    }

    private var costText: some View {
        Text(item.valueText(for: .cost))
            .foregroundStyle(.primary)
            .monospacedDigit()
    }

    private var shareText: some View {
        Text(item.valueText(for: .share))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }
}

/// Compact, keyboard- and VoiceOver-friendly switch for the amount card.
/// Keeping both options visible avoids hiding the persisted scope behind a
/// context menu while leaving the other overview cells unchanged.
struct DashboardSavingsStatCell: View {
    let value: String
    let label: String
    let help: String
    @Binding var scopeRaw: String

    private var scope: DashboardSavingsScope {
        DashboardSavingsScope.storedValue(for: scopeRaw)
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.68)
                .lineLimit(1)

            Picker("金额口径", selection: $scopeRaw) {
                ForEach(DashboardSavingsScope.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 78, height: 17)
            .accessibilityLabel("金额口径")
            .accessibilityValue(scope.title)
        }
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)，当前口径：\(scope.title)")
        .accessibilityHint("可切换本 7d 周期或累计金额")
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
