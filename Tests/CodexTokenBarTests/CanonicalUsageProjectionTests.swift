import XCTest
@testable import CodexTokenBar

final class CanonicalUsageProjectionTests: XCTestCase {
    func testCopiesUseOneProjectionWhileDivergentAndOtherSessionConsumptionSurvives() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("CanonicalUsage-"+UUID().uuidString)
        let home=root.appendingPathComponent("home"), cache=root.appendingPathComponent("cache")
        let sessions=home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
        let names=["CODEX_TOKEN_BAR_DISABLE_USAGE_CACHE","CODEX_TOKEN_BAR_USAGE_CACHE_DIR","CODEX_TOKEN_BAR_USAGE_CACHE_STATE_DIR"]
        let old=names.map { getenv($0).map { String(cString:$0) } }
        unsetenv(names[0]);setenv(names[1],cache.path,1);setenv(names[2],cache.path,1)
        defer {
            for (name,value) in zip(names,old) { if let value { setenv(name,value,1) } else { unsetenv(name) } }
            try? FileManager.default.removeItem(at:root)
        }
        let timestamp=Date(timeIntervalSince1970:1_700_000_100)
        func line(_ seconds:Double,_ cumulative:Int,_ last:Int) throws -> Data {
            func usage(_ count:Int)->[String:Int] { ["input_tokens":count,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":count] }
            let object:[String:Any]=["timestamp":ISO8601DateFormatter().string(from:timestamp.addingTimeInterval(seconds)),"type":"event_msg","payload":["type":"token_count","info":["total_token_usage":usage(cumulative),"last_token_usage":usage(last)]]]
            var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10);return data
        }
        let uuid="019eaaaa-bbbb-4ccc-8ddd-000000000001"
        let a=sessions.appendingPathComponent("a-\(uuid).jsonl")
        let b=sessions.appendingPathComponent("b-\(uuid).jsonl")
        let other=sessions.appendingPathComponent("c-019eaaaa-bbbb-4ccc-8ddd-000000000002.jsonl")
        let first=try line(0,100,100);try first.write(to:a);try first.write(to:b)
        let analyzer=CodexUsageAnalyzer(dataSource:.init(codexHome:home,origin:.userSelected))
        let index=try CodexUsageHistoryIndex(codexHome:home)
        func sync(_ files:[URL]) throws {
            _ = try index.synchronize(files:files,sessionID:analyzer.sessionID(from:)) { f,id,request,fingerprint,emit in
                try analyzer.parseSessionIntoHistoryIndex(file:f,sessionID:id,request:request,insertFingerprint:fingerprint,emit:emit)
            }
        }
        func assertTotals(_ expected:Int,file:StaticString=#filePath,line:UInt=#line) throws {
            var total=0;try index.forEachStoredEvent { total += $0.event.tokens }
            XCTAssertEqual(total,expected,file:file,line:line)
            let compact=try index.compactTotals(todayStart:timestamp.addingTimeInterval(-100),before:timestamp.addingTimeInterval(1000))
            XCTAssertEqual(compact.totalTokens,expected,file:file,line:line)
            let state=try index.attributionState()
            let ledger=try index.attributionSourceBuckets(provenanceEpoch:state.provenanceEpoch,from:timestamp.addingTimeInterval(-600),before:timestamp.addingTimeInterval(1000))
            XCTAssertEqual(ledger.reduce(0) { $0+$1.breakdown.totalTokens },expected,file:file,line:line)
        }
        try sync([a,b]);try assertTotals(100)
        // Same UUID: shared prefix is one call; genuine new suffix is another.
        var appended=first;appended.append(try line(30,150,50));try appended.write(to:b)
        try sync([a,b]);try assertTotals(150)
        // Different UUID: even equal fingerprints are separate consumption.
        // Fork inherited-prefix filtering remains the parser's responsibility.
        try first.write(to:other);try sync([a,b,other]);try assertTotals(250)
        try FileManager.default.removeItem(at:a);try FileManager.default.removeItem(at:b)
        try sync([other]);try assertTotals(250)
        try FileManager.default.removeItem(at:other);try sync([]);try assertTotals(250)
        let reopened=try CodexUsageHistoryIndex(codexHome:home)
        var retained=0;try reopened.forEachStoredEvent { retained += $0.event.tokens }
        XCTAssertEqual(retained,250)
    }
}
