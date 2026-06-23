import SwiftUI

struct CodexRadarStrip: View {
    let snapshot: CodexRadarSnapshot?
    let status: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onShowDetails: () -> Void

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
                let columnWidth = max(128, (proxy.size.width - 3) / 4)
                HStack(spacing: 0) {
                    CodexRadarWindowBlock(snapshot: snapshot)
                        .frame(width: columnWidth, height: 74, alignment: .leading)
                    CodexRadarDivider()
                    CodexRadarModelIQBlock(snapshot: snapshot)
                        .frame(width: columnWidth, height: 74, alignment: .leading)
                    CodexRadarDivider()
                    CodexRadarQuotaBlock(snapshot: snapshot)
                        .frame(width: columnWidth, height: 74, alignment: .leading)
                    CodexRadarDivider()
                    CodexRadarEnvironmentBlock(snapshot: snapshot)
                        .frame(width: columnWidth, height: 74, alignment: .leading)
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
        let latest = snapshot?.modelIQ.latest
        VStack(alignment: .leading, spacing: 6) {
            CodexRadarBlockTitle("今日主模型", systemImage: "brain.head.profile")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(latest?.scoreDisplayText ?? "IQ --")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(latest?.modelDisplayName ?? "待读取")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                ForEach((snapshot?.modelIQ.comparisonRows ?? []).prefix(3), id: \.label) { row in
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
                    VStack(alignment: .leading, spacing: 18) {
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

            Text(snapshot.prediction.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 14) {
                CodexRadarSignalList(title: "积极信号", items: snapshot.prediction.positiveSignals)
                CodexRadarSignalList(title: "降温信号", items: snapshot.prediction.negativeSignals)
            }

            if let tibo = snapshot.tiboPresence, tibo.shouldDisplay == true {
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

private struct CodexRadarIQDetail: View {
    let snapshot: CodexRadarSnapshot

    var body: some View {
        CodexRadarDetailSection(title: "降智雷达", systemImage: "brain.head.profile") {
            CodexRadarLineChart(
                points: snapshot.modelIQ.recentDays.map { ($0.date, $0.score) },
                color: AppTheme.accentCyan,
                valuePrefix: "IQ "
            )
            .frame(height: 155)

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

private struct CodexRadarQuotaDetail: View {
    let snapshot: CodexRadarSnapshot

    var body: some View {
        CodexRadarDetailSection(title: "预估额度", systemImage: "gauge.with.dots.needle.67percent") {
            if let quotaRadar = snapshot.modelIQ.quotaRadar {
                CodexRadarKeyValueGrid(rows: [
                    ("依据窗口", quotaRadar.basisWindowLabel),
                    ("本轮成本", "$\(CodexRadarModelIQPoint.display(quotaRadar.costUsd, fractionDigits: 2))"),
                    ("本轮 tokens", "\(CodexRadarModelIQPoint.display(Double(quotaRadar.totalTokens) / 1_000_000, fractionDigits: 2))M"),
                    ("原始变化", "\(quotaRadar.rawDelta)%"),
                    ("修正变化", "\(quotaRadar.adjustedDelta)%"),
                    ("rate", "$\(CodexRadarModelIQPoint.display(quotaRadar.rate, fractionDigits: 4))")
                ])

                CodexRadarLineChart(
                    points: quotaRadar.trend.map { ($0.date, $0.fiveHour20x) },
                    color: AppTheme.accentOrange,
                    valuePrefix: "$"
                )
                .frame(height: 155)

                CodexRadarTable(
                    headers: ["套餐", "5h", "7d", "依据"],
                    rows: quotaRadar.rowsForDisplay.map { row in
                        [row.tier, row.fiveHourDisplayText, row.sevenDayDisplayText, row.basis]
                    }
                )

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
            } else {
                Text("暂无额度雷达数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CodexRadarEnvironmentDetail: View {
    let snapshot: CodexRadarSnapshot
    let feedItems: [CodexRadarFeedItem]

    var body: some View {
        let environment = snapshot.codexEnvironment
        CodexRadarDetailSection(title: "环境压力与资讯", systemImage: "waveform.path.ecg") {
            CodexRadarKeyValueGrid(rows: [
                ("官方动态 24h", "\(environment.officialUpdates24h)"),
                ("社区提及 24h", "\(environment.communityMentions24h)"),
                ("异常/限额反馈", "\(environment.issueOrLimitAnomalies24h)"),
                ("Status 事故", "\(environment.statusIncidents24h)"),
                ("抱怨压力", environment.complaintPressure),
                ("RSS", snapshot.links.rss)
            ])

            CodexRadarRoleCountsView(roleCounts: environment.roleCounts)

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
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
            content
        }
        .padding(.bottom, 4)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodexRadarLineChart: View {
    let points: [(String, Double)]
    let color: Color
    let valuePrefix: String

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.1)
            let minValue = values.min() ?? 0
            let maxValue = values.max() ?? 1
            let range = max(maxValue - minValue, 1)
            let plot = CGRect(x: 0, y: 18, width: proxy.size.width, height: max(10, proxy.size.height - 42))
            let step = plot.width / CGFloat(max(points.count - 1, 1))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.insetBackground)
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                ForEach(0..<3, id: \.self) { index in
                    let y = plot.minY + CGFloat(index) * plot.height / 2
                    Path { path in
                        path.move(to: CGPoint(x: plot.minX, y: y))
                        path.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    .stroke(AppTheme.grid, style: StrokeStyle(lineWidth: 1, dash: [4, 8]))
                }

                Path { path in
                    for (index, point) in points.enumerated() {
                        let x = plot.minX + CGFloat(index) * step
                        let y = plot.maxY - CGFloat((point.1 - minValue) / range) * plot.height
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))

                HStack {
                    Text("\(valuePrefix)\(CodexRadarModelIQPoint.display(maxValue, fractionDigits: 2))")
                    Spacer()
                    Text("\(valuePrefix)\(CodexRadarModelIQPoint.display(minValue, fractionDigits: 2))")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(y: plot.maxY + 8)

                HStack {
                    Text(points.first?.0 ?? "")
                    Spacer()
                    Text(points.last?.0 ?? "")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex 雷达趋势图")
    }
}

private struct CodexRadarTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(headers, id: \.self) { header in
                    Text(header)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        Text(value)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(height: 1)
                }
            }
        }
    }
}

private struct CodexRadarRoleCountsView: View {
    let roleCounts: [String: Int]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(roleCounts.sorted(by: { $0.value > $1.value }), id: \.key) { role, count in
                Text("\(role): \(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            if items.isEmpty {
                Text("暂无")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(4)) { item in
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
                    .padding(.vertical, 2)
                }
            }
        }
    }
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
