import AppKit
import SwiftUI

struct StatusBarOwnerIdentity: Equatable {
    let store: ObjectIdentifier
    let monitor: ObjectIdentifier
    let quota: ObjectIdentifier
    let taskCompletionMonitor: ObjectIdentifier

    init(store: AnyObject, monitor: AnyObject, quota: AnyObject, taskCompletionMonitor: AnyObject) {
        self.store = ObjectIdentifier(store)
        self.monitor = ObjectIdentifier(monitor)
        self.quota = ObjectIdentifier(quota)
        self.taskCompletionMonitor = ObjectIdentifier(taskCompletionMonitor)
    }
}

struct StatusBarLifecycleDecision: Equatable {
    let assignRoot: Bool
    let startTimer: Bool
}

enum StatusBarRefreshCadence {
    static let statusItem: TimeInterval = 1.0
}

final class StatusBarLifecycleState {
    private var ownerIdentity: StatusBarOwnerIdentity?
    private var timerActive = false
    private var lastPresentation: StatusBarTokenItemPresentation?

    func bind(_ identity: StatusBarOwnerIdentity) -> StatusBarLifecycleDecision {
        let ownerChanged = ownerIdentity != identity
        ownerIdentity = identity
        let shouldStartTimer = !timerActive
        timerActive = true
        return StatusBarLifecycleDecision(
            assignRoot: ownerChanged,
            startTimer: shouldStartTimer
        )
    }

    func changes(for presentation: StatusBarTokenItemPresentation) -> StatusBarTokenItemChanges {
        let changes = presentation.changes(previous: lastPresentation)
        lastPresentation = presentation
        return changes
    }

    func close() -> Bool {
        let shouldStopTimer = timerActive
        timerActive = false
        ownerIdentity = nil
        lastPresentation = nil
        return shouldStopTimer
    }
}

final class StatusBarPopoverContentLifecycle {
    private(set) var isContentAttached = false

    func prepareToPresent() -> Bool {
        guard !isContentAttached else { return false }
        isContentAttached = true
        return true
    }

    func didClose() -> Bool {
        guard isContentAttached else { return false }
        isContentAttached = false
        return true
    }
}

