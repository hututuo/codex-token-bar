import Foundation

/// Today's measured output per source in one-second buckets (METRICS 6.6) and the measured peak of any source set
/// (METRICS 6.8). A source gets its buckets only once it has measured data today.
///
/// Each requested set keeps the peak trailing average per block of `blockSeconds`; a change marks the blocks it
/// touched in the sets that contain its source, so a set is recomputed only after one of its sources changed, and
/// then only those blocks.
struct SourceSeconds: Sendable {
    static let blockSeconds = 256
    /// Sets beyond this are dropped oldest first; at most eight orbs ask at a time.
    static let maxCachedSets = 32

    private struct SetPeak: Sendable {
        var blockPeaks: [Double] = []
        /// One bit per block whose trailing averages are out of date.
        var dirtyBlocks: [UInt64] = []
        var isDirty = false
        var peak = 0.0

        mutating func invalidate(_ blocks: ClosedRange<Int>, blockCount: Int) {
            if dirtyBlocks.isEmpty {
                blockPeaks = Array(repeating: 0, count: blockCount)
                dirtyBlocks = Array(repeating: 0, count: (blockCount + 63) / 64)
            }
            for block in blocks { dirtyBlocks[block >> 6] |= 1 << UInt64(block & 63) }
            isDirty = true
        }
    }

    private let firstSecond: Int64
    private let capacity: Int
    private let blockCount: Int
    private var buckets: [[Float]]
    /// Indices that ever held data, per source.
    private var dataRanges: [ClosedRange<Int>?]
    private var cachedSets: [SourceSet] = []
    private var cachedPeaks: [SetPeak] = []
    /// Peak computations that were not answered from the cache, and the blocks they scanned (tests).
    private(set) var peakScans = 0
    private(set) var scannedBlocks = 0

    init(firstSecond: Int64, capacity: Int) {
        self.firstSecond = firstSecond
        self.capacity = capacity
        blockCount = (capacity + Self.blockSeconds - 1) / Self.blockSeconds
        let count = SourceKind.allCases.count
        buckets = Array(repeating: [], count: count)
        dataRanges = Array(repeating: nil, count: count)
    }

    /// Sources whose buckets are allocated.
    var allocated: SourceSet {
        SourceSet(SourceKind.allCases.filter { !buckets[$0.ordinal].isEmpty })
    }

    /// Adds (`sign` 1) or removes (`sign` -1) a measured response of `source`, like the all-sources buckets.
    mutating func apply(_ timed: TimedResponse, source: SourceKind, sign: Int) {
        let base = firstSecond
        let lastSecond = base + Int64(capacity) - 1
        guard ResponseTiming.overlap(base * 1000, (lastSecond + 1) * 1000, timed.startMs, timed.endMs) > 0 else { return }
        let slot = source.ordinal
        if buckets[slot].isEmpty {
            guard sign > 0 else { return }
            buckets[slot] = Array(repeating: 0, count: capacity)
        }
        let from = Int(max(base, ResponseTiming.second(of: timed.startMs)) - base)
        let to = Int(min(lastSecond, ResponseTiming.second(of: timed.endMs)) - base)
        if sign > 0 {
            dataRanges[slot] = dataRanges[slot].map { min($0.lowerBound, from)...max($0.upperBound, to) } ?? from...to
        }
        let factor = Double(sign)
        buckets[slot].withUnsafeMutableBufferPointer { seconds in
            timed.distribute(firstSecond: base, lastSecond: lastSecond) { second, output, _ in
                let index = Int(second - base)
                seconds[index] = Float(max(0, Double(seconds[index]) + factor * output))
            }
        }
        let blocks = blocks(touching: from...to)
        for position in cachedSets.indices where cachedSets[position].contains(source) {
            cachedPeaks[position].invalidate(blocks, blockCount: blockCount)
        }
    }

    /// Maximum 3-bucket trailing average of the per-second sum over `set`.
    mutating func measuredPeak(for set: SourceSet) -> Double {
        let position = cachedSets.firstIndex(of: set) ?? cache(set)
        guard cachedPeaks[position].isDirty else { return cachedPeaks[position].peak }
        peakScans += 1
        let members = membersWithData(of: set)
        for word in cachedPeaks[position].dirtyBlocks.indices {
            var bits = cachedPeaks[position].dirtyBlocks[word]
            while bits != 0 {
                let block = word << 6 + bits.trailingZeroBitCount
                bits &= bits - 1
                let peak = blockPeak(block, members: members)
                cachedPeaks[position].blockPeaks[block] = peak
                scannedBlocks += 1
            }
            cachedPeaks[position].dirtyBlocks[word] = 0
        }
        cachedPeaks[position].peak = cachedPeaks[position].blockPeaks.max() ?? 0
        cachedPeaks[position].isDirty = false
        return cachedPeaks[position].peak
    }

    private mutating func cache(_ set: SourceSet) -> Int {
        if cachedSets.count >= Self.maxCachedSets {
            cachedSets.removeFirst()
            cachedPeaks.removeFirst()
        }
        var entry = SetPeak()
        var range: ClosedRange<Int>?
        for kind in set.kinds {
            guard let data = dataRanges[kind.ordinal] else { continue }
            range = range.map { min($0.lowerBound, data.lowerBound)...max($0.upperBound, data.upperBound) } ?? data
        }
        if let range { entry.invalidate(blocks(touching: range), blockCount: blockCount) }
        cachedSets.append(set)
        cachedPeaks.append(entry)
        return cachedSets.count - 1
    }

    /// Blocks whose trailing windows include any of `seconds`.
    private func blocks(touching seconds: ClosedRange<Int>) -> ClosedRange<Int> {
        (seconds.lowerBound / Self.blockSeconds)...(min(seconds.upperBound + 2, capacity - 1) / Self.blockSeconds)
    }

    private func membersWithData(of set: SourceSet) -> UInt32 {
        var members: UInt32 = 0
        for slot in buckets.indices where set.rawValue & 1 << UInt32(slot) != 0 && !buckets[slot].isEmpty {
            members |= 1 << UInt32(slot)
        }
        return members
    }

    /// Peak of the trailing averages that end in `block`.
    private func blockPeak(_ block: Int, members: UInt32) -> Double {
        let first = block * Self.blockSeconds
        let last = min(first + Self.blockSeconds, capacity) - 1
        var previous = (sum(at: first - 2, members), sum(at: first - 1, members))
        var peak = 0.0
        for index in first...last {
            let value = sum(at: index, members)
            peak = max(peak, (previous.0 + previous.1 + value) / 3)
            previous = (previous.1, value)
        }
        return peak
    }

    @inline(__always)
    private func sum(at index: Int, _ members: UInt32) -> Double {
        guard index >= 0 else { return 0 }
        var value = 0.0
        var bits = members
        while bits != 0 {
            let slot = bits.trailingZeroBitCount
            bits &= bits - 1
            value += Double(buckets[slot][index])
        }
        return value
    }
}
