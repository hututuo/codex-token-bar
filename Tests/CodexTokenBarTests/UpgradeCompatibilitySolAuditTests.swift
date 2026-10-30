import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

/// Upgrade gate regressions discovered while auditing the public v0.9.7 -> A/B route.
/// All paths and permission changes stay inside one disposable test directory.
final class UpgradeCompatibilitySolAuditTests: XCTestCase {
    private func fixture() throws -> (URL, BusinessDatabaseMigration.Configuration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upgrade-compatibility-sol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            BusinessSQLiteRoutes.deactivate()
            try? FileManager.default.removeItem(at: root)
        }
        let support = root.appendingPathComponent("support")
        return (root, .init(
            container: support.appendingPathComponent("codex-ledger.sqlite"),
            support: support,
            exact: root.appendingPathComponent("exact"),
            legacyExact: root.appendingPathComponent("legacy-exact")
        ))
    }

    private func denyDirectoryRead(_ directory: URL) throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses the directory permission fixture") }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        // Validate the fixture itself so this test cannot pass because the
        // runner ignores POSIX directory permissions.
        do {
            _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            throw XCTSkip("The runner can read a chmod 000 directory")
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return
        }
    }

    func testUnreadableNestedLegacyDirectoryStopsActivationAndCanRetry() throws {
        let (_, configuration) = try fixture()
        let modeltraceDirectory = configuration.support.appendingPathComponent("modeltrace")
        let legacy = modeltraceDirectory.appendingPathComponent("modeltrace.sqlite")
        let raw = SQLiteDatabaseDriver(url: legacy, bypassBusinessRoutes: true)
        try raw.execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY); INSERT INTO preserved VALUES(42)")
        let original = try raw.withConnection { try CodexBusinessDatabase.proof($0) }
        try denyDirectoryRead(modeltraceDirectory)

        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.container.appendingPathExtension("initialized").path))
        XCTAssertNil(BusinessSQLiteRoutes.store(for: legacy), "An incomplete discovery must not release business owners")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: modeltraceDirectory.path)
        try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32)
        XCTAssertEqual(try SQLiteDatabaseDriver(url: legacy).readRows("SELECT id FROM preserved") { $0.int(0) }, [42])
        XCTAssertEqual(try raw.withConnection { try CodexBusinessDatabase.proof($0) }, original)
    }

    func testUnreadableExactRootCannotPublishAnEmptyReadyContainer() throws {
        let (_, configuration) = try fixture()
        try FileManager.default.createDirectory(at: configuration.exact, withIntermediateDirectories: true)
        let legacy = configuration.exact.appendingPathComponent(String(repeating: "a", count: 64) + ".sqlite")
        // Discovery must reject the inaccessible root before normalization.
        // A real released index is unnecessary to exercise that boundary.
        try SQLiteDatabaseDriver(url: legacy, bypassBusinessRoutes: true)
            .execute("CREATE TABLE preserved(id INTEGER PRIMARY KEY); INSERT INTO preserved VALUES(17)")
        try denyDirectoryRead(configuration.exact)

        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.container.appendingPathExtension("initialized").path))
        XCTAssertNil(BusinessSQLiteRoutes.store(for: legacy))
    }

    func testUnsearchableExactAncestorIsNotTreatedAsAnAbsentRoot() throws {
        let (root, base) = try fixture()
        let blocked = root.appendingPathComponent("blocked")
        let exact = blocked.appendingPathComponent("exact")
        try FileManager.default.createDirectory(at: exact, withIntermediateDirectories: true)
        let configuration = BusinessDatabaseMigration.Configuration(
            container: base.container, support: base.support,
            exact: exact, legacyExact: base.legacyExact
        )
        try denyDirectoryRead(blocked)

        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.container.appendingPathExtension("initialized").path))
    }

    func testTrulyAbsentLegacyDirectoriesRemainAValidFirstInstallation() throws {
        let (_, configuration) = try fixture()
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.exact.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.legacyExact.path))

        try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.container.appendingPathExtension("initialized").path))
        let raw = SQLiteDatabaseDriver(
            url: configuration.container, readOnly: true,
            createsFileIfMissing: false, bypassBusinessRoutes: true
        )
        XCTAssertEqual(try raw.readRows("SELECT COUNT(*) FROM tb_stores") { $0.int(0) }, [0])
        XCTAssertEqual(try raw.readRows("SELECT value FROM tb_container_meta WHERE key='activation_state'") { $0.text(0) }, ["ready"])
    }

    func testConfiguredExactDirectorySymlinkStillWorksAndDanglingRootFails() throws {
        let (root, base) = try fixture()
        let actual = root.appendingPathComponent("actual-exact")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.exact, withDestinationURL: actual)
        try BusinessDatabaseMigration.migrate(base, availableBytes: 1 << 32)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.container.appendingPathExtension("initialized").path))
        BusinessSQLiteRoutes.deactivate()
        let dangling = root.appendingPathComponent("dangling-exact")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent-target"))
        let container = root.appendingPathComponent("second-support/codex-ledger.sqlite")
        let configuration = BusinessDatabaseMigration.Configuration(
            container: container, support: container.deletingLastPathComponent(),
            exact: dangling, legacyExact: base.legacyExact
        )
        XCTAssertThrowsError(try BusinessDatabaseMigration.migrate(configuration, availableBytes: 1 << 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathExtension("initialized").path))
    }

    func testPublicV097JSONBodyHistoryImportsOnceWithoutChangingItsOriginal() async throws {
        let (root, _) = try fixture()
        let now = 1_800_000_600.0
        let legacy = root.appendingPathComponent("observed-speed-public097.json")
        let logical = root.appendingPathComponent("body-speed-public097.sqlite")
        let shared = root.appendingPathComponent("multi-client-usage.sqlite")
        let sample = ObservedSpeedSample(
            id: "public097-body", threadID: "thread-a", turnID: "turn-a", itemID: "item-a",
            model: "gpt-6.1-sol", startedAt: now - 64, endedAt: now - 60,
            outputTokens: 200, outputCharacters: 400, outputBytes: 400, chunkCount: 1,
            durationSeconds: 4, tokensPerSecond: 50, confidence: "high", networkWarning: nil,
            source: "Codex 本地已完成正文", measurementKind: "completed_body", tokenizer: "o200k_base",
            bodyPhase: "final_answer"
        )
        var oldStream = sample
        oldStream.id = "public097-stream"
        oldStream.measurementKind = nil
        oldStream.tokenizer = nil
        let bytes = try JSONEncoder().encode([sample, oldStream])
        try bytes.write(to: legacy)

        let first = try await BodySpeedSampleWriter(sharedURL: shared).load(from: logical, now: now)
        XCTAssertEqual(first, [sample], "Public v0.9.7 stored JSON; a SQLite-only importer misses that actual release")
        let second = try await BodySpeedSampleWriter(sharedURL: shared).load(from: logical, now: now)
        XCTAssertEqual(second, [sample])
        let store = try BodySpeedTrendStore(url: logical, sharedURL: shared)
        XCTAssertEqual(try store.read(now: now, days: 1).reduce(Int64(0)) { $0 + $1.sampleCount }, 1)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes, "The full JSON, including legacy stream evidence, must remain untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logical.path), "Production body history belongs to B")
    }

    func testNewerSQLiteBodyIDWinsAndCommittedJSONNeverReplaysAfterPruning() async throws {
        let (root, _) = try fixture()
        let now = 1_800_000_600.0
        let legacy = root.appendingPathComponent("observed-speed-existing097.json")
        let logical = root.appendingPathComponent("body-speed-existing097.sqlite")
        let shared = root.appendingPathComponent("multi-client-usage.sqlite")
        let old = ObservedSpeedSample(
            id: "same-id", threadID: "thread", turnID: "turn", itemID: "item", model: "gpt-6.1-sol",
            startedAt: now - 62, endedAt: now - 60, outputTokens: 100, outputCharacters: 200,
            outputBytes: 200, chunkCount: 1, durationSeconds: 2, tokensPerSecond: 50,
            confidence: "medium", networkWarning: nil, source: "legacy-v097",
            measurementKind: "completed_body", tokenizer: "o200k_base", bodyPhase: "final_answer"
        )
        var newer = old
        newer.outputTokens = 200
        newer.tokensPerSecond = 100
        let store = try BodySpeedTrendStore(url: logical, sharedURL: shared)
        try store.ingest(samples: [newer], now: now, retentionDays: 15)
        let bytes = try JSONEncoder().encode([old])
        try bytes.write(to: legacy)
        let first = try await BodySpeedSampleWriter(sharedURL: shared).load(from: logical, now: now, retentionDays: 15)
        XCTAssertEqual(first, [newer])
        XCTAssertEqual(try store.retentionDays(), 15)
        let database = try BodySpeedDatabase(logicalURL: logical, sharedURL: shared)
        try database.transaction {
            try $0.execute("DELETE FROM speed_samples; DELETE FROM speed_sample_ids; DELETE FROM speed_5m")
        }
        let afterRestart = try await BodySpeedSampleWriter(sharedURL: shared).load(from: logical, now: now, retentionDays: 15)
        XCTAssertTrue(afterRestart.isEmpty, "A committed import receipt must fence frozen JSON after projections have been pruned")
        XCTAssertTrue(try store.read(now: now, days: 1).isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    func testUnreadableOrInvalidPublicV097JSONCannotSilentlyBecomeEmptyHistory() async throws {
        let (root, _) = try fixture()
        let legacy = root.appendingPathComponent("observed-speed-invalid097.json")
        let logical = root.appendingPathComponent("body-speed-invalid097.sqlite")
        let shared = root.appendingPathComponent("multi-client-usage.sqlite")
        let bytes = Data("{invalid legacy JSON".utf8)
        try bytes.write(to: legacy)
        do {
            _ = try await BodySpeedSampleWriter(sharedURL: shared).load(from: logical, now: 1_800_000_600)
            XCTFail("A present but unreadable legacy history must stop the body owner rather than publish an empty history")
        } catch {
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        }
    }
}
