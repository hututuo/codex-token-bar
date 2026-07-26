import SwiftUI

struct ProviderSyncStepStatus {
    let label: String
    let text: String
    let systemImage: String
    let color: Color

    static func success(_ label: String, _ text: String) -> ProviderSyncStepStatus {
        ProviderSyncStepStatus(label: label, text: text, systemImage: "checkmark.circle.fill", color: AppTheme.accentCyan)
    }

    static func failure(_ label: String, _ text: String) -> ProviderSyncStepStatus {
        ProviderSyncStepStatus(label: label, text: text, systemImage: "xmark.circle.fill", color: AppTheme.accentOrange)
    }

    static func pending(_ label: String, _ text: String) -> ProviderSyncStepStatus {
        ProviderSyncStepStatus(label: label, text: text, systemImage: "circle.dashed", color: .secondary)
    }
}

struct ProviderSyncStepCard: View {
    let number: Int
    let title: String
    let subtitle: String
    let status: ProviderSyncStepStatus
    let accent: Color
    let buttonTitle: String
    let systemImage: String
    var secondaryTitle: String?
    var secondarySystemImage: String?
    var secondaryRole: ButtonRole?
    var isProminent = false
    var disabled = false
    let action: () -> Void
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(accent)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    ProviderSyncStepStatusPill(status: status, accent: accent)
                }
            }

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 54, alignment: .topLeading)

            Spacer(minLength: 0)

            actionButtons
            .font(.system(size: 12, weight: .medium))
            .disabled(disabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.raisedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let secondaryTitle, let secondaryAction {
            HStack(spacing: 6) {
                primaryButton

                Button(role: secondaryRole) {
                    secondaryAction()
                } label: {
                    Label(secondaryTitle, systemImage: secondarySystemImage ?? "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isProminent {
            Button {
                action()
            } label: {
                Label(buttonTitle, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                action()
            } label: {
                Label(buttonTitle, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct ProviderSyncStepStatusPill: View {
    let status: ProviderSyncStepStatus
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Label {
                Text(status.label)
            } icon: {
                Image(systemName: status.systemImage)
            }
            .labelStyle(.titleAndIcon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(status.color)

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1, height: 10)

            Text(status.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(status.color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(accent.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.24), lineWidth: 1)
        )
    }
}

struct ProviderSyncBackupList: View {
    let backups: [ProviderSyncBackupRecord]
    let disabled: Bool
    let onRollback: (ProviderSyncBackupRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("回滚备份")
                    .font(.system(size: 13, weight: .semibold))
                Text(backups.isEmpty ? "还没有可回滚的备份" : "最近 \(backups.count) 次备份，可选择具体时间回滚")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if backups.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    Text("执行第 2 步或第 3 步后，这里会出现备份列表。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.panelBackgroundAlt)
                )
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(backups) { backup in
                            ProviderSyncBackupRow(
                                backup: backup,
                                disabled: disabled,
                                onRollback: {
                                    onRollback(backup)
                                }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 174)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct ProviderSyncBackupRow: View {
    let backup: ProviderSyncBackupRecord
    let disabled: Bool
    let onRollback: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Text("第 \(backup.sequence) 次")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(AppTheme.accentBlue.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(backup.targetProvider) · \(backup.sessionFileCount) 个会话文件 · \(backup.name)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup.path)])
            } label: {
                Label("打开", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11, weight: .medium))
            .disabled(disabled)

            Button(role: .destructive) {
                onRollback()
            } label: {
                Label("回滚", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11, weight: .medium))
            .disabled(disabled)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppTheme.panelBackgroundAlt)
        )
    }

    private var formattedDate: String {
        if backup.createdAt == .distantPast {
            return "时间未知"
        }
        return backup.createdAt.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }
}

struct ProviderSyncAdvancedPanel: View {
    @ObservedObject var store: ProviderSyncStore
    let backupPath: String?
    let migrationTarget: String
    let migrationCandidateCount: Int
    let migrationDisabled: Bool
    let onRequestMigration: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("高级选项")
                        .font(.system(size: 12, weight: .semibold))
                    Text("一般保持默认；手动 Provider 只用于下方显式迁移。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 270, alignment: .leading)

                Toggle("包含归档会话", isOn: $store.includeArchivedSessions)
                    .toggleStyle(.checkbox)
                Toggle("演练模式", isOn: $store.dryRunOnly)
                    .toggleStyle(.checkbox)

                TextField("显式迁移目标 Provider", text: $store.manualProvider)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.panelBackgroundAlt)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity)

                if let backupPath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backupPath)])
                    } label: {
                        Label("打开备份", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12, weight: .medium))
                }
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.accentOrange)
                Text(
                    "显式迁移：\(migrationCandidateCount) 个候选 → \(migrationTarget)。仅在确实要统一旧历史 Provider 时使用。"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 10)

                Button(role: .destructive) {
                    onRequestMigration()
                } label: {
                    Label("显式迁移历史", systemImage: "arrow.triangle.swap")
                }
                .buttonStyle(.bordered)
                .disabled(migrationDisabled)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.insetBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct ProviderSyncResultPanel: View {
    let snapshot: ProviderSyncSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 14) {
                ProviderDistributionRow(title: "JSONL", values: snapshot.sessionProviders.map { "\($0.provider) \($0.count)" })
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProviderDistributionRow(
                    title: "SQLite",
                    values: snapshot.sqliteProviders.map { "\($0.provider) archived=\($0.archived) \($0.count)" }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ProviderDistributionRow(
                title: "前端",
                values: frontendStateValues
            )

            ProviderDistributionRow(
                title: "数量",
                values: visibilityValues
            )

            ProviderDistributionRow(
                title: "项目",
                values: workspaceValues
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.panelBackgroundAlt)
        )
    }

    private var frontendStateValues: [String] {
        var values: [String] = []
        values.append("索引 \(snapshot.sessionIndexRows)")
        values.append(snapshot.sessionIndexCurrentThreadPresent ? "当前会话 present" : "当前会话 missing")
        if snapshot.workspaceIssues.isEmpty {
            values.append("工作区顺序正常")
        } else {
            values.append(contentsOf: snapshot.workspaceIssues.prefix(3).map { "\($0.label) 缺序 \($0.threadCount) 条" })
        }
        return values
    }

    private var visibilityValues: [String] {
        let summary = snapshot.visibilitySummary
        guard summary.sqliteThreads > 0 else { return ["暂无"] }
        return [
            "SQLite \(summary.sqliteThreads)",
            "未归档 \(summary.activeThreads)",
            "桌面 \(summary.desktopUserThreads)",
            "用户全来源 \(summary.userThreads)",
            "当前项目 \(summary.currentWorkspaceDesktopThreads)",
            "CLI/exec \(summary.cliExecUserThreads)",
            "子会话 \(summary.subagentThreads)",
            "归档 \(summary.archivedThreads)"
        ]
    }

    private var workspaceValues: [String] {
        let workspaces = snapshot.visibilitySummary.workspaces
        guard !workspaces.isEmpty else { return ["暂无"] }
        return workspaces.prefix(5).map { workspace in
            let marker = workspace.isActive ? "当前 " : ""
            return "\(marker)\(workspace.label) 桌面 \(workspace.threadCount) / 接口 \(workspace.interactiveThreadCount)"
        }
    }
}
