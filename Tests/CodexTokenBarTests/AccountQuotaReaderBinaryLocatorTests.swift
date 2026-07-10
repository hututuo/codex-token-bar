import Foundation
import XCTest
@testable import CodexTokenBar

final class AccountQuotaReaderBinaryLocatorTests: XCTestCase {
    func testCandidatePathsIncludeChatGPTAppBeforeLegacyCodexApp() {
        let home = "/Users/tester"

        let candidates = CodexBinaryLocator.candidatePaths(homeDirectory: home)

        XCTAssertEqual(candidates[0], "/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertEqual(candidates[1], "\(home)/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertTrue(candidates.contains("/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertTrue(candidates.contains("\(home)/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/codex"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/codex"))
    }

    func testFindExecutableUsesFirstExecutableCandidate() throws {
        let root = try makeTemporaryDirectory(named: "CodexBinaryLocator")
        let missing = root.appendingPathComponent("missing-codex").path
        let nonExecutable = root.appendingPathComponent("non-executable-codex").path
        let chatGPTCodex = root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex").path
        let legacyCodex = root.appendingPathComponent("Codex.app/Contents/Resources/codex").path

        try writeExecutableStub(at: nonExecutable, executable: false)
        try writeExecutableStub(at: chatGPTCodex, executable: true)
        try writeExecutableStub(at: legacyCodex, executable: true)

        let found = try CodexBinaryLocator.findExecutable(in: [
            missing,
            nonExecutable,
            chatGPTCodex,
            legacyCodex
        ])

        XCTAssertEqual(found, chatGPTCodex)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutableStub(at path: String, executable: Bool) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: path
        )
    }
}
