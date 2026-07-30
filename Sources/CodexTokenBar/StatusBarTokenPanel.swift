import AppKit
import SwiftUI

struct StatusBarOwnerIdentity: Equatable {
    let store: ObjectIdentifier
    let monitor: ObjectIdentifier
    let quota: ObjectIdentifier
    let radar: ObjectIdentifier
    let taskCompletionMonitor: ObjectIdentifier

    init(store: AnyObject, monitor: AnyObject, quota: AnyObject, radar: AnyObject, taskCompletionMonitor: AnyObject) {
        self.store = ObjectIdentifier(store)
        self.monitor = ObjectIdentifier(monitor)
        self.quota = ObjectIdentifier(quota)
        self.radar = ObjectIdentifier(radar)
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

enum StatusBarPopoverMetrics {
    static let width: CGFloat = 390
    static let height: CGFloat = 440

    static func size(scale: CGFloat) -> NSSize {
        let safeScale = max(0.5, min(2, scale.isFinite ? scale : 1))
        return NSSize(width: width * safeScale, height: height * safeScale)
    }
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

struct StatusBarPopoverActivityState {
    private(set) var isPresented = false

    mutating func transition(to presented: Bool) -> Bool {
        guard isPresented != presented else { return false }
        isPresented = presented
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
    private weak var radar: CodexRadarStore?
    private weak var taskCompletionMonitor: TaskCompletionMonitor?
    private var metricsEnabled = true
    private var metricConfiguration = StatusBarMetricConfiguration.default
    private var summaryConfiguration = StatusSummaryConfiguration.default
    private var onOpenDashboard: (() -> Void)?
    private var onOpenSettings: (() -> Void)?
    private var onClose: (() -> Void)?
    private var onPopoverPresentationChanged: ((Bool) -> Void)?
    private let lifecycle = StatusBarLifecycleState()
    private var popoverActivity = StatusBarPopoverActivityState()

    func show(
        store: CodexUsageStore,
        monitor: LiveRateMonitor,
        quota: AccountQuotaStore,
        radar: CodexRadarStore,
        taskCompletionMonitor: TaskCompletionMonitor,
        metricsEnabled: Bool = true,
        configuration: StatusBarMetricConfiguration = .default,
        summaryConfiguration: StatusSummaryConfiguration = .default,
        onOpenDashboard: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onPopoverPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        let summaryConfigurationChanged = self.summaryConfiguration != summaryConfiguration
        self.store = store
        self.monitor = monitor
        self.quota = quota
        self.radar = radar
        self.taskCompletionMonitor = taskCompletionMonitor
        self.metricsEnabled = metricsEnabled
        metricConfiguration = configuration
        self.summaryConfiguration = summaryConfiguration
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        self.onPopoverPresentationChanged = onPopoverPresentationChanged
        let lifecycleDecision = lifecycle.bind(StatusBarOwnerIdentity(
            store: store,
            monitor: monitor,
            quota: quota,
            radar: radar,
            taskCompletionMonitor: taskCompletionMonitor
        ))

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.contentTintColor = .controlAccentColor
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.sendAction(on: [.leftMouseDown])
            item.button?.alignment = .center
            item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            statusItem = item
        }

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentSize = NSSize(width: StatusBarPopoverMetrics.width, height: StatusBarPopoverMetrics.height)
            self.popover = popover
        } else if (lifecycleDecision.assignRoot || summaryConfigurationChanged),
                  let hostingController = popover?.contentViewController as? NSHostingController<StatusBarTokenPopoverView> {
            hostingController.rootView = makePopoverView(
                store: store,
                monitor: monitor,
                quota: quota,
                radar: radar,
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
        setPopoverPresented(false)
        let closingPopover = popover
        popover = nil
        closingPopover?.performClose(nil)
        DispatchQueue.main.async {
            closingPopover?.contentViewController = nil
        }
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
        radar = nil
        taskCompletionMonitor = nil
        metricsEnabled = true
        metricConfiguration = .default
        summaryConfiguration = .default
        onOpenDashboard = nil
        onOpenSettings = nil
        onClose = nil
        onPopoverPresentationChanged = nil
        isPresented = false
    }

    func popoverDidClose(_ notification: Notification) {
        setPopoverPresented(false)
        updateStatusItem()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            setPopoverPresented(true)
            updatePopoverSize(for: button)
            attachLatestPopoverContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateStatusItem() {
        guard let store, let monitor, let quota, let radar, let taskCompletionMonitor else { return }
        let snapshot = TokenDisplaySnapshot.make(
            store: store,
            monitor: monitor,
            quota: quota,
            runningThreads: taskCompletionMonitor.runningThreadSummary
        )
        let radarPresentation = CodexRadarPresentationState(
            snapshot: radar.snapshot,
            status: radar.status,
            diagnostics: radar.diagnostics,
            staleDataDisplayed: radar.staleDataDisplayed,
            feedStaleDataDisplayed: radar.feedStaleDataDisplayed,
            crowdSnapshot: radar.crowdSnapshot
        )
        let presentationConfiguration = metricsEnabled
            ? metricConfiguration
            : StatusBarMetricConfiguration(
                version: metricConfiguration.version,
                orderedMetricIDs: metricConfiguration.orderedMetricIDs,
                selectedMetricIDs: [],
                showsIcon: true,
                labelStyle: metricConfiguration.labelStyle
            )
        let metricsPresentation = StatusBarMetricsPresentation.make(
            values: StatusBarMetricValues(
                snapshot: snapshot,
                radar: radarPresentation,
                rateAvailable: monitor.monitoringEnabled && monitor.currentDataSourceIdentity != nil,
                unreadThreadCount: taskCompletionMonitor.statusBarUnreadThreadCount
            ),
            configuration: presentationConfiguration
        )
        guard let button = statusItem?.button else { return }
        let showsRecoveryIcon = presentationConfiguration.showsIcon || metricsPresentation.text.isEmpty
        let presentation = StatusBarTokenItemPresentation(
            title: metricsPresentation.text,
            accessibilityValue: metricsPresentation.accessibilityValue,
            showsIcon: showsRecoveryIcon,
            toolTip: metricsPresentation.accessibilityValue
        )
        let changes = lifecycle.changes(for: presentation)
        if changes.imageChanged {
            button.image = presentation.showsIcon
                ? NSImage(
                    systemSymbolName: "bolt.circle.fill",
                    accessibilityDescription: "Codex Token Bar"
                )
                : nil
            button.imagePosition = presentation.showsIcon ? .imageLeading : .noImage
        }
        if changes.titleChanged {
            button.title = presentation.title
        }
        if changes.accessibilityChanged {
            button.setAccessibilityLabel("Codex Token Bar 状态栏指标")
            button.setAccessibilityValue(presentation.accessibilityValue)
        }
        if changes.toolTipChanged {
            button.toolTip = presentation.toolTip
        }
        if changes.titleChanged || changes.imageChanged {
            statusItem?.length = NSStatusItem.variableLength
        }
    }

    private func attachLatestPopoverContentIfNeeded() {
        guard let popover,
              popover.contentViewController == nil,
              let store, let monitor, let quota, let radar, let taskCompletionMonitor else { return }
        popover.contentViewController = NSHostingController(
            rootView: makePopoverView(
                store: store,
                monitor: monitor,
                quota: quota,
                radar: radar,
                taskCompletionMonitor: taskCompletionMonitor
            )
        )
    }

    private func updatePopoverSize(for button: NSStatusBarButton) {
        let defaults = UserDefaults.standard
        let autoEnabled = defaults.object(forKey: InterfaceScaleSettings.autoEnabledKey) == nil
            ? InterfaceScaleSettings.defaultAutoEnabled
            : defaults.bool(forKey: InterfaceScaleSettings.autoEnabledKey)
        let manualMultiplier = defaults.object(forKey: InterfaceScaleSettings.manualMultiplierKey) == nil
            ? InterfaceScaleSettings.defaultManualMultiplier
            : defaults.double(forKey: InterfaceScaleSettings.manualMultiplierKey)
        let scale = CGFloat(InterfaceScaleSettings.effectiveScale(
            manualMultiplier: manualMultiplier,
            autoEnabled: autoEnabled,
            screen: button.window?.screen ?? InterfaceScaleSettings.activeScreen()
        ))
        popover?.contentSize = StatusBarPopoverMetrics.size(scale: scale)
    }

    private func makePopoverView(
        store: CodexUsageStore,
        monitor: LiveRateMonitor,
        quota: AccountQuotaStore,
        radar: CodexRadarStore,
        taskCompletionMonitor: TaskCompletionMonitor
    ) -> StatusBarTokenPopoverView {
        StatusBarTokenPopoverView(
            store: store,
            monitor: monitor,
            quota: quota,
            radar: radar,
            taskCompletionMonitor: taskCompletionMonitor,
            configuration: summaryConfiguration,
            onOpenDashboard: { [weak self] in self?.openDashboardFromPopover() },
            onOpenSettings: { [weak self] in self?.openSettingsFromPopover() },
            onClose: { [weak self] in self?.switchToIconOnlyFromPopover() }
        )
    }

    private func openDashboardFromPopover() {
        popover?.performClose(nil)
        onOpenDashboard?()
    }

    private func openSettingsFromPopover() {
        popover?.performClose(nil)
        onOpenSettings?()
    }

    private func switchToIconOnlyFromPopover() {
        popover?.performClose(nil)
        onClose?()
    }

    private func setPopoverPresented(_ presented: Bool) {
        guard popoverActivity.transition(to: presented) else { return }
        onPopoverPresentationChanged?(presented)
    }

}

struct StatusBarTokenItemPresentation: Equatable {
    let title: String
    let accessibilityValue: String
    let showsIcon: Bool
    let toolTip: String?

    init(
        title: String,
        accessibilityValue: String,
        showsIcon: Bool = true,
        toolTip: String? = nil
    ) {
        self.title = title
        self.accessibilityValue = accessibilityValue
        self.showsIcon = showsIcon
        self.toolTip = toolTip
    }

    func changes(previous: StatusBarTokenItemPresentation?) -> StatusBarTokenItemChanges {
        StatusBarTokenItemChanges(
            titleChanged: previous?.title != title,
            accessibilityChanged: previous?.accessibilityValue != accessibilityValue,
            imageChanged: previous?.showsIcon != showsIcon,
            toolTipChanged: previous?.toolTip != toolTip
        )
    }
}

struct StatusBarTokenItemChanges: Equatable {
    let titleChanged: Bool
    let accessibilityChanged: Bool
    let imageChanged: Bool
    let toolTipChanged: Bool

    init(
        titleChanged: Bool,
        accessibilityChanged: Bool,
        imageChanged: Bool = false,
        toolTipChanged: Bool = false
    ) {
        self.titleChanged = titleChanged
        self.accessibilityChanged = accessibilityChanged
        self.imageChanged = imageChanged
        self.toolTipChanged = toolTipChanged
    }
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
    @ObservedObject var radar: CodexRadarStore
    @ObservedObject var taskCompletionMonitor: TaskCompletionMonitor
    let configuration: StatusSummaryConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(InterfaceScaleSettings.autoEnabledKey) private var interfaceScaleAutoEnabled = InterfaceScaleSettings.defaultAutoEnabled
    @AppStorage(InterfaceScaleSettings.manualMultiplierKey) private var interfaceScaleManualMultiplier = InterfaceScaleSettings.defaultManualMultiplier
    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
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
        let snapshot = TokenDisplaySnapshot.make(
            store: store,
            monitor: monitor,
            quota: quota,
            runningThreads: taskCompletionMonitor.runningThreadSummary
        )
        let live = monitor.totalSnapshot
        let interfaceScale = CGFloat(
            InterfaceScaleSettings.effectiveScale(
                manualMultiplier: interfaceScaleManualMultiplier,
                autoEnabled: interfaceScaleAutoEnabled,
                screen: InterfaceScaleSettings.activeScreen()
            )
        )
        let baseSize = CGSize(width: StatusBarPopoverMetrics.width, height: StatusBarPopoverMetrics.height)
        let radarPresentation = CodexRadarPresentationState(
            snapshot: radar.snapshot,
            status: radar.status,
            diagnostics: radar.diagnostics,
            staleDataDisplayed: radar.staleDataDisplayed,
            feedStaleDataDisplayed: radar.feedStaleDataDisplayed,
            crowdSnapshot: radar.crowdSnapshot
        )
        let metricValues = StatusBarMetricValues(
            snapshot: snapshot,
            radar: radarPresentation,
            rateAvailable: monitor.monitoringEnabled && monitor.currentDataSourceIdentity != nil,
            unreadThreadCount: taskCompletionMonitor.statusBarUnreadThreadCount
        )
        let radarPalette = FloatingPanelReadableTextPalette(
            backgroundLuminance: colorScheme == .dark ? 0.10 : 0.96
        )

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Token Bar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("状态摘要 · \(snapshot.status)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("按设置编排")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    if configuration.visibleSectionIDs.isEmpty {
                        VStack(spacing: 5) {
                            Image(systemName: "rectangle.stack.badge.minus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("未选择摘要内容")
                                .font(.system(size: 11, weight: .semibold))
                            Text("可在状态栏设置中重新启用并排序")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                    } else {
                        ForEach(configuration.visibleSectionIDs) { section in
                            summarySection(
                                section,
                                snapshot: snapshot,
                                live: live,
                                metricValues: metricValues,
                                radarPresentation: radarPresentation,
                                radarPalette: radarPalette
                            )
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                StatusBarActionButton(title: "主界面", systemImage: "rectangle.on.rectangle", action: onOpenDashboard)
                StatusBarActionButton(title: "设置", systemImage: "gearshape", action: onOpenSettings)
                StatusBarActionButton(title: "只留图标", systemImage: "menubar.rectangle", action: onClose)
            }
        }
        .padding(14)
        .frame(width: StatusBarPopoverMetrics.width, height: StatusBarPopoverMetrics.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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

    @ViewBuilder
    private func summarySection(
        _ section: StatusSummarySectionID,
        snapshot: TokenDisplaySnapshot,
        live: LiveRateSnapshot,
        metricValues: StatusBarMetricValues,
        radarPresentation: CodexRadarPresentationState,
        radarPalette: FloatingPanelReadableTextPalette
    ) -> some View {
        switch section {
        case .overview:
            let rateText = metricValues.rate.map { String(format: "%.1f", $0) } ?? "—"
            StatusSummaryCard(section: section) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(rateText)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tok/s")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(snapshot.compactUsageStatus)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.accentBlue)
                            .lineLimit(1)
                        Text("更新 \(DateFormatter.statusString(from: snapshot.updatedAt))")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                StatusBarRateTrack(rate: metricValues.rate)
            }
        case .usage:
            let usage = StatusBarUsageMetricsPresentation(snapshot: snapshot)
            StatusSummaryCard(section: section) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 2),
                    spacing: 7
                ) {
                    StatusBarMetricTile(
                        title: "累计 Token",
                        value: snapshot.hasPreciseTokenUsage ? usage.totalTokens : "—"
                    )
                    StatusBarMetricTile(
                        title: "今日 Token",
                        value: snapshot.hasPreciseTokenUsage ? usage.todayTokens : "—"
                    )
                    StatusBarMetricTile(
                        title: "今日请求",
                        value: snapshot.hasPreciseTokenUsage ? usage.todayRequests : "—"
                    )
                    StatusBarMetricTile(
                        title: "模型生成",
                        value: metricValues.rate == nil ? "—" : "\(live.breakdown.modelGenerated)"
                    )
                }
            }
        case .quota:
            StatusSummaryCard(section: section) {
                VStack(alignment: .leading, spacing: 7) {
                    StatusBarQuotaLine(title: "5h", window: snapshot.quota.fiveHour)
                    StatusBarQuotaLine(title: "7d", window: snapshot.quota.sevenDay)
                }
            }
        case .running:
            let running = RunningThreadPresentation(summary: snapshot.runningThreads)
            StatusSummaryCard(section: section) {
                Text(
                    running.hasCounts
                        ? running.displayText
                        : "运行 — · 主 — · 子 —"
                )
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(running.hasCounts ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(running.accessibilityText)
            }
        case .unread:
            let unreadCount = metricValues.unreadThreadCount
            StatusSummaryCard(section: section) {
                HStack(spacing: 8) {
                    Text(unreadCount.map(String.init) ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("个未读")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        taskCompletionMonitor.markAllRead()
                    } label: {
                        Label("全部已读", systemImage: "checkmark.circle")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(unreadCount == nil || unreadCount == 0)
                }
            }
        case .radar:
            StatusSummaryCard(section: section) {
                if radarPresentation.snapshot == nil {
                    Text("—")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TokenDisplayRadarStrip(presentation: radarPresentation)
                        .environment(\.tokenDisplayScale, 1)
                        .environment(\.tokenDisplayTextPalette, radarPalette)
                        .environment(\.tokenDisplayRadarActionTextPalette, radarPalette)
                        .environment(\.tokenDisplayRadarModelTextPalette, radarPalette)
                        .frame(height: 30)
                }
            }
        case .crowdRadar:
            StatusSummaryCard(section: section) {
                if let crowd = radarPresentation.crowdSnapshot, !crowd.rankedModels.isEmpty {
                    TokenDisplayCrowdRadarRow(presentation: radarPresentation)
                        .environment(\.tokenDisplayScale, 1)
                        .environment(\.tokenDisplayTextPalette, radarPalette)
                        .frame(height: 24)
                } else {
                    Text("—")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct StatusSummaryCard<Content: View>: View {
    let section: StatusSummarySectionID
    @ViewBuilder let content: Content

    init(
        section: StatusSummarySectionID,
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(section.title, systemImage: section.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct StatusBarActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StatusBarRateTrack: View {
    let rate: Double?
    @AppStorage(TokenRateScaleSettings.key) private var tokenRateFullScale = TokenRateScaleSettings.defaultValue

    private var fillFraction: CGFloat {
        guard let rate else { return 0 }
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
                    .frame(width: rate == nil ? 0 : max(5, proxy.size.width * fillFraction))
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("实时速率进度")
        .accessibilityValue(
            rate == nil ? "暂不可用" : "\(Int((fillFraction * 100).rounded()))%"
        )
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

    @AppStorage(FloatingPanelAppearance.startHexKey) private var floatingPanelGradientStartHex = FloatingPanelAppearance.defaultStartHex
    @AppStorage(FloatingPanelAppearance.endHexKey) private var floatingPanelGradientEndHex = FloatingPanelAppearance.defaultEndHex
    @AppStorage(FloatingPanelAppearance.directionKey) private var floatingPanelGradientDirection = FloatingPanelAppearance.defaultDirection
    @AppStorage(FloatingPanelAppearance.styleKey) private var floatingPanelGradientStyle = FloatingPanelAppearance.defaultStyle
    @AppStorage(FloatingQuotaColorStyle.modeKey) private var floatingQuotaColorMode = FloatingQuotaColorStyle.defaultMode
    @AppStorage(FloatingQuotaColorStyle.fixedHexKey) private var floatingQuotaFixedHex = FloatingQuotaColorStyle.defaultFixedHex

    // 紧凑状态面共用用户配色模式（随均速/固定色/面板渐变），与悬浮窗
    // TokenQuotaMiniSegment 同一取值路径；绝对剩余量配色只保留在主界面。
    private var quotaColorStyle: FloatingQuotaColorStyle {
        FloatingQuotaColorStyle(
            modeRaw: floatingQuotaColorMode,
            fixedHex: floatingQuotaFixedHex,
            gradientAppearance: FloatingPanelAppearance(
                startHex: floatingPanelGradientStartHex,
                endHex: floatingPanelGradientEndHex,
                directionRaw: floatingPanelGradientDirection,
                styleRaw: floatingPanelGradientStyle
            )
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .frame(width: 20, alignment: .leading)
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let percent = Double(window?.remainingPercent ?? 0)
                let width = window == nil
                    ? 0
                    : max(4, proxy.size.width * CGFloat(percent / 100.0))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(
                            quotaColorStyle.fillStyle(
                                remainingPercent: percent,
                                expectedRemainingPercent: window?.expectedRemainingPercentByEvenPace.map(Double.init)
                            )
                        )
                        .frame(width: width)
                }
            }
            .frame(height: 10)

            Text(window.map { "剩 \($0.remainingPercent)% · \($0.compactResetText)" } ?? "—")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 额度")
        .accessibilityValue(window.map { "剩余 \($0.remainingPercent)%，已用 \($0.usedPercent)%，\($0.accessibleResetText) 重置" } ?? "暂不可用")
    }
}
