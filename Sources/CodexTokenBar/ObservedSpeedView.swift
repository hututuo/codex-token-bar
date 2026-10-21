import AppKit
import SwiftUI

struct ObservedSpeedView: View {
    @ObservedObject var monitor: LiveRateMonitor
    private var recentSamples: [ObservedSpeedSample] {
        Array(monitor.speedSamples.lazy.filter { $0.isBody && $0.hasKnownModel }.prefix(6))
    }
    private var readings: [BodySpeedModelReading] {
        BodySpeedModelReading.combined(recent: monitor.modelSpeeds, retained: monitor.retainedModelSpeeds)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正文测速").font(.headline)
                Text("TPS · token/秒").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("统计范围", selection: Binding(get: { monitor.speedWindowMinutes }, set: monitor.setSpeedWindowMinutes)) {
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            if readings.isEmpty {
                Text("暂无合格模型读数").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(readings) { reading in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reading.summary.model).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(reading.summary.tokensPerSecond, format: .number.precision(.fractionLength(1)))
                                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text("TPS").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(reading.historical ? "近7天均速" : "近\(monitor.speedWindowMinutes)分钟均速") · \(reading.summary.sampleCount)条")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(reading.summary.lastMeasuredAt.map { "末次 " + speedTimestamp($0) } ?? "采样时间未知")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            HStack {
                Text("最近6条 · 已识别模型").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查看详情") { BodySpeedHistoryWindowController.shared.present(monitor: monitor) }.buttonStyle(.borderless)
            }
            if recentSamples.isEmpty {
                Text("等待带模型的正文测速").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(recentSamples) { sample in
                    HStack(spacing: 6) {
                        Text(speedTimestamp(sample.endedAt)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 104, alignment: .leading)
                        Text(sample.model).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .lineLimit(1).frame(width: 100, alignment: .leading)
                        Text(sample.bodyTypeLabel).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(monitor.speedThreadTitle(sample.threadID)).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(sample.outputTokens) token / \(sample.durationSeconds, specifier: "%.2f")秒")
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().frame(width: 112, alignment: .trailing)
                        Text("\(sample.tokensPerSecond, specifier: "%.1f") TPS")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(sample.bodyQuality.statusLabel).font(.system(size: 9))
                            .foregroundStyle(sample.bodyQuality.included ? Color.secondary : Color.orange)
                            .frame(width: 84, alignment: .trailing)
                    }.lineLimit(1).padding(.vertical, 4)
                        .help("\(monitor.speedThreadTitle(sample.threadID))\n\(sample.itemID)\n\(sample.bodyQuality.reason ?? "计入模型均速")")
                        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                }
            }
            if monitor.measurementStatus.contains("失败") || monitor.measurementStatus.contains("不可用") {
                Text(monitor.measurementStatus).font(.caption).foregroundStyle(.orange)
            }
        }.padding(.top, 7)
            .accessibilityIdentifier("observed-speed-details")
    }
}

