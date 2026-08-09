import AppKit
import SwiftUI

enum TokenDisplayLockState {
    case unlocked
    case locked

    var systemImage: String {
        switch self {
        case .unlocked:
            return "lock.open"
        case .locked:
            return "lock.fill"
        }
    }

    var helpText: String {
        switch self {
        case .unlocked:
            return "锁定悬浮窗到当前窗口位置"
        case .locked:
            return "解除悬浮窗锁定"
        }
    }
}

private struct TokenDisplayScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct TokenDisplayTextPaletteKey: EnvironmentKey {
    static let defaultValue = FloatingPanelReadableTextPalette(backgroundLuminance: 0.88)
}

private struct TokenDisplayRowTextPalettesKey: EnvironmentKey {
    static let defaultValue: [FloatingPanelContentGroup: FloatingPanelReadableTextPalette] = [:]
}

private struct TokenDisplayRadarActionTextPaletteKey: EnvironmentKey {
    static let defaultValue: FloatingPanelReadableTextPalette? = nil
}

private struct TokenDisplayRadarModelTextPaletteKey: EnvironmentKey {
    static let defaultValue: FloatingPanelReadableTextPalette? = nil
}

private struct TokenDisplayMetricTextPalettesKey: EnvironmentKey {
    static let defaultValue: [FloatingPanelMetricTextRegion: FloatingPanelReadableTextPalette] = [:]
}

private struct TokenDisplayEmbeddedUsageStatusTextPaletteKey: EnvironmentKey {
    static let defaultValue: FloatingPanelReadableTextPalette? = nil
}

private struct TokenDisplayStandaloneUsageStatusTextPaletteKey: EnvironmentKey {
    static let defaultValue: FloatingPanelReadableTextPalette? = nil
}

private struct TokenDisplayQuotaColorStyleKey: EnvironmentKey {
    static let defaultValue = FloatingQuotaColorStyle.default
}

extension EnvironmentValues {
    var tokenDisplayScale: CGFloat {
        get { self[TokenDisplayScaleKey.self] }
        set { self[TokenDisplayScaleKey.self] = newValue }
    }

    var tokenDisplayTextPalette: FloatingPanelReadableTextPalette {
        get { self[TokenDisplayTextPaletteKey.self] }
        set { self[TokenDisplayTextPaletteKey.self] = newValue }
    }

    var tokenDisplayRowTextPalettes: [FloatingPanelContentGroup: FloatingPanelReadableTextPalette] {
        get { self[TokenDisplayRowTextPalettesKey.self] }
        set { self[TokenDisplayRowTextPalettesKey.self] = newValue }
    }

    var tokenDisplayRadarActionTextPalette: FloatingPanelReadableTextPalette? {
        get { self[TokenDisplayRadarActionTextPaletteKey.self] }
        set { self[TokenDisplayRadarActionTextPaletteKey.self] = newValue }
    }

    var tokenDisplayRadarModelTextPalette: FloatingPanelReadableTextPalette? {
        get { self[TokenDisplayRadarModelTextPaletteKey.self] }
        set { self[TokenDisplayRadarModelTextPaletteKey.self] = newValue }
    }

    var tokenDisplayMetricTextPalettes: [FloatingPanelMetricTextRegion: FloatingPanelReadableTextPalette] {
        get { self[TokenDisplayMetricTextPalettesKey.self] }
        set { self[TokenDisplayMetricTextPalettesKey.self] = newValue }
    }

    var tokenDisplayEmbeddedUsageStatusTextPalette: FloatingPanelReadableTextPalette? {
        get { self[TokenDisplayEmbeddedUsageStatusTextPaletteKey.self] }
        set { self[TokenDisplayEmbeddedUsageStatusTextPaletteKey.self] = newValue }
    }

    var tokenDisplayStandaloneUsageStatusTextPalette: FloatingPanelReadableTextPalette? {
        get { self[TokenDisplayStandaloneUsageStatusTextPaletteKey.self] }
        set { self[TokenDisplayStandaloneUsageStatusTextPaletteKey.self] = newValue }
    }

