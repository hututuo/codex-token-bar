import Foundation

/// One shared presentation policy for all periods. Rows retain their source IDs
/// and already-computed amounts; sorting never reprices or merges a ledger.
enum DashboardModelCostOrder {
    struct Group: Decodable { let id: String; let title: String; let models: [String]; let patterns: [String] }
    struct Policy: Decodable { let schema: Int; let groups: [Group]; let familyPriority: [String]; let clientPriority: [String] }
    static let policy: Policy = {
        guard let url = AppResources.url(forResource: "model-cost-order", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Policy.self, from: data), value.schema == 1 else {
            return Policy(schema: 1, groups: [Group(id: "other", title: "其他", models: [], patterns: []),
                Group(id: "unknown-models", title: "未知模型", models: [], patterns: [])], familyPriority: [], clientPriority: [])
        }
        return value
    }()
    static func identity(_ id: String) -> String {
        var raw = id.split(separator: "|").last.map(String.init) ?? id
        if ClaudeModelPresentation.identity(raw) != nil, !raw.hasPrefix("claude-") { raw = "claude-" + raw }
        let resolved = ModelPresentationIdentity.resolve(raw).key
        return resolved.replacingOccurrences(of: #"(?:-fast)?(?::free)?$"#, with: "", options: .regularExpression)
    }
    static func groupID(_ item: FloatingTodayModelUsageItem) -> String {
        if item.isFallbackEstimate { return "unknown-models" }
        if item.isReferenceOnly { return "other" }
        let key = identity(item.id)
        return policy.groups.first(where: { $0.models.contains(key) || $0.patterns.contains(where: {
            key.range(of: $0, options: .regularExpression) != nil
        }) })?.id ?? "other"
    }
    static func groups(_ items: [FloatingTodayModelUsageItem]) -> [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] {
        let grouped = Dictionary(grouping: items.filter { $0.tokens > 0 }, by: groupID)
        return policy.groups.compactMap { group in
            guard let rows = grouped[group.id], !rows.isEmpty else { return nil }
            return .init(id: group.id, title: group.title, items: rows.sorted { before($0, $1, group: group) })
        }
    }
    private static func version(_ value: String) -> [Int] {
        // Dates/snapshot suffixes are not model generations.
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { $0 < 1000 }
    }
    private static func before(_ a: FloatingTodayModelUsageItem, _ b: FloatingTodayModelUsageItem, group: Group) -> Bool {
        let ak = identity(a.id), bk = identity(b.id)
        let ar = group.models.firstIndex(of: ak) ?? Int.max, br = group.models.firstIndex(of: bk) ?? Int.max
        if ar != br { return ar < br }
        if a.isReferenceOnly != b.isReferenceOnly { return !a.isReferenceOnly }
        let order = ClaudeModelPresentation.compare(version(ak), version(bk))
        if order != 0 { return order > 0 }
        func family(_ value: String) -> Int { policy.familyPriority.firstIndex(where: { value.contains($0) }) ?? Int.max }
        if family(ak) != family(bk) { return family(ak) < family(bk) }
        if ak != bk { return ak < bk }
        func client(_ value: String) -> Int { policy.clientPriority.firstIndex(of: String(value.split(separator: "|").first ?? "")) ?? Int.max }
        if client(a.id) != client(b.id) { return client(a.id) < client(b.id) }
        return a.id < b.id
    }
}
