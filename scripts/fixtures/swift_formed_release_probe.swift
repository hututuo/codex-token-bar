import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

/// Injected only into an exact Git archive. All database creation, import,
/// routing and accounting use that archive's unchanged production methods.
final class SwiftFormedReleaseProbeTests: XCTestCase {
    private static let compiledSource = "__TOKENBAR_SWIFT_FORMED_SOURCE_SHA__"
    private static let compiledRole = "__TOKENBAR_SWIFT_FORMED_ROLE__"
    private static let producerVersion = "__TOKENBAR_SWIFT_FORMED_RELEASE__"
    private static let ownerNames = ["a", "b"].map { String(repeating: $0, count: 64) + ".sqlite" }
    private static let retainedTables = ["retained_usage_meta", "retained_usage_sources", "retained_usage_events",
        "retained_usage_revisions", "retained_usage_fingerprints", "retained_usage_checkpoints"]
    private static let durableTables = ["events", "sources", "usage_ledger_meta", "usage_ledger_bindings",
        "usage_ledger_identities", "usage_ledger_turns", "usage_ledger_unresolved", "usage_ledger_sources", "usage_ledger_corrections"] + retainedTables
    private static let numericColumns = ["source_id", "source_offset", "timestamp", "tokens", "input_tokens",
        "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "accounting_kind", "reported_total_tokens", "legacy_tokens"]
    private enum Failure: Error { case invalid(String) }
    private struct TableImage: Codable, Equatable {
        let columns: [String]
        let rows: [[String]]
    }
    private struct Original: Codable {
        let sha256: String
        let proof: BusinessStoreProof
        let tables: [String: TableImage]
    }
    private struct Seed: Codable {
        let originals: [String: Original]
        let bProof: BusinessStoreProof
    }
    private struct LateSource: Codable {
        let latest: Seed
        let previousExactBackup: String
        let enrichment: Enrichment?
    }
    private struct Enrichment: Codable {
        let numericBefore: TableImage
        let numericAfter: TableImage
        let retainedVersions: TableImage
        let rawBeforeSha256: String
        let rawAfterSha256: String
    }
    private struct Formed: Codable {
        let producerVersion: String
        let producerSha: String
        let runtime: String
        let scenario: String
        let completedImports: Int
        let totalInputs: Int
        let originalProofs: Seed
        let formedStoreProofs: [String: BusinessStoreProof]
        let exactTables: [String: [String: TableImage]]
        let formedTotals: [Int]
    }

    private static func require(_ value: Bool, _ reason: String) throws {
        guard value else { throw Failure.invalid(reason) }
    }
    private static func root() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let configured = env["TOKENBAR_SWIFT_FORMED_ROOT"],
              let scenario = env["TOKENBAR_SWIFT_FORMED_SCENARIO"],
              ["committed", "interrupted", "enriched"].contains(scenario) else {
            throw Failure.invalid("Required owned fixture root/scenario is absent")
        }
        let root = URL(fileURLWithPath: configured).standardizedFileURL
        let physical = root.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let temporaryPrefix = temporary.hasSuffix("/") ? temporary : temporary + "/"
        try require(root == physical && root.path.hasPrefix(temporaryPrefix)
            && !root.path.hasPrefix(home + "/") && root.path != home
            && !home.hasPrefix(root.path + "/") && root.lastPathComponent == scenario
            && root.deletingLastPathComponent().lastPathComponent.hasPrefix("tokenbar-swift-formed-"),
            "Fixture is not a canonical, isolated OS temporary root")
        let marker = root.appendingPathComponent(".swift-formed-fixture")
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular
            && (try String(contentsOf: marker, encoding: .utf8)) == "synthetic-swift-formed-v1\n",
            "Disposable fixture ownership marker mismatch")
        return root
    }
    private static func configuration(_ root: URL) -> BusinessDatabaseMigration.Configuration {
        // Quota imports first. The interrupted case stops after the first
        // Exact partition, while the second Home is still pending.
        let support = root.appendingPathComponent("00-support", isDirectory: true)
        return .init(container: support.appendingPathComponent("codex-ledger.sqlite"), support: support,
            exact: root.appendingPathComponent("10-exact"), legacyExact: root.appendingPathComponent("legacy-exact"))
    }
    private static func raw(_ url: URL, readOnly: Bool = true) -> SQLiteDatabaseDriver {
        SQLiteDatabaseDriver(url: url, readOnly: readOnly, createsFileIfMissing: false, bypassBusinessRoutes: true)
    }
    private static func proof(_ url: URL) throws -> BusinessStoreProof {
        try raw(url).withConnection { try CodexBusinessDatabase.proof($0) }
    }
    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private static func write<T: Encodable>(_ value: T, _ name: String, in root: URL) throws {
        let target = root.appendingPathComponent(name)
        try require(!FileManager.default.fileExists(atPath: target.path), "Refusing to overwrite phase evidence")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: target, options: .withoutOverwriting)
        try BusinessDatabaseMigration.synchronize(target)
        try BusinessDatabaseMigration.synchronize(root)
    }
    private static func read<T: Decodable>(_ type: T.Type, _ name: String, in root: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    private static func table(_ db: SQLiteDatabaseDriver, _ name: String) throws -> TableImage {
        let quoted = SQLiteStoreNamespace.quote(name)
        let columns = try db.readRows("PRAGMA table_info(\(quoted))") { $0.text(1) ?? "" }
        try require(!columns.isEmpty, "Required durable table is absent: \(name)")
        let projection = columns.map(SQLiteStoreNamespace.quote).joined(separator: ",")
        let rows = try db.readRows("SELECT \(projection) FROM \(quoted)") { row in
            columns.indices.map { row.canonicalBytes(Int32($0)).base64EncodedString() }
        }.sorted { $0.lexicographicallyPrecedes($1) }
        return .init(columns: columns, rows: rows)
    }
    private static func tables(_ db: SQLiteDatabaseDriver) throws -> [String: TableImage] {
        try Dictionary(uniqueKeysWithValues: durableTables.map { ($0, try table(db, $0)) })
    }
    private static func numeric(_ db: SQLiteDatabaseDriver, retained: Bool = false) throws -> TableImage {
        let projection = numericColumns.map { retained && $0 == "source_offset" ? "position" : $0 }
            .map(SQLiteStoreNamespace.quote).joined(separator: ",")
        let rows = try db.readRows("SELECT " + projection + " FROM " + (retained ? "retained_usage_revisions" : "events")) { row in
            numericColumns.indices.map { row.canonicalBytes(Int32($0)).base64EncodedString() }
        }.sorted { $0.lexicographicallyPrecedes($1) }
        return .init(columns: numericColumns, rows: rows)
    }
    private static func total(_ url: URL) throws -> Int {
        let value = try SQLiteDatabaseDriver(url: url, readOnly: true, createsFileIfMissing: false)
            .readRows("SELECT COALESCE(SUM(tokens),0) FROM events") { $0.int(0) }.first ?? nil
        guard let value else { throw Failure.invalid("Missing exact total") }
        return value
    }
    private static func home(_ root: URL, _ letter: String) -> URL { root.appendingPathComponent("home-" + letter) }
    private static func source(_ root: URL, _ letter: String) -> URL {
        home(root, letter).appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065a.jsonl")
    }
    private static func addSource(_ root: URL, released: Bool) throws -> URL {
        let suffix = released ? "b" : "c"
        let file = home(root, "a").appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065\(suffix).jsonl")
        let tokens = released ? 7 : 11
        let line = "{\"timestamp\":\"2026-10-21T10:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(tokens),\"total_tokens\":\(tokens)}}}}\n"
        try require(!FileManager.default.fileExists(atPath: file.path), "Raw append fixture already exists")
        try Data(line.utf8).write(to: file, options: .withoutOverwriting)
        return file
    }
    private static func sync(_ root: URL, letter: String, files: [URL], forbidParse: Bool = false) throws {
        let c = configuration(root)
        let number = letter == "a" ? 0 : 1
        let index = try CodexUsageHistoryIndex(sessionCatalogTestingDatabaseURL: c.exact.appendingPathComponent(ownerNames[number]))
        let analyzer = CodexUsageAnalyzer(dataSource: CodexDataSource(codexHome: home(root, letter), origin: .userSelected))
        _ = try index.synchronize(files: files, sessionID: analyzer.sessionID(from:)) { file, id, request, fingerprint, emit in
            if forbidParse { throw Failure.invalid("A settled or missing-raw source was parsed again") }
            return try analyzer.parseSessionIntoHistoryIndex(file: file, sessionID: id, request: request,
                insertFingerprint: fingerprint, emit: emit)
        }
    }
    private static func createSeed(_ root: URL) throws {
        let c = configuration(root)
        for directory in [c.support, c.exact] {
            try require(!FileManager.default.fileExists(atPath: directory.path), "Seed output already exists")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var originals: [String: Original] = [:]
        for (number, letter) in ["a", "b"].enumerated() {
            let scale = number + 1
            let file = source(root, letter)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lines = [(80, 20, "01"), (40, 15, "02")].map { input, output, second in
                "{\"timestamp\":\"2026-10-21T10:00:\(second)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input * scale),\"cached_input_tokens\":\(16 * scale),\"output_tokens\":\(output * scale),\"reasoning_output_tokens\":\(3 * scale),\"total_tokens\":\((input + output) * scale)}}}}"
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .withoutOverwriting)
            try sync(root, letter: letter, files: [file])
            let url = c.exact.appendingPathComponent(ownerNames[number])
            try require(try total(url) == 155 * scale, "Released parser did not form the required history")
            let db = raw(url, readOnly: false)
            _ = try db.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
            _ = try db.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
            originals["10-exact/" + ownerNames[number]] = .init(sha256: try digest(url), proof: try proof(url), tables: try tables(raw(url)))
        }
        let quota = c.support.appendingPathComponent("quota-history.sqlite")
        try QuotaHistoryDatabase(databaseURL: quota).migrate()
        let quotaDB = raw(quota, readOnly: false)
        try quotaDB.execute("INSERT INTO quota_snapshots(id,created_at,account_key,status) VALUES(42,1800000000,'swift-formed-synthetic','available'); UPDATE sqlite_sequence SET seq=12345 WHERE name='quota_snapshots'")
        _ = try quotaDB.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
        _ = try quotaDB.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
        originals["00-support/quota-history.sqlite"] = .init(sha256: try digest(quota), proof: try proof(quota), tables: [:])

        let b = try MultiClientUsageLedger(url: c.support.appendingPathComponent("multi-client-usage.sqlite"))
        let event = ClientUsageEvent(client: .claudeCode, eventID: "formed-old-event", sessionID: "formed-session", model: "synthetic",
            timestamp: Date(timeIntervalSince1970: 1800000000), inputTokens: 100, outputTokens: 20,
            cacheReadTokens: 60, cacheWriteTokens: 10, reasoningTokens: nil)
        try require(try b.ingest([event]) == 1, "Released B writer did not persist its event")
        _ = try b.database.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
        _ = try b.database.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
        try write(Seed(originals: originals, bProof: try proof(b.url)), "seed-state.json", in: root)
    }
    private static func checkOriginals(_ seed: Seed, root: URL) throws {
        try require(seed.originals.count == 3, "Both original Exact Homes and quota proof are required")
        for (relative, original) in seed.originals {
            try require(relative == "00-support/quota-history.sqlite"
                || ownerNames.map { "10-exact/" + $0 }.contains(relative), "Unexpected legacy source path")
            let url = root.appendingPathComponent(relative)
            try require(try digest(url) == original.sha256 && proof(url) == original.proof,
                "Original legacy database changed: \(relative)")
        }
    }
    private static func storeProofs(_ url: URL) throws -> [String: BusinessStoreProof] {
        try raw(url).withConnection { db in
            let stores = try db.readRows("SELECT store_id,namespace_prefix FROM tb_stores") { ($0.text(0) ?? "", $0.text(1) ?? "") }
            return try Dictionary(uniqueKeysWithValues: stores.map { id, prefix in
                (id, try CodexBusinessDatabase.proof(db, namespace: SQLiteStoreNamespace(prefix: prefix, objectNames: [])))
            })
        }
    }
    private static func finishProducer(_ root: URL, scenario: String, completed: Int, total: Int) throws -> Never {
        let c = configuration(root)
        let seed = try read(Seed.self, "seed-state.json", in: root)
        try checkOriginals(seed, root: root)
        let committed = scenario == "committed"
        let container = committed ? c.container : c.support.appendingPathComponent(".codex-ledger-migrating.sqlite")
        try require(FileManager.default.fileExists(atPath: container.path), "Released runtime did not form A")
        try require(FileManager.default.fileExists(atPath: c.container.path) == committed, "Unexpected activation boundary")
        let activation = try raw(container).readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") { $0.text(0) }.first ?? nil
        try require(activation == (committed ? "ready" : "importing"), "Wrong released activation state")
        let formed = try storeProofs(container)
        try require(formed.count == (committed ? 3 : 2), "Incorrect number of released partitions")
        var exactTables: [String: [String: TableImage]] = [:]
        if committed {
            for name in ownerNames { exactTables[name] = try tables(SQLiteDatabaseDriver(url: c.exact.appendingPathComponent(name), readOnly: true)) }
        }
        try write(Formed(producerVersion: producerVersion, producerSha: compiledSource,
            runtime: "native-swift-xctest-production-apis", scenario: scenario,
            completedImports: completed, totalInputs: total, originalProofs: seed,
            formedStoreProofs: formed, exactTables: exactTables, formedTotals: [committed ? 162 : 155, 310]),
            "formed-state.json", in: root)
        // Keep this real connection alive across _exit. A normal XCTest return
        // would close it and could checkpoint away the crash fixture WAL.
        return try raw(container, readOnly: false).withConnection { db in
            try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
            try db.execute("INSERT INTO tb_container_meta(key,value) VALUES('swift_formed_crash_probe','committed-before-exit')")
            Darwin._exit(86)
        }
    }
    private static func produce(_ root: URL, scenario: String) throws {
        try require(compiledRole == "release", "Only the pinned release may produce old state")
        try createSeed(root)
        let c = configuration(root)
        if scenario != "committed" {
            try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 34, onProgress: { progress in
                if progress.stage == .importing && progress.completed == 2 {
                    do { try Self.finishProducer(root, scenario: scenario, completed: 2, total: progress.total) }
                    catch {
                        FileHandle.standardError.write(Data("SWIFT_FORMED_PRODUCER_ERROR \(error)\n".utf8))
                        Darwin._exit(87)
                    }
                }
            })
            throw Failure.invalid("The required interrupted import boundary was not reached")
        }
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 34)
        let added = try addSource(root, released: true)
        try sync(root, letter: "a", files: [source(root, "a"), added])
        try require(try total(c.exact.appendingPathComponent(ownerNames[0])) == 162,
            "Released A must include post-activation history absent from its legacy original")
        try finishProducer(root, scenario: scenario, completed: 3, total: 3)
    }
    private static func updateUsingReleasedOwner(_ root: URL, scenario: String) throws {
        try require(compiledRole == "release", "Only the actual release may form a late legacy observation")
        let formed = try read(Formed.self, "formed-state.json", in: root)
        try require(formed.scenario == scenario && ["interrupted", "enriched"].contains(scenario), "Late legacy update requires an unfinished A")
        try checkOriginals(formed.originalProofs, root: root)
        let c = configuration(root)
        let previous = c.support.appendingPathComponent(".codex-ledger-migrating.sqlite")
        let relative = "10-exact/" + ownerNames[0]
        let original = c.exact.appendingPathComponent(ownerNames[0])
        let backupName = scenario == "enriched" ? "pre-enrichment-exact.sqlite" : "pre-append-exact.sqlite"
        let backup = root.appendingPathComponent(backupName)
        try require(!FileManager.default.fileExists(atPath: backup.path), "Previous Exact evidence already exists")
        // The seed was explicitly closed/checkpointed in DELETE mode. Preserve
        // those exact original bytes before the real old writer changes them.
        try FileManager.default.copyItem(at: original, to: backup)
        try BusinessDatabaseMigration.synchronize(backup)
        let file = source(root, "a")
        let oldNumeric = try numeric(raw(original))
        let oldIdentities = try table(raw(original), "usage_ledger_identities")
        let oldBindings = try table(raw(original), "usage_ledger_bindings")
        let rawBefore = try digest(file)
        if scenario == "enriched" {
            try require(try raw(original).readRows("SELECT COUNT(*) FROM events WHERE model IS NULL AND user_prompt_offset IS NULL") { $0.int(0) } == [2],
                "The actual released producer did not naturally form empty model/turn metadata")
            let retainedRaw = root.appendingPathComponent("pre-enrichment-rollout.jsonl")
            try FileManager.default.copyItem(at: file, to: retainedRaw)
            let prefix = """
                {"timestamp":"2026-10-21T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5"}}
                {"timestamp":"2026-10-21T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"restored prompt"}]}}
                {"timestamp":"2026-10-21T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"restored answer"}]}}

                """
            try (Data(prefix.utf8) + Data(contentsOf: file)).write(to: file, options: .atomic)
            try require(try digest(retainedRaw) == rawBefore, "The old raw representation was not preserved")
        } else {
            let line = "{\"timestamp\":\"2026-10-21T10:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":17,\"total_tokens\":17}}}}\n"
            let handle = try FileHandle(forWritingTo: file)
            _ = try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)); try handle.close()
        }
        // This separate release process has no active routes. It exercises
        // the released legacy owner, including sources/checkpoints/derived
        // updates, while the previously imported A partition stays frozen.
        try sync(root, letter: "a", files: [file])
        let total = scenario == "enriched" ? 155 : 172
        try require(try Self.total(original) == total, "The released legacy writer changed the required numeric total")
        let db = raw(original, readOnly: false)
        _ = try db.readRows("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
        _ = try db.readRows("PRAGMA journal_mode=DELETE") { $0.text(0) }
        let updatedTables = try tables(raw(original))
        guard let beforeEvents = formed.originalProofs.originals[relative]?.tables["events"],
              let afterEvents = updatedTables["events"] else { throw Failure.invalid("Missing old/current Exact events") }
        let enrichment: Enrichment?
        if scenario == "enriched" {
            let afterNumeric = try numeric(raw(original))
            try require(afterNumeric == oldNumeric && (try table(raw(original), "usage_ledger_identities")) == oldIdentities,
                "Released enrichment changed an old typed numeric fact or identity")
            try require(try table(raw(original), "usage_ledger_bindings") != oldBindings,
                "Released enrichment did not exercise an actual raw-generation rebinding")
            try require(try raw(original).readRows("SELECT COUNT(*) FROM events WHERE model='gpt-5' AND user_prompt_offset IS NOT NULL AND assistant_start_offset IS NOT NULL") { $0.int(0) } == [2],
                "Released admit/enrichTurn did not complete model and turn metadata")
            let versions = try table(raw(original), "retained_usage_revisions")
            try require(versions.rows.count == 2 && (try raw(original).readRows("SELECT COUNT(*) FROM retained_usage_revisions WHERE model IS NULL") { $0.int(0) }) == [2],
                "Released enrichment did not retain both old model versions")
            try require(try numeric(raw(original), retained: true) == oldNumeric,
                "Retained versions do not contain every exact historical numeric field")
            enrichment = .init(numericBefore: oldNumeric, numericAfter: afterNumeric, retainedVersions: versions,
                rawBeforeSha256: rawBefore, rawAfterSha256: try digest(file))
        } else {
            try require(beforeEvents.columns == afterEvents.columns
                && Set(beforeEvents.rows).isSubset(of: Set(afterEvents.rows)),
                "The late released writer changed an old typed event")
            enrichment = nil
        }
        try require(try storeProofs(previous) == formed.formedStoreProofs, "The late writer changed unfinished A")
        var latest = formed.originalProofs.originals
        latest[relative] = .init(sha256: try digest(original), proof: try proof(original), tables: updatedTables)
        try write(LateSource(latest: Seed(originals: latest, bProof: formed.originalProofs.bProof),
            previousExactBackup: backupName, enrichment: enrichment), "late-source-state.json", in: root)
        try checkPreviousExact(formed, root: root)
        var report: [String: Any] = ["status": "PASS", "phase": scenario == "enriched" ? "legacy-enrich" : "legacy-append", "scenario": scenario,
            "producerVersion": producerVersion, "producerSha": compiledSource, "runtime": "native-swift-xctest-production-apis",
            "totals": [total, 310], "frozenDestinationUnchanged": true,
            "previousOriginalPreserved": true]
        if scenario == "enriched" {
            report["oldNumericRowsPreserved"] = true; report["oldIdentityRowsPreserved"] = true
            report["nullModelAndTurnCompleted"] = true; report["originalVersionsRetained"] = true
        } else { report["oldTypedEventsPreserved"] = true }
        print("TOKENBAR_SWIFT_FORMED_REPORT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
    private static func checkPreviousExact(_ formed: Formed, root: URL) throws {
        let expected = formed.originalProofs.originals["10-exact/" + ownerNames[0]]
        let backup = root.appendingPathComponent(formed.scenario == "enriched" ? "pre-enrichment-exact.sqlite" : "pre-append-exact.sqlite")
        try require(try digest(backup) == expected?.sha256 && proof(backup) == expected?.proof,
            "The pre-append original Exact database was not preserved")
    }
    private static func resume(_ root: URL, scenario: String, phase: String) throws {
        try require(compiledRole == "candidate", "Only the candidate may resume old state")
        let c = configuration(root)
        let formed = try read(Formed.self, "formed-state.json", in: root)
        try require(formed.producerVersion == producerVersion && formed.scenario == scenario,
            "Producer identity/scenario differs")
        let handoff: Seed
        if scenario != "committed" {
            let late = try read(LateSource.self, "late-source-state.json", in: root)
            try require(late.previousExactBackup == (scenario == "enriched" ? "pre-enrichment-exact.sqlite" : "pre-append-exact.sqlite"), "Unexpected original evidence path")
            if scenario == "enriched" {
                guard let enrichment = late.enrichment else { throw Failure.invalid("Required released enrichment evidence is missing") }
                try require(enrichment.numericBefore == enrichment.numericAfter && enrichment.retainedVersions.rows.count == 2,
                    "Incomplete released enrichment evidence")
            }
            handoff = late.latest
            try checkPreviousExact(formed, root: root)
        } else { handoff = formed.originalProofs }
        try checkOriginals(handoff, root: root)
        if phase == "resume" {
            let previous = scenario == "committed" ? c.container : c.support.appendingPathComponent(".codex-ledger-migrating.sqlite")
            try require(try storeProofs(previous) == formed.formedStoreProofs, "Released namespace proof changed before candidate startup")
        }
        try BusinessDatabaseMigration.migrate(c, availableBytes: 1 << 34)
        try require(try raw(c.container).readRows("SELECT value FROM tb_container_meta WHERE key='swift_formed_crash_probe'") { $0.text(0) } == ["committed-before-exit"],
            "Committed producer WAL was not recovered")
        try require(try raw(c.container).readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") { $0.text(0) } == ["ready"], "Candidate activation did not complete")
        let expected = [scenario == "committed" ? 173 : (scenario == "enriched" ? 166 : 183), 310]
        if phase == "resume" {
            let resumedProofs = try storeProofs(c.container)
            let changedExactID = c.specification(for: c.exact.appendingPathComponent(ownerNames[0]))?.id
            for (id, before) in formed.formedStoreProofs {
                if scenario != "committed" && id == changedExactID { continue }
                try require(resumedProofs[id] == before,
                    "A released namespace lost or changed typed rows during startup")
            }
            for (number, name) in ownerNames.enumerated() {
                let expectedTables = scenario == "committed" ? formed.exactTables[name] : handoff.originals["10-exact/" + name]?.tables
                try require(try tables(SQLiteDatabaseDriver(url: c.exact.appendingPathComponent(name), readOnly: true)) == expectedTables,
                    "Released typed Exact history changed during upgrade")
                let incomingTotals = scenario == "committed" ? formed.formedTotals : [scenario == "enriched" ? 155 : 172, 310]
                try require(try total(c.exact.appendingPathComponent(name)) == incomingTotals[number], "Pre-append total differs")
            }
            let candidateAdded = try addSource(root, released: false)
            var files = [source(root, "a"), candidateAdded]
            if scenario == "committed" {
                files.append(home(root, "a").appendingPathComponent("sessions/rollout-019ff8b9-09e7-75c1-b9a5-14fe7b60065b.jsonl"))
            }
            try sync(root, letter: "a", files: files)
            try sync(root, letter: "a", files: files, forbidParse: true)
            for file in files + [source(root, "b")] { try FileManager.default.removeItem(at: file) }
            for letter in ["a", "b"] { try sync(root, letter: letter, files: [], forbidParse: true) }
            var events: [String: TableImage] = [:]
            for name in ownerNames { events[name] = try table(SQLiteDatabaseDriver(url: c.exact.appendingPathComponent(name), readOnly: true), "events") }
            try write(events, "resumed-events.json", in: root)
            var retained: [String: [String: TableImage]] = [:]
            for name in ownerNames {
                let db = SQLiteDatabaseDriver(url: c.exact.appendingPathComponent(name), readOnly: true)
                retained[name] = try Dictionary(uniqueKeysWithValues: retainedTables.map { ($0, try table(db, $0)) })
            }
            try write(retained, "resumed-retention.json", in: root)
        } else {
            let events = try read([String: TableImage].self, "resumed-events.json", in: root)
            let retained = try read([String: [String: TableImage]].self, "resumed-retention.json", in: root)
            for (letter, name) in zip(["a", "b"], ownerNames) {
                let rawFiles = try FileManager.default.contentsOfDirectory(at: home(root, letter).appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
                try require(rawFiles.isEmpty, "Missing-raw reopen fixture unexpectedly still has raw files")
                try sync(root, letter: letter, files: [], forbidParse: true)
                try require(try table(SQLiteDatabaseDriver(url: c.exact.appendingPathComponent(name), readOnly: true), "events") == events[name],
                    "Missing-raw restart changed historical event rows")
                let db = SQLiteDatabaseDriver(url: c.exact.appendingPathComponent(name), readOnly: true)
                for tableName in retainedTables {
                    try require(try table(db, tableName) == retained[name]?[tableName], "Missing-raw restart lost a retained history version")
                }
            }
        }
        let totals = try ownerNames.map { try total(c.exact.appendingPathComponent($0)) }
        try require(totals == expected, "Increment or missing-raw history was lost/doubled")
        let quota = SQLiteDatabaseDriver(url: c.support.appendingPathComponent("quota-history.sqlite"), readOnly: true)
        try require(try quota.readRows("SELECT id FROM quota_snapshots ORDER BY id") { $0.int(0) } == [42], "Quota identity changed")
        try require(try quota.readRows("SELECT seq FROM sqlite_sequence WHERE name='quota_snapshots'") { $0.int(0) } == [12345], "Quota AUTOINCREMENT state changed")
        let b = try MultiClientUsageLedger(url: c.support.appendingPathComponent("multi-client-usage.sqlite"))
        try require(try proof(b.url) == formed.originalProofs.bProof, "Released B typed history changed")
        try checkOriginals(handoff, root: root)
        if scenario != "committed" { try checkPreviousExact(formed, root: root) }
        var report: [String: Any] = ["status": "PASS", "phase": phase, "scenario": scenario,
            "runtime": "native-swift-xctest-production-apis", "producerVersion": producerVersion,
            "producerSha": formed.producerSha, "candidateSha": compiledSource,
            "totals": totals, "oldTypedProofsPreserved": true, "originalDatabasesUnchanged": true,
            "crashWALPreserved": true, "oldBPreserved": true, "rawDisappearanceRetainsHistory": true]
        if scenario == "enriched" {
            let active = SQLiteDatabaseDriver(url: c.exact.appendingPathComponent(ownerNames[0]), readOnly: true)
            try require(try active.readRows("SELECT COUNT(*) FROM events WHERE model='gpt-5' AND user_prompt_offset IS NOT NULL") { $0.int(0) } == [2],
                "Upgraded model/turn history is unavailable")
            try require(try active.readRows("SELECT COUNT(*) FROM retained_usage_revisions WHERE model IS NULL") { $0.int(0) } == [2],
                "Original metadata versions were discarded")
            report["nullModelAndTurnCompleted"] = true; report["originalVersionsRetained"] = true
        }
        print("TOKENBAR_SWIFT_FORMED_REPORT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
    func testRunIsolatedPhase() throws {
        let root = try Self.root()
        let env = ProcessInfo.processInfo.environment
        guard let phase = env["TOKENBAR_SWIFT_FORMED_PHASE"], let scenario = env["TOKENBAR_SWIFT_FORMED_SCENARIO"],
              ["produce", "legacy-append", "legacy-enrich", "resume", "reopen"].contains(phase) else { throw Failure.invalid("Unknown phase") }
        defer { BusinessSQLiteRoutes.deactivate() }
        if phase == "produce" { try Self.produce(root, scenario: scenario) }
        else if phase == "legacy-append" || phase == "legacy-enrich" {
            try Self.require((phase == "legacy-enrich") == (scenario == "enriched"), "Wrong released update phase")
            try Self.updateUsingReleasedOwner(root, scenario: scenario)
        }
        else { try Self.resume(root, scenario: scenario, phase: phase) }
    }
}
