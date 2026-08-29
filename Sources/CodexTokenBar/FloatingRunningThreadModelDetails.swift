import SwiftUI

struct RunningThreadModelDisplayRow: Equatable, Identifiable {
    let id: String
    let model: String?
    let title: String
    let count: Int

    var color: Color {
        ModelUsagePresentation.color(for: model)
    }
}

enum RunningThreadModelDetailsPresentation {
    static func rows(
        from breakdowns: [RunningThreadModelBreakdown],
        expectedCount: Int
    ) -> [RunningThreadModelDisplayRow] {
        var rows = breakdowns.filter { $0.count > 0 }.map { breakdown in
            let modelLabel = breakdown.model == nil
                ? "配置待读取"
                : ModelUsagePresentation.label(for: breakdown.model)
            let effort = breakdown.reasoningEffort?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let title = effort.map { "\(modelLabel) · \($0)" } ?? modelLabel
            return RunningThreadModelDisplayRow(
                id: breakdown.id,
                model: breakdown.model,
                title: title,
                count: breakdown.count
            )
        }
        let represented = rows.reduce(0) { $0 + $1.count }
        if expectedCount > represented {
            rows.append(
                RunningThreadModelDisplayRow(
                    id: "unresolved|\(expectedCount - represented)",
                    model: nil,
                    title: "配置待读取",
                    count: expectedCount - represented
                )
            )
        }
        return rows.sorted { lhs, rhs in
            lhs.count == rhs.count
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                : lhs.count > rhs.count
        }
    }

    static func statusLabel(for freshness: RunningThreadFreshness, isDemo: Bool) -> String {
        if isDemo { return "示例" }
        switch freshness {
        case .loading: return "读取中"
        case .fresh: return "实时"
        case .stale: return "上次"
        case .unavailable: return "不可用"
        }
    }
}

struct FloatingRunningThreadModelDetailsCard: View {
    let summary: RunningThreadSummary
    let scale: CGFloat
    let width: CGFloat
    let height: CGFloat
    var isDemo = false

    private let primary = Color(red: 0.075, green: 0.106, blue: 0.157)
    private let secondary = Color(red: 0.31, green: 0.36, blue: 0.43)
    private let divider = Color(red: 0.14, green: 0.18, blue: 0.24).opacity(0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 7.scaled(by: scale)) {
            HStack(alignment: .center, spacing: 6.scaled(by: scale)) {
                Text("运行模型详情")
                    .font(.system(size: 11.2.scaled(by: scale), weight: .bold))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Spacer(minLength: 4.scaled(by: scale))
                Text(RunningThreadModelDetailsPresentation.statusLabel(
                    for: summary.freshness,
                    isDemo: isDemo
                ))
                    .font(.system(size: 7.6.scaled(by: scale), weight: .bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.42, blue: 0.48))
                    .padding(.horizontal, 5.scaled(by: scale))
                    .frame(minHeight: 15.scaled(by: scale))
                    .background(
                        Color(red: 0.84, green: 0.95, blue: 0.94),
                        in: Capsule()
                    )
            }

            Divider().overlay(divider)

            HStack(alignment: .top, spacing: 8.scaled(by: scale)) {
                modelSection(
                    title: "主线程",
                    count: summary.main,
                    rows: RunningThreadModelDetailsPresentation.rows(
                        from: summary.mainModels,
                        expectedCount: summary.main
                    )
                )
                Rectangle()
                    .fill(divider)
                    .frame(width: 1)
                modelSection(
                    title: "子 Agent",
                    count: summary.subagents,
                    rows: RunningThreadModelDetailsPresentation.rows(
                        from: summary.subagentModels,
                        expectedCount: summary.subagents
                    )
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(10.scaled(by: scale))
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            Color.white.opacity(0.965),
            in: RoundedRectangle(cornerRadius: 12.scaled(by: scale), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12.scaled(by: scale), style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 1.scaled(by: scale))
        }
        .shadow(
            color: Color.black.opacity(0.18),
            radius: 12.scaled(by: scale),
            y: 5.scaled(by: scale)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12.scaled(by: scale), style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isDemo ? "运行模型详情示例" : "运行模型详情")
    }

    private func modelSection(
        title: String,
        count: Int,
        rows: [RunningThreadModelDisplayRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5.scaled(by: scale)) {
            HStack(spacing: 3.scaled(by: scale)) {
                Text(title)
                    .font(.system(size: 8.3.scaled(by: scale), weight: .bold))
                    .foregroundStyle(secondary)
                Text("\(count)")
                    .font(.system(size: 8.3.scaled(by: scale), weight: .bold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
            }

            if rows.isEmpty {
                Text(emptyStateText)
                    .font(.system(size: 8.scaled(by: scale), weight: .medium))
                    .foregroundStyle(secondary.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 5.scaled(by: scale)) {
                        ForEach(rows) { row in
                            HStack(spacing: 4.scaled(by: scale)) {
                                Circle()
                                    .fill(row.color)
                                    .frame(width: 5.scaled(by: scale), height: 5.scaled(by: scale))
                                Text(row.title)
                                    .font(.system(size: 8.2.scaled(by: scale), weight: .semibold))
                                    .foregroundStyle(primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                Spacer(minLength: 2.scaled(by: scale))
                                Text("×\(row.count)")
                                    .font(.system(size: 8.scaled(by: scale), weight: .bold))
                                    .foregroundStyle(secondary)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.title)，\(row.count) 个")
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyStateText: String {
        switch summary.freshness {
        case .loading: return "读取中…"
        case .unavailable: return "暂不可用"
        case .fresh, .stale: return "暂无运行"
        }
    }
}

extension RunningThreadSummary {
    static let guideModelDetailsDemo = RunningThreadSummary(
        main: 3,
        subagents: 2,
        mainModels: [
            RunningThreadModelBreakdown(model: "gpt-5.6-sol", reasoningEffort: "ultra", count: 2),
            RunningThreadModelBreakdown(model: "gpt-5.6-luna", reasoningEffort: "max", count: 1),
        ],
        subagentModels: [
            RunningThreadModelBreakdown(model: "gpt-5.6-luna", reasoningEffort: "max", count: 2),
        ],
        updatedAt: nil,
        freshness: .fresh
    )
}
