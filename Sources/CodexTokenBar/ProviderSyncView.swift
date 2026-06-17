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

                        Text("建议退出 Codex Desktop 后执行同步；运行中的 Codex 可能会重新写回历史索引。所有同步都会先创建完整备份，可在本页备份列表选择回滚。")
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
                ProviderSyncMetric(value: "\(store.snapshot.sessionIndexRows)", label: "索引行")
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
                    disabled: store.snapshot.isWorking || dataSource == nil
                ) {
                    store.scan(dataSource: dataSource)
                }

                ProviderSyncStepCard(
                    number: 2,
                    title: "创建备份",
                    subtitle: "先备份 config、SQLite、索引和会话 JSONL，后面不满意可以回滚。",
                    status: backupStepStatus,
                    accent: AppTheme.accentBlue,
                    buttonTitle: "只创建备份",
                    systemImage: "externaldrive.badge.timemachine",
                    disabled: store.snapshot.isWorking || dataSource == nil
                ) {
                    store.backup(dataSource: dataSource)
                }

                ProviderSyncStepCard(
                    number: 3,
                    title: "一键修复",
                    subtitle: "同步 provider，处理异常时间戳，并补齐索引和前端工作区状态。",
                    status: repairStepStatus,
                    accent: AppTheme.accentOrange,
                    buttonTitle: store.dryRunOnly ? "演练修复" : "修复历史",
                    systemImage: "arrow.triangle.2.circlepath",
                    isProminent: true,
                    disabled: store.snapshot.isWorking || dataSource == nil
                ) {
                    store.sync(dataSource: dataSource)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                ProviderSyncStepCard(
                    number: 4,
                    title: "验证结果",
                    subtitle: "修复后检查 provider、数据库、索引和工作区状态是否都正常。",
                    status: verifyStepStatus,
                    accent: AppTheme.accentCyan,
                    buttonTitle: "验证结果",
                    systemImage: "checkmark.seal",
                    disabled: store.snapshot.isWorking || dataSource == nil
                ) {
                    store.verify(dataSource: dataSource)
                }
            }

            ProviderSyncBackupList(
                backups: store.snapshot.backupRecords,
                disabled: store.snapshot.isWorking || dataSource == nil,
                onRollback: { backup in
                    store.rollback(dataSource: dataSource, backup: backup)
                }
            )

            ProviderSyncAdvancedPanel(store: store, backupPath: store.snapshot.lastBackupPath)

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
            return "扫描完成：未发现需修复项。\(visibilitySummaryText)"
        }

        var parts: [String] = []
        if jsonlMismatchCount > 0 {
            parts.append("JSONL \(jsonlMismatchCount) 条")
        }
        if store.snapshot.sqliteRowsToRepair > 0 {
            parts.append("SQLite provider \(store.snapshot.sqliteRowsToRepair) 行")
        }
        if store.snapshot.invalidSessionFiles > 0 {
            parts.append("异常首行 \(store.snapshot.invalidSessionFiles) 条")
        }
        if store.snapshot.workspaceOrderMissing > 0 {
            parts.append("工作区缺序 \(store.snapshot.workspaceOrderMissing) 个")
        }
        return "扫描完成：发现 \(total) 处需要处理，" + parts.joined(separator: "，") + "。\(visibilitySummaryText)"
    }

    private var scanIssueCount: Int {
        jsonlMismatchCount
            + store.snapshot.sqliteRowsToRepair
            + store.snapshot.invalidSessionFiles
            + store.snapshot.workspaceOrderMissing
    }

    private var jsonlMismatchCount: Int {
        store.snapshot.sessionProviders
            .filter { $0.provider != store.snapshot.detectedProvider }
            .reduce(0) { $0 + $1.count }
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
