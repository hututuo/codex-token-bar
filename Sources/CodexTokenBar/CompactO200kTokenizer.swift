import Foundation
import CryptoKit

/// Encoding-only o200k vocabulary. The app counts ordinary text; it does not
/// need a reverse dictionary, special-token decoder or per-thread regex copies.
/// Entries share one byte buffer and one fixed open-addressed rank table.
final class CompactO200kTokenizer: @unchecked Sendable {
    static let pattern = #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    private struct Entry {
        var hash: UInt32 = 0
        var offset: UInt32 = 0
        var length: UInt32 = 0
        var rank: UInt32 = 0
    }
    private let bytes: [UInt8]
    private let entries: [Entry]
    private let expression: NSRegularExpression
    private let mask: Int
    private let mapped: MappedTokenizerVocabulary?
    var retainedVocabularyBytes: Int { bytes.count + entries.count * MemoryLayout<Entry>.stride }
    var mappedVocabularyBytes: Int { mapped?.byteCount ?? 0 }

    init(mappedVocabularyURL: URL) throws {
        mapped = try MappedTokenizerVocabulary(url: mappedVocabularyURL)
        bytes = []
        entries = []
        mask = 0
        expression = try NSRegularExpression(pattern: Self.pattern)
    }

    init(vocabulary: Data) throws {
        guard SHA256.hash(data: vocabulary).map({ String(format: "%02x", $0) }).joined()
                == "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d",
              let text = String(data: vocabulary, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var storage: [UInt8] = []
        storage.reserveCapacity(2_000_000)
        var table = [Entry](repeating: Entry(), count: 1 << 19)
        let mask = table.count - 1
        var count = 0
        for line in text.split(separator: "\n") {
            try autoreleasepool {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let token = Data(base64Encoded: String(parts[0])),
                      !token.isEmpty, let rank = UInt32(parts[1]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let hash = Self.hash(token)
                var index = Int(hash) & mask
                while table[index].length != 0 { index = (index + 1) & mask }
                table[index] = Entry(hash: hash, offset: UInt32(storage.count),
                                     length: UInt32(token.count), rank: rank)
                storage.append(contentsOf: token)
                count += 1
            }
        }
        guard count == 199_998 else { throw CocoaError(.fileReadCorruptFile) }
        bytes = storage
        entries = table
        self.mask = mask
        mapped = nil
        expression = try NSRegularExpression(pattern: Self.pattern)
    }

    private static func hash<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var value: UInt32 = 2_166_136_261
        for byte in bytes { value = (value ^ UInt32(byte)) &* 16_777_619 }
        return value
    }

    private func rank(_ piece: [UInt8], _ start: Int, _ end: Int) -> UInt32? {
        if let mapped { return mapped.rank(piece, start, end) }
        let length = end - start
        let hash = Self.hash(piece[start..<end])
        var index = Int(hash) & mask
        while true {
            let entry = entries[index]
            if entry.length == 0 { return nil }
            if entry.hash == hash, Int(entry.length) == length {
                var matches = true
                let offset = Int(entry.offset)
                for i in 0..<length where bytes[offset + i] != piece[start + i] {
                    matches = false
                    break
                }
                if matches { return entry.rank }
            }
            index = (index + 1) & mask
        }
    }

    func encodeOrdinary(text: String) -> [UInt32] {
        let source = text as NSString
        var output: [UInt32] = []
        var covered = 0
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            autoreleasepool {
                // Preserve any unmatched bytes rather than omitting input if
                // a future Unicode version classifies a scalar differently.
                if match.range.location > covered {
                    self.appendPiece(Array(source.substring(with: NSRange(location: covered,
                        length: match.range.location - covered)).utf8), to: &output)
                }
                self.appendPiece(Array(source.substring(with: match.range).utf8), to: &output)
                covered = NSMaxRange(match.range)
            }
        }
        if covered < source.length {
            appendPiece(Array(source.substring(from: covered).utf8), to: &output)
        }
        return output
    }

    private struct Merge {
        let rank: UInt32
        let left: Int
        let right: Int
        let end: Int
        func precedes(_ other: Self) -> Bool {
            rank < other.rank || (rank == other.rank && left < other.left)
        }
    }
    private struct Heap {
        var items: [Merge] = []
        mutating func push(_ item: Merge) {
            items.append(item)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].precedes(items[parent]) else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }
        mutating func pop() -> Merge? {
            guard !items.isEmpty else { return nil }
            if items.count == 1 { return items.removeLast() }
            let first = items[0]
            items[0] = items.removeLast()
            var parent = 0
            while parent * 2 + 1 < items.count {
                var child = parent * 2 + 1
                if child + 1 < items.count, items[child + 1].precedes(items[child]) { child += 1 }
                guard items[child].precedes(items[parent]) else { break }
                items.swapAt(child, parent)
                parent = child
            }
            return first
        }
    }

    private func appendPiece(_ piece: [UInt8], to output: inout [UInt32]) {
        guard !piece.isEmpty else { return }
        if let exact = rank(piece, 0, piece.count) { output.append(exact); return }
        // Greedy BPE: smallest rank first, leftmost pair on ties. Node indices
        // remain byte offsets, so stale heap entries can be rejected cheaply.
        let count = piece.count
        var previous = (0..<count).map { $0 - 1 }
        var next = (0..<count).map { $0 + 1 }
        var alive = [Bool](repeating: true, count: count)
        var heap = Heap()
        for i in 0..<(count - 1) {
            if let value = rank(piece, i, i + 2) {
                heap.push(Merge(rank: value, left: i, right: i + 1, end: i + 2))
            }
        }
        while let merge = heap.pop() {
            let left = merge.left, right = merge.right
            guard alive[left], alive[right], next[left] == right, next[right] == merge.end else { continue }
            alive[right] = false
            next[left] = merge.end
            if merge.end < count { previous[merge.end] = left }
            if merge.end < count, let value = rank(piece, left, next[merge.end]) {
                heap.push(Merge(rank: value, left: left, right: merge.end, end: next[merge.end]))
            }
            let before = previous[left]
            if before >= 0, let value = rank(piece, before, merge.end) {
                heap.push(Merge(rank: value, left: before, right: left, end: merge.end))
            }
        }
        var start = 0
        while start < count {
            // Every individual byte is present in the verified vocabulary;
            // later spans exist only after a successful vocabulary lookup.
            output.append(rank(piece, start, next[start])!)
            start = next[start]
        }
    }
}
