import SwiftUI

struct ModelUsageSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let tokens: Int
    let calls: Int
    let share: Double
    let color: Color
}

enum ModelUsagePresentation {
    private static let autoReviewDisplayPrefix = "codex-auto-review@"

    /// Presentation aliases are deliberately narrower than the pricing
    /// detector.  A bare `gpt-5.6` value identifies a family, not Sol, so it
    /// must remain an unknown/raw label until a source supplies the lane.
    private static let knownModelAliases: [String: String] = [
        "gpt-6-astra": "gpt-6-astra",
        "gpt6-astra": "gpt-6-astra",
        "gpt6astra": "gpt-6-astra",
        "gpt 6 astra": "gpt-6-astra",
        "gpt-6.1-sol": "gpt-6.1-sol",
        "gpt6.1-sol": "gpt-6.1-sol",
        "gpt61-sol": "gpt-6.1-sol",
        "gpt61sol": "gpt-6.1-sol",
        "gpt 6.1 sol": "gpt-6.1-sol",
        "gpt-6.1-terra": "gpt-6.1-terra",
        "gpt6.1-terra": "gpt-6.1-terra",
        "gpt61-terra": "gpt-6.1-terra",
        "gpt61terra": "gpt-6.1-terra",
        "gpt 6.1 terra": "gpt-6.1-terra",
        "gpt-6-sol": "gpt-6-sol",
        "gpt6-sol": "gpt-6-sol",
        "gpt6sol": "gpt-6-sol",
        "gpt 6 sol": "gpt-6-sol",
        "gpt-6-luna": "gpt-6-luna",
        "gpt6-luna": "gpt-6-luna",
        "gpt6luna": "gpt-6-luna",
        "gpt 6 luna": "gpt-6-luna",

        "gpt-5.6-sol": "gpt-5.6-sol",
        "gpt5.6-sol": "gpt-5.6-sol",
        "gpt56-sol": "gpt-5.6-sol",
        "gpt56sol": "gpt-5.6-sol",
        "gpt 5.6 sol": "gpt-5.6-sol",

        "gpt-5.5": "gpt-5.5",
        "gpt5.5": "gpt-5.5",
        "gpt55": "gpt-5.5",
        "gpt 5.5": "gpt-5.5",

        "gpt-5.6-terra": "gpt-5.6-terra",
        "gpt5.6-terra": "gpt-5.6-terra",
        "gpt56-terra": "gpt-5.6-terra",
        "gpt56terra": "gpt-5.6-terra",
        "gpt 5.6 terra": "gpt-5.6-terra",

        "gpt-5.6-luna": "gpt-5.6-luna",
        "gpt5.6-luna": "gpt-5.6-luna",
        "gpt56-luna": "gpt-5.6-luna",
        "gpt56luna": "gpt-5.6-luna",
        "gpt 5.6 luna": "gpt-5.6-luna",

        "gpt-5.3-codex": "gpt-5.3-codex",
        "gpt5.3-codex": "gpt-5.3-codex",
        "gpt53-codex": "gpt-5.3-codex",
        "gpt53codex": "gpt-5.3-codex",
        "gpt 5.3 codex": "gpt-5.3-codex",

        "gpt-5.2-codex": "gpt-5.2-codex",
        "gpt5.2-codex": "gpt-5.2-codex",
        "gpt52-codex": "gpt-5.2-codex",
        "gpt52codex": "gpt-5.2-codex",
        "gpt 5.2 codex": "gpt-5.2-codex",

        "gpt-5.4": "gpt-5.4",
        "gpt54": "gpt-5.4",
        "gpt 5.4": "gpt-5.4",

        "gpt-5.4-mini": "gpt-5.4-mini",
        "gpt54mini": "gpt-5.4-mini",
        "gpt 5.4 mini": "gpt-5.4-mini",

        // This synthetic key is retained for old presentation snapshots.
        "gpt-5.6-generic": "gpt-5.6-generic",
    ]

