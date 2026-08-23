import AppKit
import SwiftUI

struct RecentChartAccessibilityButtonPresentation: Equatable {
    let label: String
    let value: String?
    let isEnabled: Bool
}

struct RecentChartAccessibilityButtonRepresentation: NSViewRepresentable {
    let presentation: RecentChartAccessibilityButtonPresentation
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = Self.makeButton(presentation: presentation)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        Self.configure(button, presentation: presentation)
    }

    @MainActor
    static func makeButton(presentation: RecentChartAccessibilityButtonPresentation) -> NSButton {
        let button = NSButton(title: presentation.label, target: nil, action: nil)
        configure(button, presentation: presentation)
        return button
    }

    @MainActor
    private static func configure(
        _ button: NSButton,
        presentation: RecentChartAccessibilityButtonPresentation
    ) {
        button.title = presentation.label
        button.isEnabled = presentation.isEnabled
        button.setAccessibilityLabel(presentation.label)
        button.setAccessibilityValue(presentation.value)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

struct RecentChartRangeOptionPresentation: Equatable {
    let visibleTitle: String
    let accessibilityLabel: String
    let accessibilityValue: String

    init(range: RecentChartRange, isSelected: Bool) {
        visibleTitle = range.label
        accessibilityLabel = "曲线范围 \(range.title)"
        accessibilityValue = isSelected ? "已选择" : "未选择"
    }

    var accessibilityButton: RecentChartAccessibilityButtonPresentation {
        RecentChartAccessibilityButtonPresentation(
            label: accessibilityLabel,
            value: accessibilityValue,
            isEnabled: true
        )
    }
}

struct RecentChartRangeSelector: View {
    @Binding var selection: RecentChartRange

    var body: some View {
        HStack(spacing: 3) {
            ForEach(RecentChartRange.allCases) { range in
                let presentation = RecentChartRangeOptionPresentation(
                    range: range,
                    isSelected: selection == range
                )
                Button {
                    selection = range
                } label: {
                    Label {
                        Text(presentation.accessibilityLabel)
                    } icon: {
                        Text(presentation.visibleTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selection == range ? AppTheme.accentBlue : .secondary)
                            .frame(width: 34, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selection == range ? AppTheme.accentBlue.opacity(0.12) : Color.clear)
                            )
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityRepresentation {
                    RecentChartAccessibilityButtonRepresentation(
                        presentation: presentation.accessibilityButton,
                        action: { selection = range }
                    )
                }
            }
        }
        .padding(3)
        .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct ChartLegend: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(label == "命中率" ? .primary : .secondary)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) 图例")
        .accessibilityValue(value)
    }
}

struct ChartLineToggle: View {
    let title: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? color : .secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? color.opacity(0.10) : AppTheme.raisedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isOn ? color.opacity(0.28) : AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("显示 \(title) 曲线")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint("切换这条曲线是否显示")
    }
}

struct RecentChartSelectionInvalidationBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(AppTheme.accentAmber)
            .padding(.horizontal, 12)
            .frame(width: 460, alignment: .leading)
            .frame(minHeight: 36, alignment: .leading)
            .background(
                AppTheme.accentAmber.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.accentAmber.opacity(0.30), lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("图表选区已失效")
            .accessibilityValue(message)
    }
}

struct RecentChartQuotaEstimateOverlay: View {
    let selection: QuotaConsumptionSelection
    let attribution: QuotaSelectionAttributionResult?
    let isSelectionFixed: Bool
    let showsFiveHourQuota: Bool
    let showsSevenDayQuota: Bool
    let currentFiveHourQuotaPresent: Bool
    let currentSevenDayQuotaPresent: Bool
    let attributionEventsComplete: Bool
    let onClose: () -> Void
    @State private var detailSnapshot: QuotaConsumptionSelectionDetailSnapshot?

