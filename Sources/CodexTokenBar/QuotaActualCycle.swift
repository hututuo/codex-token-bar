import Foundation

/// One stable account/Home/plan/limit timeline. Schedules are display metadata,
/// never evidence that consumption was replenished.
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
    let scheduledResetAt: Date?
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
        if endedEarly { return "额度已重置" }
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

/// Unknown coverage is deliberately distinct from a covered, empty interval.
/// Token events are local to Home; any consumption conservatively vetoes rollback.
enum QuotaCycleConsumption: String, Sendable { case absent, present, unknown }

struct QuotaCycleReversal: Equatable, Sendable {
    let beforeIndex: Int
    let dropIndex: Int
    let returnIndex: Int
}

enum QuotaActualCycleProjector {
    static let projectionVersion = 3
    static let minimumDrop = 5
    static let reboundTolerance = 3
    typealias Consumption = (Date, Date) -> QuotaCycleConsumption

    static func project(_ input: [QuotaCycleObservation], now: Date,
                        consumption: Consumption = { _, _ in .unknown }) -> [QuotaActualCycle] {
        projectWithDiagnostics(input, now: now, consumption: consumption).cycles
    }

    /// Returns raw-input indices. At most seven baseline bands are searched on
    /// an abrupt rise; no whole-history lookahead or time-limited candidate.
    static func reversals(_ observations: [QuotaCycleObservation],
                          consumption: Consumption) -> [QuotaCycleReversal] {
        var drops: [Int: [Int]] = [:]
        var result: [QuotaCycleReversal] = []
        for index in observations.indices.dropFirst() {
            let previous = observations[index - 1], item = observations[index]
            if previous.usedPercent - item.usedPercent >= minimumDrop {
                drops[previous.usedPercent, default: []].append(index)
            } else if item.usedPercent - previous.usedPercent >= minimumDrop {
                let bands = max(0, item.usedPercent - reboundTolerance)...min(100, item.usedPercent + reboundTolerance)
                guard let band = bands.filter({ drops[$0]?.isEmpty == false })
                    .max(by: { drops[$0]!.last! < drops[$1]!.last! }),
                      consumption(previous.at, item.at) == .absent else { continue }
                let drop = drops[band]!.removeLast()
                result.append(.init(beforeIndex: drop - 1, dropIndex: drop, returnIndex: index))
            }
        }
        return result
    }

    static func accepted(_ input: [QuotaCycleObservation], now: Date) -> [QuotaCycleObservation] {
        input.enumerated().filter {
            $0.element.at <= now && $0.element.at.timeIntervalSince1970.isFinite
                && (0...100).contains($0.element.usedPercent)
        }.sorted {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }.reduce(into: [QuotaCycleObservation]()) { result, pair in
            if result.last?.at != pair.element.at { result.append(pair.element) }
        }
    }

    static func projectWithDiagnostics(_ input: [QuotaCycleObservation], now: Date,
        consumption: Consumption = { _, _ in .unknown }) -> QuotaCycleProjection {
        let observations = accepted(input, now: now)
        guard let first = observations.first else { return .init(cycles: [], diagnostics: []) }
        let reversals = reversals(observations, consumption: consumption)
        let revoked = Set(reversals.map(\.dropIndex))
        var diagnostics = reversals.map { reversal in
            QuotaCycleDiagnosticEvent(kind: .withdrawn, at: observations[reversal.returnIndex].at,
                before: observations[reversal.beforeIndex], after: observations[reversal.dropIndex])
        }
        var cycles: [QuotaActualCycle] = []
        var firstObserved = first
        var latest = first
        var start: QuotaCycleBoundary?
        func make(end: Date?, current: Bool) -> QuotaActualCycle {
            .init(id: "observed-v3:\(firstObserved.at.timeIntervalSince1970)", start: start,
                  end: end.map(QuotaCycleBoundary.exact), scheduledResetAt: latest.resetsAt.timeIntervalSince1970.isFinite && latest.resetsAt.timeIntervalSince1970 > 0 ? latest.resetsAt : nil,
                  firstObservedAt: firstObserved.at, lastObservedAt: latest.at,
                  endedEarly: end != nil, resetChangePending: false, isCurrent: current)
        }
        for index in observations.indices.dropFirst() {
            let item = observations[index], previous = observations[index - 1]
            if previous.usedPercent - item.usedPercent >= minimumDrop && !revoked.contains(index) {
                cycles.append(make(end: item.at, current: false))
                diagnostics.append(.init(kind: .confirmed, at: item.at, before: previous, after: item))
                firstObserved = item
                start = .exact(item.at)
            }
            latest = item
        }
        // A clock tick or a changed reset deadline cannot end an observed cycle.
        cycles.append(make(end: nil, current: true))
        return .init(cycles: cycles.reversed(), diagnostics: diagnostics.sorted { $0.at < $1.at })
    }
}