    var tokenDisplayQuotaColorStyle: FloatingQuotaColorStyle {
        get { self[TokenDisplayQuotaColorStyleKey.self] }
        set { self[TokenDisplayQuotaColorStyleKey.self] = newValue }
    }
}

extension CGFloat {
    func scaled(by scale: CGFloat) -> CGFloat {
        self * Swift.max(scale, 0.1)
    }
}

extension BinaryInteger {
    func scaled(by scale: CGFloat) -> CGFloat {
        CGFloat(self) * Swift.max(scale, 0.1)
    }
}

enum TokenDisplayMode: String, CaseIterable, Identifiable {
    case off
    case floating
    case statusBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "关闭"
        case .floating:
            return "悬浮窗"
        case .statusBar:
            return "状态栏"
        }
    }

    var controlLabel: String {
        label
    }

    var systemImage: String {
        switch self {
        case .off:
            return "slash.circle"
        case .floating:
            return "rectangle.on.rectangle"
        case .statusBar:
            return "menubar.rectangle"
        }
    }
}

struct TokenDisplaySnapshot {
    let title: String
    let status: String
    let rate: Double
    let consumedTokens: Int
    let todayTokens: Int
    let todayRequests: Int
    let todayModelBreakdowns: [ModelTokenBreakdown]
    let usagePrecision: DashboardUsagePrecision
    let usageReadStatus: String
    let quota: AccountQuotaSnapshot
    let runningThreads: RunningThreadSummary
    let updatedAt: Date

    init(
        title: String,
        status: String,
        rate: Double,
        consumedTokens: Int,
        todayTokens: Int,
        todayRequests: Int,
        todayModelBreakdowns: [ModelTokenBreakdown] = [],
        usagePrecision: DashboardUsagePrecision = .precise,
        usageReadStatus: String = "",
        quota: AccountQuotaSnapshot,
        runningThreads: RunningThreadSummary = .unavailable,
        updatedAt: Date
    ) {
        self.title = title
        self.status = status
        self.rate = rate
        self.consumedTokens = consumedTokens
        self.todayTokens = todayTokens
        self.todayRequests = todayRequests
        self.todayModelBreakdowns = todayModelBreakdowns
        self.usagePrecision = usagePrecision
        self.usageReadStatus = usageReadStatus
        self.quota = quota
        self.runningThreads = runningThreads
        self.updatedAt = updatedAt
    }

    @MainActor
    static func make(
        store: CodexUsageStore,
        monitor: LiveRateMonitor,
        quota: AccountQuotaStore,
        runningThreads: RunningThreadSummary = .unavailable
    ) -> TokenDisplaySnapshot {
        let calendar = Calendar.current
        let today = Date()
        let todayUsage = store.snapshot.dailyUsage.first { calendar.isDate($0.date, inSameDayAs: today) }

        return TokenDisplaySnapshot(
            title: "全会话实时",
            status: monitor.totalSnapshot.status,
            rate: monitor.totalSnapshot.rollingTokensPerSecond,
            consumedTokens: store.snapshot.stats.totalTokens,
            todayTokens: todayUsage?.tokens ?? 0,
            todayRequests: todayUsage?.calls ?? 0,
            todayModelBreakdowns: store.todayModelBreakdowns,
            usagePrecision: store.snapshot.usagePrecision,
            usageReadStatus: store.status,
            quota: quota.snapshot,
            runningThreads: runningThreads,
            updatedAt: max(
                store.snapshot.generatedAt,
                max(
                    monitor.totalSnapshot.updatedAt,
                    max(
                        quota.snapshot.updatedAt ?? .distantPast,
                        runningThreads.updatedAt ?? .distantPast
                    )
                )
            )
        )
    }

    var hasPreciseTokenUsage: Bool {
        usagePrecision.hasPreciseTokenUsage
    }

    var consumedTokensText: String {
        hasPreciseTokenUsage ? consumedTokens.abbreviatedTokens : "待读取"
    }

    var todayTokensText: String {
        hasPreciseTokenUsage ? todayTokens.abbreviatedTokens : "待读取"
    }

    var todayRequestsText: String {
        hasPreciseTokenUsage ? "\(todayRequests)" : "待读取"
    }

