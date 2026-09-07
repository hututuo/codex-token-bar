import Foundation
import SwiftUI

enum FloatingTodayModelUsagePage: String, Equatable, Sendable {
    case share
    case cost

    var compactTitle: String {
        switch self {
        case .share: "占比"
        case .cost: "费用"
        }
    }
}

struct FloatingTodayModelUsageItem: Identifiable, Equatable {
    let id: String
    let label: String
    let tokens: Int
    let share: Double
    let costUSD: Double?
    let usesIndependentQuota: Bool
    let referenceCostUSD: Double?
    let color: Color

    func valueText(for page: FloatingTodayModelUsagePage) -> String {
        switch page {
        case .share:
            let percent = max(0, share) * 100
            if percent > 0, percent < 0.1 { return "<0.1%" }
            if percent > 0, percent < 10 { return String(format: "%.1f%%", percent) }
            return "\(Int(percent.rounded()))%"
        case .cost:
            if usesIndependentQuota {
                let referenceCost = referenceCostUSD?.quotaEstimatorMoneyText ?? "—"
                return "\(referenceCost)（不计入总计）"
            }
            guard let costUSD else { return "价格未知" }
            return costUSD.quotaEstimatorMoneyText
        }
    }
}

enum FloatingTodayModelUsagePresentation {
    static let visibleItemLimit = 4
    static let minimumVisibleModelCount = 4
    static let dashboardPrimaryModelKeys = [
        "gpt-6-astra",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    ]

    /// Keep the compact model strip useful even when the current day only
    /// contains one model. Astra/Sol/Terra/Luna are the stable placeholder
    /// priority list, but only enough zero rows are added to reach four total
    /// visible models. Other models are added only when the source actually
    /// reports them. Spark is intentionally not part of this default paid-model
    /// set because it has its own quota.
    static let defaultModelKeys = [
        "gpt-6-astra",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    ]

    /// UI-only values used while the first precise model read is still pending
    /// during the paging guide. They never enter a snapshot, index, or cost
    /// calculation and disappear as soon as the guide is completed.
    static let guideDemoRows: [ModelTokenBreakdown] = [
        ModelTokenBreakdown(
            model: "gpt-5.6-sol",
            breakdown: TokenCacheBreakdown(
                inputTokens: 4_400_000,
                cachedInputTokens: 2_300_000,
                outputTokens: 800_000,
                reasoningOutputTokens: 0,
                totalTokens: 5_200_000,
                calls: 18
            )
        ),
        ModelTokenBreakdown(
            model: "gpt-5.6-luna",
            breakdown: TokenCacheBreakdown(
                inputTokens: 2_800_000,
                cachedInputTokens: 1_200_000,
                outputTokens: 500_000,
                reasoningOutputTokens: 0,
                totalTokens: 3_300_000,
                calls: 11
            )
        ),
        ModelTokenBreakdown(
            model: "gpt-5.6-terra",
            breakdown: TokenCacheBreakdown(
                inputTokens: 1_200_000,
                cachedInputTokens: 600_000,
                outputTokens: 300_000,
                reasoningOutputTokens: 0,
                totalTokens: 1_500_000,
                calls: 6
            )
        ),
    ]

    static func rowsForFloatingWindow(
        from rows: [ModelTokenBreakdown],
        mergeAutoReview: Bool
    ) -> [ModelTokenBreakdown] {
        let presentationRows = ModelUsagePresentation.rowsWithDatedAutoReviewTargets(from: rows)
        guard mergeAutoReview else { return presentationRows }
        return presentationRows.map { row in
            guard let targetKey = ModelUsagePresentation.autoReviewUnderlyingModelKey(for: row.model) else {
                return row
            }
            return ModelTokenBreakdown(
                model: targetKey,
                breakdown: row.breakdown,
                pricePeriods: row.pricingRows
            )
        }
    }

