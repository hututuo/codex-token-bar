import SwiftUI

private enum CacheRankingScope: String, CaseIterable, Identifiable {
    case sessions = "会话"
    case turns = "单轮"

    var id: String { rawValue }
}

private struct CacheRankingItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let context: String?
    let breakdown: TokenCacheBreakdown
}

struct CacheHitRankingSection: View {
    let cacheUsage: TokenCacheUsage
    @State private var scope: CacheRankingScope = .sessions
    @State private var excludesSingleTurnSessions = true
    @State private var excludesFirstTurns = true

    private let minimumInputTokens = 1_000

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("缓存命中排行")
                        .font(.system(size: 19, weight: .semibold))
                    Text(rankingSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    CacheRankingCheckmark(
                        isOn: scope == .sessions ? $excludesSingleTurnSessions : $excludesFirstTurns,
                        title: scope == .sessions ? "排除单轮会话" : "排除首轮"
                    )

                    Picker("", selection: $scope) {
                        ForEach(CacheRankingScope.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                    .accessibilityLabel("缓存命中排行类型")
                    .accessibilityValue(scope.rawValue)
                }
            }

            if rankingItems.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                    Text("暂无可排行的缓存命中数据")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(AppTheme.insetBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("缓存命中排行")
                .accessibilityValue("暂无可排行的缓存命中数据")
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(rankingItems.enumerated()), id: \.element.id) { index, item in
                        CacheRankingRow(rank: index + 1, item: item)
                    }
                }
            }
        }
        .frame(maxWidth: 980)
    }

    private var rankingItems: [CacheRankingItem] {
        let source: [CacheRankingItem]
        switch scope {
        case .sessions:
            source = cacheUsage.sessions
                .filter { !excludesSingleTurnSessions || $0.breakdown.calls > 1 }
                .map { session in
                    CacheRankingItem(
                        id: session.id,
                        title: session.title,
                        subtitle: sessionSubtitle(session),
                        context: nil,
                        breakdown: session.breakdown
                    )
                }
        case .turns:
            source = cacheUsage.turns
                .filter { !excludesFirstTurns || $0.turnIndexInSession > 1 }
                .map { turn in
                    let time = DateFormatter.monthDayHourMinute.string(from: turn.timestamp)
                    return CacheRankingItem(
                        id: turn.id,
                        title: "问：\(turn.userPrompt.isEmpty ? "暂无可见问题" : turn.userPrompt)",
                        subtitle: "答：\(turn.assistantResponse.isEmpty ? "暂无可见回答" : turn.assistantResponse)",
                        context: "\(turn.sessionTitle) · 第 \(turn.turnIndexInSession) 轮 · \(time)",
                        breakdown: turn.breakdown
                    )
                }
        }

        return source
            .filter { $0.breakdown.inputTokens >= minimumInputTokens && $0.breakdown.calls > 0 }
            .sorted { lhs, rhs in
                let leftRate = lhs.breakdown.cacheHitRate
                let rightRate = rhs.breakdown.cacheHitRate
                if abs(leftRate - rightRate) > 0.0001 {
                    return leftRate < rightRate
                }
                return lhs.breakdown.uncachedInputTokens > rhs.breakdown.uncachedInputTokens
            }
            .prefix(10)
            .map { $0 }
    }

    private var rankingSubtitle: String {
        switch scope {
        case .sessions:
            return excludesSingleTurnSessions ? "低命中优先 · 已排除只有一轮的会话" : "低命中优先 · 包含单轮会话"
        case .turns:
            return excludesFirstTurns ? "低命中优先 · 已排除每个会话首轮" : "低命中优先 · 包含首轮"
        }
    }

    private func sessionSubtitle(_ session: SessionCacheUsage) -> String {
        let time = session.lastUpdated.map { DateFormatter.monthDayHourMinute.string(from: $0) } ?? "未知时间"
        return "\(session.breakdown.calls) 轮 · \(time)"
    }
}

private struct CacheRankingCheckmark: View {
    @Binding var isOn: Bool
    let title: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? AppTheme.accentBlue : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(AppTheme.raisedBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isOn ? AppTheme.accentBlue.opacity(0.25) : AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint("切换排行过滤条件")
    }
}

private struct CacheRankingRow: View {
    let rank: Int
    let item: CacheRankingItem

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.accentBlue)
                .frame(width: 21, height: 21)
                .background(AppTheme.accentBlue.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let context = item.context {
                    Text(context)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CacheHitMeter(breakdown: item.breakdown)
                .frame(width: 154)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.breakdown.cacheHitRate.percentString)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.cacheHitColor(rate: item.breakdown.cacheHitRate))
                Text("未命中 \(item.breakdown.uncachedInputTokens.abbreviatedTokens)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("缓存命中排行第 \(rank) 名，\(item.title)")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [
            item.subtitle,
            "命中率 \(item.breakdown.cacheHitRate.percentString)",
            "输入 \(item.breakdown.inputTokens.abbreviatedTokens)",
            "命中 \(item.breakdown.cachedInputTokens.abbreviatedTokens)",
            "未命中 \(item.breakdown.uncachedInputTokens.abbreviatedTokens)",
            "\(item.breakdown.calls) 次调用"
        ]
        if let context = item.context {
            parts.insert(context, at: 1)
        }
        return parts.joined(separator: "；")
    }
}

private struct CacheHitMeter: View {
    let breakdown: TokenCacheBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.insetBackground)
                    Capsule()
                        .fill(AppTheme.cacheHitColor(rate: breakdown.cacheHitRate))
                        .frame(width: proxy.size.width * CGFloat(max(0, min(1, breakdown.cacheHitRate))))
                    Capsule()
                        .stroke(AppTheme.border, lineWidth: 1)
                }
            }
            .frame(height: 7)

            HStack(spacing: 6) {
                Text("命中 \(breakdown.cachedInputTokens.abbreviatedTokens)")
                Text("输入 \(breakdown.inputTokens.abbreviatedTokens)")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("缓存命中比例")
        .accessibilityValue("\(breakdown.cacheHitRate.percentString)，命中 \(breakdown.cachedInputTokens.abbreviatedTokens)，输入 \(breakdown.inputTokens.abbreviatedTokens)")
    }
}
