import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Report usernames")
struct ReportUsernameTests {
    static func vectors() throws -> [String: Any] {
        try #require(try Fixtures.json("report-vectors.json")["usernames"] as? [String: Any])
    }

    static func cases(_ group: String) throws -> [[String: Any]] {
        try #require(try vectors()[group] as? [[String: Any]])
    }

    static func rules(_ name: String) throws -> ReportUsernameRules {
        let all = try #require(try vectors()["rules"] as? [String: [String: Any]])
        let rule = try #require(all[name])
        let charset = try #require(rule["charset"] as? String)
        return ReportUsernameRules(
            minLength: try #require(rule["minLength"] as? Int),
            maxLength: try #require(rule["maxLength"] as? Int),
            charset: try #require(ReportUsernameRules.Charset(rawValue: charset)),
            spaces: try #require(rule["spaces"] as? Bool)
        )
    }

    static func scalars(_ text: String?) -> [UInt32]? {
        text.map { $0.unicodeScalars.map(\.value) }
    }

    @Test func vectorGroupsArePresent() throws {
        #expect(try Self.cases("validate").count >= 20)
        #expect(try Self.cases("fit").count >= 13)
        #expect(try Self.cases("keys").count >= 4)
    }

    @Test func rulesVectorsMatchTheClampedDefaults() throws {
        #expect(try Self.rules("default") == .standard)
        #expect(try Self.rules("strict") == ReportUsernameRules(minLength: 3, maxLength: 16, charset: .ascii, spaces: false))
    }

