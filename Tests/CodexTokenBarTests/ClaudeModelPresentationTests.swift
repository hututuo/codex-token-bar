import XCTest
import SwiftUI
@testable import CodexTokenBar

final class ClaudeModelPresentationTests: XCTestCase {
    private func item(_ id: String) -> FloatingTodayModelUsageItem {
        .init(id: id, label: id, tokens: 100, share: 0.25, costUSD: 0.5,
              usesIndependentQuota: false, referenceCostUSD: nil, color: .blue)
    }

    func testVersionParserRecognizesFivePointFiveWithProviderPrefixesAndDates() {
        for raw in [
            "claude-opus-5-5",
            "anthropic/claude-opus-5.5-20261022",
            "us.anthropic.claude-sonnet-5-5-20261022-v1:0",
            "ClaudeCode|haiku5.5",
            "claude-fable-5-1-20261022",
        ] {
            let expected: [Int] = raw.lowercased().contains("fable") ? [5, 1] : [5, 5]
            XCTAssertEqual(ClaudeModelPresentation.identity(raw)?.version, expected, raw)
        }
        XCTAssertEqual(ClaudeModelPresentation.identity("claude-opus-20261001")?.version, [])
    }

    func testBundledCatalogProvidesCurrentLatestModelFloors() {
        let expected = [
            "fable": ("claude-fable-5-1", [5, 1]),
            "opus": ("claude-opus-5-5", [5, 5]),
            "sonnet": ("claude-sonnet-5-5", [5, 5]),
            "haiku": ("claude-haiku-5-5", [5, 5]),
        ]
        XCTAssertEqual(Set(ClaudeModelPresentation.newestCatalogModelsByFamily.keys), Set(expected.keys))
        for (family, value) in expected {
            XCTAssertEqual(ClaudeModelPresentation.newestCatalogModelsByFamily[family]?.id, value.0)
            XCTAssertEqual(ClaudeModelPresentation.newestCatalogModelsByFamily[family]?.version, value.1)
        }
    }

    func testOlderObservedModelsShareOneOtherGroupUntilCatalogVersionIsObserved() {
        let items = [
            item("claudeCode|opus-4-8"), item("claudeDesktop|sonnet-5"),
            item("claudeCode|haiku-4-5"), item("claudeDesktop|fable-5"),
            item("claudeCode|claude-opus-20261001"), item("claudeDesktop|custom-model"),
        ]

        let groups = ClaudeModelPresentation.groups(items, client: "claude")

        XCTAssertFalse(groups.contains { $0.id == "claude:latest" })
        XCTAssertEqual(groups.map(\.id), ["claude:other"])
        XCTAssertEqual(groups.first?.items.count, items.count)
        XCTAssertEqual(groups.flatMap(\.items).sorted { $0.id < $1.id }, items.sorted { $0.id < $1.id })
    }

    func testObservedVersionAboveCatalogFloorWinsWithoutChangingAnyRows() {
        let items = [
            item("claudeCode|opus-5-5"), item("claudeDesktop|opus-6-1"),
            item("claudeCode|haiku-6"), item("claudeDesktop|fable-5-1"),
            item("claudeCode|custom-model"),
        ]

        let groups = ClaudeModelPresentation.groups(items, client: "claude")

        XCTAssertEqual(groups.first(where: { $0.id == "claude:latest" })?.items.map(\.id), [
            "claudeDesktop|fable-5-1", "claudeDesktop|opus-6-1", "claudeCode|haiku-6",
        ])
        XCTAssertEqual(groups.flatMap(\.items).sorted { $0.id < $1.id }, items.sorted { $0.id < $1.id })
    }
}
