import Foundation

public enum PriceTableError: Error, Equatable, Sendable {
    case tooLarge
    case notJSON
    /// A table of another schema (NETWORK 3: a higher one needs a newer build; not an error to report loudly).
    case unsupportedSchema(Int?)
    /// The rules of `validate_table` in `spec/tools/prices.py`, or the table's own `tests`.
    case invalid([String])

    public var isNewerSchema: Bool {
        if case .unsupportedSchema(let schema?) = self { return schema > PriceTable.supportedSchema }
        return false
    }
}

extension PriceTable {
    /// Parses and validates a table exactly like `spec/tools/prices.py` (NETWORK 3 checks 1–4).
    public static func load(_ data: Data) -> Result<PriceTable, PriceTableError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let value = try? JSONParser.parse(data), value.object != nil else { return .failure(.notJSON) }
        let schema = value["schema"]?.int64
        guard schema == Int64(supportedSchema) else { return .failure(.unsupportedSchema(schema.map { Int($0) })) }
        var validator = PriceTableValidator()
        guard let table = validator.validate(value, data: data) else { return .failure(.invalid(validator.errors)) }
        return .success(table)
    }
}

/// `validate_table` of `spec/tools/prices.py`, rule for rule, on the raw document.
struct PriceTableValidator {
    static let priceFields = ["input", "cachedInput", "cacheWrite", "cacheWrite1h", "output"]
    static let requiredPrices = ["input", "output"]
    static let statuses: Set<String> = ["current", "preview", "legacy", "deprecated", "retired"]
    static let normalizeLists = [
        "freeProviders", "cloudSuffixes", "bedrockRegions", "bedrockVendors", "freeSuffixes", "variantSuffixes",
        "fastSuffixes", "dateSuffixPrefixes", "dotHyphenPrefixes",
    ]
    static let normalizeKeys = Set(normalizeLists + ["rewrites", "modifierSuffixes"])
    static let modelKeys: Set<String> = [
        "id", "provider", "name", "status", "free", "prices", "tiers", "offPeak", "periods", "fast", "aliases", "source",
        "checked", "note",
    ]
    static let freeModelKeys: Set<String> = ["id", "provider", "name", "status", "free", "aliases", "source", "checked", "note"]
    static let maxPrice = Decimal(10000)
    static let maxModels = 2000

    private(set) var errors: [String] = []

    // MARK: - Table

