import SwiftUI

struct ProviderSyncPage: View {
    @ObservedObject var store: ProviderSyncStore
    let dataSource: CodexDataSource?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("会话消失修复")
                            .font(.system(size: 24, weight: .semibold))
                        Text("按 1-2-3-4 扫描、备份、修复、验证，把消失的历史会话找回来。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("关闭会话消失修复")
                    .accessibilityHint("关闭当前修复向导窗口")
                    .background(
                        Circle()
                            .fill(AppTheme.raisedBackground)
                    )
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ProviderSyncView(store: store, dataSource: dataSource)

                        Text("Codex Desktop 运行时仍可扫描、验证和创建备份；同步与回滚会被后端拒绝。请先退出 Codex，再执行会修改 Provider 数据的操作。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 980, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(24)
            .frame(width: 1040)
        }
        .frame(width: 1080, height: 720)
        .onAppear {
            store.scan(dataSource: dataSource)
        }
    }
}

struct ProviderSyncView: View {
    @ObservedObject var store: ProviderSyncStore
    let dataSource: CodexDataSource?
    @State private var showMigrationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("修复向导")
                        .font(.system(size: 17, weight: .semibold))
                    Text(store.snapshot.status)
                        .font(.system(size: 12))
                        .foregroundStyle(store.snapshot.codexRunning ? AppTheme.accentOrange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                ProviderTargetPill(snapshot: store.snapshot)
            }

            HStack(alignment: .top, spacing: 12) {
                ProviderSyncMetric(value: "\(store.snapshot.sessionFilesFound)", label: "会话文件")
                ProviderSyncMetric(value: "\(store.snapshot.visibilitySummary.sqliteThreads)", label: "SQLite 线程")
                ProviderSyncMetric(value: "\(store.snapshot.visibilitySummary.desktopUserThreads)", label: "桌面会话")
                ProviderSyncMetric(value: "\(store.snapshot.visibilitySummary.currentWorkspaceDesktopThreads)", label: "当前项目")
                ProviderSyncMetric(value: store.snapshot.sqliteIntegrity, label: "数据库检查")
                ProviderSyncMetric(value: "\(store.snapshot.sqliteRowsToRepair)", label: "Provider 行")
                ProviderSyncMetric(value: "\(store.snapshot.migrationCandidateCount)", label: "迁移候选")
            }

