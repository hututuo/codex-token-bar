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

/// The progress stream is intentionally kept as the sole source of truth for
/// the header. This presentation layer only gives the raw phases a stable,
/// human-readable label; it never estimates duration or invents work.
enum DashboardHeaderProgressStage: Equatable {
    case idle
    case structureUpgrade
    case historyModelBackfill
    case reconciliation
    case waiting
    case preparing
    case scanning
    case publishing
    case complete
    case failed

    var title: String {
        switch self {
        case .idle: return "等待精确统计"
        case .structureUpgrade: return "索引升级"
        case .historyModelBackfill: return "历史模型补齐"
        case .reconciliation: return "单文件对账"
        case .waiting: return "等待精确统计"
        case .preparing: return "准备精确统计"
        case .scanning: return "扫描历史"
        case .publishing: return "发布精确统计"
        case .complete: return "已就绪"
        case .failed: return "失败"
        }
    }

    var isVisible: Bool { self != .idle }

    var showsProgress: Bool {
        switch self {
        case .structureUpgrade, .historyModelBackfill, .reconciliation, .waiting,
             .preparing, .scanning, .publishing:
            return true
        case .idle, .complete, .failed:
            return false
        }
    }

    private static func messageContainsAny(_ message: String, _ terms: [String]) -> Bool {
        let normalized = message.lowercased()
        return terms.contains { normalized.contains($0) }
    }

    static func resolve(_ progress: PreciseIndexProgress) -> Self {
        let message = progress.message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch progress.phase {
        case .idle:
            return .idle
        case .complete:
            return .complete
        case .failed:
            return .failed
        case .backfillingModel:
            return .historyModelBackfill
        case .migrating:
            // Tauri versions have emitted both `model` and `reasoning` in the
            // migration detail. Keep that wording compatible with Swift's
            // explicit backfillingModel phase.
            return messageContainsAny(
                message,
                ["model", "reasoning", "模型"]
            ) ? .historyModelBackfill : .structureUpgrade
        case .waiting:
            return messageContainsAny(
                message,
                ["reconcil", "对账", "单文件", "单个文件"]
            ) ? .reconciliation : .waiting
        case .preparing:
            return messageContainsAny(
                message,
                ["model", "reasoning", "模型"]
            ) ? .historyModelBackfill : .preparing
        case .scanning:
            if messageContainsAny(message, ["reconcil", "对账", "单文件", "单个文件"]) {
                return .reconciliation
            }
            return messageContainsAny(
                message,
                ["model", "reasoning", "模型"]
            ) ? .historyModelBackfill : .scanning
        case .publishing:
            return .publishing
        }
    }
}

struct DashboardHeaderProgressPresentation: Equatable {
    static let reassurance = "首次升级可能需要几分钟，原始数据不会丢失"

    let stage: DashboardHeaderProgressStage
    let text: String
    let countText: String?
    let fraction: Double?
    let showsProgress: Bool
    let showsReassurance: Bool
    let needsAttention: Bool
    let isReady: Bool

    init(progress: PreciseIndexProgress) {
        let stage = DashboardHeaderProgressStage.resolve(progress)
        let rawMessage = progress.message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stage = stage
        switch stage {
        case .idle:
            text = rawMessage.isEmpty ? stage.title : rawMessage
        case .complete:
            text = stage.title
        case .failed:
            if rawMessage.isEmpty {
                text = "失败：精确统计失败"
            } else if rawMessage.contains("失败") {
                text = rawMessage
            } else {
                text = "失败：\(rawMessage)"
            }
        default:
            if rawMessage.isEmpty {
                text = stage.title
            } else if rawMessage.contains(stage.title) {
                text = rawMessage
            } else {
                text = "\(stage.title)：\(rawMessage)"
            }
        }
        countText = progress.total.map { "\(progress.completed)/\($0)" }
        fraction = progress.fraction
        showsProgress = stage.showsProgress
        showsReassurance = stage.isVisible && stage != .complete
        needsAttention = stage == .failed
        isReady = stage == .complete
    }
}

struct DashboardHeaderFreshnessPresentation: Equatable {
    let text: String
    let needsAttention: Bool
    let showsProgress: Bool
    let progressFraction: Double?

