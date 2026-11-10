import Foundation

/// Shared client/period policy. Every row and price survives below the four-slot fold.
enum DashboardModelCostOrder {
    struct Client: Decodable { let id: String; let title: String; let preferred: [String] }
    struct Generation: Decodable { let prefix: String; let pattern: String; let minimum: [Int] }
    struct Policy: Decodable {
        let schema: Int; let columns: Int; let otherVisibleLimit: Int
        let clients: [Client]; let generations: [Generation]; let otherPatterns: [String]
    }
    static let policy: Policy = {
        guard let url = AppResources.url(forResource: "model-cost-order", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Policy.self, from: data),
              value.schema == 2, value.columns == 4, value.otherVisibleLimit == 4 else {
            return Policy(schema: 2, columns: 4, otherVisibleLimit: 4, clients: [], generations: [], otherPatterns: [])
        }
        return value
    }()

    static func identity(_ id: String) -> String {
        var raw = id.split(separator: "|").last.map(String.init) ?? id
        if ClaudeModelPresentation.identity(raw) != nil, !raw.hasPrefix("claude-") { raw = "claude-" + raw }
        return ModelPresentationIdentity.resolve(raw).key
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
        let active = items.filter { $0.tokens > 0 }
        let grouped = Dictionary(grouping: active.filter { !$0.isFallbackEstimate }, by: { client($0.id) })
        let clientIDs = policy.clients.map(\.id) + grouped.keys.filter { id in !policy.clients.contains { $0.id == id } }.sorted()
        var primary: [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] = [], other: [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] = []
        for id in clientIDs {
            guard let rows = grouped[id], !rows.isEmpty else { continue }
            let rule = policy.clients.first { $0.id == id }
            let preferred = rule?.preferred ?? []
            let candidates = rows.filter(isFeaturedCandidate).sorted { before($0, $1, preferred: preferred) }
            let top = Array(candidates.prefix(policy.columns))
            let selected = Set(top.map(\.id))
            let remaining = rows.filter { !selected.contains($0.id) }.sorted {
                let a = isFeaturedCandidate($0), b = isFeaturedCandidate($1)
                if a != b { return a }
                return before($0, $1, preferred: preferred)
            }
            let title = rule?.title ?? ClientDisplayScope.title(id)
            if !top.isEmpty { primary.append(.init(id: "client:" + id, title: title, items: top)) }
            if !remaining.isEmpty {
                other.append(.init(id: "other:" + id, title: title, items: remaining, isSecondary: true, visibleLimit: policy.otherVisibleLimit))
            }
        }
        let unknown = active.filter(\.isFallbackEstimate)
        if !unknown.isEmpty { other.append(.init(id: "unknown-models", title: "未知模型", items: unknown, isSecondary: true)) }
        return primary + other
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