    var metadataOnlyStatusText: String? {
        usageReadDiagnostic ?? (hasPreciseTokenUsage ? nil : "仅会话元数据")
    }

    var statusBarTitle: String {
        let safeRate = rate.isFinite ? max(0, rate) : 0
        return String(format: "%.1f/s", safeRate)
    }

    var compactUsageStatus: String {
        usageStatus(resetCreditSuffix: quota.compactResetCreditRateBarSuffix)
    }

    var standaloneUsageStatus: String {
        usageStatus(resetCreditSuffix: quota.compactResetCreditStandaloneSuffix)
    }

    private func usageStatus(resetCreditSuffix: String) -> String {
        if let usageReadDiagnostic {
            return usageReadDiagnostic
        }
        guard quota.isAvailable else {
            if quota.status.contains("失败") {
                return "读取失败"
            }
            return "读取中"
        }

        if let pace = quota.sevenDayPaceStatus {
            return "\(pace.compactTitle)(\(pace.compactDetail))\(resetCreditSuffix)"
        }

        if let sevenDay = quota.sevenDay {
            return "7d剩\(sevenDay.remainingPercent)%\(resetCreditSuffix)"
        }
        if let fiveHour = quota.fiveHour {
            return "5h剩\(fiveHour.remainingPercent)%\(resetCreditSuffix)"
        }
        return "额度已读\(resetCreditSuffix)"
    }

    private var usageReadDiagnostic: String? {
        if usageReadStatus.contains("当前显示已陈旧") || usageReadStatus.contains("用量已陈旧") {
            return "用量已陈旧"
        }
        if usageReadStatus.hasPrefix("读取失败") {
            return "用量读取失败"
        }
        return nil
    }
}

struct TokenDisplayCard: View {
    let snapshot: TokenDisplaySnapshot
    let radarSnapshot: CodexRadarSnapshot?
    var radarPresentation: CodexRadarPresentationState? = nil
    let visibility: FloatingPanelContentVisibility
    let onClose: (() -> Void)?
    var lockState: TokenDisplayLockState? = nil
    var lockTargetDescription: String? = nil
    var onToggleLock: (() -> Void)? = nil
    var selectedPreviewRowID: String? = nil
    var onPreviewRowSelect: ((String) -> Void)? = nil
    @AppStorage(SharedAccountUsageAttributionSettings.priceModelKey)
    private var fallbackPriceModelRaw = OfficialAPIPriceModel.gpt56Sol.rawValue
    @State private var selectedPageIndexByRowID: [String: Int] = [:]
    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette
    @Environment(\.tokenDisplayRowTextPalettes) private var rowTextPalettes
    @Environment(\.tokenDisplayMetricTextPalettes) private var metricTextPalettes
    @Environment(\.tokenDisplayEmbeddedUsageStatusTextPalette) private var embeddedUsageStatusTextPalette
    @Environment(\.tokenDisplayStandaloneUsageStatusTextPalette) private var standaloneUsageStatusTextPalette

