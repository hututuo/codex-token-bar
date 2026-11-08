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
        XCTAssertEqual(projected.count,4)
        XCTAssertEqual(projected.reduce(0){$0+$1.tokens},rows.reduce(0){$0+Int($1.inputTokens+$1.outputTokens)})
        XCTAssertEqual(projected.reduce(0){$0+($1.costUSD ?? $1.knownPartialCostUSD ?? 0)},1.7,accuracy:1e-12)
        let argon=try XCTUnwrap(projected.first{$0.id=="antigravity|gemini-4-argon"})
        XCTAssertEqual(argon.tokens,350);XCTAssertEqual(argon.costUSD,1)
        XCTAssertEqual(argon.sourceModels,["gemini-4-argon","gemini-4-argon-high"])
        let flash=try XCTUnwrap(projected.first{$0.id=="antigravity|gemini-3.8-flash"})
        XCTAssertNil(flash.costUSD);XCTAssertEqual(try XCTUnwrap(flash.knownPartialCostUSD),0.3,accuracy:1e-12)
        XCTAssertNil(projected.first{$0.id.hasSuffix("-n")}?.costUSD)
        XCTAssertEqual(rows,before,"Presentation must not rewrite original IDs or reprice events")
    }
    func testAllUnpricedRowsNeverTurnIntoKnownZeroCost() {
        let rows=[ClientUsageSummary(client:.antigravity,model:"gemini-4-argon-high",inputTokens:100,
            outputTokens:20,cacheReadTokens:nil,cacheWriteTokens:nil,reasoningTokens:nil,requests:1,
            lastSeen:.distantPast,incompleteFields:true,apiCostUSD:0,unpricedRequests:1)]
        let items=ClientModelCostPeriods.modelItems(rows,[],allowed:["antigravity"])
        XCTAssertEqual(items.first?.tokens,120);XCTAssertNil(items.first?.costUSD);XCTAssertNil(items.first?.knownPartialCostUSD)
    }
}