    static func slices(from rows: [ModelTokenBreakdown]) -> [ModelUsageSlice] {
        let combined = combinedRows(rows)
        let total = combined.reduce(0) { $0 + $1.breakdown.totalTokens }
        guard total > 0 else { return [] }

        return combined
            .map { row in
                let key = key(for: row.model)
                return ModelUsageSlice(
                    id: key,
                    label: label(for: row.model),
                    tokens: row.breakdown.totalTokens,
                    calls: row.breakdown.calls,
                    share: Double(row.breakdown.totalTokens) / Double(total),
                    color: color(for: key)
                )
            }
            .sorted { lhs, rhs in
                lhs.tokens == rhs.tokens ? lhs.label < rhs.label : lhs.tokens > rhs.tokens
            }
    }

    static func rows(from events: [TokenCacheAttributionEvent]) -> [ModelTokenBreakdown] {
        combinedRows(events.map {
            ModelTokenBreakdown(
                model: displayModelKey(for: $0.model, at: $0.start),
                breakdown: $0.breakdown,
                pricePeriods: [.init(model: $0.model, start: $0.start, breakdown: $0.breakdown)]
            )
        })
    }

    /// Normalizes rows returned by a compact aggregate.  The compact index
    /// query intentionally returns one row per raw `events.model` value, so
    /// aliases such as `gpt5.6`/`gpt-5.6-sol` would otherwise remain split.
    /// Compact today's rows do not carry one timestamp per event; the caller
    /// supplies the effective date for the already-filtered day so Auto Review
    /// follows the same versioned routing rule as the event-based path.
    static func rows(
        from aggregatedRows: [ModelTokenBreakdown],
        at effectiveDate: Date
    ) -> [ModelTokenBreakdown] {
        combinedRows(aggregatedRows.map { row in
            let hasDatedPricingRows = row.pricePeriods != nil
                && row.pricingRows.contains { $0.start != nil }
            return ModelTokenBreakdown(
                model: hasDatedPricingRows
                    ? row.model
                    : displayModelKey(for: row.model, at: effectiveDate),
                breakdown: row.breakdown,
                pricePeriods: row.pricePeriods ?? [.init(model: row.model, start: effectiveDate, breakdown: row.breakdown)]
            )
        })
    }

    static func compactText(from rows: [ModelTokenBreakdown], limit: Int = 3) -> String? {
        let slices = slices(from: rows)
        guard !slices.isEmpty else { return nil }
        let visible = slices.prefix(max(limit, 1)).map {
            "\($0.label) \(Int(($0.share * 100).rounded()))%"
        }
        let suffix = slices.count > visible.count ? " · +\(slices.count - visible.count)" : ""
        return visible.joined(separator: " · ") + suffix
    }

    static func dominantColor(from rows: [ModelTokenBreakdown]) -> Color? {
        slices(from: rows).first?.color
    }