@MainActor
final class StatusBarTokenController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var isPresented = false

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?
    private weak var store: CodexUsageStore?
    private weak var monitor: LiveRateMonitor?
    private weak var quota: AccountQuotaStore?
    private weak var taskCompletionMonitor: TaskCompletionMonitor?
    private var onClose: (() -> Void)?
    private let lifecycle = StatusBarLifecycleState()
    private let popoverContentLifecycle = StatusBarPopoverContentLifecycle()

    func show(
        store: CodexUsageStore,
        monitor: LiveRateMonitor,
        quota: AccountQuotaStore,
        taskCompletionMonitor: TaskCompletionMonitor,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.monitor = monitor
        self.quota = quota
        self.taskCompletionMonitor = taskCompletionMonitor
        self.onClose = onClose
        let lifecycleDecision = lifecycle.bind(StatusBarOwnerIdentity(
            store: store,
            monitor: monitor,
            quota: quota,
            taskCompletionMonitor: taskCompletionMonitor
        ))

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "Codex token rate")
            item.button?.imagePosition = .imageLeading
            item.button?.contentTintColor = .controlAccentColor
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.sendAction(on: [.leftMouseDown])
            item.button?.toolTip = "Codex Token Bar 实时速率"
            item.button?.alignment = .center
            item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            statusItem = item
        }

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentSize = NSSize(width: 360, height: 336)
            self.popover = popover
        } else if lifecycleDecision.assignRoot,
                  popoverContentLifecycle.isContentAttached,
                  let hostingController = popover?.contentViewController as? NSHostingController<StatusBarTokenPopoverView> {
            hostingController.rootView = makePopoverView(
                store: store,
                monitor: monitor,
                quota: quota,
                taskCompletionMonitor: taskCompletionMonitor
            )
        }

        updateStatusItem()
        if lifecycleDecision.startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: StatusBarRefreshCadence.statusItem, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updateStatusItem()
                }
            }
        }
        isPresented = true
    }

    func close() {
        popover?.performClose(nil)
        detachPopoverContentIfNeeded()
        popover = nil
        if lifecycle.close() {
            timer?.invalidate()
        }
        timer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        store = nil
        monitor = nil
        quota = nil
        taskCompletionMonitor = nil
        onClose = nil
        isPresented = false
    }

    func popoverDidClose(_ notification: Notification) {
        detachPopoverContentIfNeeded()
        updateStatusItem()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            attachLatestPopoverContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateStatusItem() {
        guard let store, let monitor, let quota, let taskCompletionMonitor else { return }
        let snapshot = TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota)
        guard let button = statusItem?.button else { return }
        let title = "    \(snapshot.statusBarTitle)    "
        let presentation = StatusBarTokenItemPresentation(
            title: title,
            accessibilityValue: statusBarAccessibilityValue(
                snapshot,
                unreadThreadCount: taskCompletionMonitor.unreadThreadCount
            )
        )
        let changes = lifecycle.changes(for: presentation)
        if changes.titleChanged {
            button.title = presentation.title
            let length = max(132, button.intrinsicContentSize.width + 48)
            statusItem?.length = length
        }
        if changes.accessibilityChanged {
            button.setAccessibilityLabel("Codex Token Bar 状态栏速率")
            button.setAccessibilityValue(presentation.accessibilityValue)
        }
    }

    private func attachLatestPopoverContentIfNeeded() {
        guard popoverContentLifecycle.prepareToPresent(),
              let popover, let store, let monitor, let quota, let taskCompletionMonitor else { return }
        popover.contentViewController = NSHostingController(
            rootView: makePopoverView(
                store: store,
                monitor: monitor,
                quota: quota,
                taskCompletionMonitor: taskCompletionMonitor
            )
        )
    }

    private func detachPopoverContentIfNeeded() {
        guard popoverContentLifecycle.didClose() else { return }
        popover?.contentViewController = nil
    }

    private func makePopoverView(
        store: CodexUsageStore,
        monitor: LiveRateMonitor,
        quota: AccountQuotaStore,
        taskCompletionMonitor: TaskCompletionMonitor
    ) -> StatusBarTokenPopoverView {
        StatusBarTokenPopoverView(
            store: store,
            monitor: monitor,
            quota: quota,
            taskCompletionMonitor: taskCompletionMonitor
        ) { [weak self] in
            self?.onClose?()
        }
    }

    private func statusBarAccessibilityValue(_ snapshot: TokenDisplaySnapshot, unreadThreadCount: Int) -> String {
        var parts = [
            String(format: "实时速率 %.1f token 每秒", snapshot.rate),
            "累计 \(snapshot.consumedTokensText)",
            "今天 \(snapshot.todayTokensText)",
            "今天 \(snapshot.todayRequestsText) 次请求",
            snapshot.compactUsageStatus
        ]
        if snapshot.metadataOnlyStatusText == "仅会话元数据" {
            parts.append("当前仅显示会话元数据，精确 token 仍在读取")
        }
        if unreadThreadCount > 0 {
            parts.append("未读会话 \(unreadThreadCount) 个")
        }
        return parts.joined(separator: "；")
    }
}

struct StatusBarTokenItemPresentation: Equatable {
    let title: String
    let accessibilityValue: String

    func changes(previous: StatusBarTokenItemPresentation?) -> StatusBarTokenItemChanges {
        StatusBarTokenItemChanges(
            titleChanged: previous?.title != title,
            accessibilityChanged: previous?.accessibilityValue != accessibilityValue
        )
    }
}

struct StatusBarTokenItemChanges: Equatable {
    let titleChanged: Bool
    let accessibilityChanged: Bool
}

struct StatusBarUsageMetricsPresentation: Equatable {
    let totalTokens: String
    let todayTokens: String
    let todayRequests: String

    init(snapshot: TokenDisplaySnapshot) {
        totalTokens = snapshot.consumedTokensText
        todayTokens = snapshot.todayTokensText
        todayRequests = snapshot.todayRequestsText
    }
}

