import Foundation

/// Cumulative `rx`/`tx` counters of one key at one sample.
struct TrafficCounter: Equatable, Sendable {
    var rx: Int64
    var tx: Int64

    init(rx: Int64, tx: Int64) {
        self.rx = rx
        self.tx = tx
    }
}

enum CounterDelta {
    /// 100 Gbit/s (METRICS 10.4).
    static let maxBytesPerSecond = 12_500_000_000.0

    /// `cur − prev`; a decrease or more than 12.5 GB/s × Δt is a reset (0).
    static func delta(from previous: Int64, to current: Int64, intervalMs: Int64?) -> Int64 {
        guard current >= previous else { return 0 }
        let delta = current - previous
        if let intervalMs, Double(delta) > maxBytesPerSecond * Double(max(intervalMs, 1)) / 1000 { return 0 }
        return delta
    }

    static func delta(from previous: TrafficCounter, to current: TrafficCounter, intervalMs: Int64?) -> TrafficBytes {
        TrafficBytes(rx: delta(from: previous.rx, to: current.rx, intervalMs: intervalMs),
                     tx: delta(from: previous.tx, to: current.tx, intervalMs: intervalMs))
    }
}

/// Process-counter baselines of one stream (METRICS 10.4.2–10.4.4, 10.4.7): a key absent from three consecutive
/// samples is forgotten.
struct CounterBaselines {
    static let forgetAfter = 3

    private var values: [ProcessIdentity: TrafficCounter] = [:]
    private var missing: [ProcessIdentity: Int] = [:]

    var count: Int { values.count }

    func value(_ key: ProcessIdentity) -> TrafficCounter? { values[key] }

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
        missing.removeAll(keepingCapacity: true)
    }

    mutating func set(_ key: ProcessIdentity, _ counter: TrafficCounter) {
        values[key] = counter
    }

    /// Ages every key not in `seen` by one sample.
    mutating func age(seen: Set<ProcessIdentity>) {
        var forgotten: [ProcessIdentity] = []
        for key in values.keys {
            if seen.contains(key) {
                missing[key] = nil
            } else {
                let count = (missing[key] ?? 0) + 1
                if count >= Self.forgetAfter { forgotten.append(key) } else { missing[key] = count }
            }
        }
        for key in forgotten {
            values[key] = nil
            missing[key] = nil
        }
    }
}
