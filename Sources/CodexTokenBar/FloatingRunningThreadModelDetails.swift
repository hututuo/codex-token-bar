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
            RunningThreadModelDisplayRow(
                id: breakdown.id,
                model: breakdown.model,
                title: memberLabel(
                    model: breakdown.model,
                    reasoningEffort: breakdown.reasoningEffort
                ),
                count: breakdown.count
            )
        }
        let represented = rows.reduce(0) { $0 + $1.count }
        if expectedCount > represented {
            rows.append(
                RunningThreadModelDisplayRow(
                    id: "unresolved|\(expectedCount - represented)",
                    model: nil,
                    title: "配置同步中",
                    count: expectedCount - represented
                )
            )
        }
        return sorted(rows)
    }

    static func rows(from members: [RunningThreadMember]) -> [RunningThreadModelDisplayRow] {
        var grouped: [String: (model: String?, title: String, count: Int)] = [:]
        for member in members {
            let id = "\(member.model ?? "unknown")|\(member.reasoningEffort ?? "unknown")"
            if let existing = grouped[id] {
                grouped[id] = (existing.model, existing.title, existing.count + 1)
            } else {
                grouped[id] = (
                    member.model,
                    memberLabel(
                        model: member.model,
                        reasoningEffort: member.reasoningEffort
                    ),
                    1
                )
            }
        }
        return sorted(grouped.map { id, value in
            RunningThreadModelDisplayRow(
                id: id,
                model: value.model,
                title: value.title,
                count: value.count
            )
        })
    }

    static func memberLabel(_ member: RunningThreadMember) -> String {
        memberLabel(model: member.model, reasoningEffort: member.reasoningEffort)
    }

    static func statusLabel(
        for freshness: RunningThreadFreshness,
        isDemo: Bool,
        hasPendingConfiguration: Bool
    ) -> String {
        if isDemo { return "示例" }
        if hasPendingConfiguration { return "同步中" }
        switch freshness {
        case .loading: return "读取中"
        case .fresh: return "实时"
        case .stale: return "上次"
        case .unavailable: return "不可用"
        }
    }

    static func hasPendingConfiguration(in summary: RunningThreadSummary) -> Bool {
        let resolvedMain = summary.mainModels
            .filter { $0.model != nil }
            .reduce(0) { $0 + $1.count }
        let resolvedSubagents = summary.subagentModels
            .filter { $0.model != nil }
            .reduce(0) { $0 + $1.count }
        return resolvedMain < summary.main || resolvedSubagents < summary.subagents
    }

    private static func memberLabel(model: String?, reasoningEffort: String?) -> String {
        let modelLabel = model == nil
            ? "配置同步中"
            : ModelUsagePresentation.label(for: model)
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        return effort.map { "\(modelLabel) · \($0)" } ?? modelLabel
    }

    private static func sorted(
        _ rows: [RunningThreadModelDisplayRow]
    ) -> [RunningThreadModelDisplayRow] {
        rows.sorted { lhs, rhs in
            lhs.count == rhs.count
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                : lhs.count > rhs.count
        }
    }
}

struct FloatingRunningThreadModelDetailsCard: View {
    let summary: RunningThreadSummary
    let scale: CGFloat
    let width: CGFloat
    let height: CGFloat
    let appearance: FloatingPanelAppearance
    var isDemo = false
    var onClose: (() -> Void)? = nil

    private let primary = Color(red: 0.075, green: 0.106, blue: 0.157)
    private let secondary = Color(red: 0.31, green: 0.36, blue: 0.43)
    private let divider = Color(red: 0.14, green: 0.18, blue: 0.24).opacity(0.12)

