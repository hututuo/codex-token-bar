import AppKit
import XCTest
@testable import CodexTokenBar

final class BarIdleWorkTests: XCTestCase {
    func testRegisteredExecutableSkipsApplicationDirectoryDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Registered.app", isDirectory: true)
        let binary = app.appendingPathComponent("Contents/Resources/codex", isDirectory: false)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let files = DirectoryScanCountingFileManager()
        let found = try CodexBinaryLocator.findExecutable(environment: [:],
            registeredApplications: [.init(url: app, bundleIdentifier: CodexApplicationLocator.bundleIdentifier)],
            applicationRoots: [root], knownApplicationURLs: [], knownCLIPaths: [], fileManager: files)
        XCTAssertEqual(found, binary.resolvingSymlinksInPath().path)
        XCTAssertEqual(files.directoryScans, 0)
    }

    func testRolloutPathNormalizationPreservesBlankRelativeAndAbsolutePaths() {
        for path in ["", " \n ", " ./sessions/a.jsonl ", "/tmp/parent/../rollout.jsonl", "/tmp/unavailable.jsonl"] {
            let option = LiveThreadOption(id: "test", title: "test", updatedAtMS: 0, rolloutPath: path)
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed).standardizedFileURL.path
            XCTAssertEqual(option.normalizedRolloutPath, expected)
            XCTAssertEqual(option.hasRolloutPath, expected != nil)
        }
    }

    @MainActor
    func testUnchangedCanvasLayoutDoesNotResizeHostingViewsAgain() {
        let content = FrameAssignmentCountingView()
        let signal = FrameAssignmentCountingView()
        let canvas = QuotaSidebarCanvasView(host: content, edge: .right, signal: signal)
        canvas.setFrameSize(NSSize(width: 16, height: 192))
        let contentWrites = content.frameWrites
        let signalWrites = signal.frameWrites
        for _ in 0..<20 {
            canvas.edge = .right
            canvas.layout()
        }
        XCTAssertEqual(content.frameWrites, contentWrites)
        XCTAssertEqual(signal.frameWrites, signalWrites)
        canvas.setFrameSize(NSSize(width: 88, height: 470))
        XCTAssertGreaterThan(content.frameWrites, contentWrites)
        XCTAssertGreaterThan(signal.frameWrites, signalWrites)
    }
}

private final class DirectoryScanCountingFileManager: FileManager, @unchecked Sendable {
    var directoryScans = 0
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        directoryScans += 1
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

@MainActor
private final class FrameAssignmentCountingView: NSView {
    var frameWrites = 0
    override var frame: NSRect {
        didSet { frameWrites += 1 }
    }
}
