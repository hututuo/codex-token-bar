import Foundation
import Darwin
import XCTest
import SQLite3
@testable import TokenBarDiagnosticsCore

final class DiagnosticBundleTests: XCTestCase {
    func testBoundedExportRetainsLatestSessionRegardlessOfUUIDFileOrder() throws {
        let root = try fixture(), configuration = DiagnosticConfiguration(home: root)
        try FileManager.default.createDirectory(at: configuration.journal, withIntermediateDirectories: true)
        let session = "11111111-1111-1111-1111-111111111111"
        for segment in 0..<7 {
            var bytes = Data()
            for index in 0..<1000 {
                let at = Int64(segment * 1000 + index)
                bytes.append(try JSONEncoder().encode(DiagnosticEvent(session: session, sequence: at, area: .refresh,
                    phase: .progress, version: "0.9.11", build: "1007", at: at)))
                bytes.append(10)
            }
            try bytes.write(to: configuration.journal.appendingPathComponent("events-a-\(segment).jsonl"))
        }
        // More than 128 unrelated entries cannot hide the real latest session.
        for index in 0..<130 { try Data().write(to: configuration.journal.appendingPathComponent("a-unused-\(index)")) }
        let latest = DiagnosticEvent(session: "ffffffff-ffff-ffff-ffff-ffffffffffff", sequence: 1, area: .startup,
            phase: .ready, version: "0.9.11", build: "1008", at: 10_000)
        let latestBytes = try JSONEncoder().encode(latest)
        let latestURL = configuration.journal.appendingPathComponent("events-z-latest.jsonl")
        try latestBytes.write(to: latestURL)
        let result = DiagnosticCollector.collect(.events, configuration: configuration)
        let rows = try XCTUnwrap(result["events"] as? [[String:Any]])
        XCTAssertEqual(rows.count, 6000); XCTAssertEqual(result["omitted"] as? Int, 1001)
        XCTAssertEqual(rows.last?["at"] as? Int64, 10_000)
        XCTAssertEqual(rows.last?["build"] as? String, "1008")
        XCTAssertEqual(try Data(contentsOf: latestURL), latestBytes)
    }
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("diagnostics-tests-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    func testDiagnosticsBundleAllowlistRemovesSecretsAndPaths() throws {
        let secret="sk-test-secret-DO-NOT-EXPORT", path="/Users/private-person/private-project"
        let value:[String:Any] = ["schema":1,"session":UUID().uuidString,"sequence":1,"at":123,"area":"refresh","phase":"failed",
            "version":secret,"build":path,"metrics":["code":5,"password":123],"authorization":secret,"conversation":path,"attempt":secret]
        let bytes=try JSONSerialization.data(withJSONObject:value)
        let event=try XCTUnwrap(DiagnosticEvent.sanitized(bytes))
        let output=try JSONEncoder().encode(event)
        let text=String(decoding:output,as:UTF8.self)
        XCTAssertFalse(text.contains(secret));XCTAssertFalse(text.contains(path));XCTAssertFalse(text.contains("password"))
        XCTAssertEqual(event.metrics,["code":5]);XCTAssertEqual(event.version,"unknown")
        XCTAssertNil(DiagnosticEvent.sanitized(Data("{\"schema\":999}".utf8)))
        let archive=try DiagnosticCollector.archive(probes:["environment":["status":secret,"version":path,"password":secret,
            "objects":[["path":path,"regular":true]]]])
        XCTAssertFalse(String(decoding:archive,as:UTF8.self).contains(secret))
        XCTAssertFalse(String(decoding:archive,as:UTF8.self).contains(path))
    }
    func testDiagnosticsCollectionLeavesDatabaseAndSourceTreeUnchanged() throws {
        let root=try fixture(), c=DiagnosticConfiguration(home:root)
        try FileManager.default.createDirectory(at:c.support,withIntermediateDirectories:true)
        let database=c.support.appendingPathComponent("codex-ledger.sqlite")
        let bytes=Data("locked database with private chat body and Bearer SECRET".utf8)
        try bytes.write(to:database)
        let before=try FileManager.default.subpathsOfDirectory(atPath:root.path).sorted()
        var probes:[String:[String:Any]]=[:]
        for probe in DiagnosticProbe.allCases { probes[probe.rawValue]=DiagnosticCollector.collect(probe,configuration:c) }
        let archive=try DiagnosticCollector.archive(probes:probes)
        XCTAssertEqual(try Data(contentsOf:database),bytes)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath:root.path).sorted(),before)
        XCTAssertFalse(String(decoding:archive,as:UTF8.self).contains("private chat"))
        XCTAssertFalse(String(decoding:archive,as:UTF8.self).contains(root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:c.journal.path))
        XCTAssertEqual(probes["storage"]?["databaseQueriesPerformed"] as? Bool,false)
    }
    func testDiagnosticsIgnoresHeldSQLiteExclusiveLock() throws {
        let root=try fixture(),c=DiagnosticConfiguration(home:root)
        try FileManager.default.createDirectory(at:c.support,withIntermediateDirectories:true)
        let path=c.support.appendingPathComponent("codex-ledger.sqlite")
        var connection:OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path,&connection),SQLITE_OK)
        defer{sqlite3_close(connection)}
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TABLE secret(body TEXT);INSERT INTO secret VALUES('PRIVATE CHAT');BEGIN EXCLUSIVE;",nil,nil,nil),SQLITE_OK)
        defer{sqlite3_exec(connection,"ROLLBACK",nil,nil,nil)}
        let before=try Data(contentsOf:path), names=try FileManager.default.subpathsOfDirectory(atPath:root.path).sorted(),at=Date()
        let state=DiagnosticCollector.collect(.storage,configuration:c)
        XCTAssertEqual(state["databaseQueriesPerformed"] as? Bool,false)
        XCTAssertLessThan(Date().timeIntervalSince(at),1)
        XCTAssertEqual(try Data(contentsOf:path),before)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath:root.path).sorted(),names)
    }
    func testDiagnosticsJournalPreservesPreviousFailedLaunch() throws {
        let root=try fixture().appendingPathComponent("diagnostics")
        let first=DiagnosticJournal(root:root,version:"0.9.11",build:"996")
        first.record(.startup,.started);first.record(.migration,.failed,metrics:["code":5])
        XCTAssertTrue(first.flush())
        let before=try DiagnosticFiles.files(root,prefix:"events-",suffix:".jsonl")
        let evidence=try DiagnosticFiles.read(XCTUnwrap(before.first))
        let second=DiagnosticJournal(root:root,version:"0.9.11",build:"997")
        second.record(.startup,.started);second.record(.startup,.ready);XCTAssertTrue(second.flush())
        XCTAssertEqual(try DiagnosticFiles.files(root,prefix:"events-",suffix:".jsonl").count,2)
        XCTAssertEqual(try DiagnosticFiles.read(XCTUnwrap(before.first)),evidence)
        XCTAssertEqual(try DiagnosticFiles.files(root,prefix:"failure-",suffix:".json").count,1)
    }
    func testDiagnosticsRefusesSymlinksHardlinksAndFIFOs() throws {
        let root=try fixture(), source=root.appendingPathComponent("private")
        try Data("secret".utf8).write(to:source)
        let link=root.appendingPathComponent("link"), hard=root.appendingPathComponent("hard"), fifo=root.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        XCTAssertThrowsError(try DiagnosticFiles.read(link))
        XCTAssertEqual(Darwin.link(source.path,hard.path),0)
        XCTAssertThrowsError(try DiagnosticFiles.read(hard))
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        let at=Date();XCTAssertThrowsError(try DiagnosticFiles.read(fifo));XCTAssertLessThan(Date().timeIntervalSince(at),1)
    }
    func testDiagnosticsAllowsDarwinTemporaryAliasButNotUserDirectoryLinks() throws {
        let root=try fixture(),file=root.appendingPathComponent("probe")
        try DiagnosticFiles.create(file,data:Data("safe".utf8))
        XCTAssertEqual(try DiagnosticFiles.read(file),Data("safe".utf8))
        let link=root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        XCTAssertThrowsError(try DiagnosticFiles.read(link.appendingPathComponent("probe")))
    }
    func testDiagnosticsTimeoutProducesPartialEvidenceWithoutHanging() throws {
        var at=Date()
        XCTAssertEqual(DiagnosticCLI.run(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["5"],timeout:0.08),"timeout")
        XCTAssertLessThan(Date().timeIntervalSince(at),1)
        let root=try fixture(), out=root.appendingPathComponent("report.zip")
        at=Date()
        try DiagnosticCLI.export(to:out,configuration:.init(home:root),executable:URL(fileURLWithPath:"/usr/bin/false"),probeTimeout:0.1)
        XCTAssertLessThan(Date().timeIntervalSince(at),3)
        let bytes=try Data(contentsOf:out)
        XCTAssertTrue(bytes.starts(with:[0x50,0x4b,3,4]))
        XCTAssertTrue(String(decoding:bytes,as:UTF8.self).contains("SUMMARY.md"))
        XCTAssertTrue(String(decoding:bytes,as:UTF8.self).contains("failed"))
    }
    func testDiagnosticsExportNeverOverwritesExistingDestination() throws {
        let root=try fixture(),file=root.appendingPathComponent("existing.zip"),bytes=Data("keep".utf8)
        try bytes.write(to:file)
        XCTAssertThrowsError(try DiagnosticCLI.export(to:file,configuration:.init(home:root),executable:URL(fileURLWithPath:"/usr/bin/false")))
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testDiagnosticsSeparatesBackendAndUIProgress() throws {
        let root=try fixture(), c=DiagnosticConfiguration(home:root)
        let journal=DiagnosticJournal(root:c.journal,version:"0.9.11",build:"997")
        journal.record(.backendProgress,.progress,metrics:["completed":10,"total":20])
        journal.record(.uiProgress,.progress,metrics:["completed":7,"total":20])
        XCTAssertTrue(journal.flush())
        let rows=try XCTUnwrap(DiagnosticCollector.collect(.events,configuration:c)["events"] as? [[String:Any]])
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual((rows[0]["metrics"] as? [String:Int])?["completed"],10)
        XCTAssertEqual((rows[1]["metrics"] as? [String:Int])?["completed"],7)
    }
    func testInstallationConfirmationRequiresMatchingTargetBuildAndLocation() throws {
        let root=try fixture(),c=DiagnosticConfiguration(home:root,application:root.appendingPathComponent("Token Bar.app"))
        let journal=DiagnosticJournal(root:c.journal,version:"0.9.11",build:"997"),id=UUID().uuidString
        DiagnosticInstallations.prepare(configuration:c,attempt:id,targetVersion:"0.9.11",targetBuild:"997",sourceBuild:"996")
        DiagnosticInstallations.confirm(configuration:c,version:"0.9.11",build:"996",journal:journal)
        let elsewhere=DiagnosticConfiguration(home:root,application:root.appendingPathComponent("Other.app"))
        DiagnosticInstallations.confirm(configuration:elsewhere,version:"0.9.11",build:"997",journal:journal)
        XCTAssertTrue(journal.flush());XCTAssertTrue((try? DiagnosticFiles.files(c.journal,prefix:"events-",suffix:".jsonl"))?.isEmpty ?? true)
        DiagnosticInstallations.confirm(configuration:c,version:"0.9.11",build:"997",journal:journal)
        XCTAssertTrue(journal.flush())
        let rows=try XCTUnwrap(DiagnosticCollector.collect(.events,configuration:c)["events"] as? [[String:Any]])
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0]["phase"] as? String,"confirmed")
    }
}
