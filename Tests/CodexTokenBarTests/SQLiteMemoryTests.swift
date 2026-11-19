import Foundation
import XCTest

final class SQLiteMemoryTests: XCTestCase {
    func testFreshExecutableInstallsAllocatorAndReclaimsConcurrentSchemas() throws {
        let testBundle = Bundle(for: Self.self).bundleURL
        let directory = testBundle.pathExtension == "xctest"
            ? testBundle.deletingLastPathComponent()
            : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let executable = directory.appendingPathComponent("CodexTokenBar")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--verify-sqlite-memory"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("PASS SQLite isolated memory"), text)
    }
}
