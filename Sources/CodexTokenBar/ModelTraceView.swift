import AppKit
import SwiftUI

struct ModelTraceView: View {
    @ObservedObject var controller: ModelTraceController
    var compact = false
    @State private var model = ModelTrace.defaultModel
    @State private var selection: String?
    private var selected: ModelTrace.Run? { controller.runs.first { $0.id == selection } ?? controller.runs.first }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型指纹参考").font(.system(size: compact ? 15 : 22, weight: .bold))
                    Text("ModelTrace · 三份独立回答并行检测").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
                Button("刷新") { controller.refresh() }.disabled(controller.busy)
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("请求模型", selection: $model) { ForEach(ModelTrace.models, id: \.self) { Text($0).tag($0) } }
                    .frame(maxWidth: compact ? .infinity : 300).disabled(controller.busy)
                HStack(spacing: 12) {
                    Text("light · low").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if controller.busy { Button("停止") { controller.stop() } }
                    else { Button("并行检测 3 次") { selection = nil; controller.start(model: model) }.buttonStyle(.borderedProminent) }
                }
            }
            Text("消耗当前 Codex 配置的额度。6.1 Sol 尚未收录，结果仅供特征比较，不能确认身份或排除 Luna。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if compact {
                if !controller.runs.isEmpty {
                    Picker("检测记录", selection: Binding(get: { selected?.id ?? "" }, set: { selection = $0 })) {
                        ForEach(controller.runs) { run in
                            Text("\(Date(timeIntervalSince1970: Double(run.startedAt)).formatted(.dateTime.month().day().hour().minute())) · \(status(run))").tag(run.id)
                        }
                    }
                }
                resultContent
            } else {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("检测记录").font(.headline)
                    if controller.runs.isEmpty { Text("暂无记录").font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(controller.runs) { run in
                                Button { selection = run.id } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack { Text(Date(timeIntervalSince1970: Double(run.startedAt)), format: .dateTime.month().day().hour().minute()); Spacer(); Text(status(run)) }
                                        Text(run.model).fontWeight(.medium)
                                        if let prediction = run.attribution?.prediction { Text("更接近 \(prediction)").foregroundStyle(.secondary) }
                                    }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .background(selected?.id == run.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(width: 230)
                resultContent
            }.frame(minHeight: 260)
            }
            Divider()
            HStack(spacing: compact ? 8 : 12) {
                Toggle("自动检测", isOn: Binding(get: { controller.settings.enabled }, set: { controller.saveAuto(enabled: $0, hours: controller.settings.intervalHours) }))
                    .toggleStyle(.switch).fixedSize().disabled(controller.settingsSaving)
                Picker("频率", selection: Binding(get: { controller.settings.intervalHours }, set: { controller.saveAuto(enabled: controller.settings.enabled, hours: $0) })) {
                    ForEach([1, 6, 12, 24, 48, 168], id: \.self) { Text($0 == 24 ? "每天一次" : "每 \($0) 小时").tag($0) }
                }.frame(width: compact ? 145 : 190).disabled(controller.settingsSaving)
                Spacer()
                if !compact { Text("默认关闭 · 每次并行请求 3 次").font(.caption).foregroundStyle(.secondary) }
            }
            if compact { Text("默认关闭 · 每次并行请求 3 次").font(.caption2).foregroundStyle(.secondary) }
            if controller.settings.enabled, let next = controller.settings.nextRunAt {
                Text("下次：\(Date(timeIntervalSince1970: Double(next)).formatted()) · 默认 6.1 Sol / light")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(compact ? 0 : 24).frame(minWidth: compact ? 0 : 730, minHeight: compact ? 0 : 530)
    }
    private var resultContent: some View {
                VStack(alignment: .leading, spacing: 10) {
                    if let run = selected {
                        HStack { Text(status(run)).font(.headline); Spacer(); Text("已请求 \(run.attempts)/3 · 有效 \(run.validSamples)/3").font(.caption).foregroundStyle(.secondary) }
                        if let attribution = run.attribution {
                            ForEach(Array(attribution.candidates.prefix(5))) { candidate in
                                HStack { Text(candidate.displayName).foregroundStyle(ModelUsagePresentation.color(for: candidate.model)).font(.system(size: 12, weight: .medium)); Spacer(); Text(candidate.probability, format: .percent.precision(.fractionLength(1))).monospacedDigit() }
                                GeometryReader { proxy in
                                    RoundedRectangle(cornerRadius: 3).fill(ModelUsagePresentation.color(for: candidate.model).opacity(0.12))
                                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 3).fill(ModelUsagePresentation.color(for: candidate.model)).frame(width: max(0, proxy.size.width * candidate.probability)) }
                                }.frame(height: 6)
                            }
                            Text("相对匹配分值 · 不是身份正确率").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let message = run.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    } else { Text("选择模型后手动开始检测").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func status(_ run: ModelTrace.Run) -> String {
        switch run.status { case "running": "检测中"; case "completed": "已完成"; case "cancelled": "已停止"; case "interrupted": "已中断"; default: "未完成" }
    }
}

@MainActor
final class ModelTraceWindowController: NSObject {
    static let shared = ModelTraceWindowController()
    private var window: NSWindow?
    func present(source: CodexDataSource?) {
        let controller = ModelTraceController.shared; controller.bind(source: source)
        let panel = window ?? NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 590), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "模型指纹参考"; panel.identifier = NSUserInterfaceItemIdentifier("modeltrace")
        panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 740, height: 560)
        panel.contentView = NSHostingView(rootView: ModelTraceView(controller: controller)); panel.center()
        window = panel; panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
