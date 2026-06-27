import SwiftUI

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
    let onRefresh: () -> Void
    let onChangeDirectory: () -> Void
    let onOpenProviderSync: () -> Void
    @Binding var showingInterfaceScaleMenu: Bool
    @Binding var interfaceScaleAutoEnabled: Bool
    @Binding var interfaceScaleManualMultiplier: Double
    @Binding var showingResetCreditDetails: Bool

    @AppStorage("customAccountDisplayName") private var customAccountDisplayName = ""
    @State private var isEditingDisplayName = false
    @State private var displayNameDraft = ""
    @FocusState private var displayNameFieldFocused: Bool

    private var accountDisplayName: String {
        let trimmed = customAccountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? quotaSnapshot.accountDisplayName : trimmed
    }

    private var planDisplayName: String {
        "Codex Token Bar"
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
                } else {
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
                }

                HStack(spacing: 9) {
                    Text(planDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 132, alignment: .leading)
                    InterfaceScaleMenuButton(
                        isPresented: $showingInterfaceScaleMenu,
                        autoEnabled: $interfaceScaleAutoEnabled,
                        manualMultiplier: $interfaceScaleManualMultiplier
                    )
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

                    Spacer(minLength: 8)

                    Button(action: onRefresh) {
                        Label(isRefreshing ? "刷新中" : "立即刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)
                    .accessibilityLabel(isRefreshing ? "刷新中" : "立即刷新")

                    Button(action: onChangeDirectory) {
                        Label("更改目录", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("更改目录")

                    Button(action: onOpenProviderSync) {
                        Label("会话消失修复", systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("会话消失修复")
                }
                .font(.system(size: 14))
                .padding(.leading, 12)
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
}

struct DataSourceBadge: View {
    let path: String
    let origin: String

    var body: some View {
        Label {
            HStack(spacing: 5) {
                Text(origin)
                    .foregroundStyle(.secondary)
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
        .frame(maxWidth: 260)
        .help(path)
    }
}

struct StatStrip: View {
    let stats: DashboardStats

    var body: some View {
        HStack(spacing: 0) {
            StatCell(value: stats.totalTokens.abbreviatedTokens, label: "累计 Token 数")
            Divider().frame(height: 40)
            StatCell(value: stats.peakDayTokens.abbreviatedTokens, label: "峰值 Token 数")
            Divider().frame(height: 40)
            StatCell(value: stats.peakThreadTokens.abbreviatedTokens, label: "单会话最大 Token")
            Divider().frame(height: 40)
            StatCell(value: "\(stats.currentStreakDays) 天", label: "当前连续天数")
            Divider().frame(height: 40)
            StatCell(value: "\(stats.longestStreakDays) 天", label: "最长连续天数")
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
