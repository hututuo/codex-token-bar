import AppKit
import SwiftUI
import TokenBarDiagnosticsCore
import UniformTypeIdentifiers

enum DiagnosticRuntime {
    private static let isTestProcess = CommandLine.arguments.first?.contains(".xctest") == true
    static let journal = DiagnosticJournal(root: DiagnosticConfiguration.production.journal,
        version: Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "",
        build: Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "")
    static func record(_ area: DiagnosticArea, _ phase: DiagnosticPhase, _ metrics: [String:Int64] = [:]) {
        guard !isTestProcess else { return }
        journal.record(area, phase, metrics: metrics)
    }
    static func progress(_ value: PreciseIndexProgress, backend: Bool, generation: Int) {
        record(backend ? .backendProgress : .uiProgress,
            value.phase == .failed ? .failed : value.phase == .complete ? .completed : .progress,
            ["completed":Int64(value.completed), "total":Int64(value.total ?? 0), "generation":Int64(generation)])
    }
    static func confirmInstallation() {
        guard !isTestProcess else { return }
        let configuration = DiagnosticConfiguration.production
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""
        DispatchQueue.global(qos:.utility).async {
            DiagnosticInstallations.confirm(configuration:configuration,version:version,build:build,journal:journal)
        }
    }
    static func migration(_ value: BusinessDatabaseMigration.Progress) {
        record(.migration, DiagnosticPhase(rawValue:value.stage.rawValue) ?? .progress,
            ["completed":Int64(value.completed),"total":Int64(value.total)])
    }
    static func migrationPhase(_ value: String) { record(.migration, DiagnosticPhase(rawValue:value) ?? .progress) }
}

@MainActor
final class DiagnosticsExportController: ObservableObject {
    static let shared = DiagnosticsExportController()
    @Published private(set) var exporting = false
    @Published private(set) var result = ""
    func chooseAndExport() {
        guard !exporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TokenBar-Diagnostics-\(UUID().uuidString.prefix(8)).zip"
        panel.message = "仅导出脱敏诊断信息，不含密钥、对话或原始路径。诊断包保存在本机，由你决定是否发送。"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            self.exporting = true; self.result = "正在采集诊断信息…"
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TokenBarDiagnostics")
            let configuration = DiagnosticConfiguration.production
            Task {
                let success = await Task.detached(priority:.utility) {
                    do { try DiagnosticCLI.export(to: destination, configuration:configuration, executable:helper); return true }
                    catch { return false }
                }.value
                self.exporting = false
                self.result = success ? "诊断包已保存，可查看后发送给支持人员。" : "导出失败，请选择可写的新文件位置。"
                if success { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
        }
    }
}

struct DiagnosticsExportButton: View {
    @ObservedObject private var controller = DiagnosticsExportController.shared
    var body: some View {
        VStack(alignment:.leading, spacing:4) {
            Button(controller.exporting ? "正在生成诊断包…" : "导出升级与运行诊断包") { controller.chooseAndExport() }
                .disabled(controller.exporting)
            if !controller.result.isEmpty { Text(controller.result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}
