import Foundation

/// A pricing projection only: usage facts, raw model aliases and dated price
/// cards stay intact. Free review and separately metered Spark cannot inflate
/// subscription value or quota-drop attribution.
enum QuotaValueExclusion {
    static func modelName(for rawModel: String?) -> String? {
        if CodexAutoReviewPricingPolicy.isAutoReviewUsage(rawModel) { return "codex-auto-review" }
        return OfficialAPIPriceModel.independentQuotaModelName(from: rawModel)
    }
}

enum AutoReviewReferencePricing {
    static func costUSD(for row: ModelTokenBreakdown) -> Double? {
        guard CodexAutoReviewPricingPolicy.isAutoReviewUsage(row.model) else { return nil }
        var total = 0.0
        for period in row.pricingRows {
            guard let model = CodexAutoReviewPricingPolicy.referenceModel(for: period.model, at: period.start)
                    ?? OfficialAPIPriceModel.detected(from: period.model, at: period.start) else { return nil }
            let rates: APIPriceRates
            if let date = period.start {
                guard let quote = StandardAPIPriceSchedule.quote(for: model.title, at: date) else { return nil }
                rates = quote.rates
            } else { rates = model.currentPriceRates }
            total += rates.costUSD(for: period.breakdown)
        }
        return total
    }
}