    @Test func validateVectors() throws {
        for item in try Self.cases("validate") {
            let name = try #require(item["name"] as? String)
            let rules = try Self.rules(try #require(item["rules"] as? String))
            let expected = item["expect"] as? String
            #expect(ReportUsername.validate(name, rules: rules)?.rawValue == expected, "\(Self.scalars(name) ?? [])")
        }
    }

    @Test func fitVectors() throws {
        for item in try Self.cases("fit") {
            let computerName = try #require(item["computerName"] as? String)
            let rules = try Self.rules(try #require(item["rules"] as? String))
            let expected = item["expect"] as? String
            let fitted = ReportUsername.fit(computerName: computerName, rules: rules)
            #expect(Self.scalars(fitted) == Self.scalars(expected), "\(computerName) → \(fitted ?? "nil")")
        }
    }

    @Test func keyVectors() throws {
        for item in try Self.cases("keys") {
            let a = try #require(item["a"] as? String)
            let b = try #require(item["b"] as? String)
            let same = try #require(item["same"] as? Bool)
            #expect(ReportUsername.isSameName(a, b) == same, "\(a) / \(b)")
            #expect((Self.scalars(ReportUsername.comparisonKey(a)) == Self.scalars(ReportUsername.comparisonKey(b))) == same)
        }
    }

    @Test func normalFormIsCheckedByCodePoints() {
        #expect(ReportUsername.validate("Zo\u{00EB}", rules: .standard) == nil)
        #expect(ReportUsername.validate("Zoe\u{0308}", rules: .standard) == .characters)
        #expect(Self.scalars(ReportUsername.normalized("Zoe\u{0308}")) == Self.scalars("Zo\u{00EB}"))
        #expect(ReportUsername.normalized("\u{FF5A}\u{FF4F}\u{FF45}") == "zoe")
    }

    @Test func checksFollowTheOrderOfTheSpec() {
        #expect(ReportUsername.validate("x\u{200B}", rules: .standard) == .characters)
        #expect(ReportUsername.validate("x", rules: .standard) == .length)
        #expect(ReportUsername.validate(" zoe", rules: .standard) == .start)
        #expect(ReportUsername.validate("zoe\u{3000}x", rules: .standard) == .characters)
        #expect(ReportUsername.validate("zoe\u{2028}x", rules: .standard) == .spaces)
        #expect(ReportUsername.validate("zoe@ x", rules: .standard) == .characters)
        #expect(ReportUsername.validate(".zoe", rules: .standard) == .start)
        #expect(ReportUsername.validate("\u{0301}zoe", rules: .standard) == .start)
        #expect(ReportUsername.validate("Zo\u{00EB}", rules: ReportUsernameRules(charset: .ascii)) == .characters)
    }

    @Test func caseFoldingFollowsUnicodeCaseFolding() {
        #expect(ReportUsername.comparisonKey("Straße") == "strasse")
        #expect(ReportUsername.comparisonKey("\u{1E9E}") == "ss")
        #expect(Self.scalars(ReportUsername.comparisonKey("\u{0130}")) == [0x69, 0x307])
        #expect(Self.scalars(ReportUsername.comparisonKey("\u{AB70}\u{13A0}\u{13F8}")) == [0x13A0, 0x13A0, 0x13F0])
        #expect(Self.scalars(ReportUsername.comparisonKey("\u{1C80}\u{1C88}")) == [0x0432, 0xA64B])
        #expect(Self.scalars(ReportUsername.comparisonKey("ΣΑΣ ς")) == Self.scalars("σασ σ"))
        #expect(ReportUsername.comparisonKey("\u{FB01}x") == "fix")
        #expect(ReportUsername.isSameName("ＺＯＥ", "zoe"))
        #expect(!ReportUsername.isSameName("zoe", "zoë"))
    }

    @Test func rulesAreClamped() throws {
        let low = ReportUsernameRules(minLength: 0, maxLength: 1)
        #expect(low.minLength == 1 && low.maxLength == 12)
        let high = ReportUsernameRules(minLength: 40, maxLength: 99)
        #expect(high.minLength == 12 && high.maxLength == 32)
        let decoded = try JSONDecoder().decode(
            ReportUsernameRules.self, from: Data(#"{"minLength": -5, "maxLength": 500, "charset": "ascii"}"#.utf8))
        #expect(decoded == ReportUsernameRules(minLength: 1, maxLength: 32, charset: .ascii, spaces: true))
        let encoded = try JSONEncoder().encode(ReportUsernameRules.standard)
        #expect(try JSONDecoder().decode(ReportUsernameRules.self, from: encoded) == .standard)
    }

    @Test func fitDropsWhatTheRulesForbid() {
        let strict = ReportUsernameRules(minLength: 3, maxLength: 16, charset: .ascii, spaces: false)
        #expect(ReportUsername.fit(computerName: "Zoë's  --  Mac", rules: .standard) == "Zoës-Mac")
        #expect(ReportUsername.fit(computerName: "__Zoe__", rules: .standard) == "Zoe")
        #expect(ReportUsername.fit(computerName: "Ab", rules: strict) == nil)
        #expect(ReportUsername.fit(computerName: "", rules: .standard) == nil)
        #expect(ReportUsername.fit(computerName: "Zoe\u{200B}\u{202E}Mac", rules: .standard) == "Zoe Mac")
    }

    @Test func randomNamesUseTheSafeAlphabet() {
        let alphabet = Set("23456789abcdefghjkmnpqrstuvwxyz")
        let strict = ReportUsernameRules(minLength: 3, maxLength: 16, charset: .ascii, spaces: false)
        var names = Set<String>()
        for _ in 0..<200 {
            let name = ReportUsername.random()
            #expect(name.hasPrefix("racer-") && name.count == 12)
            #expect(name.dropFirst(6).allSatisfy(alphabet.contains))
            #expect(ReportUsername.validate(name, rules: .standard) == nil)
            #expect(ReportUsername.validate(name, rules: strict) == nil)
            names.insert(name)
        }
        #expect(names.count > 190)
    }

    @Test func randomNamesCoverTheWholeAlphabet() {
        var generator = SplitMix(seed: 42)
        var seen = Set<Character>()
        for _ in 0..<200 { seen.formUnion(ReportUsername.random(using: &generator).dropFirst(6)) }
        #expect(seen == Set("23456789abcdefghjkmnpqrstuvwxyz"))
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
