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
    static let dataSourceWidth: CGFloat = 240
    static let badgeHorizontalPadding: CGFloat = 9
    static let iconWidth: CGFloat = 14
    static let badgeSpacing: CGFloat = 5
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

                VStack(spacing: 7) {
                    HStack(spacing: 9) {
                        if presentationMode.showsActions {
                            InterfaceScaleMenuButton(
                                isPresented: $showingInterfaceScaleMenu,
                                autoEnabled: $interfaceScaleAutoEnabled,
                                manualMultiplier: $interfaceScaleManualMultiplier
                            )
                        }
                        Text("Local")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(AppTheme.borderStrong, lineWidth: 1)
                            )
                        DataSourceBadge(path: dataSourceLabel, origin: dataSourceOrigin)
                        Text(status)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if presentationMode.showsActions {
                        HStack(spacing: 9) {
                            Spacer(minLength: 0)

                            if actions.contains(.markAllRead) {
                                Button(action: markAllRead) {
                                    Label("全部已读", systemImage: "checkmark.circle")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(
                                            markAllReadPresentation.tone == .active
                                                ? AppTheme.accentBlue
                                                : Color.secondary
                                        )
                                        .frame(minWidth: 76)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            markAllReadPresentation.tone == .active
                                                ? AppTheme.selectedControlBackground
                                                : AppTheme.solidControlBackground,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(AppTheme.borderStrong, lineWidth: 1)
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
                                    Label(isRefreshing ? "刷新中" : "立即刷新", systemImage: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .disabled(isRefreshing)
                                .accessibilityLabel(isRefreshing ? "刷新中" : "立即刷新")
                            }

                            if actions.contains(.changeDirectory) {
                                Button(action: onChangeDirectory) {
                                    Label("更改目录", systemImage: "folder")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("更改目录")
                            }

                            if actions.contains(.providerRepair) {
                                Button(action: onOpenProviderSync) {
                                    Label("会话消失修复", systemImage: "wrench.and.screwdriver")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("会话消失修复")
                            }

                            if actions.contains(.threadDelete) {
                                Button(action: onThreadDeleteConnectionAction) {
                                    Label(threadDeleteStatus.dashboardActionTitle, systemImage: "trash")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(
                                            threadDeleteStatus.connected
                                                ? AppTheme.accentGreen
                                                : AppTheme.accentRed
                                        )
                                }
                                .buttonStyle(.bordered)
                                .help(threadDeleteStatus.message)
                                .accessibilityLabel(threadDeleteStatus.dashboardActionTitle)
                                .accessibilityValue(threadDeleteStatus.message)
                                .accessibilityHint(
                                    threadDeleteStatus.connected
                                        ? "重新连接 Codex 会话删除按钮"
                                        : "启用 Codex 会话删除按钮"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
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
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(AppTheme.raisedBackground)
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .frame(width: DashboardHeaderContextLayout.dataSourceWidth)
        .help(path)
        .accessibilityLabel("数据源 \(origin) \(path)")
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
    var isPreparingUsageCache = false
    var cacheStatus = ""

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

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                StatCell(value: tokenValue(stats.totalTokens.abbreviatedTokens), label: "累计 Token 数")
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
    }
}
