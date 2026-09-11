import Foundation
import XCTest
@testable import CodexTokenBar

final class UsageEventLedgerTests: XCTestCase {
    private func fixture() throws -> SQLiteDatabaseDriver {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-ledger-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("index.sqlite")
        let db=SQLiteDatabaseDriver(url:url)
        try db.execute("""
            CREATE TABLE sources(source_id INTEGER PRIMARY KEY,path TEXT,session_id TEXT,size_bytes INTEGER,modified_at REAL,content_probe TEXT,last_seen_generation TEXT);
            CREATE TABLE event_enrichment_sources(source_id INTEGER PRIMARY KEY,parser_revision TEXT);
            CREATE TABLE events(source_id INTEGER,source_offset INTEGER,timestamp REAL,tokens INTEGER,input_tokens INTEGER,cached_input_tokens INTEGER,output_tokens INTEGER,reasoning_output_tokens INTEGER,model TEXT,user_prompt_offset INTEGER,assistant_start_offset INTEGER,accounting_kind INTEGER,reported_total_tokens INTEGER,legacy_tokens INTEGER,PRIMARY KEY(source_id,source_offset));
            INSERT INTO sources(source_id,path,session_id,size_bytes,modified_at,content_probe,last_seen_generation)
            VALUES(1,'/source.jsonl','child',1000,100,'old','legacy-generation');
            INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,user_prompt_offset,accounting_kind)
            VALUES(1,100,1000,80,80,0,0,0,'known-model',20,0),(1,200,1001,20,20,0,0,0,'known-model',120,0);
            """)
        try db.withConnection { try UsageEventLedger.install(on:$0) }
        return db
    }
    private func row(_ offset: Int64,_ tokens: Int64,_ identity: String? = nil) -> UsageEventLedger.Candidate {
        .init(rawOffset:offset,timestamp:2000,tokens:tokens,input:tokens,cached:0,output:0,reasoning:0,
              model:"new-model",promptOffset:10,assistantOffset:15,accountingKind:0,reported:tokens,legacy:nil,
              fingerprint:identity.map { Data($0.utf8) })
    }
    private func total(_ db: SQLiteDatabaseDriver) throws -> Int64 {
        try XCTUnwrap(db.readRows("SELECT SUM(tokens) FROM events") { $0.int64(0) }.first ?? nil)
    }

    func testOldReleaseRowsRewriteReopenAndAppendKeepOneNumericLedger() throws {
        let db=try fixture()
        try db.transaction { tx in
            try UsageEventLedger.beginGeneration(source:1,session:"child",generation:"rewrite",on:tx)
            // Legacy B has no per-event identity proof: keep its old numeric
            // fact and preserve the new observation for later association.
            XCTAssertEqual(try UsageEventLedger.admit(row(20,20,"b"),source:1,generation:"rewrite",admission:.reconcile,on:tx),.unresolved)
            _ = try UsageEventLedger.admit(row(30,5,"c"),source:1,generation:"rewrite",admission:.newConsumption,on:tx)
        }
        XCTAssertEqual(try total(db),105)
        try db.withConnection { try UsageEventLedger.install(on:$0) }
        try db.transaction { tx in
            let outcome=try UsageEventLedger.admit(row(30,5,"c"),source:1,generation:"rewrite",admission:.reconcile,on:tx)
            guard case .associated = outcome else { return XCTFail("proven identity should be reused") }
        }
        XCTAssertEqual(try total(db),105)
        try db.transaction { tx in
            _ = try UsageEventLedger.admit(row(40,7,"d"),source:1,generation:"rewrite",admission:.newConsumption,on:tx)
        }
        XCTAssertEqual(try total(db),112)
        XCTAssertEqual(try db.readRows("SELECT COUNT(*) FROM events WHERE source_offset IN (100,200) AND model='known-model' AND timestamp IN (1000,1001)") { $0.int(0) }.first,2)
        XCTAssertEqual(try db.readRows("SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=0") { $0.int(0) }.first,2)
    }

