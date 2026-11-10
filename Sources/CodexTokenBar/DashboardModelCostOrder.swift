import Foundation

/// Shared client/period policy. Every row and price survives below the four-slot fold.
enum DashboardModelCostOrder {
    struct Client: Decodable { let id: String; let title: String; let sources: [String]; let preferred: [String] }
    struct Generation: Decodable { let prefix: String; let pattern: String; let minimum: [Int] }
    struct Policy: Decodable {
        let schema: Int; let columns: Int; let otherVisibleLimit: Int
        let clients: [Client]; let generations: [Generation]; let otherPatterns: [String]
    }
    static let policy: Policy = {
        guard let url = AppResources.url(forResource: "model-cost-order", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Policy.self, from: data),
              value.schema == 3, value.columns == 4, value.otherVisibleLimit == 4 else {
            return Policy(schema: 3, columns: 4, otherVisibleLimit: 4, clients: [], generations: [], otherPatterns: [])
        }
        return value
    }()

    private static func modelIdentity(_ id: String) -> ModelPresentationIdentity {
        var raw = id.split(separator: "|").last.map(String.init) ?? id
        if ClaudeModelPresentation.identity(raw) != nil, !raw.hasPrefix("claude-") { raw = "claude-" + raw }
        return ModelPresentationIdentity.resolve(raw)
    }
    static func identity(_ id: String) -> String {
        modelIdentity(id).key
            .replacingOccurrences(of: #"(?:-fast)?(?::free)?$"#, with: "", options: .regularExpression)
    }
    static func client(_ id: String) -> String {
        id.contains("|") ? String(id.split(separator: "|")[0]) : "codex"
    }
    static func isFeaturedCandidate(_ item: FloatingTodayModelUsageItem) -> Bool {
        guard !item.isReferenceOnly else { return false }
        let key = identity(item.id)
        guard ["known", "source"].contains(ModelPresentationIdentity.resolve(key).kind),
              !policy.otherPatterns.contains(where: { key.range(of: $0, options: .regularExpression) != nil }) else { return false }
        guard let generation = policy.generations.first(where: { key.hasPrefix($0.prefix) }) else { return true }
        guard let expression = try? NSRegularExpression(pattern: generation.pattern),
              let match = expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) else { return false }
        let version = (1...2).map { index in Range(match.range(at: index), in: key).flatMap { Int(key[$0]) } ?? 0 }
        return ClaudeModelPresentation.compare(version, generation.minimum) >= 0
    }

