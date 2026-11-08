import Foundation
import AgentSpeedCore

/// Display text only. Never use these names to group rows, resolve a price or
/// write a ledger. Swift and the frontend share the same exhaustive name asset.
enum ModelDisplayNames {
    private struct Catalog: Decodable { let schema: Int; let names: [String: String] }
    static let names: [String: String] = {
        guard let url = AppResources.url(forResource: "model-display-names", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.schema == 1 else { return [:] }
        return catalog.names
    }()

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
    }

    // The price resolver admits this family alias; a label must not guess Sol.
    private static let untyped: Set<String> = ["gpt-5.6", "gpt5.6", "gpt56"]
    private static let byAlias: [String: String] = {
        var result: [String: String] = [:], ambiguous: Set<String> = []
        for model in PriceBook.bundled.models {
            guard let label = names[model.id] else { continue }
            for value in [model.id, model.name] + model.aliases {
                let key = normalized(value)
                guard !untyped.contains(key), !ambiguous.contains(key) else { continue }
                if let previous = result[key], previous != label {
                    result.removeValue(forKey: key); ambiguous.insert(key)
                } else { result[key] = label }
            }
        }
        return result
    }()

    /// Only known IDs/aliases and documented transport wrappers are shortened.
    /// Unknown future variants retain their original spelling. Fast/free markers
    /// remain visible even though this function performs no pricing resolution.
    static func catalogLabel(for raw: String) -> String? {
        var key = normalized(raw)
        if let label = byAlias[key] { return label }
        key = key.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? key
        let rules = PriceBook.bundled.normalize
        for region in rules.bedrockRegions where key.hasPrefix(region + ".") {
            let rest = String(key.dropFirst(region.count + 1))
            if rules.bedrockVendors.contains(where: { rest.hasPrefix($0 + ".") }) { key = rest }
            break
        }
        for vendor in rules.bedrockVendors where key.hasPrefix(vendor + ".") {
            key = String(key.dropFirst(vendor.count + 1))
                .replacingOccurrences(of: #"-v[0-9]+(?::[0-9]+)?$"#, with: "", options: .regularExpression)
            break
        }
        key = key.replacingOccurrences(of: #"@(?:default|[0-9]{8})$"#, with: "", options: .regularExpression)
        if let label = byAlias[key] { return label }
        var suffix = ""
        if let marker = rules.freeSuffixes.first(where: { key.hasSuffix($0) }) {
            key.removeLast(marker.count); suffix = " Free"
        }
        if key.hasSuffix("-fast") { key.removeLast(5); suffix = " Fast" + suffix }
        if let label = byAlias[key] { return label + suffix }
        for rewrite in rules.rewrites where key.hasPrefix(rewrite.prefix) {
            key = rewrite.to + String(key.dropFirst(rewrite.prefix.count)); break
        }
        if rules.dateSuffixPrefixes.contains(where: { key.hasPrefix($0) }) {
            key = key.replacingOccurrences(of: #"-[0-9]{8}$"#, with: "", options: .regularExpression)
        }
        for rule in rules.modifierSuffixes where key.hasPrefix(rule.prefix) {
            while let marker = rule.suffixes.first(where: { key.hasSuffix($0) }) { key.removeLast(marker.count) }
            break
        }
        if let label = byAlias[key] { return label + suffix }
        if rules.dotHyphenPrefixes.contains(where: { key.hasPrefix($0) }) { key = key.replacingOccurrences(of: ".", with: "-") }
        return byAlias[key].map { $0 + suffix }
    }

    /// Benchmark labels carry effort as a separate word, not part of a model ID.
    static func catalogLabelWithEffort(for raw: String) -> String? {
        if let label = catalogLabel(for: raw) { return label }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count > 1, let effort = parts.last?.lowercased(),
              ["ultra", "max", "xhigh", "high", "medium", "low", "minimal", "none"].contains(effort),
              let label = catalogLabel(for: parts.dropLast().joined(separator: " ")) else { return nil }
        return label + " " + effort
    }
}
