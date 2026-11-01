import Foundation
import XCTest
@testable import CodexTokenBar

final class BusinessMigrationDiagnosticsTests: XCTestCase {
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
