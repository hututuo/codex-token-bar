import Foundation

struct CommandFailure: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    var description: String { "\(command) exited with status \(status)" }
}

/// Runs a system tool with an argument array (never through a shell) and returns its standard output.
@discardableResult
func runTool(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CommandFailure(command: ([executable] + arguments).joined(separator: " "), status: process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self)
}

/// Deterministic, incompressible-looking bytes (xorshift64*).
func pseudoRandomData(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
    var state = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        bytes[index] = UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56)
    }
    return Data(bytes)
}

/// Writes stored (uncompressed) zip archives byte by byte, including entries no well-behaved tool would produce.
struct ZipBuilder {
    struct Entry {
        var name: [UInt8]
        var data: [UInt8]
        var mode: UInt32
        var madeBy: UInt16
        var flags: UInt16
    }

    /// Byte offsets of the records inside a built archive, for patching individual fields.
    struct Archive {
        var data: Data
        let directoryOffset: Int
        let endOffset: Int
    }

    static let unixMadeBy: UInt16 = 0x0314
    static let dosMadeBy: UInt16 = 0x0014

    private(set) var entries: [Entry] = []
    var comment: [UInt8] = []

    mutating func directory(_ name: String) {
        add(name, data: [], mode: 0o040755)
    }

    mutating func file(_ name: String, _ text: String = "payload\n") {
        add(name, data: Array(text.utf8), mode: 0o100644)
    }

    mutating func symlink(_ name: String, to target: String) {
        add(name, data: Array(target.utf8), mode: 0o120755)
    }

    mutating func add(_ name: String, data: [UInt8], mode: UInt32, madeBy: UInt16 = unixMadeBy) {
        let bytes = Array(name.utf8)
        let flags: UInt16 = bytes.allSatisfy { $0 < 0x80 } ? 0 : 0x0800
        add(raw: bytes, data: data, mode: mode, madeBy: madeBy, flags: flags)
    }

    mutating func add(raw name: [UInt8], data: [UInt8], mode: UInt32, madeBy: UInt16 = unixMadeBy, flags: UInt16 = 0) {
        entries.append(Entry(name: name, data: data, mode: mode, madeBy: madeBy, flags: flags))
    }

    func build() -> Archive {
        var archive: [UInt8] = []
        var directory: [UInt8] = []
        for entry in entries {
            let localOffset = UInt32(archive.count)
            let crc = Self.crc32(entry.data)
            let size = UInt32(entry.data.count)
            archive.append32(0x0403_4B50)
            archive.append16(20)
            archive.append16(entry.flags)
            archive.append16(0)
            archive.append16(0)
            archive.append16(0x21)
            archive.append32(crc)
            archive.append32(size)
            archive.append32(size)
            archive.append16(UInt16(entry.name.count))
            archive.append16(0)
            archive.append(contentsOf: entry.name)
            archive.append(contentsOf: entry.data)

            directory.append32(0x0201_4B50)
            directory.append16(entry.madeBy)
            directory.append16(20)
            directory.append16(entry.flags)
            directory.append16(0)
            directory.append16(0)
            directory.append16(0x21)
            directory.append32(crc)
            directory.append32(size)
            directory.append32(size)
            directory.append16(UInt16(entry.name.count))
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append32(entry.mode << 16 | (entry.mode & 0o170000 == 0o040000 ? 0x10 : 0))
            directory.append32(localOffset)
            directory.append(contentsOf: entry.name)
        }
        let directoryOffset = archive.count
        archive.append(contentsOf: directory)
        let endOffset = archive.count
        archive.append32(0x0605_4B50)
        archive.append16(0)
        archive.append16(0)
        archive.append16(UInt16(entries.count))
        archive.append16(UInt16(entries.count))
        archive.append32(UInt32(directory.count))
        archive.append32(UInt32(directoryOffset))
        archive.append16(UInt16(comment.count))
        archive.append(contentsOf: comment)
        return Archive(data: Data(archive), directoryOffset: directoryOffset, endOffset: endOffset)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

extension ZipBuilder.Archive {
    /// End of central directory fields.
    enum EndField: Int {
        case disk = 4, directoryDisk = 6, entriesOnDisk = 8, entries = 10, directorySize = 12, directoryOffset = 16
    }

    /// Fields of the first central directory header.
    enum EntryField: Int {
        case signature = 0, uncompressedSize = 24, nameLength = 28, diskStart = 34, localOffset = 42
    }

    mutating func patch(_ field: EndField, _ value: UInt32) {
        write(value, at: endOffset + field.rawValue, width: field.rawValue >= 12 ? 4 : 2)
    }

    mutating func patch(_ field: EntryField, _ value: UInt32) {
        let width = field == .nameLength || field == .diskStart ? 2 : 4
        write(value, at: directoryOffset + field.rawValue, width: width)
    }

    private mutating func write(_ value: UInt32, at offset: Int, width: Int) {
        for index in 0..<width {
            data[data.startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index)))
        }
    }
}

extension [UInt8] {
    fileprivate mutating func append16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    fileprivate mutating func append32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
}