    init(
        status: String,
        isRefreshing: Bool,
        generatedAt: Date,
        aggregateCoveredAt: Date? = nil,
        progress: PreciseIndexProgress = .idle
    ) {
        let progressPresentation = DashboardHeaderProgressPresentation(progress: progress)
        if progressPresentation.stage.isVisible {
            text = progressPresentation.text
            needsAttention = progressPresentation.needsAttention
            showsProgress = progressPresentation.showsProgress
            progressFraction = progressPresentation.fraction
            return
        }
        if isRefreshing {
            text = "正在同步"
            needsAttention = false
            showsProgress = false
            progressFraction = nil
            return
        }

        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("失败") || trimmed.contains("陈旧") {
            text = trimmed
            needsAttention = true
            showsProgress = false
            progressFraction = nil
            return
        }

        if let aggregateCoveredAt {
            text = "摘要 \(DateFormatter.statusString(from: generatedAt)) · 图表至 \(DateFormatter.hourMinute.string(from: aggregateCoveredAt))"
        } else {
            text = "更新于 \(DateFormatter.statusString(from: generatedAt))"
        }
        needsAttention = false
        showsProgress = false
        progressFraction = nil
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
    let preciseIndexProgress: PreciseIndexProgress
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
            generatedAt: snapshot.generatedAt,
            aggregateCoveredAt: snapshot.preciseTimeSeriesGeneratedAt,
            progress: preciseIndexProgress
        )
    }

    private var progressPresentation: DashboardHeaderProgressPresentation {
        DashboardHeaderProgressPresentation(progress: preciseIndexProgress)
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

    private var preciseProgressColor: Color {
        switch progressPresentation.stage {
        case .waiting, .structureUpgrade:
            return .orange
        case .historyModelBackfill:
            return .purple
        case .publishing:
            return .teal
        case .preparing, .scanning:
            return AppTheme.accentBlue
        case .failed:
            return AppTheme.accentRed
        case .reconciliation:
            return .orange
        case .idle, .complete:
            return headerPrecisionColor
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
                            Circle()
                                .fill(preciseProgressColor)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(headerPrecisionLabel)
                                        .foregroundStyle(headerPrecisionColor)
                                    Text(freshnessPresentation.text)
                                        .foregroundStyle(freshnessPresentation.needsAttention ? AppTheme.accentRed : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let countText = progressPresentation.countText,
                                       progressPresentation.stage.isVisible {
                                        Text(countText)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                                if progressPresentation.showsReassurance {
                                    Text(DashboardHeaderProgressPresentation.reassurance)
                                        .font(.system(size: 9, weight: .regular))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            if freshnessPresentation.showsProgress {
                                if let fraction = freshnessPresentation.progressFraction {
                                    ProgressView(value: fraction)
                                        .tint(preciseProgressColor)
                                        .frame(width: 52)
                                } else {
                                    ProgressView()
                                        .tint(preciseProgressColor)
                                        .frame(width: 52)
                                }
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .help(
                            progressPresentation.showsReassurance
                                ? DashboardHeaderProgressPresentation.reassurance
                                : freshnessPresentation.text
                        )
                        .accessibilityValue(
                            progressPresentation.countText.map {
                                "\(freshnessPresentation.text)，\($0)"
                            } ?? freshnessPresentation.text
                        )
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

struct StatStrip: View, @preconcurrency Equatable {
    let snapshot: DashboardSnapshot
    var quotaSnapshot: AccountQuotaSnapshot? = nil
    var todayUsageSummary: DayUsage? = nil
    var todayModelBreakdowns: [ModelTokenBreakdown] = []
    var todayModelBreakdownsFresh = false
    var showsModelCostRow = true
    var planLabel = ""
    var isPreparingUsageCache = false
    var isRefreshing = false
    var preciseTimeSeriesFresh = false
    var cacheStatus = ""

    @AppStorage(SharedAccountUsageAttributionSettings.priceModelKey) private var quotaEstimateModelRaw = OfficialAPIPriceModel.gpt56Sol.rawValue
    @AppStorage(DashboardModelCostScope.storageKey) private var modelCostScopeRaw = DashboardModelCostScope.defaultScope.rawValue

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

    private var sevenDayModelData: DashboardSevenDayModelData {
        DashboardSevenDayModelData(
            cacheUsage: snapshot.cacheUsage,
            quotaSnapshot: quotaSnapshot,
            now: snapshot.generatedAt,
            dataAvailable: snapshot.hasPreciseTokenUsage
        )
    }

    private var todayTokens: Int {
        todayUsageSummary?.tokens ?? snapshot.dailyUsage.last {
            Calendar.current.isDateInToday($0.date)
        }?.tokens ?? 0
    }

    private var todayModelDisplayState: ModelAttributionDisplayState {
        guard todayTokens > 0 else { return .current }
        guard !todayModelBreakdowns.isEmpty else { return .pending }
        return todayModelBreakdownsFresh && !isRefreshing ? .current : .stale
    }

    private var sevenDayModelDisplayState: ModelAttributionDisplayState {
        let state = sevenDayModelData.displayState
        guard state == .current else { return state }
        return isRefreshing || !preciseTimeSeriesFresh ? .stale : .current
    }

    private var modelCostScopeBinding: Binding<DashboardModelCostScope> {
        Binding(
            get: { DashboardModelCostScope.storedValue(for: modelCostScopeRaw) },
            set: { modelCostScopeRaw = $0.rawValue }
        )
    }

    /// Live-rate publications invalidate the dashboard root once per second,
    /// but they do not change this historical strip.  Keep the equality key
    /// deliberately metadata-based: the exact index generation and snapshot
    /// timestamp are the authoritative change signals, while avoiding an
    /// O(all-attribution-events) comparison on every live tick.
    static func == (lhs: StatStrip, rhs: StatStrip) -> Bool {
        let left = lhs.snapshot
        let right = rhs.snapshot
        return left.generatedAt == right.generatedAt
            && left.preciseTimeSeriesGeneratedAt == right.preciseTimeSeriesGeneratedAt
            && left.usagePrecision == right.usagePrecision
            && left.stats.totalTokens == right.stats.totalTokens
            && left.stats.peakDayTokens == right.stats.peakDayTokens
            && left.stats.peakThreadTokens == right.stats.peakThreadTokens
            && left.stats.currentStreakDays == right.stats.currentStreakDays
            && left.stats.longestStreakDays == right.stats.longestStreakDays
            && left.stats.totalCalls == right.stats.totalCalls
            && left.stats.firstUsageAt == right.stats.firstUsageAt
            && left.dailyUsage.last == right.dailyUsage.last
            && lhs.todayUsageSummary == rhs.todayUsageSummary
            && left.cacheUsage.total == right.cacheUsage.total
            && left.cacheUsage.attributionProvenanceEpoch == right.cacheUsage.attributionProvenanceEpoch
            && left.cacheUsage.attributionGeneration == right.cacheUsage.attributionGeneration
            && left.cacheUsage.attributionEventsComplete == right.cacheUsage.attributionEventsComplete
            && left.cacheUsage.attributionModelBucketsComplete == right.cacheUsage.attributionModelBucketsComplete
            && left.cacheUsage.attributionCurrentScanUnsafeCauseDetected == right.cacheUsage.attributionCurrentScanUnsafeCauseDetected
            && left.cacheUsage.attributionEvents.count == right.cacheUsage.attributionEvents.count
            && left.cacheUsage.attributionEvents.last?.id == right.cacheUsage.attributionEvents.last?.id
            && left.cacheUsage.modelBreakdowns == right.cacheUsage.modelBreakdowns
            && left.cacheUsage.dailyModelBreakdowns == right.cacheUsage.dailyModelBreakdowns
            && left.cacheUsage.recentBins.count == right.cacheUsage.recentBins.count
            && left.cacheUsage.recentBins.last == right.cacheUsage.recentBins.last
            && lhs.quotaSnapshot == rhs.quotaSnapshot
            && lhs.todayModelBreakdowns == rhs.todayModelBreakdowns
            && lhs.todayModelBreakdownsFresh == rhs.todayModelBreakdownsFresh
            && lhs.showsModelCostRow == rhs.showsModelCostRow
            && lhs.planLabel == rhs.planLabel
            && lhs.isPreparingUsageCache == rhs.isPreparingUsageCache
            && lhs.isRefreshing == rhs.isRefreshing
            && lhs.preciseTimeSeriesFresh == rhs.preciseTimeSeriesFresh
            && lhs.cacheStatus == rhs.cacheStatus
            && lhs.quotaEstimateModelRaw == rhs.quotaEstimateModelRaw
            && lhs.modelCostScopeRaw == rhs.modelCostScopeRaw
    }

    var body: some View {
        let savingsPresentation = self.savingsPresentation
        let sevenDayModelData = self.sevenDayModelData
        let todayTokens = self.todayTokens

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

            if showsModelCostRow {
                DashboardModelCostRow(
                    scope: modelCostScopeBinding,
                    todayRows: todayModelBreakdowns,
                    lifetimeRows: snapshot.cacheUsage.modelBreakdowns,
                    sevenDayRows: sevenDayModelData.rows,
                    todayTokens: todayTokens,
                    lifetimeTokens: snapshot.stats.totalTokens,
                    sevenDayTokens: sevenDayModelData.tokens,
                    fallbackModel: OfficialAPIPriceModel.storedValue(for: quotaEstimateModelRaw),
                    dataAvailable: snapshot.hasPreciseTokenUsage,
                    todayModelDisplayState: todayModelDisplayState,
                    sevenDayDataAvailable: sevenDayModelData.dataAvailable,
                    sevenDayModelDisplayState: sevenDayModelDisplayState,
                    sevenDayEstimateSource: sevenDayModelData.estimateSource
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
    case sevenDay = "本7d"
    case today = "今日"
    case lifetime = "累计"

    static let defaultScope: DashboardModelCostScope = .sevenDay
    static let storageKey = "dashboardModelCostScopeV1"

    var id: String { rawValue }

    static func storedValue(for rawValue: String?) -> DashboardModelCostScope {
        DashboardModelCostScope(rawValue: rawValue ?? "") ?? defaultScope
    }
}

enum ModelAttributionDisplayState: Equatable {
    case current
    case stale
    case pending

    var isWaiting: Bool {
        self != .current
    }
}

struct DashboardSevenDayModelData: Equatable {
    let rows: [ModelTokenBreakdown]
    let tokens: Int
    let dataAvailable: Bool
    let displayState: ModelAttributionDisplayState
    let isEstimated: Bool
    let estimateSource: String?

    init(
        cacheUsage: TokenCacheUsage,
        quotaSnapshot: AccountQuotaSnapshot?,
        now: Date,
        dataAvailable: Bool
    ) {
        guard dataAvailable,
              let resetAt = quotaSnapshot?.sevenDay?.resetsAt,
              resetAt.timeIntervalSince1970.isFinite,
              resetAt > now else {
            rows = []
            tokens = 0
            self.dataAvailable = false
            displayState = .pending
            isEstimated = false
            estimateSource = nil
            return
        }

        let start = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let eventsAreUsable = cacheUsage.attributionModelBucketsComplete
            && !cacheUsage.attributionCurrentScanUnsafeCauseDetected
        if eventsAreUsable {
            let events = cacheUsage.attributionEvents.filter {
                $0.start >= start && $0.start < resetAt
            }
            rows = ModelUsagePresentation.rows(from: events)
            tokens = events.reduce(0) { $0 + max($1.breakdown.totalTokens, 0) }
            self.dataAvailable = true
            displayState = .current
            isEstimated = false
            estimateSource = nil
            return
        }

        // A complete event projection can be retained while the current
        // numeric scan is being refreshed. Show that last trusted model view
        // as stale; never turn an anonymous five-minute aggregate into a
        // fabricated Sol/Terra/Luna attribution.
        if cacheUsage.attributionEventsComplete,
           !cacheUsage.attributionCurrentScanUnsafeCauseDetected {
            let trustedEvents = cacheUsage.attributionEvents.filter {
                $0.start >= start && $0.start < resetAt
            }
            if !trustedEvents.isEmpty {
                rows = ModelUsagePresentation.rows(from: trustedEvents)
                tokens = trustedEvents.reduce(0) { $0 + max($1.breakdown.totalTokens, 0) }
                self.dataAvailable = true
                displayState = .stale
                isEstimated = true
                estimateSource = "上次可信模型明细"
                return
            }
        }

        // Five-minute buckets remain valid for charts and total-token
        // progress, but they do not carry enough information for model
        // attribution. Keep the model-cost surface pending until exact rows
        // are available.
        rows = []
        tokens = 0
        self.dataAvailable = false
        displayState = .pending
        isEstimated = true
        estimateSource = "精确模型归因"
    }
}

struct DashboardModelCostRow: View {
    @Binding var scope: DashboardModelCostScope
    let todayRows: [ModelTokenBreakdown]
    let lifetimeRows: [ModelTokenBreakdown]
    let sevenDayRows: [ModelTokenBreakdown]
    let todayTokens: Int
    let lifetimeTokens: Int
    let sevenDayTokens: Int
    let fallbackModel: OfficialAPIPriceModel
    let dataAvailable: Bool
    let todayModelDisplayState: ModelAttributionDisplayState
    let sevenDayDataAvailable: Bool
    let sevenDayModelDisplayState: ModelAttributionDisplayState
    let sevenDayEstimateSource: String?

    private var sourceRows: [ModelTokenBreakdown] {
        switch scope {
        case .sevenDay: return sevenDayRows
        case .today: return todayRows
        case .lifetime: return lifetimeRows
        }
    }

    private var selectedDataAvailable: Bool {
        switch scope {
        case .sevenDay: return dataAvailable && sevenDayDataAvailable
        case .today, .lifetime: return dataAvailable
        }
    }

    private var items: [FloatingTodayModelUsageItem] {
        guard selectedDataAvailable, hasModelDetail else { return [] }
        return FloatingTodayModelUsagePresentation.items(
            from: sourceRows,
            fallbackModel: fallbackModel
        )
    }

    private var expectedTokens: Int {
        switch scope {
        case .sevenDay: return sevenDayTokens
        case .today: return todayTokens
        case .lifetime: return lifetimeTokens
        }
    }

    private var hasModelDetail: Bool {
        expectedTokens == 0 || !sourceRows.isEmpty
    }

    private var missingDetailText: String {
        switch scope {
        case .sevenDay: return "本7d模型明细待读取"
        case .today: return "今日模型明细待读取"
        case .lifetime: return "逐模型历史待读取"
        }
    }

    private var selectedModelDisplayState: ModelAttributionDisplayState {
        switch scope {
        case .sevenDay: return sevenDayModelDisplayState
        case .today: return todayModelDisplayState
        case .lifetime: return .current
        }
    }

    private var emptyDetailText: String {
        switch scope {
        case .sevenDay: return "本7d暂无模型用量"
        case .today: return "今日暂无模型用量"
        case .lifetime: return "暂无逐模型历史"
        }
    }

    var body: some View {
        // `body` can be revisited by SwiftUI while a live-rate tick is being
        // published.  Materialize the model-cost presentation once per
        // transaction instead of re-normalizing the same rows for every
        // conditional and every card section below.
        let visibleItems = items
        let visibleTotalCost = visibleItems.compactMap(\.costUSD).reduce(0, +)
        let visibleReferenceEntries = visibleItems.compactMap { item -> String? in
            guard let referenceCostUSD = item.referenceCostUSD else { return nil }
            return "\(item.label) 参考 \(referenceCostUSD.quotaEstimatorMoneyText)"
        }
        let visibleReferenceCostSummary = visibleReferenceEntries.isEmpty
            ? nil
            : visibleReferenceEntries.joined(separator: " · ")
        let visiblePrimaryItems = FloatingTodayModelUsagePresentation.dashboardPrimaryItems(from: visibleItems)
        let visibleSecondaryItems = FloatingTodayModelUsagePresentation.dashboardSecondaryItems(from: visibleItems)
        let selectedAvailable = selectedDataAvailable
        let modelDetailAvailable = hasModelDetail

        VStack(spacing: 6) {
            HStack(spacing: 9) {
                DashboardModelCostScopePicker(scope: $scope)

                Text("各模型 API 等值费用")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                if selectedModelDisplayState != .current {
                    HStack(spacing: 4) {
                        Text("正在精准计算中…")
                        if selectedModelDisplayState == .stale {
                            Text("显示上次可信结果")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
                    .fixedSize()
                    .help(
                        sevenDayEstimateSource.map {
                            "\($0)保留显示，精确模型归因完成后自动替换。"
                        } ?? "精确模型归因完成后自动替换。"
                    )
                }

                Spacer(minLength: 4)

                if selectedAvailable, modelDetailAvailable, !visibleItems.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("合计 \(visibleTotalCost.quotaEstimatorMoneyText)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(AppTheme.accentBlue)
                            .monospacedDigit()
                            .fixedSize()
                        if let visibleReferenceCostSummary {
                            Text(visibleReferenceCostSummary)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                }
            }

            if !selectedAvailable {
                if scope == .sevenDay {
                    Text(selectedModelDisplayState == .stale
                        ? "正在精准计算中，显示上次可信结果"
                        : "本7d模型明细待读取")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(selectedModelDisplayState == .stale
                        ? "正在精准计算中，显示上次可信结果"
                        : "今日模型明细待读取")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !modelDetailAvailable {
                Text(missingDetailText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if visibleItems.isEmpty {
                Text(emptyDetailText)
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
                        ForEach(visiblePrimaryItems) { item in
                            DashboardPrimaryModelCostCard(item: item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !visibleSecondaryItems.isEmpty {
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
                            ForEach(visibleSecondaryItems) { item in
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

private struct DashboardModelCostScopePicker: View {
    @Binding var scope: DashboardModelCostScope

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DashboardModelCostScope.allCases) { option in
                Button {
                    scope = option
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(scope == option ? AppTheme.accentBlue : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            scope == option
                                ? AppTheme.selectedControlBackground
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(scope == option ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: 104, height: 26)
        .background(
            AppTheme.solidControlBackground,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型费用范围")
        .accessibilityValue(scope.rawValue)
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
