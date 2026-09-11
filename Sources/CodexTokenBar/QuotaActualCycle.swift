import Foundation

/// Only accepted quota observations enter this projection. Generation changes
/// are deliberately insufficient: a server reset correction is not a reset.
struct QuotaCycleObservation: Equatable, Sendable {
    let at: Date
    let usedPercent: Int
    let resetsAt: Date
}

struct QuotaCycleBoundary: Equatable, Sendable {
    let earliest: Date
    let latest: Date
    var isExact: Bool { earliest == latest }
    static func exact(_ date: Date) -> Self { Self(earliest: date, latest: date) }
}

struct QuotaActualCycle: Identifiable, Equatable, Sendable {
    let id: String
    let start: QuotaCycleBoundary?
    let end: QuotaCycleBoundary?
    let scheduledResetAt: Date
    let firstObservedAt: Date
    let lastObservedAt: Date
    let endedEarly: Bool
    let resetChangePending: Bool
    let isCurrent: Bool

    var certainStart: Date { start?.latest ?? firstObservedAt }
    var certainEnd: Date { end?.earliest ?? lastObservedAt }
    var hasCompleteBoundaries: Bool { start?.isExact == true && end?.isExact == true }
    var statusText: String {
        if resetChangePending { return "时间待确认" }
        if endedEarly { return "提前重置（推测）" }
        if end?.isExact == false { return "时间待确认" }
        if start == nil { return "起点未知" }
        if start?.isExact == false { return "时间待确认" }
        return isCurrent ? "本期进行中" : "已结束"
    }
}

enum QuotaActualCycleProjector {
    static func project(_ input: [QuotaCycleObservation], now: Date) -> [QuotaActualCycle] {
        let observations = input.filter {
            $0.at <= now && $0.at.timeIntervalSince1970.isFinite
                && $0.resetsAt.timeIntervalSince1970.isFinite && $0.resetsAt > $0.at
                && (0...100).contains($0.usedPercent)
        }.sorted { $0.at < $1.at }.reduce(into: [QuotaCycleObservation]()) { result, item in
            if result.last?.at != item.at { result.append(item) }
        }
        guard let first = observations.first else { return [] }
        var output: [QuotaActualCycle] = []
        var firstObserved = first
        var lastAccepted = first
        var anchor = first.resetsAt
        var start: QuotaCycleBoundary?
        var pending = false
        func make(end: QuotaCycleBoundary?, early: Bool, current: Bool) -> QuotaActualCycle {
            QuotaActualCycle(id: "observed:\(firstObserved.at.timeIntervalSince1970)", start: start,
                end: end, scheduledResetAt: anchor, firstObservedAt: firstObserved.at,
                lastObservedAt: lastAccepted.at, endedEarly: early,
                resetChangePending: pending, isCurrent: current)
        }
        for index in observations.indices.dropFirst() {
            let item = observations[index]
            let delta = item.resetsAt.timeIntervalSince(anchor)
            if abs(delta) <= 5 {
                lastAccepted = item
                pending = false
                continue
            }
            guard delta > 900 else {
                // Larger backward and small forward corrections are not proof
                // of a new period; keep the last unambiguous observation.
                pending = true
                continue
            }
            let natural = item.at >= anchor && lastAccepted.at < anchor
            // A second app can repeat the same provider reading seconds later.
            // Require a near-empty new period sustained across a minute; weak
            // drops and immediate rebounds remain unconfirmed corrections.
            var confirmedEarly = false
            if item.at < anchor && item.usedPercent <= 5 && item.usedPercent < lastAccepted.usedPercent {
                for next in observations.dropFirst(index + 1) {
                    guard abs(next.resetsAt.timeIntervalSince(item.resetsAt)) <= 5,
                          next.usedPercent >= item.usedPercent,
                          next.usedPercent < lastAccepted.usedPercent else { break }
                    if next.at.timeIntervalSince(item.at) >= 60 {
                        confirmedEarly = true
                        break
                    }
                }
            }
            guard natural || confirmedEarly else { pending = true; continue }
            let boundary = natural ? QuotaCycleBoundary.exact(anchor)
                : QuotaCycleBoundary(earliest: lastAccepted.at, latest: item.at)
            pending = false
            output.append(make(end: boundary, early: confirmedEarly, current: false))
            // A long offline gap may contain unknown cycles. Preserve the old
            // observed expiry but never backfill invented intermediate periods.
            start = natural && item.at.timeIntervalSince(lastAccepted.at) >= 7 * 24 * 60 * 60 ? nil : boundary
            firstObserved = item
            lastAccepted = item
            anchor = item.resetsAt
        }
        let expired = now >= anchor
        output.append(make(end: expired ? QuotaCycleBoundary(earliest: lastAccepted.at, latest: anchor) : nil, early: false, current: !expired))
        return output.reversed()
    }
}