    private var mainColumnWidth: CGFloat {
        86.scaled(by: scale)
    }

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
                    isDemo: isDemo,
                    hasPendingConfiguration: RunningThreadModelDetailsPresentation
                        .hasPendingConfiguration(in: summary)
                ))
                    .font(.system(size: 7.6.scaled(by: scale), weight: .bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.42, blue: 0.48))
                    .padding(.horizontal, 5.scaled(by: scale))
                    .frame(minHeight: 15.scaled(by: scale))
                    .background(
                        Color(red: 0.84, green: 0.95, blue: 0.94),
                        in: Capsule()
                    )
                closeAffordance
            }

            if onClose != nil {
                Text("Esc 或 × 关闭 · 再次点击主／子数字也可收起")
                    .font(.system(size: 8.scaled(by: scale), weight: .regular))
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(divider)

            ScrollView(.vertical) {
              VStack(alignment: .leading, spacing: 0) {
                columnLabels
                if summary.runningModelDetailsRowCount == 0 {
                    Text(emptyStateText)
                        .font(.system(size: 8.scaled(by: scale), weight: .medium))
                        .foregroundStyle(secondary.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8.scaled(by: scale))
                        .overlay(alignment: .top) { Divider().overlay(divider.opacity(0.74)) }
                } else {
                    ForEach(summary.groups) { group in
                        groupRow(group)
                    }
                    if !summary.unassignedSubagents.isEmpty {
                        unassignedRow(summary.unassignedSubagents)
                    }
                }
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10.scaled(by: scale))
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            appearance.runningModelDetailsBackgroundColor,
            in: RoundedRectangle(cornerRadius: 12.scaled(by: scale), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12.scaled(by: scale), style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 1.scaled(by: scale))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12.scaled(by: scale), style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isDemo ? "运行模型详情示例" : "运行模型详情")
    }

    private var columnLabels: some View {
        HStack(spacing: 8.scaled(by: scale)) {
            HStack(spacing: 3.scaled(by: scale)) {
                Text("主线程")
                Text("\(summary.main)")
                    .foregroundStyle(primary)
                    .monospacedDigit()
            }
            .frame(width: mainColumnWidth, alignment: .leading)

            Rectangle()
                .fill(divider)
                .frame(width: 1, height: 10.scaled(by: scale))

            HStack(spacing: 3.scaled(by: scale)) {
                Text("子 Agent")
                Text("\(summary.subagents)")
                    .foregroundStyle(primary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 8.3.scaled(by: scale), weight: .bold))
        .foregroundStyle(secondary)
        .padding(.horizontal, 4.scaled(by: scale))
        .padding(.bottom, 5.scaled(by: scale))
    }

    private func groupRow(_ group: RunningThreadGroup) -> some View {
        HStack(alignment: .center, spacing: 8.scaled(by: scale)) {
            mainThreadLabel(group.mainThread)
                .frame(width: mainColumnWidth, alignment: .leading)
            Rectangle()
                .fill(divider)
                .frame(width: 1)
            subagentModels(group.subagents)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4.scaled(by: scale))
        .padding(.vertical, 4.scaled(by: scale))
        .overlay(alignment: .top) { Divider().overlay(divider.opacity(0.74)) }
    }

    private func unassignedRow(_ members: [RunningThreadMember]) -> some View {
        HStack(alignment: .center, spacing: 8.scaled(by: scale)) {
            Text("未关联")
                .font(.system(size: 8.1.scaled(by: scale), weight: .bold))
                .foregroundStyle(Color(red: 0.48, green: 0.36, blue: 0.29))
                .frame(width: mainColumnWidth, alignment: .leading)
            Rectangle()
                .fill(divider)
                .frame(width: 1)
            subagentModels(members)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4.scaled(by: scale))
        .padding(.vertical, 4.scaled(by: scale))
        .overlay(alignment: .top) { Divider().overlay(divider.opacity(0.74)) }
    }

    private func mainThreadLabel(_ member: RunningThreadMember) -> some View {
        HStack(spacing: 4.scaled(by: scale)) {
            Circle()
                .fill(ModelUsagePresentation.color(for: member.model))
                .frame(width: 5.scaled(by: scale), height: 5.scaled(by: scale))
            Text(RunningThreadModelDetailsPresentation.memberLabel(member))
                .font(.system(size: 8.2.scaled(by: scale), weight: .semibold))
                .foregroundStyle(primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 4.scaled(by: scale))
        .padding(.vertical, 3.scaled(by: scale))
        .background(Color.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 6.scaled(by: scale)))
        .help(member.title ?? "会话标题暂未生成")
        .accessibilityLabel(
            "\(RunningThreadModelDetailsPresentation.memberLabel(member))，\(member.title ?? "会话标题暂未生成")"
        )
    }

    @ViewBuilder
    private func subagentModels(_ members: [RunningThreadMember]) -> some View {
        let rows = RunningThreadModelDetailsPresentation.rows(from: members)
        if rows.isEmpty {
            Text("暂无子 Agent")
                .font(.system(size: 8.scaled(by: scale), weight: .medium))
                .foregroundStyle(secondary.opacity(0.72))
        } else {
            VStack(alignment: .leading, spacing: 4.scaled(by: scale)) {
                ForEach(rows) { row in
                    HStack(spacing: 3.scaled(by: scale)) {
                        Circle()
                            .fill(row.color)
                            .frame(width: 5.scaled(by: scale), height: 5.scaled(by: scale))
                        Text(row.title)
                            .font(.system(size: 8.1.scaled(by: scale), weight: .semibold))
                            .foregroundStyle(primary)
                            .lineLimit(1)
                        if row.count > 1 {
                            Text("×\(row.count)")
                                .font(.system(size: 7.8.scaled(by: scale), weight: .bold))
                                .foregroundStyle(secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 5.scaled(by: scale))
                    .padding(.vertical, 3.scaled(by: scale))
                    .background(Color.white.opacity(0.48), in: Capsule())
                    .overlay { Capsule().stroke(divider.opacity(0.82), lineWidth: 0.7.scaled(by: scale)) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.title)，\(row.count) 个")
                }
            }
        }
    }

    @ViewBuilder
    private var closeAffordance: some View {
        if let onClose {
            Button(action: onClose) { closeIcon }
                .buttonStyle(.plain)
                .help("关闭运行模型详情")
                .accessibilityLabel("关闭运行模型详情")
        } else {
            closeIcon.accessibilityHidden(true)
        }
    }

    private var closeIcon: some View {
        Image(systemName: "xmark")
            .font(.system(size: 7.8.scaled(by: scale), weight: .bold))
            .foregroundStyle(secondary)
            .frame(width: 16.scaled(by: scale), height: 16.scaled(by: scale))
            .background(Color(red: 0.92, green: 0.94, blue: 0.96), in: Circle())
            .contentShape(Circle())
    }

    private var emptyStateText: String {
        switch summary.freshness {
        case .loading: return "正在读取运行线程…"
        case .unavailable: return "运行线程暂不可用"
        case .fresh, .stale: return "暂无运行线程"
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
        groups: [
            RunningThreadGroup(
                mainThread: RunningThreadMember(
                    threadID: "guide-main-one",
                    title: "整理本周模型使用情况",
                    model: "gpt-5.6-sol",
                    reasoningEffort: "ultra"
                ),
                subagents: [
                    RunningThreadMember(
                        threadID: "guide-sub-one",
                        title: nil,
                        model: "gpt-5.6-luna",
                        reasoningEffort: "max"
                    ),
                    RunningThreadMember(
                        threadID: "guide-sub-two",
                        title: nil,
                        model: "gpt-5.6-luna",
                        reasoningEffort: "max"
                    ),
                ]
            ),
            RunningThreadGroup(
                mainThread: RunningThreadMember(
                    threadID: "guide-main-two",
                    title: "检查悬浮窗视觉细节",
                    model: "gpt-5.6-sol",
                    reasoningEffort: "ultra"
                ),
                subagents: []
            ),
            RunningThreadGroup(
                mainThread: RunningThreadMember(
                    threadID: "guide-main-three",
                    title: "更新使用说明",
                    model: "gpt-5.6-luna",
                    reasoningEffort: "max"
                ),
                subagents: []
            ),
        ],
        updatedAt: nil,
        freshness: .fresh
    )
}