/// The edge detail has its own compact ten-row layout, never a dashboard sheet.
struct ObservedSpeedSidebarView: View {
    @ObservedObject var monitor: LiveRateMonitor
    let onOpenDetails: () -> Void
    private var samples: [ObservedSpeedSample] {
        Array(monitor.speedSamples.lazy.filter { $0.isBody && $0.hasKnownModel }.prefix(10))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("各模型最新速度 · 正文 TPS").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            HStack(spacing: 6) {
                Text("模型").frame(maxWidth: .infinity, alignment: .leading)
                Text("最新").frame(width: 52, alignment: .trailing)
                Text("15min均速").frame(width: 64, alignment: .trailing)
                Text("30min均速").frame(width: 64, alignment: .trailing)
            }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
            VStack(spacing: 6) {
                ForEach(monitor.latestModelSpeeds30m) { model in
                    HStack(spacing: 6) {
                        Text(model.model.replacingOccurrences(of: "gpt-", with: "")).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).help(model.model)
                        Text(model.tokensPerSecond, format: .number.precision(.fractionLength(1))).bold().monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                        averageText(model.model, readings: monitor.modelSpeeds15m).frame(width: 64, alignment: .trailing)
                        averageText(model.model, readings: monitor.modelSpeeds30m).frame(width: 64, alignment: .trailing)
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                }
            }
            if monitor.latestModelSpeeds30m.isEmpty { Text("近30分钟暂无合格读数").font(.caption).foregroundStyle(.white.opacity(0.8)) }
            Text("最近10条").font(.system(size: 10)).foregroundStyle(.secondary)
            if samples.isEmpty { Text("等待带模型的正文测速").font(.caption).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(samples) { sample in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(speedTimestamp(sample.endedAt)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.85))
                            Text(sample.model.replacingOccurrences(of: "gpt-", with: "")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(sample.tokensPerSecond, specifier: "%.1f") TPS").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(sample.bodyQuality.included ? Color.white : Color.orange)
                        }
                        HStack(spacing: 6) {
                            Text(monitor.speedThreadTitle(sample.threadID)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(sample.bodyTypeLabel) · \(sample.outputTokens) / \(sample.durationSeconds, specifier: "%.2f")秒").lineLimit(1)
                        }.font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                        .help("\(sample.itemID)\n\(sample.bodyQuality.reason ?? "计入模型均速")")
                        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
                }
            }
            Button("打开详细信息", action: onOpenDetails).buttonStyle(.borderless).font(.system(size: 11))
        }.padding(.top, 5).accessibilityIdentifier("sidebar-body-speeds")
    }
    private func averageText(_ model: String, readings: [ModelSpeedSummary]) -> Text {
        if let reading = readings.first(where: { $0.model == model }) {
            return Text(reading.tokensPerSecond, format: .number.precision(.fractionLength(1))).monospacedDigit()
        }
        return Text("—")
    }
}

@MainActor
final class BodySpeedHistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = BodySpeedHistoryWindowController()
    private var window: NSWindow?
    private override init() { super.init() }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.contentView = nil
        window = nil
    }
    nonisolated static func centeredFrame(size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, max(1, area.width - 24))
        let height = min(size.height, max(1, area.height - 24))
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }
    func present(monitor: LiveRateMonitor, screen: NSScreen? = nil) {
        let target = screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let panel = window ?? NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "正文测速详情"
        panel.identifier = NSUserInterfaceItemIdentifier("body-speed-history")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: BodySpeedHistoryView(monitor: monitor, onClose: { [weak panel] in panel?.close() }))
        panel.minSize = NSSize(width: 780, height: 480)
        if let target { panel.setFrame(Self.centeredFrame(size: panel.frame.size, in: target.visibleFrame), display: true) }
        else { panel.center() }
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private func speedTimestamp(_ timestamp: Double) -> String {
    Date(timeIntervalSince1970: timestamp).formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
}

private struct BodySpeedTableHeader: View {
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Text("采样时间").frame(width: 112, alignment: .leading)
            Text("会话 / 轮次").frame(maxWidth: .infinity, alignment: .leading)
            Text("正文 ID").frame(width: 72, alignment: .leading)
            Text("类型").frame(width: 56, alignment: .leading)
            Text("token").frame(width: 45, alignment: .trailing)
            Text("秒").frame(width: 44, alignment: .trailing)
            Text("TPS").frame(width: 54, alignment: .trailing)
            Text("采样状态").frame(width: 90, alignment: .trailing)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, compact ? 4 : 7)
    }
}

