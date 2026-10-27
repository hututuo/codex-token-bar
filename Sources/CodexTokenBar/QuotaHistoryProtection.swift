import Foundation

/// Pure retrospective projection over one identity/plan/limit timeline.
/// Indices refer to the input observations; raw values are never rewritten.
struct QuotaHistoryProtection {
    struct Sample: Codable {
        let at: Double
        let fiveUsed: Int?
        let fiveReset: Double?
        let sevenUsed: Int?
        let sevenReset: Double?
    }
    enum Reason: String { case returnToBaseline, jump, resetReturned, resetUnchanged }
    struct Rejection {
        let baseline: Int
        let start: Int
        let end: Int
        let reason: Reason
    }
    struct Projection {
        var fiveRejected = Set<Int>()
        var sevenRejected = Set<Int>()
        /// Explicit baseline -> retained endpoint, including cross-cycle links.
        var fiveBridges: [Int: Int] = [:]
        var sevenBridges: [Int: Int] = [:]
        var events: [Rejection] = []
    }
    private static let epsilon = 0.000_001
    static func valid(_ used: Int?) -> Int? { used.flatMap { (0...100).contains($0) ? $0 : nil } }
    private static func sameReset(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a.isFinite, b.isFinite else { return false }
        return abs(a - b) <= 5 + epsilon
    }

    static func project(_ samples: [Sample], plan: String?, now: Double,
                        consumption: QuotaActualCycleProjector.Consumption = { _, _ in .unknown }) -> Projection {
        var result = Projection()
        var fresh = Set<Int>()
        var indices: [Int] = []
        var observations: [QuotaCycleObservation] = []
        var seen = -Double.infinity
        for (i, sample) in samples.enumerated() {
            guard sample.at.isFinite, sample.at <= now, sample.at > seen else { continue }
            seen = sample.at
            fresh.insert(i)
            guard let used = valid(sample.sevenUsed) else { continue }
            indices.append(i)
            observations.append(.init(at: Date(timeIntervalSince1970: sample.at), usedPercent: used,
                resetsAt: Date(timeIntervalSince1970: sample.sevenReset ?? 0)))
        }
        for reversal in QuotaActualCycleProjector.reversals(observations, consumption: consumption) {
            let baseline = indices[reversal.beforeIndex], start = indices[reversal.dropIndex]
            let end = indices[reversal.returnIndex]
            // Only the presentation projection is repaired. The raw quota
            // observations and numeric usage ledger are never rewritten.
            for i in start..<end { result.sevenRejected.insert(i) }
            result.sevenBridges[baseline] = end
            result.events.append(.init(baseline: baseline, start: start, end: end, reason: .returnToBaseline))
        }

        // A 5h event needs its own single-point A-B-A evidence and an exact
        // paired observation rejected by 7d; proximity within a bin is not pairing.
        let five = samples.indices.filter { fresh.contains($0) && valid(samples[$0].fiveUsed) != nil }
        if five.count >= 3 {
            for n in 1..<(five.count - 1) {
                let a = five[n - 1], b = five[n], c = five[n + 1]
                guard result.sevenRejected.contains(b), samples[a].fiveUsed! > 0,
                      samples[b].fiveUsed == 0, samples[c].fiveUsed! > 0,
                      samples[c].at > samples[b].at + epsilon,
                      samples[c].at - samples[b].at <= 120 + epsilon,
                      abs(samples[c].fiveUsed! - samples[a].fiveUsed!) <= 1,
                      sameReset(samples[a].fiveReset, samples[b].fiveReset),
                      sameReset(samples[a].fiveReset, samples[c].fiveReset) else { continue }
                result.fiveRejected.insert(b)
                if samples[b].at - samples[a].at <= 90 * 60 + epsilon {
                    result.fiveBridges[a] = c
                }
            }
        }
        return result
    }
}
