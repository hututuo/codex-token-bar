import Foundation
import XCTest
@testable import CodexTokenBar

final class UsageHistoryRetentionTests: XCTestCase {
    private func fixture() throws -> SQLiteDatabaseDriver {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-retention-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
        let db = SQLiteDatabaseDriver(url: url)
        try db.execute("""
            INSERT INTO sources(source_id,path,session_id,size_bytes,modified_at,content_probe,last_seen_generation)
            VALUES (1,'/old/source.jsonl','child',1000,100,'probe','1');
            INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind)
            VALUES(1,100,1000,80,70,50,10,2,'gpt-5.6-sol',0),(1,200,1001,20,18,10,2,1,'gpt-5.6-sol',0);
            INSERT INTO source_fingerprints(source_id,value) VALUES(1,x'0000000000000000000000');
            INSERT INTO usage_ledger_bindings(source_id,event_id,generation,raw_offset) VALUES(1,100,'1',100),(1,200,'1',200);
            """)
        return db
    }

    private func scalar(_ sql: String, _ db: SQLiteDatabaseDriver) throws -> Int64 {
        try XCTUnwrap(db.readRows(sql) { $0.int64(0) }.first ?? nil)
    }

    func testReplacingEventsRetainsOldEvidenceWithoutChangingCurrentProjection() throws {
        let db = try fixture()
        try db.transaction { tx in
            try tx.execute("DELETE FROM events WHERE source_id=1; DELETE FROM source_fingerprints WHERE source_id=1;")
            try tx.execute("""
                INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model)
                VALUES(1,10,1001,20,18,10,2,1,'gpt-5.6-sol'),(1,20,1002,5,4,2,1,0,'gpt-5.6-sol');
                """)
        }
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_events", db), 100)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_fingerprints", db), 1)
        // P1 is the protection layer. Reconciliation, not adding 100+25,
        // will publish the effective ledger in the next implementation stage.
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", db), 25)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_events WHERE model='gpt-5.6-sol' AND accounting_kind=0", db), 2)
    }

    func testSourceCascadeCannotDeleteRetainedEventsOrFingerprints() throws {
        let db = try fixture()
        try db.execute("DELETE FROM sources WHERE source_id=1")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sources", db), 0)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_events", db), 100)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_fingerprints", db), 1)
    }

    func testFailedReplacementRollsBackCaptureAndDeletionTogether() throws {
        let db = try fixture()
        enum Abort: Error { case now }
        XCTAssertThrowsError(try db.transaction { tx in
            try tx.execute("DELETE FROM sources WHERE source_id=1")
            throw Abort.now
        })
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", db), 100)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_events", db), 0)
    }

    func testSourceIdentityChangeKeepsOriginalOwnerAndModel() throws {
        let db = try fixture()
        try db.execute("UPDATE sources SET session_id='new-owner',path='/new/file' WHERE source_id=1")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_sources WHERE session_id='child' AND path='/old/source.jsonl'", db), 1)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_events", db), 100)
    }

    func testReopenDoesNotWriteOrRearchiveUnchangedEvents() throws {
        let db = try fixture()
        try db.withConnection { connection in
            let before = try connection.readRows("SELECT total_changes()") { $0.int64(0) }.first
            try UsageHistoryRetention.install(on: connection)
            let after = try connection.readRows("SELECT total_changes()") { $0.int64(0) }.first
            XCTAssertEqual(before, after)
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_events", db), 0)
    }

    func testFutureRetentionContractIsRejectedWithoutDeletingEvidence() throws {
        let db = try fixture()
        try db.execute("UPDATE retained_usage_meta SET value='999' WHERE key='schema_version'")
        XCTAssertThrowsError(try db.withConnection { try UsageHistoryRetention.install(on: $0) })
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", db), 100)
    }
    func testAccountingAndModelChangesKeepEveryPriorVersionButNoOpDoesNot() throws {
        let db = try fixture()
        try db.execute("UPDATE events SET tokens=70,input_tokens=60 WHERE source_id=1 AND source_offset=100")
        try db.execute("UPDATE events SET model='corrected-model' WHERE source_id=1 AND source_offset=100")
        try db.execute("UPDATE events SET tokens=tokens,model=model WHERE source_id=1")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_revisions", db), 2)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_revisions", db), 150)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", db), 90)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_revisions WHERE model='gpt-5.6-sol'", db), 2)
    }

    func testMissingProtectionTriggerIsReinstalled() throws {
        let db = try fixture()
        try db.execute("DROP TRIGGER retain_usage_before_source_delete")
        try db.withConnection { try UsageHistoryRetention.install(on: $0) }
        try db.execute("DELETE FROM sources WHERE source_id=1")
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_events", db), 100)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_fingerprints", db), 1)
    }

    func testRepeatedReplacementAtSamePositionAndSignatureCannotOverwriteEvidence() throws {
        let db = try fixture()
        try db.execute("DELETE FROM events WHERE source_id=1 AND source_offset=100")
        try db.execute("""
            INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind)
            VALUES(1,100,1000,9,8,3,1,0,'another-model',0);
            DELETE FROM sources WHERE source_id=1;
            """)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_events", db), 100)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_revisions", db), 9)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_revisions WHERE model='another-model'", db), 1)
    }

    func testRetainedCheckpointSurvivesReplacementWithoutClaimingItCanResumeNewFile() throws {
        let db = try fixture()
        try db.execute("UPDATE sources SET append_ready=1,resume_offset=999,previous_total_tokens=300,is_explicit_subagent_fork=1,accounting_state='old-counter-proof' WHERE source_id=1")
        try db.execute("DELETE FROM events WHERE source_id=1")
        try db.execute("UPDATE sources SET resume_offset=25,previous_total_tokens=5,accounting_state='new-counter-proof' WHERE source_id=1")
        XCTAssertEqual(try scalar("SELECT resume_offset FROM retained_usage_checkpoints", db), 999)
        XCTAssertEqual(try scalar("SELECT previous_total_tokens FROM retained_usage_checkpoints", db), 300)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_checkpoints WHERE accounting_state='old-counter-proof' AND is_explicit_subagent_fork=1", db), 1)
    }

    func testFutureWriterIsRejectedByActualIndexOpen() throws {
        let db = try fixture()
        try db.execute("UPDATE retained_usage_meta SET value='999' WHERE key='writer_revision'")
        XCTAssertThrowsError(try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: db.url))
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events", db), 100)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_events", db), 0)
    }

    func testProtectedHistoricalFixturePreservesEveryNumericColumn() throws {
        guard let input = ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_RETENTION_SWIFT_FIXTURE"] else {
            throw XCTSkip("Set an immutable, closed SQLite snapshot to exercise a real historical fixture")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-real-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("isolated.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: input), to: copy)
        let db = SQLiteDatabaseDriver(url: copy)
        let allFields = "source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind,reported_total_tokens,legacy_tokens"
        try db.execute("CREATE TABLE test_expected_upgrade AS SELECT \(allFields) FROM events")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL:copy)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM (SELECT * FROM test_expected_upgrade EXCEPT SELECT \(allFields) FROM events)", db),0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM (SELECT \(allFields) FROM events EXCEPT SELECT * FROM test_expected_upgrade)", db),0)
        let upgradedCount = try scalar("SELECT COUNT(*) FROM events",db)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_bindings",db),upgradedCount)
        print("Real Swift schema12 to13: \(upgradedCount) rows unchanged, bindings complete")
        try db.execute("DROP TABLE test_expected_upgrade")

        let source = try scalar("SELECT source_id FROM events GROUP BY source_id ORDER BY COUNT(*) DESC LIMIT 1", db)
        let fields = "timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind,reported_total_tokens,legacy_tokens"
        try db.transaction { tx in
            try tx.execute("CREATE TEMP TABLE expected AS SELECT source_offset AS position,\(fields) FROM events WHERE source_id=?", bindings: [.int64(source)])
            try tx.execute("DELETE FROM sources WHERE source_id=?", bindings: [.int64(source)])
            let retained = "SELECT position,\(fields) FROM retained_usage_events"
            let missing = try tx.readRows("SELECT COUNT(*) FROM (SELECT * FROM expected EXCEPT \(retained))") { $0.int64(0) }.first
            let extra = try tx.readRows("SELECT COUNT(*) FROM (\(retained) EXCEPT SELECT * FROM expected)") { $0.int64(0) }.first
            XCTAssertEqual(missing, 0)
            XCTAssertEqual(extra, 0)
            let expected = try XCTUnwrap(tx.readRows("SELECT COUNT(*) FROM expected") { $0.int64(0) }.first ?? nil)
            let actual = try tx.readRows("SELECT COUNT(*) FROM retained_usage_events") { $0.int64(0) }.first
            XCTAssertGreaterThan(expected, 0)
            XCTAssertEqual(actual, expected)
            print("Protected historical Swift fixture: \(expected) event rows preserved field-for-field")
        }
    }

    func testOldRetentionRevisionAddsLocationsWithoutDiscardingOldEvidence() throws {
        let db = try fixture()
        try db.execute("DELETE FROM events WHERE source_id=1 AND source_offset=100")
        for name in ["event_delete", "source_delete", "identity_update", "fingerprint_delete", "event_update"] {
            try db.execute("DROP TRIGGER retain_usage_before_\(name)")
        }
        for table in ["retained_usage_events", "retained_usage_revisions"] {
            for column in ["user_prompt_start", "user_prompt_end", "assistant_response_start", "assistant_response_end", "token_source_offset"] {
                try db.execute("ALTER TABLE \(table) DROP COLUMN \(column)")
            }
        }
        try db.execute("UPDATE retained_usage_meta SET value='1' WHERE key='schema_version'; DELETE FROM retained_usage_meta WHERE key='writer_revision';")
        try db.withConnection { try UsageHistoryRetention.install(on: $0) }
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_events", db), 80)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_events WHERE token_source_offset IS NULL", db), 1)
        try db.execute("UPDATE events SET user_prompt_offset=120,assistant_start_offset=150 WHERE source_id=1 AND source_offset=200; UPDATE usage_ledger_bindings SET prompt_offset=120,assistant_offset=150 WHERE source_id=1 AND event_id=200; DELETE FROM sources WHERE source_id=1;")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM retained_usage_events WHERE user_prompt_start=120 AND assistant_response_start=150 AND token_source_offset=200", db), 1)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM retained_usage_events", db), 100)
    }

}
