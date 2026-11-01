import AppKit
import SwiftUI

/// Available before any dashboard/database owner is created. Sparkle retains
/// its usual signed-update protocol and installer UI; this view cannot change
/// the release feed, bypass verification, or delete/restore business files.
@MainActor
struct BusinessRecoveryView: View {
    let onRetry: () -> Void
    @State private var exporting = false
    @State private var detailsVisible = false
    @State private var preview = "正在读取诊断…"
    @State private var message: String?
    @State private var persistenceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("重试账本准备", action: onRetry)
                Button("检查软件更新") { ApplicationSoftwareUpdater.shared.controller.updater.checkForUpdates() }
                Button(exporting ? "正在导出…" : "导出完整迁移日志") { export() }.disabled(exporting)
                Button("退出") { NSApp.terminate(nil) }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            if let persistenceError {
                Text("日志未能完整写入磁盘：\(persistenceError)。下方仅保留最近的内存记录，请先保存。")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            DisclosureGroup("迁移诊断（最近 100 条；导出包含全部已保存的尝试）", isExpanded: $detailsVisible) {
                Text("日志可能包含本机路径，分享前请检查。每次尝试分别保留，导出不会删除原日志。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 230)
            }
        }.task {
            do {
                let text = try await Task.detached(priority: .utility) {
                    try BusinessMigrationDiagnostics.preview(at: BusinessMigrationDiagnostics.productionDirectory())
                }.value
                preview = text
            } catch { preview = "读取诊断失败：\(error.localizedDescription)" }
            persistenceError = BusinessMigrationDiagnostics.currentPersistenceError
            if persistenceError != nil { preview = BusinessMigrationDiagnostics.currentMemoryPreview }
        }
    }
    private func export() {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let target = try await Task.detached(priority: .utility) {
                    try BusinessMigrationDiagnostics.exportToSupportDirectory()
                }.value
                message = "完整日志已保存：\(target.path)"
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch { message = "导出失败，原日志未删除：\(error.localizedDescription)" }
        }
    }
}