    static func items(
        from rows: [ModelTokenBreakdown],
        fallbackModel: OfficialAPIPriceModel,
        showPlaceholders: Bool = false,
        mergeAutoReview: Bool = false
    ) -> [FloatingTodayModelUsageItem] {
        // The dashboard keeps dated Auto Review rows visible. The compact
        // floating window opts into merging them into their underlying model
        // so a dated 5.4/Luna route consumes the same model slot as its normal
        // row while retaining each input's pricing periods.
        let floatingRows = rowsForFloatingWindow(
            from: rows,
            mergeAutoReview: mergeAutoReview
        )
        let combined = ModelUsagePresentation.combinedRows(floatingRows)
        let total = combined.reduce(0) { $0 + $1.breakdown.totalTokens }
        guard total > 0 || showPlaceholders else { return [] }

        var rowsByKey = Dictionary(uniqueKeysWithValues: combined.map { row in
            (ModelUsagePresentation.key(for: row.model), row)
        })
        if showPlaceholders {
            for key in defaultModelKeys
                where rowsByKey.count < minimumVisibleModelCount && rowsByKey[key] == nil {
                rowsByKey[key] = ModelTokenBreakdown(
                    model: key,
                    breakdown: .empty
                )
            }
        }

        let defaultOrder = Dictionary(
            uniqueKeysWithValues: defaultModelKeys.enumerated().map { ($1, $0) }
        )
        return rowsByKey.map { key, row in
            let independent = OfficialAPIPriceModel.independentQuotaModelName(from: row.model) != nil
            let costUSD: Double?
            if independent {
                costUSD = nil
            } else {
                let estimate = ModelAwareAPIPriceEstimator.estimate(
                    modelBreakdowns: [row],
                    fallbackBreakdown: row.breakdown,
                    fallbackModel: fallbackModel,
                    standardAPI: true,
                    rates: { $0.currentPriceRates }
                )
                costUSD = estimate.unpricedModels.isEmpty ? estimate.costUSD : nil
            }
            let referenceCostUSD = IndependentQuotaReferencePricing.costUSD(
                for: row.model,
                breakdown: row.breakdown
            )
            return (
                item: FloatingTodayModelUsageItem(
                    id: key,
                    label: ModelUsagePresentation.label(for: row.model),
                    tokens: row.breakdown.totalTokens,
                    share: total > 0 ? Double(row.breakdown.totalTokens) / Double(total) : 0,
                    costUSD: costUSD,
                    usesIndependentQuota: independent,
                    referenceCostUSD: referenceCostUSD,
                    color: ModelUsagePresentation.color(for: row.model)
                ),
                defaultIndex: defaultOrder[key] ?? defaultModelKeys.count,
                key: key
            )
        }
        .sorted { lhs, rhs in
            let lhsUsed = lhs.item.tokens > 0
            let rhsUsed = rhs.item.tokens > 0
            if lhsUsed != rhsUsed { return lhsUsed }

            // Paid models are ordered by the same daily dollar estimate on
            // both pages. Independent-quota Spark has no billable dollar
            // value in the primary total; its reference price is shown below
            // the total and does not affect this order.
            let lhsCost = lhs.item.costUSD ?? 0
            let rhsCost = rhs.item.costUSD ?? 0
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            if lhs.item.usesIndependentQuota != rhs.item.usesIndependentQuota {
                return !lhs.item.usesIndependentQuota
            }
            if lhs.defaultIndex != rhs.defaultIndex {
                return lhs.defaultIndex < rhs.defaultIndex
            }
            return lhs.key < rhs.key
        }
        .map(\.item)
    }

    /// The cost page can continue onto additional pages instead of hiding
    /// models behind a `+N` marker.  The share page keeps its compact summary
    /// behavior because it is intentionally a single glanceable page.
    static func pageCount(
        for page: FloatingTodayModelUsagePage,
        items: [FloatingTodayModelUsageItem]
    ) -> Int {
        guard page == .cost, !items.isEmpty else { return 1 }
        return max(1, pageSizes(for: items.count).count)
    }

