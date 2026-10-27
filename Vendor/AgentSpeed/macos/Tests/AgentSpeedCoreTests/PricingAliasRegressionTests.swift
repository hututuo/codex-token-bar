import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Pricing alias regressions")
struct PricingAliasRegressionTests {
    static let datedFlash = "deepseek-v4.1-flash-1017"
    static let endMs: Int64 = 1_792_849_200_000
    static let usage = TokenUsage(input: 1000, cachedInput: 900, output: 100)

    @Test func datedDeepSeekFlashUsesTheExistingPriceAndCacheClasses() {
        let table = PriceBook.bundled
        for model in [Self.datedFlash, "deepseek-v4.1-flash", "deepseek-flash"] {
            #expect(table.reportModelId(model: model, provider: "deepseek") == "deepseek-flash")
            #expect(table.cost(model: model, provider: "deepseek", usage: Self.usage, endMs: Self.endMs, fast: false) == 78)
        }
        #expect(table.cost(model: Self.datedFlash, provider: "deepseek", usage: TokenUsage(input: 1000, output: 100),
                           endMs: Self.endMs, fast: false) == 210)
    }

    @Test func datedDeepSeekFlashKeepsHistoricalAndOffPeakPrices() throws {
        let table = PriceBook.bundled
        let cases: [(String, Int64)] = [
            ("2026-04-26T12:14Z", 67),
            ("2026-04-26T12:15Z", 45),
            ("2026-08-17T02:00Z", 189),
            ("2026-08-17T04:00Z", 94),
            ("2026-09-10T04:00Z", 78),
            ("2026-10-19T02:00Z", 155),
            ("2026-10-19T04:00Z", 78),
            ("2026-10-01T02:00Z", 78),
            ("2026-10-18T02:00Z", 78),
        ]
        for (instant, expected) in cases {
            let end = try #require(UTCDay.instantMs(instant))
            for model in [Self.datedFlash, "deepseek-v4.1-flash"] {
                #expect(table.cost(model: model, provider: "deepseek", usage: Self.usage, endMs: end, fast: false) == expected,
                        "\(model) at \(instant)")
            }
        }
    }

    @Test func unrelatedSuffixesAndPrivateModelsRemainUnpriced() {
        let table = PriceBook.bundled
        for model in ["deepseek-v4.1-flash-1018", "deepseek-unrecognized-model", "Gemini private router", "codex-internal"] {
            #expect(table.reportModelId(model: model, provider: nil) == "unknown")
            #expect(table.cost(model: model, provider: nil, usage: Self.usage, endMs: Self.endMs, fast: false) == nil)
        }
    }

    @Test func antigravityDisplayFallbackUsesItsExactPublishedAlias() throws {
        let table = PriceBook.bundled
        for (display, canonical, expected) in [
            ("Gemini 3.8 Flash", "gemini-3.8-flash", Int64(518)),
            ("Gemini 4 Argon", "gemini-4-argon", Int64(1290)),
        ] {
            let record = try Self.antigravityResponse(display: display)
            #expect(record.model == display)
            #expect(record.usage == Self.usage)
            #expect(table.reportModelId(model: record.model, provider: record.provider) == canonical)
            #expect(table.cost(of: record) == expected)
        }
    }

    @Test func antigravityResponseModelStillPrecedesItsDisplayLabel() throws {
        let table = PriceBook.bundled
        let canonical = try Self.antigravityResponse(responseModel: "gemini-4-argon", display: "Gemini 3.8 Flash")
        #expect(canonical.model == "gemini-4-argon")
        #expect(table.reportModelId(model: canonical.model, provider: canonical.provider) == "gemini-4-argon")
        #expect(table.cost(of: canonical) == 1290)
        let privateModel = try Self.antigravityResponse(responseModel: "private-gemini-route", display: "Gemini 4 Argon")
        #expect(privateModel.model == "private-gemini-route")
        #expect(table.reportModelId(model: privateModel.model, provider: privateModel.provider) == "unknown")
        #expect(table.cost(of: privateModel) == nil)
    }

    @Test func aNewAliasPricesRetainedResponsesAndReportsTheCostOnlyOnce() throws {
        let current = PriceBook.bundled
        let old = try Self.withoutDatedFlashAlias(current)
        var labeler = DayLabeler(timeZone: .current)
        let day = labeler.label(forMs: Self.endMs)
        let book = PriceBook(tables: [old], bindings: [day: old.version])
        var engine = SpeedEngine(pricing: book)
        let date = Date(timeIntervalSince1970: TimeInterval(Self.endMs) / 1000)
        let today = Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000)
        let records = [
            Self.record("dated", model: Self.datedFlash),
            Self.record("known", model: "deepseek-v4.1-flash"),
            Self.record("unknown", model: "deepseek-unrecognized-model"),
        ]
        for record in records {
            engine.upsert(record, project: "synthetic", isCompletion: true, emitsEvents: true, nowMs: Self.endMs)
        }
        let before = engine.advance(nowMs: Self.endMs, todayStartMs: today, emitsEvents: true)
        #expect(before.todayCost == CostTally(costMicroUsd: 78, unpricedRequests: 2))
        #expect(before.report.counters.total.requests == 3)
        #expect(before.report.counters.total.costMicroUsd == 78)
        #expect(book.add(current))
        let after = engine.advance(nowMs: Self.endMs + 1000, todayStartMs: today, emitsEvents: true)
        #expect(book.boundVersion(forDay: day) == old.version)
        #expect(after.todayCost == CostTally(costMicroUsd: 156, unpricedRequests: 1))
        let delta = after.report.counters.since(before.report.counters).total
        #expect(delta.costMicroUsd == 78)
        #expect(delta.requests == 0 && delta.output == 0 && delta.input == 0 && delta.cachedInput == 0)
        #expect(engine.advance(nowMs: Self.endMs + 1500, todayStartMs: today, emitsEvents: true).report.counters == after.report.counters)

        let fresh = Self.record("fresh", model: Self.datedFlash)
        engine.upsert(fresh, project: "synthetic", isCompletion: true, emitsEvents: true, nowMs: Self.endMs + 2000)
        let first = engine.advance(nowMs: Self.endMs + 2000, todayStartMs: today, emitsEvents: true).report.counters
        #expect(first.total.requests == 4)
        #expect(first.total.costMicroUsd == 234)
        let freshDelta = first.since(after.report.counters).total
        #expect(freshDelta.requests == 1 && freshDelta.costMicroUsd == 78)
        #expect(freshDelta.input == 1000 && freshDelta.cachedInput == 900 && freshDelta.output == 100)
        engine.upsert(fresh, project: "synthetic", isCompletion: true, emitsEvents: true, nowMs: Self.endMs + 2500)
        #expect(engine.advance(nowMs: Self.endMs + 2500, todayStartMs: today, emitsEvents: true).report.counters == first)
    }

    static func record(_ key: String, model: String) -> ResponseRecord {
        ResponseRecord(key: key, source: .deepseek, agentId: "/synthetic/dsh", model: model,
                       startMs: endMs - 2000, endMs: endMs, usage: usage, isFinal: true, provider: "deepseek")
    }

    static func antigravityResponse(responseModel: String = "", display: String) throws -> ResponseRecord {
        let generation = AntigravityBlobEncoder.generation([1], responseModel: responseModel, display: display)
        let metadata = AntigravityBlobEncoder.step(
            created: endMs - 2000, finished: endMs,
            usage: AntigravityBlobEncoder.usage(input: 100, output: 100, cache: 900, responseId: "synthetic-response")
        )
        let batch = AntigravityBatch(
            generations: [AntigravityIndexedRow(idx: 0, value: generation.withUnsafeBytes { AntigravityBlobs.generation($0) })],
            steps: [AntigravityStepRow(idx: 1, stepType: AntigravityStep.plannerResponse, status: AntigravityStep.done,
                                      metadata: metadata.withUnsafeBytes { AntigravityBlobs.stepMetadata($0) })]
        )
        var parser = AntigravityParser(agentId: "/synthetic/antigravity.db", fileID: 0)
        var deduper = Deduper()
        var records: [ResponseRecord] = []
        parser.consume(batch, deduper: &deduper) { records.append($0.record) }
        #expect(records.count == 1)
        return try #require(records.first)
    }

    static func withoutDatedFlashAlias(_ table: PriceTable) throws -> PriceTable {
        var object = try #require(try JSONSerialization.jsonObject(with: table.data) as? [String: Any])
        var models = try #require(object["models"] as? [[String: Any]])
        let index = try #require(models.firstIndex { $0["id"] as? String == "deepseek-flash" })
        models[index]["aliases"] = (models[index]["aliases"] as? [String])?.filter { $0 != datedFlash }
        object["models"] = models
        let tests = try #require(object["tests"] as? [[String: Any]])
        object["tests"] = tests.filter { $0["model"] as? String != datedFlash }
        object["version"] = table.version - 1
        return try PriceTable.load(JSONSerialization.data(withJSONObject: object)).get()
    }
}
