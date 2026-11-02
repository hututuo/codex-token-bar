import Foundation
import XCTest
@testable import CodexTokenBar

final class BusinessMigrationDiagnosticsTests: XCTestCase {
    @MainActor
    func testPreviewWaitsForDurableWriterWithoutBlockingMainActorHeartbeat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let previewStarted = DispatchSemaphore(value: 0)
        let heartbeat = DispatchSemaphore(value: 0)
        defer {
            releaseWriter.signal()
            try? FileManager.default.removeItem(at: root)
        }
        let journal = BusinessMigrationDiagnostics(root: root, operation: "blocked-writer") { event in
            if event.stage == "delayed-durable-write" {
                writerEntered.signal()
                releaseWriter.wait()
            }
        }
        let writer = Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    journal.record("delayed-durable-write", "succeeded", ["proof": "retained"])
                    continuation.resume()
                }
            }
        }
        let entered = await waitOnBackgroundQueue(writerEntered, timeout: .now() + 5)
        XCTAssertTrue(entered, "The real writer must hold the same lock used by previews")
        guard entered else { releaseWriter.signal(); await writer.value; return }

        let refresh = Task { @MainActor in
            previewStarted.signal()
            return await BusinessMigrationDiagnostics.readPreview(at: root)
        }
        // The watchdog must not need the main actor to release the writer:
        // otherwise the regressed synchronous read would deadlock the test.
        let watchdog = Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard previewStarted.wait(timeout: .now() + 5) == .success else {
                        releaseWriter.signal()
                        continuation.resume(returning: false)
                        return
                    }
                    Task { @MainActor in heartbeat.signal() }
                    let responsive = heartbeat.wait(timeout: .now() + 2) == .success
                    releaseWriter.signal()
                    continuation.resume(returning: responsive)
                }
            }
        }
        let responsive = await watchdog.value
        let snapshot = await refresh.value
        await writer.value
        XCTAssertTrue(responsive, "A slow log write must not hold the migration UI's main actor")
        XCTAssertEqual(snapshot.attemptID, journal.attemptID)
        XCTAssertNil(snapshot.persistenceError)
        XCTAssertTrue(snapshot.text.contains("delayed-durable-write"))
        let persisted = try String(contentsOf: journal.url, encoding: .utf8)
        XCTAssertTrue(persisted.contains("delayed-durable-write"), "The delayed write still completes and fsyncs")
    }

    @MainActor
    func testPreviewSnapshotKeepsFailureAndTailBoundToOneAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BusinessMigrationDiagnostics(root: root, operation: "failure") { event in
            if event.stage == "write-failure" { throw NSError(domain: "test-writer", code: 42) }
        }
        first.record("write-failure", "failed", ["identity": "first-only"])
        let firstSnapshot = await BusinessMigrationDiagnostics.readPreview(at: root)
        XCTAssertEqual(firstSnapshot.attemptID, first.attemptID)
        XCTAssertNotNil(firstSnapshot.persistenceError)
        XCTAssertTrue(firstSnapshot.text.contains("first-only"))
        let second = BusinessMigrationDiagnostics(root: root, operation: "retry")
        second.record("new-attempt", "succeeded", ["identity": "second-only"])
        let secondSnapshot = await BusinessMigrationDiagnostics.readPreview(at: root)
        XCTAssertEqual(secondSnapshot.attemptID, second.attemptID)
        XCTAssertNil(secondSnapshot.persistenceError)
        XCTAssertTrue(secondSnapshot.text.contains("second-only"))
        XCTAssertFalse(secondSnapshot.text.contains("first-only"))
        XCTAssertEqual(firstSnapshot.attemptID, first.attemptID, "A returned snapshot does not follow latest")
        XCTAssertNotNil(firstSnapshot.persistenceError)
        XCTAssertFalse(firstSnapshot.text.contains("second-only"))
    }

    func testSeparateAttemptsKeepAllRecordsBeyondPreviewAndExportEscapesErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BusinessMigrationDiagnostics(root: root, operation: "first")
        for n in 0..<140 { first.record("verify", "succeeded", ["index": String(n)]) }
        first.finish()
        let second = BusinessMigrationDiagnostics(root: root, operation: "retry")
        second.record("probe", "failed", ["error": "line1\nline2\"\\quoted"])
        second.finish(NSError(domain: "test", code: 1))
        let paths = try BusinessMigrationDiagnostics.files(at: root)
        XCTAssertEqual(paths.count, 2)
        let firstLines = try String(contentsOf: first.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(firstLines.count, 142)
        XCTAssertEqual(first.memoryPreview.split(separator: "\n").count, 100)
        for line in firstLines { _ = try JSONDecoder().decode(BusinessMigrationDiagnostics.Event.self, from: Data(line.utf8)) }
        let secondLines = try String(contentsOf: second.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(secondLines.count, 3)
        let event = try JSONDecoder().decode(BusinessMigrationDiagnostics.Event.self, from: Data(secondLines[1].utf8))
        XCTAssertEqual(event.details["error"], "line1\nline2\"\\quoted")
        let target = root.appendingPathComponent("export.log")
        try BusinessMigrationDiagnostics.export(at: root, to: target)
        let exported = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(exported.contains(first.attemptID)); XCTAssertTrue(exported.contains(second.attemptID))
        XCTAssertTrue(exported.contains(String(firstLines[0]))); XCTAssertTrue(exported.contains(String(firstLines.last!)))
        let retained = try Data(contentsOf: target)
        XCTAssertThrowsError(try BusinessMigrationDiagnostics.export(at: root, to: target))
        XCTAssertEqual(try Data(contentsOf: target), retained)
        XCTAssertEqual(try BusinessMigrationDiagnostics.files(at: root).count, 2)
    }
    func testRuntimeBackfillIsSilentForRefreshAndRetainsEveryWorkerFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("ledger.sqlite")
        let directory = root.appendingPathComponent("migration-diagnostics")
        let ordinary = BusinessBackfillDiagnostics(database: database)
        ordinary.progress(0, 2, .scanning)
        XCTAssertEqual(try ordinary.source(database) { 42 }, 42)
        ordinary.finish(generation: 1, complete: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let backfill = BusinessBackfillDiagnostics(database: database)
        backfill.progress(0, 8, .backfillingModel)
        backfill.progress(0, 8, .backfillingModel) // coalesce duplicate progress only
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            do {
                try backfill.source(root.appendingPathComponent("source-\(worker).jsonl")) {
                    throw NSError(domain: "synthetic-worker", code: worker)
                }
            } catch { /* the public attempt also records its terminal failure */ }
        }
        backfill.fail(NSError(domain: "synthetic-backfill", code: 1))
        let paths = try BusinessMigrationDiagnostics.files(at: directory)
        XCTAssertEqual(paths.count, 1)
        let rows = try String(contentsOf: XCTUnwrap(paths.first), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(BusinessMigrationDiagnostics.Event.self, from: Data($0.utf8)) }
        XCTAssertEqual(rows.filter { $0.stage == "parse-source" && $0.status == "failed" }.count, 8)
        XCTAssertEqual(rows.filter { $0.stage == "backfill-progress" }.count, 1)
        XCTAssertEqual(rows.last?.stage, "attempt"); XCTAssertEqual(rows.last?.status, "failed")
        XCTAssertEqual(rows.map(\.sequence), Array(1...rows.count))
        XCTAssertEqual(Set(rows.map(\.attemptId)).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    func testWriteFailureKeepsMemoryPreviewAndNeverRemovesBlockingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = BusinessMigrationDiagnostics(root: root, operation: "blocked")
        journal.record("proof", "failed", ["error": "business failure"])
        XCTAssertNotNil(journal.persistenceError)
        XCTAssertTrue(journal.memoryPreview.contains("business failure"))
        XCTAssertEqual(try String(contentsOf: root, encoding: .utf8), "keep")
    }
    func testExportRefusesSymbolicLogWithoutReadingPrivateTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateFile = root.appendingPathComponent("private.txt")
        try Data("not a diagnostic".utf8).write(to: privateFile)
        let link = root.appendingPathComponent("attempt-\(UUID().uuidString).jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: privateFile)
        let target = root.appendingPathComponent("export.log")
        XCTAssertThrowsError(try BusinessMigrationDiagnostics.export(at: root, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "not a diagnostic")
    }
}

private func waitOnBackgroundQueue(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> Bool {
    // Deliberately blocking test synchronization belongs on a dispatch worker,
    // never on Swift's cooperative executor or the application's main actor.
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
        }
    }
}
