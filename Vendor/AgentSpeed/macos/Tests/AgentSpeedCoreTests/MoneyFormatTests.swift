import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Money formatting")
struct MoneyFormatTests {
    static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    @Test func everyFixtureCase() throws {
        let cases = try #require(try Fixtures.json("money-format.json")["cases"] as? [[String: Any]])
        #expect(cases.count >= 40)
        let table = CurrencyTable.bundled
        for spec in cases {
            let currency = try #require(table.currency(spec.string("currency") ?? ""))
            let language = try #require(spec.string("language"))
            let form: MoneyForm = spec.string("form") == "rate" ? .rate : .amount
            let value: Decimal
            if let text = spec.string("value") {
                value = Self.decimal(text)
            } else {
                let micro = try #require(spec.int64("costMicroUsd"))
                value = MoneyFormat.amount(microUsd: micro, rate: Self.decimal(try #require(spec.string("rate"))))
            }
            let got = MoneyFormat.format(value, currency: currency, language: language, form: form)
            #expect(got.number == spec.string("number"), "\(spec)")
            #expect(got.text == spec.string("text"), "\(spec)")
        }
    }

    @Test func liveRatesEnterThroughTheirShortestText() {
        let value = MoneyFormat.rate(microUsdPerSecond: 4200, rate: Self.decimal("6.67476"))
        #expect(value == Self.decimal("0.02803399200"))
        #expect(MoneyFormat.number(value, digits: 2, form: .rate) == "0.028")
        #expect(MoneyFormat.rate(microUsdPerSecond: -1, rate: 1) == 0)
        #expect(MoneyFormat.rate(microUsdPerSecond: .nan, rate: 1) == 0)
        #expect(MoneyFormat.rate(microUsdPerSecond: 0.000_012_34, rate: 1) == Self.decimal("0.00000000001234"))
    }

    @Test func roundingIntoTheNextRow() {
        #expect(MoneyFormat.number(Self.decimal("0.9996"), digits: 2, form: .amount) == "1.00")
        #expect(MoneyFormat.number(Self.decimal("99.96"), digits: 2, form: .rate) == "100")
        #expect(MoneyFormat.number(Self.decimal("999999.6"), digits: 0, form: .rate) == "1.00M")
        #expect(MoneyFormat.number(Self.decimal("999700000"), digits: 2, form: .amount) == "1.00B")
        #expect(MoneyFormat.number(Self.decimal("1234500000000"), digits: 2, form: .amount) == "1,235B")
    }

    @Test func symbolsEndingInALetterTakeANoBreakSpace() {
        #expect(MoneyFormat.withSymbol("CHF", "0.42") == "CHF\u{00A0}0.42")
        #expect(MoneyFormat.withSymbol("฿", "1.20") == "฿1.20")
        #expect(MoneyFormat.withSymbol("Rp", "<0.000001") == "<Rp\u{00A0}0.000001")
    }

    @Test func csvColumns() {
        #expect(MoneyFormat.csvUSD(microUsd: 51565) == "0.051565")
        #expect(MoneyFormat.csvUSD(microUsd: 0) == "0.000000")
        #expect(MoneyFormat.csvUSD(microUsd: 12_345_678_901) == "12345.678901")
        #expect(MoneyFormat.csv(microUsd: 37_940_000, rate: Self.decimal("32.552"), digits: 0) == "1235.02")
        #expect(MoneyFormat.csv(microUsd: 4200, rate: Self.decimal("6.67476"), digits: 2) == "0.0280")
        #expect(MoneyFormat.csv(microUsd: 5, rate: 1, digits: 2) == "0.0000")
    }
}

@Suite("Rate status number")
struct RateStatusNumberTests {
    @Test func atLeastFourSignificantDigits() {
        #expect(MoneyFormat.significant(Decimal(string: "32.411205")!) == "32.41")
        #expect(MoneyFormat.significant(Decimal(string: "158.100039")!) == "158.1")
        #expect(MoneyFormat.significant(Decimal(string: "0.890292")!) == "0.8903")
        #expect(MoneyFormat.significant(Decimal(string: "25841.9")!) == "25,842")
        #expect(MoneyFormat.significant(Decimal(string: "6.689327")!) == "6.689")
        #expect(MoneyFormat.significant(Decimal(string: "1")!) == "1.000")
        #expect(MoneyFormat.significant(Decimal(string: "9.99999")!) == "10.00")
        #expect(MoneyFormat.significant(0) == "0")
    }
}
