import AgentSpeedCore
import XCTest
@testable import CodexTokenBar

final class ModelDisplayNamesTests: XCTestCase {
    func testEveryPriceEntryAndUnambiguousAliasHasAShortName() {
        let models = PriceBook.bundled.models
        XCTAssertEqual(models.count, 199)
        XCTAssertEqual(Set(ModelDisplayNames.names.keys), Set(models.map(\.id)))
        XCTAssertEqual(Set(ModelDisplayNames.names.values).count, models.count,
            "Different price entries must remain distinguishable")
        for model in models {
            let label = ModelDisplayNames.names[model.id]!
            XCTAssertLessThanOrEqual(label.count, 32, model.id)
            for raw in [model.id, model.name] + model.aliases where raw != "gpt-5.6" {
                XCTAssertEqual(ModelUsagePresentation.label(for: raw), label, raw)
            }
        }
    }

    func testKnownWrappersKeepVersionAndServiceTierButUnknownsKeepTheirIdentity() {
        let cases = [
            "Gemini 4 Argon (High)": "Argon4", "models/gemini-4-argon": "Argon4",
            "gemini-3.8-flash-low": "Flash3.8", "claude-mythos-5-1": "Mythos5.1",
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0": "Sonnet4.5",
            "anthropic/claude-opus-5.5-fast": "Opus5.5 Fast",
            "deepseek/deepseek-v4-flash:free": "DS4.1 Flash Free",
            "k3.1-pro-highspeed": "Kimi3.1 Pro Fast", "gpt61sol": "Sol6.1",
            "gpt-6-sol": "Sol6", "gpt-5.6-sol": "Sol5.6",
            "gpt-4o-2024-05-13": "4o (2024-05-13)"
        ]
        for (raw, expected) in cases { XCTAssertEqual(ModelUsagePresentation.label(for: raw), expected, raw) }
        for raw in ["gpt-5.6", "gpt5.6", "gpt56", "GPT-7-Nova", "gemini-3.1-flash", "gpt-6.1-sol-preview", "router/auto"] {
            XCTAssertEqual(ModelUsagePresentation.label(for: raw), raw)
            XCTAssertEqual(ModelUsagePresentation.key(for: raw), raw)
        }
        XCTAssertEqual(ModelUsagePresentation.key(for: "models/gemini-4-argon"), "models/gemini-4-argon")
        XCTAssertEqual(ModelUsagePresentation.label(for: "codex-auto-review@5.4"), "Auto Review（5.4）")
    }

    func testAddedPricesAndExistingDateBoundariesStayIndependentOfLabels() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-08T02:00:00Z"))
        for (raw, expected) in [
            ("k3.1-pro", "$2.00 / $10.00"), ("k3.1-pro-highspeed", "$4.00 / $20.00"),
            ("mimo-v2.6-flash", "$0.14 / $0.28"), ("mimo-v2.6-pro", "$0.435 / $0.87"),
            ("mimo-v2.6-pro-ultraspeed", "$4.35 / $8.70")
        ] { XCTAssertEqual(ClientReferencePrice.text(raw, at: date), expected) }
        XCTAssertEqual(ClientReferencePrice.text("gemini-4-argon", at: date), "$2.00 / $10.00")
        let later = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        XCTAssertEqual(ClientReferencePrice.text("gemini-4-argon", at: later), "$4.00 / $20.00")
        XCTAssertEqual(ModelUsagePresentation.label(for: "gemini-4-argon"), "Argon4")
        XCTAssertEqual(ClientReferencePrice.text("kimi-for-coding", at: date), "未计价")
        XCTAssertEqual(ClientReferencePrice.text("gpt-6.1-sol-ultrafast", at: date), "未计价")
    }
}
