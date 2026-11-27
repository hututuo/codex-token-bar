import AgentSpeedCore
import XCTest
@testable import CodexTokenBar

final class ExactBundledPriceIndexTests: XCTestCase {
    func testExactPriceIndexMatchesIndependentGroupingOfEveryBundledIdentifier() {
        let models = PriceBook.bundled.models
        let entries = ExactBundledPriceEntry.makeIndex(for: models)
        var grouped: [String: [Int]] = [:]
        for (index, model) in models.enumerated() {
            for identifier in [model.id] + model.aliases where !identifier.isEmpty {
                grouped[identifier.lowercased(), default: []].append(index)
            }
        }

        XCTAssertFalse(grouped.isEmpty)
        XCTAssertEqual(Set(entries.keys), Set(grouped.keys))
        for (identifier, indices) in grouped {
            let identities = Set(indices.map { models[$0].id })
            let expected: ExactBundledPriceEntry = identities.count == 1
                ? .unique(indices.min()!) : .ambiguous
            XCTAssertEqual(entries[identifier], expected, identifier)
            if case .unique(let index)? = entries[identifier] {
                XCTAssertEqual(models[index], models[indices.min()!], identifier)
            }
        }
        XCTAssertNil(entries["unlisted-test-billing-model"])
        XCTAssertNil(entries[""])
    }

    func testExactPriceIndexKeepsFirstSameIDAndNeverResolvesAnAmbiguousAlias() throws {
        let template = try XCTUnwrap(PriceBook.bundled.models.first)
        var first = template
        first.id = "model-a"
        first.aliases = ["SHARED", "A-Only", "", "model-a", "Repeated"]
        var repeated = first
        repeated.name = "A distinct catalog value with the same model ID"
        repeated.aliases = ["a-only", "Repeated", "second-only"]
        var other = template
        other.id = "model-b"
        other.aliases = ["shared", "Model-A", "b-only"]
        var later = first
        later.aliases = ["sHaReD", "model-a", "late-only"]
        let models = [first, repeated, other, later]
        let entries = ExactBundledPriceEntry.makeIndex(for: models)

        XCTAssertEqual(entries["a-only"], .unique(0))
        XCTAssertEqual(entries["repeated"], .unique(0))
        XCTAssertEqual(entries["second-only"], .unique(1))
        XCTAssertEqual(entries["model-b"], .unique(2))
        XCTAssertEqual(entries["b-only"], .unique(2))
        XCTAssertEqual(entries["late-only"], .unique(3))
        XCTAssertEqual(entries["shared"], .ambiguous)
        XCTAssertEqual(entries["model-a"], .ambiguous)
        XCTAssertNil(entries[""])
        XCTAssertNil(entries["SHARED"])
        XCTAssertEqual(ExactBundledPriceEntry.makeIndex(for: []), [:])
    }
}
