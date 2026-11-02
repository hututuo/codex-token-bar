import Foundation
import XCTest
@testable import CodexTokenBar

final class RecoveryDiagnosticsTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func ownedFile(_ directory: URL, bytes: Int = 0, modified: Date = Date()) throws -> URL {
        let id = UUID().uuidString.lowercased(), path = directory.appendingPathComponent("session-\(id).jsonl")
        let header = Data("{\"format\":\"tokenbar-recovery-diagnostic-v1\",\"attempt\":\"\(id)\"}\n".utf8)
        try (header + Data(repeating: 32, count: bytes)).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        return path
    }
    func testBufferedRecordsFlushAtCloseAndContainOnlyStructuredDiagnostics() throws {
        let folder = try root().appendingPathComponent("diagnostics/v1")
        let log = try XCTUnwrap(RecoveryDiagnostics(root: folder))
        log.record(.importing, completed: 2, total: 10)
        log.record(.failure, code: 13)
        log.close(); log.close()
        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("tokenbar-recovery-diagnostic-v1"))
        XCTAssertTrue(lines[1].contains("importing"))
        XCTAssertTrue(lines[2].contains("failure"))
        XCTAssertFalse(lines.joined().contains(NSHomeDirectory()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("latest-failure.json").path))
    }
    func testRotationOnlyDeletesOwnedLogsAndPreservesLastFailureAndUnknownFiles() throws {
        let base = try root(), folder = base.appendingPathComponent("logs/v1")
        let log = try XCTUnwrap(RecoveryDiagnostics(root: folder)); log.record(.failure, code: 5); log.close()
        let expired = try ownedFile(folder, modified: Date().addingTimeInterval(-31 * 86400))
        let recent = try ownedFile(folder)
        let unknown = folder.appendingPathComponent("session-\(UUID().uuidString.lowercased()).jsonl")
        let unknownBytes = Data("user-export\n".utf8); try unknownBytes.write(to: unknown)
        let outside = base.appendingPathComponent("original.sqlite"); try unknownBytes.write(to: outside)
        let link = folder.appendingPathComponent("session-\(UUID().uuidString.lowercased()).jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try RecoveryDiagnostics.prune(root: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(try Data(contentsOf: unknown), unknownBytes)
        XCTAssertEqual(try Data(contentsOf: outside), unknownBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("latest-failure.json").path))
    }
    func testByteBudgetAndPerSessionBoundsDoNotRequirePerRecordWrites() throws {
        let folder = try root().appendingPathComponent("logs/v1")
        let log = try XCTUnwrap(RecoveryDiagnostics(root: folder))
        for n in 0..<10_000 { log.record(.importing, completed: n, total: 10_000) }
        log.record(.failure, code: 13)
        log.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("latest-failure.json").path))
        XCTAssertLessThanOrEqual(try Data(contentsOf: log.fileURL).count, 256 * 1024)
        _ = try ownedFile(folder, bytes: 200 * 1024, modified: Date().addingTimeInterval(-5))
        let newest = try ownedFile(folder, bytes: 200 * 1024)
        try RecoveryDiagnostics.prune(root: folder, byteLimit: 512 * 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        let total = try files.reduce(0) { try $0 + Data(contentsOf: $1).count }
        XCTAssertLessThanOrEqual(total, 256 * 1024)
    }
    func testUnknownDirectoryOrMarkerAndSymlinksAreNeverAdopted() throws {
        let base = try root(), unknown = base.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let owned = unknown.appendingPathComponent("owner.marker"); try Data("unknown owner".utf8).write(to: owned)
        XCTAssertNil(RecoveryDiagnostics(root: unknown))
        XCTAssertEqual(try Data(contentsOf: owned), Data("unknown owner".utf8))
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unknown)
        XCTAssertNil(RecoveryDiagnostics(root: link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), unknown.path)
    }
}
