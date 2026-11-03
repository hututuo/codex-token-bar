import Foundation

/// Display only: the same rise/fall response used by the Codex Bar curve.
/// Time-based gain keeps a faster reader from changing the smoothing strength.
enum ActivityRateSmoothing {
    static func step(previous: Double, target: Double, seconds: Double = 1) -> Double {
        let gain = target >= previous ? 0.28 : 0.18
        return previous + (target - previous) * (seconds == 1 ? gain : 1 - pow(1 - gain, seconds))
    }
    static func tail(age: Double) -> Double {
        let x = min(1, max(0, (5 - age) / 2))
        return x * x * (3 - 2 * x)
    }
}

/// Bounded local presentation state. Never feeds usage, measured TPS or reporting.
struct ActivityModelRateSmoother {
    private struct Value { var rate: Double; var positiveAt: Double }
    private var values: [String: Value] = [:]
    private var lastTime: Double?
    var rates: [String: Double] {
        values.mapValues { $0.rate * ActivityRateSmoothing.tail(age: (lastTime ?? $0.positiveAt) - $0.positiveAt) }
    }

    mutating func update(_ raw: [String: Double], at time: Double, active: Bool) -> [String: Double] {
        guard time.isFinite, active else { self = Self(); return [:] }
        if let lastTime, time <= lastTime { return rates }
        if let lastTime, time - lastTime > 3.5 { self = Self() }
        let seconds = lastTime.map { time - $0 } ?? 1
        lastTime = time
        let clean = raw.filter { $0.value.isFinite && $0.value > 0 }
        for model in Set(values.keys).union(clean.keys) {
            let target = clean[model] ?? 0
            let old = values[model] ?? Value(rate: 0, positiveAt: time)
            let positiveAt = target > 0 ? time : old.positiveAt
            let rate = ActivityRateSmoothing.step(previous: old.rate, target: target, seconds: seconds)
            if time - positiveAt < 5, rate.isFinite, rate > 0.001 {
                values[model] = Value(rate: rate, positiveAt: positiveAt)
            } else { values.removeValue(forKey: model) }
        }
        return rates
    }
}
