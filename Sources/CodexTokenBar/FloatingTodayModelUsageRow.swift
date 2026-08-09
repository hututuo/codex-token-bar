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
    let color: Color

    func valueText(for page: FloatingTodayModelUsagePage) -> String {
        switch page {
        case .share:
            return "\(Int((share * 100).rounded()))%"
        case .cost:
            if usesIndependentQuota { return "独立" }
            return (costUSD ?? 0).quotaEstimatorMoneyText
        }
    }
}

enum FloatingTodayModelUsagePresentation {
    /// Keep the compact model strip useful even when the current day only
    /// contains one model. Spark is intentionally not part of this default
    /// paid-model set: it has its own quota and remains an explicit row only
    /// when the source actually reports Spark usage.
    static let defaultModelKeys = [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.4",
    ]

    static func items(
        from rows: [ModelTokenBreakdown],
        fallbackModel: OfficialAPIPriceModel,
        showPlaceholders: Bool = false
    ) -> [FloatingTodayModelUsageItem] {
        let combined = ModelUsagePresentation.combinedRows(rows)
        let total = combined.reduce(0) { $0 + $1.breakdown.totalTokens }
        guard total > 0 || showPlaceholders else { return [] }

        var rowsByKey = Dictionary(uniqueKeysWithValues: combined.map { row in
            (ModelUsagePresentation.key(for: row.model), row)
        })
        if showPlaceholders {
            for key in defaultModelKeys where rowsByKey[key] == nil {
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
            let priceModel = OfficialAPIPriceModel.detected(from: row.model) ?? fallbackModel
            let costUSD = independent ? nil : priceModel.currentPriceRates.costUSD(for: row.breakdown)
            return (
                item: FloatingTodayModelUsageItem(
                    id: key,
                    label: ModelUsagePresentation.label(for: row.model),
                    tokens: row.breakdown.totalTokens,
                    share: total > 0 ? Double(row.breakdown.totalTokens) / Double(total) : 0,
                    costUSD: costUSD,
                    usesIndependentQuota: independent,
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
            // both pages. Independent-quota Spark has no dollar value, so it
            // follows priced usage but remains ahead of zero placeholders.
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

    static func accessibilityText(
        page: FloatingTodayModelUsagePage,
        rows: [ModelTokenBreakdown],
        fallbackModel: OfficialAPIPriceModel,
        showPlaceholders: Bool = false
    ) -> String {
        let items = items(
            from: rows,
            fallbackModel: fallbackModel,
            showPlaceholders: showPlaceholders
        )
        guard !items.isEmpty else { return "今日模型待读取" }
        let detail = items.map { "\($0.label) \($0.valueText(for: page))" }
            .joined(separator: "，")
        return "今日模型\(page.compactTitle)：\(detail)"
    }
}

struct FloatingTodayModelUsageRow: View {
    let page: FloatingTodayModelUsagePage
    let rows: [ModelTokenBreakdown]
    let fallbackModel: OfficialAPIPriceModel
    let showPlaceholders: Bool

    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette

    var body: some View {
        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: fallbackModel,
            showPlaceholders: showPlaceholders
        )
        HStack(spacing: 5.scaled(by: displayScale)) {
            if items.isEmpty {
                Text("今日模型待读取")
                    .font(.system(size: 9.2.scaled(by: displayScale), weight: .medium))
                    .foregroundStyle(textPalette.secondaryColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 6.scaled(by: displayScale)) {
                    ForEach(Array(items.prefix(4))) { item in
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
                    }
                    if items.count > 4 {
                        Text("+\(items.count - 4)")
                            .font(.system(size: 7.8.scaled(by: displayScale), weight: .semibold))
                            .foregroundStyle(textPalette.mutedColor)
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
                rows: rows,
                fallbackModel: fallbackModel,
                showPlaceholders: showPlaceholders
            )
        )
    }
}
