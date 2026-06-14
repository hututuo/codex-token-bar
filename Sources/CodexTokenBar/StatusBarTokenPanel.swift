import AppKit
import SwiftUI

@MainActor
final class StatusBarTokenController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var isPresented = false

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?
    private weak var store: CodexUsageStore?
    private weak var monitor: LiveRateMonitor?
    private weak var quota: AccountQuotaStore?
    private var onClose: (() -> Void)?

    func show(store: CodexUsageStore, monitor: LiveRateMonitor, quota: AccountQuotaStore, onClose: @escaping () -> Void) {
        self.store = store
        self.monitor = monitor
        self.quota = quota
        self.onClose = onClose

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "Codex token rate")
            item.button?.imagePosition = .imageLeading
            item.button?.contentTintColor = .controlAccentColor
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.sendAction(on: [.leftMouseDown])
            item.button?.toolTip = "Codex Token Bar 实时速率"
            statusItem = item
        }

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentSize = NSSize(width: 360, height: 310)
            popover.contentViewController = NSHostingController(
                rootView: StatusBarTokenPopoverView(store: store, monitor: monitor, quota: quota) { [weak self] in
                    self?.onClose?()
                }
            )
            self.popover = popover
        }

        updateStatusItem()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }
        isPresented = true
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
        timer?.invalidate()
        timer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        isPresented = false
    }

    func popoverDidClose(_ notification: Notification) {
        updateStatusItem()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateStatusItem() {
        guard let store, let monitor, let quota else { return }
        let snapshot = TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota)
        guard let button = statusItem?.button else { return }
        button.title = "    \(snapshot.statusBarTitle)    "
        button.alignment = .center
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        statusItem?.length = max(132, button.intrinsicContentSize.width + 48)
    }
}

struct StatusBarTokenPopoverView: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var quota: AccountQuotaStore
    let onClose: () -> Void

    var body: some View {
        let snapshot = TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota)
        let live = monitor.totalSnapshot

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Token Bar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("状态栏实时速率 · \(snapshot.status)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Label("隐藏状态栏", systemImage: "menubar.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(String(format: "%.1f", snapshot.rate))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text("tok/s")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(snapshot.compactUsageStatus)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                        .lineLimit(1)
                    Text("更新 \(DateFormatter.status.string(from: snapshot.updatedAt))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            StatusBarRateTrack(rate: snapshot.rate)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 2), spacing: 7) {
                StatusBarMetricTile(title: "累计 Token", value: snapshot.consumedTokens.abbreviatedTokens)
                StatusBarMetricTile(title: "今日 Token", value: snapshot.todayTokens.abbreviatedTokens)
                StatusBarMetricTile(title: "今日请求", value: "\(snapshot.todayRequests)")
                StatusBarMetricTile(title: "模型生成", value: "\(live.breakdown.modelGenerated)")
            }

            VStack(alignment: .leading, spacing: 6) {
                StatusBarQuotaLine(title: "5h", window: snapshot.quota.fiveHour)
                StatusBarQuotaLine(title: "7d", window: snapshot.quota.sevenDay)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("实时组成")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    StatusBarBreakdownChip(label: "可见", value: live.breakdown.visibleText)
                    StatusBarBreakdownChip(label: "工具", value: live.breakdown.toolArguments)
                    StatusBarBreakdownChip(label: "编辑", value: live.breakdown.patchInput)
                    StatusBarBreakdownChip(label: "输出", value: live.breakdown.toolOutput)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(width: 360, height: 310, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .preferredColorScheme(.light)
    }
}

private struct StatusBarRateTrack: View {
    let rate: Double
    @AppStorage(TokenRateScaleSettings.key) private var tokenRateFullScale = TokenRateScaleSettings.defaultValue

    private var fillFraction: CGFloat {
        let scale = TokenRateScaleSettings.clamped(tokenRateFullScale)
        return CGFloat(min(max(rate, 0), scale) / scale)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.065))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.95), Color.blue.opacity(0.90)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(5, proxy.size.width * fillFraction))
            }
        }
        .frame(height: 6)
    }
}

private struct StatusBarMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.045))
        )
    }
}

private struct StatusBarQuotaLine: View {
    let title: String
    let window: AccountQuotaWindow?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .frame(width: 20, alignment: .leading)
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let percent = Double(window?.remainingPercent ?? 0)
                let width = max(4, proxy.size.width * CGFloat(percent / 100.0))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.055))
                    Capsule()
                        .fill(AppTheme.quotaRemainingColor(percent: percent))
                        .frame(width: width)
                }
            }
            .frame(height: 10)

            Text(window.map { "剩 \($0.remainingPercent)% · \($0.compactResetText)" } ?? "读取中")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .trailing)
        }
    }
}

private struct StatusBarBreakdownChip: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 9))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.045)))
    }
}
