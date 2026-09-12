import AppKit
import SwiftUI

struct DiagnosticLogEntry: Identifiable {
    let id = UUID()
    let source: String
    let summary: String
    let detail: String
    let firstAt: Date
    var lastAt: Date
    var count: Int
    var endedAt: Date?
    var recovered = false
    var text: String {
        "\(summary)\n来源：\(source)\n首次：\(firstAt.ISO8601Format())\n最近：\(lastAt.ISO8601Format()) · 次数：\(count)" +
        (endedAt.map { "\n\(recovered ? "恢复" : "错误变化")：\($0.ISO8601Format())" } ?? "") + "\n\(detail)"
    }
}

@MainActor
final class DiagnosticLogHistory: ObservableObject {
    static let shared = DiagnosticLogHistory()
    @Published private(set) var current: [String: DiagnosticLogEntry] = [:]
    @Published private(set) var history: [DiagnosticLogEntry] = []
    func record(summary: String, logs: String, source: String? = nil, at: Date = Date()) {
        let key = source ?? summary
        if var previous = current[key] {
            if previous.detail == logs {
                guard at.timeIntervalSince(previous.lastAt) >= 1 else { return }
                previous.lastAt = at; previous.count += 1; current[key] = previous
                return
            }
            previous.endedAt = at; previous.recovered = logs.isEmpty
            history.insert(previous, at: 0)
            if history.count > 100 { history.removeLast(history.count - 100) }
            current.removeValue(forKey: key)
        }
        guard !logs.isEmpty else { return }
        current[key] = DiagnosticLogEntry(source: key, summary: summary, detail: logs, firstAt: at, lastAt: at, count: 1)
    }
    var currentText: String {
        let text = current.values.sorted { $0.lastAt > $1.lastAt }.map(\.text).joined(separator: "\n\n")
        return text.isEmpty ? "暂无已记录的当前问题" : text
    }
    var historyText: String {
        history.isEmpty ? "暂无历史记录" : history.map(\.text).joined(separator: "\n\n")
    }
    var report: String {
        "Codex Token Bar · Swift 端\n版本：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n导出时间：\(Date().ISO8601Format())\n记录范围：本次运行；历史最多 100 条\n\n【当前问题】\n\(currentText)\n\n【历史记录】\n\(historyText)"
    }
}

struct DiagnosticNotice: View {
    let summary: String
    let logs: String
    var buttonOnly = false
    @ObservedObject private var history = DiagnosticLogHistory.shared
    @State private var showingLogs = false
    @State private var copied = false
    private var supplement: String {
        logs.isEmpty || history.current.values.contains(where: { $0.detail.contains(logs) }) ? "" : "\n\n当前页面补充诊断：\n\(logs)"
    }
    var body: some View {
        HStack(spacing: 12) {
            if !buttonOnly {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            Button(buttonOnly ? "完整日志" : "查看日志") { copied = false; showingLogs = true }
                .font(.system(size: buttonOnly ? 12 : 11, weight: .medium))
                .padding(.horizontal, buttonOnly ? 6 : 0)
        }
        .sheet(isPresented: $showingLogs) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("运行日志").font(.headline)
                    Spacer()
                    Button(copied ? "已复制全部日志" : "一键复制全部日志") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(history.report + supplement, forType: .string)
                    }
                    Button("关闭") { showingLogs = false }.keyboardShortcut(.cancelAction)
                }
                Text("本次运行 · 历史最多 100 条").font(.caption).foregroundStyle(.secondary)
                Text("当前问题（\(history.current.count)）").font(.headline)
                logArea(history.currentText + supplement)
                Divider()
                Text("历史记录（\(history.history.count)）").font(.headline)
                logArea(history.historyText)
            }.padding(20).frame(width: 680, height: 540)
        }
    }
    private func logArea(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