    init(
        selection: QuotaConsumptionSelection,
        attribution: QuotaSelectionAttributionResult?,
        isSelectionFixed: Bool,
        showsFiveHourQuota: Bool,
        showsSevenDayQuota: Bool,
        currentFiveHourQuotaPresent: Bool,
        currentSevenDayQuotaPresent: Bool,
        attributionEventsComplete: Bool = true,
        onClose: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.attribution = attribution
        self.isSelectionFixed = isSelectionFixed
        self.showsFiveHourQuota = showsFiveHourQuota
        self.showsSevenDayQuota = showsSevenDayQuota
        self.currentFiveHourQuotaPresent = currentFiveHourQuotaPresent
        self.currentSevenDayQuotaPresent = currentSevenDayQuotaPresent
        self.attributionEventsComplete = attributionEventsComplete
        self.onClose = onClose
    }

    var body: some View {
        let presentation = QuotaConsumptionEstimatorOverlayPresentation(
            selection: selection,
            showsFiveHourQuota: showsFiveHourQuota,
            showsSevenDayQuota: showsSevenDayQuota,
            currentFiveHourQuotaPresent: currentFiveHourQuotaPresent,
            currentSevenDayQuotaPresent: currentSevenDayQuotaPresent
        )

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(presentation.costTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(presentation.costText)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AppTheme.accentBlue)
                        Text(presentation.durationText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(presentation.timeRangeText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(presentation.cacheHitText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppTheme.accentCyan)
                    }

                    HStack(spacing: 7) {
                        Text(presentation.estimateTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if showsFiveHourQuota {
                            QuotaEstimateChip(presentation: presentation.fiveHourChip, color: .purple)
                        }
                        if showsSevenDayQuota {
                            QuotaEstimateChip(presentation: presentation.sevenDayChip, color: .green)
                        }
                        if let comparisonScopeText = presentation.comparisonScopeText {
                            Text(comparisonScopeText)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if presentation.showsBudgetRatio {
                        HStack(spacing: 6) {
                            Text(presentation.ratioTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(presentation.budgetRatioText)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(presentation.showsRatioWarning ? .orange : .primary)
                            Text(presentation.ratioHelpText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            if let ratioWarningText = presentation.ratioWarningText {
                                Text(ratioWarningText)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                        }

                        if let ratioWarningDetailText = presentation.ratioWarningDetailText {
                            Text(ratioWarningDetailText)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityValue(presentation.accessibilityValue)

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(presentation.closeAccessibilityLabel)
                .accessibilityRepresentation {
                    RecentChartAccessibilityButtonRepresentation(
                        presentation: RecentChartAccessibilityButtonPresentation(
                            label: presentation.closeAccessibilityLabel,
                            value: nil,
                            isEnabled: true
                        ),
                        action: onClose
                    )
                }
            }

            HStack(spacing: 7) {
                if let attribution {
                    QuotaSelectionAttributionSummaryRow(result: attribution)
                } else if !attributionEventsComplete {
                    Text("等待完整模型跟踪")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("共享归因未开启")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if isSelectionFixed {
                    Button(action: showDetails) {
                        Label("查看详情", systemImage: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 9)
                            .frame(minHeight: 28)
                            .background(AppTheme.accentBlue.opacity(0.10), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accentBlue)
                    .contentShape(Rectangle())
                    .help("查看选区额度、token 与共享账号归因明细")
                    .accessibilityLabel("查看选区额度归因详情")
                    .accessibilityHint("打开详情卡片")
                    .accessibilityRepresentation {
                        RecentChartAccessibilityButtonRepresentation(
                            presentation: RecentChartAccessibilityButtonPresentation(
                                label: "查看选区额度归因详情",
                                value: nil,
                                isEnabled: true
                            ),
                            action: showDetails
                        )
                    }
                    .popover(
                        isPresented: Binding(
                            get: { detailSnapshot != nil },
                            set: { isPresented in
                                if !isPresented { detailSnapshot = nil }
                            }
                        ),
                        arrowEdge: .bottom
                    ) {
                        if let detailSnapshot {
                            QuotaConsumptionSelectionDetailView(snapshot: detailSnapshot)
                        }
                    }
                } else {
                    Label("预览中", systemImage: "cursorarrow")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(AppTheme.accentAmber)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 28)
                        .background(AppTheme.accentAmber.opacity(0.09), in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("选区预览中")
                        .accessibilityHint("第二次点击图表固定终点")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 460, alignment: .leading)
        .background(AppTheme.hoverBubble.opacity(0.96), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func showDetails() {
        guard isSelectionFixed else { return }
        detailSnapshot = QuotaConsumptionSelectionDetailSnapshot(
            selection: selection,
            attribution: attribution
        )
    }
}

private struct QuotaSelectionAttributionSummaryRow: View {
    let result: QuotaSelectionAttributionResult

    private var presentation: QuotaSelectionAttributionPresentation {
        QuotaSelectionAttributionPresentation(result: result)
    }

    var body: some View {
        HStack(spacing: 6) {
            compactMetric(presentation.accountTitle, presentation.accountText, color: AppTheme.accentBlue)
            Text("｜").foregroundStyle(.tertiary)
            compactMetric(presentation.localTitle, presentation.localText, color: AppTheme.accentGreen)
            Text("｜").foregroundStyle(.tertiary)
            compactMetric(
                presentation.differenceTitle,
                presentation.differenceText,
                color: result.state == .withinTolerance ? AppTheme.accentGreen : AppTheme.accentAmber
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("选区共享账号归因")
        .accessibilityValue(presentation.accessibilityValue)
    }

    private func compactMetric(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .monospacedDigit()
    }
}

struct QuotaConsumptionSelectionDetailSnapshot: Equatable {
    let selection: QuotaConsumptionSelection
    let attribution: QuotaSelectionAttributionResult?
}

struct QuotaConsumptionSelectionDetailView: View {
    let snapshot: QuotaConsumptionSelectionDetailSnapshot
    @Environment(\.dismiss) private var dismiss

    private var selection: QuotaConsumptionSelection { snapshot.selection }
    private var attributionPresentation: QuotaSelectionAttributionPresentation? {
        snapshot.attribution.map(QuotaSelectionAttributionPresentation.init)
    }
    private var comparisonCoveragePresentation: QuotaConsumptionComparisonCoveragePresentation {
        QuotaConsumptionComparisonCoveragePresentation(
            basis: selection.sevenDay.quotaDropBasis,
            usesConservativeBuckets: selection.sevenDay.comparisonUsesConservativeBuckets
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Rectangle().fill(AppTheme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    metricRow
                    formulaSection
                    tokenSection
                    attributionCoverageSection
                    sourceSection
                    caveatSection
                }
                .padding(18)
            }
        }
        .frame(width: 650, height: 440)
        .background(AppTheme.panelBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("选区额度与共享账号归因详情")
    }

    private var detailHeader: some View {
        HStack(spacing: 11) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 30, height: 30)
                .background(AppTheme.accentBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("选区额度估算详情")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(selection.quotaEstimatorTimeRangeText) · \(selection.quotaEstimatorDurationText)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let attribution = snapshot.attribution {
                Text(attribution.tier.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
                    .padding(.horizontal, 8)
                    .frame(height: 23)
                    .background(AppTheme.accentBlue.opacity(0.10), in: Capsule())
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭选区额度估算详情")
            .accessibilityRepresentation {
                RecentChartAccessibilityButtonRepresentation(
                    presentation: RecentChartAccessibilityButtonPresentation(
                        label: "关闭选区额度估算详情",
                        value: nil,
                        isEnabled: true
                    ),
                    action: { dismiss() }
                )
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private var metricRow: some View {
        HStack(spacing: 9) {
            detailMetric(
                title: attributionPresentation.map { "\($0.accountTitle) · 7d" }
                    ?? sevenDayDropTitle,
                value: attributionPresentation?.accountText
                    ?? (selection.sevenDay.quotaDropBasis != .unavailable
                        ? QuotaSelectionAttributionPresentation.percent(selection.sevenDay.quotaDropPercent)
                        : "--"),
                detail: fiveHourDropDetail,
                color: AppTheme.accentBlue
            )
            detailMetric(
                title: "本机折算",
                value: snapshot.attribution?.localSharePercent
                    .map(QuotaSelectionAttributionPresentation.percent) ?? "--",
                detail: snapshot.attribution?.localComparableCostUSD
                    .map(QuotaSelectionAttributionPresentation.money)
                    ?? "等待 Radar 同口径",
                color: AppTheme.accentGreen
            )
            detailMetric(
                title: attributionPresentation?.differenceTitle ?? "差额",
                value: attributionPresentation?.differenceText ?? "--",
                detail: attributionPresentation?.stateText ?? "共享归因未开启",
                color: snapshot.attribution?.state == .withinTolerance
                    ? AppTheme.accentGreen
                    : AppTheme.accentAmber
            )
        }
    }

    private var formulaSection: some View {
        detailSection(title: "计算", systemImage: "function") {
            VStack(alignment: .leading, spacing: 7) {
                formulaRow("1", attributionPresentation?.localFormula
                    ?? "本机占比 = 本机同基准金额 ÷ Radar 套餐 7 天总额 × 100")
                formulaRow("2", attributionPresentation?.differenceFormula
                    ?? fallbackDifferenceFormula)
            }
        }
    }

    private var tokenSection: some View {
        detailSection(title: "完整选区本机 token", systemImage: "number") {
            HStack(spacing: 0) {
                compactValue("非缓存输入", selection.breakdown.uncachedInputTokens.abbreviatedTokens)
                Divider().frame(height: 30)
                compactValue("缓存输入", selection.breakdown.cachedInputTokens.abbreviatedTokens)
                Divider().frame(height: 30)
                compactValue("输出", selection.breakdown.outputTokens.abbreviatedTokens)
                Divider().frame(height: 30)
                compactValue("请求", "\(selection.breakdown.calls)")
                Divider().frame(height: 30)
                compactValue(
                    "当前 API 等值",
                    selection.fullCurrentAPIPriceEstimate.costUSD.quotaEstimatorMoneyText
                )
            }
        }
    }

    private var attributionCoverageSection: some View {
        let covered = selection.sevenDayAttributionBreakdown
        return detailSection(
            title: comparisonCoveragePresentation.sectionTitle,
            systemImage: "scope"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(comparisonRangeText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    compactValue("非缓存输入", covered.uncachedInputTokens.abbreviatedTokens)
                    Divider().frame(height: 30)
                    compactValue("缓存输入", covered.cachedInputTokens.abbreviatedTokens)
                    Divider().frame(height: 30)
                    compactValue("输出", covered.outputTokens.abbreviatedTokens)
                    Divider().frame(height: 30)
                    compactValue("请求", "\(covered.calls)")
                    Divider().frame(height: 30)
                    compactValue(
                        "当前 API 等值",
                        snapshot.attribution.map {
                            QuotaSelectionAttributionPresentation.money(
                                $0.localCurrentOfficialCostUSD
                            )
                        } ?? selection.sevenDayCurrentAPIPriceEstimate.costUSD.quotaEstimatorMoneyText
                    )
                }
            }
        }
    }

    private var sourceSection: some View {
        detailSection(title: "基准与来源", systemImage: "dot.radiowaves.left.and.right") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 14, alignment: .leading),
                    count: 3
                ),
                alignment: .leading,
                spacing: 10
            ) {
                sourceValue(
                    "Radar 7 天总额",
                    snapshot.attribution?.radarSevenDayTotalUSD
                        .map(QuotaSelectionAttributionPresentation.money) ?? "--"
                )
                sourceValue("定价版本", snapshot.attribution?.priceRevision.title ?? "--")
                sourceValue(
                    "模型计价",
                    snapshot.attribution?.pricingModelText
                        ?? selection.sevenDayCurrentAPIPriceEstimate.pricingModelText(
                            fallbackModel: selection.fallbackPriceModel
                        )
                )
                sourceValue("Radar 基准日", snapshot.attribution?.radarPricingBasisDate ?? "--")
                sourceValue("Radar 来源", snapshot.attribution?.radarSource ?? "--")
                sourceValue("Radar 更新时间", snapshot.attribution?.radarUpdatedAt ?? "--")
                sourceValue(
                    comparisonCoveragePresentation.sourceTitle,
                    comparisonRangeText
                )
            }
        }
    }

    private var fiveHourDropDetail: String {
        guard selection.fiveHour.quotaDropBasis != .unavailable else {
            return "5h 同期下降 --"
        }
        let prefix = selection.fiveHour.quotaDropEstimated ? "暂算 " : ""
        return "5h 同期\(prefix)下降 \(QuotaSelectionAttributionPresentation.percent(selection.fiveHour.quotaDropPercent))"
    }

    private var sevenDayDropTitle: String {
        switch selection.sevenDay.quotaDropBasis {
        case .observed: "账号实降 · 7d"
        case .estimated: "账号暂降 · 7d"
        case .unavailable: "账号下降 · 7d"
        }
    }

    private var fallbackDifferenceFormula: String {
        let accountTerm = switch selection.sevenDay.quotaDropBasis {
        case .observed: "账号选区实降"
        case .estimated: "账号选区暂算下降"
        case .unavailable: "账号选区下降"
        }
        return "差额 = \(accountTerm) − 本机折算占比"
    }

    private var comparisonRangeText: String {
        guard let start = selection.sevenDay.comparisonStartDate,
              let end = selection.sevenDay.comparisonEndDate else { return "--" }
        return "\(DateFormatter.monthDayHourMinute.string(from: start)) – \(DateFormatter.monthDayHourMinute.string(from: end))"
    }

    @ViewBuilder
    private var caveatSection: some View {
        let caveats = snapshot.attribution?.caveats ?? ["共享账号归因未开启；当前只展示本机选区统计与额度下降。"]
        detailSection(
            title: caveats.isEmpty ? "结论口径" : "限制与误差",
            systemImage: caveats.isEmpty ? "checkmark.shield" : "exclamationmark.triangle"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if caveats.isEmpty {
                    Text("选区处于当前安全基线与额度观测覆盖内；正差超过 2 个百分点时才标记为疑似他人使用。")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(caveats, id: \.self) { caveat in
                        Label(caveat, systemImage: "info.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func detailMetric(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func detailSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.raisedBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func formulaRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 18, height: 18)
                .background(AppTheme.accentBlue.opacity(0.10), in: Circle())
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func compactValue(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sourceValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaEstimateChip: View {
    let presentation: QuotaConsumptionEstimatePresentation
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(presentation.title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(presentation.detail)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.detail)
    }
}

extension View {
    func chartBubblePlacement(tokenX: CGFloat, plot: CGRect) -> some View {
        modifier(ChartBubblePlacementModifier(tokenX: tokenX, plot: plot))
    }
}

struct ChartBubblePlacementModifier: ViewModifier {
    let tokenX: CGFloat
    let plot: CGRect

    func body(content: Content) -> some View {
        let plot = self.plot
        let tokenX = self.tokenX
        content
            .fixedSize(horizontal: true, vertical: false)
            // Keep the hit-test region to the actual preview card. The
            // alignment frame below spans the plot so the card can be placed
            // above the selected x-position, but it must not swallow clicks
            // intended for the chart itself.
            .contentShape(Rectangle())
            .alignmentGuide(.leading) { dimensions in
                let lower = plot.minX
                let upper = max(lower, plot.maxX - dimensions.width)
                let centered = tokenX - dimensions.width / 2
                return -min(max(centered, lower), upper)
            }
            .alignmentGuide(.top) { dimensions in
                -(plot.minY - recentChartHoverBubbleVerticalOffset - dimensions.height / 2)
            }
            .frame(width: plot.width, height: plot.height, alignment: .topLeading)
            .allowsHitTesting(true)
    }
}

struct ChartHoverBubble: View {
    let bin: BinUsage
    let cacheBreakdown: TokenCacheBreakdown?
    let modelBreakdowns: [ModelTokenBreakdown]
    let costUSD: Double
    let fiveHourRemaining: Double?
    let sevenDayRemaining: Double?
    let bucketInterval: TimeInterval
    let isHovering: Bool
    let onClose: () -> Void

    init(
        bin: BinUsage,
        cacheBreakdown: TokenCacheBreakdown?,
        modelBreakdowns: [ModelTokenBreakdown] = [],
        costUSD: Double = 0,
        fiveHourRemaining: Double?,
        sevenDayRemaining: Double?,
        bucketInterval: TimeInterval,
        isHovering: Bool,
        onClose: @escaping () -> Void = {}
    ) {
        self.bin = bin
        self.cacheBreakdown = cacheBreakdown
        self.modelBreakdowns = modelBreakdowns
        self.costUSD = costUSD
        self.fiveHourRemaining = fiveHourRemaining
        self.sevenDayRemaining = sevenDayRemaining
        self.bucketInterval = bucketInterval
        self.isHovering = isHovering
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(isHovering ? "当前点" : "最新点")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHovering ? AppTheme.accentBlue : .secondary)
                    Text(timeRange)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isHovering ? "关闭当前点预览" : "关闭最新点预览")
            }
            Text(bin.tokens.abbreviatedTokens)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
            Text("请求 \(bin.calls) 次 · avg \(average.abbreviatedTokens)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("金额 \(costUSD.quotaEstimatorMoneyText)")
                .font(.system(size: 10))
                .foregroundStyle(.pink)
            if let cacheBreakdown, cacheBreakdown.calls > 0 {
                Text("缓存命中 \(cacheBreakdown.cacheHitRate.percentString) · 命中 \(cacheBreakdown.cachedInputTokens.abbreviatedTokens)")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.accentCyan)
            }
            ModelUsageInlineSummary(rows: modelBreakdowns)
            if let quotaSummary {
                Text("额度 \(quotaSummary)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if isHovering {
                Text(RecentChartQuotaEstimateAffordancePresentation.hoverInstruction)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .fixedSize(horizontal: true, vertical: false)
        .background(AppTheme.hoverBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isHovering ? "曲线当前点" : "曲线最新点")
        .accessibilityValue(accessibilitySummary)
    }

    private var average: Int {
        bin.calls > 0 ? bin.tokens / bin.calls : 0
    }

    private var quotaSummary: String? {
        let parts = [
            fiveHourRemaining.map { "5h \(percentText($0))" },
            sevenDayRemaining.map { "7d \(percentText($0))" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var parts = [
            timeRange,
            "\(bin.tokens.abbreviatedTokens) token",
            "\(bin.calls) 次请求",
            "平均 \(average.abbreviatedTokens)",
            "金额 \(costUSD.quotaEstimatorMoneyText)"
        ]
        if let cacheBreakdown, cacheBreakdown.calls > 0 {
            parts.append("缓存命中率 \(cacheBreakdown.cacheHitRate.percentString)")
            parts.append("命中 \(cacheBreakdown.cachedInputTokens.abbreviatedTokens)")
        }
        if let models = ModelUsagePresentation.compactText(from: modelBreakdowns) {
            parts.append("模型占比 \(models)")
        }
        if let fiveHourRemaining { parts.append("5 小时额度 \(percentText(fiveHourRemaining))") }
        if let sevenDayRemaining { parts.append("7 天额度 \(percentText(sevenDayRemaining))") }
        if isHovering {
            parts.append(RecentChartQuotaEstimateAffordancePresentation.hoverAccessibilityPrompt)
        }
        return parts.joined(separator: "；")
    }

    private var timeRange: String {
        let end = bin.start.addingTimeInterval(bucketInterval)
        if bucketInterval <= 60 * 60,
           Calendar.current.isDate(bin.start, inSameDayAs: end) {
            return "\(DateFormatter.hourMinute.string(from: bin.start)) - \(DateFormatter.hourMinute.string(from: end))"
        }
        return "\(DateFormatter.monthDayHourMinute.string(from: bin.start)) - \(DateFormatter.monthDayHourMinute.string(from: end))"
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }
}

struct ChartSelectionSummaryBubble: View {
    let selection: QuotaConsumptionSelection
    let onClose: () -> Void

    init(
        selection: QuotaConsumptionSelection,
        onClose: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("选中区间")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.accentBlue)
                    Text(timeRange)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭选中区间预览")
            }
            Text(selection.breakdown.totalTokens.abbreviatedTokens)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accentBlue)
            Text("请求 \(selection.breakdown.calls) 次 · avg \(average.abbreviatedTokens)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("金额 \(selection.fullCurrentAPIPriceEstimate.costUSD.quotaEstimatorMoneyText)")
                .font(.system(size: 10))
                .foregroundStyle(.pink)
            if selection.breakdown.calls > 0 {
                Text("缓存命中 \(selection.breakdown.cacheHitRate.percentString) · 命中 \(selection.breakdown.cachedInputTokens.abbreviatedTokens)")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.accentCyan)
            }
            ModelUsageInlineSummary(
                rows: ModelUsagePresentation.rows(from: selection.fullAttributionEvents)
            )
            Text("持续 \(durationText)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .fixedSize(horizontal: true, vertical: false)
        .background(AppTheme.hoverBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("曲线选中区间")
        .accessibilityValue(accessibilitySummary)
    }

    private var average: Int {
        selection.breakdown.calls > 0
            ? selection.breakdown.totalTokens / selection.breakdown.calls
            : 0
    }

    private var accessibilitySummary: String {
        var parts = [
            timeRange,
            "\(selection.breakdown.totalTokens.abbreviatedTokens) token",
            "\(selection.breakdown.calls) 次请求",
            "金额 \(selection.fullCurrentAPIPriceEstimate.costUSD.quotaEstimatorMoneyText)",
            "缓存命中率 \(selection.breakdown.cacheHitRate.percentString)"
        ]
        if let models = ModelUsagePresentation.compactText(
            from: ModelUsagePresentation.rows(from: selection.fullAttributionEvents)
        ) {
            parts.append("模型占比 \(models)")
        }
        return parts.joined(separator: "；")
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDate(selection.startDate, inSameDayAs: selection.endDate)
            ? "HH:mm"
            : "M月d日 HH:mm"
        return "\(formatter.string(from: selection.startDate)) - \(formatter.string(from: selection.endDate))"
    }

    private var durationText: String {
        let seconds = max(0, Int(selection.endDate.timeIntervalSince(selection.startDate)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)天 \(hours)小时" }
        if hours > 0 { return "\(hours)小时 \(minutes)分钟" }
        return "\(max(minutes, 1))分钟"
    }
}

struct ChartTimeMarkers: View {
    let bins: [BinUsage]
    let markerIndices: [Int]
    let range: RecentChartRange
    let plot: CGRect
    let markerOffset: CGFloat

    var body: some View {
        ForEach(markerIndices, id: \.self) { index in
            if let bin = bins[safe: index] {
                Text(ChartTimeMarkerLabel.text(for: bin.start, range: range))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .position(x: xPosition(for: index), y: plot.maxY + markerOffset)
            }
        }
    }

    private func xPosition(for index: Int) -> CGFloat {
        plot.minX + CGFloat(index) * plot.width / CGFloat(max(bins.count - 1, 1))
    }

}

enum ChartTimeMarkerLabel {
    static func text(for date: Date, range _: RecentChartRange) -> String {
        DateFormatter.monthDay.string(from: date)
    }
}
