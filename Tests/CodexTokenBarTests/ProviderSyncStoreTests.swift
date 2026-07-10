import Foundation
import XCTest
@testable import CodexTokenBar

@MainActor
final class ProviderSyncStoreTests: XCTestCase {
    func testSourceTransitionRejectsLatePreviousSourceCompletion() async throws {
        let sourceA = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderSourceA"),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderSourceB"),
            origin: .userSelected
        )
        let runner = SuspendedProviderSyncRunner()
        let store = ProviderSyncStore(runner: runner)

        XCTAssertTrue(store.setDataSource(sourceA))
        store.scan(dataSource: sourceA)
        await waitUntil("source A provider scan pending") {
            await runner.hasPending(.scan, codexHome: sourceA.codexHome)
        }

        XCTAssertTrue(store.setDataSource(sourceB))
        XCTAssertEqual(store.currentDataSource?.stableIdentityKey, sourceB.stableIdentityKey)
        XCTAssertEqual(store.snapshot.codexHome, sourceB.displayPath)

        await runner.complete(
            .scan,
            codexHome: sourceA.codexHome,
            with: providerSnapshot(status: "late source A", provider: "source-a-provider")
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotEqual(store.snapshot.status, "late source A")
        XCTAssertNotEqual(store.snapshot.detectedProvider, "source-a-provider")
        XCTAssertEqual(store.currentDataSource?.stableIdentityKey, sourceB.stableIdentityKey)
    }

    func testBoundProviderSourceOverridesStaleViewArgument() async throws {
        let sourceA = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderStaleViewSourceA"),
            origin: .userSelected
        )
        let sourceB = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderBoundSourceB"),
            origin: .userSelected
        )
        let runner = SuspendedProviderSyncRunner()
        let store = ProviderSyncStore(runner: runner)
        store.setDataSource(sourceB)

        store.scan(dataSource: sourceA)
        await waitUntil("provider scan request") {
            let hasSourceA = await runner.hasPending(.scan, codexHome: sourceA.codexHome)
            let hasSourceB = await runner.hasPending(.scan, codexHome: sourceB.codexHome)
            return hasSourceA || hasSourceB
        }

        let requestedSourceA = await runner.hasPending(.scan, codexHome: sourceA.codexHome)
        let requestedSourceB = await runner.hasPending(.scan, codexHome: sourceB.codexHome)
        XCTAssertFalse(requestedSourceA)
        XCTAssertTrue(requestedSourceB)

        let completedSource = requestedSourceB ? sourceB : sourceA
        await runner.complete(
            .scan,
            codexHome: completedSource.codexHome,
            with: providerSnapshot(status: "扫描完成", provider: "openai")
        )
    }

    func testOlderNonDestructiveOperationCannotOverwriteNewerSnapshot() async throws {
        let source = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderSyncRaceHome"),
            origin: .userSelected
        )
        let runner = SuspendedProviderSyncRunner()
        let store = ProviderSyncStore(runner: runner)

        store.scan(dataSource: source)
        await waitUntil("scan request pending") {
            await runner.hasPending(.scan, codexHome: source.codexHome)
        }

        store.verify(dataSource: source)
        await waitUntil("verify request pending") {
            await runner.hasPending(.verify, codexHome: source.codexHome)
        }

        await runner.complete(
            .verify,
            codexHome: source.codexHome,
            with: providerSnapshot(status: "验证新结果", provider: "new")
        )
        await waitUntil("verify snapshot published") {
            store.snapshot.status == "验证新结果"
        }

        await runner.complete(
            .scan,
            codexHome: source.codexHome,
            with: providerSnapshot(status: "扫描旧结果", provider: "old")
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.snapshot.status, "验证新结果")
        XCTAssertEqual(store.snapshot.detectedProvider, "new")
        XCTAssertTrue(store.hasVerified)
    }

    func testDestructiveOperationDoesNotStartWhileAnotherOperationIsWorking() async throws {
        let source = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderSyncSerializedHome"),
            origin: .userSelected
        )
        let runner = SuspendedProviderSyncRunner()
        let store = ProviderSyncStore(runner: runner)

        store.scan(dataSource: source)
        await waitUntil("scan request pending") {
            await runner.hasPending(.scan, codexHome: source.codexHome)
        }

        store.sync(dataSource: source)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let hasSyncPending = await runner.hasPending(.sync, codexHome: source.codexHome)
        XCTAssertFalse(hasSyncPending)
        XCTAssertTrue(store.snapshot.isWorking)
        XCTAssertEqual(store.snapshot.status, "已有修复操作进行中，请等待完成")

        await runner.complete(
            .scan,
            codexHome: source.codexHome,
            with: providerSnapshot(status: "扫描完成", provider: "openai")
        )
        await waitUntil("scan completes after rejected destructive operation") {
            store.snapshot.status == "扫描完成"
        }
    }

    func testCancelledOlderOperationFailureCannotOverwriteNewerStatus() async throws {
        let source = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderSyncCancelledHome"),
            origin: .userSelected
        )
        let runner = SuspendedProviderSyncRunner()
        let store = ProviderSyncStore(runner: runner)

        store.scan(dataSource: source)
        await waitUntil("scan request pending") {
            await runner.hasPending(.scan, codexHome: source.codexHome)
        }

        store.verify(dataSource: source)
        await waitUntil("verify request pending") {
            await runner.hasPending(.verify, codexHome: source.codexHome)
        }

        await runner.complete(
            .verify,
            codexHome: source.codexHome,
            with: providerSnapshot(status: "验证完成", provider: "new")
        )
        await waitUntil("verify status published") {
            store.snapshot.status == "验证完成"
        }

        await runner.fail(.scan, codexHome: source.codexHome, error: ProviderSyncTestError())
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.snapshot.status, "验证完成")
        XCTAssertEqual(store.snapshot.detectedProvider, "new")
    }

    func testRunningCodexOnlyDisablesProviderMutationsInUIModel() async throws {
        let source = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderSyncRunningHome"),
            origin: .userSelected
        )
        let runner = SuspendedProviderSyncRunner()
        let store = ProviderSyncStore(runner: runner)

        store.scan(dataSource: source)
        await waitUntil("scan request pending") {
            await runner.hasPending(.scan, codexHome: source.codexHome)
        }
        await runner.complete(
            .scan,
            codexHome: source.codexHome,
            with: providerSnapshot(status: "扫描完成，建议退出 Codex 后执行同步", provider: "openai", codexRunning: true)
        )
        await waitUntil("running state published") {
            store.snapshot.codexRunning && !store.snapshot.isWorking
        }

        XCTAssertTrue(store.canScanOrVerify)
        XCTAssertTrue(store.canCreateBackup)
        XCTAssertFalse(store.canSync)
        XCTAssertFalse(store.canRollback)

        store.dryRunOnly = true
        XCTAssertTrue(store.canSync)
    }

    func testBackendRunningRejectionOverridesStaleSnapshotAndDisablesMutations() async throws {
        let source = CodexDataSource(
            codexHome: try makeTemporaryDirectory(named: "ProviderSyncStaleRunningHome"),
            origin: .userSelected
        )
        let runner = SuspendedProviderSyncRunner()
        let store = ProviderSyncStore(runner: runner)

        XCTAssertFalse(store.snapshot.codexRunning)
        XCTAssertTrue(store.canSync)
        XCTAssertTrue(store.canRollback)

        store.sync(dataSource: source)
        await waitUntil("sync request pending") {
            await runner.hasPending(.sync, codexHome: source.codexHome)
        }
        let backend = ProviderSyncEngine(
            backupRoot: try makeTemporaryDirectory(named: "ProviderSyncStaleRunningBackups"),
            applicationRunningProbe: { true }
        )
        let backendRunningError: Error
        do {
            _ = try backend.sync(
                codexHome: source.codexHome,
                includeArchivedSessions: false,
                targetProviderOverride: "openai",
                dryRunOnly: false
            )
            return XCTFail("后端未拒绝 Codex 运行时的同步")
        } catch {
            backendRunningError = error
        }
        await runner.fail(
            .sync,
            codexHome: source.codexHome,
            error: backendRunningError
        )
        await waitUntil("backend running rejection published") {
            store.snapshot.codexRunning && !store.snapshot.isWorking
        }

        XCTAssertTrue(store.snapshot.status.contains("Codex 正在运行"))
        XCTAssertFalse(store.canSync)
        XCTAssertFalse(store.canRollback)
        XCTAssertTrue(store.canScanOrVerify)
        XCTAssertTrue(store.canCreateBackup)
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func providerSnapshot(
        status: String,
        provider: String,
        codexRunning: Bool = false
    ) -> ProviderSyncSnapshot {
        ProviderSyncSnapshot(
            codexHome: "~/.codex",
            detectedProvider: provider,
            providerSource: "测试",
            codexRunning: codexRunning,
            status: status,
            isWorking: false
        )
    }
}

