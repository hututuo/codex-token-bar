import XCTest
@testable import CodexTokenBar

final class ModelPresentationIdentityTests: XCTestCase {
    struct Fixture: Decodable { let raw:String;let expected:ModelPresentationIdentity }
    func testModelPresentationMatchesSharedCrossPlatformCases() throws {
        let url=try XCTUnwrap(AppResources.url(forResource:"model-presentation-cases",withExtension:"json"))
        let cases=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:url))
        XCTAssertGreaterThan(cases.count,30)
        for row in cases {XCTAssertEqual(ModelPresentationIdentity.resolve(row.raw),row.expected,row.raw)}
    }
    func testDisplayGroupingConservesRawTokensAndAlreadyPricedContributions() throws {
        func row(_ client:UsageClient,_ model:String,_ input:Int64,_ output:Int64,_ cost:Double?,_ unpriced:Int=0)->ClientUsageSummary {
            .init(client:client,model:model,inputTokens:input,outputTokens:output,cacheReadTokens:0,cacheWriteTokens:0,
                  reasoningTokens:0,requests:2,lastSeen:.distantPast,incompleteFields:false,apiCostUSD:cost,unpricedRequests:unpriced)
        }
        let rows=[row(.antigravity,"gemini-4-argon",100,20,0.3),row(.antigravity,"gemini-4-argon-high",200,30,0.7),
                  row(.antigravity,"gemini-3.8-flash",10,5,0.1),row(.antigravity,"gemini-3.8-flash-high",20,5,0.2,1),
                  row(.antigravity,"gemini-3.8-flash-n",50,5,nil,2),row(.gemini,"gemini-4-argon",70,5,0.4)]
        let before=rows
        let projected=ClientModelCostPeriods.modelItems(rows,[],allowed:["antigravity","gemini"])
        XCTAssertEqual(projected.count,3)
        XCTAssertEqual(projected.reduce(0){$0+$1.tokens},rows.reduce(0){$0+Int($1.inputTokens+$1.outputTokens)})
        XCTAssertEqual(projected.reduce(0){$0+($1.costUSD ?? $1.knownPartialCostUSD ?? 0)},1.7,accuracy:1e-12)
        let argon=try XCTUnwrap(projected.first{$0.id=="antigravity|gemini-4-argon"})
        XCTAssertEqual(argon.tokens,350);XCTAssertEqual(argon.costUSD,1)
        XCTAssertEqual(argon.sourceModels,["gemini-4-argon","gemini-4-argon-high"])
        let flash=try XCTUnwrap(projected.first{$0.id=="antigravity|gemini-3.8-flash"})
        XCTAssertNil(flash.costUSD);XCTAssertEqual(try XCTUnwrap(flash.knownPartialCostUSD),0.3,accuracy:1e-12)
        XCTAssertFalse(projected.contains{$0.id.hasSuffix("-n")})
        XCTAssertEqual(flash.tokens,95)
        XCTAssertEqual(rows,before,"Presentation must not rewrite original IDs or reprice events")
    }
    func testAllUnpricedRowsNeverTurnIntoKnownZeroCost() {
        let rows=[ClientUsageSummary(client:.antigravity,model:"gemini-4-argon-high",inputTokens:100,
            outputTokens:20,cacheReadTokens:nil,cacheWriteTokens:nil,reasoningTokens:nil,requests:1,
            lastSeen:.distantPast,incompleteFields:true,apiCostUSD:0,unpricedRequests:1)]
        let items=ClientModelCostPeriods.modelItems(rows,[],allowed:["antigravity"])
        XCTAssertEqual(items.first?.tokens,120);XCTAssertNil(items.first?.costUSD);XCTAssertNil(items.first?.knownPartialCostUSD)
    }

    func testDashboardCombinesEveryUnknownSourceIntoOneReferenceWithoutChangingKnownFees() throws {
        let models = ["unknown", "<unknown>", "null", "<synthetic>", "gemini-pro-default", "auto", "openrouter/auto", "future-model"]
        let rows = models.enumerated().map { index, model in
            ClientUsageSummary(client: index.isMultiple(of: 2) ? .antigravity : .claudeCode, model: model,
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 50, cacheWriteTokens: 0,
                reasoningTokens: 10, requests: 1, lastSeen: .distantPast, incompleteFields: false,
                apiCostUSD: index == 7 ? 0.25 : nil, unpricedRequests: index == 7 ? 0 : 1)
        }
        let raw = ModelTokenBreakdown(model: nil, breakdown: .init(inputTokens: 100, cachedInputTokens: 50,
            outputTokens: 20, reasoningOutputTokens: 10, totalTokens: 120, calls: 1))
        let items = ClientModelCostPeriods.modelItems(rows, [raw], allowed: ["codex", "antigravity", "claudeCode"])
        XCTAssertEqual(items.count, 1)
        let unknown = try XCTUnwrap(items.first)
        XCTAssertEqual(unknown.id, "unknown-models"); XCTAssertEqual(unknown.label, "未知模型")
        XCTAssertEqual(unknown.tokens, 1080); XCTAssertEqual(unknown.share, 1)
        XCTAssertEqual(unknown.sourceModels.count, 9)
        XCTAssertEqual(try XCTUnwrap(unknown.referenceCostUSD), OfficialAPIPriceModel.gpt56Sol.currentPriceRates.costUSD(for: raw.breakdown) * 9, accuracy: 1e-12)
        XCTAssertNil(unknown.costUSD); XCTAssertTrue(unknown.isReferenceOnly)
        XCTAssertEqual(FloatingTodayModelUsagePresentation.knownCostUSD(in: items), 0.25)
        XCTAssertFalse(unknown.valueText(for: .cost).contains("价格未知"))
        XCTAssertTrue(unknown.valueText(for: .cost).contains("参考"))
        let periods = ClientModelCostPeriods(lifetime: items, today: items, sevenDay: items)
        for scope in [DashboardModelCostScope.lifetime, .today, .sevenDay] {
            XCTAssertEqual(periods.groups(scope).last?.id, "unknown-models")
            XCTAssertEqual(periods.groups(scope).flatMap(\.items).count, 1)
        }
        let scoped = ClientModelCostPeriods.modelItems(rows, [raw], allowed: ["antigravity"])
        XCTAssertEqual(scoped.first?.tokens, 480, "Source selection still bounds the combined reference")
        XCTAssertNil(FloatingTodayModelUsagePresentation.knownCostUSD(in: scoped), "An estimate is not a measured zero-dollar bill")
    }

    func testCostGroupsNeverInventZeroUsageCatalogCards() {
        let used = FloatingTodayModelUsageItem(id: "claudeCode|claude-opus-5-5", label: "Opus5.5", tokens: 20,
            share: 1, costUSD: 0.2, usesIndependentQuota: false, referenceCostUSD: nil, color: .blue)
        let empty = FloatingTodayModelUsageItem(id: "claudeCode|fable-5-1", label: "Fable5.1", tokens: 0,
            share: 0, costUSD: 0, usesIndependentQuota: false, referenceCostUSD: nil, color: .blue)
        let periods = ClientModelCostPeriods(lifetime: [used,empty], today: [used,empty], sevenDay: [used,empty])
        for scope in [DashboardModelCostScope.lifetime, .today, .sevenDay] {
            let display = periods.groups(scope).flatMap(\.items)
            XCTAssertEqual(display.filter { !$0.isCatalogPlaceholder }.map(\.id), [used.id])
            XCTAssertEqual(display.filter(\.isCatalogPlaceholder).count, 3)
            XCTAssertTrue(display.filter(\.isCatalogPlaceholder).allSatisfy { $0.tokens == 0 && $0.costUSD == 0 && $0.share == 0 })
            XCTAssertEqual(periods.items(scope), [used, empty], "Catalog slots never enter the period's accounting inputs")
            XCTAssertEqual(FloatingTodayModelUsagePresentation.knownCostUSD(in: display), 0.2)
        }
    }
}