    var body: some View {
        GeometryReader { proxy in
            let radarPresentation = resolvedRadarPresentation
            let presentation = FloatingPanelPresentationModel(
                snapshot: snapshot,
                visibility: visibility,
                radarPresentation: radarPresentation,
                fallbackPriceModel: fallbackPriceModel
            )
            let rateRowHeight = FloatingTokenPanelMetrics.rateRowHeight.scaled(by: displayScale)
            let usageStatusRowHeight = FloatingTokenPanelMetrics.usageStatusRowHeight.scaled(by: displayScale)
            let metricRowHeight = FloatingTokenPanelMetrics.metricRowHeight.scaled(by: displayScale)
            let runningThreadsRowHeight = FloatingTokenPanelMetrics.runningThreadsRowHeight.scaled(by: displayScale)
            let todayModelRowHeight = FloatingTokenPanelMetrics.todayModelRowHeight.scaled(by: displayScale)
            let quotaRowHeight = FloatingTokenPanelMetrics.quotaRowHeight.scaled(by: displayScale)
            let radarRowHeight = FloatingTokenPanelMetrics.radarRowHeight.scaled(by: displayScale)
            let crowdRadarRowHeight = FloatingTokenPanelMetrics.crowdRadarRowHeight.scaled(by: displayScale)
            let topSafetyInset = presentation.needsTopSafetyInset ? FloatingTokenPanelMetrics.singleElementTopInset.scaled(by: displayScale) : 0

            VStack(alignment: .center, spacing: 0) {
                ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                    let topSpacing = index > 0
                        ? FloatingTokenPanelMetrics.spacing(
                            between: presentation.rows[index - 1].group,
                            and: row.group
                        ).scaled(by: displayScale)
                        : 0
                    pagedContentRow(
                        row,
                        presentation: presentation,
                        radarPresentation: radarPresentation,
                        rateRowHeight: rateRowHeight,
                        usageStatusRowHeight: usageStatusRowHeight,
                        metricRowHeight: metricRowHeight,
                        runningThreadsRowHeight: runningThreadsRowHeight,
                        todayModelRowHeight: todayModelRowHeight,
                        quotaRowHeight: quotaRowHeight,
                        radarRowHeight: radarRowHeight,
                        crowdRadarRowHeight: crowdRadarRowHeight
                    )
                    .padding(.top, topSpacing)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onPreviewRowSelect?(row.id)
                    }
                    .overlay {
                        if selectedPreviewRowID == row.id {
                            RoundedRectangle(cornerRadius: 4.scaled(by: displayScale), style: .continuous)
                                .stroke(palette(for: row.group).primaryColor.opacity(0.34), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: max(0, proxy.size.height - topSafetyInset), alignment: .center)
            .padding(.top, topSafetyInset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .topLeading) {
                cardLockButton
            }
            .overlay(alignment: .topTrailing) {
                cardCloseButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex Token Bar 悬浮窗")
        .accessibilityValue(FloatingPanelPresentationModel(
            snapshot: snapshot,
            visibility: visibility,
            radarPresentation: resolvedRadarPresentation,
            fallbackPriceModel: fallbackPriceModel
        ).accessibilityValue)
    }

    private var fallbackPriceModel: OfficialAPIPriceModel {
        OfficialAPIPriceModel.storedValue(for: fallbackPriceModelRaw)
    }

    private var resolvedRadarPresentation: CodexRadarPresentationState {
        radarPresentation ?? CodexRadarPresentationState(snapshot: radarSnapshot)
    }

    private func palette(for group: FloatingPanelContentGroup) -> FloatingPanelReadableTextPalette {
        rowTextPalettes[group] ?? textPalette
    }

    private func metricPalette(for region: FloatingPanelMetricTextRegion) -> FloatingPanelReadableTextPalette {
        metricTextPalettes[region] ?? palette(for: .metrics)
    }

    @ViewBuilder
    private func pagedContentRow(
        _ row: FloatingPanelPresentationRow,
        presentation: FloatingPanelPresentationModel,
        radarPresentation: CodexRadarPresentationState,
        rateRowHeight: CGFloat,
        usageStatusRowHeight: CGFloat,
        metricRowHeight: CGFloat,
        runningThreadsRowHeight: CGFloat,
        todayModelRowHeight: CGFloat,
        quotaRowHeight: CGFloat,
        radarRowHeight: CGFloat,
        crowdRadarRowHeight: CGFloat
    ) -> some View {
        let selectedGroup = selectedGroup(in: row)
        let rowHeight = row.groups.map { group -> CGFloat in
            switch group {
            case .rateAndBar: rateRowHeight
            case .usageStatus: usageStatusRowHeight
            case .metrics: metricRowHeight
            case .runningThreads: runningThreadsRowHeight
            case .todayModelShare, .todayModelCost: todayModelRowHeight
            case .quota: quotaRowHeight
            case .radar: radarRowHeight
            case .crowdRadar: crowdRadarRowHeight
            }
        }.max() ?? metricRowHeight

        ZStack {
            content(
                for: selectedGroup,
                presentation: presentation,
                radarPresentation: radarPresentation
            )
            .environment(\.tokenDisplayTextPalette, palette(for: selectedGroup))

            if row.isPaged {
                HStack {
                    pageButton(systemImage: "chevron.left", row: row, delta: -1)
                    Spacer(minLength: 0)
                    pageButton(systemImage: "chevron.right", row: row, delta: 1)
                }
                .padding(.horizontal, -9.scaled(by: displayScale))
            }
        }
        .frame(height: rowHeight, alignment: .center)
        .animation(.easeOut(duration: 0.16), value: selectedGroup)
    }

    @ViewBuilder
    private func content(
        for group: FloatingPanelContentGroup,
        presentation: FloatingPanelPresentationModel,
        radarPresentation: CodexRadarPresentationState
    ) -> some View {
        switch group {
        case .rateAndBar:
            rateRow(usageStatus: presentation.rateBarUsageStatus)
        case .usageStatus:
            TokenDisplayUsageStatusLine(
                text: presentation.standaloneUsageStatus ?? snapshot.standaloneUsageStatus
            )
            .environment(
                \.tokenDisplayTextPalette,
                standaloneUsageStatusTextPalette ?? palette(for: .usageStatus)
            )
        case .metrics:
            metricRow
        case .runningThreads:
            TokenDisplayRunningThreadsRow(summary: snapshot.runningThreads)
        case .todayModelShare:
            FloatingTodayModelUsageRow(
                page: .share,
                rows: snapshot.todayModelBreakdowns,
                fallbackModel: fallbackPriceModel,
                showPlaceholders: snapshot.hasPreciseTokenUsage
            )
        case .todayModelCost:
            FloatingTodayModelUsageRow(
                page: .cost,
                rows: snapshot.todayModelBreakdowns,
                fallbackModel: fallbackPriceModel,
                showPlaceholders: snapshot.hasPreciseTokenUsage
            )
        case .quota:
            TokenQuotaMiniStrip(snapshot: snapshot.quota)
        case .radar:
            TokenDisplayRadarStrip(presentation: radarPresentation)
        case .crowdRadar:
            TokenDisplayCrowdRadarRow(presentation: radarPresentation)
        }
    }

    private func selectedGroup(in row: FloatingPanelPresentationRow) -> FloatingPanelContentGroup {
        let index = selectedPageIndexByRowID[row.id, default: 0]
        return row.groups[index % row.groups.count]
    }

    private func pageButton(
        systemImage: String,
        row: FloatingPanelPresentationRow,
        delta: Int
    ) -> some View {
        Button {
            let current = selectedPageIndexByRowID[row.id, default: 0]
            selectedPageIndexByRowID[row.id] = (current + delta + row.groups.count) % row.groups.count
        } label: {
            ZStack {
                // Keep the glyph visually narrow while giving the button a
                // forgiving edge hit target. This overlay does not take part
                // in row layout, so it cannot squeeze model text.
                Image(systemName: systemImage)
                    .font(.system(size: 6.8.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(palette(for: selectedGroup(in: row)).secondaryColor.opacity(0.45))
                    .scaleEffect(x: 0.58, y: 0.92, anchor: .center)
                    // Keep the enlarged hit target centered on the edge gutter,
                    // but push the visible glyph back to the outer-edge position
                    // used before the hit-area expansion.
                    .offset(x: (delta < 0 ? -7 : 7).scaled(by: displayScale))
                    .frame(
                        width: 14.scaled(by: displayScale),
                        height: 20.scaled(by: displayScale)
                    )
            }
            .frame(
                width: 28.scaled(by: displayScale),
                height: 24.scaled(by: displayScale)
            )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(delta < 0 ? "上一项" : "下一项")
        .accessibilityLabel(delta < 0 ? "显示上一项" : "显示下一项")
    }

    private func rateRow(usageStatus: String?) -> some View {
        HStack(alignment: .center, spacing: 8.scaled(by: displayScale)) {
            HStack(alignment: .lastTextBaseline, spacing: 4.scaled(by: displayScale)) {
                Text(String(format: "%.1f", snapshot.rate))
                    .font(.system(size: 20.scaled(by: displayScale), weight: .semibold, design: .rounded))
                    .foregroundStyle(textPalette.primaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 64.scaled(by: displayScale), alignment: .leading)
                    .offset(x: 3.scaled(by: displayScale))
                Text("tok/s")
                    .font(.system(size: 8.6.scaled(by: displayScale), weight: .semibold))
                    .foregroundStyle(textPalette.secondaryColor)
            }
            .frame(height: FloatingTokenPanelMetrics.rateRowHeight.scaled(by: displayScale), alignment: .center)

            TokenDisplayRateBar(
                rate: snapshot.rate,
                usageStatus: usageStatus
            )
            .environment(\.tokenDisplayEmbeddedUsageStatusTextPalette, embeddedUsageStatusTextPalette)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var cardLockButton: some View {
        if let lockState, let onToggleLock {
            Button(action: onToggleLock) {
                Image(systemName: lockState.systemImage)
                    .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(textPalette.primaryColor)
                    .frame(width: 26.scaled(by: displayScale), height: 22.scaled(by: displayScale), alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(cardLockHelpText)
            .padding(.leading, 1.scaled(by: displayScale))
            .padding(.top, 1.scaled(by: displayScale))
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var cardCloseButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.8.scaled(by: displayScale), weight: .bold))
                    .foregroundStyle(textPalette.secondaryColor)
                    .frame(width: 22.scaled(by: displayScale), height: 20.scaled(by: displayScale), alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 1.scaled(by: displayScale))
            .padding(.top, 1.scaled(by: displayScale))
            .zIndex(10)
        }
    }

    private var cardLockHelpText: String {
        guard lockState == .locked else {
            return TokenDisplayLockState.unlocked.helpText
        }
        if let lockTargetDescription, !lockTargetDescription.isEmpty {
            return "已锁定到 \(lockTargetDescription)"
        }
        return TokenDisplayLockState.locked.helpText
    }

    private var metricRow: some View {
        Group {
            if visibility.embedsRunningThreadsInMetricsRow {
                HStack(spacing: 5.scaled(by: displayScale)) {
                    HStack(spacing: 8.scaled(by: displayScale)) {
                        TokenDisplayMetric(label: "总", value: snapshot.consumedTokensText, expands: false)
                            .environment(\.tokenDisplayTextPalette, metricPalette(for: .total))
                        TokenDisplayMetric(label: "今", value: snapshot.todayTokensText, expands: false)
                            .environment(\.tokenDisplayTextPalette, metricPalette(for: .today))
                        TokenDisplayMetric(label: "次", value: snapshot.todayRequestsText, expands: false)
                            .environment(\.tokenDisplayTextPalette, metricPalette(for: .requests))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .minimumScaleFactor(0.72)

                    Rectangle()
                        .fill(palette(for: .runningThreads).dividerColor)
                        .frame(width: 1, height: 9.scaled(by: displayScale))

                    TokenDisplayRunningThreadsRow(
                        summary: snapshot.runningThreads,
                        showsTotal: false
                    )
                    .environment(\.tokenDisplayTextPalette, palette(for: .runningThreads))
                    .frame(width: 62.scaled(by: displayScale))
                }
            } else {
                HStack(spacing: 6.scaled(by: displayScale)) {
                    TokenDisplayMetric(label: "总", value: snapshot.consumedTokensText)
                        .environment(\.tokenDisplayTextPalette, metricPalette(for: .total))
                        .offset(
                            x: FloatingTokenPanelMetrics.metricTotalOffset(
                                hasPreciseTokenUsage: snapshot.hasPreciseTokenUsage
                            ).scaled(by: displayScale)
                        )
                    TokenDisplayMetric(label: "今", value: snapshot.todayTokensText)
                        .environment(\.tokenDisplayTextPalette, metricPalette(for: .today))
                        .offset(
                            x: FloatingTokenPanelMetrics.metricTodayOffset(
                                hasPreciseTokenUsage: snapshot.hasPreciseTokenUsage
                            ).scaled(by: displayScale)
                        )
                    TokenDisplayMetric(label: "次", value: snapshot.todayRequestsText)
                        .environment(\.tokenDisplayTextPalette, metricPalette(for: .requests))
                        .offset(
                            x: FloatingTokenPanelMetrics.metricRequestsOffset(
                                requestCount: snapshot.todayRequests,
                                hasPreciseTokenUsage: snapshot.hasPreciseTokenUsage
                            ).scaled(by: displayScale)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
