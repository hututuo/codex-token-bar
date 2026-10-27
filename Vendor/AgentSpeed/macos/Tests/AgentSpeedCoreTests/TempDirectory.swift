import Foundation

/// A scratch directory removed when the value is released.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-speed-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path }

    func file(_ relative: String) -> URL {
        url.appendingPathComponent(relative)
    }

    @discardableResult
    func write(_ relative: String, _ text: String, modified: Date? = nil) throws -> URL {
        let target = file(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target
    }

    func append(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: file(relative))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