    mutating func validate(_ table: JSONValue, data: Data) -> PriceTable? {
        guard let t = table.object else {
            errors.append("table is not an object")
            return nil
        }
        if t["schema"]?.int64 != Int64(PriceTable.supportedSchema) { errors.append("schema must be 1") }
        let version = t["version"]?.int64
        if version.map({ $0 < 1 }) ?? true { errors.append("version must be a positive integer") }
        let updated = t["updated"]?.string
        if !(updated.map(Self.isDate) ?? false) { errors.append("updated must be YYYY-MM-DD") }
        if t["currency"]?.string != "USD" || t["unit"]?.string != "perMillionTokens" {
            errors.append(#"currency must be "USD" and unit "perMillionTokens""#)
        }
        var providers: [String: PriceProvider] = [:]
        if let raw = t["providers"]?.object, !raw.isEmpty {
            for (key, entry) in raw {
                let name = entry["name"]
                let url = Self.pythonString(entry["url"])
                if !Self.isID(key) || entry.object == nil || !Self.truthy(name) || !url.hasPrefix("https://") {
                    errors.append("provider \(key): needs name and an https url")
                }
                providers[key] = PriceProvider(name: name?.string ?? "", url: url)
            }
        } else {
            errors.append("providers must be a non-empty object")
        }
        guard let norm = t["normalize"]?.object, Set(norm.keys) == Self.normalizeKeys else {
            errors.append("normalize must have exactly \(Self.normalizeKeys.sorted())")
            return nil
        }
        guard let normalize = validateNormalize(norm), errors.isEmpty else { return nil }
        guard let rawModels = t["models"]?.array, !rawModels.isEmpty, rawModels.count <= Self.maxModels else {
            errors.append("models must be a list of 1..\(Self.maxModels) entries")
            return nil
        }
        var models: [PriceModel] = []
        var keyCounts: [String: Int] = [:]
        var keyOrder: [String] = []
        for (index, raw) in rawModels.enumerated() {
            let model = validateModel(raw, index: index, providers: providers, updated: updated)
            if let model { models.append(model) }
            if let object = raw.object {
                var keys = Self.aliases(object["aliases"]) ?? []
                if let id = object["id"]?.string { keys.insert(id, at: 0) }
                for key in keys {
                    if keyCounts[key] == nil { keyOrder.append(key) }
                    keyCounts[key, default: 0] += 1
                }
            }
        }
        for key in keyOrder where keyCounts[key, default: 0] > 1 {
            errors.append("id or alias \"\(key)\" is used \(keyCounts[key] ?? 0) times")
        }
        var unknown: [UnknownModelRule] = []
        if let rawUnknown = t["unknown"] {
            if let list = rawUnknown.array {
                for (index, entry) in list.enumerated() {
                    guard let match = entry["match"]?.string, match == "exact" || match == "prefix",
                          let value = entry["value"]?.string, !value.isEmpty, Self.isTrimmedLowercase(value),
                          Self.truthy(entry["reason"]) else {
                        errors.append("unknown[\(index)]: needs match exact|prefix, a lowercase value and a reason")
                        continue
                    }
                    let isPrefix = match == "prefix"
                    for key in keyOrder where isPrefix ? key.unicodeScalars.starts(with: value.unicodeScalars) : key == value {
                        errors.append("unknown[\(index)] \"\(value)\" shadows the id or alias \"\(key)\"")
                    }
                    unknown.append(UnknownModelRule(isPrefix: isPrefix, value: value, reason: Self.pythonString(entry["reason"])))
                }
            } else {
                errors.append("unknown must be a list")
            }
        }
        guard errors.isEmpty, let version, let updated else { return nil }
        var tests: [PriceTableTest] = []
        var testIndices: [Int] = []
        if let rawTests = t["tests"] {
            if let list = rawTests.array {
                for (index, entry) in list.enumerated() {
                    guard let object = entry.object, let expect = object["expect"]?.string, object["model"] != nil else {
                        errors.append("tests[\(index)]: needs model and expect")
                        continue
                    }
                    tests.append(PriceTableTest(model: object["model"]?.string, provider: object["provider"]?.string, expect: expect))
                    testIndices.append(index)
                }
            } else {
                errors.append("tests must be a list")
            }
        }
        let table = PriceTable(
            version: Int(version), updated: updated, providers: providers, normalize: normalize, models: models,
            unknown: unknown, tests: tests, data: data
        )
        for (index, model) in models.enumerated() {
            for key in [model.id] + model.aliases {
                let resolution = table.resolver.resolve(model: key, provider: nil)
                let ok: Bool = switch resolution {
                case .free: model.isFree && table.resolver.resolveWithKey(model: key, provider: nil).key.map { table.resolverIndex(of: $0) == index } == true
                case .priced(let hit, let fast): !model.isFree && hit == index && !fast
                case .unknown: false
                }
                if !ok {
                    errors.append("\"\(key)\" does not resolve to \(model.id) (got \(table.label(of: resolution)))")
                }
            }
        }
        for (index, test) in zip(testIndices, tests) {
            let got = table.label(of: table.resolver.resolve(model: test.model, provider: test.provider))
            if got != test.expect {
                errors.append("tests[\(index)]: \(test.model ?? "null") (provider \(test.provider ?? "None")) expected \(test.expect) got \(got)")
            }
        }
        return errors.isEmpty ? table : nil
    }

    // MARK: - Normalization

    private mutating func validateNormalize(_ norm: [String: JSONValue]) -> PriceNormalization? {
        var lists: [String: [String]] = [:]
        for key in Self.normalizeLists {
            if let list = Self.lowercaseList(norm[key]) {
                lists[key] = list
            } else {
                errors.append("normalize.\(key) must be unique lowercase strings")
            }
        }
        var rewrites: [PriceNormalization.Rewrite] = []
        if let list = norm["rewrites"]?.array, list.allSatisfy({ entry in
            guard let object = entry.object, Set(object.keys) == ["prefix", "to"] else { return false }
            return Self.lowercaseList(.array([object["prefix"]!, object["to"]!])) != nil
        }) {
            rewrites = list.map { PriceNormalization.Rewrite(prefix: $0["prefix"]?.string ?? "", to: $0["to"]?.string ?? "") }
        } else {
            errors.append("normalize.rewrites must be {prefix, to} objects with lowercase strings")
        }
        var modifiers: [PriceNormalization.Modifier] = []
        if let list = norm["modifierSuffixes"]?.array, list.allSatisfy({ entry in
            guard let object = entry.object, Set(object.keys) == ["prefix", "suffixes"] else { return false }
            return Self.lowercaseList(.array([object["prefix"]!])) != nil && Self.lowercaseList(object["suffixes"]) != nil
        }) {
            modifiers = list.map {
                PriceNormalization.Modifier(prefix: $0["prefix"]?.string ?? "", suffixes: Self.lowercaseList($0["suffixes"]) ?? [])
            }
        } else {
            errors.append("normalize.modifierSuffixes must be {prefix, suffixes} objects with lowercase strings")
        }
        guard errors.isEmpty else { return nil }
        return PriceNormalization(
            freeProviders: lists["freeProviders"] ?? [], cloudSuffixes: lists["cloudSuffixes"] ?? [],
            bedrockRegions: lists["bedrockRegions"] ?? [], bedrockVendors: lists["bedrockVendors"] ?? [],
            freeSuffixes: lists["freeSuffixes"] ?? [], variantSuffixes: lists["variantSuffixes"] ?? [],
            fastSuffixes: lists["fastSuffixes"] ?? [], rewrites: rewrites,
            dateSuffixPrefixes: lists["dateSuffixPrefixes"] ?? [], modifierSuffixes: modifiers,
            dotHyphenPrefixes: lists["dotHyphenPrefixes"] ?? []
        )
    }

    // MARK: - Models

    private mutating func validateModel(
        _ raw: JSONValue,
        index: Int,
        providers: [String: PriceProvider],
        updated: String?
    ) -> PriceModel? {
        let start = errors.count
        let where_ = "models[\(index)] \(raw["id"].map(Self.pythonString) ?? "?")"
        guard let m = raw.object else {
            errors.append("\(where_): not an object")
            return nil
        }
        let id = m["id"]?.string
        if !(id.map(Self.isID) ?? false) { errors.append("\(where_): id must be lowercase [a-z0-9._:+-]") }
        let provider = m["provider"]?.string
        if provider.map({ providers[$0] == nil }) ?? true {
            errors.append("\(where_): provider \(m["provider"].map(Self.pythonString) ?? "None") is not in providers")
        }
        let name = m["name"]?.string
        if !(name.map { !ModelResolver.strip(Array($0.unicodeScalars)).isEmpty } ?? false) {
            errors.append("\(where_): name is required")
        }
        let status = m["status"]?.string
        if !(status.map(Self.statuses.contains) ?? false) {
            errors.append("\(where_): status must be one of \(Self.statuses.sorted())")
        }
        let source = m["source"]?.string ?? ""
        if !source.hasPrefix("https://") { errors.append("\(where_): source must be an https URL") }
        let checked = m["checked"]?.string
        if !(checked.map(Self.isDate) ?? false) || (updated.flatMap { u in checked.map { $0 > u } } ?? false) {
            errors.append("\(where_): checked must be YYYY-MM-DD, not after updated")
        }
        if let note = m["note"], note.string == nil { errors.append("\(where_): note must be a string") }
        var pricing: ModelPricing?
        var periods: [PricePeriod] = []
        var fast: TieredPrices?
        let isFree = m["free"] == .bool(true)
        if isFree {
            let extra = Set(m.keys).subtracting(Self.freeModelKeys)
            if !extra.isEmpty { errors.append("\(where_): a free model has no \(extra.sorted().joined(separator: ", "))") }
        } else if m["free"] != nil {
            errors.append("\(where_): free must be true or absent")
        } else {
            pricing = checkPricing(raw, where: where_, allowed: Self.modelKeys, offPeak: true)
            if let rawFast = m["fast"] {
                fast = checkPricing(rawFast, where: where_ + ".fast", allowed: ["prices", "tiers"], offPeak: false)?.base
            }
            periods = checkPeriods(m["periods"], where: where_)
        }
        var aliases: [String] = []
        if let rawAliases = m["aliases"] {
            if let valid = Self.aliases(rawAliases) {
                aliases = valid
            } else {
                errors.append("\(where_): aliases must be trimmed lowercase strings")
            }
        }
        guard errors.count == start, let id, let provider, let name, let status, let checked else { return nil }
        return PriceModel(
            id: id, provider: provider, name: name, status: status, isFree: isFree, pricing: pricing, periods: periods,
            fast: fast, aliases: aliases, source: source, checked: checked, note: m["note"]?.string
        )
    }

    private mutating func checkPeriods(_ raw: JSONValue?, where where_: String) -> [PricePeriod] {
        guard let raw else { return [] }
        guard let list = raw.array else {
            errors.append("\(where_): periods must be a list")
            return []
        }
        var spans: [(Int64, Int64)] = []
        var periods: [PricePeriod] = []
        for (index, entry) in list.enumerated() {
            let pw = "\(where_).periods[\(index)]"
            guard let period = entry.object, period["from"] != nil || period["to"] != nil,
                  ["from", "to"].allSatisfy({ key in period[key].map { $0.string.flatMap(UTCDay.instantMs) != nil } ?? true })
            else {
                errors.append("\(pw): needs from and/or to (YYYY-MM-DD or YYYY-MM-DDTHH:MMZ, UTC)")
                continue
            }
            let from = period["from"]?.string.flatMap(UTCDay.instantMs)
            let to = period["to"]?.string.flatMap(UTCDay.instantMs)
            let lo = from ?? .min
            let hi = to ?? .max
            if lo >= hi { errors.append("\(pw): from must be before to") }
            if spans.contains(where: { lo < $0.1 && $0.0 < hi }) { errors.append("\(pw): overlaps another period") }
            spans.append((lo, hi))
            if let pricing = checkPricing(entry, where: pw, allowed: ["from", "to", "prices", "tiers", "offPeak", "note"], offPeak: true) {
                periods.append(PricePeriod(fromMs: from, toMs: to, pricing: pricing))
            }
        }
        return periods
    }

    /// `prices` plus optional ascending `tiers` with the same fields, and optionally `offPeak` (METRICS 9.1).
    private mutating func checkPricing(
        _ raw: JSONValue,
        where where_: String,
        allowed: Set<String>,
        offPeak allowsOffPeak: Bool
    ) -> ModelPricing? {
        let start = errors.count
        guard let p = raw.object else {
            errors.append("\(where_): not an object")
            return nil
        }
        for key in p.keys.sorted() where !allowed.contains(key) { errors.append("\(where_): unknown field \(key)") }
        let base = checkPriceSet(p["prices"], where: where_ + ".prices")
        let baseObject = p["prices"]?.object ?? [:]
        let fields = Set(Self.priceFields.filter { !(baseObject[$0]?.isNull ?? true) })
        if baseObject["above"] != nil { errors.append("\(where_).prices: above belongs in tiers") }
        var last: Int64 = 0
        var tiers: [PriceTier] = []
        var rawTiers: [JSONValue] = []
        if let value = p["tiers"] {
            if let list = value.array {
                rawTiers = list
            } else {
                errors.append("\(where_): tiers must be a list")
            }
        }
        for (index, tier) in rawTiers.enumerated() {
            let tw = "\(where_).tiers[\(index)]"
            let prices = checkPriceSet(tier, where: tw)
            guard let object = tier.object else { continue }
            if let above = object["above"]?.int64, above > last {
                last = above
                if let prices { tiers.append(PriceTier(above: above, prices: prices)) }
            } else {
                errors.append("\(tw): above must be an integer greater than the previous threshold")
            }
            if Set(Self.priceFields.filter { !(object[$0]?.isNull ?? true) }) != fields {
                errors.append("\(tw): must set exactly the price fields of the base prices \(fields.sorted())")
            }
        }
        var rule: OffPeakRule?
        if let rawRule = p["offPeak"] {
            guard allowsOffPeak else {
                errors.append("\(where_): offPeak is not allowed here")
                return nil
            }
            rule = checkOffPeak(rawRule, where: where_ + ".offPeak")
        }
        guard errors.count == start, let base else { return nil }
        return ModelPricing(base: TieredPrices(prices: base, tiers: tiers), offPeak: rule)
    }

    private mutating func checkOffPeak(_ raw: JSONValue, where ow: String) -> OffPeakRule? {
        let start = errors.count
        let pricing = checkPricing(raw, where: ow, allowed: ["peakUtc", "peakWeekdays", "offPeakDates", "prices", "tiers"], offPeak: false)
        guard let rule = raw.object else { return nil }
        var windows: [Range<Int>] = []
        if let list = rule["peakUtc"]?.array, !list.isEmpty, list.allSatisfy({ Self.window($0.string) != nil }) {
            windows = list.compactMap { Self.window($0.string) }
        } else {
            errors.append("\(ow).peakUtc: windows HH:MM-HH:MM with start < end <= 24:00")
        }
        var weekdays: Set<Int> = []
        if let list = rule["peakWeekdays"]?.array, !list.isEmpty, list.allSatisfy({ Self.weekday($0) != nil }) {
            weekdays = Set(list.compactMap(Self.weekday))
        } else {
            errors.append("\(ow).peakWeekdays: ISO weekdays 1 (Monday) .. 7")
        }
        var dates: Set<String> = []
        if let value = rule["offPeakDates"] {
            if let list = value.array, list.allSatisfy({ $0.string.map(Self.isDate) ?? false }) {
                dates = Set(list.compactMap(\.string))
            } else {
                errors.append("\(ow).offPeakDates: YYYY-MM-DD dates")
            }
        }
        guard errors.count == start, let pricing else { return nil }
        return OffPeakRule(peakWindows: windows, peakWeekdays: weekdays, offPeakDates: dates, pricing: pricing.base)
    }

    private mutating func checkPriceSet(_ raw: JSONValue?, where where_: String) -> PriceSet? {
        let start = errors.count
        guard let prices = raw?.object else {
            errors.append("\(where_): not an object")
            return nil
        }
        for key in prices.keys.sorted() where !Self.priceFields.contains(key) && key != "above" {
            errors.append("\(where_): unknown field \(key)")
        }
        for key in Self.requiredPrices where prices[key]?.isNull ?? true {
            errors.append("\(where_): \(key) is required")
        }
        var micro: [String: Int64] = [:]
        for key in Self.priceFields {
            guard let value = prices[key], !value.isNull else { continue }
            if let price = checkPrice(value, where: "\(where_).\(key)") { micro[key] = price }
        }
        guard errors.count == start, let input = micro["input"], let output = micro["output"] else { return nil }
        let cacheWrite = micro["cacheWrite"] ?? input
        return PriceSet(
            input: input, cachedInput: micro["cachedInput"] ?? input, cacheWrite: cacheWrite,
            cacheWrite1h: micro["cacheWrite1h"] ?? cacheWrite, output: output
        )
    }

    /// A price 0–10 000 USD per million tokens with at most 6 decimals, as integer micro-USD per million tokens.
    private mutating func checkPrice(_ value: JSONValue, where where_: String) -> Int64? {
        guard let literal = value.literal else {
            errors.append("\(where_): not a number")
            return nil
        }
        guard let decimal = literal.decimal, decimal >= 0, decimal <= Self.maxPrice else {
            errors.append("\(where_): \(literal.text) out of range 0..10000")
            return nil
        }
        guard let micro = Self.micro(decimal) else {
            errors.append("\(where_): price \(literal.text) has more than 6 decimals")
            return nil
        }
        return micro
    }

    // MARK: - Helpers

    /// `price × 1 000 000` when it is an integer.
    static func micro(_ price: Decimal) -> Int64? {
        var scaled = price * Decimal(1_000_000)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        return Int64(truncating: NSDecimalNumber(decimal: rounded))
    }

    static func isDate(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 ? byte == UInt8(ascii: "-") : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }

    /// `^[a-z0-9][a-z0-9._:+-]*$`.
    static func isID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first, isLowerAlnum(first) else { return false }
        return bytes.dropFirst().allSatisfy { isLowerAlnum($0) || ".-_:+".utf8.contains($0) }
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// `v == v.strip().lower()` for a string.
    static func isTrimmedLowercase(_ text: String?) -> Bool {
        guard let text else { return false }
        let scalars = Array(text.unicodeScalars)
        return ModelResolver.lowercasedText(ModelResolver.strip(scalars)) == text
    }

    /// A list of non-empty, trimmed lowercase strings (duplicates are reported across the table).
    static func aliases(_ raw: JSONValue?) -> [String]? {
        guard let list = raw?.array else { return raw == nil ? [] : nil }
        var values: [String] = []
        for item in list {
            guard let text = item.string, !text.isEmpty, isTrimmedLowercase(text) else { return nil }
            values.append(text)
        }
        return values
    }

    /// Unique, non-empty, trimmed lowercase strings.
    static func lowercaseList(_ raw: JSONValue?) -> [String]? {
        guard let list = raw?.array else { return nil }
        var values: [String] = []
        for item in list {
            guard let text = item.string, !text.isEmpty, isTrimmedLowercase(text) else { return nil }
            values.append(text)
        }
        return Set(values).count == values.count ? values : nil
    }

    /// `HH:MM-HH:MM` with `0 ≤ start < end ≤ 24:00`, as minutes.
    static func window(_ text: String?) -> Range<Int>? {
        guard let text else { return nil }
        let bytes = Array(text.utf8)
        guard bytes.count == 11, bytes[2] == UInt8(ascii: ":"), bytes[5] == UInt8(ascii: "-"), bytes[8] == UInt8(ascii: ":")
        else { return nil }
        func two(_ at: Int) -> Int? {
            let digits = bytes[at..<(at + 2)]
            guard digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
            return digits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        }
        guard let h0 = two(0), let m0 = two(3), let h1 = two(6), let m1 = two(9) else { return nil }
        let start = h0 * 60 + m0
        let end = h1 * 60 + m1
        guard start < end, end <= 1440 else { return nil }
        return start..<end
    }

    /// An ISO weekday 1–7 (Python's `in range(1, 8)` also takes an integral float; never a boolean).
    static func weekday(_ value: JSONValue) -> Int? {
        guard let decimal = value.literal?.decimal else { return nil }
        for day in 1...7 where decimal == Decimal(day) { return day }
        return nil
    }

    /// Python truthiness of a JSON value.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .bool(let flag)?: flag
        case .number(let literal)?: literal.decimal.map { $0 != 0 } ?? true
        case .string(let text)?: !text.isEmpty
        case .array(let items)?: !items.isEmpty
        case .object(let members)?: !members.isEmpty
        }
    }

    /// `str()` of a JSON value, for messages and the `str(...).startswith("https://")` checks.
    static func pythonString(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .number(let literal)?: literal.text
        case .bool(let flag)?: flag ? "True" : "False"
        case nil, .null?: "None"
        case .array?, .object?: "…"
        }
    }
}

extension PriceTable {
    /// `Resolution.label` of `prices.py`: the model id (with ` fast`), `free` or `unknown`.
    public func label(of resolution: ModelResolution) -> String {
        switch resolution {
        case .priced(let index, let fast): models[index].id + (fast ? " fast" : "")
        case .free: "free"
        case .unknown: "unknown"
        }
    }

    func resolverIndex(of key: String) -> Int? {
        models.firstIndex { $0.id == key || $0.aliases.contains(key) }
    }
}