    /// Splits model amounts into balanced pages with at most four items per
    /// page. This keeps 5/6/7/8 models as 3+2, 3+3, 4+3 and 4+4 instead of
    /// producing an almost-empty last page such as 4+1.
    static func pageSizes(for itemCount: Int) -> [Int] {
        let count = max(itemCount, 0)
        guard count > visibleItemLimit else {
            return count == 0 ? [] : [count]
        }

        let pageCount = Int(ceil(Double(count) / Double(visibleItemLimit)))
        let baseSize = count / pageCount
        let remainder = count % pageCount
        return (0..<pageCount).map { index in
            baseSize + (index < remainder ? 1 : 0)
        }
    }

    static func pageItems(
        for page: FloatingTodayModelUsagePage,
        items: [FloatingTodayModelUsageItem],
        pageIndex: Int
    ) -> [FloatingTodayModelUsageItem] {
        guard page == .cost else {
            return Array(items.prefix(visibleItemLimit))
        }

        let sizes = pageSizes(for: items.count)
        guard !sizes.isEmpty else { return [] }
        let safePageIndex = min(max(pageIndex, 0), sizes.count - 1)
        let start = sizes.prefix(safePageIndex).reduce(0, +)
        return Array(items.dropFirst(start).prefix(sizes[safePageIndex]))
    }

    static func accessibilityText(
        page: FloatingTodayModelUsagePage,
        rows: [ModelTokenBreakdown],
        fallbackModel: OfficialAPIPriceModel,
        showPlaceholders: Bool = false,
        mergeAutoReview: Bool = false
    ) -> String {
        let items = items(
            from: rows,
            fallbackModel: fallbackModel,
            showPlaceholders: showPlaceholders,
            mergeAutoReview: mergeAutoReview
        )
        guard !items.isEmpty else { return "今日模型待读取" }
        let detail = items.map { "\($0.label) \($0.valueText(for: page))" }
            .joined(separator: "，")
        return "今日模型\(page.compactTitle)：\(detail)"
    }

    static func dashboardPrimaryItems(
        from items: [FloatingTodayModelUsageItem]
    ) -> [FloatingTodayModelUsageItem] {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return dashboardPrimaryModelKeys.map { key in
            byID[key] ?? dashboardPlaceholder(for: key)
        }
    }

    static func dashboardSecondaryItems(
        from items: [FloatingTodayModelUsageItem]
    ) -> [FloatingTodayModelUsageItem] {
        let primaryIDs = Set(dashboardPrimaryModelKeys)
        return items.filter { !primaryIDs.contains($0.id) && $0.tokens > 0 }
    }

    private static func dashboardPlaceholder(
        for key: String
    ) -> FloatingTodayModelUsageItem {
        FloatingTodayModelUsageItem(
            id: key,
            label: ModelUsagePresentation.label(for: key),
            tokens: 0,
            share: 0,
            costUSD: 0,
            usesIndependentQuota: false,
            referenceCostUSD: nil,
            color: ModelUsagePresentation.color(for: key)
        )
    }

    static func overflowDetailText(
        items: [FloatingTodayModelUsageItem],
        visibleLimit: Int = visibleItemLimit
    ) -> String? {
        let hiddenItems = items.dropFirst(max(visibleLimit, 0))
        guard !hiddenItems.isEmpty else { return nil }

        let details = hiddenItems.map { item in
            let cost = item.usesIndependentQuota
                ? "\(item.referenceCostUSD?.quotaEstimatorMoneyText ?? "—")（不计入总计）"
                : (item.costUSD ?? 0).quotaEstimatorMoneyText
            return "\(item.label) · \(item.tokens.abbreviatedTokens) tokens · 占比 \(detailedShareText(item.share)) · \(cost)"
        }
        return (["更多模型"] + details).joined(separator: "\n")
    }

    private static func detailedShareText(_ share: Double) -> String {
        let percent = max(0, share) * 100
        if percent > 0, percent < 0.1 {
            return "<0.1%"
        }
        if percent < 10, percent.rounded() != percent {
            return String(format: "%.1f%%", percent)
        }
        return "\(Int(percent.rounded()))%"
    }
}

