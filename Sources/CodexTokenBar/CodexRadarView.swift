import SwiftUI

struct CodexRadarStrip: View {
    let snapshot: CodexRadarSnapshot?
    let status: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onShowDetails: () -> Void

    struct ColumnWidths {
        let window: CGFloat
        let modelIQ: CGFloat
        let quota: CGFloat
        let environment: CGFloat
    }

    nonisolated static func columnWidths(totalWidth: CGFloat) -> ColumnWidths {
        let clampedWidth = max(0, totalWidth)
        let weights: (window: CGFloat, modelIQ: CGFloat, quota: CGFloat, environment: CGFloat) = (0.82, 1.08, 1.12, 0.98)
        let totalWeight = weights.window + weights.modelIQ + weights.quota + weights.environment

        return ColumnWidths(
            window: clampedWidth * weights.window / totalWeight,
            modelIQ: clampedWidth * weights.modelIQ / totalWeight,
            quota: clampedWidth * weights.quota / totalWeight,
            environment: clampedWidth * weights.environment / totalWeight
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Codex 雷达")
                    .font(.system(size: 15, weight: .semibold))

                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                CodexRadarHeaderSourceCredit(snapshot: snapshot)

                Button(action: onRefresh) {
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("立即刷新 Codex 雷达")
                .disabled(isRefreshing)

                Button(action: onShowDetails) {
                    Label("详细信息", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }

            GeometryReader { proxy in
                let columnWidths = Self.columnWidths(totalWidth: proxy.size.width - 3)
                HStack(spacing: 0) {
                    CodexRadarWindowBlock(snapshot: snapshot)
                        .frame(width: columnWidths.window, height: 74, alignment: .leading)
                    CodexRadarDivider()
                    CodexRadarModelIQBlock(snapshot: snapshot)
                        .frame(width: columnWidths.modelIQ, height: 74, alignment: .leading)
                    CodexRadarDivider()
                    CodexRadarQuotaBlock(snapshot: snapshot)
                        .frame(width: columnWidths.quota, height: 74, alignment: .leading)
                    CodexRadarDivider()
                    CodexRadarEnvironmentBlock(snapshot: snapshot)
                        .frame(width: columnWidths.environment, height: 74, alignment: .leading)
                }
            }
            .frame(height: 74)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 980)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var statusText: String {
        guard let snapshot else { return status }
        return "10分钟刷新 · \(snapshot.monitoredAt)"
    }
}

private struct CodexRadarDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.border)
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}

private struct CodexRadarHeaderSourceCredit: View {
    let snapshot: CodexRadarSnapshot?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("感谢")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Codex 雷达  codexradar.com")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .help(sourceHelpText)
    }

    private var sourceHelpText: String {
        guard let html = snapshot?.links.html else {
            return "感谢来源网址与雷达"
        }
        return "感谢 \(html)"
    }
}

private struct CodexRadarWindowBlock: View {
    let snapshot: CodexRadarSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodexRadarBlockTitle("速蹬窗口", systemImage: "bolt.badge.clock")
            Text(snapshot?.window.message ?? "等待 Codex 雷达")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 10) {
                CodexRadarTinyMetric(label: "建议动作", value: snapshot?.recommendedAction ?? "--")
                CodexRadarTinyMetric(label: "24h", value: probabilityText(snapshot?.prediction.probability24hPercent))
                CodexRadarTinyMetric(label: "48h", value: probabilityText(snapshot?.prediction.probability48hPercent))
            }
        }
        .padding(.trailing, 10)
    }
}

private struct CodexRadarModelIQBlock: View {
    let snapshot: CodexRadarSnapshot?