            HStack(alignment: .top, spacing: 10) {
                ProviderSyncStepCard(
                    number: 1,
                    title: "扫描现状",
                    subtitle: scanSummary,
                    status: scanStepStatus,
                    accent: AppTheme.accentCyan,
                    buttonTitle: "重新扫描",
                    systemImage: "magnifyingglass",
                    disabled: !store.canScanOrVerify || dataSource == nil
                ) {
                    store.scan(dataSource: dataSource)
                }

                ProviderSyncStepCard(
                    number: 2,
                    title: "创建备份",
                    subtitle: "创建 SQLite 一致性恢复点，不复制数十 GiB 的会话正文。",
                    status: backupStepStatus,
                    accent: AppTheme.accentBlue,
                    buttonTitle: "只创建备份",
                    systemImage: "externaldrive.badge.timemachine",
                    disabled: !store.canCreateBackup || dataSource == nil
                ) {
                    store.backup(dataSource: dataSource)
                }

                ProviderSyncStepCard(
                    number: 3,
                    title: "安全修复",
                    subtitle: "只按每个会话的 canonical 首行修正 SQLite Provider；不改 JSONL、模型、时间戳、索引或工作区。",
                    status: repairStepStatus,
                    accent: AppTheme.accentOrange,
                    buttonTitle: store.dryRunOnly ? "仅建恢复点" : "安全修复",
                    systemImage: "arrow.triangle.2.circlepath",
                    isProminent: true,
                    disabled: !store.canSync || dataSource == nil
                ) {
                    store.sync(dataSource: dataSource)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                ProviderSyncStepCard(
                    number: 4,
                    title: "验证结果",
                    subtitle: "检查会话首行与 SQLite Provider 是否逐线程一致，并验证数据库完整性。",
                    status: verifyStepStatus,
                    accent: AppTheme.accentCyan,
                    buttonTitle: "验证结果",
                    systemImage: "checkmark.seal",
                    disabled: !store.canScanOrVerify || dataSource == nil
                ) {
                    store.verify(dataSource: dataSource)
                }
            }

            ProviderSyncBackupList(
                backups: store.snapshot.backupRecords,
                disabled: !store.canRollback || dataSource == nil,
                onRollback: { backup in
                    store.rollback(dataSource: dataSource, backup: backup)
                }
            )

            ProviderSyncAdvancedPanel(
                store: store,
                backupPath: store.snapshot.lastBackupPath,
                migrationTarget: explicitMigrationTarget,
                migrationCandidateCount: store.snapshot.migrationCandidateCount,
                migrationDisabled: !store.canMigrate || dataSource == nil,
                onRequestMigration: {
                    showMigrationConfirmation = true
                }
            )

            ProviderSyncResultPanel(snapshot: store.snapshot)
        }
        .padding(16)
        .frame(maxWidth: 980)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .onAppear {
            if store.snapshot.providerSource == "等待扫描" {
                store.scan(dataSource: dataSource)
            }
        }
        .confirmationDialog(
            "确认显式迁移历史 Provider？",
            isPresented: $showMigrationConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "迁移 \(store.snapshot.migrationCandidateCount) 个会话到 \(explicitMigrationTarget)",
                role: .destructive
            ) {
                store.migrate(dataSource: dataSource)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "这不是“安全修复”：它会流式改写每个候选 JSONL 的 canonical 首行并更新 SQLite Provider。程序会先创建小型恢复点，不修改消息正文、模型、时间戳、session_index 或工作区；目标必须与 config.toml 当前设置一致。如果旧会话含 encrypted_content，跨 Provider 或跨账号后可能无法解密；恢复点只能撤销元数据迁移，不能让另一账号解密原内容。"
            )
        }
    }

    private var scanStepStatus: ProviderSyncStepStatus {
        if !store.hasScanned && store.snapshot.providerSource == "等待扫描" {
            return .pending("未运行", "等待扫描")
        }
        let total = scanIssueCount
        return total == 0
            ? .success("已扫描", "未发现不一致")
            : .failure("已扫描", "发现 \(total) 处不一致")
    }

    private var backupStepStatus: ProviderSyncStepStatus {
        if store.hasBackedUp || store.snapshot.lastBackupPath != nil {
            return .success("已运行", "已备份")
        }
        return .pending("未运行", "未备份")
    }

    private var repairStepStatus: ProviderSyncStepStatus {
        if store.hasRepaired || store.snapshot.changedSessionFiles > 0 || store.snapshot.sqliteRowsChanged > 0 {
            return .success("已运行", "已进行修复")
        }
        return .pending("未运行", "未进行修复")
    }

    private var verifyStepStatus: ProviderSyncStepStatus {
        guard store.hasVerified || store.snapshot.status.hasPrefix("验证") else {
            return .pending("未运行", "未验证")
        }
        return verificationIssueCount == 0
            ? .success("已运行", "已验证")
            : .failure("已运行", "已验证，仍有 \(verificationIssueCount) 处")
    }

    private var verificationIssueCount: Int {
        scanIssueCount + (store.snapshot.sqliteIntegrity == "ok" ? 0 : 1)
    }

    private var scanSummary: String {
        if store.snapshot.providerSource == "等待扫描" {
            return "读取会话文件、SQLite 和索引，先确认到底哪里不一致。"
        }

        let total = scanIssueCount
        guard total > 0 else {
            let migration = store.snapshot.migrationCandidateCount > 0
                ? "另有 \(store.snapshot.migrationCandidateCount) 个会话可显式迁移。"
                : ""
            return "扫描完成：未发现安全修复项。\(migration)\(visibilitySummaryText)"
        }

        var parts: [String] = []
        if store.snapshot.sqliteRowsToRepair > 0 {
            parts.append("SQLite provider \(store.snapshot.sqliteRowsToRepair) 行")
        }
        if store.snapshot.invalidSessionFiles > 0 {
            parts.append("异常首行 \(store.snapshot.invalidSessionFiles) 条")
        }
        if store.snapshot.ambiguousThreadCount > 0 {
            parts.append("歧义线程 \(store.snapshot.ambiguousThreadCount) 个")
        }
        if store.snapshot.pendingMigrationRecovery {
            parts.append("未完成迁移恢复 1 项")
        }
        return "扫描完成：发现 \(total) 处需要处理，" + parts.joined(separator: "，") + "。\(visibilitySummaryText)"
    }

    private var scanIssueCount: Int {
        store.snapshot.sqliteRowsToRepair
            + store.snapshot.invalidSessionFiles
            + store.snapshot.ambiguousThreadCount
            + (store.snapshot.pendingMigrationRecovery ? 1 : 0)
    }

    private var explicitMigrationTarget: String {
        let manual = store.manualProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? "未填写" : manual
    }

    private var visibilitySummaryText: String {
        let summary = store.snapshot.visibilitySummary
        guard summary.sqliteThreads > 0 else { return "历史数量还未读取。" }
        var parts = [
            "SQLite \(summary.sqliteThreads)",
            "桌面 \(summary.desktopUserThreads)",
            "当前项目 \(summary.currentWorkspaceDesktopThreads)"
        ]
        if summary.cliExecUserThreads > 0 {
            parts.append("CLI/exec \(summary.cliExecUserThreads)")
        }
        if summary.subagentThreads > 0 {
            parts.append("子会话 \(summary.subagentThreads)")
        }
        if summary.archivedThreads > 0 {
            parts.append("归档 \(summary.archivedThreads)")
        }
        return "数量口径：" + parts.joined(separator: "，") + "。项目卡片可能只预览 3 条，完整列表以项目行的接口数为准。"
    }
}