    static func key(for model: String?) -> String {
        let source = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return "unknown" }
        if normalized.hasPrefix(autoReviewDisplayPrefix) {
            return normalized
        }
        if CodexAutoReviewPricingPolicy.isAutoReviewAlias(normalized) {
            return "codex-auto-review"
        }
        if OfficialAPIPriceModel.independentQuotaModelName(from: normalized) != nil {
            return "gpt-5.3-codex-spark"
        }
        // Keep this list explicit.  In particular, `gpt-5.6`, `gpt5.6` and
        // `gpt56` intentionally fall through so their original spelling is
        // visible instead of being guessed as Sol.
        return knownModelAliases[normalized] ?? source
    }

    static func label(for model: String?) -> String {
        if let model, model.hasPrefix("client:") { return SpeedColorOverrides.clientTitle(model) }
        switch key(for: model) {
        case "gpt-6-astra": return "Astra"
        case "gpt-6.1-sol": return "GPT-6.1 Sol"
        case "gpt-6.1-terra": return "GPT-6.1 Terra"
        case "gpt-6-sol": return "GPT-6 Sol"
        case "gpt-6-luna": return "GPT-6 Luna"
        case "gpt-5.6-sol": return "Sol"
        case "gpt-5.6-terra": return "Terra"
        case "gpt-5.6-luna": return "Luna"
        case "gpt-5.5": return "5.5"
        case "gpt-5.6-generic": return "5.6（未分型）"
        case "codex-auto-review": return "Auto Review（Luna）"
        case "gpt-5.4-mini": return "5.4 m"
        case "gpt-5.4": return "5.4"
        case "gpt-5.3-codex": return "5.3"
        case "gpt-5.3-codex-spark": return "Spark"
        case "gpt-5.2-codex": return "5.2"
        case "unknown": return "未知模型"
        default:
            let modelKey = key(for: model)
            if modelKey.hasPrefix(autoReviewDisplayPrefix) {
                let suffix = String(modelKey.dropFirst(autoReviewDisplayPrefix.count))
                return "Auto Review（\(displayTargetTitle(for: suffix))）"
            }
            return model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未知模型"
        }
    }

    static func color(for model: String?) -> Color {
        let modelKey = key(for: model)
        if modelKey == "codex-auto-review" {
            return color(forKey: "gpt-5.6-luna")
        }
        if modelKey.hasPrefix(autoReviewDisplayPrefix) {
            let suffix = String(modelKey.dropFirst(autoReviewDisplayPrefix.count))
            return color(forKey: displayTargetKey(for: suffix))
        }
        return color(forKey: modelKey)
    }

    static func isAutoReviewModelKey(_ model: String?) -> Bool {
        guard let model else { return false }
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return normalized.hasPrefix(autoReviewDisplayPrefix)
            || CodexAutoReviewPricingPolicy.isAutoReviewAlias(normalized)
    }

    /// Returns the billable presentation key used by the compact floating
    /// surface.  Main/dashboard rows retain their dated Auto Review display
    /// keys; callers opt into this mapping only when they need one slot per
    /// underlying model.
    static func autoReviewUnderlyingModelKey(for model: String?) -> String? {
        guard isAutoReviewModelKey(model) else { return nil }
        let displayKey = key(for: model)
        guard displayKey.hasPrefix(autoReviewDisplayPrefix) else {
            return canonicalPresentationKey(for: CodexAutoReviewPricingPolicy.currentRule.targetModel)
        }

        let suffix = String(displayKey.dropFirst(autoReviewDisplayPrefix.count))
        switch suffix {
        case "luna": return "gpt-5.6-luna"
        case "5.4": return "gpt-5.4"
        default:
            let targetKey = displayTargetKey(for: suffix)
            return targetKey == suffix ? nil : targetKey
        }
    }

    /// Expands a raw Auto Review aggregate into one display row per dated
    /// pricing period. Event rows already carry `codex-auto-review@5.4` or
    /// `codex-auto-review@luna`; those synthetic display keys pass through
    /// unchanged. Keeping the original period model/start is required by the
    /// historical estimator after the display row is later merged into a
    /// floating underlying model.
    static func rowsWithDatedAutoReviewTargets(from rows: [ModelTokenBreakdown]) -> [ModelTokenBreakdown] {
        rows.flatMap { row in
            if row.pricePeriods == nil, key(for: row.model).hasPrefix(autoReviewDisplayPrefix) {
                // Keep the free-service identity even when only an old display
                // key remains. Its underlying card is for reference pricing,
                // never a replacement for the usage's billable identity.
                return [ModelTokenBreakdown(model: row.model, breakdown: row.breakdown,
                    pricePeriods: [.init(model: row.model, start: nil, breakdown: row.breakdown)])]
            }
            guard key(for: row.model) == "codex-auto-review", row.pricePeriods != nil else {
                return [row]
            }
            let periods = row.pricingRows
            guard periods.contains(where: { $0.start != nil }),
                  periods.map(\.breakdown).combined == row.breakdown else {
                return [row]
            }

            return periods.map { period in
                let sourceModel = period.model ?? row.model
                let sourceKey = key(for: sourceModel)
                let displayModel: String?
                if sourceKey.hasPrefix(autoReviewDisplayPrefix) {
                    displayModel = sourceKey
                } else if sourceKey == "codex-auto-review", let start = period.start {
                    displayModel = displayModelKey(for: sourceModel, at: start)
                } else {
                    displayModel = sourceModel
                }
                return ModelTokenBreakdown(
                    model: displayModel,
                    breakdown: period.breakdown,
                    pricePeriods: [period]
                )
            }
        }
    }

    static func combinedRows(_ rows: [ModelTokenBreakdown]) -> [ModelTokenBreakdown] {
        var grouped: [String: (model: String?, breakdowns: [TokenCacheBreakdown], periods: [ModelTokenPricePeriod])] = [:]
        for row in rowsWithDatedAutoReviewTargets(from: rows) where row.breakdown.totalTokens > 0 {
            let modelKey = key(for: row.model)
            var value = grouped[modelKey] ?? (row.model, [], [])
            value.breakdowns.append(row.breakdown)
            value.periods.append(contentsOf: row.pricingRows)
            grouped[modelKey] = value
        }
        return grouped.map { key, value in
            ModelTokenBreakdown(
                model: key == "unknown" ? nil : value.model,
                breakdown: value.breakdowns.combined,
                pricePeriods: value.periods
            )
        }
    }

    static let dashboardOtherModelColor = "#87919e"
    static func dashboardColorHex(for model: String?, latest: Bool) -> String {
        let raw = model?.split(separator: "|").last.map(String.init)
        let modelKey = autoReviewUnderlyingModelKey(for: raw ?? "unknown") ?? key(for: raw)
        return SpeedColorOverrides.shared.color(for: modelKey) ?? (latest ? colorHex(for: modelKey) : dashboardOtherModelColor)
    }
    static func dashboardColor(for model: String?, latest: Bool) -> Color {
        let rgb = UInt32(dashboardColorHex(for: model, latest: latest).dropFirst(), radix:16) ?? 0x87919e
        return Color(red:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255)
    }

    static func colorHex(for model: String?) -> String {
        let overrideKey = key(for: model)
        if let custom = SpeedColorOverrides.shared.color(for: overrideKey) { return custom }
        if overrideKey.hasPrefix("client:") { return SpeedColorOverrides.clientColor(overrideKey) }
        let key = self.key(for: model)
        if key == "codex-auto-review" { return colorHex(for: "gpt-5.6-luna") }
        if key.hasPrefix(autoReviewDisplayPrefix) {
            return colorHex(for: displayTargetKey(for: String(key.dropFirst(autoReviewDisplayPrefix.count))))
        }
        let fixed = [
            "claude-fable": "#99623f", "claude-opus": "#c35b96", "claude-sonnet": "#c08b28", "claude-haiku": "#269c92",
            "gpt-6-astra": "#a3d977", "gpt-6.1-sol": "#df7055", "gpt-6.1-terra": "#a773e8", "gpt-6-sol": "#d6ac5b", "gpt-6-luna": "#63a6eb",
            "gpt-5.6-sol": "#8b83c5", "gpt-5.6-terra": "#9b75bd", "gpt-5.6-luna": "#7595bd", "gpt-5.5": "#a87629",
            "gpt-5.6-generic": "#7a879e", "gpt-5.4": "#f28f14", "gpt-5.4-mini": "#2eb35c",
            "gpt-5.3-codex": "#db4575", "gpt-5.3-codex-spark": "#f5b022", "gpt-5.2-codex": "#3d7fe0", "unknown": "#7a879e",
        ]
        if let hex = fixed[key] { return hex }
        // Resolve presentation color only; never merge model versions or
        // provider IDs in the ledger/pricing dimensions.
        if let identity = ClaudeModelPresentation.identity(key), let hex = fixed["claude-" + identity.family] { return hex }
        let hash = key.utf8.reduce(UInt32(0x811c9dc5)) { ($0 ^ UInt32($1)) &* 0x01000193 }
        let channels = [16, 8, 0].map { 80 + Int((hash >> $0) & 127) }
        return String(format: "#%02x%02x%02x", channels[0], channels[1], channels[2])
    }

    private static func color(forKey key: String) -> Color {
        let rgb = UInt32(colorHex(for: key).dropFirst(), radix: 16) ?? 0x7a879e
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    private static func displayModelKey(for model: String?, at date: Date) -> String? {
        let modelKey = key(for: model)
        if modelKey.hasPrefix(autoReviewDisplayPrefix) {
            return modelKey
        }
        guard CodexAutoReviewPricingPolicy.isAutoReviewAlias(model) else {
            return model
        }
        let target = OfficialAPIPriceModel.detected(from: model, at: date)
        switch target {
        case .gpt56Luna:
            return "\(autoReviewDisplayPrefix)luna"
        case .gpt54Legacy:
            return "\(autoReviewDisplayPrefix)5.4"
        case let target?:
            return "\(autoReviewDisplayPrefix)\(target.rawValue)"
        case nil:
            return "codex-auto-review"
        }
    }

    private static func displayTargetTitle(for suffix: String) -> String {
        switch displayTargetKey(for: suffix) {
        case "gpt-5.6-luna": return "Luna"
        case "gpt-5.4": return "5.4"
        case "gpt-5.5": return "5.5"
        case "gpt-5.6-sol": return "Sol"
        case "gpt-5.6-terra": return "Terra"
        case "gpt-5.3-codex": return "5.3"
        case "gpt-5.2-codex": return "5.2"
        case "gpt-5.4-mini": return "5.4 m"
        default: return suffix
        }
    }

    private static func displayTargetKey(for suffix: String) -> String {
        switch suffix {
        case "luna", OfficialAPIPriceModel.gpt56Luna.rawValue:
            return "gpt-5.6-luna"
        case "5.4", OfficialAPIPriceModel.gpt54Legacy.rawValue:
            return "gpt-5.4"
        case OfficialAPIPriceModel.gpt56Sol.rawValue:
            return "gpt-5.6-sol"
        case OfficialAPIPriceModel.gpt56Terra.rawValue:
            return "gpt-5.6-terra"
        case OfficialAPIPriceModel.gpt53Codex.rawValue:
            return "gpt-5.3-codex"
        case OfficialAPIPriceModel.gpt52Codex.rawValue:
            return "gpt-5.2-codex"
        case OfficialAPIPriceModel.gpt54MiniLegacy.rawValue:
            return "gpt-5.4-mini"
        case "gpt54legacy":
            return "gpt-5.4"
        case "gpt54minilegacy":
            return "gpt-5.4-mini"
        default:
            return knownModelAliases[suffix] ?? suffix
        }
    }

    private static func canonicalPresentationKey(for model: OfficialAPIPriceModel) -> String {
        switch model {
        case .gpt6Astra: return "gpt-6-astra"
        case .gpt61Sol: return "gpt-6.1-sol"
        case .gpt61Terra: return "gpt-6.1-terra"
        case .gpt6Sol: return "gpt-6-sol"
        case .gpt6Luna: return "gpt-6-luna"
        case .gpt56Sol: return "gpt-5.6-sol"
        case .gpt55: return "gpt-5.5"
        case .gpt56Terra: return "gpt-5.6-terra"
        case .gpt56Luna: return "gpt-5.6-luna"
        case .gpt53Codex: return "gpt-5.3-codex"
        case .gpt52Codex: return "gpt-5.2-codex"
        case .gpt54Legacy: return "gpt-5.4"
        case .gpt54MiniLegacy: return "gpt-5.4-mini"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct ModelUsageInlineSummary: View {
    let rows: [ModelTokenBreakdown]
    var limit = 3
    var emptyPlaceholder: String? = nil

    var body: some View {
        let slices = ModelUsagePresentation.slices(from: rows)
        if !slices.isEmpty {
            HStack(spacing: 7) {
                ForEach(Array(slices.prefix(max(limit, 1)))) { slice in
                    HStack(spacing: 3) {
                        Circle().fill(slice.color).frame(width: 6, height: 6)
                        Text("\(slice.label) \(Int((slice.share * 100).rounded()))%")
                    }
                }
                if slices.count > limit {
                    Text("+\(slices.count - limit)")
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if let emptyPlaceholder {
            Text(emptyPlaceholder)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
