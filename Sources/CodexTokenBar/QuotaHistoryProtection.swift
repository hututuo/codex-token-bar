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
    private struct Candidate {
        let baseline: Int
        let start: Int
        var last: Int
        var leftBand: Bool
        var resetLeft: Bool
        var resetUnchanged: Bool
    }
    private static let epsilon = 0.000_001
    static func valid(_ used: Int?) -> Int? { used.flatMap { (0...100).contains($0) ? $0 : nil } }
    private static func sameReset(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a.isFinite, b.isFinite else { return false }
        return abs(a - b) <= 5 + epsilon
    }

    static func project(_ samples: [Sample], plan: String?, now: Double) -> Projection {
        var result = Projection()
        var candidate: Candidate?
        var previous: Int?
        var seen: Double?
        var suppressed = false
        var fresh = Set<Int>()
        let rate: Double? = switch plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plus": 10
        case "pro": 2
        default: nil
        }
        func reject(_ c: Candidate, _ reason: Reason) {
            guard c.last > c.start else { return }
            for i in c.start..<c.last { result.sevenRejected.insert(i) }
            // Do not extend explicit repair across an unrelated long gap
            // preceding the candidate (existing carry horizon is 90 minutes).
            if samples[c.start].at - samples[c.baseline].at <= 90 * 60 + epsilon {
                result.sevenBridges[c.baseline] = c.last
            }
            result.events.append(Rejection(baseline: c.baseline, start: c.start, end: c.last, reason: reason))
        }
        func settle(_ c: Candidate) {
            let deadline = samples[c.start].at + 300
            if c.resetUnchanged && deadline - samples[c.last].at <= 120 + epsilon {
                reject(c, .resetUnchanged)
            }
        }
        for (i, sample) in samples.enumerated() {
            guard sample.at.isFinite, sample.at <= now + epsilon,
                  seen.map({ sample.at > $0 + epsilon }) ?? true else { continue }
            seen = sample.at
            fresh.insert(i)
            if let c = candidate, sample.at > samples[c.start].at + 300 + epsilon {
                settle(c)
                candidate = nil
                suppressed = (valid(samples[c.last].sevenUsed) ?? 0) <= 2
            }
            guard let used = valid(sample.sevenUsed) else {
                candidate?.resetUnchanged = false
                continue
            }
            if var c = candidate {
                let base = samples[c.baseline]
                let last = samples[c.last]
                let inBand = abs(used - base.sevenUsed!) <= 3
                let resetSame = sameReset(sample.sevenReset, base.sevenReset)
                let resetReturn = c.resetLeft && resetSame
                let returned = c.leftBand && inBand && used > last.sevenUsed!
                let jumped = rate.map { Double(used - last.sevenUsed!) * 60 / (sample.at - last.at) > $0 + epsilon } ?? false
                c.resetUnchanged = c.resetUnchanged && resetSame && sample.at - last.at <= 120 + epsilon
                if let reset = sample.sevenReset, reset.isFinite,
                   let old = base.sevenReset, old.isFinite, !resetSame { c.resetLeft = true }
                c.leftBand = c.leftBand || !inBand
                c.last = i
                if returned || jumped || resetReturn {
                    reject(c, returned ? .returnToBaseline : (jumped ? .jump : .resetReturned))
                    candidate = nil
                    suppressed = used <= 2
                } else if sample.at >= samples[c.start].at + 300 - epsilon {
                    settle(c)
                    candidate = nil
                    suppressed = used <= 2
                } else {
                    candidate = c
                }
            } else {
                if used > 2 { suppressed = false }
                if !suppressed, let previous, let prior = valid(samples[previous].sevenUsed), used < prior, used <= 2 {
                    let same = sameReset(sample.sevenReset, samples[previous].sevenReset)
                    let hasResets = sample.sevenReset?.isFinite == true && samples[previous].sevenReset?.isFinite == true
                    candidate = Candidate(baseline: previous, start: i, last: i,
                        leftBand: abs(used - prior) > 3, resetLeft: hasResets && !same, resetUnchanged: same)
                }
            }
            previous = i
        }
        if let c = candidate, now >= samples[c.start].at + 300 - epsilon { settle(c) }

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
