import Foundation
import XCTest
@testable import CodexTokenBar

/// Inputs must be produced by the v0.9.1 implementation, never relabeled current databases.
final class ReleaseDatabaseUpgradeTests: XCTestCase {
    func testActualReleaseSixUpgradesWithoutLosingHistoricalComponents() throws {
        guard let input = ProcessInfo.processInfo.environment["CODEX_RELEASE_SWIFT_DATABASE"] else {
            throw XCTSkip("Provide the database exported by actual v0.9.1 code")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("actual-release-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("index.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: input), to: target)
        let db = SQLiteDatabaseDriver(url: target)
        func scalar(_ sql: String) throws -> Int64 { try XCTUnwrap(db.readRows(sql) { $0.int64(0) }.first ?? nil) }
        XCTAssertEqual(try db.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }.first!, "6")
        let fields = "source_id,source_offset,timestamp,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model"
        try db.execute("CREATE TABLE release_expected AS SELECT \(fields),tokens AS old_tokens FROM events")
        let count = try scalar("SELECT COUNT(*) FROM events")
        XCTAssertGreaterThan(count, 0)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: target)
        XCTAssertEqual(try db.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }.first!, "13")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM events"), count)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM (SELECT \(fields) FROM release_expected EXCEPT SELECT \(fields) FROM events)"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM (SELECT \(fields) FROM events EXCEPT SELECT \(fields) FROM release_expected)"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM events e JOIN release_expected r USING(source_id,source_offset) WHERE e.legacy_tokens IS NOT r.old_tokens"),0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM usage_ledger_bindings"),count)
        let total = try scalar("SELECT SUM(tokens) FROM events")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: target)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM events"),count)
        XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),total)
        if let homePath = ProcessInfo.processInfo.environment["CODEX_RELEASE_SWIFT_HISTORICAL_HOME"] {
            let home = URL(fileURLWithPath: homePath)
            let files = (FileManager.default.enumerator(at:home,includingPropertiesForKeys:nil)!.allObjects as! [URL]).filter{$0.pathExtension == "jsonl"}.sorted{$0.path<$1.path}
            XCTAssertEqual(files.count,164)
            XCTAssertGreaterThan(count,1000)
            let analyzer=CodexUsageAnalyzer(dataSource:CodexDataSource(codexHome:home,origin:.userSelected))
            func sync(_ files:[URL]) throws -> CodexUsageHistoryIndex.SynchronizationResult {
                let index=try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL:target)
                return try index.synchronize(files:files,sessionID:analyzer.sessionID(from:)) { file,id,request,fp,emit in
                    try analyzer.parseSessionIntoHistoryIndex(file:file,sessionID:id,request:request,insertFingerprint:fp,emit:emit)
                }
            }
            let first=try sync(files)
            let baseline=try scalar("SELECT SUM(tokens) FROM events")
            let warm=try sync(files)
            XCTAssertEqual(warm.changedFiles,0)
            XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),baseline)
            if let output=ProcessInfo.processInfo.environment["CODEX_RELEASE_SWIFT_UPGRADED_OUTPUT"] {
                let url=URL(fileURLWithPath:output)
                XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
                try SQLiteDatabaseDriver(url:url,enableWAL:false).withConnection { try $0.restoreDatabase(from:target) }
            }
            let probe=home.appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl")
            XCTAssertFalse(FileManager.default.fileExists(atPath:probe.path))
            defer { try? FileManager.default.removeItem(at:probe) }
            func token(_ sum:Int,_ last:Int) throws -> Data {
                let counters:(Int)->[String:Int] = { ["input_tokens":$0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":$0] }
                let event:[String:Any] = ["timestamp":ISO8601DateFormatter().string(from:Date()),"type":"event_msg","payload":["type":"token_count","info":["total_token_usage":counters(sum),"last_token_usage":counters(last)]]]
                var data=try JSONSerialization.data(withJSONObject:event);data.append(10);return data
            }
            try token(5,5).write(to:probe)
            _=try sync(files+[probe]);XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),baseline+5)
            let out=try FileHandle(forWritingTo:probe);try out.seekToEnd();try out.write(contentsOf:token(12,7));try out.close()
            let appended=try sync(files+[probe]);XCTAssertEqual(appended.incrementallyParsedFiles,1)
            XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),baseline+12)
            _=try sync([]);XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),baseline+12)
            print("REAL HISTORY Swift: first changed \(first.changedFiles), warm changed \(warm.changedFiles), +5/+7 incremental probe and all-source disappearance retained, baseline \(baseline)")
        }
        if let homePath = ProcessInfo.processInfo.environment["CODEX_RELEASE_SWIFT_HOME"] {
            let home = URL(fileURLWithPath: homePath)
            let file = home.appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl")
            let original = try Data(contentsOf: file)
            defer { try? original.write(to: file) }
            let lines = String(decoding: original, as: UTF8.self).split(separator: "\n")
            let previous = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String:Any]
            func token(_ total: Int, _ last: Int) throws -> String {
                var event = previous
                var payload = event["payload"] as! [String:Any]
                var info = payload["info"] as! [String:Any]
                var cumulative = info["total_token_usage"] as! [String:Any]
                var latest = info["last_token_usage"] as! [String:Any]
                cumulative["input_tokens"] = total; cumulative["total_tokens"] = total
                latest["input_tokens"] = last; latest["total_tokens"] = last
                info["total_token_usage"] = cumulative; info["last_token_usage"] = latest
                payload["info"] = info; event["payload"] = payload
                event["timestamp"] = ISO8601DateFormatter().string(from: Date())
                return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            }
            let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
            func sync(_ files: [URL]) throws -> CodexUsageHistoryIndex.SynchronizationResult {
                let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: target)
                return try index.synchronize(files: files, sessionID: analyzer.sessionID(from:)) { file,id,request,fp,emit in
                    try analyzer.parseSessionIntoHistoryIndex(file:file,sessionID:id,request:request,insertFingerprint:fp,emit:emit)
                }
            }
            let header = #"{"type":"session_meta","payload":{"id":"019ff8b9-09e7-75c1-b9a5-14fe7b60065a","history_mode":"paginated"}}"#
            try ([header,token(100,20),token(105,5)].joined(separator:"\n")+"\n").write(to:file,atomically:true,encoding:.utf8)
            _ = try sync([file]); XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),105)
            _ = try sync([file]); XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),105)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data((token(112,7)+"\n").utf8)); try handle.close()
            XCTAssertEqual(try sync([file]).incrementallyParsedFiles,1)
            XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),112)
            _ = try sync([]); XCTAssertEqual(try scalar("SELECT SUM(tokens) FROM events"),112)
            print("ACTUAL RELEASE Swift rewrite 100 -> 105, incremental append 112, missing source retained")
        }
        print("ACTUAL RELEASE 6 -> 13: \(count) rows, every original component and old total preserved; reopen stable; total \(total)")
    }
}