private struct BodySpeedTableRow: View {
    let sample: ObservedSpeedSample
    let title: String
    var compact = false
    private var quality: BodySpeedQuality { sample.bodyQuality }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Text(speedTimestamp(sample.endedAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                Text(title).lineLimit(1)
                Text("轮 \(sample.turnID.suffix(6)) · \(sample.model.replacingOccurrences(of: "gpt-", with: ""))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(String(sample.itemID.suffix(9))).font(.system(size: 9, design: .monospaced)).frame(width: 72, alignment: .leading)
            Text(sample.bodyTypeLabel).frame(width: 56, alignment: .leading)
            Text("\(sample.outputTokens)").frame(width: 45, alignment: .trailing)
            Text(sample.durationSeconds, format: .number.precision(.fractionLength(2))).frame(width: 44, alignment: .trailing)
            Text(sample.tokensPerSecond, format: .number.precision(.fractionLength(1))).fontWeight(.medium).frame(width: 54, alignment: .trailing)
            Text(quality.statusLabel)
                .foregroundStyle(quality.included ? Color.secondary : Color.orange).frame(width: 90, alignment: .trailing)
                .help(quality.reason ?? "计入模型均速")
        }.font(.system(size: 10)).monospacedDigit().padding(.vertical, compact ? 3 : 8)
            .overlay(alignment: .bottom) { Divider().opacity(0.45) }
            .help("会话：\(title)\n会话 ID：\(sample.threadID)\n轮次 ID：\(sample.turnID)\n正文 ID：\(sample.itemID)\n模型：\(sample.model)\n完成：\(Date(timeIntervalSince1970: sample.endedAt).formatted())\n\(quality.reason ?? "计入模型均速")")
            .contextMenu {
                Button("复制正文 ID") { copy(sample.itemID) }
                Button("复制会话 ID") { copy(sample.threadID) }
                Button("复制轮次 ID") { copy(sample.turnID) }
            }
    }
}

private struct BodySpeedHistoryView: View {
    @ObservedObject var monitor: LiveRateMonitor
    let onClose: () -> Void
    @State private var rows: [ObservedSpeedSample] = []
    @State private var page = 0
    @State private var asOf = Date().timeIntervalSince1970
    private let pageSize = 50
    private var pageRows: ArraySlice<ObservedSpeedSample> { rows.dropFirst(page * pageSize).prefix(pageSize) }
    private func refreshRows() {
        rows = monitor.speedSamples.filter { $0.endedAt <= asOf }.sorted { $0.endedAt == $1.endedAt ? $0.id < $1.id : $0.endedAt > $1.endedAt }
        page = min(page, max(0, (rows.count - 1) / pageSize))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("正文记录").font(.title3.bold())
                Text("\(rows.count) 条").foregroundStyle(.secondary)
                Spacer()
                if monitor.bodyHistoryLoading { ProgressView().controlSize(.small) }
                Picker("保留", selection: Binding(get: { monitor.speedRetentionDays }, set: monitor.setSpeedRetentionDays)) {
                    Text("15 天").tag(15); Text("30 天").tag(30)
                }.frame(width: 130).help("只清理测速记录，不影响用量历史")
                Button("刷新") { asOf = Date().timeIntervalSince1970; page = 0; refreshRows() }
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            HStack {
                Text("最近 \(monitor.speedRetentionDays) 天已收集的正文").lineLimit(1)
                Spacer()
                Text("低置信度保留记录，不计均速")
            }.font(.caption).foregroundStyle(.secondary)
            BodySpeedTableHeader()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pageRows) { row in BodySpeedTableRow(sample: row, title: monitor.speedThreadTitle(row.threadID)) }
                }
            }
            HStack {
                Text("本地日志起止计时 · o200k 分词").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page == 0)
                Text("\(page + 1) / \(max(1, (rows.count + pageSize - 1) / pageSize))").monospacedDigit().font(.caption)
                Button("下一页") { page += 1 }.disabled((page + 1) * pageSize >= rows.count)
            }
        }.padding(20).frame(minWidth: 760, idealWidth: 960, minHeight: 440, idealHeight: 660)
            .onAppear { refreshRows(); monitor.loadBodySpeedHistory() }
            .onChange(of: monitor.speedSamples) { refreshRows() }
    }
}
