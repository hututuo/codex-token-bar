import SwiftUI

private enum CacheRankingScope: String, CaseIterable, Identifiable {
    case sessions = "会话"
    case turns = "单轮"

    var id: String { rawValue }
}

enum CacheRankingSortOrder: String, CaseIterable, Identifiable {
    case lowHit = "低命中"
    case latest = "最新"

    var id: String { rawValue }

    var subtitlePrefix: String {
        switch self {
        case .lowHit:
            return "低命中优先"
        case .latest:
            return "最新优先"
        }
    }

    func sortsBefore(_ lhs: CacheRankingSortValue, _ rhs: CacheRankingSortValue) -> Bool {
        switch self {
        case .lowHit:
            return Self.lowHitSortsBefore(lhs, rhs)
        case .latest:
            switch (lhs.sortDate, rhs.sortDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return Self.lowHitSortsBefore(lhs, rhs)
            }
        }
    }

    private static func lowHitSortsBefore(_ lhs: CacheRankingSortValue, _ rhs: CacheRankingSortValue) -> Bool {
        let leftRate = lhs.breakdown.cacheHitRate
        let rightRate = rhs.breakdown.cacheHitRate
        if abs(leftRate - rightRate) > 0.0001 {
            return leftRate < rightRate
        }
        if lhs.breakdown.uncachedInputTokens != rhs.breakdown.uncachedInputTokens {
            return lhs.breakdown.uncachedInputTokens > rhs.breakdown.uncachedInputTokens
        }
        switch (lhs.sortDate, rhs.sortDate) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }
}

struct CacheRankingSortValue: Equatable {
    let id: String
    let sortDate: Date?
    let breakdown: TokenCacheBreakdown
}

struct CacheRankingPagingState: Equatable {
    static let pageSize = 10
    private(set) var requestedCount = pageSize

    func visibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), requestedCount)
    }

    func hasMore(totalCount: Int) -> Bool {
        visibleCount(totalCount: totalCount) < max(totalCount, 0)
    }

    mutating func loadMore(totalCount: Int) {
        requestedCount = min(
            max(totalCount, 0),
            requestedCount + Self.pageSize
        )
    }

    mutating func reset() {
        requestedCount = Self.pageSize
    }
}

private enum CacheRankingPolicy {
    static let minimumInputTokens = 1_000
}

private struct CacheRankingItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let context: String?
    let sortDate: Date?
    let breakdown: TokenCacheBreakdown

    var sortValue: CacheRankingSortValue {
        CacheRankingSortValue(id: id, sortDate: sortDate, breakdown: breakdown)
    }
}

enum CacheRankingSearchMatcher {
    static func matches(
        query: String,
        title: String,
        subtitle: String,
        context: String?
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return [title, subtitle, context ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

private enum CacheRankingItemsBuilder {
    static func build(
        cacheUsage: TokenCacheUsage,
        scope: CacheRankingScope,
        sortOrder: CacheRankingSortOrder,
        excludesSingleTurnSessions: Bool,
        excludesFirstTurns: Bool,
        searchText: String = ""
    ) -> [CacheRankingItem] {
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
                        sortDate: session.lastUpdated,
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
                        sortDate: turn.timestamp,
                        breakdown: turn.breakdown
                    )
                }
        }

        return source
            .filter {
                $0.breakdown.inputTokens >= CacheRankingPolicy.minimumInputTokens
                    && $0.breakdown.calls > 0
                    && CacheRankingSearchMatcher.matches(
                        query: searchText,
                        title: $0.title,
                        subtitle: $0.subtitle,
                        context: $0.context
                    )
            }
            .sorted { sortOrder.sortsBefore($0.sortValue, $1.sortValue) }
    }

    private static func sessionSubtitle(_ session: SessionCacheUsage) -> String {
        let time = session.lastUpdated.map {
            DateFormatter.monthDayHourMinute.string(from: $0)
        } ?? "未知时间"
        return "\(session.breakdown.calls) 轮 · \(time)"
    }
}

