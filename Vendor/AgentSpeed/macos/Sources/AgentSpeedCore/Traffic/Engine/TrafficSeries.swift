import Foundation

/// Deltas of one counter series with their sample times, for the live rate (METRICS 10.7): the bytes of the samples in
/// `(t − 3000, t]` over `t − t₀`, `t₀` the latest sample time ≤ `t − 3000`. A gap restarts the series.
struct TrafficSeries {
    static let windowMs: Int64 = 3000

    private struct Point {
        var t: Int64
        var bytes: TrafficBytes
    }

    private var points: [Point] = []

    mutating func add(t: Int64, bytes: TrafficBytes, gap: Bool) {
        if gap {
            points.removeAll(keepingCapacity: true)
            points.append(Point(t: t, bytes: .zero))
            return
        }
        points.append(Point(t: t, bytes: bytes))
        var drop = 0
        while points.count - drop > 2, points[drop + 1].t <= t - Self.windowMs { drop += 1 }
        if drop > 0 { points.removeFirst(drop) }
    }

    /// Nil before two samples exist.
    var rate: TrafficRate? {
        guard points.count >= 2, let last = points.last else { return nil }
        var start = 0
        for (index, point) in points.enumerated() where point.t <= last.t - Self.windowMs { start = index }
        let seconds = Double(last.t - points[start].t) / 1000
        guard seconds > 0 else { return nil }
        var sum = TrafficBytes.zero
        for point in points[(start + 1)...] { sum += point.bytes }
        return TrafficRate(rx: Double(sum.rx) / seconds, tx: Double(sum.tx) / seconds)
    }
}

/// The own and own + tools series of a source or agent tree (`includeTools`, DESIGN 10).
struct TrafficSeriesPair {
    private var own = TrafficSeries()
    private var all = TrafficSeries()

    mutating func add(t: Int64, split: TrafficSplit, gap: Bool) {
        own.add(t: t, bytes: split.own, gap: gap)
        all.add(t: t, bytes: split.own + split.tools, gap: gap)
    }

    var withTools: TrafficRate? { all.rate }
    var ownOnly: TrafficRate? { own.rate }
}

/// One-second buckets of the last 300 s (METRICS 10.7 history buffer). A sample's rate (bytes ÷ interval seconds)
/// fills the buckets of the wall-clock seconds its interval ends in or covers, so a 5-second sample fills five
/// buckets and a 1-second sample one; gap samples are not added.
struct TrafficBuckets {
    static let seconds = 300

    private var rates: [TrafficRate]
    /// The wall-clock second of `rates[cursor]`.
    private var newestSecond: Int64?
    private var cursor = 0

    init() {
        rates = Array(repeating: .zero, count: Self.seconds)
    }

    var isEmpty: Bool { newestSecond == nil }

    mutating func add(wallMs: Int64, intervalMs: Int64, bytes: TrafficBytes) {
        guard intervalMs > 0 else { return }
        let seconds = Double(intervalMs) / 1000
        let rate = TrafficRate(rx: Double(bytes.rx) / seconds, tx: Double(bytes.tx) / seconds)
        let last = Self.second(of: wallMs)
        let first = max(Self.second(of: wallMs - intervalMs) + 1, last - Int64(Self.seconds) + 1)
        advance(to: last)
        guard first <= last else { return }
        for second in first...last { slot(second).map { rates[$0] = rate } }
    }

    /// The 300 buckets ending at `nowMs`'s second, oldest first.
    func points(nowMs: Int64) -> [TrafficPoint] {
        let last = Self.second(of: nowMs)
        let first = last - Int64(Self.seconds) + 1
        return (first...last).map { second in
            TrafficPoint(time: Date(timeIntervalSince1970: TimeInterval(second)), rate: slot(second).map { rates[$0] } ?? .zero)
        }
    }

    private static func second(of ms: Int64) -> Int64 {
        ms >= 0 ? ms / 1000 : (ms - 999) / 1000
    }

    private func slot(_ second: Int64) -> Int? {
        guard let newestSecond, second <= newestSecond, newestSecond - second < Int64(Self.seconds) else { return nil }
        let back = Int(newestSecond - second)
        return (cursor - back + Self.seconds) % Self.seconds
    }

    private mutating func advance(to second: Int64) {
        guard let newest = newestSecond else {
            newestSecond = second
            return
        }
        if second <= newest {
            // The wall clock went back: start over rather than mix two timelines.
            if newest - second >= Int64(Self.seconds) || second < newest - 5 { reset(at: second) }
            return
        }
        let steps = second - newest
        if steps >= Int64(Self.seconds) {
            reset(at: second)
            return
        }
        for _ in 0..<steps {
            cursor = (cursor + 1) % Self.seconds
            rates[cursor] = .zero
        }
        newestSecond = second
    }

    private mutating func reset(at second: Int64) {
        rates = Array(repeating: .zero, count: Self.seconds)
        cursor = 0
        newestSecond = second
    }
}