    func testRawOffsetReuseNeverOverwritesOrGroupsUnrelatedCalls() throws {
        let db=try fixture()
        try db.transaction { tx in
            try UsageEventLedger.beginGeneration(source:1,session:"child",generation:"rewrite",on:tx)
            _ = try UsageEventLedger.admit(row(100,5,"new-c"),source:1,generation:"rewrite",admission:.newConsumption,on:tx)
        }
        XCTAssertEqual(try total(db),105)
        XCTAssertEqual(try db.readRows("SELECT COUNT(DISTINCT user_prompt_offset) FROM events") { $0.int(0) }.first,3)
        XCTAssertEqual(try db.readRows("SELECT tokens FROM events WHERE source_id=1 AND source_offset=100") { $0.int(0) }.first,80)
    }

    func testConflictingIdentityDoesNotAutomaticallyCorrectHistoricalConsumption() throws {
        let db=try fixture()
        try db.transaction { tx in
            _ = try UsageEventLedger.admit(row(300,5,"c"),source:1,generation:"one",admission:.newConsumption,on:tx)
            XCTAssertEqual(try UsageEventLedger.admit(row(400,50,"c"),source:1,generation:"two",admission:.newConsumption,on:tx),.unresolved)
        }
        XCTAssertEqual(try total(db),105)
    }

    func testVerifiedUnchangedRawLocationAllowsAnAuditedCorrection() throws {
        let db=try fixture()
        try db.transaction { tx in
            let result=try UsageEventLedger.admit(row(100,70,"corrected-a"),source:1,generation:"checked",
                admission:.reconcile,unchangedFromGeneration:"legacy-generation",correctionRevision:"verified-parser",on:tx)
            guard case .associated = result else { return XCTFail("same proved observation must correct once") }
        }
        XCTAssertEqual(try total(db),90)
        XCTAssertEqual(try db.readRows("SELECT old_tokens || ':' || new_tokens FROM usage_ledger_corrections") { $0.text(0) }.first,"80:70")
        // An unrelated rewrite with the same fingerprint still cannot change it.
        try db.transaction { tx in
            XCTAssertEqual(try UsageEventLedger.admit(row(2000,7,"corrected-a"),source:1,generation:"unproved",admission:.reconcile,on:tx),.unresolved)
        }
        XCTAssertEqual(try total(db),90)
    }

    func testIncompleteLedgerFailsClosedWithoutRebootstrap() throws {
        let db=try fixture()
        try db.execute("DROP TABLE usage_ledger_bindings")
        XCTAssertThrowsError(try db.withConnection { try UsageEventLedger.install(on:$0) })
        XCTAssertEqual(try total(db),100)
    }

    func testInterruptedPublishRollsBackBindingsAndConsumptionTogether() throws {
        let db=try fixture()
        enum Abort: Error { case now }
        XCTAssertThrowsError(try db.transaction { tx in
            try UsageEventLedger.beginGeneration(source:1,session:"child",generation:"rewrite",on:tx)
            _ = try UsageEventLedger.admit(row(300,5,"c"),source:1,generation:"one",admission:.newConsumption,on:tx)
            throw Abort.now
        })
        XCTAssertEqual(try total(db),100)
        XCTAssertEqual(try db.readRows("SELECT COUNT(*) FROM usage_ledger_bindings WHERE available=1") { $0.int(0) }.first,2)
    }

    func testReopenHasNoWriteAndIdentityChangeFailsBeforeBindingMutation() throws {
        let db=try fixture()
        try db.withConnection { tx in
            let before=try tx.readRows("SELECT total_changes()") { $0.int64(0) }.first
            try UsageEventLedger.install(on:tx)
            XCTAssertEqual(try tx.readRows("SELECT total_changes()") { $0.int64(0) }.first,before)
            XCTAssertThrowsError(try UsageEventLedger.beginGeneration(source:1,session:"another-task",generation:"rewrite",on:tx))
        }
        XCTAssertEqual(try total(db),100)
    }
}
