import Foundation
import AgentSpeedCore

/// `resolve` is a presentation identity and never rewrites persisted IDs,
/// periods or events. `billingIdentifier` separately exposes only explicitly
/// confirmed route aliases; general display normalization cannot price a row.
/// A price-book alias alone is not proof that two versions are the same model.
struct ModelPresentationIdentity: Codable, Equatable, Sendable {
    let key: String
    let label: String
    let kind: String

    private struct Policy: Decodable, Sendable {
        let schema: Int
        let unsafeScalarRanges: [[UInt32]]
        let wrappers: [String]
        let missing: [String]
        let ambiguous: [String]
        let modifiers: [String: [String]]
        let routingLabels: [String: String]
        let sourceLabels: [String: String]
        let billingAliases: [String: String]
    }
    private static let policy: Policy = {
        guard let url=AppResources.url(forResource:"model-presentation-policy",withExtension:"json"),
              let data=try? Data(contentsOf:url),let value=try? JSONDecoder().decode(Policy.self,from:data),value.schema==1 else {
            return Policy(schema:1,unsafeScalarRanges:[[0,31],[127,159]],wrappers:[],missing:[""],ambiguous:[],modifiers:[:],routingLabels:[:],sourceLabels:[:],billingAliases:[:])
        }
        return value
    }()
    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().replacingOccurrences(of:"_",with:"-")
    }
    private static func stripModifiers(_ raw: String) -> String {
        var key=raw
        for prefix in policy.modifiers.keys.sorted() where key.hasPrefix(prefix) {
            while let suffix=policy.modifiers[prefix]!.first(where:{key.hasSuffix($0)}) { key.removeLast(suffix.count) }
            break
        }
        return key
    }
    private static func shape(_ raw: String) -> String {
        var key=normalized(raw).replacingOccurrences(of:" ",with:"-")
            .replacingOccurrences(of:"(",with:"").replacingOccurrences(of:")",with:"")
        key=stripModifiers(key)
        if key.hasPrefix("claude-") {
            key=key.replacingOccurrences(of:".",with:"-")
                .replacingOccurrences(of:#"-[0-9]{8}$"#,with:"",options:.regularExpression)
        }
        return key
    }
    private static let aliases: [String:String] = {
        var result:[String:String]=[:],ambiguous=Set<String>()
        for model in PriceBook.bundled.models {
            for raw in [model.id,model.name]+model.aliases where shape(raw)==shape(model.id) {
                let key=normalized(raw)
                guard !policy.ambiguous.contains(key),!ambiguous.contains(key) else { continue }
                if let old=result[key],old != model.id { result.removeValue(forKey:key);ambiguous.insert(key) }
                else { result[key]=model.id }
            }
        }
        return result
    }()

    static func resolve(_ raw: String?) -> Self {
        let original=(raw ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        var key=normalized(original)
        key = billingIdentifier(key)
        if policy.missing.contains(key) { return .init(key:"unknown",label:"未报告模型",kind:"unreported") }
        if policy.ambiguous.contains(key) { return .init(key:"gpt-5.6-generic",label:"5.6（未分型）",kind:"ambiguous") }
        if let label=policy.routingLabels[key] { return .init(key:key,label:label,kind:"routing") }
        if let label=policy.sourceLabels[key] { return .init(key:key,label:label,kind:"source") }
        func known(_ value:String,_ suffix:String="") -> Self? {
            guard let id=aliases[value],let label=ModelDisplayNames.names[id] else { return nil }
            return .init(key:id+suffix,label:label+(suffix.contains("-fast") ? " Fast":"")+(suffix.contains(":free") ? " Free":""),kind:"known")
        }
        if let hit=known(key) { return hit }
        if let prefix=policy.wrappers.first(where:{key.hasPrefix($0)}) { key=String(key.dropFirst(prefix.count)) }
        key = billingIdentifier(key)
        let rules=PriceBook.bundled.normalize
        for region in rules.bedrockRegions where key.hasPrefix(region+".") {
            let rest=String(key.dropFirst(region.count+1))
            if rules.bedrockVendors.contains(where:{rest.hasPrefix($0+".")}) { key=rest };break
        }
        for vendor in rules.bedrockVendors where key.hasPrefix(vendor+".") {
            key=String(key.dropFirst(vendor.count+1)).replacingOccurrences(of:#"-v[0-9]+(?::[0-9]+)?$"#,with:"",options:.regularExpression);break
        }
        var suffix=""
        if let free=[":free","-free"].first(where:{key.hasSuffix($0)}) { key.removeLast(free.count);suffix=":free" }
        if key.hasSuffix("-fast") { key.removeLast(5);suffix="-fast"+suffix }
        if let hit=known(key,suffix) { return hit }
        key=stripModifiers(key)
        if let hit=known(key,suffix) { return hit }
        if key.hasPrefix("claude-") { key=key.replacingOccurrences(of:".",with:"-") }
        if let hit=known(key,suffix) { return hit }
        // Unknown routes/snapshots never inherit the identity or price of the
        // nearest known name. Keep distinct raw keys even when text is unsafe.
        // Pin control/format ranges and count Unicode scalars across all three
        // implementations; platform Unicode versions and graphemes can differ.
        let invalid=original.unicodeScalars.count>160 || original.unicodeScalars.contains { scalar in
            policy.unsafeScalarRanges.contains { $0[0] <= scalar.value && scalar.value <= $0[1] }
        } || original.contains("{") || original.contains("}")
        return .init(key:original,label:invalid ? "异常模型标识":original,kind:invalid ? "invalid":"unknown")
    }

    static func detail(_ raw: String) -> String {
        let identity=resolve(raw)
        if identity.kind=="invalid" { return "异常标识已隐藏；原始账目保留" }
        return raw.trimmingCharacters(in:.whitespacesAndNewlines)
    }

    /// Explicitly confirmed Antigravity route slots, shared with both ledgers.
    /// This is the only display-policy input allowed to change a price lookup;
    /// it never rewrites stored model IDs and does not perform fuzzy matching.
    static func billingIdentifier(_ normalizedIdentifier: String) -> String {
        policy.billingAliases[normalizedIdentifier] ?? normalizedIdentifier
    }
}