    static func groups(_ items: [FloatingTodayModelUsageItem]) -> [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] {
        let available = items.filter { $0.tokens >= 0 && !$0.isCatalogPlaceholder }
        let grouped = Dictionary(grouping: available.filter { !$0.isFallbackEstimate }, by: { item in
            policy.clients.first { $0.sources.contains(client(item.id)) }?.id ?? client(item.id)
        })
        let clientIDs = policy.clients.map(\.id) + grouped.keys.filter { id in !policy.clients.contains { $0.id == id } }.sorted()
        var primary: [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] = [], other: [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] = []
        for id in clientIDs {
            guard let sourceRows = grouped[id], !sourceRows.isEmpty else { continue }
            let rule = policy.clients.first { $0.id == id }
            let preferred = rule?.preferred ?? []
            let used = sourceRows.filter { $0.tokens > 0 }
            let rows = rule.map { mergeSources(used, rule: $0) } ?? used
            let sorted = rows.sorted {
                let a = isFeaturedCandidate($0), b = isFeaturedCandidate($1)
                return a != b ? a : before($0, $1, preferred: preferred)
            }
            let sources = Array(Set(sourceRows.flatMap { $0.sourceClients.isEmpty ? [client($0.id)] : $0.sourceClients })).sorted()
            var top = preferred.prefix(policy.columns).map { model in
                sorted.first { modelIdentity($0.id).key == model && !$0.isReferenceOnly }
                    ?? sorted.first { identity($0.id) == model && !$0.isReferenceOnly }
                    ?? FloatingTodayModelUsageItem(id: id + "|" + model, label: modelIdentity(model).label,
                        tokens: 0, share: 0, costUSD: 0, usesIndependentQuota: false, referenceCostUSD: nil,
                        color: ModelUsagePresentation.color(for: model), sourceClients: sources, isCatalogPlaceholder: true)
            }
            if top.count < policy.columns {
                let chosen = Set(top.map(\.id))
                top += sorted.filter { isFeaturedCandidate($0) && !chosen.contains($0.id) }.prefix(policy.columns - top.count)
            }
            let selected = Set(top.map(\.id))
            let remaining = sorted.filter { !selected.contains($0.id) }
            let title = rule?.title ?? ClientDisplayScope.title(id)
            if !top.isEmpty {
                primary.append(.init(id: "client:" + id, title: title, items: top + remaining, visibleLimit: policy.columns))
            } else if !remaining.isEmpty {
                other.append(.init(id: "other:" + id, title: title, items: remaining, isSecondary: true, visibleLimit: policy.otherVisibleLimit))
            }
        }
        let unknown = available.filter { $0.isFallbackEstimate && $0.tokens > 0 }
        if !unknown.isEmpty { other.append(.init(id: "unknown-models", title: "未知模型", items: unknown, isSecondary: true)) }
        return primary + other
    }

    /// Merge only explicitly grouped sources and exact display identities.
    /// Fast/free variants remain distinct; known partial prices stay partial.
    private static func mergeSources(_ rows: [FloatingTodayModelUsageItem], rule: Client) -> [FloatingTodayModelUsageItem] {
        guard rule.sources.count > 1 else { return rows }
        return Dictionary(grouping: rows, by: { $0.isReferenceOnly ? $0.id : modelIdentity($0.id).key }).values.map { values in
            let sorted = values.sorted { $0.id < $1.id }
            guard sorted.count > 1 else { return sorted[0] }
            let model = modelIdentity(sorted[0].id)
            let known = sorted.compactMap { $0.knownPartialCostUSD ?? $0.costUSD }
            let subtotal = known.isEmpty ? nil : known.reduce(0, +)
            let complete = sorted.allSatisfy { $0.costUSD != nil && $0.knownPartialCostUSD == nil }
            return .init(id: rule.id + "|" + model.key, label: model.label,
                tokens: sorted.reduce(0) { $0 + $1.tokens }, share: sorted.reduce(0) { $0 + $1.share },
                costUSD: complete ? subtotal : nil, usesIndependentQuota: false, referenceCostUSD: nil,
                color: sorted[0].color, knownPartialCostUSD: complete ? nil : subtotal,
                sourceModels: Array(Set(sorted.flatMap { $0.sourceModels.isEmpty ? [String($0.id.split(separator: "|").last!)] : $0.sourceModels })).sorted(),
                sourceClients: Array(Set(sorted.flatMap { $0.sourceClients.isEmpty ? [client($0.id)] : $0.sourceClients })).sorted())
        }
    }

    private static func before(_ a: FloatingTodayModelUsageItem, _ b: FloatingTodayModelUsageItem, preferred: [String]) -> Bool {
        let ar = preferred.firstIndex(of: identity(a.id)) ?? Int.max
        let br = preferred.firstIndex(of: identity(b.id)) ?? Int.max
        if ar != br { return ar < br }
        if a.isReferenceOnly != b.isReferenceOnly { return !a.isReferenceOnly }
        if a.tokens != b.tokens { return a.tokens > b.tokens }
        func version(_ id: String) -> [Int] { identity(id).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { $0 < 1000 } }
        let generation = ClaudeModelPresentation.compare(version(a.id), version(b.id))
        if generation != 0 { return generation > 0 }
        return a.id < b.id
    }
}