private enum ProviderSyncTestOperation: Hashable {
    case scan
    case backup
    case sync
    case verify
    case rollback
}

private actor SuspendedProviderSyncRunner: ProviderSyncRunning {
    private var continuations: [RequestKey: CheckedContinuation<ProviderSyncSnapshot, Error>] = [:]

    func scan(codexHome: URL, includeArchivedSessions: Bool) async throws -> ProviderSyncSnapshot {
        try await suspend(.scan, codexHome: codexHome)
    }

    func verify(codexHome: URL, includeArchivedSessions: Bool, targetProviderOverride: String?) async throws -> ProviderSyncSnapshot {
        try await suspend(.verify, codexHome: codexHome)
    }

    func sync(
        codexHome: URL,
        includeArchivedSessions: Bool,
        targetProviderOverride: String?,
        dryRunOnly: Bool
    ) async throws -> ProviderSyncSnapshot {
        try await suspend(dryRunOnly ? .backup : .sync, codexHome: codexHome)
    }

    func rollbackLatest(codexHome: URL) async throws -> ProviderSyncSnapshot {
        try await suspend(.rollback, codexHome: codexHome)
    }

    func rollback(codexHome: URL, backupPath: String) async throws -> ProviderSyncSnapshot {
        try await suspend(.rollback, codexHome: codexHome)
    }

    func hasPending(_ operation: ProviderSyncTestOperation, codexHome: URL) -> Bool {
        continuations[RequestKey(operation: operation, codexHome: codexHome)] != nil
    }

    func complete(_ operation: ProviderSyncTestOperation, codexHome: URL, with snapshot: ProviderSyncSnapshot) {
        continuations.removeValue(forKey: RequestKey(operation: operation, codexHome: codexHome))?
            .resume(returning: snapshot)
    }

    func fail(_ operation: ProviderSyncTestOperation, codexHome: URL, error: Error) {
        continuations.removeValue(forKey: RequestKey(operation: operation, codexHome: codexHome))?
            .resume(throwing: error)
    }

    private func suspend(_ operation: ProviderSyncTestOperation, codexHome: URL) async throws -> ProviderSyncSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            continuations[RequestKey(operation: operation, codexHome: codexHome)] = continuation
        }
    }

    private struct RequestKey: Hashable {
        let operation: ProviderSyncTestOperation
        let codexHome: URL
    }
}

private struct ProviderSyncTestError: LocalizedError {
    var errorDescription: String? {
        "旧操作失败"
    }
}
