import Foundation
import AgentSpeedCore

/// Presentation metadata only. Versioned model IDs and accounting stay intact.
enum ClaudeModelPresentation {
    static let families = ["fable", "opus", "sonnet", "haiku"]
    struct Identity: Equatable {
        let family: String
        let version: [Int]
        var label: String { family.capitalized + (version.isEmpty ? "" : " " + version.map(String.init).joined(separator: ".")) }
    }
    static func identity(_ raw: String) -> Identity? {
        let model = raw.split(separator: "|", maxSplits: 1).last.map(String.init) ?? raw
        let value = model.lowercased().replacingOccurrences(of: "_", with: "-")
        for family in families {
            let expression = #"(?:^|[^a-z])"# + family + #"(?:[- ]*([0-9]{1,2})(?![0-9])(?:[.\- ]([0-9]{1,2})(?![0-9]))?)?(?:$|[^a-z])"#
            guard let regex = try? NSRegularExpression(pattern: expression),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
            var version = (1...2).compactMap { n -> Int? in
                guard let range = Range(match.range(at: n), in: value) else { return nil }
                return Int(value[range])
            }
            if version.isEmpty,
               let regex = try? NSRegularExpression(pattern: #"claude-([0-9]{1,2})[.\-]([0-9]{1,2})-"# + family),
               let old = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) {
                version = (1...2).compactMap { Range(old.range(at: $0), in: value).flatMap { Int(value[$0]) } }
            }
            return Identity(family: family, version: version)
        }
        return nil
    }
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let delta = (i < a.count ? a[i] : 0) - (i < b.count ? b[i] : 0)
            if delta != 0 { return delta }
        }
        return 0
    }
    struct CatalogModel: Equatable {
        let id: String
        let version: [Int]
    }
    /// Latest current Anthropic model ID known to this bundled build, by Claude family.
    /// This is presentation metadata only; it never initializes price sync or changes accounting.
    static let newestCatalogModelsByFamily: [String: CatalogModel] = {
        var newest: [String: CatalogModel] = [:]
        for model in PriceBook.bundled.models where model.provider == "anthropic" && model.status == "current" {
            guard let parsed = identity(model.id), !parsed.version.isEmpty else { continue }
            let candidate = CatalogModel(id: model.id, version: parsed.version)
            if newest[parsed.family].map({ compare($0.version, candidate.version) >= 0 }) != true {
                newest[parsed.family] = candidate
            }
        }
        return newest
    }()
    static func groups(_ items: [FloatingTodayModelUsageItem], client: String) -> [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] {
        let identities = Dictionary(uniqueKeysWithValues: items.compactMap { item in identity(item.id).map { (item.id, $0) } })
        var newest = newestCatalogModelsByFamily.mapValues(\.version)
        for value in identities.values where !value.version.isEmpty {
            if newest[value.family] == nil || compare(newest[value.family]!, value.version) < 0 { newest[value.family] = value.version }
        }
        let latest = items.filter { item in
            guard let value = identities[item.id], !value.version.isEmpty else { return false }
            return compare(value.version, newest[value.family] ?? []) == 0
        }
        let latestIDs = Set(latest.map(\.id))
        var result: [FloatingTodayModelUsagePresentation.DashboardFamilyGroup] = []
        if !latest.isEmpty { result.append(.init(id: client + ":latest", title: "Claude 最新", items: latest.sorted { a,b in
            families.firstIndex(of: identities[a.id]!.family)! < families.firstIndex(of: identities[b.id]!.family)!
        })) }
        for family in families {
            let rows = items.filter { !latestIDs.contains($0.id) && identities[$0.id]?.family == family }
            if !rows.isEmpty { result.append(.init(id: client + ":" + family, title: family.capitalized, items: rows)) }
        }
        let other = items.filter { identities[$0.id] == nil }
        if !other.isEmpty { result.append(.init(id: client + ":other", title: "Claude 其他", items: other)) }
        return result
    }
}
