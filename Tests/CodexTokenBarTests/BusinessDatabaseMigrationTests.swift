import Foundation
import XCTest
@testable import CodexTokenBar

final class BusinessDatabaseMigrationTests: XCTestCase {
    func testIncompleteDiscoveryLogsIndependentRootsAndReadableInputsWithoutImporting() throws {
        let (_, c) = try fixture()
        for directory in [c.support, c.exact, c.legacyExact] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let manifests = [c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite.schema11-migration.json"),
                         c.legacyExact.appendingPathComponent(String(repeating: "b", count: 64) + ".sqlite.schema11-migration.json")]
        let manifestBytes = Data("{\"manifestVersion\":999}".utf8)
        for manifest in manifests { try manifestBytes.write(to: manifest) }
        let quota = c.support.appendingPathComponent("quota-history.sqlite")
        let corruptBytes = Data("not a SQLite database".utf8)
        try corruptBytes.write(to: quota)
        let valid = c.support.appendingPathComponent("shared-account-usage-safety.sqlite")
        try SQLiteDatabaseDriver(url: valid).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)) { error in
            guard case .batchFailures(let errors) = error as? BusinessDatabaseMigration.Failure else {
                return XCTFail("Independent discovery and database failures must be collected: \(error)")
            }
            XCTAssertEqual(errors.count, 3)
        }
        let events = try migrationEvents(c)
        XCTAssertEqual(events.filter { $0.stage == "discover-input" && $0.status == "failed" }.count, 2)
        XCTAssertEqual(events.filter { $0.stage == "blocked-input-readonly-proof" && $0.status == "failed" }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == "blocked-input-readonly-proof" && $0.status == "succeeded" }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == "store-import" && $0.status == "skipped" }.count, 2)
        XCTAssertFalse(events.contains { $0.stage == "store-import" && $0.status == "started" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.support.appendingPathComponent(".codex-ledger-migrating.sqlite").path))
        for manifest in manifests { XCTAssertEqual(try Data(contentsOf: manifest), manifestBytes) }
        XCTAssertEqual(try Data(contentsOf: quota), corruptBytes)
    }

    func testEverySourceLockFailureIsLoggedBeforeGlobalImportIsStopped() throws {
        let (_, c) = try fixture()
        var locks: [CodexCrossProcessFileLock] = []
        defer { for lock in locks { lock.release() } }
        for letter in ["a", "b"] {
            let exact = c.exact.appendingPathComponent(String(repeating: letter, count: 64) + ".sqlite")
            try SQLiteDatabaseDriver(url: exact).execute("CREATE TABLE schema_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO schema_meta VALUES('schema_version','99')")
            locks.append(try CodexCrossProcessFileLock(url: exact.appendingPathExtension("operation.lock"), label: "test held migration"))
        }
        let quota = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)) { error in
            guard case .batchFailures(let errors) = error as? BusinessDatabaseMigration.Failure else { return XCTFail("Missing independent lock errors: \(error)") }
            XCTAssertEqual(errors.count, 2)
        }
        let events = try migrationEvents(c)
        XCTAssertEqual(events.filter { $0.stage == "acquire-source-lock" && $0.status == "failed" }.count, 2)
        XCTAssertEqual(events.filter { $0.stage == "blocked-input-readonly-proof" && $0.status == "succeeded" }.count, 3)
        XCTAssertEqual(events.filter { $0.stage == "store-import" && $0.status == "skipped" }.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.support.appendingPathComponent(".codex-ledger-migrating.sqlite").path))
    }

    func testExactRootNestedInsideSupportIsImportedAndLockedOnlyOnce() throws {
        let (root, original) = try fixture()
        let c = BusinessDatabaseMigration.Configuration(container: original.container, support: original.support,
            exact: original.support.appendingPathComponent("exact"), legacyExact: original.legacyExact)
        let source = c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: source)
        let rollout = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"total_tokens\":120}}}}\n".utf8).write(to: rollout)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        _ = try index.synchronize(files: [rollout], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request, insertFingerprint: fingerprint, emit: emit)
        }
        let quota = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let physical = SQLiteDatabaseDriver(url: c.container, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try physical.readRows("SELECT module FROM tb_stores ORDER BY module") { $0.text(0) }, ["exact.swift", "quota.swift"])
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source).readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 120)
        let events = try migrationEvents(c)
        XCTAssertEqual(events.filter { $0.stage == "acquire-source-lock" && $0.status == "succeeded" }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == "duplicate-input" && $0.status == "coalesced" }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == "store-import" && $0.status == "succeeded" }.count, 2)
    }

    func testSamePhysicalInputAssignedToTwoStoresDoesNotChooseAnOverwriteSource() throws {
        let (_, c) = try fixture()
        let first = c.support.appendingPathComponent("body-speed-one.sqlite")
        let second = c.support.appendingPathComponent("body-speed-two.sqlite")
        let old = SQLiteDatabaseDriver(url: first)
        try old.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        try FileManager.default.linkItem(at: first, to: second)
        let original = try old.withConnection { try CodexBusinessDatabase.proof($0) }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.support.appendingPathComponent(".codex-ledger-migrating.sqlite").path))
        XCTAssertEqual(try old.withConnection { try CodexBusinessDatabase.proof($0) }, original)
        XCTAssertTrue(try migrationEvents(c).contains { $0.stage == "discover-ownership" && $0.status == "failed" })
    }

    private func migrationEvents(_ configuration: BusinessDatabaseMigration.Configuration) throws -> [BusinessMigrationDiagnostics.Event] {
        let paths = try BusinessMigrationDiagnostics.files(at: configuration.container.deletingLastPathComponent().appendingPathComponent("migration-diagnostics"))
        XCTAssertEqual(paths.count, 1)
        return try String(contentsOf: XCTUnwrap(paths.first), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(BusinessMigrationDiagnostics.Event.self, from: Data($0.utf8)) }
    }

    func testAllIndependentInputFailuresAreLoggedBeforeActivationIsWithheld() throws {
        let (_, c) = try fixture()
        try FileManager.default.createDirectory(at: c.support, withIntermediateDirectories: true)
        let broken = [c.support.appendingPathComponent("body-speed-broken.sqlite"),
                      c.support.appendingPathComponent("quota-history.sqlite")]
        let bytes = Data("deliberately invalid SQLite input".utf8)
        for file in broken { try bytes.write(to: file) }
        let valid = c.support.appendingPathComponent("shared-account-usage-safety.sqlite")
        try SQLiteDatabaseDriver(url: valid).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)) { error in
            guard case .batchFailures(let errors) = error as? BusinessDatabaseMigration.Failure else {
                return XCTFail("Both independent failures must appear in the same result: \(error)")
            }
            XCTAssertEqual(errors.count, 2)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.appendingPathExtension("initialized").path))
        for file in broken { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        let candidate = SQLiteDatabaseDriver(url: c.support.appendingPathComponent(".codex-ledger-migrating.sqlite"),
            readOnly: true, createsFileIfMissing: false, bypassBusinessRoutes: true)
        XCTAssertEqual(try candidate.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") { $0.text(0) }.first!, "importing")
        XCTAssertEqual(try candidate.readRows("SELECT module FROM tb_stores") { $0.text(0) }, ["safety.swift"],
            "A later independent store must finish its proof after earlier inputs fail")
        let paths = try BusinessMigrationDiagnostics.files(at: c.support.appendingPathComponent("migration-diagnostics"))
        XCTAssertEqual(paths.count, 1)
        let events = try String(contentsOf: XCTUnwrap(paths.first), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(BusinessMigrationDiagnostics.Event.self, from: Data($0.utf8)) }
        XCTAssertEqual(Set(events.filter { $0.stage == "store-import" && $0.status == "failed" }.compactMap { $0.details["module"] }),
            ["body.swift", "quota.swift"])
        XCTAssertEqual(events.filter { $0.stage == "store-import" && $0.status == "succeeded" }.count, 1)
        XCTAssertFalse(events.contains { $0.stage == "activate-container" })
        XCTAssertEqual(events.last?.stage, "attempt")
        XCTAssertEqual(events.last?.status, "failed")
        XCTAssertEqual(events.map(\.sequence), Array(1...events.count))

        for file in broken {
            try FileManager.default.removeItem(at: file)
            try SQLiteDatabaseDriver(url: file).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(7)")
        }
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: valid).readRows("SELECT id FROM samples") { $0.int(0) }, [42])
        for file in broken { XCTAssertEqual(try SQLiteDatabaseDriver(url: file).readRows("SELECT id FROM samples") { $0.int(0) }, [7]) }
    }

    func testUnchangedInterruptedMigrationReusesVerifiedSnapshotPair() throws {
        let (_, c) = try fixture()
        let source = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: source).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(77)")
        enum Stop: Error { case now }
        for _ in 0..<3 {
            XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { throw Stop.now }))
        }
        let files = try FileManager.default.subpathsOfDirectory(atPath: c.backups.path)
        XCTAssertEqual(files.filter { $0.contains("original-") && $0.hasSuffix(".sqlite") }.count, 1)
        XCTAssertEqual(files.filter { $0.contains("normalized-") && $0.hasSuffix(".sqlite") }.count, 1)
        XCTAssertEqual(try attemptReceipts(for: source, configuration: c).count, 1,
                       "An unchanged interrupted retry must reuse its attempt provenance receipt")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source).readRows("SELECT id FROM samples") { $0.int(0)! }, [77])
        XCTAssertEqual(try attemptReceipts(for: source, configuration: c).count, 1,
                       "Activation must not create another receipt for the same input snapshot")
    }

    func testRetryRejectsTruncatedLegacyHistoryAndIndependentlyChangedDestination() throws {
        for destinationChanged in [false, true] {
            BusinessSQLiteRoutes.deactivate()
            let (_, c) = try fixture()
            let source = c.support.appendingPathComponent("quota-history.sqlite")
            let old = SQLiteDatabaseDriver(url: source, bypassBusinessRoutes: true)
            try old.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY,tokens INTEGER); INSERT INTO samples VALUES(1,120),(2,55)")
            enum Stop: Error { case now }
            XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33, beforeActivation: { throw Stop.now }))
            let store = try XCTUnwrap(c.specification(for: source))
            let working = c.support.appendingPathComponent(".codex-ledger-migrating.sqlite")
            let frozen = SQLiteDatabaseDriver(url: working, bypassBusinessRoutes: true)
            let table = SQLiteStoreNamespace.quote(store.prefix + "samples")
            if destinationChanged {
                try frozen.execute("INSERT INTO \(table) VALUES(99,999)")
                try old.execute("INSERT INTO samples VALUES(3,10)")
            } else {
                try old.execute("DELETE FROM samples WHERE id=1")
            }
            let before = try frozen.withConnection { try CodexBusinessDatabase.proof($0) }
            let receipts = try attemptReceipts(for: source, configuration: c)
            let protected = try receipts.map { (URL(fileURLWithPath: $0.1.normalizedPath), try Data(contentsOf: URL(fileURLWithPath: $0.1.normalizedPath))) }
            XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)) { error in
                guard let failure = error as? BusinessDatabaseMigration.Failure else { return XCTFail("Unexpected error: \(error)") }
                if destinationChanged {
                    guard case .pendingDestinationChanged = failure else { return XCTFail("A changed destination must not be overwritten: \(failure)") }
                } else {
                    guard case .retryHistoryNotCovered = failure else { return XCTFail("Truncation must not replace the frozen complete history: \(failure)") }
                }
            }
            XCTAssertEqual(try frozen.withConnection { try CodexBusinessDatabase.proof($0) }, before)
            XCTAssertEqual(try frozen.readRows("SELECT id,tokens FROM \(table) ORDER BY id") { [$0.int(0), $0.int(1)] },
                destinationChanged ? [[1,120], [2,55], [99,999]] : [[1,120], [2,55]])
            for (url, data) in protected { XCTAssertEqual(try Data(contentsOf: url), data) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.appendingPathExtension("initialized").path))
        }
    }

    func testRetryAfterCommittedNamespaceWithoutAttemptJSONUsesFrozenDatabaseReceipt() throws {
        let (_, c) = try fixture()
        let source = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: source).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(88)")
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33, beforeActivation: { throw Stop.now }))
        let attempts = try attemptReceipts(for: source, configuration: c)
        let receipt = try XCTUnwrap(attempts.first)
        try FileManager.default.removeItem(at: receipt.0)
        try FileManager.default.removeItem(at: receipt.0.deletingLastPathComponent().appendingPathComponent("receipt.json"))
        try SQLiteDatabaseDriver(url: source, bypassBusinessRoutes: true).execute("INSERT INTO samples VALUES(89)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source).readRows("SELECT id FROM samples ORDER BY id") { $0.int(0) }, [88,89])
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.1.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.1.normalizedPath))
    }

    func testQuotaMaintenanceClockCanAdvanceDuringInterruptedRetryWithoutLosingObservations() throws {
        let (_, c) = try fixture()
        let source = c.support.appendingPathComponent("quota-history.sqlite")
        let old = SQLiteDatabaseDriver(url: source, bypassBusinessRoutes: true)
        try old.execute("CREATE TABLE quota_history_maintenance(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE samples(id INTEGER PRIMARY KEY,tokens INTEGER)")
        try old.execute("INSERT INTO quota_history_maintenance VALUES('policy_version','3'),('last_compacted_at','100'); INSERT INTO samples VALUES(1,120)")
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33, beforeActivation: { throw Stop.now }))
        try old.execute("UPDATE quota_history_maintenance SET value='200.5' WHERE key='last_compacted_at'; INSERT INTO samples VALUES(2,55)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let active = SQLiteDatabaseDriver(url: source)
        XCTAssertEqual(try active.readRows("SELECT SUM(tokens) FROM samples") { $0.int(0) }.first!, 175)
        XCTAssertEqual(try active.readRows("SELECT value FROM quota_history_maintenance WHERE key='last_compacted_at'") { $0.text(0) }.first!, "200.5")
        XCTAssertEqual(try attemptReceipts(for: source, configuration: c).count, 2)
    }

    func testExactSchemaThirteenUpgradeAndEquivalentBackupPathsCanResumeFrozenImport() throws {
        let (root, c) = try fixture()
        let source = c.exact.appendingPathComponent(String(repeating: "e", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: source)
        let file = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"cached_input_tokens\":30,\"total_tokens\":120}}}}\n".utf8).write(to: file)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        _ = try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        let raw = SQLiteDatabaseDriver(url: source, bypassBusinessRoutes: true)
        try raw.execute("DROP TABLE source_representations; DELETE FROM schema_meta WHERE key IN ('representation_revision','representation_upgrade_backup'); UPDATE schema_meta SET value='13' WHERE key='schema_version'")
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33, beforeActivation: { throw Stop.now }))
        let first = try XCTUnwrap(attemptReceipts(for: source, configuration: c).first?.1)
        XCTAssertEqual(try raw.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }.first!, "13")

        // A legacy application independently reaches the same additive schema
        // upgrade. Its backup path differs from our private normalization path.
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: source)
        XCTAssertEqual(try raw.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }.first!, "14")
        let retained = SQLiteDatabaseDriver(url: URL(fileURLWithPath: first.normalizedPath), readOnly: true, bypassBusinessRoutes: true)
        XCTAssertNotEqual(try raw.readRows("SELECT value FROM schema_meta WHERE key='representation_upgrade_backup'") { $0.text(0) },
            try retained.readRows("SELECT value FROM schema_meta WHERE key='representation_upgrade_backup'") { $0.text(0) })
        XCTAssertTrue(try CodexBusinessDatabase.snapshot(source, covers: URL(fileURLWithPath: first.normalizedPath),
            module: "exact.swift", legacySourceURL: source, expectedRetained: first.imported))
        try raw.execute("UPDATE events SET tokens=119,input_tokens=119")
        XCTAssertFalse(try CodexBusinessDatabase.snapshot(source, covers: URL(fileURLWithPath: first.normalizedPath),
            module: "exact.swift", legacySourceURL: source, expectedRetained: first.imported),
            "Equivalent representation backups do not authorize a changed numeric observation")
        try raw.execute("UPDATE events SET tokens=120,input_tokens=120")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source).readRows("SELECT SUM(tokens),SUM(cached_input_tokens) FROM events") { [$0.int(0), $0.int(1)] }.first!, [120,30])
        XCTAssertEqual(try attemptReceipts(for: source, configuration: c).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.normalizedPath))
    }

    func testReceiptWithOutsideSnapshotPathIsNotReusedOrModified() throws {
        let (root, c) = try fixture()
        let source = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: source).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(88)")
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { throw Stop.now }))
        let outside = root.appendingPathComponent("user-file.sqlite")
        let bytes = Data("unrelated user data".utf8)
        try bytes.write(to: outside)
        let receiptPath = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: c.backups.path).first { $0.hasSuffix("receipt.json") })
        let url = c.backups.appendingPathComponent(receiptPath)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["backupPath"] = outside.path
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source).readRows("SELECT id FROM samples") { $0.int(0)! }, [88])
    }

    private func fixture() throws -> (URL, BusinessDatabaseMigration.Configuration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("business-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        return (root, .init(container: support.appendingPathComponent("codex-ledger.sqlite"), support: support,
            exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("cache")))
    }

    private func attemptReceipts(for source: URL, configuration: BusinessDatabaseMigration.Configuration) throws -> [(URL, BusinessDatabaseMigration.Receipt)] {
        let store = try XCTUnwrap(configuration.specification(for: source))
        let folder = configuration.backups.appendingPathComponent(store.id, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("attempt-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                (url, try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self, from: Data(contentsOf: url)))
            }
    }

    func testMismatchedAttemptReceiptIsPreservedAndBlocksReuse() throws {
        let (_, c) = try fixture()
        let source = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: source).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(88)")
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { throw Stop.now }))

        let attempts = try attemptReceipts(for: source, configuration: c)
        let (attemptURL, receipt) = try XCTUnwrap(attempts.first)
        let attemptID = URL(fileURLWithPath: receipt.backupPath).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "original-", with: "")
        XCTAssertEqual(attemptURL.lastPathComponent, "attempt-\(attemptID).json")

        var mismatched = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: attemptURL)) as? [String: Any])
        mismatched["sourcePath"] = source.appendingPathComponent("different-source.sqlite").path
        let protectedBytes = try JSONSerialization.data(withJSONObject: mismatched, options: [.sortedKeys])
        try protectedBytes.write(to: attemptURL, options: .atomic)

        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)) { error in
            guard let failure = error as? BusinessDatabaseMigration.Failure,
                  case .unsafeInput(let path) = failure else {
                XCTFail("Expected the protected attempt receipt, received: \(error)")
                return
            }
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL,
                           attemptURL.resolvingSymlinksInPath().standardizedFileURL,
                           "The error must name the protected receipt even through /var aliases")
        }
        XCTAssertEqual(try Data(contentsOf: attemptURL), protectedBytes,
                       "Retry must not overwrite or repair a preexisting mismatched attempt receipt")
    }

    func testDirectoryAliasAndDeletedLegacyFileKeepOneRegisteredHistoryPartition() throws {
        let (root, physical) = try fixture()
        let legacy = physical.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: legacy).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        let alias = root.appendingPathComponent("support-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical.support)
        let configured = BusinessDatabaseMigration.Configuration(container: physical.container, support: alias,
            exact: physical.exact, legacyExact: physical.legacyExact)
        try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 32)
        let logical = alias.appendingPathComponent("quota-history.sqlite")
        XCTAssertEqual(BusinessSQLiteRoutes.store(for: legacy)?.id, BusinessSQLiteRoutes.store(for: logical)?.id)
        try SQLiteDatabaseDriver(url: logical).execute("INSERT INTO samples VALUES(43)")
        BusinessSQLiteRoutes.deactivate()
        try FileManager.default.removeItem(at: legacy)
        // A new launch may spell the same configured root physically. Ownership
        // is module/source identity, not whether the old leaf still resolves.
        try BusinessDatabaseMigration.migrate(physical, availableBytes: 0)
        let routed = SQLiteDatabaseDriver(url: legacy, readOnly: true, createsFileIfMissing: false)
        XCTAssertEqual(try routed.readRows("SELECT id FROM samples ORDER BY id") { $0.int(0)! }, [42,43])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let raw = SQLiteDatabaseDriver(url: physical.container, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM tb_stores WHERE module='quota.swift'") { $0.int(0) }.first!, 1)
    }
    func testRetryOfAddedLegacyInputDoesNotSkipChangedSource() throws {
        let (_, c) = try fixture()
        let active = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: active).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(100)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try SQLiteDatabaseDriver(url: active).execute("INSERT INTO samples VALUES(101)")
        BusinessSQLiteRoutes.deactivate()
        let added = c.support.appendingPathComponent("body-speed-late.sqlite")
        let raw = SQLiteDatabaseDriver(url: added, bypassBusinessRoutes: true)
        try raw.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(1)")
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { throw Stop.now }))
        try raw.execute("INSERT INTO samples VALUES(2)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let attempts = try attemptReceipts(for: added, configuration: c)
        XCTAssertEqual(attempts.count, 2, "A changed source must get a new attempt receipt while preserving the old attempt")
        XCTAssertTrue(attempts.allSatisfy { $0.1.sourcePath == added.path })
        XCTAssertEqual(Set(attempts.map { $0.1.backupPath }).count, 2)
        XCTAssertEqual(Set(attempts.map { $0.1.normalizedPath }).count, 2)
        let snapshotRowCounts = try attempts.map { item -> Int in
            let receipt = item.1
            for path in [receipt.backupPath, receipt.normalizedPath] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Each attempt must retain its original/normalized snapshot pair")
            }
            let backupCount = try SQLiteDatabaseDriver(url: URL(fileURLWithPath: receipt.backupPath), readOnly: true, bypassBusinessRoutes: true)
                .readRows("SELECT COUNT(*) FROM samples") { $0.int(0)! }.first!
            let normalizedCount = try SQLiteDatabaseDriver(url: URL(fileURLWithPath: receipt.normalizedPath), readOnly: true, bypassBusinessRoutes: true)
                .readRows("SELECT COUNT(*) FROM samples") { $0.int(0)! }.first!
            XCTAssertEqual(normalizedCount, backupCount, "The retained normalized snapshot must still match its original pair")
            return backupCount
        }
        XCTAssertEqual(snapshotRowCounts.sorted(), [1, 2], "Both the old and changed source snapshots must remain verifiable")
        XCTAssertEqual(try SQLiteDatabaseDriver(url: added).readRows("SELECT COUNT(*) FROM samples") { $0.int(0) }.first!, 2,
                       "Retry must re-verify the incomplete import rather than silently omit the newly committed legacy row")
        XCTAssertEqual(try SQLiteDatabaseDriver(url: active).readRows("SELECT COUNT(*) FROM samples") { $0.int(0) }.first!, 2, "Previously activated new rows must survive the retry")
        BusinessSQLiteRoutes.deactivate()
        try raw.execute("INSERT INTO samples VALUES(3)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: added).readRows("SELECT COUNT(*) FROM samples") { $0.int(0) }.first!, 2, "After activation the old file is frozen evidence")
    }
    func testInterruptedBatchMissingSourceFailsAndCanResumeWhenRestored() throws {
        let (_, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        BusinessSQLiteRoutes.deactivate()
        let added = c.support.appendingPathComponent("body-speed-pending.sqlite")
        try SQLiteDatabaseDriver(url: added).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(8)")
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { throw Stop.now }))
        let saved = added.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: added, to: saved)
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32))
        XCTAssertNil(BusinessSQLiteRoutes.store(for: added))
        try FileManager.default.moveItem(at: saved, to: added)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: added).readRows("SELECT id FROM samples") { $0.int(0) }.first!, 8)
    }
    func testUntrackedOldInterruptedBatchDoesNotActivateOrOverwriteLiveRows() throws {
        let (_, c) = try fixture()
        let active = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: active).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(1)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try SQLiteDatabaseDriver(url: active).execute("INSERT INTO samples VALUES(2)")
        BusinessSQLiteRoutes.deactivate()
        let database = try CodexBusinessDatabase(url: c.container)
        try database.driver.execute("INSERT OR REPLACE INTO tb_container_meta VALUES ('activation_state','importing')")
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32))
        XCTAssertNil(BusinessSQLiteRoutes.store(for: active))
        XCTAssertEqual(try SQLiteDatabaseDriver(url: active, bypassBusinessRoutes: true).readRows("SELECT COUNT(*) FROM samples") { $0.int(0) }.first!, 1)
        // The active A partition still contains its independently written row.
        let store = try XCTUnwrap(c.specification(for: active))
        XCTAssertEqual(try database.driver.readRows("SELECT COUNT(*) FROM \(store.prefix)samples") { $0.int(0) }.first!, 2)
    }
    func testBootstrapPreservesRawWALAndKeysAndReopensWithoutReimporting() throws {
        let (_, c) = try fixture()
        let legacy = c.support.appendingPathComponent("quota-history.sqlite")
        let source = SQLiteDatabaseDriver(url: legacy, enableWAL: true)
        try source.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,account TEXT,used REAL,payload BLOB); PRAGMA user_version=8")
        try source.execute("INSERT INTO quota_snapshots VALUES(42,'account-a',37.5,?)", bindings: [.blob(Data([0,255,0]))])
        let rawBefore = try source.withConnection { try CodexBusinessDatabase.proof($0) }
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let routed = SQLiteDatabaseDriver(url: legacy)
        XCTAssertEqual(routed.backingURL, c.container)
        XCTAssertEqual(try routed.readRows("SELECT payload FROM quota_snapshots WHERE id=42") { $0.data(0) }.first!, Data([0,255,0]))
        try routed.execute("INSERT INTO quota_snapshots VALUES(43,'account-a',38,NULL)")
        let old = SQLiteDatabaseDriver(url: legacy, readOnly: true, bypassBusinessRoutes: true)
        XCTAssertEqual(try old.withConnection { try CodexBusinessDatabase.proof($0) }, rawBefore)
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: legacy).readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 2)
        let receipts = try FileManager.default.subpathsOfDirectory(atPath: c.backups.path)
        XCTAssertTrue(receipts.contains { $0.hasSuffix("receipt.json") })
        XCTAssertTrue(receipts.contains { $0.contains("original-") && $0.hasSuffix(".sqlite") })
    }
    func testFailureBeforeActivationAndOutOfSpaceLeaveOldLedgerAndRetry() throws {
        let (_, c) = try fixture()
        let legacy = c.support.appendingPathComponent("quota-history.sqlite")
        let source = SQLiteDatabaseDriver(url: legacy)
        try source.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,used INTEGER); INSERT INTO quota_snapshots VALUES(1,77)")
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 0))
        XCTAssertNil(BusinessSQLiteRoutes.store(for: legacy))
        enum Stop: Error { case now }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { throw Stop.now }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertEqual(try source.readRows("SELECT used FROM quota_snapshots") { $0.int(0) }.first!, 77)
        try source.execute("INSERT INTO quota_snapshots VALUES(2,80)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: legacy).readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 2)
    }
    func testReadyStartupSkipsActivationButNewLegacyInputStillUsesTheGate() throws {
        let (_, c) = try fixture()
        let quota = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quota).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(42)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        BusinessSQLiteRoutes.deactivate()
        var activations = 0
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0, beforeActivation: { activations += 1 })
        XCTAssertEqual(activations, 0, "A ready container must not repeat migration activation or its whole-file check")
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota).readRows("SELECT id FROM samples") { $0.int(0) }.first!, 42)
        BusinessSQLiteRoutes.deactivate()
        let added = c.support.appendingPathComponent("body-speed-additional.sqlite")
        try SQLiteDatabaseDriver(url: added).execute("CREATE TABLE samples(id INTEGER PRIMARY KEY); INSERT INTO samples VALUES(77)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32, beforeActivation: { activations += 1 })
        XCTAssertEqual(activations, 1, "New inputs still require backups, proof and activation")
        XCTAssertEqual(try SQLiteDatabaseDriver(url: added).readRows("SELECT id FROM samples") { $0.int(0) }.first!, 77)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quota).readRows("SELECT id FROM samples") { $0.int(0) }.first!, 42)
    }
    func testNewModulesWriteOnlyAAndStageSealSurvivesUnrelatedWrites() throws {
        let (_, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let stageURL = c.exact.appendingPathComponent("staging/\(String(repeating: "a", count: 64)).sqlite/job.sqlite")
        let stage = SQLiteDatabaseDriver(url: stageURL)
        try stage.withConnection { db in
            try db.execute("CREATE TABLE events(id INTEGER PRIMARY KEY,payload BLOB); INSERT INTO events VALUES(1,x'000102')")
            try BusinessStoreFiles.seal(at: stageURL, connection: db)
        }
        let before = try SourceFileObservation.read(at: stageURL)
        let quotaURL = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: quotaURL).execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY); INSERT INTO quota_snapshots VALUES(1)")
        XCTAssertTrue(before.matches(try SourceFileObservation.read(at: stageURL)))
        XCTAssertThrowsError(try stage.execute("DELETE FROM events"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quotaURL.path))
        let old = try XCTUnwrap(BusinessSQLiteRoutes.store(for: stageURL))
        XCTAssertTrue(try BusinessStoreFiles.quarantine(stageURL, into: stageURL.deletingLastPathComponent().appendingPathComponent("preserved/one")))
        let fresh = SQLiteDatabaseDriver(url: stageURL)
        try fresh.execute("CREATE TABLE events(id INTEGER PRIMARY KEY); INSERT INTO events VALUES(2)")
        XCTAssertNotEqual(BusinessSQLiteRoutes.store(for: stageURL)?.id, old.id)
        XCTAssertEqual(try fresh.readRows("SELECT id FROM events") { $0.int(0) }.first!, 2)
        XCTAssertTrue(try BusinessStoreFiles.removeCompletedStage(stageURL))
        XCTAssertEqual(try SQLiteDatabaseDriver(url: quotaURL).readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 1)
    }
    func testCurrentExactAndDeletedSourceLedgerRemainAvailableAfterMigration() throws {
        let (_, c) = try fixture()
        let url = c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
        let old = SQLiteDatabaseDriver(url: url)
        try old.execute("""
        INSERT INTO sources(source_id,path,session_id,size_bytes,modified_at,content_probe,last_seen_generation)
        VALUES(1,'/deleted/source.jsonl','same-uuid',1000,100,'probe','1');
        INSERT INTO events(source_id,source_offset,timestamp,tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,model,accounting_kind)
        VALUES(1,100,1000,80,70,50,10,2,'gpt-6.1-sol',0);
        """)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let routed = SQLiteDatabaseDriver(url: url)
        XCTAssertEqual(try routed.readRows("SELECT tokens FROM events") { $0.int(0) }.first!, 80)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
        XCTAssertEqual(try routed.readRows("SELECT tokens FROM events") { $0.int(0) }.first!, 80)
        XCTAssertEqual(try routed.readRows("SELECT session_id FROM sources") { $0.text(0) }.first!, "same-uuid")
    }
    func testUnsupportedDormantHomesArePreservedWithoutBlockingSupportedHome() throws {
        let (_, c) = try fixture()
        let supported = c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: supported)
        var originals: [(URL, BusinessStoreProof)] = []
        // Include a cache-only source, an empty v3 index (the real startup
        // blocker), and a populated future version whose IDs must survive.
        for (version, character, root) in [("3", "b", c.legacyExact), ("999", "c", c.exact)] {
            let url = root.appendingPathComponent(String(repeating: character, count: 64) + ".sqlite")
            let source = SQLiteDatabaseDriver(url: url, enableWAL: true)
            try source.execute("CREATE TABLE schema_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE retained(id INTEGER PRIMARY KEY,payload BLOB)")
            try source.execute("INSERT INTO schema_meta VALUES('schema_version',?)", bindings: [.text(version)])
            if version == "999" {
                try source.execute("INSERT INTO retained VALUES(42,?)", bindings: [.blob(Data([0,255,1]))])
            }
            originals.append((url, try source.withConnection { try CodexBusinessDatabase.proof($0) }))
        }
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: supported)
        for (url, proof) in originals {
            let destination = c.exact.appendingPathComponent(url.lastPathComponent)
            let routed = SQLiteDatabaseDriver(url: destination)
            XCTAssertEqual(routed.backingURL, c.container)
            XCTAssertEqual(try routed.readRows("SELECT value FROM schema_meta WHERE key='schema_version'") { $0.text(0) }.first!,
                url.lastPathComponent.hasPrefix("b") ? "3" : "999")
            let payloads = try routed.readRows("SELECT id,payload FROM retained") { ($0.int(0), $0.data(1)) }
            XCTAssertEqual(payloads.count, url.lastPathComponent.hasPrefix("b") ? 0 : 1)
            if let payload = payloads.first { XCTAssertEqual(payload.0, 42); XCTAssertEqual(payload.1, Data([0,255,1])) }
            let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: destination))
            let receipt = try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self,
                from: Data(contentsOf: c.backups.appendingPathComponent(store.id).appendingPathComponent("receipt.json")))
            XCTAssertNotNil(receipt.normalizationDeferredReason)
            XCTAssertEqual(receipt.original, receipt.imported)
            XCTAssertThrowsError(try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: destination)) { error in
                XCTAssertTrue(error.localizedDescription.contains("newer or unknown"), "\(error)")
            }
            XCTAssertEqual(try SQLiteDatabaseDriver(url: url, readOnly: true, bypassBusinessRoutes: true)
                .withConnection { try CodexBusinessDatabase.proof($0) }, proof)
        }
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 0)
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: supported)
    }
    func testNewExactScansInAReuseStagePathsAndDeletedHistorySurvivesAcrossHomes() throws {
        let (root, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let id = "019f1234-1234-1234-1234-123456789abc"
        var urls: [URL] = []
        for i in 0..<2 {
            let home = root.appendingPathComponent("home-\(i)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let file = home.appendingPathComponent("rollout-\(id).jsonl")
            func line(_ value: Int, second: Int) -> String {
                "{\"timestamp\":\"2026-10-01T00:00:0\(second)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(value),\"cached_input_tokens\":0,\"output_tokens\":0,\"total_tokens\":\(value)}}}}\n"
            }
            try Data(line(120 + i, second: 0).utf8).write(to: file)
            let url = c.exact.appendingPathComponent(String(repeating: i == 0 ? "b" : "c", count: 64) + ".sqlite")
            urls.append(url)
            let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: url)
            let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
            func sync(_ files: [URL]) throws {
                _ = try index.synchronize(files: files, sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
                    try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                        insertFingerprint: fingerprint, emit: emit)
                }
            }
            try sync([file])
            // Atomic rewrite forces a second full rebuild at the same logical
            // staging path. A completed prior job must not become a new file.
            try Data((line(120 + i, second: 0) + line(7, second: 1)).utf8).write(to: file, options: .atomic)
            try sync([file])
            try sync([file])
            try FileManager.default.removeItem(at: file)
            try sync([])
            let db = SQLiteDatabaseDriver(url: url)
            XCTAssertEqual(try db.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 127 + i)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertNotEqual(BusinessSQLiteRoutes.store(for: urls[0])?.id, BusinessSQLiteRoutes.store(for: urls[1])?.id)
        let physical = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".sqlite") }
        XCTAssertEqual(physical, ["support/codex-ledger.sqlite"])
    }
    func testSafetyRecoveryIsScopedAndDoesNotEraseQuotaOrExact() throws {
        let (_, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let quota = SQLiteDatabaseDriver(url: c.support.appendingPathComponent("quota-history.sqlite"))
        try quota.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,used INTEGER); INSERT INTO quota_snapshots VALUES(1,77)")
        let safetyURL = c.support.appendingPathComponent("shared-account-usage-safety.sqlite")
        let safety = SharedAccountUsageSafetyDatabase(url: safetyURL)
        XCTAssertTrue(safety.persistenceHealthy)
        XCTAssertTrue(safety.store(Data("{\"kept\":true}".utf8), as: .segments))
        safety.reportCorruptPayload(.segments)
        let suite = "scoped-safety-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovered = try XCTUnwrap(safety.rebuildEmptySafetyBaseline(preciseContinuityPayload: Data("{}".utf8),
            defaults: defaults, retiredUserDefaultsKeys: []))
        XCTAssertTrue(safety.persistenceHealthy)
        XCTAssertEqual(safety.load(.segments), Data("{}".utf8))
        XCTAssertEqual(try quota.readRows("SELECT used FROM quota_snapshots") { $0.int(0) }.first!, 77)
        let backup = SQLiteDatabaseDriver(url: recovered.quarantineDirectory.appendingPathComponent("safety-before-recovery.sqlite"), readOnly: true)
        XCTAssertEqual(try backup.readRows("SELECT payload FROM safety_records WHERE kind='segments-v08'") { $0.data(0) }.first!, Data("{\"kept\":true}".utf8))
    }

    func testMissingActivatedContainerCannotResurrectStaleLegacy() throws {
        let (_, c) = try fixture()
        let legacy = c.support.appendingPathComponent("quota-history.sqlite")
        try SQLiteDatabaseDriver(url: legacy).execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY); INSERT INTO quota_snapshots VALUES(1)")
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        try SQLiteDatabaseDriver(url: legacy).execute("INSERT INTO quota_snapshots VALUES(2)")
        BusinessSQLiteRoutes.deactivate()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: c.container.path + suffix) }
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.container.path))
        XCTAssertEqual(try SQLiteDatabaseDriver(url: legacy, readOnly: true, bypassBusinessRoutes: true)
            .readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 1)
    }
    func testContainerMaintenancePreservesOtherModulesAndSealedJobs() throws {
        let (_, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 32)
        let quota = SQLiteDatabaseDriver(url: c.support.appendingPathComponent("quota-history.sqlite"))
        try quota.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY,payload BLOB)")
        try quota.transaction { tx in
            let insert = try tx.prepare("INSERT INTO quota_snapshots VALUES(?,?)")
            for id in 0..<2048 { _ = try insert.execute([.int(id), .blob(Data(repeating: UInt8(id % 255), count: 2048))]) }
        }
        try quota.execute("DELETE FROM quota_snapshots WHERE id>=10")
        let stageURL = c.exact.appendingPathComponent("staging/store.sqlite/sealed.sqlite")
        try SQLiteDatabaseDriver(url: stageURL).withConnection { db in
            try db.execute("CREATE TABLE events(label TEXT); INSERT INTO events(rowid,label) VALUES(150,'retained-rowid')")
            try BusinessStoreFiles.seal(at: stageURL, connection: db)
        }
        let before = try SourceFileObservation.read(at: stageURL)
        let policy = CodexUsageIndexStorageMaintenancePolicy(minimumCheckInterval: 86400, minimumFreeBytes: 1,
            absoluteFreeBytes: 1, minimumFreePercent: 0, diskReserveBytes: 0)
        let result = try BusinessDatabaseMaintenance.run(container: c.container, now: Date(timeIntervalSince1970: 100), policy: policy, availableCapacity: 1 << 32)
        guard case .compacted = result else { return XCTFail("expected scoped container maintenance: \(result)") }
        XCTAssertTrue(before.matches(try SourceFileObservation.read(at: stageURL)))
        XCTAssertEqual(try quota.readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 10)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: stageURL, readOnly: true).readRows("SELECT rowid FROM events") { $0.int(0) }.first!, 150)
        XCTAssertEqual(try BusinessDatabaseMaintenance.run(container: c.container, now: Date(timeIntervalSince1970: 101), policy: policy), .notDue)
    }

    func testOldPhysicalStageMigratesAndResumesWithoutParsingOrLosingCheckpoint() throws {
        let (root, c) = try fixture()
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"cached_input_tokens\":30,\"output_tokens\":0,\"total_tokens\":120}}}}\n".utf8).write(to: file)
        let exactURL = c.exact.appendingPathComponent(String(repeating: "d", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home, origin: .userSelected))
        CodexUsageHistoryIndex.failNextImportAfterStagingForTesting()
        XCTAssertThrowsError(try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
            try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        })
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let migrated = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        _ = try migrated.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
            XCTFail("a verified migrated stage must be reused")
            return try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        XCTAssertEqual(try SQLiteDatabaseDriver(url: exactURL).readRows("SELECT SUM(tokens),SUM(cached_input_tokens) FROM events") { [$0.int(0),$0.int(1)] }.first!, [120,30])
    }

    func testLegacyAStageSurvivesDeletedFilesAndChangedConfiguredDirectoryAlias() throws {
        let (root, physical) = try fixture()
        let file = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"cached_input_tokens\":30,\"total_tokens\":120}}}}\n".utf8).write(to: file)
        let exactURL = physical.exact.appendingPathComponent(String(repeating: "c", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        CodexUsageHistoryIndex.failNextImportAfterStagingForTesting()
        XCTAssertThrowsError(try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        })
        let legacyDirectory = physical.exact.appendingPathComponent("staging/\(exactURL.lastPathComponent)")
        let physicalStage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "sqlite" })
        let alias = root.appendingPathComponent("exact-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical.exact)
        let configured = BusinessDatabaseMigration.Configuration(container: physical.container, support: physical.support,
            exact: alias, legacyExact: physical.legacyExact)
        try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 33)
        let migratedStage = try XCTUnwrap(BusinessStoreFiles.stageURLs(in: legacyDirectory).first)
        XCTAssertTrue(migratedStage.path.hasPrefix(alias.path + "/"), "The catalog retains its configured logical spelling")
        let stageID = try XCTUnwrap(BusinessSQLiteRoutes.store(for: migratedStage)?.id)
        BusinessSQLiteRoutes.deactivate()
        for database in [exactURL, physicalStage] {
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: database.path + suffix) {
                try FileManager.default.removeItem(atPath: database.path + suffix)
            }
        }
        try FileManager.default.removeItem(at: physical.exact.appendingPathComponent("staging"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))

        try BusinessDatabaseMigration.migrate(physical, availableBytes: 0)
        XCTAssertEqual(BusinessStoreFiles.stageURLs(in: legacyDirectory).count, 1,
            "A legacy namespace must remain discoverable when its leaves and all staging parents are absent")
        XCTAssertEqual(BusinessSQLiteRoutes.store(for: migratedStage)?.id, stageID)
        let resumed = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        _ = try resumed.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            XCTFail("The retained A job must be reused through the new physical root spelling")
            return try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        XCTAssertEqual(try SQLiteDatabaseDriver(url: exactURL).readRows("SELECT SUM(tokens),SUM(cached_input_tokens) FROM events") { [$0.int(0), $0.int(1)] }.first!, [120,30])
        XCTAssertFalse(FileManager.default.fileExists(atPath: physicalStage.path))
        XCTAssertTrue(BusinessStoreFiles.stageURLs(in: legacyDirectory).isEmpty, "The old job retires only after successful publication")
    }

    func testPrivateParserJobsKeepContainerSchemaBoundedAndResumeAtomicPublication() throws {
        let (root, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let exactURL = c.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        let files = try (0..<9).map { number -> URL in
            let file = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-\(String(format: "%012d", number)).jsonl")
            let tokens = 120 + number
            try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(tokens),\"total_tokens\":\(tokens)}}}}\n".utf8).write(to: file)
            return file
        }
        let parse: CodexUsageHistoryIndex.SessionParser = { file, id, request, fingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        _ = try index.synchronize(files: [files[0]], sessionID: analyzer.sessionID(from:), parser: parse)
        let logical = SQLiteDatabaseDriver(url: exactURL)
        let physical = SQLiteDatabaseDriver(url: c.container, readOnly: true, bypassBusinessRoutes: true)
        let schemaBefore = try physical.readRows("SELECT name FROM sqlite_master ORDER BY name") { $0.text(0) }
        let ledgerBefore = try logical.readRows("SELECT source_id,source_offset,tokens FROM events ORDER BY source_id,source_offset") {
            [$0.int64(0), $0.int64(1), $0.int64(2)]
        }
        CodexUsageHistoryIndex.failNextBatchAfterFirstImportForTesting()
        XCTAssertThrowsError(try index.synchronize(files: files, sessionID: analyzer.sessionID(from:), parser: parse))
        XCTAssertEqual(try logical.readRows("SELECT source_id,source_offset,tokens FROM events ORDER BY source_id,source_offset") {
            [$0.int64(0), $0.int64(1), $0.int64(2)]
        }, ledgerBefore, "A failure after importing a source must roll back the whole new generation")
        XCTAssertEqual(try physical.readRows("SELECT name FROM sqlite_master ORDER BY name") { $0.text(0) }, schemaBefore,
            "Ready parser jobs must not add four shared-A tables per rollout")
        XCTAssertEqual(try physical.readRows("SELECT COUNT(*) FROM tb_stores WHERE module='exact.swift.stage'") { $0.int(0) }.first!, 0)
        let directory = c.exact.appendingPathComponent("staging-private-v1/\(exactURL.lastPathComponent)")
        let stages = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
        XCTAssertEqual(stages.count, 8, "All private jobs remain available after publication rolls back")
        for stage in stages {
            XCTAssertNil(c.specification(for: stage), "Private jobs must never reenter automatic legacy import")
            XCTAssertNil(BusinessSQLiteRoutes.store(for: stage))
            XCTAssertTrue(try CodexUsageHistoryIndex.stagingIntegrityIsValid(using: SQLiteDatabaseDriver(url: stage, readOnly: true)))
        }

        // A fresh startup must neither import these private jobs into A nor
        // drop them; the owning Exact index resumes and verifies their data.
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let resumed = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
        _ = try resumed.synchronize(files: files, sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            XCTFail("Completed private jobs must not be parsed again after restart")
            return try parse(file, id, request, fingerprint, emit)
        }
        let restored = SQLiteDatabaseDriver(url: exactURL)
        XCTAssertEqual(try restored.readRows("SELECT COUNT(*),SUM(tokens) FROM events") { [$0.int(0), $0.int(1)] }.first!,
            [9, (0..<9).reduce(0) { $0 + 120 + $1 }])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Cleanup follows the complete generation's commit")
    }

    func testCheckpointResetPreservesVerifiedEnrichmentStageAndRejectsCorruptEvidence() throws {
        for corrupt in [false, true] {
            let (root, c) = try fixture()
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
            let exactURL = c.exact.appendingPathComponent(String(repeating: "b", count: 64) + ".sqlite")
            let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: exactURL)
            let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
            let file = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
            func line(_ tokens: Int, second: Int) -> String {
                "{\"timestamp\":\"2026-10-01T00:00:0\(second)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(tokens),\"total_tokens\":\(tokens)}}}}\n"
            }
            try Data(line(120, second: 0).utf8).write(to: file)
            let parse: CodexUsageHistoryIndex.SessionParser = { file, id, request, fingerprint, emit in
                try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                    insertFingerprint: fingerprint, emit: emit)
            }
            _ = try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:), parser: parse)
            let db = SQLiteDatabaseDriver(url: exactURL)
            try db.execute("DELETE FROM event_enrichment_sources; DELETE FROM schema_meta WHERE key='event_enrichment_revision';")
            CodexUsageHistoryIndex.failNextImportAfterStagingForTesting()
            XCTAssertThrowsError(try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:), parser: parse))
            let directory = c.exact.appendingPathComponent("staging-private-v1/\(exactURL.lastPathComponent)")
            let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "sqlite" })
            if corrupt { try SQLiteDatabaseDriver(url: stage).execute("UPDATE manifest SET actual_bytes=actual_bytes+1") }
            let evidence = try Data(contentsOf: stage)
            // A released replay repair may clear this checkpoint; the active
            // rollout can grow while its old bounded enrichment stage remains.
            try db.execute("UPDATE sources SET append_ready=0")
            try Data((line(120, second: 0) + line(55, second: 1)).utf8).write(to: file)
            if corrupt {
                XCTAssertThrowsError(try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
                    XCTFail("Unproven stage contents must not trigger a replacement parse")
                    return try parse(file, id, request, fingerprint, emit)
                })
                XCTAssertEqual(try Data(contentsOf: stage), evidence)
                XCTAssertEqual(try db.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 120)
            } else {
                _ = try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:), parser: parse)
                XCTAssertEqual(try db.readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 175)
                let preserved = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                    .filter { $0.hasPrefix("preserved/") && $0.hasSuffix(".sqlite") }
                XCTAssertEqual(preserved.count, 1)
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(XCTUnwrap(preserved.first))), evidence,
                    "The superseded complete stage remains unchanged as recovery evidence")
            }
            BusinessSQLiteRoutes.deactivate()
        }
    }

    func testColdParserDoesNotHoldTheContainersWriteLock() throws {
        let (root, c) = try fixture()
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        let quota = SQLiteDatabaseDriver(url: c.support.appendingPathComponent("quota-history.sqlite"))
        try quota.execute("CREATE TABLE quota_snapshots(id INTEGER PRIMARY KEY); INSERT INTO quota_snapshots VALUES(1)")
        let file = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"total_tokens\":120}}}}\n".utf8).write(to: file)
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: c.exact.appendingPathComponent(String(repeating: "e", count: 64) + ".sqlite"))
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        var parses = 0
        _ = try index.synchronize(files: [file], sessionID: analyzer.sessionID(from:)) { file,id,request,fingerprint,emit in
            parses += 1
            // This write is on a second connection, while the producer's TEMP
            // transaction is open. It would time out if the parser held A.
            try quota.execute("INSERT INTO quota_snapshots VALUES(2) ON CONFLICT(id) DO NOTHING")
            return try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id,
                request: request, insertFingerprint: fingerprint, emit: emit)
        }
        XCTAssertEqual(parses, 1)
        XCTAssertEqual(try quota.readRows("SELECT COUNT(*) FROM quota_snapshots") { $0.int(0) }.first!, 2)
    }
    func testInterruptedLegacyExchangeUsesRollbackWithoutChangingOldFiles() throws {
        let (_, c) = try fixture()
        let main = c.exact.appendingPathComponent(String(repeating: "f", count: 64) + ".sqlite")
        _ = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: main)
        let old = SQLiteDatabaseDriver(url: main)
        try old.execute("INSERT INTO schema_meta(key,value) VALUES('extra-legacy-evidence','kept')")
        try old.execute("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
        let rollback = URL(fileURLWithPath: main.path + ".schema11-rollback")
        try FileManager.default.moveItem(at: main, to: rollback)
        let manifest = URL(fileURLWithPath: main.path + ".schema11-migration.json")
        let bytes = try JSONSerialization.data(withJSONObject: [
            "manifestVersion": 1, "phase": "switching", "sourcePath": main.path,
            "candidatePath": main.path + ".schema11-candidate", "rollbackPath": rollback.path
        ], options: [.sortedKeys])
        try bytes.write(to: manifest)
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 33)
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollback.path))
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: main).readRows("SELECT value FROM schema_meta WHERE key='extra-legacy-evidence'") { $0.text(0) }.first!, "kept")
    }

}
