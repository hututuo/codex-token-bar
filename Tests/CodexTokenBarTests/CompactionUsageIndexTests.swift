import Foundation
import XCTest
@testable import CodexTokenBar

/// Production parser -> staging/append admission -> canonical numeric ledger.
/// Only generated usage metadata is written; no user database is opened.
final class CompactionUsageIndexTests: XCTestCase {
    private func fixture(_ body: (URL,URL,CodexUsageHistoryIndex,CodexUsageAnalyzer,SQLiteDatabaseDriver) throws -> Void) throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("CompactionIndex-\(UUID())")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        let database=home.appendingPathComponent("exact.sqlite")
        let index=try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL:database)
        let analyzer=CodexUsageAnalyzer(dataSource:.init(codexHome:home,origin:.userSelected))
        try body(home,home.appendingPathComponent("session.jsonl"),index,analyzer,SQLiteDatabaseDriver(url:database))
    }
    private func line(_ type:String,_ payload:[String:Any],second:Int) throws -> String {
        String(data:try JSONSerialization.data(withJSONObject:["type":type,"payload":payload,
            "timestamp":String(format:"2026-10-31T00:00:%02d.000Z",second)]),encoding:.utf8)!+"\n"
    }
    private func synchronize(_ index:CodexUsageHistoryIndex,_ analyzer:CodexUsageAnalyzer,_ file:URL) throws {
        _=try index.synchronize(files:[file],sessionID:{ _ in "019eaaaa-bbbb-4ccc-8ddd-000000000001" }) {
            file,session,request,insert,emit in
            try analyzer.parseSessionIntoHistoryIndex(file:file,sessionID:session,request:request,
                insertFingerprint:insert,emit:emit)
        }
    }
    private func assertMeasured(_ driver:SQLiteDatabaseDriver) throws {
        let values=try driver.readRows("SELECT COUNT(*),SUM(tokens),SUM(accounting_kind) FROM events") {
            [$0.int(0) ?? -1,$0.int(1) ?? -1,$0.int(2) ?? -1]
        }
        XCTAssertEqual(values,[[1,95,0]])
    }
    func testUnknownThenMatchingUsageInOneScanUpdatesOneStagingRow() throws {
        try fixture { _,file,index,analyzer,driver in
            let marker=try line("compacted",["compaction_response_id":"resp-late"],second:1)
            let modern=try line("token_usage_record",["response_id":"resp-late","usage":[
                "input_tokens":80,"cached_input_tokens":30,"output_tokens":15,"reasoning_output_tokens":5,
                "total_tokens":95]],second:2)
            try (marker+modern).write(to:file,atomically:true,encoding:.utf8)
            try synchronize(index,analyzer,file)
            try assertMeasured(driver)
            XCTAssertTrue(try index.unreportedCompactionDates().isEmpty)
            try synchronize(index,analyzer,file)
            try assertMeasured(driver)
        }
    }
    func testUnknownThenUsageAppendedKeepsLedgerIDAndAudit() throws {
        try fixture { _,file,index,analyzer,driver in
            try line("compacted",["compaction_response_id":"resp-late"],second:1).write(to:file,atomically:true,encoding:.utf8)
            try synchronize(index,analyzer,file)
            let before=try driver.readRows("SELECT source_offset FROM events") { $0.int64(0) }.first!
            XCTAssertEqual(try index.unreportedCompactionDates().count,1)
            let modern=try line("token_usage_record",["response_id":"resp-late","usage":[
                "input_tokens":80,"cached_input_tokens":30,"output_tokens":15,"reasoning_output_tokens":5,
                "total_tokens":95]],second:2)
            let handle=try FileHandle(forWritingTo:file)
            try handle.seekToEnd();try handle.write(contentsOf:Data(modern.utf8));try handle.close()
            try synchronize(index,analyzer,file)
            try assertMeasured(driver)
            XCTAssertEqual(try driver.readRows("SELECT source_offset FROM events") { $0.int64(0) }.first!,before)
            XCTAssertTrue(try index.unreportedCompactionDates().isEmpty)
            XCTAssertEqual(try driver.readRows("SELECT COUNT(*) FROM usage_ledger_corrections") { $0.int(0) }.first,1)
        }
    }
    func testPreCompactionReceiptBackfillsUnchangedSourceWithoutLosingOldConsumption() throws {
        try fixture { _,file,index,analyzer,driver in
            let first=try line("event_msg",["type":"token_count","info":["last_token_usage":[
                "input_tokens":40,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":0,
                "total_tokens":60]]],second:0)
            let modern=try line("token_usage_record",["response_id":"resp-missed","usage":[
                "input_tokens":80,"cached_input_tokens":30,"output_tokens":15,"reasoning_output_tokens":5,
                "total_tokens":95]],second:1)
            let marker=try line("compacted",["compaction_response_id":"resp-missed"],second:2)
            try (first+modern+marker).write(to:file,atomically:true,encoding:.utf8)
            // Model the previous parser's publication: keep ordinary observations,
            // but do not publish the then-unsupported compaction request identity.
            _=try index.synchronize(files:[file],sessionID:{ _ in "019eaaaa-bbbb-4ccc-8ddd-000000000001" }) {
                file,session,request,insert,emit in
                try analyzer.parseSessionIntoHistoryIndex(file:file,sessionID:session,request:request,
                    insertFingerprint:{ fingerprint in
                        if !fingerprint.hasLastUsage && fingerprint.lastTokens == 2 { return false }
                        return try insert(fingerprint)
                    },emit:emit)
            }
            let oldID=try driver.readRows("SELECT source_offset FROM events WHERE tokens=60") { $0.int64(0) }.first!
            let current=try XCTUnwrap(driver.readRows("SELECT parser_revision FROM event_enrichment_sources") { $0.text(0) }.first ?? nil)
            let old=current.replacingOccurrences(of:"token-event-v4-",with:"token-event-v3-")
                .replacingOccurrences(of:"-compaction-v1",with:"")
            XCTAssertNotEqual(old,current)
            try driver.execute("UPDATE event_enrichment_sources SET parser_revision=?",bindings:[.text(old)])
            try synchronize(index,analyzer,file)
            XCTAssertEqual(try driver.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first,155)
            XCTAssertEqual(try driver.readRows("SELECT source_offset FROM events WHERE tokens=60") { $0.int64(0) }.first!,oldID)
            XCTAssertEqual(try driver.readRows("SELECT SUM(tokens) FROM canonical_usage_events") { $0.int(0) }.first,155)
            try synchronize(index,analyzer,file)
            XCTAssertEqual(try driver.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first,155)
        }
    }

}