struct CacheHitRankingSection: View {
    let cacheUsage: TokenCacheUsage
    let cacheUsageRevision: Date
    let onOpenDetails: () -> Void
    @State private var scope: CacheRankingScope = .turns
    @State private var sortOrder: CacheRankingSortOrder = .latest
    @State private var excludesSingleTurnSessions = true
    @State private var excludesFirstTurns = true

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
                    CacheRankingControls(
                        scope: $scope,
                        sortOrder: $sortOrder,
                        excludesSingleTurnSessions: $excludesSingleTurnSessions,
                        excludesFirstTurns: $excludesFirstTurns
                    )

                    Button(action: onOpenDetails) {
                        Label("查看完整排行", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityValue("外层保留前 10 条，详情支持搜索和分批加载")
                }
            }

            CacheRankingTopTenList(
                cacheUsage: cacheUsage,
                cacheUsageRevision: cacheUsageRevision,
                scope: scope,
                sortOrder: sortOrder,
                excludesSingleTurnSessions: excludesSingleTurnSessions,
                excludesFirstTurns: excludesFirstTurns
            )
            .equatable()
        }
        .frame(maxWidth: 980)
    }

    private var rankingSubtitle: String {
        CacheRankingSubtitle.text(
            scope: scope,
            sortOrder: sortOrder,
            excludesSingleTurnSessions: excludesSingleTurnSessions,
            excludesFirstTurns: excludesFirstTurns
        )
    }
}

private struct CacheRankingTopTenList: View, Equatable {
    let cacheUsage: TokenCacheUsage
    let cacheUsageRevision: Date
    let scope: CacheRankingScope
    let sortOrder: CacheRankingSortOrder
    let excludesSingleTurnSessions: Bool
    let excludesFirstTurns: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cacheUsageRevision == rhs.cacheUsageRevision
            && lhs.cacheUsage.sessions.count == rhs.cacheUsage.sessions.count
            && lhs.cacheUsage.turns.count == rhs.cacheUsage.turns.count
            && lhs.scope == rhs.scope
            && lhs.sortOrder == rhs.sortOrder
            && lhs.excludesSingleTurnSessions == rhs.excludesSingleTurnSessions
            && lhs.excludesFirstTurns == rhs.excludesFirstTurns
    }

    var body: some View {
        let rankingItems = CacheRankingItemsBuilder.build(
            cacheUsage: cacheUsage,
            scope: scope,
            sortOrder: sortOrder,
            excludesSingleTurnSessions: excludesSingleTurnSessions,
            excludesFirstTurns: excludesFirstTurns
        )

        if rankingItems.isEmpty {
            CacheRankingEmptyState(message: "暂无可排行的缓存命中数据")
        } else {
            VStack(spacing: 5) {
                ForEach(Array(rankingItems.prefix(10).enumerated()), id: \.element.id) { index, item in
                    CacheRankingRow(rank: index + 1, item: item)
                }
            }
        }
    }
}

struct CacheHitRankingDetailView: View {
    let cacheUsage: TokenCacheUsage
    let onClose: () -> Void
    @State private var scope: CacheRankingScope = .turns
    @State private var sortOrder: CacheRankingSortOrder = .latest
    @State private var excludesSingleTurnSessions = true
    @State private var excludesFirstTurns = true
    @State private var searchText = ""
    @State private var paging = CacheRankingPagingState()

    var body: some View {
        let allRankingItems = CacheRankingItemsBuilder.build(
            cacheUsage: cacheUsage,
            scope: scope,
            sortOrder: sortOrder,
            excludesSingleTurnSessions: excludesSingleTurnSessions,
            excludesFirstTurns: excludesFirstTurns,
            searchText: searchText
        )
        let visibleRankingItems = Array(
            allRankingItems.prefix(
                paging.visibleCount(totalCount: allRankingItems.count)
            )
        )

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("缓存命中排行")
                        .font(.system(size: 19, weight: .semibold))
                    Text(rankingSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(AppTheme.raisedBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭缓存命中排行")
            }

            CacheRankingControls(
                scope: scopeBinding,
                sortOrder: sortOrderBinding,
                excludesSingleTurnSessions: Binding(
                    get: { excludesSingleTurnSessions },
                    set: {
                        paging.reset()
                        excludesSingleTurnSessions = $0
                    }
                ),
                excludesFirstTurns: Binding(
                    get: { excludesFirstTurns },
                    set: {
                        paging.reset()
                        excludesFirstTurns = $0
                    }
                )
            )

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索会话、问题、回答或上下文", text: searchBinding)
                    .textFieldStyle(.roundedBorder)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        paging.reset()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空排行搜索")
                }
            }