struct StatusBarTokenPopoverView: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var monitor: LiveRateMonitor
    @ObservedObject var quota: AccountQuotaStore
    @ObservedObject var taskCompletionMonitor: TaskCompletionMonitor
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(InterfaceScaleSettings.autoEnabledKey) private var interfaceScaleAutoEnabled = InterfaceScaleSettings.defaultAutoEnabled
    @AppStorage(InterfaceScaleSettings.manualMultiplierKey) private var interfaceScaleManualMultiplier = InterfaceScaleSettings.defaultManualMultiplier
    let onClose: () -> Void

    private var panelFill: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color.white
    }

    private var panelStroke: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    var body: some View {
        let snapshot = TokenDisplaySnapshot.make(store: store, monitor: monitor, quota: quota)
        let live = monitor.totalSnapshot
        let usageMetrics = StatusBarUsageMetricsPresentation(snapshot: snapshot)
        let interfaceScale = CGFloat(
            InterfaceScaleSettings.effectiveScale(
                manualMultiplier: interfaceScaleManualMultiplier,
                autoEnabled: interfaceScaleAutoEnabled,
                screen: InterfaceScaleSettings.activeScreen()
            )
        )
        let baseSize = CGSize(width: 360, height: 336)

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
                    Text("更新 \(DateFormatter.statusString(from: snapshot.updatedAt))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            StatusBarRateTrack(rate: snapshot.rate)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 2), spacing: 7) {
                StatusBarMetricTile(title: "累计 Token", value: usageMetrics.totalTokens)
                StatusBarMetricTile(title: "今日 Token", value: usageMetrics.todayTokens)
                StatusBarMetricTile(title: "今日请求", value: usageMetrics.todayRequests)
                StatusBarMetricTile(title: "模型生成", value: "\(live.breakdown.modelGenerated)")
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(StatusBarQuotaPresentation.items(for: snapshot.quota)) { item in
                    StatusBarQuotaLine(title: item.title, window: item.window)
                }
                if StatusBarQuotaPresentation.items(for: snapshot.quota).isEmpty {
                    Text("额度待读取")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if taskCompletionMonitor.unreadThreadCount > 0 {
                HStack(spacing: 8) {
                    Label("\(taskCompletionMonitor.unreadThreadCount) 个未读", systemImage: "bell.badge")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.accentOrange)
                    Spacer(minLength: 8)
                    Button {
                        taskCompletionMonitor.markAllRead()
                    } label: {
                        Label("全部已读", systemImage: "checkmark.circle")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                }
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
        .frame(width: 360, height: 336, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(panelStroke, lineWidth: 1)
        )
        .scaleEffect(interfaceScale, anchor: .topLeading)
        .frame(
            width: baseSize.width * interfaceScale,
            height: baseSize.height * interfaceScale,
            alignment: .topLeading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex Token Bar 状态栏详情")
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
                    .fill(Color.primary.opacity(0.07))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时速率进度")
        .accessibilityValue("\(Int((fillFraction * 100).rounded()))%")
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
                .fill(Color.primary.opacity(0.055))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct StatusBarQuotaPresentationItem: Identifiable {
    let title: String
    let window: AccountQuotaWindow

    var id: String { title }
}

enum StatusBarQuotaPresentation {
    static func items(for quota: AccountQuotaSnapshot) -> [StatusBarQuotaPresentationItem] {
        [
            quota.fiveHour.map { StatusBarQuotaPresentationItem(title: "5h", window: $0) },
            quota.sevenDay.map { StatusBarQuotaPresentationItem(title: "7d", window: $0) }
        ].compactMap { $0 }
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
                        .fill(Color.primary.opacity(0.06))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 额度")
        .accessibilityValue(window.map { "剩余 \($0.remainingPercent)%，已用 \($0.usedPercent)%，\($0.accessibleResetText) 重置" } ?? "读取中")
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
        .background(Capsule().fill(Color.primary.opacity(0.055)))
    }
}