    var body: some View {
        let primary = snapshot?.modelIQ.primaryModelRow.point
        VStack(alignment: .leading, spacing: 6) {
            CodexRadarBlockTitle("今日主模型", systemImage: "brain.head.profile")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(primary?.scoreDisplayText ?? "IQ --")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(primary?.modelDisplayName ?? "待读取")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                ForEach((snapshot?.modelIQ.secondaryModelRows ?? []).prefix(3), id: \.label) { row in
                    Text("\(row.label.replacingOccurrences(of: "GPT-", with: "")) \(CodexRadarModelIQPoint.display(row.point.score))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color(for: row.point.status))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct CodexRadarQuotaBlock: View {
    let snapshot: CodexRadarSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodexRadarBlockTitle("预估额度", systemImage: "gauge.with.dots.needle.67percent")
            ForEach(snapshot?.modelIQ.quotaRadar?.rowsForDisplay ?? []) { row in
                HStack(spacing: 8) {
                    Text(row.tier)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 44, alignment: .leading)
                    Text("5h \(row.fiveHourDisplayText)")
                    Text("7d \(row.sevenDayDisplayText)")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct CodexRadarEnvironmentBlock: View {
    let snapshot: CodexRadarSnapshot?

    var body: some View {
        let environment = snapshot?.codexEnvironment
        VStack(alignment: .leading, spacing: 6) {
            CodexRadarBlockTitle("环境压力", systemImage: "waveform.path.ecg")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(environment?.complaintPressure ?? "--")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("异常 \(environment?.issueOrLimitAnomalies24h ?? 0)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                CodexRadarTinyMetric(label: "官方", value: "\(environment?.officialUpdates24h ?? 0)")
                CodexRadarTinyMetric(label: "社区", value: "\(environment?.communityMentions24h ?? 0)")
                CodexRadarTinyMetric(label: "事故", value: "\(environment?.statusIncidents24h ?? 0)")
            }
        }
        .padding(.leading, 10)
    }
}

struct CodexRadarDetailCard: View {
    let snapshot: CodexRadarSnapshot?
    let feedItems: [CodexRadarFeedItem]
    let status: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Codex 雷达详细信息")
                    .font(.system(size: 20, weight: .semibold))
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: onRefresh) {
                    Label(isRefreshing ? "刷新中" : "刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(AppTheme.calloutHeaderBackground)

            Divider()

            ScrollView {
                if let snapshot {
                    VStack(alignment: .leading, spacing: 14) {
                        CodexRadarDetailOverview(snapshot: snapshot)
                        CodexRadarIQDetail(snapshot: snapshot)
                        CodexRadarQuotaDetail(snapshot: snapshot)
                        CodexRadarEnvironmentDetail(snapshot: snapshot, feedItems: feedItems)
                    }
                    .padding(18)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(status)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.calloutBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CodexRadarDetailOverview: View {
    let snapshot: CodexRadarSnapshot

    var body: some View {
        CodexRadarDetailSection(title: "速蹬窗口与预测", systemImage: "bolt.badge.clock") {
            CodexRadarDetailSubsection(title: "窗口摘要") {
                CodexRadarKeyValueGrid(rows: [
                    ("窗口状态", snapshot.window.message),
                    ("建议动作", snapshot.recommendedAction),
                    ("24h 概率", probabilityText(snapshot.prediction.probability24hPercent)),
                    ("48h 概率", probabilityText(snapshot.prediction.probability48hPercent)),
                    ("预计窗口", snapshot.prediction.expectedWindow),
                    ("范围", snapshot.window.scope),
                    ("上次关闭", snapshot.window.closedAt ?? "--"),
                    ("来源", snapshot.window.sourceUrl ?? "--")
                ])
            }

            CodexRadarDetailSubsection(title: "预测说明") {
                Text(snapshot.prediction.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CodexRadarDetailSubsection(title: "信号拆分") {
                HStack(alignment: .top, spacing: 12) {
                    CodexRadarSignalList(title: "积极信号", items: snapshot.prediction.positiveSignals)
                    CodexRadarSignalList(title: "降温信号", items: snapshot.prediction.negativeSignals)
                }
            }

            if let tibo = snapshot.tiboPresence, tibo.shouldDisplay == true {
                CodexRadarDetailSubsection(title: "Tibo 观察") {
                    CodexRadarKeyValueGrid(rows: [
                        ("Tibo 位置/时区", tibo.locationLabelZh ?? "--"),
                        ("概率", probabilityText(Int(((tibo.probability ?? 0) * 100).rounded()))),
                        ("置信度", tibo.confidence ?? "--"),
                        ("观察数", "\(tibo.observationsConsidered ?? 0)")
                    ])
                    Text(tibo.safetyNoteZh ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CodexRadarIQDetail: View {
    let snapshot: CodexRadarSnapshot
    @State private var selectedModelSeriesIDs: Set<String> = []

    var body: some View {
        let modelSeries = snapshot.modelIQ.chartSeries
        let activeIDs = activeSelectedIDs(for: modelSeries)

        CodexRadarDetailSection(title: "降智雷达", systemImage: "brain.head.profile") {
            CodexRadarDetailSubsection(title: "IQ 趋势") {
                HStack(spacing: 5) {
                    ForEach(Array(modelSeries.enumerated()), id: \.element.id) { index, series in
                        ChartLineToggle(
                            title: compactModelLabel(series.label),
                            color: codexRadarSeriesColor(index),
                            isOn: modelSelectionBinding(for: series.id, in: modelSeries)
                        )
                    }
                }

                CodexRadarSeriesLineChart(
                    series: modelSeries,
                    visibleSeriesIDs: activeIDs,
                    xAxisTitle: "评测日期",
                    yAxisTitle: "IQ 指数",
                    valuePrefix: "IQ ",
                    yDomain: 50...130,
                    yTickValues: [120, 100, 80, 60],
                    highlightRange: 90...110
                )
                .frame(height: 155)
            }

            CodexRadarDetailSubsection(title: "模型对比") {
                CodexRadarTable(
                    headers: ["模型", "IQ", "通过", "状态", "费用", "耗时", "Tokens"],
                    rows: snapshot.modelIQ.comparisonRows.map { row in
                        [
                            row.label,
                            CodexRadarModelIQPoint.display(row.point.score),
                            row.point.passRatioText,
                            row.point.status,
                            row.point.costDisplayText,
                            row.point.wallTimeHuman,
                            row.point.totalTokensDisplayText
                        ]
                    }
                )
            }

            CodexRadarDetailSubsection(title: "近日日志") {
                CodexRadarTable(
                    headers: ["日期", "IQ", "通过", "状态", "耗时", "Tokens"],
                    rows: snapshot.modelIQ.recentDays.map { point in
                        [
                            point.date,
                            CodexRadarModelIQPoint.display(point.score),
                            point.passRatioText,
                            point.status,
                            point.wallTimeHuman,
                            point.totalTokensDisplayText
                        ]
                    }
                )
            }
        }
    }

    private func activeSelectedIDs(for series: [CodexRadarChartSeries]) -> Set<String> {
        let validIDs = Set(series.map(\.id))
        let selected = selectedModelSeriesIDs.intersection(validIDs)
        if !selected.isEmpty {
            return selected
        }
        return Set(series.prefix(2).map(\.id))
    }

    private func modelSelectionBinding(for id: String, in series: [CodexRadarChartSeries]) -> Binding<Bool> {
        Binding(
            get: {
                activeSelectedIDs(for: series).contains(id)
            },
            set: { isOn in
                var next = activeSelectedIDs(for: series)
                if isOn {
                    next.insert(id)
                } else {
                    next.remove(id)
                    if next.isEmpty {
                        next.insert(id)
                    }
                }
                selectedModelSeriesIDs = next
            }
        )
    }
}

private struct CodexRadarQuotaDetail: View {
    let snapshot: CodexRadarSnapshot
    @State private var selectedQuotaWindow: CodexRadarQuotaWindow = .fiveHour
    @State private var selectedQuotaTierIDs: Set<String> = ["quota-plus", "quota-5x", "quota-20x"]

    var body: some View {
        CodexRadarDetailSection(title: "预估额度", systemImage: "gauge.with.dots.needle.67percent") {
            if let quotaRadar = snapshot.modelIQ.quotaRadar {
                let quotaSeries = quotaRadar.chartSeries(for: selectedQuotaWindow)
                let activeTierIDs = activeSelectedTierIDs(for: quotaSeries)

                CodexRadarDetailSubsection(title: "额度基准") {
                    CodexRadarKeyValueGrid(rows: [
                        ("依据窗口", quotaRadar.basisWindowLabel),
                        ("本轮成本", "$\(CodexRadarModelIQPoint.display(quotaRadar.costUsd, fractionDigits: 2))"),
                        ("本轮 tokens", "\(CodexRadarModelIQPoint.display(Double(quotaRadar.totalTokens) / 1_000_000, fractionDigits: 2))M"),
                        ("原始变化", "\(quotaRadar.rawDelta)%"),
                        ("修正变化", "\(quotaRadar.adjustedDelta)%"),
                        ("rate", "$\(CodexRadarModelIQPoint.display(quotaRadar.rate, fractionDigits: 4))")
                    ])
                }

                CodexRadarDetailSubsection(title: "\(selectedQuotaWindow.title) 额度趋势") {
                    HStack(alignment: .center, spacing: 10) {
                        CodexRadarQuotaWindowSelector(selection: $selectedQuotaWindow)

                        HStack(spacing: 5) {
                            ForEach(Array(quotaSeries.enumerated()), id: \.element.id) { index, series in
                                ChartLineToggle(
                                    title: series.label,
                                    color: codexRadarSeriesColor(index),
                                    isOn: quotaTierSelectionBinding(for: series.id, in: quotaSeries)
                                )
                            }
                        }
                    }

                    CodexRadarSeriesLineChart(
                        series: quotaSeries,
                        visibleSeriesIDs: activeTierIDs,
                        xAxisTitle: "日期",
                        yAxisTitle: "\(selectedQuotaWindow.title)美元额度",
                        valuePrefix: "$"
                    )
                    .frame(height: 155)
                }

                CodexRadarDetailSubsection(title: "套餐预估") {
                    CodexRadarTable(
                        headers: ["套餐", "5h", "7d", "依据"],
                        rows: quotaRadar.rowsForDisplay.map { row in
                            [row.tier, row.fiveHourDisplayText, row.sevenDayDisplayText, row.basis]
                        }
                    )
                }

                CodexRadarDetailSubsection(title: "趋势明细") {
                    CodexRadarTable(
                        headers: ["日期", "20x 5h", "20x 7d", "5x 5h", "Plus 5h", "依据"],
                        rows: quotaRadar.trend.map { point in
                            [
                                point.date,
                                "$\(CodexRadarModelIQPoint.display(point.fiveHour20x, fractionDigits: 2))",
                                "$\(CodexRadarModelIQPoint.display(point.sevenDay20x, fractionDigits: 2))",
                                "$\(CodexRadarModelIQPoint.display(point.fiveHour5x, fractionDigits: 2))",
                                "$\(CodexRadarModelIQPoint.display(point.fiveHourPlus, fractionDigits: 2))",
                                point.basisWindowLabel
                            ]
                        }
                    )
                }
            } else {
                Text("暂无额度雷达数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeSelectedTierIDs(for series: [CodexRadarChartSeries]) -> Set<String> {
        let validIDs = Set(series.map(\.id))
        let selected = selectedQuotaTierIDs.intersection(validIDs)
        if !selected.isEmpty {
            return selected
        }
        return validIDs
    }

    private func quotaTierSelectionBinding(for id: String, in series: [CodexRadarChartSeries]) -> Binding<Bool> {
        Binding(
            get: {
                activeSelectedTierIDs(for: series).contains(id)
            },
            set: { isOn in
                var next = activeSelectedTierIDs(for: series)
                if isOn {
                    next.insert(id)
                } else {
                    next.remove(id)
                    if next.isEmpty {
                        next.insert(id)
                    }
                }
                selectedQuotaTierIDs = next
            }
        )
    }
}

private struct CodexRadarEnvironmentDetail: View {
    let snapshot: CodexRadarSnapshot
    let feedItems: [CodexRadarFeedItem]

    var body: some View {
        let environment = snapshot.codexEnvironment
        CodexRadarDetailSection(title: "环境压力与资讯", systemImage: "waveform.path.ecg") {
            CodexRadarDetailSubsection(title: "压力指标") {
                CodexRadarKeyValueGrid(rows: [
                    ("官方动态 24h", "\(environment.officialUpdates24h)"),
                    ("社区提及 24h", "\(environment.communityMentions24h)"),
                    ("异常/限额反馈", "\(environment.issueOrLimitAnomalies24h)"),
                    ("Status 事故", "\(environment.statusIncidents24h)"),
                    ("抱怨压力", environment.complaintPressure),
                    ("RSS", snapshot.links.rss)
                ])
            }

            CodexRadarDetailSubsection(title: "角色分布") {
                CodexRadarRoleCountsView(roleCounts: environment.roleCounts)
            }

            CodexRadarArticleList(title: "官方动态", items: environment.officialNews.map {
                CodexRadarArticleRow(title: $0.titleZh ?? "Codex 官方动态", subtitle: "@\($0.account ?? "--") · \($0.summaryEn ?? $0.text ?? "")", url: $0.url)
            })

            CodexRadarArticleList(title: "社区反馈样本", items: environment.complaintExamples.map {
                CodexRadarArticleRow(title: "@\($0.account)", subtitle: $0.summaryZh, url: $0.url)
            })

            CodexRadarArticleList(title: "RSS 提醒历史", items: feedItems.map {
                CodexRadarArticleRow(title: $0.title, subtitle: "\($0.pubDate) · \($0.description)", url: $0.link)
            })
        }
    }
}

private struct CodexRadarBlockTitle: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct CodexRadarTinyMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct CodexRadarDetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.accentBlue)
                    .frame(width: 26, height: 26)
                    .background(AppTheme.selectedControlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Spacer(minLength: 8)
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(13)
        .background(AppTheme.calloutOptionBackground.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.borderStrong.opacity(0.56), lineWidth: 1)
        )
    }
}

private struct CodexRadarDetailSubsection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.calloutBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(AppTheme.borderStrong.opacity(0.42), lineWidth: 1)
        )
    }
}

private struct CodexRadarKeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.0)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.insetBackground.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct CodexRadarSignalList: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("· \(item)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.insetBackground.opacity(0.48), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct CodexRadarQuotaWindowSelector: View {
    @Binding var selection: CodexRadarQuotaWindow

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CodexRadarQuotaWindow.allCases) { window in
                Button {
                    selection = window
                } label: {
                    Text(window.shortTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selection == window ? AppTheme.accentBlue : .secondary)
                        .frame(width: 46, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == window ? AppTheme.accentBlue.opacity(0.12) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("额度窗口 \(window.title)")
                .accessibilityValue(selection == window ? "已选择" : "未选择")
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

private struct CodexRadarSeriesLineChart: View {
    let series: [CodexRadarChartSeries]
    let visibleSeriesIDs: Set<String>
    let xAxisTitle: String
    let yAxisTitle: String
    let valuePrefix: String
    var yDomain: ClosedRange<Double>? = nil
    var yTickValues: [Double]? = nil
    var highlightRange: ClosedRange<Double>? = nil
    @State private var hoveredChartIndex: Int?

    private var visibleSeries: [(index: Int, series: CodexRadarChartSeries)] {
        series.enumerated().compactMap { index, series in
            visibleSeriesIDs.contains(series.id) ? (index, series) : nil
        }
    }

    private var xLabels: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for point in visibleSeries.flatMap(\.series.points) {
            guard !seen.contains(point.rawLabel) else { continue }
            seen.insert(point.rawLabel)
            labels.append(point.rawLabel)
        }
        return labels
    }

    private var xDisplayLabels: [String] {
        xLabels.map(CodexRadarChartPoint.shortDateLabel)
    }

    private var values: [Double] {
        visibleSeries.flatMap(\.series.points).map(\.value)
    }

    var body: some View {
        GeometryReader { proxy in
            let axis = valueAxis(values: values)
            let labels = xLabels
            let displayLabels = xDisplayLabels
            let xIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset) })
            let plot = CGRect(x: 48, y: 20, width: max(10, proxy.size.width - 58), height: max(10, proxy.size.height - 54))
            let step = plot.width / CGFloat(max(labels.count - 1, 1))
            let activeIndex = hoveredChartIndex.flatMap { labels.indices.contains($0) ? $0 : nil }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.insetBackground)
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                if let highlightRange {
                    let upper = yPosition(for: highlightRange.upperBound, axis: axis, plot: plot)
                    let lower = yPosition(for: highlightRange.lowerBound, axis: axis, plot: plot)
                    Rectangle()
                        .fill(AppTheme.accentCyan.opacity(0.075))
                        .frame(width: plot.width, height: max(1, lower - upper))
                        .offset(x: plot.minX, y: upper)
                }

                ForEach(axis.tickValues, id: \.self) { tick in
                    let y = yPosition(for: tick, axis: axis, plot: plot)
                    Path { path in
                        path.move(to: CGPoint(x: plot.minX, y: y))
                        path.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    .stroke(AppTheme.grid, style: StrokeStyle(lineWidth: 1, dash: [4, 8]))

                    Text("\(valuePrefix)\(CodexRadarModelIQPoint.display(tick, fractionDigits: 2))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                        .position(x: plot.minX - 25, y: y)
                }

                ForEach(visibleSeries, id: \.series.id) { item in
                    let points = chartPoints(for: item.series, xIndex: xIndex, axis: axis, plot: plot, step: step)
                    let color = codexRadarSeriesColor(item.index)

                    Path { path in
                        for (index, point) in points.enumerated() {
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(AppTheme.calloutBackground)
                            .frame(width: 5.5, height: 5.5)
                            .overlay(Circle().stroke(color, lineWidth: 1.4))
                            .position(point)
                    }
                }

                if let activeIndex {
                    let x = plot.minX + CGFloat(activeIndex) * step
                    Path { path in
                        path.move(to: CGPoint(x: x, y: plot.minY))
                        path.addLine(to: CGPoint(x: x, y: plot.maxY))
                    }
                    .stroke(AppTheme.accentBlue.opacity(0.36), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

                    CodexRadarChartHoverBubble(
                        dateLabel: displayLabels[safe: activeIndex] ?? labels[activeIndex],
                        rows: hoverRows(at: activeIndex, labels: labels)
                    )
                    .chartBubblePlacement(tokenX: x, plot: plot)
                    .zIndex(10)
                }

                HoverTrackingArea(
                    onMove: { location in
                        let plotLocation = CGPoint(x: location.x + plot.minX, y: location.y + plot.minY)
                        hoveredChartIndex = hoverIndex(at: plotLocation, in: plot, step: step, count: labels.count)
                    },
                    onExit: {
                        hoveredChartIndex = nil
                    }
                )
                .frame(width: plot.width, height: plot.height)
                .position(x: plot.midX, y: plot.midY)

                ForEach(allXMarkerIndices(count: labels.count), id: \.self) { index in
                    Text(displayLabels[safe: index] ?? "")
                        .font(.system(size: labels.count > 7 ? 8 : 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .rotationEffect(labels.count > 7 ? .degrees(-24) : .zero)
                        .fixedSize(horizontal: true, vertical: false)
                        .position(x: plot.minX + CGFloat(index) * step, y: plot.maxY + 15)
                }

                HStack {
                    Text("Y: \(yAxisTitle)")
                    Spacer()
                    Text("X: \(xAxisTitle)")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: plot.width)
                .offset(x: plot.minX, y: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex 雷达趋势图")
    }

    private struct ValueAxis {
        let minValue: Double
        let maxValue: Double
        let tickValues: [Double]
    }

    private func valueAxis(values: [Double]) -> ValueAxis {
        if let yDomain {
            return ValueAxis(
                minValue: yDomain.lowerBound,
                maxValue: yDomain.upperBound,
                tickValues: yTickValues ?? evenlySpacedTicks(min: yDomain.lowerBound, max: yDomain.upperBound)
            )
        }

        let minData = values.min() ?? 0
        let maxData = values.max() ?? 1
        let rawRange = max(maxData - minData, 1)
        let paddedMin = max(0, minData - rawRange * 0.12)
        let paddedMax = maxData + rawRange * 0.12
        let niceMin = floor(paddedMin / 10) * 10
        let niceMax = ceil(paddedMax / 10) * 10
        return ValueAxis(minValue: niceMin, maxValue: niceMax, tickValues: evenlySpacedTicks(min: niceMin, max: niceMax))
    }

    private func evenlySpacedTicks(min: Double, max: Double) -> [Double] {
        let count = 4
        guard max > min else { return [max] }
        return (0..<count).map { index in
            max - (max - min) * Double(index) / Double(count - 1)
        }
    }

    private func yPosition(for value: Double, axis: ValueAxis, plot: CGRect) -> CGFloat {
        let range = max(axis.maxValue - axis.minValue, 1)
        let clamped = min(max(value, axis.minValue), axis.maxValue)
        return plot.maxY - CGFloat((clamped - axis.minValue) / range) * plot.height
    }

    private func chartPoints(
        for series: CodexRadarChartSeries,
        xIndex: [String: Int],
        axis: ValueAxis,
        plot: CGRect,
        step: CGFloat
    ) -> [CGPoint] {
        series.points.compactMap { point in
            guard let index = xIndex[point.rawLabel] else { return nil }
            return CGPoint(
                x: plot.minX + CGFloat(index) * step,
                y: yPosition(for: point.value, axis: axis, plot: plot)
            )
        }
    }

    private func allXMarkerIndices(count: Int) -> [Int] {
        Array(0..<max(count, 0))
    }

    private func hoverIndex(at location: CGPoint, in plot: CGRect, step: CGFloat, count: Int) -> Int? {
        guard count > 0, plot.contains(location) else { return nil }
        let rawIndex = Int(round((location.x - plot.minX) / max(step, 1)))
        return min(max(rawIndex, 0), count - 1)
    }

    private func hoverRows(at index: Int, labels: [String]) -> [CodexRadarChartHoverRow] {
        guard let rawLabel = labels[safe: index] else { return [] }
        return visibleSeries.compactMap { item in
            guard let point = item.series.points.first(where: { $0.rawLabel == rawLabel }) else {
                return nil
            }
            return CodexRadarChartHoverRow(
                id: item.series.id,
                label: item.series.label,
                value: "\(valuePrefix)\(CodexRadarModelIQPoint.display(point.value, fractionDigits: 2))",
                colorIndex: item.index
            )
        }
    }
}

private struct CodexRadarChartHoverRow: Identifiable {
    let id: String
    let label: String
    let value: String
    let colorIndex: Int
}

private struct CodexRadarChartHoverBubble: View {
    let dateLabel: String
    let rows: [CodexRadarChartHoverRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack(spacing: 7) {
                    Circle()
                        .fill(codexRadarSeriesColor(row.colorIndex))
                        .frame(width: 7, height: 7)
                    Text(compactModelLabel(row.label))
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 132, alignment: .leading)
        .background(AppTheme.hoverBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.borderStrong, lineWidth: 1)
        )
    }
}

private struct CodexRadarTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        CodexRadarTableContainer {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(headers, id: \.self) { header in
                        Text(header)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.calloutHeaderBackground)

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(index.isMultiple(of: 2) ? Color.clear : AppTheme.insetBackground.opacity(0.45))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
}

private struct CodexRadarTableContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(AppTheme.calloutBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.borderStrong.opacity(0.46), lineWidth: 1)
            )
            .padding(.top, 1)
    }
}

private struct CodexRadarArticlePanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.calloutBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(AppTheme.borderStrong.opacity(0.42), lineWidth: 1)
        )
    }
}

private struct CodexRadarRoleCountsView: View {
    let roleCounts: [String: Int]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(roleCounts.sorted(by: { $0.value > $1.value }), id: \.key) { role, count in
                Text("\(role): \(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(AppTheme.insetBackground.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct CodexRadarArticleRow: Identifiable {
    var id: String { url }
    let title: String
    let subtitle: String
    let url: String
}

private struct CodexRadarArticleList: View {
    let title: String
    let items: [CodexRadarArticleRow]

    var body: some View {
        CodexRadarArticlePanel(title: title) {
            if items.isEmpty {
                Text("暂无")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(item.url)
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.accentBlue)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.insetBackground.opacity(index.isMultiple(of: 2) ? 0.42 : 0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

private func codexRadarSeriesColor(_ index: Int) -> Color {
    let colors: [Color] = [
        AppTheme.accentCyan,
        AppTheme.accentOrange,
        AppTheme.accentBlue,
        .green.opacity(0.88),
        .purple.opacity(0.90)
    ]
    return colors[index % colors.count]
}

private func compactModelLabel(_ label: String) -> String {
    label
        .replacingOccurrences(of: "GPT-", with: "")
        .replacingOccurrences(of: " ", with: "-")
}

private func probabilityText(_ percent: Int?) -> String {
    guard let percent else { return "--" }
    return "\(percent)%"
}

private func color(for status: String) -> Color {
    switch status {
    case "green":
        return .green
    case "yellow":
        return AppTheme.accentOrange
    case "red":
        return .red
    default:
        return .secondary
    }
}
