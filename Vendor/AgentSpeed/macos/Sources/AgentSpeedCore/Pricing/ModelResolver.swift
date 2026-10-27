import Foundation
import os

/// What a response's model resolves to (METRICS 9.2).
public enum ModelResolution: Equatable, Sendable {
    /// A priced entry (its index in `PriceTable.models`); `fast` when the id itself selects fast mode.
    case priced(index: Int, fast: Bool)
    case free
    case unknown(reason: String)
}

/// Model resolution of METRICS 9.2. Strings are compared by Unicode scalars, the way `spec/tools/prices.py` compares
/// code points, and the character classes follow Python's (`\s`, `\d`, `str.strip`).
public struct ModelResolver: Sendable {
    typealias Key = [Unicode.Scalar]

    /// One normalization step's candidate key; nil for the `free` step, which resolves without a lookup.
    struct Candidate: Equatable {
        var step: String
        var key: String?
        var fast: Bool
    }

    private let normalize: PriceNormalization
    private let byKey: [String: Int]
    private let freeModels: Set<Int>
    private let fastModels: Set<Int>
    private let unknownExact: [String: String]
    private let unknownPrefixes: [(Key, String)]
    private let cache = ResolutionCache()

    init(normalize: PriceNormalization, models: [PriceModel], unknown: [UnknownModelRule]) {
        self.normalize = normalize
        var byKey: [String: Int] = [:]
        for (index, model) in models.enumerated() {
            for key in [model.id] + model.aliases { byKey[key] = index }
        }
        self.byKey = byKey
        freeModels = Set(models.indices.filter { models[$0].isFree })
        fastModels = Set(models.indices.filter { models[$0].fast != nil })
        var exact: [String: String] = [:]
        var prefixes: [(Key, String)] = []
        for rule in unknown {
            if rule.isPrefix {
                prefixes.append((Array(rule.value.unicodeScalars), rule.reason))
            } else {
                exact[rule.value] = rule.reason
            }
        }
        unknownExact = exact
        unknownPrefixes = prefixes
    }

    public func resolve(model: String?, provider: String?) -> ModelResolution {
        resolveWithKey(model: model, provider: provider).resolution
    }

    /// The resolution and the candidate key that decided it (nil when no lookup decided).
    public func resolveWithKey(model: String?, provider: String?) -> (resolution: ModelResolution, key: String?) {
        let cacheKey = (provider.map { "1" + $0 } ?? "0") + "\u{0}" + (model.map { "1" + $0 } ?? "0")
        if let hit = cache.value(for: cacheKey) { return hit }
        let result = computeResolution(model: model, provider: provider)
        cache.store(result, for: cacheKey)
        return result
    }

    /// The table entry an id or alias names.
    func entryIndex(forKey key: String) -> Int? {
        byKey[key]
    }

    /// Step 1 of METRICS 9.2: a local runtime's provider with a model that does not run in its cloud.
    func isLocalProvider(model: String?, provider: String?) -> Bool {
        guard let provider, normalize.freeProviders.contains(Self.lowercasedText(Self.strip(Array(provider.unicodeScalars)))) else {
            return false
        }
        let cloud = model.map { Self.lowercasedKey(Self.strip(Array($0.unicodeScalars))) }
        return !(cloud.map { key in normalize.cloudSuffixes.contains { Self.hasSuffix(key, $0) } } ?? false)
    }

    private func computeResolution(model: String?, provider: String?) -> (resolution: ModelResolution, key: String?) {
        if isLocalProvider(model: model, provider: provider) { return (.free, nil) }
        guard let model, !Self.strip(Array(model.unicodeScalars)).isEmpty else { return (.unknown(reason: "no model"), nil) }
        var seen: Set<String> = []
        for candidate in candidates(model) {
            guard let key = candidate.key else { return (.free, nil) }
            guard !key.isEmpty, seen.insert((candidate.fast ? "1" : "0") + key).inserted else { continue }
            if let hit = lookup(key, fast: candidate.fast) { return (hit, key) }
        }
        return (.unknown(reason: "not in table"), nil)
    }