            Divider()

            if allRankingItems.isEmpty {
                CacheRankingEmptyState(
                    message: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "暂无可排行的缓存命中数据"
                        : "没有匹配“\(searchText)”的排行结果"
                )
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(visibleRankingItems.enumerated()), id: \.element.id) { index, item in
                            CacheRankingRow(rank: index + 1, item: item)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(minHeight: 220)

                HStack(spacing: 12) {
                    Text("已显示 \(visibleRankingItems.count) / 共 \(allRankingItems.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if paging.hasMore(totalCount: allRankingItems.count) {
                        Button {
                            paging.loadMore(totalCount: allRankingItems.count)
                        } label: {
                            Label(
                                "继续加载 \(min(CacheRankingPagingState.pageSize, allRankingItems.count - visibleRankingItems.count)) 条",
                                systemImage: "arrow.down.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("在当前排行后继续显示下一批结果")
                    } else {
                        Label("已全部加载", systemImage: "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 900, minHeight: 430, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var scopeBinding: Binding<CacheRankingScope> {
        Binding(
            get: { scope },
            set: {
                paging.reset()
                scope = $0
            }
        )
    }

    private var sortOrderBinding: Binding<CacheRankingSortOrder> {
        Binding(
            get: { sortOrder },
            set: {
                paging.reset()
                sortOrder = $0
            }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchText },
            set: {
                paging.reset()
                searchText = $0
            }
        )
    }

    private var rankingSubtitle: String {
        CacheRankingSubtitle.text(
            scope: scope,
            sortOrder: sortOrder,
            excludesSingleTurnSessions: excludesSingleTurnSessions,
            excludesFirstTurns: excludesFirstTurns
        )
    }
}

private enum CacheRankingSubtitle {
    static func text(
        scope: CacheRankingScope,
        sortOrder: CacheRankingSortOrder,
        excludesSingleTurnSessions: Bool,
        excludesFirstTurns: Bool
    ) -> String {
        switch scope {
        case .sessions:
            return excludesSingleTurnSessions
                ? "\(sortOrder.subtitlePrefix) · 已排除只有一轮的会话"
                : "\(sortOrder.subtitlePrefix) · 包含单轮会话"
        case .turns:
            return excludesFirstTurns
                ? "\(sortOrder.subtitlePrefix) · 已排除每个会话首轮"
                : "\(sortOrder.subtitlePrefix) · 包含首轮"
        }
    }
}

private struct CacheRankingControls: View {
    @Binding var scope: CacheRankingScope
    @Binding var sortOrder: CacheRankingSortOrder
    @Binding var excludesSingleTurnSessions: Bool
    @Binding var excludesFirstTurns: Bool

    var body: some View {
        HStack(spacing: 8) {
            CacheRankingCheckmark(
                isOn: scope == .sessions
                    ? $excludesSingleTurnSessions
                    : $excludesFirstTurns,
                title: scope == .sessions ? "排除单轮会话" : "排除首轮"
            )

            Picker("", selection: $sortOrder) {
                ForEach(CacheRankingSortOrder.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 126)
            .accessibilityLabel("缓存命中排行排序")
            .accessibilityValue(sortOrder.rawValue)

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
}

private struct CacheRankingEmptyState: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
            Text(message)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(
            AppTheme.insetBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("缓存命中排行")
        .accessibilityValue(message)
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
            .help(rankingHoverText)
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

    private var rankingHoverText: String {
        [item.title, item.subtitle, item.context]
            .compactMap { $0 }
            .joined(separator: "\n")
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