struct FloatingTodayModelUsageRow: View {
    let page: FloatingTodayModelUsagePage
    let rows: [ModelTokenBreakdown]
    let fallbackModel: OfficialAPIPriceModel
    let showPlaceholders: Bool
    var isGuideDemo = false
    var pageIndex = 0

    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette

    var body: some View {
        let usesGuideDemo = isGuideDemo
        let displayRows = usesGuideDemo
            ? FloatingTodayModelUsagePresentation.guideDemoRows
            : rows
        let allItems = FloatingTodayModelUsagePresentation.items(
            from: displayRows,
            fallbackModel: fallbackModel,
            showPlaceholders: showPlaceholders,
            mergeAutoReview: true
        )
        let items = FloatingTodayModelUsagePresentation.pageItems(
            for: page,
            items: allItems,
            pageIndex: pageIndex
        )
        let visibleLimit = FloatingTodayModelUsagePresentation.visibleItemLimit
        let overflowDetail = page == .share
            ? FloatingTodayModelUsagePresentation.overflowDetailText(
                items: allItems,
                visibleLimit: visibleLimit
            )
            : nil
        HStack(spacing: 5.scaled(by: displayScale)) {
            if allItems.isEmpty {
                Text("今日模型待读取")
                    .font(.system(size: 9.2.scaled(by: displayScale), weight: .medium))
                    .foregroundStyle(textPalette.secondaryColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                if usesGuideDemo {
                    Text("示例")
                        .font(.system(size: 7.2.scaled(by: displayScale), weight: .semibold))
                        .foregroundStyle(textPalette.secondaryColor.opacity(0.86))
                        .help("仅用于引导展示，不会写入真实统计")
                }
                let visibleItems = Array(items.prefix(visibleLimit))
                let hasOverflow = page == .share && allItems.count > visibleLimit

                // Use flexible columns instead of a fixed cost-page gap. The
                // old 10pt gap was added three times for four models, so the
                // last amount could be pushed outside the compact panel. Each
                // column now receives the available width; the gap naturally
                // grows when there are fewer models and collapses when there
                // are four (or an overflow marker) to keep every value visible.
                HStack(spacing: 0) {
                    ForEach(visibleItems) { item in
                        modelItemView(item, page: page)
                    }
                    if hasOverflow {
                        Text("+\(allItems.count - visibleLimit)")
                            .font(.system(size: 7.8.scaled(by: displayScale), weight: .semibold))
                            .foregroundStyle(textPalette.mutedColor)
                            .help(overflowDetail ?? "更多模型")
                            .accessibilityLabel(overflowDetail ?? "更多模型")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            FloatingTodayModelUsagePresentation.accessibilityText(
                page: page,
                rows: displayRows,
                fallbackModel: fallbackModel,
                showPlaceholders: showPlaceholders,
                mergeAutoReview: true
            ) + (usesGuideDemo ? "（示例，仅用于引导展示）" : "")
        )
    }

    @ViewBuilder
    private func modelItemView(
        _ item: FloatingTodayModelUsageItem,
        page: FloatingTodayModelUsagePage
    ) -> some View {
        HStack(spacing: 2.scaled(by: displayScale)) {
            Circle()
                .fill(item.color)
                .frame(
                    width: 4.scaled(by: displayScale),
                    height: 4.scaled(by: displayScale)
                )
            Text(item.label)
                .foregroundStyle(textPalette.secondaryColor)
            Text(item.valueText(for: page))
                .foregroundStyle(textPalette.primaryColor)
                .monospacedDigit()
        }
        .font(.system(size: 8.4.scaled(by: displayScale), weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ModelCostInlineSummary: View {
    let rows: [ModelTokenBreakdown]
    let fallbackModel: OfficialAPIPriceModel
    var limit = 3

    var body: some View {
        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: fallbackModel
        )
        HStack(spacing: 7) {
            ForEach(Array(items.prefix(max(limit, 1)))) { item in
                HStack(spacing: 3) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)
                    Text("\(item.label) \(item.valueText(for: .cost))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if items.count > max(limit, 1) {
                Text("+\(items.count - max(limit, 1))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }
}