    private func lookup(_ key: String, fast: Bool) -> ModelResolution? {
        if let index = byKey[key] {
            if freeModels.contains(index) { return .free }
            if fast, !fastModels.contains(index) { return .unknown(reason: "no fast-mode price") }
            return .priced(index: index, fast: fast)
        }
        if let reason = unknownExact[key] { return .unknown(reason: reason) }
        let scalars = Array(key.unicodeScalars)
        for (prefix, reason) in unknownPrefixes where scalars.starts(with: prefix) {
            return .unknown(reason: reason)
        }
        return nil
    }

    /// The normalization steps of METRICS 9.2, in order.
    func candidates(_ model: String) -> [Candidate] {
        var out: [Candidate] = []
        func yield(_ step: String, _ key: Key, _ fast: Bool = false) {
            out.append(Candidate(step: step, key: String(String.UnicodeScalarView(key)), fast: fast))
        }
        var k = Self.lowercasedKey(Self.strip(Self.collapseWhitespace(Self.removeBrackets(Array(model.unicodeScalars)))))
        yield("exact", k)
        if let slash = k.lastIndex(of: "/") {
            k = Array(k[(slash + 1)...])
            yield("route", k)
        }
        for region in normalize.bedrockRegions {
            let head = Array((region + ".").unicodeScalars)
            guard k.starts(with: head) else { continue }
            let rest = Array(k[head.count...])
            if normalize.bedrockVendors.contains(where: { rest.starts(with: Array(($0 + ".").unicodeScalars)) }) {
                k = rest
                break
            }
        }
        for vendor in normalize.bedrockVendors {
            let head = Array((vendor + ".").unicodeScalars)
            if k.starts(with: head) {
                k = Self.removeBedrockVersion(Array(k[head.count...]))
                break
            }
        }
        k = Self.removeVertexTag(Self.vertexDate(k))
        yield("cloud", k)
        if normalize.freeSuffixes.contains(where: { Self.hasSuffix(k, $0) && k.count > $0.unicodeScalars.count }) {
            out.append(Candidate(step: "free", key: nil, fast: false))
            return out
        }
        var stripped = true
        while stripped {
            stripped = false
            for suffix in normalize.variantSuffixes where Self.hasSuffix(k, suffix) && k.count > suffix.unicodeScalars.count {
                k.removeLast(suffix.unicodeScalars.count)
                stripped = true
            }
        }
        yield("variant", k)
        for rule in normalize.rewrites {
            let prefix = Array(rule.prefix.unicodeScalars)
            if k.starts(with: prefix) {
                k = Array(rule.to.unicodeScalars) + k[prefix.count...]
                break
            }
        }
        yield("rewrite", k)
        var fast = false
        for suffix in normalize.fastSuffixes where Self.hasSuffix(k, suffix) && k.count > suffix.unicodeScalars.count {
            k.removeLast(suffix.unicodeScalars.count)
            fast = true
            break
        }
        if fast { yield("fast", k, true) }
        if normalize.dateSuffixPrefixes.contains(where: { k.starts(with: Array($0.unicodeScalars)) }) {
            k = Self.removeDateSuffix(k)
        }
        yield("date", k, fast)
        for rule in normalize.modifierSuffixes {
            let prefixLength = rule.prefix.unicodeScalars.count
            guard k.starts(with: Array(rule.prefix.unicodeScalars)) else { continue }
            stripped = true
            while stripped {
                stripped = false
                for suffix in rule.suffixes
                where Self.hasSuffix(k, suffix) && k.count > prefixLength + suffix.unicodeScalars.count {
                    k.removeLast(suffix.unicodeScalars.count)
                    stripped = true
                }
            }
            break
        }
        yield("modifier", k, fast)
        if normalize.dotHyphenPrefixes.contains(where: { k.starts(with: Array($0.unicodeScalars)) }) {
            k = k.map { $0 == "." ? "-" : $0 }
        }
        yield("dotHyphen", k, fast)
        return out
    }

