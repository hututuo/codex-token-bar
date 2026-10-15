import Foundation

/// Pure, deterministic analysis of already-qualified cache-retention pairs.
/// This type does not read source data or persist its result.
struct CacheRetentionAnalysis: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case insufficient
        case rangeTooLarge = "range_too_large"
        case smallSample = "small_sample"
        case ready
        case notDetected = "not_detected"
    }

    struct Segment: Codable, Equatable, Sendable {
        let count: Int
        let highCount: Int
        let rate: Double
    }

    let count: Int
    let highCount: Int
    let p95Microseconds: Int64?
    let p95CoverageCount: Int?
    let dropMicroseconds: Double?
    let dropLeftMicroseconds: Int64?
    let dropRightMicroseconds: Int64?
    let p95State: State
    let dropState: State
    let segments: [Segment]
    let bestSegments: Int?
    /// `not_run`, `exact`, or `bounded_candidate_grid`.
    let searchMode: String

    struct EarlierDecline: Codable, Equatable, Sendable {
        let microseconds: Double
        let leftMicroseconds: Int64
        let rightMicroseconds: Int64
        let count: Int
        let segments: [Segment]
        let searchMode: String
    }

    /// Separately fit only observations strictly before the main decline.
    /// An absent value means there is no supported second, earlier boundary.
    var earlierDecline: EarlierDecline? = nil

    private static let maximumCount = 100_000
    private static let minimumHighCount = 20
    private static let minimumSegmentCount = 20
    private static let exactCutLimit = 512
    private static let candidateGridDivisor = 513

    private struct TieGroup {
        let gap: Int64
        var count: Int
        var highCount: Int
    }

    private struct Fit {
        let logLikelihood: Double
        let cuts: [Int]
    }

    private struct SegmentStats {
        let count: Int
        let highCount: Int
        let rate: Double
        let logLikelihood: Double

        var segment: Segment {
            Segment(count: count, highCount: highCount, rate: rate)
        }
    }

    static func calculate(_ points: [CacheRetentionPoint]) -> CacheRetentionAnalysis {
        var result = fit(points)
        guard let main = result.dropMicroseconds, let lastBefore = result.dropLeftMicroseconds else { return result }
        let prefix = points.filter { $0.gapMicroseconds <= lastBefore }
        let earlier = fit(prefix)
        if let value = earlier.dropMicroseconds, value < main,
           let left = earlier.dropLeftMicroseconds, let right = earlier.dropRightMicroseconds {
            result.earlierDecline = EarlierDecline(microseconds: value, leftMicroseconds: left,
                rightMicroseconds: right, count: prefix.count, segments: earlier.segments,
                searchMode: earlier.searchMode)
        }
        return result
    }

    // Shared monotone 1/2/3-segment fit and model penalty. No fixed
    // percentage-point drop threshold or desired minute enters this method.
    private static func fit(_ points: [CacheRetentionPoint]) -> CacheRetentionAnalysis {
        let count = points.count
        let highCount = points.reduce(into: 0) { total, point in
            if point.highReuse { total += 1 }
        }

        guard count <= maximumCount else {
            return CacheRetentionAnalysis(
                count: count,
                highCount: highCount,
                p95Microseconds: nil,
                p95CoverageCount: nil,
                dropMicroseconds: nil,
                dropLeftMicroseconds: nil,
                dropRightMicroseconds: nil,
                p95State: .rangeTooLarge,
                dropState: .rangeTooLarge,
                segments: [],
                bestSegments: nil,
                searchMode: "not_run"
            )
        }

        var p95Microseconds: Int64?
        var p95CoverageCount: Int?
        var p95State: State = .insufficient
        if highCount >= minimumHighCount {
            let highGaps = points.lazy
                .filter(\.highReuse)
                .map(\.gapMicroseconds)
                .sorted()
            // Nearest rank: ceil(0.95 * k), expressed with integer math.
            let rank = (95 * highCount + 99) / 100
            let value = highGaps[rank - 1]
            p95Microseconds = value
            p95CoverageCount = upperBound(value, in: highGaps)
            p95State = highCount < 100 ? .smallSample : .ready
        }

        guard count >= 40 else {
            return CacheRetentionAnalysis(
                count: count,
                highCount: highCount,
                p95Microseconds: p95Microseconds,
                p95CoverageCount: p95CoverageCount,
                dropMicroseconds: nil,
                dropLeftMicroseconds: nil,
                dropRightMicroseconds: nil,
                p95State: p95State,
                dropState: .insufficient,
                segments: [],
                bestSegments: nil,
                searchMode: "not_run"
            )
        }

        var groupsByGap: [Int64: TieGroup] = [:]
        groupsByGap.reserveCapacity(count)
        for point in points {
            if var group = groupsByGap[point.gapMicroseconds] {
                group.count += 1
                if point.highReuse { group.highCount += 1 }
                groupsByGap[point.gapMicroseconds] = group
            } else {
                groupsByGap[point.gapMicroseconds] = TieGroup(
                    gap: point.gapMicroseconds,
                    count: 1,
                    highCount: point.highReuse ? 1 : 0
                )
            }
        }
        let groups = groupsByGap.values.sorted { $0.gap < $1.gap }

        let groupCount = groups.count
        var prefixCounts = [Int](repeating: 0, count: groupCount + 1)
        var prefixHighCounts = [Int](repeating: 0, count: groupCount + 1)
        for index in groups.indices {
            prefixCounts[index + 1] = prefixCounts[index] + groups[index].count
            prefixHighCounts[index + 1] = prefixHighCounts[index] + groups[index].highCount
        }

        var searchMode = "exact"
        var candidateCuts = Array(1..<groupCount)
        if candidateCuts.count > exactCutLimit {
            searchMode = "bounded_candidate_grid"
            var candidates = Set<Int>()
            for gridIndex in 1...exactCutLimit {
                // ceil(gridIndex * n / 513), equivalent to bisect_left over
                // cumulative sample counts using the reference algorithm's
                // fractional target, without floating-point boundary drift.
                let targetCount = (gridIndex * count + candidateGridDivisor - 1)
                    / candidateGridDivisor
                let insertion = lowerBound(targetCount, in: prefixCounts)
                candidates.insert(min(max(insertion, 1), groupCount - 1))
            }
            candidateCuts = candidates.sorted()
        }

        func segmentStats(from start: Int, to end: Int) -> SegmentStats? {
            let n = prefixCounts[end] - prefixCounts[start]
            guard n >= minimumSegmentCount else { return nil }
            let k = prefixHighCounts[end] - prefixHighCounts[start]
            let probability = Double(k) / Double(n)
            var logLikelihood = 0.0
            if k > 0 {
                logLikelihood += Double(k) * log(probability)
            }
            if n > k {
                logLikelihood += Double(n - k) * log1p(-probability)
            }
            return SegmentStats(
                count: n,
                highCount: k,
                rate: probability,
                logLikelihood: logLikelihood
            )
        }

        // The full range has at least 40 points, so the one-segment fit exists.
        let whole = segmentStats(from: 0, to: groupCount)!
        var fits: [Int: Fit] = [1: Fit(logLikelihood: whole.logLikelihood, cuts: [])]
        var hasSupportedTwoSegmentSplit = false

        for cut in candidateCuts {
            guard let left = segmentStats(from: 0, to: cut),
                  let right = segmentStats(from: cut, to: groupCount) else {
                continue
            }
            hasSupportedTwoSegmentSplit = true
            guard left.rate >= right.rate else { continue }
            let logLikelihood = left.logLikelihood + right.logLikelihood
            if let current = fits[2],
               logLikelihood <= current.logLikelihood + 1e-12 {
                continue
            }
            fits[2] = Fit(logLikelihood: logLikelihood, cuts: [cut])
        }

        for firstIndex in candidateCuts.indices {
            let firstCut = candidateCuts[firstIndex]
            guard let first = segmentStats(from: 0, to: firstCut) else { continue }
            for secondIndex in candidateCuts.indices where secondIndex > firstIndex {
                let secondCut = candidateCuts[secondIndex]
                guard let middle = segmentStats(from: firstCut, to: secondCut),
                      let last = segmentStats(from: secondCut, to: groupCount),
                      first.rate >= middle.rate,
                      middle.rate >= last.rate else {
                    continue
                }
                let logLikelihood = first.logLikelihood
                    + middle.logLikelihood
                    + last.logLikelihood
                if let current = fits[3],
                   logLikelihood <= current.logLikelihood + 1e-12 {
                    continue
                }
                fits[3] = Fit(
                    logLikelihood: logLikelihood,
                    cuts: [firstCut, secondCut]
                )
            }
        }

        guard hasSupportedTwoSegmentSplit else {
            return CacheRetentionAnalysis(
                count: count,
                highCount: highCount,
                p95Microseconds: p95Microseconds,
                p95CoverageCount: p95CoverageCount,
                dropMicroseconds: nil,
                dropLeftMicroseconds: nil,
                dropRightMicroseconds: nil,
                p95State: p95State,
                dropState: .insufficient,
                segments: [],
                bestSegments: nil,
                searchMode: searchMode
            )
        }

        let scores = fits.mapValues { fit in
            -2 * fit.logLikelihood
                + Double(2 * fit.cuts.count + 1) * log(Double(count))
        }
        let minimumScore = scores.values.min()!
        let bestSegments = scores.keys.sorted().first { segmentCount in
            scores[segmentCount]! <= minimumScore + 1e-10
        }!
        let bestFit = fits[bestSegments]!
        let boundaries = [0] + bestFit.cuts + [groupCount]
        let fittedSegments = zip(boundaries, boundaries.dropFirst()).compactMap {
            segmentStats(from: $0.0, to: $0.1)?.segment
        }

        var dropMicroseconds: Double?
        var dropLeftMicroseconds: Int64?
        var dropRightMicroseconds: Int64?
        var dropState: State = .notDetected
        if bestSegments > 1 {
            var largestDropIndex = 0
            var largestDrop = fittedSegments[0].rate - fittedSegments[1].rate
            for index in 1..<(fittedSegments.count - 1) {
                let drop = fittedSegments[index].rate - fittedSegments[index + 1].rate
                // Strict comparison preserves the earliest cut on a tie.
                if drop > largestDrop {
                    largestDrop = drop
                    largestDropIndex = index
                }
            }
            let cut = bestFit.cuts[largestDropIndex]
            let left = groups[cut - 1].gap
            let right = groups[cut].gap
            dropLeftMicroseconds = left
            dropRightMicroseconds = right
            dropMicroseconds = midpoint(left, right)
            dropState = .ready
        }

        return CacheRetentionAnalysis(
            count: count,
            highCount: highCount,
            p95Microseconds: p95Microseconds,
            p95CoverageCount: p95CoverageCount,
            dropMicroseconds: dropMicroseconds,
            dropLeftMicroseconds: dropLeftMicroseconds,
            dropRightMicroseconds: dropRightMicroseconds,
            p95State: p95State,
            dropState: dropState,
            segments: fittedSegments,
            bestSegments: bestSegments,
            searchMode: searchMode
        )
    }

    private static func upperBound(_ value: Int64, in sortedValues: [Int64]) -> Int {
        var lower = 0
        var upper = sortedValues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sortedValues[middle] <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func lowerBound(_ value: Int, in sortedValues: [Int]) -> Int {
        var lower = 0
        var upper = sortedValues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sortedValues[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    /// Computes (left + right) / 2 without overflowing the Int64 sum.
    private static func midpoint(_ left: Int64, _ right: Int64) -> Double {
        let whole = left / 2 + right / 2
        let remainder = left % 2 + right % 2
        return Double(whole) + Double(remainder) / 2
    }
}
