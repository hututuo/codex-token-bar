import Foundation

/// Parses `nettop -P -L 0 -x -J bytes_in,bytes_out` output (METRICS 10.3): every sample starts with a header line
/// beginning with `,`; each following line is `<name>.<pid>,<bytes_in>,<bytes_out>,`. Columns are located by header
/// name; the pid is the digits after the last `.` of the first field (names may contain `.`, spaces and even `,`); a
/// line that does not parse is skipped.
struct NettopParser {
    struct Row: Equatable, Sendable {
        var pid: Int32
        var rx: Int64
        var tx: Int64
    }

    enum Sample: Equatable, Sendable {
        case rows([Row])
        /// The header lacks the columns, or no line of the sample parsed.
        case unparseable
    }

    private struct Columns {
        var rx: Int
        var tx: Int
        var count: Int
    }

    private var line: [UInt8] = []
    private var columns: Columns?
    private var rows: [Row] = []
    private var lines = 0
    private var inSample = false

    /// Feeds output bytes; returns the samples a new header completed.
    mutating func feed(_ bytes: UnsafeRawBufferPointer) -> [Sample] {
        var completed: [Sample] = []
        for byte in bytes {
            if byte == 0x0A {
                if let sample = handle(line) { completed.append(sample) }
                line.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                line.append(byte)
            }
        }
        return completed
    }

    /// Completes the sample being read (the output went quiet); nil when none is open. An unterminated line stays
    /// buffered: a truncated number must never be read as a counter.
    mutating func finish() -> Sample? {
        close()
    }

    private mutating func close() -> Sample? {
        guard inSample else { return nil }
        inSample = false
        defer {
            rows.removeAll(keepingCapacity: true)
            lines = 0
        }
        guard columns != nil, rows.count > 0 || lines == 0 else { return .unparseable }
        return .rows(rows)
    }

    private mutating func handle(_ line: [UInt8]) -> Sample? {
        guard !line.isEmpty else { return nil }
        if line[0] == UInt8(ascii: ",") {
            let previous = close()
            columns = Self.columns(of: line)
            inSample = true
            return previous
        }
        guard inSample else { return nil }
        lines += 1
        if let columns, let row = Self.row(line, columns) { rows.append(row) }
        return nil
    }

    private static func fields(_ line: [UInt8]) -> [ArraySlice<UInt8>] {
        line.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
    }

    private static func columns(of header: [UInt8]) -> Columns? {
        let names = fields(header).map { String(decoding: $0, as: UTF8.self) }
        guard let rx = names.firstIndex(of: "bytes_in"), let tx = names.firstIndex(of: "bytes_out") else { return nil }
        return Columns(rx: rx, tx: tx, count: names.count)
    }

    private static func row(_ line: [UInt8], _ columns: Columns) -> Row? {
        let fields = fields(line)
        // Commas inside the name shift every column right by the same amount.
        let extra = fields.count - columns.count
        guard extra >= 0, columns.rx > 0, columns.tx > 0 else { return nil }
        let name = line[line.startIndex..<fields[extra].endIndex]
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), let pid = integer(name[(dot + 1)...]),
              pid > 0, pid <= Int64(Int32.max),
              let rx = integer(fields[columns.rx + extra]), let tx = integer(fields[columns.tx + extra]) else { return nil }
        return Row(pid: Int32(pid), rx: rx, tx: tx)
    }

    private static func integer(_ digits: ArraySlice<UInt8>) -> Int64? {
        guard !digits.isEmpty, digits.count <= 18 else { return nil }
        var value: Int64 = 0
        for byte in digits {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int64(byte - 0x30)
        }
        return value
    }
}
