import Foundation

/// Builds a trusted, per-window quota history projection from ordered
/// observations. The caller remains responsible for retaining the raw rows.
///
/// The state is intentionally local to one quota window. A 5-hour window and
/// a 7-day window must each have their own instance.
struct QuotaHistoryProtection {
    struct Result: Equatable, Sendable {
        let usedPercent: Int?
        let resetsAt: Date?
        let generation: Int
        let isAnchor: Bool
        let needsEvidence: Bool
        let isCorrection: Bool
    }

    private struct LowerCandidate {
        let firstObservedAt: Date
        var lastObservedAt: Date
        var count: Int
    }

    private let policy: QuotaHistoryProtectionPolicy
    private static let timestampComparisonTolerance: TimeInterval = 0.000_001

    private var lastObservedAt: Date?
    private var acceptedUsed: Int?
    private var acceptedReset: Date?
    private var generation: Int = 0
    private var lowerCandidate: LowerCandidate?

    init(policy: QuotaHistoryProtectionPolicy = .fiveHour) { self.policy = policy }

    mutating func observe(
        usedPercent: Int?,
        resetsAt: Date?,
        observedAt: Date
    ) -> Result {
        guard isFinite(observedAt),
              lastObservedAt.map({ observedAt.timeIntervalSince($0) > Self.timestampComparisonTolerance }) ?? true else {
            // A replayed or late observation must not advance any state,
            // including the lower-value confirmation candidate.
            return result(
                usedPercent: nil,
                isAnchor: false,
                needsEvidence: false,
                isCorrection: false
            )
        }

        lastObservedAt = observedAt

        guard let usedPercent, (0...100).contains(usedPercent) else {
            lowerCandidate = nil
            return result(
                usedPercent: nil,
                isAnchor: false,
                needsEvidence: true,
                isCorrection: false
            )
        }

        let reset = resetsAt.flatMap { isFinite($0) ? $0 : nil }

        // The first valid value establishes the projection baseline. A reset
        // anchor is optional until a finite reset is observed.
        guard acceptedUsed != nil else {
            acceptedUsed = usedPercent
            acceptedReset = reset
            if let reset, observedAt >= reset {
                lowerCandidate = nil
                return result(
                    usedPercent: nil,
                    isAnchor: true,
                    needsEvidence: true,
                    isCorrection: false
                )
            }
            return result(
                usedPercent: usedPercent,
                isAnchor: reset != nil,
                needsEvidence: false,
                isCorrection: false
            )
        }

        // A reset moving forward by more than 30 minutes is an explicit new
        // cycle. This applies to every valid used percentage, including a
        // non-zero value or 100% used.
        if let reset,
           let acceptedReset,
           reset.timeIntervalSince(acceptedReset)
                > policy.newCycleResetDelta + Self.timestampComparisonTolerance {
            guard usedPercent <= policy.maximumNewCycleUsedPercent else {
                lowerCandidate = nil
                return result(usedPercent: nil, isAnchor: false, needsEvidence: true, isCorrection: false)
            }
            generation = generation == Int.max ? Int.max : generation + 1
            self.acceptedReset = reset
            acceptedUsed = usedPercent
            lowerCandidate = nil
            return result(
                usedPercent: usedPercent,
                isAnchor: true,
                needsEvidence: false,
                isCorrection: false
            )
        }

        // Once local observation time reaches the accepted reset boundary,
        // the old cycle cannot be extended without a new reset boundary.
        if let acceptedReset, observedAt >= acceptedReset {
            lowerCandidate = nil
            return result(
                usedPercent: nil,
                isAnchor: false,
                needsEvidence: true,
                isCorrection: false
            )
        }

        // A reset moving backwards by more than the jitter band conflicts with
        // the fixed anchor. Never follow creeping reset values.
        if let reset,
           let acceptedReset,
           reset.timeIntervalSince(acceptedReset)
                < -policy.resetJitterTolerance - Self.timestampComparisonTolerance {
            lowerCandidate = nil
            return result(
                usedPercent: nil,
                isAnchor: false,
                needsEvidence: true,
                isCorrection: false
            )
        }

        // If the first baseline had no reset, the first finite reset can
        // establish the fixed anchor. It does not create a new generation.
        let establishingAnchor = acceptedReset == nil && reset != nil
        if establishingAnchor {
            acceptedReset = reset
            if let reset, observedAt >= reset {
                lowerCandidate = nil
                return result(
                    usedPercent: nil,
                    isAnchor: true,
                    needsEvidence: true,
                    isCorrection: false
                )
            }
        }

        guard let acceptedUsed else {
            // This is unreachable because the initial baseline is guarded
            // above, but retaining a gap is safer than inventing a value if
            // the state model changes later.
            lowerCandidate = nil
            return result(
                usedPercent: nil,
                isAnchor: establishingAnchor,
                needsEvidence: true,
                isCorrection: false
            )
        }

        if usedPercent >= acceptedUsed {
            self.acceptedUsed = usedPercent
            lowerCandidate = nil
            return result(
                usedPercent: usedPercent,
                isAnchor: establishingAnchor,
                needsEvidence: false,
                isCorrection: false
            )
        }

        // A lower value cannot be confirmed without a reset tied to the
        // fixed anchor. Missing reset values and reset drift restart the
        // candidate instead of inferring negative consumption.
        guard let reset,
              let acceptedReset,
              abs(reset.timeIntervalSince(acceptedReset))
                <= policy.resetJitterTolerance + Self.timestampComparisonTolerance else {
            lowerCandidate = nil
            return result(
                usedPercent: nil,
                isAnchor: establishingAnchor,
                needsEvidence: true,
                isCorrection: false
            )
        }

        if lowerCandidate == nil {
            lowerCandidate = LowerCandidate(
                firstObservedAt: observedAt,
                lastObservedAt: observedAt,
                count: 0
            )
        }
        if var candidate = lowerCandidate {
            candidate.lastObservedAt = observedAt
            candidate.count += 1
            lowerCandidate = candidate
        }

        if let lowerCandidate,
           lowerCandidate.count >= policy.correctionSampleCount,
           observedAt.timeIntervalSince(lowerCandidate.firstObservedAt)
                + Self.timestampComparisonTolerance
                >= policy.correctionEvidenceDuration {
            self.acceptedUsed = usedPercent
            self.lowerCandidate = nil
            return result(
                usedPercent: usedPercent,
                isAnchor: establishingAnchor,
                needsEvidence: true,
                isCorrection: true
            )
        }

        return result(
            usedPercent: nil,
            isAnchor: establishingAnchor,
            needsEvidence: true,
            isCorrection: false
        )
    }

    private func result(
        usedPercent: Int?,
        isAnchor: Bool,
        needsEvidence: Bool,
        isCorrection: Bool
    ) -> Result {
        Result(
            usedPercent: usedPercent,
            resetsAt: acceptedReset,
            generation: generation,
            isAnchor: isAnchor,
            needsEvidence: needsEvidence,
            isCorrection: isCorrection
        )
    }

    private func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
    }
}
