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
    // A possible reset limits certain attribution, not observation freshness.
    var pendingBoundary: QuotaCycleBoundary? = nil

    var certainStart: Date { start?.latest ?? firstObservedAt }
    var certainEnd: Date { end?.earliest ?? pendingBoundary?.earliest ?? lastObservedAt }
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

struct QuotaCycleDiagnosticEvent: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case corrected, candidate, confirmed, withdrawn }
    let kind: Kind
    let at: Date
    let before: QuotaCycleObservation
    let after: QuotaCycleObservation
    var id: String { "\(kind.rawValue):\(at.timeIntervalSince1970):\(before.resetsAt.timeIntervalSince1970):\(after.resetsAt.timeIntervalSince1970)" }
    var detail: String {
        "\(kind.rawValue) at=\(at.ISO8601Format()) reset=\(before.resetsAt.ISO8601Format())→\(after.resetsAt.ISO8601Format()) used=\(before.usedPercent)→\(after.usedPercent) beforeAt=\(before.at.ISO8601Format())"
    }
}

struct QuotaCycleProjection {
    let cycles: [QuotaActualCycle]
    let diagnostics: [QuotaCycleDiagnosticEvent]
}

enum QuotaActualCycleProjector {
    static let projectionVersion = 2

    static func project(_ input: [QuotaCycleObservation], now: Date) -> [QuotaActualCycle] {
        projectWithDiagnostics(input, now: now).cycles
    }

    static func projectWithDiagnostics(_ input: [QuotaCycleObservation], now: Date) -> QuotaCycleProjection {
        let observations = input.filter {
            $0.at <= now && $0.at.timeIntervalSince1970.isFinite
                && $0.resetsAt.timeIntervalSince1970.isFinite && $0.resetsAt > $0.at
                && (0...100).contains($0.usedPercent)
        }.sorted { $0.at < $1.at }.reduce(into: [QuotaCycleObservation]()) { result, item in
            if result.last?.at != item.at { result.append(item) }
        }
        guard let first = observations.first else { return .init(cycles: [], diagnostics: []) }
        var output: [QuotaActualCycle] = []
        var diagnostics: [QuotaCycleDiagnosticEvent] = []
        var diagnosticIDs = Set<String>()
        var firstObserved = first
        var latest = first
        var lastCertain = first
        var anchor = first.resetsAt
        var start: QuotaCycleBoundary?
        var pending = false
        var pendingBoundary: QuotaCycleBoundary?
        func make(end: QuotaCycleBoundary?, early: Bool, current: Bool) -> QuotaActualCycle {
            QuotaActualCycle(id: "observed:\(firstObserved.at.timeIntervalSince1970)", start: start,
                end: end, scheduledResetAt: anchor, firstObservedAt: firstObserved.at,
                lastObservedAt: latest.at, endedEarly: early,
                resetChangePending: pending, isCurrent: current, pendingBoundary: pendingBoundary)
        }
        func record(_ kind: QuotaCycleDiagnosticEvent.Kind, before: QuotaCycleObservation,
                    after: QuotaCycleObservation, at: Date? = nil) {
            let event = QuotaCycleDiagnosticEvent(kind: kind, at: at ?? after.at, before: before, after: after)
            if diagnosticIDs.insert(event.id).inserted { diagnostics.append(event) }
        }
        for index in observations.indices.dropFirst() {
            let item = observations[index]
            let previous = latest
            let delta = item.resetsAt.timeIntervalSince(anchor)
            if delta <= 900 {
                // Jitter, small forward corrections and backward corrections
                // do not establish a boundary. Advance the observation and
                // accepted schedule together, including cumulative drift.
                if pending { record(.withdrawn, before: previous, after: item) }
                else if abs(delta) > 5 { record(.corrected, before: previous, after: item) }
                latest = item
                lastCertain = item
                anchor = item.resetsAt
                pending = false
                pendingBoundary = nil
                continue
            }
            let natural = item.at >= anchor && lastCertain.at < anchor
            // A second app can repeat the same provider reading seconds later.
            // Require a clear replenishment followed by consumption; weak
            // drops and immediate rebounds remain unconfirmed corrections.
            var confirmedEarly = false
            var confirmationAt: Date?
            let replenished = item.at < anchor && previous.usedPercent - item.usedPercent >= 5
            if replenished {
                for next in observations.dropFirst(index + 1) {
                    guard abs(next.resetsAt.timeIntervalSince(item.resetsAt)) <= 5,
                          next.usedPercent >= item.usedPercent,
                          next.usedPercent < previous.usedPercent else { break }
                    if next.at.timeIntervalSince(item.at) >= 60 && next.usedPercent > item.usedPercent {
                        confirmedEarly = true
                        confirmationAt = next.at
                        break
                    }
                }
            }
            // A later abrupt return invalidates a provisional reset; do not
            // mistake a real period gradually consuming back to its old level.
            if confirmedEarly {
                var prior = item
                for next in observations.dropFirst(index + 1) {
                    if next.at.timeIntervalSince(item.at) > 90 * 60 { break }
                    if abs(next.usedPercent - previous.usedPercent) <= 3
                        && next.usedPercent - prior.usedPercent >= 5
                        && abs(next.resetsAt.timeIntervalSince(anchor)) <= 5 {
                        confirmedEarly = false
                        record(.withdrawn, before: item, after: next)
                        break
                    }
                    prior = next
                }
            }
            if replenished, pendingBoundary == nil { record(.candidate, before: previous, after: item) }
            guard natural || confirmedEarly else {
                if replenished, pendingBoundary == nil {
                    pendingBoundary = .init(earliest: previous.at, latest: item.at)
                }
                // Without a replenishment, only the schedule is uncertain;
                // same-period usage is still certain and may keep advancing.
                if pendingBoundary == nil { lastCertain = item }
                latest = item
                pending = true
                continue
            }
            let boundary: QuotaCycleBoundary = if natural {
                // A pre-expiry unconfirmed drop cannot make expiry exact.
                pendingBoundary.map { .init(earliest: $0.earliest, latest: anchor) } ?? .exact(anchor)
            } else {
                .init(earliest: pendingBoundary?.earliest ?? previous.at, latest: item.at)
            }
            record(.confirmed, before: previous, after: item, at: confirmationAt ?? item.at)
            pending = false
            pendingBoundary = nil
            output.append(make(end: boundary, early: confirmedEarly, current: false))
            // A long offline gap may contain unknown cycles. Preserve the old
            // observed expiry but never backfill invented intermediate periods.
            start = natural && item.at.timeIntervalSince(lastCertain.at) >= 7 * 24 * 60 * 60 ? nil : boundary
            firstObserved = item
            latest = item
            lastCertain = item
            anchor = item.resetsAt
        }
        let expired = now >= anchor
        output.append(make(end: expired ? QuotaCycleBoundary(earliest: lastCertain.at, latest: anchor) : nil, early: false, current: !expired))
        return .init(cycles: output.reversed(), diagnostics: diagnostics.sorted { $0.at < $1.at })
    }
}
