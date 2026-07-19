import Darwin
import XCTest
@testable import CodexTokenBar

final class RefreshPerformanceProbeTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        unsetenv("CODEX_TOKEN_BAR_REFRESH_PROBE")
        unsetenv("CODEX_TOKEN_BAR_REFRESH_PROBE_LOG")
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testProbeDoesNotWriteWhenDisabled() throws {
        let logURL = try makeLogURL()
        unsetenv("CODEX_TOKEN_BAR_REFRESH_PROBE")
        setenv("CODEX_TOKEN_BAR_REFRESH_PROBE_LOG", logURL.path, 1)

        let trace = RefreshPerformanceProbe.begin("test.disabled")
        RefreshPerformanceProbe.event("test.disabled.event")

        XCTAssertNil(trace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testProbeWritesTraceWhenEnabled() throws {
        let logURL = try makeLogURL()
        setenv("CODEX_TOKEN_BAR_REFRESH_PROBE", "1", 1)
        setenv("CODEX_TOKEN_BAR_REFRESH_PROBE_LOG", logURL.path, 1)

        let trace = try XCTUnwrap(RefreshPerformanceProbe.begin("test.enabled", metadata: ["phase": "begin"]))
        trace.mark("middle", metadata: ["phase": "mark"])
        trace.end("ok", metadata: ["phase": "end"])

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("event=begin"))
        XCTAssertTrue(log.contains("event=mark:middle"))
        XCTAssertTrue(log.contains("event=end"))
        XCTAssertTrue(log.contains("name=test.enabled"))
        XCTAssertTrue(log.contains("status=ok"))
    }

    func testProbeRotatesBoundedLogBeforeAppending() throws {
        let logURL = try makeLogURL()
        setenv("CODEX_TOKEN_BAR_REFRESH_PROBE", "1", 1)
        setenv("CODEX_TOKEN_BAR_REFRESH_PROBE_LOG", logURL.path, 1)
        try Data(repeating: 0x78, count: 5 * 1024 * 1024).write(to: logURL)

        RefreshPerformanceProbe.event("test.rotate")

        let previousURL = logURL.appendingPathExtension("previous")
        XCTAssertEqual(try Data(contentsOf: previousURL).count, 5 * 1024 * 1024)
        let current = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(current.contains("event=test.rotate"))
        XCTAssertLessThan(current.utf8.count, 1_024)
    }

    private func makeLogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenBarProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("refresh-performance.log")
    }
}
