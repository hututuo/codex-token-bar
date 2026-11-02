import Foundation
import XCTest
@testable import CodexTokenBar

final class BusinessDatabaseMigrationAliasTests: XCTestCase {
    private enum Stop: Error { case beforeActivation }

    func testCompletedMigrationKeepsPublishedHistoryWhenRetainedOriginalUsesAnotherRootSpelling() throws {
        let (_, physical, configured) = try fixture()
        let source = physical.support.appendingPathComponent("quota-history.sqlite")
        try createSource(source, id: 42, tokens: 155)
        let originalBytes = try Data(contentsOf: source)
        try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 33)
        let logical = configured.support.appendingPathComponent(source.lastPathComponent)
        let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: logical))
        try SQLiteDatabaseDriver(url: logical).execute("INSERT INTO samples VALUES(43,11,x'00fe')")
        let published = try namespaceProof(at: physical.container, store: store)
        let oldCatalog = try catalog(at: physical.container)
        BusinessSQLiteRoutes.deactivate()

        var reactivated = false
        try BusinessDatabaseMigration.migrate(physical, availableBytes: 0,
            beforeActivation: { reactivated = true })
        XCTAssertFalse(reactivated, "A directory alias must not make a completed migration run again")
        XCTAssertEqual(try catalog(at: physical.container), oldCatalog)
        XCTAssertEqual(try namespaceProof(at: physical.container, store: store), published)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(BusinessSQLiteRoutes.store(for: source)?.id, store.id)
        XCTAssertEqual(BusinessSQLiteRoutes.store(for: source)?.logicalURL, logical)
        XCTAssertEqual(try raw(physical.container).readRows("SELECT source_path FROM tb_legacy_inputs") { $0.text(0) }, [logical.path])
    }

    func testExactRetainedOriginalAndOperationLockFollowTheSamePhysicalDirectoryAlias() throws {
        let (root, physical, configured) = try fixture()
        try FileManager.default.createDirectory(at: physical.exact, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("exact-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical.exact)
        let aliased = BusinessDatabaseMigration.Configuration(container: physical.container, support: configured.support,
            exact: alias, legacyExact: physical.legacyExact)
        let source = physical.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: source)
        let rollout = root.appendingPathComponent("rollout-019f1234-1234-1234-1234-123456789abc.jsonl")
        try Data("{\"timestamp\":\"2026-10-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":120,\"total_tokens\":120}}}}\n".utf8).write(to: rollout)
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: root, origin: .userSelected))
        _ = try index.synchronize(files: [rollout], sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
        let original = try sourceProof(source)
        let originalBytes = try Data(contentsOf: source)
        try BusinessDatabaseMigration.migrate(aliased, availableBytes: 1 << 33)
        let logical = alias.appendingPathComponent(source.lastPathComponent)
        let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: logical))
        let published = try namespaceProof(at: physical.container, store: store)
        let oldCatalog = try catalog(at: physical.container)
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(physical, availableBytes: 0)
        XCTAssertEqual(try namespaceProof(at: physical.container, store: store), published)
        XCTAssertEqual(try catalog(at: physical.container), oldCatalog)
        XCTAssertEqual(BusinessSQLiteRoutes.store(for: source)?.logicalURL, logical)
        XCTAssertEqual(try sourceProof(source), original)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source, readOnly: true).readRows("SELECT SUM(tokens) FROM events") { $0.int(0) }.first!, 120)
    }

    func testInterruptedMigrationKeepsJournalAndCatalogIdentityAcrossAnAliasChangeAndLegacyAppend() throws {
        let (_, physical, configured) = try fixture()
        let source = physical.support.appendingPathComponent("quota-history.sqlite")
        let body = physical.support.appendingPathComponent("body-speed-one.sqlite")
        try createSource(source, id: 42, tokens: 155)
        try createSource(body, id: 7, tokens: 310)
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 33,
            beforeActivation: { throw Stop.beforeActivation })) { error in
            XCTAssertTrue(error is Stop, "Unexpected interruption: \(error)")
        }
        let working = physical.support.appendingPathComponent(".codex-ledger-migrating.sqlite")
        let oldCatalog = try catalog(at: working)
        let journal = try pendingJournal(at: working)
        XCTAssertEqual(Set(journal.keys), Set([source, body].map { configured.support.appendingPathComponent($0.lastPathComponent).path }))
        // This is an old standalone writer, after the first import but before
        // the retry. The recovery must not reuse its older normalized image.
        try raw(source, readOnly: false).execute("INSERT INTO samples VALUES(43,17,x'01ff')")
        let originals = try [source, body].map { ($0, try Data(contentsOf: $0), try sourceProof($0)) }
        BusinessSQLiteRoutes.deactivate()

        try BusinessDatabaseMigration.migrate(physical, availableBytes: 1 << 33)
        XCTAssertEqual(try catalog(at: physical.container), oldCatalog)
        XCTAssertEqual(try pendingJournal(at: physical.container), [:])
        for (url, bytes, proof) in originals {
            let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: url))
            XCTAssertEqual(store.logicalURL, configured.support.appendingPathComponent(url.lastPathComponent))
            XCTAssertEqual(try namespaceProof(at: physical.container, store: store), proof)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertEqual(try SQLiteDatabaseDriver(url: source, readOnly: true).readRows("SELECT id,tokens FROM samples ORDER BY id") { [$0.int(0), $0.int(1)] }, [[42,155], [43,17]])
        XCTAssertEqual(Set(try raw(physical.container).readRows("SELECT source_path FROM tb_legacy_inputs") { $0.text(0) ?? "" }), Set(journal.keys))
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(physical, availableBytes: 0)
        XCTAssertEqual(try catalog(at: physical.container), oldCatalog)
    }

    func testInterruptedContainerAliasReusesTheSameImmutableAttemptAndSnapshotFiles() throws {
        let (_, physical, configured) = try fixture()
        let source = physical.support.appendingPathComponent("quota-history.sqlite")
        try createSource(source, id: 42, tokens: 155)
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 33,
            beforeActivation: { throw Stop.beforeActivation }))
        let store = try XCTUnwrap(configured.specification(for: configured.support.appendingPathComponent(source.lastPathComponent)))
        let folder = physical.backups.appendingPathComponent(store.id)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "receipt.json" }
        XCTAssertEqual(files.count, 3, "One immutable attempt receipt and its two verified snapshots")
        let retained = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let prior = try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self,
            from: Data(contentsOf: folder.appendingPathComponent("receipt.json")))
        XCTAssertTrue(prior.backupPath.hasPrefix(configured.backups.path + "/"))
        BusinessSQLiteRoutes.deactivate()

        try BusinessDatabaseMigration.migrate(physical, availableBytes: 1 << 33)
        let afterFiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "receipt.json" }
        XCTAssertEqual(Set(afterFiles.map(\.lastPathComponent)), Set(retained.keys))
        for file in afterFiles { XCTAssertEqual(try Data(contentsOf: file), retained[file.lastPathComponent]) }
        let latest = try JSONDecoder().decode(BusinessDatabaseMigration.Receipt.self,
            from: Data(contentsOf: folder.appendingPathComponent("receipt.json")))
        XCTAssertEqual(latest.sourcePath, prior.sourcePath)
        XCTAssertEqual(latest.backupPath, prior.backupPath)
        XCTAssertEqual(latest.normalizedPath, prior.normalizedPath)
        XCTAssertEqual(latest.storeID, prior.storeID)
        XCTAssertEqual(latest.original, prior.original)
        XCTAssertEqual(latest.imported, prior.imported)
    }

    func testJournalOnlyInputCanResumeThroughItsOriginalAliasAfterTheLegacyFailureIsRepaired() throws {
        let (_, physical, configured) = try fixture()
        let quota = physical.support.appendingPathComponent("quota-history.sqlite")
        let body = physical.support.appendingPathComponent("body-speed-one.sqlite")
        try createSource(quota, id: 42, tokens: 155)
        try Data("a synthetic corrupt legacy database".utf8).write(to: body)
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 33))
        let working = physical.support.appendingPathComponent(".codex-ledger-migrating.sqlite")
        let journal = try pendingJournal(at: working)
        XCTAssertEqual(journal.count, 2)
        XCTAssertEqual(try raw(working).readRows("SELECT COUNT(*) FROM tb_stores") { $0.int(0) }.first!, 1)
        XCTAssertEqual(try raw(working).readRows("SELECT COUNT(*) FROM tb_legacy_inputs") { $0.int(0) }.first!, 1)
        // Repair only the synthetic producer's bad input. The candidate still
        // has no receipt/catalog row for this journal entry.
        try FileManager.default.removeItem(at: body)
        try createSource(body, id: 7, tokens: 310)
        let originals = try [quota, body].map { ($0, try Data(contentsOf: $0), try sourceProof($0)) }
        BusinessSQLiteRoutes.deactivate()
        try BusinessDatabaseMigration.migrate(physical, availableBytes: 1 << 33)
        XCTAssertEqual(try pendingJournal(at: physical.container), [:])
        XCTAssertEqual(Set(try raw(physical.container).readRows("SELECT source_path FROM tb_legacy_inputs") { $0.text(0) ?? "" }), Set(journal.keys))
        for (url, bytes, proof) in originals {
            let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: url))
            XCTAssertEqual(try namespaceProof(at: physical.container, store: store), proof)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testDifferentPhysicalInputOrHardLinkCannotClaimARegisteredStoreByBasename() throws {
        for hardLink in [false, true] {
            let (root, physical, configured) = try fixture()
            let source = physical.support.appendingPathComponent("quota-history.sqlite")
            try createSource(source, id: 42, tokens: 155)
            try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 33)
            let store = try XCTUnwrap(BusinessSQLiteRoutes.store(for: source))
            let published = try namespaceProof(at: physical.container, store: store)
            let oldCatalog = try catalog(at: physical.container)
            let alternative = root.appendingPathComponent("different-support")
            try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
            let other = alternative.appendingPathComponent(source.lastPathComponent)
            if hardLink { try FileManager.default.linkItem(at: source, to: other) }
            else { try createSource(other, id: 99, tokens: 155) }
            let originalBytes = try [source, other].map { try Data(contentsOf: $0) }
            BusinessSQLiteRoutes.deactivate()
            let foreign = BusinessDatabaseMigration.Configuration(container: physical.container, support: alternative,
                exact: physical.exact, legacyExact: physical.legacyExact)
            XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(foreign, availableBytes: 1 << 33)) { error in
                guard case .unmigratedInput = error as? BusinessDatabaseMigration.Failure else {
                    return XCTFail("A different physical ownership path must remain blocked: \(error)")
                }
            }
            XCTAssertEqual(try namespaceProof(at: physical.container, store: store), published)
            XCTAssertEqual(try catalog(at: physical.container), oldCatalog)
            XCTAssertEqual(try [source, other].map { try Data(contentsOf: $0) }, originalBytes)
        }
    }

    func testAliasCannotOverrideAConflictingPendingStoreOwner() throws {
        let (_, physical, configured) = try fixture()
        let source = physical.support.appendingPathComponent("quota-history.sqlite")
        try createSource(source, id: 42, tokens: 155)
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configured, availableBytes: 1 << 33,
            beforeActivation: { throw Stop.beforeActivation }))
        let working = physical.support.appendingPathComponent(".codex-ledger-migrating.sqlite")
        let oldCatalog = try catalog(at: working)
        let wrong = [configured.support.appendingPathComponent(source.lastPathComponent).path: String(repeating: "f", count: 64)]
        try raw(working, readOnly: false).execute("UPDATE tb_container_meta SET value=? WHERE key='migration_pending_sources_v1'",
            bindings: [.text(String(decoding: try JSONEncoder().encode(wrong), as: UTF8.self))])
        let candidate = try sourceProof(working)
        let originalBytes = try Data(contentsOf: source)
        BusinessSQLiteRoutes.deactivate()
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(physical, availableBytes: 1 << 33))
        XCTAssertFalse(FileManager.default.fileExists(atPath: physical.container.path))
        XCTAssertEqual(try sourceProof(working), candidate)
        XCTAssertEqual(try catalog(at: working), oldCatalog)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }

    private func fixture() throws -> (URL, BusinessDatabaseMigration.Configuration, BusinessDatabaseMigration.Configuration) {
        BusinessSQLiteRoutes.deactivate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("business-alias-\(UUID())")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("support-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: support)
        addTeardownBlock { BusinessSQLiteRoutes.deactivate(); try? FileManager.default.removeItem(at: root) }
        let physical = BusinessDatabaseMigration.Configuration(container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support, exact: root.appendingPathComponent("exact"), legacyExact: root.appendingPathComponent("cache"))
        let configured = BusinessDatabaseMigration.Configuration(container: alias.appendingPathComponent("codex-ledger.sqlite"), support: alias,
            exact: physical.exact, legacyExact: physical.legacyExact)
        return (root, physical, configured)
    }
    private func raw(_ url: URL, readOnly: Bool = true) -> SQLiteDatabaseDriver {
        SQLiteDatabaseDriver(url: url, readOnly: readOnly, createsFileIfMissing: !readOnly, bypassBusinessRoutes: true)
    }
    private func createSource(_ url: URL, id: Int, tokens: Int) throws {
        let database = raw(url, readOnly: false)
        try database.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY,tokens INTEGER NOT NULL,payload BLOB)")
        try database.execute("INSERT INTO samples VALUES(?,?,x'00ff')", bindings: [.int(id), .int(tokens)])
    }
    private func sourceProof(_ url: URL) throws -> BusinessStoreProof {
        try raw(url).withConnection { try CodexBusinessDatabase.proof($0) }
    }
    private func namespaceProof(at url: URL, store: BusinessSQLiteStore) throws -> BusinessStoreProof {
        try raw(url).withConnection {
            try CodexBusinessDatabase.proof($0, namespace: SQLiteStoreNamespace(prefix: store.prefix, objectNames: []))
        }
    }
    private func catalog(at url: URL) throws -> [[String]] {
        try raw(url).readRows("SELECT store_id,logical_path,module,source_identity FROM tb_stores ORDER BY store_id") { row in
            (Int32(0)..<4).map { column in row.text(column) ?? "" }
        }
    }
    private func pendingJournal(at url: URL) throws -> [String: String] {
        guard let text = try raw(url).readRows("SELECT value FROM tb_container_meta WHERE key='migration_pending_sources_v1'", map: { $0.text(0) }).first ?? nil else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    }
}
