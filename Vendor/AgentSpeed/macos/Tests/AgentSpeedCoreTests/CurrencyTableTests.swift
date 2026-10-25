import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Currencies")
struct CurrencyTableTests {
    static let table = CurrencyTable.bundled

    static func strings() throws -> [String: Any] {
        let url = Fixtures.root.deletingLastPathComponent().appendingPathComponent("strings.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func name(_ currency: Currency, _ language: String, _ strings: [String: Any]) -> String {
        (strings["currency.\(currency.code)"] as? [String: String])?[language] ?? currency.code
    }

    /// `validate_currencies` of `spec/tools/prices.py`.
    @Test func bundledTableFollowsTheRules() throws {
        let currencies = Self.table.currencies
        #expect(currencies.count == 38)
        #expect(Set(currencies.map(\.code)).count == currencies.count)
        #expect(Self.table.currency("USD") != nil)
        for currency in currencies {
            #expect(currency.code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, "\(currency.code)")
            #expect((0...3).contains(currency.digits), "\(currency.code) digits")
            #expect(!currency.symbol.isEmpty && currency.symbol == currency.symbol.trimmingCharacters(in: .whitespaces))
            #expect(Set(currency.symbols.keys).isSubset(of: Set(CurrencyTable.languages)), "\(currency.code) symbols")
        }
        let ranks = currencies.compactMap(\.common).sorted()
        #expect(ranks == Array(1...ranks.count))
        let fallback = Self.table.fallbackRates
        #expect(fallback.source.hasPrefix("https://"))
        #expect(fallback.rates["USD"] == 1)
        #expect(Set(fallback.rates.keys) == Self.table.codes)
        #expect(fallback.rates.values.allSatisfy { $0 > 0 })
        #expect(fallback.dateMs > 0)
    }

    @Test func everyCurrencyHasANameInEveryLanguage() throws {
        let strings = try Self.strings()
        for currency in Self.table.currencies {
            let entry = try #require(strings["currency.\(currency.code)"] as? [String: String], "currency.\(currency.code)")
            for language in CurrencyTable.languages {
                #expect(entry[language]?.isEmpty == false, "currency.\(currency.code) \(language)")
            }
        }
    }

    @Test func symbolsFollowTheLanguage() throws {
        let usd = try #require(Self.table.currency("USD"))
        #expect(usd.symbol(language: "en") == "$")
        #expect(usd.symbol(language: "zh-Hant") == "US$")
        let cny = try #require(Self.table.currency("CNY"))
        #expect(cny.symbol(language: "zh-Hans") == "¥")
        #expect(cny.symbol(language: "ja") == "CN¥")
        let jpy = try #require(Self.table.currency("JPY"))
        #expect(jpy.symbol(language: "ja") == "¥")
        #expect(jpy.symbol(language: "en") == "JP¥")
        #expect(Self.table.currencyOrUSD("XXX").code == "USD")
    }

    @Test func commonGroupPutsUSDThenTheHomeCurrencies() {
        #expect(Self.table.commonGroup(language: "zh-Hant").map(\.code).prefix(4) == ["USD", "TWD", "HKD", "MOP"])
        #expect(Self.table.commonGroup(language: "zh-Hans").map(\.code).prefix(3) == ["USD", "CNY", "TWD"])
        #expect(Self.table.commonGroup(language: "ja").map(\.code).prefix(3) == ["USD", "JPY", "CNY"])
        #expect(Self.table.commonGroup(language: "en").map(\.code) == ["USD", "CNY", "TWD", "HKD", "JPY", "EUR", "GBP", "KRW", "SGD"])
    }

    @Test func otherGroupIsSortedByLocalizedName() throws {
        let strings = try Self.strings()
        let names = Self.table.otherGroup(language: "en") { Self.name($0, "en", strings) }.map { Self.name($0, "en", strings) }
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let common = Set(Self.table.commonGroup(language: "en").map(\.code))
        let other = Self.table.otherGroup(language: "en") { Self.name($0, "en", strings) }
        #expect(common.count + other.count == Self.table.currencies.count)
        #expect(other.allSatisfy { !common.contains($0.code) })
    }

    @Test func searchMatchesWordStartsCodesFirst() throws {
        let strings = try Self.strings()
        func search(_ query: String, _ language: String) -> [String] {
            Self.table.search(
                query, language: language, localizedName: { Self.name($0, language, strings) },
                englishName: { Self.name($0, "en", strings) }
            ).map(\.code)
        }
        let dollars = search("dol", "en")
        #expect(dollars.contains("USD") && dollars.contains("TWD") && dollars.contains("HKD") && dollars.contains("AUD"))
        #expect(!dollars.contains("EUR"))
        #expect(search("yen", "zh-Hant") == ["JPY"])
        #expect(search("円", "ja").contains("JPY"))
        #expect(search("nt", "zh-Hant").contains("TWD"))
        #expect(search("TW", "en").first == "TWD")
        #expect(search("ｕｓｄ", "en").first == "USD", "width-insensitive")
        #expect(search("美元", "zh-Hant").first == "USD")
        #expect(search("zzz", "en").isEmpty)
        #expect(search("  ", "en").isEmpty)
        #expect(search("ar", "en").first == "ARS", "a code match ranks first")
    }
}
