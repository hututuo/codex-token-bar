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
    static func items(
        from rows: [ModelTokenBreakdown],
        fallbackModel: OfficialAPIPriceModel
    ) -> [FloatingTodayModelUsageItem] {
        let combined = ModelUsagePresentation.combinedRows(rows)
            .filter { $0.breakdown.totalTokens > 0 }
        let total = combined.reduce(0) { $0 + $1.breakdown.totalTokens }
        guard total > 0 else { return [] }

        return combined.map { row in
            let key = ModelUsagePresentation.key(for: row.model)
            let independent = OfficialAPIPriceModel.independentQuotaModelName(from: row.model) != nil
            let priceModel = OfficialAPIPriceModel.detected(from: row.model) ?? fallbackModel
            return FloatingTodayModelUsageItem(
                id: key,
                label: ModelUsagePresentation.label(for: row.model),
                tokens: row.breakdown.totalTokens,
                share: Double(row.breakdown.totalTokens) / Double(total),
                costUSD: independent ? nil : priceModel.currentPriceRates.costUSD(for: row.breakdown),
                usesIndependentQuota: independent,
                color: ModelUsagePresentation.color(for: row.model)
            )
        }
        .sorted { lhs, rhs in
            lhs.tokens == rhs.tokens ? lhs.label < rhs.label : lhs.tokens > rhs.tokens
        }
    }

    static func accessibilityText(
        page: FloatingTodayModelUsagePage,
        rows: [ModelTokenBreakdown],
        fallbackModel: OfficialAPIPriceModel
    ) -> String {
        let items = items(from: rows, fallbackModel: fallbackModel)
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

    @Environment(\.tokenDisplayScale) private var displayScale
    @Environment(\.tokenDisplayTextPalette) private var textPalette

    var body: some View {
        let items = FloatingTodayModelUsagePresentation.items(
            from: rows,
            fallbackModel: fallbackModel
        )
        HStack(spacing: 5.scaled(by: displayScale)) {
            Text(page.compactTitle)
                .font(.system(size: 7.8.scaled(by: displayScale), weight: .semibold))
                .foregroundStyle(textPalette.mutedColor)
                .frame(width: 24.scaled(by: displayScale), alignment: .leading)

            if items.isEmpty {
                Text("今日模型待读取")
                    .font(.system(size: 9.2.scaled(by: displayScale), weight: .medium))
                    .foregroundStyle(textPalette.secondaryColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 6.scaled(by: displayScale)) {
                    ForEach(Array(items.prefix(3))) { item in
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
                    if items.count > 3 {
                        Text("+\(items.count - 3)")
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
                fallbackModel: fallbackModel
            )
        )
    }
}
