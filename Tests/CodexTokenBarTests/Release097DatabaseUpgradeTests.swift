import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

/// Inputs are produced by the pinned public implementation, never by changing
/// the version marker of a current database. The dedicated hosted lane requires
/// these inputs and fails if any fixture is absent; ordinary tests may opt out.
final class Release097DatabaseUpgradeTests: XCTestCase {
    private let releaseSHA = "0219554ce444b0013987da7b82e3c2e891f4afdb"
    private let names = ["a", "b"].map { String(repeating: $0, count: 64) + ".sqlite" }
    private let sessionID = "019ff8b9-09e7-75c1-b9a5-14fe7b60065a"
    private let durableTables = [
        "events", "sources", "usage_ledger_meta", "usage_ledger_bindings", "usage_ledger_identities",
        "usage_ledger_turns", "usage_ledger_unresolved", "usage_ledger_sources", "usage_ledger_corrections"
    ]
    private struct Fixture {
        let root: URL
        let original: URL
        let configuration: BusinessDatabaseMigration.Configuration
    }
    private struct TableRows: Equatable {
        let columns: [String]
        let rows: [[Data]]
    }
    private enum Injected: Error { case beforeActivation }

    private func fixture() throws -> Fixture {
        guard let configured = ProcessInfo.processInfo.environment["TOKENBAR_V097_INPUTS"] else {
            if ProcessInfo.processInfo.environment["TOKENBAR_V097_REQUIRE_FIXTURES"] == "1" {
                XCTFail("The required public-release fixture path is missing")
                throw CocoaError(.fileReadNoSuchFile)
            }
            throw XCTSkip("Run the dedicated release-upgrade compatibility workflow for actual v0.9.7 inputs")
        }
        let original = URL(fileURLWithPath: configured).resolvingSymlinksInPath()
        let provenance = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("provenance.json"))) as? [String: Any])
        XCTAssertEqual(provenance["release_sha"] as? String, releaseSHA)
        XCTAssertEqual(provenance["synthetic"] as? Bool, true)
        let verified = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("fixture-result.json"))) as? [String: Any])
        XCTAssertEqual(verified["verified"] as? Bool, true)
        XCTAssertEqual(verified["release_sha"] as? String, releaseSHA)
        let artifacts = try XCTUnwrap(verified["artifacts"] as? [String: [String: Any]])
        for (relative, artifact) in artifacts {
            XCTAssertEqual(try digest(original.appendingPathComponent(relative)), artifact["sha256"] as? String)
        }
        XCTAssertEqual(artifacts.count, 4)
        let proposed = FileManager.default.temporaryDirectory.appendingPathComponent("release097-upgrade-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        let root = proposed.resolvingSymlinksInPath()
        try FileManager.default.copyItem(at: original.appendingPathComponent("exact"), to: root.appendingPathComponent("exact"))
        try FileManager.default.copyItem(at: original.appendingPathComponent("support"), to: root.appendingPathComponent("support"))
        addTeardownBlock {
            BusinessSQLiteRoutes.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = configuration(root)
        for name in names {
            let database = raw(configuration.exact.appendingPathComponent(name))
            XCTAssertEqual(try database.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }, ["14"])
            XCTAssertGreaterThan(try count(database, "events"), 0)
        }
        return Fixture(root: root, original: original, configuration: configuration)
    }

    private func configuration(_ root: URL) -> BusinessDatabaseMigration.Configuration {
        let support = root.appendingPathComponent("support", isDirectory: true)
        return .init(container: support.appendingPathComponent("codex-ledger.sqlite"), support: support,
                     exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("legacy-exact"))
    }
    private func raw(_ url: URL) -> SQLiteDatabaseDriver {
        SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
    }
    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func count(_ database: SQLiteDatabaseDriver, _ table: String) throws -> Int64 {
        try XCTUnwrap(database.readRows("SELECT COUNT(*) FROM \(SQLiteStoreNamespace.quote(table))") { $0.int64(0) }.first ?? nil)
    }
    private func total(_ url: URL) throws -> Int64 {
        try XCTUnwrap(SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
            .readRows("SELECT COALESCE(SUM(tokens),0) FROM events") { $0.int64(0) }.first ?? nil)
    }
    private func rows(_ database: SQLiteDatabaseDriver, table: String, columns: [String]? = nil) throws -> TableRows {
        let selected = try columns ?? database.readRows("PRAGMA table_info(\(SQLiteStoreNamespace.quote(table)))") { $0.text(1)! }
        let values = try database.readRows("SELECT \(selected.map(SQLiteStoreNamespace.quote).joined(separator: ",")) FROM \(SQLiteStoreNamespace.quote(table))") { row in
            selected.indices.map { row.canonicalBytes(Int32($0)) }
        }
        // Compare typed rows as a multiset. Storage order is not accounting.
        return TableRows(columns: selected, rows: values.sorted { left, right in
            for (a, b) in zip(left, right) where a != b { return a.lexicographicallyPrecedes(b) }
            return left.count < right.count
        })
    }
    private func migrate(_ fixture: Fixture, beforeActivation: (() throws -> Void)? = nil) throws {
        try BusinessDatabaseMigration.migrate(fixture.configuration, availableBytes: 1 << 34, beforeActivation: beforeActivation)
    }
    private func compareAccounting(_ fixture: Fixture) throws {
        for name in names {
            let old = raw(fixture.original.appendingPathComponent("exact/" + name))
            let current = SQLiteDatabaseDriver(url: fixture.configuration.exact.appendingPathComponent(name), readOnly: true, createsFileIfMissing: false)
            XCTAssertEqual(current.backingURL.standardizedFileURL.path, fixture.configuration.container.standardizedFileURL.path)
            for table in durableTables {
                let expected = try rows(old, table: table)
                XCTAssertEqual(try rows(current, table: table, columns: expected.columns), expected, "\(name): every old typed field in \(table)")
            }
        }
    }

    func testActualV097ExactAndQuotaKeepEveryHistoricalFieldAndOriginal() throws {
        let f = try fixture()
        let quota = f.configuration.support.appendingPathComponent("quota-history.sqlite")
        let quotaBefore = try raw(quota).withConnection { try CodexBusinessDatabase.proof($0) }
        let originalBytes = try Dictionary(uniqueKeysWithValues: (names.map { f.configuration.exact.appendingPathComponent($0) } + [quota]).map { ($0, try Data(contentsOf: $0)) })
        try migrate(f)
        try compareAccounting(f)
        let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: quota))
        let imported = try raw(f.configuration.container).withConnection {
            try CodexBusinessDatabase.proof($0, namespace: SQLiteStoreNamespace(prefix: store.prefix, objectNames: []))
        }
        XCTAssertEqual(imported, quotaBefore, "Quota schema, typed rows, primary keys, hidden rowids and sequences are exact")
        for (url, bytes) in originalBytes { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        let migratedQuota = SQLiteDatabaseDriver(url: quota)
        XCTAssertEqual(try migratedQuota.readRows("SELECT seq FROM sqlite_sequence WHERE name='quota_snapshots'") { $0.int(0) }, [12345])
        let stores = try raw(f.configuration.container).readRows("SELECT store_id FROM tb_stores WHERE module IN ('exact.swift','quota.swift')") { $0.text(0)! }
        XCTAssertEqual(stores.count, 3, "Two Homes with the same session UUID must retain independent accounts")
        for id in stores {
            let receiptURL = f.configuration.backups.appendingPathComponent(id).appendingPathComponent("receipt.json")
            let receipt = try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self, from: Data(contentsOf: receiptURL))
            XCTAssertNil(receipt.normalizationDeferredReason)
            XCTAssertEqual(try raw(URL(fileURLWithPath: receipt.backupPath)).withConnection { try CodexBusinessDatabase.proof($0) }, receipt.original)
        }
        print("V097_ACCOUNTING_PROOF exactHomes=2 quota=1 oldFieldsPreserved=true")
    }

    func testWarmRestartIncrementAndDeletedSourceKeepImportedConsumption() throws {
        let f = try fixture()
        try migrate(f)
        let url = f.configuration.exact.appendingPathComponent(names[0])
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: f.original.appendingPathComponent("home-a"), origin: .userSelected))
        let oldFile = f.original.appendingPathComponent("home-a/sessions/rollout-\(sessionID).jsonl")
        func sync(_ files: [URL]) throws -> CodexUsageHistoryIndex.SynchronizationResult {
            let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
            return try index.synchronize(files: files, sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request, insertFingerprint: fingerprint, emit: emit)
            }
        }
        _ = try sync([oldFile])
        XCTAssertEqual(try total(url), 155)
        XCTAssertEqual(try sync([oldFile]).changedFiles, 0)
        let added = f.root.appendingPathComponent("rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065b.jsonl")
        let line = #"{"timestamp":"2026-10-21T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7},"last_token_usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}}"#
        try (line + "\n").write(to: added, atomically: true, encoding: .utf8)
        _ = try sync([oldFile, added])
        XCTAssertEqual(try total(url), 162)
        _ = try sync([oldFile, added])
        XCTAssertEqual(try total(url), 162)
        try FileManager.default.removeItem(at: added)
        _ = try sync([])
        XCTAssertEqual(try total(url), 162, "Source disappearance must never erase recorded consumption")
        XCTAssertEqual(try total(f.configuration.exact.appendingPathComponent(names[1])), 310)
        BusinessSQLiteRoutes.deactivate()
        try migrate(f)
        XCTAssertEqual(try total(url), 162, "A restart must not reimport the frozen v0.9.7 total of 155")
    }

    func testInterruptedActivationRechecksChangedOldQuotaAndResumes() throws {
        let f = try fixture()
        XCTAssertThrowsError(try migrate(f, beforeActivation: { throw Injected.beforeActivation }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.path))
        XCTAssertNil(BusinessSQLiteRoutes.store(for: f.configuration.exact.appendingPathComponent(names[0])))
        let quota = f.configuration.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota, bypassBusinessRoutes: true).execute("INSERT INTO quota_snapshots(id,created_at,account_key,status) VALUES(43,1800000001,'late-synthetic','available')")
        try migrate(f)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota).readRows("SELECT id FROM quota_snapshots ORDER BY id") { $0.int(0) }, [42, 43])
        try compareAccounting(f)
    }

    func testPendingSourceDisappearanceCannotActivateAndRestoredSourceResumes() throws {
        let f = try fixture()
        XCTAssertThrowsError(try migrate(f, beforeActivation: { throw Injected.beforeActivation }))
        let quota = f.configuration.support.appendingPathComponent("quota-history.sqlite")
        let saved = quota.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: quota, to: saved)
        XCTAssertThrowsError(try migrate(f))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.appendingPathExtension("initialized").path))
        try FileManager.default.moveItem(at: saved, to: quota)
        try migrate(f)
        try compareAccounting(f)
    }

    func testMissingCommittedContainerCannotResurrectFrozenReleaseFiles() throws {
        let f = try fixture()
        try migrate(f)
        BusinessSQLiteRoutes.deactivate()
        try FileManager.default.moveItem(at: f.configuration.container, to: f.configuration.container.appendingPathExtension("preserved"))
        XCTAssertThrowsError(try migrate(f))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.configuration.container.appendingPathExtension("preserved").path))
    }

    func testCommittedWALAndSpaceFailureRetainActualReleaseRows() throws {
        let f = try fixture()
        let quota = f.configuration.support.appendingPathComponent("quota-history.sqlite")
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        writer.arguments = ["python3", "-c", "import os,sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('PRAGMA journal_mode=WAL'); c.execute(\"INSERT INTO quota_snapshots(id,created_at,account_key,status) VALUES(43,1800000001,'committed-wal','available')\"); c.commit(); os._exit(0)", quota.path]
        try writer.run(); writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quota.path + "-wal"))
        let before = try raw(quota).withConnection { try CodexBusinessDatabase.proof($0) }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(f.configuration, availableBytes: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.path))
        try migrate(f)
        let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: quota))
        let after = try raw(f.configuration.container).withConnection {
            try CodexBusinessDatabase.proof($0, namespace: SQLiteStoreNamespace(prefix: store.prefix, objectNames: []))
        }
        XCTAssertEqual(after, before)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota).readRows("SELECT id FROM quota_snapshots ORDER BY id") { $0.int(0) }, [42, 43])
    }

    func testHardProcessExitBeforeActivationCanRestartFromCommittedCandidateWAL() throws {
        if let childRoot = ProcessInfo.processInfo.environment["TOKENBAR_V097_CRASH_CHILD_ROOT"] {
            let candidate = configuration(URL(fileURLWithPath: childRoot))
            try BusinessDatabaseMigration.migrate(candidate, availableBytes: 1 << 34, beforeActivation: {
                let path = candidate.container.deletingLastPathComponent().appendingPathComponent(".codex-ledger-migrating.sqlite")
                // Keep a real connection alive across _exit, otherwise SQLite's
                // last orderly close can checkpoint away the crash fixture WAL.
                try SQLiteDatabaseDriver(url: path, createsFileIfMissing: false, bypassBusinessRoutes: true).withConnection { connection in
                    try connection.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
                    try connection.transaction {
                        try $0.execute("INSERT INTO tb_container_meta(key,value) VALUES('release097_crash_probe','committed-before-exit')")
                    }
                    Darwin._exit(86)
                }
            })
            XCTFail("The injected process exit was not reached")
            return
        }
        let f = try fixture()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "CodexTokenBarTests.Release097DatabaseUpgradeTests/testHardProcessExitBeforeActivationCanRestartFromCommittedCandidateWAL", Bundle(for: Self.self).bundleURL.path]
        // xctest can print its environment on launcher errors. Only pass the
        // runtime variables needed by the isolated child, never credentials.
        let allowed = Set(["PATH", "TMPDIR", "HOME", "DEVELOPER_DIR", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "SDKROOT"])
        child.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        child.environment?["TOKENBAR_V097_CRASH_CHILD_ROOT"] = f.root.path
        let output = Pipe(); child.standardOutput = output; child.standardError = output
        let exited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in exited.signal() }
        try child.run()
        guard exited.wait(timeout: .now() + 60) == .success else {
            child.terminate()
            XCTFail("The isolated crash child did not reach its bounded exit")
            return
        }
        child.waitUntilExit()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(child.terminationReason, .exit, report)
        XCTAssertEqual(child.terminationStatus, 86, report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.container.path))
        let candidate = f.configuration.container.deletingLastPathComponent().appendingPathComponent(".codex-ledger-migrating.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path + "-wal"))
        XCTAssertEqual(try raw(candidate).readRows("SELECT value FROM tb_container_meta WHERE key='release097_crash_probe'") { $0.text(0) }, ["committed-before-exit"])
        try migrate(f)
        try compareAccounting(f)
        XCTAssertEqual(try raw(f.configuration.container).readRows("SELECT value FROM tb_container_meta WHERE key='release097_crash_probe'") { $0.text(0) }, ["committed-before-exit"])
        print("V097_CRASH_RESTART_PROOF abruptExit=86 rowsPreserved=true")
    }

    func testTagEncodedBodyJSONReachesBOnceAndLeavesAIntact() async throws {
        let f = try fixture()
        try migrate(f)
        let containerBefore = try raw(f.configuration.container).withConnection { try CodexBusinessDatabase.proof($0) }
        let logical = f.configuration.support.appendingPathComponent("body-speed-release097.sqlite")
        let shared = f.configuration.support.appendingPathComponent("multi-client-usage.sqlite")
        let json = f.configuration.support.appendingPathComponent("observed-speed-release097.json")
        let bytes = try Data(contentsOf: json)
        let first = try await BodySpeedSampleWriter(sharedURL: shared).load(from: logical, now: 1_800_000_600)
        XCTAssertEqual(first.map(\.id), ["v097-body"])
        let second = try await BodySpeedSampleWriter(sharedURL: shared).load(from: logical, now: 1_800_000_600)
        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: json), bytes)
        XCTAssertEqual(try raw(shared).readRows("PRAGMA user_version") { $0.int(0) }, [2])
        XCTAssertEqual(try raw(f.configuration.container).withConnection { try CodexBusinessDatabase.proof($0) }, containerBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logical.path))
    }
}
