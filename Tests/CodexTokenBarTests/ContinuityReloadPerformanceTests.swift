import Combine
import Foundation
import XCTest
@testable import CodexTokenBar

/// Presentation work may be skipped only after a fresh authoritative read.
/// All defaults, database files and synthetic source paths are disposable.
@MainActor
final class ContinuityReloadPerformanceTests: XCTestCase {
    func testUnchangedDefaultsReloadDoesNotPublishEmptyGapOrRecoveryState() throws {
        let losses: [PreciseTimeSeriesContinuityLossRecord?] = [
            nil, record(1), record(2, reason: .storageRecovery),
        ]
        for loss in losses {
            let context = try fixture()
            defer { context.cleanup() }
            context.defaults.set(try payload(loss, source: context.source), forKey: context.storageKey)
            let store = makeStore(context)
            assertObserved(store, loss: loss)
            if loss?.reason == .storageRecovery {
                XCTAssertEqual(store.sharedAccountSafetyRecoveryState, .awaitingFreshBaseline)
            }

            var publications = 0
            let observation = store.objectWillChange.sink { publications += 1 }
            for _ in 0..<5 { store.reloadPreciseTimeSeriesContinuityLoss() }

            assertObserved(store, loss: loss)
            XCTAssertEqual(publications, 0, "identical defaults state must not invalidate the dashboard")
            withExtendedLifetime(observation) {}
        }
    }

    func testUnchangedDatabaseReloadDoesNotPublishEmptyGapOrRecoveryState() throws {
        let losses: [PreciseTimeSeriesContinuityLossRecord?] = [
            nil, record(3), record(4, reason: .storageRecovery),
        ]
        for loss in losses {
            let context = try fixture()
            defer { context.cleanup() }
            let database = SharedAccountUsageSafetyDatabase(url: context.databaseURL)
            XCTAssertTrue(database.store(try payload(loss, source: context.source), as: .preciseContinuity))
            let store = makeStore(context, database: database)
            assertObserved(store, loss: loss)
            if loss?.reason == .storageRecovery {
                XCTAssertEqual(store.sharedAccountSafetyRecoveryState, .awaitingFreshBaseline)
            }

            var publications = 0
            let observation = store.objectWillChange.sink { publications += 1 }
            for _ in 0..<5 { store.reloadPreciseTimeSeriesContinuityLoss() }

            assertObserved(store, loss: loss)
            XCTAssertTrue(database.persistenceHealthy)
            XCTAssertEqual(publications, 0, "identical durable state must not invalidate the dashboard")
            withExtendedLifetime(observation) {}
        }
    }

    func testFreshExternalDatabaseReplacementAndRemovalAreObservedOnEveryReload() throws {
        let context = try fixture()
        defer { context.cleanup() }
        let database = SharedAccountUsageSafetyDatabase(url: context.databaseURL)
        let store = makeStore(context, database: database)
        let externalWriter = SharedAccountUsageSafetyDatabase(url: context.databaseURL)
        assertObserved(store, loss: nil)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }

        let mutations: [PreciseTimeSeriesContinuityLossRecord?] = [
            record(5), record(6, reason: .storageRecovery), nil,
        ]
        for loss in mutations {
            XCTAssertTrue(externalWriter.store(try payload(loss, source: context.source), as: .preciseContinuity))
            publications = 0
            store.reloadPreciseTimeSeriesContinuityLoss()
            assertObserved(store, loss: loss)
            XCTAssertGreaterThan(publications, 0, "a changed authoritative payload must reach observers")

            publications = 0
            store.reloadPreciseTimeSeriesContinuityLoss()
            assertObserved(store, loss: loss)
            XCTAssertEqual(publications, 0, "the next unchanged read must stop redundant publication")
        }
        withExtendedLifetime(observation) {}
    }

    func testNewDefaultsCorruptionFailsClosedWithoutReplacingEvidenceOrCachingLastGood() throws {
        let context = try fixture()
        defer { context.cleanup() }
        let initial = record(7)
        context.defaults.set(try payload(initial, source: context.source), forKey: context.storageKey)
        let store = makeStore(context)
        assertObserved(store, loss: initial)
        let corrupt = Data(#"{"unexpected":true}"#.utf8)
        context.defaults.set(corrupt, forKey: context.storageKey)

        store.reloadPreciseTimeSeriesContinuityLoss()
        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertNil(store.preciseTimeSeriesContinuityLossID)
        XCTAssertNil(store.preciseTimeSeriesContinuityLostAt)
        XCTAssertNil(store.preciseTimeSeriesContinuityLossReason)
        XCTAssertEqual(context.defaults.data(forKey: context.storageKey), corrupt)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        store.reloadPreciseTimeSeriesContinuityLoss()
        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(context.defaults.data(forKey: context.storageKey), corrupt)

        // Defaults are the legacy/test backend. A fresh valid value is read on
        // the next callback; no successful or failed result is cached.
        let repaired = record(8)
        context.defaults.set(try payload(repaired, source: context.source), forKey: context.storageKey)
        store.reloadPreciseTimeSeriesContinuityLoss()
        assertObserved(store, loss: repaired)
        XCTAssertGreaterThan(publications, 0)
        withExtendedLifetime(observation) {}
    }

    func testNewDatabaseTypedCorruptionFailsClosedAndKeepsDurableEvidence() throws {
        let context = try fixture()
        defer { context.cleanup() }
        let database = SharedAccountUsageSafetyDatabase(url: context.databaseURL)
        let initial = record(9)
        XCTAssertTrue(database.store(try payload(initial, source: context.source), as: .preciseContinuity))
        let store = makeStore(context, database: database)
        assertObserved(store, loss: initial)
        let externalWriter = SharedAccountUsageSafetyDatabase(url: context.databaseURL)
        // Valid generic JSON, invalid typed continuity data: exercise the real
        // typed fail-closed boundary without bypassing its durable writer.
        let corrupt = Data(#"{"unexpected":true}"#.utf8)
        XCTAssertTrue(externalWriter.store(corrupt, as: .preciseContinuity))

        store.reloadPreciseTimeSeriesContinuityLoss()
        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertFalse(database.persistenceHealthy)
        XCTAssertNil(store.preciseTimeSeriesContinuityLossID)
        XCTAssertNil(store.preciseTimeSeriesContinuityLostAt)
        XCTAssertNil(store.preciseTimeSeriesContinuityLossReason)
        XCTAssertEqual(SharedAccountUsageSafetyDatabase(url: context.databaseURL).load(.preciseContinuity), corrupt,
            "failure must retain the corrupt record for explicit recovery")
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        store.reloadPreciseTimeSeriesContinuityLoss()
        XCTAssertFalse(store.preciseContinuityPersistenceHealthy)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observation) {}
    }

    private func record(_ index: Int, reason: PreciseTimeSeriesContinuityLossReason = .observationGap) -> PreciseTimeSeriesContinuityLossRecord {
        .init(id: UUID(), detectedAt: Date(timeIntervalSince1970: Double(2_400 + index)), reason: reason)
    }

    private func payload(_ loss: PreciseTimeSeriesContinuityLossRecord?, source: CodexDataSource) throws -> Data {
        let values = loss.map { [CodexUsageStore.continuityIdentifier(for: source): $0] } ?? [:]
        return try JSONEncoder().encode(values)
    }

    private func makeStore(_ context: Fixture, database: SharedAccountUsageSafetyDatabase? = nil) -> CodexUsageStore {
        CodexUsageStore(resolver: ContinuityReloadSourceResolver(source: context.source), autoStart: false,
            continuityDefaults: context.defaults, continuityStorageKey: context.storageKey,
            legacyContinuityStorageKey: nil, continuitySafetyDatabase: database)
    }

    private func assertObserved(_ store: CodexUsageStore, loss: PreciseTimeSeriesContinuityLossRecord?,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(store.preciseContinuityPersistenceHealthy, file: file, line: line)
        XCTAssertEqual(store.preciseTimeSeriesContinuityLossID, loss?.id, file: file, line: line)
        XCTAssertEqual(store.preciseTimeSeriesContinuityLostAt, loss?.detectedAt, file: file, line: line)
        XCTAssertEqual(store.preciseTimeSeriesContinuityLossReason, loss?.reason, file: file, line: line)
    }

    private func fixture() throws -> Fixture {
        let suite = "ContinuityReloadPerformanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root, suite: suite, defaults: defaults, storageKey: "synthetic-continuity",
            source: CodexDataSource(codexHome: root.appendingPathComponent("synthetic-home"), origin: .userSelected))
    }

    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let storageKey: String
        let source: CodexDataSource
        var databaseURL: URL { root.appendingPathComponent("safety.sqlite") }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct ContinuityReloadSourceResolver: CodexDataSourceResolving {
    let source: CodexDataSource
    func resolve() -> CodexDataSource? { source }
    func saveSelectedDirectory(_ directory: URL) -> CodexDataSource? { source }
}