    // MARK: - Python string semantics

    static func hasSuffix(_ key: Key, _ suffix: String) -> Bool {
        let tail = Array(suffix.unicodeScalars)
        return key.count >= tail.count && key[(key.count - tail.count)...].elementsEqual(tail)
    }

    /// `str.isspace()`: the ASCII separators and Unicode White_Space.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (0x09...0x0D).contains(value) || (0x1C...0x20).contains(value) { return true }
        return value >= 0x80 && scalar.properties.isWhitespace
    }

    /// `\d`: a Unicode decimal digit.
    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType == .decimal
    }

    static func strip(_ key: Key) -> Key {
        guard let first = key.firstIndex(where: { !isSpace($0) }), let last = key.lastIndex(where: { !isSpace($0) }) else {
            return []
        }
        return Array(key[first...last])
    }

    static func lowercasedKey(_ key: Key) -> Key {
        Array(lowercasedText(key).unicodeScalars)
    }

    static func lowercasedText(_ key: Key) -> String {
        String(String.UnicodeScalarView(key)).lowercased()
    }

    /// `\[[^\]]*\]` → one space.
    static func removeBrackets(_ key: Key) -> Key {
        var out: Key = []
        var index = 0
        while index < key.count {
            if key[index] == "[", let close = key[(index + 1)...].firstIndex(of: "]") {
                out.append(" ")
                index = close + 1
            } else {
                out.append(key[index])
                index += 1
            }
        }
        return out
    }

    /// `\s+` → one space.
    static func collapseWhitespace(_ key: Key) -> Key {
        var out: Key = []
        var inRun = false
        for scalar in key {
            if isSpace(scalar) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return out
    }

    /// Removes a trailing `-v\d+(:\d+)?`.
    static func removeBedrockVersion(_ key: Key) -> Key {
        var index = 0
        while index + 2 < key.count {
            if key[index] == "-", key[index + 1] == "v", matchesVersionTail(key[(index + 2)...]) {
                return Array(key[..<index])
            }
            index += 1
        }
        return key
    }

    private static func matchesVersionTail(_ tail: ArraySlice<Unicode.Scalar>) -> Bool {
        var digits = 0
        var index = tail.startIndex
        while index < tail.endIndex, isDigit(tail[index]) {
            digits += 1
            index += 1
        }
        guard digits > 0 else { return false }
        if index == tail.endIndex { return true }
        guard tail[index] == ":" else { return false }
        index += 1
        let rest = tail[index...]
        return !rest.isEmpty && rest.allSatisfy(isDigit)
    }

    /// A trailing `@` + 8 digits becomes `-` + the digits.
    static func vertexDate(_ key: Key) -> Key {
        guard key.count >= 9, key[key.count - 9] == "@", key[(key.count - 8)...].allSatisfy(isDigit) else { return key }
        var out = key
        out[key.count - 9] = "-"
        return out
    }

    /// Removes a trailing `@…` that contains no `@` or `/`.
    static func removeVertexTag(_ key: Key) -> Key {
        guard let at = key.lastIndex(of: "@"), !key[at...].contains("/") else { return key }
        return Array(key[..<at])
    }

    /// Removes a trailing `-` + 8 digits.
    static func removeDateSuffix(_ key: Key) -> Key {
        guard key.count >= 9, key[key.count - 9] == "-", key[(key.count - 8)...].allSatisfy(isDigit) else { return key }
        return Array(key[..<(key.count - 9)])
    }
}

/// Resolutions by (provider, model): a running app sees a handful of distinct models over and over.
private final class ResolutionCache: Sendable {
    static let limit = 4096

    private let entries = OSAllocatedUnfairLock<[String: (resolution: ModelResolution, key: String?)]>(initialState: [:])

    func value(for key: String) -> (resolution: ModelResolution, key: String?)? {
        entries.withLock { $0[key] }
    }

    func store(_ value: (resolution: ModelResolution, key: String?), for key: String) {
        entries.withLock { entries in
            if entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
            entries[key] = value
        }
    }
}
