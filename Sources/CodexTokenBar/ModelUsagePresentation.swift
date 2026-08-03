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
    static func slices(from rows: [ModelTokenBreakdown]) -> [ModelUsageSlice] {
        let combined = combine(rows)
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
                    color: color(forKey: key)
                )
            }
            .sorted { lhs, rhs in
                lhs.tokens == rhs.tokens ? lhs.label < rhs.label : lhs.tokens > rhs.tokens
            }
    }

    static func rows(from events: [TokenCacheAttributionEvent]) -> [ModelTokenBreakdown] {
        combine(events.map { ModelTokenBreakdown(model: $0.model, breakdown: $0.breakdown) })
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
        let normalized = (model ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return "unknown" }
        if normalized.contains("gpt-5.6") {
            if normalized.contains("luna") { return "gpt-5.6-luna" }
            if normalized.contains("terra") { return "gpt-5.6-terra" }
            return "gpt-5.6-sol"
        }
        if normalized.contains("gpt-5.4-mini") { return "gpt-5.4-mini" }
        if normalized.contains("gpt-5.4") { return "gpt-5.4" }
        return normalized
    }

    static func label(for model: String?) -> String {
        switch key(for: model) {
        case "gpt-5.6-sol": "Sol"
        case "gpt-5.6-terra": "Terra"
        case "gpt-5.6-luna": "Luna"
        case "gpt-5.4-mini": "5.4 mini"
        case "gpt-5.4": "5.4"
        case "unknown": "未知模型"
        default: model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未知模型"
        }
    }

    static func color(for model: String?) -> Color {
        color(forKey: key(for: model))
    }

    private static func combine(_ rows: [ModelTokenBreakdown]) -> [ModelTokenBreakdown] {
        var grouped: [String: (model: String?, breakdowns: [TokenCacheBreakdown])] = [:]
        for row in rows where row.breakdown.totalTokens > 0 {
            let modelKey = key(for: row.model)
            var value = grouped[modelKey] ?? (row.model, [])
            value.breakdowns.append(row.breakdown)
            grouped[modelKey] = value
        }
        return grouped.map { key, value in
            ModelTokenBreakdown(
                model: key == "unknown" ? nil : value.model,
                breakdown: value.breakdowns.combined
            )
        }
    }

    private static func color(forKey key: String) -> Color {
        switch key {
        case "gpt-5.6-sol": return Color(red: 0.18, green: 0.42, blue: 0.98)
        case "gpt-5.6-terra": return Color(red: 0.57, green: 0.32, blue: 0.90)
        case "gpt-5.6-luna": return Color(red: 0.00, green: 0.64, blue: 0.68)
        case "gpt-5.4": return Color(red: 0.95, green: 0.56, blue: 0.08)
        case "gpt-5.4-mini": return Color(red: 0.18, green: 0.70, blue: 0.36)
        case "unknown": return Color(red: 0.48, green: 0.53, blue: 0.62)
        default:
            let palette: [Color] = [
                Color(red: 0.91, green: 0.33, blue: 0.45),
                Color(red: 0.15, green: 0.58, blue: 0.88),
                Color(red: 0.78, green: 0.43, blue: 0.84),
                Color(red: 0.13, green: 0.68, blue: 0.55),
                Color(red: 0.90, green: 0.48, blue: 0.16),
            ]
            let index = key.utf8.reduce(UInt64(1469598103934665603)) {
                ($0 ^ UInt64($1)) &* 1099511628211
            } % UInt64(palette.count)
            return palette[Int(index)]
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct ModelUsageInlineSummary: View {
    let rows: [ModelTokenBreakdown]
    var limit = 3

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
        }
    }
}
